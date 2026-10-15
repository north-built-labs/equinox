# Equinox Phase 1 (Engine & Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar app that captures all system audio with a Core Audio process tap, runs it through a parametric EQ + gain/balance/boost + safety limiter, and plays it on the current output device, with a live-spectrum EQ editor, presets, and per-device memory.

**Architecture:** Swift package with four modules. `EquinoxDSP` is pure, realtime-safe signal processing (biquads via `vDSP_biquadm`, limiter, FFT). `EquinoxAudio` owns Core Audio: a private aggregate device with a global tap (excluding our own process) whose IOProc calls the DSP `Renderer`. `EquinoxCore` holds the `@Observable` `AppModel`, presets and JSON persistence behind an `AudioControlling` protocol (so it is unit-testable with a fake). `Equinox` is the SwiftUI executable (MenuBarExtra + main window). `scripts/build-app.sh` assembles and signs `build/Equinox.app`.

**Tech Stack:** Swift 6.x toolchain in Swift 5 language mode, SwiftUI, Observation, CoreAudio (process taps, macOS 14.2+ API), Accelerate/vDSP, Synchronization (`Atomic`), os (`OSAllocatedUnfairLock`), ServiceManagement, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-15-equinox-design.md`

## Global Constraints

- Deployment target: macOS 15 (`platforms: [.macOS(.v15)]`); host is macOS 27, Apple Silicon.
- No third-party dependencies. No network access in Phase 1.
- Realtime code (anything called from the IOProc: `Renderer.render`, `MasterProcessor.process`, `BiquadBank`, `PeakLimiter`, `AnalysisTap.write`, `ChannelIO`) must not allocate, lock (except `withLockIfAvailable`), log, or call Objective-C.
- Max parametric bands: 32 (`BiquadBank.maxSections`). Band ranges: frequency 20–20000 Hz, gain −24…+24 dB, Q 0.1–18.
- Boost range 0…+12 dB; limiter ceiling −0.3 dBFS, always the last stage.
- Persistence directory: `~/Library/Application Support/Equinox/`, JSON, atomic writes, corrupt files renamed to `<name>.corrupt-<unix-time>`.
- Bundle ID `com.pie.equinox`; `NSAudioCaptureUsageDescription` present; `LSUIElement` = true.
- Sign with the local `Apple Development` identity (stable TCC permission across rebuilds).
- Clean-room: no eqMac code, assets, or strings.

## Review Focus

1. **Own-process feedback:** if Equinox's own process object cannot be resolved, the tap must not be created (otherwise our output is re-captured → howl). Test in Task 6 (`AudioSystemTests.testExclusionListRejectsUnknown`).
2. **Device switch / buffer size larger than expected** (AirPods connect, interface with 4096+ frame buffers): processing must chunk instead of truncating. Test in Task 3 (`testProcessesMoreFramesThanCapacityByChunking`).
3. **Sample-rate change (44.1 ↔ 48 ↔ 96 kHz):** coefficients must be recomputed for the new rate. Test in Task 3 (`testConfigUsesSampleRate`).
4. **Extreme settings** (all bands +24 dB, +12 dB boost, band at/above Nyquist, NaN input): output finite and ≤ ceiling. Tests in Tasks 1 and 3 (`testBandAboveNyquistIsStable`, `testExtremeSettingsStayUnderCeiling`, `testNaNInputIsSilencedAndRecovers`).
5. **Old/corrupt/garbage JSON** (settings from older builds missing keys, invalid preset import): no crash, defaults used, state unchanged. Tests in Task 8 (`testMissingKeysUseDefaults`, `testCorruptFileIsQuarantined`, `testImportGarbageThrowsAndLeavesStateUnchanged`).

---

## File Structure

```
Package.swift
Resources/Info.plist
scripts/build-app.sh
Sources/EquinoxDSP/
  EQBand.swift            FilterType, EQBand, ranges, clamping
  BiquadDesign.swift      BiquadCoefficients (RBJ), magnitude, EQResponse curve
  BiquadBank.swift        32-section stereo vDSP_biquadm wrapper with ramping
  GainMath.swift          Decibels, Balance
  PeakLimiter.swift       stereo-linked peak limiter
  DSPSettings.swift       DSPSettings (value) + DSPConfig (immutable, sample-rate specific)
  MasterProcessor.swift   EQ → gain ramp → limiter; chunking; NaN guard
  AnalysisTap.swift       lock-free mono ring + peak meters
  SpectrumAnalyzer.swift  FFT → log-spaced dB bins
Sources/EquinoxAudio/
  CoreAudioProperty.swift AudioObjectID property helpers, CoreAudioError
  AudioSystem.swift       devices, default output, process objects, HW volume, listeners
  ChannelIO.swift         AudioBufferList ↔ stereo planar
  Renderer.swift          ConfigMailbox + IOProc render function
  TapSession.swift        tap + private aggregate + IOProc lifecycle
  AudioController.swift   AudioStatus, AudioControlling, AudioController (rebuild/watchdog)
Sources/EquinoxCore/
  Preset.swift            Preset, built-ins, import/export
  AppSettings.swift       AppSettings, DeviceProfile (forward-compatible decoding)
  Store.swift             JSON persistence
  LoginItem.swift         LoginItemControlling + SMAppService impl
  EQGeometry.swift        canvas ↔ frequency/dB mapping
  AppModel.swift          @Observable app state
Sources/Equinox/
  EquinoxApp.swift        @main, scenes
  Theme.swift             colors, GlassCard
  SpectrumModel.swift     polls AnalysisTap, smooths
  EQCanvasView.swift      spectrum + curve + draggable nodes
  BandInspector.swift     band chips + numeric editing
  GraphicEQView.swift     vertical sliders
  Controls.swift          VolumeControl, BalanceControl, MeterView, VerticalSlider
  PresetBar.swift         preset menu, save/as, import/export
  MenuBarPanel.swift      popover
  MainWindow.swift        sidebar, EqualizerPage, SettingsPage
  OnboardingView.swift    first-run permission + signal check
Tests/EquinoxDSPTests/    BiquadDesignTests, BiquadBankTests, ProcessorTests, AnalysisTests
Tests/EquinoxAudioTests/  ChannelIOTests, AudioSystemTests
Tests/EquinoxCoreTests/   PresetTests, StoreTests, EQGeometryTests, AppModelTests
```

---

### Task 1: Package scaffold, band model, biquad design

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/EquinoxDSP/EQBand.swift`, `Sources/EquinoxDSP/BiquadDesign.swift`
- Create placeholders so the package resolves: `Sources/EquinoxAudio/CoreAudioProperty.swift` (empty `import CoreAudio`), `Sources/EquinoxCore/Preset.swift` (empty `import EquinoxDSP`), `Sources/Equinox/EquinoxApp.swift` (temporary, below)
- Test: `Tests/EquinoxDSPTests/BiquadDesignTests.swift`, placeholder `Tests/EquinoxAudioTests/ChannelIOTests.swift`, `Tests/EquinoxCoreTests/PresetTests.swift` (each `import XCTest`)

**Interfaces:**
- Produces: `FilterType` (`peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass`; `displayName`, `usesGain`), `EQBand(id:type:frequency:gainDB:q:isEnabled:)`, `EQBand.clamped()`, `EQBand.frequencyRange/gainRange/qRange`, `BiquadCoefficients(b0:b1:b2:a1:a2:)`, `.identity`, `BiquadCoefficients(band:sampleRate:)`, `.magnitude(at:sampleRate:) -> Double`, `EQResponse.decibels(bands:preampDB:frequency:sampleRate:) -> Double`.

- [ ] **Step 1: Create the package**

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Equinox",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Equinox", targets: ["Equinox"])],
    targets: [
        .target(name: "EquinoxDSP"),
        .target(name: "EquinoxAudio", dependencies: ["EquinoxDSP"]),
        .target(name: "EquinoxCore", dependencies: ["EquinoxDSP", "EquinoxAudio"]),
        .executableTarget(name: "Equinox", dependencies: ["EquinoxCore", "EquinoxDSP", "EquinoxAudio"]),
        .testTarget(name: "EquinoxDSPTests", dependencies: ["EquinoxDSP"]),
        .testTarget(name: "EquinoxAudioTests", dependencies: ["EquinoxAudio"]),
        .testTarget(name: "EquinoxCoreTests", dependencies: ["EquinoxCore", "EquinoxDSP", "EquinoxAudio"]),
    ],
    swiftLanguageModes: [.v5]
)
```

`.gitignore`:
```
.build/
build/
.swiftpm/
*.xcodeproj
```

Temporary `Sources/Equinox/EquinoxApp.swift`:
```swift
import SwiftUI

@main
struct EquinoxApp: App {
    var body: some Scene {
        MenuBarExtra("Equinox", systemImage: "waveform.circle") { Text("Equinox") }
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/EquinoxDSPTests/BiquadDesignTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

final class BiquadDesignTests: XCTestCase {
    let fs = 48_000.0

    func dB(_ band: EQBand, at f: Double, fs: Double = 48_000) -> Double {
        20 * log10(BiquadCoefficients(band: band, sampleRate: fs).magnitude(at: f, sampleRate: fs))
    }

    func testPeakHasGainAtCenterAndUnityFarAway() {
        let band = EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)
        XCTAssertEqual(dB(band, at: 1000), 6, accuracy: 0.01)
        XCTAssertEqual(dB(band, at: 20), 0, accuracy: 0.1)
        XCTAssertEqual(dB(band, at: 20000), 0, accuracy: 0.1)
    }

    func testLowShelfBoostsLowsOnly() {
        let band = EQBand(type: .lowShelf, frequency: 1000, gainDB: 6, q: 0.707)
        XCTAssertEqual(dB(band, at: 10), 6, accuracy: 0.1)
        XCTAssertEqual(dB(band, at: 20000), 0, accuracy: 0.1)
        XCTAssertEqual(dB(band, at: 1000), 3, accuracy: 0.2)
    }

    func testHighShelfBoostsHighsOnly() {
        let band = EQBand(type: .highShelf, frequency: 1000, gainDB: -6, q: 0.707)
        XCTAssertEqual(dB(band, at: 20), 0, accuracy: 0.1)
        XCTAssertEqual(dB(band, at: 20000), -6, accuracy: 0.15)
    }

    func testLowPassAndHighPassAreMinus3dBAtCorner() {
        XCTAssertEqual(dB(EQBand(type: .lowPass, frequency: 2000, q: 0.7071), at: 2000), -3.01, accuracy: 0.05)
        XCTAssertEqual(dB(EQBand(type: .lowPass, frequency: 2000, q: 0.7071), at: 20), 0, accuracy: 0.05)
        XCTAssertEqual(dB(EQBand(type: .highPass, frequency: 200, q: 0.7071), at: 200), -3.01, accuracy: 0.05)
        XCTAssertEqual(dB(EQBand(type: .highPass, frequency: 200, q: 0.7071), at: 15000), 0, accuracy: 0.05)
    }

    func testNotchAndBandPass() {
        XCTAssertLessThan(dB(EQBand(type: .notch, frequency: 3000, q: 4), at: 3000), -60)
        XCTAssertEqual(dB(EQBand(type: .bandPass, frequency: 3000, q: 2), at: 3000), 0, accuracy: 0.05)
    }

    func testBandAboveNyquistIsStable() {
        let c = BiquadCoefficients(band: EQBand(type: .peak, frequency: 20000, gainDB: 24, q: 18), sampleRate: 22_050)
        for v in [c.b0, c.b1, c.b2, c.a1, c.a2] { XCTAssertTrue(v.isFinite) }
        // Poles inside the unit circle: |a2| < 1 and |a1| < 1 + a2
        XCTAssertLessThan(abs(c.a2), 1)
        XCTAssertLessThan(abs(c.a1), 1 + c.a2)
    }

    func testClampingKeepsBandInRange() {
        let b = EQBand(type: .peak, frequency: 5, gainDB: 99, q: 0).clamped()
        XCTAssertEqual(b.frequency, 20); XCTAssertEqual(b.gainDB, 24); XCTAssertEqual(b.q, 0.1)
    }

    func testResponseSumsBandsAndPreamp() {
        let bands = [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1),
                     EQBand(type: .peak, frequency: 1000, gainDB: 3, q: 1, isEnabled: false)]
        XCTAssertEqual(EQResponse.decibels(bands: bands, preampDB: -2, frequency: 1000, sampleRate: fs), 4, accuracy: 0.02)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter BiquadDesignTests`
Expected: compile failure — `cannot find 'EQBand' in scope`.

- [ ] **Step 4: Implement**

`Sources/EquinoxDSP/EQBand.swift`:
```swift
import Foundation

public enum FilterType: String, Codable, CaseIterable, Sendable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass

    public var displayName: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .notch: "Notch"
        case .bandPass: "Band Pass"
        }
    }

    /// Whether the gain parameter affects this filter type.
    public var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}

public struct EQBand: Codable, Hashable, Identifiable, Sendable {
    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let gainRange: ClosedRange<Double> = -24...24
    public static let qRange: ClosedRange<Double> = 0.1...18

    public var id: UUID
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), type: FilterType = .peak, frequency: Double,
                gainDB: Double = 0, q: Double = 1, isEnabled: Bool = true) {
        self.id = id; self.type = type; self.frequency = frequency
        self.gainDB = gainDB; self.q = q; self.isEnabled = isEnabled
    }

    public func clamped() -> EQBand {
        var b = self
        b.frequency = Self.clamp(frequency, Self.frequencyRange)
        b.gainDB = Self.clamp(gainDB, Self.gainRange)
        b.q = Self.clamp(q, Self.qRange)
        return b
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }
}
```

`Sources/EquinoxDSP/BiquadDesign.swift`:
```swift
import Foundation

/// Normalized biquad (a0 == 1). Direct form: y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// RBJ Audio-EQ-Cookbook design. Shelves use alpha = sin(w0)/(2Q), matching AutoEQ / Equalizer APO.
    public init(band rawBand: EQBand, sampleRate: Double) {
        let band = rawBand.clamped()
        let f0 = min(band.frequency, 0.49 * sampleRate)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * band.q)
        let A = pow(10, band.gainDB / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cw)
            b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s
            a1 = -2 * ((A - 1) + (A + 1) * cw)
            a2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cw)
            b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s
            a1 = 2 * ((A - 1) - (A + 1) * cw)
            a2 = (A + 1) - (A - 1) * cw - s
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .bandPass:
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Linear magnitude of the frequency response.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
    }
}

