# Equinox Phase 3 (Effects & Plugins) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reorderable effects chain (built-in Reverb, Compressor, Multiband Compressor, Limiter, Delay, plus any installed Audio Unit effect) between the EQ and the output gain, with per-effect bypass, plugin UIs in their own windows, plugin state saved in presets, and crash protection for in-process plugins.

**Architecture:** `EffectsChain` (EquinoxAudio) wraps one `AVAudioEngine` in `.realtime` manual-rendering mode: input node → effect units in order → main mixer. Its `render(left:right:frames:)` is called from the IOProc between `MasterProcessor.processPre` (EQ) and `processPost` (gain + limiter). Chains are built off the audio thread (async AU instantiation) and handed over through the acknowledgement mailbox (now generic `Mailbox<Value>`), so an engine is never freed on the audio thread. Enable/disable toggles `shouldBypassEffect` live; structural edits (add/remove/reorder/preset switch) build a new chain carrying the live parameter state over. Third-party AUv3 load out-of-process; AUv2 load in-process behind a crash marker file (`PluginGuard`).

**Tech Stack:** as before + AVFoundation (`AVAudioEngine`, `AVAudioUnit`, `AVAudioUnitComponentManager`), CoreAudioKit-free (`AUAudioUnit.requestViewController`).

**Spec:** `docs/superpowers/specs/2026-10-15-equinox-design.md` (§3 Phase 3, §4.3, §5 plugin crash)

## Global Constraints

- All Phase 1–2 Global Constraints still apply.
- Effects position: after EQ (and preamp-free), before volume/boost/balance gain and the limiter. Master "Enabled" off (bypass) also skips the effects chain.
- `EffectsChain.maxFrames` = 4096 per engine render call; larger IO buffers are chunked.
- Built-in effects are Apple Audio Units (`kAudioUnitManufacturer_Apple`, type `kAudioUnitType_Effect`): reverb `kAudioUnitSubType_Reverb2`, compressor `kAudioUnitSubType_DynamicsProcessor`, multiband `kAudioUnitSubType_MultiBandCompressor`, limiter `kAudioUnitSubType_PeakLimiter`, delay `kAudioUnitSubType_Delay`.
- Plugin state = `AUAudioUnit.fullState` as binary plist `Data`, stored per slot inside the preset.
- Crash marker file: `~/Library/Application Support/Equinox/plugin-loading.json`; only written for in-process (non-v3) loads.
- A slot whose unit fails to load is skipped (the chain still runs).

## Review Focus

1. **Chain swap while audio runs** (add/remove/reorder rapidly): no engine freed or stopped on the audio thread; stale async builds never overwrite a newer chain. Tests in Task 2 (`testStaleBuildIsDiscarded` via `AudioController` is not unit-testable → covered by `MailboxTests` + live self-test "effects: rapid edits converge").
2. **Live parameter tweaks survive structural edits and saving** (tweak reverb, then add a delay, then save): state carried over and persisted. Tests in Task 2 (`testStateRoundTripsThroughFullState`) and Task 3 (`testSaveCapturesLiveStates`).
3. **Old presets/settings without effects fields** load unchanged. Test in Task 1 (`testPresetWithoutEffectsDecodes`).
4. **Plugin that crashes during load:** next launch it is disabled with a notice, the rest of the chain still runs, user can re-enable. Tests in Task 2 (`PluginGuardTests`) and Task 3 (`testCrashedPluginIsDisabledAndFiltered`).
5. **IO buffers larger than 4096 frames / sample-rate change:** chain chunks renders; a rate change rebuilds the chain at the new rate. Tests in Task 2 (`testChunksLargeBuffers`, `testChainBuiltAtRequestedRate`).

---

## File Structure

```
Sources/EquinoxDSP/
  Effects.swift            NEW BuiltInEffect, AudioUnitID, EffectKind, EffectSlot
  MasterProcessor.swift    split into processPre / processPost
Sources/EquinoxAudio/
  Renderer.swift           Mailbox<Value> (generic), effects mailbox, effects render stage
  EffectsChain.swift       NEW manual-rendering engine chain, EffectLoader, PluginCatalog, component descriptions
  PluginGuard.swift        NEW crash marker
  AudioController.swift    setEffects / effectUnit / captureEffectStates / installedPlugins, chain (re)builds
Sources/EquinoxCore/
  Preset.swift             effects field + tolerant decoding
  AppSettings.swift        disabledPlugins
  AppModel.swift           effects API, crash recovery, state capture on save
Sources/Equinox/
  EffectsViews.swift       NEW EffectsPage, EffectCard, GenericParameterView, PluginWindows
  MainWindow.swift         + Effects page
  EquinoxApp.swift         PluginGuard wiring
  Diagnostics/SelfTest.swift, Snapshots.swift
Tests/EquinoxDSPTests/EffectsModelTests.swift
Tests/EquinoxAudioTests/EffectsChainTests.swift
Tests/EquinoxCoreTests/EffectsAppModelTests.swift
```

---

### Task 1: Effect model, preset field, processor split

**Files:**
- Create: `Sources/EquinoxDSP/Effects.swift`
- Modify: `Sources/EquinoxDSP/MasterProcessor.swift`, `Sources/EquinoxCore/Preset.swift`
- Test: `Tests/EquinoxDSPTests/EffectsModelTests.swift`, add to `Tests/EquinoxCoreTests/PresetTests.swift`

**Interfaces:**
- Produces:
  - `BuiltInEffect` (`reverb, compressor, multibandCompressor, limiter, delay`; `displayName`, `symbol`)
  - `AudioUnitID(type:subType:manufacturer:name:manufacturerName:)` (Codable, Hashable), `.key: String`
  - `EffectKind` (`.builtIn(BuiltInEffect)`, `.audioUnit(AudioUnitID)`; Codable, Hashable), `.displayName`
  - `EffectSlot(id:kind:isEnabled:state:)` (Codable, Hashable, Identifiable), `.structure: EffectSlot.Structure` (id, kind, isEnabled)
  - `MasterProcessor.processPre(left:right:frames:)`, `.processPost(left:right:frames:)`; `process` = pre + post
  - `Preset.effects: [EffectSlot]` (decodes as `[]` when absent; imported presets get fresh slot IDs)

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxDSPTests/EffectsModelTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

