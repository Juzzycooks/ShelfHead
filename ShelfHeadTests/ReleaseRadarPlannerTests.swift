import XCTest
@testable import ShelfHead

/// Batch 442: release radar planner and catalog decode.
final class ReleaseRadarPlannerTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ s: String, calendar: Calendar? = nil) -> Date {
        ReleaseRadarPlanner.parseReleaseDate(s, calendar: calendar ?? cal)!
    }

    private func product(_ asin: String, _ title: String, seq: Double?, release: String,
                         series: String = "The Stormlight Archive", format: String = "unabridged",
                         language: String = "english") -> CatalogProduct {
        CatalogProduct(asin: asin, title: title, authors: ["Brandon Sanderson"], formatType: format,
                       language: language, releaseDate: release,
                       series: [.init(asin: "S1", title: series, sequence: seq)], coverURL: "https://example.com/\(asin).jpg")
    }

    private func target(max: Double = 4, owned: Set<String> = ["OWN4"]) -> ReleaseRadarPlanner.SeriesTarget {
        .init(key: ReleaseRadarPlanner.normalisedSeriesKey("The Stormlight Archive"), name: "The Stormlight Archive",
              author: "Brandon Sanderson", language: "English", maxOwnedSequence: max, ownedASINs: owned, sampleASIN: "OWN4")
    }

    func testSequenceFilteringAndOwnedExcluded() {
        let t = target()
        let catalog = [t.key: [
            product("A3", "Book 3", seq: 3, release: "2021-11-23"),
            product("OWN4", "Rhythm", seq: 4, release: "2020-11-17"),
            product("A5", "Wind and Truth", seq: 5, release: "2024-12-06"),
        ]]
        let out = ReleaseRadarPlanner.plan(targets: [t], catalog: catalog, today: date("2026-10-28"), calendar: cal)
        XCTAssertEqual(out.map(\.asin), ["A5"])
        XCTAssertEqual(out.first?.status(today: date("2026-10-28"), calendar: cal), .outNotInLibrary)
    }

    func testOrderingUpcomingSoonestThenRecentReleases() {
        let t = target(max: 1)
        let today = date("2026-10-28")
        let catalog = [t.key: [
            product("OLD", "Old", seq: 2, release: "2025-01-01"),
            product("NEW", "New", seq: 3, release: "2026-09-01"),
            product("FAR", "Far", seq: 5, release: "2027-05-01"),
            product("SOON", "Soon", seq: 4, release: "2026-11-09"),
        ]]
        let out = ReleaseRadarPlanner.plan(targets: [t], catalog: catalog, today: today, calendar: cal)
        XCTAssertEqual(out.map(\.asin), ["SOON", "FAR", "NEW", "OLD"])
        XCTAssertEqual(out.first?.status(today: today, calendar: cal), .upcoming(daysUntil: 12))
    }

    func testDuplicateSequencePrefersUnabridgedThenEarliest() {
        let t = target(max: 1)
        let catalog = [t.key: [
            product("ABR", "Abridged", seq: 2, release: "2020-01-01", format: "abridged"),
            product("U2", "Later unabridged", seq: 2, release: "2022-01-01"),
            product("U1", "Earlier unabridged", seq: 2, release: "2021-01-01"),
        ]]
        let out = ReleaseRadarPlanner.plan(targets: [t], catalog: catalog, today: date("2026-10-28"), calendar: cal)
        XCTAssertEqual(out.map(\.asin), ["U1"])
    }

    func testOtherSeriesAndLanguageDropped() {
        let t = target(max: 1)
        let catalog = [t.key: [
            product("DRAMA", "Dramatized", seq: 3, release: "2024-01-01", series: "The Stormlight Archive [Dramatized Adaptation]"),
            product("ES", "Viento", seq: 5, release: "2025-01-01", language: "spanish"),
            product("OK", "Fine", seq: 2, release: "2025-01-01"),
        ]]
        let out = ReleaseRadarPlanner.plan(targets: [t], catalog: catalog, today: date("2026-10-28"), calendar: cal)
        XCTAssertEqual(out.map(\.asin), ["OK"])
    }

    func testDaysUntilAcrossTimeZones() {
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let release = date("2026-11-09", calendar: tokyo)
        // 2026-10-28 20:00 UTC is 29 Oct 05:00 in Tokyo and 28 Oct 13:00 in Los Angeles.
        let now = Date(timeIntervalSince1970: ISO8601DateFormatter().date(from: "2026-10-28T20:00:00Z")!.timeIntervalSince1970)
        XCTAssertEqual(ReleaseRadarPlanner.daysUntil(release, today: now, calendar: tokyo), 11)
        let releaseLA = date("2026-11-09", calendar: la)
        XCTAssertEqual(ReleaseRadarPlanner.daysUntil(releaseLA, today: now, calendar: la), 12)
        XCTAssertEqual(ReleaseRadarPlanner.status(releaseDate: releaseLA, today: date("2026-11-09", calendar: la), calendar: la), .outNotInLibrary)
    }

    func testSeriesToCheckOnlyStartedAndRotates() {
        func book(_ series: String, started: Bool, seq: Double) -> ReleaseRadarPlanner.LibraryBook {
            .init(asin: "A\(series)\(seq)", author: "X", language: "English", isStarted: started, series: [(series, seq)])
        }
        let books = [book("Alpha", started: true, seq: 2), book("Alpha", started: false, seq: 3),
                     book("Beta", started: false, seq: 1), book("Gamma", started: true, seq: 1), book("Delta", started: true, seq: 1)]
        let all = ReleaseRadarPlanner.seriesToCheck(books: books, cap: 10)
        XCTAssertEqual(all.targets.map(\.name), ["Alpha", "Delta", "Gamma"])
        XCTAssertEqual(all.targets.first?.maxOwnedSequence, 3)
        let first = ReleaseRadarPlanner.seriesToCheck(books: books, cap: 2, rotation: 0)
        XCTAssertEqual(first.targets.map(\.name), ["Alpha", "Delta"])
        let second = ReleaseRadarPlanner.seriesToCheck(books: books, cap: 2, rotation: first.nextRotation)
        XCTAssertEqual(second.targets.map(\.name), ["Gamma", "Alpha"])
    }

    func testNormalisedSeriesKey() {
        XCTAssertEqual(ReleaseRadarPlanner.normalisedSeriesKey("The Stormlight Archive"),
                       ReleaseRadarPlanner.normalisedSeriesKey("Stormlight Archive"))
        XCTAssertEqual(ReleaseRadarPlanner.normalisedSeriesKey("Mistborn Series"), "mistborn")
    }

    // Trimmed from a real api.audible.com response (28 Oct 2026).
    private let fixture = """
    {"products":[{"asin":"B0CQDHTSFJ","title":"Wind and Truth","subtitle":"Stormlight Archive, Book 5","authors":[{"asin":"B001IGFHW6","name":"Brandon Sanderson"}],"format_type":"unabridged","language":"english","release_date":"2024-12-06","series":[{"asin":"B006K1RP8I","sequence":"5","title":"The Stormlight Archive","url":"/pd/x"},{"asin":"B0DMXTJ8WH","sequence":"","title":"The Cosmere","url":"/pd/y"}],"product_images":{"500":"https://m.media-amazon.com/images/I/51ZFAWrapyL._SL500_.jpg"},"narrators":[{"name":"Kate Reading"}]},{"bad":true}],"total_results":2}
    """

    func testCatalogDecode() throws {
        let list = CatalogProduct.decodeList(Data(fixture.utf8))
        XCTAssertEqual(list.count, 1)
        let p = try XCTUnwrap(list.first)
        XCTAssertEqual(p.title, "Wind and Truth")
        XCTAssertEqual(p.authors, ["Brandon Sanderson"])
        XCTAssertEqual(p.releaseDate, "2024-12-06")
        XCTAssertEqual(p.series.first?.sequence, 5)
        XCTAssertNil(p.series.last?.sequence)
        XCTAssertEqual(p.coverURL, "https://m.media-amazon.com/images/I/51ZFAWrapyL._SL500_.jpg")
    }

    func testSeriesChildrenDecode() {
        let json = """
        {"product":{"asin":"S","relationships":[{"asin":"B0CQ3759C3","relationship_to_product":"child","relationship_type":"series","sequence":"5"},{"asin":"P","relationship_to_product":"parent","sequence":"1"},{"asin":"B0B75NY8F2","relationship_to_product":"child","sequence":"3.5"}]}}
        """
        let kids = CatalogSeriesChild.decode(Data(json.utf8))
        XCTAssertEqual(kids, [.init(asin: "B0CQ3759C3", sequence: 5), .init(asin: "B0B75NY8F2", sequence: 3.5)])
    }
}
