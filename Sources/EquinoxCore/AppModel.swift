import EquinoxAudio
import EquinoxDSP
import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    private static let settingsFile = "settings.json"

    // MARK: Audio state
    public private(set) var status: AudioStatus = .stopped
    public private(set) var devices: [AudioDevice] = []
    public private(set) var currentDevice: AudioDevice?
    public var analysis: AnalysisTap { audio.analysis }
    public var sampleRate: Double { if case .running(_, let rate) = status { rate } else { 48_000 } }

    // MARK: Presets
    public private(set) var userPresets: [Preset] = []
    public private(set) var selectedPresetID: UUID = Preset.flat.id
    /// The edited copy that is audible right now.
    public private(set) var working: Preset = Preset.flat
    public var presets: [Preset] { Preset.builtIns + userPresets }
    public var selectedPreset: Preset { presets.first { $0.id == selectedPresetID } ?? Preset.flat }
    public var isModified: Bool { working.bands != selectedPreset.bands || working.preampDB != selectedPreset.preampDB }

    // MARK: Controls
    public var isEnabled = true { didSet { recordDeviceProfile(); push() } }
    public var volume = 1.0 { didSet { volumeChanged() } }
    public var boostDB = 0.0 { didSet { push() } }
    public var balance = 0.0 { didSet { push() } }
    public var isMuted = false { didSet { push() } }
    public var preampDB: Double {
        get { working.preampDB }
        set { working.preampDB = min(max(newValue, -24), 24); push() }
    }
    public private(set) var hasCompletedOnboarding = false
    public var launchAtLogin = false { didSet { applyLaunchAtLogin(oldValue) } }
    public private(set) var lastError: String?

    // MARK: Private
    @ObservationIgnored private let audio: AudioControlling
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private var deviceProfiles: [String: DeviceProfile] = [:]
    @ObservationIgnored private var usesSoftwareVolume = false
    @ObservationIgnored private var applyingExternalVolume = false
    @ObservationIgnored private var restoring = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(audio: AudioControlling, store: Store = Store(), loginItem: LoginItemControlling = SystemLoginItem()) {
        self.audio = audio
        self.store = store
        self.loginItem = loginItem

        let loaded = store.load(AppSettings.self, from: Self.settingsFile)
        let s = loaded.value ?? AppSettings()
        if loaded.wasCorrupt { lastError = "Settings file was unreadable and has been reset." }
        if s.droppedEntries > 0 {
            store.backup(Self.settingsFile)
            lastError = "Some saved presets couldn't be read and were skipped. The original settings file was backed up."
        }
        userPresets = s.userPresets
        selectedPresetID = presets.contains { $0.id == s.selectedPresetID } ? s.selectedPresetID : Preset.flat.id
        working = s.workingPreset.flatMap { $0.id == selectedPresetID ? $0 : nil } ?? selectedPreset
        isEnabled = s.isEnabled
        volume = min(max(s.volume, 0), 1)
        boostDB = min(max(s.boostDB, 0), DSPSettings.maxBoostDB)
        balance = min(max(s.balance, -1), 1)
        isMuted = s.isMuted
        deviceProfiles = s.deviceProfiles
        hasCompletedOnboarding = s.hasCompletedOnboarding
        launchAtLogin = s.launchAtLogin
        restoring = false

        audio.onStatusChange = { [weak self] in self?.status = $0 }
        audio.onOutputDeviceChange = { [weak self] in self?.outputDeviceChanged($0) }
        audio.onHardwareVolumeChange = { [weak self] in self?.hardwareVolumeChanged($0) }
        devices = audio.outputDevices()
        push()
    }

    // MARK: Lifecycle

    public func launch() { if hasCompletedOnboarding { audio.start() } }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        audio.start()
        scheduleSave()
    }

    public func restartAudio() { audio.restart() }

    // MARK: Presets

    public func selectPreset(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        selectedPresetID = id
        working = preset
        recordDeviceProfile()
        push()
    }

    public func updateBand(_ id: UUID, _ change: (inout EQBand) -> Void) {
        guard let i = working.bands.firstIndex(where: { $0.id == id }) else { return }
        var band = working.bands[i]
        change(&band)
        working.bands[i] = band.clamped()
        push()
    }

    /// Returns nil when the band limit is reached.
    @discardableResult
    public func addBand(frequency: Double, gainDB: Double) -> UUID? {
        guard working.bands.count < BiquadBank.maxSections else { return nil }
        let band = EQBand(type: .peak, frequency: frequency, gainDB: gainDB, q: 1).clamped()
        working.bands.append(band)
        working.bands.sort { $0.frequency < $1.frequency }
        push()
        return band.id
    }

    public func removeBand(_ id: UUID) {
        working.bands.removeAll { $0.id == id }
        push()
    }

    /// Saves edits into the selected user preset (built-ins are read-only; use saveAs).
    public func save() {
        guard let i = userPresets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        userPresets[i].bands = working.bands
        userPresets[i].preampDB = working.preampDB
        working = userPresets[i]
        push()
    }

    public func saveAs(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(name: trimmed.isEmpty ? "Untitled" : trimmed, preampDB: working.preampDB,
                            bands: working.bands, isBuiltIn: false)
        userPresets.append(preset)
        selectPreset(preset.id)
    }

    public func revert() { selectPreset(selectedPresetID) }

    public func deletePreset(_ id: UUID) {
        guard userPresets.contains(where: { $0.id == id }) else { return }
        userPresets.removeAll { $0.id == id }
        for (uid, profile) in deviceProfiles where profile.presetID == id {
            deviceProfiles[uid]?.presetID = Preset.flat.id
        }
        if selectedPresetID == id { selectPreset(Preset.flat.id) } else { scheduleSave() }
    }

    public func renamePreset(_ id: UUID, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets[i].name = trimmed
        if selectedPresetID == id { working.name = trimmed }
        scheduleSave()
    }

    public func importPresets(from data: Data) throws {
        let imported = try Preset.importPresets(from: data)
        userPresets.append(contentsOf: imported)
        selectPreset(imported[0].id)
    }

    public func exportData(for ids: [UUID]) throws -> Data {
        try Preset.exportData(presets.filter { ids.contains($0.id) })
    }

    // MARK: Devices

    public func refreshDevices() { devices = audio.outputDevices() }

    public func selectOutputDevice(_ device: AudioDevice) { audio.selectOutputDevice(device) }

    private func outputDeviceChanged(_ device: AudioDevice) {
        refreshDevices()
        // Volume mode follows the device, not the last slider write (a device without hardware
        // volume must keep getting the saved software volume after relaunch or a device switch).
        usesSoftwareVolume = !device.hasHardwareVolume
        guard device.uid != currentDevice?.uid else { push(); return }
        currentDevice = device
        if let profile = deviceProfiles[device.uid] {
            // Only switch presets when the device remembers a different one; otherwise keep unsaved edits.
            if profile.presetID != selectedPresetID, presets.contains(where: { $0.id == profile.presetID }) {
                selectedPresetID = profile.presetID
                working = selectedPreset
            }
            isEnabled = profile.isEnabled
        } else {
            recordDeviceProfile()
        }
        push()
    }

    private func recordDeviceProfile() {
        guard !restoring, let uid = currentDevice?.uid else { return }
        deviceProfiles[uid] = DeviceProfile(presetID: selectedPresetID, isEnabled: isEnabled)
    }

    // MARK: Volume

    private func volumeChanged() {
        guard !restoring else { return }
        if !applyingExternalVolume {
            usesSoftwareVolume = !audio.setHardwareVolume(Float(volume))
        }
        push()
    }

    private func hardwareVolumeChanged(_ value: Float) {
        usesSoftwareVolume = false
        applyingExternalVolume = true
        volume = Double(value)
        applyingExternalVolume = false
    }

    // MARK: Login item

    private func applyLaunchAtLogin(_ oldValue: Bool) {
        guard !restoring, launchAtLogin != oldValue else { return }
        do { try loginItem.setEnabled(launchAtLogin) }
        catch { lastError = "Could not change Launch at Login: \(error.localizedDescription)" }
        scheduleSave()
    }

    // MARK: Push & persist

    private func push() {
        guard !restoring else { return }
        var s = DSPSettings()
        s.isBypassed = !isEnabled
        s.preampDB = working.preampDB
        s.bands = working.bands
        s.softwareVolume = usesSoftwareVolume ? volume : 1
        s.boostDB = boostDB
        s.balance = balance
        s.isMuted = isMuted
        audio.apply(s)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    public func flushSave() {
        saveTask?.cancel()
        var s = AppSettings()
        s.selectedPresetID = selectedPresetID
        s.workingPreset = working
        s.userPresets = userPresets
        s.isEnabled = isEnabled
        s.volume = volume
        s.boostDB = boostDB
        s.balance = balance
        s.isMuted = isMuted
        s.deviceProfiles = deviceProfiles
        s.hasCompletedOnboarding = hasCompletedOnboarding
        s.launchAtLogin = launchAtLogin
        do { try store.save(s, to: Self.settingsFile) }
        catch { lastError = "Could not save settings: \(error.localizedDescription)" }
    }
}