final class EffectsModelTests: XCTestCase {
    func testSlotRoundTripsThroughJSON() throws {
        let au = AudioUnitID(type: 0x61756678, subType: 0x62706173, manufacturer: 0x6170706C, name: "AUBandpass", manufacturerName: "Apple")
        let slots = [EffectSlot(kind: .builtIn(.reverb), isEnabled: false, state: Data([1, 2, 3])),
                     EffectSlot(kind: .audioUnit(au))]
        let decoded = try JSONDecoder().decode([EffectSlot].self, from: JSONEncoder().encode(slots))
        XCTAssertEqual(decoded, slots)
        XCTAssertEqual(decoded[1].kind.displayName, "AUBandpass")
        XCTAssertEqual(au.key, "61756678-62706173-6170706C")
    }

    func testStructureIgnoresState() {
        let a = EffectSlot(kind: .builtIn(.delay), state: Data([1]))
        var b = a; b.state = Data([2])
        XCTAssertEqual(a.structure, b.structure)
        b.isEnabled = false
        XCTAssertNotEqual(a.structure, b.structure)
    }

    func testPrePlusPostEqualsProcess() {
        var s = DSPSettings(); s.softwareVolume = 0.5
        s.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)]
        let a = MasterProcessor(maxFrames: 512, sampleRate: 48_000), b = MasterProcessor(maxFrames: 512, sampleRate: 48_000)
        a.apply(DSPConfig(settings: s, sampleRate: 48_000)); b.apply(DSPConfig(settings: s, sampleRate: 48_000))
        var l1 = Signal.sine(1000, fs: 48_000, count: 2000), r1 = l1, l2 = l1, r2 = l1
        l1.withUnsafeMutableBufferPointer { lp in r1.withUnsafeMutableBufferPointer { rp in
            a.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 2000) } }
        l2.withUnsafeMutableBufferPointer { lp in r2.withUnsafeMutableBufferPointer { rp in
            b.processPre(left: lp.baseAddress!, right: rp.baseAddress!, frames: 2000)
            b.processPost(left: lp.baseAddress!, right: rp.baseAddress!, frames: 2000) } }
        XCTAssertEqual(l1, l2)
    }

    func testPostSilencesNonFiniteFromEffects() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: 48_000)
        p.apply(DSPConfig(settings: DSPSettings(), sampleRate: 48_000))
        var l = [Float](repeating: .infinity, count: 64), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            p.processPost(left: lp.baseAddress!, right: rp.baseAddress!, frames: 64) } }
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
    }
}
```

Add to `Tests/EquinoxCoreTests/PresetTests.swift` (inside the class):
```swift
    func testPresetWithoutEffectsDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-0000000000AA","name":"Old","preampDB":0,"bands":[],"isBuiltIn":false}"#
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(p.effects, [])
        XCTAssertEqual(p.name, "Old")
    }

    func testImportKeepsEffectsWithFreshSlotIDs() throws {
        var p = Preset(name: "FX", bands: [])
        p.effects = [EffectSlot(kind: .builtIn(.reverb), state: Data([9]))]
        let imported = try Preset.importPresets(from: try Preset.exportData([p]))[0]
        XCTAssertEqual(imported.effects.count, 1)
        XCTAssertEqual(imported.effects[0].state, Data([9]))
        XCTAssertNotEqual(imported.effects[0].id, p.effects[0].id)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "EffectsModelTests|PresetTests"`
Expected: compile failure — `cannot find 'AudioUnitID' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxDSP/Effects.swift`:
```swift
import Foundation

public enum BuiltInEffect: String, Codable, CaseIterable, Sendable {
    case reverb, compressor, multibandCompressor, limiter, delay

    public var displayName: String {
        switch self {
        case .reverb: "Reverb"
        case .compressor: "Compressor"
        case .multibandCompressor: "Multiband Compressor"
        case .limiter: "Limiter"
        case .delay: "Delay"
        }
    }

    public var symbol: String {
        switch self {
        case .reverb: "building.columns"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .multibandCompressor: "chart.bar.xaxis"
        case .limiter: "rectangle.compress.vertical"
        case .delay: "wave.3.right"
        }
    }
}

/// Identifies an installed Audio Unit effect by its component description (four-char codes as UInt32).
public struct AudioUnitID: Codable, Hashable, Sendable {
    public let type: UInt32
    public let subType: UInt32
    public let manufacturer: UInt32
    public let name: String
    public let manufacturerName: String

    public init(type: UInt32, subType: UInt32, manufacturer: UInt32, name: String, manufacturerName: String) {
        self.type = type; self.subType = subType; self.manufacturer = manufacturer
        self.name = name; self.manufacturerName = manufacturerName
    }

    public var key: String { String(format: "%08X-%08X-%08X", type, subType, manufacturer) }
}

public enum EffectKind: Codable, Hashable, Sendable {
    case builtIn(BuiltInEffect)
    case audioUnit(AudioUnitID)

    public var displayName: String {
        switch self {
        case .builtIn(let e): e.displayName
        case .audioUnit(let id): id.name
        }
    }
}

public struct EffectSlot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: EffectKind
    public var isEnabled: Bool
    /// `AUAudioUnit.fullState` as a binary plist; nil = factory defaults.
    public var state: Data?

    public init(id: UUID = UUID(), kind: EffectKind, isEnabled: Bool = true, state: Data? = nil) {
        self.id = id; self.kind = kind; self.isEnabled = isEnabled; self.state = state
    }

    public struct Structure: Hashable, Sendable {
        public let id: UUID
        public let kind: EffectKind
        public let isEnabled: Bool
    }

    /// Identity, order-relevant kind and enablement — everything except parameter state.
    public var structure: Structure { Structure(id: id, kind: kind, isEnabled: isEnabled) }
}
```

`Sources/EquinoxDSP/MasterProcessor.swift` — replace `process(left:right:frames:)` and `processChunk` with:
```swift
    /// Realtime-safe, in place, any frame count. Equivalent to `processPre` then `processPost`.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        processPre(left: left, right: right, frames: frames)
        processPost(left: left, right: right, frames: frames)
    }

    /// EQ stage (before the effects chain). Realtime-safe, in place, any frame count.
    public func processPre(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        forEachChunk(frames) { o, n in
            eq.process(left: left + o, right: right + o, frames: n)
            if !Self.isFinite(left + o, right + o, n) {
                eq.reset()
                (left + o).update(repeating: 0, count: n); (right + o).update(repeating: 0, count: n)
            }
        }
    }

    /// Output stage (after the effects chain): gain ramp, then limiter. Realtime-safe, in place, any frame count.
    public func processPost(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        forEachChunk(frames) { o, n in
            if !Self.isFinite(left + o, right + o, n) {
                limiter.reset()
                (left + o).update(repeating: 0, count: n); (right + o).update(repeating: 0, count: n)
            }
            ramp(left + o, &currentLeft, targetLeft, n)
            ramp(right + o, &currentRight, targetRight, n)
            limiter.process(left: left + o, right: right + o, frames: n)
        }
    }

    @inline(__always)
    private func forEachChunk(_ frames: Int, _ body: (Int, Int) -> Void) {
        var offset = 0
        while offset < frames {
            let n = min(maxFrames, frames - offset)
            body(offset, n)
            offset += n
        }
    }

    private static func isFinite(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) -> Bool {
        var el: Float = 0, er: Float = 0
        vDSP_svesq(l, 1, &el, vDSP_Length(n))
        vDSP_svesq(r, 1, &er, vDSP_Length(n))
        return (el + er).isFinite
    }
