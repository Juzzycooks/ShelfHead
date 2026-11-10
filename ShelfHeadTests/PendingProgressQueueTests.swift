import XCTest
@testable import ShelfHead

/// Pins ARCH-3 (REVIEW_2026-08-12.md): the old `AudioPlayerService` pending-progress
/// queue was a `load-whole-dictionary → mutate one key → save-whole-dictionary` pattern
/// with no guard against a flush's own success deleting a *newer* position that raced in
/// while its network write was still in flight, and a scope key computed too late (at
/// `Task`-execution time rather than capture time), letting an account switch mid-flight
/// mis-attribute a queued position to the wrong account.
///
/// Each test uses its own `PendingProgressQueue` instance pointed at a scratch file (never
/// `.shared`), so these never touch the app's real queue and can run in any order/in
/// parallel with each other.
final class PendingProgressQueueTests: XCTestCase {

    private var scratchURL: URL!

    override func setUp() {
        super.setUp()
        scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingProgressQueueTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        // The damaged-file tests below leave the queue file mode 000, and one leaves a
        // quarantined `<name>.corrupt` sibling; clear both so nothing survives the run.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratchURL.path)
        try? FileManager.default.removeItem(at: PersistedStoreLoad.quarantineURL(for: scratchURL))
        try? FileManager.default.removeItem(at: scratchURL)
        scratchURL = nil
        super.tearDown()
    }

    private func makeQueue() -> PendingProgressQueue {
        PendingProgressQueue(fileURL: scratchURL)
    }

    /// The same five minutes `DownloadManager.conflictThreshold` uses in production,
    /// spelled out here so each test reads as "five minutes of listening" rather than
    /// silently tracking whatever that constant later becomes.
    private let threshold: Double = 5 * 60

    private func entry(
        scope: String = "scope-a", itemId: String = "item-1",
        currentTime: Double = 100, duration: Double = 1000, updatedAt: Double = 1_000_000,
        conflictResolved: Bool = false
    ) -> PendingProgressQueue.Entry {
        .init(scope: scope, itemId: itemId, currentTime: currentTime, duration: duration,
              updatedAt: updatedAt, conflictResolved: conflictResolved)
    }

    // MARK: - record / allEntries round trip

    func testRecordThenAllEntriesContainsIt() async {
        let queue = makeQueue()
        let e = entry()
        await queue.record(e)
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1"], e)
    }

