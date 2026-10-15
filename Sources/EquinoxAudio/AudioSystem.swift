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

public struct AudioProcessInfo: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let executableName: String
    public let isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, executableName: String, isRunningOutput: Bool) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID
        self.executableName = executableName; self.isRunningOutput = isRunningOutput
    }
}

extension AudioSystem {
    /// Every process the HAL knows about (clients of Core Audio).
    public static func audioProcesses() -> [AudioProcessInfo] {
        let ids = (try? AudioObjectID.system.getArray(kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))) ?? []
        return ids.compactMap { id in
            guard let pid = try? id.get(kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { return nil }
            let bundleID = (try? id.getString(kAudioProcessPropertyBundleID)) ?? ""
            let running = ((try? id.get(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundleID,
                                    executableName: executableName(pid), isRunningOutput: running)
        }
    }

    static func executableName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
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
