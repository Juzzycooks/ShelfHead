import XCTest
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 L1, L6, L7, F1, E6): pins the pure pieces of the Library quick
/// wins — grouped search decoding, the Continue Listening offer rules, recent searches,
/// the Want to Read matcher and the Ask snapshot's partial flag.
@MainActor
final class QuickWinsLibraryTests: XCTestCase {

    // MARK: L1 — grouped search decoding

    private let bookSearchJSON = """
    {"book":[{"libraryItem":{"id":"b1","libraryId":"lib","mediaType":"book",
               "media":{"metadata":{"title":"Dune","authorName":"Frank Herbert"}}}}],
     "series":[{"series":{"id":"s1","name":"Dune"},
                "books":[{"id":"b1","libraryId":"lib","mediaType":"book"},
                         {"id":"b2","libraryId":"lib","mediaType":"book"}]}],
     "authors":[{"id":"a1","asin":null,"name":"Frank Herbert","description":null,"imagePath":null,
                 "libraryId":"lib","addedAt":1,"updatedAt":1,"numBooks":6},
                {"id":"","name":"No Id"},
                {"id":"a2","name":"  "}],
     "narrators":[{"name":"Scott Brick","numBooks":3},{"name":"scott brick","numBooks":1}],
     "tags":[{"name":"Classic","numItems":2}],
     "genres":[{"name":"Science Fiction","numItems":9}]}
    """

