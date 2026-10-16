import Foundation

/// Fixed-state, stereo-linked adaptive processing. No allocation, locks or added latency.
/// All mutable state belongs to the render thread; UI activity is copied through AnalysisTap.
public final class ListeningProcessor {
    private var config: ListeningConfig
    private var bass = ReactiveBand()
    private var harshness = ReactiveBand()
    private var sibilance = ReactiveBand()
    private var power = 0.0
    private var fastPower = 0.0
    private var gain = 1.0
    private var targetGain = 1.0
    private var wet = 0.0
    private var activeFrames = 0
    private var controlFrames = 0
    public private(set) var activity = ListeningActivity()

    public init(sampleRate: Double) {
        config = ListeningConfig(settings: ListeningSettings(), sampleRate: sampleRate)
    }

    public func configure(_ config: ListeningConfig) {
        if self.config.sampleRate != config.sampleRate { reset() }
        self.config = config
    }

    public func reset() {
        bass = ReactiveBand(); harshness = ReactiveBand(); sibilance = ReactiveBand()
        power = 0; fastPower = 0; gain = 1; targetGain = 1; wet = 0
        activeFrames = 0; controlFrames = 0
        activity = ListeningActivity()
    }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let c = config, s = c.settings
        if !s.isEnabled && wet == 0 { return }
        let targetWet = s.isEnabled ? 1.0 : 0.0
        for i in 0..<frames {
            let dryL = Double(left[i]), dryR = Double(right[i])
            guard dryL.isFinite, dryR.isFinite else {
                left[i] = 0; right[i] = 0; reset()
                continue
            }
            let energy = 0.5 * (dryL * dryL + dryR * dryR)
            power = energy + c.envelopeRelease * (power - energy)
            fastPower = energy + c.envelopeAttack * (fastPower - energy)
            // Flush inaudible tails so long silent periods do not enter subnormal arithmetic.
            if power < 1e-30 { power = 0 }
            if fastPower < 1e-30 { fastPower = 0 }
            // Require sustained activity before boosting. Noise/silence cannot wind gain up.
            if fastPower > 1e-5 {
                activeFrames = min(activeFrames + 1, Int(c.sampleRate))
            } else {
                activeFrames = 0
            }
            if controlFrames == 0 {
                let inputDB = 10 * log10(max(power, 1e-20))
                var desiredDB = s.levelsEnabled ? (s.targetDB - inputDB) * (1 - 0.6 * s.preserveDynamics) : 0
                desiredDB = min(max(desiredDB, -18), 6)
                if activeFrames < Int(c.sampleRate * 0.25) { desiredDB = min(desiredDB, 0) }
                if fastPower < 1e-5 { desiredDB = 0 }
                targetGain = pow(10, desiredDB / 20)
            }
            let smoothing = !s.levelsEnabled ? c.transition : (targetGain < gain ? c.gainDown : c.gainUp)
            gain = targetGain + smoothing * (gain - targetGain)
            var l = dryL * gain, r = dryR * gain
            bass.process(left: &l, right: &r, coefficients: c.bass, amount: s.bass, thresholdDB: -24,
                         config: c, update: controlFrames == 0)
            harshness.process(left: &l, right: &r, coefficients: c.harshness, amount: s.harshness, thresholdDB: -28,
                              config: c, update: controlFrames == 0)
            sibilance.process(left: &l, right: &r, coefficients: c.sibilance, amount: s.sibilance, thresholdDB: -32,
                              config: c, update: controlFrames == 0)
            wet = targetWet + c.transition * (wet - targetWet)
            left[i] = Float(dryL + wet * (l - dryL))
            right[i] = Float(dryR + wet * (r - dryR))
            if !left[i].isFinite || !right[i].isFinite {
                left[i] = 0; right[i] = 0; reset()
            }
            controlFrames = (controlFrames + 1) & 63
        }
        if !s.isEnabled && wet < 1e-6 { reset() }
        activity.gainDB = Float(20 * log10(max(1 + wet * (gain - 1), 1e-20)))
        activity.bassDB = bass.reductionDB(wet: wet)
        activity.harshnessDB = harshness.reductionDB(wet: wet)
        activity.sibilanceDB = sibilance.reductionDB(wet: wet)
    }
}

private struct FilterState {
    var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        if abs(z1) < 1e-30 { z1 = 0 }
        if abs(z2) < 1e-30 { z2 = 0 }
        return y
    }
}

private struct ReactiveBand {
    var left = FilterState(), right = FilterState()
    var power = 0.0
    var cut = 0.0, targetCut = 0.0

    mutating func process(left l: inout Double, right r: inout Double, coefficients: BiquadCoefficients,
                          amount: Double, thresholdDB: Double, config c: ListeningConfig, update: Bool) {
        let bandL = left.process(l, coefficients), bandR = right.process(r, coefficients)
        let energy = 0.5 * (bandL * bandL + bandR * bandR)
        let detector = energy > power ? c.bandAttack : c.bandRelease
        power = energy + detector * (power - energy)
        if power < 1e-30 { power = 0 }
        if update {
            let levelDB = 10 * log10(max(power, 1e-20))
            let reduction = min(max(0, (levelDB - thresholdDB) * 0.75), 9 * amount)
            targetCut = 1 - pow(10, -reduction / 20)
        }
        let smoothing = targetCut > cut ? c.bandAttack : c.bandRelease
        cut = targetCut + smoothing * (cut - targetCut)
        if cut < 1e-30 { cut = 0 }
        l -= cut * bandL
        r -= cut * bandR
    }

    func reductionDB(wet: Double) -> Float {
        Float(-20 * log10(max(1 - wet * cut, 1e-20)))
    }
}
