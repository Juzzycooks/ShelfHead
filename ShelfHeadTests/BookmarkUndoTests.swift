import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): the shared bookmark-delete Undo (`BookmarkDeleteUndo`, used by
/// Book Detail's sheet, the player's sheet and All Bookmarks) and the Edit Bookmark result
/// (`PlayerViewModel.updateBookmark` → `BookmarkSaveResult?`). The network side isn't run
/// here; these pin the pure pieces.
@MainActor
final class BookmarkUndoTests: XCTestCase {

    // MARK: Undo copy

    func testDeletedBookmarkWithATitleNamesIt() {
        XCTAssertEqual(BookmarkDeleteUndo.message(title: "  The gate ", time: 125), "Deleted \u{201C}The gate\u{201D}")
    }

    func testDeletedBookmarkWithOnlyATimeSaysTheTime() {
        XCTAssertEqual(BookmarkDeleteUndo.message(title: "2:05", time: 125), "Deleted bookmark at 2:05")
        XCTAssertEqual(BookmarkDeleteUndo.message(title: "   ", time: 3723), "Deleted bookmark at 1:02:03")
    }

    func testBookDetailUsesTheSharedCopy() {
        XCTAssertEqual(BookDetailView.bookmarkDeletedMessage(title: "Chapter One", time: 10),
                       BookmarkDeleteUndo.message(title: "Chapter One", time: 10))
    }

    func testUndoToastMatchesTheAppsOtherUndoToasts() {
        XCTAssertEqual(BookmarkDeleteUndo.toastDuration, 6)
    }

    func testUndoWithNothingDeletedDoesNothing() {
        let undo = BookmarkDeleteUndo()
        XCTAssertNil(undo.undo())
        XCTAssertNil(undo.message)
        XCTAssertNil(undo.deleted)
    }

    // MARK: Edit Bookmark result

    func testSaveResultMapping() {
        XCTAssertEqual(PlayerViewModel.bookmarkSaveResult(synced: true), .synced)
        XCTAssertEqual(PlayerViewModel.bookmarkSaveResult(synced: false), .queued)
    }

    func testEditNeedsAnItemAndASignedInServer() {
        XCTAssertTrue(PlayerViewModel.canSaveBookmarkEdit(itemId: "li_1", serverURL: "https://abs.example"))
        XCTAssertFalse(PlayerViewModel.canSaveBookmarkEdit(itemId: "", serverURL: "https://abs.example"))
        XCTAssertFalse(PlayerViewModel.canSaveBookmarkEdit(itemId: "li_1", serverURL: ""))
        XCTAssertFalse(PlayerViewModel.canSaveBookmarkEdit(itemId: " ", serverURL: " "))
    }

    func testBlankEditedTitleFallsBackToTheTime() {
        XCTAssertEqual(PlayerViewModel.editedBookmarkTitle(note: "  ", time: 125), "2:05")
        XCTAssertEqual(PlayerViewModel.editedBookmarkTitle(note: " Gate \n", time: 125), "Gate")
    }

    func testSheetClosesOnlyOnASyncedOrQueuedSave() {
        XCTAssertTrue(BookmarkEditFeedback.shouldClose(after: .synced))
        XCTAssertTrue(BookmarkEditFeedback.shouldClose(after: .queued))
        XCTAssertFalse(BookmarkEditFeedback.shouldClose(after: nil))
    }

    func testFailureCopyNamesTheProblemAndTheRecovery() {
        let text = BookmarkEditFeedback.failureMessage
        XCTAssertTrue(text.hasPrefix("Couldn\u{2019}t save this bookmark."))
        XCTAssertTrue(text.contains("try again"))
        XCTAssertFalse(text.lowercased().contains("are you sure"))
    }
}
