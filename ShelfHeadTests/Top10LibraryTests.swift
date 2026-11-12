import XCTest
@testable import ShelfHead

/// Batch 492 (REVIEW 2026-11-11 L1, L2): pins the pure pieces of Library search's Genres and
/// Tags groups and of the podcast-library rules (sort, filter, actions, copy, icon).
@MainActor
final class Top10LibraryTests: XCTestCase {

    // MARK: L1 — genres and tags

    func testSearchDecodesGenresAndTagsByNameOnceEach() throws {
        let json = """
        {"book":[],"tags":[{"name":"Classic","numItems":2},{"name":"classic","numItems":1},{"name":" ","numItems":4}],
         "genres":[{"name":"Science Fiction","numItems":9},{"numItems":3}]}
        """
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(json.utf8))
        XCTAssertEqual(groups.tags, [.init(name: "Classic", numItems: 2)])
        XCTAssertEqual(groups.genres, [.init(name: "Science Fiction", numItems: 9)])
    }

    func testOneMalformedGroupDoesNotEmptyTheOthers() throws {
        // `genres` is an object, not an array: only that group is lost.
        let json = """
        {"book":[{"libraryItem":{"id":"b1","mediaType":"book"}}],
         "genres":{"oops":true},"tags":[{"name":"Epic","numItems":1}]}
        """
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(json.utf8))
        XCTAssertEqual(groups.books.map(\.id), ["b1"])
        XCTAssertTrue(groups.genres.isEmpty)
        XCTAssertEqual(groups.tags.map(\.name), ["Epic"])
    }

    func testRouteKeysSeparateGenreAndTag() {
        XCTAssertNotEqual(LibraryRoute.genre("Epic"), LibraryRoute.tag("Epic"))
        XCTAssertEqual(LibraryRoute.tag("Epic"), LibraryRoute.tag("Epic"))
    }

    // MARK: L2 — podcast search and metadata

    func testPodcastSearchDecodesShows() throws {
        let json = """
        {"podcast":[{"libraryItem":{"id":"p1","mediaType":"podcast",
                     "media":{"metadata":{"title":"Show","author":"Host"}}}}],
         "tags":[],"genres":[],"episodes":[]}
        """
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(json.utf8))
        XCTAssertEqual(groups.podcasts.map(\.id), ["p1"])
        XCTAssertTrue(groups.books.isEmpty)
        XCTAssertEqual(groups.podcasts.first?.authorName, "Host")
    }

    func testAuthorNameFallsBackToPodcastAuthorThenUnknown() throws {
        let withAuthor = try JSONDecoder().decode(LibraryItem.self, from: Data(
            #"{"id":"p1","mediaType":"podcast","media":{"metadata":{"title":"S","author":"Host"}}}"#.utf8))
        XCTAssertEqual(withAuthor.authorName, "Host")
        let book = try JSONDecoder().decode(LibraryItem.self, from: Data(
            #"{"id":"b1","mediaType":"book","media":{"metadata":{"title":"B","authorName":"Ann","author":"Other"}}}"#.utf8))
        XCTAssertEqual(book.authorName, "Ann")
        let none = try JSONDecoder().decode(LibraryItem.self, from: Data(
            #"{"id":"p2","mediaType":"podcast","media":{"metadata":{"title":"S","author":""}}}"#.utf8))
        XCTAssertEqual(none.authorName, String(localized: "Unknown Author"))
    }

    func testLibraryIsPodcastLibraryFromMediaType() throws {
        let podcast = try JSONDecoder().decode(Library.self, from: Data(
            #"{"id":"l1","name":"Pods","mediaType":"podcast","icon":"podcast"}"#.utf8))
        let book = try JSONDecoder().decode(Library.self, from: Data(
            #"{"id":"l2","name":"Books","mediaType":"book","icon":"books-1"}"#.utf8))
        XCTAssertTrue(podcast.isPodcastLibrary)
        XCTAssertFalse(book.isPodcastLibrary)
        XCTAssertEqual(podcast.symbolName, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(book.symbolName, "books.vertical")
        XCTAssertNil(Library.symbolName(forIcon: "database"))
        XCTAssertNil(Library.symbolName(forIcon: nil))
        XCTAssertEqual(Library.symbolName(forIcon: "microphone-2"), "mic")
    }

    // MARK: L2 — sort, filter, actions, copy

    func testPodcastSortOptionsAndServerKeys() {
        XCTAssertEqual(LibraryViewModel.sortOptions(isPodcast: true), [.title, .author, .addedAt, .duration])
        XCTAssertEqual(LibraryViewModel.sortOptions(isPodcast: false), LibrarySort.allCases)
        XCTAssertEqual(LibraryViewModel.serverSortKey(.title, isPodcast: true), "media.metadata.title")
        XCTAssertEqual(LibraryViewModel.serverSortKey(.author, isPodcast: true), "media.metadata.author")
        XCTAssertEqual(LibraryViewModel.serverSortKey(.addedAt, isPodcast: true), "addedAt")
        XCTAssertEqual(LibraryViewModel.serverSortKey(.duration, isPodcast: true), "media.numTracks")
        // Books keep their keys.
        XCTAssertEqual(LibraryViewModel.serverSortKey(.author, isPodcast: false), "media.metadata.authorName")
        XCTAssertEqual(LibraryViewModel.serverSortKey(.duration, isPodcast: false), "media.duration")
    }

    func testRecentlyPlayedFallsBackToTitleInAPodcastLibrary() {
        XCTAssertEqual(LibraryViewModel.effectiveSort(.recent, isPodcast: true), .title)
        XCTAssertEqual(LibraryViewModel.effectiveSort(.recent, isPodcast: false), .recent)
        XCTAssertEqual(LibraryViewModel.serverSortKey(.recent, isPodcast: true), "media.metadata.title")
    }

    func testPodcastLibrarySendsNoProgressFilter() {
        XCTAssertNil(LibraryViewModel.serverFilter(.finished, isPodcast: true))
        XCTAssertEqual(LibraryViewModel.serverFilter(.finished, isPodcast: false), LibraryProgressFilter.finished.filterValue)
        XCTAssertNil(LibraryViewModel.serverFilter(.all, isPodcast: false))
    }

    func testShowsGetNoBookActions() {
        XCTAssertFalse(BookContextMenu.offersBookActions(isPodcast: true))
        XCTAssertTrue(BookContextMenu.offersBookActions(isPodcast: false))
    }

    func testPodcastSortLabelAndCountLine() {
        XCTAssertEqual(LibraryViewModel.sortLabel(.duration, isPodcast: true), "Episodes")
        XCTAssertEqual(LibraryViewModel.sortLabel(.duration, isPodcast: false), LibrarySort.duration.label)
        let en = Locale(identifier: "en_US")
        let many = LibraryLocalQuery.countAndSortLine(
            count: 12, sort: .title, descending: false, downloadedOnly: false, smartFilter: nil,
            isPodcast: true, locale: en)
        XCTAssertEqual(many, "12 shows · Title A–Z")
        let one = LibraryLocalQuery.countAndSortLine(
            count: 1, sort: .duration, descending: true, downloadedOnly: false, smartFilter: nil,
            isPodcast: true, locale: en)
        XCTAssertEqual(one, "1 show · Episodes, most first")
        // A saved Recently Played reads as Title in a podcast library.
        let recent = LibraryLocalQuery.countAndSortLine(
            count: 3, sort: .recent, descending: false, downloadedOnly: false, smartFilter: nil,
            isPodcast: true, locale: en)
        XCTAssertEqual(recent, "3 shows · Title A–Z")
    }
}
