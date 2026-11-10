import XCTest
@testable import ShelfHead

/// Item 15 (REVIEW-2026-09-09-REMAINING.md): `DiskCoverCache` never revalidated — a
/// cover fetched once was served from disk indefinitely, so replaced server artwork
/// never showed up in the app until LRU eviction happened to reach it (unbounded in
/// practice for anyone comfortably under the 200MB cap).
///
/// Only `needsRevalidation(storedAt:now:ttl:)` — the pure staleness predicate
/// `CoverImageCache.coverData(for:)` (Extensions.swift) now calls before kicking a
/// background re-fetch — is covered here. The actual disk I/O (`storedAt`/`touch`) and
/// the network re-fetch/compare need a real cache directory and a live server, the same
/// line `DownloadManager`'s orphan sweep and this file's own `evictIfNeeded()` are left
/// untested on.
final class DiskCoverCacheRevalidationTests: XCTestCase {

    private let ttl: TimeInterval = DiskCoverCache.coverTTL
    private let referenceNow = Date(timeIntervalSince1970: 1_000_000)

    func testAnEntryYoungerThanTheTTLDoesNotNeedRevalidation() {
        let storedAt = referenceNow.addingTimeInterval(-ttl / 2)
        XCTAssertFalse(DiskCoverCache.needsRevalidation(storedAt: storedAt, now: referenceNow, ttl: ttl))
    }

    /// The boundary: exactly `ttl` old is still within the freshness window (strict `>`,
    /// not `>=`) — the same "don't flag the exact edge" shape as the sleep-timer fix
    /// (item 26) elsewhere in this batch.
    func testAnEntryExactlyAtTheTTLDoesNotNeedRevalidation() {
        let storedAt = referenceNow.addingTimeInterval(-ttl)
        XCTAssertFalse(DiskCoverCache.needsRevalidation(storedAt: storedAt, now: referenceNow, ttl: ttl))
    }

    func testAnEntryOneSecondPastTheTTLNeedsRevalidation() {
        let storedAt = referenceNow.addingTimeInterval(-ttl - 1)
        XCTAssertTrue(DiskCoverCache.needsRevalidation(storedAt: storedAt, now: referenceNow, ttl: ttl))
    }

    func testAnEntryWellPastTheTTLNeedsRevalidation() {
        let storedAt = referenceNow.addingTimeInterval(-ttl * 10)
        XCTAssertTrue(DiskCoverCache.needsRevalidation(storedAt: storedAt, now: referenceNow, ttl: ttl))
    }

    /// A cover stored in the future (clock skew, or simply "just written") is never
    /// stale — `timeIntervalSince` goes negative, which is well below any positive `ttl`.
    func testAnEntryStoredInTheFutureDoesNotNeedRevalidation() {
        let storedAt = referenceNow.addingTimeInterval(60)
        XCTAssertFalse(DiskCoverCache.needsRevalidation(storedAt: storedAt, now: referenceNow, ttl: ttl))
    }

    func testTheDefaultTTLIsSevenDays() {
        XCTAssertEqual(DiskCoverCache.coverTTL, 7 * 24 * 60 * 60)
    }
}
