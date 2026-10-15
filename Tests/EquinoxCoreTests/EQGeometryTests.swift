import XCTest
@testable import EquinoxCore

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
