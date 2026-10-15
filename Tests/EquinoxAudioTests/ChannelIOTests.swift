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
