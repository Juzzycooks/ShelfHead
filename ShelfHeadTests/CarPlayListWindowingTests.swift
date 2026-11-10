import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • CarPlayListWindowingTests
// =============================================================================
//
// C2/C3/C12 (REVIEW_2026-09-04_UI.md Pass 4): pins the pure windowing/ordering/
// display-text functions extracted out of `CarPlayCoordinator` so the browse-list
// cap (C2), the chapter-list windowing (C3), the Downloads reorder (C2), and the
// blank-chapter-title fallback (C12) can be verified without a live
// `CPListTemplate`/`CPInterfaceController` — this project's extract-a-pure-function
// precedent (e.g. `DownloadManager.shouldReclaimOrphanDirectory`), same shape as the
// existing `CarPlayAlertCopyTests` (C4). All the functions under test are marked
// `nonisolated` on `CarPlayCoordinator` (a `@MainActor` type), so they're callable
// here directly, with no `await`/`@MainActor` needed — the actual presentation path
// (`applyWindowedItems`, `renderChapterWindow`, `pushChapters`, …) isn't unit-tested,
// since it needs a live interface controller.
final class CarPlayListWindowingTests: XCTestCase {

    // MARK: - listWindow (C2)

    func testListWindowShowsEverythingWhenUnderTheLimit() {
        let window = CarPlayCoordinator.listWindow(total: 10, offset: 0, limit: 24)
        XCTAssertEqual(window.visible, 10)
        XCTAssertEqual(window.remaining, 0)
    }

    func testListWindowShowsEverythingWhenExactlyAtTheLimit() {
        // Exactly `limit` items fit with nothing left over — no reason to reserve a
        // "Show more" slot for zero remaining items.
        let window = CarPlayCoordinator.listWindow(total: 24, offset: 0, limit: 24)
        XCTAssertEqual(window.visible, 24)
        XCTAssertEqual(window.remaining, 0)
    }

    func testListWindowReservesOneSlotForShowMoreWhenOverTheLimit() {
        // 61 downloads, capped at 24: 23 real rows + 1 "Show more" row = 24 on screen,
        // 38 left for the next page. This is the Downloads-tab scenario from C2's
        // review text almost exactly (61 downloads, 24-item cap).
        let window = CarPlayCoordinator.listWindow(total: 61, offset: 0, limit: 24)
        XCTAssertEqual(window.visible, 23)
        XCTAssertEqual(window.remaining, 38)
        // The "Show more" row is chrome, not an item: visible + remaining must account
        // for every book exactly once. (Integration fix, build 29: this asserted
        // `visible + 1 + remaining == 61`, which double-counted the chrome row.)
        XCTAssertEqual(window.visible + window.remaining, 61, "visible rows + remaining should account for every item")
    }

    func testListWindowPagesFromANonZeroOffset() {
        // Second page of the 61-item case above: 61 - 23 = 38 left, still over the
        // limit, so another "Show more" row is reserved.
        let window = CarPlayCoordinator.listWindow(total: 61, offset: 23, limit: 24)
        XCTAssertEqual(window.visible, 23)
        XCTAssertEqual(window.remaining, 15)
    }

    func testListWindowFinalPageShowsEverythingLeftWithNoShowMoreRow() {
        // Third page: 61 - 23 - 23 = 15 left, under the limit — no more "Show more" row.
        let window = CarPlayCoordinator.listWindow(total: 61, offset: 46, limit: 24)
        XCTAssertEqual(window.visible, 15)
        XCTAssertEqual(window.remaining, 0)
    }

    func testListWindowOffsetAtOrPastTotalShowsNothing() {
        let atEnd = CarPlayCoordinator.listWindow(total: 10, offset: 10, limit: 24)
        XCTAssertEqual(atEnd.visible, 0)
        XCTAssertEqual(atEnd.remaining, 0)

        let pastEnd = CarPlayCoordinator.listWindow(total: 10, offset: 50, limit: 24)
        XCTAssertEqual(pastEnd.visible, 0)
        XCTAssertEqual(pastEnd.remaining, 0)
    }

