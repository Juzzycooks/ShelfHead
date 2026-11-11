import XCTest
@testable import ShelfHead_Watch

/// Batch 490 (REVIEW 2026-11-11 W5, W8, W9, W14, F29): the Watch player quick wins. The
/// views and the engine aren't driven here; the decisions they call are.
@MainActor
final class QuickWinsWatchPlayerTests: XCTestCase {

    // MARK: - W8: one haptic per action

    func testRoutineCommandRepliesPlayNoSuccessHaptic() {
        let routine: [WatchCommandKind] = [
            .playPause, .play, .pause, .rewind(seconds: 15), .forward(seconds: 30), .seek(time: 10),
            .seekToChapter(chapterId: 1, startTime: 60), .seekToBookmark(time: 5),
            .setPlaybackSpeed(rate: 1.5), .setSleepTimer(option: .minutes(15)), .extendSleepTimer(seconds: 900),
        ]
        for kind in routine {
            XCTAssertNil(WatchFeedbackHaptic.forReply(to: kind, ok: true), "\(kind)")
            XCTAssertEqual(WatchFeedbackHaptic.forReply(to: kind, ok: false), .failure, "\(kind)")
        }
    }

    func testOutcomesTheListenerWaitsOnKeepSuccess() {
        for kind: WatchCommandKind in [.markFinished, .markItemFinished(itemId: "li_1"), .playItem(itemId: "li_1")] {
            XCTAssertEqual(WatchFeedbackHaptic.forReply(to: kind, ok: true), .success, "\(kind)")
            XCTAssertEqual(WatchFeedbackHaptic.forReply(to: kind, ok: false), .failure, "\(kind)")
        }
    }

    /// The bookmark's one haptic comes from its outcome UI, so the reply plays none either way.
    func testBookmarkAndSnapshotRepliesPlayNothing() {
        for ok in [true, false] {
            XCTAssertNil(WatchFeedbackHaptic.forReply(to: .addBookmark, ok: ok))
            XCTAssertNil(WatchFeedbackHaptic.forReply(to: .requestSnapshot, ok: ok))
        }
    }

    func testBookmarkOutcomeHaptic() {
        XCTAssertNil(WatchFeedbackHaptic.forBookmark(.saving))
        XCTAssertEqual(WatchFeedbackHaptic.forBookmark(.saved), .success)
        XCTAssertEqual(WatchFeedbackHaptic.forBookmark(.savedOffline), .success)
        XCTAssertEqual(WatchFeedbackHaptic.forBookmark(.failed), .failure)
    }

    // MARK: - W9: Crown scrub timing

    func testCrownScrubKeepsDebounceAndReleasesAfterThreeIdleSeconds() {
        XCTAssertEqual(WatchCrownScrub.seekDebounce, 0.35, accuracy: 0.0001)
        XCTAssertEqual(WatchCrownScrub.releaseAfterIdle, 3, accuracy: 0.0001)
        XCTAssertGreaterThan(WatchCrownScrub.releaseAfterIdle, WatchCrownScrub.seekDebounce)
        XCTAssertEqual(WatchCrownScrub.nanoseconds(0.35), 350_000_000)
        XCTAssertEqual(WatchCrownScrub.nanoseconds(-1), 0)
    }

    // MARK: - W5: standalone Now Playing follows the engine

    func testFollowsADifferentBookTheEngineLoaded() {
        XCTAssertTrue(StandaloneNowPlayingFollow.shouldFollow(
            shownItemId: "a", previousLoadedItemId: "a", newLoadedItemId: "b", isLoaded: true, isConfirming: false))
    }

    func testDoesNotFollowItsOwnBookNothingOrWhileAsking() {
        XCTAssertFalse(StandaloneNowPlayingFollow.shouldFollow(
            shownItemId: "a", previousLoadedItemId: nil, newLoadedItemId: "a", isLoaded: true, isConfirming: false))
        XCTAssertFalse(StandaloneNowPlayingFollow.shouldFollow(
            shownItemId: "a", previousLoadedItemId: "a", newLoadedItemId: nil, isLoaded: false, isConfirming: false))
        XCTAssertFalse(StandaloneNowPlayingFollow.shouldFollow(
            shownItemId: "a", previousLoadedItemId: "a", newLoadedItemId: "b", isLoaded: false, isConfirming: false))
        XCTAssertFalse(StandaloneNowPlayingFollow.shouldFollow(
            shownItemId: "a", previousLoadedItemId: "c", newLoadedItemId: "b", isLoaded: true, isConfirming: true))
        XCTAssertFalse(StandaloneNowPlayingFollow.shouldFollow(
            shownItemId: "a", previousLoadedItemId: "b", newLoadedItemId: "b", isLoaded: true, isConfirming: false))
    }

    // MARK: - F29: Add 15 Minutes

    func testExtendOnlyForARunningCountdown() {
        XCTAssertEqual(WatchSleepExtend.seconds, 900)
        XCTAssertTrue(WatchSleepExtend.isAvailable(option: .minutes(15), secondsLeft: 600))
        XCTAssertFalse(WatchSleepExtend.isAvailable(option: .minutes(15), secondsLeft: 0))
        XCTAssertFalse(WatchSleepExtend.isAvailable(option: .minutes(15), secondsLeft: nil))
        XCTAssertFalse(WatchSleepExtend.isAvailable(option: .endOfChapter, secondsLeft: 600))
        XCTAssertFalse(WatchSleepExtend.isAvailable(option: .off, secondsLeft: 600))
        XCTAssertFalse(WatchSleepExtend.isAvailable(option: nil, secondsLeft: 600))
    }

