import XCTest
@testable import ShelfHead_Watch

final class Review5BookmarkQueueTests: XCTestCase {
    private func makeQueue() -> WatchPendingBookmarkQueue {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        return WatchPendingBookmarkQueue(fileURL: url)
    }

    func testAddReplacingSameSecondKeepsEntryID() async {
        let q = makeQueue()
        let a = WatchPendingBookmarkQueue.Entry(itemId: "i", title: "A", time: 10.2)
        await q.add(a)
        await q.add(.init(itemId: "i", title: "B", time: 10.7))
        let p = await q.pending()
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].id, a.id)
        XCTAssertEqual(p[0].title, "B")
    }

    func testServerErrorResetsAmbiguousCount() async {
        let q = makeQueue()
        await q.add(.init(itemId: "i", title: "A", time: 5, ambiguousFailures: 3, firstAmbiguousFailureAt: Date()))
        await q.flush { _ in throw WatchAPIError.httpError(500) }
        let p = await q.pending()
        XCTAssertEqual(p[0].ambiguousFailures, 0)
        XCTAssertNil(p[0].firstAmbiguousFailureAt)
    }
}
