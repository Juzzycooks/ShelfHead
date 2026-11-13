//
//  Batch496DownloadsQueueTests.swift
//  ShelfHeadTests
//
//  Batch 496 (REVIEW 2026-11-11 D2): pins the pure decisions behind the download queue
//  (`DownloadQueuePlan`) and its persisted record. The live queue (session tasks, app
//  state, relaunch) is not exercised here.
//

import XCTest
@testable import ShelfHead

final class Batch496DownloadsQueueTests: XCTestCase {
    private typealias Entry = DownloadQueuePlan.Entry

    private func running(_ id: String, automatic: Bool = false) -> Entry {
        Entry(id: id, isQueued: false, isPaused: false, hasStarted: true, isAutomatic: automatic)
    }

    private func waiting(_ id: String, started: Bool = false, automatic: Bool = false) -> Entry {
        Entry(id: id, isQueued: true, isPaused: false, hasStarted: started, isAutomatic: automatic)
    }

    private func paused(_ id: String, automatic: Bool = false) -> Entry {
        Entry(id: id, isQueued: false, isPaused: true, hasStarted: true, isAutomatic: automatic)
    }

    // MARK: insertionIndex

    func testAutomaticBookGoesToTheEnd() {
        let queue = [running("a"), waiting("b"), waiting("c", automatic: true)]
        XCTAssertEqual(DownloadQueuePlan.insertionIndex(automatic: true, queue: queue), 3)
    }

    func testManualBookGoesAheadOfWaitingAutomaticBooks() {
        let queue = [running("a"), waiting("b"), waiting("c", automatic: true), waiting("d", automatic: true)]
        XCTAssertEqual(DownloadQueuePlan.insertionIndex(automatic: false, queue: queue), 2)
    }

    func testManualBookDoesNotJumpARunningAutomaticBook() {
        let queue = [running("a", automatic: true), waiting("b")]
        XCTAssertEqual(DownloadQueuePlan.insertionIndex(automatic: false, queue: queue), 2)
    }

    func testManualBookGoesAheadOfAPausedAutomaticBook() {
        let queue = [running("a"), paused("b", automatic: true)]
        XCTAssertEqual(DownloadQueuePlan.insertionIndex(automatic: false, queue: queue), 1)
    }

    func testEmptyQueueInsertsAtZero() {
        XCTAssertEqual(DownloadQueuePlan.insertionIndex(automatic: false, queue: []), 0)
        XCTAssertEqual(DownloadQueuePlan.insertionIndex(automatic: true, queue: []), 0)
    }

    // MARK: movedToFront

    func testDownloadNextMovesAheadOfOtherWaitingBooksOnly() {
        let queue = [running("a"), paused("p"), waiting("b"), waiting("c"), waiting("d")]
        let moved = DownloadQueuePlan.movedToFront("d", in: queue).map(\.id)
        XCTAssertEqual(moved, ["a", "p", "d", "b", "c"])
    }

    func testDownloadNextOnTheFirstWaitingBookChangesNothing() {
        let queue = [running("a"), waiting("b"), waiting("c")]
        XCTAssertEqual(DownloadQueuePlan.movedToFront("b", in: queue), queue)
    }

    func testDownloadNextOnAnUnknownIdChangesNothing() {
        let queue = [running("a"), waiting("b")]
        XCTAssertEqual(DownloadQueuePlan.movedToFront("zzz", in: queue), queue)
    }

    func testMoveNeverPushesABookBackwards() {
        // "c" is already before the first other waiting book's slot after removal.
        let queue = [waiting("c"), running("a"), waiting("b")]
        XCTAssertEqual(DownloadQueuePlan.movedToFront("c", in: queue).map(\.id), ["c", "a", "b"])
    }

    // MARK: booksToStart

