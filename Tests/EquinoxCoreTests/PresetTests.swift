import XCTest
@testable import EquinoxCore
import EquinoxDSP

final class PresetTests: XCTestCase {
    func testBuiltInsHaveStableUniqueIDsAndTenBands() {
        let ids = Set(Preset.builtIns.map(\.id))
        XCTAssertEqual(ids.count, Preset.builtIns.count)
        XCTAssertEqual(Preset.builtIns.first, Preset.flat)
        XCTAssertTrue(Preset.builtIns.allSatisfy { $0.isBuiltIn && $0.bands.count == 10 })
        XCTAssertEqual(Preset.flat.id.uuidString, "00000000-0000-0000-0000-000000000001")
    }

    func testExportImportRoundTripAssignsNewIDsAndClearsBuiltIn() throws {
        let original = Preset.builtIns[1]
        let data = try Preset.exportData([original])
        let imported = try Preset.importPresets(from: data)
        XCTAssertEqual(imported.count, 1)
        XCTAssertNotEqual(imported[0].id, original.id)
        XCTAssertFalse(imported[0].isBuiltIn)
        XCTAssertEqual(imported[0].bands.map(\.gainDB), original.bands.map(\.gainDB))
    }

    func testImportAcceptsSinglePresetObject() throws {
        let data = try JSONEncoder().encode(Preset.builtIns[2])
        XCTAssertEqual(try Preset.importPresets(from: data).count, 1)
    }

    func testImportClampsAndCapsBands() throws {
        var p = Preset(name: "Wild", preampDB: 99, bands: (0..<40).map { _ in EQBand(frequency: 1, gainDB: 80, q: 50) })
        p.isBuiltIn = true
        let imported = try Preset.importPresets(from: try Preset.exportData([p]))[0]
        XCTAssertEqual(imported.bands.count, BiquadBank.maxSections)
        XCTAssertEqual(imported.bands[0].gainDB, 24)
        XCTAssertEqual(imported.preampDB, 24)
    }

    func testImportGarbageThrows() {
        XCTAssertThrowsError(try Preset.importPresets(from: Data("nope".utf8)))
        XCTAssertThrowsError(try Preset.importPresets(from: Data("[]".utf8)))
    }
}
