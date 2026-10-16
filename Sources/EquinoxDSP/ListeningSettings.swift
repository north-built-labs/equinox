import Foundation

/// Opt-in master processing. The target is stereo RMS in dBFS, not LUFS or acoustic SPL.
public struct ListeningSettings: Codable, Hashable, Sendable {
    public var isEnabled = false
    public var levelsEnabled = true
    public var targetDB = -20.0
    public var preserveDynamics = 0.5
    public var bass = 0.0
    public var harshness = 0.35
    public var sibilance = 0.2

    public init() {}

    public func clamped() -> Self {
        var s = self
        s.targetDB = Self.clamp(targetDB, -30...(-14), fallback: -20)
        s.preserveDynamics = Self.clamp(preserveDynamics, 0...1, fallback: 0.5)
        s.bass = Self.clamp(bass, 0...1, fallback: 0)
        s.harshness = Self.clamp(harshness, 0...1, fallback: 0)
        s.sibilance = Self.clamp(sibilance, 0...1, fallback: 0)
        return s
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, levelsEnabled, targetDB, preserveDynamics, bass, harshness, sibilance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        levelsEnabled = try c.decodeIfPresent(Bool.self, forKey: .levelsEnabled) ?? true
        targetDB = try c.decodeIfPresent(Double.self, forKey: .targetDB) ?? -20
        preserveDynamics = try c.decodeIfPresent(Double.self, forKey: .preserveDynamics) ?? 0.5
        bass = try c.decodeIfPresent(Double.self, forKey: .bass) ?? 0
        harshness = try c.decodeIfPresent(Double.self, forKey: .harshness) ?? 0.35
        sibilance = try c.decodeIfPresent(Double.self, forKey: .sibilance) ?? 0.2
        self = clamped()
    }
}

/// All expensive design work happens when the immutable DSP snapshot is built.
public struct ListeningConfig: Sendable {
    let settings: ListeningSettings
    let sampleRate: Double
    let bass, harshness, sibilance: BiquadCoefficients
    let envelopeAttack, envelopeRelease, gainDown, gainUp, transition: Double
    let bandAttack, bandRelease: Double

    public init(settings: ListeningSettings, sampleRate: Double) {
        let s = settings.clamped()
        self.settings = s
        let rate = sampleRate.isFinite ? min(max(sampleRate, 8_000), 384_000) : 48_000
        self.sampleRate = rate
        bass = BiquadCoefficients(band: EQBand(type: .bandPass, frequency: 120, q: 0.8), sampleRate: rate)
        harshness = BiquadCoefficients(band: EQBand(type: .bandPass, frequency: 3200, q: 1.4), sampleRate: rate)
        sibilance = BiquadCoefficients(band: EQBand(type: .bandPass, frequency: 7000, q: 2), sampleRate: rate)
        envelopeAttack = exp(-1 / (0.025 * rate))
        envelopeRelease = exp(-1 / (0.25 * rate))
        gainDown = exp(-1 / ((0.08 + 0.32 * s.preserveDynamics) * rate))
        gainUp = exp(-1 / ((1 + 3 * s.preserveDynamics) * rate))
        transition = exp(-1 / (0.01 * rate))
        bandAttack = exp(-1 / (0.008 * rate))
        bandRelease = exp(-1 / (0.15 * rate))
    }
}

public struct ListeningActivity: Equatable, Sendable {
    public var gainDB: Float = 0
    public var bassDB: Float = 0
    public var harshnessDB: Float = 0
    public var sibilanceDB: Float = 0
    public init() {}
}
