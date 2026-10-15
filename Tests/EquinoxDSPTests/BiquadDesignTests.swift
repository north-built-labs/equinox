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
