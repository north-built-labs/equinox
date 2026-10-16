import XCTest
@testable import EquinoxCore
import EquinoxAudio
import EquinoxDSP

final class FakeAutoEQ: AutoEQProviding {
    var list: [AutoEQEntry] = [AutoEQEntry(name: "Apple AirPods Pro", source: "crinacle", rig: "711", path: "./crinacle/711%20in-ear/Apple%20AirPods%20Pro")]
    var fail = false
    func entries() async throws -> [AutoEQEntry] { if fail { throw URLError(.notConnectedToInternet) }; return list }
    func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile {
        CorrectionProfile(name: entry.name, source: entry.source, preampDB: -4, bands: [EQBand(type: .peak, frequency: 3000, gainDB: 4, q: 2)])
    }
}

final class FakeUpdates: UpdateProviding {
    var release = ReleaseInfo(version: "9.9.9", downloadURL: URL(string: "https://example.com/Equinox-macos.zip")!,
                              signatureURL: URL(string: "https://example.com/Equinox-macos.zip.sig")!,
                              pageURL: URL(string: "https://example.com")!)
    func latestRelease() async throws -> ReleaseInfo { release }
}

@MainActor
final class HeadphoneModelTests: XCTestCase {
    var dir: URL!
    var audio: FakeAudio!
    let airpods = AudioDevice(id: 7, uid: "airpods", name: "AirPods Pro", transportType: 0, isHeadphones: true)
    let speakers = AudioDevice(id: 1, uid: "builtin", name: "MacBook Speakers", transportType: 0, isHeadphones: false)
    let jack = AudioDevice(id: 1, uid: "builtin", name: "MacBook Speakers", transportType: 0, isHeadphones: true)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-hp-\(UUID().uuidString)")
        audio = FakeAudio()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func makeModel(autoEQ: AutoEQProviding = FakeAutoEQ(), updates: UpdateProviding = FakeUpdates()) -> AppModel {
        AppModel(audio: audio, store: Store(directory: dir), loginItem: FakeLoginItem(), autoEQ: autoEQ, updates: updates,
                 currentVersion: "0.4.0")
    }

    func testNewHeadphonesAutoEnableTheLayer() {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        XCTAssertTrue(m.isHeadphoneOutput)
        XCTAssertTrue(m.headphones.isEnabled)
        audio.onOutputDeviceChange?(speakers)
        XCTAssertFalse(m.headphones.isEnabled)
    }

    func testApplyingAutoEQPushesCorrection() async {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        await m.searchAutoEQ("airpods")
        XCTAssertEqual(m.autoEQResults.count, 1)
        await m.applyAutoEQ(m.autoEQResults[0])
        XCTAssertEqual(audio.applied.last?.correction?.name, "Apple AirPods Pro")
        m.updateHeadphones { $0.isEnabled = false }
        XCTAssertNil(audio.applied.last?.correction)
    }

    func testSearchFailureIsReported() async {
        let fake = FakeAutoEQ(); fake.fail = true
        let m = makeModel(autoEQ: fake)
        await m.searchAutoEQ("hd 650")
        XCTAssertTrue(m.autoEQResults.isEmpty)
        XCTAssertNotNil(m.autoEQStatus)
    }

    func testImportParametricText() throws {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        try m.importCorrection(from: Data("Preamp: -2 dB\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1".utf8), name: "Mine")
        XCTAssertEqual(audio.applied.last?.correction?.preampDB, -2)
        XCTAssertThrowsError(try m.importCorrection(from: Data("nope".utf8), name: "Bad"))
        m.removeCorrection()
        XCTAssertNil(audio.applied.last?.correction)
    }

    func testSpatialSupersedesCrossfeed() {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        m.updateHeadphones { $0.crossfeed = .high }
        XCTAssertEqual(audio.applied.last?.crossfeed, .high)
        XCTAssertNil(audio.spatial)
        m.updateHeadphones { $0.spatialEnabled = true; $0.spatial.width = 45 }
        XCTAssertEqual(audio.applied.last?.spatialEnabled, true)
        XCTAssertEqual(audio.applied.last?.crossfeed, .off)
        XCTAssertEqual(audio.spatial?.width, 45)
    }

    func testJackAndSpeakersKeepSeparateSettings() {
        let m = makeModel()
        audio.onOutputDeviceChange?(jack)
        m.updateHeadphones { $0.crossfeed = .medium }
        audio.onOutputDeviceChange?(speakers)            // same UID, jack unplugged
        XCTAssertEqual(m.headphones.crossfeed, .off)
        XCTAssertEqual(audio.applied.last?.crossfeed, .off)
        audio.onOutputDeviceChange?(jack)
        XCTAssertEqual(m.headphones.crossfeed, .medium)
    }

    func testOverrideTreatsSpeakerAsHeadphones() {
        let m = makeModel()
        audio.onOutputDeviceChange?(speakers)
        m.setHeadphoneOverride(true)
        XCTAssertTrue(m.isHeadphoneOutput)
        m.updateHeadphones { $0.isEnabled = true; $0.crossfeed = .low }
        XCTAssertEqual(audio.applied.last?.crossfeed, .low)
    }

    func testHeadphoneSettingsPersist() {
        let m = makeModel()
        audio.onOutputDeviceChange?(airpods)
        m.updateHeadphones { $0.crossfeed = .high }
        m.flushSave()
        let m2 = makeModel()
        audio.onOutputDeviceChange?(airpods)
        XCTAssertEqual(m2.headphones.crossfeed, .high)
    }

    func testUpdateCheckFindsNewerRelease() async {
        let m = makeModel()
        await m.checkForUpdates(userInitiated: true)
        XCTAssertEqual(m.availableUpdate?.version, "9.9.9")
        let current = FakeUpdates(); current.release = ReleaseInfo(version: "0.0.1", downloadURL: current.release.downloadURL,
                                      signatureURL: current.release.signatureURL, pageURL: current.release.pageURL)
        let m2 = makeModel(updates: current)
        await m2.checkForUpdates(userInitiated: true)
        XCTAssertNil(m2.availableUpdate)
        XCTAssertNotNil(m2.updateStatus)
    }

    func testMoveEffectToIndex() {
        let m = makeModel()
        let a = m.addEffect(.builtIn(.reverb)), b = m.addEffect(.builtIn(.delay)), c = m.addEffect(.builtIn(.limiter))
        m.moveEffect(c, to: 0)
        XCTAssertEqual(m.working.effects.map(\.id), [c, a, b])
        m.moveEffect(c, to: 99)
        XCTAssertEqual(m.working.effects.map(\.id), [a, b, c])
    }
}
