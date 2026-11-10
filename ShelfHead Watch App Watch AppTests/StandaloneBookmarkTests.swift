import XCTest
@testable import ShelfHead_Watch

/// PL-4 follow-up: standalone Watch bookmarks (naming, merging, the offline queue).
final class StandaloneBookmarkTests: XCTestCase {
    private func bm(_ time: Double, _ title: String = "t", pending: Bool = false) -> StandaloneBookmark {
        StandaloneBookmark(itemId: "i", title: title, time: time, isPending: pending)
    }

    func testWholeSecondsNeverTraps() {
        XCTAssertEqual(StandaloneBookmarkRules.wholeSeconds(12.9), 12)
        XCTAssertEqual(StandaloneBookmarkRules.wholeSeconds(-3), 0)
        XCTAssertEqual(StandaloneBookmarkRules.wholeSeconds(.nan), 0)
        XCTAssertEqual(StandaloneBookmarkRules.wholeSeconds(.infinity), 0)
        XCTAssertEqual(StandaloneBookmarkRules.wholeSeconds(1e30), 10_000_000)
    }

    func testDefaultTitlePrefersTheChapter() {
        XCTAssertEqual(StandaloneBookmarkRules.defaultTitle(chapterTitle: "  Chapter 3 ", time: 100), "Chapter 3")
        XCTAssertTrue(StandaloneBookmarkRules.defaultTitle(chapterTitle: nil, time: 75).hasPrefix("Bookmark at "))
        XCTAssertTrue(StandaloneBookmarkRules.defaultTitle(chapterTitle: "   ", time: 75).hasPrefix("Bookmark at "))
    }

    func testMergeSortsAndLetsPendingReplaceTheSameSecond() {
        let merged = StandaloneBookmarkRules.merged(
            server: [bm(90, "server 90"), bm(10, "server 10")],
            pending: [bm(90.4, "pending 90", pending: true), bm(50, "pending 50", pending: true)])
        XCTAssertEqual(merged.map(\.time), [10, 50, 90.4])
        XCTAssertEqual(merged.last?.title, "pending 90")
        XCTAssertTrue(merged.last?.isPending == true)
    }

    private func tempQueue() -> (WatchPendingBookmarkQueue, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bm-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("q.json")
        return (WatchPendingBookmarkQueue(fileURL: url), url)
    }

    func testQueueReplacesTheSameSecondAndPersists() async {
        let (queue, url) = tempQueue()
        await queue.add(.init(itemId: "i", title: "a", time: 10.1))
        await queue.add(.init(itemId: "i", title: "b", time: 10.8))
        await queue.add(.init(itemId: "j", title: "c", time: 10.2))
        let all = await queue.pending()
        XCTAssertEqual(all.map(\.title), ["b", "c"])
        let reloaded = WatchPendingBookmarkQueue(fileURL: url)
        let again = await reloaded.pending(itemId: "i")
        XCTAssertEqual(again.map(\.title), ["b"])
    }

    func testFlushKeepsATransientFailureAndContinuesWithTheRest() async {
        let (queue, _) = tempQueue()
        for (i, t) in [10.0, 20.0, 30.0].enumerated() { await queue.add(.init(itemId: "i", title: "\(i)", time: t)) }
        struct Boom: Error {}
        var seen: [Double] = []
        let sent = await queue.flush { entry in
            if entry.time == 20 { throw Boom() }
            seen.append(entry.time)
        }
        // Review Low (bookmarks, 30 Oct 2026): a failing entry no longer blocks the ones behind it.
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(seen, [10, 30])
        let left = await queue.pending()
        XCTAssertEqual(left.map(\.time), [20], "only the transiently failed entry stays queued")
    }

    func testClearEmptiesTheQueue() async {
        let (queue, _) = tempQueue()
        await queue.add(.init(itemId: "i", title: "x", time: 1))
        await queue.clear()
        let left = await queue.pending()
        XCTAssertTrue(left.isEmpty)
    }
}

/// L14: the complication snapshot's JSON keys are the contract with `ShelfHeadWatchWidgets`,
/// which declares its own copy of the struct.
final class WatchComplicationSnapshotTests: XCTestCase {
    func testJSONKeysMatchWhatTheWidgetDecodes() throws {
        let snapshot = WatchComplicationSnapshot(title: "T", author: "A", progress: 0.5, isPlaying: true, updatedAt: Date(timeIntervalSince1970: 0))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["title", "author", "progress", "isPlaying", "updatedAt"])
    }

    func testProgressIsClampedAndSafe() {
        XCTAssertEqual(WatchComplicationSnapshot.progress(currentTime: 50, duration: 200), 0.25)
        XCTAssertEqual(WatchComplicationSnapshot.progress(currentTime: 500, duration: 200), 1)
        XCTAssertEqual(WatchComplicationSnapshot.progress(currentTime: -5, duration: 200), 0)
        XCTAssertEqual(WatchComplicationSnapshot.progress(currentTime: 5, duration: 0), 0)
        XCTAssertEqual(WatchComplicationSnapshot.progress(currentTime: .nan, duration: 200), 0)
    }

    func testAppGroupMatchesTheWidgetEntitlement() {
        XCTAssertEqual(WatchComplicationSnapshot.appGroup, "group.com.shelfhead.app")
    }
}
