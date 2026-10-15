import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) { self.status = status; self.operation = operation }

    public var description: String {
        let n = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        let code = chars.allSatisfy { (32...126).contains($0) } ? "'\(String(bytes: chars, encoding: .ascii)!)'" : "\(status)"
        return "\(operation) failed (\(code))"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func address(_ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func has(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = address(selector, scope)
        return AudioObjectHasProperty(self, &a)
    }

    func isSettable(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = address(selector, scope)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &a, &settable) == noErr && settable.boolValue
    }

    func get<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                initial: T) throws -> T {
        var a = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &value), "Read property \(selector)")
        return value
    }

    func getArray<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     zero: T) throws -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size), "Size of property \(selector)")
        var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &values), "Read property \(selector)")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func getString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var a = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &value), "Read string \(selector)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    func set<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                value: T) throws {
        var a = address(selector, scope)
        var v = value
        try check(AudioObjectSetPropertyData(self, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v), "Write property \(selector)")
    }
}
