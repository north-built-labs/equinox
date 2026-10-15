import EquinoxDSP
import Foundation

/// Crash marker for in-process plugin loads: written before instantiation, removed after.
/// If Equinox dies while loading, the marker survives and names the culprit on the next launch.
public final class PluginGuard {
    private let url: URL

    public init(directory: URL) { url = directory.appendingPathComponent("plugin-loading.json") }

    public func begin(_ id: AudioUnitID) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(id).write(to: url, options: .atomic)
    }

    public func end() { try? FileManager.default.removeItem(at: url) }

    /// Returns (and clears) the plugin that was loading when Equinox last died, if any.
    public func takeCrashedPlugin() -> AudioUnitID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        end()
        return try? JSONDecoder().decode(AudioUnitID.self, from: data)
    }
}
