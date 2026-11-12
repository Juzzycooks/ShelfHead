import XCTest
@testable import ShelfHead

/// REVIEW 2026-11-11 F2: the pure decisions behind Add to Playlist / Collection and the list editor.
final class Top10PlaylistEditTests: XCTestCase {

    private func user(type: String, update: Bool? = nil, delete: Bool? = nil) throws -> User {
        let perms = "{" + [update.map { "\"update\":\($0)" }, delete.map { "\"delete\":\($0)" }]
            .compactMap { $0 }.joined(separator: ",") + "}"
        let json = "{\"id\":\"u1\",\"username\":\"u\",\"type\":\"\(type)\",\"permissions\":\(perms)}"
        return try JSONDecoder().decode(User.self, from: Data(json.utf8))
    }

    func testTrimmedName() {
        XCTAssertNil(ListEditing.trimmedName("   \n"))
        XCTAssertEqual(ListEditing.trimmedName("  Road trip "), "Road trip")
    }

    func testAddToCollectionNeedsUpdatePermission() throws {
        XCTAssertTrue(ListEditing.offersAddToCollection(user: try user(type: "admin"), isPodcast: false))
        XCTAssertTrue(ListEditing.offersAddToCollection(user: try user(type: "user", update: true), isPodcast: false))
        XCTAssertFalse(ListEditing.offersAddToCollection(user: try user(type: "user", update: false), isPodcast: false))
        XCTAssertFalse(ListEditing.offersAddToCollection(user: nil, isPodcast: false))
        XCTAssertFalse(ListEditing.offersAddToCollection(user: try user(type: "admin"), isPodcast: true))
    }

    func testPlaylistOfferedForBooksOnly() {
        XCTAssertTrue(ListEditing.offersAddToPlaylist(isPodcast: false))
        XCTAssertFalse(ListEditing.offersAddToPlaylist(isPodcast: true))
    }

    func testDeleteCollectionNeedsDeletePermission() throws {
        XCTAssertTrue(ListEditing.canDeleteCollection(user: try user(type: "root")))
        XCTAssertTrue(ListEditing.canDeleteCollection(user: try user(type: "user", delete: true)))
        XCTAssertFalse(ListEditing.canDeleteCollection(user: try user(type: "user", update: true)))
    }

    func testEditOutcomeReorderOnly() {
        let a = PlaylistItemRef(libraryItemId: "a"), b = PlaylistItemRef(libraryItemId: "b"), c = PlaylistItemRef(libraryItemId: "c")
        let out = ListEditing.editOutcome(original: [a, b, c], edited: [c, a, b])
        XCTAssertTrue(out.removed.isEmpty)
        XCTAssertEqual(out.order, [c, a, b])
    }

    func testEditOutcomeRemovalKeepsOrderUntouched() {
        let a = PlaylistItemRef(libraryItemId: "a"), b = PlaylistItemRef(libraryItemId: "b"), c = PlaylistItemRef(libraryItemId: "c")
        let out = ListEditing.editOutcome(original: [a, b, c], edited: [a, c])
        XCTAssertEqual(out.removed, [b])
        XCTAssertNil(out.order, "survivors are still in server order, so no re-order PATCH")
    }

    func testEditOutcomeRemovalPlusReorder() {
        let a = PlaylistItemRef(libraryItemId: "a"), b = PlaylistItemRef(libraryItemId: "b"), c = PlaylistItemRef(libraryItemId: "c")
        let out = ListEditing.editOutcome(original: [a, b, c], edited: [c, a])
        XCTAssertEqual(out.removed, [b])
        XCTAssertEqual(out.order, [c, a])
    }

    func testEditOutcomeDistinguishesEpisodesOfOneShow() {
        let e1 = PlaylistItemRef(libraryItemId: "show", episodeId: "e1"), e2 = PlaylistItemRef(libraryItemId: "show", episodeId: "e2")
        let out = ListEditing.editOutcome(original: [e1, e2], edited: [e2])
        XCTAssertEqual(out.removed, [e1])
    }

    func testPlaylistItemRefOmitsNilEpisodeId() throws {
        let data = try JSONEncoder().encode(PlaylistItemRef(libraryItemId: "x"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("episodeId"))
        XCTAssertTrue(text.contains("\"libraryItemId\":\"x\""))
    }
}
