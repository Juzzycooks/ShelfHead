import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 P4): a stream that dies for good is explained, not left
/// as a silent pause. Pins `AudioPlayerService.shouldShowStreamLostNotice`, the one
/// decision behind the "Lost the connection to your server" notice.
final class Batch495PlayerStreamLostTests: XCTestCase {

    private func decide(streamed: Bool = true, playing: Bool = true,
                        interruption: Bool = false, recovering: Bool = false) -> Bool {
        AudioPlayerService.shouldShowStreamLostNotice(isStreamed: streamed,
                                                      listenerWasPlaying: playing,
                                                      interruptionPending: interruption,
                                                      recoveryInFlight: recovering)
    }

    func testStreamThatStopsWhilePlayingShowsTheNotice() {
        XCTAssertTrue(decide())
    }

    func testDownloadedBookNeverShowsTheNotice() {
        XCTAssertFalse(decide(streamed: false))
    }

    /// A deliberate pause and a sleep timer stop both run `pause()` first, so the listener
    /// is no longer playing when the check runs.
    func testDeliberatePauseOrSleepTimerStopShowsNothing() {
        XCTAssertFalse(decide(playing: false))
    }

    func testInterruptionWaitingToResumeShowsNothing() {
        XCTAssertFalse(decide(interruption: true))
        XCTAssertFalse(decide(playing: false, interruption: true))
    }

    /// A token-refresh reload still on its way may yet recover the stream.
    func testRecoveryReloadInFlightShowsNothing() {
        XCTAssertFalse(decide(recovering: true))
    }

    func testNoticeCopyIsTheReviewWording() {
        XCTAssertEqual(PlayerViewModel.streamLostMessage,
                       "Playback stopped. Lost the connection to your server.")
    }
}
