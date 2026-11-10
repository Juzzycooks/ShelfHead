import Foundation

/// Batch 457: the body for `POST /api/users` and `PATCH /api/users/:id` (Audiobookshelf 2.36, admin or root only).
/// Pure value types so the shape is unit-tested; the server enforces every restriction itself.
nonisolated struct ABSUserBody: Encodable, Equatable {
    struct Permissions: Encodable, Equatable {
        var download: Bool
        var update = false
        var delete = false
        var upload = false
        var createEreader = false
        var accessAllLibraries: Bool
        var accessAllTags: Bool
        var accessExplicitContent = false
        var selectedTagsNotAccessible = false
    }

    var username: String
    /// Omitted from a PATCH that doesn't change it.
    var password: String?
    var type = "user"
    var isActive = true
    var permissions: Permissions
    var librariesAccessible: [String]
    var itemTagsSelected: [String]

    /// A child's account: explicit content off, only the chosen libraries, and only items carrying one of `tags`
    /// when any are given (an empty list means every tag). Never able to update, delete, upload or create e-readers.
    static func child(username: String, password: String?, libraryIds: [String], tags: [String],
                      allowDownloads: Bool) -> ABSUserBody {
        ABSUserBody(username: username, password: password,
                    permissions: Permissions(download: allowDownloads,
                                             accessAllLibraries: false,
                                             accessAllTags: tags.isEmpty),
                    librariesAccessible: libraryIds, itemTagsSelected: tags)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Batch 457: readable one-time passwords for a child's account. Letters and digits with the look-alikes removed.
nonisolated enum KidPasswordGenerator {
    static let alphabet = Array("abcdefghijkmnpqrstuvwxyzACDEFGHJKLMNPQRTUVWXY346789")

    static func make<G: RandomNumberGenerator>(length: Int = 12, using generator: inout G) -> String {
        String((0..<max(length, 1)).map { _ in alphabet.randomElement(using: &generator)! })
    }

    static func make(length: Int = 12) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(length: length, using: &generator)
    }
}

extension AudiobookshelfAPI {
    private struct UserEnvelope: Decodable { let user: User }
    private struct UsersEnvelope: Decodable { let users: [User] }

    /// `POST /api/users`. Admin only; a non-admin session gets `APIError.forbidden`, a taken name a 400.
    func createUser(_ body: ABSUserBody) async throws -> User {
        let data = try await send(path: "/api/users", method: "POST", body: try body.encoded())
        return try JSONDecoder().decode(UserEnvelope.self, from: data).user
    }

    /// `PATCH /api/users/:id`.
    func updateUser(id: String, _ body: ABSUserBody) async throws {
        _ = try await send(path: "/api/users/\(id)", method: "PATCH", body: try body.encoded())
    }

    /// `DELETE /api/users/:id`.
    func deleteUser(id: String) async throws {
        _ = try await send(path: "/api/users/\(id)", method: "DELETE")
    }

    /// `GET /api/users` (admin only), to find a child's server id from its username.
    func listUsers() async throws -> [User] {
        let data = try await send(path: "/api/users", method: "GET")
        return try JSONDecoder().decode(UsersEnvelope.self, from: data).users
    }
}
