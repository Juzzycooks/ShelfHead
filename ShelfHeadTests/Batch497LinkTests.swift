import XCTest
import CoreSpotlight
@testable import ShelfHead

/// Batch 497: `shelfhead://series?name=` (Release Radar reminders) and Spotlight's "Search in App".
final class Batch497LinkTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: series?name=

    func testSeriesNameParsing() {
        XCTAssertEqual(DeepLinkParser.seriesName(in: url("shelfhead://series?name=The%20Expanse")), "The Expanse")
        XCTAssertEqual(DeepLinkParser.seriesName(in: url("shelfhead://series?name=%20Dune%20")), "Dune")
        XCTAssertNil(DeepLinkParser.seriesName(in: url("shelfhead://series?name=%20%20")))
        XCTAssertNil(DeepLinkParser.seriesName(in: url("shelfhead://series")))
        XCTAssertNil(DeepLinkParser.seriesName(in: url("shelfhead://series/abc?name=Dune")))
        XCTAssertNil(DeepLinkParser.seriesName(in: url("shelfhead://author?name=Dune")))
        XCTAssertEqual(DeepLinkParser.seriesID(in: url("shelfhead://series/abc")), "abc")
        XCTAssertNil(DeepLinkParser.seriesID(in: url("shelfhead://series?name=Dune")))
    }

    func testSeriesURLRoundTrips() throws {
        let link = try XCTUnwrap(DeepLinkParser.seriesURL(named: "Tom & Jerry: Café #1"))
        XCTAssertEqual(DeepLinkParser.seriesName(in: link), "Tom & Jerry: Café #1")
    }

    func testExactMatchIgnoresCaseAndDiacritics() {
        let names = [["Other"], ["The Café Series", "The Café Series"]]
        XCTAssertEqual(SeriesNameRoute.decide(name: "the cafe series", candidateNames: names), .open(1))
        XCTAssertEqual(SeriesNameRoute.decide(name: "  THE CAFÉ SERIES ", candidateNames: names), .open(1))
    }

    func testNoClosestMatch() {
        let names = [["The Expanse Collection"]]
        XCTAssertEqual(SeriesNameRoute.decide(name: "The Expanse", candidateNames: names),
                       .search(url("shelfhead://search?q=The%20Expanse")))
    }

    func testFallsBackWhenListUnavailableEmptyOrAmbiguous() {
        let search = SeriesNameRoute.search(url("shelfhead://search?q=Dune"))
        XCTAssertEqual(SeriesNameRoute.decide(name: "Dune", candidateNames: nil), search)
        XCTAssertEqual(SeriesNameRoute.decide(name: "Dune", candidateNames: []), search)
        XCTAssertEqual(SeriesNameRoute.decide(name: "Dune", candidateNames: [["Dune"], ["dune"]]), search)
    }

    func testBlankNameFallsBackToBareSearch() {
        XCTAssertEqual(SeriesNameRoute.decide(name: "  ", candidateNames: [["  "]]),
                       .search(SeriesNameRoute.searchURL(for: "  ")))
    }

    // MARK: Spotlight continuation

    func testSpotlightQueryBecomesSearchLink() throws {
        let link = try XCTUnwrap(SpotlightSearchContinuation.url(
            activityType: CSQueryContinuationActionType, userInfo: [CSSearchQueryString: " Dune & co "]))
        XCTAssertEqual(link.host, "search")
        XCTAssertEqual(DeepLinkParser.searchQuery(in: link), "Dune & co")
    }

    func testSpotlightBlankOrMissingQueryOpensEmptySearch() {
        XCTAssertEqual(SpotlightSearchContinuation.url(activityType: CSQueryContinuationActionType,
                                                       userInfo: [CSSearchQueryString: "   "]), url("shelfhead://search"))
        XCTAssertEqual(SpotlightSearchContinuation.url(activityType: CSQueryContinuationActionType, userInfo: nil),
                       url("shelfhead://search"))
        XCTAssertEqual(SpotlightSearchContinuation.url(activityType: CSQueryContinuationActionType,
                                                       userInfo: [CSSearchQueryString: 5]), url("shelfhead://search"))
    }

    func testOtherActivityTypesAreIgnored() {
        XCTAssertNil(SpotlightSearchContinuation.url(activityType: CSSearchableItemActionType,
                                                     userInfo: [CSSearchQueryString: "Dune"]))
    }
}
