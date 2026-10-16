import EquinoxDSP
import Foundation

public protocol DataFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionFetching: DataFetching {
    public init() {}
    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct AutoEQEntry: Hashable, Identifiable, Sendable {
    public let name: String
    public let source: String
    public let rig: String?
    /// Percent-encoded relative path from the AutoEq results directory, e.g. "./oratory1990/over-ear/Sennheiser%20HD%20650".
    public let path: String
    public var id: String { path }

    public init(name: String, source: String, rig: String?, path: String) {
        self.name = name; self.source = source; self.rig = rig; self.path = path
    }
}

public enum AutoEQIndex {
    static let resultsBase = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    /// Parses AutoEq's results/INDEX.md: `- [Name](./path) by Source[ on Rig]`. Paths may contain parentheses.
    public static func parse(_ markdown: String) -> [AutoEQEntry] {
        markdown.split(whereSeparator: \.isNewline).compactMap { raw -> AutoEQEntry? in
            let line = String(raw)
            guard line.hasPrefix("- ["), let nameEnd = line.range(of: "](./") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<nameEnd.lowerBound])
            let pathStart = line.index(nameEnd.lowerBound, offsetBy: 2)
            guard let by = line.range(of: ") by ", range: pathStart..<line.endIndex) else { return nil }
            let path = String(line[pathStart..<by.lowerBound])
            guard isSafe(path), !name.isEmpty else { return nil }
            let attribution = String(line[by.upperBound...])
            let parts = attribution.components(separatedBy: " on ")
            return AutoEQEntry(name: name, source: parts[0], rig: parts.count > 1 ? parts[1...].joined(separator: " on ") : nil,
                               path: path)
        }
    }

    static func isSafe(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return path.hasPrefix("./") && !path.contains("..") && !lowered.contains("%2e") && !lowered.contains("%2f")
            && !path.contains("?") && !path.contains("#") && !path.contains("://") && !path.contains("\\")
    }

    /// Entries whose name contains every whitespace-separated token; names starting with the query first.
    public static func search(_ entries: [AutoEQEntry], query: String, limit: Int = 60) -> [AutoEQEntry] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let q = query.lowercased()
        return entries
            .filter { e in let n = e.name.lowercased(); return tokens.allSatisfy { n.contains($0) } }
            .sorted { a, b in
                let pa = a.name.lowercased().hasPrefix(q), pb = b.name.lowercased().hasPrefix(q)
                return pa != pb ? pa : (a.name.count, a.name, a.source) < (b.name.count, b.name, b.source)
            }
            .prefix(limit).map { $0 }
    }

    public static func profileURL(for entry: AutoEQEntry) -> URL? {
        guard isSafe(entry.path), let folder = entry.path.split(separator: "/").last else { return nil }
        return URL(string: resultsBase + entry.path.dropFirst(2) + "/" + folder + "%20ParametricEQ.txt")
    }
}

public protocol AutoEQProviding: AnyObject {
    func entries() async throws -> [AutoEQEntry]
    func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile
}

/// Downloads AutoEq's index (cached on disk, refreshed weekly, stale copy used offline) and profiles.
/// An actor: concurrent searches share one in-flight index download.
public actor AutoEQCatalog: AutoEQProviding {
    public static let indexURL = URL(string: AutoEQIndex.resultsBase + "INDEX.md")!

    private let fetcher: DataFetching
    private let cacheFile: URL
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var memory: [AutoEQEntry]?
    private var loading: Task<[AutoEQEntry], Error>?

    public init(fetcher: DataFetching = URLSessionFetching(), cacheDirectory: URL = Store.defaultDirectory,
                maxAge: TimeInterval = 7 * 86_400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        cacheFile = cacheDirectory.appendingPathComponent("autoeq-index.md")
        self.maxAge = maxAge
        self.now = now
    }

    public func entries() async throws -> [AutoEQEntry] {
        if let memory { return memory }
        if let loading { return try await loading.value }
        let task = Task { try await self.load() }
        loading = task
        defer { loading = nil }
        let entries = try await task.value
        memory = entries
        return entries
    }

    private func load() async throws -> [AutoEQEntry] {
        let cached = try? String(contentsOf: cacheFile, encoding: .utf8)
        let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached, let modified, now().timeIntervalSince(modified) < maxAge { return AutoEQIndex.parse(cached) }
        do {
            let data = try await fetcher.data(from: Self.indexURL)
            guard data.count < 20_000_000, let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            let parsed = AutoEQIndex.parse(text)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return parsed
        } catch {
            if let cached { return AutoEQIndex.parse(cached) }
            throw error
        }
    }

    public func profile(for entry: AutoEQEntry) async throws -> CorrectionProfile {
        guard let url = AutoEQIndex.profileURL(for: entry) else { throw URLError(.badURL) }
        let data = try await fetcher.data(from: url)
        guard data.count < 200_000, let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try ParametricEQText.parse(text, name: entry.name, source: entry.source)
    }
}
