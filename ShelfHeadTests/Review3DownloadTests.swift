import XCTest
@testable import ShelfHead

// Review 3 Medium 6 (30 October 2026): removing a playing download clears the player.
final class Review3DownloadTests: XCTestCase {
    func testStopDecision() {
        XCTAssertTrue(PlayerViewModel.shouldStopForRemovedDownload(removedId: "a", currentId: "a"))
        XCTAssertFalse(PlayerViewModel.shouldStopForRemovedDownload(removedId: "a", currentId: "b"))
        XCTAssertTrue(PlayerViewModel.shouldStopForRemovedDownload(removedId: nil, currentId: "b"))
        XCTAssertFalse(PlayerViewModel.shouldStopForRemovedDownload(removedId: nil, currentId: nil))
    }
}
