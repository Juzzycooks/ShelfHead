import XCTest
@testable import ShelfHead

/// Critique 2026-10-05 (Book Detail): pins the pure decisions behind the pinned bar and the
/// header title.
final class BookDetailStateTests: XCTestCase {
    // MARK: pinnedBarMode

    func testLoadedAndPlayingIsNowPlaying() {
        XCTAssertEqual(BookDetailView.pinnedBarMode(isThisBookLoaded: true, isPlaying: true, anotherBookLoaded: false), .nowPlaying)
    }

    func testLoadedAndPausedIsPausedHere() {
        XCTAssertEqual(BookDetailView.pinnedBarMode(isThisBookLoaded: true, isPlaying: false, anotherBookLoaded: false), .pausedHere)
    }

    func testAnotherBookLoadedIsPlayInstead() {
        XCTAssertEqual(BookDetailView.pinnedBarMode(isThisBookLoaded: false, isPlaying: true, anotherBookLoaded: true), .playInstead)
        XCTAssertEqual(BookDetailView.pinnedBarMode(isThisBookLoaded: false, isPlaying: false, anotherBookLoaded: true), .playInstead)
    }

    func testNothingLoadedIsStartOrContinue() {
        XCTAssertEqual(BookDetailView.pinnedBarMode(isThisBookLoaded: false, isPlaying: false, anotherBookLoaded: false), .startOrContinue)
    }

    func testThisBookLoadedWinsOverAnother() {
        XCTAssertEqual(BookDetailView.pinnedBarMode(isThisBookLoaded: true, isPlaying: true, anotherBookLoaded: true), .nowPlaying)
    }

    // MARK: labels

