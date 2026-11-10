import XCTest
@testable import ShelfHead

/// §8 decomposition (REVIEW_2026-08-12.md): tests for the pure decision logic extracted
/// out of `DownloadManager.reconcile` and the playback start position into
/// `ProgressReconciler` — one of the review's "six highest-value tests to add"
/// (§7, "ProgressReconcilerTests").
/// `@MainActor`: the `DownloadManager` members exercised here are main-actor-isolated.
/// This test target predates that annotation and had never been rebuilt against it.
@MainActor
final class ProgressReconcilerTests: XCTestCase {

    // MARK: - startPosition (polish pass Phase 2a #3)

    private typealias C = ProgressReconciler.StartCandidate

    private func start(answered: Bool = true, server: C? = nil, local: C? = nil, queued: C? = nil,
                       lastKnown: C? = nil, duration: Double = 36_000) -> Double {
        ProgressReconciler.startPosition(serverAnswered: answered, server: server, local: local,
                                         queued: queued, lastKnownServer: lastKnown, duration: duration)
    }

    /// The PB-1 bug: a server copy with no timestamp read as 1970 and the stale download won.
    func testServerAheadWinsEvenWithoutAServerTimestamp() {
        XCTAssertEqual(start(server: C(time: 900, updatedAtMs: nil), local: C(time: 300, updatedAtMs: 5_000)), 900)
    }

    func testPhoneAheadWinsOverOlderServer() {
        XCTAssertEqual(start(server: C(time: 300, updatedAtMs: 9_000), local: C(time: 900, updatedAtMs: 5_000)), 900)
    }

    func testQueuedPositionCountsWhenItIsFurthest() {
        XCTAssertEqual(start(server: C(time: 300, updatedAtMs: nil), local: C(time: 400, updatedAtMs: nil),
                             queued: C(time: 700, updatedAtMs: nil)), 700)
    }

    func testNoAnswerNeverStartsBehindLastKnownServer() {
        XCTAssertEqual(start(answered: false, server: C(time: 2_000, updatedAtMs: nil),
                             local: C(time: 300, updatedAtMs: 5_000), lastKnown: C(time: 800, updatedAtMs: nil)), 800,
                       "an unanswered server's value is ignored; the last known one is the floor")
        XCTAssertEqual(start(answered: false, local: C(time: 300, updatedAtMs: 5_000)), 300)
    }

    func testKnownNewerResetBeatsOlderAndUnstampedCopies() {
        let reset = C(time: 0, updatedAtMs: 10_000)
        XCTAssertEqual(start(server: reset, local: C(time: 900, updatedAtMs: 5_000), queued: C(time: 950, updatedAtMs: nil)), 0)
        // Listening after the reset still counts.
        XCTAssertEqual(start(server: reset, local: C(time: 40, updatedAtMs: 12_000)), 40)
    }

    func testZeroServerWithoutTimestampIsNotTreatedAsReset() {
        XCTAssertEqual(start(server: C(time: 0, updatedAtMs: nil), local: C(time: 900, updatedAtMs: 5_000)), 900)
    }

    func testInvalidPositionsAreIgnored() {
        XCTAssertEqual(start(server: C(time: 100, updatedAtMs: nil), local: C(time: 99_999, updatedAtMs: nil), duration: 3_600), 100)
        XCTAssertEqual(start(server: C(time: .nan, updatedAtMs: nil), local: C(time: -5, updatedAtMs: nil)), 0)
        // Unknown duration doesn't cap.
        XCTAssertEqual(start(local: C(time: 99_999, updatedAtMs: nil), duration: 0), 99_999)
    }

    // MARK: - reconcile

    func testReconcileLocalNewerPushesLocal() {
        let outcome = ProgressReconciler.reconcile(
            localTime: 100, localLastUpdate: 2000, localDuration: 3600,
            serverEntryExists: true, serverTime: 50, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pushLocal)
    }

    func testReconcileServerNewerPullsServer() {
        let outcome = ProgressReconciler.reconcile(
            localTime: 50, localLastUpdate: 1000, localDuration: 3600,
            serverEntryExists: true, serverTime: 100, serverLastUpdate: 2000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pullServer)
    }