public enum EQResponse {
    /// Combined response in dB of all enabled bands plus preamp.
    public static func decibels(bands: [EQBand], preampDB: Double, frequency: Double, sampleRate: Double) -> Double {
        var total = preampDB
        for band in bands where band.isEnabled {
            let m = BiquadCoefficients(band: band, sampleRate: sampleRate).magnitude(at: frequency, sampleRate: sampleRate)
            total += 20 * log10(max(m, 1e-9))
        }
        return total
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter BiquadDesignTests`
Expected: all 8 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(dsp): package scaffold, EQ band model, RBJ biquad design"
```

---

### Task 2: BiquadBank (vDSP multi-section stereo filter with ramping)

**Files:**
- Create: `Sources/EquinoxDSP/BiquadBank.swift`
- Test: `Tests/EquinoxDSPTests/BiquadBankTests.swift`

**Interfaces:**
- Consumes: `BiquadCoefficients`.
- Produces: `BiquadBank(maxFrames:)`, `BiquadBank.maxSections` (32), `BiquadBank.flatten(_ sections: [BiquadCoefficients]) -> [Double]` (count `32*2*5`, layout index `(section*2 + channel)*5`, verified empirically), `setCoefficients(_ flat: [Double], ramp: Bool)`, `process(left:right:frames:)` (in place, `frames <= maxFrames`), `reset()`.

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxDSPTests/BiquadBankTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

/// Shared helpers for DSP tests.
enum Signal {
    static func sine(_ f: Double, fs: Double, count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * f * Double($0) / fs)) }
    }
    static func rms(_ x: ArraySlice<Float>) -> Float {
        sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
    }
}

final class BiquadBankTests: XCTestCase {
    let fs = 48_000.0

    func run(_ bank: BiquadBank, _ input: [Float]) -> (l: [Float], r: [Float]) {
        var l = input, r = input
        var offset = 0
        while offset < input.count {
            let n = min(512, input.count - offset)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                bank.process(left: lp.baseAddress! + offset, right: rp.baseAddress! + offset, frames: n)
            } }
            offset += n
        }
        return (l, r)
    }

    func testFlattenPadsWithIdentityAndDuplicatesChannels() {
        let c = BiquadCoefficients(b0: 2, b1: 0, b2: 0, a1: 0, a2: 0)
        let flat = BiquadBank.flatten([c])
        XCTAssertEqual(flat.count, BiquadBank.maxSections * 2 * 5)
        XCTAssertEqual(flat[0], 2); XCTAssertEqual(flat[5], 2)      // section 0, ch 0 and ch 1
        XCTAssertEqual(flat[10], 1); XCTAssertEqual(flat[15], 1)    // section 1 identity
    }

    func testIdentityPassesSignalThrough() {
        let bank = BiquadBank(maxFrames: 512)
        let x = Signal.sine(440, fs: fs, count: 2048)
        let y = run(bank, x)
        XCTAssertEqual(y.l, x); XCTAssertEqual(y.r, x)
    }

    func testPeakFilterBoostsMatchingSine() {
        let bank = BiquadBank(maxFrames: 512)
        let band = EQBand(type: .peak, frequency: 1000, gainDB: 12, q: 1)
        bank.setCoefficients(BiquadBank.flatten([BiquadCoefficients(band: band, sampleRate: fs)]), ramp: false)
        let x = Signal.sine(1000, fs: fs, count: 24_000)
        let y = run(bank, x)
        let gain = 20 * log10(Signal.rms(y.l[12_000...]) / Signal.rms(x[12_000...]))
        XCTAssertEqual(Double(gain), 12, accuracy: 0.1)
        XCTAssertEqual(y.l, y.r)
    }

    func testRampedChangeConvergesToTarget() {
        let bank = BiquadBank(maxFrames: 512)
        bank.setCoefficients(BiquadBank.flatten([]), ramp: false)
        let band = EQBand(type: .peak, frequency: 1000, gainDB: -12, q: 1)
        bank.setCoefficients(BiquadBank.flatten([BiquadCoefficients(band: band, sampleRate: fs)]), ramp: true)
        let x = Signal.sine(1000, fs: fs, count: 48_000)
        let y = run(bank, x)
        let gain = 20 * log10(Signal.rms(y.l[36_000...]) / Signal.rms(x[36_000...]))
        XCTAssertEqual(Double(gain), -12, accuracy: 0.2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BiquadBankTests`
Expected: compile failure — `cannot find 'BiquadBank' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxDSP/BiquadBank.swift`:
```swift
import Accelerate

/// Stereo cascade of `maxSections` biquads backed by vDSP_biquadm.
/// Unused sections are identity, so the section count never changes and
/// coefficient updates can always be ramped (no zipper noise).
public final class BiquadBank {
    public static let maxSections = 32
    static let channels = 2
    /// Fraction of the remaining distance covered per sample while ramping (~2 ms time constant at 48 kHz).
    static let interpolationRate: Float = 0.01
    static let interpolationThreshold: Float = 1e-6

    public let maxFrames: Int
    private let setup: vDSP_biquadm_Setup
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let inputs: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
        let identity = Self.flatten([])
        setup = vDSP_biquadm_CreateSetup(identity, vDSP_Length(Self.maxSections), vDSP_Length(Self.channels))!
        scratchL = .allocate(capacity: maxFrames); scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR = .allocate(capacity: maxFrames); scratchR.initialize(repeating: 0, count: maxFrames)
        inputs = .allocate(capacity: 2)
        inputs.initialize(to: UnsafePointer(scratchL)); (inputs + 1).initialize(to: UnsafePointer(scratchR))
        outputs = .allocate(capacity: 2)
        outputs.initialize(to: scratchL); (outputs + 1).initialize(to: scratchR)
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
        scratchL.deallocate(); scratchR.deallocate(); inputs.deallocate(); outputs.deallocate()
    }

    /// Flattened coefficient array in vDSP_biquadm layout: index (section * channels + channel) * 5.
    /// Sections beyond `maxSections` are dropped; missing ones are identity.
    public static func flatten(_ sections: [BiquadCoefficients]) -> [Double] {
        var flat = [Double](repeating: 0, count: maxSections * channels * 5)
        for s in 0..<maxSections {
            let c = s < sections.count ? sections[s] : .identity
            for ch in 0..<channels {
                let i = (s * channels + ch) * 5
                flat[i] = c.b0; flat[i + 1] = c.b1; flat[i + 2] = c.b2; flat[i + 3] = c.a1; flat[i + 4] = c.a2
            }
        }
        return flat
    }

    /// Realtime-safe. `flat` must come from `flatten`.
    public func setCoefficients(_ flat: [Double], ramp: Bool) {
        precondition(flat.count == Self.maxSections * Self.channels * 5)
        flat.withUnsafeBufferPointer { p in
            if ramp {
                vDSP_biquadm_SetTargetsDouble(setup, p.baseAddress!, Self.interpolationRate, Self.interpolationThreshold,
                                              0, 0, vDSP_Length(Self.maxSections), vDSP_Length(Self.channels))
            } else {
                vDSP_biquadm_SetCoefficientsDouble(setup, p.baseAddress!, 0, 0,
                                                   vDSP_Length(Self.maxSections), vDSP_Length(Self.channels))
            }
        }
    }

    /// Realtime-safe, in place. `frames` must be <= maxFrames.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        precondition(frames <= maxFrames)
        scratchL.update(from: left, count: frames)
        scratchR.update(from: right, count: frames)
        outputs[0] = left; outputs[1] = right
        vDSP_biquadm(setup, inputs, 1, outputs, 1, vDSP_Length(frames))
    }

    public func reset() { vDSP_biquadm_ResetState(setup) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BiquadBankTests`
Expected: 4 tests PASS. If `testRampedChangeConvergesToTarget` fails, the interpolation-rate semantics differ from the assumption: lower `interpolationRate` toward `0.001` and re-run, keeping the test unchanged.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(dsp): 32-section stereo BiquadBank with coefficient ramping"
```

---

### Task 3: Gain math, limiter, DSP settings/config, MasterProcessor

**Files:**
- Create: `Sources/EquinoxDSP/GainMath.swift`, `Sources/EquinoxDSP/PeakLimiter.swift`, `Sources/EquinoxDSP/DSPSettings.swift`, `Sources/EquinoxDSP/MasterProcessor.swift`
- Test: `Tests/EquinoxDSPTests/ProcessorTests.swift`

**Interfaces:**
- Consumes: `EQBand`, `BiquadCoefficients`, `BiquadBank`.
- Produces:
  - `Decibels.toLinear(_:) -> Double`, `Decibels.fromLinear(_:) -> Double`, `Balance.gains(_ balance: Double) -> (left: Double, right: Double)`
  - `PeakLimiter(ceilingDB:releaseMs:sampleRate:)`, `.process(left:right:frames:)`, `.ceiling: Float`
  - `DSPSettings` (Codable, Equatable): `isBypassed, preampDB, bands, softwareVolume, boostDB, balance, isMuted`; `DSPSettings.maxBoostDB = 12`
  - `DSPConfig(settings:sampleRate:)` (final class): `isBypassed, eqCoefficients: [Double], leftGain: Float, rightGain: Float, sampleRate: Double`
  - `MasterProcessor(maxFrames:sampleRate:)`, `.apply(_ config: DSPConfig)`, `.process(left:right:frames:)` (any frame count), `.limiter`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxDSPTests/ProcessorTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

final class ProcessorTests: XCTestCase {
    let fs = 48_000.0

    func process(_ p: MasterProcessor, _ l: inout [Float], _ r: inout [Float]) {
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            p.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count)
        } }
    }

    func testDecibelsAndBalance() {
        XCTAssertEqual(Decibels.toLinear(-6.0206), 0.5, accuracy: 1e-4)
        XCTAssertEqual(Decibels.fromLinear(2), 6.0206, accuracy: 1e-3)
        XCTAssertEqual(Balance.gains(0).left, 1); XCTAssertEqual(Balance.gains(0).right, 1)
        XCTAssertEqual(Balance.gains(0.5).left, 0.5); XCTAssertEqual(Balance.gains(0.5).right, 1)
        XCTAssertEqual(Balance.gains(-1).right, 0); XCTAssertEqual(Balance.gains(-1).left, 1)
    }

    func testLimiterNeverExceedsCeiling() {
        let lim = PeakLimiter(ceilingDB: -0.3, releaseMs: 80, sampleRate: fs)
        var l = Signal.sine(100, fs: fs, count: 4800, amplitude: 4), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            lim.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 4800)
        } }
        XCTAssertLessThanOrEqual(l.map(abs).max()!, lim.ceiling)
        XCTAssertLessThanOrEqual(r.map(abs).max()!, lim.ceiling)
    }

    func testConfigUsesSampleRate() {
        var s = DSPSettings(); s.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 12, q: 1)]
        for rate in [44_100.0, 96_000.0] {
            let cfg = DSPConfig(settings: s, sampleRate: rate)
            let f = cfg.eqCoefficients
            let c = BiquadCoefficients(b0: f[0], b1: f[1], b2: f[2], a1: f[3], a2: f[4])
            XCTAssertEqual(20 * log10(c.magnitude(at: 1000, sampleRate: rate)), 12, accuracy: 0.01)
        }
    }

    func testConfigGainsCombineVolumeBoostBalancePreampAndMute() {
        var s = DSPSettings(); s.softwareVolume = 0.5; s.boostDB = 6.0206; s.balance = 0.5; s.preampDB = -6.0206
        let cfg = DSPConfig(settings: s, sampleRate: fs)
        XCTAssertEqual(cfg.rightGain, 0.5, accuracy: 1e-3)   // 0.5 * 2 * 1 * 0.5
        XCTAssertEqual(cfg.leftGain, 0.25, accuracy: 1e-3)
        s.isMuted = true
        XCTAssertEqual(DSPConfig(settings: s, sampleRate: fs).leftGain, 0)
    }

    func testIgnoresBandsBeyondMaxAndDisabledBands() {
        var s = DSPSettings()
        s.bands = (0..<40).map { EQBand(frequency: 100 + Double($0) * 10, gainDB: 3) }
        s.bands[0].isEnabled = false
        let cfg = DSPConfig(settings: s, sampleRate: fs)
        XCTAssertEqual(cfg.eqCoefficients.count, BiquadBank.maxSections * 2 * 5)
    }

    func testBypassLeavesAudioUntouched() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        var s = DSPSettings(); s.isBypassed = true; s.boostDB = 12
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        let x = Signal.sine(300, fs: fs, count: 1000)
        var l = x, r = x
        process(p, &l, &r)
        XCTAssertEqual(l, x)
    }

    func testProcessesMoreFramesThanCapacityByChunking() {
        let p = MasterProcessor(maxFrames: 256, sampleRate: fs)
        var s = DSPSettings(); s.softwareVolume = 0.5
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        var l = [Float](repeating: 0.4, count: 5000), r = l
        process(p, &l, &r)
        XCTAssertEqual(l[4999], 0.2, accuracy: 1e-4)
        XCTAssertEqual(r[300], 0.2, accuracy: 1e-4)
    }

    func testExtremeSettingsStayUnderCeiling() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        var s = DSPSettings(); s.boostDB = 12; s.preampDB = 12
        s.bands = (0..<32).map { EQBand(type: .peak, frequency: 30 * pow(1.25, Double($0)), gainDB: 24, q: 0.5) }
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        var l = Signal.sine(80, fs: fs, count: 9600, amplitude: 1), r = l
        process(p, &l, &r)
        XCTAssertTrue(l.allSatisfy { $0.isFinite })
        XCTAssertLessThanOrEqual(l.map(abs).max()!, p.limiter.ceiling)
    }

    func testNaNInputIsSilencedAndRecovers() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        var s = DSPSettings(); s.bands = [EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 1)]
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        var l = [Float](repeating: .nan, count: 512), r = l
        process(p, &l, &r)
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
        var l2 = Signal.sine(1000, fs: fs, count: 512), r2 = l2
        process(p, &l2, &r2)
        XCTAssertTrue(l2.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(l2.map(abs).max()!, 0.01)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProcessorTests`
Expected: compile failure — `cannot find 'MasterProcessor' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxDSP/GainMath.swift`:
```swift
import Foundation

public enum Decibels {
    public static func toLinear(_ dB: Double) -> Double { pow(10, dB / 20) }
    public static func fromLinear(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }
}

public enum Balance {
    /// balance in -1 (left only) ... +1 (right only). The louder side stays at unity.
    public static func gains(_ balance: Double) -> (left: Double, right: Double) {
        let b = min(max(balance.isFinite ? balance : 0, -1), 1)
        return (left: b > 0 ? 1 - b : 1, right: b < 0 ? 1 + b : 1)
    }
}
```

`Sources/EquinoxDSP/PeakLimiter.swift`:
```swift
import Foundation

/// Stereo-linked peak limiter: instant attack, exponential release, hard ceiling clamp.
public final class PeakLimiter {
    public let ceiling: Float
    private let releaseMs: Double
    private var releaseCoefficient: Float
    private var gain: Float = 1

    public init(ceilingDB: Double = -0.3, releaseMs: Double = 80, sampleRate: Double) {
        ceiling = Float(Decibels.toLinear(ceilingDB))
        self.releaseMs = releaseMs
        releaseCoefficient = Self.coefficient(releaseMs: releaseMs, sampleRate: sampleRate)
    }

    private static func coefficient(releaseMs: Double, sampleRate: Double) -> Float {
        Float(exp(-1 / (releaseMs * 0.001 * sampleRate)))
    }

    public func setSampleRate(_ sampleRate: Double) {
        releaseCoefficient = Self.coefficient(releaseMs: releaseMs, sampleRate: sampleRate)
    }

    public func reset() { gain = 1 }

    /// Realtime-safe, in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let c = ceiling, rel = releaseCoefficient
        var g = gain
        for i in 0..<frames {
            let peak = max(abs(left[i]), abs(right[i]))
            let target: Float = peak > c ? c / peak : 1
            g = target < g ? target : target + (g - target) * rel
            left[i] = min(max(left[i] * g, -c), c)
            right[i] = min(max(right[i] * g, -c), c)
        }
        gain = g
    }
}
```

`Sources/EquinoxDSP/DSPSettings.swift`:
```swift
import Foundation

