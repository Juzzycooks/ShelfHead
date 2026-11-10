import XCTest
@testable import ShelfHead

/// Library browse plan §3.2 / §8 step 9 (2026-10-05): pins the pure copy and layout math
/// behind Library select mode, the bulk action bar, the Mark Finished confirmation and Undo
/// toast, and the placeholder slots. The surrounding views need live view models, so the
/// decisions are tested here as statics (the `LibraryView.isPrimaryScope` precedent).
@MainActor
final class LibrarySelectionCopyTests: XCTestCase {

    // MARK: Nav title

    func testSelectionTitle() {
        XCTAssertEqual(LibraryView.selectionTitle(count: 0), "Select Books")
        XCTAssertEqual(LibraryView.selectionTitle(count: 1), "1 Book")
        XCTAssertEqual(LibraryView.selectionTitle(count: 12), "12 Books")
    }

    func testSelectionTitleStaysShort() {
        // HIG Toolbars: keep the title under 15 characters.
        for count in [0, 1, 9, 50, 200, 3_000] {
            XCTAssertLessThan(LibraryView.selectionTitle(count: count).count, 15, "count \(count)")
        }
    }

    // MARK: Bulk action labels

    func testBulkActionLabelsCarryCount() {
        XCTAssertEqual(LibraryView.bulkActionLabel(.download, count: 12), "Download 12 books")
        XCTAssertEqual(LibraryView.bulkActionLabel(.download, count: 1), "Download 1 book")
        XCTAssertEqual(LibraryView.bulkActionLabel(.markFinished, count: 12), "Mark 12 books finished")
        XCTAssertEqual(LibraryView.bulkActionLabel(.markFinished, count: 1), "Mark 1 book finished")
        XCTAssertEqual(LibraryView.bulkActionLabel(.upNext, count: 3), "Add 3 books to Up Next")
        XCTAssertEqual(LibraryView.bulkActionLabel(.upNext, count: 1), "Add 1 book to Up Next")
    }

    func testBulkActionLabelsWithNothingSelected() {
        XCTAssertEqual(LibraryView.bulkActionLabel(.download, count: 0), "Download")
        XCTAssertEqual(LibraryView.bulkActionLabel(.markFinished, count: 0), "Mark Finished")
        XCTAssertEqual(LibraryView.bulkActionLabel(.upNext, count: 0), "Add to Up Next")
    }

    func testBulkActionTitlesAndGlyphs() {
        // Glyphs match the swipe actions and BookContextMenu (plan §3.2).
        XCTAssertEqual(LibraryView.BulkAction.allCases, [.upNext, .download, .markFinished])
        XCTAssertEqual(LibraryView.BulkAction.upNext.systemImage, "text.badge.plus")
        XCTAssertEqual(LibraryView.BulkAction.download.systemImage, "arrow.down.circle")
        XCTAssertEqual(LibraryView.BulkAction.markFinished.systemImage, "checkmark.circle")
        XCTAssertEqual(LibraryView.BulkAction.upNext.title, "Up Next")
        XCTAssertEqual(LibraryView.BulkAction.download.title, "Download")
        XCTAssertEqual(LibraryView.BulkAction.markFinished.title, "Mark Finished")
    }

    // MARK: Mark Finished confirmation

    func testConfirmTitleAndButton() {
        XCTAssertEqual(LibraryView.markFinishedConfirmTitle(count: 12), "Mark 12 books finished?")
        XCTAssertEqual(LibraryView.markFinishedConfirmTitle(count: 1), "Mark 1 book finished?")
        // Series detail's button wording.
        XCTAssertEqual(LibraryView.markFinishedConfirmButton(count: 12), "Mark 12 Finished")
    }

    func testConfirmMessageWithBooksInProgress() {
        XCTAssertEqual(
            LibraryView.markFinishedConfirmMessage(count: 12, inProgress: 3),
            "This updates 12 books on the server. 3 are in progress \u{2014} their positions will be replaced. You can undo this right after."
        )
    }

    func testConfirmMessageWithOneInProgress() {
        XCTAssertEqual(
            LibraryView.markFinishedConfirmMessage(count: 5, inProgress: 1),
            "This updates 5 books on the server. 1 is in progress \u{2014} its position will be replaced. You can undo this right after."
        )
        XCTAssertEqual(
            LibraryView.markFinishedConfirmMessage(count: 1, inProgress: 1),
            "This updates 1 book on the server. It\u{2019}s in progress \u{2014} its position will be replaced. You can undo this right after."
        )
    }

    func testConfirmMessageWithNothingInProgressOmitsThePositionSentence() {
        XCTAssertEqual(
            LibraryView.markFinishedConfirmMessage(count: 4, inProgress: 0),
            "This updates 4 books on the server. You can undo this right after."
        )
    }

    func testConfirmMessageClampsInProgressToCount() {
        XCTAssertEqual(
            LibraryView.markFinishedConfirmMessage(count: 2, inProgress: 9),
            LibraryView.markFinishedConfirmMessage(count: 2, inProgress: 2)
        )
        XCTAssertEqual(
            LibraryView.markFinishedConfirmMessage(count: 2, inProgress: -1),
            LibraryView.markFinishedConfirmMessage(count: 2, inProgress: 0)
        )
    }

    // MARK: Undo toast and failures

    func testMarkedFinishedToast() {
        XCTAssertEqual(LibraryView.markedFinishedToast(succeeded: 12, failed: 0), "Marked 12 finished")
        XCTAssertEqual(
            LibraryView.markedFinishedToast(succeeded: 10, failed: 2),
            "Marked 10 finished. 2 books couldn\u{2019}t be updated. Try again."
        )
        XCTAssertEqual(
            LibraryView.markedFinishedToast(succeeded: 4, failed: 1),
            "Marked 4 finished. 1 book couldn\u{2019}t be updated. Try again."
        )
    }

