import XCTest
@testable import ShelfHead

// Batch 490 (REVIEW 2026-11-11 E2, D7, F27): the pure decisions behind the Stats quick wins —
// which state the Cassette Wall and Passport show, "See all sessions" paging, the
// books-this-year goal, and the listening history CSV.
@MainActor
final class QuickWinsStatsTests: XCTestCase {

    // MARK: - E2: finished-book catalog display state

    func testFailedLoadWithNothingCachedIsAFailureNotEmpty() {
        XCTAssertEqual(FinishedCatalogDisplayState.resolve(isEmpty: true, isRefreshing: false, hasLoaded: true, lastRefreshFailed: true), .failed)
    }

    func testLoadedEmptyCatalogIsTheEmptyState() {
        XCTAssertEqual(FinishedCatalogDisplayState.resolve(isEmpty: true, isRefreshing: false, hasLoaded: true, lastRefreshFailed: false), .empty)
    }

    func testEmptyCatalogLoadsWhileRefreshingOrBeforeFirstLoad() {
        // Retry: the refresh in flight wins over the previous failure.
        XCTAssertEqual(FinishedCatalogDisplayState.resolve(isEmpty: true, isRefreshing: true, hasLoaded: true, lastRefreshFailed: true), .loading)
        XCTAssertEqual(FinishedCatalogDisplayState.resolve(isEmpty: true, isRefreshing: false, hasLoaded: false, lastRefreshFailed: false), .loading)
    }

    func testCachedBooksShowEvenAfterAFailedRefresh() {
        XCTAssertEqual(FinishedCatalogDisplayState.resolve(isEmpty: false, isRefreshing: false, hasLoaded: true, lastRefreshFailed: true), .content)
        XCTAssertEqual(FinishedCatalogDisplayState.resolve(isEmpty: false, isRefreshing: true, hasLoaded: true, lastRefreshFailed: false), .content)
    }

    // MARK: - D7: sessions paging

    private struct Row: Identifiable, Equatable { let id: String }

    func testShortPageIsTheLastPage() {
        XCTAssertEqual(SessionPaging.pageSize, 25)
        XCTAssertTrue(SessionPaging.reachedEnd(lastPageCount: 0))
        XCTAssertTrue(SessionPaging.reachedEnd(lastPageCount: 24))
        XCTAssertFalse(SessionPaging.reachedEnd(lastPageCount: 25))
        XCTAssertTrue(SessionPaging.reachedEnd(lastPageCount: 9, pageSize: 10))
    }

    func testLoadsMoreOnlyWhenTheLastRowAppearsAndNothingBlocksIt() {
        XCTAssertTrue(SessionPaging.shouldLoadMore(appearingId: "c", lastId: "c", isLoading: false, reachedEnd: false, failed: false))
        XCTAssertFalse(SessionPaging.shouldLoadMore(appearingId: "b", lastId: "c", isLoading: false, reachedEnd: false, failed: false))
        XCTAssertFalse(SessionPaging.shouldLoadMore(appearingId: "c", lastId: "c", isLoading: true, reachedEnd: false, failed: false))
        XCTAssertFalse(SessionPaging.shouldLoadMore(appearingId: "c", lastId: "c", isLoading: false, reachedEnd: true, failed: false))
        // A failed page waits for Retry rather than looping on every appearance.
        XCTAssertFalse(SessionPaging.shouldLoadMore(appearingId: "c", lastId: "c", isLoading: false, reachedEnd: false, failed: true))
        XCTAssertFalse(SessionPaging.shouldLoadMore(appearingId: "c", lastId: nil, isLoading: false, reachedEnd: false, failed: false))
    }

