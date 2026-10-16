import XCTest
@testable import EquinoxDSP

final class ListeningTests: XCTestCase {
    let rate = 48_000.0

    func settings(levels: Bool = true) -> ListeningSettings {
        var s = ListeningSettings()
        s.isEnabled = true; s.levelsEnabled = levels; s.preserveDynamics = 0
        s.bass = 0; s.harshness = 0; s.sibilance = 0
        return s
    }

    func processor(_ s: ListeningSettings, rate: Double = 48_000) -> ListeningProcessor {
        let p = ListeningProcessor(sampleRate: rate)
        p.configure(ListeningConfig(settings: s, sampleRate: rate))
        return p
    }

    func run(_ p: ListeningProcessor, _ left: inout [Float], _ right: inout [Float], chunk: Int = 512) {
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            var offset = 0
            while offset < l.count {
                let n = min(chunk, l.count - offset)
                p.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: n)
                offset += n
            }
        } }
    }

    func level(_ signal: [Float], tail: Int = 24_000) -> Double {
        20 * log10(Double(Signal.rms(signal.suffix(tail))))
    }

    func testSteadyLoudAndQuietSourcesApproachTarget() {
        for amplitude: Float in [0.07, 0.4] {
            let p = processor(settings())
            var l = Signal.sine(1000, fs: rate, count: 384_000, amplitude: amplitude), r = l
            run(p, &l, &r)
            XCTAssertEqual(level(l), -20, accuracy: 0.2)
            XCTAssertEqual(l, r)
        }
    }

    func testPreserveDynamicsLeavesMoreOfTheOriginalDifference() {
        var s = settings(); s.preserveDynamics = 1
        let p = processor(s)
        var l = Signal.sine(1000, fs: rate, count: 384_000, amplitude: 0.4), r = l
        run(p, &l, &r)
        XCTAssertGreaterThan(level(l), -16)
        XCTAssertLessThan(level(l), -12)
    }

    func testGainIsBoundedEvenAtExtremeTargets() {
        var s = settings(); s.targetDB = -14
        let up = processor(s)
        var l = Signal.sine(1000, fs: rate, count: 384_000, amplitude: 0.01), r = l
        run(up, &l, &r)
        XCTAssertEqual(up.activity.gainDB, 6, accuracy: 0.02)
        s.targetDB = -30
        let down = processor(s)
        l = Signal.sine(1000, fs: rate, count: 192_000, amplitude: 1); r = l
        run(down, &l, &r)
        XCTAssertEqual(down.activity.gainDB, -18, accuracy: 0.02)
    }

    func testSilenceAndLowNoiseDoNotBuildUpGain() {
        let p = processor(settings())
        var l = [Float](repeating: 0, count: 96_000), r = l
        run(p, &l, &r)
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
        XCTAssertEqual(p.activity.gainDB, 0)
        l = Signal.sine(1000, fs: rate, count: 96_000, amplitude: 0.001); r = l
        let original = l
        run(p, &l, &r)
        XCTAssertEqual(l, original)
        XCTAssertEqual(p.activity.gainDB, 0)
    }

    func testGainReturnsToUnityThroughPauseBeforeLoudAudio() {
        let p = processor(settings())
        var l = Signal.sine(1000, fs: rate, count: 384_000, amplitude: 0.02), r = l
        run(p, &l, &r)
        XCTAssertGreaterThan(p.activity.gainDB, 5.9)
        l = [Float](repeating: 0, count: 144_000); r = l
        run(p, &l, &r)
        XCTAssertTrue(l.allSatisfy { $0 == 0 })
        XCTAssertEqual(p.activity.gainDB, 0, accuracy: 0.01)
        l = Signal.sine(1000, fs: rate, count: 96_000, amplitude: 0.7); r = l
        run(p, &l, &r)
        XCTAssertEqual(level(l), -20, accuracy: 0.2)
    }

    func testReactiveBandsCutTheirCentresAndLeaveQuietContentAlone() {
        for (frequency, key) in [(120.0, \ListeningSettings.bass), (3200.0, \.harshness), (7000.0, \.sibilance)] {
            var s = settings(levels: false); s[keyPath: key] = 1
            let p = processor(s)
            var l = Signal.sine(frequency, fs: rate, count: 96_000, amplitude: 0.4), r = l
            let before = level(l)
            run(p, &l, &r)
            XCTAssertEqual(level(l) - before, -9, accuracy: 0.15, "\(frequency) Hz")
            let quiet = processor(s)
            l = Signal.sine(frequency, fs: rate, count: 48_000, amplitude: 0.001); r = l
            let original = l
            run(quiet, &l, &r)
            XCTAssertEqual(l, original)
        }
    }

    func testHarshnessCutLeavesLowMidrangeAlone() {
        var s = settings(levels: false); s.harshness = 1
        let p = processor(s)
        var l = Signal.sine(400, fs: rate, count: 48_000, amplitude: 0.1), r = l
        let original = l
        run(p, &l, &r)
        XCTAssertEqual(l, original)
        XCTAssertEqual(p.activity.harshnessDB, 0)
    }

    func testStereoLinkPreservesChannelRatioAndSilentChannel() {
        var s = settings(); s.harshness = 1
        for ratio: Float in [0, 0.25] {
            let p = processor(s)
            var l = Signal.sine(3200, fs: rate, count: 96_000, amplitude: 0.4)
            var r = l.map { $0 * ratio }
            run(p, &l, &r)
            for i in stride(from: 0, to: l.count, by: 97) {
                XCTAssertEqual(r[i], l[i] * ratio, accuracy: 1e-6)
            }
        }
    }

    func testDisabledIsExactIdentityAndTurningOffSettlesToIdentity() {
        let off = processor(ListeningSettings())
        var l = Signal.sine(3200, fs: rate, count: 48_000, amplitude: 0.4), r = l
        let original = l
        run(off, &l, &r)
        XCTAssertEqual(l, original)
        var s = settings(); s.harshness = 1
        let p = processor(s)
        run(p, &l, &r)
        s.isEnabled = false
        p.configure(ListeningConfig(settings: s, sampleRate: rate))
        l = original; r = original
        run(p, &l, &r)
        XCTAssertEqual(Array(l.suffix(24_000)), Array(original.suffix(24_000)))
        XCTAssertEqual(p.activity, ListeningActivity())
    }

    func testEnableAndDisableDoNotJumpOnConstantInput() {
        var s = settings(); s.bass = 1; s.harshness = 1
        let p = processor(s)
        var l = [Float](repeating: 0.3, count: 48_000), r = l
        run(p, &l, &r)
        let last = l.last!
        s.isEnabled = false
        p.configure(ListeningConfig(settings: s, sampleRate: rate))
        l = [Float](repeating: 0.3, count: 48_000); r = l
        run(p, &l, &r)
        XCTAssertLessThan(abs(l[0] - last), 0.001)
        XCTAssertLessThan(zip(l.dropFirst(), l).map { abs($0 - $1) }.max()!, 0.001)
    }

    func testResultsDoNotDependOnCallbackSize() {
        var s = settings(); s.bass = 0.8; s.harshness = 0.7; s.sibilance = 0.5
        let input = (0..<48_000).map { i -> Float in
            let t = Double(i) / rate
            return Float(0.2 * sin(2 * .pi * 120 * t) + 0.3 * sin(2 * .pi * 3200 * t))
        }
        var a = input, ar = input, b = input, br = input
        run(processor(s), &a, &ar, chunk: 63)
        run(processor(s), &b, &br, chunk: 4096)
        XCTAssertEqual(a, b)
    }

    func testSupportedSampleRatesAndRateChangeRemainFinite() {
        var s = settings(); s.bass = 1; s.harshness = 1; s.sibilance = 1
        let p = processor(s)
        for rate in [8_000.0, 44_100, 48_000, 96_000, 192_000] {
            p.configure(ListeningConfig(settings: s, sampleRate: rate))
            var l = Signal.sine(1000, fs: rate, count: Int(rate), amplitude: 0.4), r = l
            run(p, &l, &r)
            XCTAssertTrue(l.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(Signal.rms(l.suffix(1000)), 0.001)
        }
    }

    func testInvalidInputResetsAndRecovers() {
        let p = processor(settings())
        var l: [Float] = [.nan, .infinity, -.infinity], r = l
        run(p, &l, &r)
        XCTAssertEqual(l, [0, 0, 0])
        l = Signal.sine(1000, fs: rate, count: 48_000, amplitude: 0.1); r = l
        run(p, &l, &r)
        XCTAssertTrue(l.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(Signal.rms(l.suffix(1000)), 0.01)
    }

    func testUntrustedConfigAndOversizedFiniteInputDoNotPoisonState() {
        var s = settings()
        s.targetDB = .nan; s.preserveDynamics = .infinity
        s.bass = 100; s.harshness = -.infinity; s.sibilance = .nan
        for invalidRate in [Double.nan, .infinity, -1, 1e100] {
            let p = processor(s, rate: invalidRate)
            var l = [Float](repeating: .greatestFiniteMagnitude, count: 512), r = l
            run(p, &l, &r)
            XCTAssertTrue(l.allSatisfy(\.isFinite))
            l = Signal.sine(1000, fs: rate, count: 48_000, amplitude: 0.1); r = l
            run(p, &l, &r)
            XCTAssertTrue(l.allSatisfy(\.isFinite))
            XCTAssertTrue(p.activity.gainDB.isFinite)
        }
    }

    func testMasterOutputControlsLimiterAndBypassStillWork() {
        var s = DSPSettings(); s.listening = settings(); s.listening.harshness = 1
        let full = MasterProcessor(maxFrames: 512, sampleRate: rate)
        full.apply(DSPConfig(settings: s, sampleRate: rate))
        s.softwareVolume = 0.25
        let quiet = MasterProcessor(maxFrames: 512, sampleRate: rate)
        quiet.apply(DSPConfig(settings: s, sampleRate: rate))
        var a = Signal.sine(1000, fs: rate, count: 48_000, amplitude: 0.2), ar = a, b = a, br = a
        processMaster(full, &a, &ar); processMaster(quiet, &b, &br)
        XCTAssertEqual(level(b) - level(a), 20 * log10(0.25), accuracy: 0.01)
        s.isMuted = true
        quiet.apply(DSPConfig(settings: s, sampleRate: rate))
        processMaster(quiet, &b, &br)
        XCTAssertTrue(b.suffix(1000).allSatisfy { $0 == 0 })
        s.isMuted = false; s.softwareVolume = 1; s.boostDB = 12
        full.apply(DSPConfig(settings: s, sampleRate: rate))
        a = Signal.sine(1000, fs: rate, count: 48_000, amplitude: 4); ar = a
        processMaster(full, &a, &ar)
        XCTAssertTrue(a.allSatisfy { $0.isFinite && abs($0) <= full.limiter.ceiling })
        s.isBypassed = true; s.boostDB = 0
        full.apply(DSPConfig(settings: s, sampleRate: rate))
        let original = Signal.sine(3200, fs: rate, count: 48_000, amplitude: 0.1)
        a = original; ar = a
        processMaster(full, &a, &ar)
        // The always-on Float limiter retains a tiny release tail from the preceding overload.
        let error = zip(a.suffix(1000), original.suffix(1000)).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(error, 0.00002)
        XCTAssertEqual(full.listeningActivity, ListeningActivity())
    }

    private func processMaster(_ p: MasterProcessor, _ left: inout [Float], _ right: inout [Float]) {
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            p.process(left: l.baseAddress!, right: r.baseAddress!, frames: l.count)
        } }
    }
}
