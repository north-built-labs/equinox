import Foundation

/// A headphone correction (e.g. from AutoEq), applied ahead of the user's EQ.
public struct CorrectionProfile: Codable, Hashable, Sendable {
    public var name: String
    public var source: String
    public var preampDB: Double
    public var bands: [EQBand]

    public init(name: String, source: String, preampDB: Double, bands: [EQBand]) {
        self.name = name; self.source = source; self.preampDB = preampDB; self.bands = bands
    }
}

/// Parser for Equalizer APO / AutoEq "ParametricEQ.txt" files. Input is untrusted: values are clamped,
/// filters capped at `BiquadBank.maxSections`, unknown lines ignored.
public enum ParametricEQText {
    public enum ParseError: Error { case noFilters }

    static let types: [String: FilterType] = [
        "PK": .peak, "PEQ": .peak, "LSC": .lowShelf, "LS": .lowShelf, "HSC": .highShelf, "HS": .highShelf,
        "LP": .lowPass, "LPQ": .lowPass, "HP": .highPass, "HPQ": .highPass, "NO": .notch, "BP": .bandPass,
    ]

    public static func parse(_ text: String, name: String, source: String) throws -> CorrectionProfile {
        var preamp = 0.0
        var bands: [EQBand] = []
        for raw in text.split(whereSeparator: \.isNewline).prefix(1000) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let tokens = line.split(separator: " ").map(String.init)
            if line.hasPrefix("Preamp:"), tokens.count >= 2, let v = Double(tokens[1]) {
                preamp = v
                continue
            }
            guard line.hasPrefix("Filter"), let on = tokens.firstIndex(where: { $0 == "ON" }),
                  on + 1 < tokens.count, let type = types[tokens[on + 1].uppercased()],
                  let fc = value(after: "Fc", in: tokens) else { continue }
            let q = value(after: "Q", in: tokens) ?? 0.707
            bands.append(EQBand(type: type, frequency: fc, gainDB: value(after: "Gain", in: tokens) ?? 0, q: q).clamped())
            if bands.count == BiquadBank.maxSections { break }
        }
        guard !bands.isEmpty else { throw ParseError.noFilters }
        return CorrectionProfile(name: name, source: source,
                                 preampDB: min(max(preamp.isFinite ? preamp : 0, -24), 24), bands: bands)
    }

    private static func value(after key: String, in tokens: [String]) -> Double? {
        guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count, let v = Double(tokens[i + 1]), v.isFinite else { return nil }
        return v
    }
}
