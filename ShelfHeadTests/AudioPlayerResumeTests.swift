import XCTest
@testable import ShelfHead

/// Pins the three pure decisions extracted while fixing the resume/skip/sleep-timer
/// defects in `AudioPlayerService` (fix plan item 6 of REVIEW-2026-09-09.md):
///
/// - `clampedSeekTarget` (6.C) — a skip that clamped against a `duration` of 0 and
///   therefore seeked to 0:00, then synced that to the server.
/// - `chapterSleepTarget` (6.F) — an "end of chapter" timer that armed against chapter
///   0's end whenever the position fell outside every chapter range, so it paused
///   playback on the very next tick.
/// - `shouldRetargetPendingSeek` (6.B) — a user seek made while the player item was
///   still loading being silently rewound to the resume point the track was loaded
///   with.
///
/// Same precedent as `NowPlayingChapterRepublishTests` /
/// `CarPlayListWindowingTests`: the stateful parts (the actual `AVPlayer`, the
/// `pendingItemStart` lifecycle, the `timeControlStatus` reconciliation) can't be
/// exercised without a live player and real media, so what gets pinned here is the
/// decision each of them turns on.
final class AudioPlayerResumeTests: XCTestCase {

    /// `Chapter` declares `init(from:)` inside the struct, so there's no memberwise
    /// initializer to call — build them through the same plain `JSONDecoder()` the app
    /// decodes sessions with (see `UserProgressDecodingTests` for the same approach).
    private func chapters(_ ranges: [(Double, Double)]) throws -> [Chapter] {
        let objects: [[String: Any]] = ranges.enumerated().map { index, range in
            ["id": index, "start": range.0, "end": range.1, "title": "Chapter \(index + 1)"]
        }
        let data = try JSONSerialization.data(withJSONObject: objects)
        return try JSONDecoder().decode([Chapter].self, from: data)
    }

    // MARK: - 6.C: clampedSeekTarget

