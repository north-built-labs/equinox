import Accelerate

/// Master chain: EQ → gain (preamp·volume·boost·balance, ramped) → limiter.
/// EQ is linear, so folding preamp into the post-EQ gain is equivalent and avoids zipper noise.
public final class MasterProcessor {
    public let maxFrames: Int
    public let limiter: PeakLimiter
    private let eq: BiquadBank
    private var hasConfig = false
    private var isBypassed = false
    private var currentLeft: Float = 1, currentRight: Float = 1
    private var targetLeft: Float = 1, targetRight: Float = 1

    public init(maxFrames: Int, sampleRate: Double) {
        self.maxFrames = maxFrames
        eq = BiquadBank(maxFrames: maxFrames)
        limiter = PeakLimiter(sampleRate: sampleRate)
    }

    /// Realtime-safe. The first config is applied immediately, later ones are ramped.
    public func apply(_ config: DSPConfig) {
        eq.setCoefficients(config.eqCoefficients, ramp: hasConfig)
        isBypassed = config.isBypassed
        targetLeft = config.leftGain; targetRight = config.rightGain
        if !hasConfig { currentLeft = targetLeft; currentRight = targetRight }
        limiter.setSampleRate(config.sampleRate)
        hasConfig = true
    }

    /// Realtime-safe, in place, any frame count.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard !isBypassed else { return }
        var offset = 0
        while offset < frames {
            let n = min(maxFrames, frames - offset)
            processChunk(left + offset, right + offset, n)
            offset += n
        }
    }

    private func processChunk(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        eq.process(left: l, right: r, frames: n)

        var energy: Float = 0
        vDSP_svesq(l, 1, &energy, vDSP_Length(n))
        var energyR: Float = 0
        vDSP_svesq(r, 1, &energyR, vDSP_Length(n))
        if !(energy + energyR).isFinite {
            eq.reset(); limiter.reset()
            l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
            return
        }

        ramp(l, &currentLeft, targetLeft, n)
        ramp(r, &currentRight, targetRight, n)
        limiter.process(left: l, right: r, frames: n)
    }

    private func ramp(_ x: UnsafeMutablePointer<Float>, _ current: inout Float, _ target: Float, _ n: Int) {
        if current == target {
            if target != 1 { var g = target; vDSP_vsmul(x, 1, &g, x, 1, vDSP_Length(n)) }
            return
        }
        var start = current
        var step = (target - current) / Float(n)
        vDSP_vrampmul(x, 1, &start, &step, x, 1, vDSP_Length(n))
        current = target
    }
}
