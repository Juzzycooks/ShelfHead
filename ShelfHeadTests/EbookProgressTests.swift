import XCTest
@testable import ShelfHead

/// P-15 (REVIEW_2026-09-14_DESIGN.md): the ebook reader now writes its PDF reading
/// position back to Audiobookshelf (`ebookLocation`/`ebookProgress` via
/// `AudiobookshelfAPI.updateEbookProgress`). The page → progress-fraction mapping is the
/// one pure decision in that change, so it's pinned here rather than through the
/// stateful network/PDFKit path — this project's convention (see
/// `DownloadManager.shouldReclaimOrphanDirectory`, `PendingProgressQueueTests`, etc.).
final class EbookProgressTests: XCTestCase {

    func testFirstPageOfManyIsNearZero() {
        XCTAssertEqual(EbookReaderView.ebookProgressFraction(pageIndex: 0, pageCount: 300), 0)
    }

    func testMidBookPageIsRoughlyHalfway() {
        let fraction = EbookReaderView.ebookProgressFraction(pageIndex: 150, pageCount: 300)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.0001)
    }

    func testLastValidPageIndexIsJustUnderOne() {
        // `pageIndex` is 0-based (as PDFKit reports it), so the last real page (299 of
        // 300) lands at 299/300 — just under, not exactly, 1.0. That matches what the
        // reader can actually observe: `PDFViewPageChanged` reports the page the user is
        // ON, not "pages read," so there is no in-range index that means "finished."
        let fraction = EbookReaderView.ebookProgressFraction(pageIndex: 299, pageCount: 300)
        XCTAssertEqual(fraction, 299.0 / 300.0, accuracy: 0.0001)
    }

    func testZeroPageCountNeverDividesByZero() {
        // Defensive: a corrupt/empty `PDFDocument` reporting zero pages must not crash or
        // produce NaN/infinity, since this value is sent straight to the server.
        XCTAssertEqual(EbookReaderView.ebookProgressFraction(pageIndex: 0, pageCount: 0), 0)
    }

    func testNegativePageIndexClampsToZero() {
        XCTAssertEqual(EbookReaderView.ebookProgressFraction(pageIndex: -5, pageCount: 300), 0)
    }

    func testOutOfRangePageIndexClampsToPageCount() {
        // Shouldn't happen (PDFKit only ever reports in-range pages), but the fraction
        // must still stay finite and non-negative if it ever did.
        let fraction = EbookReaderView.ebookProgressFraction(pageIndex: 9_999, pageCount: 300)
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }
}
