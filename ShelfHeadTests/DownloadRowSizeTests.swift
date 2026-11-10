import XCTest
@testable import ShelfHead

/// Pins Batch 318's follow-up to Batch 317's `DownloadRowDetail`: the formatter now
/// also takes a cached on-disk byte count (`DownloadManager.itemStorageBytes`) and
/// produces "8h 12m · 412 MB" — falling back to duration-only when the size isn't
/// known yet (e.g. before the first post-launch storage walk lands). See
/// `DownloadRowDetail`'s own doc comment in `DownloadsView.swift` for the full
/// reasoning, and `DownloadRowDetailTests` for the pre-existing duration-only
/// coverage this file doesn't duplicate.
final class DownloadRowSizeTests: XCTestCase {

    private let eightHoursTwelveMinutes: Double = 8 * 3600 + 12 * 60

    func testCombinesDurationAndSize() {
        // 412 MB, matching `ByteCountFormatter`'s `.file` count style (decimal MB, not
        // binary MiB).
        let bytes: Int64 = 412_000_000
        XCTAssertEqual(
            DownloadRowDetail.text(forDuration: eightHoursTwelveMinutes, bytes: bytes),
            "8h 12m · 412 MB"
        )
    }

    func testFallsBackToDurationOnlyWhenBytesIsNil() {
        XCTAssertEqual(
            DownloadRowDetail.text(forDuration: eightHoursTwelveMinutes, bytes: nil),
            "8h 12m"
        )
    }

    func testFallsBackToDurationOnlyWhenBytesIsZeroOrNegative() {
        // Zero/negative reads as "not cached yet" (the cache is only ever populated
        // with real positive byte counts), not as a literal empty book.
        XCTAssertEqual(
            DownloadRowDetail.text(forDuration: eightHoursTwelveMinutes, bytes: 0),
            "8h 12m"
        )
        XCTAssertEqual(
            DownloadRowDetail.text(forDuration: eightHoursTwelveMinutes, bytes: -1),
            "8h 12m"
        )
    }

    func testShowsSizeOnlyWhenDurationIsUnknown() {
        // A manifest with no recorded duration but a known size shows the size alone
        // rather than omitting the whole detail line.
        XCTAssertEqual(DownloadRowDetail.text(forDuration: 0, bytes: 412_000_000), "412 MB")
        XCTAssertEqual(DownloadRowDetail.text(forDuration: .nan, bytes: 412_000_000), "412 MB")
    }

    func testOmitsDetailLineWhenBothAreUnknown() {
        XCTAssertNil(DownloadRowDetail.text(forDuration: 0, bytes: nil))
        XCTAssertNil(DownloadRowDetail.text(forDuration: -1, bytes: 0))
    }

    func testDefaultBytesParameterMatchesExplicitNil() {
        // The single-argument call `DownloadRowDetailTests` pins must keep compiling
        // and behaving exactly as it did before `bytes` was added.
        XCTAssertEqual(
            DownloadRowDetail.text(forDuration: eightHoursTwelveMinutes),
            DownloadRowDetail.text(forDuration: eightHoursTwelveMinutes, bytes: nil)
        )
    }
}
