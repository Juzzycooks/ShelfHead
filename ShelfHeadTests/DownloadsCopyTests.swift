import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (clarify + distill): Settings > Downloads and the Downloads page.
/// Pins the plural helper ("1 books" on the Storage row), the Downloads page's sort
/// orders, and the signed-out servers' confirmation and outcome copy.
final class DownloadsCopyTests: XCTestCase {

    // MARK: - Plural helper

    func testBookCountIsPluralisedCorrectly() {
        XCTAssertEqual(DownloadCountCopy.books(0), "0 books")
        XCTAssertEqual(DownloadCountCopy.books(1), "1 book")
        XCTAssertEqual(DownloadCountCopy.books(2), "2 books")
        XCTAssertEqual(DownloadCountCopy.books(120), "120 books")
    }

    // MARK: - Sort orders

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var keys: [DownloadsSort.Key] {
        [
            DownloadsSort.Key(id: "b", title: "beta", downloadedAt: now.addingTimeInterval(-3_600), bytes: 300),
            DownloadsSort.Key(id: "a", title: "Alpha", downloadedAt: now, bytes: 100),
            DownloadsSort.Key(id: "c", title: "Gamma", downloadedAt: nil, bytes: nil),
            DownloadsSort.Key(id: "d", title: "delta", downloadedAt: now.addingTimeInterval(-7_200), bytes: 900),
        ]
    }

    func testTitleOrderIsCaseInsensitive() {
        XCTAssertEqual(DownloadsSort.orderedIDs(keys, by: .title), ["a", "b", "d", "c"])
    }

    func testRecentlyDownloadedIsNewestFirstWithUndatedLast() {
        XCTAssertEqual(DownloadsSort.orderedIDs(keys, by: .recentlyDownloaded), ["a", "b", "d", "c"])
    }

    func testSizeIsLargestFirstWithUnknownLast() {
        XCTAssertEqual(DownloadsSort.orderedIDs(keys, by: .size), ["d", "b", "a", "c"])
    }

    func testTiesFallBackToTitle() {
        let tied = [
            DownloadsSort.Key(id: "z", title: "Zed", downloadedAt: now, bytes: 50),
            DownloadsSort.Key(id: "m", title: "Mid", downloadedAt: now, bytes: 50),
        ]
        XCTAssertEqual(DownloadsSort.orderedIDs(tied, by: .size), ["m", "z"])
        XCTAssertEqual(DownloadsSort.orderedIDs(tied, by: .recentlyDownloaded), ["m", "z"])
    }

    func testZeroBytesCountsAsUnknownSize() {
        let zero = [
            DownloadsSort.Key(id: "zero", title: "A", bytes: 0),
            DownloadsSort.Key(id: "some", title: "B", bytes: 10),
        ]
        XCTAssertEqual(DownloadsSort.orderedIDs(zero, by: .size), ["some", "zero"])
    }

    func testTitleOrderMatchesTheExistingComparator() {
        // The Title order must not reorder rows relative to the pinned comparator the
        // page has always used (`DownloadsViewSortTests`).
        typealias Summary = DownloadsSettingsView.DownloadedBookSummary
        let summaries = keys.map { Summary(id: $0.id, title: $0.title, author: "") }
            .sorted(by: Summary.isOrderedBeforeByTitle)
        XCTAssertEqual(summaries.map(\.id), DownloadsSort.orderedIDs(keys, by: .title))
    }

    func testEverySortOrderHasALabel() {
        for order in DownloadsSortOrder.allCases {
            XCTAssertFalse(order.label.isEmpty)
        }
    }

    // MARK: - Signed-out servers

    func testRemoveMessageStatesTheSize() {
        XCTAssertTrue(SignedOutStorage.removeMessage(size: "1.2 GB").hasPrefix("Frees 1.2 GB"))
        XCTAssertFalse(SignedOutStorage.removeMessage(size: nil).contains("Frees"))
        XCTAssertTrue(SignedOutStorage.removeMessage(size: nil).contains("progress"))
    }

    func testRemovalOutcome() {
        XCTAssertEqual(SignedOutStorage.removalOutcome(serverCount: 1, freed: "800 MB"),
                       "Removed downloads from 1 server, freeing 800 MB.")
        XCTAssertEqual(SignedOutStorage.removalOutcome(serverCount: 2, freed: nil),
                       "Removed downloads from 2 servers.")
        XCTAssertTrue(SignedOutStorage.removalOutcome(serverCount: 0, freed: "1 GB").hasPrefix("Nothing to remove"))
    }

    func testAlertTitlesUseTitleCase() {
        XCTAssertEqual(RemoveAllDownloadsCopy.title, "Remove All Downloads?")
        XCTAssertEqual(SignedOutStorage.removeTitle, "Remove Downloads from Signed-Out Servers?")
    }
}
