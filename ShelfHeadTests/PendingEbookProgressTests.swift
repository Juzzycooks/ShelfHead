import XCTest
@testable import ShelfHead

/// Follow-up to P-15 (`REVIEW_2026-09-14_DESIGN.md`): `EbookReaderView`'s PDF page sync
/// (`AudiobookshelfAPI.updateEbookProgress`) used to be fire-and-forget with no retry — a
/// failed write while offline was only logged, and the next reader open just resumed at
/// whatever the server last had. `PendingProgressQueue.Entry` gained optional
/// `ebookLocation`/`ebookProgress` fields (and the computed `isEbook` discriminator) so an
/// ebook reading position gets the same durable, drained-on-reconnect path an audio
/// position already has.
///
/// Same fixture pattern as `PendingProgressQueueTests`: each test gets its own queue
/// instance pointed at a scratch file, never `.shared`.
final class PendingEbookProgressTests: XCTestCase {

    private var scratchURL: URL!

    override func setUp() {
        super.setUp()
        scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingEbookProgressTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: PersistedStoreLoad.quarantineURL(for: scratchURL))
        try? FileManager.default.removeItem(at: scratchURL)
        scratchURL = nil
        super.tearDown()
    }

    private func makeQueue() -> PendingProgressQueue {
        PendingProgressQueue(fileURL: scratchURL)
    }

    // MARK: - Legacy decode

    /// Pins the same guarantee `heldForConflict`/`conflictResolved` established when they
    /// were added: a queue file written before `ebookLocation`/`ebookProgress` existed —
    /// with neither key present at all — must still decode the whole dictionary, as an
    /// ordinary (non-ebook) audio entry.
    func testAQueueFileWrittenBeforeTheEbookFieldsExistedStillDecodes() throws {
        let legacy = #"{"scope-a|item-1":{"scope":"scope-a","itemId":"item-1","currentTime":123.5,"duration":1000,"updatedAt":42,"heldForConflict":false,"conflictResolved":false}}"#
        try XCTUnwrap(legacy.data(using: .utf8)).write(to: scratchURL)
        let decoded = try JSONDecoder().decode(
            [String: PendingProgressQueue.Entry].self, from: Data(contentsOf: scratchURL))
        let entry = try XCTUnwrap(decoded["scope-a|item-1"])
        XCTAssertEqual(entry.currentTime, 123.5)
        XCTAssertNil(entry.ebookLocation)
        XCTAssertNil(entry.ebookProgress)
        XCTAssertFalse(entry.isEbook)
    }

    /// Same as above, but with no `heldForConflict`/`conflictResolved` keys either — the
    /// oldest possible on-disk shape, before *any* of these follow-up fields existed.
    func testAFullyLegacyQueueFileStillDecodesAsNonEbook() throws {
        let legacy = #"{"scope-a|item-1":{"scope":"scope-a","itemId":"item-1","currentTime":123.5,"duration":1000,"updatedAt":42}}"#
        try XCTUnwrap(legacy.data(using: .utf8)).write(to: scratchURL)
        let decoded = try JSONDecoder().decode(
            [String: PendingProgressQueue.Entry].self, from: Data(contentsOf: scratchURL))
        let entry = try XCTUnwrap(decoded["scope-a|item-1"])
        XCTAssertFalse(entry.isEbook)
        XCTAssertFalse(entry.heldForConflict)
        XCTAssertFalse(entry.conflictResolved)
    }

    // MARK: - Ebook entry round-trip

    func testEbookEntryRoundTripsThroughRecordAndAllEntries() async {
        let queue = makeQueue()
        let entry = PendingProgressQueue.Entry.ebook(
            scope: "scope-a", itemId: "item-1", location: "42", progress: 0.5,
            updatedAt: Date().timeIntervalSince1970)
        await queue.record(entry)
        let all = await queue.allEntries()
        // Discriminated key (this pass): an ebook entry is filed under "scope|itemId|ebook",
        // not the plain audio key, so it never shares a slot with an audio entry for the
        // same item.
        let stored = all["scope-a|item-1|ebook"]
        XCTAssertEqual(stored?.ebookLocation, "42")
        XCTAssertEqual(stored?.ebookProgress, 0.5)
        XCTAssertTrue(stored?.isEbook ?? false)
        // Ebook entries carry no listening position — `Entry.ebook(...)` leaves both at 0.
        XCTAssertEqual(stored?.currentTime, 0)
        XCTAssertEqual(stored?.duration, 0)
    }

    func testEbookEntryPersistsAcrossSeparateQueueInstances() async {
        let first = PendingProgressQueue(fileURL: scratchURL)
        await first.record(.ebook(
            scope: "scope-a", itemId: "item-1", location: "7", progress: 0.25,
            updatedAt: Date().timeIntervalSince1970))
        let second = PendingProgressQueue(fileURL: scratchURL)
        let all = await second.allEntries()
        XCTAssertEqual(all["scope-a|item-1|ebook"]?.ebookLocation, "7")
        XCTAssertTrue(all["scope-a|item-1|ebook"]?.isEbook ?? false)
    }

    // MARK: - Discriminated key: audio and ebook coexist for the same scope/item

    /// The bug this whole pass exists to close: before the key discriminated on
    /// `isEbook`, an audio position and an ebook page for the same item/scope competed
    /// for one slot and whichever `record(_:)` landed last silently won.
    func testAudioAndEbookEntriesForTheSameItemBothSurviveRecord() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 250, duration: 1000, updatedAt: now))
        await queue.record(.ebook(
            scope: "scope-a", itemId: "item-1", location: "9", progress: 0.3, updatedAt: now))
        let all = await queue.allEntries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["scope-a|item-1"]?.currentTime, 250)
        XCTAssertEqual(all["scope-a|item-1|ebook"]?.ebookLocation, "9")
    }

    /// `clear(isEbook:)` must only ever remove the one kind it's told to — a successful
    /// audio push clearing its entry must not take an unsent ebook entry down with it,
    /// and vice versa.
    func testClearWithIsEbookFalseLeavesAnEbookEntryUntouched() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 250, duration: 1000, updatedAt: now))
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "9", progress: 0.3, updatedAt: now))
        await queue.clear(itemId: "item-1", scope: "scope-a", ifNotNewerThan: now)
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-a|item-1"], "The audio entry should have been cleared.")
        XCTAssertNotNil(all["scope-a|item-1|ebook"], "The ebook entry must survive an audio-only clear.")
    }

    func testClearWithIsEbookTrueLeavesAnAudioEntryUntouched() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 250, duration: 1000, updatedAt: now))
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "9", progress: 0.3, updatedAt: now))
        await queue.clear(itemId: "item-1", scope: "scope-a", isEbook: true, ifNotNewerThan: now)
        let all = await queue.allEntries()
        XCTAssertNotNil(all["scope-a|item-1"], "The audio entry must survive an ebook-only clear.")
        XCTAssertNil(all["scope-a|item-1|ebook"], "The ebook entry should have been cleared.")
    }

    func testDrainReturnsBothAnAudioAndAnEbookEntryForTheSameItem() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 250, duration: 1000, updatedAt: now))
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "9", progress: 0.3, updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: 5 * 60)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(Set(drained.map(\.itemId)), ["item-1"])
        XCTAssertEqual(drained.filter(\.isEbook).count, 1)
        XCTAssertEqual(drained.filter { !$0.isEbook }.count, 1)
    }

    // MARK: - rekeyed(_:) — legacy on-disk migration

    /// A build before this pass had only the audio key, so an ebook entry it wrote sits
    /// on disk at `"scope|itemId"`. `rekeyed(_:)` must move it to its canonical
    /// `"scope|itemId|ebook"` key.
    func testRekeyedMovesALegacyEbookEntryOntoItsEbookKey() {
        let legacyEbook = PendingProgressQueue.Entry.ebook(
            scope: "scope-a", itemId: "item-1", location: "9", progress: 0.3, updatedAt: 100)
        let decoded = ["scope-a|item-1": legacyEbook]
        let result = PendingProgressQueue.rekeyed(decoded)
        XCTAssertNil(result["scope-a|item-1"])
        XCTAssertEqual(result["scope-a|item-1|ebook"]?.ebookLocation, "9")
    }

    /// An audio entry's canonical key is the key it's already at — `rekeyed(_:)` must be
    /// a no-op for it.
    func testRekeyedLeavesAnAudioEntryAtItsExistingKey() {
        let audio = PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 250, duration: 1000, updatedAt: 100)
        let decoded = ["scope-a|item-1": audio]
        let result = PendingProgressQueue.rekeyed(decoded)
        XCTAssertEqual(result, decoded)
    }

    /// Both a legacy ebook entry (at the audio key) and a genuine audio entry (already at
    /// the audio key it belongs at) can be decoded from the same file — they must not
    /// collide with each other once re-keyed.
    func testRekeyedSeparatesALegacyEbookEntryFromAGenuineAudioEntryAtTheSameOriginalKey() {
        let audio = PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 250, duration: 1000, updatedAt: 50)
        let legacyEbook = PendingProgressQueue.Entry.ebook(
            scope: "scope-b", itemId: "item-2", location: "9", progress: 0.3, updatedAt: 100)
        let decoded = ["scope-a|item-1": audio, "scope-b|item-2": legacyEbook]
        let result = PendingProgressQueue.rekeyed(decoded)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["scope-a|item-1"]?.currentTime, 250)
        XCTAssertEqual(result["scope-b|item-2|ebook"]?.ebookLocation, "9")
    }

    /// On a genuine collision at the same canonical key, the newer `updatedAt` wins — the
    /// same tie-break `record(_:)` applies.
    func testRekeyedKeepsTheNewerEntryOnACollisionAtTheSameCanonicalKey() {
        let older = PendingProgressQueue.Entry.ebook(
            scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: 100)
        let newer = PendingProgressQueue.Entry.ebook(
            scope: "scope-a", itemId: "item-1", location: "2", progress: 0.2, updatedAt: 200)
        // Both decode to the same canonical key ("scope-a|item-1|ebook"); simulate that by
        // constructing the decoded dictionary directly with distinct (but colliding-after-
        // rekey) source keys the way two hand-merged files might.
        let decoded = ["scope-a|item-1": older, "some-other-legacy-key": newer]
        let result = PendingProgressQueue.rekeyed(decoded)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["scope-a|item-1|ebook"]?.ebookLocation, "2")
    }

    /// End-to-end through the actor: a legacy on-disk file with an ebook entry sitting at
    /// the old (audio) key loads, migrates, and both an audio and ebook entry for the same
    /// item are then independently addressable — `clear`, `drain`, etc. all see two
    /// entries, not one clobbering the other.
    func testALegacyOnDiskFileWithAnEbookEntryAtTheAudioKeyLoadsAndBothKindsBecomeAddressable() async throws {
        // Legacy shape: written by a build before the key discriminated on `isEbook`, so
        // the ebook entry sits at plain "scope|itemId" with the ebook fields populated.
        let legacyJSON = #"""
        {
            "scope-a|item-1": {
                "scope": "scope-a", "itemId": "item-1", "currentTime": 0, "duration": 0,
                "updatedAt": 100, "heldForConflict": false, "conflictResolved": false,
                "ebookLocation": "9", "ebookProgress": 0.3
            }
        }
        """#
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: scratchURL)

        let queue = makeQueue()
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-a|item-1"], "The legacy audio-shaped key must not still hold the ebook entry.")
        let migratedEbook = try XCTUnwrap(all["scope-a|item-1|ebook"])
        XCTAssertEqual(migratedEbook.ebookLocation, "9")
        XCTAssertTrue(migratedEbook.isEbook)

        // Now record a genuine audio entry for the same item/scope — it must land
        // independently, not collide with the migrated ebook entry.
        await queue.record(PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 400, duration: 1000,
            updatedAt: Date().timeIntervalSince1970))
        let afterAudioRecord = await queue.allEntries()
        XCTAssertEqual(afterAudioRecord.count, 2)
        XCTAssertEqual(afterAudioRecord["scope-a|item-1"]?.currentTime, 400)
        XCTAssertEqual(afterAudioRecord["scope-a|item-1|ebook"]?.ebookLocation, "9")

        // Both are independently clearable.
        await queue.clear(itemId: "item-1", scope: "scope-a", isEbook: true, ifNotNewerThan: .greatestFiniteMagnitude)
        let afterEbookClear = await queue.allEntries()
        XCTAssertNil(afterEbookClear["scope-a|item-1|ebook"])
        XCTAssertNotNil(afterEbookClear["scope-a|item-1"], "Clearing the ebook entry must not touch the audio one.")
    }

    // MARK: - Dedupe (newest wins)

    /// Ordinary audio entries can fall back to "did `currentTime` advance?" when clocks
    /// disagree (P3-8), but an ebook entry's `currentTime` is always 0 — that fallback
    /// would let an older write always tie-break as newer (`0 >= 0`). Ebook-to-ebook dedupe
    /// must fall back to `updatedAt` alone.
    func testNewerEbookEntryReplacesAnOlderOneForTheSameItem() async {
        let queue = makeQueue()
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: 1))
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "9", progress: 0.9, updatedAt: 2))
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1|ebook"]?.ebookLocation, "9")
    }

    func testOlderEbookEntryDoesNotReplaceANewerOne() async {
        let queue = makeQueue()
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "9", progress: 0.9, updatedAt: 2))
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: 1))
        let all = await queue.allEntries()
        XCTAssertEqual(all["scope-a|item-1|ebook"]?.ebookLocation, "9",
                       "An older write must not win just because its (irrelevant) currentTime of 0 ties.")
    }

    func testDifferentItemsDoNotCollide() async {
        let queue = makeQueue()
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: 1))
        await queue.record(.ebook(scope: "scope-a", itemId: "item-2", location: "2", progress: 0.2, updatedAt: 1))
        let all = await queue.allEntries()
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - kind discriminator

    func testIsEbookIsFalseForAnOrdinaryAudioEntry() {
        let entry = PendingProgressQueue.Entry(
            scope: "scope-a", itemId: "item-1", currentTime: 100, duration: 1000, updatedAt: 1)
        XCTAssertFalse(entry.isEbook)
        XCTAssertNil(entry.ebookLocation)
        XCTAssertNil(entry.ebookProgress)
    }

    func testIsEbookIsTrueWhenEbookLocationIsSet() {
        let entry = PendingProgressQueue.Entry.ebook(
            scope: "scope-a", itemId: "item-1", location: "3", progress: 0.3, updatedAt: 1)
        XCTAssertTrue(entry.isEbook)
    }

    // MARK: - drain(...) bypasses the audio conflict-hold logic for ebook entries

    /// The core of the fix: an ebook entry has no `currentTime` to measure a gap against,
    /// so it must never be `.hold`-able even when the (irrelevant, always-0) "position"
    /// sits far behind a server position that has nothing to do with reading progress.
    func testDrainNeverHoldsAnEbookEntryRegardlessOfServerPosition() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "5", progress: 0.5, updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a",
            // A server position that would hold an *audio* entry this far ahead of a 0
            // currentTime (well past any conflictThreshold) — must not affect an ebook one.
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 999_999)],
            conflictThreshold: 5 * 60)
        XCTAssertEqual(drained.map(\.itemId), ["item-1"])
        let all = await queue.allEntries()
        XCTAssertFalse(all["scope-a|item-1|ebook"]?.heldForConflict ?? true,
                        "An ebook entry must never be marked heldForConflict.")
    }

    func testDrainReturnsAFreshEbookEntryWithItsLocationAndProgressIntact() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "12", progress: 0.4, updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: 5 * 60)
        XCTAssertEqual(drained.first?.ebookLocation, "12")
        XCTAssertEqual(drained.first?.ebookProgress, 0.4)
    }

    func testDrainStillAgeEvictsAStaleEbookEntry() async {
        let queue = makeQueue()
        let veryOld = Date().timeIntervalSince1970 - (31 * 24 * 3600)
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: veryOld))
        let drained = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: 5 * 60)
        XCTAssertTrue(drained.isEmpty)
        let all = await queue.allEntries()
        XCTAssertNil(all["scope-a|item-1|ebook"])
    }

    func testDrainOnlyReturnsEbookEntriesForTheActiveScope() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: now))
        await queue.record(.ebook(scope: "scope-b", itemId: "item-2", location: "2", progress: 0.2, updatedAt: now))
        let drained = await queue.drain(
            activeScope: "scope-a", serverProgress: [:], conflictThreshold: 5 * 60)
        XCTAssertEqual(drained.map(\.itemId), ["item-1"])
    }

    func testAnEbookEntryDoesNotCountTowardHeldForConflictCount() async {
        let queue = makeQueue()
        let now = Date().timeIntervalSince1970
        await queue.record(.ebook(scope: "scope-a", itemId: "item-1", location: "1", progress: 0.1, updatedAt: now))
        _ = await queue.drain(
            activeScope: "scope-a",
            serverProgress: ["item-1": .init(lastUpdate: now - 10, currentTime: 999_999)],
            conflictThreshold: 5 * 60)
        let held = await queue.heldForConflictCount(forScope: "scope-a")
        XCTAssertEqual(held, 0)
    }
}