    func testListWindowZeroOrNegativeLimitShowsNothingRatherThanCrashing() {
        // Defensive: `CPListTemplate.maximumItemCount` is always positive on real
        // hardware, but this must not crash/underflow if it were ever 0.
        let window = CarPlayCoordinator.listWindow(total: 10, offset: 0, limit: 0)
        XCTAssertEqual(window.visible, 0)
        XCTAssertEqual(window.remaining, 10)
    }

    func testListWindowEmptyListShowsNothing() {
        let window = CarPlayCoordinator.listWindow(total: 0, offset: 0, limit: 24)
        XCTAssertEqual(window.visible, 0)
        XCTAssertEqual(window.remaining, 0)
    }

    // MARK: - chapterWindow (C3)

    func testChapterWindowShowsEverythingWhenBookHasFewerChaptersThanTheLimit() {
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 10, currentIndex: 3, limit: 24)
        XCTAssertEqual(window.startIndex, 0)
        XCTAssertEqual(window.endIndex, 10)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
    }

    func testChapterWindowShowsEverythingWhenChapterCountExactlyEqualsTheLimit() {
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 24, currentIndex: 12, limit: 24)
        XCTAssertEqual(window.startIndex, 0)
        XCTAssertEqual(window.endIndex, 24)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
    }

    func testChapterWindowOnFirstChapterOfALongBookHasNoEarlierRow() {
        // The review's own scenario shape: a 90-chapter LitRPG serial. Sitting on
        // chapter 0, there is nothing "earlier" to page back to.
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 90, currentIndex: 0, limit: 24)
        XCTAssertEqual(window.startIndex, 0)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
        XCTAssertTrue((window.startIndex..<window.endIndex).contains(0), "the current chapter must always be inside its own window")
    }

    func testChapterWindowOnLastChapterOfALongBookHasNoLaterRow() {
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 90, currentIndex: 89, limit: 24)
        XCTAssertEqual(window.endIndex, 90)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
        XCTAssertTrue((window.startIndex..<window.endIndex).contains(89), "the current chapter must always be inside its own window")
    }

    func testChapterWindowInTheMiddleOfALongBookHasBothNavigationRows() {
        // The review's exact real-world case: chapter ~40 of a 90-chapter book (11
        // hours into a 21-hour audiobook) used to open on chapters 1-24, with the
        // current chapter never built at all.
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 90, currentIndex: 39, limit: 24)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
        XCTAssertTrue((window.startIndex..<window.endIndex).contains(39), "the current chapter must always be inside its own window")
        // Biased toward chapters ahead: at least as many chapters after the current
        // one as before it.
        let behindCount = 39 - window.startIndex
        let aheadCount = window.endIndex - 1 - 39
        XCTAssertLessThanOrEqual(behindCount, 4)
        XCTAssertGreaterThan(aheadCount, behindCount)
    }

    func testChapterWindowWithNoCurrentChapterFallsBackToTheStart() {
        // Nothing playing, or the current time didn't match any chapter — the old
        // behavior (start at 0) is the sane fallback since there's no "current" to
        // center on.
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 90, currentIndex: nil, limit: 24)
        XCTAssertEqual(window.startIndex, 0)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
    }

    func testChapterWindowCurrentIndexIsAlwaysInsideTheWindowAcrossASpread() {
        // General invariant, checked across a spread of positions rather than one
        // hand-picked value: whatever `chapterWindow` decides, the chapter the driver
        // is actually on must be on screen.
        let chapterCount = 87
        let limit = 24
        for current in stride(from: 0, to: chapterCount, by: 5) {
            let window = CarPlayCoordinator.chapterWindow(chapterCount: chapterCount, currentIndex: current, limit: limit)
            XCTAssertTrue((window.startIndex..<window.endIndex).contains(current),
                          "current chapter \(current) must be inside window \(window.startIndex)..<\(window.endIndex)")
            XCTAssertGreaterThanOrEqual(window.startIndex, 0)
            XCTAssertLessThanOrEqual(window.endIndex, chapterCount)
        }
    }

    func testChapterWindowOutOfRangeCurrentIndexIsClamped() {
        // Defensive: a stale/out-of-range index shouldn't crash the slicing math.
        let tooHigh = CarPlayCoordinator.chapterWindow(chapterCount: 30, currentIndex: 999, limit: 24)
        XCTAssertTrue((tooHigh.startIndex..<tooHigh.endIndex).contains(29))

        let negative = CarPlayCoordinator.chapterWindow(chapterCount: 30, currentIndex: -5, limit: 24)
        XCTAssertTrue((negative.startIndex..<negative.endIndex).contains(0))
    }

    func testChapterWindowWithNoChaptersIsEmpty() {
        let window = CarPlayCoordinator.chapterWindow(chapterCount: 0, currentIndex: nil, limit: 24)
        XCTAssertEqual(window.startIndex, 0)
        XCTAssertEqual(window.endIndex, 0)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
    }

    // MARK: - chapterPage (item 17: "Earlier chapters…" paging bug)

    func testChapterPageForwardStartsExactlyWhereThePreviousPageEnded() {
        // 90 chapters, limit 24, sitting on chapter 0: `chapterWindow` gives (0, 23,
        // hasEarlier: false, hasLater: true) — see
        // `testChapterWindowOnFirstChapterOfALongBookHasNoEarlierRow`. Paging "Later"
        // from there must start the next page at exactly `endIndex` (23), not some
        // recentered index nudged by the old `behind = 4` trick.
        let page = CarPlayCoordinator.chapterPage(chapterCount: 90, anchorIndex: 23, limit: 24, forward: true)
        XCTAssertEqual(page.startIndex, 23, "forward paging must start exactly where the previous page ended, with no gap or overlap")
        XCTAssertTrue(page.hasEarlier)
    }

    func testChapterPageBackwardEndsExactlyWhereThePageItWasPagedFromStarted() {
        // The bug (item 17): the old logic moved backward by a fixed 5 chapters no
        // matter how wide the page was. Paging "Earlier" must instead end the new page
        // exactly at the OLD page's own `startIndex`.
        let page = CarPlayCoordinator.chapterPage(chapterCount: 90, anchorIndex: 23, limit: 24, forward: false)
        XCTAssertEqual(page.endIndex, 23, "backward paging must end exactly where the page it was paged from started")
    }

    func testChapterPageForwardThenBackwardReturnsToTheExactOriginalPage() {
        // Round trip: paging Later then Earlier from the result must land back on the
        // exact page you started from — the core "contiguous, no gap, no overlap,
        // same size both directions" property item 17 asks for.
        let chapterCount = 90
        let limit = 24
        let original = CarPlayCoordinator.chapterWindow(chapterCount: chapterCount, currentIndex: 0, limit: limit)
        let forward = CarPlayCoordinator.chapterPage(chapterCount: chapterCount, anchorIndex: original.endIndex, limit: limit, forward: true)
        let back = CarPlayCoordinator.chapterPage(chapterCount: chapterCount, anchorIndex: forward.startIndex, limit: limit, forward: false)
        XCTAssertEqual(back.startIndex, original.startIndex)
        XCTAssertEqual(back.endIndex, original.endIndex)
        XCTAssertEqual(back.hasEarlier, original.hasEarlier)
        XCTAssertEqual(back.hasLater, original.hasLater)
    }

    func testChapterPageForwardAndBackwardAdvanceByTheSamePageSize() {
        // The exact regression this item fixes: before, backward paging moved by a
        // fixed 5 chapters while forward moved by a different, width-dependent amount.
        // From a middle page with both nav rows reserved, a page in either direction
        // should show the same number of real chapter rows: `limit` minus however many
        // nav rows THAT page itself needs.
        let chapterCount = 90
        let limit = 24
        let middle = CarPlayCoordinator.chapterPage(chapterCount: chapterCount, anchorIndex: 40, limit: limit, forward: true)
        XCTAssertTrue(middle.hasEarlier)
        XCTAssertTrue(middle.hasLater)
        let forwardWidth = middle.endIndex - middle.startIndex
        let nextForward = CarPlayCoordinator.chapterPage(chapterCount: chapterCount, anchorIndex: middle.endIndex, limit: limit, forward: true)
        let backward = CarPlayCoordinator.chapterPage(chapterCount: chapterCount, anchorIndex: middle.startIndex, limit: limit, forward: false)
        XCTAssertEqual(forwardWidth, limit - 2, "both nav rows are reserved mid-book, so the visible width is limit - 2")
        XCTAssertEqual(nextForward.endIndex - nextForward.startIndex, backward.endIndex - backward.startIndex,
                       "forward and backward paging must advance by the same page size")
    }

    func testChapterPageForwardFromTheLastPageHasNoLaterRow() {
        // Anchored exactly at the end of the book: there is nothing later to page to.
        let page = CarPlayCoordinator.chapterPage(chapterCount: 90, anchorIndex: 67, limit: 24, forward: true)
        XCTAssertEqual(page.endIndex, 90)
        XCTAssertFalse(page.hasLater)
        XCTAssertTrue(page.hasEarlier)
    }

    func testChapterPageBackwardToTheFirstPageHasNoEarlierRow() {
        // Anchored exactly at the start of the book: there is nothing earlier to page to.
        let page = CarPlayCoordinator.chapterPage(chapterCount: 90, anchorIndex: 0, limit: 24, forward: false)
        XCTAssertEqual(page.startIndex, 0)
        XCTAssertFalse(page.hasEarlier)
    }

    func testChapterPageOutOfRangeAnchorIsClamped() {
        // Defensive: a stale/out-of-range anchor shouldn't crash the slicing math.
        let tooHigh = CarPlayCoordinator.chapterPage(chapterCount: 30, anchorIndex: 999, limit: 24, forward: true)
        XCTAssertLessThanOrEqual(tooHigh.endIndex, 30)
        XCTAssertGreaterThanOrEqual(tooHigh.startIndex, 0)

        let negative = CarPlayCoordinator.chapterPage(chapterCount: 30, anchorIndex: -5, limit: 24, forward: false)
        XCTAssertGreaterThanOrEqual(negative.startIndex, 0)
        XCTAssertLessThanOrEqual(negative.endIndex, 30)
    }

    func testChapterPageWhenBookFitsInOneScreenShowsEverythingWithNoNavigationRows() {
        let forward = CarPlayCoordinator.chapterPage(chapterCount: 10, anchorIndex: 5, limit: 24, forward: true)
        XCTAssertEqual(forward.startIndex, 0)
        XCTAssertEqual(forward.endIndex, 10)
        XCTAssertFalse(forward.hasEarlier)
        XCTAssertFalse(forward.hasLater)
    }

    // MARK: - chapterDisplayTitle (C12)

    func testChapterDisplayTitleFallsBackWhenTitleIsBlank() {
        let chapter = Chapter.testFixture(id: 5, start: 100, end: 200, title: "")
        XCTAssertEqual(CarPlayCoordinator.chapterDisplayTitle(chapter), "Chapter 6")
    }

    func testChapterDisplayTitleFallsBackWhenTitleIsWhitespaceOnly() {
        let chapter = Chapter.testFixture(id: 0, start: 0, end: 100, title: "   ")
        XCTAssertEqual(CarPlayCoordinator.chapterDisplayTitle(chapter), "Chapter 1")
    }

    func testChapterDisplayTitlePreservesARealTitleUnchanged() {
        let chapter = Chapter.testFixture(id: 62, start: 100, end: 200, title: "63. Something Incredibly Questionable")
        XCTAssertEqual(CarPlayCoordinator.chapterDisplayTitle(chapter), "63. Something Incredibly Questionable")
    }

    // MARK: - orderedDownloadsForCarPlay (C2)

    func testOrderedDownloadsForCarPlaySortsMostRecentProgressFirst() {
        let old = LibraryItem.testFixture(title: "Alpha", lastUpdate: 1_000)
        let recent = LibraryItem.testFixture(title: "Zulu", lastUpdate: 5_000)
        let ordered = CarPlayCoordinator.orderedDownloadsForCarPlay([old, recent])
        XCTAssertEqual(ordered.map(\.title), ["Zulu", "Alpha"], "the more recently updated book should sort first even though its title sorts later")
    }

    func testOrderedDownloadsForCarPlayPutsNeverPlayedBooksLast() {
        let inProgress = LibraryItem.testFixture(title: "Zulu", lastUpdate: 1)
        let neverPlayed = LibraryItem.testFixture(title: "Alpha", lastUpdate: nil)
        let ordered = CarPlayCoordinator.orderedDownloadsForCarPlay([neverPlayed, inProgress])
        XCTAssertEqual(ordered.map(\.title), ["Zulu", "Alpha"], "a book with any progress at all should sort ahead of one that's never been opened")
    }

    func testOrderedDownloadsForCarPlayBreaksTiesByTitle() {
        let a = LibraryItem.testFixture(title: "Beta", lastUpdate: nil)
        let b = LibraryItem.testFixture(title: "Alpha", lastUpdate: nil)
        let ordered = CarPlayCoordinator.orderedDownloadsForCarPlay([a, b])
        XCTAssertEqual(ordered.map(\.title), ["Alpha", "Beta"])
    }

    func testOrderedDownloadsForCarPlayIsStableAndDoesNotDropBooks() {
        let items = (0..<10).map { LibraryItem.testFixture(title: "Book \($0)", lastUpdate: $0 % 3 == 0 ? nil : $0) }
        let ordered = CarPlayCoordinator.orderedDownloadsForCarPlay(items)
        XCTAssertEqual(Set(ordered.map(\.title)), Set(items.map(\.title)), "reordering must not drop or duplicate any book")
        XCTAssertEqual(ordered.count, items.count)
    }

    // MARK: - capShelvesToSystemLimit (item 18: cap before building rows/fetching covers)

    func testCapShelvesToSystemLimitKeepsEverythingUnderBothCeilings() {
        let shelves: [(header: String, items: [Int])] = [
            (header: "Continue Listening", items: [1, 2, 3]),
            (header: "Recently Added", items: [4, 5])
        ]
        let capped = CarPlayCoordinator.capShelvesToSystemLimit(shelves, maxSections: 5, maxItems: 20)
        XCTAssertEqual(capped.map { $0.header }, ["Continue Listening", "Recently Added"])
        XCTAssertEqual(capped.map { $0.items }, [[1, 2, 3], [4, 5]])
    }

    func testCapShelvesToSystemLimitTruncatesTheShelfThatCrossesTheItemCeilingAndDropsWhatFollows() {
        // Mirrors `capItemCount`'s doc: the item ceiling is TOTAL across every
        // section, not per section — a later shelf can be cut short or dropped
        // entirely once the running total is spent, but everything BEFORE that point
        // stays intact (earlier shelves — Continue Listening first — always win).
        let shelves: [(header: String, items: [Int])] = [
            (header: "Continue Listening", items: [1, 2, 3, 4, 5]),
            (header: "Recently Added", items: [6, 7, 8, 9, 10]),
            (header: "Discover", items: [11, 12])
        ]
        let capped = CarPlayCoordinator.capShelvesToSystemLimit(shelves, maxSections: 5, maxItems: 8)
        XCTAssertEqual(capped.map { $0.header }, ["Continue Listening", "Recently Added"])
        XCTAssertEqual(capped[0].items, [1, 2, 3, 4, 5], "the first shelf fits entirely and must not be touched")
        XCTAssertEqual(capped[1].items, [6, 7, 8], "the shelf that crosses the ceiling is truncated to what's left, not dropped outright")
        XCTAssertEqual(capped.reduce(0) { $0 + $1.items.count }, 8, "total items across every kept shelf must never exceed the item ceiling")
    }

    func testCapShelvesToSystemLimitDropsShelvesPastTheSectionCeilingEvenWithItemBudgetToSpare() {
        // C9's exact scenario: small shelves can sum well under the item budget while
        // still exceeding the SEPARATE section-count ceiling.
        let shelves: [(header: String, items: [Int])] = [
            (header: "A", items: [1]), (header: "B", items: [2]), (header: "C", items: [3]),
            (header: "D", items: [4]), (header: "E", items: [5])
        ]
        let capped = CarPlayCoordinator.capShelvesToSystemLimit(shelves, maxSections: 3, maxItems: 100)
        XCTAssertEqual(capped.map { $0.header }, ["A", "B", "C"])
    }

    func testCapShelvesToSystemLimitPreservesShelfOrder() {
        let shelves: [(header: String, items: [Int])] = [
            (header: "First", items: [1]), (header: "Second", items: [2]), (header: "Third", items: [3])
        ]
        let capped = CarPlayCoordinator.capShelvesToSystemLimit(shelves, maxSections: 10, maxItems: 100)
        XCTAssertEqual(capped.map { $0.header }, ["First", "Second", "Third"], "shown shelves must keep the same order they were built in")
    }

    func testCapShelvesToSystemLimitWithNothingOverEitherCeilingReturnsEveryShelfUnchanged() {
        let shelves: [(header: String, items: [Int])] = [(header: "Only", items: [1, 2, 3])]
        let capped = CarPlayCoordinator.capShelvesToSystemLimit(shelves, maxSections: 1, maxItems: 3)
        XCTAssertEqual(capped.count, 1)
        XCTAssertEqual(capped[0].items, [1, 2, 3])
    }

    func testCapShelvesToSystemLimitZeroItemCeilingDropsEverything() {
        let shelves: [(header: String, items: [Int])] = [(header: "Only", items: [1, 2, 3])]
        let capped = CarPlayCoordinator.capShelvesToSystemLimit(shelves, maxSections: 5, maxItems: 0)
        XCTAssertTrue(capped.isEmpty)
    }
}

