import CoreAudio
import EquinoxDSP
import Foundation

/// An app that gets its own tap (and mixer strip).
public struct DedicatedStrip: Hashable, Sendable {
    public let key: String
    public let processes: [AudioObjectID]
    public init(key: String, processes: [AudioObjectID]) { self.key = key; self.processes = processes }
}

/// A rest tap (everything except Equinox and the dedicated apps) plus one tap per dedicated app, in a private
/// aggregate device clocked by the real output. Tapped audio is muted at the source while this session's taps
/// exist; destroying it (or Equinox exiting) restores normal playback automatically.
///
/// Lifecycle: `init` creates taps + aggregate (no IO) → `prepare(renderer:)` → `startIO()` → `stopIO()` → `invalidate()`.
/// Splitting creation from IO lets the controller build the next session before stopping the current one.
public final class TapSession {
    public let outputDeviceID: AudioObjectID
    public private(set) var sampleRate: Double = 48_000
    /// Strip keys in the aggregate's input-stream order ("" = Other Apps).
    public private(set) var stripKeys: [String] = [StripSettings.othersKey]
    /// Dedicated strips that actually got a tap (a strip whose tap can't be created stays in Other Apps).
    public private(set) var activeStrips: [DedicatedStrip] = []

    private var restTap = AudioObjectID(kAudioObjectUnknown)
    private var restDescription: CATapDescription?
    private var exclusions: [AudioObjectID] = []
    private var stripTaps: [(key: String, tap: AudioObjectID, description: CATapDescription)] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var inputOffset = 0
    private var isStarted = false

