import XCTest
@testable import EquinoxAudio

final class StallMonitorTests: XCTestCase {
    let s: UInt64 = 1_000_000_000

    func testHealthyCallbacksNeverRebuild() {
        var m = StallMonitor()
        XCTAssertEqual(m.evaluate(now: 10 * s, lastCallback: 10 * s - 5_000_000, sessionStart: 1 * s), .healthy)
    }

    func testSessionThatNeverCallsBackIsRebuiltThenAbandoned() {
        var m = StallMonitor()
        var start: UInt64 = 0
        var actions: [StallMonitor.Action] = []
        for i in 1...4 {
            let now = start + 3 * s
            let a = m.evaluate(now: now, lastCallback: 0, sessionStart: start)
            actions.append(a)
            start = now   // a rebuild starts a new session
            _ = i
        }
        XCTAssertEqual(actions, [.rebuild, .rebuild, .rebuild, .giveUp])
    }

    func testFreshSessionGetsGracePeriodEvenIfOldCallbackIsStale() {
        var m = StallMonitor()
        XCTAssertEqual(m.evaluate(now: 100 * s, lastCallback: 10 * s, sessionStart: 99 * s), .healthy)
    }

    func testCallbacksResumingResetTheRetryBudget() {
        var m = StallMonitor()
        XCTAssertEqual(m.evaluate(now: 3 * s, lastCallback: 0, sessionStart: 0), .rebuild)
        XCTAssertEqual(m.evaluate(now: 5 * s, lastCallback: 4 * s, sessionStart: 3 * s), .healthy)
        XCTAssertEqual(m.evaluate(now: 9 * s, lastCallback: 4 * s, sessionStart: 3 * s), .rebuild)
        XCTAssertEqual(m.retries, 1)
    }
}

final class StreamUsageTests: XCTestCase {
    func testOnlyTapStreamsAreEnabledForTheIOProc() {
        XCTAssertEqual(TapSession.inputStreamUsage(deviceInputStreams: 2, tapStreams: 1), [0, 0, 1])
        XCTAssertEqual(TapSession.inputStreamUsage(deviceInputStreams: 0, tapStreams: 1), [1])
    }
}

final class TapOrderTests: XCTestCase {
    func testStripKeysFollowTheAggregateTapOrder() {
        let keys = TapSession.orderedKeys(tapOrder: [30, 10, 20], keyForTap: [10: "", 20: "a", 30: "b"])
        XCTAssertEqual(keys, ["b", "", "a"])
    }

    func testUnknownOrMissingTapsFallBack() {
        XCTAssertNil(TapSession.orderedKeys(tapOrder: [10, 99], keyForTap: [10: "", 20: "a"]))
        XCTAssertNil(TapSession.orderedKeys(tapOrder: [10], keyForTap: [10: "", 20: "a"]))
    }
}
