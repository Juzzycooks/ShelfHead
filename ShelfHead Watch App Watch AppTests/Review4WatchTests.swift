import XCTest
@testable import ShelfHead_Watch

final class Review4WatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAmbiguousDropNeedsCountAndAge() {
        let limit = StandaloneBookmarkRules.ambiguousFailureLimit
        let day = StandaloneBookmarkRules.ambiguousFailureWindow
        let error = WatchAPIError.httpError(404)
        // Count reached, but the first failure was minutes ago.
        XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: limit - 1,
                                                          firstAmbiguousFailureAt: now.addingTimeInterval(-300), now: now))
        // Old enough but count not reached.
        XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: limit - 2,
                                                          firstAmbiguousFailureAt: now.addingTimeInterval(-2 * day), now: now))
        // Both.
        XCTAssertTrue(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: limit - 1,
                                                         firstAmbiguousFailureAt: now.addingTimeInterval(-day), now: now))
        // No timestamp: never dropped yet.
        XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: 99, now: now))
    }

    func testPermanentCodesIgnoreAge() {
        XCTAssertTrue(StandaloneBookmarkRules.shouldDrop(after: WatchAPIError.httpError(410), priorAmbiguousFailures: 0, now: now))
    }

    func testOldEntryDecodesWithIdAndNoTimestamp() throws {
        let json = #"[{"itemId":"a","title":"t","time":1,"ambiguousFailures":2}]"#.data(using: .utf8)!
        let entry = try JSONDecoder().decode([WatchPendingBookmarkQueue.Entry].self, from: json)[0]
        XCTAssertNil(entry.firstAmbiguousFailureAt)
        XCTAssertEqual(entry.ambiguousFailures, 2)
    }

    func testEntryRoundTripKeepsIdAndTimestamp() throws {
        let entry = WatchPendingBookmarkQueue.Entry(itemId: "a", title: "t", time: 1, ambiguousFailures: 1,
                                                    firstAmbiguousFailureAt: now)
        let back = try JSONDecoder().decode(WatchPendingBookmarkQueue.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back, entry)
    }

    func testFlushCountsFailureAndStampsFirstTime() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("q.json")
        let queue = WatchPendingBookmarkQueue(fileURL: url)
        await queue.add(.init(itemId: "a", title: "t", time: 1))
        await queue.flush { _ in throw WatchAPIError.httpError(404) }
        let entry = await queue.pending()[0]
        XCTAssertEqual(entry.ambiguousFailures, 1)
        XCTAssertNotNil(entry.firstAmbiguousFailureAt)
    }
}
