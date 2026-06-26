import Foundation
import UIKit

actor AudiobookshelfAPI {
    static let shared = AudiobookshelfAPI()

    /// In-flight refresh, so concurrent 401s trigger only a single refresh
    /// (avoids same-second refresh-token collisions on the server).
    private var refreshTask: Task<Bool, Never>?

    // Credentials live in AuthStore (in-memory, seeded from Keychain).
    var serverURL: String { AuthStore.shared.serverURL }
    var authToken: String { AuthStore.shared.accessToken }
    var isConfigured: Bool { AuthStore.shared.isConfigured }

    /// Seed the in-memory store (used on launch when restoring a saved session).
    func configure(serverURL: String, accessToken: String, refreshToken: String?) {
        AuthStore.shared.set(serverURL: serverURL, accessToken: accessToken, refreshToken: refreshToken)
    }

    // MARK: - Authentication

    func login(serverURL: String, username: String, password: String) async throws -> LoginResponse {
        let url = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let requestURL = URL(string: "\(url)/login") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ask the server (v2.26+) to return the refresh token in the body —
        // mobile clients can't use the HTTP-only cookie the web client relies on.
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")

        request.httpBody = try JSONEncoder().encode(LoginRequest(username: username, password: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard let access = loginResponse.user.effectiveAccessToken else {
            throw APIError.unauthorized
        }

        AuthStore.shared.set(serverURL: url, accessToken: access, refreshToken: loginResponse.user.refreshToken)
        try? await persistTokens(access: access, refresh: loginResponse.user.refreshToken)
        return loginResponse
    }

    func logout() async {
        let server = AuthStore.shared.serverURL
        guard let url = URL(string: "\(server)/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AuthStore.shared.accessToken)", forHTTPHeaderField: "Authorization")
        if let refresh = AuthStore.shared.refreshToken {
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    private func persistTokens(access: String, refresh: String?) async throws {
        try await KeychainService.shared.save(access, for: .authToken)
        if let refresh {
            try await KeychainService.shared.save(refresh, for: .refreshToken)
        }
    }

    // MARK: - Token Refresh

    /// Ensures a single refresh runs at a time; returns true if a usable token is now available.
    private func refreshIfPossible() async -> Bool {
        if let task = refreshTask { return await task.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Refreshes the access token if it expires within `minRemaining` seconds (or always
    /// when `force` is true). Keeps a streamed AVPlayer URL's token valid, since the token
    /// is baked into the asset URL and access tokens expire ~hourly.
    func ensureFreshAccessToken(minRemaining: TimeInterval = 600, force: Bool = false) async {
        if force { _ = await refreshIfPossible(); return }
        guard let exp = Self.jwtExpiry(AuthStore.shared.accessToken) else { return }
        if exp.timeIntervalSinceNow < minRemaining { _ = await refreshIfPossible() }
    }

    /// Decodes the `exp` (seconds since epoch) claim from a JWT, if present.
    private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func performRefresh() async -> Bool {
        // 1) Try the refresh token.
        if let refresh = AuthStore.shared.refreshToken, !refresh.isEmpty,
           let url = URL(string: "\(AuthStore.shared.serverURL)/auth/refresh") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            request.setValue("true", forHTTPHeaderField: "x-return-tokens")

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let lr = try? JSONDecoder().decode(LoginResponse.self, from: data),
               let access = lr.user.effectiveAccessToken {
                let newRefresh = lr.user.refreshToken ?? refresh
                AuthStore.shared.updateTokens(accessToken: access, refreshToken: newRefresh)
                try? await persistTokens(access: access, refresh: newRefresh)
                return true
            }
        }

        // 2) Fall back to stored credentials. ABS native clients commonly hit a
        // "lost rotation" logout where the refresh token is rejected; silently
        // re-authenticating with the saved credentials avoids kicking the user out.
        return await reauthenticateWithStoredCredentials()
    }

    private func reauthenticateWithStoredCredentials() async -> Bool {
        guard let username = try? await KeychainService.shared.get(.username),
              let password = try? await KeychainService.shared.get(.password),
              !username.isEmpty, !password.isEmpty else {
            return false
        }
        let server = AuthStore.shared.serverURL
        return ((try? await login(serverURL: server, username: username, password: password)) != nil)
    }

    // MARK: - Libraries

    func getLibraries() async throws -> [Library] {
        struct LibrariesResponse: Codable {
            let libraries: [Library]
        }
        let response: LibrariesResponse = try await get("/api/libraries")
        return response.libraries
    }

    func getLibraryItems(libraryId: String, limit: Int = 50, page: Int = 0, filter: String? = nil, sort: String = "media.metadata.title", desc: Bool = false) async throws -> LibraryItemsResponse {
        var params: [(String, String)] = [
            ("limit", "\(limit)"),
            ("page", "\(page)"),
            ("sort", sort),
            ("desc", desc ? "1" : "0")
        ]
        if let filter { params.append(("filter", filter)) }
        return try await get("/api/libraries/\(libraryId)/items\(encodedQuery(params))")
    }

    func getSeries(libraryId: String, limit: Int = 100, page: Int = 0, sort: String = "name", desc: Bool = false) async throws -> SeriesResponse {
        let params: [(String, String)] = [
            ("limit", "\(limit)"),
            ("page", "\(page)"),
            ("sort", sort),
            ("desc", desc ? "1" : "0")
        ]
        return try await get("/api/libraries/\(libraryId)/series\(encodedQuery(params))")
    }

    /// Authors / genres / series lists for building filter pickers and browse screens.
    func getFilterData(libraryId: String) async throws -> LibraryFilterData {
        let response: LibraryDataResponse = try await get("/api/libraries/\(libraryId)?include=filterdata")
        return response.filterdata ?? LibraryFilterData(authors: nil, genres: nil, tags: nil, series: nil, narrators: nil, languages: nil)
    }

    func getListeningStats() async throws -> ListeningStats {
        return try await get("/api/me/listening-stats")
    }

    func getCollections(libraryId: String) async throws -> [BookCollection] {
        let response: CollectionsResponse = try await get("/api/libraries/\(libraryId)/collections")
        return response.collections
    }

    func getPlaylists(libraryId: String) async throws -> [Playlist] {
        let response: PlaylistsResponse = try await get("/api/libraries/\(libraryId)/playlists")
        return response.playlists
    }

    func getPersonalizedView(libraryId: String) async throws -> [PersonalizedView] {
        return try await get("/api/libraries/\(libraryId)/personalized")
    }

    // MARK: - Items

    func getItem(itemId: String) async throws -> LibraryItem {
        return try await get("/api/items/\(itemId)", queryItems: [
            URLQueryItem(name: "expanded", value: "1"),
            URLQueryItem(name: "include", value: "progress")
        ])
    }

    // MARK: - Playback Session

    func startPlaybackSession(itemId: String) async throws -> PlaybackSession {
        let body = PlaybackSessionRequest()
        return try await post("/api/items/\(itemId)/play", body: body)
    }

    func syncSession(sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = SyncSessionRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        try await postNoResponse("/api/session/\(sessionId)/sync", body: body)
    }

    func closeSession(sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = SyncSessionRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        try await postNoResponse("/api/session/\(sessionId)/close", body: body)
    }

    // MARK: - User/Progress

    func getCurrentUser() async throws -> User {
        return try await get("/api/me")
    }

    /// Books started but not finished, most-recent first (for Siri "resume").
    func getItemsInProgress() async throws -> [LibraryItem] {
        struct Response: Codable { let libraryItems: [LibraryItem] }
        let response: Response = try await get("/api/me/items-in-progress?limit=5")
        return response.libraryItems
    }

    func updateProgress(libraryItemId: String, progress: Double, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        let body = ProgressUpdate(progress: progress, currentTime: currentTime, isFinished: isFinished, duration: duration)
        try await patchNoResponse("/api/me/progress/\(libraryItemId)", body: body)
    }

    // MARK: - Bookmarks

    func getBookmarks(itemId: String) async throws -> [AudioBookmark] {
        let user = try await getCurrentUser()
        return (user.bookmarks ?? [])
            .filter { $0.libraryItemId == itemId }
            .sorted { $0.time < $1.time }
    }

    func addBookmark(itemId: String, time: Double, title: String) async throws {
        struct Body: Codable { let time: Double; let title: String }
        try await postNoResponse("/api/me/item/\(itemId)/bookmark", body: Body(time: time, title: title))
    }

    func deleteBookmark(itemId: String, time: Double) async throws {
        _ = try await send(path: "/api/me/item/\(itemId)/bookmark/\(Int(time))", method: "DELETE")
    }

    // MARK: - Search

    func search(libraryId: String, query: String) async throws -> [LibraryItem] {
        struct SearchResponse: Codable {
            let book: [SearchResult]?

            struct SearchResult: Codable {
                let libraryItem: LibraryItem
            }
        }

        let queryItems = [URLQueryItem(name: "q", value: query)]
        let response: SearchResponse = try await get("/api/libraries/\(libraryId)/search", queryItems: queryItems)
        return response.book?.map(\.libraryItem) ?? []
    }

    // MARK: - Networking Helpers

    private func get<T: Codable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path: path, method: "GET", queryItems: queryItems)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Codable, B: Codable>(_ path: String, body: B) async throws -> T {
        let data = try await send(path: path, method: "POST", body: try JSONEncoder().encode(body))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postNoResponse<B: Codable>(_ path: String, body: B) async throws {
        _ = try await send(path: path, method: "POST", body: try JSONEncoder().encode(body))
    }

    private func patchNoResponse<B: Codable>(_ path: String, body: B) async throws {
        _ = try await send(path: path, method: "PATCH", body: try JSONEncoder().encode(body))
    }

    /// Central request executor with one automatic refresh-and-retry on 401.
    private func send(path: String, method: String, queryItems: [URLQueryItem] = [], body: Data? = nil, allowRetry: Bool = true) async throws -> Data {
        let request = try buildRequest(path: path, method: method, queryItems: queryItems, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 401 && allowRetry {
            if await refreshIfPossible() {
                // Rebuild with the fresh token and retry once.
                return try await send(path: path, method: method, queryItems: queryItems, body: body, allowRetry: false)
            }
        }

        try validateStatus(http.statusCode)
        return data
    }

    /// Builds a query string with strict percent-encoding so Base64 filter values
    /// (which contain `+`, `/`, `=`) survive transport intact.
    private func encodedQuery(_ params: [(String, String)]) -> String {
        guard !params.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics
        let parts = params.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }
        return "?" + parts.joined(separator: "&")
    }

    private func buildRequest(path: String, method: String, queryItems: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: "\(AuthStore.shared.serverURL)\(path)") else {
            throw APIError.invalidURL
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(AuthStore.shared.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode)
    }

    private func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 500...599:
            throw APIError.serverError(statusCode)
        default:
            throw APIError.httpError(statusCode)
        }
    }
}

// MARK: - API Errors

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case serverError(Int)
    case httpError(Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Authentication failed. Please check your credentials."
        case .forbidden:
            return "Access denied"
        case .notFound:
            return "Resource not found"
        case .serverError(let code):
            return "Server error (\(code))"
        case .httpError(let code):
            return "HTTP error (\(code))"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        }
    }
}
