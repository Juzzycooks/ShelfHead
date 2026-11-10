import XCTest
@testable import ShelfHead

/// Batch 406: `LiveActivityController`'s pure decisions — the sleep timer's wall-clock end
/// date (book time scaled by playback speed), when a sleep or downloads change is worth an
/// ActivityKit update, and the aggregate downloads progress. The ActivityKit calls and the
/// observation plumbing around them talk to the system and live services, so they aren't
/// unit-tested; same "extract the decision, test the decision" precedent as
/// `DownloadProgressThrottleTests`.
@MainActor
final class LiveActivityControllerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func sleep(
        _ option: SleepTimerOption, remaining: TimeInterval = 0, mediaTarget: Bool = false,
        playing: Bool = true, rate: Double = 1, currentTime: Double = 0, duration: Double = 0
    ) -> SleepTimerActivityState? {
        LiveActivityController.sleepState(
            option: option, remaining: remaining, hasMediaTarget: mediaTarget,
            isPlaying: playing, rate: rate, currentTime: currentTime, duration: duration,
            title: "Dune", now: now)
    }

    // MARK: - Sleep end date

    func testWallClockSecondsScalesByRate() {
        XCTAssertEqual(LiveActivityController.wallClockSeconds(mediaSeconds: 600, rate: 2), 300, accuracy: 0.001)
        XCTAssertEqual(LiveActivityController.wallClockSeconds(mediaSeconds: 600, rate: 0.5), 1200, accuracy: 0.001)
        XCTAssertEqual(LiveActivityController.wallClockSeconds(mediaSeconds: 600, rate: 1), 600, accuracy: 0.001)
    }

    func testWallClockSecondsGuardsZeroRateAndNegativeTime() {
        XCTAssertEqual(LiveActivityController.wallClockSeconds(mediaSeconds: -5, rate: 1.5), 0)
        XCTAssertTrue(LiveActivityController.wallClockSeconds(mediaSeconds: 10, rate: 0).isFinite)
    }

    func testOffHasNoActivity() {
        XCTAssertNil(sleep(.off, remaining: 300))
    }

    /// A plain countdown's remaining figure is already wall time: speed doesn't change it.
    func testPlainCountdownIgnoresRate() throws {
        let state = try XCTUnwrap(sleep(.minutes(15), remaining: 900, rate: 2))
        XCTAssertEqual(state.kind, .countdown)
        XCTAssertEqual(try XCTUnwrap(state.endDate).timeIntervalSince(now), 900, accuracy: 0.001)
    }

    /// A smart-snapped countdown targets a chapter boundary in book time.
    func testSnappedCountdownScalesByRate() throws {
        let state = try XCTUnwrap(sleep(.minutes(15), remaining: 900, mediaTarget: true, rate: 1.5))
        XCTAssertEqual(try XCTUnwrap(state.endDate).timeIntervalSince(now), 600, accuracy: 0.001)
    }

    func testEndOfChapterScalesByRate() throws {
        let state = try XCTUnwrap(sleep(.endOfChapter, remaining: 300, mediaTarget: true, rate: 2))
        XCTAssertEqual(state.kind, .chapter)
        XCTAssertEqual(try XCTUnwrap(state.endDate).timeIntervalSince(now), 150, accuracy: 0.001)
    }

    func testPlusChaptersIsChapterKind() throws {
        XCTAssertEqual(try XCTUnwrap(sleep(.chapters(2), remaining: 1200, mediaTarget: true)).kind, .chapter)
    }

    /// End of book carries `-1` as its remaining figure; the end comes from the position.
    func testEndOfBookCountsToBookEnd() throws {
        let state = try XCTUnwrap(sleep(.endOfBook, remaining: -1, rate: 1.25, currentTime: 1000, duration: 3500))
        XCTAssertEqual(state.kind, .endOfBook)
        XCTAssertEqual(try XCTUnwrap(state.endDate).timeIntervalSince(now), 2000, accuracy: 0.001)
    }

    func testNothingLeftHasNoActivity() {
        XCTAssertNil(sleep(.endOfChapter, remaining: 0, mediaTarget: true))
        XCTAssertNil(sleep(.endOfBook, remaining: -1, currentTime: 3500, duration: 3500))
    }

    /// Paused: no running clock, the frozen wall-clock remaining instead.
    func testPausedFreezesRemaining() throws {
        let state = try XCTUnwrap(sleep(.endOfChapter, remaining: 300, mediaTarget: true, playing: false, rate: 1.5))
        XCTAssertTrue(state.isPaused)
        XCTAssertNil(state.endDate)
        XCTAssertEqual(state.pausedRemaining, 200, accuracy: 0.001)
    }

    // MARK: - Sleep update throttle

    private func state(end: TimeInterval?, paused: Bool = false, remaining: TimeInterval = 600,
                       kind: SleepTimerActivityState.Kind = .countdown) -> SleepTimerActivityState {
        SleepTimerActivityState(kind: kind, bookTitle: "Dune",
                                endDate: end.map { now.addingTimeInterval($0) },
                                pausedRemaining: remaining, isPaused: paused)
    }

    func testFirstSleepStateAlwaysUpdates() {
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(previous: nil, next: state(end: 600)))
    }

    /// Countdown ticks and time-observer jitter move the end by under a second.
    func testTickJitterDoesNotUpdate() {
        XCTAssertFalse(LiveActivityController.sleepNeedsUpdate(previous: state(end: 600), next: state(end: 600.8)))
        XCTAssertFalse(LiveActivityController.sleepNeedsUpdate(previous: state(end: 600), next: state(end: 596)))
    }

    /// "+15", shake-to-reset, a seek or a speed change move it by far more.
    func testExtendOrSeekUpdates() {
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(previous: state(end: 600), next: state(end: 1500)))
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(previous: state(end: 600), next: state(end: 540)))
    }

    func testPauseResumeAndKindChangesUpdate() {
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(previous: state(end: 600), next: state(end: nil, paused: true)))
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(previous: state(end: nil, paused: true), next: state(end: 600)))
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(
            previous: state(end: 600, kind: .chapter), next: state(end: 600, kind: .countdown)))
    }

    func testPausedSeekUpdatesOnlyPastTolerance() {
        XCTAssertFalse(LiveActivityController.sleepNeedsUpdate(
            previous: state(end: nil, paused: true, remaining: 600), next: state(end: nil, paused: true, remaining: 598)))
        XCTAssertTrue(LiveActivityController.sleepNeedsUpdate(
            previous: state(end: nil, paused: true, remaining: 600), next: state(end: nil, paused: true, remaining: 300)))
    }

    // MARK: - Downloads aggregate

    private typealias Sample = LiveActivityController.DownloadSample

    func testAggregateAveragesActiveAndFinished() throws {
        let state = try XCTUnwrap(LiveActivityController.downloadsState(
            active: [Sample(progress: 0.5, isPaused: false), Sample(progress: 0.1, isPaused: false)],
            finishedCount: 1, failedCount: 0, singleTitle: nil))
        XCTAssertEqual(state.phase, .downloading)
        XCTAssertEqual(state.activeCount, 2)
        XCTAssertEqual(state.fraction, (0.5 + 0.1 + 1) / 3, accuracy: 0.0001)
        XCTAssertNil(state.singleTitle)
    }

    func testSingleBookCarriesTitle() throws {
        let state = try XCTUnwrap(LiveActivityController.downloadsState(
            active: [Sample(progress: 0.4, isPaused: false)], finishedCount: 0, failedCount: 0, singleTitle: "Dune"))
        XCTAssertEqual(state.singleTitle, "Dune")
        XCTAssertEqual(state.fraction, 0.4, accuracy: 0.0001)
    }

    func testOutOfRangeProgressIsClamped() throws {
        let state = try XCTUnwrap(LiveActivityController.downloadsState(
            active: [Sample(progress: 1.7, isPaused: false), Sample(progress: -0.2, isPaused: false)],
            finishedCount: 0, failedCount: 0, singleTitle: nil))
        XCTAssertEqual(state.fraction, 0.5, accuracy: 0.0001)
    }

    func testAllPausedEndsActivity() {
        XCTAssertNil(LiveActivityController.downloadsState(
            active: [Sample(progress: 0.3, isPaused: true)], finishedCount: 1, failedCount: 0, singleTitle: nil))
    }

    func testDrainedQueueFinishes() throws {
        let state = try XCTUnwrap(LiveActivityController.downloadsState(
            active: [], finishedCount: 2, failedCount: 1, singleTitle: nil))
        XCTAssertEqual(state.phase, .finished)
        XCTAssertEqual(state.fraction, 1)
        XCTAssertEqual(state.failedCount, 1)
    }

    func testAllFailedIsFailed() throws {
        let state = try XCTUnwrap(LiveActivityController.downloadsState(
            active: [], finishedCount: 0, failedCount: 2, singleTitle: nil))
        XCTAssertEqual(state.phase, .failed)
    }

    func testCancelledRunHasNoActivity() {
        XCTAssertNil(LiveActivityController.downloadsState(active: [], finishedCount: 0, failedCount: 0, singleTitle: nil))
    }

    // MARK: - Downloads update throttle

    private func downloading(_ fraction: Double, count: Int = 2) -> DownloadsActivityState {
        DownloadsActivityState(phase: .downloading, activeCount: count, fraction: fraction,
                               finishedCount: 0, failedCount: 0, singleTitle: nil)
    }

    func testFirstDownloadsStateAlwaysUpdates() {
        XCTAssertTrue(LiveActivityController.downloadsNeedsUpdate(
            previous: nil, next: downloading(0.01), lastUpdateAt: nil, now: now))
    }

    func testFivePercentStepUpdatesImmediately() {
        XCTAssertTrue(LiveActivityController.downloadsNeedsUpdate(
            previous: downloading(0.40), next: downloading(0.46), lastUpdateAt: now, now: now.addingTimeInterval(0.2)))
    }

    func testSmallStepWaitsForInterval() {
        let interval = LiveActivityController.downloadsMinimumInterval
        XCTAssertFalse(LiveActivityController.downloadsNeedsUpdate(
            previous: downloading(0.40), next: downloading(0.42), lastUpdateAt: now, now: now.addingTimeInterval(interval - 0.5)))
        XCTAssertTrue(LiveActivityController.downloadsNeedsUpdate(
            previous: downloading(0.40), next: downloading(0.42), lastUpdateAt: now, now: now.addingTimeInterval(interval)))
    }

    func testSubPercentChangeNeverUpdates() {
        XCTAssertFalse(LiveActivityController.downloadsNeedsUpdate(
            previous: downloading(0.401), next: downloading(0.408), lastUpdateAt: now, now: now.addingTimeInterval(60)))
    }

    func testCountChangeUpdatesImmediately() {
        XCTAssertTrue(LiveActivityController.downloadsNeedsUpdate(
            previous: downloading(0.40, count: 2), next: downloading(0.40, count: 3), lastUpdateAt: now, now: now))
    }
}
