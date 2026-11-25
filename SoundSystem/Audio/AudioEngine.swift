import AppKit
import AudioToolbox
import CoreAudio
import os

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false

    var isDefault: Bool { !muted && volume >= 0.995 }
    /// Squared so the slider feels even to the ear; linear gain bunches all the change at the bottom.
    var gain: Float { muted ? 0 : volume * volume }
}

struct MixerApp: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String?
    let isPlaying: Bool
    let problem: String?
}

struct OutputDevice: Equatable {
    let name: String
    let volume: Float?     // nil when the device has no adjustable volume (most HDMI displays)
    let isMuted: Bool
    let canMute: Bool
}

struct MixerSnapshot: Equatable {
    var apps: [MixerApp] = []
    var output: OutputDevice?
}

/// Watches which apps are making sound and keeps a tap on each one whose volume was changed.
/// Apps left at 100% are never touched.
final class AudioEngine: @unchecked Sendable {
    private struct Source {
        let pid: pid_t
        let identity: AppIdentity?
        let listeners: [PropertyListener]
    }

    private struct Group {
        let identity: AppIdentity
        var processes: Set<AudioObjectID> = []
        var devices: Set<AudioObjectID> = []
        var isPlaying = false
    }

    private struct TapKey: Hashable {
        let app: String
        let device: AudioObjectID
    }

    private let log = Logger(subsystem: "local.SoundSystem", category: "engine")
    private let queue = DispatchQueue(label: "local.SoundSystem.audio", qos: .userInitiated)
    private let onChange: @MainActor (MixerSnapshot) -> Void
    private let resolver = AppResolver()
    private let pendingOutputVolume = OSAllocatedUnfairLock<Float?>(initialState: nil)

    // Everything below is confined to `queue`.
    private var sources: [AudioObjectID: Source] = [:]
    private var groups: [String: Group] = [:]
    private var heard: Set<String> = []
    private var settings: [String: AppSetting] = [:]
    private var taps: [TapKey: ProcessTap] = [:]
    private var problems: [TapKey: String] = [:]
    private var isEnabled = false
    private var output = AudioObjectID.unknown
    private var systemListeners: [PropertyListener] = []
    private var outputListeners: [PropertyListener] = []
    private var sampleRates: [AudioObjectID: Float64] = [:]
    private var refreshPending = false
    private var lastSnapshot: MixerSnapshot?

    init(settings: [String: AppSetting], onChange: @escaping @MainActor (MixerSnapshot) -> Void) {
        self.onChange = onChange
        queue.async { self.startWatching(with: settings) }
    }

    private func startWatching(with savedSettings: [String: AppSetting]) {
        settings = savedSettings
        systemListeners = [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ].map { PropertyListener(.system, $0, queue: queue) { [weak self] in self?.setNeedsRefresh() } }
        systemListeners.append(
            PropertyListener(.system, kAudioHardwarePropertyServiceRestarted, queue: queue) { [weak self] in
                self?.rebuild()
            })
        refresh()
    }

    // MARK: - Commands (any thread)

    /// False until the user allows audio access. Tapping without it would silence apps.
    func setEnabled(_ enabled: Bool) {
        queue.async {
            guard enabled != self.isEnabled else { return }
            self.isEnabled = enabled
            self.rebuild()
        }
    }

    func apply(_ setting: AppSetting, to app: String) {
        queue.async {
            self.settings[app] = setting.isDefault ? nil : setting
            self.problems = self.problems.filter { $0.key.app != app }
            self.reconcile(app)
            self.publish()
        }
    }

    func resetAll() {
        queue.async {
            self.settings = [:]
            self.problems = [:]
            self.reconcileAll()
            self.publish()
        }
    }

    func refreshNow() { queue.async { self.refresh() } }
    func rebuildAfterWake() { queue.async { self.rebuild() } }

    func setOutputVolume(_ volume: Float) {
        // Only the newest value matters: if the queue is busy, skip the ones in between.
        let alreadyQueued = pendingOutputVolume.withLock { pending in
            defer { pending = volume }
            return pending != nil
        }
        guard !alreadyQueued else { return }
        queue.async {
            guard let volume = self.pendingOutputVolume.withLock({ pending -> Float? in
                defer { pending = nil }
                return pending
            }) else { return }
            let device = AudioObjectID.defaultOutput
            device.set(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, to: Float32(volume))
            if volume > 0, device.value(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0 {
                device.set(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, to: UInt32(0))
            }
        }
    }

    func setOutputMuted(_ muted: Bool) {
        queue.async {
            AudioObjectID.defaultOutput.set(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, to: UInt32(muted ? 1 : 0))
        }
    }

    /// Hands every app back to the system at full volume.
    func shutDown() {
        queue.sync {
            isEnabled = false
            closeAllTaps()
        }
    }

    // MARK: - Watching

    private func setNeedsRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        queue.async {
            self.refreshPending = false
            self.refresh()
        }
    }

    private func refresh() {
        updateOutput()
        updateSources()
        updateGroups()
        reconcileAll()
        publish()
    }

    private func rebuild() {
        closeAllTaps()
        problems = [:]
        refresh()
    }

    private func closeAllTaps() {
        taps.values.forEach { $0.close() }
        taps = [:]
    }

