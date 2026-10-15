import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transportType: UInt32
    /// Whether the device exposes a settable hardware volume; if not, Equinox applies volume in software.
    public let hasHardwareVolume: Bool

    public init(id: AudioObjectID, uid: String, name: String, transportType: UInt32, hasHardwareVolume: Bool = true) {
        self.id = id; self.uid = uid; self.name = name; self.transportType = transportType
        self.hasHardwareVolume = hasHardwareVolume
    }
}

public enum AudioSystem {
    public static func outputDevices() -> [AudioDevice] {
        let ids = (try? AudioObjectID.system.getArray(kAudioHardwarePropertyDevices, zero: AudioObjectID(0))) ?? []
        return ids.compactMap { id in
            guard streamCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 else { return nil }
            return try? describe(id)
        }
    }

    public static func describe(_ id: AudioObjectID) throws -> AudioDevice {
        AudioDevice(id: id,
                    uid: try id.getString(kAudioDevicePropertyDeviceUID),
                    name: try id.getString(kAudioObjectPropertyName),
                    transportType: (try? id.get(kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0,
                    hasHardwareVolume: id.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                     scope: kAudioObjectPropertyScopeOutput))
    }

    public static func defaultOutputDevice() throws -> AudioObjectID {
        let id = try AudioObjectID.system.get(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else { throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "Find default output") }
        return id
    }

    public static func setDefaultOutputDevice(_ id: AudioObjectID) throws {
        try AudioObjectID.system.set(kAudioHardwarePropertyDefaultOutputDevice, value: id)
    }

    public static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        ((try? id.getArray(kAudioDevicePropertyStreams, scope: scope, zero: AudioStreamID(0))) ?? []).count
    }

    public static func nominalSampleRate(_ id: AudioObjectID) throws -> Double {
        try id.get(kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    public static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var a = AudioObjectID.system.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID.system, &a, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object),
                  "Resolve audio process for pid \(pid)")
        guard object != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Resolve audio process for pid \(pid)")
        }
        return object
    }

    /// The global tap must exclude Equinox itself or its output would be re-captured (feedback).
    public static func validatedExclusions(_ objects: [AudioObjectID]) throws -> [AudioObjectID] {
        guard !objects.isEmpty, !objects.contains(AudioObjectID(kAudioObjectUnknown)) else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Exclude Equinox from capture")
        }
        return objects
    }

    public static func hardwareVolume(_ id: AudioObjectID) -> Float? {
        guard id.has(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput) else { return nil }
        return try? id.get(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
    }

    /// Returns false when the device has no settable hardware volume.
    @discardableResult
    public static func setHardwareVolume(_ id: AudioObjectID, _ volume: Float) -> Bool {
        let sel = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        guard id.isSettable(sel, scope: kAudioObjectPropertyScopeOutput) else { return false }
        return (try? id.set(sel, scope: kAudioObjectPropertyScopeOutput, value: Float32(min(max(volume, 0), 1)))) != nil
    }
}

/// Core Audio property listener delivering on the main queue; removed on deinit.
public final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    public init(object: AudioObjectID, selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping () -> Void) throws {
        self.object = object
        address = object.address(selector, scope)
        block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, .main, block), "Listen to property \(selector)")
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
}
