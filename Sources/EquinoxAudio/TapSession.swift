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
        } catch {
            invalidate()
            throw error
        }
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
