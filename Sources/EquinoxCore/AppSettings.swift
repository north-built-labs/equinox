import Foundation

public struct DeviceProfile: Codable, Equatable, Sendable {
    public var presetID: UUID
    public var isEnabled: Bool
    public init(presetID: UUID, isEnabled: Bool) { self.presetID = presetID; self.isEnabled = isEnabled }
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

    public init() {}

    enum CodingKeys: String, CodingKey {
        case selectedPresetID, workingPreset, userPresets, isEnabled, volume, boostDB, balance, isMuted,
             deviceProfiles, hasCompletedOnboarding, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        selectedPresetID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedPresetID)) ?? d.selectedPresetID
        workingPreset = try? c.decodeIfPresent(Preset.self, forKey: .workingPreset)
        userPresets = (try? c.decodeIfPresent([Preset].self, forKey: .userPresets)) ?? d.userPresets
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
        boostDB = (try? c.decodeIfPresent(Double.self, forKey: .boostDB)) ?? d.boostDB
        balance = (try? c.decodeIfPresent(Double.self, forKey: .balance)) ?? d.balance
        isMuted = (try? c.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? d.isMuted
        deviceProfiles = (try? c.decodeIfPresent([String: DeviceProfile].self, forKey: .deviceProfiles)) ?? d.deviceProfiles
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
    }
}