```

`Sources/EquinoxCore/Preset.swift`:
- Add stored property `public var effects: [EffectSlot]` after `isBuiltIn`, and an init parameter `effects: [EffectSlot] = []` (last) assigning it.
- Add tolerant decoding inside `Preset`:
```swift
    enum CodingKeys: String, CodingKey { case id, name, preampDB, bands, isBuiltIn, effects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        preampDB = try c.decode(Double.self, forKey: .preampDB)
        bands = try c.decode([EQBand].self, forKey: .bands)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        effects = (try? c.decodeIfPresent([EffectSlot].self, forKey: .effects)) ?? []
    }
```
- In `importPresets`, pass `effects: p.effects.map { var s = $0; s.id = UUID(); return s }` to the `Preset(...)` initializer.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "EffectsModelTests|PresetTests|ProcessorTests"` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(dsp): effect slot model, preset effects field, pre/post processor stages"
```

---

### Task 2: Effects engine, generic mailbox, crash guard, controller

**Files:**
- Create: `Sources/EquinoxAudio/EffectsChain.swift`, `Sources/EquinoxAudio/PluginGuard.swift`
- Modify: `Sources/EquinoxAudio/Renderer.swift`, `Sources/EquinoxAudio/AudioController.swift`
- Test: `Tests/EquinoxAudioTests/EffectsChainTests.swift`

**Interfaces:**
- Consumes: `EffectSlot`, `EffectKind`, `BuiltInEffect`, `AudioUnitID`, `MasterProcessor.processPre/processPost` (Task 1).
- Produces:
  - `Mailbox<Value: AnyObject>` (`post`, `take`, `acknowledge`, `reset`; `Entry.value`), `typealias ConfigMailbox = Mailbox<DSPConfig>`
  - `EffectsChain`: `static make(slots:sampleRate:loader:) async throws -> EffectsChain?` (@MainActor), `.sampleRate`, `.slots`, `render(left:right:frames:)`, `setBypassed(_:_:)`, `unit(for:) -> AUAudioUnit?`, `captureStates() -> [UUID: Data]`, `static maxFrames = 4096`
  - `EffectLoader(pluginGuard:)` with `instantiate(_ slot:) async throws -> AVAudioUnit`; `PluginCatalog.installedEffects() -> [AudioUnitID]`
  - `PluginGuard(directory:)`: `begin(_:)`, `end()`, `takeCrashedPlugin() -> AudioUnitID?`
  - `Renderer.submitEffects(_ chain: EffectsChain?)`
  - `AudioControlling` additions: `setEffects(_ slots: [EffectSlot])`, `effectUnit(for id: UUID) -> AUAudioUnit?`, `captureEffectStates() -> [UUID: Data]`, `installedPlugins() -> [AudioUnitID]`
  - `AudioController(pluginGuard: PluginGuard? = nil)`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxAudioTests/EffectsChainTests.swift`:
