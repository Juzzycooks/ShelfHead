import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (shape → distill): pins the pure decisions behind the drill-down
/// pages' primary actions — the Series hero (target, state, label, progress line), the
/// Collections / Playlists Play in Order plan and copy, the Author / Narrator sort orders
/// and header, the star toggle's spoken label, and All Bookmarks' export scopes,
/// "plays instead" note and lookup order.
@MainActor
final class DrillDownActionsTests: XCTestCase {

    // MARK: - Fixtures

    private func book(_ id: String, title: String, year: String? = nil, addedAt: Int? = nil,
                      seriesName: String? = nil, series: String? = nil, sequence: String? = nil) throws -> ShelfHead.LibraryItem {
        var meta = #""title": "\#(title)""#
        if let year { meta += #", "publishedYear": "\#(year)""# }
        if let seriesName { meta += #", "seriesName": "\#(seriesName)""# }
        if let series {
            let seq = sequence.map { #", "sequence": "\#($0)""# } ?? ""
            meta += #", "series": [{"id": "s-\#(series)", "name": "\#(series)"\#(seq)}]"#
        }
        let added = addedAt.map { #", "addedAt": \#($0)"# } ?? ""
        let json = #"""
        {"id": "\#(id)", "mediaType": "book"\#(added),
         "media": {"metadata": {\#(meta)}, "duration": 3600, "numAudioFiles": 1}}
        """#
        return try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }

    // MARK: - Series hero

    private let ids = ["b1", "b2", "b3", "b4"]

    func testNothingHeardStartsTheSeries() {
        let plan = SeriesDetailView.heroPlan(orderedIds: ids, finished: [], started: [], loadedId: nil, isPlaying: false)
        XCTAssertEqual(plan, SeriesDetailView.SeriesHeroPlan(targetId: "b1", state: .start))
    }

    func testContinuesAtEarliestUnfinished() {
        let plan = SeriesDetailView.heroPlan(orderedIds: ids, finished: ["b1", "b2", "b3"], started: [],
                                             loadedId: nil, isPlaying: false)
        XCTAssertEqual(plan, SeriesDetailView.SeriesHeroPlan(targetId: "b4", state: .continueAt))
        // A skipped earlier book is still the earliest unfinished (existing rule).
        let gap = SeriesDetailView.heroPlan(orderedIds: ids, finished: ["b1", "b3"], started: [],
                                            loadedId: nil, isPlaying: false)
        XCTAssertEqual(gap, SeriesDetailView.SeriesHeroPlan(targetId: "b2", state: .continueAt))
    }

    func testStartedButNothingFinishedIsContinue() {
        let plan = SeriesDetailView.heroPlan(orderedIds: ids, finished: [], started: ["b1"], loadedId: nil, isPlaying: false)
        XCTAssertEqual(plan, SeriesDetailView.SeriesHeroPlan(targetId: "b1", state: .continueAt))
    }

    func testLoadedUnfinishedBookFromThisSeriesWins() {
        let paused = SeriesDetailView.heroPlan(orderedIds: ids, finished: ["b1"], started: ["b3"],
                                               loadedId: "b3", isPlaying: false)
        XCTAssertEqual(paused, SeriesDetailView.SeriesHeroPlan(targetId: "b3", state: .resume))
        let playing = SeriesDetailView.heroPlan(orderedIds: ids, finished: ["b1"], started: ["b3"],
                                                loadedId: "b3", isPlaying: true)
        XCTAssertEqual(playing, SeriesDetailView.SeriesHeroPlan(targetId: "b3", state: .pause))
    }

    func testLoadedBookFromAnotherSeriesDoesNotChangeTheTarget() {
        let plan = SeriesDetailView.heroPlan(orderedIds: ids, finished: ["b1"], started: [],
                                             loadedId: "other", isPlaying: true)
        XCTAssertEqual(plan, SeriesDetailView.SeriesHeroPlan(targetId: "b2", state: .continueAt))
    }

    func testAllFinishedListensAgainFromTheFirst() {
        let all = Set(ids)
        XCTAssertEqual(SeriesDetailView.heroPlan(orderedIds: ids, finished: all, started: [], loadedId: nil, isPlaying: false),
                       SeriesDetailView.SeriesHeroPlan(targetId: "b1", state: .listenAgain))
        // Re-listening to book 1 already: it's loaded, so Resume / Pause.
        XCTAssertEqual(SeriesDetailView.heroPlan(orderedIds: ids, finished: all, started: [], loadedId: "b1", isPlaying: true),
                       SeriesDetailView.SeriesHeroPlan(targetId: "b1", state: .pause))
    }

    func testEmptySeriesHasNoHero() {
        XCTAssertNil(SeriesDetailView.heroPlan(orderedIds: [], finished: [], started: [], loadedId: nil, isPlaying: false))
    }

    func testHeroButtonLabels() {
        XCTAssertEqual(SeriesDetailView.heroButtonLabel(.start, sequenceText: "1"), "Start Series")
        XCTAssertEqual(SeriesDetailView.heroButtonLabel(.continueAt, sequenceText: "4"), "Continue \u{00B7} Book 4")
        XCTAssertEqual(SeriesDetailView.heroButtonLabel(.continueAt, sequenceText: nil), "Continue Series")
        XCTAssertEqual(SeriesDetailView.heroButtonLabel(.resume, sequenceText: "2.5"), "Resume \u{00B7} Book 2.5")
        XCTAssertEqual(SeriesDetailView.heroButtonLabel(.pause, sequenceText: nil), "Pause")
        XCTAssertEqual(SeriesDetailView.heroButtonLabel(.listenAgain, sequenceText: "1"), "Listen Again")
    }

    func testSeriesProgressText() {
        XCTAssertEqual(SeriesDetailView.progressText(finished: 3, total: 7), "3 of 7 finished")
        XCTAssertEqual(SeriesDetailView.progressText(finished: 0, total: 7), "7 books")
        XCTAssertEqual(SeriesDetailView.progressText(finished: 0, total: 1), "1 book")
        XCTAssertEqual(SeriesDetailView.progressText(finished: 7, total: 7), "All 7 finished")
        XCTAssertEqual(SeriesDetailView.progressText(finished: 1, total: 1), "Finished")
        XCTAssertEqual(SeriesDetailView.progressText(finished: 0, total: 0), "No books yet")
    }

    // MARK: - Play in Order

    func testPlayInOrderStartsAtFirstUnfinishedAndQueuesUnfinishedAfterIt() {
        let plan = BookCollectionDetailView.playInOrderPlan(
            orderedIds: ["a", "b", "c", "d", "e"], playable: ["a", "b", "c", "d", "e"], finished: ["a", "d"])
        XCTAssertEqual(plan, BookCollectionDetailView.PlayInOrderPlan(startId: "b", queueIds: ["c", "e"]))
    }

    func testPlayInOrderAllFinishedStartsOverFromTheTop() {
        let plan = BookCollectionDetailView.playInOrderPlan(
            orderedIds: ["a", "b", "c"], playable: ["a", "b", "c"], finished: ["a", "b", "c"])
        XCTAssertEqual(plan, BookCollectionDetailView.PlayInOrderPlan(startId: "a", queueIds: ["b", "c"]))
    }

    func testPlayInOrderSkipsUnplayableAndRepeats() {
        let plan = BookCollectionDetailView.playInOrderPlan(
            orderedIds: ["pod", "a", "a", "b"], playable: ["a", "b"], finished: [])
        XCTAssertEqual(plan, BookCollectionDetailView.PlayInOrderPlan(startId: "a", queueIds: ["b"]))
        XCTAssertNil(BookCollectionDetailView.playInOrderPlan(orderedIds: ["pod"], playable: [], finished: []))
    }

    func testPlayInOrderCaption() {
        XCTAssertEqual(BookCollectionDetailView.playInOrderCaption(startTitle: "Dune", queuedCount: 0, loadedTitle: nil),
                       "Starts with Dune.")
        XCTAssertEqual(BookCollectionDetailView.playInOrderCaption(startTitle: "Dune", queuedCount: 4, loadedTitle: nil),
                       "Starts with Dune, then 4 more in Up Next.")
        XCTAssertEqual(BookCollectionDetailView.playInOrderCaption(startTitle: "Dune", queuedCount: 1, loadedTitle: "Emma"),
                       "Starts with Dune, then 1 more in Up Next. Plays this book instead of Emma.")
    }

    func testCollectionSummary() {
        XCTAssertEqual(BookCollectionDetailView.summaryText(count: 1, totalDuration: 0, isPlaylist: false), "1 book")
        XCTAssertEqual(BookCollectionDetailView.summaryText(count: 3, totalDuration: 30, isPlaylist: true), "3 items")
        let withTime = BookCollectionDetailView.summaryText(count: 6, totalDuration: 7200, isPlaylist: false)
        XCTAssertEqual(withTime, "6 books \u{00B7} \(Double(7200).formattedDuration)")
    }

    // MARK: - Author / Narrator sort

    func testTitleSortIsFinderStyle() throws {
        let items = [try book("x", title: "Book 10"), try book("y", title: "book 2"), try book("z", title: "Alpha")]
        XCTAssertEqual(BookDrillDownSort.sorted(items, by: .title).map(\.id), ["z", "y", "x"])
    }

    func testNewestSortUsesYearThenAddedWithUnknownYearsLast() throws {
        let items = [
            try book("old", title: "Old", year: "1999"),
            try book("none", title: "None", addedAt: 9_999),
            try book("new", title: "New", year: "2021-05-01"),
            try book("newer-add", title: "Same Year", year: "2021", addedAt: 500),
        ]
        XCTAssertEqual(BookDrillDownSort.sorted(items, by: .newest).map(\.id), ["newer-add", "new", "old", "none"])
    }

    func testSeriesSortGroupsBySeriesInSequenceWithStandaloneLast() throws {
        let items = [
            try book("solo", title: "Solo"),
            try book("m2", title: "Well", series: "Mistborn", sequence: "2"),
            try book("a1", title: "Zed", seriesName: "Alpha #1"),
            try book("m1", title: "Final", series: "Mistborn", sequence: "1"),
            try book("m10", title: "Later", series: "Mistborn", sequence: "10"),
        ]
        XCTAssertEqual(BookDrillDownSort.sorted(items, by: .series).map(\.id), ["a1", "m1", "m2", "m10", "solo"])
    }

    func testSeriesKeyStripsTheDisplayNumber() throws {
        XCTAssertEqual(BookDrillDownSort.seriesKey(try book("a", title: "A", seriesName: "The Expanse #3")), "The Expanse")
        XCTAssertEqual(BookDrillDownSort.seriesKey(try book("b", title: "B", series: "Dune", sequence: "1")), "Dune")
        XCTAssertNil(BookDrillDownSort.seriesKey(try book("c", title: "C")))
    }

    func testPersonHeaderCount() throws {
        let items = [
            try book("a", title: "A", series: "Dune", sequence: "1"),
            try book("b", title: "B", seriesName: "Dune #2"),
            try book("c", title: "C"),
        ]
        XCTAssertEqual(BookDrillDownSort.countText(books: items), "3 books \u{00B7} 1 series")
        XCTAssertEqual(BookDrillDownSort.countText(books: [try book("c", title: "C")]), "1 book")
    }

    func testStarToggleLabelMatchesTheUI() {
        XCTAssertEqual(BrowseStarredSections.toggleLabel(isStarred: false), "Star")
        XCTAssertEqual(BrowseStarredSections.toggleLabel(isStarred: true), "Starred")
        XCTAssertEqual(NarratorsBrowseView.rowAccessibilityLabel(name: "N", isFavorite: true), "N, Starred")
    }

    // MARK: - All Bookmarks

    func testExportScopes() {
        XCTAssertEqual(AllBookmarksView.exportScopes(shownCount: 5, totalCount: 5), [.all])
        XCTAssertEqual(AllBookmarksView.exportScopes(shownCount: 2, totalCount: 5), [.shown, .all])
        XCTAssertEqual(AllBookmarksView.exportScopes(shownCount: 0, totalCount: 5), [.all])
        XCTAssertEqual(AllBookmarksView.exportScopes(shownCount: 0, totalCount: 0), [])
        XCTAssertEqual(AllBookmarksView.exportTitle(.shown, shownCount: 2, totalCount: 5), "Export Shown (2)")
        XCTAssertEqual(AllBookmarksView.exportTitle(.all, shownCount: 2, totalCount: 5), "Export All (5)")
    }

    func testPlaysInsteadHeader() {
        XCTAssertNil(AllBookmarksView.playsInsteadHeader(loadedId: nil, loadedTitle: nil, bookmarkItemIds: ["a"]))
        XCTAssertNil(AllBookmarksView.playsInsteadHeader(loadedId: "a", loadedTitle: "Emma", bookmarkItemIds: ["a", "a"]))
        XCTAssertEqual(AllBookmarksView.playsInsteadHeader(loadedId: "a", loadedTitle: "Emma", bookmarkItemIds: ["a", "b"]),
                       "Bookmarks from other books play instead of Emma.")
        XCTAssertNil(AllBookmarksView.playsInsteadHeader(loadedId: "a", loadedTitle: "  ", bookmarkItemIds: ["b"]))
    }

    func testResolutionOrderFollowsScreenOrderOncePerBook() {
        let marks = [
            AudioBookmark(libraryItemId: "a", title: "", time: 1, createdAt: 100),
            AudioBookmark(libraryItemId: "b", title: "", time: 2, createdAt: 300),
            AudioBookmark(libraryItemId: "a", title: "", time: 3, createdAt: 400),
            AudioBookmark(libraryItemId: "c", title: "", time: 4, createdAt: 200),
        ]
        XCTAssertEqual(AllBookmarksView.resolutionOrder(marks, newestFirst: true), ["a", "b", "c"])
        XCTAssertEqual(AllBookmarksView.resolutionOrder(marks, newestFirst: false), ["a", "c", "b"])
        XCTAssertGreaterThan(AllBookmarksView.resolveConcurrency, 1)
    }
}
