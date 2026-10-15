import Accelerate
import Synchronization

/// Lock-free per-strip peak meters (written by the audio thread, taken by the UI).
public final class StripMeters: @unchecked Sendable {
    public static let capacity = MixBus.maxStrips

    private final class Slot { let bits = Atomic<UInt32>(0) }
    private let slots: [Slot] = (0..<StripMeters.capacity).map { _ in Slot() }

    public init() {}

    /// Realtime-safe.
    public func record(strip: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard strip >= 0, strip < Self.capacity, frames > 0 else { return }
        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(left, 1, &pl, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &pr, vDSP_Length(frames))
        let peak = max(pl, pr)
        guard peak.isFinite else { return }
        let slot = slots[strip]
        var current = slot.bits.load(ordering: .relaxed)
        while peak.bitPattern > current {
            let (done, original) = slot.bits.compareExchange(expected: current, desired: peak.bitPattern, ordering: .relaxed)
            if done { break }
            current = original
        }
    }

    public func take(strip: Int) -> Float {
        guard strip >= 0, strip < Self.capacity else { return 0 }
        return Float(bitPattern: slots[strip].bits.exchange(0, ordering: .relaxed))
    }
}
