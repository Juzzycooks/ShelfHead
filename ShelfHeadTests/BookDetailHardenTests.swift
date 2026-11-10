import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): Book Detail's ••• menu notes, the podcast episode row's
/// VoiceOver label, and All Bookmarks' jump, which now reuses Book Detail's seek gate.
@MainActor
final class BookDetailHardenTests: XCTestCase {

    // MARK: All Bookmarks jump (reuses `chapterTapAction` / `shouldSeekAfterStart`)

    func testJumpWithinTheLoadedBookSeeksThroughTheUndoPath() {
        XCTAssertEqual(BookDetailView.chapterTapAction(isThisBookLoaded: true, isAwaitingResume: false),
                       .seekThenOpenPlayer)
    }

    func testJumpToAnotherBookThatDidNotStartLeavesTheLoadedBookAlone() {
        // `startPlayback` returned early (cellular off, offline and not downloaded): book B is
        // still loaded, so the bookmark's time must not be applied to it.
        XCTAssertEqual(BookDetailView.chapterTapAction(isThisBookLoaded: false, isAwaitingResume: false),
                       .startThenSeek)
        XCTAssertFalse(BookDetailView.shouldSeekAfterStart(loadedBookId: "B", itemId: "A", isAwaitingResume: false))
        XCTAssertTrue(BookDetailView.shouldSeekAfterStart(loadedBookId: "A", itemId: "A", isAwaitingResume: false))
    }

    // MARK: ••• menu notes

    func testSeriesNotesAreCalm() {
        XCTAssertEqual(BookDetailView.noNextInSeriesNotice, "Couldn\u{2019}t find a next book in this series.")
    }

    // MARK: Podcast episode row VoiceOver

    func testEpisodeLabelReadsDateDurationAndProgress() {
        XCTAssertEqual(
            PodcastEpisodeRow.accessibilityLabel(title: "Episode 12", date: "3 Oct 2026", duration: 2520,
                                                 progress: 0.3, isFinished: false),
            "Episode 12, 3 Oct 2026, 42 minutes, 30 percent played")
    }

    func testFinishedEpisodeSaysFinishedNotAPercentage() {
        XCTAssertEqual(
            PodcastEpisodeRow.accessibilityLabel(title: "Ep", date: nil, duration: 3900, progress: 1, isFinished: true),
            "Ep, 1 hour 5 minutes, Finished")
    }

    func testUnplayedEpisodeWithNoMetadata() {
        XCTAssertEqual(
            PodcastEpisodeRow.accessibilityLabel(title: nil, date: nil, duration: nil, progress: nil, isFinished: false),
            "Untitled episode")
        XCTAssertEqual(
            PodcastEpisodeRow.accessibilityLabel(title: "Ep", date: "", duration: 0, progress: 0, isFinished: false),
            "Ep")
    }

    func testSpokenDuration() {
        XCTAssertEqual(PodcastEpisodeRow.spokenDuration(30), "less than a minute")
        XCTAssertEqual(PodcastEpisodeRow.spokenDuration(60), "1 minute")
        XCTAssertEqual(PodcastEpisodeRow.spokenDuration(7200), "2 hours")
        XCTAssertEqual(PodcastEpisodeRow.spokenDuration(3660), "1 hour 1 minute")
    }
}