/// Sample-rate independent processing parameters, produced by the app model.
public struct DSPSettings: Codable, Equatable, Sendable {
    public static let maxBoostDB = 12.0

    public var isBypassed = false
    public var preampDB = 0.0
    public var bands: [EQBand] = []
    /// 0...1; used when the output device has no hardware volume.
    public var softwareVolume = 1.0
    /// 0...maxBoostDB
    public var boostDB = 0.0
    /// -1...1
    public var balance = 0.0
    public var isMuted = false

    public init() {}
}

/// Immutable, sample-rate specific snapshot handed to the realtime thread.
public final class DSPConfig: @unchecked Sendable {
    public let sampleRate: Double
    public let isBypassed: Bool
    public let eqCoefficients: [Double]
    public let leftGain: Float
    public let rightGain: Float

    public init(settings s: DSPSettings, sampleRate: Double) {
        self.sampleRate = sampleRate
        isBypassed = s.isBypassed
        let sections = s.bands.lazy.filter(\.isEnabled).prefix(BiquadBank.maxSections)
            .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        eqCoefficients = BiquadBank.flatten(Array(sections))
        let volume = min(max(s.softwareVolume.isFinite ? s.softwareVolume : 1, 0), 1)
        let boost = Decibels.toLinear(min(max(s.boostDB.isFinite ? s.boostDB : 0, 0), DSPSettings.maxBoostDB))
        let preamp = Decibels.toLinear(min(max(s.preampDB.isFinite ? s.preampDB : 0, -24), 24))
        let bal = Balance.gains(s.balance)
        let common = s.isMuted ? 0 : volume * boost * preamp
        leftGain = Float(common * bal.left)
        rightGain = Float(common * bal.right)
    }
}
```

`Sources/EquinoxDSP/MasterProcessor.swift`:
```swift
import Accelerate

/// Master chain: EQ → gain (preamp·volume·boost·balance, ramped) → limiter.
/// EQ is linear, so folding preamp into the post-EQ gain is equivalent and avoids zipper noise.
public final class MasterProcessor {
    public let maxFrames: Int
    public let limiter: PeakLimiter
    private let eq: BiquadBank
    private var hasConfig = false
    private var isBypassed = false
    private var currentLeft: Float = 1, currentRight: Float = 1
    private var targetLeft: Float = 1, targetRight: Float = 1

    public init(maxFrames: Int, sampleRate: Double) {
        self.maxFrames = maxFrames
        eq = BiquadBank(maxFrames: maxFrames)
        limiter = PeakLimiter(sampleRate: sampleRate)
    }

    /// Realtime-safe. The first config is applied immediately, later ones are ramped.
    public func apply(_ config: DSPConfig) {
        eq.setCoefficients(config.eqCoefficients, ramp: hasConfig)
        isBypassed = config.isBypassed
        targetLeft = config.leftGain; targetRight = config.rightGain
        if !hasConfig { currentLeft = targetLeft; currentRight = targetRight }
        limiter.setSampleRate(config.sampleRate)
        hasConfig = true
    }

