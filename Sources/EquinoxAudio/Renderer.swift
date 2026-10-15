import CoreAudio
import EquinoxDSP
import Foundation
import os
import Synchronization

/// Hands immutable configs from the main thread to the audio thread without blocking it.
final class ConfigMailbox: @unchecked Sendable {
    private let pending = OSAllocatedUnfairLock<DSPConfig?>(initialState: nil)
    /// Main-thread history keeps recently replaced configs alive so the audio thread never frees one.
    private var history: [DSPConfig] = []

    func post(_ config: DSPConfig) {
        history.append(config)
        if history.count > 16 { history.removeFirst(history.count - 16) }
        pending.withLock { $0 = config }
    }

    /// Realtime-safe: returns nil if nothing is pending or the lock is momentarily held.
    func take() -> DSPConfig? {
        pending.withLockIfAvailable { (state: inout DSPConfig?) -> DSPConfig? in
            let c = state; state = nil; return c
        } ?? nil
    }
}

/// Owns the realtime render path invoked by the aggregate device's IOProc.
public final class Renderer: @unchecked Sendable {
    public static let maxFrames = 4096

    public let analysis = AnalysisTap()
    private let mailbox = ConfigMailbox()
    private var processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: 48_000)
    private var current: DSPConfig?
    private var inputStreamOffset = 0
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxFrames * 4)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxFrames * 4)
    private let lastCallback = Atomic<UInt64>(0)

    public init() {
        left.initialize(repeating: 0, count: Renderer.maxFrames * 4)
        right.initialize(repeating: 0, count: Renderer.maxFrames * 4)
    }

    deinit { left.deallocate(); right.deallocate() }

    /// Main thread.
    public func submit(_ config: DSPConfig) { mailbox.post(config) }

    /// Main thread, only while the IOProc is stopped.
    func prepare(sampleRate: Double, inputStreamOffset: Int) {
        processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: sampleRate)
        current = nil
        self.inputStreamOffset = inputStreamOffset
    }

    public func lastCallbackNanos() -> UInt64 { lastCallback.load(ordering: .relaxed) }

    /// Audio thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        lastCallback.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        let out = UnsafeMutableAudioBufferListPointer(output)
        let inp = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = min(ChannelIO.frameCount(of: out), Renderer.maxFrames * 4)
        guard frames > 0 else { return }

        if let config = mailbox.take() {
            current = config   // previous config stays alive in the mailbox history
            processor.apply(config)
        }
        ChannelIO.readStereo(from: inp, bufferIndex: inputStreamOffset, frames: frames, left: left, right: right)
        if current != nil { processor.process(left: left, right: right, frames: frames) }
        analysis.write(left: left, right: right, frames: frames)
        ChannelIO.writeStereo(left: left, right: right, frames: frames, to: out)
    }
}
