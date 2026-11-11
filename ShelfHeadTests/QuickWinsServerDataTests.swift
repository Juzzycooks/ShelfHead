import XCTest
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 F11a): fixtures written from the Audiobookshelf server source
/// (ApiRouter.getUserListeningStatsHelpers, LibraryController.stats, Auth.getUserLoginResponsePayload).
final class QuickWinsServerDataTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - listening-stats items

    func testListeningStatsDecodesItemsMap() throws {
        let stats = try decode(ListeningStats.self, """
        {"totalTime": 9000, "items": {
          "li_a": {"id": "li_a", "timeListening": 7200,
                   "mediaMetadata": {"title": "Dune", "authors": [{"id": "a1", "name": "Frank Herbert"}]}},
          "li_b": {"id": "li_b", "timeListening": 1800,
                   "mediaMetadata": {"title": "Emma", "authorName": "Jane Austen"}}
        }, "days": {"2026-11-01": 60}, "dayOfWeek": {}, "today": 0, "recentSessions": []}
        """)
        XCTAssertEqual(stats.totalTime, 9000)
        XCTAssertEqual(stats.items?.byId["li_a"]?.title, "Dune")
        XCTAssertEqual(stats.items?.byId["li_a"]?.author, "Frank Herbert")
        XCTAssertEqual(stats.items?.byId["li_b"]?.author, "Jane Austen")
    }

    func testListeningStatsWithoutItemsStillDecodes() throws {
        let stats = try decode(ListeningStats.self, #"{"totalTime": 5, "days": {}}"#)
        XCTAssertNil(stats.items)
        XCTAssertTrue(MostListened.top(stats.items).isEmpty)
    }

    func testMalformedItemsNeverFailTheWholeDecode() throws {
        let notAnObject = try decode(ListeningStats.self, #"{"totalTime": 5, "items": []}"#)
        XCTAssertEqual(notAnObject.items?.byId.count, 0)
        let badValue = try decode(ListeningStats.self, #"{"totalTime": 5, "items": {"x": 7, "y": {"id": "y", "timeListening": 60, "mediaMetadata": "nope"}}}"#)
        XCTAssertEqual(badValue.totalTime, 5)
        XCTAssertEqual(MostListened.top(badValue.items).map(\.id), ["y"])
    }

    func testTopFiveSortsByTimeAndDropsEmpties() {
        var map: [String: ListeningStatsItem] = [:]
        for (i, seconds) in [100.0, 900, 300, 0, 700, 500, 800, -5].enumerated() {
            map["id\(i)"] = ListeningStatsItem(id: "id\(i)", timeListening: seconds, title: "Book \(i)", author: nil)
        }
        let top = MostListened.top(ListeningStatsItems(byId: map), limit: 5)
        XCTAssertEqual(top.map(\.seconds), [900, 800, 700, 500, 300])
        XCTAssertEqual(MostListened.top(ListeningStatsItems(byId: map), limit: 0), [])
    }

    func testTiesBreakOnTitleThenId() {
        let map: [String: ListeningStatsItem] = [
            "k1": ListeningStatsItem(id: "k1", timeListening: 60, title: "beta"),
            "k2": ListeningStatsItem(id: "k2", timeListening: 60, title: "Alpha"),
            "k3": ListeningStatsItem(id: "k3", timeListening: 60, title: nil)
        ]
        XCTAssertEqual(MostListened.top(ListeningStatsItems(byId: map)).map(\.id), ["k3", "k2", "k1"])
    }

    func testMissingIdFallsBackToMapKey() {
        let map = ["key": ListeningStatsItem(id: nil, timeListening: 60, title: "T")]
        XCTAssertEqual(MostListened.top(ListeningStatsItems(byId: map)).first?.id, "key")
    }

    // MARK: - library stats

    func testLibraryStatsDecodesBookLibrary() throws {
        let stats = try decode(LibraryStats.self, """
        {"largestItems": [{"id": "x", "title": "Big", "size": 99}], "totalAuthors": 41,
         "authorsWithCount": [], "totalGenres": 5, "genresWithCount": [], "totalItems": 230,
         "longestItems": [], "totalSize": 52428800000, "totalDuration": 3456000.5, "numAudioTracks": 900}
        """)
        XCTAssertEqual(stats.totalItems, 230)
        XCTAssertEqual(stats.totalAuthors, 41)
        XCTAssertEqual(stats.totalSize, 52_428_800_000)
        XCTAssertEqual(stats.totalDuration, 3_456_000.5)
        XCTAssertTrue(stats.hasFigures)
        XCTAssertEqual(LibraryStatsFigures.items(stats).map(\.id), ["books", "authors", "length", "size"])
    }

    func testLibraryStatsPodcastShapeAndEmptyLibrary() throws {
        let podcast = try decode(LibraryStats.self, #"{"largestItems": [], "totalGenres": 0, "totalItems": 3, "totalSize": 10, "totalDuration": 60}"#)
        XCTAssertNil(podcast.totalAuthors)
        XCTAssertEqual(LibraryStatsFigures.items(podcast).map(\.id), ["books", "length", "size"])
        let empty = try decode(LibraryStats.self, #"{"totalItems": 0, "totalSize": 0, "totalDuration": 0, "totalAuthors": 0}"#)
        XCTAssertFalse(empty.hasFigures)
        XCTAssertTrue(LibraryStatsFigures.items(empty).isEmpty)
        let junk = try decode(LibraryStats.self, #"{"totalItems": "many"}"#)
        XCTAssertNil(junk.totalItems)
    }

    // MARK: - e-reader devices

    func testAuthorizePayloadDevices() throws {
        let payload = try decode(AuthorizeEReaderDevices.self, """
        {"user": {"id": "u"}, "userDefaultLibraryId": "l", "serverSettings": {}, "Source": "docker",
         "ereaderDevices": [
           {"name": "Kindle", "email": "me@kindle.com", "availabilityOption": "userOrUp", "users": []},
           {"email": "no-name@x.com"},
           {"name": "Kobo", "email": "k@x.com", "availabilityOption": "specificUsers", "users": ["u"]}
         ]}
        """)
        XCTAssertEqual(payload.ereaderDevices?.map(\.name), ["Kindle", "Kobo"])
        let none = try decode(AuthorizeEReaderDevices.self, #"{"user": {"id": "u"}}"#)
        XCTAssertNil(none.ereaderDevices)
    }
}