```swift
import AVFoundation
import XCTest
@testable import EquinoxAudio
import EquinoxDSP

@MainActor
final class EffectsChainTests: XCTestCase {
    let fs = 48_000.0
    static let preGain: AUParameterAddress = 2   // AUPeakLimiter "Pre-Gain", −40…40 dB

    func sine(_ n: Int, amplitude: Float = 0.0316) -> [Float] {
        (0..<n).map { amplitude * Float(sin(2 * Double.pi * 1000 * Double($0) / fs)) }
    }

    /// Renders `blocks` × `size` frames of a 1 kHz sine; returns the output/input level in dB over the last half.
    func gainDB(_ chain: EffectsChain, blocks: Int = 24, size: Int = 512) -> Double {
        let x = sine(blocks * size)
        var y = x, yr = x
        y.withUnsafeMutableBufferPointer { l in yr.withUnsafeMutableBufferPointer { r in
            for b in 0..<blocks { chain.render(left: l.baseAddress! + b * size, right: r.baseAddress! + b * size, frames: size) }
        } }
        let half = x.count / 2
        let pin = x[half...].reduce(0) { $0 + $1 * $1 }, pout = y[half...].reduce(0) { $0 + $1 * $1 }
        return 10 * log10(Double(pout / pin))
    }

    func makeLimiter(state: Data? = nil, enabled: Bool = true) async throws -> (EffectsChain, UUID) {
        let slot = EffectSlot(kind: .builtIn(.limiter), isEnabled: enabled, state: state)
        let chain = try await EffectsChain.make(slots: [slot], sampleRate: fs, loader: EffectLoader(pluginGuard: nil))!
        return (chain, slot.id)
    }

    func testEmptyChainIsNil() async throws {
        let chain = try await EffectsChain.make(slots: [], sampleRate: fs, loader: EffectLoader(pluginGuard: nil))
        XCTAssertNil(chain)
    }

    func testChainAppliesUnitProcessing() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        XCTAssertEqual(gainDB(chain), 6, accuracy: 0.1)
    }

    func testBypassedSlotPassesThroughLive() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        chain.setBypassed(id, true)
        XCTAssertEqual(gainDB(chain), 0, accuracy: 0.05)
    }

    func testDisabledSlotStartsBypassed() async throws {
        let (chain, id) = try await makeLimiter(enabled: false)
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        XCTAssertEqual(gainDB(chain), 0, accuracy: 0.05)
    }

    func testStateRoundTripsThroughFullState() async throws {
        let (a, id) = try await makeLimiter()
        a.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        let state = a.captureStates()[id]
        XCTAssertNotNil(state)
        let (b, _) = try await makeLimiter(state: state)
        XCTAssertEqual(gainDB(b), 6, accuracy: 0.1)
    }

    func testChunksLargeBuffers() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        XCTAssertEqual(gainDB(chain, blocks: 3, size: 10_000), 6, accuracy: 0.1)
    }

    func testChainBuiltAtRequestedRate() async throws {
        let slot = EffectSlot(kind: .builtIn(.delay))
        let chain = try await EffectsChain.make(slots: [slot], sampleRate: 96_000, loader: EffectLoader(pluginGuard: nil))!
        XCTAssertEqual(chain.sampleRate, 96_000)
    }

    func testAllBuiltInsLoad() async throws {
        let slots = BuiltInEffect.allCases.map { EffectSlot(kind: .builtIn($0)) }
        let chain = try await EffectsChain.make(slots: slots, sampleRate: fs, loader: EffectLoader(pluginGuard: nil))!
        XCTAssertEqual(chain.slots.count, BuiltInEffect.allCases.count)
        for s in slots { XCTAssertNotNil(chain.unit(for: s.id)) }
    }

    func testInstalledAudioUnitLoadsThroughPluginPath() async throws {
        let catalog = PluginCatalog.installedEffects()
        let bandpass = try XCTUnwrap(catalog.first { $0.name.contains("AUBandpass") })
        let slot = EffectSlot(kind: .audioUnit(bandpass))
        let chain = try await EffectsChain.make(slots: [slot], sampleRate: fs, loader: EffectLoader(pluginGuard: nil))!
        XCTAssertLessThan(gainDB(chain), -6)   // default 5 kHz band-pass attenuates 1 kHz
    }

    func testUnloadableSlotIsSkipped() async throws {
        let bogus = AudioUnitID(type: 0x61756678, subType: 0x7A7A7A7A, manufacturer: 0x7A7A7A7A, name: "Nope", manufacturerName: "None")
        let good = EffectSlot(kind: .builtIn(.delay))
        let chain = try await EffectsChain.make(slots: [EffectSlot(kind: .audioUnit(bogus)), good], sampleRate: fs,
                                                loader: EffectLoader(pluginGuard: nil))!
        XCTAssertEqual(chain.slots.map(\.id), [good.id])
    }

    func testRendererAppliesEffectsBetweenEQAndOutput() async throws {
        let (chain, id) = try await makeLimiter()
        chain.unit(for: id)!.parameterTree!.parameter(withAddress: Self.preGain)!.value = 6
        let renderer = Renderer()
        renderer.prepare(sampleRate: fs, inputStreamOffset: 0, stripCount: 1)
        renderer.submit(DSPConfig(settings: DSPSettings(), sampleRate: fs))
        renderer.submitEffects(chain)
        let frames = 512
        let x = sine(frames * 24)
        var outLevel: Double = 0, inLevel: Double = 0
        for b in 0..<24 {
            let input = AudioBufferList.allocate(maximumBuffers: 1)
            let ip = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames { ip[2 * i] = x[b * frames + i]; ip[2 * i + 1] = x[b * frames + i] }
            input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: ip)
            let output = AudioBufferList.allocate(maximumBuffers: 1)
            let op = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: op)
            renderer.render(input: UnsafePointer(input.unsafeMutablePointer), output: output.unsafeMutablePointer)
            if b >= 12 { for i in 0..<frames { inLevel += Double(ip[2 * i] * ip[2 * i]); outLevel += Double(op[2 * i] * op[2 * i]) } }
        }
        XCTAssertEqual(10 * log10(outLevel / inLevel), 6, accuracy: 0.1)
    }
}

final class PluginGuardTests: XCTestCase {
    func testMarkerLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = AudioUnitID(type: 1, subType: 2, manufacturer: 3, name: "Crashy", manufacturerName: "X")
        let guardFile = PluginGuard(directory: dir)
        XCTAssertNil(guardFile.takeCrashedPlugin())
        guardFile.begin(id)
        guardFile.end()
        XCTAssertNil(guardFile.takeCrashedPlugin())
        guardFile.begin(id)                       // "crash" before end()
        XCTAssertEqual(PluginGuard(directory: dir).takeCrashedPlugin(), id)
        XCTAssertNil(PluginGuard(directory: dir).takeCrashedPlugin())   // consumed
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "EffectsChainTests|PluginGuardTests"`
Expected: compile failure — `cannot find 'EffectsChain' in scope`.

- [ ] **Step 3: Generic mailbox and renderer effects stage**

