import XCTest
@testable import ShelfHead

/// Item 8 (REVIEW-2026-09-09-REMAINING.md): `retryFailedDownload(itemId:)` used to remove
/// the `DownloadFailure` record — and persist that removal to
/// `shelfhead_failedDownloads.<scope>` — *before* it re-fetched the item and called
/// `downloadBook`. The record is the only thing that keeps a permanently-failed download
/// visible in `DownloadsView` and retryable at all, so any retry that then failed to start
/// anything (offline, a 404 for an item deleted server-side, an expired session, or the
/// Wi-Fi-only/free-space gates inside `downloadBook`) made the book vanish from the UI
/// with no download running and no way back to it. The obvious way to hit it is the most
/// likely one: tapping Retry precisely because you know the network was bad.
///
/// The ordering is now driven by `retryOutcome(fetchSucceeded:enqueued:)`, pinned here.
/// `retryFailedDownload` itself awaits the network, mutates persisted `UserDefaults` state
/// and calls into the background `URLSession`, so it isn't unit-tested directly — matching
/// this target's existing scope for this file (see `DownloadManagerScopeTests`'s header)
/// and the `failureAction` / `DownloadRepairFailureTests` precedent.
///
/// `@MainActor`: `DownloadManager` is a main-actor type.
@MainActor
final class FailedDownloadRetryTests: XCTestCase {

    // MARK: - The bug

    /// The exact bug: the item fetch failed (offline, 404, expired session), so nothing is
    /// downloading — the failure record must survive so the row stays on screen and
    /// retryable.
    func testFailedItemFetchKeepsTheFailureRecord() {
        XCTAssertEqual(
            DownloadManager.retryOutcome(fetchSucceeded: false, enqueued: false),
            .keepRecord,
            "A retry that couldn't even reach the server must leave the failed-download record in place — dropping it was the bug: the book disappeared from DownloadsView with nothing downloading."
        )
    }

    /// The fetch succeeded but `downloadBook` declined to start: Wi-Fi-only is on and
    /// we're on cellular, or the free-space check refused. Both post their own toast and
    /// leave `activeDownloads` untouched, so there is still no download — keep the record.
    func testFetchedButNotEnqueuedKeepsTheFailureRecord() {
        XCTAssertEqual(
            DownloadManager.retryOutcome(fetchSucceeded: true, enqueued: false),
            .keepRecord,
            "downloadBook's Wi-Fi-only and free-space gates return without starting anything; the record has to outlive that too."
        )
    }

    // MARK: - The behavior that must be preserved

    /// The happy path the function exists for: a live download replaced the failure, so
    /// the record is genuinely superseded and must go — otherwise the book shows as both
    /// downloading and failed.
    func testFetchedAndEnqueuedRemovesTheFailureRecord() {
        XCTAssertEqual(
            DownloadManager.retryOutcome(fetchSucceeded: true, enqueued: true),
            .removeRecord,
            "Once downloadBook has inserted a DownloadTask, the failure record is stale and must be dropped and persisted."
        )
    }

    // MARK: - The invariant

    /// The one rule the whole fix is: the record is dropped only when *both* halves
    /// actually happened. Enumerated rather than asserted case by case, so a future
    /// widening of the condition (e.g. "the fetch worked, close enough") fails here.
    func testRecordIsOnlyEverDroppedWhenSomethingIsActuallyDownloading() {
        for fetchSucceeded in [true, false] {
            for enqueued in [true, false] {
                let outcome = DownloadManager.retryOutcome(fetchSucceeded: fetchSucceeded, enqueued: enqueued)
                if fetchSucceeded && enqueued {
                    XCTAssertEqual(outcome, .removeRecord)
                } else {
                    XCTAssertEqual(
                        outcome, .keepRecord,
                        "fetchSucceeded: \(fetchSucceeded), enqueued: \(enqueued) — no download is running, so the user must keep a visible, retryable record."
                    )
                }
            }
        }
    }

    /// A defensive case the ordering makes unreachable rather than merely unlikely: there
    /// is no path where nothing was fetched but something is somehow enqueued, and if one
    /// ever appeared it must not be read as a success.
    func testEnqueuedWithoutAFetchStillKeepsTheRecord() {
        XCTAssertEqual(
            DownloadManager.retryOutcome(fetchSucceeded: false, enqueued: true),
            .keepRecord
        )
    }
}
