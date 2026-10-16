import AVFoundation

public struct SpatialParameters: Codable, Equatable, Sendable {
    public static let widthRange: ClosedRange<Double> = 10...60
    /// Angle of each virtual speaker from centre, in degrees.
    public var width: Double
    /// Room ambience, 0…1.
    public var room: Double

    public init(width: Double = 30, room: Double = 0.15) { self.width = width; self.room = room }
}

/// Virtual stereo speakers for headphones: L and R become two mono sources at ±width° in an
/// AVAudioEnvironmentNode (HRTF-HQ), rendered in realtime manual mode. `render` is realtime-safe.
public final class SpatialRenderer: @unchecked Sendable {
    public static let maxFrames = 4096
    /// Brings a centred source back to roughly unity after HRTF processing (measured; see tests).
    static let makeupGain: Float = 1.0

    private final class Feed: @unchecked Sendable {
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
    }

    public let sampleRate: Double
    private let engine: AVAudioEngine
    private let environment: AVAudioEnvironmentNode
    private let sources: [AVAudioSourceNode]
    private let feed: Feed
    private let renderBlock: AVAudioEngineManualRenderingBlock
    private let output: UnsafeMutableAudioBufferListPointer
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>

    public init(sampleRate: Double, parameters: SpatialParameters) throws {
        let engine = AVAudioEngine()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        try engine.enableManualRenderingMode(.realtime, format: stereo, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        let feed = Feed()
        func source(left: Bool) -> AVAudioSourceNode {
            AVAudioSourceNode(format: mono) { _, _, frames, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                guard let dst = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if let src = left ? feed.left : feed.right { dst.update(from: src, count: Int(frames)) }
                else { dst.update(repeating: 0, count: Int(frames)) }
                return noErr
            }
        }
        let sources = [source(left: true), source(left: false)]
        let environment = AVAudioEnvironmentNode()
        for node in sources { engine.attach(node) }
        engine.attach(environment)
        for node in sources {
            engine.connect(node, to: environment, format: mono)
            node.renderingAlgorithm = .HRTFHQ
        }
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        environment.reverbParameters.level = 0
        try engine.start()

        self.sampleRate = sampleRate
        self.engine = engine
        self.environment = environment
        self.sources = sources
        self.feed = feed
        renderBlock = engine.manualRenderingBlock
        output = AudioBufferList.allocate(maximumBuffers: 2)
        outL = .allocate(capacity: Self.maxFrames); outL.initialize(repeating: 0, count: Self.maxFrames)
        outR = .allocate(capacity: Self.maxFrames); outR.initialize(repeating: 0, count: Self.maxFrames)
        set(parameters)
    }

    deinit {
        engine.stop()
        free(output.unsafeMutablePointer)
        outL.deallocate(); outR.deallocate()
    }

    /// Main thread. Live: speaker angle and room send.
    public func set(_ p: SpatialParameters) {
        let angle = min(max(p.width, SpatialParameters.widthRange.lowerBound), SpatialParameters.widthRange.upperBound) * .pi / 180
        sources[0].position = AVAudio3DPoint(x: Float(-sin(angle)), y: 0, z: Float(-cos(angle)))
        sources[1].position = AVAudio3DPoint(x: Float(sin(angle)), y: 0, z: Float(-cos(angle)))
        let room = Float(min(max(p.room.isFinite ? p.room : 0, 0), 1))
        environment.reverbParameters.enable = room > 0
        for node in sources { node.reverbBlend = room }
    }

    /// Realtime-safe, in place, any frame count. On a render error audio passes through unchanged.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var offset = 0
        while offset < frames {
            let n = min(Self.maxFrames, frames - offset)
            feed.left = left + offset
            feed.right = right + offset
            let bytes = UInt32(n * MemoryLayout<Float>.size)
            output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outL))
            output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outR))
            var error: OSStatus = noErr
            if renderBlock(AVAudioFrameCount(n), output.unsafeMutablePointer, &error) == .success,
               let l = output[0].mData?.assumingMemoryBound(to: Float.self),
               let r = output[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<n {
                    left[offset + i] = l[i] * Self.makeupGain
                    right[offset + i] = r[i] * Self.makeupGain
                }
            }
            offset += n
        }
        feed.left = nil
        feed.right = nil
    }
}