    func testRecordOverwritesAPreviousEntryForTheSameScopeAndItem() async {
        let queue = makeQueue()
        await queue.record(entry(currentTime: 100, updatedAt: 1))
        await queue.record(entry(currentTime: 400, updatedAt: 2))
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 400)
    }

    func testSameItemIdUnderDifferentScopesDoesNotCollide() async {
        let queue = makeQueue()
        await queue.record(entry(scope: "scope-a", currentTime: 100))
        await queue.record(entry(scope: "scope-b", currentTime: 900))
        let all = await queue.allEntries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 100)
        XCTAssertEqual(all["scope-b|item-1"]?.currentTime, 900)
    }

    // MARK: - clear(ifNotNewerThan:) — the guard the old code lacked

    func testClearRemovesAnEntryNoNewerThanTheGivenTimestamp() async {
        let queue = makeQueue()
        await queue.record(entry(updatedAt: 500))
        await queue.clear(itemId: "item-1", scope: "scope-a", ifNotNewerThan: 500)
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-a|item-1"])
    }

    func testClearDoesNotDeleteAnEntryThatWasSupersededSinceTheFlushSnapshot() async {
        // This is the exact race from the review: a flush drains {itemId: t=100,
        // updatedAt: 1}, suspends on the network write, and a concurrent `record` writes
        // {t=400, updatedAt: 2} before the flush's `clear(ifNotNewerThan: 1)` runs.
        let queue = makeQueue()
        await queue.record(entry(currentTime: 100, updatedAt: 1))
        await queue.record(entry(currentTime: 400, updatedAt: 2))   // supersedes it
        await queue.clear(itemId: "item-1", scope: "scope-a", ifNotNewerThan: 1)
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 400,
                        "clear(ifNotNewerThan:) must not delete an entry newer than the timestamp it was given.")
    }

    func testClearIsANoOpForAScopeItemPairThatWasNeverQueued() async {
        let queue = makeQueue()
        await queue.clear(itemId: "missing", scope: "scope-a", ifNotNewerThan: .greatestFiniteMagnitude)
        let all = await queue.allEntries()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - drain(activeScope:serverProgress:conflictThreshold:)

    // `updatedAt` must be recent in every `drain` test: `drain` evicts anything older
    // than `maxAge` (30 days) unless the entry is held for a conflict, so a
    // small epoch-relative value (the helper's `1_000_000` default is 12 Jan 1970) is
    // dropped as stale and the test proves nothing about what it names.
    func testDrainOnlyReturnsEntriesForTheActiveScope() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(scope: "scope-a", itemId: "item-1", updatedAt: now))
        await queue.record(entry(scope: "scope-b", itemId: "item-2", updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: threshold)
        XCTAssertEqual(drained.map(\.itemId), ["item-1"])
    }

    func testDrainSkipsAndDropsAnEntryTheServerHasAlreadyMovedPast() async {
        let queue = makeQueue()
        // Was `updatedAt: 1000`, which made this pass for the wrong reason — the entry
        // was evicted as stale before the server-supersede branch was ever reached.
        let now = Date().timeIntervalSince1970
        await queue.record(entry(itemId: "item-1", updatedAt: now))
        // Server's lastUpdate is well past our queued position → drop, don't flush.
        let drained = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now + 5000, currentTime: 100)],
            conflictThreshold: threshold)
        XCTAssertTrue(drained.isEmpty)
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-a|item-1"], "A server-superseded entry must be evicted, not left to retry forever.")
    }

    func testDrainKeepsAnEntryTheServerHasNotYetCaughtUpTo() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(itemId: "item-1", updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 5000, currentTime: 100)],
            conflictThreshold: threshold)
        XCTAssertEqual(drained.map(\.itemId), ["item-1"])
    }

    func testDrainEvictsStaleEntriesRegardlessOfScope() async {
        let queue = makeQueue()
        let veryOld = Date().timeIntervalSince1970 - (31 * 24 * 3600)
        await queue.record(entry(scope: "scope-b", itemId: "stale", updatedAt: veryOld))
        // Draining as scope-a (not scope-b) must still evict the stale scope-b entry —
        // otherwise a permanently signed-out account's leftovers never get cleaned up,
        // since they can never again match an `activeScope`.
        _ = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: threshold)
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-b|stale"])
    }

    func testDrainDoesNotEvictAFreshEntryInAnInactiveScope() async {
        let queue = makeQueue()
        await queue.record(entry(scope: "scope-b", itemId: "item-2", updatedAt: Date().timeIntervalSince1970))
        _ = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: threshold)
        let all = await queue.allEntries()
        XCTAssertNotNil(all["scope-b|item-2"], "A fresh entry for an inactive scope must survive a drain — it's not stale, just not due yet.")
    }

    // MARK: - Persistence across instances (the actual bug: UserDefaults → file)

    func testEntriesPersistAcrossSeparateQueueInstancesPointedAtTheSameFile() async {
        let first = PendingProgressQueue(fileURL: scratchURL)
        await first.record(entry())
        let second = PendingProgressQueue(fileURL: scratchURL)
        let all = await second.allEntries()
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 100)
    }

    func testClearPersistsAcrossSeparateQueueInstances() async {
        let first = PendingProgressQueue(fileURL: scratchURL)
        await first.record(entry(updatedAt: 42))
        await first.clear(itemId: "item-1", scope: "scope-a", ifNotNewerThan: 42)
        let second = PendingProgressQueue(fileURL: scratchURL)
        let all = await second.allEntries()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - disposition(...) — the push / hold / drop decision (item 1)
    //
    // The bug this half of the file pins: `flushPendingProgress` was guarded by the
    // server's `lastUpdate` **timestamps** alone, which answers "has the server written
    // since we captured this?" but never "would pushing this drag the book backwards?"
    // A position captured offline could therefore be pushed while it sat well behind the
    // server's own position — overwriting it before the "Progress Doesn't Match" prompt
    // (`DownloadManager.reconcile` → `ProgressReconciler.reconcile`) had been answered,
    // and in the common case before it was ever raised. The entry is now HELD: neither
    // pushed nor dropped.

    private func disposition(
        local: Double, localUpdatedAt: Double = 1_000,
        resolved: Bool = false,
        serverTime: Double?, serverLastUpdate: Double? = nil
    ) -> PendingProgressQueue.EntryDisposition {
        PendingProgressQueue.disposition(
            entryCurrentTime: local, entryUpdatedAt: localUpdatedAt,
            entryConflictResolved: resolved,
            server: .init(lastUpdate: serverLastUpdate, currentTime: serverTime),
            conflictThreshold: threshold)
    }

    func testNoServerEntryAtAllPushes() {
        // Nothing to conflict with — a book the server has never seen progress for.
        XCTAssertEqual(
            PendingProgressQueue.disposition(
                entryCurrentTime: 100, entryUpdatedAt: 1_000, server: nil,
                conflictThreshold: threshold),
            .push)
    }

    func testServerEntryWithNoCurrentTimePushes() {
        // `MediaProgress.currentTime` is optional. A record that exists but says nothing
        // about *where* the listener is gives no gap to measure, so there's nothing to
        // hold for.
        XCTAssertEqual(disposition(local: 100, serverTime: nil), .push)
    }

    func testLocalAheadOfServerPushes() {
        // Ordinary offline listening: this device listened on past where the server was.
        XCTAssertEqual(disposition(local: 9_000, serverTime: 100), .push)
    }

    func testLocalEqualToServerPushes() {
        XCTAssertEqual(disposition(local: 500, serverTime: 500), .push)
    }

    func testLocalExactlyAtTheThresholdBehindStillPushes() {
        // Boundary: the hold test is `>` the threshold, matching
        // `ProgressReconciler.reconcile`'s own `abs(local - server) > conflictThreshold`.
        XCTAssertEqual(disposition(local: 100, serverTime: 100 + threshold), .push)
    }

    func testOneSecondPastTheThresholdHolds() {
        XCTAssertEqual(disposition(local: 100, serverTime: 100 + threshold + 1), .hold)
    }

    func testLocalFarBehindServerHolds() {
        // The flight case: offline listening from a stale base while another device (or
        // the web player) advanced the same book an hour further on.
        XCTAssertEqual(disposition(local: 600, serverTime: 4_200), .hold)
    }

    func testServerWrittenLaterStillDropsEvenWhenAlsoFarAhead() {
        // Staleness is checked first and is unchanged by this fix: a server that wrote
        // AFTER we captured has genuinely moved on, and its copy wins outright rather
        // than being held for a prompt no one needs.
        XCTAssertEqual(
            disposition(local: 100, localUpdatedAt: 1_000, serverTime: 9_000, serverLastUpdate: 5_000),
            .drop)
    }

    func testServerWrittenWithinTheOneSecondSlackIsNotTreatedAsNewer() {
        // The 1s slack absorbing clock/round-trip jitter, preserved from the original
        // inline rule — the entry falls through to the position comparison instead.
        XCTAssertEqual(
            disposition(local: 100, localUpdatedAt: 1_000, serverTime: 100, serverLastUpdate: 1_001),
            .push)
    }

    // MARK: - drain(...) applies the hold

    private func heldEntry(_ all: [String: PendingProgressQueue.Entry]) -> Bool? {
        all["scope-a|item-1"]?.heldForConflict
    }

    func testDrainHoldsBackAnEntryFarBehindTheServerWithoutDroppingIt() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(currentTime: 600, updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 4_200)],
            conflictThreshold: threshold)
        XCTAssertTrue(drained.isEmpty, "A position this far behind the server must not be pushed.")
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 600,
                       "…and must not be dropped either — the user hasn't answered the prompt yet.")
        XCTAssertEqual(heldEntry(all), true)
    }

    func testAHeldEntryIsNotCountedAsWaitingToSync() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(currentTime: 600, updatedAt: now))
        _ = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 4_200)],
            conflictThreshold: threshold)
        let pending = await queue.count(forScope: "scope-a")
        let held = await queue.heldForConflictCount(forScope: "scope-a")
        XCTAssertEqual(pending, 0, "It isn't waiting on the network, so the banner's count must not include it.")
        XCTAssertEqual(held, 1)
    }

    func testAHeldEntryIsNotAgedOutAsStale() async {
        let queue = makeQueue()
        let veryOld = Date().timeIntervalSince1970 - (31 * 24 * 3600)
        await queue.record(entry(currentTime: 600, updatedAt: veryOld))
        // Server hasn't written since (nil `lastUpdate`), it's simply much further along.
        _ = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: nil, currentTime: 4_200)],
            conflictThreshold: threshold)
        let all = await queue.allEntries()
        XCTAssertNotNil(all["scope-a|item-1"],
                        "The 30-day sweep is for entries that can never match again; this one is waiting on an answer.")
        XCTAssertEqual(heldEntry(all), true)
    }

    func testAStaleEntryInTheActiveScopeIsStillEvictedWhenItIsNotHeld() async {
        // The reordering that introduced the hold must not cost the active scope its
        // ordinary age sweep.
        let queue = makeQueue()
        let veryOld = Date().timeIntervalSince1970 - (31 * 24 * 3600)
        await queue.record(entry(currentTime: 600, updatedAt: veryOld))
        let drained = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: threshold)
        XCTAssertTrue(drained.isEmpty)
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-a|item-1"])
    }

    func testTheHoldLiftsOnceTheServerNoLongerLeads() async {
        // What happens after "Keep This Device" is chosen: the server's position is
        // pushed up to this device's, so the next drain sees no gap and the entry
        // becomes an ordinary pending push again — no explicit release call needed from
        // `DownloadManager.resolveProgressConflict`, which has no queue call on its
        // success path at all.
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(currentTime: 600, updatedAt: now))
        _ = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 4_200)],
            conflictThreshold: threshold)
        let drained = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 600)],
            conflictThreshold: threshold)
        XCTAssertEqual(drained.map(\.itemId), ["item-1"])
        XCTAssertEqual(drained.first?.heldForConflict, false)
        let all = await queue.allEntries()
        XCTAssertEqual(heldEntry(all), false)
        let pending = await queue.count(forScope: "scope-a")
        XCTAssertEqual(pending, 1)
    }

    func testRecordingAFreshPositionClearsTheHold() async {
        // The user carried on listening past the disputed point — `record` replaces the
        // whole entry, so the hold goes with it.
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(currentTime: 600, updatedAt: now))
        _ = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 4_200)],
            conflictThreshold: threshold)
        await queue.record(entry(currentTime: 5_000, updatedAt: now + 60))
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 5_000)
        XCTAssertEqual(heldEntry(all), false)
    }

    func testAnEntryHeldForAnInactiveScopeIsStillAgedOut() async {
        // The safety valve on the age-eviction exemption: the server map only describes
        // the active account, so a held entry belonging to an account that's been
        // switched away from is swept on age like any other orphan.
        let queue = makeQueue()
        let veryOld = Date().timeIntervalSince1970 - (31 * 24 * 3600)
        await queue.record(entry(scope: "scope-b", currentTime: 600, updatedAt: veryOld))
        _ = await queue.drain(
            activeScope: "scope-b",
            serverProgress: ["item-1": .init(lastUpdate: nil, currentTime: 4_200)],
            conflictThreshold: threshold)
        let afterHold = await queue.allEntries()
        XCTAssertNotNil(afterHold["scope-b|item-1"])
        _ = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: threshold)
        let afterSwitch = await queue.allEntries()
        XCTAssertNil(afterSwitch["scope-b|item-1"])
    }

    func testTheHoldFlagSurvivesAReloadFromDisk() async {
        let first = PendingProgressQueue(fileURL: scratchURL)
        let now = Date().timeIntervalSince1970
        await first.record(entry(currentTime: 600, updatedAt: now))
        _ = await first.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 4_200)],
            conflictThreshold: threshold)
        let second = PendingProgressQueue(fileURL: scratchURL)
        let reloaded = await second.allEntries()
        XCTAssertEqual(reloaded["scope-a|item-1"]?.heldForConflict, true)
        let pending = await second.count(forScope: "scope-a")
        XCTAssertEqual(pending, 0)
    }

    func testAQueueFileWrittenBeforeTheHoldFieldExistedStillDecodes() throws {
        // `heldForConflict` is decoded with `decodeIfPresent`. A hard `decode` would fail
        // the whole `[String: Entry]` dictionary and silently throw away every queued
        // offline position on the first launch after the update.
        let legacy = #"{"scope-a|item-1":{"scope":"scope-a","itemId":"item-1","currentTime":123.5,"duration":1000,"updatedAt":42}}"#
        try XCTUnwrap(legacy.data(using: .utf8)).write(to: scratchURL)
        let decoded = try JSONDecoder().decode(
            [String: PendingProgressQueue.Entry].self, from: Data(contentsOf: scratchURL))
        XCTAssertEqual(decoded["scope-a|item-1"]?.currentTime, 123.5)
        XCTAssertEqual(decoded["scope-a|item-1"]?.heldForConflict, false)
        XCTAssertEqual(decoded["scope-a|item-1"]?.conflictResolved, false)
    }

    // MARK: - conflictResolved — an answered divergence is not re-litigated
    //
    // Residual risk (a) from the first pass on item 1: `DownloadManager.resolveProgress
    // Conflict(_:keepLocal: true)` queues the kept position when its push fails, and that
    // entry looked exactly like an ordinary offline capture — so the hold-back would hold
    // it, vetoing the answer the user had just given, and `reconcile` would re-raise the
    // same prompt on the next library refresh. The entry now carries the decision with it.

    func testAnAnsweredDivergenceIsPushedNoMatterHowFarBehindItIs() {
        // "Keep This Device" chosen while the server sat an hour further on, and the push
        // failed. Without the flag this is `.hold`.
        XCTAssertEqual(disposition(local: 600, resolved: false, serverTime: 4_200), .hold)
        XCTAssertEqual(disposition(local: 600, resolved: true, serverTime: 4_200), .push)
    }

    func testAServerWriteAfterTheDecisionStillWins() {
        // The half of the rule that does NOT bend: the user decided at `localUpdatedAt`
        // having been shown the server position as it stood then. Someone listening
        // elsewhere *afterwards* is new information the decision never covered.
        XCTAssertEqual(
            disposition(local: 600, localUpdatedAt: 1_000, resolved: true,
                        serverTime: 4_200, serverLastUpdate: 5_000),
            .drop)
    }

    func testAServerTimestampOlderThanTheDecisionDoesNotVetoIt() {
        // The mirror image: the server's write is what the user was deciding *about*.
        XCTAssertEqual(
            disposition(local: 600, localUpdatedAt: 1_000, resolved: true,
                        serverTime: 4_200, serverLastUpdate: 900),
            .push)
    }

    func testDrainReturnsAnAnsweredEntryAndNeverMarksItHeld() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(currentTime: 600, updatedAt: now, conflictResolved: true))
        let drained = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 4_200)],
            conflictThreshold: threshold)
        XCTAssertEqual(drained.map(\.itemId), ["item-1"])
        let all = await queue.allEntries()
        XCTAssertEqual(heldEntry(all), false)
        let pending = await queue.count(forScope: "scope-a")
        XCTAssertEqual(pending, 1, "It is genuinely waiting on the network, so it belongs in the count.")
    }

    func testResolvedConflictItemIdsReportsAnsweredEntriesForTheActiveScopeOnly() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(itemId: "answered", updatedAt: now, conflictResolved: true))
        await queue.record(entry(itemId: "undecided", updatedAt: now))
        await queue.record(entry(scope: "scope-b", itemId: "other-account", updatedAt: now, conflictResolved: true))
        let ids = await queue.resolvedConflictItemIds(forScope: "scope-a")
        XCTAssertEqual(ids, ["answered"])
    }

    func testResolvedConflictItemIdsIsEmptyOnceTheQueuedPushHasLanded() async {
        // What lets `reconcile` start prompting for this book again: the flush's `clear`
        // after a successful push removes the entry, and the suppression goes with it.
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(updatedAt: now, conflictResolved: true))
        await queue.clear(itemId: "item-1", scope: "scope-a", ifNotNewerThan: now)
        let ids = await queue.resolvedConflictItemIds(forScope: "scope-a")
        XCTAssertTrue(ids.isEmpty)
    }

    func testResolvedConflictItemIdsExcludesAnEbookEntryEvenIfItSomehowCarriedTheFlag() async {
        // `Entry.ebook(...)` never sets `conflictResolved: true` — there's no "Progress
        // Doesn't Match" prompt for a reading position — but `resolvedConflictItemIds`
        // filters `!isEbook` explicitly rather than relying on that as an accident of the
        // call graph. Construct one directly (bypassing the factory) to prove the guard.
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        let ebookWithFlagSet = PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "ebook-item", currentTime: 0, duration: 0, updatedAt: now,
            conflictResolved: true, ebookLocation: "1", ebookProgress: 0.1)
        await queue.record(ebookWithFlagSet)
        await queue.record(entry(itemId: "audio-item", updatedAt: now, conflictResolved: true))
        let ids = await queue.resolvedConflictItemIds(forScope: "scope-a")
        XCTAssertEqual(ids, ["audio-item"], "An ebook entry must never be reported, even with conflictResolved set.")
    }

    func testAFreshPlaybackCaptureClearsTheAnsweredFlag() async {
        // The user carried on listening: `record` replaces the whole entry, so the
        // exemption can't outlive the decision it belonged to.
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(entry(currentTime: 600, updatedAt: now, conflictResolved: true))
        await queue.record(entry(currentTime: 900, updatedAt: now + 30))
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1"]?.conflictResolved, false)
        let ids = await queue.resolvedConflictItemIds(forScope: "scope-a")
        XCTAssertTrue(ids.isEmpty)
    }

    func testTheAnsweredFlagSurvivesAReloadFromDisk() async {
        let first = PendingProgressQueue(fileURL: scratchURL)
        await first.record(entry(updatedAt: Date().timeIntervalSince1970, conflictResolved: true))
        let second = PendingProgressQueue(fileURL: scratchURL)
        let reloaded = await second.allEntries()
        XCTAssertEqual(reloaded["scope-a|item-1"]?.conflictResolved, true)
    }

    // MARK: - Damaged queue file

    /// A corrupt queue file used to read as "empty" and then be overwritten by the next
    /// `persist()`, destroying every unsynced position. Now the bytes are moved aside to
    /// `<name>.corrupt` first and the queue carries on from empty, so listening still
    /// queues normally.
    func testCorruptQueueFileIsQuarantinedAndTheQueueStillWorks() async throws {
        let garbage = Data("{\"scope-a|item-1\": {\"currentTime\":".utf8)
        try garbage.write(to: scratchURL)

        let queue = makeQueue()
        let loaded = await queue.allEntries()
        XCTAssertTrue(loaded.isEmpty, "A corrupt file must load as empty rather than fail playback")
        XCTAssertEqual(try Data(contentsOf: PersistedStoreLoad.quarantineURL(for: scratchURL)), garbage,
                       "The unreadable bytes must stay recoverable, not be silently destroyed")

        await queue.record(entry(updatedAt: Date().timeIntervalSince1970))
        let reopened = PendingProgressQueue(fileURL: scratchURL)
        let reloaded = await reopened.allEntries()
        XCTAssertEqual(reloaded.count, 1, "Once the corrupt file is quarantined, persisting is safe again")
    }

    /// The case the fix exists for: the file is there and cannot be read (on device, the
    /// realistic cause is protected data being unavailable before first unlock, with
    /// playback already running). Recording must not cause `persist()` to replace the file
    /// with a queue holding only what this process happens to have captured since launch.
    func testUnreadableQueueFileIsNotOverwritten() async throws {
        let original = try JSONEncoder().encode(
            ["scope-a|already-queued": entry(itemId: "already-queued", updatedAt: 1_000_000)])
        try original.write(to: scratchURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scratchURL.path)
        if (try? Data(contentsOf: scratchURL)) != nil {
            throw XCTSkip("This environment can read a mode-000 file; the unreadable case can't be simulated")
        }

        let queue = makeQueue()
        await queue.record(entry(itemId: "new", updatedAt: Date().timeIntervalSince1970))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratchURL.path)
        XCTAssertEqual(try Data(contentsOf: scratchURL), original,
                       "Before the fix this file came back holding only the one new entry")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PersistedStoreLoad.quarantineURL(for: scratchURL).path),
            "Bytes we could not read must not be moved aside either")
    }
}
