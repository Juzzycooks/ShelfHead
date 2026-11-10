import Foundation

/// Batch 441: server calls for the Library Doctor. Endpoints confirmed against the ABS server source
/// (`server/routers/ApiRouter.js`, `LibraryItemController.js`, `SearchController.js`, `Book.js`, master
/// branch, 28 Oct 2026) and, for the read-only ones, the local test server:
///
/// - `GET /api/search/covers?title=&author=&provider=` -> `{ "results": ["https://...jpg", ...] }`
///   (plain URL strings; no permission check beyond being signed in).
/// - `POST /api/items/:id/cover` `{ "url": "..." }` -> `{ success, cover }`. The item middleware needs
///   `canUpdate` for POST/PATCH and `uploadCover` additionally needs `canUpload`; either failing is a 403.
/// - `PATCH /api/items/:id/media` `{ "metadata": { "series": [{ "name", "sequence" }] } }`. The series
///   array REPLACES the book's series list (series not named are removed from the book), and `sequence`
///   must be a JSON **string**: a number is stored as null. So `setSeriesSequence` always sends the
///   book's full current list read from the expanded item.
/// - `POST /api/items/:id/chapters` `{ "chapters": [{ "id", "start", "end", "title" }] }` ->
///   `{ success, updated }` (title non-empty string, start and end numbers, else 400).
extension AudiobookshelfAPI {

    /// Every book in `libraryId`, paged 200 at a time, capped at 10,000. `progress` receives
    /// (loaded, total) after each page.
    func fetchAllLibraryItems(libraryId: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [LibraryItem] {
        var all: [LibraryItem] = []
        var page = 0
        while all.count < 10_000 {
            try Task.checkCancellation()
            let response = try await getLibraryItems(libraryId: libraryId, limit: 200, page: page,
                                                     sort: LibrarySort.title.rawValue)
            guard !response.results.isEmpty else { break }
            all.append(contentsOf: response.results)
            progress?(all.count, response.total)
            page += 1
            if all.count >= response.total { break }
        }
        return all
    }

    /// Cover candidates (image URLs) from one metadata provider ("audible", "google", ...).
    func searchCovers(title: String, author: String?, provider: String) async throws -> [URL] {
        struct Response: Decodable { let results: [String]? }
        var items = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "provider", value: provider)]
        if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        let response: Response = try await get("/api/search/covers", queryItems: items)
        return (response.results ?? []).compactMap { URL(string: $0) }
            .filter { $0.scheme == "https" || $0.scheme == "http" }
    }

    /// Makes the server download `url` and use it as the item's cover.
    func setCover(itemId: String, url: URL) async throws {
        struct Body: Encodable { let url: String }
        let body = try JSONEncoder().encode(Body(url: url.absoluteString))
        _ = try await send(path: "/api/items/\(doctorPathComponent(itemId))/cover", method: "POST", body: body)
    }

    /// Sets the sequence of the book's entry for the series `seriesName`, keeping its other series.
    /// Reads the expanded item first because the server replaces the whole series list.
    func setSeriesSequence(itemId: String, seriesName: String, sequence: String) async throws {
        struct SeriesBody: Encodable { let name: String; let sequence: String? }
        struct MetadataBody: Encodable { let series: [SeriesBody] }
        struct Body: Encodable { let metadata: MetadataBody }

        let current = try await getItem(itemId: itemId)
        let refs = current.media?.metadata?.series ?? []
        var list: [SeriesBody] = []
        var replaced = false
        for ref in refs {
            guard let name = ref.name else { continue }
            if name.caseInsensitiveCompare(seriesName) == .orderedSame {
                list.append(SeriesBody(name: name, sequence: sequence))
                replaced = true
            } else {
                list.append(SeriesBody(name: name, sequence: ref.sequence.map(SeriesSequenceFormat.string)))
            }
        }
        if !replaced { list.append(SeriesBody(name: seriesName, sequence: sequence)) }
        let data = try JSONEncoder().encode(Body(metadata: MetadataBody(series: list)))
        _ = try await send(path: "/api/items/\(doctorPathComponent(itemId))/media", method: "PATCH", body: data)
    }

    /// Replaces the book's chapters on the server.
    func setChapters(itemId: String, chapters: [Chapter]) async throws {
        struct ChapterBody: Encodable { let id: Int; let start: Double; let end: Double; let title: String }
        struct Body: Encodable { let chapters: [ChapterBody] }
        let body = Body(chapters: chapters.enumerated().map {
            ChapterBody(id: $0.offset, start: $0.element.start, end: $0.element.end, title: $0.element.title)
        })
        _ = try await send(path: "/api/items/\(doctorPathComponent(itemId))/chapters", method: "POST",
                           body: try JSONEncoder().encode(body))
    }

    private func doctorPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
