import AppKit
import EquinoxCore
import Foundation

/// `--update-dry-run <zip> <sig> <version> <log>`: runs the real update path (signature check, staging,
/// bundle verification, detached swap script, relaunch) against local files instead of GitHub downloads.
enum UpdateDryRun {
    struct FileFetcher: DataFetching {
        func data(from url: URL) async throws -> Data { try Data(contentsOf: url) }
    }

    static func run(zip: String, sig: String, version: String, log: String) -> Never {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            Task { @MainActor in
                func write(_ s: String) { try? s.write(toFile: log, atomically: true, encoding: .utf8) }
                let release = ReleaseInfo(version: version, downloadURL: URL(fileURLWithPath: zip),
                                          signatureURL: URL(fileURLWithPath: sig), pageURL: URL(fileURLWithPath: zip))
                let app = Bundle.main.bundleURL
                do {
                    guard UpdateInstaller.canReplace(appAt: app) else { write("REFUSED not-writable"); exit(1) }
                    let staged = try await UpdateInstaller.stage(release, fetcher: FileFetcher())
                    try UpdateInstaller.verify(appAt: staged, expectedBundleID: UpdateInstaller.bundleID, newerThan: AppModel.bundleVersion)
                    try UpdateInstaller.launchReplacement(current: app, replacement: staged)
                    write("HANDED-OFF \(AppModel.bundleVersion) -> \(version)")
                    exit(0)
                } catch {
                    write("REFUSED \(error)")
                    exit(1)
                }
            }
        }
        dispatchMain()
    }
}
