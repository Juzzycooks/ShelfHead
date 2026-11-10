import XCTest
@testable import ShelfHead

/// Phase 1, Batch 422: how far into the book the listener has heard.
final class ListeningFrontierTests: XCTestCase {
    func testTakesTheMaximum() {
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: 100, progressTime: 300, currentTime: 200), 300)
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: 500, progressTime: 300, currentTime: 200), 500)
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: 100, progressTime: 300, currentTime: 900), 900)
    }

    func testIgnoresNils() {
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: nil, progressTime: 42, currentTime: nil), 42)
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: nil, progressTime: nil, currentTime: nil), 0)
    }

    func testIgnoresNonFinite() {
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: .nan, progressTime: .infinity, currentTime: 12), 12)
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: -.infinity, progressTime: nil, currentTime: nil), 0)
    }

    func testNeverNegative() {
        XCTAssertEqual(ListeningFrontier.frontier(storedHighWater: -5, progressTime: -1, currentTime: -100), 0)
    }
}
