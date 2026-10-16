# Equinox Phase 4 (Headphones, Updates, Polish) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Headphone layer (AutoEQ correction, crossfeed, HRTF spatial audio, headphone detection), in-app updates from GitHub releases, effect factory presets + drag reordering, then ship v0.4.0.

**Architecture:** Correction is a second `BiquadBank` in `MasterProcessor` ahead of the user EQ (its preamp folded into the output gain). Crossfeed is a pure-DSP stage at the start of `processPost` using a complementary formulation `L' = L + c·(D[LP(R)] − D[LP(L)])` that leaves mono exactly unchanged. Spatial is a `SpatialRenderer` (AVAudioEngine in realtime manual rendering: two mono `AVAudioSourceNode`s → `AVAudioEnvironmentNode` HRTF-HQ) rendered between effects and `processPost`, handed over through the acknowledgement mailbox like effects. Headphone settings are stored per output device (built-in jack and speakers kept apart). AutoEQ index/profiles are fetched from `raw.githubusercontent.com/jaakkopasanen/AutoEq` behind a `AutoEQProviding` protocol with an on-disk cache; updates come from `api.github.com/repos/north-built-labs/equinox/releases/latest` behind `UpdateProviding`, installed by a detached shell script that swaps the bundle after Equinox quits.

**Tech Stack:** as before + URLSession.

**Spec:** `docs/superpowers/specs/2026-10-15-equinox-design.md` (§3 Phase 4; §6 Headphones page; roadmap "updates"; Phase 3 spec drift: factory presets, draggable chain)

## Global Constraints

- All earlier Global Constraints apply. Network access is now allowed, only to `raw.githubusercontent.com` (AutoEq) and `api.github.com` / `github.com` (Equinox releases), over HTTPS.
- Downloaded content is untrusted: AutoEq index paths must start with `./`, contain no `..`, `?` or `#`; profiles are parsed with clamping and a 32-band cap; an update is installed only if the downloaded bundle's `CFBundleIdentifier` is `com.northbuiltlabs.equinox` and its version is newer.
- Signal order: correction → user EQ → effects → crossfeed **or** spatial (spatial wins) → volume/balance/boost (incl. correction preamp) → limiter. Master bypass turns off correction, crossfeed and spatial too.
- Crossfeed strengths: low (c 0.30, 700 Hz), medium (0.45, 650 Hz), high (0.60, 600 Hz); 0.3 ms cross delay.
- Spatial width 10–60° (default 30°), room 0–1 (default 0.15).
- AutoEq index cache: `~/Library/Application Support/Equinox/autoeq-index.md`, refreshed when older than 7 days, stale cache used if offline.
- Version for this release: 0.4.0 (build 4).

## Review Focus

1. **Offline / GitHub down / malformed AutoEq data:** search shows a clear error or the cached index; nothing crashes; garbage profile text is rejected. Tests in Task 1 (`testGarbageThrows`) and Task 3 (`testOfflineFallsBackToStaleCache`, `testRejectsUnsafeIndexPaths`).
2. **Built-in output switching between speakers and the headphone jack (same device UID):** headphone settings must not leak onto the speakers. Test in Task 3 (`testJackAndSpeakersKeepSeparateSettings`).
3. **Mono content through crossfeed** must be bit-for-bit unchanged; spatial must not silence or blow up the signal. Tests in Task 1 (`testMonoIsUnchanged`) and Task 2 (`testCentredSignalKeepsLevel`).
4. **Update installer** must refuse a download that isn't Equinox or isn't newer, and never delete the running app before the replacement is verified. Test in Task 3 (`testInstallerRefusesForeignBundle`, `testScriptReplacesOnlyAfterExit`).
5. **Spatial + crossfeed both requested:** only spatial runs. Test in Task 3 (`testSpatialSupersedesCrossfeed`).

---

## File Structure

```
Sources/EquinoxDSP/
  Crossfeed.swift            NEW CrossfeedStrength, Crossfeed
  ParametricEQText.swift     NEW CorrectionProfile, ParametricEQText.parse
  DSPSettings.swift          + correction, crossfeed, spatialEnabled
  MasterProcessor.swift      + correction bank, crossfeed stage
Sources/EquinoxAudio/
  SpatialRenderer.swift      NEW SpatialParameters, SpatialRenderer
  AudioSystem.swift          + HeadphoneDetection, AudioDevice.isHeadphones
  Renderer.swift             + spatial mailbox/stage
  AudioController.swift      + setSpatial, data-source listener
Sources/EquinoxCore/
  AutoEQ.swift               NEW AutoEQEntry, AutoEQIndex, AutoEQProviding, AutoEQCatalog
  Updates.swift              NEW ReleaseInfo, UpdateChecker, UpdateProviding, GitHubUpdates, UpdateInstaller
  AppSettings.swift          + headphones, headphoneOverrides, autoEnableHeadphones, checkForUpdates, lastUpdateCheck
  AppModel.swift             + headphone API, AutoEQ API, update API, moveEffect(_:to:)
Sources/Equinox/
  HeadphonesViews.swift      NEW HeadphonesPage
  EffectsViews.swift         factory presets, drag & drop
  MainWindow.swift, EquinoxApp.swift, Diagnostics/*
Resources/Info.plist         0.4.0
README.md
```

---

### Task 1: Crossfeed, correction bank, ParametricEQ parser

**Files:**
- Create: `Sources/EquinoxDSP/Crossfeed.swift`, `Sources/EquinoxDSP/ParametricEQText.swift`
- Modify: `Sources/EquinoxDSP/DSPSettings.swift`, `Sources/EquinoxDSP/MasterProcessor.swift`
- Test: `Tests/EquinoxDSPTests/HeadphoneDSPTests.swift`

**Interfaces:**
- Produces: `CrossfeedStrength` (`off, low, medium, high`, `displayName`), `Crossfeed(sampleRate:)` with `configure(_:sampleRate:)`, `process(left:right:frames:)`; `CorrectionProfile(name:source:preampDB:bands:)` (Codable, Hashable); `ParametricEQText.parse(_:name:source:) throws -> CorrectionProfile`, `ParametricEQText.ParseError.noFilters`; `DSPSettings.correction: CorrectionProfile?`, `.crossfeed: CrossfeedStrength`, `.spatialEnabled: Bool`; `DSPConfig.correctionCoefficients: [Double]?`, `.crossfeed`, `.spatialEnabled`.

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxDSPTests/HeadphoneDSPTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

final class HeadphoneDSPTests: XCTestCase {
    let fs = 48_000.0

