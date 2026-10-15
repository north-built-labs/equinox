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

    public init() {}
}

/// Immutable, sample-rate specific snapshot handed to the realtime thread.
public final class DSPConfig: @unchecked Sendable {
    public let sampleRate: Double
    public let isBypassed: Bool
    public let eqCoefficients: [Double]
    public let leftGain: Float
    public let rightGain: Float

    public init(settings s: DSPSettings, sampleRate: Double) {
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
        let bal = Balance.gains(s.balance)
        let common = s.isMuted ? 0 : volume * boost * preamp
        leftGain = Float(common * bal.left)
        rightGain = Float(common * bal.right)
    }
}
