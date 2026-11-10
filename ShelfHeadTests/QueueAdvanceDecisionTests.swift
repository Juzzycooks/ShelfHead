import XCTest
@testable import ShelfHead

/// Review test gap (progress flush / queue): pins `AudioPlayerService.queuedEntryIsFinished`
/// (review Medium 19), the `isFinished` flag sent with a queued position.
final class QueueAdvanceDecisionTests: XCTestCase {
    private func finished(_ t: Double, _ d: Double, server: Bool = false) -> Bool {
        AudioPlayerService.queuedEntryIsFinished(currentTime: t, duration: d, serverFinished: server)
    }

    func testMidBookIsNotFinished() {
        XCTAssertFalse(finished(500, 1000))
    }

    func testWithinOnePercentOfTheEndIsFinished() {
        XCTAssertTrue(finished(990, 1000))
        XCTAssertTrue(finished(1000, 1000))
        XCTAssertFalse(finished(989, 1000))
    }

    func testServerFinishedKeepsItFinishedWhenReListeningFromPartway() {
        XCTAssertTrue(finished(100, 1000, server: true))
    }

    func testZeroDurationFallsBackToTheServerFlag() {
        XCTAssertFalse(finished(50, 0))
        XCTAssertTrue(finished(50, 0, server: true))
        XCTAssertFalse(finished(50, -1))
    }
}
