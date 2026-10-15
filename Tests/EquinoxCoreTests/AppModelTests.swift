import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

@MainActor
final class FakeAudio: AudioControlling {
    var onStatusChange: ((AudioStatus) -> Void)?
    var onOutputDeviceChange: ((AudioDevice) -> Void)?
    var onHardwareVolumeChange: ((Float) -> Void)?
    let analysis = AnalysisTap()
    var onProcessesChange: (([AudioProcessInfo]) -> Void)?
    let stripMeters = StripMeters()
    var activeStripKeys: [String] = [""]
    var processes: [AudioProcessInfo] = []
    var dedicated: [DedicatedStrip] = []
    func audioProcesses() -> [AudioProcessInfo] { processes }
    func setDedicatedStrips(_ strips: [DedicatedStrip]) { dedicated = strips }
    var applied: [DSPSettings] = []
    var started = 0
    var hasHardwareVolume = true
    var hardwareVolume: Float = -1
    var devices = [AudioDevice(id: 1, uid: "speakers", name: "Speakers", transportType: 0),
                   AudioDevice(id: 2, uid: "headphones", name: "Headphones", transportType: 0),
                   AudioDevice(id: 3, uid: "hdmi", name: "HDMI", transportType: 0, hasHardwareVolume: false)]

    func start() { started += 1 }
    func stop() {}
    func restart() {}
    func apply(_ settings: DSPSettings) { applied.append(settings) }
    func outputDevices() -> [AudioDevice] { devices }
    func selectOutputDevice(_ device: AudioDevice) { onOutputDeviceChange?(device) }
    func setHardwareVolume(_ volume: Float) -> Bool {
        guard hasHardwareVolume else { return false }
        hardwareVolume = volume; return true
    }
}

