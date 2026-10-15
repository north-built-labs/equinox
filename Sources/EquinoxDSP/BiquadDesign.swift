import Foundation

/// Normalized biquad (a0 == 1). Direct form: y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// RBJ Audio-EQ-Cookbook design. Shelves use alpha = sin(w0)/(2Q), matching AutoEQ / Equalizer APO.
    public init(band rawBand: EQBand, sampleRate: Double) {
        let band = rawBand.clamped()
        let f0 = min(band.frequency, 0.49 * sampleRate)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * band.q)
        let A = pow(10, band.gainDB / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cw)
            b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s
            a1 = -2 * ((A - 1) + (A + 1) * cw)
            a2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cw)
            b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s
            a1 = 2 * ((A - 1) - (A + 1) * cw)
            a2 = (A + 1) - (A - 1) * cw - s
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .bandPass:
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Linear magnitude of the frequency response.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
    }
}

public enum EQResponse {
    /// Combined response in dB of all enabled bands plus preamp.
    public static func decibels(bands: [EQBand], preampDB: Double, frequency: Double, sampleRate: Double) -> Double {
        var total = preampDB
        for band in bands where band.isEnabled {
            let m = BiquadCoefficients(band: band, sampleRate: sampleRate).magnitude(at: frequency, sampleRate: sampleRate)
            total += 20 * log10(max(m, 1e-9))
        }
        return total
    }
}
