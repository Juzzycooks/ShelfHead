import XCTest
@testable import ShelfHead

final class SiriSkipDecisionTests: XCTestCase {
    func testSkipActions() {
        typealias C = PlaybackCoordinator
        XCTAssertEqual(C.skipAction(hasBook: false, isAwaitingResume: false, allowColdStart: true), .nothingPlaying)
        XCTAssertEqual(C.skipAction(hasBook: true, isAwaitingResume: false, allowColdStart: false), .skip)
        XCTAssertEqual(C.skipAction(hasBook: true, isAwaitingResume: true, allowColdStart: true), .coldStart)
        XCTAssertEqual(C.skipAction(hasBook: true, isAwaitingResume: true, allowColdStart: false), .needsPlayFirst)
    }

    func testColdStartTookHold() {
        XCTAssertTrue(PlaybackCoordinator.coldStartTookHold(hasBook: true, isAwaitingResume: false, isPlaying: false))
        XCTAssertTrue(PlaybackCoordinator.coldStartTookHold(hasBook: true, isAwaitingResume: true, isPlaying: true))
        XCTAssertFalse(PlaybackCoordinator.coldStartTookHold(hasBook: true, isAwaitingResume: true, isPlaying: false))
        XCTAssertFalse(PlaybackCoordinator.coldStartTookHold(hasBook: false, isAwaitingResume: false, isPlaying: true))
    }

    func testSleepTimerErrorChoice() {
        XCTAssertEqual(PlaybackIntentError.sleepTimerError(hasBook: true).localizedStringResource.key,
                       PlaybackIntentError.pressPlayFirstForSleepTimer.localizedStringResource.key)
        XCTAssertNotEqual(PlaybackIntentError.sleepTimerError(hasBook: false).localizedStringResource.key,
                          PlaybackIntentError.pressPlayFirstForSleepTimer.localizedStringResource.key)
    }
}