    func testSkipForwardClampsToDurationWhenKnown() {
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 3_500, delta: 30, duration: 3_600),
            3_530, accuracy: 0.001)
        // Within one skip interval of the end: clamp, don't overshoot.
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 3_590, delta: 30, duration: 3_600),
            3_600, accuracy: 0.001)
    }

    /// The actual bug: an offline manifest session / podcast episode with no reported
    /// duration made `min(currentTime + amount, duration)` evaluate to 0, so one tap of
    /// the +30s button (or its lock-screen/CarPlay/AirPods equivalent) threw the
    /// listener back to the start of the book — and the next `syncProgress()` wrote
    /// that 0 to the server.
    func testUnknownDurationDoesNotCollapseASkipToZero() {
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 1_800, delta: 30, duration: 0),
            1_830, accuracy: 0.001)
        // A negative/absent duration is treated the same way as 0 — unknown.
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 1_800, delta: 30, duration: -1),
            1_830, accuracy: 0.001)
    }

    func testSkipBackwardFloorsAtZeroWithOrWithoutADuration() {
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 10, delta: -30, duration: 3_600),
            0, accuracy: 0.001)
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 10, delta: -30, duration: 0),
            0, accuracy: 0.001)
        XCTAssertEqual(
            AudioPlayerService.clampedSeekTarget(current: 600, delta: -30, duration: 0),
            570, accuracy: 0.001)
    }

    // MARK: - 6.F: chapterSleepTarget

    func testEndOfChapterTargetsTheContainingChaptersEnd() throws {
        let list = try chapters([(0, 100), (100, 250), (250, 400)])
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 150, extraChapters: 0),
            250)
    }

    func testExtraChaptersCountForwardAndClampToTheLastChapter() throws {
        let list = try chapters([(0, 100), (100, 250), (250, 400)])
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 50, extraChapters: 1),
            250)
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 50, extraChapters: 2),
            400)
        // More chapters requested than remain: stop at the end of the last one rather
        // than falling off the end of the array.
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 50, extraChapters: 99),
            400)
        // A negative count can't walk backwards into an already-passed boundary.
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 300, extraChapters: -5),
            400)
    }

    /// The bug: `firstIndex(where:) ?? 0`. A position inside a gap between two chapters
    /// (or before the first one) resolved to chapter 0, whose end is in the past, so
    /// `updateCurrentTime` paused playback within half a second of the user choosing
    /// "End of chapter". It now counts from the next chapter that still ends ahead.
    func testAPositionInAGapBetweenChaptersUsesTheNextChapterAhead() throws {
        let list = try chapters([(0, 100), (120, 250), (250, 400)])
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 110, extraChapters: 0),
            250)
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 110, extraChapters: 1),
            400)
    }

    func testAPositionBeforeTheFirstChapterUsesTheFirstChapter() throws {
        let list = try chapters([(30, 100), (100, 250)])
        XCTAssertEqual(
            AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 10, extraChapters: 0),
            100)
    }

    /// Past the last chapter's end — a book whose chapter list doesn't quite cover its
    /// runtime, which is the ordinary state at the very end of a listen. There is no
    /// boundary ahead to stop at, so this must report "can't arm" instead of handing
    /// back a target in the past.
    func testAPositionPastEveryChapterCannotArm() throws {
        let list = try chapters([(0, 100), (100, 250)])
        XCTAssertNil(AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 250, extraChapters: 0))
        XCTAssertNil(AudioPlayerService.chapterSleepTarget(chapters: list, currentTime: 900, extraChapters: 2))
    }

    func testNoChapterDataCannotArm() {
        XCTAssertNil(AudioPlayerService.chapterSleepTarget(chapters: [], currentTime: 0, extraChapters: 0))
        XCTAssertNil(AudioPlayerService.chapterSleepTarget(chapters: [], currentTime: 500, extraChapters: 3))
    }

    /// Every target this hands back has to be strictly ahead of `currentTime` — that's
    /// the entire contract, since a target at-or-behind the position is what made the
    /// timer fire immediately.
    func testEveryReturnedTargetIsAheadOfTheCurrentPosition() throws {
        let list = try chapters([(0, 100), (100, 250), (250, 400), (400, 401)])
        for time in stride(from: 0.0, through: 420.0, by: 7.0) {
            for extra in 0...3 {
                guard let target = AudioPlayerService.chapterSleepTarget(
                    chapters: list, currentTime: time, extraChapters: extra) else { continue }
                XCTAssertGreaterThan(target, time, "target \(target) at time \(time), +\(extra) chapters")
            }
        }
    }

    // MARK: - 6.B: shouldRetargetPendingSeek

    func testNoRetargetWhenTheSeekLandedWhereItWasAsked() {
        XCTAssertFalse(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 900, desiredOffset: 900, attempts: 0))
        // Inside the 1s tolerance the seek was issued with.
        XCTAssertFalse(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 900, desiredOffset: 900.4, attempts: 0))
    }

    func testNoRetargetWhenNothingIsOwedAnyMore() {
        XCTAssertFalse(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 900, desiredOffset: nil, attempts: 0))
    }

    /// The bug: the user scrubbed (or skipped, or tapped a chapter) while the item was
    /// still loading, so the position they asked for is no longer the position the
    /// in-flight resume seek was aimed at. Re-issue, rather than declaring the resume
    /// point reached and leaving them where they didn't ask to be.
    func testRetargetsWhenAUserSeekMovedTheTargetWhileTheSeekWasInFlight() {
        XCTAssertTrue(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 900, desiredOffset: 1_500, attempts: 0))
        XCTAssertTrue(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 900, desiredOffset: 30, attempts: 2))
    }

    func testRetargetGivesUpAfterTheAttemptCap() {
        XCTAssertTrue(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 0, desiredOffset: 1_000, attempts: 3))
        XCTAssertFalse(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 0, desiredOffset: 1_000, attempts: 4))
        XCTAssertFalse(AudioPlayerService.shouldRetargetPendingSeek(
            seekedOffset: 0, desiredOffset: 1_000, attempts: 99))
    }
}
