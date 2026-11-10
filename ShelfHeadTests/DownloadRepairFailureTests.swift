import XCTest
@testable import ShelfHead

/// Fix 3 (REVIEW-2026-09-09.md): `failDownload` used to delete `downloadDirectory(for:)`
/// unconditionally. That's right for a partial first-time download, and destructive for
/// a failed **repair** — `repairDownload` deletes only the tracks `verifyDownload`
/// flagged as broken and re-enqueues them through the same background session, so a
/// re-download that failed (a server rescan changed the file's `ino` → HTTP 404, retries
/// exhausted, auth expired) reached `failDownload` with `completedTracks < totalTracks`
/// satisfied and wiped every healthy track, the cached cover and `manifest.json` (the
/// only store of offline progress), while leaving the id in `downloadedItems` — so
/// `isDownloaded` stayed true and `localSession(for:)` returned nil: a book the UI
/// showed as downloaded and couldn't play.
///
/// `failDownload`/`cancelDownload` themselves touch the real filesystem, the background
/// `URLSession` and this class's live instance state, so they aren't unit-tested
/// directly — matching this target's existing scope (see `DownloadManagerScopeTests`'s
/// header). What's pinned here is the pair of pure decision functions they were
/// refactored to delegate to, exactly the precedent `shouldReclaimOrphanDirectory` /
/// `DownloadOrphanSweepTests` set for this file.
/// `@MainActor`: the `DownloadManager` members exercised here are main-actor-isolated.
@MainActor
final class DownloadRepairFailureTests: XCTestCase {

    // MARK: - The bug

    /// The exact bug: a repair's re-download failed, and the whole book's directory —
    /// healthy tracks, cover and manifest included — was deleted.
    func testFailedRepairKeepsTheItemDirectory() {
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: true, isInDownloadedItems: true,
                                          completedTracks: 9, totalTracks: 10),
            .keepFiles,
            "A failed repair must leave the book's directory, manifest, cover and healthy tracks on disk — this is the exact behavior fix 3 exists to provide."
        )
        XCTAssertFalse(
            DownloadManager.shouldRemoveItemDirectoryOnFailure(isRepair: true, isInDownloadedItems: true),
            "A repair failure must never reach a directory deletion."
        )
    }

    /// A second broken track's failure arrives *after* the first one already removed the
    /// `DownloadTask`, so `isRepair` is no longer observable — `downloadedItems`
    /// membership is the guard that still catches it. `downloadBook` refuses to start a
    /// download for an already-downloaded id, so "in `downloadedItems` with a live
    /// failing track" can only be a repair (or a future partial re-fetch).
    func testSecondRepairTrackFailureStillKeepsTheItemDirectory() {
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: false, isInDownloadedItems: true,
                                          completedTracks: 8, totalTracks: 10),
            .keepFiles,
            "An id already in downloadedItems is a partial re-fetch, not a partial first download, even once its DownloadTask is gone."
        )
    }

    // MARK: - The behavior that must be preserved

    /// The ARCH-5 behavior this fix must not regress: a first-time download that dies
    /// partway still gets its partial directory reclaimed.
    func testFreshDownloadFailingPartwayDiscardsTheItemDirectory() {
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: false, isInDownloadedItems: false,
                                          completedTracks: 3, totalTracks: 10),
            .discardFiles,
            "A first-time download that failed partway leaves bytes nothing in the UI can see or delete — it must still be reclaimed."
        )
        XCTAssertTrue(
            DownloadManager.shouldRemoveItemDirectoryOnFailure(isRepair: false, isInDownloadedItems: false)
        )
    }

    /// Zero tracks done is still a partial first download, not a special case.
    func testFreshDownloadFailingBeforeAnyTrackLandedDiscardsTheItemDirectory() {
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: false, isInDownloadedItems: false,
                                          completedTracks: 0, totalTracks: 4),
            .discardFiles
        )
    }

    // MARK: - The invariant

    /// The invariant that made the bug unplayable rather than merely wasteful: an id in
    /// `downloadedItems` must always have a directory with a manifest. So no input may
    /// ever ask for a directory deletion while the id is in `downloadedItems` — the call
    /// site's other half (routing the delete through `removeDownload`, which drops the id
    /// and persists in the same step) is what keeps the two from coming apart when a
    /// delete *is* the right answer.
    func testDeletingIsNeverAskedForWhileTheIdIsInDownloadedItems() {
        for isRepair in [true, false] {
            for completed in [0, 1, 5] {
                XCTAssertNotEqual(
                    DownloadManager.failureAction(isRepair: isRepair, isInDownloadedItems: true,
                                                  completedTracks: completed, totalTracks: 6),
                    .discardFiles,
                    "No failure of an id in downloadedItems may delete its directory (isRepair: \(isRepair), completed: \(completed))."
                )
                XCTAssertFalse(
                    DownloadManager.shouldRemoveItemDirectoryOnFailure(isRepair: isRepair, isInDownloadedItems: true)
                )
            }
        }
    }

    /// Same rule from the cancel side: `cancelAllActiveDownloads()` fires on every
    /// account switch and logout, so a repair in flight at that moment used to take the
    /// whole book with it.
    func testCancellingARepairKeepsTheItemDirectory() {
        XCTAssertFalse(
            DownloadManager.shouldRemoveItemDirectoryOnFailure(isRepair: true, isInDownloadedItems: true),
            "Cancelling a repair (account switch, logout) must not delete the downloaded book."
        )
        XCTAssertTrue(
            DownloadManager.shouldRemoveItemDirectoryOnFailure(isRepair: false, isInDownloadedItems: false),
            "Cancelling a genuine first-time download must still reclaim its partial directory."
        )
    }

    // MARK: - Preserved edge cases

    /// The pre-fix guard was `completedTrackCount(itemId:) < total`, i.e. a late failure
    /// callback for a download whose tracks are all on disk is ignored. Preserved.
    func testAlreadyCompleteDownloadIgnoresALateFailure() {
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: false, isInDownloadedItems: false,
                                          completedTracks: 10, totalTracks: 10),
            .ignore
        )
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: true, isInDownloadedItems: true,
                                          completedTracks: 10, totalTracks: 10),
            .ignore,
            "A repair whose tracks all landed before the failure callback arrived has nothing to report."
        )
    }

    /// No readable manifest means `totalTracks == 0`, which the pre-fix guard also
    /// treated as "nothing to fail" (`0 < 0` is false). Preserved deliberately — this is
    /// the shape a manifest-write failure leaves behind, and `enqueueDownload` already
    /// reports and cleans up after that case itself.
    func testMissingManifestIsIgnored() {
        XCTAssertEqual(
            DownloadManager.failureAction(isRepair: false, isInDownloadedItems: false,
                                          completedTracks: 0, totalTracks: 0),
            .ignore
        )
    }
}