    func crossfeed(_ s: CrossfeedStrength, _ l: [Float], _ r: [Float]) -> ([Float], [Float]) {
        let x = Crossfeed(sampleRate: fs)
        x.configure(s, sampleRate: fs)
        var l = l, r = r
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            x.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count) } }
        return (l, r)
    }

    func testMonoIsUnchanged() {
        let x = Signal.sine(300, fs: fs, count: 4800)
        let (l, r) = crossfeed(.high, x, x)
        XCTAssertEqual(l, x); XCTAssertEqual(r, x)
    }

    func testHardLeftBassBleedsRightButTrebleDoesNot() {
        let zero = [Float](repeating: 0, count: 9600)
        let (_, rLow) = crossfeed(.medium, Signal.sine(100, fs: fs, count: 9600), zero)
        let (_, rHigh) = crossfeed(.medium, Signal.sine(8000, fs: fs, count: 9600), zero)
        let low = Signal.rms(rLow[4800...]), high = Signal.rms(rHigh[4800...])
        XCTAssertGreaterThan(low, 0.1)          // ≈ 0.45 × 0.35 rms
        XCTAssertLessThan(high, low / 8)
    }

    func testStrengthsIncreaseBleedAndOffIsIdentity() {
        let zero = [Float](repeating: 0, count: 9600), x = Signal.sine(100, fs: fs, count: 9600)
        let bleed = [CrossfeedStrength.low, .medium, .high].map { Signal.rms(crossfeed($0, x, zero).1[4800...]) }
        XCTAssertTrue(bleed[0] < bleed[1] && bleed[1] < bleed[2])
        let (l, r) = crossfeed(.off, x, zero)
        XCTAssertEqual(l, x); XCTAssertEqual(r, zero)
    }

    func gain(_ s: DSPSettings, _ f: Double = 1000) -> Double {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        let x = Signal.sine(f, fs: fs, count: 24_000, amplitude: 0.05)
        var l = x, r = x
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            p.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 24_000) } }
        return Double(20 * log10(Signal.rms(l[12_000...]) / Signal.rms(x[12_000...])))
    }

    func testCorrectionStacksWithUserEQAndAppliesPreamp() {
        var s = DSPSettings()
        s.correction = CorrectionProfile(name: "HP", source: "test", preampDB: -3,
                                         bands: [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)])
        XCTAssertEqual(gain(s), 3, accuracy: 0.1)
        s.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)]
        XCTAssertEqual(gain(s), 9, accuracy: 0.1)
        s.isBypassed = true
        XCTAssertEqual(gain(s), 0, accuracy: 0.05)
    }

    func testCrossfeedRunsInMasterButNotWhenSpatialOrBypassed() {
        var s = DSPSettings(); s.crossfeed = .high
        XCTAssertEqual(DSPConfig(settings: s, sampleRate: fs).crossfeed, .high)
        s.spatialEnabled = true
        XCTAssertEqual(DSPConfig(settings: s, sampleRate: fs).crossfeed, .off)
        s.spatialEnabled = false; s.isBypassed = true
        let cfg = DSPConfig(settings: s, sampleRate: fs)
        XCTAssertEqual(cfg.crossfeed, .off); XCTAssertFalse(cfg.spatialEnabled)
    }

    let hd650 = """
    Preamp: -6.1 dB
    Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
    Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
    Filter 3: OFF PK Fc 118 Hz Gain -3.1 dB Q 0.50
    Filter 4: ON HSC Fc 10000 Hz Gain -2.1 dB Q 0.70
    Filter 5: ON LP Fc 18000 Hz
    """

    func testParsesAutoEQParametricText() throws {
        let p = try ParametricEQText.parse(hd650, name: "Sennheiser HD 650", source: "oratory1990")
        XCTAssertEqual(p.preampDB, -6.1)
        XCTAssertEqual(p.bands.map(\.type), [.lowShelf, .peak, .highShelf, .lowPass])
        XCTAssertEqual(p.bands[0].frequency, 105); XCTAssertEqual(p.bands[0].gainDB, 6.4); XCTAssertEqual(p.bands[0].q, 0.7)
        XCTAssertEqual(p.bands[3].q, 0.707, accuracy: 0.001)
    }

    func testGarbageThrowsAndHugeFilesAreCapped() throws {
        XCTAssertThrowsError(try ParametricEQText.parse("<html>not found</html>", name: "x", source: "y"))
        let many = (1...60).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 99 dB Q 0.5" }.joined(separator: "\n")
        let p = try ParametricEQText.parse("Preamp: -400 dB\n" + many, name: "x", source: "y")
        XCTAssertEqual(p.bands.count, BiquadBank.maxSections)
        XCTAssertEqual(p.bands[0].gainDB, 24)
        XCTAssertEqual(p.preampDB, -24)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HeadphoneDSPTests` → compile failure `cannot find 'Crossfeed' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxDSP/Crossfeed.swift`:
```swift
import Foundation

public enum CrossfeedStrength: String, Codable, CaseIterable, Sendable {
    case off, low, medium, high

    public var displayName: String { rawValue.capitalized }

    var amount: Float {
        switch self { case .off: 0; case .low: 0.30; case .medium: 0.45; case .high: 0.60 }
    }

    var cutoff: Double {
        switch self { case .off, .low: 700; case .medium: 650; case .high: 600 }
    }
}

/// Complementary crossfeed: L' = L + c·(D[LP(R)] − D[LP(L)]), R' = R − c·(D[LP(R)] − D[LP(L)]).
/// Low frequencies of each side bleed (slightly delayed) into the other; mono content (L = R) is untouched.
public final class Crossfeed {
    private static let delayCapacity = 64
    private static let delaySeconds = 0.0003

    private var amount: Float = 0
    private var alpha: Float = 0
    private var delay = 1
    private var lowL: Float = 0, lowR: Float = 0
    private var writeIndex = 0
    private let lineL = UnsafeMutablePointer<Float>.allocate(capacity: Crossfeed.delayCapacity)
    private let lineR = UnsafeMutablePointer<Float>.allocate(capacity: Crossfeed.delayCapacity)

    public init(sampleRate: Double) {
        lineL.initialize(repeating: 0, count: Self.delayCapacity)
        lineR.initialize(repeating: 0, count: Self.delayCapacity)
        configure(.off, sampleRate: sampleRate)
    }

    deinit { lineL.deallocate(); lineR.deallocate() }

    /// Realtime-safe.
    public func configure(_ strength: CrossfeedStrength, sampleRate: Double) {
        if strength == .off, amount != 0 { reset() }
        amount = strength.amount
        alpha = Float(1 - exp(-2 * Double.pi * strength.cutoff / sampleRate))
        delay = min(max(Int((Self.delaySeconds * sampleRate).rounded()), 1), Self.delayCapacity - 1)
    }

    private func reset() {
        lowL = 0; lowR = 0
        lineL.update(repeating: 0, count: Self.delayCapacity)
        lineR.update(repeating: 0, count: Self.delayCapacity)
    }

    /// Realtime-safe, in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard amount > 0 else { return }
        let mask = Self.delayCapacity - 1
        for i in 0..<frames {
            lowL += alpha * (left[i] - lowL)
            lowR += alpha * (right[i] - lowR)
            lineL[writeIndex] = lowL
            lineR[writeIndex] = lowR
            let read = (writeIndex - delay) & mask
            let difference = amount * (lineR[read] - lineL[read])
            left[i] += difference
            right[i] -= difference
            writeIndex = (writeIndex + 1) & mask
        }
    }
}
```

`Sources/EquinoxDSP/ParametricEQText.swift`:
```swift
import Foundation

/// A headphone correction (e.g. from AutoEq), applied ahead of the user's EQ.
public struct CorrectionProfile: Codable, Hashable, Sendable {
    public var name: String
    public var source: String
    public var preampDB: Double
    public var bands: [EQBand]

    public init(name: String, source: String, preampDB: Double, bands: [EQBand]) {
        self.name = name; self.source = source; self.preampDB = preampDB; self.bands = bands
    }
}

/// Parser for Equalizer APO / AutoEq "ParametricEQ.txt" files. Input is untrusted: values are clamped,
/// filters capped at `BiquadBank.maxSections`, unknown lines ignored.
public enum ParametricEQText {
    public enum ParseError: Error { case noFilters }

    static let types: [String: FilterType] = [
        "PK": .peak, "PEQ": .peak, "LSC": .lowShelf, "LS": .lowShelf, "HSC": .highShelf, "HS": .highShelf,
        "LP": .lowPass, "LPQ": .lowPass, "HP": .highPass, "HPQ": .highPass, "NO": .notch, "BP": .bandPass,
    ]

    public static func parse(_ text: String, name: String, source: String) throws -> CorrectionProfile {
        var preamp = 0.0
        var bands: [EQBand] = []
        for raw in text.split(whereSeparator: \.isNewline).prefix(1000) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let tokens = line.split(separator: " ").map(String.init)
            if line.hasPrefix("Preamp:"), tokens.count >= 2, let v = Double(tokens[1]) {
                preamp = v
                continue
            }
            guard line.hasPrefix("Filter"), let on = tokens.firstIndex(where: { $0 == "ON" }),
                  on + 1 < tokens.count, let type = types[tokens[on + 1].uppercased()],
                  let fc = value(after: "Fc", in: tokens) else { continue }
            let q = value(after: "Q", in: tokens) ?? 0.707
            bands.append(EQBand(type: type, frequency: fc, gainDB: value(after: "Gain", in: tokens) ?? 0, q: q).clamped())
            if bands.count == BiquadBank.maxSections { break }
        }
        guard !bands.isEmpty else { throw ParseError.noFilters }
        return CorrectionProfile(name: name, source: source,
                                 preampDB: min(max(preamp.isFinite ? preamp : 0, -24), 24), bands: bands)
    }

    private static func value(after key: String, in tokens: [String]) -> Double? {
        guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count, let v = Double(tokens[i + 1]), v.isFinite else { return nil }
        return v
    }
}
```

`Sources/EquinoxDSP/DSPSettings.swift`:
- In `DSPSettings` add after `strips`:
```swift
    /// Headphone correction (AutoEq), applied before the user EQ.
    public var correction: CorrectionProfile?
    public var crossfeed: CrossfeedStrength = .off
    /// Spatial audio runs in the audio layer; when on, crossfeed is skipped.
    public var spatialEnabled = false
```
- In `DSPConfig` add stored properties:
```swift
    public let correctionCoefficients: [Double]?
    public let crossfeed: CrossfeedStrength
    public let spatialEnabled: Bool
```
  and in its initializer, before computing `common`:
```swift
        let correction = s.isBypassed ? nil : s.correction
        correctionCoefficients = correction.map { c in
            BiquadBank.flatten(c.bands.lazy.filter(\.isEnabled).prefix(BiquadBank.maxSections)
                .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) })
        }
        let correctionPreamp = correction.map { Decibels.toLinear(min(max($0.preampDB, -24), 24)) } ?? 1
        spatialEnabled = !s.isBypassed && s.spatialEnabled
        crossfeed = s.isBypassed || s.spatialEnabled ? .off : s.crossfeed
```
  and change `let common = s.isMuted ? 0 : volume * boost * preamp` to `let common = s.isMuted ? 0 : volume * boost * preamp * correctionPreamp`.

`Sources/EquinoxDSP/MasterProcessor.swift`:
- Add stored properties:
```swift
    private let correction: BiquadBank
    private var correctionActive = false
    private let crossfeed: Crossfeed
    private var sampleRate: Double
```
- In `init`: `correction = BiquadBank(maxFrames: maxFrames)`, `crossfeed = Crossfeed(sampleRate: sampleRate)`, `self.sampleRate = sampleRate`.
- At the end of `apply(_:)` (before `hasConfig = true`):
```swift
        if let c = config.correctionCoefficients {
            correction.setCoefficients(c, ramp: correctionActive)
            correctionActive = true
        } else if correctionActive {
            correctionActive = false
            correction.reset()
        }
        sampleRate = config.sampleRate
        crossfeed.configure(config.crossfeed, sampleRate: config.sampleRate)
```
- In `processPre`, before `eq.process(...)`: `if correctionActive { correction.process(left: left + o, right: right + o, frames: n) }`, and in its non-finite branch also `correction.reset()`.
- In `processPost`, after the non-finite guard and before the ramps: `crossfeed.process(left: left + o, right: right + o, frames: n)`.

- [ ] **Step 4: Run tests** — `swift test --filter EquinoxDSPTests` → all PASS.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dsp): headphone correction bank, complementary crossfeed, ParametricEQ parser"`

---

### Task 2: Spatial renderer, headphone detection, controller wiring

**Files:**
- Create: `Sources/EquinoxAudio/SpatialRenderer.swift`
- Modify: `Sources/EquinoxAudio/AudioSystem.swift`, `Sources/EquinoxAudio/Renderer.swift`, `Sources/EquinoxAudio/AudioController.swift`
- Test: `Tests/EquinoxAudioTests/HeadphoneAudioTests.swift`

**Interfaces:**
- Produces: `SpatialParameters(width:room:)` (Codable, Equatable; `widthRange`), `SpatialRenderer(sampleRate:parameters:) throws` with `.sampleRate`, `set(_:)`, `render(left:right:frames:)`; `HeadphoneDetection.isHeadphones(name:dataSource:) -> Bool`; `AudioDevice.isHeadphones` (init param `isHeadphones: Bool = false`); `Renderer.submitSpatial(_:)`; `AudioControlling.setSpatial(_ parameters: SpatialParameters?)`.

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxAudioTests/HeadphoneAudioTests.swift`:
```swift
import CoreAudio
import XCTest
@testable import EquinoxAudio
import EquinoxDSP