In `Sources/EquinoxAudio/Renderer.swift`:
- Rename `final class ConfigMailbox: @unchecked Sendable` to `final class Mailbox<Value: AnyObject>: @unchecked Sendable`; inside it rename the `Entry` property `config` to `value` (type `Value`), `init(config:generation:)` to `init(value:generation:)`, and `func post(_ config: DSPConfig)` to `func post(_ value: Value)` creating `Entry(value: value, generation: nextGeneration)`. Update its doc comment to "Hands immutable objects from the main thread to the audio thread…". Add below the class:
```swift
typealias ConfigMailbox = Mailbox<DSPConfig>

/// Lets the effects mailbox carry "no chain".
final class EffectsBox: @unchecked Sendable {
    let chain: EffectsChain?
    init(_ chain: EffectsChain?) { self.chain = chain }
}
```
- In `Renderer` add:
```swift
    private let effectsMailbox = Mailbox<EffectsBox>()
    private var effects: Mailbox<EffectsBox>.Entry?

    /// Main thread. nil removes the chain.
    public func submitEffects(_ chain: EffectsChain?) { effectsMailbox.post(EffectsBox(chain)) }
```
- In `prepare(...)` add `effects = nil` and `effectsMailbox.reset()` next to `current = nil` / `mailbox.reset()`.
- In `render`, replace `processor.apply(entry.config)` / `mixBus.apply(entry.config.strips)` with `entry.value`, and replace
  `if current != nil { processor.process(left: mixL, right: mixR, frames: frames) }` with:
```swift
        if let fxEntry = effectsMailbox.take() {
            effects = fxEntry                  // previous chain is still owned by the mailbox history
            effectsMailbox.acknowledge(fxEntry)
        }
        if let config = current?.value {
            processor.processPre(left: mixL, right: mixR, frames: frames)
            if !config.isBypassed, let chain = effects?.value.chain {
                chain.render(left: mixL, right: mixR, frames: frames)
            }
            processor.processPost(left: mixL, right: mixR, frames: frames)
        }
```

- [ ] **Step 4: Effects chain, loader, catalog, guard**

`Sources/EquinoxAudio/EffectsChain.swift`:
```swift
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
            if !isV3 { pluginGuard?.begin(id) }
            defer { if !isV3 { pluginGuard?.end() } }
            return try await AVAudioUnit.instantiate(with: description, options: isV3 ? .loadOutOfProcess : [])
        }
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

    /// nil when there is nothing to run. A slot whose unit fails to load is skipped.
    @MainActor
    public static func make(slots: [EffectSlot], sampleRate: Double, loader: EffectLoader) async throws -> EffectsChain? {
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

    /// Current parameter state of every unit, as binary plists.
    public func captureStates() -> [UUID: Data] {
        units.compactMapValues { unit in
            unit.auAudioUnit.fullState.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        }
    }
}
```

`Sources/EquinoxAudio/PluginGuard.swift`:
```swift
import EquinoxDSP
import Foundation

/// Crash marker for in-process plugin loads: written before instantiation, removed after.
/// If Equinox dies while loading, the marker survives and names the culprit on the next launch.
public final class PluginGuard {
    private let url: URL

    public init(directory: URL) { url = directory.appendingPathComponent("plugin-loading.json") }

    public func begin(_ id: AudioUnitID) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(id).write(to: url, options: .atomic)
    }

    public func end() { try? FileManager.default.removeItem(at: url) }

    /// Returns (and clears) the plugin that was loading when Equinox last died, if any.
    public func takeCrashedPlugin() -> AudioUnitID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        end()
        return try? JSONDecoder().decode(AudioUnitID.self, from: data)
    }
}
```

- [ ] **Step 5: Controller**

In `Sources/EquinoxAudio/AudioController.swift`:
- `import AVFoundation` at the top.
- Add to `AudioControlling`:
```swift
    /// Effect chain in order. Same slots with different enablement are toggled live; anything else rebuilds.
    func setEffects(_ slots: [EffectSlot])
    func effectUnit(for id: UUID) -> AUAudioUnit?
    func captureEffectStates() -> [UUID: Data]
    func installedPlugins() -> [AudioUnitID]
```
- Replace `public init() {}` with:
```swift
    private let pluginGuard: PluginGuard?
    private var effectSlots: [EffectSlot] = []
    private var chain: EffectsChain?
    private var chainBuild = 0

    public init(pluginGuard: PluginGuard? = nil) { self.pluginGuard = pluginGuard }

    public func setEffects(_ slots: [EffectSlot]) {
        effectSlots = slots
        if let chain, chain.slots.map(\.id) == slots.map(\.id), chain.slots.map(\.kind) == slots.map(\.kind) {
            for s in slots { chain.setBypassed(s.id, !s.isEnabled) }
            return
        }
        buildChain()
    }

    public func effectUnit(for id: UUID) -> AUAudioUnit? { chain?.unit(for: id) }
    public func captureEffectStates() -> [UUID: Data] { chain?.captureStates() ?? [:] }
    public func installedPlugins() -> [AudioUnitID] { PluginCatalog.installedEffects() }

    /// Builds a new chain off the audio thread, carrying live parameter state over; the newest build wins.
    private func buildChain() {
        chainBuild += 1
        let build = chainBuild
        let rate = session?.sampleRate ?? chain?.sampleRate ?? 48_000
        let live = chain?.captureStates() ?? [:]
        let slots = effectSlots.map { slot -> EffectSlot in
            var s = slot
            if let state = live[s.id] { s.state = state }
            return s
        }
        let loader = EffectLoader(pluginGuard: pluginGuard)
        Task { @MainActor [weak self] in
            let built = slots.isEmpty ? nil : try? await EffectsChain.make(slots: slots, sampleRate: rate, loader: loader)
            guard let self, build == self.chainBuild else { return }
            self.chain = built
            self.renderer.submitEffects(built)
        }
    }
```
- In `rebuild()`, right after `renderer.submit(DSPConfig(...))` inside the inner `do`, add:
```swift
                if let chain, chain.sampleRate == newSession.sampleRate { renderer.submitEffects(chain) }
```
  and right after `session = newSession` add:
```swift
            if let chain, chain.sampleRate != newSession.sampleRate { buildChain() }
            else if chain == nil, !effectSlots.isEmpty { buildChain() }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "EffectsChainTests|PluginGuardTests|ConfigMailboxTests|RendererTests"` → all PASS.
