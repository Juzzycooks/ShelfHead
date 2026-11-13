import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 D5): Library Select mode's bulk Remove Download.
final class Batch496LibraryBulkRemoveTests: XCTestCase {

    // MARK: - BulkRemovalPlan

    func testPlanKeepsOnlyDownloadedBooksInOrder() {
        let plan = BulkRemovalPlan.make(
            [(id: "a", serverSize: 100), (id: "b", serverSize: 200), (id: "c", serverSize: 300)],
            isDownloaded: { $0 != "b" },
            storedBytes: [:])
        XCTAssertEqual(plan.itemIds, ["a", "c"])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.totalBytes, 400)
    }

    func testPlanDeduplicatesIds() {
        let plan = BulkRemovalPlan.make(
            [(id: "a", serverSize: 100), (id: "a", serverSize: 100)],
            isDownloaded: { _ in true },
            storedBytes: [:])
        XCTAssertEqual(plan.itemIds, ["a"])
        XCTAssertEqual(plan.totalBytes, 100)
    }

    func testPlanPrefersBytesOnDiskOverServerSize() {
        let plan = BulkRemovalPlan.make(
            [(id: "a", serverSize: 100), (id: "b", serverSize: 200)],
            isDownloaded: { _ in true },
            storedBytes: ["a": 1_000, "b": 0])
        // "a" uses what's on disk; "b" has no stored figure, so the server's size.
        XCTAssertEqual(plan.totalBytes, 1_200)
    }

    func testPlanWithUnknownSizesIsZeroBytes() {
        let plan = BulkRemovalPlan.make(
            [(id: "a", serverSize: nil), (id: "b", serverSize: 0)],
            isDownloaded: { _ in true },
            storedBytes: [:])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.totalBytes, 0)
    }

    func testPlanIsEmptyWhenNothingIsDownloaded() {
        let plan = BulkRemovalPlan.make(
            [(id: "a", serverSize: 100)],
            isDownloaded: { _ in false },
            storedBytes: ["a": 500])
        XCTAssertEqual(plan, BulkRemovalPlan(itemIds: [], totalBytes: 0))
    }

    // MARK: - Copy

    func testBulkActionGlyphAndTitle() {
        XCTAssertEqual(LibraryView.BulkAction.removeDownload.systemImage, "trash")
        XCTAssertEqual(LibraryView.BulkAction.removeDownload.title, "Remove")
    }

    func testBulkActionLabelCountsDownloads() {
        XCTAssertEqual(LibraryView.bulkActionLabel(.removeDownload, count: 0), "Remove Downloads")
        XCTAssertEqual(LibraryView.bulkActionLabel(.removeDownload, count: 1), "Remove 1 download")
        XCTAssertEqual(LibraryView.bulkActionLabel(.removeDownload, count: 3), "Remove 3 downloads")
    }

    func testDownloadsPhraseHasNoDigitGrouping() {
        XCTAssertEqual(LibraryView.downloadsPhrase(1), "1 download")
        XCTAssertEqual(LibraryView.downloadsPhrase(1200), "1200 downloads")
    }

    func testConfirmTitleAndButton() {
        XCTAssertEqual(LibraryView.removeDownloadsConfirmTitle(count: 1), "Remove 1 download?")
        XCTAssertEqual(LibraryView.removeDownloadsConfirmTitle(count: 4), "Remove 4 downloads?")
        XCTAssertEqual(LibraryView.removeDownloadsConfirmButton(count: 1), RemoveDownloadConfirmation.button)
        XCTAssertEqual(LibraryView.removeDownloadsConfirmButton(count: 4), "Remove 4 Downloads")
    }

    func testConfirmMessageNamesTheSizeWhenKnown() {
        XCTAssertEqual(LibraryView.removeDownloadsConfirmMessage(bytes: 0),
                       "The audio will be deleted from this device. Your progress is kept.")
        let size = ByteCountFormatter.string(fromByteCount: 1_500_000_000, countStyle: .file)
        XCTAssertEqual(LibraryView.removeDownloadsConfirmMessage(bytes: 1_500_000_000),
                       "\(size) will be deleted from this device. Your progress is kept.")
    }

    func testRemovedToast() {
        XCTAssertEqual(LibraryView.removedDownloadsToast(count: 2, bytes: 0), "Removed 2 downloads")
        let size = ByteCountFormatter.string(fromByteCount: 700_000_000, countStyle: .file)
        XCTAssertEqual(LibraryView.removedDownloadsToast(count: 1, bytes: 700_000_000),
                       "Removed 1 download, freeing \(size)")
    }
}
