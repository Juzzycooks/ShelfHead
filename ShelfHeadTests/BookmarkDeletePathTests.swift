import XCTest
@testable import ShelfHead

/// Batch 329: pins the `:time` path segment of `DELETE /api/me/item/:id/bookmark/:time`.
///
/// Why this exists: the segment used to be `time.safeSeconds`, and Audiobookshelf (verified
/// on 2.36 with the local test server) stores a bookmark's `time` exactly as posted and
/// matches the delete by numeric equality — so a bookmark at `100.437` could never be
/// deleted through `.../bookmark/100`, and every such delete was misclassified as offline
/// and queued. Same "pin the pure decision, not the request" line as the rest of this suite.
final class BookmarkDeletePathTests: XCTestCase {

    func testFractionalTimeIsSentExactly() {
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: 100.437), "100.437")
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: 15921.4370000001), "15921.4370000001")
    }

    func testIntegralTimeIsSentAsAPlainInteger() {
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: 15921), "15921")
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: 15921.0), "15921")
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: 0), "0")
    }

    /// S4's guarantee survives: nothing here can trap.
    func testGarbageClampsInsteadOfTrapping() {
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: .nan), "0")
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: .infinity), "0")
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: -12.5), "0")
        XCTAssertEqual(AudiobookshelfAPI.bookmarkPathComponent(forTime: 1e300), String(86_400 * 365))
    }

    /// The path must parse back to the identical double the server stored, which is what
    /// `String(Double)`'s shortest round-trip form guarantees.
    func testPathRoundTripsToTheSameDouble() {
        for time in [100.437, 15921.437, 0.1, 1234.000001, 86_399.999] {
            let path = AudiobookshelfAPI.bookmarkPathComponent(forTime: time)
            XCTAssertEqual(Double(path), time, "\(path) must parse back to \(time)")
        }
    }
}
