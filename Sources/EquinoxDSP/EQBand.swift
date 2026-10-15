import Foundation

public enum FilterType: String, Codable, CaseIterable, Sendable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass

    public var displayName: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .notch: "Notch"
        case .bandPass: "Band Pass"
        }
    }

    /// Whether the gain parameter affects this filter type.
    public var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}

public struct EQBand: Codable, Hashable, Identifiable, Sendable {
    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let gainRange: ClosedRange<Double> = -24...24
    public static let qRange: ClosedRange<Double> = 0.1...18

    public var id: UUID
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), type: FilterType = .peak, frequency: Double,
                gainDB: Double = 0, q: Double = 1, isEnabled: Bool = true) {
        self.id = id; self.type = type; self.frequency = frequency
        self.gainDB = gainDB; self.q = q; self.isEnabled = isEnabled
    }

    public func clamped() -> EQBand {
        var b = self
        b.frequency = Self.clamp(frequency, Self.frequencyRange)
        b.gainDB = Self.clamp(gainDB, Self.gainRange)
        b.q = Self.clamp(q, Self.qRange)
        return b
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }
}
