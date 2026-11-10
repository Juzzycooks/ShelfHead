import Foundation

// MARK: - Standalone library browsing (Stage 4)

// MARK: - In-progress shelf cache (Polish pass WA-3)

/// Disk cache of the last in-progress shelf, so a Watch with no connection still draws its
/// shelf (and can resume a book it already has downloaded at a sensible place).
///
/// **The Watch cache is for display and offline resume only; it must never override
/// progress.** Rules, pinned by `PolishWatchTests`:
/// - lives in `Caches/` (the system may purge it; nothing depends on it existing);
/// - versioned, and keyed by the account scope (the server address). A version or scope
///   mismatch is ignored; a file that fails to decode is deleted;
/// - cleared on sign-out and on a server/account switch (`WatchStore.resetAccountScopedState`);
/// - a cached position is only ever a *reading* offered to `WatchServerProgressPicker` when the
///   server did not answer in time (`resumeCandidate`). It is never written to
///   `WatchPendingProgressQueue` or pushed, so it can't be sent as new listening.
///   A missing `lastUpdate` stays `nil` (unknown), never `0`.
struct WatchInProgressCacheFile: Codable {
    var version: Int
    var scope: String
    var savedAt: Date
    var items: [WatchLibraryItem]
}

enum WatchInProgressCache {
    /// Bump when `WatchLibraryItem`'s encoded shape changes; older files are then ignored.
    static let version = 1