Then add the four new protocol members to `FakeAudio` (Tests/EquinoxCoreTests/AppModelTests.swift) and `PreviewAudio` (Snapshots.swift), with `import AVFoundation`:
```swift
    var effects: [EffectSlot] = []
    var effectStates: [UUID: Data] = [:]
    func setEffects(_ slots: [EffectSlot]) { effects = slots }
    func effectUnit(for id: UUID) -> AUAudioUnit? { nil }
    func captureEffectStates() -> [UUID: Data] { effectStates }
    func installedPlugins() -> [AudioUnitID] { [] }
```
(`PreviewAudio.installedPlugins()` returns `PluginCatalog.installedEffects()`.) Run `swift test` → all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(audio): realtime effects engine chain, plugin loading/catalog, crash guard"
```

---

### Task 3: AppModel effects API

**Files:**
- Modify: `Sources/EquinoxCore/AppSettings.swift`, `Sources/EquinoxCore/AppModel.swift`
- Test: `Tests/EquinoxCoreTests/EffectsAppModelTests.swift`

**Interfaces:**
- Consumes: `EffectSlot`, `EffectKind`, `AudioUnitID`, `AudioControlling` effects members.
- Produces: `AppSettings.disabledPlugins: [String]`; `AppModel(…, crashedPlugin: AudioUnitID? = nil)`; `AppModel.availablePlugins`, `disabledPluginKeys`, `addEffect(_:) -> UUID`, `removeEffect(_:)`, `moveEffect(_:by:)`, `setEffectEnabled(_:_:)`, `isDisabledByCrash(_:) -> Bool`, `reenablePlugin(_:)`, `effectUnit(for:) -> AUAudioUnit?`, `refreshPlugins()`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxCoreTests/EffectsAppModelTests.swift`:
```swift
import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

@MainActor
final class EffectsAppModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!
    let crashy = AudioUnitID(type: 1, subType: 2, manufacturer: 3, name: "Crashy", manufacturerName: "X")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-fx-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel(crashed: AudioUnitID? = nil) -> AppModel {
        AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem(), crashedPlugin: crashed)
    }

    func testAddEffectPushesChainAndMarksModified() {
        let m = makeModel()
        let id = m.addEffect(.builtIn(.reverb))
        XCTAssertEqual(audio.effects.map(\.id), [id])
        XCTAssertTrue(m.isModified)
    }

    func testMoveToggleRemove() {
        let m = makeModel()
        let reverb = m.addEffect(.builtIn(.reverb)), delay = m.addEffect(.builtIn(.delay))
        m.moveEffect(delay, by: -1)
        XCTAssertEqual(audio.effects.map(\.id), [delay, reverb])
        m.moveEffect(delay, by: -1)                 // already first: no-op
        XCTAssertEqual(audio.effects.map(\.id), [delay, reverb])
        m.setEffectEnabled(reverb, false)
        XCTAssertEqual(audio.effects.last?.isEnabled, false)
        m.removeEffect(delay)
        XCTAssertEqual(audio.effects.map(\.id), [reverb])
    }

    func testSaveCapturesLiveStates() {
        let m = makeModel()
        let id = m.addEffect(.builtIn(.reverb))
        audio.effectStates = [id: Data([1, 2, 3])]
        m.saveAs(name: "FX")
        XCTAssertEqual(m.selectedPreset.effects.first?.state, Data([1, 2, 3]))
        XCTAssertFalse(m.isModified)
    }

    func testSelectingPresetSwapsEffects() {
        let m = makeModel()
        _ = m.addEffect(.builtIn(.delay))
        m.saveAs(name: "FX")
        m.selectPreset(Preset.flat.id)
        XCTAssertTrue(audio.effects.isEmpty)
        m.selectPreset(m.userPresets[0].id)
        XCTAssertEqual(audio.effects.count, 1)
    }

    func testCrashedPluginIsDisabledAndFiltered() {
        let m = makeModel(crashed: crashy)
        XCTAssertNotNil(m.lastError)
        let id = m.addEffect(.audioUnit(crashy))
        _ = m.addEffect(.builtIn(.limiter))
        XCTAssertEqual(audio.effects.count, 1)
        XCTAssertTrue(m.isDisabledByCrash(m.working.effects.first { $0.id == id }!))
        m.reenablePlugin(crashy.key)
        XCTAssertEqual(audio.effects.count, 2)
    }

    func testDisabledPluginsPersist() {
        _ = makeModel(crashed: crashy).flushSave()
        let m2 = makeModel()
        XCTAssertTrue(m2.disabledPluginKeys.contains(crashy.key))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EffectsAppModelTests`
Expected: compile failure — `extra argument 'crashedPlugin' in call`.

- [ ] **Step 3: Implement**

`Sources/EquinoxCore/AppSettings.swift`: add `public var disabledPlugins: [String] = []` after `appMix`, add `disabledPlugins` to `CodingKeys`, and decode with
```swift
        disabledPlugins = (try? c.decodeIfPresent([String].self, forKey: .disabledPlugins)) ?? []
```

`Sources/EquinoxCore/AppModel.swift`:
- `import AVFoundation` at the top.
- `isModified` becomes:
```swift
    public var isModified: Bool {
        working.bands != selectedPreset.bands || working.preampDB != selectedPreset.preampDB
            || working.effects.map(\.structure) != selectedPreset.effects.map(\.structure)
    }
```
- Add public state after the mixer state:
```swift
    // MARK: Effects
    public private(set) var availablePlugins: [AudioUnitID] = []
    public private(set) var disabledPluginKeys: Set<String> = []
```
- Add private `@ObservationIgnored private var lastPushedEffects: [EffectSlot]?`.
- Init signature gains a final parameter `crashedPlugin: AudioUnitID? = nil`. Restore `disabledPluginKeys = Set(s.disabledPlugins)` with the other restores, and after the `lastError` corrupt-file handling add:
```swift
        if let crashedPlugin {
            disabledPluginKeys.insert(crashedPlugin.key)
            lastError = "\(crashedPlugin.name) crashed while loading and was turned off. You can turn it back on in Effects."
        }
```
  and after `devices = audio.outputDevices()` add `availablePlugins = audio.installedPlugins()`.
