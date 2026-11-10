import XCTest
@testable import ShelfHead

@MainActor
final class SeriesBulkCopyTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(SeriesDetailView.confirmTitle(for: .markFinished), "Mark whole series finished?")
        XCTAssertEqual(SeriesDetailView.confirmTitle(for: .markUnfinished), "Mark whole series unfinished?")
        XCTAssertEqual(SeriesDetailView.confirmTitle(for: .downloadUnheard), "Download unheard books?")
        XCTAssertEqual(SeriesDetailView.confirmTitle(for: .downloadAll), "Download entire series?")
        XCTAssertEqual(SeriesDetailView.confirmTitle(for: nil), "")
    }

    func testButtonTitles() {
        func t(_ a: SeriesBulkAction) -> String {
            SeriesDetailView.confirmButtonTitle(a, bookCount: 7, unheardToDownload: 3, allToDownload: 5)
        }
        XCTAssertEqual(t(.markFinished), "Mark 7 Finished")
        XCTAssertEqual(t(.markUnfinished), "Mark 7 Unfinished")
        XCTAssertEqual(t(.downloadUnheard), "Download 3")
        XCTAssertEqual(t(.downloadAll), "Download 5")
    }

    func testMessagesPluralAndSingular() {
        func m(_ a: SeriesBulkAction, _ n: Int) -> String {
            SeriesDetailView.confirmMessage(a, bookCount: n, unheardToDownload: n, allToDownload: n)
        }
        // Critique 2026-10-06 (harden): Mark Finished reuses Library's bulk wording.
        XCTAssertEqual(m(.markFinished, 1), "This updates 1 book on the server. You can undo this right after.")
        XCTAssertEqual(m(.markUnfinished, 4),
                       "This updates 4 finished books on the server. Positions are kept. You can undo this right after.")
        XCTAssertEqual(m(.markUnfinished, 1),
                       "This updates 1 finished book on the server. Positions are kept. You can undo this right after.")
        XCTAssertEqual(m(.downloadUnheard, 1), "Queues 1 unfinished book for download (respects your Wi-Fi-only setting).")
        XCTAssertEqual(m(.downloadUnheard, 2), "Queues 2 unfinished books for download (respects your Wi-Fi-only setting).")
        XCTAssertEqual(m(.downloadAll, 3), "Queues all 3 remaining books in the series for download, including already-finished ones (respects your Wi-Fi-only setting).")
        XCTAssertEqual(m(.downloadAll, 1), "Queues all 1 remaining book in the series for download, including already-finished ones (respects your Wi-Fi-only setting).")
    }

    // MARK: Critique 2026-10-06 (harden)

    func testMarkFinishedWarnsAboutInProgressPositionsLikeLibrary() {
        let series = SeriesDetailView.confirmMessage(.markFinished, bookCount: 6, unheardToDownload: 0,
                                                     allToDownload: 0, inProgress: 2)
        XCTAssertEqual(series, LibraryView.markFinishedConfirmMessage(count: 6, inProgress: 2))
        XCTAssertTrue(series.contains("2 are in progress \u{2014} their positions will be replaced."))
        XCTAssertFalse(series.lowercased().contains("are you sure"))
    }

    func testInProgressIsIgnoredForOtherActions() {
        XCTAssertEqual(
            SeriesDetailView.confirmMessage(.markUnfinished, bookCount: 2, unheardToDownload: 0, allToDownload: 0, inProgress: 5),
            SeriesDetailView.confirmMessage(.markUnfinished, bookCount: 2, unheardToDownload: 0, allToDownload: 0))
    }

    func testMarkedUnfinishedToast() {
        XCTAssertEqual(SeriesDetailView.markedUnfinishedToast(succeeded: 3, failed: 0), "Marked 3 unfinished")
        XCTAssertEqual(SeriesDetailView.markedUnfinishedToast(succeeded: 2, failed: 1),
                       "Marked 2 unfinished. 1 book couldn\u{2019}t be updated. Try again.")
    }

    func testUnfinishedTargetsKeepPositionAndClearFinished() {
        let snap = LibraryProgressSnapshot(itemId: "a", title: "A", currentTime: 3600, progress: 1,
                                           isFinished: true, duration: 3600)
        let targets = SeriesDetailView.unfinishedTargets([snap])
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].itemId, "a")
        XCTAssertEqual(targets[0].currentTime, 3600)
        XCTAssertEqual(targets[0].progress, 1)
        XCTAssertEqual(targets[0].duration, 3600)
        XCTAssertFalse(targets[0].isFinished)
        // The snapshot itself (what Undo restores) is untouched.
        XCTAssertTrue(snap.isFinished)
    }

    func testFailureMessage() {
        XCTAssertEqual(SeriesDetailView.failureMessage(count: 1), "1 book couldn’t be updated. Try again.")
        XCTAssertEqual(SeriesDetailView.failureMessage(count: 2), "2 books couldn’t be updated. Try again.")
    }
}
