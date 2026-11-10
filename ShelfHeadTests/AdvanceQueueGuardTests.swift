import XCTest
@testable import ShelfHead

final class AdvanceQueueGuardTests: XCTestCase {
    func testContinuesWhenIdleOnFinishedBook() {
        XCTAssertTrue(PlayerViewModel.shouldContinueAdvance(finishedItemId: "a", currentItemId: "a", isPlaying: false, isLoadingSession: false))
    }
    func testBailsWhenAnotherBookIsCurrent() {
        XCTAssertFalse(PlayerViewModel.shouldContinueAdvance(finishedItemId: "a", currentItemId: "b", isPlaying: false, isLoadingSession: false))
    }
    func testBailsWhenPlayingOrLoading() {
        XCTAssertFalse(PlayerViewModel.shouldContinueAdvance(finishedItemId: "a", currentItemId: "a", isPlaying: true, isLoadingSession: false))
        XCTAssertFalse(PlayerViewModel.shouldContinueAdvance(finishedItemId: "a", currentItemId: "a", isPlaying: false, isLoadingSession: true))
    }
}
