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
