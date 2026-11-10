import XCTest
@testable import ShelfHead

/// Control Center's toggle now posts a real "set play state" request
/// (`com.shelfhead.setPlaying`/`com.shelfhead.setPaused`, see `PlaybackControlToggleIntent`
/// in ShelfHeadWidgets/ShelfHeadPlaybackControl.swift) instead of inferring a flip from
/// the tile's last-known state. `PlaybackCoordinator.setPlayStateAction(_:_:_:_:)` is the
/// pure decision half of `playFromWidget()`/`pauseFromWidget()`: it turns "the person
/// asked for play/pause" plus the three bits of state `ensureSomethingLoaded()` can
/// observe (a book is loaded at all, a live session was actually started, and whether
/// it's currently playing) into exactly one `SetPlayStateAction`.
///
/// The one property every "requested pause" case must satisfy: it never resolves to an
/// action that starts or restores playback (`.resumeMostRecent`/`.startFromColdSnapshot`/
/// `.play` are all unreachable when `requestedPlaying` is `false`) — a Control Center
/// pause tapped moments after a force-quit must stay a no-op, not silently resume the
/// last book just because loading its identity was needed to answer "is it playing".
///
/// Marked `nonisolated` on `PlaybackCoordinator` (a `@MainActor` class) specifically so
/// this pure function is reachable from a plain, non-actor-isolated test like this one,
/// matching the precedent set by `StartSleepTimerIntent.validatedSleepTimerMinutes(_:)`
/// (SleepTimerValidationTests.swift) for pinning a pure decision function without driving
/// the surrounding stateful machinery.
final class SetPlayStateActionTests: XCTestCase {

    // MARK: - requestedPlaying: true (Control Center asked for "playing")

    func testPlayWithNoBookResumesMostRecent() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: true, hasBook: false, isAwaitingResume: false, isPlaying: false
            ),
            .resumeMostRecent
        )
    }

    /// `hasBook: false` always means "nothing loaded" regardless of the other flags —
    /// `isAwaitingResume`/`isPlaying` are only meaningful once a book identity exists.
    func testPlayWithNoBookResumesMostRecentEvenIfOtherFlagsAreInconsistent() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: true, hasBook: false, isAwaitingResume: true, isPlaying: true
            ),
            .resumeMostRecent
        )
    }

    func testPlayWithColdSnapshotStartsIt() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: true, hasBook: true, isAwaitingResume: true, isPlaying: false
            ),
            .startFromColdSnapshot
        )
    }

    func testPlayWithLiveButPausedSessionPlays() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: true, hasBook: true, isAwaitingResume: false, isPlaying: false
            ),
            .play
        )
    }

    func testPlayWhileAlreadyPlayingIsANoOp() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: true, hasBook: true, isAwaitingResume: false, isPlaying: true
            ),
            .none
        )
    }

    // MARK: - requestedPlaying: false (Control Center asked for "paused")

    func testPauseWithNoBookIsANoOp() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: false, hasBook: false, isAwaitingResume: false, isPlaying: false
            ),
            .none
        )
    }

    /// The critical case: a cold-snapshot identity exists (so `hasBook` is true) but no
    /// live session was ever started. A pause request must not become "start it, then
    /// immediately pause" — it must stay a no-op.
    func testPauseWithColdSnapshotNeverStartsPlayback() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: false, hasBook: true, isAwaitingResume: true, isPlaying: false
            ),
            .none
        )
    }

    func testPauseWithLiveAndPlayingSessionPauses() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: false, hasBook: true, isAwaitingResume: false, isPlaying: true
            ),
            .pause
        )
    }

    func testPauseWhileAlreadyPausedIsANoOp() {
        XCTAssertEqual(
            PlaybackCoordinator.setPlayStateAction(
                requestedPlaying: false, hasBook: true, isAwaitingResume: false, isPlaying: false
            ),
            .none
        )
    }
}
