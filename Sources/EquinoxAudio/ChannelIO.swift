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
