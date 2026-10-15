# Equinox Phase 2 (Per-App Mixer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-app volume (0–150%), mute, solo and per-app EQ preset, with a Mixer page and a compact mixer in the menu-bar popover.

**Architecture:** The tap session becomes multi-tap: one *rest* tap (global, excluding Equinox and every app with custom mixer settings) plus one muted stereo-mixdown tap per customized app ("dedicated strip"). The IOProc reads each tap stream, runs it through a `MixBus` strip (optional per-app EQ + ramped gain), sums into a mix bus, then the Phase 1 master chain. Strip configs are keyed by a stable string key and mapped to the session's tap order inside `DSPConfig`, so a pending rebuild can never apply one app's volume to another. Audio processes are grouped into apps by bundle-ID prefix (Chrome's helper → Chrome); CLI processes without a bundle ID are keyed `exe:<name>`.

**Tech Stack:** as Phase 1 (Swift 6 toolchain, Swift 5 mode, SwiftUI, CoreAudio process taps, vDSP, Synchronization, XCTest).

**Spec:** `docs/superpowers/specs/2026-10-15-equinox-design.md` (§3 Phase 2, §4.1–4.2)

## Global Constraints

- All Phase 1 Global Constraints still apply (macOS 15 target, no deps, realtime rules, 32 bands, boost 0…+12 dB, limiter −0.3 dBFS, persistence rules, bundle ID `com.pie.equinox`).
- Per-app volume range 0…1.5 (0–150%). Max dedicated app strips: 16 (`MixBus.maxStrips` = 17 including "Other apps").
- The "Other apps" strip key is `""` (`StripSettings.othersKey`). App keys: owning app bundle ID, else process bundle ID, else `exe:<executable name>`.
- An app is *dedicated* (gets its own tap) iff it is running and has non-default settings (volume ≠ 1, muted, preset ≠ nil) or is soloed. Solo is transient (not persisted).
- Only apps with dedicated taps get live meters; other apps show a "playing" indicator (from `kAudioProcessPropertyIsRunningOutput`).
- Equinox's own process is always excluded from every tap.

## Review Focus

1. **Strip/tap order mismatch during a pending rebuild** (user changes app A then app B quickly): volumes must never apply to the wrong app. Test in Task 1 (`testStripsMapByKeyNotPosition`) and Task 2 (`RendererTests.testMixesTapStreamsByStripOrder`).
2. **Multi-process apps** (Chrome/Safari helpers, apps whose helper appears after the tap was made): all of the app's audio processes go into its strip, and a new helper triggers a rebuild. Test in Task 3 (`testHelpersGroupUnderOwningApp`, `testNewHelperProcessUpdatesDedicatedStrip`).
3. **App quits while dedicated / has saved settings:** strip disappears without crashing; settings return when it relaunches. Test in Task 3 (`testAppMixPersistsAndReappliesOnRelaunch`).
4. **More than 16 customized apps:** extra ones stay in "Other apps" (no crash, no silent drop of audio). Test in Task 3 (`testDedicatedStripsAreCapped`).
5. **Deleting a preset used by an app strip:** strip falls back to no per-app EQ. Test in Task 3 (`testDeletingPresetClearsAppPreset`).

---

## File Structure

```
Sources/EquinoxDSP/
  DSPSettings.swift      + StripSettings, DSPSettings.strips, StripConfig, DSPConfig(stripOrder:)
  MixBus.swift           NEW per-strip EQ + ramped gain + summing
  StripMeters.swift      NEW lock-free per-strip peak meters
Sources/EquinoxAudio/
  AudioSystem.swift      + AudioProcessInfo, audioProcesses()
  TapSession.swift       multi-tap (rest + dedicated), stripKeys
  Renderer.swift         multi-strip render through MixBus, stripMeters
  AudioController.swift  DedicatedStrip, setDedicatedStrips, onProcessesChange, process polling, stripOrder
Sources/EquinoxCore/
  AppGrouping.swift      NEW processes → AudioAppGroup
  AppSettings.swift      + appMix (lossy)
  AppModel.swift         + mixer state/API, dedicated computation, strips in push()
Sources/Equinox/
  MixerViews.swift       NEW MixerMeters model, MixerPage, ChannelStripView, CompactMixer, AppIcon
  MainWindow.swift       + Mixer page
  MenuBarPanel.swift     + CompactMixer
  Diagnostics/SelfTest.swift   + per-app checks
  Diagnostics/Snapshots.swift  + preview processes, mixer snapshot
Tests/EquinoxDSPTests/MixBusTests.swift
Tests/EquinoxAudioTests/RendererTests.swift, AudioSystemTests.swift (+1)
Tests/EquinoxCoreTests/AppGroupingTests.swift, MixerModelTests.swift; AppModelTests.swift (FakeAudio additions)
```

---

### Task 1: DSP strips — settings, config mapping, MixBus, StripMeters

**Files:**
- Modify: `Sources/EquinoxDSP/DSPSettings.swift`
- Create: `Sources/EquinoxDSP/MixBus.swift`, `Sources/EquinoxDSP/StripMeters.swift`
- Test: `Tests/EquinoxDSPTests/MixBusTests.swift`

**Interfaces:**
- Produces:
  - `StripSettings(key:volume:isMuted:preampDB:bands:)` (Codable, Equatable, Sendable), `StripSettings.othersKey = ""`, `StripSettings.maxVolume = 1.5`
  - `DSPSettings.strips: [StripSettings]` (default `[]`)
  - `StripConfig` (`gain: Float`, `eqCoefficients: [Double]?`), `StripConfig.unity`
  - `DSPConfig(settings:sampleRate:stripOrder:)` with `stripOrder: [String] = [StripSettings.othersKey]`; `DSPConfig.strips: [StripConfig]` (one per `stripOrder` entry; missing key → `.unity`)
  - `MixBus(stripCount:maxFrames:)`, `MixBus.maxStrips = 17`, `.stripCount`, `apply(_ strips: [StripConfig])`, `accumulate(strip:left:right:intoLeft:intoRight:frames:)`
  - `StripMeters()`, `StripMeters.capacity = 17`, `record(strip:left:right:frames:)`, `take(strip:) -> Float`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxDSPTests/MixBusTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

final class MixBusTests: XCTestCase {
    let fs = 48_000.0

    func testStripsMapByKeyNotPosition() {
        var s = DSPSettings()
        s.strips = [StripSettings(key: "b", volume: 0.25), StripSettings(key: "a", volume: 0.5)]
        let cfg = DSPConfig(settings: s, sampleRate: fs, stripOrder: ["", "a", "b", "missing"])
        XCTAssertEqual(cfg.strips.map(\.gain), [1, 0.5, 0.25, 1])
    }

    func testStripGainClampsMutesAndAppliesPreamp() {
        var s = DSPSettings()
        s.strips = [StripSettings(key: "a", volume: 9), StripSettings(key: "m", volume: 1, isMuted: true),
                    StripSettings(key: "p", volume: 1, preampDB: -6.0206, bands: [EQBand(frequency: 1000)])]
        let cfg = DSPConfig(settings: s, sampleRate: fs, stripOrder: ["a", "m", "p"])
        XCTAssertEqual(cfg.strips[0].gain, 1.5, accuracy: 1e-6)
        XCTAssertEqual(cfg.strips[1].gain, 0)
        XCTAssertEqual(cfg.strips[2].gain, 0.5, accuracy: 1e-4)
        XCTAssertNil(cfg.strips[0].eqCoefficients)
    }

    func testStripWithBandsGetsCoefficients() {
        var s = DSPSettings()
        s.strips = [StripSettings(key: "a", bands: [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)])]
        let cfg = DSPConfig(settings: s, sampleRate: fs, stripOrder: ["a"])
        XCTAssertEqual(cfg.strips[0].eqCoefficients?.count, BiquadBank.maxSections * 2 * 5)
    }

    func run(_ bus: MixBus, _ inputs: [[Float]], frames: Int) -> [Float] {
        var mixL = [Float](repeating: 0, count: frames), mixR = mixL
        for (i, x) in inputs.enumerated() {
            var l = x, r = x
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                mixL.withUnsafeMutableBufferPointer { ml in mixR.withUnsafeMutableBufferPointer { mr in
                    bus.accumulate(strip: i, left: lp.baseAddress!, right: rp.baseAddress!,
                                   intoLeft: ml.baseAddress!, intoRight: mr.baseAddress!, frames: frames)
                } }
            } }
        }
        return mixL
    }

    func testUnconfiguredBusSumsAtUnity() {
        let bus = MixBus(stripCount: 2, maxFrames: 512)
        let out = run(bus, [[Float](repeating: 0.25, count: 64), [Float](repeating: 0.5, count: 64)], frames: 64)
        XCTAssertEqual(out[63], 0.75, accuracy: 1e-6)
    }

    func testAppliesPerStripGains() {
        let bus = MixBus(stripCount: 2, maxFrames: 512)
        bus.apply([StripConfig(gain: 0.5, eqCoefficients: nil), StripConfig(gain: 0, eqCoefficients: nil)])
        let out = run(bus, [[Float](repeating: 0.4, count: 64), [Float](repeating: 0.9, count: 64)], frames: 64)
        XCTAssertEqual(out[0], 0.2, accuracy: 1e-6)   // first config applies immediately
        XCTAssertEqual(out[63], 0.2, accuracy: 1e-6)
    }

    func testLaterGainChangesRampAcrossTheBlock() {
        let bus = MixBus(stripCount: 1, maxFrames: 512)
        bus.apply([StripConfig(gain: 1, eqCoefficients: nil)])
        bus.apply([StripConfig(gain: 0, eqCoefficients: nil)])
        let out = run(bus, [[Float](repeating: 1, count: 100)], frames: 100)
        XCTAssertEqual(out[0], 1, accuracy: 1e-6)
        XCTAssertLessThan(out[99], 0.02)
        XCTAssertTrue(zip(out, out.dropFirst()).allSatisfy { $0 >= $1 })
    }

    func testPerStripEQBoostsOnlyThatStrip() {
        let bus = MixBus(stripCount: 2, maxFrames: 4096)
        var s = DSPSettings()
        s.strips = [StripSettings(key: "a", bands: [EQBand(type: .peak, frequency: 1000, gainDB: 12, q: 1)])]
        bus.apply(DSPConfig(settings: s, sampleRate: fs, stripOrder: ["a", "b"]).strips)
        let x = Signal.sine(1000, fs: fs, count: 4096)
        let zero = [Float](repeating: 0, count: 4096)
        let boosted = run(bus, [x, zero], frames: 4096)
        let gain = 20 * log10(Signal.rms(boosted[2048...]) / Signal.rms(x[2048...]))
        XCTAssertEqual(Double(gain), 12, accuracy: 0.2)
        let other = run(bus, [zero, x], frames: 4096)
        XCTAssertEqual(Signal.rms(other[2048...]), Signal.rms(x[2048...]), accuracy: 1e-4)
    }

    func testExtraConfigsIgnoredAndMissingOnesUnity() {
        let bus = MixBus(stripCount: 2, maxFrames: 512)
        bus.apply([StripConfig(gain: 0.5, eqCoefficients: nil)])   // fewer configs than strips
        let out = run(bus, [[Float](repeating: 0.4, count: 8), [Float](repeating: 0.4, count: 8)], frames: 8)
        XCTAssertEqual(out[7], 0.6, accuracy: 1e-6)
        bus.apply(Array(repeating: StripConfig.unity, count: 30))   // more configs than strips: no crash
    }

    func testStripMetersTakeAndReset() {
        let meters = StripMeters()
        var l: [Float] = [0.1, -0.7], r: [Float] = [0.2, 0.3]
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            meters.record(strip: 3, left: lp.baseAddress!, right: rp.baseAddress!, frames: 2)
        } }
        XCTAssertEqual(meters.take(strip: 3), 0.7, accuracy: 1e-6)
        XCTAssertEqual(meters.take(strip: 3), 0)
        XCTAssertEqual(meters.take(strip: 99), 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MixBusTests`
Expected: compile failure — `cannot find 'StripSettings' in scope`.

- [ ] **Step 3: Implement**

Modify `Sources/EquinoxDSP/DSPSettings.swift`. Add after `public var isMuted = false` inside `DSPSettings`:
```swift
    /// Per-app strips (Phase 2). Mapped to the session's tap order by key.
    public var strips: [StripSettings] = []
```
Add these types at the end of the file:
```swift
public struct StripSettings: Codable, Equatable, Sendable {
    public static let othersKey = ""
    public static let maxVolume = 1.5

    public var key: String
    public var volume: Double
    public var isMuted: Bool
    public var preampDB: Double
    /// Empty = no per-app EQ.
    public var bands: [EQBand]

    public init(key: String, volume: Double = 1, isMuted: Bool = false, preampDB: Double = 0, bands: [EQBand] = []) {
        self.key = key; self.volume = volume; self.isMuted = isMuted; self.preampDB = preampDB; self.bands = bands
    }
}

public struct StripConfig: Sendable {
    public static let unity = StripConfig(gain: 1, eqCoefficients: nil)
    public let gain: Float
    /// nil = no per-app EQ (strip EQ is skipped).
    public let eqCoefficients: [Double]?

    public init(gain: Float, eqCoefficients: [Double]?) { self.gain = gain; self.eqCoefficients = eqCoefficients }

    init(settings s: StripSettings, sampleRate: Double) {
        let volume = min(max(s.volume.isFinite ? s.volume : 1, 0), StripSettings.maxVolume)
        let preamp = s.bands.isEmpty ? 1 : Decibels.toLinear(min(max(s.preampDB.isFinite ? s.preampDB : 0, -24), 24))
        gain = s.isMuted ? 0 : Float(volume * preamp)
        let sections = s.bands.lazy.filter(\.isEnabled).prefix(BiquadBank.maxSections)
            .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        eqCoefficients = s.bands.isEmpty ? nil : BiquadBank.flatten(Array(sections))
    }
}
```
In `DSPConfig`, add the stored property and change the initializer signature and add strip mapping:
```swift
    public let strips: [StripConfig]

    public init(settings s: DSPSettings, sampleRate: Double, stripOrder: [String] = [StripSettings.othersKey]) {
```
and at the end of that initializer body:
```swift
        strips = stripOrder.map { key in
            s.strips.first { $0.key == key }.map { StripConfig(settings: $0, sampleRate: sampleRate) } ?? .unity
        }
```

`Sources/EquinoxDSP/MixBus.swift`:
```swift
import Accelerate

/// Per-strip processing before the master chain: optional per-app EQ, ramped gain, then summed into the mix bus.
/// A bus is built for a fixed strip count (one per tap); configs map positionally onto it.
public final class MixBus {
    public static let maxStrips = 17

    public let stripCount: Int
    public let maxFrames: Int
    private let banks: [BiquadBank]
    private var eqActive: [Bool]
    private var current: [Float]
    private var target: [Float]
    private var hasConfig = false

    public init(stripCount: Int, maxFrames: Int) {
        self.stripCount = max(1, min(stripCount, Self.maxStrips))
        self.maxFrames = maxFrames
        banks = (0..<self.stripCount).map { _ in BiquadBank(maxFrames: maxFrames) }
        eqActive = Array(repeating: false, count: self.stripCount)
        current = Array(repeating: 1, count: self.stripCount)
        target = Array(repeating: 1, count: self.stripCount)
    }

    /// Realtime-safe. Extra configs are ignored; strips without a config play at unity.
    public func apply(_ strips: [StripConfig]) {
        for i in 0..<stripCount {
            let cfg = i < strips.count ? strips[i] : .unity
            target[i] = cfg.gain
            if !hasConfig { current[i] = cfg.gain }
            if let eq = cfg.eqCoefficients {
                banks[i].setCoefficients(eq, ramp: eqActive[i])
                eqActive[i] = true
            } else if eqActive[i] {
                eqActive[i] = false
                banks[i].reset()
            }
        }
        hasConfig = true
    }

    /// Realtime-safe. Processes strip `strip` in place, then adds it into the mix. `frames <= maxFrames`.
    public func accumulate(strip: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                           intoLeft mixL: UnsafeMutablePointer<Float>, intoRight mixR: UnsafeMutablePointer<Float>,
                           frames: Int) {
        guard strip < stripCount, frames > 0 else { return }
        if eqActive[strip] { banks[strip].process(left: left, right: right, frames: frames) }
        let n = vDSP_Length(frames)
        if current[strip] == target[strip] {
            var g = target[strip]
            if g != 1 { vDSP_vsmul(left, 1, &g, left, 1, n); vDSP_vsmul(right, 1, &g, right, 1, n) }
        } else {
            var step = (target[strip] - current[strip]) / Float(frames)
            var startL = current[strip], startR = current[strip]
            vDSP_vrampmul(left, 1, &startL, &step, left, 1, n)
            vDSP_vrampmul(right, 1, &startR, &step, right, 1, n)
            current[strip] = target[strip]
        }
        vDSP_vadd(left, 1, mixL, 1, mixL, 1, n)
        vDSP_vadd(right, 1, mixR, 1, mixR, 1, n)
    }
}
```

`Sources/EquinoxDSP/StripMeters.swift`:
```swift
import Accelerate
import Synchronization

/// Lock-free per-strip peak meters (written by the audio thread, taken by the UI).
public final class StripMeters: @unchecked Sendable {
    public static let capacity = MixBus.maxStrips

    private final class Slot { let bits = Atomic<UInt32>(0) }
    private let slots: [Slot] = (0..<StripMeters.capacity).map { _ in Slot() }

    public init() {}

    /// Realtime-safe.
    public func record(strip: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard strip >= 0, strip < Self.capacity, frames > 0 else { return }
        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(left, 1, &pl, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &pr, vDSP_Length(frames))
        let peak = max(pl, pr)
        guard peak.isFinite else { return }
        let slot = slots[strip]
        var current = slot.bits.load(ordering: .relaxed)
        while peak.bitPattern > current {
            let (done, original) = slot.bits.compareExchange(expected: current, desired: peak.bitPattern, ordering: .relaxed)
            if done { break }
            current = original
        }
    }

    public func take(strip: Int) -> Float {
        guard strip >= 0, strip < Self.capacity else { return 0 }
        return Float(bitPattern: slots[strip].bits.exchange(0, ordering: .relaxed))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MixBusTests` → 9 tests PASS. Then `swift test --filter EquinoxDSPTests` → all PASS (existing tests use the defaulted `stripOrder`).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(dsp): per-app strips — keyed strip config, MixBus, strip meters"
```

---

### Task 2: Audio layer — processes, multi-tap session, multi-strip renderer, controller

**Files:**
- Modify: `Sources/EquinoxAudio/AudioSystem.swift`, `Sources/EquinoxAudio/TapSession.swift`, `Sources/EquinoxAudio/Renderer.swift`, `Sources/EquinoxAudio/AudioController.swift`
- Test: `Tests/EquinoxAudioTests/RendererTests.swift`, `Tests/EquinoxAudioTests/AudioSystemTests.swift` (add one test)

**Interfaces:**
- Consumes: `MixBus`, `StripMeters`, `StripConfig`, `DSPConfig(settings:sampleRate:stripOrder:)`.
- Produces:
  - `AudioProcessInfo(objectID:pid:bundleID:executableName:isRunningOutput:)` (Hashable, Sendable); `AudioSystem.audioProcesses() -> [AudioProcessInfo]`
  - `DedicatedStrip(key: String, processes: [AudioObjectID])` (Hashable, Sendable)
  - `TapSession(outputDeviceID:excludedProcesses:dedicated:renderer:) throws`, `.stripKeys: [String]` (`[""] + dedicated keys`)
  - `Renderer.prepare(sampleRate:inputStreamOffset:stripCount:)`, `Renderer.stripMeters: StripMeters`
  - `AudioControlling` additions: `onProcessesChange: (([AudioProcessInfo]) -> Void)?`, `audioProcesses() -> [AudioProcessInfo]`, `setDedicatedStrips(_ strips: [DedicatedStrip])`, `stripMeters: StripMeters`, `activeStripKeys: [String]`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxAudioTests/RendererTests.swift`:
```swift
import XCTest
import CoreAudio
@testable import EquinoxAudio
import EquinoxDSP

final class RendererTests: XCTestCase {
    func makeList(_ channels: [Int], frames: Int, fills: [Float]) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (i, ch) in channels.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: ch * frames)
            p.initialize(repeating: fills[i], count: ch * frames)
            list[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(ch * frames * 4), mData: p)
        }
        return list
    }

    func testMixesTapStreamsByStripOrder() {
        let renderer = Renderer()
        renderer.prepare(sampleRate: 48_000, inputStreamOffset: 1, stripCount: 2)
        var s = DSPSettings()
        s.strips = [StripSettings(key: "app", volume: 0.5), StripSettings(key: "", volume: 1, isMuted: false)]
        renderer.submit(DSPConfig(settings: s, sampleRate: 48_000, stripOrder: ["", "app"]))
        // buffer 0 = output device's own input (must be ignored), 1 = rest tap, 2 = app tap
        let input = makeList([2, 2, 2], frames: 64, fills: [9, 0.3, 0.4])
        let output = makeList([2], frames: 64, fills: [0])
        renderer.render(input: UnsafePointer(input.unsafeMutablePointer), output: output.unsafeMutablePointer)
        let out = output[0].mData!.assumingMemoryBound(to: Float.self)
        XCTAssertEqual(out[126], 0.3 + 0.4 * 0.5, accuracy: 1e-5)
        XCTAssertGreaterThan(renderer.stripMeters.take(strip: 1), 0.19)
    }
}
```

Add to `Tests/EquinoxAudioTests/AudioSystemTests.swift` (inside the class):
```swift
    func testListsOwnAudioProcess() {
        _ = AudioSystem.outputDevices()
        let own = AudioSystem.audioProcesses().first { $0.pid == getpid() }
        XCTAssertNotNil(own)
        XCTAssertFalse(own!.executableName.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EquinoxAudioTests`
Expected: compile failure — `extra argument 'stripCount' in call` / `cannot find 'AudioSystem.audioProcesses'`.

- [ ] **Step 3: Implement processes**

Append to `Sources/EquinoxAudio/AudioSystem.swift` (before `/// Core Audio property listener`):
```swift
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
```

- [ ] **Step 4: Implement multi-strip Renderer**

In `Sources/EquinoxAudio/Renderer.swift`, inside `Renderer`:
- Replace `public static let maxFrames = 4096` with:
```swift
    public static let maxFrames = 4096
    static let capacity = maxFrames * 4
```
- Add stored properties after `public let analysis = AnalysisTap()`:
```swift
    public let stripMeters = StripMeters()
    private var mixBus = MixBus(stripCount: 1, maxFrames: Renderer.capacity)
    private var stripCount = 1
    private let mixL = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.capacity)
    private let mixR = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.capacity)
```
- Replace every `Renderer.maxFrames * 4` with `Renderer.capacity`; in `init` also `mixL.initialize(repeating: 0, count: Renderer.capacity)` and same for `mixR`; in `deinit` also deallocate `mixL`, `mixR`.
- Replace `prepare`:
```swift
    /// Main thread, only while the IOProc is stopped.
    func prepare(sampleRate: Double, inputStreamOffset: Int, stripCount: Int = 1) {
        processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: sampleRate)
        mixBus = MixBus(stripCount: stripCount, maxFrames: Renderer.capacity)
        self.stripCount = mixBus.stripCount
        current = nil
        mailbox.reset()
        self.inputStreamOffset = inputStreamOffset
    }
```
- Replace the body of `render` after the `guard frames > 0` line with:
```swift
        if let entry = mailbox.take() {
            current = entry                 // previous entry is still owned by the mailbox history
            mailbox.acknowledge(entry)
            processor.apply(entry.config)
            mixBus.apply(entry.config.strips)
        }
        mixL.update(repeating: 0, count: frames)
        mixR.update(repeating: 0, count: frames)
        for strip in 0..<stripCount {
            ChannelIO.readStereo(from: inp, bufferIndex: inputStreamOffset + strip, frames: frames, left: left, right: right)
            mixBus.accumulate(strip: strip, left: left, right: right, intoLeft: mixL, intoRight: mixR, frames: frames)
            stripMeters.record(strip: strip, left: left, right: right, frames: frames)
        }
        if current != nil { processor.process(left: mixL, right: mixR, frames: frames) }
        analysis.write(left: mixL, right: mixR, frames: frames)
        ChannelIO.writeStereo(left: mixL, right: mixR, frames: frames, to: out)
```

- [ ] **Step 5: Implement multi-tap TapSession**

In `Sources/EquinoxAudio/TapSession.swift`:
- Add above `public final class TapSession`:
```swift
/// An app that gets its own tap (and mixer strip).
public struct DedicatedStrip: Hashable, Sendable {
    public let key: String
    public let processes: [AudioObjectID]
    public init(key: String, processes: [AudioObjectID]) { self.key = key; self.processes = processes }
}
```
- Add properties: `public let stripKeys: [String]` and `private var tapIDs: [AudioObjectID] = []` (replace `tapID`).
- Change the initializer signature to `public init(outputDeviceID: AudioObjectID, excludedProcesses: [AudioObjectID], dedicated: [DedicatedStrip] = [], renderer: Renderer) throws` and, as its first lines (before `do {`):
```swift
        let strips = Array(dedicated.filter { !$0.processes.isEmpty }.prefix(MixBus.maxStrips - 1))
        stripKeys = [StripSettings.othersKey] + strips.map(\.key)
```
- Replace the tap creation (from `let description = CATapDescription(...)` through `try check(AudioHardwareCreateProcessTap(...))`) with:
```swift
            // Rest tap: everything except Equinox and the dedicated apps. Then one tap per dedicated app.
            let rest = CATapDescription(stereoGlobalTapButExcludeProcesses: exclusions + strips.flatMap(\.processes))
            var descriptions = [rest]
            descriptions += strips.map { CATapDescription(stereoMixdownOfProcesses: $0.processes) }
            for (i, d) in descriptions.enumerated() {
                d.uuid = UUID()
                d.name = i == 0 ? "Equinox" : "Equinox \(stripKeys[i])"
                d.isPrivate = true
                d.muteBehavior = .mutedWhenTapped
                var id = AudioObjectID(kAudioObjectUnknown)
                try check(AudioHardwareCreateProcessTap(d, &id), "Create audio tap \(i)")
                tapIDs.append(id)
            }
```
- In the aggregate dictionary replace the tap list entry with:
```swift
                kAudioAggregateDeviceTapListKey: descriptions.map {
                    [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]
                },
```
- Replace `renderer.prepare(sampleRate: sampleRate, inputStreamOffset: offset)` with `renderer.prepare(sampleRate: sampleRate, inputStreamOffset: offset, stripCount: stripKeys.count)`.
- Replace `try? restrictInputToTap(deviceInputStreams: offset)` with `try? restrictInputToTap(deviceInputStreams: offset, tapStreams: stripKeys.count)`, and in `restrictInputToTap` change the signature to `(deviceInputStreams: Int, tapStreams: Int)` and use `tapStreams:` in the `inputStreamUsage` call.
- In `invalidate()` replace the single-tap destroy with:
```swift
        for id in tapIDs { AudioHardwareDestroyProcessTap(id) }
        tapIDs.removeAll()
```
- Add `import EquinoxDSP` at the top (for `MixBus`, `StripSettings`).

- [ ] **Step 6: Implement controller changes**

In `Sources/EquinoxAudio/AudioController.swift`:
- Add to `AudioControlling`:
```swift
    var onProcessesChange: (([AudioProcessInfo]) -> Void)? { get set }
    var stripMeters: StripMeters { get }
    /// Strip keys of the running session, in meter/tap order.
    var activeStripKeys: [String] { get }
    func audioProcesses() -> [AudioProcessInfo]
    /// Apps that need their own tap. Changing the set rebuilds the session (debounced).
    func setDedicatedStrips(_ strips: [DedicatedStrip])
```
- In `AudioController` add:
```swift
    public var onProcessesChange: (([AudioProcessInfo]) -> Void)?
    public var stripMeters: StripMeters { renderer.stripMeters }
    public var activeStripKeys: [String] { session?.stripKeys ?? [] }
    private var dedicated: [DedicatedStrip] = []
    private var processSnapshot: [AudioProcessInfo] = []
    private var processPoll: Timer?

    public func audioProcesses() -> [AudioProcessInfo] { AudioSystem.audioProcesses() }

    public func setDedicatedStrips(_ strips: [DedicatedStrip]) {
        guard strips != dedicated else { return }
        dedicated = strips
        if session != nil { scheduleRebuild() }
    }

    private func pollProcesses() {
        let now = AudioSystem.audioProcesses()
        guard now != processSnapshot else { return }
        processSnapshot = now
        onProcessesChange?(now)
    }
```
- In `start()`, add to the `systemListeners` array:
```swift
                try? PropertyListener(object: .system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                    MainActor.assumeIsolated { self?.pollProcesses() }
                },
```
  and after `startWatchdog()`:
```swift
        pollProcesses()
        processPoll?.invalidate()
        processPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollProcesses() }
        }
```
- In `stop()` add `processPoll?.invalidate(); processPoll = nil`.
- In `apply(_:)` replace the submit with `renderer.submit(DSPConfig(settings: settings, sampleRate: session.sampleRate, stripOrder: session.stripKeys))`.
- In `rebuild()` change session creation and first submit to:
```swift
            let newSession = try TapSession(outputDeviceID: deviceID, excludedProcesses: [ownProcess],
                                            dedicated: dedicated, renderer: renderer)
            renderer.submit(DSPConfig(settings: settings, sampleRate: newSession.sampleRate, stripOrder: newSession.stripKeys))
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter EquinoxAudioTests` → all PASS (RendererTests 1, AudioSystemTests 4, plus existing). Then `swift build` must fail only in `Tests/EquinoxCoreTests` FakeAudio / `Sources/Equinox` PreviewAudio conformance — fix both by adding the five new members:
```swift
    var onProcessesChange: (([AudioProcessInfo]) -> Void)?
    let stripMeters = StripMeters()
    var activeStripKeys: [String] = [""]
    var processes: [AudioProcessInfo] = []
    var dedicated: [DedicatedStrip] = []
    func audioProcesses() -> [AudioProcessInfo] { processes }
    func setDedicatedStrips(_ strips: [DedicatedStrip]) { dedicated = strips }
```
(In `PreviewAudio` the same, with `processes` left empty for now.) Run `swift test` → all PASS.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(audio): multi-tap session with per-app strips, process discovery, strip meters"
```

---

### Task 3: App grouping, mixer settings, AppModel mixer API

**Files:**
- Create: `Sources/EquinoxCore/AppGrouping.swift`
- Modify: `Sources/EquinoxCore/AppSettings.swift`, `Sources/EquinoxCore/AppModel.swift`
- Test: `Tests/EquinoxCoreTests/AppGroupingTests.swift`, `Tests/EquinoxCoreTests/MixerModelTests.swift`

**Interfaces:**
- Consumes: `AudioProcessInfo`, `DedicatedStrip`, `StripSettings`, `AudioControlling` (Task 2).
- Produces:
  - `RunningAppInfo(bundleID:name:)`, `RunningAppsProviding` (`runningApps() -> [RunningAppInfo]`), `WorkspaceRunningApps`
  - `AudioAppGroup(key:name:bundleID:processObjects:isPlaying:)`, `AppGrouping.group(_:runningApps:excludingBundleIDs:excludingPIDs:) -> [AudioAppGroup]`
  - `AppMixSettings(volume:isMuted:presetID:)` with `isDefault`; `AppSettings.appMix: [String: AppMixSettings]`
  - `MixerStrip` (`id`, `name`, `bundleID`, `isOthers`, `isPlaying`, `isDedicated`, `volume`, `isMuted`, `isSoloed`, `presetID`)
  - `AppModel`: `mixerStrips`, `soloKey`, `setStripVolume(_:for:)`, `setStripMuted(_:for:)`, `toggleSolo(_:)`, `setStripPreset(_:for:)`, `resetStrip(_:)`, `stripMeters`, `activeStripKeys`; init gains `runningApps: RunningAppsProviding = WorkspaceRunningApps()`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxCoreTests/AppGroupingTests.swift`:
```swift
import XCTest
import EquinoxAudio
@testable import EquinoxCore

final class AppGroupingTests: XCTestCase {
    let apps = [RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome"),
                RunningAppInfo(bundleID: "com.spotify.client", name: "Spotify")]

    func p(_ id: AudioObjectID, _ bundle: String, _ exe: String = "x", playing: Bool = false, pid: pid_t = 100) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: pid + pid_t(id), bundleID: bundle, executableName: exe, isRunningOutput: playing)
    }

    func testHelpersGroupUnderOwningApp() {
        let groups = AppGrouping.group([p(1, "com.google.Chrome"), p(2, "com.google.Chrome.helper", playing: true)],
                                       runningApps: apps, excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, "com.google.Chrome")
        XCTAssertEqual(groups[0].name, "Google Chrome")
        XCTAssertEqual(Set(groups[0].processObjects), [1, 2])
        XCTAssertTrue(groups[0].isPlaying)
    }

    func testPrefixMustEndAtDotBoundary() {
        let groups = AppGrouping.group([p(1, "com.google.Chromecast")], runningApps: apps,
                                       excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups[0].key, "com.google.Chromecast")
        XCTAssertEqual(groups[0].name, "Chromecast")
    }

    func testProcessesWithoutBundleIDUseExecutableName() {
        let groups = AppGrouping.group([p(1, "", "afplay")], runningApps: apps, excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups[0].key, "exe:afplay")
        XCTAssertEqual(groups[0].name, "afplay")
        XCTAssertNil(groups[0].bundleID)
    }

    func testExclusionsAndSorting() {
        let groups = AppGrouping.group([p(1, "com.spotify.client"), p(2, "com.pie.equinox"), p(3, "com.google.Chrome"),
                                        p(4, "", "self", pid: 5000)],
                                       runningApps: apps, excludingBundleIDs: ["com.pie.equinox"], excludingPIDs: [5004])
        XCTAssertEqual(groups.map(\.name), ["Google Chrome", "Spotify"])
    }
}
```

`Tests/EquinoxCoreTests/MixerModelTests.swift`:
```swift
import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

final class FakeRunningApps: RunningAppsProviding {
    func runningApps() -> [RunningAppInfo] {
        [RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome"),
         RunningAppInfo(bundleID: "com.spotify.client", name: "Spotify")]
    }
}

@MainActor
final class MixerModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-mixer-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    let chrome = [AudioProcessInfo(objectID: 11, pid: 11, bundleID: "com.google.Chrome", executableName: "Chrome", isRunningOutput: false),
                  AudioProcessInfo(objectID: 12, pid: 12, bundleID: "com.google.Chrome.helper", executableName: "Helper", isRunningOutput: true)]
    let spotify = AudioProcessInfo(objectID: 21, pid: 21, bundleID: "com.spotify.client", executableName: "Spotify", isRunningOutput: true)

    func makeModel() -> AppModel {
        let m = AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem(), runningApps: FakeRunningApps())
        audio.onProcessesChange?(chrome + [spotify])
        return m
    }

    func strip(_ key: String) -> StripSettings? { audio.applied.last?.strips.first { $0.key == key } }

    func testStripsListOthersFirstThenApps() {
        let m = makeModel()
        XCTAssertEqual(m.mixerStrips.map(\.name), ["Other Apps", "Google Chrome", "Spotify"])
        XCTAssertTrue(m.mixerStrips[0].isOthers)
        XCTAssertTrue(audio.dedicated.isEmpty)
    }

    func testChangingAppVolumeDedicatesItWithAllProcesses() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        XCTAssertEqual(audio.dedicated, [DedicatedStrip(key: "com.google.Chrome", processes: [11, 12])])
        XCTAssertEqual(strip("com.google.Chrome")?.volume, 0.5)
        XCTAssertTrue(m.mixerStrips.first { $0.id == "com.google.Chrome" }!.isDedicated)
    }

    func testResettingAppRemovesDedication() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        m.resetStrip("com.google.Chrome")
        XCTAssertTrue(audio.dedicated.isEmpty)
        XCTAssertNil(strip("com.google.Chrome"))
    }

    func testOthersStripVolumeDoesNotDedicate() {
        let m = makeModel()
        m.setStripVolume(0.3, for: StripSettings.othersKey)
        XCTAssertTrue(audio.dedicated.isEmpty)
        XCTAssertEqual(strip("")?.volume, 0.3)
    }

    func testSoloMutesEverythingElse() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        m.toggleSolo("com.spotify.client")
        XCTAssertEqual(Set(audio.dedicated.map(\.key)), ["com.google.Chrome", "com.spotify.client"])
        XCTAssertEqual(strip("")?.isMuted, true)
        XCTAssertEqual(strip("com.google.Chrome")?.isMuted, true)
        XCTAssertEqual(strip("com.spotify.client")?.isMuted, false)
        m.toggleSolo("com.spotify.client")
        XCTAssertNil(m.soloKey)
        XCTAssertEqual(audio.dedicated.map(\.key), ["com.google.Chrome"])
    }

    func testAppPresetResolvesBandsAndPreamp() {
        let m = makeModel()
        let bass = Preset.builtIns[1]
        m.setStripPreset(bass.id, for: "com.spotify.client")
        XCTAssertEqual(strip("com.spotify.client")?.bands, bass.bands)
        XCTAssertEqual(strip("com.spotify.client")?.preampDB, bass.preampDB)
    }

    func testDeletingPresetClearsAppPreset() {
        let m = makeModel()
        m.saveAs(name: "Mine")
        let mine = m.selectedPresetID
        m.setStripPreset(mine, for: "com.spotify.client")
        m.deletePreset(mine)
        XCTAssertNil(m.mixerStrips.first { $0.id == "com.spotify.client" }!.presetID)
        XCTAssertTrue(audio.dedicated.isEmpty)
    }

    func testNewHelperProcessUpdatesDedicatedStrip() {
        let m = makeModel()
        m.setStripMuted(true, for: "com.google.Chrome")
        let helper2 = AudioProcessInfo(objectID: 13, pid: 13, bundleID: "com.google.Chrome.helper", executableName: "Helper", isRunningOutput: true)
        audio.onProcessesChange?(chrome + [helper2, spotify])
        XCTAssertEqual(audio.dedicated.first?.processes, [11, 12, 13])
    }

    func testAppMixPersistsAndReappliesOnRelaunch() {
        let m = makeModel()
        m.setStripVolume(1.25, for: "com.spotify.client")
        audio.onProcessesChange?(chrome)              // Spotify quits
        XCTAssertTrue(audio.dedicated.isEmpty)
        XCTAssertNil(m.mixerStrips.first { $0.id == "com.spotify.client" })
        m.flushSave()
        let m2 = makeModel()                           // relaunch; Spotify running again
        XCTAssertEqual(m2.mixerStrips.first { $0.id == "com.spotify.client" }?.volume, 1.25)
        XCTAssertEqual(audio.dedicated.map(\.key), ["com.spotify.client"])
    }

    func testDedicatedStripsAreCapped() {
        let m = makeModel()
        let many = (0..<20).map { AudioProcessInfo(objectID: AudioObjectID(100 + $0), pid: pid_t(100 + $0), bundleID: "",
                                                   executableName: "tool\($0)", isRunningOutput: true) }
        audio.onProcessesChange?(many)
        for i in 0..<20 { m.setStripMuted(true, for: "exe:tool\(i)") }
        XCTAssertEqual(audio.dedicated.count, MixBus.maxStrips - 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "AppGroupingTests|MixerModelTests"`
Expected: compile failure — `cannot find 'RunningAppInfo' in scope`.

- [ ] **Step 3: Implement grouping**

`Sources/EquinoxCore/AppGrouping.swift`:
```swift
import AppKit
import EquinoxAudio

public struct RunningAppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public protocol RunningAppsProviding: AnyObject {
    func runningApps() -> [RunningAppInfo]
}

public final class WorkspaceRunningApps: RunningAppsProviding {
    public init() {}
    public func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: id, name: app.localizedName ?? id)
        }
    }
}

public struct AudioAppGroup: Equatable, Sendable {
    public let key: String
    public let name: String
    /// Bundle ID used for the icon; nil for command-line processes.
    public let bundleID: String?
    public let processObjects: [AudioObjectID]
    public let isPlaying: Bool
}

public enum AppGrouping {
    /// Groups audio processes into apps. Helpers whose bundle ID extends a running app's bundle ID
    /// (at a dot boundary) belong to that app; processes without a bundle ID are keyed by executable.
    public static func group(_ processes: [AudioProcessInfo], runningApps: [RunningAppInfo],
                             excludingBundleIDs: Set<String>, excludingPIDs: Set<pid_t>) -> [AudioAppGroup] {
        var order: [String] = []
        var members: [String: (name: String, bundleID: String?, objects: [AudioObjectID], playing: Bool)] = [:]
        for p in processes where !excludingPIDs.contains(p.pid) {
            let owner = owningApp(p.bundleID, runningApps)
            let key: String, name: String, bundleID: String?
            if let owner {
                key = owner.bundleID; name = owner.name; bundleID = owner.bundleID
            } else if !p.bundleID.isEmpty {
                key = p.bundleID; name = p.bundleID.split(separator: ".").last.map(String.init) ?? p.bundleID; bundleID = p.bundleID
            } else {
                key = "exe:\(p.executableName)"; name = p.executableName; bundleID = nil
            }
            if excludingBundleIDs.contains(key) || excludingBundleIDs.contains(p.bundleID) { continue }
            if members[key] == nil { order.append(key); members[key] = (name, bundleID, [], false) }
            members[key]!.objects.append(p.objectID)
            members[key]!.playing = members[key]!.playing || p.isRunningOutput
        }
        return order.map { key in
            let m = members[key]!
            return AudioAppGroup(key: key, name: m.name, bundleID: m.bundleID, processObjects: m.objects.sorted(), isPlaying: m.playing)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func owningApp(_ bundleID: String, _ apps: [RunningAppInfo]) -> RunningAppInfo? {
        guard !bundleID.isEmpty else { return nil }
        return apps.filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
}
```

- [ ] **Step 4: Implement mixer settings**

In `Sources/EquinoxCore/AppSettings.swift` add before `public struct AppSettings`:
```swift
public struct AppMixSettings: Codable, Equatable, Sendable {
    public var volume: Double = 1
    public var isMuted = false
    public var presetID: UUID?

    public init(volume: Double = 1, isMuted: Bool = false, presetID: UUID? = nil) {
        self.volume = volume; self.isMuted = isMuted; self.presetID = presetID
    }

    public var isDefault: Bool { volume == 1 && !isMuted && presetID == nil }
}
```
In `AppSettings`: add `public var appMix: [String: AppMixSettings] = [:]` after `launchAtLogin`, add `appMix` to `CodingKeys`, and in `init(from:)`:
```swift
        let mix = (try? c.decodeIfPresent([String: Lossy<AppMixSettings>].self, forKey: .appMix)) ?? [:]
        appMix = mix.compactMapValues(\.value)
        droppedEntries += mix.count - appMix.count
```

- [ ] **Step 5: Implement AppModel mixer**

In `Sources/EquinoxCore/AppModel.swift`:

Add above `@MainActor @Observable public final class AppModel`:
```swift
public struct MixerStrip: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let isOthers: Bool
    public let isPlaying: Bool
    public let isDedicated: Bool
    public let volume: Double
    public let isMuted: Bool
    public let isSoloed: Bool
    public let presetID: UUID?
}
```
Add state (after `lastError`):
```swift
    // MARK: Mixer
    public private(set) var mixerStrips: [MixerStrip] = []
    public private(set) var soloKey: String?
    public var stripMeters: StripMeters { audio.stripMeters }
    public var activeStripKeys: [String] { audio.activeStripKeys }
```
Add private state (with the other `@ObservationIgnored` vars):
```swift
    @ObservationIgnored private let runningApps: RunningAppsProviding
    @ObservationIgnored private var appMix: [String: AppMixSettings] = [:]
    @ObservationIgnored private var appGroups: [AudioAppGroup] = []
    @ObservationIgnored private var dedicatedKeys: [String] = []
```
Change the initializer signature to:
```swift
    public init(audio: AudioControlling, store: Store = Store(), loginItem: LoginItemControlling = SystemLoginItem(),
                runningApps: RunningAppsProviding = WorkspaceRunningApps()) {
```
set `self.runningApps = runningApps` with the other stored assignments, restore `appMix = s.appMix` with the other restores (before `restoring = false`), add after the other `audio.on…` hooks:
```swift
        audio.onProcessesChange = { [weak self] in self?.processesChanged($0) }
```
and replace the final `push()` of `init` with:
```swift
        processesChanged(audio.audioProcesses())
```

Add the mixer API (new `// MARK: Mixer` section):
```swift
    public func setStripVolume(_ volume: Double, for key: String) {
        updateMix(key) { $0.volume = min(max(volume, 0), StripSettings.maxVolume) }
    }

    public func setStripMuted(_ muted: Bool, for key: String) { updateMix(key) { $0.isMuted = muted } }

    public func setStripPreset(_ id: UUID?, for key: String) { updateMix(key) { $0.presetID = id } }

    public func resetStrip(_ key: String) {
        appMix[key] = nil
        if soloKey == key { soloKey = nil }
        mixerChanged()
    }

    public func toggleSolo(_ key: String) {
        guard key != StripSettings.othersKey else { return }
        soloKey = soloKey == key ? nil : key
        mixerChanged()
    }

    private func updateMix(_ key: String, _ change: (inout AppMixSettings) -> Void) {
        var s = appMix[key] ?? AppMixSettings()
        change(&s)
        appMix[key] = s.isDefault ? nil : s
        mixerChanged()
    }

    private func processesChanged(_ processes: [AudioProcessInfo]) {
        appGroups = AppGrouping.group(processes, runningApps: runningApps.runningApps(),
                                      excludingBundleIDs: [Bundle.main.bundleIdentifier ?? "com.pie.equinox", "com.pie.equinox"],
                                      excludingPIDs: [getpid()])
        if let solo = soloKey, !appGroups.contains(where: { $0.key == solo }) { soloKey = nil }
        mixerChanged()
    }

    /// Recomputes strips and dedicated taps, then pushes audio settings.
    private func mixerChanged() {
        let dedicatedGroups = appGroups
            .filter { appMix[$0.key] != nil || soloKey == $0.key }
            .sorted { $0.key < $1.key }
            .prefix(MixBus.maxStrips - 1)
        dedicatedKeys = dedicatedGroups.map(\.key)
        audio.setDedicatedStrips(dedicatedGroups.map { DedicatedStrip(key: $0.key, processes: $0.processObjects) })

        let others = appMix[StripSettings.othersKey] ?? AppMixSettings()
        var strips = [MixerStrip(id: StripSettings.othersKey, name: "Other Apps", bundleID: nil, isOthers: true,
                                 isPlaying: appGroups.contains { $0.isPlaying && !dedicatedKeys.contains($0.key) },
                                 isDedicated: true, volume: others.volume, isMuted: others.isMuted,
                                 isSoloed: false, presetID: others.presetID)]
        let apps = appGroups.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        strips += apps.map { g in
            let s = appMix[g.key] ?? AppMixSettings()
            return MixerStrip(id: g.key, name: g.name, bundleID: g.bundleID, isOthers: false, isPlaying: g.isPlaying,
                              isDedicated: dedicatedKeys.contains(g.key), volume: s.volume, isMuted: s.isMuted,
                              isSoloed: soloKey == g.key, presetID: s.presetID)
        }
        mixerStrips = strips
        push()
    }

    private func stripSettings() -> [StripSettings] {
        ([StripSettings.othersKey] + dedicatedKeys).map { key in
            let s = appMix[key] ?? AppMixSettings()
            let preset = s.presetID.flatMap { id in presets.first { $0.id == id } }
            let soloMuted = soloKey != nil && soloKey != key
            return StripSettings(key: key, volume: s.volume, isMuted: s.isMuted || soloMuted,
                                 preampDB: preset?.preampDB ?? 0, bands: preset?.bands ?? [])
        }
    }
```
In `push()` add `s.strips = stripSettings()` before `audio.apply(s)`.
In `deletePreset(_:)`, after removing from `userPresets`, add:
```swift
        for (key, mix) in appMix where mix.presetID == id {
            var m = mix; m.presetID = nil
            appMix[key] = m.isDefault ? nil : m
        }
```
and replace its trailing `if selectedPresetID == id { selectPreset(Preset.flat.id) } else { scheduleSave() }` with:
```swift
        if selectedPresetID == id { selectPreset(Preset.flat.id) }
        mixerChanged()
```
In `flushSave()` add `s.appMix = appMix`.
In `save()`, after updating the user preset, call `mixerChanged()` instead of `push()` (so app strips using that preset get the new bands).

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "AppGroupingTests|MixerModelTests"` → 14 PASS. Then `swift test` → all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(core): app grouping, persisted per-app mix settings, mixer API with solo"
```

---

### Task 4: Mixer UI, live self-test checks, snapshots

**Files:**
- Create: `Sources/Equinox/MixerViews.swift`
- Modify: `Sources/Equinox/MainWindow.swift`, `Sources/Equinox/MenuBarPanel.swift`, `Sources/Equinox/Diagnostics/SelfTest.swift`, `Sources/Equinox/Diagnostics/Snapshots.swift`

**Interfaces:**
- Consumes: `AppModel` mixer API (Task 3), `StripMeters`, `VerticalSlider`, `Theme`, `GlassCard`.
- Produces: `MixerMeters(model:)` (`level(_ key:) -> Float`, `attach()`, `detach()`), `MixerPage(model:meters:)`, `CompactMixer(model:meters:)`, `AppIcon(bundleID:size:)`.

- [ ] **Step 1: Mixer views**

`Sources/Equinox/MixerViews.swift`:
```swift
import AppKit
import EquinoxCore
import EquinoxDSP
import Observation
import SwiftUI

/// Polls per-strip peaks at 30 Hz while attached.
@MainActor
@Observable
final class MixerMeters {
    private(set) var levels: [String: Float] = [:]
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clients = 0
    @ObservationIgnored private var frozen = false

    init(model: AppModel) { self.model = model }

    func level(_ key: String) -> Float { levels[key] ?? 0 }

    func attach() {
        clients += 1
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        clients = max(clients - 1, 0)
        if clients == 0 { timer?.invalidate(); timer = nil }
    }

    /// Diagnostics: fixed levels, no polling.
    func freeze(_ levels: [String: Float]) { frozen = true; self.levels = levels }

    private func tick() {
        guard !frozen else { return }
        var next: [String: Float] = [:]
        for (i, key) in model.activeStripKeys.enumerated() {
            next[key] = max(model.stripMeters.take(strip: i), (levels[key] ?? 0) * 0.85)
        }
        levels = next
    }
}

struct AppIcon: View {
    var bundleID: String?
    var size: CGFloat

    var body: some View {
        if let image = icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: bundleID == nil ? "terminal.fill" : "app.fill")
                .font(.system(size: size * 0.6)).frame(width: size, height: size)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var icon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct MixerPage: View {
    @Bindable var model: AppModel
    var meters: MixerMeters

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Mixer").font(.system(.title2, design: .rounded).weight(.bold))
                Spacer()
                Text("Changing an app gives it its own channel. Reset returns it to Other Apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.mixerStrips) { strip in ChannelStripView(model: model, meters: meters, strip: strip) }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .onAppear { meters.attach() }
        .onDisappear { meters.detach() }
    }
}

struct ChannelStripView: View {
    @Bindable var model: AppModel
    var meters: MixerMeters
    var strip: MixerStrip

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if strip.isOthers {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 22)).frame(width: 38, height: 38)
                        .foregroundStyle(Theme.accent)
                } else {
                    AppIcon(bundleID: strip.bundleID, size: 38)
                }
                if strip.isPlaying {
                    Circle().fill(.green).frame(width: 9, height: 9).overlay(Circle().stroke(Theme.background, lineWidth: 2))
                }
            }
            Text(strip.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).frame(width: 96)

            HStack(alignment: .bottom, spacing: 8) {
                VerticalSlider(value: Binding(get: { strip.volume * 100 },
                                              set: { model.setStripVolume(($0 / 100), for: strip.id) }),
                               range: 0...150, tint: strip.isMuted ? .gray : Theme.cyan, zero: 100)
                    .frame(width: 34, height: 170)
                meter.frame(width: 6, height: 170)
            }
            Text("\(Int((strip.volume * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(strip.volume > 1 ? Theme.amber : .white.opacity(0.8))

            HStack(spacing: 6) {
                toggle("M", on: strip.isMuted, color: .red) { model.setStripMuted(!strip.isMuted, for: strip.id) }
                if !strip.isOthers {
                    toggle("S", on: strip.isSoloed, color: Theme.amber) { model.toggleSolo(strip.id) }
                }
            }

            Menu {
                Button("No EQ") { model.setStripPreset(nil, for: strip.id) }
                Divider()
                ForEach(model.presets) { p in Button(p.name) { model.setStripPreset(p.id, for: strip.id) } }
            } label: {
                Text(presetName).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .menuStyle(.button).controlSize(.small).frame(width: 96)

            Button("Reset") { model.resetStrip(strip.id) }
                .buttonStyle(.borderless).font(.caption2)
                .opacity(strip.volume != 1 || strip.isMuted || strip.presetID != nil || strip.isSoloed ? 1 : 0.3)
        }
        .frame(width: 112)
        .glassCard(cornerRadius: 18, padding: 12)
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(strip.isSoloed ? Theme.amber : .clear, lineWidth: 1.5))
    }

    private var presetName: String {
        strip.presetID.flatMap { id in model.presets.first { $0.id == id }?.name } ?? "No EQ"
    }

    @ViewBuilder private var meter: some View {
        GeometryReader { geo in
            let db = Decibels.fromLinear(Double(meters.level(strip.id)))
            let t = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(LinearGradient(colors: [Theme.cyan, Theme.violet, db > -1 ? .red : Theme.violet],
                                              startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * t)
            }
        }
        .opacity(strip.isDedicated ? 1 : 0.25)
        .help(strip.isDedicated ? "Live level" : "Adjust this app to get a live meter")
    }

    private func toggle(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : .white.opacity(0.08)))
                .foregroundStyle(on ? .black : .white.opacity(0.8))
        }.buttonStyle(.plain)
    }
}

/// Popover mixer: apps currently playing (max 5) plus Other Apps.
struct CompactMixer: View {
    @Bindable var model: AppModel
    var meters: MixerMeters

    var body: some View {
        let strips = Array(model.mixerStrips.filter { $0.isOthers || $0.isPlaying || $0.isDedicated }.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(strips) { strip in
                HStack(spacing: 8) {
                    if strip.isOthers {
                        Image(systemName: "square.stack.3d.up.fill").frame(width: 18).foregroundStyle(Theme.accent)
                    } else {
                        AppIcon(bundleID: strip.bundleID, size: 18)
                    }
                    Text(strip.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 84, alignment: .leading)
                    Slider(value: Binding(get: { strip.volume }, set: { model.setStripVolume($0, for: strip.id) }),
                           in: 0...StripSettings.maxVolume)
                        .tint(strip.volume > 1 ? Theme.amber : Theme.cyan).controlSize(.small)
                    Button { model.setStripMuted(!strip.isMuted, for: strip.id) } label: {
                        Image(systemName: strip.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .foregroundStyle(strip.isMuted ? .red : .white.opacity(0.7)).frame(width: 16)
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { meters.attach() }
        .onDisappear { meters.detach() }
    }
}
```

In `Sources/Equinox/Controls.swift`, give `VerticalSlider` a configurable zero line by adding `var zero: Double = 0` after `var tint: Color`, replacing `(0 - range.lowerBound)` with `(zero - range.lowerBound)`, and replacing the double-tap reset `value = 0` with `value = zero`.

- [ ] **Step 2: Wire into the app**

In `Sources/Equinox/MainWindow.swift`:
- `enum Page`: add `case mixer = "Mixer"` between `equalizer` and `settings`; `icon`:
```swift
    var icon: String {
        switch self {
        case .equalizer: "slider.vertical.3"
        case .mixer: "slider.horizontal.below.square.and.square.filled"
        case .settings: "gearshape"
        }
    }
```
- `MainWindow`: add `var meters: MixerMeters` after `spectrum`, and in the detail `switch` add `case .mixer: MixerPage(model: model, meters: meters)`.

In `Sources/Equinox/MenuBarPanel.swift`: add `var meters: MixerMeters` after `spectrum`, and insert after the volume `glassCard` block:
```swift
            CompactMixer(model: model, meters: meters)
                .glassCard(cornerRadius: 14, padding: 12)
```

In `Sources/Equinox/EquinoxApp.swift`: add `let meters: MixerMeters` to `AppEnvironment`, initialise `meters = MixerMeters(model: model)` after `spectrum`, and pass `meters: env.meters` to `MenuBarPanel` and `MainWindow`.

- [ ] **Step 3: Snapshots**

In `Sources/Equinox/Diagnostics/Snapshots.swift`:
- `PreviewAudio`: implement the Task 2 members, with:
```swift
    var processes: [AudioProcessInfo] = [
        AudioProcessInfo(objectID: 31, pid: 31, bundleID: "com.apple.Music", executableName: "Music", isRunningOutput: true),
        AudioProcessInfo(objectID: 32, pid: 32, bundleID: "com.google.Chrome.helper", executableName: "Helper", isRunningOutput: true),
        AudioProcessInfo(objectID: 33, pid: 33, bundleID: "us.zoom.xos", executableName: "zoom.us", isRunningOutput: false),
        AudioProcessInfo(objectID: 34, pid: 34, bundleID: "", executableName: "afplay", isRunningOutput: true),
    ]
    var activeStripKeys: [String] = ["", "com.apple.Music", "com.google.Chrome"]
```
- Use a preview running-apps provider:
```swift
final class PreviewRunningApps: RunningAppsProviding {
    func runningApps() -> [RunningAppInfo] {
        [RunningAppInfo(bundleID: "com.apple.Music", name: "Music"),
         RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome"),
         RunningAppInfo(bundleID: "us.zoom.xos", name: "zoom.us")]
    }
}
```
  and pass `runningApps: PreviewRunningApps()` to the preview `AppModel`.
- After the existing model setup add:
```swift
            model.setStripVolume(1.3, for: "com.apple.Music")
            model.setStripPreset(Preset.builtIns[1].id, for: "com.apple.Music")
            model.setStripVolume(0.45, for: "com.google.Chrome")
            model.setStripMuted(true, for: "us.zoom.xos")
            let meters = MixerMeters(model: model)
            meters.freeze(["": 0.35, "com.apple.Music": 0.8, "com.google.Chrome": 0.3])
```
- Pass `meters:` to `MenuBarPanel` and `MainWindow`, and add:
```swift
            save("mixer", MixerPage(model: model, meters: meters).frame(width: 900).background(bg), dir)
```

- [ ] **Step 4: Per-app live checks in the self-test**

In `Sources/Equinox/Diagnostics/SelfTest.swift`:
- Change `try startTone(seconds: 14)` to `try startTone(seconds: 26)`.
- Insert before `audio.apply(DSPSettings())` / `audio.restart()` (the rebuild check):
```swift
        await perAppChecks(flat: flat)
```
- Add:
```swift
    /// Gives afplay (the tone) its own strip and checks per-app volume, mute, EQ and isolation from Other Apps.
    private func perAppChecks(flat: Double) async {
        let tone = AudioSystem.audioProcesses().filter { $0.executableName == "afplay" }.map(\.objectID)
        guard !tone.isEmpty else { check("per-app: tone process found", false, "afplay not in HAL process list"); return }
        let key = "exe:afplay"
        audio.setDedicatedStrips([DedicatedStrip(key: key, processes: tone)])
        await sleep(0.6)   // debounced rebuild
        let rebuilt = await waitForRunning()
        await sleep(0.8)
        check("per-app: dedicated tap session", rebuilt && audio.activeStripKeys == ["", key],
              "strips \(audio.activeStripKeys)")

        var s = DSPSettings()
        s.strips = [StripSettings(key: key, volume: 0.5)]
        let half = await measure(s)
        check("per-app: app volume 50% = −6 dB", abs(half - flat + 6.02) < 0.5, "Δ \(fmt(half - flat)) dB")

        s.strips = [StripSettings(key: key, volume: 1), StripSettings(key: StripSettings.othersKey, volume: 0)]
        let isolated = await measure(s)
        check("per-app: Other Apps fader doesn't touch a dedicated app", abs(isolated - flat) < 0.5, "Δ \(fmt(isolated - flat)) dB")

        s.strips = [StripSettings(key: key, isMuted: true)]
        let muted = await measure(s)
        check("per-app: app mute", muted < -90, "\(fmt(muted)) dBFS")

        s.strips = [StripSettings(key: key, bands: [EQBand(type: .peak, frequency: 1000, gainDB: 12, q: 1)])]
        let eq = await measure(s)
        check("per-app: app EQ +12 dB at 1 kHz", abs(eq - flat - 12) < 1, "Δ \(fmt(eq - flat)) dB")

        audio.setDedicatedStrips([])
        await sleep(0.6)
        _ = await waitForRunning()
        await sleep(0.8)
    }
```

- [ ] **Step 5: Build, test, render, and run the live checks**

Run: `swift test 2>&1 | grep -E "with [1-9][0-9]* failures" | wc -l` → `0`.
Run: `scripts/self-test.sh <snapshot-dir>`
Expected: every line `PASS` (now 17 checks: the Phase 1 twelve + five per-app), `RESULT: all 17 checks passed`. Open `mixer.png`, `menubar.png`, `main-window.png` from the snapshot dir and check: strips render with icons, Other Apps first, Music at 130% amber with Bass Boost, Chrome 45%, Zoom muted (red M), afplay with terminal icon; popover shows the compact mixer.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(app): mixer page, popover mixer, per-app self-test checks and snapshots"
```
