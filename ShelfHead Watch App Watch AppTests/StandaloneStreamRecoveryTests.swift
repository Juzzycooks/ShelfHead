import XCTest
@testable import ShelfHead_Watch

/// 30 Oct 2026 review (High 8): pins `StandaloneAudioEngine.streamFailureAction(...)`.
final class StandaloneStreamRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func action(streamed: Bool = true, playing: Bool = true, inFlight: Bool = false,
                        last: TimeInterval? = nil) -> StandaloneAudioEngine.StreamFailureAction {
        StandaloneAudioEngine.streamFailureAction(
            isStreamed: streamed, wasPlaying: playing, recoveryInFlight: inFlight,
            lastRecoveryAt: last.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testStreamedFirstFailureRecoversAndResumesWhenPlaying() {
        XCTAssertEqual(action(), .recover(resume: true))
    }

    func testStreamedFailureWhilePausedRecoversWithoutResuming() {
        XCTAssertEqual(action(playing: false), .recover(resume: false))
    }

    func testDownloadedItemNeverRecovers() {
        XCTAssertEqual(action(streamed: false), .ignore)
        XCTAssertEqual(action(streamed: false, last: 1), .ignore)
    }

    func testRecoveryInFlightIsIgnored() {
        XCTAssertEqual(action(inFlight: true), .ignore)
    }

    func testSecondFailureInsideWindowGivesUp() {
        XCTAssertEqual(action(last: 5), .giveUp)
    }

    func testFailureAfterWindowRecoversAgain() {
        XCTAssertEqual(action(last: 31), .recover(resume: true))
    }
}