    /// Realtime-safe, in place, any frame count.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard !isBypassed else { return }
        var offset = 0
        while offset < frames {
            let n = min(maxFrames, frames - offset)
            processChunk(left + offset, right + offset, n)
            offset += n
        }
    }

    private func processChunk(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        eq.process(left: l, right: r, frames: n)

        var energy: Float = 0
        vDSP_svesq(l, 1, &energy, vDSP_Length(n))
        var energyR: Float = 0
        vDSP_svesq(r, 1, &energyR, vDSP_Length(n))
        if !(energy + energyR).isFinite {
            eq.reset(); limiter.reset()
            l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
            return
        }

        ramp(l, &currentLeft, targetLeft, n)
        ramp(r, &currentRight, targetRight, n)
        limiter.process(left: l, right: r, frames: n)
    }

    private func ramp(_ x: UnsafeMutablePointer<Float>, _ current: inout Float, _ target: Float, _ n: Int) {
        if current == target {
            if target != 1 { var g = target; vDSP_vsmul(x, 1, &g, x, 1, vDSP_Length(n)) }
            return
        }
        var start = current
        var step = (target - current) / Float(n)
        vDSP_vrampmul(x, 1, &start, &step, x, 1, vDSP_Length(n))
        current = target
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProcessorTests`
Expected: 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(dsp): gain math, peak limiter, DSP config and master processor"
```

---

### Task 4: AnalysisTap and SpectrumAnalyzer

**Files:**
- Create: `Sources/EquinoxDSP/AnalysisTap.swift`, `Sources/EquinoxDSP/SpectrumAnalyzer.swift`
- Test: `Tests/EquinoxDSPTests/AnalysisTests.swift`

**Interfaces:**
- Produces:
  - `AnalysisTap()` (final class, Sendable): `static capacity = 16384`, `write(left:right:frames:)` (RT), `copyLatest(into: inout [Float])` (copies the newest `array.count` mono samples), `takePeaks() -> (left: Float, right: Float)`
  - `SpectrumAnalyzer(fftSize: Int = 4096, bandCount: Int = 96)`, `.fftSize`, `.frequencies: [Double]`, `analyze(_ samples: [Float], sampleRate: Double) -> [Float]` (dBFS per band, sine of amplitude 1 ≈ 0 dB)

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxDSPTests/AnalysisTests.swift`:
```swift
import XCTest
@testable import EquinoxDSP

final class AnalysisTests: XCTestCase {
    func write(_ tap: AnalysisTap, _ l: [Float], _ r: [Float]) {
        var l = l, r = r
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            tap.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count)
        } }
    }

    func testCopyLatestReturnsNewestMonoSamples() {
        let tap = AnalysisTap()
        let l = (0..<100).map { Float($0) }, r = l.map { $0 + 2 }
        write(tap, l, r)
        var out = [Float](repeating: 0, count: 10)
        tap.copyLatest(into: &out)
        XCTAssertEqual(out, (90..<100).map { Float($0) + 1 })
    }

    func testCopyLatestWrapsAroundRing() {
        let tap = AnalysisTap()
        let block = [Float](repeating: 0.25, count: 4000)
        for _ in 0..<5 { write(tap, block, block) }   // 20000 > capacity
        var out = [Float](repeating: 0, count: 4096)
        tap.copyLatest(into: &out)
        XCTAssertTrue(out.allSatisfy { $0 == 0.25 })
    }

    func testPeaksAreTakenAndReset() {
        let tap = AnalysisTap()
        write(tap, [0.1, -0.8, 0.2], [0.3, 0.05, -0.4])
        let p = tap.takePeaks()
        XCTAssertEqual(p.left, 0.8, accuracy: 1e-6); XCTAssertEqual(p.right, 0.4, accuracy: 1e-6)
        XCTAssertEqual(tap.takePeaks().left, 0)
    }

    func testSpectrumFindsSineAtZeroDB() {
        let fs = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let x = Signal.sine(1000, fs: fs, count: analyzer.fftSize, amplitude: 1)
        let bands = analyzer.analyze(x, sampleRate: fs)
        XCTAssertEqual(bands.count, analyzer.frequencies.count)
        let i1k = analyzer.frequencies.enumerated().min { abs($0.1 - 1000) < abs($1.1 - 1000) }!.offset
        let i10k = analyzer.frequencies.enumerated().min { abs($0.1 - 10000) < abs($1.1 - 10000) }!.offset
        XCTAssertEqual(Double(bands[i1k]), 0, accuracy: 2)
        XCTAssertLessThan(bands[i10k], -50)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnalysisTests`
Expected: compile failure — `cannot find 'AnalysisTap' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxDSP/AnalysisTap.swift`:
```swift
import Accelerate
import Synchronization

/// Single-producer (audio thread) ring of post-processing mono samples + peak meters.
/// Readers may observe a partially overwritten window under heavy load; acceptable for visualization.
public final class AnalysisTap: @unchecked Sendable {
    public static let capacity = 16_384
    private static let mask = capacity - 1

    private let ring: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let peakLeftBits = Atomic<UInt32>(0)
    private let peakRightBits = Atomic<UInt32>(0)

    public init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { ring.deallocate() }

    /// Realtime-safe.
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let start = writeIndex.load(ordering: .relaxed)
        for i in 0..<frames {
            ring[(start + i) & Self.mask] = 0.5 * (left[i] + right[i])
        }
        writeIndex.store(start + frames, ordering: .releasing)

        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(left, 1, &pl, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &pr, vDSP_Length(frames))
        Self.raise(peakLeftBits, to: pl)
        Self.raise(peakRightBits, to: pr)
    }

    private static func raise(_ atomic: borrowing Atomic<UInt32>, to value: Float) {
        guard value.isFinite else { return }
        let bits = value.bitPattern   // non-negative floats order like their bit patterns
        var current = atomic.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = atomic.compareExchange(expected: current, desired: bits, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    /// Copies the newest `out.count` samples (oldest first). `out.count` must be <= capacity.
    public func copyLatest(into out: inout [Float]) {
        let n = min(out.count, Self.capacity)
        let end = writeIndex.load(ordering: .acquiring)
        for i in 0..<n {
            out[i] = ring[(end - n + i) & Self.mask]
        }
    }

    /// Peak magnitudes since the last call.
    public func takePeaks() -> (left: Float, right: Float) {
        (Float(bitPattern: peakLeftBits.exchange(0, ordering: .relaxed)),
         Float(bitPattern: peakRightBits.exchange(0, ordering: .relaxed)))
    }
}
```

`Sources/EquinoxDSP/SpectrumAnalyzer.swift`:
```swift
import Accelerate

/// FFT spectrum reduced to log-spaced bands in dBFS. Main-thread use; not realtime.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let frequencies: [Double]
    private let edges: [Double]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    public init(fftSize: Int = 4096, bandCount: Int = 96, minFrequency: Double = 20, maxFrequency: Double = 20_000) {
        self.fftSize = fftSize
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        let ratio = maxFrequency / minFrequency
        edges = (0...bandCount).map { minFrequency * pow(ratio, Double($0) / Double(bandCount)) }
        frequencies = (0..<bandCount).map { sqrt(edges[$0] * edges[$0 + 1]) }
    }

    public func analyze(_ samples: [Float], sampleRate: Double) -> [Float] {
        precondition(samples.count == fftSize)
        vDSP.multiply(samples, window, result: &windowed)
        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // vDSP real FFT is scaled by 2; with a Hann window a full-scale sine peaks at N/2.
        let norm = Float(half) * Float(half)
        let binHz = sampleRate / Double(fftSize)
        var result = [Float](repeating: -120, count: frequencies.count)
        for b in 0..<frequencies.count {
            var lo = Int((edges[b] / binHz).rounded(.down))
            var hi = Int((edges[b + 1] / binHz).rounded(.up))
            lo = min(max(lo, 1), half - 1); hi = min(max(hi, lo), half - 1)
            var p: Float = 0
            for k in lo...hi { p = max(p, power[k]) }
            result[b] = max(10 * log10(max(p / norm, 1e-12)), -120)
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnalysisTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(dsp): lock-free analysis tap and log-band spectrum analyzer"
```

---

### Task 5: Presets (model, built-ins, import/export)

**Files:**
- Modify: `Sources/EquinoxCore/Preset.swift` (replace placeholder)
- Test: `Tests/EquinoxCoreTests/PresetTests.swift` (replace placeholder)

**Interfaces:**
- Consumes: `EQBand`, `BiquadBank.maxSections`.
- Produces: `Preset(id:name:preampDB:bands:isBuiltIn:)` (Codable, Hashable, Identifiable), `Preset.graphicFrequencies: [Double]` (10), `Preset.graphic(id:name:gains:preampDB:) -> Preset`, `Preset.flat`, `Preset.builtIns: [Preset]`, `Preset.importPresets(from data: Data) throws -> [Preset]`, `Preset.exportData(_ presets: [Preset]) throws -> Data`, `PresetError.invalidFile`.

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxCoreTests/PresetTests.swift`:
```swift
import XCTest
@testable import EquinoxCore
import EquinoxDSP

final class PresetTests: XCTestCase {
    func testBuiltInsHaveStableUniqueIDsAndTenBands() {
        let ids = Set(Preset.builtIns.map(\.id))
        XCTAssertEqual(ids.count, Preset.builtIns.count)
        XCTAssertEqual(Preset.builtIns.first, Preset.flat)
        XCTAssertTrue(Preset.builtIns.allSatisfy { $0.isBuiltIn && $0.bands.count == 10 })
        XCTAssertEqual(Preset.flat.id.uuidString, "00000000-0000-0000-0000-000000000001")
    }

    func testExportImportRoundTripAssignsNewIDsAndClearsBuiltIn() throws {
        let original = Preset.builtIns[1]
        let data = try Preset.exportData([original])
        let imported = try Preset.importPresets(from: data)
        XCTAssertEqual(imported.count, 1)
        XCTAssertNotEqual(imported[0].id, original.id)
        XCTAssertFalse(imported[0].isBuiltIn)
        XCTAssertEqual(imported[0].bands.map(\.gainDB), original.bands.map(\.gainDB))
    }

    func testImportAcceptsSinglePresetObject() throws {
        let data = try JSONEncoder().encode(Preset.builtIns[2])
        XCTAssertEqual(try Preset.importPresets(from: data).count, 1)
    }

    func testImportClampsAndCapsBands() throws {
        var p = Preset(name: "Wild", preampDB: 99, bands: (0..<40).map { _ in EQBand(frequency: 1, gainDB: 80, q: 50) })
        p.isBuiltIn = true
        let imported = try Preset.importPresets(from: try Preset.exportData([p]))[0]
        XCTAssertEqual(imported.bands.count, BiquadBank.maxSections)
        XCTAssertEqual(imported.bands[0].gainDB, 24)
        XCTAssertEqual(imported.preampDB, 24)
    }

    func testImportGarbageThrows() {
        XCTAssertThrowsError(try Preset.importPresets(from: Data("nope".utf8)))
        XCTAssertThrowsError(try Preset.importPresets(from: Data("[]".utf8)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PresetTests`
Expected: compile failure — `cannot find 'Preset' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxCore/Preset.swift`:
```swift
import Foundation
import EquinoxDSP

public enum PresetError: Error, Equatable { case invalidFile }

public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var preampDB: Double
    public var bands: [EQBand]
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, preampDB: Double = 0, bands: [EQBand], isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.preampDB = preampDB; self.bands = bands; self.isBuiltIn = isBuiltIn
    }

    public static let graphicFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public static func graphic(id: String, name: String, gains: [Double], preampDB: Double = 0) -> Preset {
        let bands = zip(graphicFrequencies, gains).map { EQBand(type: .peak, frequency: $0, gainDB: $1, q: 1.41) }
        return Preset(id: UUID(uuidString: id)!, name: name, preampDB: preampDB, bands: bands, isBuiltIn: true)
    }

    public static let flat = graphic(id: "00000000-0000-0000-0000-000000000001", name: "Flat", gains: Array(repeating: 0, count: 10))

    public static let builtIns: [Preset] = [
        flat,
        graphic(id: "00000000-0000-0000-0000-000000000002", name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000003", name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000004", name: "Vocal", gains: [-2, -2, -1, 0, 2, 4, 4, 2, 0, -1], preampDB: -3),
        graphic(id: "00000000-0000-0000-0000-000000000005", name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000006", name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000007", name: "Acoustic", gains: [4, 3, 2, 1, 1, 1, 2, 3, 2, 1], preampDB: -3),
        graphic(id: "00000000-0000-0000-0000-000000000008", name: "Late Night", gains: [-3, -2, 0, 1, 2, 2, 1, 0, -2, -3], preampDB: -2),
    ]

    /// Accepts a single preset object or an array. Returns user presets with fresh IDs, clamped values.
    public static func importPresets(from data: Data) throws -> [Preset] {
        let decoder = JSONDecoder()
        let raw: [Preset]
        if let many = try? decoder.decode([Preset].self, from: data) {
            raw = many
        } else if let one = try? decoder.decode(Preset.self, from: data) {
            raw = [one]
        } else {
            throw PresetError.invalidFile
        }
        guard !raw.isEmpty else { throw PresetError.invalidFile }
        return raw.map { p in
            Preset(name: p.name.isEmpty ? "Imported" : p.name,
                   preampDB: min(max(p.preampDB.isFinite ? p.preampDB : 0, -24), 24),
                   bands: p.bands.prefix(BiquadBank.maxSections).map { var b = $0.clamped(); b.id = UUID(); return b },
                   isBuiltIn: false)
        }
    }

    public static func exportData(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(presets)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PresetTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): presets with built-ins and JSON import/export"
```

---

### Task 6: Core Audio layer (properties, devices, ChannelIO, Renderer)

**Files:**
- Modify: `Sources/EquinoxAudio/CoreAudioProperty.swift` (replace placeholder)
- Create: `Sources/EquinoxAudio/AudioSystem.swift`, `Sources/EquinoxAudio/ChannelIO.swift`, `Sources/EquinoxAudio/Renderer.swift`
- Test: `Tests/EquinoxAudioTests/ChannelIOTests.swift` (replace placeholder), `Tests/EquinoxAudioTests/AudioSystemTests.swift`

**Interfaces:**
- Consumes: `MasterProcessor`, `DSPConfig`, `AnalysisTap`.
- Produces:
  - `CoreAudioError(status:operation:)`; `AudioObjectID` extension: `get(_:scope:initial:)`, `getArray(_:scope:zero:)`, `getString(_:scope:)`, `has(_:scope:)`, `isSettable(_:scope:)`, `set(_:scope:value:)`
  - `AudioDevice` (`id: AudioObjectID, uid: String, name: String, transportType: UInt32`, Identifiable/Hashable/Sendable)
  - `AudioSystem.outputDevices() -> [AudioDevice]`, `defaultOutputDevice() throws -> AudioObjectID`, `setDefaultOutputDevice(_:) throws`, `describe(_:) throws -> AudioDevice`, `streamCount(_:scope:) -> Int`, `nominalSampleRate(_:) throws -> Double`, `processObject(forPID:) throws -> AudioObjectID`, `validatedExclusions(_:) throws -> [AudioObjectID]`, `hardwareVolume(_:) -> Float?`, `setHardwareVolume(_:_:) -> Bool`
  - `PropertyListener(object:selector:scope:handler:) throws` (handler on main queue; removed on deinit)
  - `ChannelIO.frameCount(of:)`, `ChannelIO.readStereo(from:bufferIndex:frames:left:right:)`, `ChannelIO.writeStereo(left:right:frames:to:)`
  - `Renderer`: `analysis: AnalysisTap`, `submit(_ config: DSPConfig)`, `prepare(sampleRate:inputStreamOffset:)`, `render(input:output:)`, `lastCallbackNanos() -> UInt64`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxAudioTests/ChannelIOTests.swift`:
```swift
import XCTest
import CoreAudio
@testable import EquinoxAudio

final class ChannelIOTests: XCTestCase {
    /// Builds an AudioBufferList with interleaved Float32 buffers having the given channel counts.
    func makeList(_ channels: [Int], frames: Int, fill: Float = 0) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (i, ch) in channels.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: ch * frames)
            p.initialize(repeating: fill, count: ch * frames)
            list[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(ch * frames * 4), mData: p)
        }
        return list
    }

    func samples(_ list: UnsafeMutableAudioBufferListPointer, _ i: Int) -> [Float] {
        let b = list[i]
        return Array(UnsafeBufferPointer(start: b.mData!.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4))
    }

    func testReadStereoDeinterleavesAndDuplicatesMono() {
        let stereo = makeList([2], frames: 3)
        let p = stereo[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<6 { p[i] = Float(i) }
        var l = [Float](repeating: 9, count: 3), r = l
        ChannelIO.readStereo(from: stereo, bufferIndex: 0, frames: 3, left: &l, right: &r)
        XCTAssertEqual(l, [0, 2, 4]); XCTAssertEqual(r, [1, 3, 5])

        let mono = makeList([1], frames: 2, fill: 0.5)
        ChannelIO.readStereo(from: mono, bufferIndex: 0, frames: 2, left: &l, right: &r)
        XCTAssertEqual(Array(l[0..<2]), [0.5, 0.5]); XCTAssertEqual(Array(r[0..<2]), [0.5, 0.5])
    }

    func testReadMissingBufferGivesSilence() {
        let list = makeList([2], frames: 2)
        var l: [Float] = [1, 1], r: [Float] = [1, 1]
        ChannelIO.readStereo(from: list, bufferIndex: 3, frames: 2, left: &l, right: &r)
        XCTAssertEqual(l, [0, 0]); XCTAssertEqual(r, [0, 0])
    }

    func testWriteStereoFillsFirstTwoChannelsAndZerosRest() {
        let out = makeList([4], frames: 2, fill: 7)
        ChannelIO.writeStereo(left: [1, 2], right: [3, 4], frames: 2, to: out)
        XCTAssertEqual(samples(out, 0), [1, 3, 0, 0, 2, 4, 0, 0])
    }

    func testWriteStereoAcrossSeparateMonoBuffers() {
        let out = makeList([1, 1, 1], frames: 2, fill: 7)
        ChannelIO.writeStereo(left: [1, 2], right: [3, 4], frames: 2, to: out)
        XCTAssertEqual(samples(out, 0), [1, 2]); XCTAssertEqual(samples(out, 1), [3, 4]); XCTAssertEqual(samples(out, 2), [0, 0])
    }

    func testWriteToMonoOutputMixesDown() {
        let out = makeList([1], frames: 2)
        ChannelIO.writeStereo(left: [1, 0], right: [0, 1], frames: 2, to: out)
        XCTAssertEqual(samples(out, 0), [0.5, 0.5])
    }

    func testFrameCount() {
        XCTAssertEqual(ChannelIO.frameCount(of: makeList([2], frames: 256)), 256)
    }
}
```

`Tests/EquinoxAudioTests/AudioSystemTests.swift`:
```swift
import XCTest
import CoreAudio
@testable import EquinoxAudio

final class AudioSystemTests: XCTestCase {
    func testExclusionListRejectsUnknown() {
        XCTAssertThrowsError(try AudioSystem.validatedExclusions([AudioObjectID(kAudioObjectUnknown)]))
        XCTAssertThrowsError(try AudioSystem.validatedExclusions([]))
        XCTAssertEqual(try AudioSystem.validatedExclusions([42]), [42])
    }

    func testListsAtLeastOneOutputDeviceWithUID() throws {
        let devices = AudioSystem.outputDevices()
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        let defaultID = try AudioSystem.defaultOutputDevice()
        XCTAssertGreaterThan(try AudioSystem.nominalSampleRate(defaultID), 0)
    }

    func testResolvesOwnProcessObject() throws {
        _ = AudioSystem.outputDevices()   // ensure we are a HAL client
        XCTAssertNotEqual(try AudioSystem.processObject(forPID: getpid()), AudioObjectID(kAudioObjectUnknown))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EquinoxAudioTests`
Expected: compile failure — `cannot find 'ChannelIO' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxAudio/CoreAudioProperty.swift`:
```swift
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
```

`Sources/EquinoxAudio/AudioSystem.swift`:
```swift
import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transportType: UInt32

    public init(id: AudioObjectID, uid: String, name: String, transportType: UInt32) {
        self.id = id; self.uid = uid; self.name = name; self.transportType = transportType
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
                    transportType: (try? id.get(kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0)
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
```

`Sources/EquinoxAudio/ChannelIO.swift`:
```swift
import CoreAudio

/// Conversion between interleaved Float32 AudioBufferLists and planar stereo. Realtime-safe.
public enum ChannelIO {
    public static func frameCount(of list: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = list.first, first.mNumberChannels > 0 else { return 0 }
        return Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
    }

    /// Reads channels 0/1 of buffer `bufferIndex` (mono is duplicated). Missing buffer → silence.
    public static func readStereo(from list: UnsafeMutableAudioBufferListPointer, bufferIndex: Int, frames: Int,
                                  left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard bufferIndex < list.count, let data = list[bufferIndex].mData else {
            left.update(repeating: 0, count: frames); right.update(repeating: 0, count: frames); return
        }
        let ch = Int(list[bufferIndex].mNumberChannels)
        let available = Int(list[bufferIndex].mDataByteSize) / max(ch * 4, 1)
        let n = min(frames, available)
        let src = data.assumingMemoryBound(to: Float.self)
        if ch >= 2 {
            for i in 0..<n { left[i] = src[i * ch]; right[i] = src[i * ch + 1] }
        } else if ch == 1 {
            for i in 0..<n { left[i] = src[i]; right[i] = src[i] }
        }
        if n < frames {
            (left + n).update(repeating: 0, count: frames - n); (right + n).update(repeating: 0, count: frames - n)
        }
    }

    /// Writes L/R into the first two channels across all buffers; zeroes everything else.
    /// A single-channel output receives (L+R)/2.
    public static func writeStereo(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                                   to list: UnsafeMutableAudioBufferListPointer) {
        var totalChannels = 0
        for b in list { totalChannels += Int(b.mNumberChannels) }
        var channelBase = 0
        for b in list {
            guard let data = b.mData else { continue }
            let ch = Int(b.mNumberChannels)
            let dst = data.assumingMemoryBound(to: Float.self)
            let capacity = Int(b.mDataByteSize) / 4
            dst.update(repeating: 0, count: capacity)
            let n = min(frames, capacity / max(ch, 1))
            for k in 0..<ch {
                let global = channelBase + k
                if totalChannels == 1 {
                    for i in 0..<n { dst[i] = 0.5 * (left[i] + right[i]) }
                } else if global == 0 {
                    for i in 0..<n { dst[i * ch + k] = left[i] }
                } else if global == 1 {
                    for i in 0..<n { dst[i * ch + k] = right[i] }
                }
            }
            channelBase += ch
        }
    }
}
```

`Sources/EquinoxAudio/Renderer.swift`:
```swift
import CoreAudio
import EquinoxDSP
import Foundation
import os
import Synchronization

/// Hands immutable configs from the main thread to the audio thread without blocking it.
final class ConfigMailbox: @unchecked Sendable {
    private let pending = OSAllocatedUnfairLock<DSPConfig?>(initialState: nil)
    /// Main-thread history keeps recently replaced configs alive so the audio thread never frees one.
    private var history: [DSPConfig] = []

    func post(_ config: DSPConfig) {
        history.append(config)
        if history.count > 16 { history.removeFirst(history.count - 16) }
        pending.withLock { $0 = config }
    }

    /// Realtime-safe: returns nil if nothing is pending or the lock is momentarily held.
    func take() -> DSPConfig? {
        pending.withLockIfAvailable { (state: inout DSPConfig?) -> DSPConfig? in
            let c = state; state = nil; return c
        } ?? nil
    }
}

/// Owns the realtime render path invoked by the aggregate device's IOProc.
public final class Renderer: @unchecked Sendable {
    public static let maxFrames = 4096

    public let analysis = AnalysisTap()
    private let mailbox = ConfigMailbox()
    private var processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: 48_000)
    private var current: DSPConfig?
    private var inputStreamOffset = 0
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxFrames * 4)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxFrames * 4)
    private let lastCallback = Atomic<UInt64>(0)

    public init() {
        left.initialize(repeating: 0, count: Renderer.maxFrames * 4)
        right.initialize(repeating: 0, count: Renderer.maxFrames * 4)
    }

    deinit { left.deallocate(); right.deallocate() }

    /// Main thread.
    public func submit(_ config: DSPConfig) { mailbox.post(config) }

    /// Main thread, only while the IOProc is stopped.
    func prepare(sampleRate: Double, inputStreamOffset: Int) {
        processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: sampleRate)
        current = nil
        self.inputStreamOffset = inputStreamOffset
    }

    public func lastCallbackNanos() -> UInt64 { lastCallback.load(ordering: .relaxed) }

    /// Audio thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        lastCallback.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        let out = UnsafeMutableAudioBufferListPointer(output)
        let inp = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = min(ChannelIO.frameCount(of: out), Renderer.maxFrames * 4)
        guard frames > 0 else { return }

        if let config = mailbox.take() {
            current = config   // previous config stays alive in the mailbox history
            processor.apply(config)
        }
        ChannelIO.readStereo(from: inp, bufferIndex: inputStreamOffset, frames: frames, left: left, right: right)
        if current != nil { processor.process(left: left, right: right, frames: frames) }
        analysis.write(left: left, right: right, frames: frames)
        ChannelIO.writeStereo(left: left, right: right, frames: frames, to: out)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EquinoxAudioTests`
Expected: 9 tests PASS. (`AudioSystemTests` touch the real HAL; they need an output device, which this Mac has.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(audio): Core Audio helpers, device/process queries, ChannelIO, realtime Renderer"
```

---

### Task 7: TapSession, AudioController, app bundle — first audible end-to-end

**Files:**
- Create: `Sources/EquinoxAudio/TapSession.swift`, `Sources/EquinoxAudio/AudioController.swift`, `Resources/Info.plist`, `scripts/build-app.sh`
- Modify: `Sources/Equinox/EquinoxApp.swift` (temporary debug UI, replaced in Task 10)

**Interfaces:**
- Consumes: everything from Task 6, `DSPSettings`, `DSPConfig`.
- Produces:
  - `TapSession(outputDeviceID:excludedProcesses:renderer:) throws`, `.sampleRate`, `.start() throws`, `.invalidate()`
  - `AudioStatus` (`.stopped`, `.running(deviceName: String, sampleRate: Double)`, `.failed(String)`), `.isRunning`
  - `@MainActor protocol AudioControlling: AnyObject` with `onStatusChange: ((AudioStatus) -> Void)?`, `onOutputDeviceChange: ((AudioDevice) -> Void)?`, `onHardwareVolumeChange: ((Float) -> Void)?`, `analysis: AnalysisTap`, `start()`, `stop()`, `restart()`, `apply(_ settings: DSPSettings)`, `outputDevices() -> [AudioDevice]`, `selectOutputDevice(_:)`, `setHardwareVolume(_ volume: Float) -> Bool`
  - `AudioController: AudioControlling`

- [ ] **Step 1: Implement TapSession**

`Sources/EquinoxAudio/TapSession.swift`:
```swift
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
```

- [ ] **Step 2: Implement AudioController**

`Sources/EquinoxAudio/AudioController.swift`:
```swift
import CoreAudio
import EquinoxDSP
import Foundation
import os

public enum AudioStatus: Equatable, Sendable {
    case stopped
    case running(deviceName: String, sampleRate: Double)
    case failed(String)

    public var isRunning: Bool { if case .running = self { true } else { false } }
}

@MainActor
public protocol AudioControlling: AnyObject {
    var onStatusChange: ((AudioStatus) -> Void)? { get set }
    var onOutputDeviceChange: ((AudioDevice) -> Void)? { get set }
    var onHardwareVolumeChange: ((Float) -> Void)? { get set }
    var analysis: AnalysisTap { get }
    func start()
    func stop()
    func restart()
    func apply(_ settings: DSPSettings)
    func outputDevices() -> [AudioDevice]
    func selectOutputDevice(_ device: AudioDevice)
    /// Returns false when the current device has no settable hardware volume.
    func setHardwareVolume(_ volume: Float) -> Bool
}

@MainActor
public final class AudioController: AudioControlling {
    private static let log = Logger(subsystem: "com.pie.equinox", category: "audio")

    public var onStatusChange: ((AudioStatus) -> Void)?
    public var onOutputDeviceChange: ((AudioDevice) -> Void)?
    public var onHardwareVolumeChange: ((Float) -> Void)?
    public private(set) var status: AudioStatus = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public let renderer = Renderer()
    public var analysis: AnalysisTap { renderer.analysis }

    private var session: TapSession?
    private var settings = DSPSettings()
    private var wantsRunning = false
    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var rebuildTask: Task<Void, Never>?
    private var watchdog: Timer?

    public init() {}

    public func start() {
        wantsRunning = true
        if systemListeners.isEmpty {
            systemListeners = [
                try? PropertyListener(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRebuild() }
                },
                try? PropertyListener(object: .system, selector: kAudioHardwarePropertyDevices) { [weak self] in
                    MainActor.assumeIsolated { self?.devicesChanged() }
                },
            ].compactMap { $0 }
        }
        rebuild()
        startWatchdog()
    }

    public func stop() {
        wantsRunning = false
        rebuildTask?.cancel()
        watchdog?.invalidate(); watchdog = nil
        tearDown()
        status = .stopped
    }

    public func restart() { if wantsRunning { rebuild() } else { start() } }

    public func apply(_ settings: DSPSettings) {
        self.settings = settings
        if let session { renderer.submit(DSPConfig(settings: settings, sampleRate: session.sampleRate)) }
    }

    public func outputDevices() -> [AudioDevice] { AudioSystem.outputDevices() }

    public func selectOutputDevice(_ device: AudioDevice) {
        do { try AudioSystem.setDefaultOutputDevice(device.id) }   // listener triggers the rebuild
        catch { Self.log.error("Select output failed: \(String(describing: error))") }
    }

    public func setHardwareVolume(_ volume: Float) -> Bool {
        guard let id = session?.outputDeviceID ?? (try? AudioSystem.defaultOutputDevice()) else { return false }
        return AudioSystem.setHardwareVolume(id, volume)
    }

    // MARK: - Session lifecycle

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    private func devicesChanged() {
        guard let session else { return }
        if !AudioSystem.outputDevices().contains(where: { $0.id == session.outputDeviceID }) { scheduleRebuild() }
    }

    private func tearDown() {
        deviceListeners = []
        session?.invalidate()
        session = nil
    }

    private func rebuild() {
        tearDown()
        guard wantsRunning else { return }
        do {
            let deviceID = try AudioSystem.defaultOutputDevice()
            let device = try AudioSystem.describe(deviceID)
            let ownProcess = try AudioSystem.processObject(forPID: getpid())
            let newSession = try TapSession(outputDeviceID: deviceID, excludedProcesses: [ownProcess], renderer: renderer)
            renderer.submit(DSPConfig(settings: settings, sampleRate: newSession.sampleRate))
            try newSession.start()
            session = newSession
            deviceListeners = [
                try? PropertyListener(object: deviceID, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRebuild() }
                },
                try? PropertyListener(object: deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                      scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                    MainActor.assumeIsolated {
                        if let v = AudioSystem.hardwareVolume(deviceID) { self?.onHardwareVolumeChange?(v) }
                    }
                },
            ].compactMap { $0 }
            status = .running(deviceName: device.name, sampleRate: newSession.sampleRate)
            onOutputDeviceChange?(device)
            if let v = AudioSystem.hardwareVolume(deviceID) { onHardwareVolumeChange?(v) }
            Self.log.info("Running on \(device.name) @ \(newSession.sampleRate) Hz")
        } catch {
            tearDown()
            status = .failed(String(describing: error))
            Self.log.error("Start failed: \(String(describing: error))")
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning, self.session != nil else { return }
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let last = self.renderer.lastCallbackNanos()
                if last != 0, now > last, now - last > 2_000_000_000 {
                    Self.log.warning("Audio callback stalled; rebuilding")
                    self.rebuild()
                }
            }
        }
    }
}
```

- [ ] **Step 3: Bundle files and temporary debug app**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.pie.equinox</string>
    <key>CFBundleName</key><string>Equinox</string>
    <key>CFBundleDisplayName</key><string>Equinox</string>
    <key>CFBundleExecutable</key><string>Equinox</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSAudioCaptureUsageDescription</key><string>Equinox processes your Mac's audio output so it can apply the equalizer and effects.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

`scripts/build-app.sh` (then `chmod +x scripts/build-app.sh`):
```bash
#!/usr/bin/env bash
# Builds and signs build/Equinox.app. Usage: scripts/build-app.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_ID="${SIGN_ID:-Apple Development}"

swift build -c "$CONFIG" --product Equinox
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Equinox.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Equinox" "$APP/Contents/MacOS/Equinox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Equinox 2>/dev/null || true
    open "$APP"
fi
```

Temporary `Sources/Equinox/EquinoxApp.swift` (debug UI to prove the pipeline; replaced in Task 10):
```swift
import EquinoxAudio
import EquinoxDSP
import SwiftUI

@MainActor
final class DebugModel: ObservableObject {
    let audio = AudioController()
    @Published var status: AudioStatus = .stopped
    @Published var bassTest = false { didSet { push() } }

    init() {
        audio.onStatusChange = { [weak self] in self?.status = $0 }
        audio.start()
        push()
    }

    func push() {
        var s = DSPSettings()
        s.bands = bassTest ? [EQBand(type: .lowShelf, frequency: 150, gainDB: 12, q: 0.7)] : []
        s.preampDB = bassTest ? -6 : 0
        audio.apply(s)
    }
}

@main
struct EquinoxApp: App {
    @StateObject private var model = DebugModel()

    var body: some Scene {
        MenuBarExtra("Equinox", systemImage: "waveform.circle") {
            Text(String(describing: model.status))
            Toggle("Bass test (+12 dB low shelf)", isOn: $model.bassTest)
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
```

- [ ] **Step 4: Build and run**

Run: `swift build 2>&1 | tail -5 && scripts/build-app.sh --run`
Expected: `Built build/Equinox.app`; a waveform icon appears in the menu bar; macOS asks for **System Audio Recording** permission (grant it).

- [ ] **Step 5: Verify capture end-to-end**

Run: `log stream --predicate 'subsystem == "com.pie.equinox"' --style compact` in a background shell for ~10 s.
Expected: `Running on <device> @ <rate> Hz`, no `Start failed`.

Then ask the human partner to: play music, toggle **Bass test** (bass should get obviously heavier, with no crackles), switch output device (e.g. to headphones) and confirm audio continues, then quit Equinox and confirm audio still plays normally. Record the outcome in the task notes. If audio is silent while running, check System Settings → Privacy & Security → Screen & System Audio Recording → Equinox is enabled.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(audio): process-tap session, audio controller, app bundle script"
```

---

### Task 8: Settings, Store, EQGeometry, AppModel

**Files:**
- Create: `Sources/EquinoxCore/AppSettings.swift`, `Sources/EquinoxCore/Store.swift`, `Sources/EquinoxCore/LoginItem.swift`, `Sources/EquinoxCore/EQGeometry.swift`, `Sources/EquinoxCore/AppModel.swift`
- Test: `Tests/EquinoxCoreTests/StoreTests.swift`, `Tests/EquinoxCoreTests/EQGeometryTests.swift`, `Tests/EquinoxCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `Preset`, `AudioControlling`, `AudioStatus`, `AudioDevice`, `DSPSettings`, `EQBand`, `AnalysisTap`.
- Produces:
  - `DeviceProfile(presetID: UUID, isEnabled: Bool)`; `AppSettings` (all fields with defaults, tolerant decoding): `selectedPresetID, workingPreset: Preset?, userPresets: [Preset], isEnabled, volume, boostDB, balance, isMuted, deviceProfiles: [String: DeviceProfile], hasCompletedOnboarding, launchAtLogin`
  - `Store(directory: URL = Store.defaultDirectory)`, `load<T: Decodable>(_:from:) -> (value: T?, wasCorrupt: Bool)`, `save<T: Encodable>(_:to:) throws`
  - `LoginItemControlling` (`isEnabled: Bool { get }`, `setEnabled(_:) throws`), `SystemLoginItem`
  - `EQGeometry(size:)`: `x(for:)`, `frequency(atX:)`, `y(forDB:)`, `db(atY:)`, `static dbRange = 24.0`
  - `AppModel` (`@MainActor @Observable`): `status, devices, currentDevice, presets, userPresets, selectedPreset, working, isModified, isEnabled, volume, boostDB, balance, isMuted, preampDB, hasCompletedOnboarding, launchAtLogin, sampleRate, analysis, lastError`; methods `launch()`, `completeOnboarding()`, `selectPreset(_ id: UUID)`, `updateBand(_ id: UUID, _ change: (inout EQBand) -> Void)`, `addBand(frequency:gainDB:) -> UUID?`, `removeBand(_:)`, `save()`, `saveAs(name:)`, `revert()`, `deletePreset(_:)`, `renamePreset(_:to:)`, `importPresets(from:) throws`, `exportData(for:) throws -> Data`, `selectOutputDevice(_:)`, `refreshDevices()`, `restartAudio()`, `flushSave()`

- [ ] **Step 1: Write the failing tests**

`Tests/EquinoxCoreTests/StoreTests.swift`:
```swift
import XCTest
@testable import EquinoxCore

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-tests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRoundTrip() throws {
        let store = Store(directory: dir)
        var s = AppSettings(); s.boostDB = 4; s.hasCompletedOnboarding = true
        try store.save(s, to: "settings.json")
        let loaded = store.load(AppSettings.self, from: "settings.json")
        XCTAssertEqual(loaded.value, s); XCTAssertFalse(loaded.wasCorrupt)
    }

    func testMissingFileIsNotCorrupt() {
        let r = Store(directory: dir).load(AppSettings.self, from: "settings.json")
        XCTAssertNil(r.value); XCTAssertFalse(r.wasCorrupt)
    }

    func testCorruptFileIsQuarantined() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let r = Store(directory: dir).load(AppSettings.self, from: "settings.json")
        XCTAssertNil(r.value); XCTAssertTrue(r.wasCorrupt)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains("settings.json"))
        XCTAssertTrue(files.contains { $0.hasPrefix("settings.json.corrupt-") })
    }

    func testMissingKeysUseDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"boostDB": 3}"#.utf8))
        XCTAssertEqual(s.boostDB, 3)
        XCTAssertEqual(s.selectedPresetID, Preset.flat.id)
        XCTAssertTrue(s.isEnabled)
        XCTAssertEqual(s.volume, 1)
    }
}
```

`Tests/EquinoxCoreTests/EQGeometryTests.swift`:
```swift
import XCTest
@testable import EquinoxCore

final class EQGeometryTests: XCTestCase {
    func testMappingRoundTripsAndEdges() {
        let g = EQGeometry(size: CGSize(width: 600, height: 300))
        XCTAssertEqual(g.x(for: 20), 0, accuracy: 0.001)
        XCTAssertEqual(g.x(for: 20000), 600, accuracy: 0.001)
        XCTAssertEqual(g.frequency(atX: g.x(for: 1234)), 1234, accuracy: 0.01)
        XCTAssertEqual(g.y(forDB: 0), 150, accuracy: 0.001)
        XCTAssertEqual(g.db(atY: g.y(forDB: 7.5)), 7.5, accuracy: 0.001)
        XCTAssertLessThan(g.y(forDB: 24), g.y(forDB: 0))
        XCTAssertEqual(g.frequency(atX: -50), 20, accuracy: 0.001)   // clamped
    }
}
```

`Tests/EquinoxCoreTests/AppModelTests.swift`:
```swift
import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

@MainActor
final class FakeAudio: AudioControlling {
    var onStatusChange: ((AudioStatus) -> Void)?
    var onOutputDeviceChange: ((AudioDevice) -> Void)?
    var onHardwareVolumeChange: ((Float) -> Void)?
    let analysis = AnalysisTap()
    var applied: [DSPSettings] = []
    var started = 0
    var hasHardwareVolume = true
    var hardwareVolume: Float = -1
    var devices = [AudioDevice(id: 1, uid: "speakers", name: "Speakers", transportType: 0),
                   AudioDevice(id: 2, uid: "headphones", name: "Headphones", transportType: 0)]

    func start() { started += 1 }
    func stop() {}
    func restart() {}
    func apply(_ settings: DSPSettings) { applied.append(settings) }
    func outputDevices() -> [AudioDevice] { devices }
    func selectOutputDevice(_ device: AudioDevice) { onOutputDeviceChange?(device) }
    func setHardwareVolume(_ volume: Float) -> Bool {
        guard hasHardwareVolume else { return false }
        hardwareVolume = volume; return true
    }
}

final class FakeLoginItem: LoginItemControlling {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
final class AppModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-model-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel() -> AppModel { AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem()) }

    func testInitPushesSelectedPreset() {
        _ = makeModel()
        XCTAssertEqual(audio.applied.last?.bands, Preset.flat.bands)
    }

    func testLaunchStartsAudioOnlyAfterOnboarding() {
        let m = makeModel()
        m.launch(); XCTAssertEqual(audio.started, 0)
        m.completeOnboarding(); XCTAssertEqual(audio.started, 1)
        XCTAssertTrue(m.hasCompletedOnboarding)
    }

    func testSelectingPresetAppliesBandsAndPreamp() {
        let m = makeModel()
        let bass = Preset.builtIns[1]
        m.selectPreset(bass.id)
        XCTAssertEqual(m.working.bands, bass.bands)
        XCTAssertEqual(audio.applied.last?.bands, bass.bands)
        XCTAssertEqual(audio.applied.last?.preampDB, bass.preampDB)
        XCTAssertFalse(m.isModified)
    }

    func testEditingMarksModifiedAndSaveAsCreatesUserPreset() {
        let m = makeModel()
        let id = m.working.bands[0].id
        m.updateBand(id) { $0.gainDB = 5 }
        XCTAssertTrue(m.isModified)
        XCTAssertEqual(audio.applied.last?.bands[0].gainDB, 5)
        m.saveAs(name: "Mine")
        XCTAssertEqual(m.selectedPreset.name, "Mine")
        XCTAssertFalse(m.selectedPreset.isBuiltIn)
        XCTAssertFalse(m.isModified)
        XCTAssertEqual(m.userPresets.count, 1)
    }

    func testRevertRestoresSavedBands() {
        let m = makeModel()
        m.updateBand(m.working.bands[0].id) { $0.gainDB = 9 }
        m.revert()
        XCTAssertEqual(m.working.bands, Preset.flat.bands)
    }

    func testBandEditsAreClampedAndCapped() {
        let m = makeModel()
        m.updateBand(m.working.bands[0].id) { $0.gainDB = 100; $0.frequency = 1 }
        XCTAssertEqual(m.working.bands[0].gainDB, 24); XCTAssertEqual(m.working.bands[0].frequency, 20)
        for _ in 0..<40 { _ = m.addBand(frequency: 1000, gainDB: 0) }
        XCTAssertEqual(m.working.bands.count, BiquadBank.maxSections)
        XCTAssertNil(m.addBand(frequency: 1000, gainDB: 0))
    }

    func testDisablingBypassesAudio() {
        let m = makeModel()
        m.isEnabled = false
        XCTAssertEqual(audio.applied.last?.isBypassed, true)
    }

    func testVolumeUsesHardwareWhenAvailableElseSoftware() {
        let m = makeModel()
        m.volume = 0.4
        XCTAssertEqual(audio.hardwareVolume, 0.4, accuracy: 1e-6)
        XCTAssertEqual(audio.applied.last?.softwareVolume, 1)
        audio.hasHardwareVolume = false
        m.volume = 0.3
        XCTAssertEqual(audio.applied.last?.softwareVolume ?? 0, 0.3, accuracy: 1e-9)
    }

    func testExternalHardwareVolumeChangeUpdatesModelWithoutEcho() {
        let m = makeModel()
        audio.hardwareVolume = -1
        audio.onHardwareVolumeChange?(0.25)
        XCTAssertEqual(m.volume, 0.25, accuracy: 1e-6)
        XCTAssertEqual(audio.hardwareVolume, -1)   // did not write back
    }

    func testDeviceProfilesAreRememberedPerDevice() {
        let m = makeModel()
        audio.onOutputDeviceChange?(audio.devices[0])
        m.selectPreset(Preset.builtIns[1].id)
        audio.onOutputDeviceChange?(audio.devices[1])
        m.selectPreset(Preset.builtIns[3].id)
        audio.onOutputDeviceChange?(audio.devices[0])
        XCTAssertEqual(m.selectedPreset.id, Preset.builtIns[1].id)
        audio.onOutputDeviceChange?(audio.devices[1])
        XCTAssertEqual(m.selectedPreset.id, Preset.builtIns[3].id)
    }

    func testStatePersistsAcrossInstances() {
        let m = makeModel()
        m.saveAs(name: "Keep")
        m.boostDB = 6
        m.flushSave()
        let m2 = makeModel()
        XCTAssertEqual(m2.selectedPreset.name, "Keep")
        XCTAssertEqual(m2.boostDB, 6)
    }

    func testImportGarbageThrowsAndLeavesStateUnchanged() {
        let m = makeModel()
        XCTAssertThrowsError(try m.importPresets(from: Data("garbage".utf8)))
        XCTAssertTrue(m.userPresets.isEmpty)
        XCTAssertEqual(m.selectedPreset.id, Preset.flat.id)
    }

    func testDeletingSelectedUserPresetFallsBackToFlat() {
        let m = makeModel()
        m.saveAs(name: "Temp")
        m.deletePreset(m.selectedPreset.id)
        XCTAssertEqual(m.selectedPreset.id, Preset.flat.id)
        XCTAssertTrue(m.userPresets.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EquinoxCoreTests`
Expected: compile failure — `cannot find 'Store' in scope`.

- [ ] **Step 3: Implement**

`Sources/EquinoxCore/AppSettings.swift`:
```swift
import Foundation

public struct DeviceProfile: Codable, Equatable, Sendable {
    public var presetID: UUID
    public var isEnabled: Bool
    public init(presetID: UUID, isEnabled: Bool) { self.presetID = presetID; self.isEnabled = isEnabled }
}

/// Persisted state. Every field has a default and decoding tolerates missing keys,
/// so settings written by older builds always load.
public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedPresetID: UUID = Preset.flat.id
    public var workingPreset: Preset?
    public var userPresets: [Preset] = []
    public var isEnabled = true
    public var volume = 1.0
    public var boostDB = 0.0
    public var balance = 0.0
    public var isMuted = false
    public var deviceProfiles: [String: DeviceProfile] = [:]
    public var hasCompletedOnboarding = false
    public var launchAtLogin = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case selectedPresetID, workingPreset, userPresets, isEnabled, volume, boostDB, balance, isMuted,
             deviceProfiles, hasCompletedOnboarding, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        selectedPresetID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedPresetID)) ?? d.selectedPresetID
        workingPreset = try? c.decodeIfPresent(Preset.self, forKey: .workingPreset)
        userPresets = (try? c.decodeIfPresent([Preset].self, forKey: .userPresets)) ?? d.userPresets
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
        boostDB = (try? c.decodeIfPresent(Double.self, forKey: .boostDB)) ?? d.boostDB
        balance = (try? c.decodeIfPresent(Double.self, forKey: .balance)) ?? d.balance
        isMuted = (try? c.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? d.isMuted
        deviceProfiles = (try? c.decodeIfPresent([String: DeviceProfile].self, forKey: .deviceProfiles)) ?? d.deviceProfiles
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
    }
}
```

`Sources/EquinoxCore/Store.swift`:
```swift
import Foundation

/// JSON files in Application Support. Writes are atomic; unreadable files are quarantined.
public final class Store {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Equinox", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = Store.defaultDirectory) { self.directory = directory }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> (value: T?, wasCorrupt: Bool) {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return (nil, false) }
        do {
            return (try JSONDecoder().decode(T.self, from: data), false)
        } catch {
            let quarantine = directory.appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return (nil, true)
        }
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
```

`Sources/EquinoxCore/LoginItem.swift`:
```swift
import ServiceManagement

public protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public final class SystemLoginItem: LoginItemControlling {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
```

`Sources/EquinoxCore/EQGeometry.swift`:
```swift
import CoreGraphics
import Foundation

/// Maps between canvas points and (frequency, dB). Log frequency axis 20 Hz–20 kHz, linear ±24 dB.
public struct EQGeometry: Sendable {
    public static let dbRange = 24.0
    public static let minFrequency = 20.0
    public static let maxFrequency = 20_000.0

    public var size: CGSize
    public init(size: CGSize) { self.size = size }

    private var decades: Double { log10(Self.maxFrequency / Self.minFrequency) }

    public func x(for frequency: Double) -> CGFloat {
        CGFloat(log10(max(frequency, Self.minFrequency) / Self.minFrequency) / decades) * size.width
    }

    public func frequency(atX x: CGFloat) -> Double {
        let t = min(max(Double(x / max(size.width, 1)), 0), 1)
        return Self.minFrequency * pow(10, t * decades)
    }

    public func y(forDB db: Double) -> CGFloat {
        size.height / 2 - CGFloat(db / Self.dbRange) * size.height / 2
    }

    public func db(atY y: CGFloat) -> Double {
        let v = Double((size.height / 2 - y) / max(size.height / 2, 1)) * Self.dbRange
        return min(max(v, -Self.dbRange), Self.dbRange)
    }
}
```

`Sources/EquinoxCore/AppModel.swift`:
```swift
import EquinoxAudio
import EquinoxDSP
import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    private static let settingsFile = "settings.json"

    // MARK: Audio state
    public private(set) var status: AudioStatus = .stopped
    public private(set) var devices: [AudioDevice] = []
    public private(set) var currentDevice: AudioDevice?
    public var analysis: AnalysisTap { audio.analysis }
    public var sampleRate: Double { if case .running(_, let rate) = status { rate } else { 48_000 } }

    // MARK: Presets
    public private(set) var userPresets: [Preset] = []
    public private(set) var selectedPresetID: UUID = Preset.flat.id
    /// The edited copy that is audible right now.
    public private(set) var working: Preset = Preset.flat
    public var presets: [Preset] { Preset.builtIns + userPresets }
    public var selectedPreset: Preset { presets.first { $0.id == selectedPresetID } ?? Preset.flat }
    public var isModified: Bool { working.bands != selectedPreset.bands || working.preampDB != selectedPreset.preampDB }

    // MARK: Controls
    public var isEnabled = true { didSet { recordDeviceProfile(); push() } }
    public var volume = 1.0 { didSet { volumeChanged() } }
    public var boostDB = 0.0 { didSet { push() } }
    public var balance = 0.0 { didSet { push() } }
    public var isMuted = false { didSet { push() } }
    public var preampDB: Double {
        get { working.preampDB }
        set { working.preampDB = min(max(newValue, -24), 24); push() }
    }
    public private(set) var hasCompletedOnboarding = false
    public var launchAtLogin = false { didSet { applyLaunchAtLogin(oldValue) } }
    public private(set) var lastError: String?

    // MARK: Private
    @ObservationIgnored private let audio: AudioControlling
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private var deviceProfiles: [String: DeviceProfile] = [:]
    @ObservationIgnored private var usesSoftwareVolume = false
    @ObservationIgnored private var applyingExternalVolume = false
    @ObservationIgnored private var restoring = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(audio: AudioControlling, store: Store = Store(), loginItem: LoginItemControlling = SystemLoginItem()) {
        self.audio = audio
        self.store = store
        self.loginItem = loginItem

        let loaded = store.load(AppSettings.self, from: Self.settingsFile)
        let s = loaded.value ?? AppSettings()
        if loaded.wasCorrupt { lastError = "Settings file was unreadable and has been reset." }
        userPresets = s.userPresets
        selectedPresetID = presets.contains { $0.id == s.selectedPresetID } ? s.selectedPresetID : Preset.flat.id
        working = s.workingPreset.flatMap { $0.id == selectedPresetID ? $0 : nil } ?? selectedPreset
        isEnabled = s.isEnabled
        volume = min(max(s.volume, 0), 1)
        boostDB = min(max(s.boostDB, 0), DSPSettings.maxBoostDB)
        balance = min(max(s.balance, -1), 1)
        isMuted = s.isMuted
        deviceProfiles = s.deviceProfiles
        hasCompletedOnboarding = s.hasCompletedOnboarding
        launchAtLogin = s.launchAtLogin
        restoring = false

        audio.onStatusChange = { [weak self] in self?.status = $0 }
        audio.onOutputDeviceChange = { [weak self] in self?.outputDeviceChanged($0) }
        audio.onHardwareVolumeChange = { [weak self] in self?.hardwareVolumeChanged($0) }
        devices = audio.outputDevices()
        push()
    }

    // MARK: Lifecycle

    public func launch() { if hasCompletedOnboarding { audio.start() } }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        audio.start()
        scheduleSave()
    }

    public func restartAudio() { audio.restart() }

    // MARK: Presets

    public func selectPreset(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        selectedPresetID = id
        working = preset
        recordDeviceProfile()
        push()
    }

    public func updateBand(_ id: UUID, _ change: (inout EQBand) -> Void) {
        guard let i = working.bands.firstIndex(where: { $0.id == id }) else { return }
        var band = working.bands[i]
        change(&band)
        working.bands[i] = band.clamped()
        push()
    }

    /// Returns nil when the band limit is reached.
    @discardableResult
    public func addBand(frequency: Double, gainDB: Double) -> UUID? {
        guard working.bands.count < BiquadBank.maxSections else { return nil }
        let band = EQBand(type: .peak, frequency: frequency, gainDB: gainDB, q: 1).clamped()
        working.bands.append(band)
        working.bands.sort { $0.frequency < $1.frequency }
        push()
        return band.id
    }

    public func removeBand(_ id: UUID) {
        working.bands.removeAll { $0.id == id }
        push()
    }

    /// Saves edits into the selected user preset (built-ins are read-only; use saveAs).
    public func save() {
        guard let i = userPresets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        userPresets[i].bands = working.bands
        userPresets[i].preampDB = working.preampDB
        working = userPresets[i]
        push()
    }

    public func saveAs(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(name: trimmed.isEmpty ? "Untitled" : trimmed, preampDB: working.preampDB,
                            bands: working.bands, isBuiltIn: false)
        userPresets.append(preset)
        selectPreset(preset.id)
    }

    public func revert() { selectPreset(selectedPresetID) }

    public func deletePreset(_ id: UUID) {
        guard userPresets.contains(where: { $0.id == id }) else { return }
        userPresets.removeAll { $0.id == id }
        for (uid, profile) in deviceProfiles where profile.presetID == id {
            deviceProfiles[uid]?.presetID = Preset.flat.id
        }
        if selectedPresetID == id { selectPreset(Preset.flat.id) } else { scheduleSave() }
    }

    public func renamePreset(_ id: UUID, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets[i].name = trimmed
        if selectedPresetID == id { working.name = trimmed }
        scheduleSave()
    }

    public func importPresets(from data: Data) throws {
        let imported = try Preset.importPresets(from: data)
        userPresets.append(contentsOf: imported)
        selectPreset(imported[0].id)
    }

    public func exportData(for ids: [UUID]) throws -> Data {
        try Preset.exportData(presets.filter { ids.contains($0.id) })
    }

    // MARK: Devices

    public func refreshDevices() { devices = audio.outputDevices() }

    public func selectOutputDevice(_ device: AudioDevice) { audio.selectOutputDevice(device) }

    private func outputDeviceChanged(_ device: AudioDevice) {
        refreshDevices()
        guard device.uid != currentDevice?.uid else { return }
        currentDevice = device
        if let profile = deviceProfiles[device.uid] {
            if presets.contains(where: { $0.id == profile.presetID }) {
                selectedPresetID = profile.presetID
                working = selectedPreset
            }
            isEnabled = profile.isEnabled
        } else {
            recordDeviceProfile()
        }
        push()
    }

    private func recordDeviceProfile() {
        guard !restoring, let uid = currentDevice?.uid else { return }
        deviceProfiles[uid] = DeviceProfile(presetID: selectedPresetID, isEnabled: isEnabled)
    }

    // MARK: Volume

    private func volumeChanged() {
        guard !restoring else { return }
        if !applyingExternalVolume {
            usesSoftwareVolume = !audio.setHardwareVolume(Float(volume))
        }
        push()
    }

    private func hardwareVolumeChanged(_ value: Float) {
        usesSoftwareVolume = false
        applyingExternalVolume = true
        volume = Double(value)
        applyingExternalVolume = false
    }

    // MARK: Login item

    private func applyLaunchAtLogin(_ oldValue: Bool) {
        guard !restoring, launchAtLogin != oldValue else { return }
        do { try loginItem.setEnabled(launchAtLogin) }
        catch { lastError = "Could not change Launch at Login: \(error.localizedDescription)" }
        scheduleSave()
    }

    // MARK: Push & persist

    private func push() {
        guard !restoring else { return }
        var s = DSPSettings()
        s.isBypassed = !isEnabled
        s.preampDB = working.preampDB
        s.bands = working.bands
        s.softwareVolume = usesSoftwareVolume ? volume : 1
        s.boostDB = boostDB
        s.balance = balance
        s.isMuted = isMuted
        audio.apply(s)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    public func flushSave() {
        saveTask?.cancel()
        var s = AppSettings()
        s.selectedPresetID = selectedPresetID
        s.workingPreset = working
        s.userPresets = userPresets
        s.isEnabled = isEnabled
        s.volume = volume
        s.boostDB = boostDB
        s.balance = balance
        s.isMuted = isMuted
        s.deviceProfiles = deviceProfiles
        s.hasCompletedOnboarding = hasCompletedOnboarding
        s.launchAtLogin = launchAtLogin
        do { try store.save(s, to: Self.settingsFile) }
        catch { lastError = "Could not save settings: \(error.localizedDescription)" }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EquinoxCoreTests`
Expected: all Store (4), EQGeometry (1), AppModel (13), Preset (5) tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(core): settings store, EQ geometry and observable app model"
```

---

### Task 9: Visual layer — theme, spectrum, EQ canvas, band editing

**Files:**
- Create: `Sources/Equinox/Theme.swift`, `Sources/Equinox/SpectrumModel.swift`, `Sources/Equinox/EQCanvasView.swift`, `Sources/Equinox/BandInspector.swift`, `Sources/Equinox/GraphicEQView.swift`, `Sources/Equinox/Controls.swift`

**Interfaces:**
- Consumes: `AppModel`, `EQGeometry`, `EQResponse`, `SpectrumAnalyzer`, `AnalysisTap`, `FilterType`.
- Produces (used by Task 10): `Theme` (`cyan`, `violet`, `amber`, `background`, `accent`, `bandColor(_:)`), `View.glassCard(cornerRadius:padding:)`, `SpectrumModel(tap:sampleRate:)` with `levels`, `frequencies`, `peakLeft`, `peakRight`, `attach()`, `detach()`, `EQCanvasView(model:spectrum:interactive:selectedBandID:)`, `BandInspector(model:selectedBandID:)`, `GraphicEQView(model:)`, `VolumeControl(model:)`, `BalanceControl(model:)`, `MeterView(spectrum:)`, `VerticalSlider(value:range:tint:)`.

Views are verified visually (Step 7); logic they depend on is already unit-tested in `EQGeometry`/`AppModel`.

- [ ] **Step 1: Theme**

`Sources/Equinox/Theme.swift`:
```swift
import SwiftUI

enum Theme {
    static let cyan = Color(red: 0.25, green: 0.88, blue: 1.0)
    static let violet = Color(red: 0.62, green: 0.38, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let background = Color(red: 0.055, green: 0.06, blue: 0.09)
    static let accent = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)

    static func bandColor(_ index: Int) -> Color {
        Color(hue: (0.52 + Double(index % 8) * 0.045).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1)
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: f >= 10_000 ? "%.0fk" : "%.1fk", f / 1000) : String(format: "%.0f", f)
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(padding).glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.padding(padding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.08)))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }
}
```

- [ ] **Step 2: SpectrumModel**

`Sources/Equinox/SpectrumModel.swift`:
```swift
import EquinoxDSP
import Observation
import SwiftUI

