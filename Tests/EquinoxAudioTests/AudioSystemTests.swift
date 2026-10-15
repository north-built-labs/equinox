import XCTest
import CoreAudio
@testable import EquinoxAudio

final class AudioSystemTests: XCTestCase {
    func testExclusionListRejectsUnknown() {
        XCTAssertThrowsError(try AudioSystem.validatedExclusions([AudioObjectID(kAudioObjectUnknown)]))
        XCTAssertThrowsError(try AudioSystem.validatedExclusions([]))
        XCTAssertEqual(try AudioSystem.validatedExclusions([42]), [42])
    }

    func testListsAtLeastOneOutputDeviceWithUID() throws {
        let devices = AudioSystem.outputDevices()
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        let defaultID = try AudioSystem.defaultOutputDevice()
        XCTAssertGreaterThan(try AudioSystem.nominalSampleRate(defaultID), 0)
    }

    func testResolvesOwnProcessObject() throws {
        _ = AudioSystem.outputDevices()   // ensure we are a HAL client
        XCTAssertNotEqual(try AudioSystem.processObject(forPID: getpid()), AudioObjectID(kAudioObjectUnknown))
    }

    func testListsOwnAudioProcess() {
        _ = AudioSystem.outputDevices()
        let own = AudioSystem.audioProcesses().first { $0.pid == getpid() }
        XCTAssertNotNil(own)
        XCTAssertFalse(own!.executableName.isEmpty)
    }
}
