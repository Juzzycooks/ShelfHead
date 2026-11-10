import XCTest
@testable import ShelfHead

/// Library browse plan §3.2, §6.6 and §11 (2026-10-05): pins the pure pieces behind bulk
/// Mark Finished — the post-write diff, the prior-progress snapshot, the finish and Undo
/// batch payloads — and the Select All eligibility rule.
@MainActor
final class LibraryBulkFinishTests: XCTestCase {

    private func progress(
        _ id: String, currentTime: Double?, fraction: Double?, finished: Bool?
    ) -> MediaProgress {
        MediaProgress(
            id: "p-\(id)", libraryItemId: id, episodeId: nil, duration: 3600, progress: fraction,
            currentTime: currentTime, isFinished: finished, lastUpdate: 0,
            startedAt: nil, finishedAt: nil
        )
    }

    // MARK: - failedIds

    func testFailedIdsIsEmptyWhenEveryRequestedBookIsNowFinished() {
        XCTAssertEqual(LibraryViewModel.failedIds(requested: ["a", "b"], after: ["a": true, "b": true]), [])
    }

    func testFailedIdsReportsUnfinishedAndMissingInRequestOrder() {
        let failed = LibraryViewModel.failedIds(
            requested: ["c", "a", "b", "d"],
            after: ["a": true, "b": false, "c": false]
        )
        XCTAssertEqual(failed, ["c", "b", "d"], "a missing key (no progress record) counts as not finished")
    }

    func testFailedIdsListsADuplicatedRequestOnce() {
        XCTAssertEqual(LibraryViewModel.failedIds(requested: ["a", "a", "b"], after: ["b": true]), ["a"])
    }

    func testFailedIdsWithNothingRequested() {
        XCTAssertEqual(LibraryViewModel.failedIds(requested: [], after: ["a": false]), [])
    }

    func testFailedIdsIgnoresExtraKeysInTheRefreshedMap() {
        XCTAssertEqual(LibraryViewModel.failedIds(requested: ["a"], after: ["a": true, "z": false]), [])
    }

    // MARK: - Snapshot

    func testSnapshotOfAnInProgressBookKeepsItsPosition() {
        let snap = LibraryViewModel.progressSnapshot(
            itemId: "a", title: "Alpha",
            prior: progress("a", currentTime: 900, fraction: 0.25, finished: false), duration: 3600
        )
        XCTAssertEqual(snap, LibraryProgressSnapshot(
            itemId: "a", title: "Alpha", currentTime: 900, progress: 0.25, isFinished: false, duration: 3600
        ))
        XCTAssertTrue(snap.wasInProgress)
    }

    func testSnapshotWithNoPriorProgressIsAtZeroAndNotInProgress() {
        let snap = LibraryViewModel.progressSnapshot(itemId: "a", title: "Alpha", prior: nil, duration: 3600)
        XCTAssertEqual(snap.currentTime, 0)
        XCTAssertEqual(snap.progress, 0)
        XCTAssertFalse(snap.isFinished)
        XCTAssertFalse(snap.wasInProgress)
    }

    func testSnapshotDerivesTheFractionWhenTheRecordHasNone() {
        let snap = LibraryViewModel.progressSnapshot(
            itemId: "a", title: "Alpha",
            prior: progress("a", currentTime: 1800, fraction: nil, finished: nil), duration: 3600
        )
        XCTAssertEqual(snap.progress, 0.5, accuracy: 1e-9)
        XCTAssertFalse(snap.isFinished, "a nil finished flag reads as not finished, like the single path")
    }

    func testSnapshotOfAFinishedBookIsNotCountedAsInProgress() {
        let snap = LibraryViewModel.progressSnapshot(
            itemId: "a", title: "Alpha",
            prior: progress("a", currentTime: 3600, fraction: 1, finished: true), duration: 3600
        )
        XCTAssertTrue(snap.isFinished)
        XCTAssertFalse(snap.wasInProgress)
    }

    func testSnapshotClampsOutOfRangeValues() {
        let snap = LibraryViewModel.progressSnapshot(
            itemId: "a", title: "Alpha",
            prior: progress("a", currentTime: -5, fraction: 1.4, finished: false), duration: 3600
        )
        XCTAssertEqual(snap.currentTime, 0)
        XCTAssertEqual(snap.progress, 1)
    }

