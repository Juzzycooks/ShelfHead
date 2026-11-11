import XCTest
import PDFKit
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11): the pure decisions behind the Book Detail, Upload and reader
/// quick wins (L5, L9, E6, F31).
final class QuickWinsBookDetailTests: XCTestCase {

    // MARK: - L5: upload busy state

    func testUploadPhaseIsBusyOnlyWhileSending() {
        XCTAssertTrue(UploadViewModel.Phase.preparing.isBusy)
        XCTAssertTrue(UploadViewModel.Phase.uploading(sent: 10, total: 100).isBusy)
        XCTAssertFalse(UploadViewModel.Phase.loading.isBusy)
        XCTAssertFalse(UploadViewModel.Phase.notPermitted.isBusy)
        XCTAssertFalse(UploadViewModel.Phase.editing.isBusy)
        XCTAssertFalse(UploadViewModel.Phase.done.isBusy)
        XCTAssertFalse(UploadViewModel.Phase.failed("x").isBusy)
    }

    // MARK: - E6: upload error copy

    func testUploadOfflineError() {
        let error = URLError(.notConnectedToInternet)
        let message = UploadViewModel.message(for: error)
        XCTAssertEqual(message, "You’re offline. Connect to the internet and try again.")
        XCTAssertFalse(message.contains(error.localizedDescription))
    }

