import XCTest
@testable import ShelfHead

// Batch 473 review 2 (30 October 2026): the download retry / restart token.
final class DownloadReview2Tests: XCTestCase {
    func testSameLiveRunRequiresMatchingTokenAndNotCancelled() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(DownloadManager.isSameLiveRun(entry: (a, false), runId: a))
        XCTAssertFalse(DownloadManager.isSameLiveRun(entry: (a, true), runId: a))
        XCTAssertFalse(DownloadManager.isSameLiveRun(entry: (b, false), runId: a))   // cancel-then-restart
        XCTAssertFalse(DownloadManager.isSameLiveRun(entry: nil, runId: a))
    }

    func testEachDownloadTaskHasItsOwnRunId() {
        XCTAssertNotEqual(DownloadTask(itemId: "x", title: "t").runId, DownloadTask(itemId: "x", title: "t").runId)
    }
}
