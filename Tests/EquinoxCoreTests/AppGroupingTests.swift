import XCTest
import CoreAudio
import EquinoxAudio
@testable import EquinoxCore

final class AppGroupingTests: XCTestCase {
    let apps = [RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome"),
                RunningAppInfo(bundleID: "com.spotify.client", name: "Spotify")]

    func p(_ id: AudioObjectID, _ bundle: String, _ exe: String = "x", playing: Bool = false, pid: pid_t = 100) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: pid + pid_t(id), bundleID: bundle, executableName: exe, isRunningOutput: playing)
    }

    func testHelpersGroupUnderOwningApp() {
        let groups = AppGrouping.group([p(1, "com.google.Chrome"), p(2, "com.google.Chrome.helper", playing: true)],
                                       runningApps: apps, excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, "com.google.Chrome")
        XCTAssertEqual(groups[0].name, "Google Chrome")
        XCTAssertEqual(Set(groups[0].processObjects), [1, 2])
        XCTAssertTrue(groups[0].isPlaying)
    }

    func testPrefixMustEndAtDotBoundary() {
        let groups = AppGrouping.group([p(1, "com.google.Chromecast")], runningApps: apps,
                                       excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups[0].key, "com.google.Chromecast")
        XCTAssertEqual(groups[0].name, "Chromecast")
    }

    func testProcessesWithoutBundleIDUseExecutableName() {
        let groups = AppGrouping.group([p(1, "", "afplay")], runningApps: apps, excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups[0].key, "exe:afplay")
        XCTAssertEqual(groups[0].name, "afplay")
        XCTAssertNil(groups[0].bundleID)
    }

    func testExclusionsAndSorting() {
        let groups = AppGrouping.group([p(1, "com.spotify.client"), p(2, "com.northbuiltlabs.equinox"), p(3, "com.google.Chrome"),
                                        p(4, "", "self", pid: 5000)],
                                       runningApps: apps, excludingBundleIDs: ["com.northbuiltlabs.equinox"], excludingPIDs: [5004])
        XCTAssertEqual(groups.map(\.name), ["Google Chrome", "Spotify"])
    }

    func testResponsibleAppOwnsOutOfTreeHelper() {
        let safari = RunningAppInfo(bundleID: "com.apple.Safari", name: "Safari", pid: 500)
        let gpu = AudioProcessInfo(objectID: 7, pid: 900, bundleID: "com.apple.WebKit.GPU", executableName: "GPU",
                                   isRunningOutput: true, responsiblePID: 500)
        let groups = AppGrouping.group([gpu], runningApps: apps + [safari], excludingBundleIDs: [], excludingPIDs: [])
        XCTAssertEqual(groups.map(\.key), ["com.apple.Safari"])
        XCTAssertEqual(groups[0].name, "Safari")
    }
}