/// Polls the analysis tap at display rate while at least one view is attached.
@MainActor
@Observable
final class SpectrumModel {
    private(set) var levels: [Float]
    private(set) var peakLeft: Float = 0
    private(set) var peakRight: Float = 0
    let frequencies: [Double]

    @ObservationIgnored private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored private let tap: AnalysisTap
    @ObservationIgnored private let sampleRate: () -> Double
    @ObservationIgnored private var samples: [Float]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clients = 0

    init(tap: AnalysisTap, sampleRate: @escaping () -> Double) {
        self.tap = tap
        self.sampleRate = sampleRate
        frequencies = analyzer.frequencies
        levels = Array(repeating: -120, count: analyzer.frequencies.count)
        samples = Array(repeating: 0, count: analyzer.fftSize)
    }

    func attach() {
        clients += 1
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        clients = max(clients - 1, 0)
        if clients == 0 { timer?.invalidate(); timer = nil }
    }

    private func tick() {
        tap.copyLatest(into: &samples)
        let fresh = analyzer.analyze(samples, sampleRate: sampleRate())
        var next = levels
        for i in next.indices {
            let target = fresh[i]
            next[i] = target > next[i] ? next[i] + (target - next[i]) * 0.6 : next[i] + (target - next[i]) * 0.12
        }
        levels = next
        let p = tap.takePeaks()
        peakLeft = max(p.left, peakLeft * 0.88)
        peakRight = max(p.right, peakRight * 0.88)
    }
}
```

- [ ] **Step 3: EQ canvas**

`Sources/Equinox/EQCanvasView.swift`:
```swift
import EquinoxCore
import EquinoxDSP
import SwiftUI

