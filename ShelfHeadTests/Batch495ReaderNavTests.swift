import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 L13 / L11): the end-of-chapter links and the reader's
/// error messages for the shared ebook cache.
final class Batch495ReaderNavTests: XCTestCase {

    private let spine = ["OEBPS/c1.xhtml", "OEBPS/c2.xhtml", "OEBPS/c3.xhtml"]

    func testTitleComesFromFirstMatchingContentsEntry() {
        let toc = [
            EPUBTOCEntry(title: "One", href: "OEBPS/c1.xhtml", level: 0),
            EPUBTOCEntry(title: "Two", href: "OEBPS/c2.xhtml#start", level: 0),
            EPUBTOCEntry(title: "Two, part B", href: "OEBPS/c2.xhtml#b", level: 1),
        ]
        XCTAssertEqual(EPUBChapterNav.title(forSpineIndex: 0, spineHrefs: spine, toc: toc), "One")
        XCTAssertEqual(EPUBChapterNav.title(forSpineIndex: 1, spineHrefs: spine, toc: toc), "Two")
        XCTAssertNil(EPUBChapterNav.title(forSpineIndex: 2, spineHrefs: spine, toc: toc), "not in the contents")
        XCTAssertNil(EPUBChapterNav.title(forSpineIndex: 3, spineHrefs: spine, toc: toc), "past the end")
        XCTAssertNil(EPUBChapterNav.title(forSpineIndex: -1, spineHrefs: spine, toc: toc))
    }

    func testBlankTitleIsSkipped() {
        let toc = [
            EPUBTOCEntry(title: "  ", href: "OEBPS/c2.xhtml", level: 0),
            EPUBTOCEntry(title: "Chapter Two", href: "OEBPS/c2.xhtml#x", level: 1),
        ]
        XCTAssertEqual(EPUBChapterNav.title(forSpineIndex: 1, spineHrefs: spine, toc: toc), "Chapter Two")
    }

    func testScriptReplacesItselfAndAvoidsReadAlongBlocks() {
        let script = EPUBChapterNav.script
        XCTAssertTrue(script.contains("getElementById('shelfhead-chapter-nav')"))
        XCTAssertTrue(script.contains("old.remove()"))
        XCTAssertTrue(script.contains("createElement('nav')"))
        XCTAssertTrue(script.contains("createElement('a')"))
        XCTAssertTrue(script.contains("min-height: 44px"))
        // Read-along counts p, h1–h6, li, … blocks; the links must not add one.
        for tag in ["'p'", "'li'", "'h1'", "'div'"] {
            XCTAssertFalse(script.contains("createElement(\(tag))"), tag)
        }
    }

    func testStoreErrorsKeepTheirOwnMessage() {
        for error in [EbookStore.StoreError.noFile, .missingInfo, .badURL] {
            XCTAssertEqual(EbookReaderView.downloadFailureMessage(for: error), error.errorDescription)
        }
    }

    func testOfflineMessageStillShownForUncachedBook() {
        let message = EbookReaderView.downloadFailureMessage(for: URLError(.notConnectedToInternet))
        XCTAssertEqual(message, String(localized: "You’re offline. Connect to the internet to open this book."))
    }
}
