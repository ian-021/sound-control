import AppIntents

extension Notification.Name {
    static let openMixer = Notification.Name("local.SoundSystem.openMixer")
}

/// Runs inside the app (not the extension) because it requires the foreground.
struct OpenMixerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open App Volumes"
    static let description = IntentDescription("Shows a volume slider for each app that is playing sound.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openMixer, object: nil)
        return .result()
    }
}