struct EQCanvasView: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    var interactive = true
    @Binding var selectedBandID: UUID?

    @State private var dragBandID: UUID?
    @State private var hoverBandID: UUID?
    @State private var pinchStartQ: Double?

    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]

    var body: some View {
        let levels = spectrum.levels
        let bands = model.working.bands
        let preamp = model.working.preampDB
        let rate = model.sampleRate
        let enabled = model.isEnabled
        GeometryReader { geo in
            let g = EQGeometry(size: geo.size)
            Canvas { ctx, size in
                drawGrid(ctx, g, size)
                drawSpectrum(ctx, g, size, levels)
                drawCurve(ctx, g, size, bands, preamp, rate, enabled)
                if interactive { drawNodes(ctx, g, bands) }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(g), including: interactive ? .all : .none)
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                guard interactive, nearestBand(to: v.location, in: g) == nil else { return }
                selectedBandID = model.addBand(frequency: g.frequency(atX: v.location.x), gainDB: g.db(atY: v.location.y))
            }, including: interactive ? .all : .none)
            .simultaneousGesture(MagnifyGesture().onChanged { v in
                guard let id = selectedBandID, let band = bands.first(where: { $0.id == id }) else { return }
                if pinchStartQ == nil { pinchStartQ = band.q }
                model.updateBand(id) { $0.q = (pinchStartQ ?? 1) * Double(v.magnification) }
            }.onEnded { _ in pinchStartQ = nil }, including: interactive ? .all : .none)
            .onContinuousHover { phase in
                guard interactive else { return }
                if case .active(let p) = phase { hoverBandID = nearestBand(to: p, in: g) } else { hoverBandID = nil }
            }
            .contextMenu { if interactive { bandMenu } }
        }
        .onAppear { spectrum.attach() }
        .onDisappear { spectrum.detach() }
    }

    // MARK: Interaction

    private func nearestBand(to p: CGPoint, in g: EQGeometry) -> UUID? {
        model.working.bands
            .map { b in (b.id, hypot(g.x(for: b.frequency) - p.x, g.y(forDB: nodeDB(b)) - p.y)) }
            .filter { $0.1 < 16 }
            .min { $0.1 < $1.1 }?.0
    }

    private func nodeDB(_ b: EQBand) -> Double { b.type.usesGain ? b.gainDB : 0 }

    private func dragGesture(_ g: EQGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBandID == nil {
                    dragBandID = nearestBand(to: v.startLocation, in: g)
                    if let id = dragBandID { selectedBandID = id }
                }
                guard let id = dragBandID else { return }
                let f = g.frequency(atX: v.location.x), db = g.db(atY: v.location.y)
                model.updateBand(id) { band in
                    band.frequency = f
                    if band.type.usesGain { band.gainDB = (db * 10).rounded() / 10 }
                }
            }
            .onEnded { _ in dragBandID = nil }
    }

    @ViewBuilder private var bandMenu: some View {
        if let id = hoverBandID ?? selectedBandID, let band = model.working.bands.first(where: { $0.id == id }) {
            Picker("Type", selection: Binding(get: { band.type }, set: { t in model.updateBand(id) { $0.type = t } })) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Enabled", isOn: Binding(get: { band.isEnabled }, set: { v in model.updateBand(id) { $0.isEnabled = v } }))
            Button("Reset Gain") { model.updateBand(id) { $0.gainDB = 0 } }
            Divider()
            Button("Delete Band", role: .destructive) { model.removeBand(id); selectedBandID = nil }
        } else {
            Text("Double-click to add a band")
        }
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ g: EQGeometry, _ size: CGSize) {
        for f in Self.gridFrequencies {
            let x = g.x(for: f)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                       with: .color(.white.opacity(0.05)), lineWidth: 1)
            if interactive {
                ctx.draw(Text(Theme.hz(f)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.35)),
                         at: CGPoint(x: min(max(x, 10), size.width - 12), y: size.height - 8))
            }
        }
        for db in stride(from: -18.0, through: 18.0, by: 6.0) {
            let y = g.y(forDB: db)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .color(.white.opacity(db == 0 ? 0.16 : 0.05)), lineWidth: 1)
            if interactive && db != 0 {
                ctx.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.3)),
                         at: CGPoint(x: 14, y: y - 7))
            }
        }
    }

    private func drawSpectrum(_ ctx: GraphicsContext, _ g: EQGeometry, _ size: CGSize, _ levels: [Float]) {
        guard !levels.isEmpty else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, level) in levels.enumerated() {
            let t = CGFloat(min(max((Double(level) + 90) / 90, 0), 1))
            path.addLine(to: CGPoint(x: g.x(for: spectrum.frequencies[i]), y: size.height - t * size.height * 0.85))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .linearGradient(Gradient(colors: [Theme.violet.opacity(0.45), Theme.cyan.opacity(0.05)]),
                                             startPoint: CGPoint(x: 0, y: size.height * 0.15),
                                             endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawCurve(_ ctx: GraphicsContext, _ g: EQGeometry, _ size: CGSize, _ bands: [EQBand],
                           _ preamp: Double, _ rate: Double, _ enabled: Bool) {
        let steps = max(Int(size.width / 3), 64)
        var curve = Path()
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let db = EQResponse.decibels(bands: bands, preampDB: preamp, frequency: g.frequency(atX: x), sampleRate: rate)
            let p = CGPoint(x: x, y: g.y(forDB: min(max(db, -EQGeometry.dbRange), EQGeometry.dbRange)))
            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: size.width, y: g.y(forDB: 0)))
        fill.addLine(to: CGPoint(x: 0, y: g.y(forDB: 0)))
        fill.closeSubpath()
        let opacity = enabled ? 1.0 : 0.35
        ctx.fill(fill, with: .color(Theme.cyan.opacity(0.08 * opacity)))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.stroke(curve, with: .color(Theme.cyan.opacity(0.6 * opacity)), lineWidth: 5)
        }
        ctx.stroke(curve, with: .linearGradient(Gradient(colors: [Theme.cyan.opacity(opacity), Theme.violet.opacity(opacity)]),
                                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func drawNodes(_ ctx: GraphicsContext, _ g: EQGeometry, _ bands: [EQBand]) {
        for (i, b) in bands.enumerated() {
            let c = CGPoint(x: g.x(for: b.frequency), y: g.y(forDB: nodeDB(b)))
            let selected = b.id == selectedBandID, hovered = b.id == hoverBandID
            let r: CGFloat = selected ? 9 : (hovered ? 8 : 7)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let color = Theme.bandColor(i)
            if b.isEnabled {
                ctx.drawLayer { l in l.addFilter(.blur(radius: 5)); l.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.6))) }
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                ctx.stroke(Path(ellipseIn: rect), with: .color(.gray), lineWidth: 1.5)
            }
            if selected { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 2) }
            ctx.draw(Text("\(i + 1)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.75)), at: c)
        }
    }
}
```

- [ ] **Step 4: Controls**

`Sources/Equinox/Controls.swift`:
```swift
import EquinoxCore
import EquinoxDSP
import SwiftUI

