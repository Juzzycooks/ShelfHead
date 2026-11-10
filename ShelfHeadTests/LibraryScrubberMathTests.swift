import XCTest
@testable import ShelfHead

/// Library browse plan §3.1 / §8 step 1 (2026-10-05): pins the scrubber's pure decisions.
final class LibraryScrubberMathTests: XCTestCase {

    func testIndexEndpoints() {
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 0, count: 3000), 0)
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 1, count: 3000), 2999)
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: -1, count: 3000), 0)
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 2, count: 3000), 2999)
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 0.5, count: 0), 0)
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 0.5, count: 1), 0)
    }

    func testIndexRounds() {
        // count 11 -> indices 0...10; 0.34 * 10 = 3.4 -> 3, 0.36 * 10 = 3.6 -> 4
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 0.34, count: 11), 3)
        XCTAssertEqual(LibraryScrubberMath.index(forFraction: 0.36, count: 11), 4)
    }

    func testFractionRoundTrip() {
        XCTAssertEqual(LibraryScrubberMath.fraction(forIndex: 0, count: 3000), 0)
        XCTAssertEqual(LibraryScrubberMath.fraction(forIndex: 2999, count: 3000), 1)
        XCTAssertEqual(LibraryScrubberMath.fraction(forIndex: 5, count: 1), 0)
        for i in [0, 1, 49, 50, 1449, 2999] {
            let f = LibraryScrubberMath.fraction(forIndex: i, count: 3000)
            XCTAssertEqual(LibraryScrubberMath.index(forFraction: f, count: 3000), i)
        }
    }

    func testRowSnap() {
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(0, columns: 2), 0)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(1, columns: 2), 0)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(7, columns: 2), 6)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(2, columns: 3), 0)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(3, columns: 3), 3)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(1450, columns: 3), 1449)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(9, columns: 0), 9)
        XCTAssertEqual(LibraryScrubberMath.rowSnappedIndex(-4, columns: 2), 0)
    }

    func testThreshold() {
        XCTAssertFalse(LibraryScrubberMath.showsScrubber(count: 0))
        XCTAssertFalse(LibraryScrubberMath.showsScrubber(count: 119))
        XCTAssertTrue(LibraryScrubberMath.showsScrubber(count: 120))
        XCTAssertTrue(LibraryScrubberMath.showsScrubber(count: 3000))
    }

    func testPositionTextIsOneBasedAndLocaleFormatted() {
        XCTAssertEqual(LibraryScrubberMath.positionText(index: 0, total: 3000, locale: Locale(identifier: "en_US")),
                       "Book 1 of 3,000")
        XCTAssertEqual(LibraryScrubberMath.positionText(index: 1449, total: 3000, locale: Locale(identifier: "en_US")),
                       "Book 1,450 of 3,000")
        let de = LibraryScrubberMath.positionText(index: 1449, total: 3000, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(de.contains("1.450") && de.contains("3.000"), de)
        // Out-of-range index clamps to the last book.
        XCTAssertEqual(LibraryScrubberMath.positionText(index: 9999, total: 212, locale: Locale(identifier: "en_US")),
                       "Book 212 of 212")
        XCTAssertEqual(LibraryScrubberMath.positionText(index: 0, total: 0, locale: Locale(identifier: "en_US")),
                       "Book 0 of 0")
    }

    func testVoiceOverStep() {
        XCTAssertEqual(LibraryScrubberMath.voiceOverStep(total: 120), 50)
        XCTAssertEqual(LibraryScrubberMath.voiceOverStep(total: 5000), 50)
        XCTAssertEqual(LibraryScrubberMath.voiceOverStep(total: 10_000), 500)
    }

    func testCrossedPageBoundary() {
        XCTAssertFalse(LibraryScrubberMath.crossedPageBoundary(from: 0, to: 49, pageSize: 50))
        XCTAssertTrue(LibraryScrubberMath.crossedPageBoundary(from: 49, to: 50, pageSize: 50))
        XCTAssertTrue(LibraryScrubberMath.crossedPageBoundary(from: 120, to: 10, pageSize: 50))
        XCTAssertFalse(LibraryScrubberMath.crossedPageBoundary(from: 60, to: 60, pageSize: 50))
    }
}
