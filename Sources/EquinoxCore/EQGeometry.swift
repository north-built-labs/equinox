import CoreGraphics
import EquinoxDSP
import Foundation

/// Maps between canvas points and (frequency, dB). Log frequency axis 20 Hz–20 kHz, linear ±24 dB.
public struct EQGeometry: Sendable {
    public static let dbRange = 24.0
    public static let minFrequency = 20.0
    public static let maxFrequency = 20_000.0

    public var size: CGSize
    public init(size: CGSize) { self.size = size }

    private var decades: Double { log10(Self.maxFrequency / Self.minFrequency) }

    public func x(for frequency: Double) -> CGFloat {
        CGFloat(log10(max(frequency, Self.minFrequency) / Self.minFrequency) / decades) * size.width
    }

    public func frequency(atX x: CGFloat) -> Double {
        let t = min(max(Double(x / max(size.width, 1)), 0), 1)
        return Self.minFrequency * pow(10, t * decades)
    }

    public func y(forDB db: Double) -> CGFloat {
        size.height / 2 - CGFloat(db / Self.dbRange) * size.height / 2
    }

    public func db(atY y: CGFloat) -> Double {
        let v = Double((size.height / 2 - y) / max(size.height / 2, 1)) * Self.dbRange
        return min(max(v, -Self.dbRange), Self.dbRange)
    }

    /// Curve shown on the canvas: band response only. The preamp is drawn separately so that
    /// each node sits on the curve it controls.
    public func curveDB(bands: [EQBand], sampleRate: Double, atX x: CGFloat) -> Double {
        EQResponse.decibels(bands: bands, preampDB: 0, frequency: frequency(atX: x), sampleRate: sampleRate)
    }
}