    nonisolated static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("WatchInProgressShelf.json")
    }

    /// The account scope: the server address in comparable form. Empty means no session.
    static func scope(serverURL: String) -> String {
        WatchStore.comparableServerURL(serverURL)
    }

    /// What is worth keeping: the shelf's fields, without chapter lists (the largest part of a
    /// full item) so the file stays small.
    static func slimmed(_ items: [WatchLibraryItem]) -> [WatchLibraryItem] {
        items.map { item in
            var media = item.media
            if let m = item.media {
                media = WatchMedia(metadata: m.metadata, coverPath: m.coverPath, duration: m.duration,
                                   chapters: nil, numChapters: m.numChapters, numAudioFiles: m.numAudioFiles)
            }
            return WatchLibraryItem(id: item.id, libraryId: item.libraryId, mediaType: item.mediaType,
                                    media: media, addedAt: item.addedAt, updatedAt: item.updatedAt,
                                    mediaProgress: item.mediaProgress, size: item.size)
        }
    }

    /// Pure: whether a decoded file may be used for `scope`.
    static func isUsable(_ file: WatchInProgressCacheFile, scope: String) -> Bool {
        !scope.isEmpty && file.version == version && file.scope == scope
    }

    static func load(scope: String, from url: URL = defaultFileURL()) -> [WatchLibraryItem]? {
        guard !scope.isEmpty, let data = try? Data(contentsOf: url) else { return nil }
        guard let file = try? JSONDecoder().decode(WatchInProgressCacheFile.self, from: data) else {
            // Discard on decode failure and carry on.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return isUsable(file, scope: scope) ? file.items : nil
    }

    static func save(_ items: [WatchLibraryItem], scope: String, to url: URL = defaultFileURL()) {
        guard !scope.isEmpty else { return }
        let file = WatchInProgressCacheFile(version: version, scope: scope, savedAt: Date(), items: slimmed(items))
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(at url: URL = defaultFileURL()) {
        try? FileManager.default.removeItem(at: url)
    }

    /// One cached book's position as a server-side reading, or `nil` when it has none.
    static func reading(itemId: String, in items: [WatchLibraryItem]) -> WatchServerProgress? {
        guard let progress = items.first(where: { $0.id == itemId })?.mediaProgress,
              progress.isFinished != true,
              let time = progress.currentTime, time.isFinite, time > 0 else { return nil }
        return WatchServerProgress(currentTime: time, lastUpdateMs: progress.lastUpdate.map(Double.init))
    }

    /// The cached reading offered as an *offline floor*: only when the server did not answer
    /// (`fresh == nil`). When the server answered, its reading is the one that counts.
    static func resumeCandidate(fresh: WatchServerProgress?, cached: WatchServerProgress?) -> WatchServerProgress? {
        fresh == nil ? cached : nil
    }

    /// Disk read for the engine's resume decision (`StandaloneAudioEngine.play`).
    static func cachedReading(itemId: String, serverURL: String) -> WatchServerProgress? {
        guard let items = load(scope: scope(serverURL: serverURL)) else { return nil }
        return reading(itemId: itemId, in: items)
    }
}

/// Backs `StandaloneLibraryView`. Owns real paging against
/// `WatchAudiobookshelfAPI.getLibraryItems`/`search` — the workstream the addendum's
/// §4 identified as missing between "auth" and "playback": Stage 3 only ever played
/// from the phone's capped, push-based mirror lists (`RecentlyAddedView.recentlyAdded`,
/// the iPhone downloads mirror, now `StandaloneDownloadsView`'s "On iPhone" section — each capped at a small count purely to fit under
/// WatchConnectivity's payload ceiling, per `WatchSessionManager.swift:85–87`'s own
/// doc comment). A standalone Watch fetching its own library over its own network
/// connection has no reason to inherit that ceiling — this store is what replaces it.
///
/// `@MainActor @Observable final class`, same shape as `WatchStore`/
/// `StandaloneAudioEngine` and for the identical reason: `@Observable`'s
/// access-tracking is generated on the concrete type, and this project has already
/// deliberately avoided protocol existentials in `@Environment` for exactly that
/// reason (see `WatchStore`'s own type doc comment).
@MainActor
@Observable
final class WatchStandaloneLibraryStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let api: WatchAudiobookshelfAPI
    /// Persists the user's last-chosen library across launches — a Watch with only
    /// one library (the common case) never surfaces a picker at all; one with several
    /// shouldn't re-ask every time the app opens. Plain `UserDefaults.standard` (this
    /// target has its own container, distinct from the phone's App Group — nothing
    /// here needs to be shared with the phone).
    static let selectedLibraryDefaultsKey = "standaloneSelectedLibraryId"

    private(set) var libraries: [WatchLibrary] = []
    private(set) var librariesState: LoadState = .idle
    private(set) var selectedLibraryId: String?

    private(set) var items: [WatchLibraryItem] = []
    private(set) var itemsState: LoadState = .idle
    private var currentPage = 0
    private(set) var hasMorePages = true
    private(set) var isLoadingMore = false

    /// Critique 2026-10-06 (adapt): the books part-way through on the server, shown at
    /// the top of Library so the one to take on a run is first, not somewhere in an
    /// alphabetical list. Best-effort: a failure leaves the section out.
    var inProgressItems: [WatchLibraryItem] { Array(allInProgressItems.prefix(Self.inProgressLimit)) }
    static let inProgressLimit = 5
    /// Batch 411: the whole filtered list (up to the 20 fetched), which the Shelf draws
    /// from; Library's section still shows the first `inProgressLimit`.
    private(set) var allInProgressItems: [WatchLibraryItem] = []
    private(set) var inProgressState: LoadState = .idle
    /// Polish pass (WA-3): true while the shelf shows the last saved list because the server
    /// couldn't be reached. For display only.
    private(set) var inProgressIsFromCache = false

    var searchQuery: String = ""
    private(set) var searchResults: [WatchLibraryItem] = []
    private(set) var searchState: LoadState = .idle
    private var searchTask: Task<Void, Never>?

    // No default value on `api` (build fix, 28 August 2026 — same precedent as
    // `WatchStore.swift`'s own `private init(companion:)` doc comment): a default
    // *parameter* value is evaluated as if `nonisolated` regardless of the
    // enclosing initializer's own actor isolation, so `WatchAudiobookshelfAPI.shared`
    // can't be a default value here even though this `init` is `@MainActor`. The
    // one real call site (`WatchStore.swift`) already passes it explicitly.
    init(api: WatchAudiobookshelfAPI) {
        self.api = api
    }

    var selectedLibrary: WatchLibrary? {
        libraries.first { $0.id == selectedLibraryId }
    }

    // MARK: - Libraries

    func loadLibrariesIfNeeded() async {
        guard librariesState == .idle else { return }
        await reloadLibraries()
    }

    func reloadLibraries() async {
        librariesState = .loading
        do {
            // Funnelled through `WatchStandaloneCall` (9 September 2026, review
            // MEDIUM): a dead session used to collapse into `message(for:)`'s generic
            // "Couldn't reach the server," with `authState` left at `.active` — so the
            // only affordance was a Retry that could never succeed. See that type's
            // own doc comment.
            let fetched = try await WatchStandaloneCall.perform { try await api.getLibraries() }
            libraries = fetched
            librariesState = .loaded
            let stored = UserDefaults.standard.string(forKey: Self.selectedLibraryDefaultsKey)
            let resolved = fetched.first { $0.id == stored } ?? fetched.first
            if let resolved {
                await selectLibrary(resolved.id)
            }
        } catch {
            librariesState = .failed(Self.message(for: error))
        }
    }

    func selectLibrary(_ libraryId: String) async {
        guard libraryId != selectedLibraryId || items.isEmpty else { return }
        selectedLibraryId = libraryId
        UserDefaults.standard.set(libraryId, forKey: Self.selectedLibraryDefaultsKey)
        currentPage = 0
        hasMorePages = true
        items = []
        await loadMoreItems()
    }

    // MARK: - In progress (Critique 2026-10-06)

    func loadInProgress() async {
        guard let libraryId = selectedLibraryId else {
            // No library list (offline at launch): show the last saved shelf, if any.
            restoreInProgressFromCache()
            return
        }
        inProgressState = .loading
        guard let fetched = try? await WatchStandaloneCall.perform({ try await api.getItemsInProgress(limit: 20) }) else {
            if !restoreInProgressFromCache() {
                inProgressState = .failed(String(localized: "Couldn\u{2019}t load books in progress."))
            }
            return
        }
        allInProgressItems = fetched.filter { item in
            WatchLibraryInProgressFilter.keeps(itemLibraryId: item.libraryId, isPodcast: item.isPodcast,
                                               isFinished: item.mediaProgress?.isFinished ?? false,
                                               selectedLibraryId: libraryId)
        }
        inProgressIsFromCache = false
        inProgressState = .loaded
        WatchInProgressCache.save(allInProgressItems, scope: WatchInProgressCache.scope(serverURL: api.serverURL))
    }

    /// Polish pass (WA-3): fills the shelf from the disk cache when the live list isn't
    /// available. Never replaces a list already fetched this launch. Returns whether it did.
    @discardableResult
    private func restoreInProgressFromCache() -> Bool {
        guard allInProgressItems.isEmpty,
              let cached = WatchInProgressCache.load(scope: WatchInProgressCache.scope(serverURL: api.serverURL)),
              !cached.isEmpty else { return false }
        allInProgressItems = cached
        inProgressIsFromCache = true
        inProgressState = .loaded
        return true
    }

    // MARK: - Items (paged)

    /// Called both for the first page (from `selectLibrary`) and every subsequent
    /// page, via the row-appears-near-bottom trigger in `StandaloneLibraryView`. Not
    /// re-entrant-guarded by `itemsState` alone — `isLoadingMore` is the real guard,
    /// since `itemsState` describes the *first* page's outcome for the empty/error UI,
    /// while every page after that should feel like appending, not a full reload.
    func loadMoreItems() async {
        guard let libraryId = selectedLibraryId, hasMorePages, !isLoadingMore else { return }
        isLoadingMore = true
        if currentPage == 0 { itemsState = .loading }
        do {
            let response = try await WatchStandaloneCall.perform {
                try await api.getLibraryItems(libraryId: libraryId, limit: 25, page: currentPage)
            }
            items.append(contentsOf: response.results)
            hasMorePages = response.results.count == 25 && items.count < response.total
            currentPage += 1
            itemsState = .loaded
        } catch {
            // A failed *later* page leaves the already-loaded items on screen rather
            // than replacing them with an error — only a first-page failure should
            // blank the list. `hasMorePages` stays true so scrolling back down retries
            // rather than permanently giving up after one transient failure.
            if currentPage == 0 {
                itemsState = .failed(Self.message(for: error))
            }
        }
        isLoadingMore = false
    }

    // MARK: - Search

    /// Debounced (400ms) rather than firing on every keystroke — a Watch's own
    /// on-device typing (scribble/dictation) already arrives in bursts, not a
    /// character at a time the way a physical keyboard would, but debouncing costs
    /// nothing and avoids a network request per partial word regardless of input
    /// method.
    func search() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let libraryId = selectedLibraryId else {
            searchResults = []
            searchState = .idle
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.searchState = .loading
            do {
                let results = try await WatchStandaloneCall.perform {
                    try await self.api.search(libraryId: libraryId, query: query)
                }
                guard !Task.isCancelled else { return }
                self.searchResults = results
                self.searchState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.searchState = .failed(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? WatchAPIError)?.errorDescription ?? String(localized: "Couldn't reach the server.")
    }
}
