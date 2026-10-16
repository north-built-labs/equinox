import AVFoundation
import EquinoxAudio
import EquinoxDSP
import Foundation
import Observation

public struct MixerStrip: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let isOthers: Bool
    public let isPlaying: Bool
    public let isDedicated: Bool
    public let volume: Double
    public let isMuted: Bool
    public let isSoloed: Bool
    public let presetID: UUID?
}

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
    public var isModified: Bool {
        working.bands != selectedPreset.bands || working.preampDB != selectedPreset.preampDB
            || working.effects.map(\.structure) != selectedPreset.effects.map(\.structure)
            || effectParametersEdited
    }
    /// Set when an effect parameter changes (sliders, plugin UI); cleared by save, Save As, select and revert.
    public private(set) var effectParametersEdited = false
    /// Called when the audio side installs a new effects chain (open editors must re-target). UI hook.
    @ObservationIgnored public var onEffectsChainChanged: (() -> Void)?

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

    // MARK: Mixer
    public private(set) var mixerStrips: [MixerStrip] = []
    public private(set) var soloKey: String?
    public var stripMeters: StripMeters { audio.stripMeters }
    public var activeStripKeys: [String] { audio.activeStripKeys }

    // MARK: Headphones
    public private(set) var headphoneSettings: [String: HeadphoneSettings] = [:]
    public private(set) var headphoneOverrides: [String: Bool] = [:]
    public var autoEnableHeadphones = true { didSet { if !restoring { scheduleSave() } } }
    public private(set) var autoEQResults: [AutoEQEntry] = []
    public private(set) var autoEQStatus: String?
    public private(set) var isApplyingAutoEQ = false

    // MARK: Updates
    public private(set) var availableUpdate: ReleaseInfo?
    public private(set) var updateStatus: String?
    public var checkForUpdatesAutomatically = true { didSet { if !restoring { scheduleSave() } } }
    @ObservationIgnored private var lastUpdateCheck: Date?
    @ObservationIgnored private var latestAutoEQQuery = ""
    public private(set) var isInstallingUpdate = false
    public let currentVersion: String
    nonisolated public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    @ObservationIgnored private let autoEQ: AutoEQProviding
    @ObservationIgnored private let updates: UpdateProviding

    // MARK: Effects
    public private(set) var availablePlugins: [AudioUnitID] = []
    public private(set) var disabledPluginKeys: Set<String> = []

    // MARK: Private
    @ObservationIgnored private let audio: AudioControlling
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private var deviceProfiles: [String: DeviceProfile] = [:]
    @ObservationIgnored private var usesSoftwareVolume = false
    @ObservationIgnored private var applyingExternalVolume = false
    @ObservationIgnored private var restoring = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let runningApps: RunningAppsProviding
    @ObservationIgnored private var appMix: [String: AppMixSettings] = [:]
    @ObservationIgnored private var appGroups: [AudioAppGroup] = []
    @ObservationIgnored private var dedicatedKeys: [String] = []
    @ObservationIgnored private var lastPushedEffects: [EffectSlot]?
    @ObservationIgnored private var reloadEffectsOnNextPush = false

    public init(audio: AudioControlling, store: Store = Store(), loginItem: LoginItemControlling = SystemLoginItem(),
                runningApps: RunningAppsProviding = WorkspaceRunningApps(), crashedPlugins: [AudioUnitID] = [],
                autoEQ: AutoEQProviding? = nil, updates: UpdateProviding? = nil,
                currentVersion: String = AppModel.bundleVersion) {
        self.audio = audio
        self.store = store
        self.loginItem = loginItem
        self.runningApps = runningApps
        self.autoEQ = autoEQ ?? AutoEQCatalog(cacheDirectory: store.directory)
        self.updates = updates ?? GitHubUpdates()
        self.currentVersion = currentVersion

        let loaded = store.load(AppSettings.self, from: Self.settingsFile)
        let s = loaded.value ?? AppSettings()
        if loaded.wasCorrupt { lastError = "Settings file was unreadable and has been reset." }
        if s.droppedEntries > 0 {
            store.backup(Self.settingsFile)
            lastError = "Some saved presets couldn't be read and were skipped. The original settings file was backed up."
        }
        if !crashedPlugins.isEmpty {
            disabledPluginKeys.formUnion(crashedPlugins.map(\.key))
            let names = crashedPlugins.map(\.name).joined(separator: ", ")
            lastError = "\(names) crashed while loading and was turned off. You can turn it back on in Effects."
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
        appMix = s.appMix
        disabledPluginKeys.formUnion(s.disabledPlugins)
        headphoneSettings = s.headphones
        headphoneOverrides = s.headphoneOverrides
        autoEnableHeadphones = s.autoEnableHeadphones
        checkForUpdatesAutomatically = s.checkForUpdates
        lastUpdateCheck = s.lastUpdateCheck
        restoring = false

        audio.onStatusChange = { [weak self] in self?.status = $0 }
        audio.onOutputDeviceChange = { [weak self] in self?.outputDeviceChanged($0) }
        audio.onHardwareVolumeChange = { [weak self] in self?.hardwareVolumeChanged($0) }
        audio.onProcessesChange = { [weak self] in self?.processesChanged($0) }
        audio.onEffectParametersChanged = { [weak self] in self?.effectParametersEdited = true }
        audio.onEffectsChainChanged = { [weak self] in self?.onEffectsChainChanged?() }
        devices = audio.outputDevices()
        availablePlugins = audio.installedPlugins()
        processesChanged(audio.audioProcesses())
    }

    // MARK: Lifecycle

    public func launch() {
        if hasCompletedOnboarding { audio.start() }
        Task { await checkForUpdates(userInitiated: false) }
    }

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
        effectParametersEdited = false
        reloadEffectsOnNextPush = true   // apply the preset's saved effect settings even if the structure matches
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
        captureEffectStates()
        userPresets[i].bands = working.bands
        userPresets[i].effects = working.effects
        userPresets[i].preampDB = working.preampDB
        working = userPresets[i]
        effectParametersEdited = false
        mixerChanged()
    }

    public func saveAs(name: String) {
        captureEffectStates()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(name: trimmed.isEmpty ? "Untitled" : trimmed, preampDB: working.preampDB,
                            bands: working.bands, isBuiltIn: false,
                            effects: working.effects.map { var e = $0; e.id = UUID(); return e })   // own slot identities
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
        for (key, mix) in appMix where mix.presetID == id {
            var m = mix; m.presetID = nil
            appMix[key] = m.isDefault ? nil : m
        }
        if selectedPresetID == id { selectPreset(Preset.flat.id) }
        mixerChanged()
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

    // MARK: Mixer

    public func setStripVolume(_ volume: Double, for key: String) {
        updateMix(key) { $0.volume = min(max(volume, 0), StripSettings.maxVolume) }
    }

    public func setStripMuted(_ muted: Bool, for key: String) { updateMix(key) { $0.isMuted = muted } }

    public func setStripPreset(_ id: UUID?, for key: String) { updateMix(key) { $0.presetID = id } }

    public func resetStrip(_ key: String) {
        appMix[key] = nil
        if soloKey == key { soloKey = nil }
        mixerChanged()
    }

    public func toggleSolo(_ key: String) {
        guard key != StripSettings.othersKey else { return }
        soloKey = soloKey == key ? nil : key
        mixerChanged()
    }

    private func updateMix(_ key: String, _ change: (inout AppMixSettings) -> Void) {
        var s = appMix[key] ?? AppMixSettings()
        change(&s)
        // Keep the entry (and the app's channel) even when values return to default, e.g. a fader dragged
        // through 100%; only Reset removes it. Avoids a session rebuild mid-drag.
        appMix[key] = s
        mixerChanged()
    }

    private func processesChanged(_ processes: [AudioProcessInfo]) {
        appGroups = AppGrouping.group(processes, runningApps: runningApps.runningApps(),
                                      excludingBundleIDs: [Bundle.main.bundleIdentifier ?? "com.northbuiltlabs.equinox", "com.northbuiltlabs.equinox"],
                                      excludingPIDs: [getpid()])
        if let solo = soloKey, !appGroups.contains(where: { $0.key == solo }) { soloKey = nil }
        mixerChanged()
    }

    /// Recomputes strips and dedicated taps, then pushes audio settings.
    private func mixerChanged() {
        // Channel priority when over the cap: the soloed app, then apps that are playing, then by key.
        let dedicatedGroups = appGroups
            .filter { appMix[$0.key] != nil || soloKey == $0.key }
            .sorted { (rank($0), $0.key) < (rank($1), $1.key) }
            .prefix(MixBus.maxStrips - 1)
            .sorted { $0.key < $1.key }
        dedicatedKeys = dedicatedGroups.map(\.key)
        audio.setDedicatedStrips(dedicatedGroups.map { DedicatedStrip(key: $0.key, processes: $0.processObjects) })

        let others = appMix[StripSettings.othersKey] ?? AppMixSettings()
        var strips = [MixerStrip(id: StripSettings.othersKey, name: "Other Apps", bundleID: nil, isOthers: true,
                                 isPlaying: appGroups.contains { $0.isPlaying && !dedicatedKeys.contains($0.key) },
                                 isDedicated: true, volume: others.volume, isMuted: others.isMuted,
                                 isSoloed: false, presetID: others.presetID)]
        let apps = appGroups.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        strips += apps.map { g in
            let s = appMix[g.key] ?? AppMixSettings()
            return MixerStrip(id: g.key, name: g.name, bundleID: g.bundleID, isOthers: false, isPlaying: g.isPlaying,
                              isDedicated: dedicatedKeys.contains(g.key), volume: s.volume, isMuted: s.isMuted,
                              isSoloed: soloKey == g.key, presetID: s.presetID)
        }
        mixerStrips = strips
        push()
    }

    private func rank(_ g: AudioAppGroup) -> Int { g.key == soloKey ? 0 : (g.isPlaying ? 1 : 2) }

    private func stripSettings() -> [StripSettings] {
        ([StripSettings.othersKey] + dedicatedKeys).map { key in
            let s = appMix[key] ?? AppMixSettings()
            let preset = s.presetID.flatMap { id in presets.first { $0.id == id } }
            let soloMuted = soloKey != nil && soloKey != key
            return StripSettings(key: key, volume: s.volume, isMuted: s.isMuted || soloMuted,
                                 preampDB: preset?.preampDB ?? 0, bands: preset?.bands ?? [])
        }
    }

    // MARK: Effects

    @discardableResult
    public func addEffect(_ kind: EffectKind) -> UUID {
        let slot = EffectSlot(kind: kind)
        working.effects.append(slot)
        push()
        return slot.id
    }

    public func removeEffect(_ id: UUID) {
        working.effects.removeAll { $0.id == id }
        push()
    }

    public func moveEffect(_ id: UUID, by offset: Int) {
        guard let i = working.effects.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), working.effects.count - 1)
        guard i != j else { return }
        working.effects.swapAt(i, j)
        push()
    }

    public func setEffectEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = working.effects.firstIndex(where: { $0.id == id }) else { return }
        working.effects[i].isEnabled = enabled
        push()
    }

    public func isDisabledByCrash(_ slot: EffectSlot) -> Bool {
        if case .audioUnit(let id) = slot.kind { return disabledPluginKeys.contains(id.key) }
        return false
    }

    public func reenablePlugin(_ key: String) {
        disabledPluginKeys.remove(key)
        push()
    }

    public func effectUnit(for id: UUID) -> AUAudioUnit? { audio.effectUnit(for: id) }

    public func refreshPlugins() { availablePlugins = audio.installedPlugins() }

    /// Copies live plugin parameter state into the working preset's slots.
    private func captureEffectStates() {
        let states = audio.captureEffectStates()
        guard !states.isEmpty else { return }
        for i in working.effects.indices {
            if let state = states[working.effects[i].id] { working.effects[i].state = state }
        }
    }

    // MARK: Headphones & updates

    /// Overrides are stored per detected state, so overriding the jack never affects the speakers of the
    /// same (shared-UID) built-in output, and vice versa.
    private var overrideKey: String? { currentDevice.map { $0.uid + ($0.isHeadphones ? "#detected-headphones" : "#detected-speakers") } }

    public var isHeadphoneOutput: Bool {
        guard let d = currentDevice else { return false }
        return overrideKey.flatMap { headphoneOverrides[$0] } ?? d.isHeadphones
    }

    /// Settings key: the jack and the speakers of the built-in output share a UID, so they are kept apart.
    private var headphoneKey: String? {
        currentDevice.map { $0.uid + (isHeadphoneOutput ? "#headphones" : "#speakers") }
    }

    public var headphones: HeadphoneSettings { headphoneKey.flatMap { headphoneSettings[$0] } ?? HeadphoneSettings() }

    public func updateHeadphones(_ change: (inout HeadphoneSettings) -> Void) {
        guard let key = headphoneKey else { return }
        var s = headphoneSettings[key] ?? HeadphoneSettings()
        change(&s)
        s.spatial.width = min(max(s.spatial.width, SpatialParameters.widthRange.lowerBound), SpatialParameters.widthRange.upperBound)
        s.spatial.room = min(max(s.spatial.room, 0), 1)
        headphoneSettings[key] = s
        push()
    }

    public func setHeadphoneOverride(_ value: Bool?) {
        guard let device = currentDevice, let key = overrideKey else { return }
        headphoneOverrides[key] = value == device.isHeadphones ? nil : value
        ensureHeadphoneDefaults()
        push()
    }

    private func ensureHeadphoneDefaults() {
        guard let key = headphoneKey, headphoneSettings[key] == nil, isHeadphoneOutput, autoEnableHeadphones else { return }
        headphoneSettings[key] = HeadphoneSettings(isEnabled: true)
    }

    public func searchAutoEQ(_ query: String) async {
        latestAutoEQQuery = query
        autoEQStatus = nil
        do {
            let entries = try await autoEQ.entries()
            guard query == latestAutoEQQuery else { return }   // a newer search superseded this one
            autoEQResults = AutoEQIndex.search(entries, query: query)
            if autoEQResults.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty { autoEQStatus = "No matches." }
        } catch {
            guard query == latestAutoEQQuery else { return }
            autoEQResults = []
            autoEQStatus = "Couldn't load the AutoEq database. Check your connection and try again."
        }
    }

    public func applyAutoEQ(_ entry: AutoEQEntry) async {
        isApplyingAutoEQ = true
        defer { isApplyingAutoEQ = false }
        do {
            let profile = try await autoEQ.profile(for: entry)
            updateHeadphones { $0.correction = profile; $0.isEnabled = true }
            autoEQStatus = nil
        } catch {
            autoEQStatus = "Couldn't download that profile."
        }
    }

    public func importCorrection(from data: Data, name: String) throws {
        guard data.count < 200_000, let text = String(data: data, encoding: .utf8) else { throw ParametricEQText.ParseError.noFilters }
        let profile = try ParametricEQText.parse(text, name: name, source: "Imported")
        updateHeadphones { $0.correction = profile; $0.isEnabled = true }
    }

    public func removeCorrection() { updateHeadphones { $0.correction = nil } }

    public func checkForUpdates(userInitiated: Bool) async {
        if !userInitiated {
            guard checkForUpdatesAutomatically else { return }
            if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        }
        do {
            let release = try await updates.latestRelease()
            lastUpdateCheck = Date()
            if UpdateChecker.isNewer(release.version, than: currentVersion) {
                availableUpdate = release
                updateStatus = "Equinox \(release.version) is available."
            } else {
                availableUpdate = nil
                updateStatus = "Equinox is up to date."
            }
            scheduleSave()
        } catch {
            if userInitiated { updateStatus = "Couldn't check for updates." }
        }
    }

    /// Downloads, verifies and hands off the available update. Returns true when the caller should quit
    /// so the swap script can replace the app; otherwise `updateStatus` explains what went wrong.
    public func installUpdate(currentApp: URL = Bundle.main.bundleURL) async -> Bool {
        guard let release = availableUpdate, !isInstallingUpdate else { return false }
        guard UpdateInstaller.canReplace(appAt: currentApp) else {
            updateStatus = "Equinox can't update itself from where it is. Move it to your Applications folder, or download \(release.version) from GitHub."
            return false
        }
        isInstallingUpdate = true
        defer { isInstallingUpdate = false }
        updateStatus = "Downloading Equinox \(release.version)…"
        do {
            let staged = try await updates.stage(release)
            try updates.verify(appAt: staged, newerThan: currentVersion)
            try updates.launchReplacement(current: currentApp, replacement: staged)
            flushSave()
            return true
        } catch {
            updateStatus = Self.message(for: error)
            return false
        }
    }

    static func message(for error: Error) -> String {
        switch error as? UpdateError {
        case .unsigned?, .badSignature?: "The download's signature didn't check out, so it wasn't installed."
        case .notEquinox?: "The download wasn't Equinox, so it wasn't installed."
        case .notNewer?: "The download isn't newer than this version."
        case .badArchive?: "The download was damaged. Try again."
        default: "The update couldn't be downloaded. Check your connection, or get it from GitHub."
        }
    }

    public func moveEffect(_ id: UUID, to index: Int) {
        guard let i = working.effects.firstIndex(where: { $0.id == id }) else { return }
        let slot = working.effects.remove(at: i)
        working.effects.insert(slot, at: min(max(index, 0), working.effects.count))
        push()
    }

    // MARK: Devices

    public func refreshDevices() { devices = audio.outputDevices() }

    public func selectOutputDevice(_ device: AudioDevice) { audio.selectOutputDevice(device) }

    private func outputDeviceChanged(_ device: AudioDevice) {
        refreshDevices()
        // Volume mode follows the device, not the last slider write (a device without hardware
        // volume must keep getting the saved software volume after relaunch or a device switch).
        usesSoftwareVolume = !device.hasHardwareVolume
        guard device.uid != currentDevice?.uid else {
            currentDevice = device          // e.g. built-in output switched between speakers and the jack
            ensureHeadphoneDefaults()
            push()
            return
        }
        currentDevice = device
        ensureHeadphoneDefaults()
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
        s.strips = stripSettings()
        let hp = headphones
        let layer = hp.isEnabled
        s.correction = layer ? hp.correction : nil
        s.crossfeed = layer && !hp.spatialEnabled ? hp.crossfeed : .off
        s.spatialEnabled = layer && hp.spatialEnabled
        audio.apply(s)
        audio.setSpatial(s.spatialEnabled && isEnabled ? hp.spatial : nil)
        let effects = working.effects.filter { !isDisabledByCrash($0) }
        if reloadEffectsOnNextPush || effects.map(\.structure) != lastPushedEffects?.map(\.structure) {
            audio.setEffects(effects, reload: reloadEffectsOnNextPush)
            lastPushedEffects = effects
            reloadEffectsOnNextPush = false
        }
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
        captureEffectStates()
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
        s.appMix = appMix
        s.disabledPlugins = disabledPluginKeys.sorted()
        s.headphones = headphoneSettings
        s.headphoneOverrides = headphoneOverrides
        s.autoEnableHeadphones = autoEnableHeadphones
        s.checkForUpdates = checkForUpdatesAutomatically
        s.lastUpdateCheck = lastUpdateCheck
        do { try store.save(s, to: Self.settingsFile) }
        catch { lastError = "Could not save settings: \(error.localizedDescription)" }
    }
}
