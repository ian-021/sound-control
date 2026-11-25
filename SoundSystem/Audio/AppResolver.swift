import AppKit
import Darwin

/// The app a user would recognise as the source of a sound.
struct AppIdentity: Hashable {
    let key: String        // stable across launches; used to remember volumes
    let name: String
    let path: String?      // bundle path, for the icon
}

/// Maps audio processes (often anonymous helpers) to the app they belong to.
///
/// The enclosing .app bundle wins over macOS's "responsible process", because launchers are
/// responsible for what they launch: Riot Client would otherwise swallow League of Legends.
/// The responsible process is the fallback for system helpers that live outside any app
/// bundle, such as the WebKit process that plays Safari's audio.
final class AppResolver {
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private let responsibleFor: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private var identitiesByBundlePath: [String: AppIdentity] = [:]

    func identity(for pid: pid_t) -> AppIdentity? {
        guard let path = executablePath(of: pid) else { return nil }
        if (path as NSString).lastPathComponent == "systemsoundserverd" {
            return AppIdentity(key: "system-sounds", name: "System Sounds", path: nil)
        }
        if let bundle = enclosingApp(of: path) { return identity(forBundle: bundle) }

        if let owner = responsibleFor?(pid), owner > 1, owner != pid,
           let ownerPath = executablePath(of: owner), let bundle = enclosingApp(of: ownerPath) {
            return identity(forBundle: bundle)
        }
        return AppIdentity(key: path, name: (path as NSString).lastPathComponent, path: path)
    }

    private func identity(forBundle path: String) -> AppIdentity {
        if let cached = identitiesByBundlePath[path] { return cached }
        let name = FileManager.default.displayName(atPath: path)
        let identity = AppIdentity(
            key: Bundle(path: path)?.bundleIdentifier ?? path,
            name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
            path: path
        )
        identitiesByBundlePath[path] = identity
        return identity
    }

    /// Outermost bundle: ".../Brave Browser.app/.../Brave Browser Helper.app/..." is Brave Browser.
    private func enclosingApp(of path: String) -> String? {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if component.hasSuffix(".app") { return current }
        }
        return nil
    }

    private func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
