import CoreAudio
import Foundation

/// One global process tap (excluding Equinox) + a private aggregate device clocked by the real output.
/// The tapped audio is muted at the source while this session lives; destroying it (or Equinox exiting)
/// restores normal playback automatically.
public final class TapSession {
    public let outputDeviceID: AudioObjectID
    public private(set) var sampleRate: Double = 48_000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false

    public init(outputDeviceID: AudioObjectID, excludedProcesses: [AudioObjectID], renderer: Renderer) throws {
        self.outputDeviceID = outputDeviceID
        do {
            let exclusions = try AudioSystem.validatedExclusions(excludedProcesses)
            let outputUID = try outputDeviceID.getString(kAudioDevicePropertyDeviceUID)

            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclusions)
            description.uuid = UUID()
            description.name = "Equinox"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap")

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Equinox",
                kAudioAggregateDeviceUIDKey: "com.pie.equinox.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

            sampleRate = try AudioSystem.nominalSampleRate(aggregateID)
            // Aggregate input streams: the output device's own inputs first, then the tap.
            let offset = AudioSystem.streamCount(outputDeviceID, scope: kAudioObjectPropertyScopeInput)
            renderer.prepare(sampleRate: sampleRate, inputStreamOffset: offset)

            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
                renderer.render(input: input, output: output)
            }, "Create audio callback")
            // Keep the output device's own inputs (e.g. a headset mic) off: only the tap is read.
            // Otherwise starting IO could open the microphone (orange indicator, Bluetooth HFP mode).
            try? restrictInputToTap(deviceInputStreams: offset)
        } catch {
            invalidate()
            throw error
        }
    }

    static func inputStreamUsage(deviceInputStreams: Int, tapStreams: Int) -> [UInt32] {
        Array(repeating: 0, count: deviceInputStreams) + Array(repeating: 1, count: tapStreams)
    }

    private func restrictInputToTap(deviceInputStreams: Int) throws {
        guard deviceInputStreams > 0, let ioProcID else { return }
        let usage = Self.inputStreamUsage(deviceInputStreams: deviceInputStreams, tapStreams: 1)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!
        let size = flagsOffset + usage.count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(usage.count), toByteOffset: countOffset, as: UInt32.self)
        for (i, on) in usage.enumerated() {
            raw.storeBytes(of: on, toByteOffset: flagsOffset + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = aggregateID.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw), "Limit capture to system audio")
    }

    public func start() throws {
        try check(AudioDeviceStart(aggregateID, ioProcID), "Start audio")
        isStarted = true
    }

    /// Idempotent teardown in reverse creation order.
    public func invalidate() {
        if isStarted, let ioProcID { AudioDeviceStop(aggregateID, ioProcID); isStarted = false }
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID); self.ioProcID = nil }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { invalidate() }
}