final class FakeLoginItem: LoginItemControlling {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
final class AppModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-model-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel() -> AppModel { AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem()) }

    func testInitPushesSelectedPreset() {
        _ = makeModel()
        XCTAssertEqual(audio.applied.last?.bands, Preset.flat.bands)
    }

    func testLaunchStartsAudioOnlyAfterOnboarding() {
        let m = makeModel()
        m.launch(); XCTAssertEqual(audio.started, 0)
        m.completeOnboarding(); XCTAssertEqual(audio.started, 1)
        XCTAssertTrue(m.hasCompletedOnboarding)
    }

    func testSelectingPresetAppliesBandsAndPreamp() {
        let m = makeModel()
        let bass = Preset.builtIns[1]
        m.selectPreset(bass.id)
        XCTAssertEqual(m.working.bands, bass.bands)
        XCTAssertEqual(audio.applied.last?.bands, bass.bands)
        XCTAssertEqual(audio.applied.last?.preampDB, bass.preampDB)
        XCTAssertFalse(m.isModified)
    }

    func testEditingMarksModifiedAndSaveAsCreatesUserPreset() {
        let m = makeModel()
        let id = m.working.bands[0].id
        m.updateBand(id) { $0.gainDB = 5 }
        XCTAssertTrue(m.isModified)
        XCTAssertEqual(audio.applied.last?.bands[0].gainDB, 5)
        m.saveAs(name: "Mine")
        XCTAssertEqual(m.selectedPreset.name, "Mine")
        XCTAssertFalse(m.selectedPreset.isBuiltIn)
        XCTAssertFalse(m.isModified)
        XCTAssertEqual(m.userPresets.count, 1)
    }

    func testRevertRestoresSavedBands() {
        let m = makeModel()
        m.updateBand(m.working.bands[0].id) { $0.gainDB = 9 }
        m.revert()
        XCTAssertEqual(m.working.bands, Preset.flat.bands)
    }

    func testBandEditsAreClampedAndCapped() {
        let m = makeModel()
        m.updateBand(m.working.bands[0].id) { $0.gainDB = 100; $0.frequency = 1 }
        XCTAssertEqual(m.working.bands[0].gainDB, 24); XCTAssertEqual(m.working.bands[0].frequency, 20)
        for _ in 0..<40 { _ = m.addBand(frequency: 1000, gainDB: 0) }
        XCTAssertEqual(m.working.bands.count, BiquadBank.maxSections)
        XCTAssertNil(m.addBand(frequency: 1000, gainDB: 0))
    }

    func testDisablingBypassesAudio() {
        let m = makeModel()
        m.isEnabled = false
        XCTAssertEqual(audio.applied.last?.isBypassed, true)
    }

    func testVolumeUsesHardwareWhenAvailableElseSoftware() {
        let m = makeModel()
        m.volume = 0.4
        XCTAssertEqual(audio.hardwareVolume, 0.4, accuracy: 1e-6)
        XCTAssertEqual(audio.applied.last?.softwareVolume, 1)
        audio.hasHardwareVolume = false
        m.volume = 0.3
        XCTAssertEqual(audio.applied.last?.softwareVolume ?? 0, 0.3, accuracy: 1e-9)
    }

    func testExternalHardwareVolumeChangeUpdatesModelWithoutEcho() {
        let m = makeModel()
        audio.hardwareVolume = -1
        audio.onHardwareVolumeChange?(0.25)
        XCTAssertEqual(m.volume, 0.25, accuracy: 1e-6)
        XCTAssertEqual(audio.hardwareVolume, -1)   // did not write back
    }

    func testDeviceProfilesAreRememberedPerDevice() {
        let m = makeModel()
        audio.onOutputDeviceChange?(audio.devices[0])
        m.selectPreset(Preset.builtIns[1].id)
        audio.onOutputDeviceChange?(audio.devices[1])
        m.selectPreset(Preset.builtIns[3].id)
        audio.onOutputDeviceChange?(audio.devices[0])
        XCTAssertEqual(m.selectedPreset.id, Preset.builtIns[1].id)
        audio.onOutputDeviceChange?(audio.devices[1])
        XCTAssertEqual(m.selectedPreset.id, Preset.builtIns[3].id)
    }

    func testStatePersistsAcrossInstances() {
        let m = makeModel()
        m.saveAs(name: "Keep")
        m.boostDB = 6
        m.flushSave()
        let m2 = makeModel()
        XCTAssertEqual(m2.selectedPreset.name, "Keep")
        XCTAssertEqual(m2.boostDB, 6)
    }

    func testImportGarbageThrowsAndLeavesStateUnchanged() {
        let m = makeModel()
        XCTAssertThrowsError(try m.importPresets(from: Data("garbage".utf8)))
        XCTAssertTrue(m.userPresets.isEmpty)
        XCTAssertEqual(m.selectedPreset.id, Preset.flat.id)
    }

    func testDeletingSelectedUserPresetFallsBackToFlat() {
        let m = makeModel()
        m.saveAs(name: "Temp")
        m.deletePreset(m.selectedPreset.id)
        XCTAssertEqual(m.selectedPreset.id, Preset.flat.id)
        XCTAssertTrue(m.userPresets.isEmpty)
    }

    // MARK: Review fixes

    func testSoftwareVolumeIsAppliedAfterRelaunchOnDeviceWithoutHardwareVolume() {
        let m = makeModel()
        audio.hasHardwareVolume = false
        audio.onOutputDeviceChange?(audio.devices[2])
        m.volume = 0.1
        m.flushSave()
        let relaunched = makeModel()
        audio.onOutputDeviceChange?(audio.devices[2])
        XCTAssertEqual(audio.applied.last?.softwareVolume ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(relaunched.volume, 0.1, accuracy: 1e-9)
    }

    func testSwitchingToDeviceWithoutHardwareVolumeAppliesSoftwareVolume() {
        let m = makeModel()
        audio.onOutputDeviceChange?(audio.devices[0])
        m.volume = 0.4
        XCTAssertEqual(audio.applied.last?.softwareVolume, 1)
        audio.onOutputDeviceChange?(audio.devices[2])
        XCTAssertEqual(audio.applied.last?.softwareVolume ?? -1, 0.4, accuracy: 1e-9)
        audio.onOutputDeviceChange?(audio.devices[0])
        XCTAssertEqual(audio.applied.last?.softwareVolume, 1)
    }

    func testUnsavedEditsSurviveRelaunch() {
        let m = makeModel()
        audio.onOutputDeviceChange?(audio.devices[0])
        m.updateBand(m.working.bands[0].id) { $0.gainDB = 9 }
        m.flushSave()
        let m2 = makeModel()
        audio.onOutputDeviceChange?(audio.devices[0])
        XCTAssertEqual(m2.working.bands[0].gainDB, 9)
        XCTAssertTrue(m2.isModified)
    }

    func testDeviceSwitchWithSamePresetKeepsEdits() {
        let m = makeModel()
        audio.onOutputDeviceChange?(audio.devices[0])
        audio.onOutputDeviceChange?(audio.devices[1])   // headphones profile: same preset (Flat)
        m.updateBand(m.working.bands[0].id) { $0.gainDB = 7 }
        audio.onOutputDeviceChange?(audio.devices[0])
        XCTAssertEqual(m.working.bands[0].gainDB, 7)
    }

    func testOneUnreadablePresetIsDroppedAndFileBackedUp() throws {
        let good = Preset(name: "Good", bands: [EQBand(frequency: 100, gainDB: 3)])
        var json = String(data: try JSONEncoder().encode(AppSettings()), encoding: .utf8)!
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let badJSON = goodJSON.replacingOccurrences(of: "\"peak\"", with: "\"bogus\"").replacingOccurrences(of: "Good", with: "Bad")
        json = json.replacingOccurrences(of: "\"userPresets\":[]", with: "\"userPresets\":[\(goodJSON),\(badJSON)]")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("settings.json"))

        let m = makeModel()
        XCTAssertEqual(m.userPresets.map(\.name), ["Good"])
        XCTAssertNotNil(m.lastError)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("settings.json.corrupt-") })
        XCTAssertTrue(files.contains("settings.json"))
    }
}
