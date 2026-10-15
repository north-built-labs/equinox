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

    /// Bypass turns the EQ (and preamp) off; output controls, the limiter and the NaN guard stay active.
    func testBypassSkipsEQButKeepsOutputControls() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        var s = DSPSettings(); s.isBypassed = true; s.preampDB = -6
        s.bands = [EQBand(type: .peak, frequency: 300, gainDB: 12, q: 1)]
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        let x = Signal.sine(300, fs: fs, count: 1000)
        var l = x, r = x
        process(p, &l, &r)
        for i in 0..<1000 { XCTAssertEqual(l[i], x[i], accuracy: 1e-5) }
    }

    func testBypassStillAppliesMuteAndSoftwareVolume() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        var s = DSPSettings(); s.isBypassed = true; s.softwareVolume = 0.5
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        var l = [Float](repeating: 0.4, count: 600), r = l
        process(p, &l, &r)
        XCTAssertEqual(l[599], 0.2, accuracy: 1e-4)
        s.isMuted = true
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        var l2 = [Float](repeating: 0.4, count: 600), r2 = l2
        process(p, &l2, &r2)
        XCTAssertEqual(l2[599], 0, accuracy: 1e-6)
    }

    func testBypassStillSilencesNaN() {
        let p = MasterProcessor(maxFrames: 512, sampleRate: fs)
        var s = DSPSettings(); s.isBypassed = true
        p.apply(DSPConfig(settings: s, sampleRate: fs))
        var l = [Float](repeating: .nan, count: 256), r = l
        process(p, &l, &r)
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
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