- Add the API:
```swift
    @discardableResult
    public func addEffect(_ kind: EffectKind) -> UUID {
        let slot = EffectSlot(kind: kind)
        working.effects.append(slot)
        push()
        return slot.id
    }

    public func removeEffect(_ id: UUID) {
        working.effects.removeAll { $0.id == id }
        push()
    }

    public func moveEffect(_ id: UUID, by offset: Int) {
        guard let i = working.effects.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), working.effects.count - 1)
        guard i != j else { return }
        working.effects.swapAt(i, j)
        push()
    }

    public func setEffectEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = working.effects.firstIndex(where: { $0.id == id }) else { return }
        working.effects[i].isEnabled = enabled
        push()
    }

    public func isDisabledByCrash(_ slot: EffectSlot) -> Bool {
        if case .audioUnit(let id) = slot.kind { return disabledPluginKeys.contains(id.key) }
        return false
    }

    public func reenablePlugin(_ key: String) {
        disabledPluginKeys.remove(key)
        push()
    }

    public func effectUnit(for id: UUID) -> AUAudioUnit? { audio.effectUnit(for: id) }

    public func refreshPlugins() { availablePlugins = audio.installedPlugins() }

    /// Copies live plugin parameter state into the working preset's slots.
    private func captureEffectStates() {
        let states = audio.captureEffectStates()
        guard !states.isEmpty else { return }
        for i in working.effects.indices {
            if let state = states[working.effects[i].id] { working.effects[i].state = state }
        }
    }
```
- In `push()`, after `audio.apply(s)`:
```swift
        let effects = working.effects.filter { !isDisabledByCrash($0) }
        if effects.map(\.structure) != lastPushedEffects?.map(\.structure) {
            audio.setEffects(effects)
            lastPushedEffects = effects
        }
```
- In `save()`, first line inside after the `guard`: `captureEffectStates()`, and set `userPresets[i].effects = working.effects` with the bands/preamp copy.
- In `saveAs(name:)`, call `captureEffectStates()` first and pass `effects: working.effects` into the new `Preset(...)`.
- In `flushSave()`, call `captureEffectStates()` before building `s`, and add `s.disabledPlugins = disabledPluginKeys.sorted()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EffectsAppModelTests` → 6 PASS; `swift test` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): effects chain in presets, plugin crash recovery, live state capture"
```

---

### Task 4: Effects UI, plugin windows, live checks, snapshots

**Files:**
- Create: `Sources/Equinox/EffectsViews.swift`
- Modify: `Sources/Equinox/MainWindow.swift`, `Sources/Equinox/EquinoxApp.swift`, `Sources/Equinox/Diagnostics/SelfTest.swift`, `Sources/Equinox/Diagnostics/Snapshots.swift`

**Interfaces:**
- Consumes: Task 3 AppModel API, `AUAudioUnit`, `PluginGuard`, `PluginCatalog`.
- Produces: `EffectsPage(model:)`, `EffectCard`, `GenericParameterView(unit:)`, `PluginWindows.shared.open(slot:model:)`.

- [ ] **Step 1: Views**

`Sources/Equinox/EffectsViews.swift`:
```swift
import AppKit
import AVFoundation
import EquinoxCore
import EquinoxDSP
import SwiftUI

struct EffectsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.system(.title2, design: .rounded).weight(.bold))
                Spacer()
                addMenu
            }
            Text("Effects run after the EQ, in order from left to right. They're saved with the preset.")
                .font(.caption).foregroundStyle(.secondary)
            if model.working.effects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    Text("No effects yet").font(.headline)
                    Text("Add reverb, compression, a limiter, a delay, or any Audio Unit installed on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .glassCard()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(model.working.effects.enumerated()), id: \.element.id) { index, slot in
                            if index > 0 { Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 80) }
                            EffectCard(model: model, slot: slot, index: index, count: model.working.effects.count)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(24)
        .onAppear { model.refreshPlugins() }
    }

    private var addMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(BuiltInEffect.allCases, id: \.self) { e in
                    Button { model.addEffect(.builtIn(e)) } label: { Label(e.displayName, systemImage: e.symbol) }
                }
            }
            Section("Audio Units") {
                let byMaker = Dictionary(grouping: model.availablePlugins, by: \.manufacturerName)
                ForEach(byMaker.keys.sorted(), id: \.self) { maker in
                    Menu(maker) {
                        ForEach(byMaker[maker]!, id: \.self) { au in Button(au.name) { model.addEffect(.audioUnit(au)) } }
                    }
                }
            }
        } label: { Label("Add Effect", systemImage: "plus") }
        .menuStyle(.button).fixedSize()
    }
}

struct EffectCard: View {
    @Bindable var model: AppModel
    var slot: EffectSlot
    var index: Int
    var count: Int

    var body: some View {
        let crashed = model.isDisabledByCrash(slot)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(slot.isEnabled && !crashed ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.gray))
                    .frame(width: 30)
                Spacer()
                Toggle("", isOn: Binding(get: { slot.isEnabled }, set: { model.setEffectEnabled(slot.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.cyan).disabled(crashed)
            }
            Text(slot.kind.displayName).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if crashed {
                Text("Turned off after it crashed while loading.").font(.caption2).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                if case .audioUnit(let id) = slot.kind { Button("Turn Back On") { model.reenablePlugin(id.key) }.controlSize(.small) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { model.moveEffect(slot.id, by: -1) } label: { Image(systemName: "arrow.left") }.disabled(index == 0)
                Button { model.moveEffect(slot.id, by: 1) } label: { Image(systemName: "arrow.right") }.disabled(index == count - 1)
                Spacer()
                Button("Edit") { PluginWindows.shared.open(slot: slot, model: model) }.disabled(crashed)
                Button(role: .destructive) { PluginWindows.shared.close(slot.id); model.removeEffect(slot.id) } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
        .frame(width: 170, height: 170, alignment: .topLeading)
        .glassCard(cornerRadius: 18, padding: 14)
        .opacity(slot.isEnabled && !crashed ? 1 : 0.6)
    }

    private var icon: String {
        if case .builtIn(let e) = slot.kind { return e.symbol }
        return "puzzlepiece.extension"
    }

    private var subtitle: String {
        switch slot.kind {
        case .builtIn: "Built-in"
        case .audioUnit(let id): id.manufacturerName
        }
    }
}

/// Sliders for every parameter of a unit (used when a plugin has no custom view, and for built-ins).
struct GenericParameterView: View {
    let unit: AUAudioUnit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(unit.parameterTree?.allParameters ?? [], id: \.address) { p in ParameterRow(parameter: p) }
            }
            .padding(18)
        }
        .frame(minWidth: 380, minHeight: 200)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

private struct ParameterRow: View {
    let parameter: AUParameter
    @State private var value: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(display)
                    .font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { value = $0; parameter.setValue($0, originator: nil) }),
                   in: parameter.minValue...max(parameter.maxValue, parameter.minValue + 0.0001))
                .tint(Theme.cyan).controlSize(.small)
        }
        .foregroundStyle(.white)
        .onAppear { value = parameter.value }
    }

    private var display: String {
        var v = value
        return parameter.string(fromValue: &v) + (parameter.unitName.map { " \($0)" } ?? "")
    }
}

