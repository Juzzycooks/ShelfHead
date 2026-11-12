import Foundation

/// Batch 446: collection writes for smart collections. Endpoints confirmed against the ABS server
/// source (`server/controllers/CollectionController.js`, master, 28 Oct 2026) and the local test server:
///
/// - `POST /api/collections` `{ libraryId, name, description?, books:[itemIds] }`: needs at least one
///   book (400 "No books" otherwise); returns the expanded collection.
/// - `PATCH /api/collections/:id` `{ name?, description? }`.
/// - `POST /api/collections/:id/batch/add` and `/batch/remove` `{ books:[itemIds] }`: return the
///   expanded collection. Removing the last book leaves an empty collection.
/// - `GET /api/libraries/:id/collections` -> `{ results:[...] }`, each with `description` and `books`.
/// - Permission: the middleware answers 403 to POST/PATCH unless the user `canUpdate` (admins and root
///   always can), and to DELETE unless `canDelete`. `User.canUpdateLibrary` mirrors the first.
/// One playlist row as the server's write endpoints take it. `episodeId` is omitted for books.
struct PlaylistItemRef: Codable, Equatable, Sendable {
    let libraryItemId: String
    var episodeId: String? = nil
}

struct ServerCollectionSummary: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let bookIds: [String]

    private struct Book: Decodable { let id: String }
    enum CodingKeys: String, CodingKey { case id, name, description, books }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        bookIds = ((try? c.decodeIfPresent(LossyArray<Book>.self, forKey: .books)) ?? nil)?.elements.map(\.id) ?? []
    }
}

extension AudiobookshelfAPI {

    private func collectionPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    /// Collections of a library with their descriptions and member ids (the existing
    /// `getCollections` model does not keep the description).
    func getCollectionSummaries(libraryId: String) async throws -> [ServerCollectionSummary] {
        struct Response: Decodable {
            let results: [ServerCollectionSummary]?
            let collections: [ServerCollectionSummary]?
        }
        let response: Response = try await get("/api/libraries/\(collectionPathComponent(libraryId))/collections")
        return response.results ?? response.collections ?? []
    }

    /// Creates a collection and returns its id. `bookIds` must not be empty (server rule).
    func createCollection(libraryId: String, name: String, description: String?, bookIds: [String]) async throws -> String {
        struct Body: Encodable { let libraryId: String; let name: String; let description: String?; let books: [String] }
        struct Created: Decodable { let id: String }
        let created: Created = try await post("/api/collections",
                                              body: Body(libraryId: libraryId, name: name, description: description, books: bookIds))
        return created.id
    }

    func updateCollection(id: String, name: String? = nil, description: String? = nil) async throws {
        struct Body: Encodable { let name: String?; let description: String? }
        let body = try JSONEncoder().encode(Body(name: name, description: description))
        _ = try await send(path: "/api/collections/\(collectionPathComponent(id))", method: "PATCH", body: body)
    }

    func addBooksToCollection(id: String, bookIds: [String]) async throws {
        guard !bookIds.isEmpty else { return }
        struct Body: Encodable { let books: [String] }
        let body = try JSONEncoder().encode(Body(books: bookIds))
        _ = try await send(path: "/api/collections/\(collectionPathComponent(id))/batch/add", method: "POST", body: body)
    }

    func removeBooksFromCollection(id: String, bookIds: [String]) async throws {
        guard !bookIds.isEmpty else { return }
        struct Body: Encodable { let books: [String] }
        let body = try JSONEncoder().encode(Body(books: bookIds))
        _ = try await send(path: "/api/collections/\(collectionPathComponent(id))/batch/remove", method: "POST", body: body)
    }

    func deleteCollection(id: String) async throws {
        _ = try await send(path: "/api/collections/\(collectionPathComponent(id))", method: "DELETE")
    }

    // MARK: Playlists (REVIEW 2026-11-11 F2)
    //
    // Verified against ABS master `PlaylistController.js` / `ApiRouter.js` (12 Nov 2026):
    // - `POST /api/playlists` `{ libraryId, name, description?, items:[{libraryItemId, episodeId?}] }`
    //   (items may be empty; all rows must be books or all episodes); returns the expanded playlist.
    // - `PATCH /api/playlists/:id` `{ name?, description?, items? }`; `items` re-orders, and must be the
    //   full list (400 "Length mismatch" otherwise).
    // - `DELETE /api/playlists/:id`; `POST /api/playlists/:id/batch/add|remove` `{ items:[...] }`.
    //   Removing the last item makes the server delete the playlist.
    // - Owner only (403 otherwise); no `canUpdate` needed.

    func createPlaylist(libraryId: String, name: String, items: [PlaylistItemRef]) async throws -> String {
        struct Body: Encodable { let libraryId: String; let name: String; let items: [PlaylistItemRef] }
        struct Created: Decodable { let id: String }
        let created: Created = try await post("/api/playlists", body: Body(libraryId: libraryId, name: name, items: items))
        return created.id
    }

    func renamePlaylist(id: String, name: String) async throws {
        struct Body: Encodable { let name: String }
        let body = try JSONEncoder().encode(Body(name: name))
        _ = try await send(path: "/api/playlists/\(collectionPathComponent(id))", method: "PATCH", body: body)
    }

    /// Re-orders a playlist; `items` is every row in the new order.
    func reorderPlaylist(id: String, items: [PlaylistItemRef]) async throws {
        struct Body: Encodable { let items: [PlaylistItemRef] }
        let body = try JSONEncoder().encode(Body(items: items))
        _ = try await send(path: "/api/playlists/\(collectionPathComponent(id))", method: "PATCH", body: body)
    }

    func deletePlaylist(id: String) async throws {
        _ = try await send(path: "/api/playlists/\(collectionPathComponent(id))", method: "DELETE")
    }

    func addToPlaylist(id: String, items: [PlaylistItemRef]) async throws {
        guard !items.isEmpty else { return }
        struct Body: Encodable { let items: [PlaylistItemRef] }
        let body = try JSONEncoder().encode(Body(items: items))
        _ = try await send(path: "/api/playlists/\(collectionPathComponent(id))/batch/add", method: "POST", body: body)
    }

    func removeFromPlaylist(id: String, items: [PlaylistItemRef]) async throws {
        guard !items.isEmpty else { return }
        struct Body: Encodable { let items: [PlaylistItemRef] }
        let body = try JSONEncoder().encode(Body(items: items))
        _ = try await send(path: "/api/playlists/\(collectionPathComponent(id))/batch/remove", method: "POST", body: body)
    }
}
