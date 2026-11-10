import XCTest
@testable import ShelfHead

/// Item 14 (REVIEW-2026-09-09-REMAINING.md): `LibraryViewModel.loadSeries()` used to
/// fetch only page 0 of `getSeries` and treat that as the whole Series browse mode, even
/// though `getSeries` is itself paginated (`limit`/`page`, same shape `getLibraryItems`
/// uses) and `findSeries` in the same file already had to paginate that same endpoint to
/// find one named series in a large library. Any library with more than 100 series
/// silently truncated with no "there's more" signal.
///
/// `LibraryViewModel.nextPage(after:receivedInPage:accumulatedCount:total:limit:)` is the
/// pure page-plan `loadSeries()` now drives its fetch loop with. Pinned here rather than
/// via a live/mocked network call, matching this project's precedent of testing the
/// decision function instead of the I/O around it.
final class LibraryViewModelPaginationTests: XCTestCase {

    // MARK: - Stopping conditions

    func testAShortPageMeansThereIsNoMore() {
        // Server returned fewer than a full page — the last page, exactly like
        // `findSeries`'s own `results.count < pageSize` check.
        XCTAssertNil(LibraryViewModel.nextPage(
            after: 0, receivedInPage: 40, accumulatedCount: 40, total: nil, limit: 100))
    }

    func testAnEmptyPageMeansThereIsNoMore() {
        XCTAssertNil(LibraryViewModel.nextPage(
            after: 2, receivedInPage: 0, accumulatedCount: 200, total: nil, limit: 100))
    }

    func testReachingTheReportedTotalStopsEvenOnAFullPage() {
        // A full page that happens to land exactly on `total` shouldn't ask for one more.
        XCTAssertNil(LibraryViewModel.nextPage(
            after: 1, receivedInPage: 100, accumulatedCount: 200, total: 200, limit: 100))
    }

    // MARK: - Continuing

    func testAFullPageBelowAnUnknownTotalContinues() {
        // `SeriesResponse.total` is optional; with none reported, a full page is the only
        // signal there might be more.
        XCTAssertEqual(LibraryViewModel.nextPage(
            after: 0, receivedInPage: 100, accumulatedCount: 100, total: nil, limit: 100), 1)
    }

    func testAFullPageBelowAKnownTotalContinues() {
        XCTAssertEqual(LibraryViewModel.nextPage(
            after: 0, receivedInPage: 100, accumulatedCount: 100, total: 250, limit: 100), 1)
    }

    // MARK: - Assembling multiple pages in order

    /// The regression scenario itself: a 250-series library, paginated in 100-item
    /// pages, must come back as all 250 in the order the server returned them — not
    /// truncated at the first page's 100.
    func testAssemblesA250ItemListInOrderFromThreePages() {
        let limit = 100
        let total = 250
        // Simulates three server pages of series names, each just an index so ordering
        // is easy to assert on.
        let allSeries = (0..<total).map { "series-\($0)" }
        func page(_ n: Int) -> [String] {
            let start = n * limit
            let end = min(start + limit, allSeries.count)
            return start < end ? Array(allSeries[start..<end]) : []
        }

        var assembled: [String] = []
        var currentPage = 0
        var pagesFetched = 0
        while true {
            let results = page(currentPage)
            assembled.append(contentsOf: results)
            pagesFetched += 1
            guard let next = LibraryViewModel.nextPage(
                after: currentPage, receivedInPage: results.count,
                accumulatedCount: assembled.count, total: total, limit: limit
            ) else { break }
            currentPage = next
        }

        XCTAssertEqual(pagesFetched, 3, "100 + 100 + 50 should take exactly three fetches")
        XCTAssertEqual(assembled.count, 250)
        XCTAssertEqual(assembled, allSeries, "Pages must be appended in fetch order, not re-sorted")
    }

    func testDefensiveCapIsRespectedByTheCaller() {
        // `nextPage` itself has no cap — `loadSeries()`'s `maxPages` guard is what stops
        // a pathological/looping response. Confirm the plan alone would otherwise keep
        // asking for more, so that cap is genuinely load-bearing and not dead code.
        XCTAssertEqual(LibraryViewModel.nextPage(
            after: 500, receivedInPage: 100, accumulatedCount: 50_100, total: nil, limit: 100), 501)
    }
}
