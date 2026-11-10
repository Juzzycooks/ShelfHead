import XCTest
@testable import ShelfHead

/// Critique 2026-10-05 (Library): pins the pure decisions behind the Library's honest
/// filter state — client-side progress filter + sort for "Downloaded only", local search for
/// offline, the count-and-sort wayfinding line, the "Recently Played" relabel, the series
/// number badge text and the Author grid's tile subtitle.
@MainActor
final class LibraryStateTests: XCTestCase {

    // MARK: - Fixtures

    private func book(
        _ id: String, title: String, author: String = "An Author", narrator: String? = nil,
        series: String? = nil, duration: Double = 3600, addedAt: Int? = nil
    ) throws -> ShelfHead.LibraryItem {
        var meta = #""title": "\#(title)", "authorName": "\#(author)""#
        if let narrator { meta += #", "narratorName": "\#(narrator)""# }
        if let series { meta += #", "seriesName": "\#(series)""# }
        let added = addedAt.map { #", "addedAt": \#($0)"# } ?? ""
        let json = #"""
        {"id": "\#(id)", "mediaType": "book"\#(added),
         "media": {"metadata": {\#(meta)}, "duration": \#(duration), "numAudioFiles": 1}}
        """#
        return try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }

    private func progress(
        _ id: String, _ fraction: Double, finished: Bool = false, lastUpdate: Int = 0
    ) -> MediaProgress {
        MediaProgress(
            id: id, libraryItemId: id, episodeId: nil, duration: 3600, progress: fraction,
            currentTime: fraction * 3600, isFinished: finished, lastUpdate: lastUpdate,
            startedAt: nil, finishedAt: nil
        )
    }

    private func apply(
        _ items: [ShelfHead.LibraryItem], filter: LibraryProgressFilter = .all,
        sort: LibrarySort = .title, descending: Bool = false,
        progress map: [String: MediaProgress] = [:]
    ) -> [String] {
        LibraryLocalQuery.apply(items, filter: filter, sort: sort, descending: descending) { map[$0.id] }
            .map(\.id)
    }

    // MARK: - Downloaded only honours progress filter and sort

    func testProgressBuckets() {
        XCTAssertEqual(LibraryLocalQuery.progressBucket(nil), .notStarted)
        XCTAssertEqual(LibraryLocalQuery.progressBucket(progress("a", 0)), .notStarted)
        XCTAssertEqual(LibraryLocalQuery.progressBucket(progress("a", 0.4)), .inProgress)
        XCTAssertEqual(LibraryLocalQuery.progressBucket(progress("a", 1, finished: true)), .finished)
        // Finished wins even if the stored fraction is partial.
        XCTAssertEqual(LibraryLocalQuery.progressBucket(progress("a", 0.2, finished: true)), .finished)
    }

    func testProgressFilterIsAppliedToDownloads() throws {
        let items = [try book("a", title: "A"), try book("b", title: "B"), try book("c", title: "C")]
        let map = ["b": progress("b", 0.5), "c": progress("c", 1, finished: true)]
        XCTAssertEqual(apply(items, filter: .all, progress: map), ["a", "b", "c"])
        XCTAssertEqual(apply(items, filter: .notStarted, progress: map), ["a"])
        XCTAssertEqual(apply(items, filter: .inProgress, progress: map), ["b"])
        XCTAssertEqual(apply(items, filter: .finished, progress: map), ["c"])
    }

    func testTitleSortAscendingAndDescendingIsNaturalNumeric() throws {
        let items = [try book("10", title: "Book 10"), try book("2", title: "Book 2"), try book("1", title: "Book 1")]
        XCTAssertEqual(apply(items, sort: .title, descending: false), ["1", "2", "10"])
        XCTAssertEqual(apply(items, sort: .title, descending: true), ["10", "2", "1"])
    }

    func testAuthorSortFallsBackToTitleWithinAnAuthor() throws {
        let items = [
            try book("z", title: "Zed", author: "Brown"),
            try book("a", title: "Alpha", author: "Brown"),
            try book("m", title: "Mid", author: "Adams"),
        ]
        XCTAssertEqual(apply(items, sort: .author), ["m", "a", "z"])
        XCTAssertEqual(apply(items, sort: .author, descending: true), ["a", "z", "m"])
    }

    func testDateAddedAndDurationSorts() throws {
        let items = [
            try book("old", title: "Old", duration: 7200, addedAt: 100),
            try book("new", title: "New", duration: 1800, addedAt: 900),
            try book("mid", title: "Mid", duration: 3600, addedAt: 500),
        ]
        XCTAssertEqual(apply(items, sort: .addedAt, descending: true), ["new", "mid", "old"])
        XCTAssertEqual(apply(items, sort: .addedAt, descending: false), ["old", "mid", "new"])
        XCTAssertEqual(apply(items, sort: .duration, descending: false), ["new", "mid", "old"])
        XCTAssertEqual(apply(items, sort: .duration, descending: true), ["old", "mid", "new"])
    }

    func testRecentSortKeepsOnlyInProgressNewestFirstAndIgnoresDirection() throws {
        let items = [try book("a", title: "A"), try book("b", title: "B"), try book("c", title: "C"), try book("d", title: "D")]
        let map = [
            "a": progress("a", 0.3, lastUpdate: 100),
            "b": progress("b", 0.6, lastUpdate: 900),
            "c": progress("c", 1, finished: true, lastUpdate: 999),
        ]
        XCTAssertEqual(apply(items, sort: .recent, descending: false, progress: map), ["b", "a"])
        XCTAssertEqual(apply(items, sort: .recent, descending: true, progress: map), ["b", "a"])
    }

    func testFilterAndSortCompose() throws {
        let items = [
            try book("a", title: "A", duration: 100), try book("b", title: "B", duration: 300),
            try book("c", title: "C", duration: 200),
        ]
        let map = ["a": progress("a", 0.1), "b": progress("b", 0.2), "c": progress("c", 1, finished: true)]
        XCTAssertEqual(apply(items, filter: .inProgress, sort: .duration, descending: true, progress: map), ["b", "a"])
    }

    // MARK: - Local (offline) search

    func testLocalSearchMatchesTitleAuthorNarratorAndSeries() throws {
        let items = [
            try book("k", title: "The Way of Kings", author: "Brandon Sanderson", narrator: "Michael Kramer", series: "Stormlight Archive"),
            try book("e", title: "Emperor's Soul", author: "Brandon Sanderson", narrator: "Emily Woo Zeller"),
            try book("o", title: "Other", author: "Someone Else"),
        ]
        func ids(_ q: String) -> [String] { LibraryLocalQuery.search(items, query: q).map(\.id) }
        XCTAssertEqual(ids("kings"), ["k"])
        XCTAssertEqual(ids("sanderson"), ["k", "e"])
        XCTAssertEqual(ids("kramer"), ["k"])
        XCTAssertEqual(ids("stormlight"), ["k"])
        XCTAssertEqual(ids("SANDERSON way"), ["k"], "every token must match somewhere, case-insensitively")
        XCTAssertEqual(ids("zzz"), [])
    }

    func testLocalSearchIgnoresDiacriticsAndBlankQueries() throws {
        let items = [try book("a", title: "Café Society")]
        XCTAssertEqual(LibraryLocalQuery.search(items, query: "cafe").map(\.id), ["a"])
        XCTAssertTrue(LibraryLocalQuery.search(items, query: "   ").isEmpty)
        XCTAssertTrue(LibraryLocalQuery.search(items, query: "").isEmpty)
    }

    // MARK: - Count and sort line

    private let us = Locale(identifier: "en_US")

    func testCountAndSortLineUsesGroupingAndSortDescription() {
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 1240, sort: .title, descending: false,
                                               downloadedOnly: false, smartFilter: nil, locale: us),
            "1,240 books · Title A–Z")
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 1, sort: .addedAt, descending: true,
                                               downloadedOnly: false, smartFilter: nil, locale: us),
            "1 book · Date Added, newest first")
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 12, sort: .duration, descending: false,
                                               downloadedOnly: true, smartFilter: nil, locale: us),
            "12 downloaded books · Duration, shortest first")
    }

    func testCountAndSortLineSaysRecentIsInProgressOnly() {
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 7, sort: .recent, descending: false,
                                               downloadedOnly: false, smartFilter: nil, locale: us),
            "7 books · Recently Played, in progress only")
    }

    func testCountAndSortLineForASmartFilterNamesTheFilterNotTheSort() {
        let line = LibraryLocalQuery.countAndSortLine(count: 3, sort: .title, descending: false,
                                                      downloadedOnly: false, smartFilter: .nearlyFinished, locale: us)
        XCTAssertEqual(line, "3 books · \(SmartFilter.nearlyFinished.label)")
    }

    func testRecentlyPlayedSortOptionIsLabelledHonestly() {
        XCTAssertEqual(LibraryLocalQuery.sortOptionLabel(.recent), "Recently Played (in progress only)")
        XCTAssertEqual(LibraryLocalQuery.sortOptionLabel(.title), LibrarySort.title.label)
    }

    // MARK: - View-model composition

    func testDisplayedItemsAppliesFilterAndSortToDownloadsOnlyWhenDownloadedOnly() throws {
        let vm = LibraryViewModel()
        let server = [try book("s1", title: "Server One")]
        let downloads = [try book("d2", title: "Bravo"), try book("d1", title: "Alpha")]
        vm.items = server
        vm.totalItems = 900
        vm.sortOption = .title
        vm.sortDescending = false
        vm.progressFilter = .all
        defer { vm.sortOption = .title; vm.sortDescending = false; vm.progressFilter = .all }

        XCTAssertEqual(vm.displayedItems(downloads: downloads).map(\.id), ["s1"])
        XCTAssertEqual(vm.totalResultCount(downloads: downloads), 900, "server total, not loaded pages")

        vm.downloadedOnly = true
        XCTAssertEqual(vm.displayedItems(downloads: downloads).map(\.id), ["d1", "d2"])
        vm.sortDescending = true
        XCTAssertEqual(vm.displayedItems(downloads: downloads).map(\.id), ["d2", "d1"])
        vm.sortDescending = false
        vm.progressFilter = .finished
        XCTAssertEqual(vm.displayedItems(downloads: downloads).map(\.id), [], "no download is finished")
        XCTAssertEqual(vm.totalResultCount(downloads: downloads), 0)
        vm.downloadedOnly = false
    }

    // MARK: - Series badge and Author tile subtitle

    func testSequenceBadgeText() {
        XCTAssertEqual(SeriesDetailView.sequenceBadgeText(3), "3")
        XCTAssertEqual(SeriesDetailView.sequenceBadgeText(2.5), "2.5")
        XCTAssertEqual(SeriesDetailView.sequenceBadgeText(0), "0")
        XCTAssertNil(SeriesDetailView.sequenceBadgeText(nil))
        XCTAssertNil(SeriesDetailView.sequenceBadgeText(-1))
        XCTAssertNil(SeriesDetailView.sequenceBadgeText(.nan))
    }

    func testAuthorTileSubtitlePrefersSeriesThenDurationAndNeverTheAuthor() throws {
        let inSeries = try book("a", title: "A", author: "Ann", series: "Saga", duration: 3600)
        let standalone = try book("b", title: "B", author: "Ann", duration: 5400)
        let unknown = try book("c", title: "C", author: "Ann", duration: 0)
        XCTAssertEqual(AuthorBooksView.tileSubtitle(for: inSeries), "Saga")
        XCTAssertEqual(AuthorBooksView.tileSubtitle(for: standalone), standalone.duration.formattedDuration)
        XCTAssertEqual(AuthorBooksView.tileSubtitle(for: unknown), "Standalone", "never empty: VoiceOver joins the parts")
    }

    // MARK: - Critique 2026-10-05 (Library, 2nd)

    func testSourceAfterFailure() {
        // Books on screen are kept whatever the source was.
        XCTAssertEqual(LibraryLocalQuery.sourceAfterFailure(current: .server, hasItems: true, hasDownloads: true), .server)
        XCTAssertEqual(LibraryLocalQuery.sourceAfterFailure(current: .offlineFallback, hasItems: true, hasDownloads: true), .offlineFallback)
        // Nothing on screen: downloads become a labelled fallback, otherwise the load failed.
        XCTAssertEqual(LibraryLocalQuery.sourceAfterFailure(current: .server, hasItems: false, hasDownloads: true), .offlineFallback)
        XCTAssertEqual(LibraryLocalQuery.sourceAfterFailure(current: .server, hasItems: false, hasDownloads: false), .failed)
    }

    func testEffectiveFiltersDropOverriddenFilters() {
        // A smart filter outranks progress and Downloaded.
        let smart = LibraryLocalQuery.effectiveFilters(
            smartFilter: .nearlyFinished, progressFilter: .finished, downloadedOnly: true, sort: .title)
        XCTAssertEqual(smart.smartFilter, .nearlyFinished)
        XCTAssertNil(smart.progress)
        XCTAssertFalse(smart.downloadedOnly)
        // Recently Played ignores the progress filter.
        let recent = LibraryLocalQuery.effectiveFilters(
            smartFilter: nil, progressFilter: .finished, downloadedOnly: true, sort: .recent)
        XCTAssertNil(recent.progress)
        XCTAssertTrue(recent.downloadedOnly)
        // Otherwise everything the user set shows; .all is no chip.
        let plain = LibraryLocalQuery.effectiveFilters(
            smartFilter: nil, progressFilter: .inProgress, downloadedOnly: false, sort: .title)
        XCTAssertEqual(plain.progress, .inProgress)
        XCTAssertTrue(LibraryLocalQuery.effectiveFilters(
            smartFilter: nil, progressFilter: .all, downloadedOnly: false, sort: .title).isEmpty)
    }

    func testRecentSortIgnoresProgressFilterLocally() throws {
        let items = [try book("a", title: "A"), try book("b", title: "B")]
        let map = ["a": progress("a", 0.3, lastUpdate: 5), "b": progress("b", 0.6, lastUpdate: 9)]
        XCTAssertEqual(apply(items, filter: .finished, sort: .recent, progress: map), ["b", "a"])
    }

    func testTitleSortIgnoresLeadingArticles() throws {
        let items = [try book("1", title: "The Zebra"), try book("2", title: "An Apple"),
                     try book("3", title: "A Mango"), try book("4", title: "Banana"), try book("5", title: "The")]
        XCTAssertEqual(apply(items), ["2", "4", "3", "5", "1"])
        XCTAssertEqual(LibraryLocalQuery.titleSortKey("The Hobbit"), "Hobbit")
        XCTAssertEqual(LibraryLocalQuery.titleSortKey("Theodore"), "Theodore")
        XCTAssertEqual(LibraryLocalQuery.titleSortKey("The"), "The")
    }

    func testCountLineOfflineFallbackAndRecentCap() {
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 12, sort: .title, descending: false, downloadedOnly: false,
                                               smartFilter: nil, offlineFallback: true, locale: us),
            "12 downloaded books (offline) · Title A–Z")
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 100, sort: .recent, descending: false,
                                               downloadedOnly: false, smartFilter: nil, locale: us),
            "100 most recent in progress")
        XCTAssertEqual(
            LibraryLocalQuery.countAndSortLine(count: 99, sort: .recent, descending: false,
                                               downloadedOnly: false, smartFilter: nil, locale: us),
            "99 books · Recently Played, in progress only")
    }

    func testShowDownloadsClearsSmartFilterAndFlipsToLocal() {
        let vm = LibraryViewModel()
        vm.smartFilter = .nearlyFinished
        vm.showDownloads()
        XCTAssertNil(vm.smartFilter)
        XCTAssertTrue(vm.downloadedOnly)
        XCTAssertTrue(vm.showsLocalDownloads)
        vm.downloadedOnly = false
    }

    func testOfflineFallbackShowsLocalDownloadsHonouringSort() throws {
        let vm = LibraryViewModel()
        let downloads = [try book("d2", title: "Bravo"), try book("d1", title: "Alpha")]
        vm.itemsSource = .offlineFallback
        vm.sortOption = .title
        vm.sortDescending = false
        vm.progressFilter = .all
        XCTAssertEqual(vm.displayedItems(downloads: downloads).map(\.id), ["d1", "d2"])
        vm.sortDescending = true
        XCTAssertEqual(vm.displayedItems(downloads: downloads).map(\.id), ["d2", "d1"], "cache keyed on sort")
        vm.sortDescending = false
    }

    func testSequenceBadgeClearsBottomFurniture() {
        XCTAssertEqual(SeriesDetailView.sequenceBadgeBottomInset(progressLine: false, reelBand: false), 0)
        XCTAssertEqual(SeriesDetailView.sequenceBadgeBottomInset(progressLine: true, reelBand: true), 17)
    }

    // MARK: - Library browse plan §6.2 (2026-10-05): local vs server-paged windows

    func testIsLocalQueryForEveryLocalSourceAndServerPagedOtherwise() {
        XCTAssertFalse(LibraryViewModel.isLocalQuery(smartFilterActive: false, downloadedOnly: false,
                                                     offlineFallback: false, recentlyPlayed: false),
                       "plain browse (any server sort or progress filter) is server-paged")
        XCTAssertTrue(LibraryViewModel.isLocalQuery(smartFilterActive: true, downloadedOnly: false,
                                                    offlineFallback: false, recentlyPlayed: false))
        XCTAssertTrue(LibraryViewModel.isLocalQuery(smartFilterActive: false, downloadedOnly: true,
                                                    offlineFallback: false, recentlyPlayed: false))
        XCTAssertTrue(LibraryViewModel.isLocalQuery(smartFilterActive: false, downloadedOnly: false,
                                                    offlineFallback: true, recentlyPlayed: false))
        XCTAssertTrue(LibraryViewModel.isLocalQuery(smartFilterActive: false, downloadedOnly: false,
                                                    offlineFallback: false, recentlyPlayed: true))
        XCTAssertTrue(LibraryViewModel.isLocalQuery(smartFilterActive: true, downloadedOnly: true,
                                                    offlineFallback: true, recentlyPlayed: true))
    }

    func testAssigningItemsMakesAFullyLoadedLocalWindow() throws {
        let vm = LibraryViewModel()
        let list = try (0..<120).map { try book("b\($0)", title: "Book \($0)") }
        vm.items = list
        XCTAssertFalse(vm.isWindowed, "an assigned list is local, never server-paged")
        XCTAssertEqual(vm.window.total, 120)
        XCTAssertEqual(vm.window.pageCount, 3)
        XCTAssertEqual(vm.items.map(\.id), list.map(\.id), "items reads back in position order")
        XCTAssertEqual(vm.slot(at: 119).item?.id, "b119")
        XCTAssertEqual(vm.totalItems, 0, "assigning items doesn't touch the server total")
        vm.items = []
        XCTAssertEqual(vm.window.total, 0)
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testDisplayWindowWrapsTheDownloadedSetAsLocal() throws {
        let vm = LibraryViewModel()
        vm.items = [try book("s1", title: "Server One")]
        let downloads = [try book("d2", title: "Bravo"), try book("d1", title: "Alpha")]
        vm.sortOption = .title
        vm.sortDescending = false
        vm.progressFilter = .all
        defer { vm.downloadedOnly = false }

        XCTAssertEqual(vm.displayWindow(downloads: downloads).total, 1, "not filtered: the main window")
        vm.downloadedOnly = true
        let local = vm.displayWindow(downloads: downloads)
        XCTAssertEqual(local.total, 2)
        XCTAssertEqual(local.loadedInOrder.map(\.id), ["d1", "d2"], "same order as displayedItems")
        XCTAssertTrue(vm.canSelectAll(downloads: downloads), "a local set of 2 offers Select All")
    }
}
