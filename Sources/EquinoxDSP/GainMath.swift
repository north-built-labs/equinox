import Foundation

public enum Decibels {
    public static func toLinear(_ dB: Double) -> Double { pow(10, dB / 20) }
    public static func fromLinear(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }
}

public enum Balance {
    /// balance in -1 (left only) ... +1 (right only). The louder side stays at unity.
    public static func gains(_ balance: Double) -> (left: Double, right: Double) {
        let b = min(max(balance.isFinite ? balance : 0, -1), 1)
        return (left: b > 0 ? 1 - b : 1, right: b < 0 ? 1 + b : 1)
    }
}
