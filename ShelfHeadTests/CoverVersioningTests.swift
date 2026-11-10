import XCTest
import UIKit
@testable import ShelfHead

/// User report: replacing a book's cover art on the Audiobookshelf server left every
/// tile (Library, Series, Authors, Home, Collections) — and a downloaded copy of the
/// book — showing the old artwork. Only Book Detail picked up the new cover, because it
/// happened to request a width (440) no cache tier had already populated an entry for.
///
/// Root cause: `shelfCoverURL(itemId:width:)` built `.../cover?width=<w>`, which never
/// changes when the server-side artwork does, while every cache tier (`CoverImageCache`'s
/// `NSCache`, `DiskCoverCache`, and `CachedCover`'s own `.task(id: url)`) keys on that
/// URL. A downloaded book was worse still: its cover is a `cover.jpg` on disk, read by a
/// stable local file URL that never changes at all.
///
/// This file pins the pieces of the fix that are pure functions:
/// - `CoverVersions` (Extensions.swift): the record/observe registry populated as
///   `LibraryItem`s decode.
/// - `coverCacheBustedURL` (Extensions.swift): the pure URL-versioning helper.
/// - `CoverImageCache.targetSize(for:)` / `evict(url:)` (Extensions.swift): unaffected by
///   the extra query item; the eviction helper added alongside the fix.
/// - `DownloadManager.shouldRefreshLocalCover` (DownloadManager.swift): the pure
///   predicate deciding whether a downloaded book's local cover needs re-fetching.
/// - `DownloadedBook.coverUpdatedAt` (DownloadedBook.swift): decodes to `nil` for a
///   manifest written before this existed, so no existing download vanishes.
final class CoverVersioningTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CoverVersions.reset()
        CoverVersions.onVersionObserved = nil
    }

    override func tearDown() {
        CoverVersions.reset()
        CoverVersions.onVersionObserved = nil
        super.tearDown()
    }

    // MARK: - CoverVersions: record / version / reset

    func testAnItemWithNoRecordedVersionReturnsNil() {
        XCTAssertNil(CoverVersions.version(for: "unseen-item"))
    }

    func testRecordIgnoresANilUpdatedAt() {
        XCTAssertFalse(CoverVersions.record(itemId: "b1", updatedAt: nil))
        XCTAssertNil(CoverVersions.version(for: "b1"))
    }

    func testTheFirstSightingOfAnItemIsNotReportedAsAChange() {
        // There is no *previous* value to have moved on from — recording an item for the
        // first time this launch must not be treated as "the cover changed."
        XCTAssertFalse(CoverVersions.record(itemId: "b1", updatedAt: 1000))
        XCTAssertEqual(CoverVersions.version(for: "b1"), 1000)
    }

    func testANewerUpdatedAtIsReportedAsAGenuineChange() {
        CoverVersions.record(itemId: "b1", updatedAt: 1000)
        XCTAssertTrue(CoverVersions.record(itemId: "b1", updatedAt: 2000))
        XCTAssertEqual(CoverVersions.version(for: "b1"), 2000)
    }

    func testAnUnchangedUpdatedAtIsNotAChange() {
        CoverVersions.record(itemId: "b1", updatedAt: 1000)
        XCTAssertFalse(CoverVersions.record(itemId: "b1", updatedAt: 1000))
        XCTAssertEqual(CoverVersions.version(for: "b1"), 1000)
    }

    func testAnOlderOutOfOrderUpdatedAtIsNotAChangeAndDoesNotMoveTheVersionBackward() {
        CoverVersions.record(itemId: "b1", updatedAt: 2000)
        XCTAssertFalse(CoverVersions.record(itemId: "b1", updatedAt: 1000))
        XCTAssertEqual(CoverVersions.version(for: "b1"), 2000, "a stale/out-of-order payload must not roll the version back")
    }

    func testResetClearsEveryRecordedVersion() {
        CoverVersions.record(itemId: "b1", updatedAt: 1000)
        CoverVersions.record(itemId: "b2", updatedAt: 2000)
        CoverVersions.reset()
        XCTAssertNil(CoverVersions.version(for: "b1"))
        XCTAssertNil(CoverVersions.version(for: "b2"))
    }

    func testOnVersionObservedFiresOnlyForAGenuineChange() {
        var observed: [(String, Int)] = []
        CoverVersions.onVersionObserved = { id, updatedAt in observed.append((id, updatedAt)) }

        CoverVersions.record(itemId: "b1", updatedAt: 1000)   // first sighting — no callback
        CoverVersions.record(itemId: "b1", updatedAt: 1000)   // unchanged — no callback
        CoverVersions.record(itemId: "b1", updatedAt: 500)    // older — no callback
        CoverVersions.record(itemId: "b1", updatedAt: 2000)   // genuine increase — fires

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, "b1")
        XCTAssertEqual(observed.first?.1, 2000)
    }

    // MARK: - LibraryItem.init(from:) records the version as items decode

    func testDecodingALibraryItemRecordsItsUpdatedAt() throws {
        let json = #"""
        {"id": "b1", "mediaType": "book", "updatedAt": 1700000000000}
        """#
        _ = try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(CoverVersions.version(for: "b1"), 1_700_000_000_000)
    }

    func testDecodingALibraryItemWithNoUpdatedAtRecordsNothing() throws {
        let json = #"{"id": "b2", "mediaType": "book"}"#
        _ = try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
        XCTAssertNil(CoverVersions.version(for: "b2"))
    }

    // MARK: - coverCacheBustedURL

    private let base = URL(string: "https://example.com/api/items/abc/cover?width=300")!

    func testNoVersionLeavesTheURLUnchanged() {
        XCTAssertEqual(coverCacheBustedURL(base: base, version: nil), base)
    }

    func testAVersionIsAppendedAsTheTsQueryItem() {
        let busted = coverCacheBustedURL(base: base, version: 1700000000000)
        let items = URLComponents(url: busted, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "ts", value: "1700000000000")))
        // The original query item survives alongside it.
        XCTAssertTrue(items.contains(URLQueryItem(name: "width", value: "300")))
    }

    func testTwoDifferentVersionsProduceTwoDifferentURLs() {
        let first = coverCacheBustedURL(base: base, version: 100)
        let second = coverCacheBustedURL(base: base, version: 200)
        XCTAssertNotEqual(first, second)
    }

    func testTheSameVersionProducesAnIdenticalURLEachTime() {
        let first = coverCacheBustedURL(base: base, version: 100)
        let second = coverCacheBustedURL(base: base, version: 100)
        XCTAssertEqual(first, second, "a cache keyed on the URL must see a hit on an unchanged version")
    }

    func testABustedFileURLStillReadsTheSameLocalFileAndItsPathDropsTheQuery() throws {
        // Local (downloaded-book) covers are versioned the same way — the query is
        // decorative for cache-keying purposes only, and every reader in this app either
        // uses `Data(contentsOf:)` (tolerates it) or `.path` (drops it). Both are
        // exercised here against a real temp file, not just asserted.
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("CoverVersioningTests-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("cover-bytes".utf8).write(to: file)

        let busted = coverCacheBustedURL(base: file, version: 42)
        XCTAssertEqual(busted.path, file.path, "the query must not corrupt the readable file path")
        XCTAssertEqual(try Data(contentsOf: busted), Data("cover-bytes".utf8))
    }

    // MARK: - CoverImageCache.targetSize(for:) still parses `width` with `ts` present

    func testTargetSizeStillParsesWidthWhenATsParamIsAlsoPresent() {
        let url = coverCacheBustedURL(
            base: URL(string: "https://example.com/api/items/abc/cover?width=440")!,
            version: 1700000000000)
        XCTAssertEqual(CoverImageCache.targetSize(for: url), CGSize(width: 440, height: 440))
    }

    func testTargetSizeFallsBackTo300WhenNoWidthParamExistsEvenWithTsPresent() {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ts", value: "123")]
        XCTAssertEqual(CoverImageCache.targetSize(for: components.url!), CGSize(width: 300, height: 300))
    }

    // MARK: - CoverImageCache.evict(url:)

    func testEvictRemovesAnInMemoryEntry() {
        let url = URL(string: "https://example.com/api/items/evict-test/cover?width=300")!
        let image = UIImage()
        CoverImageCache.shared.setObject(image, forKey: url as NSURL, cost: 1)
        XCTAssertNotNil(CoverImageCache.shared.object(forKey: url as NSURL))
        CoverImageCache.evict(url: url)
        XCTAssertNil(CoverImageCache.shared.object(forKey: url as NSURL))
    }

    // MARK: - DownloadManager.shouldRefreshLocalCover truth table

    func testShouldRefreshLocalCoverNilManifestNilServerIsFalse() {
        XCTAssertFalse(DownloadManager.shouldRefreshLocalCover(manifestVersion: nil, serverVersion: nil))
    }

    func testShouldRefreshLocalCoverNilManifestKnownServerIsTrue() {
        // One-time refresh for a book downloaded before cover versioning existed — there
        // is no recorded version to compare against, so this errs toward refreshing.
        XCTAssertTrue(DownloadManager.shouldRefreshLocalCover(manifestVersion: nil, serverVersion: 1000))
    }

    func testShouldRefreshLocalCoverKnownManifestNilServerIsFalse() {
        // Nothing new is actually known about the server's cover — don't refresh speculatively.
        XCTAssertFalse(DownloadManager.shouldRefreshLocalCover(manifestVersion: 1000, serverVersion: nil))
    }

    func testShouldRefreshLocalCoverKnownManifestOlderServerIsFalse() {
        XCTAssertFalse(DownloadManager.shouldRefreshLocalCover(manifestVersion: 2000, serverVersion: 1000))
    }

    func testShouldRefreshLocalCoverKnownManifestEqualServerIsFalse() {
        XCTAssertFalse(DownloadManager.shouldRefreshLocalCover(manifestVersion: 1000, serverVersion: 1000))
    }

    func testShouldRefreshLocalCoverKnownManifestNewerServerIsTrue() {
        XCTAssertTrue(DownloadManager.shouldRefreshLocalCover(manifestVersion: 1000, serverVersion: 2000))
    }

    // MARK: - DownloadedBook.coverUpdatedAt decoding

    private func decodeManifest(_ json: String) throws -> DownloadedBook {
        try JSONDecoder().decode(DownloadedBook.self, from: Data(json.utf8))
    }

    func testALegacyManifestWithNoCoverUpdatedAtKeyDecodesWithNil() throws {
        let manifest = try decodeManifest(#"""
        {
          "id": "b1", "title": "A Book", "author": "An Author",
          "duration": 300, "currentTime": 0,
          "chapters": [], "tracks": []
        }
        """#)
        XCTAssertNil(manifest.coverUpdatedAt)
    }

    func testAManifestWithACoverUpdatedAtKeyDecodesIt() throws {
        let manifest = try decodeManifest(#"""
        {
          "id": "b1", "title": "A Book", "author": "An Author",
          "duration": 300, "currentTime": 0,
          "chapters": [], "tracks": [], "coverUpdatedAt": 1700000000000
        }
        """#)
        XCTAssertEqual(manifest.coverUpdatedAt, 1_700_000_000_000)
    }

    func testCoverUpdatedAtSurvivesAnEncodeDecodeRoundTrip() throws {
        let manifest = DownloadedBook(
            id: "b1", title: "A Book", author: "An Author", narrator: nil,
            duration: 300, chapters: [], tracks: [],
            currentTime: 0, lastUpdate: nil, droppedChapterCount: 0,
            coverUpdatedAt: 1_700_000_000_000
        )
        let round = try JSONDecoder().decode(DownloadedBook.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(round.coverUpdatedAt, 1_700_000_000_000)
    }
}

// MARK: - Widget publisher (Batch 315 integration)

final class WidgetCoverRefreshDecisionTests: XCTestCase {
    func testMissingCoverIsAlwaysFetched() {
        XCTAssertTrue(WidgetLibraryPublisher.needsCoverRefresh(hasCover: false, publishedVersion: nil, currentVersion: nil))
        XCTAssertTrue(WidgetLibraryPublisher.needsCoverRefresh(hasCover: false, publishedVersion: 5, currentVersion: 5))
    }
    func testPresentCoverWithNoServerVersionIsLeftAlone() {
        XCTAssertFalse(WidgetLibraryPublisher.needsCoverRefresh(hasCover: true, publishedVersion: nil, currentVersion: nil))
        XCTAssertFalse(WidgetLibraryPublisher.needsCoverRefresh(hasCover: true, publishedVersion: 3, currentVersion: nil))
    }
    func testPresentCoverPublishedAtUnknownVersionIsRefreshedOnce() {
        XCTAssertTrue(WidgetLibraryPublisher.needsCoverRefresh(hasCover: true, publishedVersion: nil, currentVersion: 7))
    }
    func testPresentCoverIsRefreshedOnlyWhenTheServerMovedPast() {
        XCTAssertFalse(WidgetLibraryPublisher.needsCoverRefresh(hasCover: true, publishedVersion: 7, currentVersion: 7))
        XCTAssertFalse(WidgetLibraryPublisher.needsCoverRefresh(hasCover: true, publishedVersion: 8, currentVersion: 7))
        XCTAssertTrue(WidgetLibraryPublisher.needsCoverRefresh(hasCover: true, publishedVersion: 7, currentVersion: 8))
    }
}
