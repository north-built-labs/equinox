import XCTest
@testable import EquinoxCore
import EquinoxDSP

final class EQGeometryTests: XCTestCase {
    func testMappingRoundTripsAndEdges() {
        let g = EQGeometry(size: CGSize(width: 600, height: 300))
        XCTAssertEqual(g.x(for: 20), 0, accuracy: 0.001)
        XCTAssertEqual(g.x(for: 20000), 600, accuracy: 0.001)
        XCTAssertEqual(g.frequency(atX: g.x(for: 1234)), 1234, accuracy: 0.01)
        XCTAssertEqual(g.y(forDB: 0), 150, accuracy: 0.001)
        XCTAssertEqual(g.db(atY: g.y(forDB: 7.5)), 7.5, accuracy: 0.001)
        XCTAssertLessThan(g.y(forDB: 24), g.y(forDB: 0))
        XCTAssertEqual(g.frequency(atX: -50), 20, accuracy: 0.001)   // clamped
    }
}

final class EQCurveDisplayTests: XCTestCase {
    func testDisplayCurvePassesThroughIsolatedNodeIgnoringPreamp() {
        let g = EQGeometry(size: CGSize(width: 800, height: 300))
        let band = EQBand(type: .peak, frequency: 1000, gainDB: 6, q: 4)
        let db = g.curveDB(bands: [band], sampleRate: 48_000, atX: g.x(for: 1000))
        XCTAssertEqual(db, 6, accuracy: 0.05)
    }
}
