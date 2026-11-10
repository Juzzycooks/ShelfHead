import XCTest
@testable import ShelfHead

/// Audiobookshelf 2.36 returns the library's collections and playlists as a paginated
/// `{ "results": [...] }`; older servers use `{ "collections": [...] }` / `{ "playlists": [...] }`.
/// The Library's "More" scopes menu stayed hidden on 2.36 because only the old shape was read.
final class BrowseResponseDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testCollectionsDecodeFromResultsKey() throws {
        let r = try decode(CollectionsResponse.self, #"{"results":[{"id":"c1","name":"Victorian Mysteries","books":[]}],"total":1}"#)
        XCTAssertEqual(r.collections.map(\.id), ["c1"])
        XCTAssertEqual(r.collections.first?.displayName, "Victorian Mysteries")
    }

    func testCollectionsDecodeFromLegacyCollectionsKey() throws {
        let r = try decode(CollectionsResponse.self, #"{"collections":[{"id":"c2","name":"Old"}]}"#)
        XCTAssertEqual(r.collections.map(\.id), ["c2"])
    }

    func testPlaylistsDecodeFromResultsKey() throws {
        let r = try decode(PlaylistsResponse.self, #"{"results":[{"id":"p1","name":"Road trip","items":[]}]}"#)
        XCTAssertEqual(r.playlists.map(\.id), ["p1"])
    }

    func testPlaylistsDecodeFromLegacyPlaylistsKey() throws {
        let r = try decode(PlaylistsResponse.self, #"{"playlists":[{"id":"p2"}]}"#)
        XCTAssertEqual(r.playlists.map(\.id), ["p2"])
    }

    func testEmptyResultsIsAnEmptyList() throws {
        XCTAssertTrue(try decode(CollectionsResponse.self, #"{"results":[]}"#).collections.isEmpty)
    }

    func testNeitherKeyDecodesAsEmpty() throws {
        XCTAssertTrue(try decode(CollectionsResponse.self, #"{"other":[]}"#).collections.isEmpty)
    }

    func testAMalformedRowIsDroppedNotFatal() throws {
        let r = try decode(CollectionsResponse.self, #"{"results":[{"id":null},{"id":"ok","name":"Fine"}]}"#)
        XCTAssertEqual(r.collections.map(\.id), ["ok"])
    }
}
