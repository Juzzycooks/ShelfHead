import XCTest
@testable import ShelfHead

/// Batch 472 (30 October 2026): pins the pure decisions behind review Medium 9 (close the
/// previous session when switching books) and Medium 19 (queued progress keeps the
/// server's finished flag).
final class SwitchBookSyncTests: XCTestCase {

    func testSwitchingToDifferentBookClosesPrevious() {
        XCTAssertTrue(AudioPlayerService.shouldCloseOutPreviousSession(
            loadedSessionId: "s1", loadedItemId: "a", newSessionId: "s2", newItemId: "b"))
    }

    func testNothingLoadedClosesNothing() {
        XCTAssertFalse(AudioPlayerService.shouldCloseOutPreviousSession(
            loadedSessionId: nil, loadedItemId: nil, newSessionId: "s2", newItemId: "b"))
    }

    func testSameSessionHandedAgainClosesNothing() {
        XCTAssertFalse(AudioPlayerService.shouldCloseOutPreviousSession(
            loadedSessionId: "s1", loadedItemId: "a", newSessionId: "s1", newItemId: "a"))
    }

    func testSameBookNewSessionClosesPrevious() {
        // Review 2 Low (Playback): a fresh session for the same book (or another episode of
        // the same podcast) still closes the old one.
        XCTAssertTrue(AudioPlayerService.shouldCloseOutPreviousSession(
            loadedSessionId: "s1", loadedItemId: "a", newSessionId: "s2", newItemId: "a"))
    }

    func testGaplessPrefetchedSessionForNextBookClosesFinishedOne() {
        XCTAssertTrue(AudioPlayerService.shouldCloseOutPreviousSession(
            loadedSessionId: "s1", loadedItemId: "a", newSessionId: "prefetched", newItemId: "next"))
    }

    func testQueuedEntryFinishedNearEnd() {
        XCTAssertTrue(AudioPlayerService.queuedEntryIsFinished(currentTime: 990, duration: 1000, serverFinished: false))
    }

    func testQueuedEntryMidBookNotFinished() {
        XCTAssertFalse(AudioPlayerService.queuedEntryIsFinished(currentTime: 300, duration: 1000, serverFinished: false))
    }

    func testQueuedEntryKeepsServerFinishedFlag() {
        XCTAssertTrue(AudioPlayerService.queuedEntryIsFinished(currentTime: 300, duration: 1000, serverFinished: true))
    }

    func testUnknownDurationFollowsServer() {
        XCTAssertFalse(AudioPlayerService.queuedEntryIsFinished(currentTime: 300, duration: 0, serverFinished: false))
        XCTAssertTrue(AudioPlayerService.queuedEntryIsFinished(currentTime: 300, duration: 0, serverFinished: true))
    }

    func testPositionRecordingSuppressedDuringMixtape() {
        XCTAssertFalse(AudioPlayerService.shouldRecordPosition(suppressed: true))
        XCTAssertTrue(AudioPlayerService.shouldRecordPosition(suppressed: false))
    }
}
