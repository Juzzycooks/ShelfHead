import XCTest
@testable import ShelfHead

/// Review Medium 15 (30 October 2026): hold only downloaded books; Use Server discards.
final class PendingProgressHoldScopeTests: XCTestCase {
    private var scratchURL: URL!

    override func setUp() {
        super.setUp()
        scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingProgressHoldScopeTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchURL)
        super.tearDown()
    }

    private func entry(_ itemId: String, time: Double = 100) -> PendingProgressQueue.Entry {
        .init(scope: "s", itemId: itemId, currentTime: time, duration: 10_000,
              updatedAt: Date().timeIntervalSince1970)
    }

    func testMayHold() {
        XCTAssertTrue(PendingProgressQueue.mayHold(itemId: "a", downloadedItemIds: nil))
        XCTAssertTrue(PendingProgressQueue.mayHold(itemId: "a", downloadedItemIds: ["a"]))
        XCTAssertFalse(PendingProgressQueue.mayHold(itemId: "a", downloadedItemIds: ["b"]))
    }

    func testStreamedBookBehindServerIsPushedNotHeld() async {
        let queue = PendingProgressQueue(fileURL: scratchURL)
        await queue.record(entry("streamed"))
        let drained = await queue.drain(
            activeScope: "s",
            serverProgress: ["streamed": .init(lastUpdate: 1, currentTime: 5000)],
            conflictThreshold: 300, downloadedItemIds: [])
        XCTAssertEqual(drained.map(\.itemId), ["streamed"])
    }

    func testDownloadedBookBehindServerIsStillHeld() async {
        let queue = PendingProgressQueue(fileURL: scratchURL)
        await queue.record(entry("dl"))
        let drained = await queue.drain(
            activeScope: "s",
            serverProgress: ["dl": .init(lastUpdate: 1, currentTime: 5000)],
            conflictThreshold: 300, downloadedItemIds: ["dl"])
        XCTAssertTrue(drained.isEmpty)
        let held = await queue.heldForConflictCount(forScope: "s")
        XCTAssertEqual(held, 1)
    }

    func testDiscardAudioEntryRemovesHeldEntry() async {
        let queue = PendingProgressQueue(fileURL: scratchURL)
        await queue.record(entry("dl"))
        _ = await queue.drain(
            activeScope: "s", serverProgress: ["dl": .init(lastUpdate: 1, currentTime: 5000)],
            conflictThreshold: 300, downloadedItemIds: ["dl"])
        await queue.discardAudioEntry(itemId: "dl", scope: "s")
        let held = await queue.heldForConflictCount(forScope: "s")
        XCTAssertEqual(held, 0)
        let all = await queue.allEntries()
        XCTAssertTrue(all.isEmpty)
    }
}
