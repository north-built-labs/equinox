import CryptoKit
import XCTest
@testable import EquinoxCore

final class UpdatesTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.4.0", than: "0.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.3", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "0.3.0"))
    }

    func testParsesLatestReleaseJSON() throws {
        let json = #"{"tag_name":"v0.5.0","html_url":"https://github.com/north-built-labs/equinox/releases/tag/v0.5.0","assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt"},{"name":"Equinox-macos.zip","browser_download_url":"https://github.com/north-built-labs/equinox/releases/download/v0.5.0/Equinox-macos.zip"},{"name":"Equinox-macos.zip.sig","browser_download_url":"https://github.com/north-built-labs/equinox/releases/download/v0.5.0/Equinox-macos.zip.sig"}]}"#
        let r = try UpdateChecker.parseLatest(Data(json.utf8))
        XCTAssertEqual(r.version, "0.5.0")
        XCTAssertEqual(r.downloadURL.lastPathComponent, "Equinox-macos.zip")
        XCTAssertEqual(r.signatureURL.lastPathComponent, "Equinox-macos.zip.sig")
        XCTAssertThrowsError(try UpdateChecker.parseLatest(Data(#"{"tag_name":"v1","assets":[]}"#.utf8)))
    }

    func makeApp(_ dir: URL, bundleID: String, version: String) throws -> URL {
        let app = dir.appendingPathComponent("Equinox.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        return dir.appendingPathComponent("Equinox.app")
    }

    func testInstallerRefusesForeignBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try makeApp(dir.appendingPathComponent("a"), bundleID: "com.northbuiltlabs.equinox", version: "0.5.0")
        XCTAssertNoThrow(try UpdateInstaller.verify(appAt: good, expectedBundleID: "com.northbuiltlabs.equinox", newerThan: "0.4.0"))
        let foreign = try makeApp(dir.appendingPathComponent("b"), bundleID: "com.evil.app", version: "9.0.0")
        XCTAssertThrowsError(try UpdateInstaller.verify(appAt: foreign, expectedBundleID: "com.northbuiltlabs.equinox", newerThan: "0.4.0"))
        let old = try makeApp(dir.appendingPathComponent("c"), bundleID: "com.northbuiltlabs.equinox", version: "0.4.0")
        XCTAssertThrowsError(try UpdateInstaller.verify(appAt: old, expectedBundleID: "com.northbuiltlabs.equinox", newerThan: "0.4.0"))
    }

    func testScriptReplacesOnlyAfterExit() {
        let s = UpdateInstaller.relaunchScript(current: URL(fileURLWithPath: "/Applications/Equinox.app"),
                                               replacement: URL(fileURLWithPath: "/tmp/x/Equinox.app"), pid: 4242)
        let wait = s.range(of: "kill -0 4242")!, remove = s.range(of: "mv '/Applications/Equinox.app'")!
        XCTAssertLessThan(wait.lowerBound, remove.lowerBound)
        XCTAssertTrue(s.contains("'/Applications/Equinox.app'"))
        XCTAssertTrue(s.contains("open '/Applications/Equinox.app'"))
    }

    func testUnsignedReleaseIsRejected() {
        let json = #"{"tag_name":"v0.5.0","assets":[{"name":"Equinox-macos.zip","browser_download_url":"https://x/Equinox-macos.zip"}]}"#
        XCTAssertThrowsError(try UpdateChecker.parseLatest(Data(json.utf8))) { XCTAssertEqual($0 as? UpdateError, .unsigned) }
    }

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("release bytes".utf8)
        let signature = try key.signature(for: archive)
        let publicKey = key.publicKey.rawRepresentation
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(of: archive, signature: signature, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: Data("tampered".utf8), signature: signature, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: archive, signature: Data(repeating: 0, count: 64), publicKey: publicKey))
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: archive, signature: signature,
                                                                 publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
    }

    func testStageRefusesBadSignatureBeforeUnpacking() async throws {
        let f = FakeFetcher()
        let release = ReleaseInfo(version: "0.5.0", downloadURL: URL(string: "https://x/Equinox-macos.zip")!,
                                  signatureURL: URL(string: "https://x/Equinox-macos.zip.sig")!, pageURL: URL(string: "https://x")!)
        f.responses[release.downloadURL.absoluteString] = Data("evil zip".utf8)
        f.responses[release.signatureURL.absoluteString] = Data(repeating: 1, count: 64)
        do {
            _ = try await UpdateInstaller.stage(release, fetcher: f)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? UpdateError, .badSignature)
        }
    }

    func testEmbeddedPublicKeyIsValid() {
        XCTAssertNotNil(try? Curve25519.Signing.PublicKey(rawRepresentation: UpdateInstaller.releasePublicKey))
    }
}
