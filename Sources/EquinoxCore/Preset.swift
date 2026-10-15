import Foundation
import EquinoxDSP

public enum PresetError: Error, Equatable { case invalidFile }

public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var preampDB: Double
    public var bands: [EQBand]
    public var isBuiltIn: Bool
    public var effects: [EffectSlot]

    public init(id: UUID = UUID(), name: String, preampDB: Double = 0, bands: [EQBand], isBuiltIn: Bool = false,
                effects: [EffectSlot] = []) {
        self.id = id; self.name = name; self.preampDB = preampDB; self.bands = bands; self.isBuiltIn = isBuiltIn
        self.effects = effects
    }

    enum CodingKeys: String, CodingKey { case id, name, preampDB, bands, isBuiltIn, effects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        preampDB = try c.decode(Double.self, forKey: .preampDB)
        bands = try c.decode([EQBand].self, forKey: .bands)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        effects = (try? c.decodeIfPresent([EffectSlot].self, forKey: .effects)) ?? []
    }

    public static let graphicFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public static func graphic(id: String, name: String, gains: [Double], preampDB: Double = 0) -> Preset {
        let bands = zip(graphicFrequencies, gains).map { EQBand(type: .peak, frequency: $0, gainDB: $1, q: 1.41) }
        return Preset(id: UUID(uuidString: id)!, name: name, preampDB: preampDB, bands: bands, isBuiltIn: true)
    }

    public static let flat = graphic(id: "00000000-0000-0000-0000-000000000001", name: "Flat", gains: Array(repeating: 0, count: 10))

    public static let builtIns: [Preset] = [
        flat,
        graphic(id: "00000000-0000-0000-0000-000000000002", name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000003", name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000004", name: "Vocal", gains: [-2, -2, -1, 0, 2, 4, 4, 2, 0, -1], preampDB: -3),
        graphic(id: "00000000-0000-0000-0000-000000000005", name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000006", name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5], preampDB: -4),
        graphic(id: "00000000-0000-0000-0000-000000000007", name: "Acoustic", gains: [4, 3, 2, 1, 1, 1, 2, 3, 2, 1], preampDB: -3),
        graphic(id: "00000000-0000-0000-0000-000000000008", name: "Late Night", gains: [-3, -2, 0, 1, 2, 2, 1, 0, -2, -3], preampDB: -2),
    ]

    /// Accepts a single preset object or an array. Returns user presets with fresh IDs, clamped values.
    public static func importPresets(from data: Data) throws -> [Preset] {
        let decoder = JSONDecoder()
        let raw: [Preset]
        if let many = try? decoder.decode([Preset].self, from: data) {
            raw = many
        } else if let one = try? decoder.decode(Preset.self, from: data) {
            raw = [one]
        } else {
            throw PresetError.invalidFile
        }
        guard !raw.isEmpty else { throw PresetError.invalidFile }
        return raw.map { p in
            Preset(name: p.name.isEmpty ? "Imported" : p.name,
                   preampDB: min(max(p.preampDB.isFinite ? p.preampDB : 0, -24), 24),
                   bands: p.bands.prefix(BiquadBank.maxSections).map { var b = $0.clamped(); b.id = UUID(); return b },
                   isBuiltIn: false,
                   effects: p.effects.map { var s = $0; s.id = UUID(); return s })
        }
    }

    public static func exportData(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(presets)
    }
}