    func testAppendingSkipsSessionsAlreadyShown() {
        let existing = [Row(id: "a"), Row(id: "b")]
        let page = [Row(id: "b"), Row(id: "c"), Row(id: "c"), Row(id: "d")]
        XCTAssertEqual(SessionPaging.appending(page, to: existing).map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(SessionPaging.appending([Row](), to: existing), existing)
    }

    // MARK: - F27: books-this-year goal

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    func testGoalOffHasNoProgress() {
        XCTAssertNil(BooksYearGoal.progress(finishDates: [date(2026, 3, 1)], goal: 0, now: date(2026, 6, 1), calendar: utc))
    }

    func testCountsOnlyTheCurrentCalendarYear() {
        let dates = [date(2025, 6, 1), date(2026, 1, 5), date(2026, 11, 1), date(2027, 1, 1)]
        let p = BooksYearGoal.progress(finishDates: dates, goal: 24, now: date(2026, 11, 11), calendar: utc)
        XCTAssertEqual(p, BooksYearGoal.Progress(finished: 2, goal: 24))
        XCTAssertEqual(p?.isMet, false)
        XCTAssertEqual(p?.fraction ?? -1, 2.0 / 24.0, accuracy: 0.0001)
    }

    func testYearBoundary() {
        let lastSecondOf2025 = date(2025, 12, 31, 23, 59, 59)
        let firstSecondOf2026 = date(2026, 1, 1, 0, 0, 0)
        let dates = [lastSecondOf2025, firstSecondOf2026]
        // Just after midnight on 1 January only the new year's book counts...
        XCTAssertEqual(BooksYearGoal.progress(finishDates: dates, goal: 12, now: date(2026, 1, 1, 0, 0, 1), calendar: utc)?.finished, 1)
        // ...and a second before midnight only the old year's.
        XCTAssertEqual(BooksYearGoal.progress(finishDates: dates, goal: 12, now: lastSecondOf2025, calendar: utc)?.finished, 1)
        XCTAssertEqual(BooksYearGoal.finishedCount(finishDates: dates, year: 2024, calendar: utc), 0)
    }

    func testFractionClampsAndGoalMet() {
        let over = BooksYearGoal.Progress(finished: 30, goal: 24)
        XCTAssertTrue(over.isMet)
        XCTAssertEqual(over.fraction, 1)
        XCTAssertTrue(BooksYearGoal.Progress(finished: 24, goal: 24).isMet)
        XCTAssertEqual(BooksYearGoal.Progress(finished: 0, goal: 24).fraction, 0)
    }

    func testGoalLineOnlyShowsOnceTheCatalogHasReallyLoaded() {
        XCTAssertTrue(BooksYearGoal.isVisible(goal: 24, catalogState: .content))
        XCTAssertTrue(BooksYearGoal.isVisible(goal: 24, catalogState: .empty))
        XCTAssertFalse(BooksYearGoal.isVisible(goal: 24, catalogState: .loading))
        XCTAssertFalse(BooksYearGoal.isVisible(goal: 24, catalogState: .failed))
        XCTAssertFalse(BooksYearGoal.isVisible(goal: 0, catalogState: .content))
    }

    func testGoalCopy() {
        XCTAssertEqual(BooksYearGoal.text(.init(finished: 7, goal: 24)), "7 of 24 books this year")
        XCTAssertEqual(BooksYearGoal.text(.init(finished: 25, goal: 24)), "Goal hit \u{00B7} 25 of 24 books this year")
        XCTAssertEqual(BooksYearGoal.spoken(.init(finished: 7, goal: 24)), "Books goal: 7 of 24 books finished this year.")
        XCTAssertEqual(BooksYearGoal.spoken(.init(finished: 24, goal: 24)), "Books goal hit: 24 of 24 books finished this year.")
    }

    func testGoalDefaultsOffAndPresets() {
        XCTAssertEqual(BooksYearGoal.defaultsKey, "settings_booksPerYearGoal")
        XCTAssertEqual(BooksYearGoal.presets, [6, 12, 24, 36, 52])
        XCTAssertEqual(BooksYearGoal.customRange, 1...365)
    }

    // MARK: - F27: listening history CSV

    func testCSVIsSortedISODatesWithMinutesToOneDecimal() {
        let days: [String: Double] = [
            "2026-03-02": 750,      // 12.5 minutes
            "2026-03-01": 3600,     // 60 minutes
            "2025-12-31": 100,      // 1.666… minutes
            "2026-03-03": -30,      // a negative server value counts as 0
            "not-a-date": 600,      // dropped
        ]
        XCTAssertEqual(ListeningHistoryCSV.make(days: days),
                       "date,minutes\n2025-12-31,1.7\n2026-03-01,60.0\n2026-03-02,12.5\n2026-03-03,0.0\n")
    }

    func testCSVWithNoDaysIsJustTheHeader() {
        XCTAssertEqual(ListeningHistoryCSV.make(days: [:]), "date,minutes\n")
    }

    func testCSVMinutesUseAPointNotTheLocaleSeparator() {
        XCTAssertEqual(ListeningHistoryCSV.minutes(seconds: 90), "1.5")
        XCTAssertEqual(ListeningHistoryCSV.minutes(seconds: 0), "0.0")
        XCTAssertEqual(ListeningHistoryCSV.minutes(seconds: 6_000_000), "100000.0")
    }
}
