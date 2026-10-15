import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

@MainActor
final class EffectsAppModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!
    let crashy = AudioUnitID(type: 1, subType: 2, manufacturer: 3, name: "Crashy", manufacturerName: "X")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-fx-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel(crashed: AudioUnitID? = nil) -> AppModel {
        AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem(), crashedPlugin: crashed)
    }

    func testAddEffectPushesChainAndMarksModified() {
        let m = makeModel()
        let id = m.addEffect(.builtIn(.reverb))
        XCTAssertEqual(audio.effects.map(\.id), [id])
        XCTAssertTrue(m.isModified)
    }

    func testMoveToggleRemove() {
        let m = makeModel()
        let reverb = m.addEffect(.builtIn(.reverb)), delay = m.addEffect(.builtIn(.delay))
        m.moveEffect(delay, by: -1)
        XCTAssertEqual(audio.effects.map(\.id), [delay, reverb])
        m.moveEffect(delay, by: -1)                 // already first: no-op
        XCTAssertEqual(audio.effects.map(\.id), [delay, reverb])
        m.setEffectEnabled(reverb, false)
        XCTAssertEqual(audio.effects.last?.isEnabled, false)
        m.removeEffect(delay)
        XCTAssertEqual(audio.effects.map(\.id), [reverb])
    }

    func testSaveCapturesLiveStates() {
        let m = makeModel()
        let id = m.addEffect(.builtIn(.reverb))
        audio.effectStates = [id: Data([1, 2, 3])]
        m.saveAs(name: "FX")
        XCTAssertEqual(m.selectedPreset.effects.first?.state, Data([1, 2, 3]))
        XCTAssertFalse(m.isModified)
    }

    func testSelectingPresetSwapsEffects() {
        let m = makeModel()
        _ = m.addEffect(.builtIn(.delay))
        m.saveAs(name: "FX")
        m.selectPreset(Preset.flat.id)
        XCTAssertTrue(audio.effects.isEmpty)
        m.selectPreset(m.userPresets[0].id)
        XCTAssertEqual(audio.effects.count, 1)
    }

    func testCrashedPluginIsDisabledAndFiltered() {
        let m = makeModel(crashed: crashy)
        XCTAssertNotNil(m.lastError)
        let id = m.addEffect(.audioUnit(crashy))
        _ = m.addEffect(.builtIn(.limiter))
        XCTAssertEqual(audio.effects.count, 1)
        XCTAssertTrue(m.isDisabledByCrash(m.working.effects.first { $0.id == id }!))
        m.reenablePlugin(crashy.key)
        XCTAssertEqual(audio.effects.count, 2)
    }

    func testDisabledPluginsPersist() {
        _ = makeModel(crashed: crashy).flushSave()
        let m2 = makeModel()
        XCTAssertTrue(m2.disabledPluginKeys.contains(crashy.key))
    }
}
