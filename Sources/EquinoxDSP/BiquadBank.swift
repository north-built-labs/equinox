import Accelerate

/// Stereo cascade of `maxSections` biquads backed by vDSP_biquadm.
/// Unused sections are identity, so the section count never changes and
/// coefficient updates can always be ramped (no zipper noise).
public final class BiquadBank {
    public static let maxSections = 32
    static let channels = 2
    /// Fraction of the remaining distance covered per sample while ramping (~2 ms time constant at 48 kHz).
    static let interpolationRate: Float = 0.01
    static let interpolationThreshold: Float = 1e-6

    public let maxFrames: Int
    private let setup: vDSP_biquadm_Setup
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let inputs: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
        let identity = Self.flatten([])
        setup = vDSP_biquadm_CreateSetup(identity, vDSP_Length(Self.maxSections), vDSP_Length(Self.channels))!
        scratchL = .allocate(capacity: maxFrames); scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR = .allocate(capacity: maxFrames); scratchR.initialize(repeating: 0, count: maxFrames)
        inputs = .allocate(capacity: 2)
        inputs.initialize(to: UnsafePointer(scratchL)); (inputs + 1).initialize(to: UnsafePointer(scratchR))
        outputs = .allocate(capacity: 2)
        outputs.initialize(to: scratchL); (outputs + 1).initialize(to: scratchR)
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
        scratchL.deallocate(); scratchR.deallocate(); inputs.deallocate(); outputs.deallocate()
    }

    /// Flattened coefficient array in vDSP_biquadm layout: index (section * channels + channel) * 5.
    /// Sections beyond `maxSections` are dropped; missing ones are identity.
    public static func flatten(_ sections: [BiquadCoefficients]) -> [Double] {
        var flat = [Double](repeating: 0, count: maxSections * channels * 5)
        for s in 0..<maxSections {
            let c = s < sections.count ? sections[s] : .identity
            for ch in 0..<channels {
                let i = (s * channels + ch) * 5
                flat[i] = c.b0; flat[i + 1] = c.b1; flat[i + 2] = c.b2; flat[i + 3] = c.a1; flat[i + 4] = c.a2
            }
        }
        return flat
    }

    /// Realtime-safe. `flat` must come from `flatten`.
    public func setCoefficients(_ flat: [Double], ramp: Bool) {
        precondition(flat.count == Self.maxSections * Self.channels * 5)
        flat.withUnsafeBufferPointer { p in
            if ramp {
                vDSP_biquadm_SetTargetsDouble(setup, p.baseAddress!, Self.interpolationRate, Self.interpolationThreshold,
                                              0, 0, vDSP_Length(Self.maxSections), vDSP_Length(Self.channels))
            } else {
                vDSP_biquadm_SetCoefficientsDouble(setup, p.baseAddress!, 0, 0,
                                                   vDSP_Length(Self.maxSections), vDSP_Length(Self.channels))
            }
        }
    }

    /// Realtime-safe, in place. `frames` must be <= maxFrames.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        precondition(frames <= maxFrames)
        scratchL.update(from: left, count: frames)
        scratchR.update(from: right, count: frames)
        outputs[0] = left; outputs[1] = right
        vDSP_biquadm(setup, inputs, 1, outputs, 1, vDSP_Length(frames))
    }

    public func reset() { vDSP_biquadm_ResetState(setup) }
}
