import XCTest
@testable import ShelfHead

final class Review4PlaybackTests: XCTestCase {
    func testAbandonedMixtapeClearsSuppression() {
        XCTAssertFalse(MixtapeSuppression.suppressionAfterEnd(reason: .abandoned))
    }

    func testStoppedOrFinishedMixtapeKeepsSuppression() {
        XCTAssertTrue(MixtapeSuppression.suppressionAfterEnd(reason: .stoppedOrFinished))
    }

    func testQuickPauseAfterMixtapeSkipsRecord() {
        XCTAssertTrue(AudioPlayerService.shouldSkipPauseRecord(resumedFromMixtapeClip: true, listened: 1))
        XCTAssertFalse(AudioPlayerService.shouldSkipPauseRecord(resumedFromMixtapeClip: true, listened: 6))
        XCTAssertFalse(AudioPlayerService.shouldSkipPauseRecord(resumedFromMixtapeClip: false, listened: 0))
    }
}