    private func updateOutput() {
        let current = AudioObjectID.defaultOutput
        guard current != output else { return }
        output = current
        problems = [:]
        outputListeners = [
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput),
        ].map { PropertyListener(current, $0.0, $0.1, queue: queue) { [weak self] in self?.publish() } }
        outputListeners.append(
            PropertyListener(current, kAudioDevicePropertyNominalSampleRate, queue: queue) { [weak self] in
                self?.sampleRateChanged(current)
            })
        sampleRates[current] = current.value(kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    private func sampleRateChanged(_ device: AudioObjectID) {
        let rate = device.value(kAudioDevicePropertyNominalSampleRate, default: Float64(0))
        guard rate != sampleRates[device] else { return }
        sampleRates[device] = rate
        rebuild()
    }

    private func updateSources() {
        let current = Set(AudioObjectID.system.objectList(kAudioHardwarePropertyProcessObjectList))
        for gone in sources.keys where !current.contains(gone) { sources[gone] = nil }

        for object in current where sources[object] == nil {
            let pid = object.value(kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != getpid() else {
                sources[object] = Source(pid: pid, identity: nil, listeners: [])
                continue
            }
            // IsRunningOutput does not reliably notify on its own; IsRunning and Devices do.
            let listeners = [
                (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
                (kAudioProcessPropertyIsRunning, kAudioObjectPropertyScopeGlobal),
                (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
            ].map { PropertyListener(object, $0.0, $0.1, queue: queue) { [weak self] in self?.setNeedsRefresh() } }
            sources[object] = Source(pid: pid, identity: resolver.identity(for: pid), listeners: listeners)
        }
    }

    private func updateGroups() {
        let devices = Set(AudioObjectID.system.objectList(kAudioHardwarePropertyDevices))
        var updated: [String: Group] = [:]
        for (object, source) in sources {
            guard let identity = source.identity else { continue }
            var group = updated[identity.key] ?? Group(identity: identity)
            group.processes.insert(object)
            if object.value(kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 {
                group.isPlaying = true
                group.devices.formUnion(
                    object.objectList(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
                        .filter { devices.contains($0) && $0.hasOutput })
            }
            updated[identity.key] = group
        }
        groups = updated
        heard.formUnion(updated.values.filter(\.isPlaying).map(\.identity.key))
        heard.formIntersection(updated.keys)
    }

    // MARK: - Taps

    private func reconcileAll() {
        for app in Set(groups.keys).union(taps.keys.map(\.app)) { reconcile(app) }
    }

    private func reconcile(_ app: String) {
        guard isEnabled, let group = groups[app] else { return closeTaps(of: app) }

        guard let setting = settings[app] else {
            // Back at 100%. Play through for a moment before letting go, so dragging the
            // slider against its end doesn't repeatedly tear down and rebuild the tap.
            let existing = taps.filter { $0.key.app == app }
            guard !existing.isEmpty else { return }
            existing.forEach { try? $0.value.setGain(1) }
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.settings[app] == nil else { return }
                self.closeTaps(of: app)
            }
            return
        }

        // The default device is always covered, so an app that is about to start playing is
        // already at the right volume when it does.
        let wanted = Set(group.devices.union([output]).filter { $0 != .unknown }.map { TapKey(app: app, device: $0) })
        for key in taps.keys where key.app == app && !wanted.contains(key) {
            taps.removeValue(forKey: key)?.close()
        }
        for key in wanted where problems[key] == nil {
            let isPlaying = group.isPlaying && (group.devices.isEmpty || group.devices.contains(key.device))
            do {
                if let tap = taps[key] {
                    try tap.setProcesses(group.processes)
                    try tap.setPlaying(isPlaying)
                    try tap.setGain(setting.gain)
                } else {
                    taps[key] = try ProcessTap(
                        name: group.identity.name, processes: group.processes, device: key.device,
                        gain: setting.gain, isPlaying: isPlaying, queue: queue)
                    log.info("Adjusting \(group.identity.name, privacy: .public) on device \(key.device)")
                }
            } catch {
                // Fail open: better an app at full volume than one that is silent for no visible reason.
                log.error("\(group.identity.name, privacy: .public): \(String(describing: error), privacy: .public)")
                taps.removeValue(forKey: key)?.close()
                problems[key] = "Can’t change this app’s volume on the current output (\(error))."
            }
        }
    }

    private func closeTaps(of app: String) {
        for key in taps.keys where key.app == app { taps.removeValue(forKey: key)?.close() }
    }

    // MARK: - Publishing

    private func publish() {
        let apps = groups.values
            .filter { $0.isPlaying || heard.contains($0.identity.key) || settings[$0.identity.key] != nil }
            .map { group in
                MixerApp(
                    id: group.identity.key, name: group.identity.name, path: group.identity.path,
                    isPlaying: group.isPlaying,
                    problem: problems.first { $0.key.app == group.identity.key }?.value)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let snapshot = MixerSnapshot(apps: apps, output: outputSnapshot())
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(snapshot) } }
    }

    private func outputSnapshot() -> OutputDevice? {
        guard output != .unknown else { return nil }
        let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        let scope = kAudioObjectPropertyScopeOutput
        return OutputDevice(
            name: output.string(kAudioObjectPropertyName) ?? "Output",
            volume: output.isSettable(volume, scope) ? output.value(volume, scope, default: Float32(1)) : nil,
            isMuted: output.value(kAudioDevicePropertyMute, scope, default: UInt32(0)) != 0,
            canMute: output.isSettable(kAudioDevicePropertyMute, scope))
    }
}
