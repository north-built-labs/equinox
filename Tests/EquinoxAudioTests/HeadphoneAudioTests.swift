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
