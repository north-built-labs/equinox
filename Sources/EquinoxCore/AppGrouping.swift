import AppKit
import CoreAudio
import EquinoxAudio

public struct RunningAppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let pid: pid_t?
    /// A regular app with a Dock icon, as opposed to an agent or background service.
    public let isRegular: Bool
    public init(bundleID: String, name: String, pid: pid_t? = nil, isRegular: Bool = true) {
        self.bundleID = bundleID; self.name = name; self.pid = pid; self.isRegular = isRegular
    }
}

public protocol RunningAppsProviding: AnyObject {
    func runningApps() -> [RunningAppInfo]
}

public final class WorkspaceRunningApps: RunningAppsProviding {
    public init() {}
    public func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: id, name: app.localizedName ?? id, pid: app.processIdentifier,
                                  isRegular: app.activationPolicy == .regular)
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
    /// Owned by a regular app. Background daemons (mediaremoted, systemsoundserverd, …) are not.
    public let isApp: Bool
}

public enum AppGrouping {
    /// Groups audio processes into apps. A process belongs to the running app macOS holds responsible
    /// for it (Safari for its WebKit GPU process); failing that, to a running app whose bundle ID it
    /// extends at a dot boundary (Chrome's helpers); processes without a bundle ID are keyed by executable.
    public static func group(_ processes: [AudioProcessInfo], runningApps: [RunningAppInfo],
                             excludingBundleIDs: Set<String>, excludingPIDs: Set<pid_t>) -> [AudioAppGroup] {
        var order: [String] = []
        var members: [String: (name: String, bundleID: String?, objects: [AudioObjectID], playing: Bool, isApp: Bool)] = [:]
        for p in processes where !excludingPIDs.contains(p.pid) {
            let owner = runningApps.first { $0.pid != nil && $0.pid == p.responsiblePID && p.responsiblePID != p.pid }
                ?? owningApp(p.bundleID, runningApps)
            let key: String, name: String, bundleID: String?
            if let owner {
                key = owner.bundleID; name = owner.name; bundleID = owner.bundleID
            } else if !p.bundleID.isEmpty {
                key = p.bundleID; name = p.bundleID.split(separator: ".").last.map(String.init) ?? p.bundleID; bundleID = p.bundleID
            } else {
                key = "exe:\(p.executableName)"; name = p.executableName; bundleID = nil
            }
            if excludingBundleIDs.contains(key) || excludingBundleIDs.contains(p.bundleID) { continue }
            if members[key] == nil { order.append(key); members[key] = (name, bundleID, [], false, owner?.isRegular ?? false) }
            members[key]!.objects.append(p.objectID)
            members[key]!.playing = members[key]!.playing || p.isRunningOutput
        }
        return order.map { key in
            let m = members[key]!
            return AudioAppGroup(key: key, name: m.name, bundleID: m.bundleID, processObjects: m.objects.sorted(), isPlaying: m.playing,
                                 isApp: m.isApp)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func owningApp(_ bundleID: String, _ apps: [RunningAppInfo]) -> RunningAppInfo? {
        guard !bundleID.isEmpty else { return nil }
        return apps.filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
}
