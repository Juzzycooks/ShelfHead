import XCTest
@testable import ShelfHead

/// F3 (REVIEW_2026-09-04_UI.md): the Library filter sheet had no result count
/// anywhere, so it was impossible to tell how many books a Smart Filter or the
/// Progress/Downloaded-only/Sort controls actually left visible without dismissing
/// the sheet. `LibraryFilterSheet.resultCountLabel` is the pure copy function behind
/// that count line — pinned here since the surrounding view needs a live
/// `LibraryViewModel`/`DownloadManager` and isn't unit-testable directly.
final class LibraryFilterSheetCopyTests: XCTestCase {

    func testZeroResults() {
        XCTAssertEqual(LibraryFilterSheet.resultCountLabel(0), "No books match")
    }

    func testSingularResult() {
        XCTAssertEqual(LibraryFilterSheet.resultCountLabel(1), "1 book")
    }

    func testPluralResults() {
        XCTAssertEqual(LibraryFilterSheet.resultCountLabel(42), "42 books")
    }

    // MARK: - Smart Filters chip count/a11y copy
    //
    // Follow-up to Batch 319/320 (CHANGES_IMPLEMENTED.md): the Home Smart Filters
    // shelf shipped hidden by default, so the Library filter sheet's grid became
    // most users' only route to Smart Filters. These pin the two pure functions
    // behind giving each chip a free (never-fetched) match count, same rationale
    // as the tests above — the surrounding chip needs a live `LibraryViewModel`
    // and isn't unit-testable directly.

    func testChipCountTextNilWhenNoCount() {
        XCTAssertNil(LibraryFilterSheet.smartFilterChipCountText(nil))
    }

    func testChipCountTextShowsZero() {
        // 0 is a legitimate "matches nothing" answer, not "no count available" —
        // must still render, not be treated the same as nil.
        XCTAssertEqual(LibraryFilterSheet.smartFilterChipCountText(0), "0")
    }

    func testChipCountTextShowsPositiveCount() {
        XCTAssertEqual(LibraryFilterSheet.smartFilterChipCountText(7), "7")
    }

    func testChipAccessibilityLabelPlainWhenNoCount() {
        XCTAssertEqual(
            LibraryFilterSheet.smartFilterChipAccessibilityLabel(label: "Nearly Finished", count: nil),
            "Nearly Finished"
        )
    }

    func testChipAccessibilityLabelSingularCount() {
        XCTAssertEqual(
            LibraryFilterSheet.smartFilterChipAccessibilityLabel(label: "Nearly Finished", count: 1),
            "Nearly Finished, 1 book"
        )
    }

    func testChipAccessibilityLabelPluralCount() {
        XCTAssertEqual(
            LibraryFilterSheet.smartFilterChipAccessibilityLabel(label: "Nearly Finished", count: 3),
            "Nearly Finished, 3 books"
        )
    }

    func testChipAccessibilityLabelZeroCountIsPlural() {
        XCTAssertEqual(
            LibraryFilterSheet.smartFilterChipAccessibilityLabel(label: "Missing Covers", count: 0),
            "Missing Covers, 0 books"
        )
    }
}
