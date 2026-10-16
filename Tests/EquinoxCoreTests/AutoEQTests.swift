import XCTest
@testable import EquinoxCore
import EquinoxDSP

final class FakeFetcher: DataFetching, @unchecked Sendable {
    var responses: [String: Data] = [:]
    private let lock = NSLock()
    private var _requested: [URL] = []
    var requested: [URL] { lock.withLock { _requested } }
    var offline = false
    var delay: Duration = .zero
    func data(from url: URL) async throws -> Data {
        lock.withLock { _requested.append(url) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if offline { throw URLError(.notConnectedToInternet) }
        guard let d = responses[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return d
    }
}

final class AutoEQTests: XCTestCase {
    let index = """
    # Index
    - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990
    - [Sennheiser HD 650](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20650) by crinacle on GRAS 43AG-7
    - [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045
    - [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro) by crinacle on 711
    - [Evil](./../../etc/passwd) by attacker
    - [Query](./a/b?x=1) by attacker
    """

    func testParsesEntriesIncludingParenthesesInPaths() {
        let entries = AutoEQIndex.parse(index)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1].rig, "GRAS 43AG-7")
        XCTAssertEqual(entries[2].name, "1MORE Aero (ANC Off)")
        XCTAssertEqual(entries[2].path, "./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)")
        XCTAssertNil(entries[0].rig)
    }

    func testRejectsUnsafeIndexPaths() {
        XCTAssertFalse(AutoEQIndex.parse(index).contains { $0.source == "attacker" })
    }

    func testSearchMatchesAllTokensPrefixFirst() {
        let entries = AutoEQIndex.parse(index)
        XCTAssertEqual(AutoEQIndex.search(entries, query: "hd 650").count, 2)
        XCTAssertEqual(AutoEQIndex.search(entries, query: "airpods").first?.name, "Apple AirPods Pro")
        XCTAssertTrue(AutoEQIndex.search(entries, query: "").isEmpty)
    }

    func testProfileURL() {
        let e = AutoEQIndex.parse(index)[0]
        XCTAssertEqual(AutoEQIndex.profileURL(for: e)?.absoluteString,
                       "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20650/Sennheiser%20HD%20650%20ParametricEQ.txt")
    }

    func makeCatalog(_ fetcher: FakeFetcher, dir: URL, now: Date = Date()) -> AutoEQCatalog {
        AutoEQCatalog(fetcher: fetcher, cacheDirectory: dir, maxAge: 7 * 86_400, now: { now })
    }

    func testCatalogCachesIndexAndFetchesProfiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autoeq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = FakeFetcher()
        f.responses[AutoEQCatalog.indexURL.absoluteString] = Data(index.utf8)
        let entry = AutoEQIndex.parse(index)[0]
        f.responses[AutoEQIndex.profileURL(for: entry)!.absoluteString] = Data("Preamp: -6.1 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1".utf8)
        let catalog = makeCatalog(f, dir: dir)
        _ = try await catalog.entries()
        _ = try await catalog.entries()
        XCTAssertEqual(f.requested.filter { $0 == AutoEQCatalog.indexURL }.count, 1)   // cached
        let profile = try await catalog.profile(for: entry)
        XCTAssertEqual(profile.name, "Sennheiser HD 650")
        XCTAssertEqual(profile.source, "oratory1990")
        XCTAssertEqual(profile.bands.count, 1)
    }

    func testOfflineFallsBackToStaleCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autoeq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = FakeFetcher()
        f.responses[AutoEQCatalog.indexURL.absoluteString] = Data(index.utf8)
        _ = try await makeCatalog(f, dir: dir).entries()
        f.offline = true
        let later = makeCatalog(f, dir: dir, now: Date().addingTimeInterval(30 * 86_400))
        let entries = try await later.entries()
        XCTAssertEqual(entries.count, 4)
        let empty = makeCatalog(f, dir: dir.appendingPathComponent("none"))
        do { _ = try await empty.entries(); XCTFail("expected error") } catch {}
    }

    func testConcurrentLoadsShareOneDownload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autoeq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = FakeFetcher()
        f.delay = .milliseconds(200)
        f.responses[AutoEQCatalog.indexURL.absoluteString] = Data(index.utf8)
        let catalog = makeCatalog(f, dir: dir)
        async let a = catalog.entries()
        async let b = catalog.entries()
        async let c = catalog.entries()
        let counts = try await [a.count, b.count, c.count]
        XCTAssertEqual(counts, [4, 4, 4])
        XCTAssertEqual(f.requested.count, 1)
    }

    func testRejectsEncodedTraversal() {
        let evil = "- [X](./a/%2e%2E/b) by attacker"
        XCTAssertTrue(AutoEQIndex.parse(evil).isEmpty)
    }
}
