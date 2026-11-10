import XCTest
@testable import ShelfHead

/// Pins the deferred item from Batch 317 (`CHANGES_IMPLEMENTED.md`): Downloads rows
/// (`DownloadsView.DownloadedBooksSection`) show a duration-only detail line on each
/// `LibraryListRow`, built by the pure `DownloadRowDetail.text(forDuration:)` formatter.
/// Duration-only (not "duration · size") is a deliberate decision — `DownloadManager`
/// only caches a *total* across all downloads, not a per-item size, and computing one
/// per row would mean a filesystem walk on every row on every render. See
/// `DownloadRowDetail`'s own doc comment in `DownloadsView.swift` for the full reasoning.
final class DownloadRowDetailTests: XCTestCase {

    func testFormatsPositiveDurationAsHoursMinutes() {
        // 8h 12m, matching `Double.formattedDuration`'s own "\(hours)h \(minutes)m" shape.
        let seconds: Double = 8 * 3600 + 12 * 60
        XCTAssertEqual(DownloadRowDetail.text(forDuration: seconds), "8h 12m")
    }

    func testFormatsSubHourDurationInMinutes() {
        let seconds: Double = 45 * 60
        XCTAssertEqual(DownloadRowDetail.text(forDuration: seconds), "45m")
    }

    func testZeroDurationOmitsTheDetailLine() {
        // A manifest with no recorded duration shows no detail line at all, rather than
        // a misleading "0h 0m" — matches `LibraryListRow.detail`'s own `nil`-omits
        // convention.
        XCTAssertNil(DownloadRowDetail.text(forDuration: 0))
    }

    func testNegativeOrNonFiniteDurationOmitsTheDetailLine() {
        XCTAssertNil(DownloadRowDetail.text(forDuration: -1))
        XCTAssertNil(DownloadRowDetail.text(forDuration: .nan))
        XCTAssertNil(DownloadRowDetail.text(forDuration: .infinity))
    }
}
