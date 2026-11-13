import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 Y2, Y3, Y5): the pure decisions behind Siri's background
/// "Play ‹book›", the intent-scoped Live Activity start, and the pinned widget's Play disc.
@MainActor
final class Batch495SystemTests: XCTestCase {

    // MARK: - Y2: BackgroundPlayOutcome.decide

    func testPlayingWhenRequestedBookIsLiveAndPlaying() {
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: "a", isPlaying: true,
                                                    workFinished: true, startBegun: true), .playing)
        // Playing counts even when the bound expired before the work returned.
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: "a", isPlaying: true,
                                                    workFinished: false, startBegun: true), .playing)
    }

    func testAnotherBookPlayingIsNotSuccess() {
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: "b", isPlaying: true,
                                                    workFinished: true, startBegun: true), .couldNotStart)
    }

    func testRequestedBookLoadedButPausedAfterFinishedWorkCouldNotStart() {
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: "a", isPlaying: false,
                                                    workFinished: true, startBegun: true), .couldNotStart)
    }

    func testStillStartingWhenBoundExpiredAfterLoadingBegan() {
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: nil, isPlaying: false,
                                                    workFinished: false, startBegun: true), .stillStarting)
    }

    func testCouldNotStartWhenBoundExpiredBeforeLoadingBegan() {
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: nil, isPlaying: false,
                                                    workFinished: false, startBegun: false), .couldNotStart)
    }

    func testCouldNotStartWhenNothingPlays() {
        XCTAssertEqual(BackgroundPlayOutcome.decide(requestedItemId: "a", liveItemId: nil, isPlaying: false,
                                                    workFinished: true, startBegun: false), .couldNotStart)
    }

    // MARK: - Y2: PlayBookIntentError.forOutcome

    func testPlayingThrowsNothing() {
        XCTAssertNil(PlayBookIntentError.forOutcome(.playing, title: "Dune"))
    }

    func testFailuresMapToTheirErrors() {
        XCTAssertEqual(PlayBookIntentError.forOutcome(.stillStarting, title: "Dune"), .stillStarting(title: "Dune"))
        XCTAssertEqual(PlayBookIntentError.forOutcome(.couldNotStart, title: "Dune"), .couldNotStart(title: "Dune"))
    }

    // MARK: - Y3: LiveActivityController.mayRequestActivity

    func testInsideLiveActivityIntentMayRequestFromBackground() {
        let now = Date()
        XCTAssertTrue(LiveActivityController.mayRequestActivity(isInBackground: true, insideLiveActivityIntent: true,
                                                                lastRefusedAt: now, now: now))
    }

    func testBackgroundOutsideIntentMayNotRequest() {
        XCTAssertFalse(LiveActivityController.mayRequestActivity(isInBackground: true, insideLiveActivityIntent: false,
                                                                 lastRefusedAt: nil, now: Date()))
    }

    func testForegroundRespectsRetryInterval() {
        let now = Date()
        XCTAssertTrue(LiveActivityController.mayRequestActivity(isInBackground: false, insideLiveActivityIntent: false,
                                                                lastRefusedAt: nil, now: now))
        XCTAssertFalse(LiveActivityController.mayRequestActivity(isInBackground: false, insideLiveActivityIntent: false,
                                                                 lastRefusedAt: now.addingTimeInterval(-1), now: now,
                                                                 retryInterval: 60))
        XCTAssertTrue(LiveActivityController.mayRequestActivity(isInBackground: false, insideLiveActivityIntent: false,
                                                                lastRefusedAt: now.addingTimeInterval(-61), now: now,
                                                                retryInterval: 60))
    }

    // MARK: - Y5: PinnedPlayRequest

    func testMakeRejectsBlankIdAndTrims() {
        let now = Date()
        XCTAssertNil(PinnedPlayRequest.make(itemId: "  ", now: now))
        XCTAssertEqual(PinnedPlayRequest.make(itemId: " li_1 ", now: now, token: "t"),
                       PinnedPlayRequest.Request(token: "t", itemId: "li_1", requestedAt: now))
    }

    func testFreshnessWindow() {
        let now = Date()
        let request = PinnedPlayRequest.Request(token: "t", itemId: "x", requestedAt: now)
        XCTAssertTrue(PinnedPlayRequest.isFresh(request, now: now))
        XCTAssertTrue(PinnedPlayRequest.isFresh(request, now: now.addingTimeInterval(15), maxAge: 15))
        XCTAssertFalse(PinnedPlayRequest.isFresh(request, now: now.addingTimeInterval(16), maxAge: 15))
        // A clock skew of under a second between processes is tolerated; a far-future stamp isn't.
        XCTAssertTrue(PinnedPlayRequest.isFresh(request, now: now.addingTimeInterval(-0.5)))
        XCTAssertFalse(PinnedPlayRequest.isFresh(request, now: now.addingTimeInterval(-5)))
    }

    func testOutcomeParsingMatchesToken() {
        XCTAssertEqual(PinnedPlayRequest.outcome(fromStored: "t1|playing", token: "t1"), .playing)
        XCTAssertEqual(PinnedPlayRequest.outcome(fromStored: "t1|failed", token: "t1"), .failed)
        XCTAssertNil(PinnedPlayRequest.outcome(fromStored: "t2|playing", token: "t1"))
        XCTAssertNil(PinnedPlayRequest.outcome(fromStored: nil, token: "t1"))
        XCTAssertNil(PinnedPlayRequest.outcome(fromStored: "t1", token: "t1"))
        XCTAssertNil(PinnedPlayRequest.outcome(fromStored: "t1|unknown", token: "t1"))
    }
}
