import XCTest
@testable import EquinoxCore
import EquinoxDSP

@MainActor
final class ListeningModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-listening-\(UUID().uuidString)")
        audio = FakeAudio()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel() -> AppModel {
        AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem())
    }

    func testEditsReachAudioAndSaveRevertAndSwitchWithPreset() {
        let m = makeModel()
        XCTAssertFalse(m.listening.isEnabled)
        m.listening.isEnabled = true
        m.listening.targetDB = -24
        m.listening.harshness = 0.8
        XCTAssertTrue(m.isModified)
        XCTAssertEqual(audio.applied.last?.listening, m.listening)
        m.saveAs(name: "Comfort")
        let id = m.selectedPresetID
        XCTAssertFalse(m.isModified)
        XCTAssertEqual(m.selectedPreset.listening, m.listening)
        m.listening.bass = 0.6
        m.save()
        XCTAssertFalse(m.isModified)
        m.listening.bass = 0
        m.revert()
        XCTAssertEqual(m.listening.bass, 0.6)
        m.selectPreset(Preset.flat.id)
        XCTAssertFalse(m.listening.isEnabled)
        m.selectPreset(id)
        XCTAssertTrue(m.listening.isEnabled)
        XCTAssertEqual(m.listening.targetDB, -24)
    }

    func testUnsavedEditsSurviveRelaunch() {
        let m = makeModel()
        m.listening.isEnabled = true
        m.listening.targetDB = -26
        m.flushSave()
        let restored = makeModel()
        XCTAssertEqual(restored.listening, m.listening)
        XCTAssertTrue(restored.isModified)
        XCTAssertEqual(audio.applied.last?.listening, m.listening)
    }

    func testImportExportAndOldPresets() throws {
        var p = Preset(name: "Comfort", bands: [])
        p.listening.isEnabled = true; p.listening.bass = 0.4
        let imported = try Preset.importPresets(from: Preset.exportData([p]))
        XCTAssertEqual(imported.first?.listening, p.listening)
        let old = #"{"id":"00000000-0000-0000-0000-0000000000AA","name":"Old","preampDB":0,"bands":[]}"#
        XCTAssertFalse(try JSONDecoder().decode(Preset.self, from: Data(old.utf8)).listening.isEnabled)
        let partial = try JSONDecoder().decode(ListeningSettings.self, from: Data(#"{"isEnabled":true,"targetDB":400,"bass":-3}"#.utf8))
        XCTAssertTrue(partial.isEnabled)
        XCTAssertEqual(partial.targetDB, -14)
        XCTAssertEqual(partial.bass, 0)
    }

    func testInvalidParametersAreClampedBeforeAudioAndStorage() {
        let m = makeModel()
        var s = ListeningSettings()
        s.targetDB = .nan; s.bass = .infinity; s.harshness = 99; s.sibilance = -1; s.preserveDynamics = -3
        m.listening = s
        XCTAssertEqual(m.listening.targetDB, -20)
        XCTAssertEqual(m.listening.bass, 0)
        XCTAssertEqual(m.listening.harshness, 1)
        XCTAssertEqual(m.listening.sibilance, 0)
        XCTAssertEqual(m.listening.preserveDynamics, 0)
        m.flushSave()
        XCTAssertEqual(makeModel().listening, m.listening)
    }

    func testBypassKeepsSavedListeningPreference() {
        let m = makeModel()
        m.listening.isEnabled = true
        m.isEnabled = false
        XCTAssertTrue(m.listening.isEnabled)
        XCTAssertTrue(audio.applied.last!.isBypassed)
        m.isEnabled = true
        XCTAssertTrue(audio.applied.last!.listening.isEnabled)
    }
}
