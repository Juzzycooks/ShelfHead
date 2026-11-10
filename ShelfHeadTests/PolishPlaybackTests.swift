import XCTest
@testable import ShelfHead

/// Polish pass (PB-3, PB-7, PB-10, WG-2): pins the pure decisions behind the playback fixes.
final class PolishPlaybackTests: XCTestCase {

    // PB-3
    func testNowPlayingRateIsZeroWhileBuffering() {
        XCTAssertEqual(AudioPlayerService.nowPlayingRate(isPlaying: true, isBuffering: true, playbackRate: 1.5), 0)
    }

    func testNowPlayingRateIsPlaybackRateWhenRendering() {
        XCTAssertEqual(AudioPlayerService.nowPlayingRate(isPlaying: true, isBuffering: false, playbackRate: 1.5), 1.5)
    }

    func testNowPlayingRateIsZeroWhenPaused() {
        XCTAssertEqual(AudioPlayerService.nowPlayingRate(isPlaying: false, isBuffering: false, playbackRate: 2), 0)
    }

    // PB-7
    func testSeekToleranceZeroForLocalOneSecondForStream() {
        XCTAssertEqual(AudioPlayerService.seekTolerance(isLocalFile: true), 0)
        XCTAssertEqual(AudioPlayerService.seekTolerance(isLocalFile: false), 1)
    }

    // PB-10
    func testTerminateSaveRequiresDownloadedLoadedBookPastResumeSeek() {
        XCTAssertTrue(AudioPlayerService.shouldSaveLocalProgressOnTerminate(
            hasItem: true, isDownloaded: true, suppressed: false, hasReachedResumePosition: true, currentTime: 120))
        XCTAssertFalse(AudioPlayerService.shouldSaveLocalProgressOnTerminate(
            hasItem: true, isDownloaded: false, suppressed: false, hasReachedResumePosition: true, currentTime: 120))
        XCTAssertFalse(AudioPlayerService.shouldSaveLocalProgressOnTerminate(
            hasItem: true, isDownloaded: true, suppressed: true, hasReachedResumePosition: true, currentTime: 120))
        XCTAssertFalse(AudioPlayerService.shouldSaveLocalProgressOnTerminate(
            hasItem: true, isDownloaded: true, suppressed: false, hasReachedResumePosition: false, currentTime: 120))
        XCTAssertFalse(AudioPlayerService.shouldSaveLocalProgressOnTerminate(
            hasItem: true, isDownloaded: true, suppressed: false, hasReachedResumePosition: true, currentTime: 0.5))
        XCTAssertFalse(AudioPlayerService.shouldSaveLocalProgressOnTerminate(
            hasItem: false, isDownloaded: true, suppressed: false, hasReachedResumePosition: true, currentTime: 120))
    }

    // WG-2
    func testWidgetReloadThrottledWhenStateUnchanged() {
        XCTAssertFalse(AudioPlayerService.shouldReloadWidgetsNow(
            elapsedSinceLastReload: 1, minInterval: 5, lastPublishedIsPlaying: true, isPlaying: true))
    }

    func testWidgetReloadBypassesThrottleOnPlayPauseFlip() {
        XCTAssertTrue(AudioPlayerService.shouldReloadWidgetsNow(
            elapsedSinceLastReload: 1, minInterval: 5, lastPublishedIsPlaying: true, isPlaying: false))
        XCTAssertTrue(AudioPlayerService.shouldReloadWidgetsNow(
            elapsedSinceLastReload: 1, minInterval: 5, lastPublishedIsPlaying: false, isPlaying: true))
    }

    func testWidgetReloadAllowedAfterInterval() {
        XCTAssertTrue(AudioPlayerService.shouldReloadWidgetsNow(
            elapsedSinceLastReload: 5, minInterval: 5, lastPublishedIsPlaying: nil, isPlaying: true))
    }

    func testWidgetReloadThrottledWithNoPriorState() {
        XCTAssertFalse(AudioPlayerService.shouldReloadWidgetsNow(
            elapsedSinceLastReload: 1, minInterval: 5, lastPublishedIsPlaying: nil, isPlaying: true))
    }
}