/// Horizontal slider 0...2 where 0...1 is volume and 1...2 is boost (0...+12 dB, tinted amber).
struct VolumeControl: View {
    @Bindable var model: AppModel

    private var combined: Double {
        model.boostDB > 0 ? 1 + model.boostDB / DSPSettings.maxBoostDB : model.volume
    }

    private func setCombined(_ v: Double) {
        if v <= 1 { model.boostDB = 0; model.volume = max(v, 0) }
        else { if model.volume != 1 { model.volume = 1 }; model.boostDB = ((v - 1) * DSPSettings.maxBoostDB * 2).rounded() / 2 }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.isMuted.toggle() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18).foregroundStyle(model.isMuted ? .red : .white.opacity(0.8))
            }.buttonStyle(.plain)
            GeometryReader { geo in
                let w = geo.size.width, t = CGFloat(combined / 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(Theme.amber.opacity(0.15)).frame(width: w / 2).offset(x: w / 2)
                    Capsule().fill(model.boostDB > 0
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.cyan, Theme.violet, Theme.amber], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Theme.accent))
                        .frame(width: max(w * t, 6))
                    Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 3).offset(x: w * t - 7)
                }
                .frame(height: 6).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    var value = Double(min(max(v.location.x / w, 0), 1)) * 2
                    if abs(value - 1) < 0.03 { value = 1 }   // detent at 100%
                    setCombined(value)
                })
            }
            .frame(height: 20)
            Text(model.boostDB > 0 ? String(format: "+%.1f dB", model.boostDB) : "\(Int((model.volume * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(model.boostDB > 0 ? Theme.amber : .white.opacity(0.8))
                .frame(width: 58, alignment: .trailing)
        }
    }
}

struct BalanceControl: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("L").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.balance },
                                  set: { model.balance = abs($0) < 0.05 ? 0 : $0 }), in: -1...1)
                .tint(Theme.cyan)
            Text("R").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}

struct MeterView: View {
    var spectrum: SpectrumModel

    var body: some View {
        VStack(spacing: 3) {
            bar(spectrum.peakLeft)
            bar(spectrum.peakRight)
        }
        .onAppear { spectrum.attach() }
        .onDisappear { spectrum.detach() }
    }

    private func bar(_ peak: Float) -> some View {
        GeometryReader { geo in
            let db = Decibels.fromLinear(Double(peak))
            let t = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(LinearGradient(colors: [Theme.cyan, Theme.violet, db > -1 ? .red : Theme.violet],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * t)
            }
        }
        .frame(height: 4)
    }
}

