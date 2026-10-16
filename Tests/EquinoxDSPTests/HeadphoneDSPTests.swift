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
