import XCTest
@testable import ShelfHead

/// Regression cover for the next-in-series selection extracted into `SeriesOrdering`.
///
/// The bug this pins: `PlayerViewModel`'s auto-queue and auto-download both picked the
/// first unfinished book anywhere in the series, with no comparison against the book
/// that had just finished — so finishing #5 while #2 was still unfinished queued and
/// downloaded #2. `testNextUnfinishedSkipsEarlierUnfinishedBook` fails against that
/// behaviour and passes against the shared implementation.
final class SeriesOrderingTests: XCTestCase {

    private func candidate(
        _ id: String, _ sequence: Double?, finished: Bool = false, downloaded: Bool = false
    ) -> SeriesOrdering.Candidate {
        SeriesOrdering.Candidate(id: id, sequence: sequence, isFinished: finished, isDownloaded: downloaded)
    }

    /// #1 and #3 finished, #2 never started, #5 just finished. The next book is #6.
    private var partiallyReadSeries: [SeriesOrdering.Candidate] {
        [candidate("b1", 1, finished: true),
         candidate("b2", 2),
         candidate("b3", 3, finished: true),
         candidate("b5", 5, finished: true),
         candidate("b6", 6),
         candidate("b7", 7)]
    }

    // MARK: - The regression

    func testNextUnfinishedSkipsEarlierUnfinishedBook() {
        let next = SeriesOrdering.nextUnfinished(
            after: "b5", currentSequence: 5, in: partiallyReadSeries
        )
        XCTAssertEqual(next?.id, "b6", "Should continue forward, not fall back to unfinished #2")
    }

    func testLaterInSeriesExcludesSelfAndEverythingEarlier() {
        let later = SeriesOrdering.laterInSeries(
            after: "b5", currentSequence: 5, in: partiallyReadSeries
        )
        XCTAssertEqual(later.map(\.id), ["b6", "b7"])
    }

    // MARK: - Ordering

    func testSortedBySequencePutsUnsequencedBooksLast() {
        let ordered = SeriesOrdering.sortedBySequence(
            [candidate("x", nil), candidate("y", 2), candidate("z", 1)]
        )
        XCTAssertEqual(ordered.map(\.id), ["z", "y", "x"])
    }

    func testFractionalSequenceOrdersBetweenWholeNumbers() {
        let next = SeriesOrdering.nextUnfinished(
            after: "b2", currentSequence: 2,
            in: [candidate("b2", 2), candidate("b25", 2.5), candidate("b3", 3)]
        )
        XCTAssertEqual(next?.id, "b25", "A 2.5 novella comes before #3")
    }

    // MARK: - Download preference

    func testPreferDownloadedPicksLaterDownloadedBookOverEarlierStreamed() {
        let next = SeriesOrdering.nextUnfinished(
            after: "b1", currentSequence: 1,
            in: [candidate("b1", 1), candidate("b2", 2), candidate("b3", 3, downloaded: true)],
            preferDownloaded: true
        )
        XCTAssertEqual(next?.id, "b3")
    }

    func testWithoutPreferDownloadedStrictSequenceOrderWins() {
        let next = SeriesOrdering.nextUnfinished(
            after: "b1", currentSequence: 1,
            in: [candidate("b1", 1), candidate("b2", 2), candidate("b3", 3, downloaded: true)]
        )
        XCTAssertEqual(next?.id, "b2", "Auto-download wants the next book, not the one already on disk")
    }

    // MARK: - Exhausted / missing data

    func testNextUnfinishedIsNilWhenEveryLaterBookIsFinished() {
        XCTAssertNil(SeriesOrdering.nextUnfinished(
            after: "b1", currentSequence: 1,
            in: [candidate("b1", 1), candidate("b2", 2, finished: true)]
        ))
    }

    func testNextAvailableFallsBackToAFinishedLaterBook() {
        let next = SeriesOrdering.nextAvailable(
            after: "b1", currentSequence: 1,
            in: [candidate("b1", 1), candidate("b2", 2, finished: true)]
        )
        XCTAssertEqual(next?.id, "b2")
    }

    func testLastBookInSeriesHasNoSuccessor() {
        XCTAssertNil(SeriesOrdering.nextUnfinished(
            after: "b7", currentSequence: 7, in: partiallyReadSeries
        ))
    }

    /// With no sequence data on either side the comparison can't be made, so everything
    /// except the book itself stays a candidate.
    func testMissingSequenceDataKeepsEveryOtherBook() {
        let later = SeriesOrdering.laterInSeries(
            after: "a", currentSequence: nil,
            in: [candidate("a", nil), candidate("b", nil), candidate("c", nil)]
        )
        XCTAssertEqual(later.map(\.id), ["b", "c"])
    }

    func testCandidateWithoutSequenceIsStillConsideredAfterASequencedBook() {
        let next = SeriesOrdering.nextUnfinished(
            after: "b1", currentSequence: 1,
            in: [candidate("b1", 1), candidate("bonus", nil)]
        )
        XCTAssertEqual(next?.id, "bonus")
    }
}
