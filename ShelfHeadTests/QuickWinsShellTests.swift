import XCTest
@testable import ShelfHead

// Batch 490 (REVIEW 2026-11-11 E1, F13, F14, V6, E4, V8): the pure decisions behind the app-shell
// and Home quick wins — deep-link parsing (book start time, series, author, search, driving),
// the held-link freshness rule, the Home Screen quick-action mapping, the opened-book fallback,
// Release Radar's "Not Interested" filter and check summary, and Home's greeting.
final class QuickWinsShellTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Bad test URL \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    // MARK: - F14: book/<id>?t=

    func testBookIDIsTheFirstPathComponent() {
        XCTAssertEqual(DeepLinkParser.bookID(in: url("shelfhead://book/li_123")), "li_123")
        XCTAssertEqual(DeepLinkParser.bookID(in: url("shelfhead://book/li_123?t=90")), "li_123")
    }

    func testBookIDIsNilWithoutAnIdOrForAnotherHost() {
        XCTAssertNil(DeepLinkParser.bookID(in: url("shelfhead://book")))
        XCTAssertNil(DeepLinkParser.bookID(in: url("shelfhead://book/")))
        XCTAssertNil(DeepLinkParser.bookID(in: url("shelfhead://series/li_123")))
    }

    func testStartTimeAcceptsFiniteNonNegativeSeconds() {
        XCTAssertEqual(DeepLinkParser.startTime(in: url("shelfhead://book/a?t=0")), 0)
        XCTAssertEqual(DeepLinkParser.startTime(in: url("shelfhead://book/a?t=90")), 90)
        XCTAssertEqual(DeepLinkParser.startTime(in: url("shelfhead://book/a?t=12.5")), 12.5)
    }

    func testStartTimeRejectsInvalidValues() {
        for bad in ["", "abc", "-5", "nan", "inf", "-inf", "1:30"] {
            let link = url("shelfhead://book/a?t=\(bad)")
            XCTAssertNil(DeepLinkParser.startTime(in: link), "t=\(bad) should be ignored")
        }
        XCTAssertNil(DeepLinkParser.startTime(in: url("shelfhead://book/a")))
        XCTAssertNil(DeepLinkParser.startTime(in: url("shelfhead://series/a?t=90")), "only book links carry a start time")
    }

    // MARK: - F14: series, author, search

    func testSeriesAndAuthorIDs() {
        XCTAssertEqual(DeepLinkParser.seriesID(in: url("shelfhead://series/ser_1")), "ser_1")
        XCTAssertEqual(DeepLinkParser.authorID(in: url("shelfhead://author/aut_1")), "aut_1")
        XCTAssertNil(DeepLinkParser.seriesID(in: url("shelfhead://series")))
        XCTAssertNil(DeepLinkParser.authorID(in: url("shelfhead://series/aut_1")))
    }

    func testSearchQueryIsTrimmedAndBlankIsNil() {
        XCTAssertEqual(DeepLinkParser.searchQuery(in: url("shelfhead://search?q=%20Dune%20")), "Dune")
        XCTAssertEqual(DeepLinkParser.searchQuery(in: url("shelfhead://search?q=Project%20Hail%20Mary")), "Project Hail Mary")
        XCTAssertNil(DeepLinkParser.searchQuery(in: url("shelfhead://search")))
        XCTAssertNil(DeepLinkParser.searchQuery(in: url("shelfhead://search?q=%20%20")))
        XCTAssertNil(DeepLinkParser.searchQuery(in: url("shelfhead://library?q=Dune")))
    }

    // MARK: - E1: opened-book fallback

    func testResolvedBookPrefersTheServerCopyThenTheDownload() {
        XCTAssertEqual(DeepLinkParser.resolvedBook(fetched: "server", downloaded: "local"), "server")
        XCTAssertEqual(DeepLinkParser.resolvedBook(fetched: nil, downloaded: "local"), "local")
        XCTAssertNil(DeepLinkParser.resolvedBook(fetched: String?.none, downloaded: nil))
    }

    // MARK: - E1: held-link freshness

    func testHeldLinkIsFreshWithinTenMinutes() {
        let received = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(PendingLinkRule.isFresh(receivedAt: received, now: received))
        XCTAssertTrue(PendingLinkRule.isFresh(receivedAt: received, now: received.addingTimeInterval(600)))
        XCTAssertFalse(PendingLinkRule.isFresh(receivedAt: received, now: received.addingTimeInterval(601)))
    }

    func testHeldLinkWithAFutureReceiptTimeCountsAsFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(PendingLinkRule.isFresh(receivedAt: now.addingTimeInterval(30), now: now))
    }

    // MARK: - F13: quick actions

    func testQuickActionsMapToTheirDeepLinks() {
        XCTAssertEqual(QuickActionRoute.url(forShortcutType: QuickActionRoute.resumeType)?.absoluteString, "shelfhead://resume")
        XCTAssertEqual(QuickActionRoute.url(forShortcutType: QuickActionRoute.downloadsType)?.absoluteString, "shelfhead://downloads")
        XCTAssertEqual(QuickActionRoute.url(forShortcutType: QuickActionRoute.searchType)?.absoluteString, "shelfhead://search")
        XCTAssertNil(QuickActionRoute.url(forShortcutType: "something.else"))
    }

    /// The Info.plist types must match the mapping, or a quick action silently does nothing.
    func testInfoPlistQuickActionTypesAreAllMapped() {
        let items = Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems") as? [[String: Any]] ?? []
        let types = items.compactMap { $0["UIApplicationShortcutItemType"] as? String }
        XCTAssertEqual(Set(types), [QuickActionRoute.resumeType, QuickActionRoute.downloadsType, QuickActionRoute.searchType])
        for type in types {
            XCTAssertNotNil(QuickActionRoute.url(forShortcutType: type), "\(type) has no route")
        }
    }

    // MARK: - V6: Release Radar "Not Interested"

    private func entry(_ asin: String) -> ReleaseRadarPlanner.RadarEntry {
        ReleaseRadarPlanner.RadarEntry(seriesName: "Series", sequence: 1, title: "Book \(asin)", author: "Author",
                                       releaseDate: Date(timeIntervalSince1970: 0), asin: asin, coverURL: nil)
    }

    func testNotInterestedEntriesAreHidden() {
        let all = [entry("A"), entry("B"), entry("C")]
        XCTAssertEqual(ReleaseRadarViewModel.visibleEntries(all, hiding: ["B"]).map(\.asin), ["A", "C"])
        XCTAssertEqual(ReleaseRadarViewModel.visibleEntries(all, hiding: []).map(\.asin), ["A", "B", "C"])
        XCTAssertEqual(ReleaseRadarViewModel.visibleEntries(all, hiding: ["A", "B", "C"]), [])
    }

    // MARK: - E4: Release Radar check summary

    func testCheckSummaryNamesTheCountAndHome() {
        XCTAssertEqual(ReleaseRadarViewModel.checkSummary(count: 0),
                       String(localized: "Nothing new in your series yet", comment: "Release Radar settings: a check found no books"))
        XCTAssertEqual(ReleaseRadarViewModel.checkSummary(count: 1),
                       String(localized: "1 upcoming book found \u{00B7} on Home", comment: "Release Radar settings: a check found one book, shown on the Home shelf"))
        XCTAssertTrue(ReleaseRadarViewModel.checkSummary(count: 1234).contains("1234"), "no digit grouping")
    }

    // MARK: - V8: greeting

    func testLateNightGreetingIsGoodEvening() {
        let evening = String(localized: "Good evening")
        for hour in [17, 20, 21, 23, 0, 3, 4] {
            XCTAssertEqual(HomeState.greeting(hour: hour), evening, "hour \(hour)")
        }
        XCTAssertEqual(HomeState.greeting(hour: 5), String(localized: "Good morning"))
        XCTAssertEqual(HomeState.greeting(hour: 11), String(localized: "Good morning"))
        XCTAssertEqual(HomeState.greeting(hour: 12), String(localized: "Good afternoon"))
        XCTAssertEqual(HomeState.greeting(hour: 16), String(localized: "Good afternoon"))
    }
}
