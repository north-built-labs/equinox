import Accelerate

/// Master chain: EQ → gain (preamp·volume·boost·balance, ramped) → limiter.
/// EQ is linear, so folding preamp into the post-EQ gain is equivalent and avoids zipper noise.
public final class MasterProcessor {
    public let maxFrames: Int
    public let limiter: PeakLimiter
    private let eq: BiquadBank
    private var hasConfig = false
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
        targetLeft = config.leftGain; targetRight = config.rightGain
        if !hasConfig { currentLeft = targetLeft; currentRight = targetRight }
        limiter.setSampleRate(config.sampleRate)
        hasConfig = true
    }

    /// Realtime-safe, in place, any frame count. Equivalent to `processPre` then `processPost`.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        processPre(left: left, right: right, frames: frames)
        processPost(left: left, right: right, frames: frames)
    }

    /// EQ stage (before the effects chain). Realtime-safe, in place, any frame count.
    public func processPre(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        forEachChunk(frames) { o, n in
            eq.process(left: left + o, right: right + o, frames: n)
            if !Self.isFinite(left + o, right + o, n) {
                eq.reset()
                (left + o).update(repeating: 0, count: n); (right + o).update(repeating: 0, count: n)
            }
        }
    }

    /// Output stage (after the effects chain): gain ramp, then limiter. Realtime-safe, in place, any frame count.
    public func processPost(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        forEachChunk(frames) { o, n in
            if !Self.isFinite(left + o, right + o, n) {
                limiter.reset()
                (left + o).update(repeating: 0, count: n); (right + o).update(repeating: 0, count: n)
            }
            ramp(left + o, &currentLeft, targetLeft, n)
            ramp(right + o, &currentRight, targetRight, n)
            limiter.process(left: left + o, right: right + o, frames: n)
        }
    }

    @inline(__always)
    private func forEachChunk(_ frames: Int, _ body: (Int, Int) -> Void) {
        var offset = 0
        while offset < frames {
            let n = min(maxFrames, frames - offset)
            body(offset, n)
            offset += n
        }
    }

    private static func isFinite(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) -> Bool {
        var el: Float = 0, er: Float = 0
        vDSP_svesq(l, 1, &el, vDSP_Length(n))
        vDSP_svesq(r, 1, &er, vDSP_Length(n))
        return (el + er).isFinite
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
