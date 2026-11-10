import XCTest
@testable import ShelfHead

// Review 5 (30 October 2026): mixtape / playback decisions.
final class Review5PlaybackTests: XCTestCase {
    func testEndOfBookWhileSuppressedIsNotFinished() {
        XCTAssertFalse(AudioPlayerService.shouldTreatEndAsBookFinished(suppressed: true))
        XCTAssertTrue(AudioPlayerService.shouldTreatEndAsBookFinished(suppressed: false))
    }

    func testQuickPauseGuardCountsOnlyListeningSinceResume() {
        XCTAssertTrue(AudioPlayerService.shouldSkipPauseRecord(resumedFromMixtapeClip: true, listened: 0))
        XCTAssertFalse(AudioPlayerService.shouldSkipPauseRecord(resumedFromMixtapeClip: true, listened: 30))
    }

    func testSequencerFinishesWhenClipEndsPastBookDuration() {
        let clip = MixtapeClip(itemId: "a", start: 10, end: 500)
        XCTAssertEqual(MixtapeSequencer.action(clips: [clip], index: 0, playingItemId: "a", position: 300, duration: 300), .finish)
        XCTAssertEqual(MixtapeSequencer.action(clips: [clip], index: 0, playingItemId: "a", position: 300), .continuePlaying)
    }
}