    func testPrimaryLabels() {
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .nowPlaying, progress: 0.4, isFinished: false), "Pause")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .nowPlaying, progress: 0.4, isFinished: false, detail: "Chapter 9"), "Pause · Chapter 9")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .pausedHere, progress: 0.4, isFinished: false, detail: "Chapter 9"), "Resume · Chapter 9")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .pausedHere, progress: 0.4, isFinished: false, detail: "  "), "Resume")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .playInstead, progress: 0.4, isFinished: false), "Play This Book Instead")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .startOrContinue, progress: 0, isFinished: false), "Start Listening")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .startOrContinue, progress: 0.4, isFinished: false), "Continue Listening")
        XCTAssertEqual(BookDetailView.pinnedPrimaryLabel(mode: .startOrContinue, progress: 1, isFinished: true), "Listen Again")
    }

    func testLoadedDetailPrefersChapterThenTimeLeft() {
        XCTAssertEqual(BookDetailView.pinnedLoadedDetail(chapterTitle: "Chapter 9", remaining: 7200, speed: 1), "Chapter 9")
        XCTAssertEqual(BookDetailView.pinnedLoadedDetail(chapterTitle: " ", remaining: 7200, speed: 2), "≈\((3600.0).formattedDuration) left in book")
        XCTAssertNil(BookDetailView.pinnedLoadedDetail(chapterTitle: nil, remaining: 30, speed: 1))
    }

    // MARK: chapter / bookmark taps

    func testChapterTapSeeksWhenThisBookIsLive() {
        XCTAssertEqual(BookDetailView.chapterTapAction(isThisBookLoaded: true, isAwaitingResume: false), .seekThenOpenPlayer)
    }

    func testChapterTapStartsWhenOtherOrNothingOrAwaitingResume() {
        XCTAssertEqual(BookDetailView.chapterTapAction(isThisBookLoaded: false, isAwaitingResume: false), .startThenSeek)
        XCTAssertEqual(BookDetailView.chapterTapAction(isThisBookLoaded: true, isAwaitingResume: true), .startThenSeek)
    }

    func testSeekAfterStartOnlyWhenThisBookIsNowLive() {
        XCTAssertTrue(BookDetailView.shouldSeekAfterStart(loadedBookId: "a", itemId: "a", isAwaitingResume: false))
        // start refused or failed: the other book is still loaded
        XCTAssertFalse(BookDetailView.shouldSeekAfterStart(loadedBookId: "b", itemId: "a", isAwaitingResume: false))
        XCTAssertFalse(BookDetailView.shouldSeekAfterStart(loadedBookId: nil, itemId: "a", isAwaitingResume: false))
        XCTAssertFalse(BookDetailView.shouldSeekAfterStart(loadedBookId: "a", itemId: "a", isAwaitingResume: true))
    }

    func testPlaysInsteadNote() {
        XCTAssertEqual(BookDetailView.playsInsteadNote(otherTitle: "Dune"), "Plays this book instead of Dune.")
        XCTAssertNil(BookDetailView.playsInsteadNote(otherTitle: nil))
        XCTAssertNil(BookDetailView.playsInsteadNote(otherTitle: " "))
    }

    // MARK: podcast + ebook

    func testPodcastLabels() {
        XCTAssertEqual(BookDetailView.podcastPrimaryLabel(targetIndex: 0, partlyPlayed: false, anotherItemLoaded: false), "Play Latest Episode")
        XCTAssertEqual(BookDetailView.podcastPrimaryLabel(targetIndex: 3, partlyPlayed: false, anotherItemLoaded: false), "Play Next Unheard Episode")
        XCTAssertEqual(BookDetailView.podcastPrimaryLabel(targetIndex: 3, partlyPlayed: true, anotherItemLoaded: false), "Resume Episode")
        XCTAssertEqual(BookDetailView.podcastPrimaryLabel(targetIndex: 0, partlyPlayed: false, anotherItemLoaded: true), "Play Latest Episode Instead")
    }

    func testEbookNoteOnlyForUnrenderableFormats() {
        XCTAssertNil(BookDetailView.ebookFormatNote(ext: "pdf"))
        XCTAssertNil(BookDetailView.ebookFormatNote(ext: "EPUB"))
        XCTAssertNil(BookDetailView.ebookFormatNote(ext: "cbz"))
        XCTAssertNil(BookDetailView.ebookFormatNote(ext: nil))
        XCTAssertNotNil(BookDetailView.ebookFormatNote(ext: "mobi"))
        XCTAssertNotNil(BookDetailView.ebookFormatNote(ext: "azw3"))
    }

    func testProgressSummary() {
        XCTAssertNil(BookDetailView.progressSummary(progress: 0, timeLeft: "≈3h left"))
        XCTAssertEqual(BookDetailView.progressSummary(progress: 0.42, timeLeft: nil), "42%")
        XCTAssertEqual(BookDetailView.progressSummary(progress: 0.42, timeLeft: "≈3h 20m left"), "42% · ≈3h 20m left")
    }

    func testReadoutIsSpeedAdjustedTimeLeft() {
        XCTAssertEqual(BookDetailView.nowPlayingReadoutText(remaining: 10, speed: 1, hasChapter: true), "")
        XCTAssertEqual(BookDetailView.nowPlayingReadoutText(remaining: 7200, speed: 2, hasChapter: true), "≈\((3600.0).formattedDuration) left in book")
        // no chapter: the button already carries the time, so the readout doesn't repeat it
        XCTAssertEqual(BookDetailView.nowPlayingReadoutText(remaining: 7200, speed: 1, hasChapter: false), "")
    }

    func testPodcastTargetIndex() {
        XCTAssertNil(BookDetailView.podcastTargetIndex(finished: []))
        XCTAssertEqual(BookDetailView.podcastTargetIndex(finished: [false, false]), 0)
        XCTAssertEqual(BookDetailView.podcastTargetIndex(finished: [true, true, false]), 2)
        XCTAssertEqual(BookDetailView.podcastTargetIndex(finished: [true, true]), 0)
    }

    // MARK: title suffix

    func testStripsParenthesisedSeriesSuffix() {
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Wake of the Bobiverse (Bobiverse #3)", series: "Bobiverse #3"), "Wake of the Bobiverse")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Heaven's River [Bobiverse, Book 4]", series: "Bobiverse #4"), "Heaven's River")
    }

    func testStripsDashedSeriesSuffix() {
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Wolf Hall - The Cromwell Trilogy, Book 1", series: "The Cromwell Trilogy #1"), "Wolf Hall")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Dune: Dune Chronicles #1", series: "Dune Chronicles"), "Dune")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Dune — Dune Chronicles, Book 1", series: "Dune Chronicles"), "Dune")
    }

    func testLeavesUnrelatedTitlesAlone() {
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Dune Messiah", series: "Dune"), "Dune Messiah")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Dune - Dune Messiah", series: "Dune"), "Dune - Dune Messiah")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Some Title", series: nil), "Some Title")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Some Title", series: "ab"), "Some Title")
    }

    // Critique 2026-10-05 (Book Detail, 2nd): an unmarked colon/dash tail is a real subtitle.
    func testKeepsSubtitlesThatOnlyEchoTheSeriesName() {
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Star Wars: Thrawn", series: "Thrawn"), "Star Wars: Thrawn")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Dune: Dune Chronicles", series: "Dune Chronicles"), "Dune: Dune Chronicles")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Spider-Man - Thrawn", series: "Thrawn"), "Spider-Man - Thrawn")
    }

    func testHyphenNeedsSpacesAroundItEvenWithMarker() {
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Anti-Thrawn #2", series: "Thrawn #2"), "Anti-Thrawn #2")
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("Anti-Thrawn, Book 2", series: "Thrawn #2"), "Anti-Thrawn, Book 2")
    }

    func testNeverReturnsEmptyTitle() {
        XCTAssertEqual(BookDetailView.titleRemovingSeriesSuffix("(Bobiverse #3)", series: "Bobiverse #3"), "(Bobiverse #3)")
    }
}
