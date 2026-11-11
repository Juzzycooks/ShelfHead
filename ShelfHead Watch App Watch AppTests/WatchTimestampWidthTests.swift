import XCTest
@testable import ShelfHead_Watch

/// Batch 490: on arm64_32 Apple Watch hardware `Int` is 32 bits, so a millisecond timestamp
/// decoded as `Int` makes `JSONDecoder` throw. The simulator is 64-bit and can't reproduce
/// that, so these tests pin the *width* of every timestamp field the Watch decodes from the
/// server, and that real-sized values round-trip.
@MainActor
final class WatchTimestampWidthTests: XCTestCase {
    private let ms: Int64 = 1_762_819_200_123   // 11 November 2026, larger than Int32.max

    func testLibraryItemTimestampsAre64Bit() throws {
        let json = """
        {"id":"a","libraryId":"lib","mediaType":"book","addedAt":\(ms),"updatedAt":\(ms),
         "userMediaProgress":{"id":"p","libraryItemId":"a","lastUpdate":\(ms)}}
        """
        let item = try JSONDecoder().decode(WatchLibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.addedAt, ms)
        XCTAssertEqual(item.updatedAt, ms)
        XCTAssertEqual(item.mediaProgress?.lastUpdate, ms)
        XCTAssertEqual(MemoryLayout.size(ofValue: item.addedAt ?? 0), 8)
        XCTAssertEqual(MemoryLayout.size(ofValue: item.updatedAt ?? 0), 8)
        XCTAssertEqual(MemoryLayout.size(ofValue: item.mediaProgress?.lastUpdate ?? 0), 8)
    }

    func testLibraryItemSurvivesTheDiskCacheRoundTrip() throws {
        let json = """
        {"id":"a","libraryId":"lib","mediaType":"book","addedAt":\(ms),"updatedAt":\(ms)}
        """
        let item = try JSONDecoder().decode(WatchLibraryItem.self, from: Data(json.utf8))
        let again = try JSONDecoder().decode(WatchLibraryItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again.addedAt, ms)
        XCTAssertEqual(again.updatedAt, ms)
    }

    func testAuthSessionTimestampsAre64Bit() throws {
        let json = """
        {"total":1,"sessions":[{"id":"s","ipAddress":null,"userAgent":"ShelfHead","createdAt":\(ms),"updatedAt":\(ms),"current":true}]}
        """
        let response = try JSONDecoder().decode(WatchAuthSessionsResponse.self, from: Data(json.utf8))
        let session = try XCTUnwrap(response.sessions.first)
        XCTAssertEqual(session.createdAt, ms)
        XCTAssertEqual(session.updatedAt, ms)
        XCTAssertEqual(MemoryLayout.size(ofValue: session.createdAt ?? 0), 8)
        XCTAssertEqual(WatchSessionLabel.lastUsedDate(updatedAtMs: session.updatedAt, createdAtMs: session.createdAt),
                       Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
