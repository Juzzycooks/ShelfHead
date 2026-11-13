import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 N6): where search links land, and when a field sharing
/// Library's one result set has to re-run its query.
final class Batch496SearchRoutingTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testSearchLinkWithQueryGoesToSearchTabOnIOS26() {
        XCTAssertEqual(SearchRequestRoute.route(for: url("shelfhead://search?q=Dune"), hasSearchTab: true),
                       .searchTab(query: "Dune"))
    }

    func testSearchLinkWithQueryGoesToLibraryWithoutSearchTab() {
        XCTAssertEqual(SearchRequestRoute.route(for: url("shelfhead://search?q=Dune"), hasSearchTab: false),
                       .librarySearch(query: "Dune"))
    }

    func testQuickActionLinkHasNoQuery() {
        // The Search quick action opens the bare link: the field is focused, empty.
        XCTAssertEqual(SearchRequestRoute.route(for: url("shelfhead://search"), hasSearchTab: true),
                       .searchTab(query: nil))
        XCTAssertEqual(SearchRequestRoute.route(for: url("shelfhead://search"), hasSearchTab: false),
                       .librarySearch(query: nil))
    }

    func testBlankQueryIsNoQuery() {
        XCTAssertEqual(SearchRequestRoute.route(for: url("shelfhead://search?q=%20%20"), hasSearchTab: true),
                       .searchTab(query: nil))
    }

    func testQueryIsTrimmedAndDecoded() {
        XCTAssertEqual(SearchRequestRoute.route(for: url("shelfhead://search?q=%20The%20Hobbit%20"), hasSearchTab: true),
                       .searchTab(query: "The Hobbit"))
    }

    func testOtherLinksAreNotSearchRoutes() {
        XCTAssertNil(SearchRequestRoute.route(for: url("shelfhead://library"), hasSearchTab: true))
        XCTAssertNil(SearchRequestRoute.route(for: url("shelfhead://book/abc"), hasSearchTab: true))
        XCTAssertNil(SearchRequestRoute.route(for: url("https://search?q=x"), hasSearchTab: true))
    }

    func testQuickActionURLRoutesAsSearch() {
        XCTAssertEqual(SearchRequestRoute.route(for: QuickActionRoute.url(forShortcutType: QuickActionRoute.searchType)!, hasSearchTab: true),
                       .searchTab(query: nil))
    }

    // MARK: - Shared result set

    func testNeedsRerunWhenOtherFieldReplacedTheQuery() {
        XCTAssertTrue(LibrarySharedSearch.needsRerun(fieldText: "Dune", viewModelQuery: "Hobbit"))
        XCTAssertTrue(LibrarySharedSearch.needsRerun(fieldText: "Dune", viewModelQuery: ""))
    }

    func testNoRerunWhenQueryMatchesOrFieldIsEmpty() {
        XCTAssertFalse(LibrarySharedSearch.needsRerun(fieldText: "Dune", viewModelQuery: "Dune"))
        XCTAssertFalse(LibrarySharedSearch.needsRerun(fieldText: "", viewModelQuery: "Hobbit"))
    }

    func testPromptMatchesLibrary() {
        XCTAssertEqual(LibrarySharedSearch.prompt(isPodcastLibrary: true), "Search shows")
        XCTAssertEqual(LibrarySharedSearch.prompt(isPodcastLibrary: false), "Search books, authors, series…")
    }
}
