import AppKit

/// macOS gates app-audio access behind Privacy & Security > Screen & System Audio Recording.
/// There is no public API to read that state, and an unauthorised tap silently delivers
/// silence, so the state is checked before any app is touched.
enum AudioPermission {
    enum State { case granted, denied, undetermined }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var state: State {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .granted }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else { return completion(true) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { completion($0) }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
