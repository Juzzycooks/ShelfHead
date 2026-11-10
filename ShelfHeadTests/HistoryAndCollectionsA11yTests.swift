import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • HistoryAndCollectionsA11yTests
// =============================================================================
//
// N-4 (REVIEW_2026-09-14_DESIGN.md): `CollectionsPlaylistsView` and
// `PlaybackHistoryView` had zero accessibility annotations — their rows were
// composed of an unlabelled decorative icon plus separate title/caption `Text`
// stops, with no single spoken label a VoiceOver/Voice Control user could act on.
// The fix extracts the label-composition logic into pure static functions
// (`CollectionsBrowseView.rowAccessibilityLabel`, `PlaylistsBrowseView
// .rowAccessibilityLabel`, `PlaybackHistoryView.rowAccessibilityLabel`) so the
// wording can be pinned here, following this project's established precedent
// (`AccountRemovalTests`, `DownloadManagerScopeTests`, etc.) of testing the pure
// decision/composition function rather than the live SwiftUI row, which talks to
// `@Environment` view models and isn't unit-testable directly.
final class HistoryAndCollectionsA11yTests: XCTestCase {

    // MARK: - Collections

    func testCollectionRowLabelSingularBook() {
        let label = CollectionsBrowseView.rowAccessibilityLabel(name: "Summer Reads", bookCount: 1)
        XCTAssertEqual(label, "Summer Reads, collection, 1 book")
    }

    func testCollectionRowLabelPluralBooks() {
        let label = CollectionsBrowseView.rowAccessibilityLabel(name: "Summer Reads", bookCount: 4)
        XCTAssertEqual(label, "Summer Reads, collection, 4 books")
    }

    func testCollectionRowLabelZeroBooks() {
        let label = CollectionsBrowseView.rowAccessibilityLabel(name: "Empty Shelf", bookCount: 0)
        XCTAssertEqual(label, "Empty Shelf, collection, 0 books")
    }

    // MARK: - Playlists

    func testPlaylistRowLabelSingularItem() {
        let label = PlaylistsBrowseView.rowAccessibilityLabel(name: "Bedtime Mix", itemCount: 1)
        XCTAssertEqual(label, "Bedtime Mix, playlist, 1 item")
    }

    func testPlaylistRowLabelPluralItems() {
        let label = PlaylistsBrowseView.rowAccessibilityLabel(name: "Bedtime Mix", itemCount: 3)
        XCTAssertEqual(label, "Bedtime Mix, playlist, 3 items")
    }

    // MARK: - Playback history

    private func makeEntry(
        title: String = "The Hobbit",
        action: PlaybackHistoryStore.HistoryAction = .markedFinished,
        timestamp: Date = Date(timeIntervalSince1970: 0)
    ) -> PlaybackHistoryStore.HistoryEntry {
        PlaybackHistoryStore.HistoryEntry(
            id: UUID(), itemId: "item-1", title: title, action: action, timestamp: timestamp,
            previousCurrentTime: 120, previousIsFinished: false, previousDuration: 3600
        )
    }

    func testUndoableEntryLabelOmitsCantUndoNote() {
        let entry = makeEntry()
        let label = PlaybackHistoryView.rowAccessibilityLabel(for: entry, undoable: true)
        XCTAssertTrue(label.hasPrefix("The Hobbit, Marked Finished, "))
        XCTAssertFalse(label.contains("can't be undone"))
    }

    func testSupersededEntryLabelIncludesCantUndoNote() {
        let entry = makeEntry(action: .resetProgress)
        let label = PlaybackHistoryView.rowAccessibilityLabel(for: entry, undoable: false)
        XCTAssertTrue(label.hasPrefix("The Hobbit, Progress Reset, "))
        XCTAssertTrue(label.hasSuffix("can't be undone, changed again since"))
    }

    func testEntryLabelIncludesFormattedTimestamp() {
        let entry = makeEntry(timestamp: Date(timeIntervalSince1970: 0))
        let label = PlaybackHistoryView.rowAccessibilityLabel(for: entry, undoable: true)
        let expectedTimestamp = Date(timeIntervalSince1970: 0)
            .formatted(date: .abbreviated, time: .shortened)
        XCTAssertTrue(label.contains(expectedTimestamp))
    }

    func testEntryLabelReflectsMarkedUnfinishedAction() {
        let entry = makeEntry(action: .markedUnfinished)
        let label = PlaybackHistoryView.rowAccessibilityLabel(for: entry, undoable: true)
        XCTAssertTrue(label.contains("Marked Unfinished"))
    }
}
