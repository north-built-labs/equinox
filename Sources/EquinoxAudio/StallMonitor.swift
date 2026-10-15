import Foundation

/// Decides what the watchdog does when the audio callback stops arriving.
/// A session that never calls back is rebuilt a few times, then abandoned so the tap
/// (which mutes the source audio) is removed and the user's audio plays unprocessed.
struct StallMonitor {
    enum Action: Equatable { case healthy, rebuild, giveUp }

    static let stallNanos: UInt64 = 2_000_000_000
    static let maxRetries = 3

    private(set) var retries = 0

    /// `sessionStart` gives each new session a grace period even if `lastCallback` is from an older one.
    mutating func evaluate(now: UInt64, lastCallback: UInt64, sessionStart: UInt64) -> Action {
        let reference = max(lastCallback, sessionStart)
        guard now > reference, now - reference > Self.stallNanos else {
            if lastCallback > sessionStart { retries = 0 }
            return .healthy
        }
        if retries >= Self.maxRetries { return .giveUp }
        retries += 1
        return .rebuild
    }

    mutating func reset() { retries = 0 }
}
