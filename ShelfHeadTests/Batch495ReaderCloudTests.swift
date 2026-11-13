import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 L12): EPUB positions in iCloud key-value storage, and the
/// key ownership rule behind `CloudPositionStore.deleteAllFromCloud()`.
final class Batch495ReaderCloudTests: XCTestCase {

    // MARK: Keys

    func testEPUBKeyStaysUnderStoreLimits() {
        let longScope = String(repeating: "https://audiobooks.example.com:13378|someone@example.com", count: 4)
        let uuid = "0b6e3a52-2c11-4c6a-9d4f-3a0f6c1e2b7d"
        let longId = String(repeating: "x", count: 300)
        for id in [uuid, longId, "", "li_short"] {
            let key = CloudPositionStore.epubKey(scope: longScope, itemId: id)
            XCTAssertLessThanOrEqual(key.utf16.count, CloudPositionStore.maxEPUBKeyLength)
            XCTAssertLessThanOrEqual(key.utf16.count, 64, "under the stricter documented limit")
            XCTAssertTrue(key.hasPrefix("epub."))
        }
        XCTAssertEqual(CloudPositionStore.maxEPUBKeyLength, 62)
    }

    func testEPUBKeyIsDeterministicAndDistinctFromAudioKey() {
        let a = CloudPositionStore.epubKey(scope: "s", itemId: "i")
        XCTAssertEqual(a, CloudPositionStore.epubKey(scope: "s", itemId: "i"))
        XCTAssertNotEqual(a, CloudPositionStore.epubKey(scope: "t", itemId: "i"))
        XCTAssertNotEqual(a, CloudPositionStore.key(scope: "s", itemId: "i"))
    }

    func testIsOwnedKey() {
        XCTAssertTrue(CloudPositionStore.isOwnedKey(CloudPositionStore.key(scope: "s", itemId: "i")))
        XCTAssertTrue(CloudPositionStore.isOwnedKey(CloudPositionStore.epubKey(scope: "s", itemId: "i")))
        // The 6.0 / 6.1 build 1 long-key format (base64 scope) is still ours.
        XCTAssertTrue(CloudPositionStore.isOwnedKey("pos.aHR0cHM6Ly9leGFtcGxlLmNvbXwxMjM=.item"))
        XCTAssertFalse(CloudPositionStore.isOwnedKey("position.x"))
        XCTAssertFalse(CloudPositionStore.isOwnedKey("epubReader.fontScale"))
        XCTAssertFalse(CloudPositionStore.isOwnedKey("com.apple.something"))
        XCTAssertFalse(CloudPositionStore.isOwnedKey(""))
    }

    // MARK: Records

    func testEPUBRecordRoundTripsAndClamps() {
        let record = CloudPositionStore.EPUBRecord(spineIndex: 7, fraction: 0.42, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(CloudPositionStore.decodeEPUB(CloudPositionStore.encodeEPUB(record)), record)
        let odd = CloudPositionStore.decodeEPUB(["s": -3, "f": 1.7, "u": 10.0])
        XCTAssertEqual(odd?.spineIndex, 0)
        XCTAssertEqual(odd?.fraction, 1)
        XCTAssertNil(CloudPositionStore.decodeEPUB(["s": 1, "u": 10.0]))
        XCTAssertNil(CloudPositionStore.decodeEPUB("nope"))
        XCTAssertNil(CloudPositionStore.decodeEPUB(nil))
    }

    // MARK: Adoption

    func testShouldAdoptCloudEPUBPosition() {
        let now = Date()
        let cloud = CloudPositionStore.EPUBRecord(spineIndex: 3, fraction: 0.5, updatedAt: now)
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: nil, localSavedAt: nil))
        XCTAssertTrue(CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: cloud, localSavedAt: nil))
        XCTAssertTrue(CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: cloud, localSavedAt: now.addingTimeInterval(-60)))
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: cloud, localSavedAt: now))
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: cloud, localSavedAt: now.addingTimeInterval(-0.5)))
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: cloud, localSavedAt: now.addingTimeInterval(60)))
    }

    // MARK: Eviction

    func testEvictsOldestEPUBKeysOnly() {
        let base = Date(timeIntervalSince1970: 1_000)
        var stamps: [String: Date] = [:]
        for i in 0..<5 { stamps["epub.s.\(i)"] = base.addingTimeInterval(Double(i)) }
        stamps["pos.s.old"] = .distantPast
        let evicted = CloudPositionStore.epubKeysToEvict(stamps, limit: 3)
        XCTAssertEqual(evicted, ["epub.s.0", "epub.s.1"])
        XCTAssertTrue(CloudPositionStore.epubKeysToEvict(stamps, limit: 5).isEmpty)
        XCTAssertEqual(CloudPositionStore.epubKeysToEvict(stamps, limit: 0).count, 5)
    }

    func testEvictionTieBreaksByKey() {
        let t = Date(timeIntervalSince1970: 5)
        let evicted = CloudPositionStore.epubKeysToEvict(["epub.b": t, "epub.a": t, "epub.c": t], limit: 1)
        XCTAssertEqual(evicted, ["epub.a", "epub.b"])
    }

    func testCapLeavesRoomForAudioKeys() {
        XCTAssertLessThan(CloudPositionStore.maxEPUBKeys, 1024 / 2)
    }
}
