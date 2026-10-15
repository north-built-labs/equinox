import Accelerate

/// Per-strip processing before the master chain: optional per-app EQ, ramped gain, then summed into the mix bus.
/// A bus is built for a fixed strip count (one per tap); configs map positionally onto it.
public final class MixBus {
    public static let maxStrips = 17

    public let stripCount: Int
    public let maxFrames: Int
    private let banks: [BiquadBank]
    private var eqActive: [Bool]
    private var current: [Float]
    private var target: [Float]
    private var hasConfig = false

    public init(stripCount: Int, maxFrames: Int) {
        self.stripCount = max(1, min(stripCount, Self.maxStrips))
        self.maxFrames = maxFrames
        banks = (0..<self.stripCount).map { _ in BiquadBank(maxFrames: maxFrames) }
        eqActive = Array(repeating: false, count: self.stripCount)
        current = Array(repeating: 1, count: self.stripCount)
        target = Array(repeating: 1, count: self.stripCount)
    }

    /// Realtime-safe. Extra configs are ignored; strips without a config play at unity.
    public func apply(_ strips: [StripConfig]) {
        for i in 0..<stripCount {
            let cfg = i < strips.count ? strips[i] : .unity
            target[i] = cfg.gain
            if !hasConfig { current[i] = cfg.gain }
            if let eq = cfg.eqCoefficients {
                banks[i].setCoefficients(eq, ramp: eqActive[i])
                eqActive[i] = true
            } else if eqActive[i] {
                eqActive[i] = false
                banks[i].reset()
            }
        }
        hasConfig = true
    }

    /// Realtime-safe. Processes strip `strip` in place, then adds it into the mix. `frames <= maxFrames`.
    public func accumulate(strip: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                           intoLeft mixL: UnsafeMutablePointer<Float>, intoRight mixR: UnsafeMutablePointer<Float>,
                           frames: Int) {
        guard strip < stripCount, frames > 0 else { return }
        if eqActive[strip] { banks[strip].process(left: left, right: right, frames: frames) }
        let n = vDSP_Length(frames)
        if current[strip] == target[strip] {
            var g = target[strip]
            if g != 1 { vDSP_vsmul(left, 1, &g, left, 1, n); vDSP_vsmul(right, 1, &g, right, 1, n) }
        } else {
            var step = (target[strip] - current[strip]) / Float(frames)
            var startL = current[strip], startR = current[strip]
            vDSP_vrampmul(left, 1, &startL, &step, left, 1, n)
            vDSP_vrampmul(right, 1, &startR, &step, right, 1, n)
            current[strip] = target[strip]
        }
        vDSP_vadd(left, 1, mixL, 1, mixL, 1, n)
        vDSP_vadd(right, 1, mixR, 1, mixR, 1, n)
    }
}