final class HeadphoneAudioTests: XCTestCase {
    let fs = 48_000.0

    func render(_ s: SpatialRenderer, _ l: [Float], _ r: [Float]) -> ([Float], [Float]) {
        var l = l, r = r
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            for b in stride(from: 0, to: lp.count, by: 512) {
                s.render(left: lp.baseAddress! + b, right: rp.baseAddress! + b, frames: min(512, lp.count - b))
            }
        } }
        return (l, r)
    }

    func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }
    func sine(_ f: Double, _ n: Int) -> [Float] { (0..<n).map { 0.1 * Float(sin(2 * .pi * f * Double($0) / fs)) } }

    func testCentredSignalKeepsLevel() throws {
        let s = try SpatialRenderer(sampleRate: fs, parameters: SpatialParameters(room: 0))
        let x = sine(1000, 24_000)
        let (l, r) = render(s, x, x)
        XCTAssertTrue(l.allSatisfy(\.isFinite))
        let db = 20 * log10(Double(rms(l[12_000...]) / rms(x[12_000...])))
        XCTAssertEqual(db, 0, accuracy: 3)
        XCTAssertEqual(rms(l[12_000...]), rms(r[12_000...]), accuracy: 0.01)
    }

    func testHardLeftReachesBothEarsLouderOnTheLeft() throws {
        let s = try SpatialRenderer(sampleRate: fs, parameters: SpatialParameters())
        let (l, r) = render(s, sine(500, 24_000), [Float](repeating: 0, count: 24_000))
        let el = rms(l[12_000...]), er = rms(r[12_000...])
        XCTAssertGreaterThan(er, 0.005)
        XCTAssertGreaterThan(el, er)
    }

    func testWiderSpeakersSeparateMore() throws {
        func ratio(_ width: Double) throws -> Float {
            let s = try SpatialRenderer(sampleRate: fs, parameters: SpatialParameters(width: width, room: 0))
            let (l, r) = render(s, sine(500, 24_000), [Float](repeating: 0, count: 24_000))
            return rms(l[12_000...]) / rms(r[12_000...])
        }
        XCTAssertGreaterThan(try ratio(60), try ratio(10))
    }

    func testHeadphoneDetection() {
        let hdpn = UInt32(0x6864706E)   // 'hdpn'
        let ispk = UInt32(0x6973706B)   // 'ispk'
        XCTAssertTrue(HeadphoneDetection.isHeadphones(name: "MacBook Air Speakers", dataSource: hdpn))
        XCTAssertFalse(HeadphoneDetection.isHeadphones(name: "MacBook Air Speakers", dataSource: ispk))
        XCTAssertTrue(HeadphoneDetection.isHeadphones(name: "Payam's AirPods Pro", dataSource: nil))
        XCTAssertTrue(HeadphoneDetection.isHeadphones(name: "WH-1000XM5", dataSource: nil))
        XCTAssertFalse(HeadphoneDetection.isHeadphones(name: "Nighthawk", dataSource: nil))
        XCTAssertFalse(HeadphoneDetection.isHeadphones(name: "LG UltraFine Display Audio", dataSource: nil))
    }

    func testRendererRunsSpatialStageOnlyWhenEnabled() throws {
        let renderer = Renderer()
        renderer.prepare(sampleRate: fs, inputStreamOffset: 0, stripCount: 1)
        var s = DSPSettings()
        renderer.submit(DSPConfig(settings: s, sampleRate: fs))
        renderer.submitSpatial(try SpatialRenderer(sampleRate: fs, parameters: SpatialParameters()))
        func run() -> Float {
            let frames = 512
            let input = AudioBufferList.allocate(maximumBuffers: 1)
            let ip = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames { ip[2 * i] = 0.2 * Float(sin(Double(i) * 0.07)); ip[2 * i + 1] = 0 }   // hard left
            input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: ip)
            let output = AudioBufferList.allocate(maximumBuffers: 1)
            let op = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: op)
            var right: Float = 0
            for _ in 0..<8 {
                renderer.render(input: UnsafePointer(input.unsafeMutablePointer), output: output.unsafeMutablePointer)
                right = 0
                for i in 0..<frames { right = max(right, abs(op[2 * i + 1])) }
            }
            return right
        }
        XCTAssertEqual(run(), 0, accuracy: 1e-6)          // spatial not enabled → right stays silent
        s.spatialEnabled = true
        renderer.submit(DSPConfig(settings: s, sampleRate: fs))
        XCTAssertGreaterThan(run(), 0.001)                 // spatial on → left leaks into right ear
    }
}
```

- [ ] **Step 2: Run tests to verify they fail** — `swift test --filter HeadphoneAudioTests` → compile failure `cannot find 'SpatialRenderer'`.

- [ ] **Step 3: Implement**

`Sources/EquinoxAudio/SpatialRenderer.swift`:
```swift
import AVFoundation

public struct SpatialParameters: Codable, Equatable, Sendable {
    public static let widthRange: ClosedRange<Double> = 10...60
    /// Angle of each virtual speaker from centre, in degrees.
    public var width: Double
    /// Room ambience, 0…1.
    public var room: Double

    public init(width: Double = 30, room: Double = 0.15) { self.width = width; self.room = room }
}

/// Virtual stereo speakers for headphones: L and R become two mono sources at ±width° in an
/// AVAudioEnvironmentNode (HRTF-HQ), rendered in realtime manual mode. `render` is realtime-safe.
public final class SpatialRenderer: @unchecked Sendable {
    public static let maxFrames = 4096
    /// Brings a centred source back to roughly unity after HRTF processing (measured; see tests).
    static let makeupGain: Float = 1.0

    private final class Feed: @unchecked Sendable {
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
    }

    public let sampleRate: Double
    private let engine: AVAudioEngine
    private let environment: AVAudioEnvironmentNode
    private let sources: [AVAudioSourceNode]
    private let feed: Feed
    private let renderBlock: AVAudioEngineManualRenderingBlock
    private let output: UnsafeMutableAudioBufferListPointer
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>

    public init(sampleRate: Double, parameters: SpatialParameters) throws {
        let engine = AVAudioEngine()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        try engine.enableManualRenderingMode(.realtime, format: stereo, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        let feed = Feed()
        func source(left: Bool) -> AVAudioSourceNode {
            AVAudioSourceNode(format: mono) { _, _, frames, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                guard let dst = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if let src = left ? feed.left : feed.right { dst.update(from: src, count: Int(frames)) }
                else { dst.update(repeating: 0, count: Int(frames)) }
                return noErr
            }
        }
        let sources = [source(left: true), source(left: false)]
        let environment = AVAudioEnvironmentNode()
        for node in sources { engine.attach(node) }
        engine.attach(environment)
        for node in sources {
            engine.connect(node, to: environment, format: mono)
            node.renderingAlgorithm = .HRTFHQ
        }
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        environment.reverbParameters.level = 0
        try engine.start()

        self.sampleRate = sampleRate
        self.engine = engine
        self.environment = environment
        self.sources = sources
        self.feed = feed
        renderBlock = engine.manualRenderingBlock
        output = AudioBufferList.allocate(maximumBuffers: 2)
        outL = .allocate(capacity: Self.maxFrames); outL.initialize(repeating: 0, count: Self.maxFrames)
        outR = .allocate(capacity: Self.maxFrames); outR.initialize(repeating: 0, count: Self.maxFrames)
        set(parameters)
    }

    deinit {
        engine.stop()
        free(output.unsafeMutablePointer)
        outL.deallocate(); outR.deallocate()
    }

    /// Main thread. Live: speaker angle and room send.
    public func set(_ p: SpatialParameters) {
        let angle = min(max(p.width, SpatialParameters.widthRange.lowerBound), SpatialParameters.widthRange.upperBound) * .pi / 180
        sources[0].position = AVAudio3DPoint(x: Float(-sin(angle)), y: 0, z: Float(-cos(angle)))
        sources[1].position = AVAudio3DPoint(x: Float(sin(angle)), y: 0, z: Float(-cos(angle)))
        let room = Float(min(max(p.room.isFinite ? p.room : 0, 0), 1))
        environment.reverbParameters.enable = room > 0
        for node in sources { node.reverbBlend = room }
    }

    /// Realtime-safe, in place, any frame count. On a render error audio passes through unchanged.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var offset = 0
        while offset < frames {
            let n = min(Self.maxFrames, frames - offset)
            feed.left = left + offset
            feed.right = right + offset
            let bytes = UInt32(n * MemoryLayout<Float>.size)
            output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outL))
            output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outR))
            var error: OSStatus = noErr
            if renderBlock(AVAudioFrameCount(n), output.unsafeMutablePointer, &error) == .success,
               let l = output[0].mData?.assumingMemoryBound(to: Float.self),
               let r = output[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<n {
                    left[offset + i] = l[i] * Self.makeupGain
                    right[offset + i] = r[i] * Self.makeupGain
                }
            }
            offset += n
        }
        feed.left = nil
        feed.right = nil
    }
}
```

`Sources/EquinoxAudio/AudioSystem.swift`:
- `AudioDevice`: add `public let isHeadphones: Bool`, an init parameter `isHeadphones: Bool = false` (last), assigned.
- Add:
```swift
public enum HeadphoneDetection {
    static let headphoneJack: UInt32 = 0x6864706E   // 'hdpn'
    static let keywords = ["airpods", "headphone", "headset", "earbud", "earphone", "buds", "beats",
                           "wh-1000", "wf-1000", "quietcomfort", "momentum", "iem"]