    func testStandaloneTimerExtendsCountdownAndKeepsItsPreset() throws {
        var timer = try XCTUnwrap(StandaloneSleepTimer.minutes(15))
        timer.tick(seconds: 600)
        let extended = try XCTUnwrap(timer.extended(by: 900))
        XCTAssertEqual(extended.secondsLeft(currentTime: 0), 1200, accuracy: 0.001)
        XCTAssertEqual(extended.option, .minutes(15))
        XCTAssertNil(timer.extended(by: 0))
    }

    func testStandaloneEndOfChapterTimerIsNotExtended() throws {
        let chapters = try JSONDecoder().decode([WatchChapter].self, from: Data(#"[{"id":0,"start":0,"end":600,"title":"One"}]"#.utf8))
        let timer = try XCTUnwrap(StandaloneSleepTimer.endOfChapter(chapters: chapters, at: 100))
        XCTAssertNil(timer.extended(by: 900))
    }

    /// The new command is additive: older cases keep their wire shape, the new one
    /// round-trips, and a decoder that doesn't know a case (an older phone) refuses it
    /// rather than misreading it.
    func testExtendSleepTimerCommandIsBackwardCompatible() throws {
        let kind = WatchCommandKind.extendSleepTimer(seconds: 900)
        let data = try JSONEncoder().encode(kind)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["extendSleepTimer"] as? [String: Any])?["seconds"] as? Double, 900)
        XCTAssertEqual(try JSONDecoder().decode(WatchCommandKind.self, from: data), kind)

        XCTAssertEqual(try JSONDecoder().decode(WatchCommandKind.self, from: Data(#"{"addBookmark":{}}"#.utf8)), .addBookmark)
        XCTAssertEqual(try JSONDecoder().decode(WatchCommandKind.self, from: Data(#"{"setSleepTimer":{"option":{"minutes":{"_0":15}}}}"#.utf8)),
                       .setSleepTimer(option: .minutes(15)))
        XCTAssertThrowsError(try JSONDecoder().decode(WatchCommandKind.self, from: Data(#"{"someFutureCommand":{}}"#.utf8)))

        XCTAssertFalse(kind.isPositionDependent)
        XCTAssertTrue(kind.requiresActiveItem)
    }

    // MARK: - F29: chapter skip from the system controls

    func testNextChapterTarget() {
        let starts: [Double] = [0, 600, 1200]
        XCTAssertEqual(WatchChapterNavigation.nextTarget(chapterStarts: starts, bookEnd: 1800, currentTime: 100), 600)
        // Within half a second of a start counts as already there.
        XCTAssertEqual(WatchChapterNavigation.nextTarget(chapterStarts: starts, bookEnd: 1800, currentTime: 599.8), 1200)
        XCTAssertEqual(WatchChapterNavigation.nextTarget(chapterStarts: starts, bookEnd: 1800, currentTime: 1300), 1800)
        XCTAssertNil(WatchChapterNavigation.nextTarget(chapterStarts: starts, bookEnd: 1800, currentTime: 1799.8))
    }

    func testPreviousChapterRestartsAfterThreeSecondsOtherwiseGoesBack() {
        let starts: [Double] = [0, 600, 1200]
        XCTAssertEqual(WatchChapterNavigation.previousTarget(chapterStarts: starts, currentTime: 700), 600)
        XCTAssertEqual(WatchChapterNavigation.previousTarget(chapterStarts: starts, currentTime: 602), 0)
        XCTAssertEqual(WatchChapterNavigation.previousTarget(chapterStarts: starts, currentTime: 1201), 600)
        XCTAssertEqual(WatchChapterNavigation.previousTarget(chapterStarts: starts, currentTime: 2), 0)
        XCTAssertEqual(WatchChapterNavigation.previousTarget(chapterStarts: starts, currentTime: 100), 0)
    }

    func testChapterCommandsOnlyForStandaloneWithChapters() {
        XCTAssertTrue(WatchRemoteCommandRouter.chapterCommandsEnabled(owner: .standalone, standaloneCanSkipChapters: true))
        XCTAssertFalse(WatchRemoteCommandRouter.chapterCommandsEnabled(owner: .standalone, standaloneCanSkipChapters: false))
        XCTAssertFalse(WatchRemoteCommandRouter.chapterCommandsEnabled(owner: .companion, standaloneCanSkipChapters: true))
    }

    // MARK: - F29: buffering ring

    func testBufferingRingOnlyForAStalledStream() {
        XCTAssertTrue(StandaloneBufferingDecision.showsBuffering(isStreaming: true, isWaitingToPlay: true))
        XCTAssertFalse(StandaloneBufferingDecision.showsBuffering(isStreaming: true, isWaitingToPlay: false))
        XCTAssertFalse(StandaloneBufferingDecision.showsBuffering(isStreaming: false, isWaitingToPlay: true))
        XCTAssertFalse(StandaloneBufferingDecision.showsBuffering(isStreaming: false, isWaitingToPlay: false))
    }

    // MARK: - W14: the complication after Stop

    func testStoppedComplicationSnapshotIsNotPlaying() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let snapshot = try XCTUnwrap(WatchComplicationSnapshot.stopped(
            title: "Dune", author: "Frank Herbert", currentTime: 7200, duration: 7200, at: date))
        XCTAssertFalse(snapshot.isPlaying)
        XCTAssertEqual(snapshot.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.title, "Dune")
        XCTAssertEqual(snapshot.updatedAt, date)
        XCTAssertNil(WatchComplicationSnapshot.stopped(title: "", author: "", currentTime: 0, duration: 0, at: date))
    }
}