    func testUploadUnreachableError() {
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .cannotFindHost, .networkConnectionLost] {
            XCTAssertEqual(UploadViewModel.message(for: URLError(code)),
                           "Can’t reach your server. Check that it’s running and try again.", "\(code)")
        }
    }

    func testUploadFileErrors() {
        XCTAssertEqual(UploadViewModel.message(for: CocoaError(.fileWriteOutOfSpace)),
                       "This iPhone is out of space, so the upload couldn’t be prepared. Free some space and try again.")
        let unreadable = CocoaError(.fileReadNoPermission)
        let message = UploadViewModel.message(for: unreadable)
        XCTAssertEqual(message, "One of the files couldn’t be read. Remove it, add it again and try once more.")
        XCTAssertFalse(message.contains(unreadable.localizedDescription))
    }

    func testUploadUnknownErrorIsGeneric() {
        struct Odd: Error {}
        XCTAssertEqual(UploadViewModel.message(for: Odd()), "Something went wrong. Try again in a moment.")
        XCTAssertEqual(UploadViewModel.message(for: URLError(.cancelled)), "Something went wrong. Try again in a moment.")
    }

    func testUploadAPIErrorsKeepTheirSentences() {
        XCTAssertEqual(UploadViewModel.message(for: APIError.forbidden),
                       "This account isn't allowed to upload to that library.")
        XCTAssertFalse(UploadViewModel.message(for: APIError.httpError(418)).contains("418"))
    }

    // MARK: - E6: ebook reader copy

    func testEbookReaderUnreachableAndOtherErrors() {
        XCTAssertEqual(EbookReaderView.downloadFailureMessage(for: URLError(.cannotConnectToHost)),
                       "Can’t reach your server. Check that it’s running and try again.")
        let write = CocoaError(.fileWriteOutOfSpace)
        let message = EbookReaderView.downloadFailureMessage(for: write)
        XCTAssertEqual(message, "This file couldn’t be opened. Try again, or check the file on your server.")
        XCTAssertFalse(message.contains(write.localizedDescription))
    }

    // MARK: - L9: Book Detail header and Details rows

    func testSubtitleIsTrimmedAndEmptyIsHidden() {
        XCTAssertEqual(BookDetailView.displaySubtitle("  A Novel \n"), "A Novel")
        XCTAssertNil(BookDetailView.displaySubtitle("   "))
        XCTAssertNil(BookDetailView.displaySubtitle(nil))
    }

    func testAuthorLinkDependsOnMetadataNotTheFallbackText() {
        XCTAssertTrue(BookDetailView.hasAuthor("Ursula K. Le Guin"))
        XCTAssertFalse(BookDetailView.hasAuthor(nil))
        XCTAssertFalse(BookDetailView.hasAuthor(""))
        XCTAssertFalse(BookDetailView.hasAuthor(" \n"))
    }

    func testSizeText() {
        XCTAssertNil(BookDetailView.sizeText(bytes: nil))
        XCTAssertNil(BookDetailView.sizeText(bytes: 0))
        XCTAssertEqual(BookDetailView.sizeText(bytes: 1_500_000_000),
                       ByteCountFormatter.string(fromByteCount: 1_500_000_000, countStyle: .file))
    }

    func testAudioFileCountText() {
        XCTAssertNil(BookDetailView.audioFileCountText(nil))
        XCTAssertNil(BookDetailView.audioFileCountText(0))
        XCTAssertEqual(BookDetailView.audioFileCountText(12), 12.formatted())
        XCTAssertEqual(BookDetailView.audioFileCountText(1_024), 1_024.formatted())
    }

    // MARK: - F31: PDF Go to Page

    func testPageIndexFromInput() {
        XCTAssertEqual(EbookReaderView.pageIndex(fromInput: "1", pageCount: 10), 0)
        XCTAssertEqual(EbookReaderView.pageIndex(fromInput: " 7 ", pageCount: 10), 6)
        XCTAssertEqual(EbookReaderView.pageIndex(fromInput: "99", pageCount: 10), 9)
        XCTAssertEqual(EbookReaderView.pageIndex(fromInput: "0", pageCount: 10), 0)
        XCTAssertEqual(EbookReaderView.pageIndex(fromInput: "-3", pageCount: 10), 0)
        XCTAssertNil(EbookReaderView.pageIndex(fromInput: "", pageCount: 10))
        XCTAssertNil(EbookReaderView.pageIndex(fromInput: "abc", pageCount: 10))
        XCTAssertNil(EbookReaderView.pageIndex(fromInput: "3", pageCount: 0))
    }

    // MARK: - F31: PDF Contents

    func testOutlineEntriesFlattenInReadingOrderWithLevels() {
        let document = PDFDocument()
        for i in 0..<3 { document.insert(PDFPage(), at: i) }
        let root = PDFOutline()
        let one = outline("One", page: document.page(at: 0)!)
        let oneA = outline("One A", page: document.page(at: 1)!)
        let noPage = PDFOutline()
        noPage.label = "No page"
        let two = outline("Two", page: document.page(at: 2)!)
        one.insertChild(oneA, at: 0)
        root.insertChild(one, at: 0)
        root.insertChild(noPage, at: 1)
        root.insertChild(two, at: 2)
        document.outlineRoot = root

        let entries = EbookReaderView.outlineEntries(root: document.outlineRoot, in: document)
        XCTAssertEqual(entries.map(\.title), ["One", "One A", "Two"])
        XCTAssertEqual(entries.map(\.level), [0, 1, 0])
        XCTAssertEqual(entries.map(\.pageIndex), [0, 1, 2])
        XCTAssertEqual(entries.map(\.id), [0, 1, 2])
    }

    func testOutlineEntriesEmptyWithoutOutline() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        XCTAssertTrue(EbookReaderView.outlineEntries(root: nil, in: document).isEmpty)
    }

    private func outline(_ label: String, page: PDFPage) -> PDFOutline {
        let node = PDFOutline()
        node.label = label
        node.destination = PDFDestination(page: page, at: .zero)
        return node
    }

    // MARK: - F31: EPUB page theme and line spacing

    func testEPUBPageThemeColours() {
        let app: EPUBPageTheme.Colours = (background: "#111111", text: "#EEEEEE", accent: "#FFAA00")
        let match = EPUBPageTheme.matchApp.colours(app: app)
        XCTAssertEqual(match.background, "#111111")
        XCTAssertEqual(match.text, "#EEEEEE")
        let sepia = EPUBPageTheme.sepia.colours(app: app)
        XCTAssertEqual(sepia.background, "#F4ECD8")
        XCTAssertEqual(sepia.text, "#5B4636")
        XCTAssertEqual(sepia.accent, "#8B5A12")
        let black = EPUBPageTheme.black.colours(app: app)
        XCTAssertEqual(black.background, "#000000")
        XCTAssertEqual(black.text, "#EEEEEE")
        XCTAssertEqual(black.accent, "#FFAA00")
    }

    func testEPUBPageThemeDefaultsToMatchApp() {
        XCTAssertEqual(EPUBPageTheme(rawValue: "matchApp"), .matchApp)
        XCTAssertNil(EPUBPageTheme(rawValue: "unknown"))
    }

    func testEPUBLineSpacingCSS() {
        XCTAssertEqual(EPUBLineSpacing.normal.css, "")
        XCTAssertTrue(EPUBLineSpacing.relaxed.css.contains("line-height: 1.9 !important"))
    }
}
