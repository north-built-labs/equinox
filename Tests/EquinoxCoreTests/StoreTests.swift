import XCTest
@testable import EquinoxCore

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-tests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRoundTrip() throws {
        let store = Store(directory: dir)
        var s = AppSettings(); s.boostDB = 4; s.hasCompletedOnboarding = true
        try store.save(s, to: "settings.json")
        let loaded = store.load(AppSettings.self, from: "settings.json")
        XCTAssertEqual(loaded.value, s); XCTAssertFalse(loaded.wasCorrupt)
    }

    func testMissingFileIsNotCorrupt() {
        let r = Store(directory: dir).load(AppSettings.self, from: "settings.json")
        XCTAssertNil(r.value); XCTAssertFalse(r.wasCorrupt)
    }

    func testCorruptFileIsQuarantined() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let r = Store(directory: dir).load(AppSettings.self, from: "settings.json")
        XCTAssertNil(r.value); XCTAssertTrue(r.wasCorrupt)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains("settings.json"))
        XCTAssertTrue(files.contains { $0.hasPrefix("settings.json.corrupt-") })
    }

    func testMissingKeysUseDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"boostDB": 3}"#.utf8))
        XCTAssertEqual(s.boostDB, 3)
        XCTAssertEqual(s.selectedPresetID, Preset.flat.id)
        XCTAssertTrue(s.isEnabled)
        XCTAssertEqual(s.volume, 1)
    }
}