// MARK: - Test fixtures

private extension Chapter {
    /// `Chapter`'s memberwise fields are all `let` with a custom `Codable`
    /// initializer (to tolerate a missing title) and no public memberwise
    /// initializer — round-trips through JSON instead, same approach as
    /// `TrackTimelineTests.swift`'s own private `Chapter.testFixture`.
    static func testFixture(id: Int, start: Double, end: Double, title: String) -> Chapter {
        let json: [String: Any] = ["id": id, "start": start, "end": end, "title": title]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Chapter.self, from: data)
    }
}

// Module-qualified: unqualified `LibraryItem` was reported ambiguous for type lookup
// in this file by the iOS 26 toolchain (build 29 integration); the app type is meant.
private extension ShelfHead.LibraryItem {
    /// `LibraryItem` (unlike `Chapter`) has no custom `init(from decoder:)` of its
    /// own, so Swift synthesizes both `Decodable` and the ordinary memberwise
    /// initializer — the same one `DownloadedBook.asLibraryItem()` uses in the app
    /// itself, mirrored here rather than round-tripping through JSON.
    static func testFixture(title: String, lastUpdate: Int?) -> ShelfHead.LibraryItem {
        let metadata = MediaMetadata(
            title: title, subtitle: nil, authorName: nil, narratorName: nil,
            seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
            language: nil, genres: nil, isbn: nil, asin: nil, series: nil
        )
        let media = Media(
            metadata: metadata, coverPath: nil, duration: 3600, chapters: nil, audioFiles: nil,
            numChapters: nil, numAudioFiles: nil, episodes: nil, ebookFile: nil
        )
        let progress = MediaProgress(
            id: title, libraryItemId: title, episodeId: nil, duration: 3600, progress: 0,
            currentTime: 0, isFinished: false, lastUpdate: lastUpdate, startedAt: nil, finishedAt: nil
        )
        return LibraryItem(
            id: title, ino: nil, libraryId: nil, mediaType: "book", media: media,
            numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: progress
        )
    }
}