    public init(outputDeviceID: AudioObjectID, excludedProcesses: [AudioObjectID], dedicated: [DedicatedStrip] = []) throws {
        self.outputDeviceID = outputDeviceID
        do {
            exclusions = try AudioSystem.validatedExclusions(excludedProcesses)
            let outputUID = try outputDeviceID.getString(kAudioDevicePropertyDeviceUID)

            // Dedicated taps first, so a strip whose processes vanished is simply left in Other Apps.
            for strip in dedicated.filter({ !$0.processes.isEmpty }).prefix(MixBus.maxStrips - 1) {
                let d = Self.describe(CATapDescription(stereoMixdownOfProcesses: strip.processes), name: "Equinox \(strip.key)")
                var id = AudioObjectID(kAudioObjectUnknown)
                guard AudioHardwareCreateProcessTap(d, &id) == noErr, id != kAudioObjectUnknown else { continue }
                stripTaps.append((strip.key, id, d))
                activeStrips.append(strip)
            }
            let rest = Self.describe(CATapDescription(stereoGlobalTapButExcludeProcesses: restExclusions()), name: "Equinox")
            try check(AudioHardwareCreateProcessTap(rest, &restTap), "Create system audio tap")
            restDescription = rest

            let descriptions = [rest] + stripTaps.map(\.description)
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Equinox",
                kAudioAggregateDeviceUIDKey: "com.pie.equinox.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: descriptions.map {
                    [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]
                },
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

            // Derive the stream order from the aggregate itself rather than assuming creation order.
            var keyForTap: [AudioObjectID: String] = [restTap: StripSettings.othersKey]
            for s in stripTaps { keyForTap[s.tap] = s.key }
            let creationOrder = [StripSettings.othersKey] + stripTaps.map(\.key)
            let reported = (try? aggregateID.getArray(kAudioAggregateDevicePropertyTapList, zero: AudioObjectID(0))) ?? []
            stripKeys = Self.orderedKeys(tapOrder: reported, keyForTap: keyForTap) ?? creationOrder

            sampleRate = try AudioSystem.nominalSampleRate(aggregateID)
            // Aggregate input streams: the output device's own inputs first, then the taps.
            inputOffset = AudioSystem.streamCount(outputDeviceID, scope: kAudioObjectPropertyScopeInput)
        } catch {
            invalidate()
            throw error
        }
    }

    private static func describe(_ d: CATapDescription, name: String) -> CATapDescription {
        d.uuid = UUID()
        d.name = name
        d.isPrivate = true
        d.muteBehavior = .mutedWhenTapped
        return d
    }

    private func restExclusions() -> [AudioObjectID] { exclusions + activeStrips.flatMap(\.processes) }

    /// Maps the aggregate's reported tap order to strip keys; nil if it doesn't match the taps we created.
    static func orderedKeys(tapOrder: [AudioObjectID], keyForTap: [AudioObjectID: String]) -> [String]? {
        guard tapOrder.count == keyForTap.count, Set(tapOrder) == Set(keyForTap.keys) else { return nil }
        return tapOrder.map { keyForTap[$0]! }
    }

    /// Updates the processes of existing strips in place (same keys, same order) without rebuilding the
    /// session, e.g. when an app's helper process starts or exits. Returns false if a full rebuild is needed.
    public func updateProcesses(_ dedicated: [DedicatedStrip]) -> Bool {
        let strips = dedicated.filter { !$0.processes.isEmpty }
        guard strips.map(\.key) == stripTaps.map(\.key), let restDescription else { return false }
        for (i, strip) in strips.enumerated() where strip.processes != activeStrips[i].processes {
            let d = CATapDescription(stereoMixdownOfProcesses: strip.processes)
            d.uuid = stripTaps[i].description.uuid
            d.name = stripTaps[i].description.name
            d.isPrivate = true
            d.muteBehavior = .mutedWhenTapped
            guard Self.setDescription(d, on: stripTaps[i].tap) else { return false }
            stripTaps[i].description = d
            activeStrips[i] = strip
        }
        let rest = CATapDescription(stereoGlobalTapButExcludeProcesses: restExclusions())
        rest.uuid = restDescription.uuid
        rest.name = restDescription.name
        rest.isPrivate = true
        rest.muteBehavior = .mutedWhenTapped
        guard Self.setDescription(rest, on: restTap) else { return false }
        self.restDescription = rest
        return true
    }

    private static func setDescription(_ description: CATapDescription, on tap: AudioObjectID) -> Bool {
        var address = tap.address(kAudioTapPropertyDescription)
        var ref: CATapDescription = description
        return withUnsafeMutablePointer(to: &ref) { p in
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), p) == noErr
        }
    }

    /// Main thread. Binds the renderer (only while no other session's IO is running on it) and creates the IOProc.
    public func prepare(renderer: Renderer) throws {
        renderer.prepare(sampleRate: sampleRate, inputStreamOffset: inputOffset, stripCount: stripKeys.count)
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }, "Create audio callback")
        // Keep the output device's own inputs (e.g. a headset mic) off: only the taps are read.
        // Otherwise starting IO could open the microphone (orange indicator, Bluetooth HFP mode).
        try? restrictInputToTap(deviceInputStreams: inputOffset, tapStreams: stripKeys.count)
    }

    static func inputStreamUsage(deviceInputStreams: Int, tapStreams: Int) -> [UInt32] {
        Array(repeating: 0, count: deviceInputStreams) + Array(repeating: 1, count: tapStreams)
    }

    private func restrictInputToTap(deviceInputStreams: Int, tapStreams: Int) throws {
        guard deviceInputStreams > 0, let ioProcID else { return }
        let usage = Self.inputStreamUsage(deviceInputStreams: deviceInputStreams, tapStreams: tapStreams)
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

    public func startIO() throws {
        try check(AudioDeviceStart(aggregateID, ioProcID), "Start audio")
        isStarted = true
    }

    /// Stops the IOProc but keeps the taps (so the tapped audio stays muted until `invalidate`).
    public func stopIO() {
        if isStarted, let ioProcID { AudioDeviceStop(aggregateID, ioProcID); isStarted = false }
    }

    /// Idempotent teardown in reverse creation order.
    public func invalidate() {
        stopIO()
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID); self.ioProcID = nil }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if restTap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(restTap); restTap = AudioObjectID(kAudioObjectUnknown) }
        for s in stripTaps { AudioHardwareDestroyProcessTap(s.tap) }
        stripTaps.removeAll()
    }

    deinit { invalidate() }
}
