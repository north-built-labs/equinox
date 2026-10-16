import EquinoxAudio
import EquinoxDSP
import Foundation

public struct DeviceProfile: Codable, Equatable, Sendable {
    public var presetID: UUID
    public var isEnabled: Bool
    public init(presetID: UUID, isEnabled: Bool) { self.presetID = presetID; self.isEnabled = isEnabled }
}

public struct HeadphoneSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var correction: CorrectionProfile?
    public var crossfeed: CrossfeedStrength = .off
    public var spatialEnabled = false
    public var spatial = SpatialParameters()

    public init(isEnabled: Bool = false) { self.isEnabled = isEnabled }

    enum CodingKeys: String, CodingKey { case isEnabled, correction, crossfeed, spatialEnabled, spatial }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        correction = try? c.decodeIfPresent(CorrectionProfile.self, forKey: .correction)
        crossfeed = (try? c.decodeIfPresent(CrossfeedStrength.self, forKey: .crossfeed)) ?? .off
        spatialEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .spatialEnabled)) ?? false
        spatial = (try? c.decodeIfPresent(SpatialParameters.self, forKey: .spatial)) ?? SpatialParameters()
    }
}

public struct AppMixSettings: Codable, Equatable, Sendable {
    public var volume: Double = 1
    public var isMuted = false
    public var presetID: UUID?

    public init(volume: Double = 1, isMuted: Bool = false, presetID: UUID? = nil) {
        self.volume = volume; self.isMuted = isMuted; self.presetID = presetID
    }

    public var isDefault: Bool { volume == 1 && !isMuted && presetID == nil }
}

/// Persisted state. Every field has a default and decoding tolerates missing keys,
/// so settings written by older builds always load.
public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedPresetID: UUID = Preset.flat.id
    public var workingPreset: Preset?
    public var userPresets: [Preset] = []
    public var isEnabled = true
    public var volume = 1.0
    public var boostDB = 0.0
    public var balance = 0.0
    public var isMuted = false
    public var deviceProfiles: [String: DeviceProfile] = [:]
    public var hasCompletedOnboarding = false
    public var launchAtLogin = false
    public var appMix: [String: AppMixSettings] = [:]
    public var disabledPlugins: [String] = []
    public var headphones: [String: HeadphoneSettings] = [:]
    public var headphoneOverrides: [String: Bool] = [:]
    public var autoEnableHeadphones = true
    public var checkForUpdates = true
    public var lastUpdateCheck: Date?
    /// Not persisted: number of presets/profiles skipped while decoding because they were unreadable.
    public var droppedEntries = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case selectedPresetID, workingPreset, userPresets, isEnabled, volume, boostDB, balance, isMuted,
             deviceProfiles, hasCompletedOnboarding, launchAtLogin, appMix, disabledPlugins, headphones, headphoneOverrides,
             autoEnableHeadphones, checkForUpdates, lastUpdateCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        selectedPresetID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedPresetID)) ?? d.selectedPresetID
        workingPreset = try? c.decodeIfPresent(Preset.self, forKey: .workingPreset)
        // Decode element by element so one unreadable preset/profile doesn't wipe the rest.
        let presets = (try? c.decodeIfPresent([Lossy<Preset>].self, forKey: .userPresets)) ?? []
        userPresets = presets.compactMap(\.value)
        droppedEntries += presets.count - userPresets.count
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
        boostDB = (try? c.decodeIfPresent(Double.self, forKey: .boostDB)) ?? d.boostDB
        balance = (try? c.decodeIfPresent(Double.self, forKey: .balance)) ?? d.balance
        isMuted = (try? c.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? d.isMuted
        let profiles = (try? c.decodeIfPresent([String: Lossy<DeviceProfile>].self, forKey: .deviceProfiles)) ?? [:]
        deviceProfiles = profiles.compactMapValues(\.value)
        droppedEntries += profiles.count - deviceProfiles.count
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        let mix = (try? c.decodeIfPresent([String: Lossy<AppMixSettings>].self, forKey: .appMix)) ?? [:]
        appMix = mix.compactMapValues(\.value)
        disabledPlugins = (try? c.decodeIfPresent([String].self, forKey: .disabledPlugins)) ?? []
        let hp = (try? c.decodeIfPresent([String: Lossy<HeadphoneSettings>].self, forKey: .headphones)) ?? [:]
        headphones = hp.compactMapValues(\.value)
        headphoneOverrides = (try? c.decodeIfPresent([String: Bool].self, forKey: .headphoneOverrides)) ?? [:]
        autoEnableHeadphones = (try? c.decodeIfPresent(Bool.self, forKey: .autoEnableHeadphones)) ?? true
        checkForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? true
        lastUpdateCheck = try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        droppedEntries += mix.count - appMix.count
    }
}

/// Decodes a value if possible, otherwise records nil instead of failing the enclosing container.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
