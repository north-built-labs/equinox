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
