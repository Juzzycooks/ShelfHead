import XCTest
@testable import ShelfHead

/// Batch 495: decisions added while reviewing the batch's packages.
final class Batch495ReviewTests: XCTestCase {

    private func decode(_ json: String) throws -> MediaProgress {
        try JSONDecoder().decode(MediaProgress.self, from: Data(json.utf8))
    }

    // MARK: L12 — a reading fraction shown on a tile is never written back as listening progress

    func testReadingOnlyRecordHasNoAudioProgressToRestore() throws {
        let mp = try decode(#"{"libraryItemId":"li1","duration":0,"progress":0,"currentTime":0,"isFinished":false,"ebookProgress":0.6}"#)
        // Batch 497: `progress` is the server's listening fraction again; the tile picks the
        // reading fraction itself (`LibraryItem.shownProgress`).
        XCTAssertEqual(mp.progress, 0)
        XCTAssertEqual(mp.readingFraction, 0.6)
        XCTAssertEqual(mp.audioProgress, 0, "there is no listening position to send back")
    }

    func testReadingOnlyRecordWithoutAProgressFieldRestoresZero() throws {
        // Batch 497: a server that leaves `progress` out entirely.
        let mp = try decode(#"{"libraryItemId":"li1","ebookProgress":0.6}"#)
        XCTAssertNil(mp.audioProgress)
        let snapshot = LibraryViewModel.progressSnapshot(itemId: "li1", title: "Read Only", prior: mp, duration: 36_000)
        XCTAssertEqual(snapshot.progress, 0)
        XCTAssertEqual(snapshot.currentTime, 0)
    }

    func testListenedRecordKeepsItsAudioProgress() throws {
        let mp = try decode(#"{"libraryItemId":"li1","duration":3600,"progress":0.25,"currentTime":900,"ebookProgress":0.6}"#)
        XCTAssertEqual(mp.progress, 0.25)
        XCTAssertEqual(mp.audioProgress, 0.25)
    }

    func testRecordWithoutEbookProgressIsUnchanged() throws {
        let mp = try decode(#"{"libraryItemId":"li1","progress":0.4,"currentTime":0,"duration":0}"#)
        XCTAssertEqual(mp.audioProgress, 0.4)
    }

    func testUndoSnapshotOfAReadingOnlyBookRestoresZeroListeningProgress() throws {
        let mp = try decode(#"{"libraryItemId":"li1","duration":0,"progress":0,"currentTime":0,"isFinished":false,"ebookProgress":0.6}"#)
        let snapshot = LibraryViewModel.progressSnapshot(itemId: "li1", title: "Read Only", prior: mp, duration: 0)
        XCTAssertEqual(snapshot.progress, 0)
        XCTAssertEqual(snapshot.currentTime, 0)
        XCTAssertFalse(snapshot.isFinished)
    }

    // MARK: W7 — the phone and the Watch share one smart-rewind scale

    func testPhoneSmartRewindUsesTheSharedScale() {
        let enabled = SettingsStore.smartRewind
        for paused: TimeInterval in [0, 9, 10, 59, 60, 599, 600, 3599, 3600, 86_400] {
            XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: paused),
                           WatchSmartRewind.seconds(pausedFor: paused, isEnabled: enabled))
        }
        XCTAssertEqual(WatchSmartRewind.seconds(pausedFor: 120, isEnabled: true), 5)
        XCTAssertEqual(WatchSmartRewind.seconds(pausedFor: 120, isEnabled: false), 0)
    }
}
