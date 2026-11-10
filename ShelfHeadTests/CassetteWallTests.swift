import XCTest
@testable import ShelfHead

/// Batch 459: Cassette Wall pure logic: year grouping, spine colour, narrator splitting,
/// incremental catalog merge, `finishedAt` millisecond decoding.
final class CassetteWallTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func book(_ id: String, _ finished: Date, title: String? = nil) -> FinishedBook {
        FinishedBook(id: id, title: title ?? id, author: "A", narratorName: nil, narrators: [], genres: [],
                     publishedYear: nil, finishedAt: finished, duration: 3600, coverPath: nil)
    }

    // MARK: Grouping

    func testGroupsNewestYearFirstAndNewestWithinYear() {
        let books = [book("a", date(2024, 3, 1)), book("b", date(2025, 1, 5)),
                     book("c", date(2024, 11, 9)), book("d", date(2025, 8, 20))]
        let groups = CassetteWallLayout.groupByYear(books, calendar: cal)
        XCTAssertEqual(groups.map(\.year), [2025, 2024])
        XCTAssertEqual(groups[0].books.map(\.id), ["d", "b"])
        XCTAssertEqual(groups[1].books.map(\.id), ["c", "a"])
    }

    func testSameDateTieBreaksOnTitleThenId() {
        let d = date(2025, 5, 5)
        let groups = CassetteWallLayout.groupByYear([book("2", d, title: "B"), book("1", d, title: "A")], calendar: cal)
        XCTAssertEqual(groups[0].books.map(\.id), ["1", "2"])
    }

    // MARK: Spine colour

    func testShellToneIsStableAndInBand() {
        let t = CassetteWallLayout.shellTone(for: "li_abc")
        XCTAssertEqual(t, CassetteWallLayout.shellTone(for: "li_abc"))
        for id in ["a", "b", "c", "li_123", "xyz"] {
            let s = CassetteWallLayout.shellTone(for: id)
            XCTAssertTrue((0..<1).contains(s.hue))
            XCTAssertTrue((0.22...0.52).contains(s.saturation))
            XCTAssertTrue((0.34...0.60).contains(s.brightness))
        }
    }

    // MARK: Narrators / decoding

    func testSplitNarratorsCommasAndAmpersands() {
        XCTAssertEqual(FinishedBook.splitNarrators("Stephen Fry, Jim Dale & Rosamund Pike"),
                       ["Stephen Fry", "Jim Dale", "Rosamund Pike"])
        XCTAssertEqual(FinishedBook.splitNarrators("  Ray Porter  "), ["Ray Porter"])
        XCTAssertEqual(FinishedBook.splitNarrators("A, ,B,a"), ["A", "B"])
        XCTAssertEqual(FinishedBook.splitNarrators("Tom and Jerry"), ["Tom and Jerry"])
        XCTAssertEqual(FinishedBook.splitNarrators(nil), [])
        XCTAssertEqual(FinishedBook.splitNarrators(""), [])
    }

    func testMillisecondDateDecoding() {
        XCTAssertEqual(FinishedBook.date(fromMilliseconds: 1_700_000_000_000), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(FinishedBook.date(fromMilliseconds: 0))
        XCTAssertNil(FinishedBook.date(fromMilliseconds: nil))
    }

    func testYearFromPublished() {
        XCTAssertEqual(FinishedBook.year(fromPublished: "1998"), 1998)
        XCTAssertEqual(FinishedBook.year(fromPublished: "2003-04-01"), 2003)
        XCTAssertNil(FinishedBook.year(fromPublished: "n/a"))
        XCTAssertNil(FinishedBook.year(fromPublished: nil))
    }

    func testRefsFromProgressDecodedFromJSON() throws {
        let json = """
        [{"id":"p1","libraryItemId":"li_1","isFinished":true,"finishedAt":1700000000000,"lastUpdate":1,"progress":1},
         {"id":"p2","libraryItemId":"li_2","isFinished":false,"finishedAt":1700000100000},
         {"id":"p3","libraryItemId":"li_3","isFinished":true,"lastUpdate":1600000000000},
         {"id":"p4","libraryItemId":"li_4","isFinished":true},
         {"id":"p5","libraryItemId":"li_5","episodeId":"ep","isFinished":true,"finishedAt":1700000200000}]
        """
        let progress = try JSONDecoder().decode([MediaProgress].self, from: Data(json.utf8))
        let refs = FinishedRef.refs(from: progress)
        XCTAssertEqual(refs.map(\.itemId), ["li_1", "li_3"])   // unfinished, dateless and episode records dropped; newest first
        XCTAssertEqual(refs[0].finishedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(refs[1].finishedAt, Date(timeIntervalSince1970: 1_600_000_000))   // lastUpdate fallback
    }

    // MARK: Incremental merge

    func testIdsToFetchSkipsCached() {
        let cached = [book("a", date(2025, 1, 1))]
        let refs = [FinishedRef(itemId: "a", finishedAt: date(2025, 1, 1)), FinishedRef(itemId: "b", finishedAt: date(2025, 2, 1))]
        XCTAssertEqual(FinishedBookCatalogMerge.idsToFetch(cached: cached, refs: refs), ["b"])
    }

    func testMergeAddsFetchedDropsUnfinishedAndTakesServerDate() {
        let cached = [book("a", date(2024, 1, 1)), book("gone", date(2024, 2, 1))]
        let fetched = [book("b", date(2025, 3, 3))]
        let refs = [FinishedRef(itemId: "a", finishedAt: date(2025, 9, 9)),    // re-finished: new date wins
                    FinishedRef(itemId: "b", finishedAt: date(2025, 3, 3))]
        let merged = FinishedBookCatalogMerge.merge(cached: cached, fetched: fetched, refs: refs)
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertEqual(merged[0].finishedAt, date(2025, 9, 9))
        XCTAssertFalse(merged.contains { $0.id == "gone" })
    }

    func testMergeSkipsRefWithNoMetadata() {
        let merged = FinishedBookCatalogMerge.merge(cached: [], fetched: [],
                                                    refs: [FinishedRef(itemId: "x", finishedAt: date(2025, 1, 1))])
        XCTAssertTrue(merged.isEmpty)
    }

    func testFinishedBookCodableRoundTrip() throws {
        let b = FinishedBook(id: "i", title: "T", author: "A", narratorName: "N1, N2", narrators: ["N1", "N2"],
                             genres: ["Fantasy"], publishedYear: 1999, finishedAt: date(2025, 1, 1), duration: 10, coverPath: "/c")
        let back = try JSONDecoder().decode(FinishedBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }
}
