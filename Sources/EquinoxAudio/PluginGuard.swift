import EquinoxDSP
import Foundation

/// Crash marker for in-process plugin loads. Each load adds its plugin to a list in a file before instantiation
/// and removes one occurrence once the engine has started; overlapping builds therefore keep each other's entries.
/// If Equinox dies mid-load, the surviving entries name the culprits on the next launch.
public final class PluginGuard {
    private let url: URL

    public init(directory: URL) { url = directory.appendingPathComponent("plugin-loading.json") }

    private func read() -> [AudioUnitID] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([AudioUnitID].self, from: $0) } ?? []
    }

    private func write(_ ids: [AudioUnitID]) {
        if ids.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }

    public func begin(_ id: AudioUnitID) { write(read() + [id]) }

    public func end(_ id: AudioUnitID) {
        var ids = read()
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) }
        write(ids)
    }

    /// Returns (and clears) the plugins that were loading when Equinox last died.
    public func takeCrashedPlugins() -> [AudioUnitID] {
        let ids = read()
        write([])
        var seen = Set<AudioUnitID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
