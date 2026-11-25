import CoreAudio
import Foundation

/// Takes over one app's sound on one output device.
///
/// The tap diverts the app's audio away from the speakers; a private aggregate device then
/// plays it back scaled. At zero volume nothing needs to be played, so a muted app costs no
/// audio processing at all. Core Audio destroys taps with their owner, so if SoundSystem
/// quits or crashes every app simply returns to full volume.
///
/// Confined to the engine's queue.
final class ProcessTap {
    let device: AudioObjectID
    private(set) var processes: Set<AudioObjectID>

    private let name: String
    private let deviceUID: String
    private let description: CATapDescription
    private let renderer: OpaquePointer
    private var tap = AudioObjectID.unknown
    private var aggregate = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private var gain: Float
    private var isPlaying: Bool
    private let queue: DispatchQueue
    private var pendingStop: DispatchWorkItem?

    init(name: String, processes: Set<AudioObjectID>, device: AudioObjectID,
         gain: Float, isPlaying: Bool, queue: DispatchQueue) throws {
        guard let uid = device.deviceUID else { throw CoreAudioError(operation: "Read device UID", status: kAudioHardwareBadDeviceError) }
        self.name = name
        self.processes = processes
        self.device = device
        self.deviceUID = uid
        self.gain = gain
        self.isPlaying = isPlaying
        self.queue = queue
        renderer = SSRendererCreate(gain)

        // A device-specific tap keeps the device's channel layout and leaves anything the app
        // plays on other devices alone.
        description = CATapDescription(processes: processes.sorted(), deviceUID: uid, stream: 0)
        description.name = "SoundSystem – \(name)"
        description.isPrivate = true
        description.muteBehavior = .muted

        do {
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create tap")
            try updateIO()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
        // The IOProc is gone by now; the delay covers a final in-flight audio cycle.
        let renderer = renderer
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { SSRendererDestroy(renderer) }
    }

    func setGain(_ newGain: Float) throws {
        guard newGain != gain else { return }
        gain = newGain
        SSRendererSetGain(renderer, newGain)
        try updateIO()
    }

    func setPlaying(_ playing: Bool) throws {
        guard playing != isPlaying else { return }
        isPlaying = playing
        try updateIO()
    }

    /// Apps gain and lose helper processes all the time (browser tabs, game clients).
    func setProcesses(_ newProcesses: Set<AudioObjectID>) throws {
        guard newProcesses != processes else { return }
        processes = newProcesses
        description.processes = newProcesses.sorted()
        var address = AudioObjectID.address(kAudioTapPropertyDescription)
        var value = Unmanaged.passUnretained(description)
        try check(AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value),
                  "Update tap")
    }

    func close() {
        pendingStop?.cancel()
        stop()
        if let procID { AudioDeviceDestroyIOProcID(aggregate, procID) }
        procID = nil
        if aggregate != .unknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = .unknown
        if tap != .unknown { AudioHardwareDestroyProcessTap(tap) }
        tap = .unknown
    }

    // MARK: - Playback

    private func updateIO() throws {
        if gain > 0 && isPlaying {
            pendingStop?.cancel()
            pendingStop = nil
            try start()
        } else if isRunning && pendingStop == nil {
            // Linger so gaps between sounds don't restart the device, but do stop eventually:
            // running audio IO keeps the Mac from idle-sleeping.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingStop = nil
                self?.stop()
            }
            pendingStop = work
            queue.asyncAfter(deadline: .now() + (gain > 0 ? 3 : 0.25), execute: work)
        }
    }

    private func start() throws {
        guard !isRunning else { return }
        if aggregate == .unknown { try createAggregate() }
        try check(AudioDeviceStart(aggregate, procID), "Start audio")
        isRunning = true
    }

    private func stop() {
        guard isRunning else { return }
        AudioDeviceStop(aggregate, procID)
        isRunning = false
    }

    private func createAggregate() throws {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundSystem – \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create output")
        try check(AudioDeviceCreateIOProcID(aggregate, SSRendererIOProc, UnsafeMutableRawPointer(renderer), &procID), "Create IO")
        if let procID { _ = SSUseOnlyLastInputStream(aggregate, procID) }
    }
}
