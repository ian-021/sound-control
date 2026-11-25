import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class MixerModel {
    private(set) var apps: [MixerApp] = []
    private(set) var output: OutputDevice?
    private(set) var permission = AudioPermission.state
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    private var settings: [String: AppSetting]

    @ObservationIgnored private var engine: AudioEngine!
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var isRequestingPermission = false
    @ObservationIgnored private var reportedOutput: OutputDevice?
    @ObservationIgnored private var outputHold: DispatchWorkItem?
    private static let settingsKey = "appSettings"

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode([String: AppSetting].self, from: $0) } ?? [:]
        engine = AudioEngine(settings: settings) { [weak self] snapshot in
            self?.receive(snapshot)
        }
        engine.setEnabled(permission == .granted)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.engine.rebuildAfterWake() } }
    }

    // MARK: - Apps

    func setting(for app: MixerApp) -> AppSetting { settings[app.id] ?? AppSetting() }
    var hasAdjustments: Bool { !settings.isEmpty }

    /// Moving a muted app's slider unmutes it, as on Windows.
    func setVolume(_ volume: Float, for app: MixerApp) { update(app) { $0.volume = volume; $0.muted = false } }
    func toggleMute(_ app: MixerApp) { update(app) { $0.muted.toggle() } }

    func resetAll() {
        settings = [:]
        save()
        engine.resetAll()
    }

    private func update(_ app: MixerApp, _ change: (inout AppSetting) -> Void) {
        var setting = setting(for: app)
        change(&setting)
        settings[app.id] = setting.isDefault ? nil : setting
        save()
        if permission == .undetermined { requestPermission() }
        engine.apply(setting, to: app.id)
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }

    // MARK: - Output

    /// The device echoes every volume write several times, a frame or more late. Following those
    /// echoes mid-drag makes the slider jump backwards, so the dragged value wins until the
    /// drag has been still for a moment.
    func setOutputVolume(_ volume: Float) {
        if let current = output {
            output = OutputDevice(name: current.name, volume: volume, isMuted: current.isMuted && volume == 0, canMute: current.canMute)
        }
        outputHold?.cancel()
        let release = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.followDevice() }
        }
        outputHold = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: release)
        engine.setOutputVolume(volume)
    }

    func toggleOutputMute() {
        followDevice()
        engine.setOutputMuted(!(output?.isMuted ?? false))
    }

    private func receive(_ snapshot: MixerSnapshot) {
        if apps != snapshot.apps { apps = snapshot.apps }
        reportedOutput = snapshot.output
        // A different device, such as headphones being plugged in, always takes over at once.
        if outputHold == nil || snapshot.output?.name != output?.name { followDevice() }
    }

    private func followDevice() {
        outputHold?.cancel()
        outputHold = nil
        if output != reportedOutput { output = reportedOutput }
    }

    // MARK: - Permission

    func requestPermission() {
        guard permission != .denied else { return AudioPermission.openSettings() }
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        AudioPermission.request { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRequestingPermission = false
                    self.refreshPermission()
                }
            }
        }
    }

    private func refreshPermission() {
        permission = AudioPermission.state
        engine.setEnabled(permission == .granted)
    }

    // MARK: - Lifecycle

    func panelDidOpen() {
        refreshPermission()
        opensAtLogin = SMAppService.mainApp.status == .enabled
        engine.refreshNow()
        refreshTimer?.invalidate()
        refreshTimer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.refreshNow()
                if self?.permission != .granted { self?.refreshPermission() }
            }
        }
    }

    func panelDidClose() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shutDown() { engine.shutDown() }
}
