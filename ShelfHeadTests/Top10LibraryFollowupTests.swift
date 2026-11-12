import XCTest
@testable import ShelfHead

/// Batch 493: Library search "Show All" decisions and the podcast episode group.
final class Top10LibraryFollowupTests: XCTestCase {

    func testInlineShowsAllWhenWithinLimit() {
        let r = SearchGroupDisplay.inline([1, 2, 3], limit: 5)
        XCTAssertEqual(r.shown, [1, 2, 3])
        XCTAssertFalse(r.hasMore)
        XCTAssertFalse(SearchGroupDisplay.inline([1, 2, 3, 4, 5], limit: 5).hasMore)
    }

    func testInlineCapsAndOffersShowAll() {
        let r = SearchGroupDisplay.inline(Array(1...9), limit: 5)
        XCTAssertEqual(r.shown, [1, 2, 3, 4, 5])
        XCTAssertTrue(r.hasMore)
    }

    func testBooksHitLimit() {
        XCTAssertFalse(SearchGroupDisplay.booksHitLimit(49, limit: 50))
        XCTAssertTrue(SearchGroupDisplay.booksHitLimit(50, limit: 50))
        XCTAssertTrue(SearchGroupDisplay.booksHitLimit(61, limit: 50))
    }

    private func libraryItemJSON(_ id: String, episode: String?) -> String {
        let recent = episode.map { ",\"recentEpisode\":\($0)" } ?? ""
        return "{\"libraryItem\":{\"id\":\"\(id)\",\"mediaType\":\"podcast\",\"media\":{\"metadata\":{\"title\":\"Show \(id)\"}}\(recent)}}"
    }

    func testEpisodesDecodeLeniently() throws {
        let good = "{\"id\":\"ep1\",\"title\":\"First\",\"publishedAt\":1700000000000}"
        let json = """
        {"podcast":[],"tags":[],"genres":[],"episodes":[
          \(libraryItemJSON("a", episode: good)),
          \(libraryItemJSON("b", episode: nil)),
          {"libraryItem":"garbage"},
          \(libraryItemJSON("c", episode: "{\"id\":\"ep3\",\"title\":\"Third\"}"))
        ]}
        """
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data(json.utf8))
        XCTAssertEqual(groups.episodes.map(\.episode.id), ["ep1", "ep3"])
        XCTAssertEqual(groups.episodes.first?.item.id, "a")
        XCTAssertEqual(groups.episodes.first?.episode.title, "First")
    }

    func testBookSearchHasNoEpisodes() throws {
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data("{\"book\":[],\"authors\":[]}".utf8))
        XCTAssertTrue(groups.episodes.isEmpty)
    }

    func testEpisodesGroupOfWrongShapeLosesOnlyItself() throws {
        let groups = try AudiobookshelfAPI.SearchGroups.decode(Data("{\"episodes\":\"nope\",\"genres\":[{\"name\":\"Comedy\",\"numItems\":2}]}".utf8))
        XCTAssertTrue(groups.episodes.isEmpty)
        XCTAssertEqual(groups.genres.map(\.name), ["Comedy"])
    }
}
