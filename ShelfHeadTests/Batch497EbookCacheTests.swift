import XCTest
@testable import ShelfHead

/// Batch 497 (REVIEW 2026-11-11 L11): the cached ebook is refreshed when the server's file changes.
final class Batch497EbookCacheTests: XCTestCase {
    private typealias FP = EbookStore.Fingerprint

    func testEqualFingerprintsKeepCache() {
        let fp = FP(ino: "1", size: 100, mtimeMs: 5, updatedAt: 9)
        XCTAssertEqual(EbookStore.freshness(stored: fp, current: fp), .keep)
    }

    func testDifferentFieldsRefetch() {
        let stored = FP(ino: "1", size: 100, mtimeMs: 5, updatedAt: 9)
        XCTAssertEqual(EbookStore.freshness(stored: stored, current: FP(ino: "2", size: 100, mtimeMs: 5, updatedAt: 9)), .refetch)
        XCTAssertEqual(EbookStore.freshness(stored: stored, current: FP(ino: "1", size: 101, mtimeMs: 5, updatedAt: 9)), .refetch)
        XCTAssertEqual(EbookStore.freshness(stored: stored, current: FP(ino: "1", size: 100, mtimeMs: 6, updatedAt: 9)), .refetch)
        XCTAssertEqual(EbookStore.freshness(stored: stored, current: FP(ino: "1", size: 100, mtimeMs: 5, updatedAt: 10)), .refetch)
    }

    func testMissingFieldsAreNotCompared() {
        let stored = FP(ino: "1", size: 100, mtimeMs: 5, updatedAt: 9)
        // An older server that omits fields never forces a download, and nothing new is stored.
        XCTAssertEqual(EbookStore.freshness(stored: stored, current: FP(ino: "1")), .adopt)
        XCTAssertEqual(EbookStore.freshness(stored: FP(ino: "1"), current: FP(ino: "1", size: 100)), .adopt)
        XCTAssertEqual(EbookStore.freshness(stored: FP(ino: nil), current: FP(ino: nil)), .keep)
    }

    func testNoStoredFingerprintAdopts() {
        XCTAssertEqual(EbookStore.freshness(stored: nil, current: FP(ino: "1", size: 1)), .adopt)
    }

    func testFingerprintRoundTrips() throws {
        let fp = FP(ino: "1", size: 100, mtimeMs: 5.5, updatedAt: nil)
        XCTAssertEqual(try JSONDecoder().decode(FP.self, from: JSONEncoder().encode(fp)), fp)
    }

    func testClampedPage() {
        XCTAssertNil(EbookStore.clampedPage(nil, pageCount: 10))
        XCTAssertNil(EbookStore.clampedPage(3, pageCount: 0))
        XCTAssertEqual(EbookStore.clampedPage(3, pageCount: 10), 3)
        XCTAssertEqual(EbookStore.clampedPage(40, pageCount: 10), 9)
        XCTAssertEqual(EbookStore.clampedPage(-2, pageCount: 10), 0)
    }

    func testClampedPosition() {
        XCTAssertNil(EbookStore.clampedPosition(nil, spineCount: 5))
        XCTAssertNil(EbookStore.clampedPosition(EPUBPosition(spineIndex: 1, fraction: 0.5), spineCount: 0))
        XCTAssertEqual(EbookStore.clampedPosition(EPUBPosition(spineIndex: 2, fraction: 0.5), spineCount: 5),
                       EPUBPosition(spineIndex: 2, fraction: 0.5))
        XCTAssertEqual(EbookStore.clampedPosition(EPUBPosition(spineIndex: 9, fraction: 0.5), spineCount: 5),
                       EPUBPosition(spineIndex: 4, fraction: 0.5))
        XCTAssertEqual(EbookStore.clampedPosition(EPUBPosition(spineIndex: -1, fraction: 0.2), spineCount: 5)?.spineIndex, 0)
    }
}
