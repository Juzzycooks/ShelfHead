import XCTest
@testable import ShelfHead_Watch

/// Review Low (bookmarks, 30 October 2026): permanent failures drop a queued bookmark, transient ones keep it.
final class BookmarkFailureTests: XCTestCase {
    func testPermanentFailures() {
        // Review 3 Low (proxy 404/400): 404 and 400 drop only after repeated failures (see Review3WatchTests).
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.notFound))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.httpError(400)))
        XCTAssertTrue(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.httpError(410)))
        XCTAssertTrue(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.httpError(422)))
    }

    /// Review 2 Medium 10: a proxy gate's 403 (its own token expired) must not drop the bookmark.
    func testForbiddenIsTransient() {
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.forbidden))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.httpError(403)))
    }

    /// Review 2 Low (Watch offline flush): connection/session errors stop the flush; per-item errors don't.
    func testShouldStopFlush() {
        XCTAssertTrue(StandaloneBookmarkRules.shouldStopFlush(after: WatchAPIError.sessionExpired))
        XCTAssertTrue(StandaloneBookmarkRules.shouldStopFlush(after: WatchAPIError.transportError(URLError(.timedOut))))
        XCTAssertTrue(StandaloneBookmarkRules.shouldStopFlush(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(StandaloneBookmarkRules.shouldStopFlush(after: WatchAPIError.notFound))
        XCTAssertFalse(StandaloneBookmarkRules.shouldStopFlush(after: WatchAPIError.httpError(422)))
        XCTAssertFalse(StandaloneBookmarkRules.shouldStopFlush(after: WatchAPIError.serverError(503)))
    }

    func testFlushStopsOnTransportErrorAndKeepsTheRest() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = WatchPendingBookmarkQueue(fileURL: url)
        for t in [1.0, 2.0, 3.0] { await queue.add(.init(itemId: "a", title: "\(t)", time: t)) }
        var attempts = 0
        let sent = await queue.flush { _ in
            attempts += 1
            throw WatchAPIError.transportError(URLError(.timedOut))
        }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(attempts, 1, "one timeout, not one per bookmark")
        let left = await queue.pending()
        XCTAssertEqual(left.count, 3)
    }

    func testTransientFailures() {
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.httpError(408)))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.httpError(429)))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.serverError(503)))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.sessionExpired))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(WatchAPIError.transportError(URLError(.notConnectedToInternet))))
        XCTAssertFalse(StandaloneBookmarkRules.isPermanentFailure(URLError(.timedOut)))
    }

    func testFlushSkipsPermanentAndKeepsTransient() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = WatchPendingBookmarkQueue(fileURL: url)
        await queue.add(.init(itemId: "a", title: "bad", time: 1))
        await queue.add(.init(itemId: "a", title: "flaky", time: 2))
        await queue.add(.init(itemId: "a", title: "ok", time: 3))
        let sent = await queue.flush { entry in
            if entry.title == "bad" { throw WatchAPIError.httpError(410) }  // Review 3: 404 now needs five failures
            if entry.title == "flaky" { throw WatchAPIError.serverError(503) }
        }
        XCTAssertEqual(sent, 1)
        let left = await queue.pending().map(\.title)
        XCTAssertEqual(left, ["flaky"])
    }
}
