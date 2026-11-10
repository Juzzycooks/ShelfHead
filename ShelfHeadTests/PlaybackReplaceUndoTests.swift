import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden + clarify): replace-with-undo, Up Next removal undo, the
/// mini player's long-press menu and shared sleep line, and bookmark / Library wording.
@MainActor
final class PlaybackReplaceUndoTests: XCTestCase {

    // MARK: Replace with undo

    func testNothingLoadedIsNotAReplacement() {
        XCTAssertFalse(PlayerViewModel.offersReplaceUndo(currentId: nil, currentIsPodcast: false,
                                                         currentEpisodeId: nil, newId: "b", newEpisodeId: nil))
    }

    func testSameBookIsNotAReplacement() {
        XCTAssertFalse(PlayerViewModel.offersReplaceUndo(currentId: "a", currentIsPodcast: false,
                                                         currentEpisodeId: nil, newId: "a", newEpisodeId: nil))
    }

    func testDifferentBookIsAReplacement() {
        XCTAssertTrue(PlayerViewModel.offersReplaceUndo(currentId: "a", currentIsPodcast: false,
                                                        currentEpisodeId: nil, newId: "b", newEpisodeId: nil))
    }

    func testAnotherEpisodeOfTheSameShowIsAReplacement() {
        XCTAssertTrue(PlayerViewModel.offersReplaceUndo(currentId: "pod", currentIsPodcast: true,
                                                        currentEpisodeId: "e1", newId: "pod", newEpisodeId: "e2"))
        XCTAssertFalse(PlayerViewModel.offersReplaceUndo(currentId: "pod", currentIsPodcast: true,
                                                         currentEpisodeId: "e1", newId: "pod", newEpisodeId: "e1"))
    }

    /// A podcast restored after a relaunch has no known episode, so Undo couldn't put the
    /// right one back: no offer rather than a wrong one.
    func testUnknownLoadedEpisodeGetsNoOffer() {
        XCTAssertFalse(PlayerViewModel.offersReplaceUndo(currentId: "pod", currentIsPodcast: true,
                                                         currentEpisodeId: nil, newId: "book", newEpisodeId: nil))
    }

    func testReplaceCopy() {
        XCTAssertEqual(PlayerViewModel.replaceUndoMessage(previousTitle: "Dune"), "Playing instead of Dune")
        XCTAssertEqual(PlayerViewModel.playsInsteadSubtitle(loadedTitle: "Dune"), "Plays instead of Dune")
        XCTAssertNil(PlayerViewModel.playsInsteadSubtitle(loadedTitle: nil))
        XCTAssertNil(PlayerViewModel.playsInsteadSubtitle(loadedTitle: "  "))
    }

    // MARK: Up Next removal undo

    func testQueueReinsertIndexClampsToTheCurrentQueue() {
        XCTAssertEqual(PlayerViewModel.queueReinsertIndex(original: 2, count: 5), 2)
        XCTAssertEqual(PlayerViewModel.queueReinsertIndex(original: 4, count: 2), 2)
        XCTAssertEqual(PlayerViewModel.queueReinsertIndex(original: -1, count: 3), 0)
        XCTAssertEqual(PlayerViewModel.queueReinsertIndex(original: 0, count: 0), 0)
    }

    func testQueueRemovalCopy() {
        XCTAssertEqual(PlayerViewModel.queueRemovalMessage(title: "Dune"), "Removed Dune from Up Next")
    }

    // MARK: Mini player

    func testLongPressMenuStopMatchesTheVoiceOverAction() {
        XCTAssertEqual(MiniPlayerStatus.stopMenuTitle, "Stop Playback")
    }

    func testMenuSleepStatusHasNoCountdown() {
        XCTAssertNil(MiniPlayerStatus.menuSleepStatus(option: .off))
        XCTAssertEqual(MiniPlayerStatus.menuSleepStatus(option: .minutes(15)), "Sleep timer on")
        XCTAssertEqual(MiniPlayerStatus.menuSleepStatus(option: .endOfChapter), "Sleeps at end of chapter")
    }

    /// The chapter remainder is media time; at 1.5× a 15-minute chapter tail is a 10-minute wait.
    func testEndOfChapterCountdownIsWallClock() {
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfChapter, remaining: 0,
                                                  chapterRemaining: 900, rate: 1.5), "Sleeps in 10:00")
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfChapter, remaining: 0,
                                                  chapterRemaining: 900, rate: 1), "Sleeps in 15:00")
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfChapter, remaining: 0,
                                                  chapterRemaining: 600, rate: 0.5), "Sleeps in 20:00")
        let line = MiniPlayerStatus.line(isStalled: false, isStreaming: false, sleepOption: .endOfChapter,
                                         sleepRemaining: 0, chapterRemaining: 900, author: "A",
                                         playbackRate: 2)
        XCTAssertEqual(line.full, "Sleeps in 7:30")
    }

    /// The minutes timer already counts wall-clock time, so speed doesn't change it.
    func testMinutesCountdownIgnoresRate() {
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .minutes(15), remaining: 600, rate: 2), "Sleeps in 10:00")
    }

    // MARK: Wording

    func testBookmarkVocabulary() {
        XCTAssertEqual(BookmarksSheet.addFieldPlaceholder, "Title (optional)")
        XCTAssertEqual(BookDetailView.editBookmarkTitle, "Edit Bookmark")
        XCTAssertEqual(BookDetailView.bookmarksLoadFailedText, "Couldn\u{2019}t load bookmarks")
        XCTAssertFalse(BookDetailView.bookmarksEmptyMessage.isEmpty)
    }

    func testLibraryFinishedToggleMatchesBookDetail() {
        XCTAssertEqual(LibraryView.finishedToggleTitle(finished: true), "Mark as Not Finished")
        XCTAssertEqual(LibraryView.finishedToggleTitle(finished: false), "Mark as Finished")
    }

    func testPlayerTitleSizeIsCapped() {
        XCTAssertEqual(PlayerView.cappedTransportMetric(19, base: 19), 19)
        XCTAssertEqual(PlayerView.cappedTransportMetric(60, base: 19), 19 * 1.4, accuracy: 0.001)
    }
}
