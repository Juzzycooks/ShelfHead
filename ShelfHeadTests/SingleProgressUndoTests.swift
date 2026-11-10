import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden, PRODUCT.md principle 2): a single-book Mark Finished or
/// Reset Progress now snapshots the prior progress and offers Undo. Pins the toast copy and
/// that the snapshot a single change takes restores the exact prior position, through the
/// same payloads the bulk Undo sends.
@MainActor
final class SingleProgressUndoTests: XCTestCase {

    private func progress(currentTime: Double?, fraction: Double?, finished: Bool?) -> MediaProgress {
        MediaProgress(
            id: "p-a", libraryItemId: "a", episodeId: nil, duration: 3600, progress: fraction,
            currentTime: currentTime, isFinished: finished, lastUpdate: 0,
            startedAt: nil, finishedAt: nil
        )
    }

    // MARK: Toast copy

    func testMarkedFinishedToastNamesTheBook() {
        XCTAssertEqual(LibraryViewModel.progressUndoCopy(for: .markedFinished, title: "Dune"),
                       "Marked \u{201C}Dune\u{201D} finished")
    }

    func testResetToastNamesTheBook() {
        XCTAssertEqual(LibraryViewModel.progressUndoCopy(for: .resetProgress, title: "Dune"),
                       "Reset \u{201C}Dune\u{201D} to the start")
    }

    func testBlankTitleFallsBackToThisBook() {
        XCTAssertEqual(LibraryViewModel.progressUndoCopy(for: .markedFinished, title: "  "),
                       "Marked this book finished")
    }

    func testUndoFailureSaysNothingChanged() {
        let text = LibraryViewModel.progressUndoFailureMessage
        XCTAssertTrue(text.contains("nothing changed"))
        XCTAssertTrue(text.contains("Recent Changes"))
        XCTAssertFalse(text.lowercased().contains("are you sure"))
    }

    // MARK: Undo restores the prior position

    func testUndoOfMarkFinishedRestoresTheInProgressPosition() {
        let snap = LibraryViewModel.progressSnapshot(
            itemId: "a", title: "Alpha",
            prior: progress(currentTime: 1234, fraction: 0.34, finished: false), duration: 3600
        )
        XCTAssertEqual(LibraryViewModel.restorePayloads([snap]), [
            AudiobookshelfAPI.BatchProgressPayload(
                libraryItemId: "a", isFinished: false, currentTime: 1234, progress: 0.34, duration: 3600
            )
        ])
    }

    func testUndoOfResetRestoresAFinishedBook() {
        let snap = LibraryViewModel.progressSnapshot(
            itemId: "a", title: "Alpha",
            prior: progress(currentTime: 3600, fraction: 1, finished: true), duration: 3600
        )
        XCTAssertEqual(LibraryViewModel.restorePayloads([snap]), [
            AudiobookshelfAPI.BatchProgressPayload(
                libraryItemId: "a", isFinished: true, currentTime: 3600, progress: 1, duration: 3600
            )
        ])
    }

    func testUndoOfAnUnstartedBookPutsItBackAtZero() {
        let snap = LibraryViewModel.progressSnapshot(itemId: "a", title: "Alpha", prior: nil, duration: 3600)
        let payload = LibraryViewModel.restorePayloads([snap]).first
        XCTAssertEqual(payload?.currentTime, 0)
        XCTAssertEqual(payload?.progress, 0)
        XCTAssertEqual(payload?.isFinished, false)
    }

    // MARK: Shared remove-download copy

    func testRemoveDownloadCopySaysProgressIsKept() {
        XCTAssertEqual(RemoveDownloadConfirmation.title, "Remove This Download?")
        XCTAssertEqual(RemoveDownloadConfirmation.message(title: "Dune"),
                       "\u{201C}Dune\u{201D} will be deleted from this device. Your progress is kept.")
    }
}
