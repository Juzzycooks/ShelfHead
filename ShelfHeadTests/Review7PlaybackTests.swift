import XCTest
@testable import ShelfHead

final class Review7PlaybackTests: XCTestCase {
    func testMixtapeResumeFlagClearsAfterThreshold() {
        XCTAssertFalse(AudioPlayerService.shouldClearMixtapeResume(resumedFromMixtapeClip: true, listened: 4.9))
        XCTAssertTrue(AudioPlayerService.shouldClearMixtapeResume(resumedFromMixtapeClip: true, listened: 5))
        XCTAssertFalse(AudioPlayerService.shouldClearMixtapeResume(resumedFromMixtapeClip: false, listened: 60))
    }

    func testSleepTargetTimersCancelOnItemChange() {
        let cancel = { (o: SleepTimerOption, old: String?, new: String?) in
            AudioPlayerService.shouldCancelSleepOnItemChange(option: o, oldItemId: old, newItemId: new)
        }
        XCTAssertTrue(cancel(.endOfChapter, "a", "b"))
        XCTAssertTrue(cancel(.chapters(2), "a", "b"))
        XCTAssertTrue(cancel(.endOfBook, "a", "b"))
        XCTAssertFalse(cancel(.minutes(15), "a", "b"))
        XCTAssertFalse(cancel(.off, "a", "b"))
        XCTAssertFalse(cancel(.endOfChapter, "a", "a"))
    }

    func testFreshFinishedWait() {
        XCTAssertEqual(PlayerViewModel.freshFinishedWait(holdingPrefetchedSession: true), 1)
        XCTAssertEqual(PlayerViewModel.freshFinishedWait(holdingPrefetchedSession: false), 4)
    }
}
