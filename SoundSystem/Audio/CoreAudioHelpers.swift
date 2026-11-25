import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus
    var description: String { "\(operation) failed (\(status))" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

/// Thin, typed wrappers around AudioObject property calls.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func has(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope)
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(self, &address)
            && AudioObjectIsPropertySettable(self, &address, &settable) == noErr
            && settable.boolValue
    }

    /// Reads a fixed-size plain value such as UInt32, Float32 or Float64.
    func value<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T
    ) -> T {
        var address = Self.address(selector, scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result)
        return status == noErr ? result : fallback
    }

    @discardableResult
    func set<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        to newValue: T
    ) -> OSStatus {
        var address = Self.address(selector, scope)
        var value = newValue
        return AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    func objectList(_ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = Self.address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    var deviceUID: String? { string(kAudioDevicePropertyDeviceUID) }
    var hasOutput: Bool { !objectList(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty }

    static var defaultOutput: AudioObjectID {
        system.value(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
    }
}

/// A property listener that unregisters itself when released.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID,
         _ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue,
         handler: @escaping () -> Void) {
        self.object = object
        self.address = AudioObjectID.address(selector, scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
