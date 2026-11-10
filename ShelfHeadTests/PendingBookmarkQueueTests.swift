import XCTest
@testable import ShelfHead

/// Cover for the offline bookmark queue and the read-path merge that shows queued work.
///
/// Each test points a fresh `PendingBookmarkQueue` at a scratch file, the same seam
/// `PendingProgressQueueTests` uses, so nothing here touches the app's real queue.
final class PendingBookmarkQueueTests: XCTestCase {

    private var fileURL: URL!
    private var queue: PendingBookmarkQueue!
    private let scope = "server|account"

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-queue-tests-\(UUID().uuidString)")
            .appendingPathComponent("queue.json")
        queue = PendingBookmarkQueue(fileURL: fileURL)
    }

    override func tearDown() {
        // One test leaves the queue file mode 000; restore it so the sweep can remove it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        queue = nil
        fileURL = nil
        super.tearDown()
    }

    private func entry(
        _ operation: PendingBookmarkQueue.Operation, itemId: String = "book1",
        time: Double = 120, title: String = "A note", at updatedAt: Double
    ) -> PendingBookmarkQueue.Entry {
        .init(scope: scope, itemId: itemId, time: time, title: title,
              operation: operation, updatedAt: updatedAt)
    }

    // MARK: - Folding

    func testCreateThenDeleteWhileOfflineAnnihilates() async {
        await queue.record(entry(.create, at: 100))
        await queue.record(entry(.delete, at: 200))
        let all = await queue.allEntries()
        XCTAssertTrue(all.isEmpty, "A bookmark created and deleted before syncing needs no server call at all")
    }

    func testCreateThenEditStaysACreateWithTheNewTitle() async {
        await queue.record(entry(.create, title: "First", at: 100))
        await queue.record(entry(.update, title: "Edited", at: 200))
        let all = await queue.allEntries()
        XCTAssertEqual(all.count, 1)
        let queued = all.values.first
        XCTAssertEqual(queued?.operation, .create, "Replaying a PATCH for a bookmark the server has never seen would fail")
        XCTAssertEqual(queued?.title, "Edited")
    }

    func testEditOfSyncedBookmarkStaysAnUpdate() async {
        await queue.record(entry(.update, title: "Edited", at: 100))
        let all = await queue.allEntries()
        XCTAssertEqual(all.values.first?.operation, .update)
    }

    func testOlderOperationDoesNotOverwriteNewer() async {
        await queue.record(entry(.delete, at: 200))
        await queue.record(entry(.create, title: "Stale", at: 100))
        let all = await queue.allEntries()
        XCTAssertEqual(all.values.first?.operation, .delete, "An out-of-order replay must not resurrect a deleted bookmark")
    }

    /// Identity is whole seconds, matching `AudioBookmark.id` and the delete endpoint —
    /// float noise must not stop a delete from cancelling the create it undoes.
    func testSubSecondDifferenceIsTheSameBookmark() async {
        await queue.record(entry(.create, time: 120.0, at: 100))
        await queue.record(entry(.delete, time: 120.4, at: 200))
        let all = await queue.allEntries()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Scoping and draining

    /// Timestamps must be realistic here, not small integers: `drain` evicts anything older
    /// than `maxAge` (30 days), so epoch-relative values near zero are all "ancient" and
    /// the drain comes back empty for a reason that has nothing to do with what's tested.
    func testDrainReturnsOnlyActiveScopeOldestFirst() async {
        let now = Date().timeIntervalSince1970
        await queue.record(entry(.create, itemId: "b1", time: 10, at: now - 10))
        await queue.record(entry(.create, itemId: "b2", time: 20, at: now - 30))
        await queue.record(.init(scope: "other|account", itemId: "b3", time: 30,
                                 title: "x", operation: .create, updatedAt: now - 20))
        let drained = await queue.drain(activeScope: scope)
        XCTAssertEqual(drained.map(\.itemId), ["b2", "b1"], "Replay must follow the order the user acted in")
    }

    func testDrainEvictsEntriesTooOldToEverMatchAgain() async {
        let ancient = Date().timeIntervalSince1970 - (40 * 24 * 3600)
        await queue.record(entry(.create, at: ancient))
        _ = await queue.drain(activeScope: scope)
        let all = await queue.allEntries()
        XCTAssertTrue(all.isEmpty, "A removed account's entries would otherwise sit in the file forever")
    }

    func testClearRefusesToDeleteANewerOperation() async {
        await queue.record(entry(.create, at: 100))
        await queue.record(entry(.update, title: "Newer", at: 500))
        await queue.clear(itemId: "book1", time: 120, scope: scope, ifNotNewerThan: 100)
        let all = await queue.allEntries()
        XCTAssertEqual(all.count, 1, "A flush's success must not delete an edit that raced in behind it")
    }

    func testCountAndPendingAreScoped() async {
        await queue.record(entry(.create, itemId: "b1", time: 10, at: 100))
        await queue.record(.init(scope: "other|account", itemId: "b2", time: 20,
                                 title: "x", operation: .create, updatedAt: 100))
        let count = await queue.count(forScope: scope)
        let forItem = await queue.pending(forScope: scope, itemId: "b1")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(forItem.count, 1)
    }

    func testEntriesSurviveAcrossInstances() async {
        await queue.record(entry(.create, at: 100))
        let reopened = PendingBookmarkQueue(fileURL: fileURL)
        let all = await reopened.allEntries()
        XCTAssertEqual(all.count, 1, "The whole point is surviving the relaunch that follows going offline")
    }

    // MARK: - Damaged queue file

    /// A corrupt queue file used to read as "empty" and then be overwritten by the next
    /// `persist()`. Now the bytes are moved to `queue.json.corrupt` first, and the queue
    /// carries on from empty so the user can still make bookmarks.
    func testCorruptQueueFileIsQuarantinedAndTheQueueStillWorks() async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{\"truncated\": ".utf8)
        try garbage.write(to: fileURL)

        let fresh = PendingBookmarkQueue(fileURL: fileURL)
        let loaded = await fresh.allEntries()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(try Data(contentsOf: PersistedStoreLoad.quarantineURL(for: fileURL)), garbage,
                       "The unreadable bytes must be recoverable, not silently destroyed")

        await fresh.record(entry(.create, at: 100))
        let reopened = PendingBookmarkQueue(fileURL: fileURL)
        let reloaded = await reopened.allEntries()
        XCTAssertEqual(reloaded.count, 1, "Once quarantined, persisting is safe again")
    }

    /// The case the fix exists for: the file is there and we can't read it. Recording must
    /// not cause `persist()` to replace it with an almost-empty queue.
    func testUnreadableQueueFileIsNotOverwritten() async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(
            ["k": entry(.create, itemId: "already-queued", at: 100)])
        try original.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        if (try? Data(contentsOf: fileURL)) != nil {
            throw XCTSkip("This environment can read a mode-000 file; the unreadable case can't be simulated")
        }

        let fresh = PendingBookmarkQueue(fileURL: fileURL)
        await fresh.record(entry(.create, itemId: "new", at: 200))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), original,
                       "Before the fix this file came back holding only the one new entry")
    }

    // MARK: - Read-path merge

    private func serverBookmark(_ itemId: String, _ time: Double, _ title: String) -> AudioBookmark {
        AudioBookmark(libraryItemId: itemId, title: title, time: time, createdAt: 1_000)
    }

    func testPendingCreateAppearsInMergedList() {
        let merged = AudiobookshelfAPI.merging(
            server: [serverBookmark("b1", 60, "Existing")],
            pending: [entry(.create, itemId: "b1", time: 120, title: "Offline", at: 2_000)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.title == "Offline" })
    }

    func testPendingDeleteRemovesServerBookmark() {
        let merged = AudiobookshelfAPI.merging(
            server: [serverBookmark("b1", 60, "Existing")],
            pending: [entry(.delete, itemId: "b1", time: 60, at: 2_000)])
        XCTAssertTrue(merged.isEmpty)
    }

    func testPendingEditReplacesRatherThanDuplicates() {
        let merged = AudiobookshelfAPI.merging(
            server: [serverBookmark("b1", 60, "Old note")],
            pending: [entry(.update, itemId: "b1", time: 60, title: "New note", at: 2_000)])
        XCTAssertEqual(merged.count, 1, "The edited bookmark must supersede the server row, not sit beside it")
        XCTAssertEqual(merged.first?.title, "New note")
    }

    func testMergeIsIdentityWhenNothingIsQueued() {
        let server = [serverBookmark("b1", 60, "Existing")]
        XCTAssertEqual(AudiobookshelfAPI.merging(server: server, pending: []).count, 1)
    }

    /// Operations are applied oldest-first, so the newest wins on the same bookmark.
    func testLatestPendingOperationWins() {
        let merged = AudiobookshelfAPI.merging(
            server: [],
            pending: [entry(.create, itemId: "b1", time: 60, title: "First", at: 1_000),
                      entry(.update, itemId: "b1", time: 60, title: "Second", at: 2_000)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.title, "Second")
    }
}
