import XCTest
@testable import ShelfHead

/// Items 9 + 10 (REVIEW-2026-09-09.md): download progress used to be published
/// unthrottled — one main-actor `Task` per `URLSessionDownloadDelegate.didWriteData`
/// callback (several a second per in-flight track, up to six tracks in parallel), each
/// one taking `cacheLock` and writing `DownloadTask.progress`. `LibraryView` and
/// `BookDetailView` read that property inside their own bodies, so both re-evaluated at
/// write-callback frequency while anything was downloading.
///
/// `trackProgress` itself runs on the background download-delegate queue against live
/// instance state and a real background `URLSession`, so it isn't unit-tested directly —
/// matching this target's existing scope (see `DownloadManagerScopeTests`'s header). What
/// is pinned here are the two pure decisions it was refactored to delegate to, the same
/// "extract the decision, test the decision" precedent `shouldReclaimOrphanDirectory` /
/// `DownloadOrphanSweepTests` set for this file:
///
/// - `shouldHopForProgress` — should this callback hop to the main actor at all?
/// - `shouldPublishProgress` — should the observable `progress` actually be written?
///
/// `@MainActor`: matches the rest of the `DownloadManager` tests in this target (the
/// functions themselves are `nonisolated`, so they're callable either way).
@MainActor
final class DownloadProgressThrottleTests: XCTestCase {

    private let interval = DownloadManager.progressPublishInterval
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    // MARK: - Gate 1: hopping to the main actor at all

    /// The first callback for a download has nothing to be throttled against and must
    /// always get through — otherwise a download that only ever produces one callback
    /// (a small single-track book on a fast connection) would show no progress at all.
    func testFirstCallbackAlwaysHops() {
        XCTAssertTrue(
            DownloadManager.shouldHopForProgress(fraction: 0.01, lastHopAt: nil, now: now),
            "With no previous hop there is nothing to coalesce against; the first callback must publish."
        )
    }

    /// The actual fix: back-to-back callbacks inside one interval collapse into one hop.
    func testCallbacksInsideTheIntervalAreDropped() {
        XCTAssertFalse(
            DownloadManager.shouldHopForProgress(
                fraction: 0.4, lastHopAt: now.addingTimeInterval(-interval / 5), now: now),
            "A callback arriving well inside the publish interval must not allocate a Task or hop to the main actor — this is the per-callback cost item 10 exists to remove."
        )
    }

    func testCallbackAfterTheIntervalHops() {
        XCTAssertTrue(
            DownloadManager.shouldHopForProgress(
                fraction: 0.4, lastHopAt: now.addingTimeInterval(-interval), now: now),
            "Once the interval has elapsed the next callback carries the latest value to the UI."
        )
    }

    /// A track's final callback is the one that takes the book to its next whole-track
    /// boundary, and it's the last thing that track will ever report — it must never be
    /// the callback that gets dropped, however recently the previous one hopped.
    func testFinishedTrackCallbackAlwaysHops() {
        XCTAssertTrue(
            DownloadManager.shouldHopForProgress(fraction: 1.0, lastHopAt: now, now: now),
            "A completed track's last callback must always be delivered, regardless of the rate limit."
        )
    }

    /// ~4 Hz, per the review's own prescription ("≥1% or ~4 Hz").
    func testPublishIntervalIsAboutFourHertz() {
        XCTAssertEqual(DownloadManager.progressPublishInterval, 0.25, accuracy: 0.0001)
    }

    // MARK: - Gate 2: writing the observable property

    /// Observation doesn't compare values, so writing the same number still invalidates
    /// every view reading it. Six parallel tracks each reporting their own fraction make
    /// this the common case, not the edge case.
    func testUnchangedPercentageIsNotPublished() {
        XCTAssertFalse(
            DownloadManager.shouldPublishProgress(
                previous: 0.5001, next: 0.5009,
                lastPublishedAt: now.addingTimeInterval(-10), now: now),
            "Both values round to the same whole percent, so publishing would re-render every reader for a bar that cannot move."
        )
    }

    /// Parallel tracks report independently, so a lower value arrives constantly. The
    /// bar never moves backward (`max` at the write site), which means such a write can
    /// only ever be a no-op change — and must not be made at all.
    func testBackwardsProgressIsNotPublished() {
        XCTAssertFalse(
            DownloadManager.shouldPublishProgress(
                previous: 0.6, next: 0.2,
                lastPublishedAt: now.addingTimeInterval(-10), now: now),
            "A value that doesn't move the bar forward must not be published."
        )
        XCTAssertFalse(
            DownloadManager.shouldPublishProgress(
                previous: 0.6, next: 0.6,
                lastPublishedAt: now.addingTimeInterval(-10), now: now),
            "An identical value must not be published."
        )
    }

    /// A whole percent of change, and the interval has long since elapsed: this is the
    /// tick a user can actually see.
    func testPercentChangeAfterIntervalIsPublished() {
        XCTAssertTrue(
            DownloadManager.shouldPublishProgress(
                previous: 0.50, next: 0.52,
                lastPublishedAt: now.addingTimeInterval(-1), now: now),
            "A real percentage change outside the interval is exactly what should be published."
        )
    }

    /// The coalescing half: on a fast download the percentage changes many times inside
    /// one interval, and only one of those changes should reach the UI.
    func testPercentChangeInsideIntervalIsHeldBack() {
        XCTAssertFalse(
            DownloadManager.shouldPublishProgress(
                previous: 0.50, next: 0.53,
                lastPublishedAt: now.addingTimeInterval(-interval / 5), now: now),
            "A fast download publishes at ~4 Hz carrying the latest value, not on every percent it flies past."
        )
    }

    /// Completion is the one value the UI must not miss — a book stuck at 99% in the
    /// Library grid reads as a failed download.
    func testCompletionAlwaysPublishes() {
        XCTAssertTrue(
            DownloadManager.shouldPublishProgress(
                previous: 0.99, next: 1.0, lastPublishedAt: now, now: now),
            "100% must land even if the previous publish was in the same instant."
        )
    }

    /// …but only once: a second 100% write would be a re-render for no change.
    func testCompletionIsNotRepublished() {
        XCTAssertFalse(
            DownloadManager.shouldPublishProgress(
                previous: 1.0, next: 1.0,
                lastPublishedAt: now.addingTimeInterval(-10), now: now),
            "Already at 100%; republishing it invalidates every reader for nothing."
        )
    }

    /// A slow download (a large book on a weak connection) must not be starved by the
    /// rate limit: the elapsed-time half is long satisfied, so it publishes on the
    /// percentage change itself.
    func testSlowDownloadPublishesOnPercentChange() {
        XCTAssertTrue(
            DownloadManager.shouldPublishProgress(
                previous: 0.10, next: 0.11,
                lastPublishedAt: now.addingTimeInterval(-30), now: now),
            "Thirty seconds and a whole percent later, this is the only tick there is — it must not be swallowed."
        )
    }
}