    // MARK: - Payloads

    func testFinishPayloadMatchesTheSingleBookPath() {
        XCTAssertEqual(
            LibraryViewModel.finishPayload(itemId: "a", duration: 3600),
            AudiobookshelfAPI.BatchProgressPayload(
                libraryItemId: "a", isFinished: true, currentTime: 3600, progress: 1.0, duration: 3600
            )
        )
    }

    func testRestorePayloadsMapEverySnapshotFieldInOrder() {
        let snapshots = [
            LibraryProgressSnapshot(itemId: "a", title: "A", currentTime: 900, progress: 0.25, isFinished: false, duration: 3600),
            LibraryProgressSnapshot(itemId: "b", title: "B", currentTime: 0, progress: 0, isFinished: false, duration: 7200),
            LibraryProgressSnapshot(itemId: "c", title: "C", currentTime: 600, progress: 1, isFinished: true, duration: 600),
        ]
        XCTAssertEqual(LibraryViewModel.restorePayloads(snapshots), [
            AudiobookshelfAPI.BatchProgressPayload(libraryItemId: "a", isFinished: false, currentTime: 900, progress: 0.25, duration: 3600),
            AudiobookshelfAPI.BatchProgressPayload(libraryItemId: "b", isFinished: false, currentTime: 0, progress: 0, duration: 7200),
            AudiobookshelfAPI.BatchProgressPayload(libraryItemId: "c", isFinished: true, currentTime: 600, progress: 1, duration: 600),
        ])
    }

    func testRestorePayloadsOfNothingIsEmptySoNoEmptyBatchIsSent() {
        XCTAssertTrue(LibraryViewModel.restorePayloads([]).isEmpty)
    }

    func testSnapshotRoundTripsThroughTheRestorePayload() {
        let prior = progress("a", currentTime: 1234, fraction: 0.3427, finished: false)
        let snap = LibraryViewModel.progressSnapshot(itemId: "a", title: "A", prior: prior, duration: 3600)
        let payload = LibraryViewModel.restorePayloads([snap])[0]
        XCTAssertEqual(payload.currentTime, prior.currentTime)
        XCTAssertEqual(payload.progress, prior.progress)
        XCTAssertEqual(payload.isFinished, false)
        XCTAssertEqual(payload.duration, 3600)
    }

    // MARK: - unrestoredIds

    func testUnrestoredIdsComparesAgainstEachSnapshotsFinishedFlag() {
        let snapshots = [
            LibraryProgressSnapshot(itemId: "a", title: "A", currentTime: 10, progress: 0.1, isFinished: false, duration: 100),
            LibraryProgressSnapshot(itemId: "b", title: "B", currentTime: 100, progress: 1, isFinished: true, duration: 100),
            LibraryProgressSnapshot(itemId: "c", title: "C", currentTime: 0, progress: 0, isFinished: false, duration: 100),
        ]
        XCTAssertEqual(LibraryViewModel.unrestoredIds(snapshots, after: ["a": true, "b": true]), ["a"],
                       "c is missing (not finished), which matches its snapshot")
        XCTAssertEqual(LibraryViewModel.unrestoredIds(snapshots, after: ["a": false, "b": false, "c": true]), ["b", "c"])
    }

    // MARK: - Select All (plan §11 Q3)

    func testSelectAllOnlyForLocalSetsOfAtMost200() {
        XCTAssertTrue(LibraryViewModel.selectAllAvailable(isLocal: true, count: 1))
        XCTAssertTrue(LibraryViewModel.selectAllAvailable(isLocal: true, count: 200))
        XCTAssertFalse(LibraryViewModel.selectAllAvailable(isLocal: true, count: 201))
        XCTAssertFalse(LibraryViewModel.selectAllAvailable(isLocal: false, count: 12), "never across unloaded server pages")
        XCTAssertFalse(LibraryViewModel.selectAllAvailable(isLocal: true, count: 0), "nothing to select")
    }

    // MARK: - Offline gating (plan §11)

    func testBulkFinishOfNothingSendsNothing() async {
        let vm = LibraryViewModel()
        let result = await vm.markFinished(items: [])
        XCTAssertEqual(result, BulkFinishResult(succeeded: [], failed: [], snapshots: [], verified: true))
        XCTAssertTrue(result.allSucceeded)
    }
}
