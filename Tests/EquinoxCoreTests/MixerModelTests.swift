import XCTest
@testable import EquinoxCore
import CoreAudio
import EquinoxAudio
import EquinoxDSP

final class FakeRunningApps: RunningAppsProviding {
    func runningApps() -> [RunningAppInfo] {
        [RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome"),
         RunningAppInfo(bundleID: "com.spotify.client", name: "Spotify")]
    }
}

@MainActor
final class MixerModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-mixer-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    let chrome = [AudioProcessInfo(objectID: 11, pid: 11, bundleID: "com.google.Chrome", executableName: "Chrome", isRunningOutput: false),
                  AudioProcessInfo(objectID: 12, pid: 12, bundleID: "com.google.Chrome.helper", executableName: "Helper", isRunningOutput: true)]
    let spotify = AudioProcessInfo(objectID: 21, pid: 21, bundleID: "com.spotify.client", executableName: "Spotify", isRunningOutput: true)

    func makeModel() -> AppModel {
        let m = AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem(), runningApps: FakeRunningApps())
        audio.onProcessesChange?(chrome + [spotify])
        return m
    }

    func strip(_ key: String) -> StripSettings? { audio.applied.last?.strips.first { $0.key == key } }

    func testStripsListOthersFirstThenApps() {
        let m = makeModel()
        XCTAssertEqual(m.mixerStrips.map(\.name), ["Other Apps", "Google Chrome", "Spotify"])
        XCTAssertTrue(m.mixerStrips[0].isOthers)
        XCTAssertTrue(audio.dedicated.isEmpty)
    }

    func testChangingAppVolumeDedicatesItWithAllProcesses() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        XCTAssertEqual(audio.dedicated, [DedicatedStrip(key: "com.google.Chrome", processes: [11, 12])])
        XCTAssertEqual(strip("com.google.Chrome")?.volume, 0.5)
        XCTAssertTrue(m.mixerStrips.first { $0.id == "com.google.Chrome" }!.isDedicated)
    }

    func testResettingAppRemovesDedication() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        m.resetStrip("com.google.Chrome")
        XCTAssertTrue(audio.dedicated.isEmpty)
        XCTAssertNil(strip("com.google.Chrome"))
    }

    func testOthersStripVolumeDoesNotDedicate() {
        let m = makeModel()
        m.setStripVolume(0.3, for: StripSettings.othersKey)
        XCTAssertTrue(audio.dedicated.isEmpty)
        XCTAssertEqual(strip("")?.volume, 0.3)
    }

    func testSoloMutesEverythingElse() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        m.toggleSolo("com.spotify.client")
        XCTAssertEqual(Set(audio.dedicated.map(\.key)), ["com.google.Chrome", "com.spotify.client"])
        XCTAssertEqual(strip("")?.isMuted, true)
        XCTAssertEqual(strip("com.google.Chrome")?.isMuted, true)
        XCTAssertEqual(strip("com.spotify.client")?.isMuted, false)
        m.toggleSolo("com.spotify.client")
        XCTAssertNil(m.soloKey)
        XCTAssertEqual(audio.dedicated.map(\.key), ["com.google.Chrome"])
    }

    func testAppPresetResolvesBandsAndPreamp() {
        let m = makeModel()
        let bass = Preset.builtIns[1]
        m.setStripPreset(bass.id, for: "com.spotify.client")
        XCTAssertEqual(strip("com.spotify.client")?.bands, bass.bands)
        XCTAssertEqual(strip("com.spotify.client")?.preampDB, bass.preampDB)
    }

    func testDeletingPresetClearsAppPreset() {
        let m = makeModel()
        m.saveAs(name: "Mine")
        let mine = m.selectedPresetID
        m.setStripPreset(mine, for: "com.spotify.client")
        m.deletePreset(mine)
        XCTAssertNil(m.mixerStrips.first { $0.id == "com.spotify.client" }!.presetID)
        XCTAssertTrue(audio.dedicated.isEmpty)
    }

    func testNewHelperProcessUpdatesDedicatedStrip() {
        let m = makeModel()
        m.setStripMuted(true, for: "com.google.Chrome")
        let helper2 = AudioProcessInfo(objectID: 13, pid: 13, bundleID: "com.google.Chrome.helper", executableName: "Helper", isRunningOutput: true)
        audio.onProcessesChange?(chrome + [helper2, spotify])
        XCTAssertEqual(audio.dedicated.first?.processes, [11, 12, 13])
    }

    func testAppMixPersistsAndReappliesOnRelaunch() {
        let m = makeModel()
        m.setStripVolume(1.25, for: "com.spotify.client")
        audio.onProcessesChange?(chrome)              // Spotify quits
        XCTAssertTrue(audio.dedicated.isEmpty)
        XCTAssertNil(m.mixerStrips.first { $0.id == "com.spotify.client" })
        m.flushSave()
        let m2 = makeModel()                           // relaunch; Spotify running again
        XCTAssertEqual(m2.mixerStrips.first { $0.id == "com.spotify.client" }?.volume, 1.25)
        XCTAssertEqual(audio.dedicated.map(\.key), ["com.spotify.client"])
    }

    func testDedicatedStripsAreCapped() {
        let m = makeModel()
        let many = (0..<20).map { AudioProcessInfo(objectID: AudioObjectID(100 + $0), pid: pid_t(100 + $0), bundleID: "",
                                                   executableName: "tool\($0)", isRunningOutput: true) }
        audio.onProcessesChange?(many)
        for i in 0..<20 { m.setStripMuted(true, for: "exe:tool\(i)") }
        XCTAssertEqual(audio.dedicated.count, MixBus.maxStrips - 1)
    }

    func testSoloBeyondCapIsDedicated() {
        let m = makeModel()
        let many = (0..<20).map { AudioProcessInfo(objectID: AudioObjectID(100 + $0), pid: pid_t(100 + $0), bundleID: "",
                                                   executableName: "tool\($0)", isRunningOutput: false) }
        audio.onProcessesChange?(many)
        for i in 0..<20 { m.setStripMuted(true, for: "exe:tool\(i)") }
        m.toggleSolo("exe:tool9")
        XCTAssertTrue(audio.dedicated.contains { $0.key == "exe:tool9" })
        XCTAssertEqual(audio.dedicated.count, MixBus.maxStrips - 1)
    }

    func testPlayingAppsWinChannelsOverIdleOnes() {
        let m = makeModel()
        var many: [AudioProcessInfo] = []
        for i in 0..<20 {
            let id = AudioObjectID(100 + i)
            many.append(AudioProcessInfo(objectID: id, pid: pid_t(100 + i), bundleID: "",
                                         executableName: "tool\(i)", isRunningOutput: i == 9))
        }
        audio.onProcessesChange?(many)
        for i in 0..<20 { m.setStripMuted(true, for: "exe:tool\(i)") }
        XCTAssertTrue(audio.dedicated.contains { $0.key == "exe:tool9" })
    }

    func testDraggingThroughDefaultKeepsStrip() {
        let m = makeModel()
        m.setStripVolume(0.5, for: "com.google.Chrome")
        m.setStripVolume(1.0, for: "com.google.Chrome")
        XCTAssertEqual(audio.dedicated.map(\.key), ["com.google.Chrome"])
        m.resetStrip("com.google.Chrome")
        XCTAssertTrue(audio.dedicated.isEmpty)
    }
}
