// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and every sibling test
// file in this target.
//
// Pins `StandaloneAudioEngine.seekPlan(...)`, the pure decision behind Item 20 (9
// September 2026 review): a backward cross-track seek (crown scrub or skip-back
// across a file boundary on a one-file-per-chapter book) used to clamp to the start
// of whatever track the `AVQueuePlayer` was still sitting on, because
// `advanceToNextItem()` had already dropped every earlier track from the queue.
// Following this project's stated precedent (pin the pure decision function, don't
// try to drive the stateful `AVQueuePlayer` path — see `StandaloneResumePositionTests`
// in the sibling file).
import XCTest
@testable import ShelfHead_Watch

final class StandaloneAudioEngineSeekPlanTests: XCTestCase {

    // MARK: - Within the current track

    func testTargetInCurrentTrackStaysWithinTrack() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 150, currentTrackIndex: 1, trackStarts: [0, 100, 300]),
            .withinTrack(offset: 50))
    }

    func testTargetAtCurrentTrackStartIsWithinTrackWithZeroOffset() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 100, currentTrackIndex: 1, trackStarts: [0, 100, 300]),
            .withinTrack(offset: 0))
    }

    // MARK: - Forward, still-queued track

    func testTargetInALaterTrackIsForward() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 320, currentTrackIndex: 0, trackStarts: [0, 100, 300]),
            .forwardToTrack(index: 2, offset: 20))
    }

    func testForwardByExactlyOneTrack() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 100, currentTrackIndex: 0, trackStarts: [0, 100, 300]),
            .forwardToTrack(index: 1, offset: 0))
    }

    // MARK: - Backward, dropped track — the bug this function fixes

    func testTargetInAnEarlierTrackNeedsARebuild() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 50, currentTrackIndex: 2, trackStarts: [0, 100, 300]),
            .rebuildFromTrack(index: 0, offset: 50))
    }

    func testBackwardByExactlyOneTrack() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 150, currentTrackIndex: 2, trackStarts: [0, 100, 300]),
            .rebuildFromTrack(index: 1, offset: 50))
    }

    // MARK: - Exact track boundaries

    func testExactBoundaryLandsInTheTrackThatStartsThereNotTheOneBefore() {
        // Skip-back landing precisely on track 2's start, from within track 2 itself
        // (having already advanced past it) — must not be read as still-track-1.
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 300, currentTrackIndex: 2, trackStarts: [0, 100, 300]),
            .withinTrack(offset: 0))
    }

    func testExactBoundaryFromAnEarlierTrackIsForward() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 300, currentTrackIndex: 0, trackStarts: [0, 100, 300]),
            .forwardToTrack(index: 2, offset: 0))
    }

    // MARK: - Edges: target 0, target at total duration

    func testTargetZeroFromALaterTrackRebuildsToTheFirstTrack() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 0, currentTrackIndex: 2, trackStarts: [0, 100, 300]),
            .rebuildFromTrack(index: 0, offset: 0))
    }

    func testTargetZeroAlreadyOnTheFirstTrackStaysWithinTrack() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 0, currentTrackIndex: 0, trackStarts: [0, 100, 300]),
            .withinTrack(offset: 0))
    }

    func testTargetAtTotalDurationLandsInTheLastTrack() {
        // Caller (`seekInQueue(to:)`) clamps to `duration` before calling this —
        // here that's 420, ending inside the last (300...) track.
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 420, currentTrackIndex: 0, trackStarts: [0, 100, 300]),
            .forwardToTrack(index: 2, offset: 120))
    }

    // MARK: - Single-track book

    func testSingleTrackBookIsAlwaysWithinTrack() {
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 0, currentTrackIndex: 0, trackStarts: [0]),
            .withinTrack(offset: 0))
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 1_800, currentTrackIndex: 0, trackStarts: [0]),
            .withinTrack(offset: 1_800))
        XCTAssertEqual(
            StandaloneAudioEngine.seekPlan(targetAbsolute: 3_600, currentTrackIndex: 0, trackStarts: [0]),
            .withinTrack(offset: 3_600))
    }
}