    func testReconcileDivergenceBeyondThresholdIsConflict() {
        // Fix 2.3 (REVIEW-2026-09-09.md) rewrote this case's data. It used to be
        // "local 10 min @ t=1000, server 20 min @ t=2000" — a beyond-threshold gap where
        // the server was both newer *and* ahead, i.e. plain progress made on another
        // device while this one sat idle. That expected `.conflict`, which was the bug:
        // it prompted the user over a situation where the device had nothing to lose
        // (that exact case is now `testReconcileServerNewerAndAheadIsPullNotConflict`).
        // The genuinely unexplained shape keeps the `.conflict` expectation: the side
        // that wrote most recently is the side that's *behind*, so no automatic pick
        // exists that doesn't drag the position backwards past the threshold. Here the
        // device wrote 10 min at t=2000 while the server had already been moved to 60
        // min at t=1000 — the flight case (offline listening from a stale base).
        let outcome = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 2000, localDuration: 7200,
            serverEntryExists: true, serverTime: 3600, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .conflict)
    }

    // MARK: - reconcile: conflict is only for divergence one side's recency can't explain
    //
    // Fix 2.3 (REVIEW-2026-09-09.md). `.conflict` used to be decided on raw divergence
    // before `lastUpdate` was ever consulted, so both of the next two cases — the two
    // most common things that actually happen to a downloaded book — raised
    // "Progress Doesn't Match". Worse, `DownloadManager.reconcile` skips a conflicted
    // book entirely, so the offline position in the first case was never pushed until
    // the prompt was answered.

    func testReconcileOfflineListeningPushesInsteadOfConflicting() {
        // The device listened offline from where the server was (10 min) all the way to
        // 60 min: a 3000s gap, ten times the threshold, but entirely this device's own
        // forward progress — local is both newer and ahead. Push, don't ask.
        let outcome = ProgressReconciler.reconcile(
            localTime: 3600, localLastUpdate: 2000, localDuration: 7200,
            serverEntryExists: true, serverTime: 600, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pushLocal)
    }

    func testReconcileServerNewerAndAheadIsPullNotConflict() {
        // The exact data this file used to assert `.conflict` for: someone listened on
        // the web player (or another device) while this one sat idle, so the server is
        // newer *and* ahead. The device has nothing to lose — pull silently.
        let outcome = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 1000, localDuration: 7200,
            serverEntryExists: true, serverTime: 1200, serverLastUpdate: 2000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pullServer)
    }

    func testReconcileServerNewerButBehindIsConflict() {
        // Mirror image of the flight case: this device had listened to 60 min, and the
        // server was later moved *back* to 10 min (a rewind or restart elsewhere). Both
        // positions are real; pulling would throw away 50 minutes. Ask.
        let outcome = ProgressReconciler.reconcile(
            localTime: 3600, localLastUpdate: 1000, localDuration: 7200,
            serverEntryExists: true, serverTime: 600, serverLastUpdate: 2000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .conflict)
    }

    func testReconcileTimestampTieWithLargeDivergenceIsConflict() {
        // Identical `lastUpdate`s: no side is newer, so there is nothing to explain a
        // beyond-threshold gap with. Previously this fell through to `.noAction`, which
        // left the two sides permanently disagreeing — neither pushed nor pulled, and
        // never surfaced.
        let outcome = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 1000, localDuration: 7200,
            serverEntryExists: true, serverTime: 3600, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .conflict)
    }

    func testReconcileGapExactlyAtThresholdIsNotConflict() {
        // Boundary: the check is `> conflictThreshold`, not `>=`. Newer-but-behind shape
        // (which would otherwise conflict), gap exactly 300s — resolves as a push.
        let atThreshold = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 2000, localDuration: 7200,
            serverEntryExists: true, serverTime: 900, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(atThreshold, .pushLocal)
        // One second past it, same shape, and it becomes a conflict.
        let pastThreshold = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 2000, localDuration: 7200,
            serverEntryExists: true, serverTime: 901, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(pastThreshold, .conflict)
    }

    func testReconcileNoServerPositionIsNeverConflict() {
        // A server entry that exists but reports `currentTime == 0` (or nil) can't be
        // conflicted against no matter how far along the device is — nothing to lose on
        // the server side. Unchanged by fix 2.3, pinned here because the new
        // direction-of-divergence logic sits directly behind these same guards.
        let zeroServerTime = ProgressReconciler.reconcile(
            localTime: 3600, localLastUpdate: 1000, localDuration: 7200,
            serverEntryExists: true, serverTime: 0, serverLastUpdate: 2000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(zeroServerTime, .pullServer)
    }

    func testReconcileDivergenceWithinThresholdIsNotConflict() {
        let outcome = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 2000, localDuration: 7200,
            serverEntryExists: true, serverTime: 650, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pushLocal)
    }

    func testReconcileNoConflictWhenServerAlreadyFinished() {
        // A large divergence against a book the server already marks finished isn't a
        // real conflict — the server side won by simply being "done."
        let outcome = ProgressReconciler.reconcile(
            localTime: 600, localLastUpdate: 1000, localDuration: 7200,
            serverEntryExists: true, serverTime: 7100, serverLastUpdate: 2000, serverIsFinished: true,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pullServer)
    }

    func testReconcileFreshDownloadWithNoServerProgressIsNoAction() {
        // No server entry at all yet (first sync) — not a conflict, not a pull.
        let outcome = ProgressReconciler.reconcile(
            localTime: 0, localLastUpdate: 0, localDuration: 7200,
            serverEntryExists: false, serverTime: nil, serverLastUpdate: 0, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .noAction)
    }

    func testReconcileTieIsNoAction() {
        let outcome = ProgressReconciler.reconcile(
            localTime: 100, localLastUpdate: 1000, localDuration: 3600,
            serverEntryExists: true, serverTime: 100, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .noAction)
    }

    func testReconcileLocalNewerButZeroDurationDoesNotPush() {
        // Guards the original's `book.duration > 0` gate on the push branch — a
        // manifest with no known duration yet shouldn't compute a bogus progress
        // fraction and push it.
        let outcome = ProgressReconciler.reconcile(
            localTime: 100, localLastUpdate: 2000, localDuration: 0,
            serverEntryExists: true, serverTime: 50, serverLastUpdate: 1000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .noAction)
    }

    func testReconcilePullServerEvenWithNilServerCurrentTime() {
        // Locks the original edge case: the pull branch only required the server entry
        // to exist (`let server`), not that `server.currentTime` specifically be
        // non-nil — `serverEntryExists` is passed independently of `serverTime` for
        // exactly this reason (see the doc comment on `reconcile`).
        let outcome = ProgressReconciler.reconcile(
            localTime: 50, localLastUpdate: 1000, localDuration: 3600,
            serverEntryExists: true, serverTime: nil, serverLastUpdate: 2000, serverIsFinished: false,
            conflictThreshold: 300)
        XCTAssertEqual(outcome, .pullServer)
    }
}
