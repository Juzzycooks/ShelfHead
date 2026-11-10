import XCTest
@testable import ShelfHead

/// R9 (REVIEW_2026-09-04_UI.md): the "Bookmark this moment" button showed whole-book
/// time while the player behind it (and the scrubber) is chapter-relative once chapter
/// data exists. `BookmarksSheet.momentLabel` is the pure function both the live button
/// label and the captured-time alert message were extracted to use, so it's pinned here
/// directly rather than through the view.
final class BookmarkMomentLabelTests: XCTestCase {

    func testMomentLabelWithChapterIsChapterRelative() throws {
        // Chapter only has a Decodable init (from decoder:), no memberwise init —
        // build one via JSON to match its CodingKeys (id, start, end, title).
        let json = #"{"id": 1, "start": 100, "end": 500, "title": "Chapter Title"}"#
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
        XCTAssertEqual(BookmarksSheet.momentLabel(time: 352, chapter: chapter), "4:12 · Chapter Title")
    }

    func testMomentLabelWithoutChapterIsWholeBook() {
        XCTAssertEqual(BookmarksSheet.momentLabel(time: 352, chapter: nil), 352.formattedTime)
    }
}
