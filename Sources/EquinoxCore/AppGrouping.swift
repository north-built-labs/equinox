import AppKit
import CoreAudio
import EquinoxAudio

public struct RunningAppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public protocol RunningAppsProviding: AnyObject {
    func runningApps() -> [RunningAppInfo]
}

public final class WorkspaceRunningApps: RunningAppsProviding {
    public init() {}
    public func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: id, name: app.localizedName ?? id)
        }
    }
}

public struct AudioAppGroup: Equatable, Sendable {
    public let key: String
    public let name: String
    /// Bundle ID used for the icon; nil for command-line processes.
    public let bundleID: String?
    public let processObjects: [AudioObjectID]
    public let isPlaying: Bool
}

public enum AppGrouping {
    /// Groups audio processes into apps. Helpers whose bundle ID extends a running app's bundle ID
    /// (at a dot boundary) belong to that app; processes without a bundle ID are keyed by executable.
    public static func group(_ processes: [AudioProcessInfo], runningApps: [RunningAppInfo],
                             excludingBundleIDs: Set<String>, excludingPIDs: Set<pid_t>) -> [AudioAppGroup] {
        var order: [String] = []
        var members: [String: (name: String, bundleID: String?, objects: [AudioObjectID], playing: Bool)] = [:]
        for p in processes where !excludingPIDs.contains(p.pid) {
            let owner = owningApp(p.bundleID, runningApps)
            let key: String, name: String, bundleID: String?
            if let owner {
                key = owner.bundleID; name = owner.name; bundleID = owner.bundleID
            } else if !p.bundleID.isEmpty {
                key = p.bundleID; name = p.bundleID.split(separator: ".").last.map(String.init) ?? p.bundleID; bundleID = p.bundleID
            } else {
                key = "exe:\(p.executableName)"; name = p.executableName; bundleID = nil
            }
            if excludingBundleIDs.contains(key) || excludingBundleIDs.contains(p.bundleID) { continue }
            if members[key] == nil { order.append(key); members[key] = (name, bundleID, [], false) }
            members[key]!.objects.append(p.objectID)
            members[key]!.playing = members[key]!.playing || p.isRunningOutput
        }
        return order.map { key in
            let m = members[key]!
            return AudioAppGroup(key: key, name: m.name, bundleID: m.bundleID, processObjects: m.objects.sorted(), isPlaying: m.playing)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func owningApp(_ bundleID: String, _ apps: [RunningAppInfo]) -> RunningAppInfo? {
        guard !bundleID.isEmpty else { return nil }
        return apps.filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
}
