import CoreAudio
import EquinoxDSP
import Foundation
import os
import Synchronization

/// Hands immutable objects from the main thread to the audio thread without blocking it.
/// Configs are retired by acknowledgement: the main thread keeps every config the audio thread
/// might still hold until the audio thread reports it has moved past it, so the audio thread's
/// release is never the last one (no free() on the IO thread).
final class Mailbox<Value: AnyObject>: @unchecked Sendable {
    final class Entry: @unchecked Sendable {
        let value: Value
        let generation: Int
        init(value: Value, generation: Int) { self.value = value; self.generation = generation }
    }

    /// Safety cap for when the audio thread is not running and never acknowledges.
    private static var maxHistory: Int { 512 }

    private let pending = OSAllocatedUnfairLock<Entry?>(initialState: nil)
    private let acknowledged = Atomic<Int>(0)
    private var history: [Entry] = []
    private var nextGeneration = 1

    /// Main thread.
    func post(_ value: Value) {
        let entry = Entry(value: value, generation: nextGeneration)
        nextGeneration += 1
        let inUse = acknowledged.load(ordering: .acquiring)
        history.removeAll { $0.generation < inUse }
        if history.count >= Self.maxHistory { history.removeFirst(history.count - Self.maxHistory + 1) }
        history.append(entry)
        pending.withLock { $0 = entry }
    }

    /// Main thread, only while the IOProc is stopped: nothing on the audio thread holds an entry.
    func reset() {
        pending.withLock { $0 = nil }   // a never-taken entry must not survive for the audio thread to free
        history.removeAll()
        acknowledged.store(0, ordering: .releasing)
    }

    /// Realtime-safe: returns nil if nothing is pending or the lock is momentarily held.
    func take() -> Entry? {
        pending.withLockIfAvailable { (state: inout Entry?) -> Entry? in
            let e = state; state = nil; return e
        } ?? nil
    }

    /// Realtime-safe. Call after the audio thread has replaced its previous entry with `entry`.
    func acknowledge(_ entry: Entry) {
        acknowledged.store(entry.generation, ordering: .releasing)
    }
}

typealias ConfigMailbox = Mailbox<DSPConfig>

/// Lets the effects mailbox carry "no chain".
final class EffectsBox: @unchecked Sendable {
    let chain: EffectsChain?
    init(_ chain: EffectsChain?) { self.chain = chain }
}

/// Owns the realtime render path invoked by the aggregate device's IOProc.
public final class Renderer: @unchecked Sendable {
    public static let maxFrames = 4096
    static let capacity = maxFrames * 4

    public let analysis = AnalysisTap()
    private let effectsMailbox = Mailbox<EffectsBox>()
    private var effects: Mailbox<EffectsBox>.Entry?

    /// Main thread. nil removes the chain.
    public func submitEffects(_ chain: EffectsChain?) { effectsMailbox.post(EffectsBox(chain)) }
    public let stripMeters = StripMeters()
    private var mixBus = MixBus(stripCount: 1, maxFrames: Renderer.capacity)
    private var stripCount = 1
    private let mixL = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.capacity)
    private let mixR = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.capacity)
    private let mailbox = ConfigMailbox()
    private var processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: 48_000)
    private var current: ConfigMailbox.Entry?
    private var inputStreamOffset = 0
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.capacity)
    private let lastCallback = Atomic<UInt64>(0)

    public init() {
        left.initialize(repeating: 0, count: Renderer.capacity)
        right.initialize(repeating: 0, count: Renderer.capacity)
        mixL.initialize(repeating: 0, count: Renderer.capacity)
        mixR.initialize(repeating: 0, count: Renderer.capacity)
    }

    deinit { left.deallocate(); right.deallocate(); mixL.deallocate(); mixR.deallocate() }

    /// Main thread.
    public func submit(_ config: DSPConfig) { mailbox.post(config) }

    /// Main thread, only while the IOProc is stopped.
    func prepare(sampleRate: Double, inputStreamOffset: Int, stripCount: Int = 1) {
        processor = MasterProcessor(maxFrames: Renderer.maxFrames, sampleRate: sampleRate)
        mixBus = MixBus(stripCount: stripCount, maxFrames: Renderer.capacity)
        self.stripCount = mixBus.stripCount
        current = nil
        mailbox.reset()
        effects = nil
        effectsMailbox.reset()
        self.inputStreamOffset = inputStreamOffset
    }

    public func lastCallbackNanos() -> UInt64 { lastCallback.load(ordering: .relaxed) }

    /// Audio thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        lastCallback.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        let out = UnsafeMutableAudioBufferListPointer(output)
        let inp = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = min(ChannelIO.frameCount(of: out), Renderer.capacity)
        guard frames > 0 else { return }

        if let entry = mailbox.take() {
            current = entry                 // previous entry is still owned by the mailbox history
            mailbox.acknowledge(entry)
            processor.apply(entry.value)
            mixBus.apply(entry.value.strips)
        }
        mixL.update(repeating: 0, count: frames)
        mixR.update(repeating: 0, count: frames)
        for strip in 0..<stripCount {
            ChannelIO.readStereo(from: inp, bufferIndex: inputStreamOffset + strip, frames: frames, left: left, right: right)
            mixBus.accumulate(strip: strip, left: left, right: right, intoLeft: mixL, intoRight: mixR, frames: frames)
            stripMeters.record(strip: strip, left: left, right: right, frames: frames)
        }
        if let fxEntry = effectsMailbox.take() {
            effects = fxEntry                  // previous chain is still owned by the mailbox history
            effectsMailbox.acknowledge(fxEntry)
        }
        if let config = current?.value {
            processor.processPre(left: mixL, right: mixR, frames: frames)
            if !config.isBypassed, let chain = effects?.value.chain {
                chain.render(left: mixL, right: mixR, frames: frames)
            }
            processor.processPost(left: mixL, right: mixR, frames: frames)
        }
        analysis.write(left: mixL, right: mixR, frames: frames)
        ChannelIO.writeStereo(left: mixL, right: mixR, frames: frames, to: out)
    }
}