    func testFailureMessages() {
        XCTAssertEqual(LibraryView.bulkFinishFailureMessage(count: 2), "2 books couldn\u{2019}t be updated. Try again.")
        XCTAssertEqual(LibraryView.bulkFinishFailureMessage(count: 1), "1 book couldn\u{2019}t be updated. Try again.")
        XCTAssertEqual(LibraryView.undoFailureMessage(count: 3),
                       "Couldn\u{2019}t undo 3 books. Try again from Recent Changes.")
    }

    // MARK: Download confirmation

    func testDownloadConfirmTitle() {
        XCTAssertEqual(LibraryView.downloadConfirmTitle(count: 12), "Download 12 books?")
        XCTAssertEqual(LibraryView.downloadConfirmTitle(count: 1), "Download 1 book?")
    }

    func testDownloadConfirmDetailDropsTheRepeatedQuestion() {
        let items = (0..<12).map { item("b\($0)", size: 400_000_000) }
        let plan = DownloadManager.bulkDownloadPlan(
            items: items, isDownloaded: { _ in false }, isDownloading: { _ in false },
            wifiOnly: true, onWiFi: true, freeBytes: 100_000_000_000
        )
        XCTAssertTrue(plan.needsConfirmation)
        let detail = LibraryView.downloadConfirmDetail(summary: plan.summary, count: plan.toDownload.count)
        XCTAssertFalse(detail.hasPrefix("Download 12 books?"))
        XCTAssertTrue(detail.hasPrefix("About "), detail)
        XCTAssertTrue(detail.hasSuffix("Respects your Wi-Fi-only setting."), detail)
    }

    func testDownloadConfirmDetailFallsBackToWholeSummary() {
        XCTAssertEqual(LibraryView.downloadConfirmDetail(summary: "Something else.", count: 3), "Something else.")
    }

    func testSmallDownloadsDontConfirm() {
        let plan = DownloadManager.bulkDownloadPlan(
            items: (0..<5).map { item("s\($0)") }, isDownloaded: { _ in false }, isDownloading: { _ in false },
            wifiOnly: false, onWiFi: true, freeBytes: nil
        )
        XCTAssertFalse(plan.needsConfirmation)
    }

    // MARK: Status line

    func testSelectionStatusLine() {
        XCTAssertEqual(
            LibraryView.selectionStatusLine(isMarkingFinished: true, markingCount: 12, serverReachable: true),
            "Marking 12 books finished\u{2026}"
        )
        XCTAssertEqual(
            LibraryView.selectionStatusLine(isMarkingFinished: false, markingCount: 0, serverReachable: false),
            "Offline. Download and Mark Finished need your server."
        )
        XCTAssertNil(LibraryView.selectionStatusLine(isMarkingFinished: false, markingCount: 0, serverReachable: true))
    }

    // MARK: Grid column count (scrubber row snapping)

    func testAdaptiveColumnCountMatchesTheGridSolve() {
        // Comfortable (min 150) is 2 columns across the iPhone range (see `libraryGrid`'s note).
        for width in [375.0, 390, 393, 414, 428, 430] {
            XCTAssertEqual(LibraryView.adaptiveColumnCount(width: width, minimum: 150), 2, "width \(width)")
        }
        // Compact (min 96) is 3 columns on the narrowest supported iPhone.
        XCTAssertEqual(LibraryView.adaptiveColumnCount(width: 375, minimum: 96), 3)
        // Unknown width (before the first layout) still yields one column.
        XCTAssertEqual(LibraryView.adaptiveColumnCount(width: 0, minimum: 150), 1)
    }

    // MARK: Placeholder slots

    func testPlaceholderAccessibilityLabels() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(LibraryPlaceholderCopy.accessibilityLabel(index: 1_450, state: .loading, offline: false, locale: locale),
                       "Book 1,451, loading")
        XCTAssertEqual(LibraryPlaceholderCopy.accessibilityLabel(index: 0, state: .failed, offline: false, locale: locale),
                       "Book 1, couldn\u{2019}t load")
        XCTAssertEqual(LibraryPlaceholderCopy.accessibilityLabel(index: 9, state: .notRequested, offline: true, locale: locale),
                       "Book 10, not loaded, offline")
        XCTAssertEqual(LibraryPlaceholderCopy.accessibilityLabel(index: 9, state: .notRequested, offline: false, locale: locale),
                       "Book 10, loading")
    }

    func testPlaceholderGlyphs() {
        XCTAssertEqual(LibraryPlaceholderCopy.systemImage(state: .failed, offline: false), "exclamationmark.arrow.circlepath")
        XCTAssertEqual(LibraryPlaceholderCopy.systemImage(state: .failed, offline: true), "exclamationmark.arrow.circlepath")
        XCTAssertEqual(LibraryPlaceholderCopy.systemImage(state: .notRequested, offline: true), "wifi.slash")
        XCTAssertNil(LibraryPlaceholderCopy.systemImage(state: .notRequested, offline: false))
        XCTAssertNil(LibraryPlaceholderCopy.systemImage(state: .loading, offline: false))
    }

    // MARK: Helpers

    private func item(_ id: String, size: Int? = 1_000_000) -> ShelfHead.LibraryItem {
        let json = """
        {"id":"\(id)","mediaType":"book"\(size.map { ",\"size\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }
}
