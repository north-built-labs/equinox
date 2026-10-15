import Accelerate
import Synchronization

/// Single-producer (audio thread) ring of post-processing mono samples + peak meters.
/// Readers may observe a partially overwritten window under heavy load; acceptable for visualization.
public final class AnalysisTap: @unchecked Sendable {
    public static let capacity = 16_384
    private static let mask = capacity - 1

    private let ring: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let peakLeftBits = Atomic<UInt32>(0)
    private let peakRightBits = Atomic<UInt32>(0)

    public init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { ring.deallocate() }

    /// Realtime-safe.
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let start = writeIndex.load(ordering: .relaxed)
        for i in 0..<frames {
            ring[(start + i) & Self.mask] = 0.5 * (left[i] + right[i])
        }
        writeIndex.store(start + frames, ordering: .releasing)

        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(left, 1, &pl, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &pr, vDSP_Length(frames))
        Self.raise(peakLeftBits, to: pl)
        Self.raise(peakRightBits, to: pr)
    }

    private static func raise(_ atomic: borrowing Atomic<UInt32>, to value: Float) {
        guard value.isFinite else { return }
        let bits = value.bitPattern   // non-negative floats order like their bit patterns
        var current = atomic.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = atomic.compareExchange(expected: current, desired: bits, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    /// Copies the newest `out.count` samples (oldest first). `out.count` must be <= capacity.
    public func copyLatest(into out: inout [Float]) {
        let n = min(out.count, Self.capacity)
        let end = writeIndex.load(ordering: .acquiring)
        for i in 0..<n {
            out[i] = ring[(end - n + i) & Self.mask]
        }
    }

    /// Peak magnitudes since the last call.
    public func takePeaks() -> (left: Float, right: Float) {
        (Float(bitPattern: peakLeftBits.exchange(0, ordering: .relaxed)),
         Float(bitPattern: peakRightBits.exchange(0, ordering: .relaxed)))
    }
}
