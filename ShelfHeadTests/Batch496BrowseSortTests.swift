import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 L8): Series sort request, Hide finished, and the letter
/// sections behind the Authors / Narrators index.
final class Batch496BrowseSortTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    // MARK: Series sort request

    func testSortKeysAreTheServersKeys() {
        XCTAssertEqual(SeriesSortOption.name.rawValue, "name")
        XCTAssertEqual(SeriesSortOption.addedAt.rawValue, "addedAt")
        XCTAssertEqual(SeriesSortOption.numBooks.rawValue, "numBooks")
        XCTAssertEqual(SeriesSortOption.totalDuration.rawValue, "totalDuration")
    }

    func testDefaultRequestIsNameAscendingNoFilter() {
        let r = SeriesListQuery().request
        XCTAssertEqual(r, SeriesListQuery.Request(sort: "name", desc: false, filter: nil))
    }

    func testRequestCarriesSortAndDirection() {
        let r = SeriesListQuery(sort: .totalDuration, descending: true, hideFinished: false).request
        XCTAssertEqual(r.sort, "totalDuration")
        XCTAssertTrue(r.desc)
        XCTAssertNil(r.filter)
    }

    func testHideFinishedUsesProgressNotFinishedFilter() {
        let r = SeriesListQuery(sort: .name, descending: false, hideFinished: true).request
        XCTAssertEqual(r.filter, "progress.bm90LWZpbmlzaGVk")
    }

    func testDefaultDirections() {
        XCTAssertFalse(SeriesSortOption.name.defaultDescending)
        for o in SeriesSortOption.allCases where o != .name { XCTAssertTrue(o.defaultDescending) }
    }

    // MARK: Hide finished

    private func book(_ id: String, finished: Bool) -> ShelfHead.LibraryItem {
        // Finished state is supplied through the closure; only identity matters here.
        ShelfHead.LibraryItem(id: id, ino: nil, libraryId: nil, mediaType: "book", media: nil, numFiles: nil,
                    size: nil, addedAt: nil, updatedAt: nil, mediaProgress: nil)
    }

    private func series(_ id: String, _ books: [ShelfHead.LibraryItem]?) -> Series {
        Series(id: id, name: id, books: books, addedAt: nil, totalDuration: nil)
    }

    func testHideFinishedDropsSeriesWhoseBooksAreAllFinished() {
        let done = series("s1", [book("a", finished: true), book("b", finished: true)])
        let open = series("s2", [book("c", finished: true), book("d", finished: false)])
        let finishedIds: Set<String> = ["a", "b", "c"]
        let out = SeriesListQuery.visible([done, open], hideFinished: true) { finishedIds.contains($0.id) }
        XCTAssertEqual(out.map(\.id), ["s2"])
    }

    func testHideFinishedOffReturnsEverything() {
        let s = series("s1", [book("a", finished: true)])
        XCTAssertEqual(SeriesListQuery.visible([s], hideFinished: false) { _ in true }.count, 1)
    }

    func testSeriesWithoutBookDataIsKept() {
        let s = series("s1", nil)
        XCTAssertEqual(SeriesListQuery.visible([s], hideFinished: true) { _ in true }.count, 1)
    }

    // MARK: People sections

    func testSectionKeys() {
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "Anne Rice", locale: en), "A")
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "élodie", locale: en), "E")
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "  zed", locale: en), "Z")
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "50 Cent", locale: en), "#")
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "\"Weird Al\"", locale: en), "#")
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "", locale: en), "#")
    }

    func testChineseNamesSectionByPinyinInitial() {
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "张三", locale: en), "Z")
        XCTAssertEqual(BrowseLetterIndex.sectionKey(for: "王芳", locale: en), "W")
    }

    func testSectionsAreOrderedWithHashLastAndSkipEmpty() {
        let names = ["Zoe", "bob", "Álvaro", "7 Up", "Adam", "Carl"]
        let s = BrowseLetterIndex.sections(names, name: { $0 }, locale: en)
        XCTAssertEqual(s.map(\.key), ["A", "B", "C", "Z", "#"])
        XCTAssertEqual(s[0].items, ["Adam", "Álvaro"])
    }

    func testLayoutKeepsStarredSeparateAndOutOfLetters() {
        let r = BrowseLetterIndex.layout(starred: ["Mia", "Abe"], rest: ["Ben", "Zed"], name: { $0 }, locale: en)
        XCTAssertEqual(r.starred, ["Abe", "Mia"])
        XCTAssertEqual(r.sections.map(\.key), ["B", "Z"])
        XCTAssertEqual(BrowseLetterIndex.displayedFirst(starred: r.starred, sections: r.sections), "Abe")
    }

    func testDisplayedFirstWithoutStarred() {
        let r = BrowseLetterIndex.layout(starred: [String](), rest: ["Ben", "Abe"], name: { $0 }, locale: en)
        XCTAssertEqual(BrowseLetterIndex.displayedFirst(starred: r.starred, sections: r.sections), "Abe")
    }
}
