import XCTest
@testable import ShelfHead

/// Pins `BookmarkMarkdownExporter`'s pure formatting so the Markdown shape (header,
/// chapter parenthetical, note quoting, sort order) and filename sanitisation don't
/// regress silently.
final class BookmarkMarkdownExporterTests: XCTestCase {
    private func bookmark(_ title: String, _ time: Double) -> AudioBookmark {
        AudioBookmark(libraryItemId: "item1", title: title, time: time, createdAt: 1_000)
    }

    // `Chapter` has a custom `init(from:)` (lossy decoding), so no memberwise init
    // exists — build it the same way `LossyChapterDecodingTests` does, via JSON.
    private func chapter(id: Int, start: Double, end: Double, title: String) throws -> Chapter {
        let json = #"{"id": \#(id), "start": \#(start), "end": \#(end), "title": "\#(title)"}"#
        return try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
    }

    func testHeaderLines() {
        let md = BookmarkMarkdownExporter.markdown(
            bookTitle: "My Book", author: "Some Author", chapters: [], bookmarks: [], notes: [:])
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# My Book")
        XCTAssertEqual(lines[1], "_Some Author_")
    }

    func testChapterParentheticalAndNoteQuote() throws {
        let ch = try chapter(id: 0, start: 0, end: 600, title: "Chapter One")
        let bm = bookmark("A moment", 65)
        let md = BookmarkMarkdownExporter.markdown(
            bookTitle: "Book", author: nil, chapters: [ch], bookmarks: [bm],
            notes: [bm.id: "A longer note"])
        XCTAssertTrue(md.contains("(Chapter One ·"), "expected chapter parenthetical, got: \(md)")
        XCTAssertTrue(md.contains("— A moment"))
        XCTAssertTrue(md.contains("> A longer note"))
    }

    func testNoChaptersOmitsParenthetical() {
        let bm = bookmark("A moment", 65)
        let md = BookmarkMarkdownExporter.markdown(
            bookTitle: "Book", author: nil, chapters: [], bookmarks: [bm], notes: [:])
        XCTAssertFalse(md.contains("("))
    }

    func testBookmarksSortedByTime() {
        let late = bookmark("Late", 200)
        let early = bookmark("Early", 10)
        let md = BookmarkMarkdownExporter.markdown(
            bookTitle: "Book", author: nil, chapters: [], bookmarks: [late, early], notes: [:])
        let earlyRange = md.range(of: "— Early")
        let lateRange = md.range(of: "— Late")
        XCTAssertNotNil(earlyRange)
        XCTAssertNotNil(lateRange)
        XCTAssertTrue(earlyRange!.lowerBound < lateRange!.lowerBound)
    }

    func testFilenameStemIsSanitised() throws {
        let url = try XCTUnwrap(BookmarkMarkdownExporter.writeExportFile(
            markdown: "# x", filenameStem: "My Book: Part 2!"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.lastPathComponent, "My-Book-Part-2-bookmarks.md")
    }
}
