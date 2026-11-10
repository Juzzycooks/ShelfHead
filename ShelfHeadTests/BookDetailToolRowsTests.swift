import XCTest
@testable import ShelfHead

/// Batch 450: pins which rows Book Detail's grouped list shows, and in what order.
final class BookDetailToolRowsTests: XCTestCase {
    private func rows(podcast: Bool = false, chapters: Int = 0, bookmarks: Int = 0, failed: Bool = false,
                      transcript: Bool = false, searchable: Bool = false,
                      ebook: Bool = false) -> [BookDetailView.BookToolRow] {
        BookDetailView.bookToolRows(isPodcast: podcast, chapterCount: chapters, bookmarkCount: bookmarks,
                                    bookmarksLoadFailed: failed, showsTranscript: transcript,
                                    hasSearchableTranscript: searchable, hasCompanionEbook: ebook)
    }

    func testEverythingInOrder() {
        XCTAssertEqual(rows(chapters: 24, bookmarks: 3, transcript: true, searchable: true, ebook: true),
                       [.chapters, .bookmarks, .transcript, .xray, .ask, .ebook])
    }

    func testNothingShowsNoRows() {
        XCTAssertEqual(rows(), [])
    }

    func testFailedBookmarksOnlyWhenThereAreNone() {
        XCTAssertEqual(rows(failed: true), [.bookmarksFailed])
        XCTAssertEqual(rows(bookmarks: 2, failed: true), [.bookmarks])
    }

    func testXRayAndAskNeedSearchableTranscript() {
        XCTAssertEqual(rows(transcript: true), [.transcript])
    }

    func testPodcastsGetOnlyChaptersAndBookmarks() {
        XCTAssertEqual(rows(podcast: true, chapters: 5, bookmarks: 1, transcript: true, searchable: true, ebook: true),
                       [.chapters, .bookmarks])
    }
}
