import XCTest
import CarPlay
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 C1, C2, C3, C4, C6): the pure decisions behind the CarPlay
/// quick wins. The templates themselves need a live interface controller.
final class QuickWinsCarPlayTests: XCTestCase {

    // MARK: - Fixtures

    private func item(_ id: String, mediaType: String = "book") -> ShelfHead.LibraryItem {
        let metadata = MediaMetadata(
            title: id, subtitle: nil, authorName: nil, narratorName: nil,
            seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
            language: nil, genres: nil, isbn: nil, asin: nil, series: nil)
        let media = Media(
            metadata: metadata, coverPath: nil, duration: 3600, chapters: nil, audioFiles: nil,
            numChapters: nil, numAudioFiles: nil, episodes: nil, ebookFile: nil)
        return ShelfHead.LibraryItem(
            id: id, ino: nil, libraryId: nil, mediaType: mediaType, media: media,
            numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: nil)
    }

    private func library(_ id: String, mediaType: String?) -> Library {
        Library(id: id, name: id, mediaType: mediaType, icon: nil, folders: nil)
    }

    // MARK: - C1: Search row only on iOS 27+

    func testSearchRowLeftOutWhenTemplateUnsupported() {
        let state = CarPlayCoordinator.searchRowState(isSearchTemplateSupported: false, limitedUserInterfaces: [])
        XCTAssertFalse(state.include, "below iOS 27 an audio app can't use CPSearchTemplate, so the row is left out")
        XCTAssertFalse(state.enabled)
    }

    func testSearchRowLeftOutWhenUnsupportedEvenWithKeyboardLimit() {
        let state = CarPlayCoordinator.searchRowState(isSearchTemplateSupported: false, limitedUserInterfaces: .keyboard)
        XCTAssertFalse(state.include, "left out, not shown as 'Unavailable while driving'")
    }

    func testSearchRowLiveOnSupportedOSWithKeyboard() {
        let state = CarPlayCoordinator.searchRowState(isSearchTemplateSupported: true, limitedUserInterfaces: [])
        XCTAssertTrue(state.include)
        XCTAssertTrue(state.enabled)
    }

    func testSearchRowDisabledWhileDrivingOnSupportedOS() {
        let state = CarPlayCoordinator.searchRowState(isSearchTemplateSupported: true, limitedUserInterfaces: .keyboard)
        XCTAssertTrue(state.include, "on iOS 27+ the row stays, inert")
        XCTAssertFalse(state.enabled)
    }