    func testForegroundLimitCountsRunningBooks() {
        let queue = [running("a"), waiting("b"), waiting("c"), waiting("d")]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: 2, isConnected: true), ["b"])
    }

    func testNothingStartsWhenTheSlotsAreFull() {
        let queue = [running("a"), running("b"), waiting("c")]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: 2, isConnected: true), [])
    }

    func testOverTheLimitAfterBackgroundAdmitsNothing() {
        let queue = [running("a"), running("b"), running("c"), waiting("d")]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: 2, isConnected: true), [])
    }

    func testPausedBooksDoNotTakeASlot() {
        let queue = [paused("a"), paused("b"), waiting("c"), waiting("d"), waiting("e")]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: 2, isConnected: true), ["c", "d"])
    }

    func testNoLimitStartsEveryWaitingBook() {
        let queue = [running("a"), waiting("b"), paused("p"), waiting("c"), waiting("d")]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: nil, isConnected: true), ["b", "c", "d"])
    }

    func testOfflineOnlyStartedBooksStart() {
        let queue = [waiting("a"), waiting("b", started: true), waiting("c")]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: 2, isConnected: false), ["b"])
    }

    func testAutomaticBooksWaitWhileThePolicySaysNo() {
        let queue = [waiting("a", automatic: true), waiting("b"), waiting("c", started: true, automatic: true)]
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: nil, isConnected: true, automaticAllowed: false),
                       ["b", "c"])
        XCTAssertEqual(DownloadQueuePlan.booksToStart(queue, limit: nil, isConnected: true, automaticAllowed: true),
                       ["a", "b", "c"])
    }

    func testMaxConcurrentBooksIsTwo() {
        XCTAssertEqual(DownloadQueuePlan.maxConcurrentBooks, 2)
    }

    // MARK: waitingPosition / queuedLabel

    func testWaitingPositionCountsOnlyWaitingBooks() {
        let queue = [running("a"), waiting("b"), paused("p"), waiting("c")]
        XCTAssertNil(DownloadQueuePlan.waitingPosition(of: "a", in: queue))
        XCTAssertNil(DownloadQueuePlan.waitingPosition(of: "p", in: queue))
        XCTAssertEqual(DownloadQueuePlan.waitingPosition(of: "b", in: queue), 1)
        XCTAssertEqual(DownloadQueuePlan.waitingPosition(of: "c", in: queue), 2)
        XCTAssertNil(DownloadQueuePlan.waitingPosition(of: "missing", in: queue))
    }

    func testQueuedLabelUsesAnOrdinal() {
        let label = DownloadQueuePlan.queuedLabel(position: 3, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(label.contains("3rd"), label)
        XCTAssertTrue(label.contains("\u{00B7}"), label)
    }

    // MARK: syncedOrder / restoredOrder

    func testSyncDropsUntrackedAndAppendsNewIds() {
        XCTAssertEqual(DownloadQueuePlan.syncedOrder(["a", "b", "c"], tracked: ["c", "a", "d"]), ["a", "c", "d"])
    }

    func testSyncRemovesDuplicates() {
        XCTAssertEqual(DownloadQueuePlan.syncedOrder(["a", "a", "b"], tracked: ["b", "a"]), ["a", "b"])
    }

    func testRestoredOrderPutsUntrackedTransfersFirst() {
        XCTAssertEqual(DownloadQueuePlan.restoredOrder(saved: ["b", "c"], untracked: ["x", "b"]), ["x", "b", "c"])
    }

    // MARK: restoreAction

    private func record(paused: Bool = false, started: Bool = false) -> DownloadQueueRecord {
        DownloadQueueRecord(itemId: "i", title: "T", sizeBytes: 10, automatic: false, paused: paused, started: started)
    }

    func testFinishedOrFailedBooksAreDropped() {
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(), isDownloaded: true, isFailed: false,
                                                       existing: nil, hasLiveTasks: false), .drop)
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(), isDownloaded: false, isFailed: true,
                                                       existing: nil, hasLiveTasks: false), .drop)
    }

    func testARepairIsDropped() {
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(), isDownloaded: false, isFailed: false,
                                                       existing: (isPaused: false, isRepair: true), hasLiveTasks: true), .drop)
    }

    func testRecordOnlyBooksAreRecreated() {
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(), isDownloaded: false, isFailed: false,
                                                       existing: nil, hasLiveTasks: false), .create(paused: false))
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(paused: true), isDownloaded: false, isFailed: false,
                                                       existing: nil, hasLiveTasks: false), .create(paused: true))
    }

    func testResumedButNotRestartedBookIsRequeued() {
        // Paused on disk (the mark stays until it continues), but the listener had resumed it.
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(paused: false, started: true),
                                                       isDownloaded: false, isFailed: false,
                                                       existing: (isPaused: true, isRepair: false), hasLiveTasks: false),
                       .keep(requeue: true))
    }

    func testPausedOrAdoptedBooksAreKeptAsTheyAre() {
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(paused: true, started: true),
                                                       isDownloaded: false, isFailed: false,
                                                       existing: (isPaused: true, isRepair: false), hasLiveTasks: false),
                       .keep(requeue: false))
        XCTAssertEqual(DownloadQueuePlan.restoreAction(record: record(started: true),
                                                       isDownloaded: false, isFailed: false,
                                                       existing: (isPaused: false, isRepair: false), hasLiveTasks: true),
                       .keep(requeue: false))
    }

    // MARK: Persistence

    func testRecordRoundTripsThroughJSON() throws {
        let records = [DownloadQueueRecord(itemId: "li_1", title: "Dune", sizeBytes: 1_234_567,
                                           automatic: true, paused: false, started: true)]
        let data = try JSONEncoder().encode(records)
        XCTAssertEqual(try JSONDecoder().decode([DownloadQueueRecord].self, from: data), records)
    }

    func testQueueKeyIsPurgedWithTheAccount() {
        let scope = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1")
        let key = DownloadManager.downloadQueueKey(scope: scope)
        XCTAssertTrue(key.hasSuffix("." + scope))
        XCTAssertTrue(DownloadManager.scopedDefaultsKeys(scope: scope).contains(key))
    }
}