    /// Built-in output with the headphone jack in use, or a name that says headphones.
    /// (Bluetooth alone isn't enough: it also covers speakers.) The user can override per device.
    public static func isHeadphones(name: String, dataSource: UInt32?) -> Bool {
        if dataSource == headphoneJack { return true }
        let lowered = name.lowercased()
        return keywords.contains { lowered.contains($0) }
    }
}
```
- In `AudioSystem.describe(_:)` compute:
```swift
        let name = try id.getString(kAudioObjectPropertyName)
        let dataSource = id.has(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            ? try? id.get(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) : nil
```
  and pass `name: name` and `isHeadphones: HeadphoneDetection.isHeadphones(name: name, dataSource: dataSource)` to `AudioDevice(...)`.

`Sources/EquinoxAudio/Renderer.swift`:
- Add below `EffectsBox`:
```swift
final class SpatialBox: @unchecked Sendable {
    let renderer: SpatialRenderer?
    init(_ renderer: SpatialRenderer?) { self.renderer = renderer }
}
```
- In `Renderer` add `private let spatialMailbox = Mailbox<SpatialBox>()`, `private var spatialEntry: Mailbox<SpatialBox>.Entry?`, and `public func submitSpatial(_ spatial: SpatialRenderer?) { spatialMailbox.post(SpatialBox(spatial)) }`.
- In `prepare`: `spatialEntry = nil; spatialMailbox.reset()`.
- In `render`, next to the effects `take`: `if let s = spatialMailbox.take() { spatialEntry = s; spatialMailbox.acknowledge(s) }`, and after the effects chain render (inside `if let config`):
```swift
            if config.spatialEnabled, let spatial = spatialEntry?.value.renderer {
                spatial.render(left: mixL, right: mixR, frames: frames)
            }
```

`Sources/EquinoxAudio/AudioController.swift`:
- `AudioControlling` gains `func setSpatial(_ parameters: SpatialParameters?)`.
- Add:
```swift
    private var spatial: SpatialRenderer?
    private var spatialParameters: SpatialParameters?

    public func setSpatial(_ parameters: SpatialParameters?) {
        spatialParameters = parameters
        guard let parameters else {
            if spatial != nil { spatial = nil; renderer.submitSpatial(nil) }
            return
        }
        let rate = session?.sampleRate ?? 48_000
        if let spatial, spatial.sampleRate == rate { spatial.set(parameters); return }
        spatial = try? SpatialRenderer(sampleRate: rate, parameters: parameters)
        renderer.submitSpatial(spatial)
    }
```
- In `rebuild()`, right after the effects resubmission line inside the inner `do`:
```swift
                if let params = spatialParameters {
                    if spatial?.sampleRate != newSession.sampleRate {
                        spatial = try? SpatialRenderer(sampleRate: newSession.sampleRate, parameters: params)
                    }
                    renderer.submitSpatial(spatial)
                }
```
- In the device listeners array add:
```swift
                try? PropertyListener(object: deviceID, selector: kAudioDevicePropertyDataSource,
                                      scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    MainActor.assumeIsolated {
                        if let device = try? AudioSystem.describe(deviceID) { self?.onOutputDeviceChange?(device) }
                    }
                },
```

- [ ] **Step 4: Run tests** — `swift test --filter HeadphoneAudioTests`. If `testCentredSignalKeepsLevel` fails only on the level assertion, measure the printed gain and set `SpatialRenderer.makeupGain` to the reciprocal (ledger a ruling with the measured value). Then add `setSpatial` stubs to `FakeAudio` (`var spatial: SpatialParameters?; func setSpatial(_ p: SpatialParameters?) { spatial = p }`) and `PreviewAudio`, and run `swift test` → all PASS.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(audio): HRTF spatial renderer, headphone detection, spatial stage"`

---

### Task 3: AutoEQ catalog, updates, headphone & app-model API

**Files:**
- Create: `Sources/EquinoxCore/AutoEQ.swift`, `Sources/EquinoxCore/Updates.swift`
- Modify: `Sources/EquinoxCore/AppSettings.swift`, `Sources/EquinoxCore/AppModel.swift`
- Test: `Tests/EquinoxCoreTests/AutoEQTests.swift`, `Tests/EquinoxCoreTests/UpdatesTests.swift`, `Tests/EquinoxCoreTests/HeadphoneModelTests.swift`

**Interfaces:**
- Produces:
  - `AutoEQEntry(name:source:rig:path:)` (Hashable, Identifiable), `AutoEQIndex.parse(_:) -> [AutoEQEntry]`, `AutoEQIndex.search(_:query:limit:) -> [AutoEQEntry]`, `AutoEQIndex.profileURL(for:) -> URL?`
  - `protocol DataFetching { func data(from url: URL) async throws -> Data }`, `URLSessionFetching`
  - `protocol AutoEQProviding: AnyObject { func entries() async throws -> [AutoEQEntry]; func profile(for: AutoEQEntry) async throws -> CorrectionProfile }`, `AutoEQCatalog(fetcher:cacheDirectory:maxAge:now:)`
  - `ReleaseInfo(version:downloadURL:pageURL:)`, `UpdateChecker.parseLatest(_:)`, `UpdateChecker.isNewer(_:than:)`, `protocol UpdateProviding { func latestRelease() async throws -> ReleaseInfo }`, `GitHubUpdates(fetcher:)`, `UpdateInstaller.stage(_:fetcher:) async throws -> URL`, `UpdateInstaller.verify(appAt:expectedBundleID:newerThan:) throws`, `UpdateInstaller.relaunchScript(current:replacement:pid:) -> String`, `UpdateInstaller.launchReplacement(current:replacement:)`
  - `HeadphoneSettings` (isEnabled, correction, crossfeed, spatialEnabled, spatial)
  - `AppSettings`: `headphones: [String: HeadphoneSettings]`, `headphoneOverrides: [String: Bool]`, `autoEnableHeadphones = true`, `checkForUpdates = true`, `lastUpdateCheck: Date?`
  - `AppModel(…, autoEQ: AutoEQProviding? = nil, updates: UpdateProviding? = nil)`; `isHeadphoneOutput`, `headphones`, `updateHeadphones(_:)`, `setHeadphoneOverride(_:)`, `autoEnableHeadphones`, `autoEQResults`, `autoEQStatus`, `searchAutoEQ(_:) async`, `applyAutoEQ(_:) async`, `importCorrection(from:name:) throws`, `removeCorrection()`, `availableUpdate`, `updateStatus`, `checkForUpdatesAutomatically`, `checkForUpdates(userInitiated:) async`, `moveEffect(_:to:)`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxCoreTests/AutoEQTests.swift`:
```swift
import XCTest
@testable import EquinoxCore
import EquinoxDSP

final class FakeFetcher: DataFetching, @unchecked Sendable {
    var responses: [String: Data] = [:]
    var requested: [URL] = []
    var offline = false
    func data(from url: URL) async throws -> Data {
        requested.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        guard let d = responses[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return d
    }
}

final class AutoEQTests: XCTestCase {
    let index = """
    # Index
    - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990
    - [Sennheiser HD 650](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20650) by crinacle on GRAS 43AG-7
    - [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045
    - [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro) by crinacle on 711
    - [Evil](./../../etc/passwd) by attacker
    - [Query](./a/b?x=1) by attacker
    """

    func testParsesEntriesIncludingParenthesesInPaths() {
        let entries = AutoEQIndex.parse(index)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1].rig, "GRAS 43AG-7")
        XCTAssertEqual(entries[2].name, "1MORE Aero (ANC Off)")
        XCTAssertEqual(entries[2].path, "./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)")
        XCTAssertNil(entries[0].rig)
    }

    func testRejectsUnsafeIndexPaths() {
        XCTAssertFalse(AutoEQIndex.parse(index).contains { $0.source == "attacker" })
    }

    func testSearchMatchesAllTokensPrefixFirst() {
        let entries = AutoEQIndex.parse(index)
        XCTAssertEqual(AutoEQIndex.search(entries, query: "hd 650").count, 2)
        XCTAssertEqual(AutoEQIndex.search(entries, query: "airpods").first?.name, "Apple AirPods Pro")
        XCTAssertTrue(AutoEQIndex.search(entries, query: "").isEmpty)
    }

    func testProfileURL() {
        let e = AutoEQIndex.parse(index)[0]
        XCTAssertEqual(AutoEQIndex.profileURL(for: e)?.absoluteString,
                       "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20650/Sennheiser%20HD%20650%20ParametricEQ.txt")
    }

    func makeCatalog(_ fetcher: FakeFetcher, dir: URL, now: Date = Date()) -> AutoEQCatalog {
        AutoEQCatalog(fetcher: fetcher, cacheDirectory: dir, maxAge: 7 * 86_400, now: { now })
    }

    func testCatalogCachesIndexAndFetchesProfiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autoeq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = FakeFetcher()
        f.responses[AutoEQCatalog.indexURL.absoluteString] = Data(index.utf8)
        let entry = AutoEQIndex.parse(index)[0]
        f.responses[AutoEQIndex.profileURL(for: entry)!.absoluteString] = Data("Preamp: -6.1 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1".utf8)
        let catalog = makeCatalog(f, dir: dir)
        _ = try await catalog.entries()
        _ = try await catalog.entries()
        XCTAssertEqual(f.requested.filter { $0 == AutoEQCatalog.indexURL }.count, 1)   // cached
        let profile = try await catalog.profile(for: entry)
        XCTAssertEqual(profile.name, "Sennheiser HD 650")
        XCTAssertEqual(profile.source, "oratory1990")
        XCTAssertEqual(profile.bands.count, 1)
    }

    func testOfflineFallsBackToStaleCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autoeq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = FakeFetcher()
        f.responses[AutoEQCatalog.indexURL.absoluteString] = Data(index.utf8)
        _ = try await makeCatalog(f, dir: dir).entries()
        f.offline = true
        let later = makeCatalog(f, dir: dir, now: Date().addingTimeInterval(30 * 86_400))
        let entries = try await later.entries()
        XCTAssertEqual(entries.count, 4)
        let empty = makeCatalog(f, dir: dir.appendingPathComponent("none"))
        do { _ = try await empty.entries(); XCTFail("expected error") } catch {}
    }
}
```

`Tests/EquinoxCoreTests/UpdatesTests.swift`:
```swift
import XCTest
@testable import EquinoxCore

