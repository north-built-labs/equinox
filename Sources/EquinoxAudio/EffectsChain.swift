import AVFoundation
import AudioToolbox
import EquinoxDSP

public enum EffectsError: Error { case engineSetup }

extension BuiltInEffect {
    var componentDescription: AudioComponentDescription {
        let sub: OSType
        switch self {
        case .reverb: sub = kAudioUnitSubType_Reverb2
        case .compressor: sub = kAudioUnitSubType_DynamicsProcessor
        case .multibandCompressor: sub = kAudioUnitSubType_MultiBandCompressor
        case .limiter: sub = kAudioUnitSubType_PeakLimiter
        case .delay: sub = kAudioUnitSubType_Delay
        }
        return AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: sub,
                                         componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }
}

extension AudioUnitID {
    public init(component: AVAudioUnitComponent) {
        let d = component.audioComponentDescription
        self.init(type: d.componentType, subType: d.componentSubType, manufacturer: d.componentManufacturer,
                  name: component.name, manufacturerName: component.manufacturerName)
    }

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

public enum PluginCatalog {
    /// Installed effect Audio Units (effects and music effects), sorted by manufacturer then name.
    public static func installedEffects() -> [AudioUnitID] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }
        .map(AudioUnitID.init(component:))
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }
}

/// Instantiates units. Third-party AUv3 load out of process (a crash can't take Equinox down);
/// in-process loads are wrapped in the crash marker.
public final class EffectLoader {
    let pluginGuard: PluginGuard?
    public init(pluginGuard: PluginGuard?) { self.pluginGuard = pluginGuard }

    @MainActor
    public func instantiate(_ slot: EffectSlot) async throws -> AVAudioUnit {
        switch slot.kind {
        case .builtIn(let effect):
            return AVAudioUnitEffect(audioComponentDescription: effect.componentDescription)
        case .audioUnit(let id):
            let description = id.componentDescription
            guard let component = AVAudioUnitComponentManager.shared().components(matching: description).first else {
                throw EffectsError.engineSetup
            }
            let isV3 = component.audioComponentDescription.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
            return try await AVAudioUnit.instantiate(with: description, options: isV3 ? .loadOutOfProcess : [])
        }
    }

    /// The plugin's ID if it loads in-process (a crash there takes Equinox down), else nil.
    func inProcessID(_ slot: EffectSlot) -> AudioUnitID? {
        guard case .audioUnit(let id) = slot.kind,
              let component = AVAudioUnitComponentManager.shared().components(matching: id.componentDescription).first
        else { return nil }
        let isV3 = component.audioComponentDescription.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
        return isV3 ? nil : id
    }
}

/// One AVAudioEngine in realtime manual-rendering mode: input → units (in order) → main mixer.
/// Built on the main thread; `render` is realtime-safe.
public final class EffectsChain: @unchecked Sendable {
    public static let maxFrames = 4096

    public let sampleRate: Double
    /// Slots that actually loaded, in chain order.
    public let slots: [EffectSlot]
    private let units: [UUID: AVAudioUnit]
    private let engine: AVAudioEngine
    private let renderBlock: AVAudioEngineManualRenderingBlock
    private let input: UnsafeMutableAudioBufferListPointer
    private let output: UnsafeMutableAudioBufferListPointer
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private var observers: [(AUParameterTree, AUParameterObserverToken)] = []

    /// nil when there is nothing to run. A slot whose unit fails to load is skipped.
    @MainActor
    public static func make(slots: [EffectSlot], sampleRate: Double, loader: EffectLoader) async throws -> EffectsChain? {
        // Guard in-process plugins from instantiation through state restore, initialization and engine start.
        let guarded = slots.compactMap(loader.inProcessID)
        for id in guarded { loader.pluginGuard?.begin(id) }
        defer { for id in guarded { loader.pluginGuard?.end(id) } }
        var loaded: [(EffectSlot, AVAudioUnit)] = []
        for slot in slots {
            if let unit = try? await loader.instantiate(slot) { loaded.append((slot, unit)) }
        }
        guard !loaded.isEmpty else { return nil }
        return try EffectsChain(loaded, sampleRate: sampleRate)
    }

    private init(_ loaded: [(EffectSlot, AVAudioUnit)], sampleRate: Double) throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        let input = AudioBufferList.allocate(maximumBuffers: 2)
        let output = AudioBufferList.allocate(maximumBuffers: 2)
        guard engine.inputNode.setManualRenderingInputPCMFormat(format, inputBlock: { frames in
            input[0].mDataByteSize = frames * 4
            input[1].mDataByteSize = frames * 4
            return UnsafePointer(input.unsafeMutablePointer)
        }) else { throw EffectsError.engineSetup }

        var previous: AVAudioNode = engine.inputNode
        for (slot, unit) in loaded {
            engine.attach(unit)
            if let state = slot.state,
               let dict = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any] {
                unit.auAudioUnit.fullState = dict
            }
            unit.auAudioUnit.shouldBypassEffect = !slot.isEnabled
            engine.connect(previous, to: unit, format: format)
            previous = unit
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.start()

        self.sampleRate = sampleRate
        self.slots = loaded.map(\.0)
        self.units = Dictionary(uniqueKeysWithValues: loaded.map { ($0.0.id, $0.1) })
        self.engine = engine
        self.renderBlock = engine.manualRenderingBlock
        self.input = input
        self.output = output
        outL = .allocate(capacity: Self.maxFrames); outL.initialize(repeating: 0, count: Self.maxFrames)
        outR = .allocate(capacity: Self.maxFrames); outR.initialize(repeating: 0, count: Self.maxFrames)
    }

    deinit {
        for (tree, token) in observers { tree.removeParameterObserver(token) }
        engine.stop()
        free(input.unsafeMutablePointer)
        free(output.unsafeMutablePointer)
        outL.deallocate(); outR.deallocate()
    }

    /// Realtime-safe, in place, any frame count. On a render error the audio passes through unchanged.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var offset = 0
        while offset < frames {
            let n = min(Self.maxFrames, frames - offset)
            let bytes = UInt32(n * MemoryLayout<Float>.size)
            input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left + offset))
            input[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right + offset))
            output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outL))
            output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outR))
            var error: OSStatus = noErr
            if renderBlock(AVAudioFrameCount(n), output.unsafeMutablePointer, &error) == .success,
               let l = output[0].mData?.assumingMemoryBound(to: Float.self),
               let r = output[1].mData?.assumingMemoryBound(to: Float.self) {
                (left + offset).update(from: l, count: n)
                (right + offset).update(from: r, count: n)
            }
            offset += n
        }
    }

    public func setBypassed(_ id: UUID, _ bypassed: Bool) { units[id]?.auAudioUnit.shouldBypassEffect = bypassed }

    public func unit(for id: UUID) -> AUAudioUnit? { units[id]?.auAudioUnit }

    /// Calls `handler` on the main actor whenever any unit parameter changes (UI, plugin window, automation).
    public func observeParameters(_ handler: @escaping @MainActor () -> Void) {
        for unit in units.values {
            guard let tree = unit.auAudioUnit.parameterTree else { continue }
            let token = tree.token(byAddingParameterObserver: { _, _ in
                Task { @MainActor in handler() }
            })
            observers.append((tree, token))
        }
    }

    /// Current parameter state of every unit, as binary plists.
    public func captureStates() -> [UUID: Data] {
        units.compactMapValues { unit in
            unit.auAudioUnit.fullState.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        }
    }
}
