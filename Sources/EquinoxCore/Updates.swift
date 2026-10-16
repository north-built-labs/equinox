import CryptoKit
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    /// Detached Ed25519 signature of the archive (`<asset>.sig`).
    public let signatureURL: URL
    public let pageURL: URL
    public init(version: String, downloadURL: URL, signatureURL: URL, pageURL: URL) {
        self.version = version; self.downloadURL = downloadURL; self.signatureURL = signatureURL; self.pageURL = pageURL
    }
}

public enum UpdateError: Error, Equatable { case noAsset, unsigned, badSignature, notEquinox, notNewer, badArchive }

public enum UpdateChecker {
    public static let assetName = "Equinox-macos.zip"
    public static let latestURL = URL(string: "https://api.github.com/repos/north-built-labs/equinox/releases/latest")!

    public static func parseLatest(_ json: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let html_url: URL?; let assets: [Asset] }
        let r = try JSONDecoder().decode(Release.self, from: json)
        guard let asset = r.assets.first(where: { $0.name == assetName }) else { throw UpdateError.noAsset }
        guard let signature = r.assets.first(where: { $0.name == assetName + ".sig" }) else { throw UpdateError.unsigned }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return ReleaseInfo(version: version, downloadURL: asset.browser_download_url, signatureURL: signature.browser_download_url,
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
    /// Downloads, signature-checks and unpacks the release; returns the staged app.
    func stage(_ release: ReleaseInfo) async throws -> URL
    /// Staged app must be Equinox and newer than `current`.
    func verify(appAt app: URL, newerThan current: String) throws
    /// Starts the detached swap-and-relaunch; the caller then quits.
    func launchReplacement(current: URL, replacement: URL) throws
}

public final class GitHubUpdates: UpdateProviding, @unchecked Sendable {
    private let fetcher: DataFetching
    public init(fetcher: DataFetching = URLSessionFetching()) { self.fetcher = fetcher }
    public func latestRelease() async throws -> ReleaseInfo {
        try UpdateChecker.parseLatest(try await fetcher.data(from: UpdateChecker.latestURL))
    }
    public func stage(_ release: ReleaseInfo) async throws -> URL { try await UpdateInstaller.stage(release, fetcher: fetcher) }
    public func verify(appAt app: URL, newerThan current: String) throws {
        try UpdateInstaller.verify(appAt: app, expectedBundleID: UpdateInstaller.bundleID, newerThan: current)
    }
    public func launchReplacement(current: URL, replacement: URL) throws {
        try UpdateInstaller.launchReplacement(current: current, replacement: replacement)
    }
}

public enum UpdateInstaller {
    public static let bundleID = "com.northbuiltlabs.equinox"

    /// Equinox can only replace itself where it can write: not translocated, not on a read-only volume,
    /// not in a folder owned by another user.
    public static func canReplace(appAt app: URL) -> Bool {
        let path = app.path
        guard !path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return false }
        return !fm.fileExists(atPath: path) || fm.isWritableFile(atPath: path)
    }
    /// Ed25519 public key whose private half (secret EQUINOX_SIGNING_KEY, production environment) signs release archives in CI.
    /// Updates whose signature doesn't verify against it are never unpacked.
    public static let releasePublicKey = Data(base64Encoded: "e9ngBNvXF1tOyQeKbiOBPhmO79WiwYbANGSZwAgMjWQ=")!

    public static func verifySignature(of archive: Data, signature: Data, publicKey: Data = releasePublicKey) throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: archive) else { throw UpdateError.badSignature }
    }

    /// Downloads the release and its signature, verifies the signature, then unpacks; returns the staged
    /// Equinox.app (bundle identity and version are checked separately by `verify`).
    public static func stage(_ release: ReleaseInfo, fetcher: DataFetching = URLSessionFetching()) async throws -> URL {
        let signature = try await fetcher.data(from: release.signatureURL)
        let data = try await fetcher.data(from: release.downloadURL)
        try verifySignature(of: data, signature: signature)
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

    /// Waits for Equinox (pid) to exit (gives up, without touching anything, if it never does), copies the new
    /// app next to the old one, swaps them with two renames, clears quarantine and relaunches. Any failure keeps
    /// (or restores) the old app and reopens it.
    public static func relaunchScript(current: URL, replacement: URL, pid: Int32) -> String {
        let cur = quote(current.path), new = quote(replacement.path)
        let curNew = quote(current.path + ".new"), curOld = quote(current.path + ".old")
        return """
        #!/bin/sh
        for i in $(seq 1 300); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        kill -0 \(pid) 2>/dev/null && exit 1
        rm -rf \(curNew) \(curOld)
        ditto \(new) \(curNew) || { rm -rf \(curNew); open \(cur); exit 1; }
        if mv \(cur) \(curOld) && mv \(curNew) \(cur); then
          rm -rf \(curOld)
        else
          [ -d \(cur) ] || mv \(curOld) \(cur)
          rm -rf \(curNew)
          open \(cur)
          exit 1
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
