import Foundation

public enum CrossfeedStrength: String, Codable, CaseIterable, Sendable {
    case off, low, medium, high

    public var displayName: String { rawValue.capitalized }

    var amount: Float {
        switch self { case .off: 0; case .low: 0.30; case .medium: 0.45; case .high: 0.60 }
    }

    var cutoff: Double {
        switch self { case .off, .low: 700; case .medium: 650; case .high: 600 }
    }
}

/// Complementary crossfeed: L' = L + c·(D[LP(R)] − D[LP(L)]), R' = R − c·(D[LP(R)] − D[LP(L)]).
/// Low frequencies of each side bleed (slightly delayed) into the other; mono content (L = R) is untouched.
public final class Crossfeed {
    private static let delayCapacity = 64
    private static let delaySeconds = 0.0003

    private var amount: Float = 0
    private var alpha: Float = 0
    private var delay = 1
    private var lowL: Float = 0, lowR: Float = 0
    private var writeIndex = 0
    private let lineL = UnsafeMutablePointer<Float>.allocate(capacity: Crossfeed.delayCapacity)
    private let lineR = UnsafeMutablePointer<Float>.allocate(capacity: Crossfeed.delayCapacity)

    public init(sampleRate: Double) {
        lineL.initialize(repeating: 0, count: Self.delayCapacity)
        lineR.initialize(repeating: 0, count: Self.delayCapacity)
        configure(.off, sampleRate: sampleRate)
    }

    deinit { lineL.deallocate(); lineR.deallocate() }

    /// Realtime-safe.
    public func configure(_ strength: CrossfeedStrength, sampleRate: Double) {
        if strength == .off, amount != 0 { reset() }
        amount = strength.amount
        alpha = Float(1 - exp(-2 * Double.pi * strength.cutoff / sampleRate))
        delay = min(max(Int((Self.delaySeconds * sampleRate).rounded()), 1), Self.delayCapacity - 1)
    }

    private func reset() {
        lowL = 0; lowR = 0
        lineL.update(repeating: 0, count: Self.delayCapacity)
        lineR.update(repeating: 0, count: Self.delayCapacity)
    }

    /// Realtime-safe, in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard amount > 0 else { return }
        let mask = Self.delayCapacity - 1
        for i in 0..<frames {
            lowL += alpha * (left[i] - lowL)
            lowR += alpha * (right[i] - lowR)
            lineL[writeIndex] = lowL
            lineR[writeIndex] = lowR
            let read = (writeIndex - delay) & mask
            let difference = amount * (lineR[read] - lineL[read])
            left[i] += difference
            right[i] -= difference
            writeIndex = (writeIndex + 1) & mask
        }
    }
}
