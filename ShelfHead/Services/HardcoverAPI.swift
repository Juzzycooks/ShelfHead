import Foundation
import Security

/// Batch 443: Hardcover (hardcover.app) GraphQL client.
///
/// A recognised exception to "route network calls through `AudiobookshelfAPI`": this talks to a
/// third-party service, on its own ephemeral `URLSession`, with its own token. It never shares the
/// Audiobookshelf session, headers or credentials, and the ABS server never sees the token.
///
/// Endpoint `POST https://api.hardcover.app/v1/graphql`, header `authorization: Bearer <token>`
/// (a bare token is rejected). Free plan: burst 10, 60 requests a minute, 5,000 a day; throttling
/// is HTTP 429. Errors can also arrive as HTTP 200 with a top-level `errors` array.
nonisolated struct HardcoverBook: Equatable, Sendable {
    var id: Int
    var title: String
    var author: String
}

nonisolated enum HardcoverError: LocalizedError, Equatable {
    case notConnected
    case unauthorized
    case rateLimited
    case http(Int)
    case graphQL(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Hardcover isn't connected.", comment: "Reading sites error")
        case .unauthorized: return String(localized: "Hardcover rejected the token. Paste a new one.", comment: "Reading sites error")
        case .rateLimited: return String(localized: "Hardcover is busy. Try again in a minute.", comment: "Reading sites error")
        case .http(let code): return String(localized: "Hardcover returned an error (\(code.formatted())).", comment: "Reading sites error; number is an HTTP status")
        case .graphQL(let message): return message
        case .malformed: return String(localized: "Hardcover sent a reply this app couldn't read.", comment: "Reading sites error")
        }
    }
}

nonisolated enum HardcoverStatus: Int, Sendable {
    case wantToRead = 1, currentlyReading = 2, read = 3
}

