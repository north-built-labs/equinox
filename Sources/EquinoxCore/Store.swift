import Foundation

/// JSON files in Application Support. Writes are atomic; unreadable files are quarantined.
public final class Store {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Equinox", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = Store.defaultDirectory) { self.directory = directory }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> (value: T?, wasCorrupt: Bool) {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return (nil, false) }
        do {
            return (try JSONDecoder().decode(T.self, from: data), false)
        } catch {
            let quarantine = directory.appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return (nil, true)
        }
    }

    /// Copies `name` to `<name>.corrupt-<unix-time>` before it is overwritten.
    public func backup(_ name: String) {
        let url = directory.appendingPathComponent(name)
        let copy = directory.appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
