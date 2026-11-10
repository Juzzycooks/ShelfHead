import XCTest
@testable import ShelfHead

final class CloudPositionMergeTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let record = CloudPositionStore.Record(
            currentTime: 123.5, duration: 3600, updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceName: "iPhone")
        let decoded = CloudPositionStore.decode(CloudPositionStore.encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testDecodeInvalidReturnsNil() {
        XCTAssertNil(CloudPositionStore.decode(nil))
        XCTAssertNil(CloudPositionStore.decode(["t": 1.0] as [String: Any]))
        XCTAssertNil(CloudPositionStore.decode("not a dictionary"))
    }

    func testKeyFormat_scopeIsHashedAndShortItemIdStaysVerbatim() {
        let key = CloudPositionStore.key(scope: "server|acct", itemId: "book123")
        XCTAssertTrue(key.hasPrefix("pos."))
        XCTAssertTrue(key.hasSuffix(".book123"))
        // "pos." + 16 hex + "." + itemId
        XCTAssertEqual(key.count, 4 + 16 + 1 + "book123".count)
        XCTAssertFalse(key.contains("server|acct"), "the raw scope must not appear in the key")
    }

    func testKeyIsStableAndScopeSensitive() {
        XCTAssertEqual(CloudPositionStore.key(scope: "a", itemId: "x"), CloudPositionStore.key(scope: "a", itemId: "x"))
        XCTAssertNotEqual(CloudPositionStore.key(scope: "a", itemId: "x"), CloudPositionStore.key(scope: "b", itemId: "x"))
        XCTAssertNotEqual(CloudPositionStore.key(scope: "a", itemId: "x"), CloudPositionStore.key(scope: "a", itemId: "y"))
    }

    /// Regression for the 6.1 build 1 TestFlight crash: `NSUbiquitousKeyValueStore` raises
    /// an uncatchable `NSException` for an over-long key, and the real scope (base64 of
    /// `serverURL|accountUUID`) plus a UUID item id used to produce keys of 120–145
    /// characters. Every key must now fit the stricter of Apple's two documented limits
    /// (64 bytes / 128 UTF-16 characters) regardless of input length.
    func testKeyNeverExceedsStoreLimit_realisticScope() {
        let scope = DownloadPaths.scopeKey(
            serverURL: "https://audiobookshelf.myhome.duckdns.org",
            accountId: "3F2B8C1E-9A4D-4E7B-8C2A-1D5E6F7A8B9C")
        let key = CloudPositionStore.key(scope: scope, itemId: "6b225227-17e9-4bad-bbfe-9fcbc6eebaab")
        XCTAssertLessThanOrEqual(key.utf16.count, CloudPositionStore.maxKeyLength)
        XCTAssertLessThan(CloudPositionStore.maxKeyLength, 64)
        XCTAssertTrue(key.hasSuffix(".6b225227-17e9-4bad-bbfe-9fcbc6eebaab"), "a UUID item id stays verbatim")
    }

    func testKeyNeverExceedsStoreLimit_pathologicalInputs() {
        let longScope = String(repeating: "s", count: 5_000)
        let longItemId = String(repeating: "i", count: 5_000)
        let key = CloudPositionStore.key(scope: longScope, itemId: longItemId)
        XCTAssertLessThanOrEqual(key.utf16.count, CloudPositionStore.maxKeyLength)
        XCTAssertEqual(key.utf16.count, 4 + 16 + 1 + 32, "long item ids fold to 32 hex")
        // Non-ASCII item ids: the limit is in UTF-16 units, so measure that way.
        let emojiId = String(repeating: "📚", count: 40)
        XCTAssertLessThanOrEqual(CloudPositionStore.key(scope: longScope, itemId: emojiId).utf16.count,
                                 CloudPositionStore.maxKeyLength)
    }

    func testShouldAdoptCloudPosition_nilCloud() {
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: nil, localCurrentTime: 0, localUpdatedAt: nil, serverReachable: false))
    }

    func testShouldAdoptCloudPosition_serverReachable() {
        let cloud = CloudPositionStore.Record(currentTime: 500, duration: 3600, updatedAt: Date(), deviceName: "d")
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 0, localUpdatedAt: nil, serverReachable: true))
    }

    func testShouldAdoptCloudPosition_gapTooSmall() {
        let cloud = CloudPositionStore.Record(currentTime: 100, duration: 3600, updatedAt: Date(), deviceName: "d")
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 90, localUpdatedAt: nil, serverReachable: false))
    }

    func testShouldAdoptCloudPosition_localNewer() {
        let cloud = CloudPositionStore.Record(
            currentTime: 500, duration: 3600, updatedAt: Date(timeIntervalSince1970: 1000), deviceName: "d")
        let localUpdatedAt = Date(timeIntervalSince1970: 2000)
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 0, localUpdatedAt: localUpdatedAt, serverReachable: false))
    }

    func testShouldAdoptCloudPosition_localOlderUnreachableGapMet() {
        let cloud = CloudPositionStore.Record(
            currentTime: 500, duration: 3600, updatedAt: Date(timeIntervalSince1970: 2000), deviceName: "d")
        let localUpdatedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 0, localUpdatedAt: localUpdatedAt, serverReachable: false))
    }

    func testShouldAdoptCloudPosition_nilLocalUpdatedAtUnreachable() {
        let cloud = CloudPositionStore.Record(currentTime: 500, duration: 3600, updatedAt: Date(), deviceName: "d")
        XCTAssertTrue(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 0, localUpdatedAt: nil, serverReachable: false))
    }
}
