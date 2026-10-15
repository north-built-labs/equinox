import XCTest
@testable import EquinoxAudio
import EquinoxDSP

final class ConfigMailboxTests: XCTestCase {
    /// Simulates the audio thread holding config A while the main thread posts many updates in one IO cycle.
    /// When the audio thread swaps to the newest config, A must still be owned by the main thread,
    /// so its final release (a free) never happens on the audio thread.
    func testReplacedConfigIsNotFreedByTheAudioThread() {
        let mailbox = ConfigMailbox()
        weak var weakA: DSPConfig?
        var rtCurrent: ConfigMailbox.Entry?
        autoreleasepool {
            let a = DSPConfig(settings: DSPSettings(), sampleRate: 48_000)
            weakA = a
            mailbox.post(a)
        }
        rtCurrent = mailbox.take()
        mailbox.acknowledge(rtCurrent!)
        for _ in 0..<40 { mailbox.post(DSPConfig(settings: DSPSettings(), sampleRate: 48_000)) }

        let next = mailbox.take()!      // audio thread picks up the newest
        rtCurrent = next                // ...and releases A here
        XCTAssertNotNil(weakA, "A was freed by the audio thread's release")
        mailbox.acknowledge(next)

        mailbox.post(DSPConfig(settings: DSPSettings(), sampleRate: 48_000))   // main thread retires A
        XCTAssertNil(weakA)
        _ = rtCurrent
    }
}