final class UpdatesTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.4.0", than: "0.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.3", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "0.3.0"))
    }

    func testParsesLatestReleaseJSON() throws {
        let json = #"{"tag_name":"v0.5.0","html_url":"https://github.com/north-built-labs/equinox/releases/tag/v0.5.0","assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt"},{"name":"Equinox-macos.zip","browser_download_url":"https://github.com/north-built-labs/equinox/releases/download/v0.5.0/Equinox-macos.zip"}]}"#
        let r = try UpdateChecker.parseLatest(Data(json.utf8))
        XCTAssertEqual(r.version, "0.5.0")
        XCTAssertEqual(r.downloadURL.lastPathComponent, "Equinox-macos.zip")
        XCTAssertThrowsError(try UpdateChecker.parseLatest(Data(#"{"tag_name":"v1","assets":[]}"#.utf8)))
    }

    func makeApp(_ dir: URL, bundleID: String, version: String) throws -> URL {
        let app = dir.appendingPathComponent("Equinox.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        return dir.appendingPathComponent("Equinox.app")
    }

    func testInstallerRefusesForeignBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try makeApp(dir.appendingPathComponent("a"), bundleID: "com.northbuiltlabs.equinox", version: "0.5.0")
        XCTAssertNoThrow(try UpdateInstaller.verify(appAt: good, expectedBundleID: "com.northbuiltlabs.equinox", newerThan: "0.4.0"))
        let foreign = try makeApp(dir.appendingPathComponent("b"), bundleID: "com.evil.app", version: "9.0.0")
        XCTAssertThrowsError(try UpdateInstaller.verify(appAt: foreign, expectedBundleID: "com.northbuiltlabs.equinox", newerThan: "0.4.0"))
        let old = try makeApp(dir.appendingPathComponent("c"), bundleID: "com.northbuiltlabs.equinox", version: "0.4.0")
        XCTAssertThrowsError(try UpdateInstaller.verify(appAt: old, expectedBundleID: "com.northbuiltlabs.equinox", newerThan: "0.4.0"))
    }

    func testScriptReplacesOnlyAfterExit() {
        let s = UpdateInstaller.relaunchScript(current: URL(fileURLWithPath: "/Applications/Equinox.app"),
                                               replacement: URL(fileURLWithPath: "/tmp/x/Equinox.app"), pid: 4242)
        let wait = s.range(of: "kill -0 4242")!, remove = s.range(of: "mv '/Applications/Equinox.app'")!
        XCTAssertLessThan(wait.lowerBound, remove.lowerBound)
        XCTAssertTrue(s.contains("'/Applications/Equinox.app'"))
        XCTAssertTrue(s.contains("open '/Applications/Equinox.app'"))
    }
}
```

`Tests/EquinoxCoreTests/HeadphoneModelTests.swift`:
```swift
import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

final class FakeAutoEQ: AutoEQProviding {
    var list: [AutoEQEntry] = [AutoEQEntry(name: "Apple AirPods Pro", source: "crinacle", rig: "711", path: "./crinacle/711%20in-ear/Apple%20AirPods%20Pro")]
    var fail = false
    func entries() async throws -> [AutoEQEntry] { if fail { throw URLError(.notConnectedToInternet) }; return list }
    func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile {
        CorrectionProfile(name: entry.name, source: entry.source, preampDB: -4, bands: [EQBand(type: .peak, frequency: 3000, gainDB: 4, q: 2)])
    }
}

final class FakeUpdates: UpdateProviding {
    var release = ReleaseInfo(version: "9.9.9", downloadURL: URL(string: "https://example.com/Equinox-macos.zip")!,
                              pageURL: URL(string: "https://example.com")!)
    func latestRelease() async throws -> ReleaseInfo { release }
}

@MainActor
final class HeadphoneModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!
    let airpods = AudioDevice(id: 7, uid: "airpods", name: "AirPods Pro", transportType: 0, isHeadphones: true)
    let speakers = AudioDevice(id: 1, uid: "builtin", name: "MacBook Speakers", transportType: 0, isHeadphones: false)
    let jack = AudioDevice(id: 1, uid: "builtin", name: "MacBook Speakers", transportType: 0, isHeadphones: true)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-hp-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel(autoEQ: AutoEQProviding = FakeAutoEQ(), updates: UpdateProviding = FakeUpdates()) -> AppModel {
        AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem(), autoEQ: autoEQ, updates: updates,
                 currentVersion: "0.4.0")
    }

    func testNewHeadphonesAutoEnableTheLayer() {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        XCTAssertTrue(m.isHeadphoneOutput)
        XCTAssertTrue(m.headphones.isEnabled)
        audio.onOutputDeviceChange?(speakers)
        XCTAssertFalse(m.headphones.isEnabled)
    }

    func testApplyingAutoEQPushesCorrection() async {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        await m.searchAutoEQ("airpods")
        XCTAssertEqual(m.autoEQResults.count, 1)
        await m.applyAutoEQ(m.autoEQResults[0])
        XCTAssertEqual(audio.applied.last?.correction?.name, "Apple AirPods Pro")
        m.updateHeadphones { $0.isEnabled = false }
        XCTAssertNil(audio.applied.last?.correction)
    }

    func testSearchFailureIsReported() async {
        let fake = FakeAutoEQ(); fake.fail = true
        let m = makeModel(autoEQ: fake)
        await m.searchAutoEQ("hd 650")
        XCTAssertTrue(m.autoEQResults.isEmpty)
        XCTAssertNotNil(m.autoEQStatus)
    }

    func testImportParametricText() throws {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        try m.importCorrection(from: Data("Preamp: -2 dB\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1".utf8), name: "Mine")
        XCTAssertEqual(audio.applied.last?.correction?.preampDB, -2)
        XCTAssertThrowsError(try m.importCorrection(from: Data("nope".utf8), name: "Bad"))
        m.removeCorrection()
        XCTAssertNil(audio.applied.last?.correction)
    }

    func testSpatialSupersedesCrossfeed() {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        m.updateHeadphones { $0.crossfeed = .high }
        XCTAssertEqual(audio.applied.last?.crossfeed, .high)
        XCTAssertNil(audio.spatial)
        m.updateHeadphones { $0.spatialEnabled = true; $0.spatial.width = 45 }
        XCTAssertEqual(audio.applied.last?.spatialEnabled, true)
        XCTAssertEqual(audio.applied.last?.crossfeed, .off)
        XCTAssertEqual(audio.spatial?.width, 45)
    }

    func testJackAndSpeakersKeepSeparateSettings() {
        let m = makeModel()
        audio.onOutputDeviceChange?(jack)
        m.updateHeadphones { $0.crossfeed = .medium }
        audio.onOutputDeviceChange?(speakers)            // same UID, jack unplugged
        XCTAssertEqual(m.headphones.crossfeed, .off)
        XCTAssertEqual(audio.applied.last?.crossfeed, .off)
        audio.onOutputDeviceChange?(jack)
        XCTAssertEqual(m.headphones.crossfeed, .medium)
    }

    func testOverrideTreatsSpeakerAsHeadphones() {
        let m = makeModel()
        audio.onOutputDeviceChange?(speakers)
        m.setHeadphoneOverride(true)
        XCTAssertTrue(m.isHeadphoneOutput)
        m.updateHeadphones { $0.isEnabled = true; $0.crossfeed = .low }
        XCTAssertEqual(audio.applied.last?.crossfeed, .low)
    }

    func testHeadphoneSettingsPersist() {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        m.updateHeadphones { $0.crossfeed = .high }
        m.flushSave()
        let m2 = makeModel()
        audio.onOutputDeviceChange?(airpods)
        XCTAssertEqual(m2.headphones.crossfeed, .high)
    }

    func testUpdateCheckFindsNewerRelease() async {
        let m = makeModel()
        await m.checkForUpdates(userInitiated: true)
        XCTAssertEqual(m.availableUpdate?.version, "9.9.9")
        let current = FakeUpdates(); current.release = ReleaseInfo(version: "0.0.1", downloadURL: current.release.downloadURL, pageURL: current.release.pageURL)
        let m2 = makeModel(updates: current)
        await m2.checkForUpdates(userInitiated: true)
        XCTAssertNil(m2.availableUpdate)
        XCTAssertNotNil(m2.updateStatus)
    }

    func testMoveEffectToIndex() {
        let m = makeModel()
        let a = m.addEffect(.builtIn(.reverb)), b = m.addEffect(.builtIn(.delay)), c = m.addEffect(.builtIn(.limiter))
        m.moveEffect(c, to: 0)
        XCTAssertEqual(m.working.effects.map(\.id), [c, a, b])
        m.moveEffect(c, to: 99)
        XCTAssertEqual(m.working.effects.map(\.id), [a, b, c])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail** — `swift test --filter "AutoEQTests|UpdatesTests|HeadphoneModelTests"` → compile failure `cannot find type 'DataFetching'`.

- [ ] **Step 3: AutoEQ**

`Sources/EquinoxCore/AutoEQ.swift`:
```swift
import EquinoxDSP
import Foundation

public protocol DataFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionFetching: DataFetching {
    public init() {}
    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct AutoEQEntry: Hashable, Identifiable, Sendable {
    public let name: String
    public let source: String
    public let rig: String?
    /// Percent-encoded relative path from the AutoEq results directory, e.g. "./oratory1990/over-ear/Sennheiser%20HD%20650".
    public let path: String
    public var id: String { path }

    public init(name: String, source: String, rig: String?, path: String) {
        self.name = name; self.source = source; self.rig = rig; self.path = path
    }
}

public enum AutoEQIndex {
    static let resultsBase = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    /// Parses AutoEq's results/INDEX.md: `- [Name](./path) by Source[ on Rig]`. Paths may contain parentheses.
    public static func parse(_ markdown: String) -> [AutoEQEntry] {
        markdown.split(whereSeparator: \.isNewline).compactMap { raw -> AutoEQEntry? in
            let line = String(raw)
            guard line.hasPrefix("- ["), let nameEnd = line.range(of: "](./") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<nameEnd.lowerBound])
            let pathStart = line.index(nameEnd.lowerBound, offsetBy: 2)
            guard let by = line.range(of: ") by ", range: pathStart..<line.endIndex) else { return nil }
            let path = String(line[pathStart..<by.lowerBound])
            guard isSafe(path), !name.isEmpty else { return nil }
            let attribution = String(line[by.upperBound...])
            let parts = attribution.components(separatedBy: " on ")
            return AutoEQEntry(name: name, source: parts[0], rig: parts.count > 1 ? parts[1...].joined(separator: " on ") : nil,
                               path: path)
        }
    }

    static func isSafe(_ path: String) -> Bool {
        path.hasPrefix("./") && !path.contains("..") && !path.contains("?") && !path.contains("#") && !path.contains("://")
    }

    /// Entries whose name contains every whitespace-separated token; names starting with the query first.
    public static func search(_ entries: [AutoEQEntry], query: String, limit: Int = 60) -> [AutoEQEntry] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let q = query.lowercased()
        return entries
            .filter { e in let n = e.name.lowercased(); return tokens.allSatisfy { n.contains($0) } }
            .sorted { a, b in
                let pa = a.name.lowercased().hasPrefix(q), pb = b.name.lowercased().hasPrefix(q)
                return pa != pb ? pa : (a.name.count, a.name, a.source) < (b.name.count, b.name, b.source)
            }
            .prefix(limit).map { $0 }
    }

    public static func profileURL(for entry: AutoEQEntry) -> URL? {
        guard isSafe(entry.path), let folder = entry.path.split(separator: "/").last else { return nil }
        return URL(string: resultsBase + entry.path.dropFirst(2) + "/" + folder + "%20ParametricEQ.txt")
    }
}

public protocol AutoEQProviding: AnyObject {
    func entries() async throws -> [AutoEQEntry]
    func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile
}

/// Downloads AutoEq's index (cached on disk, refreshed weekly, stale copy used offline) and profiles.
public final class AutoEQCatalog: AutoEQProviding, @unchecked Sendable {
    public static let indexURL = URL(string: AutoEQIndex.resultsBase + "INDEX.md")!

    private let fetcher: DataFetching
    private let cacheFile: URL
    private let maxAge: TimeInterval
    private let now: () -> Date
    private var memory: [AutoEQEntry]?

    public init(fetcher: DataFetching = URLSessionFetching(), cacheDirectory: URL = Store.defaultDirectory,
                maxAge: TimeInterval = 7 * 86_400, now: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        cacheFile = cacheDirectory.appendingPathComponent("autoeq-index.md")
        self.maxAge = maxAge
        self.now = now
    }

    public func entries() async throws -> [AutoEQEntry] {
        if let memory { return memory }
        let cached = try? String(contentsOf: cacheFile, encoding: .utf8)
        let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached, let modified, now().timeIntervalSince(modified) < maxAge {
            memory = AutoEQIndex.parse(cached)
            return memory!
        }
        do {
            let data = try await fetcher.data(from: Self.indexURL)
            guard data.count < 20_000_000, let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            let parsed = AutoEQIndex.parse(text)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            memory = parsed
            return parsed
        } catch {
            if let cached { memory = AutoEQIndex.parse(cached); return memory! }
            throw error
        }
    }

    public func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile {
        guard let url = AutoEQIndex.profileURL(for: entry) else { throw URLError(.badURL) }
        let data = try await fetcher.data(from: url)
        guard data.count < 200_000, let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try ParametricEQText.parse(text, name: entry.name, source: entry.source)
    }
}
```

- [ ] **Step 4: Updates**

`Sources/EquinoxCore/Updates.swift`:
```swift
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let pageURL: URL
    public init(version: String, downloadURL: URL, pageURL: URL) {
        self.version = version; self.downloadURL = downloadURL; self.pageURL = pageURL
    }
}

public enum UpdateError: Error, Equatable { case noAsset, notEquinox, notNewer, badArchive }

public enum UpdateChecker {
    public static let assetName = "Equinox-macos.zip"
    public static let latestURL = URL(string: "https://api.github.com/repos/north-built-labs/equinox/releases/latest")!

    public static func parseLatest(_ json: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let html_url: URL?; let assets: [Asset] }
        let r = try JSONDecoder().decode(Release.self, from: json)
        guard let asset = r.assets.first(where: { $0.name == assetName }) else { throw UpdateError.noAsset }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return ReleaseInfo(version: version, downloadURL: asset.browser_download_url,
                           pageURL: r.html_url ?? URL(string: "https://github.com/north-built-labs/equinox/releases")!)
    }

    static func components(_ v: String) -> [Int]? {
        let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    public static func isNewer(_ remote: String, than local: String) -> Bool {
        guard var r = components(remote), var l = components(local) else { return false }
        let n = max(r.count, l.count)
        r += Array(repeating: 0, count: n - r.count); l += Array(repeating: 0, count: n - l.count)
        return r.lexicographicallyPrecedes(l) == false && r != l
    }
}

public protocol UpdateProviding: AnyObject {
    func latestRelease() async throws -> ReleaseInfo
}

public final class GitHubUpdates: UpdateProviding, @unchecked Sendable {
    private let fetcher: DataFetching
    public init(fetcher: DataFetching = URLSessionFetching()) { self.fetcher = fetcher }
    public func latestRelease() async throws -> ReleaseInfo {
        try UpdateChecker.parseLatest(try await fetcher.data(from: UpdateChecker.latestURL))
    }
}

public enum UpdateInstaller {
    /// Downloads and unpacks the release; returns the staged Equinox.app (not yet verified).
    public static func stage(_ release: ReleaseInfo, fetcher: DataFetching = URLSessionFetching()) async throws -> URL {
        let data = try await fetcher.data(from: release.downloadURL)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(UpdateChecker.assetName)
        try data.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run(); unzip.waitUntilExit()
        let app = dir.appendingPathComponent("Equinox.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.badArchive }
        return app
    }

    /// The staged app must be Equinox and newer than what's running.
    public static func verify(appAt app: URL, expectedBundleID: String, newerThan current: String) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == expectedBundleID else { throw UpdateError.notEquinox }
        guard let version = plist["CFBundleShortVersionString"] as? String,
              UpdateChecker.isNewer(version, than: current) else { throw UpdateError.notNewer }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Waits for Equinox (pid) to exit, swaps the bundle, clears quarantine, relaunches.
    public static func relaunchScript(current: URL, replacement: URL, pid: Int32) -> String {
        let cur = quote(current.path), new = quote(replacement.path)
        return """
        #!/bin/sh
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        rm -rf \(cur).old
        if mv \(cur) \(cur).old; then
          if ditto \(new) \(cur); then rm -rf \(cur).old; else rm -rf \(cur); mv \(cur).old \(cur); fi
        fi
        xattr -dr com.apple.quarantine \(cur) 2>/dev/null
        open \(cur)
        """
    }

    /// Starts the detached swap script; the caller then terminates the app.
    public static func launchReplacement(current: URL, replacement: URL) throws {
        let script = replacement.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try relaunchScript(current: current, replacement: replacement, pid: ProcessInfo.processInfo.processIdentifier)
            .write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh \(quote(script.path)) >/dev/null 2>&1 &"]
        try p.run()
    }
}
```

- [ ] **Step 5: Settings and model**

`Sources/EquinoxCore/AppSettings.swift`: add before `AppSettings`:
```swift
public struct HeadphoneSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var correction: CorrectionProfile?
    public var crossfeed: CrossfeedStrength = .off
    public var spatialEnabled = false
    public var spatial = SpatialParameters()

    public init(isEnabled: Bool = false) { self.isEnabled = isEnabled }

    enum CodingKeys: String, CodingKey { case isEnabled, correction, crossfeed, spatialEnabled, spatial }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        correction = try? c.decodeIfPresent(CorrectionProfile.self, forKey: .correction)
        crossfeed = (try? c.decodeIfPresent(CrossfeedStrength.self, forKey: .crossfeed)) ?? .off
        spatialEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .spatialEnabled)) ?? false
        spatial = (try? c.decodeIfPresent(SpatialParameters.self, forKey: .spatial)) ?? SpatialParameters()
    }
}
```
(`import EquinoxAudio` and `import EquinoxDSP` at the top.) In `AppSettings` add fields `headphones: [String: HeadphoneSettings] = [:]`, `headphoneOverrides: [String: Bool] = [:]`, `autoEnableHeadphones = true`, `checkForUpdates = true`, `lastUpdateCheck: Date?`, their `CodingKeys`, and decoding:
```swift
        let hp = (try? c.decodeIfPresent([String: Lossy<HeadphoneSettings>].self, forKey: .headphones)) ?? [:]
        headphones = hp.compactMapValues(\.value)
        headphoneOverrides = (try? c.decodeIfPresent([String: Bool].self, forKey: .headphoneOverrides)) ?? [:]
        autoEnableHeadphones = (try? c.decodeIfPresent(Bool.self, forKey: .autoEnableHeadphones)) ?? true
        checkForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? true
        lastUpdateCheck = try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
```

`Sources/EquinoxCore/AppModel.swift`:
- Init signature adds `autoEQ: AutoEQProviding? = nil, updates: UpdateProviding? = nil, currentVersion: String = AppModel.bundleVersion` (after `crashedPlugins`); assign `self.currentVersion = currentVersion`; store as `@ObservationIgnored private let autoEQ: AutoEQProviding` = `autoEQ ?? AutoEQCatalog(cacheDirectory: store.directory)` and `updates ?? GitHubUpdates()`. Restore `headphoneSettings = s.headphones`, `headphoneOverrides = s.headphoneOverrides`, `autoEnableHeadphones = s.autoEnableHeadphones`, `checkForUpdatesAutomatically = s.checkForUpdates`, `lastUpdateCheck = s.lastUpdateCheck` with the other restores.
- New state:
```swift
    // MARK: Headphones
    public private(set) var headphoneSettings: [String: HeadphoneSettings] = [:]
    public private(set) var headphoneOverrides: [String: Bool] = [:]
    public var autoEnableHeadphones = true { didSet { if !restoring { scheduleSave() } } }
    public private(set) var autoEQResults: [AutoEQEntry] = []
    public private(set) var autoEQStatus: String?
    public private(set) var isApplyingAutoEQ = false

    // MARK: Updates
    public private(set) var availableUpdate: ReleaseInfo?
    public private(set) var updateStatus: String?
    public var checkForUpdatesAutomatically = true { didSet { if !restoring { scheduleSave() } } }
    @ObservationIgnored private var lastUpdateCheck: Date?
    public let currentVersion: String
    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
```
- API:
```swift
    public var isHeadphoneOutput: Bool {
        guard let d = currentDevice else { return false }
        return headphoneOverrides[d.uid] ?? d.isHeadphones
    }

    /// Settings key: the jack and the speakers of the built-in output share a UID, so they are kept apart.
    private var headphoneKey: String? {
        currentDevice.map { $0.uid + (isHeadphoneOutput ? "#headphones" : "#speakers") }
    }

    public var headphones: HeadphoneSettings { headphoneKey.flatMap { headphoneSettings[$0] } ?? HeadphoneSettings() }

    public func updateHeadphones(_ change: (inout HeadphoneSettings) -> Void) {
        guard let key = headphoneKey else { return }
        var s = headphoneSettings[key] ?? HeadphoneSettings()
        change(&s)
        s.spatial.width = min(max(s.spatial.width, SpatialParameters.widthRange.lowerBound), SpatialParameters.widthRange.upperBound)
        s.spatial.room = min(max(s.spatial.room, 0), 1)
        headphoneSettings[key] = s
        push()
    }

    public func setHeadphoneOverride(_ value: Bool?) {
        guard let uid = currentDevice?.uid else { return }
        headphoneOverrides[uid] = value
        ensureHeadphoneDefaults()
        push()
    }

    private func ensureHeadphoneDefaults() {
        guard let key = headphoneKey, headphoneSettings[key] == nil, isHeadphoneOutput, autoEnableHeadphones else { return }
        headphoneSettings[key] = HeadphoneSettings(isEnabled: true)
    }

    public func searchAutoEQ(_ query: String) async {
        autoEQStatus = nil
        do {
            autoEQResults = AutoEQIndex.search(try await autoEQ.entries(), query: query)
            if autoEQResults.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty { autoEQStatus = "No matches." }
        } catch {
            autoEQResults = []
            autoEQStatus = "Couldn't load the AutoEq database. Check your connection and try again."
        }
    }

    public func applyAutoEQ(_ entry: AutoEQEntry) async {
        isApplyingAutoEQ = true
        defer { isApplyingAutoEQ = false }
        do {
            let profile = try await autoEQ.profile(for: entry)
            updateHeadphones { $0.correction = profile; $0.isEnabled = true }
            autoEQStatus = nil
        } catch {
            autoEQStatus = "Couldn't download that profile."
        }
    }

    public func importCorrection(from data: Data, name: String) throws {
        guard data.count < 200_000, let text = String(data: data, encoding: .utf8) else { throw ParametricEQText.ParseError.noFilters }
        let profile = try ParametricEQText.parse(text, name: name, source: "Imported")
        updateHeadphones { $0.correction = profile; $0.isEnabled = true }
    }

    public func removeCorrection() { updateHeadphones { $0.correction = nil } }

    public func checkForUpdates(userInitiated: Bool) async {
        if !userInitiated {
            guard checkForUpdatesAutomatically else { return }
            if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        }
        do {
            let release = try await updates.latestRelease()
            lastUpdateCheck = Date()
            if UpdateChecker.isNewer(release.version, than: currentVersion) {
                availableUpdate = release
                updateStatus = "Equinox \(release.version) is available."
            } else {
                availableUpdate = nil
                updateStatus = "Equinox is up to date."
            }
            scheduleSave()
        } catch {
            if userInitiated { updateStatus = "Couldn't check for updates." }
        }
    }

    public func moveEffect(_ id: UUID, to index: Int) {
        guard let i = working.effects.firstIndex(where: { $0.id == id }) else { return }
        let slot = working.effects.remove(at: i)
        working.effects.insert(slot, at: min(max(index, 0), working.effects.count))
        push()
    }
```
- In `outputDeviceChanged(_:)`, replace `guard device.uid != currentDevice?.uid else { push(); return }` with:
```swift
        guard device.uid != currentDevice?.uid else {
            currentDevice = device          // e.g. built-in output switched between speakers and the jack
            ensureHeadphoneDefaults()
            push()
            return
        }
```
  and after `currentDevice = device` add `ensureHeadphoneDefaults()`.
- In `push()`, before `audio.apply(s)`:
```swift
        let hp = headphones
        let layer = hp.isEnabled
        s.correction = layer ? hp.correction : nil
        s.crossfeed = layer && !hp.spatialEnabled ? hp.crossfeed : .off
        s.spatialEnabled = layer && hp.spatialEnabled
```
  and after it: `audio.setSpatial(s.spatialEnabled && isEnabled ? hp.spatial : nil)`.
- In `launch()`, after starting audio: `Task { await checkForUpdates(userInitiated: false) }`.
- In `flushSave()` add `s.headphones = headphoneSettings`, `s.headphoneOverrides = headphoneOverrides`, `s.autoEnableHeadphones = autoEnableHeadphones`, `s.checkForUpdates = checkForUpdatesAutomatically`, `s.lastUpdateCheck = lastUpdateCheck`.

- [ ] **Step 6: Run tests** — `swift test --filter "AutoEQTests|UpdatesTests|HeadphoneModelTests"` → all PASS; `swift test` → all PASS.

- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat(core): AutoEQ catalog, in-app updates, per-device headphone layer"`

---

### Task 4: Headphones page, updates UI, effects polish, checks, ship v0.4.0

**Files:**
- Create: `Sources/Equinox/HeadphonesViews.swift`
- Modify: `Sources/Equinox/MainWindow.swift`, `Sources/Equinox/EffectsViews.swift`, `Sources/Equinox/Diagnostics/SelfTest.swift`, `Sources/Equinox/Diagnostics/Snapshots.swift`, `Resources/Info.plist`, `README.md`

- [ ] **Step 1: Headphones page**

`Sources/Equinox/HeadphonesViews.swift`:
```swift
import AppKit
import EquinoxAudio
import EquinoxCore
import EquinoxDSP
import SwiftUI
import UniformTypeIdentifiers

struct HeadphonesPage: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var importError: String?

    var body: some View {
        let hp = model.headphones
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: model.isHeadphoneOutput ? "headphones" : "hifispeaker.fill")
                    .font(.system(size: 26)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headphones").font(.system(.title2, design: .rounded).weight(.bold))
                    Text(model.currentDevice.map { "\($0.name) · \(model.isHeadphoneOutput ? "headphones" : "speakers")" } ?? "No output")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Headphone features", isOn: Binding(get: { hp.isEnabled }, set: { v in model.updateHeadphones { $0.isEnabled = v } }))
                    .toggleStyle(.switch).tint(Theme.cyan)
            }
            HStack(spacing: 14) {
                Toggle("Treat this output as headphones", isOn: Binding(
                    get: { model.isHeadphoneOutput }, set: { model.setHeadphoneOverride($0) }))
                Toggle("Turn on automatically for new headphones", isOn: $model.autoEnableHeadphones)
            }
            .font(.caption).toggleStyle(.checkbox)

            correctionCard(hp).opacity(hp.isEnabled ? 1 : 0.55)
            HStack(alignment: .top, spacing: 16) {
                crossfeedCard(hp)
                spatialCard(hp)
            }
            .opacity(hp.isEnabled ? 1 : 0.55)
        }
        .padding(24)
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    @ViewBuilder private func correctionCard(_ hp: HeadphoneSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Correction").font(.headline)
                Text("AutoEq").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.violet.opacity(0.3)))
                Spacer()
                Button("Import ParametricEQ.txt…", action: importFile).controlSize(.small)
            }
            if let c = hp.correction {
                HStack(spacing: 12) {
                    CorrectionCurve(profile: c, sampleRate: model.sampleRate).frame(height: 70)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(.system(size: 13, weight: .semibold))
                        Text("\(c.source) · \(c.bands.count) filters · preamp \(String(format: "%+.1f", c.preampDB)) dB")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { model.removeCorrection() }.controlSize(.small)
                    }
                    .frame(width: 230, alignment: .leading)
                }
            } else {
                Text("Flatten your headphones' frequency response with a measured correction from the AutoEq database (thousands of models).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search headphones, e.g. AirPods Pro, HD 650", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.searchAutoEQ(query) } }
                if model.isApplyingAutoEQ { ProgressView().controlSize(.small) }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            .onChange(of: query) { _, q in
                Task { try? await Task.sleep(for: .milliseconds(300)); if q == query { await model.searchAutoEQ(q) } }
            }
            if let status = model.autoEQStatus { Text(status).font(.caption).foregroundStyle(Theme.amber) }
            if !model.autoEQResults.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.autoEQResults) { e in
                            Button { Task { await model.applyAutoEQ(e) } } label: {
                                HStack {
                                    Text(e.name).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(e.rig.map { "\(e.source) · \($0)" } ?? e.source).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(hp.correction?.name == e.name && hp.correction?.source == e.source ? Theme.cyan.opacity(0.18) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func crossfeedCard(_ hp: HeadphoneSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crossfeed").font(.headline)
            Picker("", selection: Binding(get: { hp.crossfeed }, set: { v in model.updateHeadphones { $0.crossfeed = v } })) {
                ForEach(CrossfeedStrength.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(hp.spatialEnabled)
            Text(hp.spatialEnabled ? "Off while Spatial audio is on." :
                 "Blends a little of each side's bass into the other ear, like speakers in a room. Centred sound is untouched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func spatialCard(_ hp: HeadphoneSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spatial audio").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { hp.spatialEnabled }, set: { v in model.updateHeadphones { $0.spatialEnabled = v } }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.cyan)
            }
            slider("Width", value: hp.spatial.width, range: SpatialParameters.widthRange, format: "%.0f°") { v in
                model.updateHeadphones { $0.spatial.width = v }
            }
            slider("Room", value: hp.spatial.room * 100, range: 0...100, format: "%.0f%%") { v in
                model.updateHeadphones { $0.spatial.room = v / 100 }
            }
            Text("Places your stereo on two virtual speakers in front of you (HRTF).").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, format: String,
                        set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range).tint(Theme.violet)
            Text(String(format: format, value)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.importCorrection(from: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ParametricEQ", with: "")) }
        catch { importError = "That file isn't a ParametricEQ.txt profile." }
    }
}

/// Small response plot of a correction profile.
struct CorrectionCurve: View {
    let profile: CorrectionProfile
    let sampleRate: Double

    var body: some View {
        Canvas { ctx, size in
            let g = EQGeometry(size: size)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                       with: .color(.white.opacity(0.12)))
            var p = Path()
            for i in 0...120 {
                let x = size.width * CGFloat(i) / 120
                let db = EQResponse.decibels(bands: profile.bands, preampDB: 0, frequency: g.frequency(atX: x), sampleRate: sampleRate)
                let y = size.height / 2 - CGFloat(max(min(db, 12), -12) / 12) * size.height / 2
                i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(p, with: .linearGradient(Gradient(colors: [Theme.cyan, Theme.violet]), startPoint: .zero,
                                                endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 2)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
    }
}
```

`Sources/Equinox/MainWindow.swift`:
- `Page`: add `case headphones = "Headphones"` after `effects`, icon `"headphones"`, and `case .headphones: HeadphonesPage(model: model)` in the detail switch.
- `SettingsPage`: add an Updates card after General:
```swift
            VStack(alignment: .leading, spacing: 10) {
                Text("Updates").font(.headline)
                Text("You have Equinox \(model.currentVersion).").font(.callout)
                Toggle("Check for updates automatically", isOn: $model.checkForUpdatesAutomatically)
                HStack {
                    Button("Check Now") { Task { await model.checkForUpdates(userInitiated: true) } }
                    if let release = model.availableUpdate {
                        Button("Install \(release.version) & Relaunch") { Task { await install(release) } }
                            .keyboardShortcut(.defaultAction)
                        Link("Release notes", destination: release.pageURL).font(.caption)
                    }
                }
                if let status = model.updateStatus ?? updateError { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard()
```
  with `@State private var updateError: String?` and:
```swift
    private func install(_ release: ReleaseInfo) async {
        do {
            let staged = try await UpdateInstaller.stage(release)
            try UpdateInstaller.verify(appAt: staged, expectedBundleID: Bundle.main.bundleIdentifier ?? "com.northbuiltlabs.equinox",
                                       newerThan: model.currentVersion)
            try UpdateInstaller.launchReplacement(current: Bundle.main.bundleURL, replacement: staged)
            model.flushSave()
            NSApp.terminate(nil)
        } catch {
            updateError = "The update couldn't be installed. You can download it from GitHub instead."
        }
    }
```

- [ ] **Step 2: Effects polish (spec drift)**

In `Sources/Equinox/EffectsViews.swift`:
- `GenericParameterView`: wrap the `ForEach` in a `VStack` preceded by a factory-preset menu:
```swift
                if let presets = unit.factoryPresets, !presets.isEmpty {
                    Menu("Preset: \(unit.currentPreset?.name ?? "Custom")") {
                        ForEach(presets, id: \.number) { p in Button(p.name) { unit.currentPreset = p; refresh += 1 } }
                    }
                    .menuStyle(.button).controlSize(.small)
                }
```
  with `@State private var refresh = 0` on `GenericParameterView` and `.id(refresh)` on the parameter `VStack` so rows re-read values after a preset change.
- `EffectsPage`: on each `EffectCard` add drag and drop:
```swift
                            EffectCard(model: model, slot: slot, index: index, count: model.working.effects.count)
                                .draggable(slot.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                                    model.moveEffect(id, to: index)
                                    return true
                                }
```
  and change the page caption to "…in order from left to right (drag to reorder)…".

- [ ] **Step 3: Live checks, snapshots, version**

`Sources/Equinox/Diagnostics/SelfTest.swift`: insert `await headphoneChecks(flat: flat)` after `await effectsChecks(flat: flat)` and add:
```swift
    /// Correction stacks with the user EQ, crossfeed leaves the centred tone unchanged, spatial renders.
    private func headphoneChecks(flat: Double) async {
        var s = DSPSettings()
        s.correction = CorrectionProfile(name: "test", source: "self-test", preampDB: 0,
                                         bands: [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)])
        let corrected = await measure(s)
        s.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)]
        let stacked = await measure(s)
        check("headphones: correction +6 dB, stacks with EQ to +12 dB",
              abs(corrected - flat - 6) < 0.5 && abs(stacked - flat - 12) < 0.5,
              "Δ \(fmt(corrected - flat)) / \(fmt(stacked - flat)) dB")

        var cf = DSPSettings(); cf.crossfeed = .high
        let crossfed = await measure(cf)
        check("headphones: crossfeed keeps centred audio unchanged", abs(crossfed - flat) < 0.3, "Δ \(fmt(crossfed - flat)) dB")

        var sp = DSPSettings(); sp.spatialEnabled = true
        audio.setSpatial(SpatialParameters(room: 0))
        let spatial = await measure(sp)
        check("headphones: spatial renders at a sane level", abs(spatial - flat) < 6, "Δ \(fmt(spatial - flat)) dB")
        audio.setSpatial(nil)
    }
```
  and lengthen the first tone to `seconds: 70`.

`Sources/Equinox/Diagnostics/Snapshots.swift`:
- `PreviewAudio`: add `func setSpatial(_ p: SpatialParameters?) {}` and make the first preview device `AudioDevice(id: 1, uid: "airpods", name: "AirPods Pro", transportType: 0, isHeadphones: true)`.
- Add a preview AutoEQ provider and pass it (and a preview updates provider returning version "0.5.0") into the preview `AppModel`:
```swift
final class PreviewAutoEQ: AutoEQProviding {
    func entries() async throws -> [AutoEQEntry] {
        [AutoEQEntry(name: "Apple AirPods Pro", source: "crinacle", rig: "711", path: "./crinacle/711%20in-ear/Apple%20AirPods%20Pro"),
         AutoEQEntry(name: "Apple AirPods Pro", source: "Super Review", rig: nil, path: "./Super%20Review/in-ear/Apple%20AirPods%20Pro"),
         AutoEQEntry(name: "Apple AirPods Pro 2", source: "crinacle", rig: "711", path: "./crinacle/711%20in-ear/Apple%20AirPods%20Pro%202")]
    }
    func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile {
        CorrectionProfile(name: entry.name, source: entry.source, preampDB: -5.2, bands: [
            EQBand(type: .lowShelf, frequency: 105, gainDB: 3.5, q: 0.7), EQBand(type: .peak, frequency: 2800, gainDB: -4, q: 1.8),
            EQBand(type: .peak, frequency: 6200, gainDB: 5, q: 2.5), EQBand(type: .highShelf, frequency: 10000, gainDB: -2, q: 0.7)])
    }
}

final class PreviewUpdates: UpdateProviding {
    func latestRelease() async throws -> ReleaseInfo {
        ReleaseInfo(version: "0.5.0", downloadURL: URL(string: "https://github.com/north-built-labs/equinox/releases/download/v0.5.0/Equinox-macos.zip")!,
                    pageURL: URL(string: "https://github.com/north-built-labs/equinox/releases")!)
    }
}
```
- After the effects setup, run async model calls synchronously by spinning the run loop:
```swift
            func await_(_ work: @escaping @MainActor () async -> Void) {
                var done = false
                Task { @MainActor in await work(); done = true }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            }
            await_ { await model.searchAutoEQ("airpods pro") }
            await_ { await model.applyAutoEQ(model.autoEQResults[0]) }
            model.updateHeadphones { $0.crossfeed = .medium }
            await_ { await model.checkForUpdates(userInitiated: true) }
            save("headphones", HeadphonesPage(model: model).frame(width: 900).background(bg), dir)
```
  (the existing `settings` snapshot now shows the update card).

`Resources/Info.plist`: `CFBundleShortVersionString` 0.4.0, `CFBundleVersion` 4.

- [ ] **Step 4: Build, test, live run, review screenshots**

Run: `swift test` → 0 failures. `scripts/self-test.sh <dir>` → all PASS (26 + 3). Review `headphones.png`, `settings.png`, `effects.png`; copy `headphones.png` into `docs/images/`.

- [ ] **Step 5: README**

In `README.md`: add a fifth feature row — a two-column row with `docs/images/headphones.png` ("Made for headphones": AutoEq correction for thousands of models, crossfeed, HRTF spatial audio, per-device, automatic on headphones) and a short "Stays up to date" cell (checks GitHub releases, one-click install & relaunch); tick the Headphones roadmap item and replace "Notarized builds and in-app updates" with "- [x] In-app updates" and "- [ ] Notarized builds (needs a Developer ID)"; update the self-test count to 29; mention in the headline table that headphones are covered.

- [ ] **Step 6: Commit, push, release**

```bash
git add -A && git commit -m "feat(app): headphones page, in-app updates, effect presets and drag reorder; v0.4.0"
```
(Push and release happen after the final review, in the finishing step.)