    func testSearchTemplateSupportMatchesRunningOS() {
        if #available(iOS 27.0, *) {
            XCTAssertTrue(CarPlayCoordinator.isSearchTemplateSupported)
        } else {
            XCTAssertFalse(CarPlayCoordinator.isSearchTemplateSupported)
        }
    }

    // MARK: - C2: podcasts kept out of CarPlay

    func testPodcastLibrariesFilteredOut() {
        let libraries = [library("books", mediaType: "book"),
                         library("pods", mediaType: "podcast"),
                         library("legacy", mediaType: nil)]
        XCTAssertEqual(CarPlayCoordinator.carPlayBrowsableLibraries(libraries).map(\.id), ["books", "legacy"],
                       "a library with no mediaType (older servers) is still treated as books")
    }

    func testPodcastOnlyServerLeavesNoLibraries() {
        XCTAssertTrue(CarPlayCoordinator.carPlayBrowsableLibraries([library("pods", mediaType: "podcast")]).isEmpty)
    }

    func testPodcastItemsFilteredOut() {
        let items = [item("a"), item("show", mediaType: "podcast"), item("b")]
        XCTAssertEqual(CarPlayCoordinator.carPlayPlayableItems(items).map(\.id), ["a", "b"])
    }

    func testPodcastShelvesSkipped() {
        XCTAssertFalse(CarPlayCoordinator.isCarPlayBookShelf(type: "podcast"))
        XCTAssertTrue(CarPlayCoordinator.isCarPlayBookShelf(type: "book"))
        XCTAssertTrue(CarPlayCoordinator.isCarPlayBookShelf(type: nil))
    }

    // MARK: - C3: "Earlier…" paging

    func testFirstPageHasNoEarlierRowAndMatchesOldWindow() {
        let window = CarPlayCoordinator.pagedListWindow(total: 61, offset: 0, limit: 24)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertEqual(window.visible, 23)
        XCTAssertEqual(window.remaining, 38)
        let old = CarPlayCoordinator.listWindow(total: 61, offset: 0, limit: 24)
        XCTAssertEqual(window.visible, old.visible)
        XCTAssertEqual(window.remaining, old.remaining)
    }

    func testMiddlePageReservesBothRows() {
        let window = CarPlayCoordinator.pagedListWindow(total: 61, offset: 23, limit: 24)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertEqual(window.visible, 22, "24 slots minus Earlier… and Show more…")
        XCTAssertEqual(window.remaining, 16)
    }

    func testLastPageHasEarlierButNoMore() {
        let window = CarPlayCoordinator.pagedListWindow(total: 61, offset: 45, limit: 24)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertEqual(window.visible, 16)
        XCTAssertEqual(window.remaining, 0)
    }

    func testRowsNeverExceedLimit() {
        for total in 0...80 {
            var offset = 0
            var guardCount = 0
            repeat {
                let w = CarPlayCoordinator.pagedListWindow(total: total, offset: offset, limit: 24)
                let rows = w.visible + (w.hasEarlier ? 1 : 0) + (w.remaining > 0 ? 1 : 0)
                XCTAssertLessThanOrEqual(rows, 24, "total \(total) offset \(offset)")
                if w.remaining == 0 { break }
                XCTAssertGreaterThan(w.visible, 0)
                offset += w.visible
                guardCount += 1
            } while guardCount < 100
        }
    }

    func testPreviousPageOffsetWalksBackContiguously() {
        // Pages for 61 items at 24: starts 0, 23, 45.
        XCTAssertEqual(CarPlayCoordinator.previousPageOffset(before: 45, total: 61, limit: 24), 23)
        XCTAssertEqual(CarPlayCoordinator.previousPageOffset(before: 23, total: 61, limit: 24), 0)
        XCTAssertEqual(CarPlayCoordinator.previousPageOffset(before: 0, total: 61, limit: 24), 0)
    }

    func testPreviousPageOffsetIsInverseOfShowMore() {
        let total = 200, limit = 24
        var starts = [0]
        while true {
            let w = CarPlayCoordinator.pagedListWindow(total: total, offset: starts.last!, limit: limit)
            if w.remaining == 0 { break }
            starts.append(starts.last! + w.visible)
        }
        XCTAssertGreaterThan(starts.count, 2)
        for i in 1..<starts.count {
            XCTAssertEqual(CarPlayCoordinator.previousPageOffset(before: starts[i], total: total, limit: limit), starts[i - 1])
        }
    }

    func testPagedWindowZeroLimitAndEmpty() {
        let zero = CarPlayCoordinator.pagedListWindow(total: 10, offset: 0, limit: 0)
        XCTAssertEqual(zero.visible, 0)
        let empty = CarPlayCoordinator.pagedListWindow(total: 0, offset: 0, limit: 24)
        XCTAssertEqual(empty.visible, 0)
        XCTAssertEqual(empty.remaining, 0)
        XCTAssertFalse(empty.hasEarlier)
        XCTAssertEqual(CarPlayCoordinator.previousPageOffset(before: 5, total: 10, limit: 0), 0)
    }

    // MARK: - C4: no instruction to use the phone

    func testNotSignedInCopyStatesTheCondition() {
        let variants = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: false, isOnline: true, loadFailed: false)
        let text = (variants.title + variants.subtitle).joined(separator: " ")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("phone"),
                       "CarPlay copy must not ask the driver to use the phone")
    }

    // MARK: - C6: phone's Home names, hidden set and order

    func testNextInSeriesTitleMatchesPhone() {
        XCTAssertEqual(CarPlayCoordinator.homeShelfTitle(for: "LabelContinueSeries"),
                       String(localized: "Next in Series", comment: "Home shelf title"))
        XCTAssertNil(CarPlayCoordinator.homeShelfTitle(for: "LabelSomethingNew"))
    }

    func testHiddenShelvesAreDropped() {
        let shelves: [(key: String, header: String, items: [Int])] = [
            ("LabelRecentlyAdded", "Recently Added", [1]),
            ("LabelDiscover", "Discover", [2]),
            ("LabelListenAgain", "Listen Again", [3])
        ]
        let result = CarPlayCoordinator.phoneOrderedHomeShelves(
            shelves, hidden: ["LabelDiscover", "LabelListenAgain"], savedOrder: [])
        XCTAssertEqual(result.map(\.header), ["Recently Added"])
    }

    func testContinueListeningIsNeverHidden() {
        let shelves: [(key: String, header: String, items: [Int])] = [
            ("LabelContinueListening", "Continue Listening", [1]),
            ("LabelRecentlyAdded", "Recently Added", [2])
        ]
        let result = CarPlayCoordinator.phoneOrderedHomeShelves(
            shelves, hidden: ["LabelContinueListening"], savedOrder: [])
        XCTAssertEqual(result.map(\.header), ["Continue Listening", "Recently Added"])
    }

    func testSavedOrderIsFollowedAndNewShelvesAppend() {
        let shelves: [(key: String, header: String, items: [Int])] = [
            ("LabelRecentlyAdded", "Recently Added", [1]),
            ("LabelContinueSeries", "Next in Series", [2]),
            ("LabelDiscover", "Discover", [3])
        ]
        // The saved order also names phone-only keys (Downloaded, B-Side); they are ignored.
        let result = CarPlayCoordinator.phoneOrderedHomeShelves(
            shelves, hidden: [],
            savedOrder: ["downloadedOffline", "LabelContinueSeries", "bSideShuffle", "LabelRecentlyAdded"])
        XCTAssertEqual(result.map(\.header), ["Next in Series", "Recently Added", "Discover"])
        XCTAssertEqual(result.map(\.items), [[2], [1], [3]])
    }

    func testContinueListeningStaysFirstAfterPromotion() {
        // The phone's saved order may put Continue Listening anywhere; publishHome's
        // promotion step still puts it first in the car.
        let shelves: [(key: String, header: String, items: [Int])] = [
            ("LabelRecentlyAdded", "Recently Added", [1]),
            ("LabelContinueListening", String(localized: "Continue Listening"), [2])
        ]
        let ordered = CarPlayCoordinator.phoneOrderedHomeShelves(
            shelves, hidden: [], savedOrder: ["LabelRecentlyAdded", "LabelContinueListening"])
        let promoted = CarPlayCoordinator.promotingContinueListening(ordered)
        XCTAssertEqual(promoted.first?.items, [2])
    }
}
