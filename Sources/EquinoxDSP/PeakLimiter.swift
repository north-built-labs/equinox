import Foundation

/// Stereo-linked peak limiter: instant attack, exponential release, hard ceiling clamp.
public final class PeakLimiter {
    public let ceiling: Float
    private let releaseMs: Double
    private var releaseCoefficient: Float
    private var gain: Float = 1

    public init(ceilingDB: Double = -0.3, releaseMs: Double = 80, sampleRate: Double) {
        ceiling = Float(Decibels.toLinear(ceilingDB))
        self.releaseMs = releaseMs
        releaseCoefficient = Self.coefficient(releaseMs: releaseMs, sampleRate: sampleRate)
    }

    private static func coefficient(releaseMs: Double, sampleRate: Double) -> Float {
        Float(exp(-1 / (releaseMs * 0.001 * sampleRate)))
    }

    public func setSampleRate(_ sampleRate: Double) {
        releaseCoefficient = Self.coefficient(releaseMs: releaseMs, sampleRate: sampleRate)
    }

    public func reset() { gain = 1 }

    /// Realtime-safe, in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let c = ceiling, rel = releaseCoefficient
        var g = gain
        for i in 0..<frames {
            let peak = max(abs(left[i]), abs(right[i]))
            let target: Float = peak > c ? c / peak : 1
            g = target < g ? target : target + (g - target) * rel
            left[i] = min(max(left[i] * g, -c), c)
            right[i] = min(max(right[i] * g, -c), c)
        }
        gain = g
    }
}
