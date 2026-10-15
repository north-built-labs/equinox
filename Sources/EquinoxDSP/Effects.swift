import Foundation

public enum BuiltInEffect: String, Codable, CaseIterable, Sendable {
    case reverb, compressor, multibandCompressor, limiter, delay

    public var displayName: String {
        switch self {
        case .reverb: "Reverb"
        case .compressor: "Compressor"
        case .multibandCompressor: "Multiband Compressor"
        case .limiter: "Limiter"
        case .delay: "Delay"
        }
    }

    public var symbol: String {
        switch self {
        case .reverb: "building.columns"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .multibandCompressor: "chart.bar.xaxis"
        case .limiter: "rectangle.compress.vertical"
        case .delay: "wave.3.right"
        }
    }
}

/// Identifies an installed Audio Unit effect by its component description (four-char codes as UInt32).
public struct AudioUnitID: Codable, Hashable, Sendable {
    public let type: UInt32
    public let subType: UInt32
    public let manufacturer: UInt32
    public let name: String
    public let manufacturerName: String

    public init(type: UInt32, subType: UInt32, manufacturer: UInt32, name: String, manufacturerName: String) {
        self.type = type; self.subType = subType; self.manufacturer = manufacturer
        self.name = name; self.manufacturerName = manufacturerName
    }

    public var key: String { String(format: "%08X-%08X-%08X", type, subType, manufacturer) }
}

public enum EffectKind: Codable, Hashable, Sendable {
    case builtIn(BuiltInEffect)
    case audioUnit(AudioUnitID)

    public var displayName: String {
        switch self {
        case .builtIn(let e): e.displayName
        case .audioUnit(let id): id.name
        }
    }
}

public struct EffectSlot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: EffectKind
    public var isEnabled: Bool
    /// `AUAudioUnit.fullState` as a binary plist; nil = factory defaults.
    public var state: Data?

    public init(id: UUID = UUID(), kind: EffectKind, isEnabled: Bool = true, state: Data? = nil) {
        self.id = id; self.kind = kind; self.isEnabled = isEnabled; self.state = state
    }

    public struct Structure: Hashable, Sendable {
        public let id: UUID
        public let kind: EffectKind
        public let isEnabled: Bool
    }

    /// Identity, order-relevant kind and enablement — everything except parameter state.
    public var structure: Structure { Structure(id: id, kind: kind, isEnabled: isEnabled) }
}
