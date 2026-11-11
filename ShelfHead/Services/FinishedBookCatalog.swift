import Foundation
import Observation

/// Batch 459: pure decisions for the finished-book catalog, split out so they can be tested
/// without I/O.
nonisolated enum FinishedBookCatalogMerge {
    /// Ids that are finished on the server but not yet cached, in `refs` order.
    static func idsToFetch(cached: [FinishedBook], refs: [FinishedRef]) -> [String] {
        let have = Set(cached.map(\.id))
        return refs.map(\.itemId).filter { !have.contains($0) }
    }

    /// Cached + freshly fetched books, restricted to what is still finished on the server
    /// (un-finishing a book removes it), with `finishedAt` taken from the server's refs.
    /// Sorted newest first. A fetched book wins over a cached one with the same id.
    static func merge(cached: [FinishedBook], fetched: [FinishedBook], refs: [FinishedRef]) -> [FinishedBook] {
        var byId: [String: FinishedBook] = [:]
        for b in cached { byId[b.id] = b }
        for b in fetched { byId[b.id] = b }
        var out: [FinishedBook] = []
        for ref in refs {
            guard var book = byId[ref.itemId] else { continue }
            book.finishedAt = ref.finishedAt
            out.append(book)
        }
        return out.sorted { $0.finishedAt > $1.finishedAt }
    }

    /// Builds a `FinishedBook` from a fetched library item.
    static func book(from item: LibraryItem, finishedAt: Date) -> FinishedBook {
        let meta = item.media?.metadata
        return FinishedBook(
            id: item.id,
            title: item.title,
            author: item.authorName,
            narratorName: meta?.narratorName,
            narrators: FinishedBook.splitNarrators(meta?.narratorName),
            genres: meta?.genres ?? [],
            publishedYear: FinishedBook.year(fromPublished: meta?.publishedYear),
            finishedAt: finishedAt,
            duration: item.duration,
            coverPath: item.media?.coverPath
        )
    }
}

/// Batch 490 (REVIEW 2026-11-11 E2): which body the Cassette Wall and the Listening Passport
/// show. An empty catalog after a failed refresh is a failure (offline, server down), not a
/// brand-new listener, so it gets the failure copy and Retry instead of "No finished books
/// yet". Cached books on screen win over a failed refresh. Pure so it's unit-tested.
nonisolated enum FinishedCatalogDisplayState: Equatable {
    case loading, failed, empty, content

    static func resolve(isEmpty: Bool, isRefreshing: Bool, hasLoaded: Bool, lastRefreshFailed: Bool) -> FinishedCatalogDisplayState {
        guard isEmpty else { return .content }
        if isRefreshing || !hasLoaded { return .loading }
        return lastRefreshFailed ? .failed : .empty
    }
}

/// Batch 459: every book the signed-in account has finished, with metadata, cached on disk
/// per account (`Application Support/ShelfHead/FinishedBooks/<scopeKey>.json`, same scope key
/// as `TranscriptStore`). Refreshed incrementally: `/api/me` supplies what is finished and
/// when; only books not already cached cost an item fetch (4 at a time). Shared by the
/// Cassette Wall, Year in Review and (Batch 463) the Listening Passport.
@MainActor
@Observable
final class FinishedBookCatalog {
    static let shared = FinishedBookCatalog()

    private(set) var books: [FinishedBook] = []
    private(set) var isRefreshing = false
    /// True once a refresh has completed (or the disk cache loaded) for the current account.
    private(set) var hasLoaded = false
    private(set) var lastRefreshFailed = false

    private var loadedScope: String?
    private var generation = 0
    private static let maxConcurrentFetches = 4

    init() {
        // Review 4 Low (ShareCard stale stats): drop the previous account's books on any account switch.
        NotificationCenter.default.addObserver(forName: .shelfheadAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    // MARK: - Public

    /// Loads the disk cache for the current account (cheap), then refreshes from the server.
    func refresh() async {
        loadFromDiskIfNeeded()
        guard !isRefreshing else { return }
        isRefreshing = true
        generation += 1
        let myGeneration = generation
        let scope = Self.currentScopeKey()
        defer { if myGeneration == generation { isRefreshing = false } }
        do {
            let user = try await AudiobookshelfAPI.shared.getCurrentUser(forceRefresh: true)
            let refs = FinishedRef.refs(from: user.mediaProgress ?? [])
            let missing = FinishedBookCatalogMerge.idsToFetch(cached: books, refs: refs)
            let dates = Dictionary(refs.map { ($0.itemId, $0.finishedAt) }, uniquingKeysWith: { a, _ in a })
            let fetched = await Self.fetchBooks(ids: missing, dates: dates)
            guard myGeneration == generation, scope == Self.currentScopeKey() else { return }
            let merged = FinishedBookCatalogMerge.merge(cached: books, fetched: fetched, refs: refs)
            books = merged
            hasLoaded = true
            lastRefreshFailed = false
            Self.save(merged, scope: scope)
        } catch {
            ShelfLog.error(.sync, "Finished-book catalog refresh failed: \(error.localizedDescription)")
            if myGeneration == generation { lastRefreshFailed = true; hasLoaded = true }
        }
    }

    /// Drops in-memory state (account switch). The next `refresh()` reloads that account's cache.
    func reset() {
        generation += 1
        books = []
        loadedScope = nil
        hasLoaded = false
        isRefreshing = false
        lastRefreshFailed = false
    }

    // MARK: - Fetching

    private static func fetchBooks(ids: [String], dates: [String: Date]) async -> [FinishedBook] {
        guard !ids.isEmpty else { return [] }
        var results: [FinishedBook] = []
        await withTaskGroup(of: FinishedBook?.self) { group in
            var iterator = ids.makeIterator()
            func addNext() -> Bool {
                guard let id = iterator.next() else { return false }
                let finished = dates[id] ?? Date()
                group.addTask {
                    // A deleted or inaccessible item just doesn't get a cassette.
                    guard let item = try? await AudiobookshelfAPI.shared.getItem(itemId: id) else { return nil }
                    return FinishedBookCatalogMerge.book(from: item, finishedAt: finished)
                }
                return true
            }
            for _ in 0..<maxConcurrentFetches { if !addNext() { break } }
            for await book in group {
                if let book { results.append(book) }
                _ = addNext()
            }
        }
        return results
    }

    // MARK: - Disk

    private func loadFromDiskIfNeeded() {
        let scope = Self.currentScopeKey()
        guard loadedScope != scope else { return }
        loadedScope = scope
        books = Self.load(scope: scope)
        if !books.isEmpty { hasLoaded = true }
    }

    nonisolated static func currentScopeKey() -> String {
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty else { return "unscoped" }
        return DownloadPaths.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
    }

    nonisolated private static func fileURL(scope: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShelfHead/FinishedBooks", isDirectory: true)
            .appendingPathComponent("\(scope).json")
    }

    nonisolated private static func load(scope: String) -> [FinishedBook] {
        guard let data = try? Data(contentsOf: fileURL(scope: scope)) else { return [] }
        return (try? JSONDecoder().decode([FinishedBook].self, from: data)) ?? []
    }

    nonisolated private static func save(_ books: [FinishedBook], scope: String) {
        let url = fileURL(scope: scope)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(books).write(to: url, options: [.atomic])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        } catch {
            ShelfLog.error(.sync, "Finished-book catalog save failed: \(error.localizedDescription)")
        }
    }
}
