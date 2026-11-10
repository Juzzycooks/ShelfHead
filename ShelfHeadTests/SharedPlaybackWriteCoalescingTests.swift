import XCTest
@testable import ShelfHead

/// Item 24 (REVIEW-2026-09-09-REMAINING.md): `SharedPlayback.write(_:)` used to
/// JSON-encode and write to the App Group `UserDefaults` synchronously on whatever actor
/// called it — in practice the main actor, from `AudioPlayerService.updateNowPlaying()`,
/// which fires on every play/pause/seek/track-change/chapter-boundary tick. `write(_:)`
/// now hands the encode+write to a serial background queue with "latest snapshot wins"
/// coalescing (so a burst of calls before the queue catches up only pays for one
/// encode+write), and `flush()` lets a caller that genuinely needs the record durable
/// before the process might suspend (`AudioPlayerService.flushProgress()`) wait for it.
///
/// Only `isRedundantWrite(_:previous:)` — the one pure decision in that change — is
/// covered here. The actual queue/lock behaviour and the real `UserDefaults`/App Group
/// write need live threading and a real container, the same line `SharedPlayback.read()`'s
/// file/defaults work is already left untested on (see `SharedPlaybackMigrationTests`).
final class SharedPlaybackWriteCoalescingTests: XCTestCase {

    private func snapshot(
        itemId: String = "li_1", currentTime: Double = 10, isPlaying: Bool = true,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> SharedPlayback.Snapshot {
        SharedPlayback.Snapshot(
            itemId: itemId, title: "Title", author: "Author",
            currentTime: currentTime, duration: 100, isPlaying: isPlaying, updatedAt: updatedAt)
    }

    func testTwoNilWritesInARowAreRedundant() {
        XCTAssertTrue(SharedPlayback.isRedundantWrite(nil, previous: nil),
                      "e.g. stop() writing nil twice in a row (write(nil) then writeCover(nil)'s sibling call)")
    }

    func testTheFirstWriteAfterNilIsNeverRedundant() {
        XCTAssertFalse(SharedPlayback.isRedundantWrite(snapshot(), previous: nil))
    }

    func testClearingAnExistingRecordIsNeverRedundant() {
        XCTAssertFalse(SharedPlayback.isRedundantWrite(nil, previous: snapshot()))
    }

    func testAnIdenticalSnapshotIsRedundant() {
        let updatedAt = Date(timeIntervalSince1970: 500)
        let a = snapshot(updatedAt: updatedAt)
        let b = snapshot(updatedAt: updatedAt)
        XCTAssertTrue(SharedPlayback.isRedundantWrite(a, previous: b))
    }

    /// The common real-world case: `updatedAt` is stamped fresh on essentially every
    /// live playback write, so two otherwise-identical snapshots a tick apart are NOT
    /// redundant — this dedup only catches genuine duplicates, not "nothing changed but
    /// the clock."
    func testASnapshotThatDiffersOnlyByUpdatedAtIsNotRedundant() {
        let a = snapshot(updatedAt: Date(timeIntervalSince1970: 0))
        let b = snapshot(updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(SharedPlayback.isRedundantWrite(a, previous: b))
    }

    func testASnapshotThatDiffersByCurrentTimeIsNotRedundant() {
        let updatedAt = Date(timeIntervalSince1970: 500)
        let a = snapshot(currentTime: 10, updatedAt: updatedAt)
        let b = snapshot(currentTime: 20, updatedAt: updatedAt)
        XCTAssertFalse(SharedPlayback.isRedundantWrite(a, previous: b))
    }

    func testASnapshotForADifferentBookIsNotRedundant() {
        let updatedAt = Date(timeIntervalSince1970: 500)
        let a = snapshot(itemId: "li_1", updatedAt: updatedAt)
        let b = snapshot(itemId: "li_2", updatedAt: updatedAt)
        XCTAssertFalse(SharedPlayback.isRedundantWrite(a, previous: b))
    }

    // MARK: - shouldSkipWrite (28 Oct 2026)

    /// The regression: a clear that is a process's first write used to compare equal to the
    /// initial `nil` and be dropped, leaving the previous run's book on disk.
    func testFirstClearInProcessIsNeverSkipped() {
        XCTAssertFalse(SharedPlayback.shouldSkipWrite(nil, lastWritten: .none))
    }

    func testFirstSnapshotInProcessIsNeverSkipped() {
        XCTAssertFalse(SharedPlayback.shouldSkipWrite(snapshot(), lastWritten: .none))
    }

    func testRepeatedClearIsSkipped() {
        XCTAssertTrue(SharedPlayback.shouldSkipWrite(nil, lastWritten: .some(nil)))
    }

    func testClearAfterSnapshotIsWritten() {
        XCTAssertFalse(SharedPlayback.shouldSkipWrite(nil, lastWritten: .some(snapshot())))
    }
}
