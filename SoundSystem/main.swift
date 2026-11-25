import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: MixerModel!
    private var panel: StatusPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = MixerModel()
        panel = StatusPanel(model: model)
        NotificationCenter.default.addObserver(forName: .openMixer, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.open() }
        }
    }

    /// Opening the app again from Finder or Spotlight shows the mixer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutDown() }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
