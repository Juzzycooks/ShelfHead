import XCTest
@testable import ShelfHead

final class DownloadReview6Tests: XCTestCase {
    func testSweepScopeUnchanged() {
        XCTAssertTrue(DownloadManager.sweepScopeUnchanged(entry: "a|1", current: "a|1"))
        XCTAssertFalse(DownloadManager.sweepScopeUnchanged(entry: "a|1", current: "a|2"))
    }
}
