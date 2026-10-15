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