/// Vertical slider used by the graphic EQ. `value` within `range`, zero line highlighted.
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let zeroT = CGFloat((0 - range.lowerBound) / (range.upperBound - range.lowerBound))
            let y = h * (1 - t), zeroY = h * (1 - zeroT)
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.08)).frame(width: 6)
                Rectangle().fill(tint.opacity(0.9)).frame(width: 6, height: abs(zeroY - y)).offset(y: min(y, zeroY))
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: tint.opacity(0.8), radius: 6).offset(y: y - 8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let tt = 1 - Double(min(max(v.location.y / h, 0), 1))
                value = ((range.lowerBound + tt * (range.upperBound - range.lowerBound)) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}
```

- [ ] **Step 5: Band inspector and graphic EQ**

`Sources/Equinox/BandInspector.swift`:
```swift
import EquinoxCore
import EquinoxDSP
import SwiftUI

struct BandInspector: View {
    @Bindable var model: AppModel
    @Binding var selectedBandID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.working.bands.enumerated()), id: \.element.id) { i, band in
                        Button { selectedBandID = band.id } label: {
                            HStack(spacing: 5) {
                                Circle().fill(band.isEnabled ? Theme.bandColor(i) : .gray).frame(width: 7, height: 7)
                                Text(Theme.hz(band.frequency)).monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(band.id == selectedBandID ? .white.opacity(0.18) : .white.opacity(0.06)))
                        }.buttonStyle(.plain)
                    }
                    Button {
                        selectedBandID = model.addBand(frequency: 1000, gainDB: 0)
                    } label: { Image(systemName: "plus").padding(6).background(Circle().fill(.white.opacity(0.06))) }
                        .buttonStyle(.plain)
                        .disabled(model.working.bands.count >= BiquadBank.maxSections)
                        .help("Add band")
                }
            }
            if let id = selectedBandID, let band = model.working.bands.first(where: { $0.id == id }) {
                HStack(spacing: 14) {
                    Picker("", selection: bind(id, \.type, band.type)) {
                        ForEach(FilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width: 120)
                    field("Freq", bind(id, \.frequency, band.frequency), unit: "Hz", format: .number.precision(.fractionLength(0)))
                    field("Gain", bind(id, \.gainDB, band.gainDB), unit: "dB", format: .number.precision(.fractionLength(1)))
                        .disabled(!band.type.usesGain)
                    field("Q", bind(id, \.q, band.q), unit: "", format: .number.precision(.fractionLength(2)))
                    Toggle("On", isOn: bind(id, \.isEnabled, band.isEnabled)).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Button(role: .destructive) { model.removeBand(id); selectedBandID = nil } label: { Image(systemName: "trash") }
                        .help("Delete band")
                }
            } else {
                Text("Drag a node to shape the sound · double-click to add · pinch to change width · right-click for options")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bind<V>(_ id: UUID, _ key: WritableKeyPath<EQBand, V>, _ current: V) -> Binding<V> {
        Binding(get: { model.working.bands.first { $0.id == id }?[keyPath: key] ?? current },
                set: { v in model.updateBand(id) { $0[keyPath: key] = v } })
    }

    private func field(_ label: String, _ value: Binding<Double>, unit: String,
                       format: FloatingPointFormatStyle<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: format).textFieldStyle(.roundedBorder).frame(width: 64)
                .font(.system(size: 12, design: .rounded).monospacedDigit())
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
```

`Sources/Equinox/GraphicEQView.swift`:
```swift
import EquinoxCore
import EquinoxDSP
import SwiftUI

/// Gain-only view over the same bands, sorted by frequency.
struct GraphicEQView: View {
    @Bindable var model: AppModel

    var body: some View {
        let bands = model.working.bands.enumerated().sorted { $0.element.frequency < $1.element.frequency }
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(bands, id: \.element.id) { i, band in
                VStack(spacing: 6) {
                    Text(String(format: "%+.1f", band.gainDB))
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                    VerticalSlider(value: Binding(get: { band.gainDB }, set: { v in model.updateBand(band.id) { $0.gainDB = v } }),
                                   range: EQBand.gainRange, tint: Theme.bandColor(i))
                        .frame(height: 150)
                        .opacity(band.type.usesGain && band.isEnabled ? 1 : 0.35)
                        .disabled(!band.type.usesGain)
                    Text(Theme.hz(band.frequency)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 44)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | grep -E "error|warning: unre|Compiling|Build" | tail -10`
Expected: `Build complete!` (the debug `EquinoxApp.swift` from Task 7 is still the entry point; these views are compiled but not yet shown).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(ui): theme, spectrum model, interactive EQ canvas and controls"
```

---

### Task 10: App shell — menu bar panel, main window, presets, settings, onboarding

**Files:**
- Create: `Sources/Equinox/PresetBar.swift`, `Sources/Equinox/MenuBarPanel.swift`, `Sources/Equinox/MainWindow.swift`, `Sources/Equinox/OnboardingView.swift`
- Modify: `Sources/Equinox/EquinoxApp.swift` (replace debug app)

**Interfaces:**
- Consumes: all Task 8–9 types, `AudioController`.
- Produces: the shipping Phase 1 app.

- [ ] **Step 1: PresetBar**

`Sources/Equinox/PresetBar.swift`:
```swift
import AppKit
import EquinoxCore
import SwiftUI
import UniformTypeIdentifiers

struct PresetBar: View {
    @Bindable var model: AppModel
    var compact = false
    @State private var naming = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var importError: String?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Built-in") {
                    ForEach(model.presets.filter(\.isBuiltIn)) { p in Button(p.name) { model.selectPreset(p.id) } }
                }
                if !model.userPresets.isEmpty {
                    Section("My Presets") {
                        ForEach(model.userPresets) { p in Button(p.name) { model.selectPreset(p.id) } }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text(model.selectedPreset.name).lineLimit(1)
                    if model.isModified { Circle().fill(Theme.amber).frame(width: 6, height: 6) }
                }
            }
            .menuStyle(.button)
            .fixedSize()

            if !compact {
                Button("Save") { model.save() }
                    .disabled(!model.isModified || model.selectedPreset.isBuiltIn)
                Button("Save As…") { newName = model.selectedPreset.name; naming = true }
                Button("Revert") { model.revert() }.disabled(!model.isModified)
                Menu {
                    Button("Rename…") { newName = model.selectedPreset.name; renaming = true }
                        .disabled(model.selectedPreset.isBuiltIn)
                    Button("Import…", action: importPresets)
                    Button("Export Current…") { export([model.selectedPresetID]) }
                    Button("Export All My Presets…") { export(model.userPresets.map(\.id)) }.disabled(model.userPresets.isEmpty)
                    Divider()
                    Button("Delete Preset", role: .destructive) { model.deletePreset(model.selectedPresetID) }
                        .disabled(model.selectedPreset.isBuiltIn)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .alert("Save Preset As", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { model.saveAs(name: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Preset", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.renamePreset(model.selectedPresetID, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.importPresets(from: Data(contentsOf: url)) }
        catch { importError = "That file isn't an Equinox preset." }
    }

    private func export(_ ids: [UUID]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ids.count == 1 ? "\(model.selectedPreset.name).json" : "Equinox Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportData(for: ids).write(to: url, options: .atomic) }
        catch { importError = "Could not export: \(error.localizedDescription)" }
    }
}
```

- [ ] **Step 2: Menu bar panel**

`Sources/Equinox/MenuBarPanel.swift`:
```swift
import EquinoxAudio
import EquinoxCore
import SwiftUI

struct StatusDot: View {
    var status: AudioStatus
    var enabled: Bool

    var color: Color {
        switch status {
        case .running: enabled ? .green : Theme.amber
        case .failed: .red
        case .stopped: .gray
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 4)
    }
}

struct MenuBarPanel: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    @Environment(\.openWindow) private var openWindow
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Equinox").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.accent)
                StatusDot(status: model.status, enabled: model.isEnabled)
                Spacer()
                Toggle("", isOn: $model.isEnabled).toggleStyle(.switch).labelsHidden().tint(Theme.cyan)
            }

            if case .failed(let message) = model.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Picker(selection: Binding(get: { model.currentDevice?.uid ?? "" },
                                      set: { uid in if let d = model.devices.first(where: { $0.uid == uid }) { model.selectOutputDevice(d) } })) {
                ForEach(model.devices) { d in Text(d.name).tag(d.uid) }
            } label: { Image(systemName: "hifispeaker.2.fill") }
                .onAppear { model.refreshDevices() }

            EQCanvasView(model: model, spectrum: spectrum, interactive: false, selectedBandID: $selected)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .glassCard(cornerRadius: 14, padding: 4)

            PresetBar(model: model, compact: true)

            VStack(spacing: 8) {
                VolumeControl(model: model)
                MeterView(spectrum: spectrum)
            }
            .glassCard(cornerRadius: 14, padding: 12)

            HStack {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: { Label("Open Equinox", systemImage: "macwindow") }
                Spacer()
                Button("Quit") { model.flushSave(); NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 360)
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 3: Main window and settings**

`Sources/Equinox/MainWindow.swift`:
```swift
import EquinoxAudio
import EquinoxCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer", settings = "Settings"
    var id: String { rawValue }
    var icon: String { self == .equalizer ? "slider.vertical.3" : "gearshape" }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    @State private var page: Page = .equalizer
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                .navigationSplitViewColumnWidth(170)
        } detail: {
            ScrollView {
                switch page {
                case .equalizer: EqualizerPage(model: model, spectrum: spectrum)
                case .settings: SettingsPage(model: model)
                }
            }
            .background(Theme.background)
        }
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear { showOnboarding = !model.hasCompletedOnboarding }
        .sheet(isPresented: $showOnboarding) { OnboardingView(model: model, spectrum: spectrum) }
    }
}

struct EqualizerPage: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    @State private var selectedBandID: UUID?
    @State private var graphic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PresetBar(model: model)
                Spacer()
                StatusDot(status: model.status, enabled: model.isEnabled)
                Toggle("Enabled", isOn: $model.isEnabled).toggleStyle(.switch).tint(Theme.cyan)
            }

            VStack(alignment: .leading, spacing: 14) {
                EQCanvasView(model: model, spectrum: spectrum, selectedBandID: $selectedBandID)
                    .frame(height: 320)
                Picker("", selection: $graphic) {
                    Text("Parametric").tag(false)
                    Text("Graphic").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if graphic { GraphicEQView(model: model) } else { BandInspector(model: model, selectedBandID: $selectedBandID) }
            }
            .glassCard(cornerRadius: 20, padding: 18)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Preamp").font(.headline)
                    HStack {
                        Slider(value: Binding(get: { model.preampDB }, set: { model.preampDB = ($0 * 2).rounded() / 2 }), in: -24...24)
                            .tint(Theme.violet)
                        Text(String(format: "%+.1f dB", model.preampDB))
                            .font(.system(size: 12, design: .rounded).monospacedDigit()).frame(width: 64, alignment: .trailing)
                    }
                    Text("Lower the preamp when boosting bands to keep headroom. The limiter catches anything above 0 dB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Output").font(.headline)
                    VolumeControl(model: model)
                    BalanceControl(model: model)
                    MeterView(spectrum: spectrum)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
        }
        .padding(24)
    }
}

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("General").font(.headline)
                Toggle("Launch Equinox at login", isOn: $model.launchAtLogin)
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("Audio").font(.headline)
                HStack {
                    StatusDot(status: model.status, enabled: model.isEnabled)
                    Text(statusText).font(.callout)
                }
                HStack {
                    Button("Restart Audio Engine") { model.restartAudio() }
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                }
                Text("Equinox needs “System Audio Recording” permission. If audio goes silent while Equinox is on, check that Equinox is enabled there.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard()

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber).glassCard()
            }
        }
        .padding(24)
    }

    private var statusText: String {
        switch model.status {
        case .running(let name, let rate): "Running on \(name) · \(Int(rate)) Hz"
        case .failed(let message): message
        case .stopped: "Stopped"
        }
    }
}
```

- [ ] **Step 4: Onboarding**

`Sources/Equinox/OnboardingView.swift`:
```swift
import EquinoxCore
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    @Environment(\.dismiss) private var dismiss
    @State private var started = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
            Text("Welcome to Equinox").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Equinox shapes everything your Mac plays. macOS will ask for **System Audio Recording** permission — that lets Equinox process your audio. Nothing is recorded or saved.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)

            if started {
                VStack(spacing: 10) {
                    Text("Play some music — these bars should move.").font(.callout)
                    MeterView(spectrum: spectrum).frame(width: 300)
                    Button("No movement? Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }.buttonStyle(.link)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                Button("Enable Equinox") { model.completeOnboarding(); started = true }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(36)
        .frame(width: 520)
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 5: App entry point**

Replace `Sources/Equinox/EquinoxApp.swift`:
```swift
import EquinoxAudio
import EquinoxCore
import SwiftUI

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    let model: AppModel
    let spectrum: SpectrumModel

    private init() {
        let model = AppModel(audio: AudioController())
        self.model = model
        spectrum = SpectrumModel(tap: model.analysis, sampleRate: { [weak model] in model?.sampleRate ?? 48_000 })
        model.launch()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.shared.model.flushSave() }
    }
}

@main
struct EquinoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: env.model, spectrum: env.spectrum)
        } label: {
            Image(systemName: env.model.isEnabled ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Equinox", id: "main") {
            MainWindow(model: env.model, spectrum: env.spectrum)
        }
        .defaultLaunchBehavior(env.model.hasCompletedOnboarding ? .suppressed : .presented)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 720)
    }
}
```

- [ ] **Step 6: Build, run, and walk the manual checklist**

Run: `swift test 2>&1 | tail -3 && scripts/build-app.sh --run`
Expected: tests pass; `Built build/Equinox.app`; app launches.

Manual checklist (do with the human partner; note results in the commit message body):
1. Fresh state: `rm -rf ~/Library/Application\ Support/Equinox` before launch → onboarding window appears → Enable → meters move while music plays.
2. Drag an EQ node: curve and sound change smoothly, no clicks. Double-click empty space adds a band; right-click → Delete removes it; pinch changes width.
3. Graphic tab shows sliders for the same bands; changing one updates the curve.
4. Preset menu: switch to Bass Boost (audible), edit → amber dot, Save As "Mine", relaunch → "Mine" still selected.
5. Volume slider past 100% → amber boost readout; loud content doesn't distort harshly (limiter).
6. Switch output device from the popover → audio continues on the new device; switch back → that device's preset is restored.
7. Toggle Enabled off → audio unprocessed; menu-bar icon changes.
8. Quit from popover and `kill -9` the app while playing → normal audio resumes both times.
9. Sleep/wake the Mac while playing → audio returns within ~2 s.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(app): menu bar panel, main window, presets, settings and onboarding"
```

---

## Later phases (each gets its own detailed plan before implementation)

- **Phase 2 — Per-app mixer.** Extend `TapSession` to N taps: a rest tap excluding Equinox + apps with custom settings, plus one `stereoMixdownOfProcesses` tap per customized app; `Renderer` reads each tap stream (`inputStreamOffset + i`), applies per-app gain/mute and an optional per-app `BiquadBank`, then sums before the master chain. `AudioSystem.audioProcesses()` (via `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningOutput`); debounced session rebuild when the customized-app set changes. UI: Mixer page with channel strips; compact mixer in popover.
- **Phase 3 — Effects & plugins.** `EffectsHost` = AVAudioEngine in `.realtime` manual rendering mode invoked from `MasterProcessor` between EQ and gain; built-in units (reverb, dynamics, multiband, limiter, delay) + `AVAudioUnitComponentManager` plugins; engine swap at buffer boundary; plugin state in presets; crash marker file. UI: Effects page with draggable chain and plugin windows.
- **Phase 4 — Headphone extras.** AutoEQ: `ParametricEQ.txt` parser (`Preamp: X dB`, `Filter N: ON PK|LSC|HSC Fc F Hz Gain G dB Q Q`) feeding a separate correction `BiquadBank` ahead of the user EQ; downloadable AutoEq index with cache. Crossfeed DSP (Bauer, 3 levels) in EquinoxDSP; spatial via `AVAudioEnvironmentNode` HRTF in the effects engine; headphone detection by transport type / data source. UI: Headphones page.
