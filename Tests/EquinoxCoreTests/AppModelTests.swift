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
    var applied: [DSPSettings] = []
    var started = 0
    var hasHardwareVolume = true
    var hardwareVolume: Float = -1
    var devices = [AudioDevice(id: 1, uid: "speakers", name: "Speakers", transportType: 0),
                   AudioDevice(id: 2, uid: "headphones", name: "Headphones", transportType: 0)]

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
}