actor HardcoverAPI {
    static let shared = HardcoverAPI()
    static let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!
    static let tokenPage = URL(string: "https://hardcover.app/account/api")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Token (Keychain)

    private static let tokenService = "com.shelfhead.app"
    private static let tokenAccount = "hardcover.token"

    /// Accepts a pasted token with or without a leading "Bearer ".
    nonisolated static func cleanedToken(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    func saveToken(_ raw: String) throws {
        let data = Data(Self.cleanedToken(raw).utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.tokenService,
                                    kSecAttrAccount as String: Self.tokenAccount]
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HardcoverError.graphQL("Keychain error \(status)") }
    }

    func token() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.tokenService,
                                    kSecAttrAccount as String: Self.tokenAccount,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.tokenService,
                                    kSecAttrAccount as String: Self.tokenAccount]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Transport

    nonisolated static func makeRequest(query: String, variables: [String: Any], token: String) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return req
    }

    /// Returns the `data` object. Never logs the request (the token is in its headers).
    private func send(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let token = token(), !token.isEmpty else { throw HardcoverError.notConnected }
        let req = Self.makeRequest(query: query, variables: variables, token: token)
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: break
        case 401, 403: throw HardcoverError.unauthorized
        case 429: throw HardcoverError.rateLimited
        default: throw HardcoverError.http(code)
        }
        return try Self.parseData(data)
    }

    nonisolated static func parseData(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HardcoverError.malformed }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
            let message = (first["message"] as? String) ?? "Hardcover error"
            if message.localizedCaseInsensitiveContains("jwt") || message.localizedCaseInsensitiveContains("unauthorized") {
                throw HardcoverError.unauthorized
            }
            throw HardcoverError.graphQL(message)
        }
        guard let payload = root["data"] as? [String: Any] else { throw HardcoverError.malformed }
        return payload
    }

    /// Review Low (Hardcover, 30 October 2026): `parseData` already throws on a top-level `errors` array, but
    /// Hardcover's mutations also report failure as a 200 with `{ data: { <mutation>: { error: "..." } } }`, which
    /// the update paths used to discard. Throws `.graphQL` when the mutation result carries a non-empty `error`.
    nonisolated static func throwIfMutationFailed(_ data: [String: Any], key: String) throws {
        guard let res = data[key] as? [String: Any] else { return }
        if let err = res["error"] as? String, !err.isEmpty { throw HardcoverError.graphQL(err) }
    }

    /// `me` is a list in Hardcover's schema (a single-element array), not an object.
    nonisolated static func firstMe(_ data: [String: Any]) -> [String: Any]? {
        if let list = data["me"] as? [[String: Any]] { return list.first }
        return data["me"] as? [String: Any]
    }

    nonisolated static func authorName(_ contributions: Any?) -> String {
        let list = contributions as? [[String: Any]] ?? []
        let names = list.compactMap { ($0["author"] as? [String: Any])?["name"] as? String }
        return names.joined(separator: ", ")
    }

    // MARK: Account

    /// The signed-in username.
    func me() async throws -> String {
        let data = try await send("query { me { id username } }")
        guard let me = Self.firstMe(data), let name = me["username"] as? String else { throw HardcoverError.malformed }
        return name
    }

    // MARK: Matching

    /// isbn, then asin, then title + author. nil when nothing plausible is found.
    func findBook(isbn: String?, asin: String?, title: String, author: String) async throws -> HardcoverBook? {
        if let isbn = ReadingSiteMatcher.isbn13(isbn) {
            let d = try await send("""
                query($i: String!) { editions(where: {isbn_13: {_eq: $i}}, limit: 1) { book_id } }
                """, ["i": isbn])
            if let id = ((d["editions"] as? [[String: Any]])?.first?["book_id"] as? Int) {
                return HardcoverBook(id: id, title: title, author: author)
            }
        }
        if let asin = ReadingSiteMatcher.normalizedASIN(asin) {
            let d = try await send("""
                query($a: String!) { editions(where: {asin: {_eq: $a}}, limit: 1) { book_id } }
                """, ["a": asin])
            if let id = ((d["editions"] as? [[String: Any]])?.first?["book_id"] as? Int) {
                return HardcoverBook(id: id, title: title, author: author)
            }
        }
        let core = ReadingSiteMatcher.coreTitle(title)
        guard !core.isEmpty else { return nil }
        let d = try await send("""
            query($t: String!) { books(where: {title: {_ilike: $t}}, order_by: {users_read_count: desc}, limit: 10) {
              id title contributions { author { name } } } }
            """, ["t": "%\(core)%"])
        let books = (d["books"] as? [[String: Any]] ?? []).compactMap { b -> HardcoverBook? in
            guard let id = b["id"] as? Int, let t = b["title"] as? String else { return nil }
            return HardcoverBook(id: id, title: t, author: Self.authorName(b["contributions"]))
        }
        let candidates = books.map { ReadingSiteMatcher.Candidate(id: String($0.id), title: $0.title, author: $0.author, isbn: nil, asin: nil) }
        guard let hit = ReadingSiteMatcher.match(title: title, author: author, isbn: nil, asin: nil, in: candidates),
              let id = Int(hit) else { return nil }
        return books.first { $0.id == id }
    }

    // MARK: Shelf state

    private struct UserBookRef { var id: Int; var readID: Int?; var startedAt: String? }

    private func userBook(for bookID: Int) async throws -> UserBookRef? {
        let d = try await send("""
            query($b: Int!) { me { user_books(where: {book_id: {_eq: $b}}, limit: 1) {
              id user_book_reads(order_by: {id: desc}, limit: 1) { id started_at } } } }
            """, ["b": bookID])
        guard let ub = (Self.firstMe(d)?["user_books"] as? [[String: Any]])?.first, let id = ub["id"] as? Int else { return nil }
        let read = (ub["user_book_reads"] as? [[String: Any]])?.first
        return UserBookRef(id: id, readID: read?["id"] as? Int, startedAt: read?["started_at"] as? String)
    }

    /// Sets the shelf. Updates the existing entry when the book is already on one.
    @discardableResult
    func setStatus(bookID: Int, status: HardcoverStatus) async throws -> Int {
        if let existing = try await userBook(for: bookID) {
            let d = try await send("""
                mutation($id: Int!, $o: UserBookUpdateInput!) { update_user_book(id: $id, object: $o) { id error } }
                """, ["id": existing.id, "o": ["status_id": status.rawValue]])
            try Self.throwIfMutationFailed(d, key: "update_user_book")
            return existing.id
        }
        let d = try await send("""
            mutation($o: UserBookCreateInput!) { insert_user_book(object: $o) { id error } }
            """, ["o": ["book_id": bookID, "status_id": status.rawValue]])
        guard let res = d["insert_user_book"] as? [String: Any] else { throw HardcoverError.malformed }
        if let err = res["error"] as? String, !err.isEmpty { throw HardcoverError.graphQL(err) }
        guard let id = res["id"] as? Int else { throw HardcoverError.malformed }
        return id
    }

    private static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Records listening progress on the current read (creates one when none exists).
    /// Uses `progress_seconds`, the audiobook field of `DatesReadInput`.
    func updateProgress(bookID: Int, seconds: Int, now: Date = Date()) async throws {
        let ub: UserBookRef
        if let existing = try await userBook(for: bookID) { ub = existing } else {
            let id = try await setStatus(bookID: bookID, status: .currentlyReading)
            ub = UserBookRef(id: id, readID: nil, startedAt: nil)
        }
        let started = ub.startedAt ?? Self.dateString(now)
        if let readID = ub.readID {
            let d = try await send("""
                mutation($id: Int!, $o: DatesReadInput!) { update_user_book_read(id: $id, object: $o) { id error } }
                """, ["id": readID, "o": ["started_at": started, "progress_seconds": seconds]])
            try Self.throwIfMutationFailed(d, key: "update_user_book_read")
        } else {
            let d = try await send("""
                mutation($u: Int!, $r: DatesReadInput!) { insert_user_book_read(user_book_id: $u, user_book_read: $r) { id error } }
                """, ["u": ub.id, "r": ["started_at": started, "progress_seconds": seconds]])
            try Self.throwIfMutationFailed(d, key: "insert_user_book_read")
        }
    }

    /// Marks the book Read and closes the current read with a finish date.
    func finish(bookID: Int, on date: Date) async throws {
        let id = try await setStatus(bookID: bookID, status: .read)
        // Review 5 Low (Hardcover finish): a finish that didn't land must not report success
        guard let ub = try await userBook(for: bookID), ub.id == id else { throw HardcoverError.malformed }
        let day = Self.dateString(date)
        if let readID = ub.readID {
            // Review 4 Low (Hardcover mutation errors): surface a 200-with-error result.
            let d = try await send("""
                mutation($id: Int!, $o: DatesReadInput!) { update_user_book_read(id: $id, object: $o) { id error } }
                """, ["id": readID, "o": ["started_at": ub.startedAt ?? day, "finished_at": day]])
            try Self.throwIfMutationFailed(d, key: "update_user_book_read")
        } else {
            let d = try await send("""
                mutation($u: Int!, $r: DatesReadInput!) { insert_user_book_read(user_book_id: $u, user_book_read: $r) { id error } }
                """, ["u": ub.id, "r": ["started_at": day, "finished_at": day]])
            try Self.throwIfMutationFailed(d, key: "insert_user_book_read")
        }
    }

    /// Star rating, 0.5 to 5 in half steps.
    func rate(bookID: Int, rating: Double) async throws {
        guard let value = ReadingSiteMatcher.clampedRating(rating) else { return }
        let id: Int
        if let existing = try await userBook(for: bookID) { id = existing.id } else {
            id = try await setStatus(bookID: bookID, status: .read)
        }
        // Review 4 Low (Hardcover mutation errors)
        let d = try await send("""
            mutation($id: Int!, $o: UserBookUpdateInput!) { update_user_book(id: $id, object: $o) { id error } }
            """, ["id": id, "o": ["rating": value]])
        try Self.throwIfMutationFailed(d, key: "update_user_book")
    }

    // MARK: Want to read

    func wantToRead() async throws -> [WantToReadEntry] {
        let d = try await send("""
            query { me { user_books(where: {status_id: {_eq: 1}}, order_by: {date_added: desc}, limit: 1000) {
              book { id title slug contributions { author { name } } } } } }
            """)
        let rows = Self.firstMe(d)?["user_books"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let book = row["book"] as? [String: Any], let title = book["title"] as? String else { return nil }
            let slug = (book["slug"] as? String).map { "https://hardcover.app/books/\($0)" }
            return WantToReadEntry(title: title, author: Self.authorName(book["contributions"]), isbn: nil, source: .hardcover, url: slug)
        }
    }
}
