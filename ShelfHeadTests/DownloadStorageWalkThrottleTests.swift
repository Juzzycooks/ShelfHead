import XCTest
@testable import ShelfHead

/// Per-item-size-at-launch fix: `refreshStorageUsed()` is now called from every
/// screen-appearance site (`DownloadManager.bootstrapIfNeeded()` at launch,
/// `DownloadsView`'s and `DownloadsSettingsView`'s root `.task`s) as well as from every
/// mutation call site that already called it (removal, remove-all, account/scope
/// deletion, orphan-scope reclamation, download completion, account switch). Without a
/// throttle, two screen appearances in quick succession — e.g. the Downloads tab
/// appearing and then its "Download Settings" push destination a moment later — would
/// each kick off their own full recursive disk walk for no new information.
///
/// `refreshStorageUsed(force:)` itself talks to the real filesystem and this class's
/// live instance state, so (matching this target's established precedent —
/// `shouldReclaimOrphanDirectory` / `DownloadOrphanSweepTests`, `shouldHopForProgress` /
/// `DownloadProgressThrottleTests`) only the pure decision behind it is unit-tested
/// here: `shouldStartStorageWalk`.
///
/// `@MainActor`: matches the rest of the `DownloadManager` tests in this target (the
/// function itself is `nonisolated`, so it's callable either way).
@MainActor
final class DownloadStorageWalkThrottleTests: XCTestCase {

    private let interval: TimeInterval = 10
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    /// The very first walk of the process (or of a fresh `DownloadManager` instance)
    /// has nothing to throttle against and must always run — otherwise
    /// `bootstrapIfNeeded()`'s launch-time call, which is exactly this case, would
    /// silently no-op and no size would ever appear.
    func testNoPreviousWalkAlwaysStarts() {
        XCTAssertTrue(
            DownloadManager.shouldStartStorageWalk(
                lastStartedAt: nil, now: now, force: false, minimumInterval: interval),
            "With no previous walk there is nothing to throttle against; the first call must always start one."
        )
    }

    /// The actual throttle: a screen-appearance call arriving well inside the minimum
    /// interval of the previous walk must be skipped.
    func testAppearanceInsideIntervalIsSkipped() {
        XCTAssertFalse(
            DownloadManager.shouldStartStorageWalk(
                lastStartedAt: now.addingTimeInterval(-interval / 5), now: now,
                force: false, minimumInterval: interval),
            "A screen reappearing moments after the last walk started should not trigger a redundant one."
        )
    }

    /// Once the interval has elapsed, a plain (non-forced) appearance may walk again —
    /// e.g. the user left the Downloads tab and came back much later.
    func testAppearanceAfterIntervalStarts() {
        XCTAssertTrue(
            DownloadManager.shouldStartStorageWalk(
                lastStartedAt: now.addingTimeInterval(-interval), now: now,
                force: false, minimumInterval: interval),
            "Once the minimum interval has elapsed, the next appearance should be allowed to walk again."
        )
    }

    /// Exactly at the boundary: `>=`, not `>`, so this counts as "elapsed."
    func testAppearanceExactlyAtIntervalStarts() {
        XCTAssertTrue(
            DownloadManager.shouldStartStorageWalk(
                lastStartedAt: now.addingTimeInterval(-interval), now: now,
                force: false, minimumInterval: interval),
            "The boundary itself should count as elapsed, matching this decision's `>=` semantics."
        )
    }

    /// The forced half: every mutation call site (`removeDownload`, `removeAllDownloads`,
    /// `deleteDownloads(forScopeKey:)`, `reclaimOrphanedDownloadScopes`,
    /// `removeFailedDownload`, `finalizeIfComplete`, `reloadForActiveScope`) knows disk
    /// state just changed and must never be silently skipped, however recently a
    /// screen-appearance walk happened to run.
    func testForceAlwaysStartsEvenImmediatelyAfterAWalk() {
        XCTAssertTrue(
            DownloadManager.shouldStartStorageWalk(
                lastStartedAt: now, now: now, force: true, minimumInterval: interval),
            "A caller that knows disk state changed (a download finished, a removal, an account switch) must always be able to force a fresh walk."
        )
    }
}
