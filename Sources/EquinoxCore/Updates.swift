import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let pageURL: URL
    public init(version: String, downloadURL: URL, pageURL: URL) {
        self.version = version; self.downloadURL = downloadURL; self.pageURL = pageURL
    }
}

public enum UpdateError: Error, Equatable { case noAsset, notEquinox, notNewer, badArchive }

public enum UpdateChecker {
    public static let assetName = "Equinox-macos.zip"
    public static let latestURL = URL(string: "https://api.github.com/repos/north-built-labs/equinox/releases/latest")!

    public static func parseLatest(_ json: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let html_url: URL?; let assets: [Asset] }
        let r = try JSONDecoder().decode(Release.self, from: json)
        guard let asset = r.assets.first(where: { $0.name == assetName }) else { throw UpdateError.noAsset }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return ReleaseInfo(version: version, downloadURL: asset.browser_download_url,
                           pageURL: r.html_url ?? URL(string: "https://github.com/north-built-labs/equinox/releases")!)
    }

    static func components(_ v: String) -> [Int]? {
        let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    public static func isNewer(_ remote: String, than local: String) -> Bool {
        guard var r = components(remote), var l = components(local) else { return false }
        let n = max(r.count, l.count)
        r += Array(repeating: 0, count: n - r.count); l += Array(repeating: 0, count: n - l.count)
        return r.lexicographicallyPrecedes(l) == false && r != l
    }
}

public protocol UpdateProviding: AnyObject {
    func latestRelease() async throws -> ReleaseInfo
}

public final class GitHubUpdates: UpdateProviding, @unchecked Sendable {
    private let fetcher: DataFetching
    public init(fetcher: DataFetching = URLSessionFetching()) { self.fetcher = fetcher }
    public func latestRelease() async throws -> ReleaseInfo {
        try UpdateChecker.parseLatest(try await fetcher.data(from: UpdateChecker.latestURL))
    }
}

public enum UpdateInstaller {
    /// Downloads and unpacks the release; returns the staged Equinox.app (not yet verified).
    public static func stage(_ release: ReleaseInfo, fetcher: DataFetching = URLSessionFetching()) async throws -> URL {
        let data = try await fetcher.data(from: release.downloadURL)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("equinox-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(UpdateChecker.assetName)
        try data.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run(); unzip.waitUntilExit()
        let app = dir.appendingPathComponent("Equinox.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.badArchive }
        return app
    }

    /// The staged app must be Equinox and newer than what's running.
    public static func verify(appAt app: URL, expectedBundleID: String, newerThan current: String) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == expectedBundleID else { throw UpdateError.notEquinox }
        guard let version = plist["CFBundleShortVersionString"] as? String,
              UpdateChecker.isNewer(version, than: current) else { throw UpdateError.notNewer }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Waits for Equinox (pid) to exit, swaps the bundle, clears quarantine, relaunches.
    public static func relaunchScript(current: URL, replacement: URL, pid: Int32) -> String {
        let cur = quote(current.path), new = quote(replacement.path)
        return """
        #!/bin/sh
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        rm -rf \(cur).old
        if mv \(cur) \(cur).old; then
          if ditto \(new) \(cur); then rm -rf \(cur).old; else rm -rf \(cur); mv \(cur).old \(cur); fi
        fi
        xattr -dr com.apple.quarantine \(cur) 2>/dev/null
        open \(cur)
        """
    }

    /// Starts the detached swap script; the caller then terminates the app.
    public static func launchReplacement(current: URL, replacement: URL) throws {
        let script = replacement.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try relaunchScript(current: current, replacement: replacement, pid: ProcessInfo.processInfo.processIdentifier)
            .write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh \(quote(script.path)) >/dev/null 2>&1 &"]
        try p.run()
    }
}