/// One window per open effect: the plugin's own UI when it has one, otherwise generic sliders.
@MainActor
final class PluginWindows {
    static let shared = PluginWindows()
    private var windows: [UUID: NSWindow] = [:]

    func open(slot: EffectSlot, model: AppModel) {
        if let w = windows[slot.id] { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        guard let unit = model.effectUnit(for: slot.id) else { NSSound.beep(); return }
        unit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                guard let self else { return }
                let content: NSViewController = controller ?? NSHostingController(rootView: GenericParameterView(unit: unit))
                let window = NSWindow(contentViewController: content)
                window.title = slot.kind.displayName
                window.styleMask.insert(.closable)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                self.windows[slot.id] = window
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windows[slot.id] = nil }
                }
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

    func close(_ id: UUID) { windows[id]?.close(); windows[id] = nil }
}
```

- [ ] **Step 2: Wire into the app**

`Sources/Equinox/MainWindow.swift`: add `case effects = "Effects"` between `mixer` and `settings`, its icon `"wand.and.stars"`, and `case .effects: EffectsPage(model: model)` in the detail switch.

`Sources/Equinox/EquinoxApp.swift` (`AppEnvironment.init`): replace `let model = AppModel(audio: AudioController())` with:
```swift
        let pluginGuard = PluginGuard(directory: Store.defaultDirectory)
        let crashed = pluginGuard.takeCrashedPlugin()
        let model = AppModel(audio: AudioController(pluginGuard: pluginGuard), crashedPlugin: crashed)
```

- [ ] **Step 3: Live checks and snapshots**

`Sources/Equinox/Diagnostics/SelfTest.swift`: insert `await effectsChecks(flat: flat)` after `await multiStripChecks(flat1: flat)`, and add:
```swift
    /// Built-in limiter (+6 dB pre-gain) in the live chain, live bypass without rebuild, an installed Audio Unit
    /// through the plugin path, and removal.
    private func effectsChecks(flat: Double) async {
        var limiter = EffectSlot(kind: .builtIn(.limiter))
        audio.setEffects([limiter])
        await sleep(0.8)
        guard let unit = audio.effectUnit(for: limiter.id) else { check("effects: limiter loads", false, "no unit"); return }
        unit.parameterTree?.parameter(withAddress: 2)?.value = 6
        let boosted = await measure(DSPSettings())
        check("effects: limiter +6 dB pre-gain in live chain", abs(boosted - flat - 6) < 0.5, "Δ \(fmt(boosted - flat)) dB")

        limiter.isEnabled = false
        audio.setEffects([limiter])
        let bypassed = await measure(DSPSettings())
        check("effects: live bypass (same engine)", abs(bypassed - flat) < 0.5 && audio.effectUnit(for: limiter.id) === unit,
              "Δ \(fmt(bypassed - flat)) dB")

        var masterOff = DSPSettings(); masterOff.isBypassed = true
        limiter.isEnabled = true
        audio.setEffects([limiter])
        let off = await measure(masterOff)
        check("effects: Equinox off skips effects", abs(off - flat) < 0.5, "Δ \(fmt(off - flat)) dB")

        if let bandpass = PluginCatalog.installedEffects().first(where: { $0.name.contains("AUBandpass") }) {
            audio.setEffects([EffectSlot(kind: .audioUnit(bandpass))])
            await sleep(0.8)
            let filtered = await measure(DSPSettings())
            check("effects: installed Audio Unit (AUBandpass) runs", filtered < flat - 6, "Δ \(fmt(filtered - flat)) dB")
        }

        // Rapid structural edits: only the newest chain may win.
        for kind in [BuiltInEffect.reverb, .delay, .compressor] { audio.setEffects([EffectSlot(kind: .builtIn(kind))]) }
        audio.setEffects([])
        await sleep(1.0)
        let cleared = await measure(DSPSettings())
        check("effects: rapid edits converge to the last (none)", abs(cleared - flat) < 0.5, "Δ \(fmt(cleared - flat)) dB")
    }
```
Also change the first tone to `seconds: 60`.

`Sources/Equinox/Diagnostics/Snapshots.swift`: after the mixer setup add
```swift
            _ = model.addEffect(.builtIn(.reverb))
            let comp = model.addEffect(.builtIn(.compressor))
            model.setEffectEnabled(comp, false)
            if let bp = PluginCatalog.installedEffects().first(where: { $0.name.contains("AUBandpass") }) {
                _ = model.addEffect(.audioUnit(bp))
            }
```
and add renders:
```swift
            save("effects", EffectsPage(model: model).frame(width: 900).background(bg), dir)
            save("effect-editor", GenericParameterView(unit: AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Reverb2,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)).auAudioUnit)
                .frame(width: 420, height: 520), dir)
```
(`import AVFoundation` at the top of Snapshots.swift.)

- [ ] **Step 4: Build, test, live run**

Run: `swift test 2>&1 | grep -cE "with [1-9][0-9]* failures"` → `0`.
Run: `scripts/self-test.sh <dir>` → all PASS (21 previous + 5 or 6 effects checks). Review `effects.png`, `effect-editor.png`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(app): effects page, plugin windows, effects self-test and snapshots"
```
