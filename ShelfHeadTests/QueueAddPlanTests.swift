import XCTest
@testable import ShelfHead

/// Pins the bulk "Add to Up Next" decision (library browse plan 2026-10-05 §3.2).
final class QueueAddPlanTests: XCTestCase {
    private func plan(_ adding: [String], existing: [String] = [], current: String? = nil)
        -> PlayerViewModel.QueueAddPlan {
        PlayerViewModel.queueAddPlan(addingIds: adding, existingIds: existing, currentId: current)
    }

    private func item(_ id: String) -> ShelfHead.LibraryItem {
        ShelfHead.LibraryItem(id: id, ino: nil, libraryId: nil, mediaType: "book", media: nil,
                    numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: nil)
    }

    func testOrderKept() {
        XCTAssertEqual(plan(["c", "a", "b"]).idsToAppend, ["c", "a", "b"])
    }

    func testSkipsCurrentAndExisting() {
        let p = plan(["a", "b", "c", "d"], existing: ["b"], current: "d")
        XCTAssertEqual(p.idsToAppend, ["a", "c"])
        XCTAssertEqual(p.skippedCount, 2)
    }

    func testDedupesWithinBatch() {
        let p = plan(["a", "a", "b", "a"])
        XCTAssertEqual(p.idsToAppend, ["a", "b"])
        XCTAssertEqual(p.skippedCount, 2)
    }

    func testMessages() {
        XCTAssertEqual(plan(["a"]).message, "Added to Up Next")
        XCTAssertEqual(plan(["a", "b", "c"]).message, "Added 3 books to Up Next")
        XCTAssertEqual(plan(["a", "b", "c"], existing: ["c"]).message,
                       "Added 2 books to Up Next \u{00B7} 1 was already queued")
        XCTAssertEqual(plan(["a", "b", "c", "d"], existing: ["c", "d"]).message,
                       "Added 2 books to Up Next \u{00B7} 2 were already queued")
        XCTAssertEqual(plan(["a", "b"], existing: ["a", "b"]).message, "Already in Up Next")
        XCTAssertEqual(plan([]).message, "Already in Up Next")
    }

    func testLibraryItemOverload() {
        let p = PlayerViewModel.queueAddPlan(adding: [item("a"), item("b")], existing: [item("a")], currentId: nil)
        XCTAssertEqual(p.idsToAppend, ["b"])
    }
}
