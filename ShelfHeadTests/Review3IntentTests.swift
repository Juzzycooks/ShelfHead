import XCTest
@testable import ShelfHead

// Review 3 Medium 4: Siri skip / sleep timer when audio was started elsewhere (CarPlay, background)
// and `currentBook` hasn't been adopted yet.
final class Review3IntentTests: XCTestCase {
    func testLiveSessionSkipsEvenWithoutBook() {
        XCTAssertEqual(PlaybackCoordinator.skipAction(hasBook: false, isAwaitingResume: false,
                                                      allowColdStart: false, hasLiveSession: true), .skip)
    }

    func testNoSessionNoBookStillNothingPlaying() {
        XCTAssertEqual(PlaybackCoordinator.skipAction(hasBook: false, isAwaitingResume: false,
                                                      allowColdStart: false), .nothingPlaying)
    }

    func testRestoredBookWithoutSessionNeverStartsFromSiri() {
        XCTAssertEqual(PlaybackCoordinator.skipAction(hasBook: true, isAwaitingResume: true,
                                                      allowColdStart: false), .needsPlayFirst)
    }

    func testSleepTimerArmsOnLiveSessionWithoutBook() {
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: true, hasBook: false,
                                                                   isAwaitingResume: false, defaultMinutes: 20,
                                                                   hasLiveSession: true), .arm(minutes: 20))
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: false, hasBook: false,
                                                                   isAwaitingResume: false, defaultMinutes: 20,
                                                                   hasLiveSession: true), .disarm)
    }

    func testSleepTimerNoOpWithoutSession() {
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: true, hasBook: false,
                                                                   isAwaitingResume: false, defaultMinutes: 20), .none)
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: true, hasBook: true,
                                                                   isAwaitingResume: true, defaultMinutes: 20), .none)
    }
}