    func testGroupedSearchDecodesBooksThenSeriesBooksDeduplicated() throws {
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(bookSearchJSON.utf8))
        XCTAssertEqual(groups.books.map(\.id), ["b1", "b2"])
    }

    func testGroupedSearchDecodesAuthorsWithIdsOnly() throws {
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(bookSearchJSON.utf8))
        XCTAssertEqual(groups.authors, [.init(id: "a1", name: "Frank Herbert", numBooks: 6)])
    }

    func testGroupedSearchDecodesNarratorsByNameOnceEach() throws {
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(bookSearchJSON.utf8))
        XCTAssertEqual(groups.narrators, [.init(id: nil, name: "Scott Brick", numBooks: 3)])
    }

    func testPodcastLibrarySearchDecodesToEmptyGroups() throws {
        // A podcast library's search has no book/series/authors/narrators keys.
        let json = """
        {"podcast":[{"libraryItem":{"id":"p1","mediaType":"podcast"}}],
         "tags":[],"genres":[],"episodes":[]}
        """
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(json.utf8))
        XCTAssertTrue(groups.books.isEmpty)
        XCTAssertTrue(groups.authors.isEmpty)
        XCTAssertTrue(groups.narrators.isEmpty)
    }

    func testOneBadAuthorDoesNotEmptyTheBooks() throws {
        let json = """
        {"book":[{"libraryItem":{"id":"b1","mediaType":"book"}}],
         "authors":[42, {"id":"a1","name":"Ann"}]}
        """
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(json.utf8))
        XCTAssertEqual(groups.books.map(\.id), ["b1"])
        XCTAssertEqual(groups.authors.map(\.name), ["Ann"])
    }

    func testSearchAsksForMoreThanTheServerDefault() {
        // ABS defaults to 12 without `limit`; the review asked for 25–50.
        XCTAssertTrue((25...50).contains(AudiobookshelfAPI.searchResultLimit))
    }

    func testPersonRowBookCount() {
        XCTAssertNil(SearchPersonRow.bookCountText(nil))
        XCTAssertNil(SearchPersonRow.bookCountText(0))
        XCTAssertEqual(SearchPersonRow.bookCountText(1), "1 book")
        XCTAssertEqual(SearchPersonRow.bookCountText(12), "12 books")
    }

    // MARK: F1 — Remove from Continue Listening

    private func progress(_ fraction: Double?, currentTime: Double? = nil, finished: Bool? = false,
                          hidden: Bool? = nil, episode: String? = nil) -> MediaProgress {
        MediaProgress(id: "p", libraryItemId: "a", episodeId: episode, duration: 3600, progress: fraction,
                      currentTime: currentTime, isFinished: finished, lastUpdate: 0,
                      startedAt: nil, finishedAt: nil, hideFromContinueListening: hidden)
    }

    func testOffersRemoveForAStartedUnfinishedBook() {
        XCTAssertTrue(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(0.3), isPodcast: false))
        XCTAssertTrue(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(nil, currentTime: 12), isPodcast: false))
    }

    func testDoesNotOfferRemoveWhenNothingToRemove() {
        XCTAssertFalse(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: nil, isPodcast: false))
        XCTAssertFalse(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(0), isPodcast: false))
        XCTAssertFalse(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(1, finished: true), isPodcast: false))
        XCTAssertFalse(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(0.3, hidden: true), isPodcast: false))
        XCTAssertFalse(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(0.3), isPodcast: true))
        XCTAssertFalse(LibraryViewModel.shouldOfferRemoveFromContinueListening(progress: progress(0.3, episode: "e1"), isPodcast: false))
    }

    func testMediaProgressDecodesHideFlagLeniently() throws {
        let hidden = try JSONDecoder().decode(MediaProgress.self, from: Data("""
        {"id":"p","libraryItemId":"a","progress":0.4,"hideFromContinueListening":true}
        """.utf8))
        XCTAssertEqual(hidden.hideFromContinueListening, true)
        let numeric = try JSONDecoder().decode(MediaProgress.self, from: Data("""
        {"libraryItemId":"a","hideFromContinueListening":0}
        """.utf8))
        XCTAssertEqual(numeric.hideFromContinueListening, false)
        let absent = try JSONDecoder().decode(MediaProgress.self, from: Data("""
        {"libraryItemId":"a"}
        """.utf8))
        XCTAssertNil(absent.hideFromContinueListening)
    }

    func testSeriesOfferedOnlyWhileItsBookIsOnContinueSeries() throws {
        let json = """
        [{"label":"Continue Series","labelStringKey":"LabelContinueSeries","type":"book",
          "entities":[{"id":"b2","mediaType":"book"}]},
         {"label":"Continue Listening","labelStringKey":"LabelContinueListening","type":"book",
          "entities":[{"id":"b9","mediaType":"book"}]}]
        """
        let shelves = try JSONDecoder().decode([PersonalizedView].self, from: Data(json.utf8))
        XCTAssertTrue(LibraryViewModel.seriesIsInContinueSeries(seriesBookIds: ["b1", "b2"], shelves: shelves))
        // A book on Continue Listening only doesn't count.
        XCTAssertFalse(LibraryViewModel.seriesIsInContinueSeries(seriesBookIds: ["b9"], shelves: shelves))
        XCTAssertFalse(LibraryViewModel.seriesIsInContinueSeries(seriesBookIds: [], shelves: shelves))
    }

    func testRemovedToastNamesTheBookOrSeries() {
        XCTAssertEqual(LibraryViewModel.continueListeningRemovedCopy(title: "Dune"),
                       "Removed \u{201C}Dune\u{201D} from Continue Listening")
        XCTAssertEqual(LibraryViewModel.continueListeningRemovedCopy(title: "Dune", isSeries: true),
                       "Removed \u{201C}Dune\u{201D} from Next in Series")
        XCTAssertEqual(LibraryViewModel.continueListeningRemovedCopy(title: " "),
                       "Removed this book from Continue Listening")
    }

    // MARK: L7 — recent searches

    func testRecentSearchesPutNewestFirstWithoutDuplicates() {
        XCTAssertEqual(RecentLibrarySearches.adding("dune", to: ["Emma", "Dune"]), ["dune", "Emma"])
    }

    func testRecentSearchesKeepFiveAndIgnoreBlanks() {
        let full = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(RecentLibrarySearches.adding("f", to: full), ["f", "a", "b", "c", "d"])
        XCTAssertEqual(RecentLibrarySearches.adding("   ", to: full), full)
        XCTAssertEqual(RecentLibrarySearches.adding("  Dune ", to: []), ["Dune"])
    }

    func testAskOffersThreeExamples() {
        XCTAssertEqual(RecentLibrarySearches.askExamples.count, 3)
    }

    // MARK: L6 — Want to Read matcher

    func testWantToReadMatchesAgainstTheWholeLibrary() {
        let entries = [
            WantToReadEntry(title: "Dune", author: "Frank Herbert", isbn: nil, source: .goodreads, url: nil),
            WantToReadEntry(title: "Emma", author: "Jane Austen", isbn: nil, source: .goodreads, url: nil)
        ]
        let candidates = [
            ReadingSiteMatcher.Candidate(id: "x", title: "Something Else", author: "Someone", isbn: nil, asin: nil),
            ReadingSiteMatcher.Candidate(id: "d", title: "Dune (Unabridged)", author: "Frank Herbert", isbn: nil, asin: nil)
        ]
        let owned = WantToReadView.ownedMatches(entries, in: candidates)
        XCTAssertEqual(owned[entries[0].id], "d")
        XCTAssertNil(owned[entries[1].id])
        XCTAssertTrue(WantToReadView.ownedMatches(entries, in: []).isEmpty)
    }

    func testWantToReadCandidatesSkipPodcasts() throws {
        let json = """
        [{"id":"b1","mediaType":"book","media":{"metadata":{"title":"Dune","authorName":"Frank Herbert"}}},
         {"id":"p1","mediaType":"podcast"}]
        """
        let items = try JSONDecoder().decode([ShelfHead.LibraryItem].self, from: Data(json.utf8))
        XCTAssertEqual(WantToReadView.candidates(from: items).map(\.id), ["b1"])
    }

    // MARK: E6 — Ask says when it read only part of the library

    func testAskSnapshotPartialOnlyWhenCapHitWithMoreOnServer() {
        let cap = MoodSearchViewModel.snapshotCap
        XCTAssertTrue(MoodSearchViewModel.isPartial(fetched: cap, total: cap + 1))
        XCTAssertFalse(MoodSearchViewModel.isPartial(fetched: cap, total: cap))
        XCTAssertFalse(MoodSearchViewModel.isPartial(fetched: 120, total: 120))
    }
}
