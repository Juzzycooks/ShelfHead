import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 D6): auto-delete finished downloads waits behind an Undo toast,
/// and Settings › Downloads lists the series with auto-download on.
@MainActor
final class Batch495DownloadsAutoDeleteTests: XCTestCase {

    // MARK: AutoDeletePlan.candidates

    func testCandidatesAreDownloadedAndFinished() {
        XCTAssertEqual(AutoDeletePlan.candidates(downloaded: ["a", "b", "c"], serverFinished: ["b", "c", "z"],
                                                 playingId: nil, kept: [], alreadyPending: []),
                       ["b", "c"])
    }

    func testCandidatesSkipThePlayingBook() {
        XCTAssertEqual(AutoDeletePlan.candidates(downloaded: ["a", "b"], serverFinished: ["a", "b"],
                                                 playingId: "a", kept: [], alreadyPending: []),
                       ["b"])
    }

    func testCandidatesSkipKeptAndAlreadyPendingBooks() {
        XCTAssertEqual(AutoDeletePlan.candidates(downloaded: ["a", "b", "c"], serverFinished: ["a", "b", "c"],
                                                 playingId: nil, kept: ["a"], alreadyPending: ["b"]),
                       ["c"])
    }

    func testCandidatesAreSortedForAStableToast() {
        XCTAssertEqual(AutoDeletePlan.candidates(downloaded: ["z", "m", "a"], serverFinished: ["z", "m", "a"],
                                                 playingId: nil, kept: [], alreadyPending: []),
                       ["a", "m", "z"])
    }

    // MARK: AutoDeletePlan.prunedKept

    func testKeptBookIsForgottenWhenNoLongerFinished() {
        XCTAssertEqual(AutoDeletePlan.prunedKept(["a", "b"], finishedById: ["a": false, "b": true]), ["b"])
    }

    func testKeptBookWithNoServerReportStaysKept() {
        XCTAssertEqual(AutoDeletePlan.prunedKept(["a"], finishedById: [:]), ["a"])
    }

    // MARK: AutoDeletePlan.message

    func testNoMessageWhenNothingIsPending() {
        XCTAssertNil(AutoDeletePlan.message(titles: []))
    }

    func testSingleBookMessageNamesIt() throws {
        let message = try XCTUnwrap(AutoDeletePlan.message(titles: ["Dune"]))
        XCTAssertTrue(message.contains("Dune"), message)
    }

    func testSingleUntitledBookStillGetsAMessage() {
        XCTAssertNotNil(AutoDeletePlan.message(titles: ["  "]))
    }

    func testSeveralBooksMessageCountsThem() throws {
        let message = try XCTUnwrap(AutoDeletePlan.message(titles: ["A", "B", "C"]))
        XCTAssertTrue(message.contains(3.formatted()), message)
        XCTAssertFalse(message.contains("A\u{201D}"), message)
    }

    func testUndoWindowEndsWellBeforeTheFallback() {
        XCTAssertGreaterThan(AutoDeletePlan.undoWindow, 0)
        XCTAssertGreaterThan(AutoDeletePlan.fallbackDelay, AutoDeletePlan.undoWindow)
    }

    // MARK: SeriesAutoDownloadList

    func testSeriesListKeepsOnlyEnabledNamedSeries() {
        XCTAssertEqual(SeriesAutoDownloadList.names(from: ["Dune": true, "Old": false, "": true]), ["Dune"])
    }

    func testSeriesListIsAlphabeticalIgnoringCase() {
        XCTAssertEqual(SeriesAutoDownloadList.names(from: ["expanse": true, "Discworld": true, "Book 10": true, "Book 2": true]),
                       ["Book 2", "Book 10", "Discworld", "expanse"])
    }

    func testEmptyStoreGivesAnEmptyList() {
        XCTAssertEqual(SeriesAutoDownloadList.names(from: [:]), [])
    }
}
