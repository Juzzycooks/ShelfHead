import XCTest
@testable import ShelfHead

/// P3-1 (third-pass review, 14 Aug 2026): the review's top recommendation, verbatim —
/// "One test asserting 'a directory with a manifest and no live task and no
/// `downloadedItems` entry is reclaimed' would have caught P3-1 immediately." This is
/// that test (plus its boundary and its regression guard).
///
/// `sweepOrphanedDownloadDirectories` itself talks to the real filesystem and this
/// class's live instance state, so it isn't unit-tested directly — matching this test
/// target's existing scope (see `DownloadManagerScopeTests`'s header comment: disk I/O
/// and background session behavior remain covered by manual/TestFlight verification).
/// What's tested here is `DownloadManager.shouldReclaimOrphanDirectory`, the pure
/// decision function the sweep was refactored to delegate to specifically so this
/// boundary could be pinned without any of that.
/// `@MainActor`: the `DownloadManager` members exercised here are main-actor-isolated.
/// This test target predates that annotation and had never been rebuilt against it.
@MainActor
final class DownloadOrphanSweepTests: XCTestCase {

    /// The exact bug: before this fix, ANY manifest — regardless of age — exempted its
    /// directory from reclamation, because `enqueueDownload` writes the manifest before
    /// a single download task exists, so every real orphan has one. This is the
    /// regression guard: a manifest well past the grace period must be reclaimed.
    func testOldManifestIsReclaimed() {
        let now = Date()
        let oldManifest = now.addingTimeInterval(-25 * 3600)   // 25h old
        XCTAssertTrue(
            DownloadManager.shouldReclaimOrphanDirectory(manifestModificationDate: oldManifest, now: now),
            "A directory with a manifest well past the grace period, no live task, and no known entry must be reclaimed — this is the exact behavior ARCH-5 exists to provide."
        )
    }

    /// A manifest from moments ago is genuinely ambiguous — it might belong to a task
    /// this particular reload just doesn't happen to know about yet (a different scope,
    /// or one that only just started) — so it must NOT be reclaimed.
    func testRecentManifestIsNotReclaimed() {
        let now = Date()
        let recentManifest = now.addingTimeInterval(-60)   // 1 minute old
        XCTAssertFalse(
            DownloadManager.shouldReclaimOrphanDirectory(manifestModificationDate: recentManifest, now: now),
            "A directory whose manifest was just written is ambiguous, not abandoned, and must be left alone."
        )
    }

    /// Boundary: exactly at the grace period should reclaim (the sweep's own comparison
    /// is `>=`), one second under should not.
    func testGracePeriodBoundary() {
        let now = Date()
        let exactlyAtBoundary = now.addingTimeInterval(-24 * 3600)
        let justUnderBoundary = now.addingTimeInterval(-24 * 3600 + 1)

        XCTAssertTrue(
            DownloadManager.shouldReclaimOrphanDirectory(manifestModificationDate: exactlyAtBoundary, now: now),
            "A manifest exactly at the grace period boundary should be reclaimed."
        )
        XCTAssertFalse(
            DownloadManager.shouldReclaimOrphanDirectory(manifestModificationDate: justUnderBoundary, now: now),
            "A manifest one second under the grace period boundary should not be reclaimed yet."
        )
    }

    /// A directory with NO manifest at all (the pre-manifest-hardening orphan case —
    /// `writeManifest` itself failed) has no "recent write" ambiguity to protect against;
    /// it's stale by construction and always reclaimable regardless of age.
    func testMissingManifestIsAlwaysReclaimed() {
        XCTAssertTrue(DownloadManager.shouldReclaimOrphanDirectory(manifestModificationDate: nil))
    }
}
