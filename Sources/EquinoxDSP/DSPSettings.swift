import Foundation

/// Sample-rate independent processing parameters, produced by the app model.
public struct DSPSettings: Codable, Equatable, Sendable {
    public static let maxBoostDB = 12.0

    public var isBypassed = false
    public var preampDB = 0.0
    public var bands: [EQBand] = []
    /// 0...1; used when the output device has no hardware volume.
    public var softwareVolume = 1.0
    /// 0...maxBoostDB
    public var boostDB = 0.0
    /// -1...1
    public var balance = 0.0
    public var isMuted = false
    /// Per-app strips (Phase 2). Mapped to the session's tap order by key.
    public var strips: [StripSettings] = []
    /// Headphone correction (AutoEq), applied before the user EQ.
    public var correction: CorrectionProfile?
    public var crossfeed: CrossfeedStrength = .off
    /// Spatial audio runs in the audio layer; when on, crossfeed is skipped.
    public var spatialEnabled = false

    public init() {}
}

/// Immutable, sample-rate specific snapshot handed to the realtime thread.
public final class DSPConfig: @unchecked Sendable {
    public let sampleRate: Double
    public let isBypassed: Bool
    public let eqCoefficients: [Double]
    public let leftGain: Float
    public let rightGain: Float
    public let strips: [StripConfig]
    public let correctionCoefficients: [Double]?
    public let crossfeed: CrossfeedStrength
    public let spatialEnabled: Bool

    public init(settings s: DSPSettings, sampleRate: Double, stripOrder: [String] = [StripSettings.othersKey]) {
        self.sampleRate = sampleRate
        isBypassed = s.isBypassed
        // Bypass turns the EQ and preamp off (ramped to identity, so no click);
        // output controls, the limiter and the non-finite guard stay active.
        let sections = s.isBypassed ? [] : s.bands.lazy.filter(\.isEnabled).prefix(BiquadBank.maxSections)
            .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        eqCoefficients = BiquadBank.flatten(Array(sections))
        let volume = min(max(s.softwareVolume.isFinite ? s.softwareVolume : 1, 0), 1)
        let boost = Decibels.toLinear(min(max(s.boostDB.isFinite ? s.boostDB : 0, 0), DSPSettings.maxBoostDB))
        let preamp = s.isBypassed ? 1 : Decibels.toLinear(min(max(s.preampDB.isFinite ? s.preampDB : 0, -24), 24))
        let correction = s.isBypassed ? nil : s.correction
        correctionCoefficients = correction.map { c in
            BiquadBank.flatten(c.bands.lazy.filter(\.isEnabled).prefix(BiquadBank.maxSections)
                .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) })
        }
        let correctionPreamp = correction.map { Decibels.toLinear(min(max($0.preampDB, -24), 24)) } ?? 1
        spatialEnabled = !s.isBypassed && s.spatialEnabled
        crossfeed = s.isBypassed || s.spatialEnabled ? .off : s.crossfeed
        let bal = Balance.gains(s.balance)
        let common = s.isMuted ? 0 : volume * boost * preamp * correctionPreamp
        leftGain = Float(common * bal.left)
        rightGain = Float(common * bal.right)
        strips = stripOrder.map { key in
            s.strips.first { $0.key == key }.map { StripConfig(settings: $0, sampleRate: sampleRate) } ?? .unity
        }
    }
}

public struct StripSettings: Codable, Equatable, Sendable {
    public static let othersKey = ""
    public static let maxVolume = 1.5

    public var key: String
    public var volume: Double
    public var isMuted: Bool
    public var preampDB: Double
    /// Empty = no per-app EQ.
    public var bands: [EQBand]

    public init(key: String, volume: Double = 1, isMuted: Bool = false, preampDB: Double = 0, bands: [EQBand] = []) {
        self.key = key; self.volume = volume; self.isMuted = isMuted; self.preampDB = preampDB; self.bands = bands
    }
}

public struct StripConfig: Sendable {
    public static let unity = StripConfig(gain: 1, eqCoefficients: nil)
    public let gain: Float
    /// nil = no per-app EQ (strip EQ is skipped).
    public let eqCoefficients: [Double]?

    public init(gain: Float, eqCoefficients: [Double]?) { self.gain = gain; self.eqCoefficients = eqCoefficients }

    init(settings s: StripSettings, sampleRate: Double) {
        let volume = min(max(s.volume.isFinite ? s.volume : 1, 0), StripSettings.maxVolume)
        let preamp = s.bands.isEmpty ? 1 : Decibels.toLinear(min(max(s.preampDB.isFinite ? s.preampDB : 0, -24), 24))
        gain = s.isMuted ? 0 : Float(volume * preamp)
        let sections = s.bands.lazy.filter(\.isEnabled).prefix(BiquadBank.maxSections)
            .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        eqCoefficients = s.bands.isEmpty ? nil : BiquadBank.flatten(Array(sections))
    }
}
