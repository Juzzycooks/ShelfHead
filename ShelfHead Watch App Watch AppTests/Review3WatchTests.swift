import XCTest
@testable import ShelfHead_Watch

final class Review3WatchTests: XCTestCase {
    func testOldQueueEntryDecodesWithZeroCounter() throws {
        let json = #"[{"itemId":"a","title":"t","time":12.5}]"#.data(using: .utf8)!
        let entries = try JSONDecoder().decode([WatchPendingBookmarkQueue.Entry].self, from: json)
        XCTAssertEqual(entries.first?.ambiguousFailures, 0)
    }

    func testImmediatelyPermanentCodes() {
        XCTAssertTrue(StandaloneBookmarkRules.shouldDrop(after: WatchAPIError.httpError(422), priorAmbiguousFailures: 0))
        XCTAssertTrue(StandaloneBookmarkRules.shouldDrop(after: WatchAPIError.httpError(410), priorAmbiguousFailures: 0))
    }

    func testAmbiguousCodesDropOnlyAfterLimit() {
        let limit = StandaloneBookmarkRules.ambiguousFailureLimit
        for error in [WatchAPIError.httpError(404), WatchAPIError.httpError(400), WatchAPIError.notFound] {
            XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: 0))
            XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: limit - 2))
            // Review 4 Low (ambiguous window): the count alone no longer drops; see Review4WatchTests.
            XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: limit - 1))
        }
    }

    func testOtherErrorsNeverDrop() {
        XCTAssertFalse(StandaloneBookmarkRules.shouldDrop(after: WatchAPIError.httpError(503), priorAmbiguousFailures: 99))
    }
}
