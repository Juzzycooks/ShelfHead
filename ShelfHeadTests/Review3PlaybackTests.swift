import XCTest
@testable import ShelfHead

final class Review3PlaybackTests: XCTestCase {
    // Review 3 High 3
    func testSuppressionHeldWhileMixtapeDrives() {
        XCTAssertTrue(AudioPlayerService.suppressionAfterExplicitAction(mixtapeDriving: true, suppressed: true))
    }

    func testSuppressionPersistsAfterMixtapeUntilExplicitAction() {
        // Mixtape ended: not driving, still suppressed. Nothing here clears it by itself,
        // and an explicit play/load (the only callers) does.
        XCTAssertFalse(AudioPlayerService.shouldRecordPosition(suppressed: true))
        XCTAssertFalse(AudioPlayerService.suppressionAfterExplicitAction(mixtapeDriving: false, suppressed: true))
    }

    func testNormalPlayLeavesNoSuppression() {
        XCTAssertFalse(AudioPlayerService.suppressionAfterExplicitAction(mixtapeDriving: false, suppressed: false))
        XCTAssertTrue(AudioPlayerService.shouldRecordPosition(suppressed: false))
    }
}
