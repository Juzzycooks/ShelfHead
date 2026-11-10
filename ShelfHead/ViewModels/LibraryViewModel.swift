import Foundation
import Observation
import CryptoKit

@MainActor
@Observable
final class LibraryViewModel {
    var libraries: [Library] = []
    var selectedLibrary: Library?
    /// Library browse plan §6.2 (2026-10-05): the position-addressed page store behind the
    /// Books scope. Server-paged results fill it page by page (`ensurePagesLoaded(around:)`,
    /// `jump(to:)`); a local list assigned through `items` (Recently Played, the offline
    /// fallback, a failed load) becomes a fully loaded `LibraryPageWindow(local:)`. The view
    /// renders slots from `displayWindow(downloads:)`, which also wraps the smart-filter and
    /// Downloaded sets, so every Books result renders through one code path.
    private(set) var window = LibraryPageWindow() {
        didSet {
            displayRevision &+= 1
            itemsCache = nil
        }
    }

    /// Every loaded book in position order. Library browse plan §6.2 (2026-10-05): kept as
    /// the compatibility reader for code that doesn't care about slots (Home's B-side and
    /// `hasUnstartedBooks`, today's LibraryView grid). Assigning a list replaces the window
    /// with a fully loaded local one (used for Recently Played, the offline fallback and
    /// tests); it does not touch `totalItems`.
    var items: [LibraryItem] {
        get {
            _ = window.total   // register the observation dependency on `window`
            if let itemsCache { return itemsCache }
            let value = window.loadedInOrder
            itemsCache = value
            return value
        }
        set {
            cancelAllPageTasks()
            windowIsServerPaged = false
            window = LibraryPageWindow(local: newValue, pageSize: pageSize)
        }
    }
    /// Memo for `items` (sorting the page keys and flattening 3,000 books on every body
    /// read would add up). Cleared whenever `window` changes.
    @ObservationIgnored private var itemsCache: [LibraryItem]?
    /// True when `window` holds server pages (as opposed to a local list wrapped as a
    /// window). Library browse plan §6.2 (2026-10-05).
    private(set) var windowIsServerPaged = false
    /// Critique 2026-10-05 (Library, 2nd): where `items` came from. `.server` is the normal
    /// paged list; `.offlineFallback` means the load failed and `items` holds the downloaded
    /// books instead (the view then shows them through `LibraryLocalQuery`, honouring the
    /// user's filter and sort, and labels the count line "(offline)"); `.failed` means the
    /// load failed with nothing to show at all (the view says so honestly instead of
    /// "No books here"). See `LibraryLocalQuery.sourceAfterFailure`.
    var itemsSource: LibraryItemsSource = .server
    /// Critique 2026-10-05 (Library, 2nd) CONTRACT: true when the most recent personalized
    /// (Home) shelf load failed; false after a success; reset on account change.
    var personalizedLoadFailed = false
    /// Critique 2026-10-05 (Library, 2nd) CONTRACT: set (instead of `errorMessage`) when a
    /// pull-to-refresh / background refresh fails while cached content is still on screen,
    /// so `ContentView` can show a non-blocking toast. `errorMessage` stays for blocking
    /// failures with nothing to show.
    var refreshFailureMessage: String?
    /// Critique 2026-10-06 (harden): the Undo toast after a single-book Mark Finished or
    /// Reset Progress (Book Detail's menu, the long-press `BookContextMenu`, Library's List
    /// swipe). Hosted once, app-wide, by `ContentView` (and by a sheet-presented Book
    /// Detail), the same way `refreshFailureMessage` is; its Undo calls
    /// `undoLastProgressChange()`. Bulk Mark Finished keeps its own toast in `LibraryView`.
    var progressUndoMessage: String?
    /// What `undoLastProgressChange()` restores: the book's progress before the change.
    /// Not observed by any view; replaced by each new single-book change.
    @ObservationIgnored private var progressUndoSnapshot: LibraryProgressSnapshot?
    /// The `PlaybackHistoryStore` entry the change recorded, so Undo goes through the
    /// store and spends that entry (Recent Changes then stops offering it).
    @ObservationIgnored private var progressUndoHistoryId: UUID?
    var personalizedShelves: [PersonalizedView] = []
    /// Polish pass (J2-2): true while `personalizedShelves` was painted from the on-disk
    /// `HomeShelvesCache` rather than a network response, so the first real response always
    /// replaces it (even an empty one).
    @ObservationIgnored private var shelvesFromCache = false
    /// Polish pass (J2-4): the most recent `/api/me/listening-stats` request (or its in-flight
    /// task), shared by the personalised load and Home's "Your Week" instead of fetching twice.
    @ObservationIgnored private var listeningStatsCache: (generation: Int, startedAt: Date, task: Task<ListeningStats?, Never>)?

    init() {
        // Polish pass (J2-2): a sign-out or account/server switch deletes every cached shelf file.
        // (`resetForAccountChange()` does the same; this covers sign-out and a fresh sign-in, which
        // post the notification without going through that reset.)
        NotificationCenter.default.addObserver(forName: .shelfheadAccountChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in HomeShelvesCache.removeAll() }
        }
    }

    /// Polish pass (J2-4): `/api/me/listening-stats`, fetched once and shared. A request started
    /// within `maxAge` seconds (finished or still in flight) for the same account is reused;
    /// `maxAge: 0` always fetches. A failed fetch isn't kept.
    func listeningStats(maxAge: TimeInterval) async -> ListeningStats? {
        let generation = accountGeneration
        if let cached = listeningStatsCache, cached.generation == generation,
           Date().timeIntervalSince(cached.startedAt) <= maxAge {
            return await cached.task.value
        }
        let startedAt = Date()
        let task = Task { try? await AudiobookshelfAPI.shared.getListeningStats() }
        listeningStatsCache = (generation, startedAt, task)
        let value = await task.value
        if value == nil, listeningStatsCache?.startedAt == startedAt { listeningStatsCache = nil }
        return value
    }
    var searchResults: [LibraryItem] = []
    /// Critique 2026-10-05 (Library): true when the last server search *failed* (as opposed
    /// to returning zero results), so the UI can say "Couldn't reach your server" with Retry
    /// instead of a misleading "No results".
    var searchFailed = false
    /// True when `searchResults` came from the downloaded books on this device (offline)
    /// rather than from the server.
    var searchIsLocal = false

    var isLoadingLibraries = false
    var isLoadingItems = false
    var isLoadingPersonalized = false
    var isSearching = false
    var errorMessage: String?

    var searchQuery = ""
    /// The server total for the current Books query (kept in step with `window.total` on
    /// every page merge). Library browse plan §6.2 (2026-10-05) removed `currentPage`:
    /// pages are addressed by position now, not appended in order.
    var totalItems = 0
    private let pageSize = 50

    // Browsing: sort / filter / series / authors
    // Persisted (SettingsStore/UserDefaults, same as `libraryLayout`) so a relaunch
    // doesn't silently reset the sort back to Title / filter back to All — these
    // used to be plain in-memory vars that reset every cold launch even though the
    // grid/list layout choice next to them stuck.
    var sortOption: LibrarySort = SettingsStore.librarySortOption {
        didSet { SettingsStore.librarySortOption = sortOption }
    }
    var sortDescending = SettingsStore.librarySortDescending {
        didSet { SettingsStore.librarySortDescending = sortDescending }
    }
    var progressFilter: LibraryProgressFilter = SettingsStore.libraryProgressFilter {
        didSet { SettingsStore.libraryProgressFilter = progressFilter }
    }
    /// Client-side "Downloaded only" toggle. Drawn from the local download
    /// manifest (reliable & offline-safe) rather than filtering a paginated
    /// server list, so it doesn't require a reload.
    ///
    /// G6 (REVIEW_2026-09-04_UI.md): this used to round-trip through `SettingsStore`
    /// like the sort and progress filter above. Rendered consequence: after following
    /// `shelfhead://downloads` once (offline banner, widget, Shortcut), every later cold
    /// launch opened Library as "No downloads yet" until the chip was cleared. Sort and
    /// layout are preferences; a narrowing filter that hides the whole library is view
    /// state, so it now starts off on each launch. Setting it within a session is
    /// unchanged — the filter sheet, the chip, the deep link and the banner all still
    /// write here.
    var downloadedOnly = false
    // MARK: - Smart filters

    /// The active smart collection, or nil for none. Setting this via `selectSmartFilter`
    /// (not directly) is what actually loads/filters `smartFilterItems`.
    var smartFilter: SmartFilter?
    var smartFilterItems: [LibraryItem] = [] {
        didSet { displayRevision &+= 1 }
    }
    var isLoadingSmartFilter = false
    /// A bulk, unpaginated snapshot of the current library, fetched once per library
    /// selection the first time any smart filter is used and reused for the rest —
    /// every smart filter needs to see the *whole* library at once (e.g. "no progress
    /// in 30 days" can't be answered one paginated page at a time), but re-fetching all
    /// of it on every filter switch would be wasteful.
    private var smartFilterSource: [LibraryItem] = []
    /// Review Medium 30 (30 October 2026): true when the snapshot hit `smartFilterItemCap`
    /// before the library ended, so Smart Filter results may be missing books.
    var smartFilterSnapshotIsPartial = false

    /// N-6 (REVIEW_2026-09-14_DESIGN.md): a browse scope some surface *outside* the
    /// Library screen has asked it to switch to, or nil when there's no outstanding
    /// request. Set by `presentSmartFilter(_:)`; the Library screen consumes it and
    /// clears it back to nil once applied.
    ///
    /// It's a request, not state: nothing else reads it, and a value left unconsumed
    /// has no effect beyond occupying this property. The Library screen owns its own
    /// `browseMode` as view state (correctly — it's which control is selected, not a
    /// preference), so this is the one seam a caller elsewhere has to ask for a scope
    /// change without that state moving out of the view.
    var requestedBrowseMode: BrowseMode?

    /// Critique 2026-10-05 (Library): true when the last bulk snapshot fetch for a smart
    /// filter failed. A failed fetch used to be `try?`-swallowed into an empty (and then
    /// cached) snapshot, so "couldn't load" rendered as "No books match". The view shows a
    /// distinct error with Retry instead, and nothing is cached on failure.
    var smartFilterFailed = false

    /// Selects a smart collection (or clears it with nil), loading the bulk library
    /// snapshot on first use. Safe to call repeatedly while switching between filters.
    func selectSmartFilter(_ filter: SmartFilter?) async {
        smartFilter = filter
        smartFilterFailed = false
        // Review 3 Medium 8: `selectLibrary` may have set the spinner for a filter that's now cleared.
        guard let filter else { smartFilterItems = []; isLoadingSmartFilter = false; return }
        isLoadingSmartFilter = true
        // Review Medium 29 (30 October 2026): remember the library so a snapshot fetched for
        // the old library is dropped if the user switched libraries while it loaded.
        let startedLibraryId = selectedLibrary?.id
        if smartFilterSource.isEmpty {
            do {
                let (fetched, partial) = try await fetchAllItemsForSmartFilter()
                // A newer selection (or a clear) superseded this one while it was loading.
                guard selectedLibrary?.id == startedLibraryId else { if smartFilter == nil { isLoadingSmartFilter = false }; return }  // Review 4 Medium 3
                guard smartFilter == filter else { if smartFilter == nil { isLoadingSmartFilter = false }; return }
                smartFilterSource = fetched
                smartFilterSnapshotIsPartial = partial  // Review 2 Low (Browsing, 30 October 2026)
            } catch {
                // Review 2 Low (Browsing, 30 October 2026): a failure from the old library must not touch the new one.
                guard selectedLibrary?.id == startedLibraryId else { if smartFilter == nil { isLoadingSmartFilter = false }; return }  // Review 4 Medium 3
                guard smartFilter == filter else { if smartFilter == nil { isLoadingSmartFilter = false }; return }
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    // Critique 2026-10-05 (Library): not cached as truth; Retry re-fetches.
                    smartFilterFailed = true
                    smartFilterItems = []
                    ShelfLog.error(.network, "Smart filter snapshot failed: \(error.localizedDescription)")
                }
                isLoadingSmartFilter = false
                return
            }
        }
        smartFilterItems = Self.applySmartFilter(filter, to: smartFilterSource, viewModel: self)
        isLoadingSmartFilter = false
    }

    /// Applies `filter` on behalf of a caller *outside* the Library screen — Home's
    /// Smart Filters shelf, or the `shelfhead://library?smartFilter=<rawValue>` deep
    /// link (N-6, REVIEW_2026-09-14_DESIGN.md).
    ///
    /// Additive to `selectSmartFilter(_:)`, which is unchanged and stays the direct way
    /// to set or clear a filter from within Library itself. The difference is the scope
    /// reset: a smart filter only ever produces a list of *books*, so arriving from
    /// elsewhere while Library happens to be showing Series or Authors would land on a
    /// scope the result set can't populate. Asking for Books here (rather than at each
    /// call site) keeps that coupling in one place.
    func presentSmartFilter(_ filter: SmartFilter) async {
        requestedBrowseMode = .books
        await selectSmartFilter(filter)
    }

    /// Whether the bulk library snapshot smart filters evaluate against is already in
    /// memory. Lets a caller decide whether match counts are free right now (see
    /// `cachedSmartFilterCounts()`) instead of guessing.
    var hasSmartFilterSnapshot: Bool { !smartFilterSource.isEmpty }

    /// Match counts for every smart filter, evaluated against the snapshot that is
    /// *already* loaded — `[:]` when there isn't one (N-6, REVIEW_2026-09-14_DESIGN.md).
    ///
    /// Deliberately never loads: `fetchAllItemsForSmartFilter()` pages the entire
    /// library, and a decoration on a shelf that renders on Home's first appear must not
    /// be able to turn eight labels into that. So Home's counts are a bonus that show up
    /// once the snapshot exists (the user has opened a smart filter at least once this
    /// session, or pulled to refresh with one active) and are simply absent before then,
    /// rather than a reason to fetch.
    ///
    /// Not a computed property: this is O(filters × library) and allocates a filtered
    /// array per filter, which is fine to call when something actually changed and very
    /// much not fine on a `body` path.
    func cachedSmartFilterCounts() -> [SmartFilter: Int] {
        guard !smartFilterSource.isEmpty else { return [:] }
        var counts: [SmartFilter: Int] = [:]
        for filter in SmartFilter.allCases {
            counts[filter] = Self.applySmartFilter(filter, to: smartFilterSource, viewModel: self).count
        }
        return counts
    }

    /// Clears the cached bulk snapshot so the next `selectSmartFilter` call re-fetches —
    /// call this alongside anything that already invalidates `items` for the same reason
    /// (library switch, pull-to-refresh), so a smart filter doesn't show stale results.
    private func invalidateSmartFilterCache() {
        smartFilterSource = []
        smartFilterSnapshotIsPartial = false
        if smartFilter != nil { smartFilterItems = [] }
    }

    /// Pages through the *entire* current library (not just one screen's worth) for
    /// smart-filter evaluation. Review Medium 30 (30 October 2026): the cap was 5,000 and
    /// silently truncated larger libraries; it is now `smartFilterItemCap` (20,000, the same
    /// ceiling the series loader uses) as a memory/pathological-response bound, and hitting it
    /// sets `smartFilterSnapshotIsPartial` so the view can say results are partial. The loop
    /// already ends on an empty page or `total`.
    ///
    /// Critique 2026-10-05 (Library): throws on any failed page instead of `try?` + `break`,
    /// because a half-fetched library silently evaluated as the whole library gave wrong
    /// smart-filter results that were then cached.
    private func fetchAllItemsForSmartFilter() async throws -> (items: [LibraryItem], partial: Bool) {
        guard let library = selectedLibrary else { return ([], false) }
        var all: [LibraryItem] = []
        var page = 0
        let limit = 200
        var partial = false  // Review 2 Low (Browsing, 30 October 2026): returned, not set mid-fetch
        while all.count < Self.smartFilterItemCap {
            let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: library.id, limit: limit, page: page, sort: LibrarySort.title.rawValue
            )
            guard !response.results.isEmpty else { break }
            all.append(contentsOf: response.results)
            page += 1
            if all.count >= response.total { break }
            if all.count >= Self.smartFilterItemCap { partial = true }
        }
        return (all, partial)
    }

    nonisolated static let smartFilterItemCap = 20_000

    /// Pure filtering logic, `static` so it doesn't accidentally read/write view-model
    /// state beyond what's passed in — `unplayedInStartedSeries` needs to compare every
    /// item against every other item's series/progress, which is easiest to reason
    /// about as a single pass over the full `source` array rather than a per-item
    /// predicate closure.
    private static func applySmartFilter(_ filter: SmartFilter, to source: [LibraryItem], viewModel: LibraryViewModel) -> [LibraryItem] {
        let favorites = FavoritesStore.shared
        return applySmartFilter(
            filter, to: source, now: Date(),
            progress: { viewModel.progressFor(itemId: $0.id) ?? $0.mediaProgress },
            isDownloaded: { DownloadManager.shared.isDownloaded(itemId: $0) },
            isFavorite: { favorites.isFavoriteAuthor($0.authorName) || favorites.isFavoriteNarrator($0.narratorName) }
        )
    }

    /// The rules themselves, with the clock, progress, downloads and favourites passed in so
    /// tests can pin each filter (review test gap, 30 October 2026).
    static func applySmartFilter(
        _ filter: SmartFilter, to source: [LibraryItem], now: Date,
        progress progressOf: (LibraryItem) -> MediaProgress?,
        isDownloaded: (String) -> Bool,
        isFavorite: (LibraryItem) -> Bool
    ) -> [LibraryItem] {
        func progress(for item: LibraryItem) -> MediaProgress? { progressOf(item) }

        switch filter {
        case .downloadedUnfinished:
            return source.filter { item in
                isDownloaded(item.id) &&
                (progress(for: item)?.isFinished ?? false) == false
            }

        case .nearlyFinished:
            return source.filter { item in
                let mp = progress(for: item)
                guard mp?.isFinished != true else { return false }
                return (mp?.progress ?? 0) >= 0.9
            }

        case .stale:
            return source.filter { item in
                guard let mp = progress(for: item), mp.isFinished != true,
                      (mp.currentTime ?? 0) > 0, let lastUpdateMs = mp.lastUpdate else { return false }
                let last = Date(timeIntervalSince1970: Double(lastUpdateMs) / 1000)
                return now.timeIntervalSince(last) > 30 * 24 * 3600
            }

        case .shortListens:
            return source.filter { $0.duration > 0 && $0.duration < 2 * 3600 }

        case .longListens:
            return source.filter { $0.duration > 20 * 3600 }

        case .unplayedInStartedSeries:
            // A series counts as "started" if any book in it has recorded progress
            // (started or finished). Any *other* book in that same series with no
            // progress at all is "unplayed in a started series".
            var startedSeries = Set<String>()
            for item in source {
                guard let series = item.seriesName else { continue }
                if progress(for: item) != nil { startedSeries.insert(series) }
            }
            return source.filter { item in
                guard let series = item.seriesName, startedSeries.contains(series) else { return false }
                return progress(for: item) == nil
            }

        case .missingCovers:
            return source.filter { $0.media?.coverPath == nil }

        case .favoriteNewArrivals:
            let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
            return source.filter { item in
                guard let addedMs = item.addedAt else { return false }
                let added = Date(timeIntervalSince1970: Double(addedMs) / 1000)
                guard added > cutoff else { return false }
                return isFavorite(item)
            }
        }
    }

    var seriesList: [Series] = []
    var isLoadingSeries = false
    var seriesLoaded = false            // distinguishes "no series" from "not loaded yet"
    var filterData: LibraryFilterData?
    /// Current listening streak, loaded with the personalized view (cached here so
    /// Home doesn't refetch it every time the header re-appears).
    var listeningStreak = 0

    var hasMoreItems: Bool {
        items.count < totalItems
    }

    /// Critique 2026-10-05 (Library): the single source of truth for "what is on screen".
    /// With a smart filter it is the smart set (which already answers "what books", so
    /// sort and progress filter don't apply). With "Downloaded only" it is the local
    /// download manifest with the active progress filter and sort applied client-side
    /// (they used to be silently ignored). Otherwise it is the server-paged list.
    func displayedItems(downloads: [LibraryItem]) -> [LibraryItem] {
        if smartFilter != nil { return smartFilterItems }
        guard showsLocalDownloads else { return items }
        // Critique 2026-10-05 (Library, 2nd): the client sort/filter used to re-run for every
        // sub-view that asked (empty check, grid, list, count line) in one body pass. Memoised
        // on the inputs that can change the answer; the cache is observation-ignored.
        var hasher = Hasher()
        for d in downloads { hasher.combine(d.id) }
        let key = DisplayKey(
            progressFilter: progressFilter, sort: sortOption, descending: sortDescending,
            revision: displayRevision, downloadsCount: downloads.count, downloadsHash: hasher.finalize()
        )
        if let cached = displayCache, cached.key == key { return cached.value }
        let value = LibraryLocalQuery.apply(
            downloads, filter: progressFilter, sort: sortOption, descending: sortDescending,
            progress: { [self] in progressFor(itemId: $0.id) ?? $0.mediaProgress }
        )
        displayCache = (key, value)
        return value
    }

    private struct DisplayKey: Equatable {
        var progressFilter: LibraryProgressFilter
        var sort: LibrarySort
        var descending: Bool
        var revision: Int
        var downloadsCount: Int
        var downloadsHash: Int
    }
    @ObservationIgnored private var displayCache: (key: DisplayKey, value: [LibraryItem])?
    /// Bumped whenever `items`, `smartFilterItems` or the progress map change, so the memo
    /// above can't serve a stale list.
    @ObservationIgnored private var displayRevision = 0

    /// Whether the grid is drawn from the local download manifest rather than the server
    /// list: the user's "Downloaded" filter, or a failed load that fell back to downloads.
    var showsLocalDownloads: Bool { downloadedOnly || itemsSource == .offlineFallback }

    /// Critique 2026-10-05 (Library, 2nd): the one intent for "show me my downloads". Clears
    /// a smart filter first (a smart filter outranks Downloaded, so setting only
    /// `downloadedOnly` left a chip claiming a filter that wasn't applied) and asks for the
    /// Books scope. NOTE for the coordinator: ContentView's `shelfhead://downloads` deep link
    /// should call this instead of setting `downloadedOnly` directly.
    func showDownloads() {
        smartFilter = nil
        smartFilterItems = []
        smartFilterFailed = false
        isLoadingSmartFilter = false
        downloadedOnly = true
        requestedBrowseMode = .books
    }

    /// How many books the current view holds in total (server total, not just the pages
    /// loaded so far) — drives the filter sheet's "N books" and the Library count line.
    func totalResultCount(downloads: [LibraryItem]) -> Int {
        if smartFilter != nil { return smartFilterItems.count }
        if showsLocalDownloads { return displayedItems(downloads: downloads).count }
        return max(totalItems, items.count)
    }

    /// Wipe all account-specific state so a switched account never shows the previous
    /// account's libraries, books, progress, or streak. Call before reloading.
    func resetForAccountChange() {
        // Fix 5 (REVIEW-2026-09-09.md): invalidate every in-flight load before anything is
        // emptied below. `loadPersonalizedView()`/`loadUserProgress()` had no staleness
        // guard at all, and clearing the shelves here is exactly what let a *previous*
        // account's response pass their `isEmpty` checks — assigning the old account's
        // books, publishing them to the widget, handing them to auto-download and letting
        // `reconcile` write a foreign position into a local manifest. Bumping both
        // counters makes any response already in flight fail its guard on arrival.
        accountGeneration &+= 1
        loadGeneration &+= 1
        searchGeneration &+= 1
        // Drop the widget's pickable set first: it's per-account by nature, and leaving
        // the previous account's titles selectable on the Home Screen would be both wrong
        // and a small privacy leak. Also cleared directly by
        // `AuthViewModel.tearDownAccountScopedState(reason:)` — this call stays because
        // this function is reachable on its own and clearing twice is a no-op.
        // Republished on the next personalized-view load.
        WidgetLibraryPublisher.clear()
        HomeShelvesCache.removeAll()   // Polish pass (J2-2)
        shelvesFromCache = false
        listeningStatsCache = nil
        libraries = []
        selectedLibrary = nil
        items = []
        personalizedShelves = []
        searchResults = []
        seriesList = []
        collections = []
        playlists = []
        filterData = nil
        seriesLoaded = false
        collectionsLoaded = false
        playlistsLoaded = false
        listeningStreak = 0
        userProgressMap = [:]
        itemsSource = .server
        personalizedLoadFailed = false
        refreshFailureMessage = nil
        // Critique 2026-10-06 (harden): an Undo for the previous account's book must not
        // survive a switch and write to the new server.
        progressUndoMessage = nil
        progressUndoSnapshot = nil
        progressUndoHistoryId = nil
        totalItems = 0
        lastVisibleRange = nil
        pageFailureBurstActive = false
        duplicateRefetchCounts = [:]
        windowQueryKey = nil
        searchQuery = ""
        smartFilter = nil
        smartFilterItems = []
        smartFilterSource = []
        smartFilterFailed = false
        isLoadingSmartFilter = false  // Review 4 Medium 3: a stale fetch must not leave the skeleton up
        searchFailed = false
        searchIsLocal = false
        isSearching = false  // Review 7 Low (isSearching)
        // N-6: an outstanding scope request belongs to the previous account's navigation
        // just as much as `searchQuery` above does — dropped rather than replayed into a
        // freshly-reset Library.
        requestedBrowseMode = nil
        favoriteNarratorItems = []
        // Review 6 Medium 10: stale loaders return without touching their flags, so reset them here.
        isLoadingLibraries = false
        isLoadingFilterData = false
        isLoadingFavoriteNarratorItems = false
    }

    // MARK: - Next in Series (smarter continue-series)

    /// Best-effort "next book to listen to" in the same series as `book`.
    ///
    /// Priority (per product spec):
    ///   1. Next *unfinished* book after the current sequence position
    ///   2. …preferring one that is already *downloaded*
    ///   3. Otherwise the next available book by sequence
    ///
    /// Returns nil when the next book can't be determined. Detecting a *missing* book
    /// (a gap in the sequence of ones you own) is handled separately by
    /// `missingSequenceGap(in:seriesName:)`, below.
    ///
    /// NOTE: This is a self-contained helper and is not yet wired into the Home
    /// UI (which currently uses the server's "Next in Series" shelf). Wire it in
    /// once series-sequence data is confirmed reliable across the catalog.
    func nextInSeries(after book: LibraryItem) async -> LibraryItem? {
        guard let libraryId = selectedLibrary?.id,
              let seriesName = book.seriesName else { return nil }

        // Paginates to find the series even in large (>100-series) libraries.
        guard let series = try? await AudiobookshelfAPI.shared.findSeries(libraryId: libraryId, matching: seriesName),
              let books = series.books else { return nil }

        // 1 & 2: next unfinished, preferring downloaded. 3: next available regardless of
        // progress. Ordering/selection lives in `SeriesOrdering` — shared with
        // `PlayerViewModel`'s auto-queue and auto-download, which used to answer this
        // same question with their own (incorrect) copies of it.
        return books.nextUnfinishedInSeries(
            after: book, seriesName: seriesName,
            isDownloaded: { DownloadManager.shared.isDownloaded(itemId: $0) }
        ) ?? books.nextAvailableInSeries(after: book, seriesName: seriesName)
    }

    /// Detects a gap in the sequence numbers of books you actually *own* within a
    /// series — e.g. you have #1, #2, #4 but not #3. Purely local (uses the series
    /// data ABS already returned for this series) — no external API. This is the
    /// only "missing book" detection ShelfHead does: ABS's own series listing only
    /// includes books already in your library, and no public API exists to reliably
    /// answer "does a book past your last one exist yet" in-app (an Audnexus-based
    /// attempt at this was tried and removed — see `CHANGES_IMPLEMENTED.md` Batch
    /// 206/207 — since Audnexus has no series- or author-bibliography endpoint).
    ///
    /// Returns the first missing whole-number sequence, or nil if there's no
    /// detectable gap (sequences aren't whole numbers, fewer than 2 books, or the
    /// run is unbroken).
    func missingSequenceGap(in books: [LibraryItem], seriesName: String) -> Int? {
        let sequences = books.compactMap { $0.sequence(inSeriesNamed: seriesName) }
        // Only whole-number sequences are checked — a series that mixes in novellas
        // at "2.5" etc. isn't a reliable enough signal to flag as a real gap.
        let whole = Set(sequences.compactMap { seq -> Int? in
            seq.truncatingRemainder(dividingBy: 1) == 0 ? Int(seq) : nil
        })
        guard let maxSeq = whole.max(), maxSeq > 1 else { return nil }
        for n in 1..<maxSeq where !whole.contains(n) {
            return n
        }
        return nil
    }

    // MARK: - Libraries

    func loadLibraries() async {
        isLoadingLibraries = true
        errorMessage = nil
        let generation = accountGeneration  // Review 6 Medium 10
        // Polish pass (J2-2): paint the last shelves for this account before the network answers.
        hydrateShelvesFromCacheIfNeeded()

        do {
            let fetched = try await LaunchTrace.interval("GetLibraries") {
                try await AudiobookshelfAPI.shared.getLibraries()
            }
            guard generation == accountGeneration else { return }  // Review 6 Medium 10: account switched mid-load
            libraries = fetched
            // Auto-select on first load: prefer the previously-chosen library (shared
            // with CarPlay), falling back to the first.
            var firstSelection = false
            if selectedLibrary == nil {
                let preferred = SettingsStore.selectedLibraryId
                    .flatMap { id in libraries.first { $0.id == id } }
                if let library = preferred ?? libraries.first {
                    selectedLibrary = library
                    SettingsStore.selectedLibraryId = library.id
                    firstSelection = true
                }
            }
            if firstSelection {
                // Polish pass (J2-1): these used to run one after another (progress, items,
                // personalised). None needs another's result: `loadPersonalizedView()` starts the
                // `/api/me` progress load itself (and awaits it before publishing to the widget),
                // and the items window reads progress lazily at render time (`displayRevision`
                // bumps when the map lands). So items and shelves now load together.
                async let itemsLoad: Void = loadItems()
                async let shelvesLoad: Void = loadPersonalizedView()
                await itemsLoad
                await shelvesLoad
            } else {
                await loadUserProgress()
            }
        } catch {
            guard generation == accountGeneration else { return }  // Review 6 Medium 10
            ShelfLog.error(.network, "Failed to load libraries: \(error.localizedDescription)")
            let kind = Self.loadFailureKind(reachability: ReachabilityStore.shared.status, error: error)
            // Polish pass (J1-8): offline with shelves already on screen (cached or earlier): the
            // connectivity banner says it, so no blocking alert on top.
            if !(kind == .offline && !personalizedShelves.isEmpty) {
                errorMessage = Self.loadFailureMessage(kind)
            }
        }

        isLoadingLibraries = false
    }

    /// Polish pass (J1-8): what kind of failure a load hit, for house-style copy.
    enum LoadFailureKind: Equatable { case offline, serverUnreachable, other }

    /// Pure: the device having no network (by the reachability store or the URLError) is
    /// `.offline`; the server not answering is `.serverUnreachable`; anything else is `.other`.
    nonisolated static func loadFailureKind(reachability: ReachabilityStore.Status, error: Error) -> LoadFailureKind {
        if reachability == .offline { return .offline }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
                 .networkConnectionLost, .secureConnectionFailed, .serverCertificateUntrusted,
                 .badServerResponse:
                return .serverUnreachable
            default:
                break
            }
        }
        return reachability == .serverUnreachable ? .serverUnreachable : .other
    }

    /// Pure: the alert text for a failed load (what happened, then what to do). Never carries
    /// `localizedDescription` or a status code; those go to `ShelfLog`.
    nonisolated static func loadFailureMessage(_ kind: LoadFailureKind) -> String {
        switch kind {
        case .offline:
            return String(localized: "You\u{2019}re offline. Your downloads still play.", comment: "Library error alert text when the device has no connection")
        case .serverUnreachable:
            return String(localized: "Can\u{2019}t reach your server. Check your connection and try again.", comment: "Library error alert text when the server doesn't answer")
        case .other:
            return String(localized: "Something went wrong loading your library. Try again in a moment.", comment: "Library error alert text for an unexpected load failure")
        }
    }

    /// Polish pass (J2-2): fills Home's shelves from the disk cache when nothing is on screen yet.
    /// Only for the library the user last had selected, and only for the signed-in account's scope.
    private func hydrateShelvesFromCacheIfNeeded() {
        guard personalizedShelves.isEmpty, let libraryId = SettingsStore.selectedLibraryId else { return }
        let scope = DownloadManager.shared.currentScopeKey()
        guard let cached = HomeShelvesCache.load(scope: scope, libraryId: libraryId), !cached.isEmpty else { return }
        personalizedShelves = cached
        shelvesFromCache = true
    }

    /// Review Medium 31: pure library filter for the Recently Played list. Items with no
    /// `libraryId` are dropped (they cannot be placed in this library).
    nonisolated static func itemsInLibrary(_ items: [LibraryItem], libraryId: String) -> [LibraryItem] {
        items.filter { $0.libraryId == libraryId }
    }

    func selectLibrary(_ library: Library) async {
        selectedLibrary = library
        SettingsStore.selectedLibraryId = library.id   // shared with CarPlay
        items = []
        personalizedShelves = []
        // Review Low (search after library switch, 30 October 2026): results and any in-flight
        // search belong to the previous library.
        searchGeneration &+= 1
        searchResults = []
        searchQuery = ""
        searchFailed = false
        isSearching = false
        // Browse lists belong to the previous library — clear so availability re-resolves.
        seriesList = []; seriesLoaded = false
        collections = []; collectionsLoaded = false
        playlists = []; playlistsLoaded = false
        filterData = nil
        invalidateSmartFilterCache()
        // Review 2 Low (Browsing, 30 October 2026): show the loading state, not "Nothing here", while items load.
        if smartFilter != nil { isLoadingSmartFilter = true }
        await loadItems()
        // Review Medium 29 (30 October 2026): the cache invalidation above empties
        // `smartFilterItems`; re-run the active filter against the new library or the
        // grid shows "Nothing here".
        if let smartFilter { await selectSmartFilter(smartFilter) }
        await loadPersonalizedView()
        await loadBrowseAvailability()
    }

    // MARK: - Library Items

    /// Bumped on each load; a response only writes state if it's still the latest request
    /// and the selected library hasn't changed underneath it (prevents stale overwrites).
    private var loadGeneration = 0
    private var searchGeneration = 0
    /// Bumped ONLY by `resetForAccountChange()`. Deliberately separate from
    /// `loadGeneration`: that one is bumped by every `loadItems()` call, so guarding the
    /// account-scoped loaders on it would discard a perfectly good progress response just
    /// because the user changed sort or paged the grid meanwhile. Fix 5
    /// (REVIEW-2026-09-09.md).
    private var accountGeneration = 0

    /// Pure staleness predicate shared by the three loaders that can outlive the state
    /// they were started for. `startedLibraryId`/`currentLibraryId` are optional so a
    /// loader with no library dimension (`loadUserProgress()`, which reads `/api/me`) can
    /// pass `nil` for both and be judged on the account generation alone.
    nonisolated static func isStaleLoad(
        startedAccountGeneration: Int, currentAccountGeneration: Int,
        startedLibraryId: String?, currentLibraryId: String?
    ) -> Bool {
        startedAccountGeneration != currentAccountGeneration || startedLibraryId != currentLibraryId
    }

    /// Loads the Books query from the top: page 0 of the server list (or the Recently Played
    /// list, which is local). Library browse plan §6.5 (2026-10-05): every page fetch still in
    /// flight is cancelled and the generation bumped, so a late page from the old query is
    /// dropped. The old window stays on screen until page 0 lands (Critique 2026-10-05,
    /// Library 2nd: no skeleton flash, nothing blanked on failure).
    func loadItems() async {
        await LaunchTrace.interval("LoadItems") {
            await loadItems(preservingWindow: false)
        }
    }

    /// `preservingWindow` is pull-to-refresh (plan §5 "Pull to refresh"): when the query is
    /// unchanged, page 0 is merged into the existing window, every other loaded page is
    /// marked stale, and the last visible range is refetched, instead of resetting to the top.
    private func loadItems(preservingWindow: Bool) async {
        guard let library = selectedLibrary else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let libraryId = library.id
        cancelAllPageTasks()
        isResettingWindow = true
        defer { if generation == loadGeneration { isResettingWindow = false } }
        isLoadingItems = true
        errorMessage = nil

        // "Recently Played" isn't a server sort key — it's the items-in-progress list,
        // which the server already returns in most-recent order. Not paginated.
        if sortOption.isRecentlyPlayed {
            do {
                // Review Medium 31 (30 October 2026): /api/me/items-in-progress spans every
                // library (and podcasts); keep this library's books. The 100 cap is the server's.
                let recent = Self.itemsInLibrary(
                    try await AudiobookshelfAPI.shared.getItemsInProgress(limit: LibraryLocalQuery.recentLimit),
                    libraryId: libraryId)
                guard generation == loadGeneration, selectedLibrary?.id == libraryId else { isLoadingItems = false; return }
                items = recent   // a local window (plan §6.2)
                windowQueryKey = nil
                totalItems = recent.count
                itemsSource = .server
                SpotlightIndexer.index(recent)
            } catch {
                guard generation == loadGeneration, selectedLibrary?.id == libraryId else { isLoadingItems = false; return }
                handleItemsLoadFailure(error, isPagedLoad: false)
            }
            isLoadingItems = false
            return
        }

        let key = currentQueryKey(libraryId: libraryId)
        do {
            let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: libraryId,
                limit: pageSize,
                page: 0,
                filter: key.filter,
                sort: key.sort,
                desc: key.descending
            )
            // Drop stale responses (library switched or a newer load started meanwhile).
            guard generation == loadGeneration, selectedLibrary?.id == libraryId else {
                isLoadingItems = false
                return
            }
            let keepWindow = preservingWindow && windowIsServerPaged && windowQueryKey == key
            if keepWindow {
                var updated = window
                for page in Array(updated.pages.keys) where page != 0 { updated.markStale(page) }
                updated.merge(page: 0, results: response.results, reportedTotal: response.total)
                window = updated
            } else {
                var fresh = LibraryPageWindow(pageSize: pageSize)
                fresh.merge(page: 0, results: response.results, reportedTotal: response.total)
                window = fresh
                lastVisibleRange = nil
                duplicateRefetchCounts = [:]
            }
            windowIsServerPaged = true
            windowQueryKey = key
            totalItems = window.total
            itemsSource = .server
            pageFailureBurstActive = false
            // Index into Spotlight so books are searchable system-wide + deep-linkable.
            // Only this page's items: `SpotlightIndexer.index` upserts each item by its own
            // id, so pages indexed earlier don't need resubmitting (plan §6.4 keeps it per page).
            SpotlightIndexer.index(response.results)
            isLoadingItems = false
            isResettingWindow = false
            if keepWindow, let visible = lastVisibleRange { ensurePagesLoaded(around: visible) }
            return
        } catch {
            guard generation == loadGeneration, selectedLibrary?.id == libraryId else {
                isLoadingItems = false
                return
            }
            handleItemsLoadFailure(error, isPagedLoad: true)
        }

        isLoadingItems = false
    }

    /// Critique 2026-10-05 (Library, 2nd): one failure path for both item loads. A cancelled
    /// pull-to-refresh (SwiftUI tears down the `.refreshable` task) must NOT alter the list.
    /// With books already on screen the list is kept and `refreshFailureMessage` (a toast)
    /// reports it. With nothing on screen `LibraryLocalQuery.sourceAfterFailure` picks
    /// downloaded books (`.offlineFallback`, labelled as such) or `.failed` (an honest "can't
    /// reach your server" state). No blocking `errorMessage` alert: the inline state already
    /// says it. Library browse plan §6.2 (2026-10-05): there is no page counter to roll back
    /// any more (`isPagedLoad` is kept for the call sites' readability); individual page
    /// failures go through `finishPage` instead.
    private func handleItemsLoadFailure(_ error: Error, isPagedLoad: Bool) {
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        guard !cancelled else { return }
        let hadItems = !items.isEmpty
        let downloads = hadItems ? [] : DownloadManager.shared.downloadedLibraryItems()
        let next = LibraryLocalQuery.sourceAfterFailure(
            current: itemsSource, hasItems: hadItems, hasDownloads: !downloads.isEmpty
        )
        itemsSource = next
        switch next {
        case .offlineFallback where !hadItems:
            items = downloads   // a local window (plan §6.2)
            windowQueryKey = nil
            totalItems = downloads.count
            mergeOfflineProgress(downloads)
        case .failed:
            items = []
            windowQueryKey = nil
            totalItems = 0
        default:
            break
        }
        if hadItems {
            refreshFailureMessage = itemsSource == .offlineFallback
                ? String(localized: "Couldn\u{2019}t refresh right now. Showing your downloaded books.", comment: "Library refresh failure toast while showing the offline downloaded fallback")
                : String(localized: "Couldn\u{2019}t refresh right now. Showing your loaded books.", comment: "Library refresh failure toast while keeping the books already loaded")
            ShelfLog.error(.network, "Library refresh failed (kept loaded items): \(error.localizedDescription)")
        } else {
            ShelfLog.error(.network, "Library load failed (\(next)): \(error.localizedDescription)")
        }
    }

    /// Seed the progress map from downloaded manifests so cached progress shows
    /// when we couldn't reach the server.
    private func mergeOfflineProgress(_ offlineItems: [LibraryItem]) {
        for item in offlineItems where userProgressMap[item.id] == nil {
            if let mp = item.mediaProgress { userProgressMap[item.id] = mp }
        }
    }

    // MARK: - Page window (Library browse plan §6.2–6.5, 2026-10-05)

    /// At most this many page requests run at once (plan §6.5).
    static let maxPagesInFlight = 2
    /// How often one page may be refetched because it repeated ids already held elsewhere,
    /// per window. A server whose sort has unstable ties could otherwise repeat forever.
    private static let maxDuplicateRefetches = 2

    /// What identifies a server-paged query; a page result only merges into a window built
    /// for the same key.
    private struct WindowQueryKey: Equatable, Sendable {
        var libraryId: String
        var sort: String
        var descending: Bool
        var filter: String?
    }

    private func currentQueryKey(libraryId: String) -> WindowQueryKey {
        WindowQueryKey(libraryId: libraryId, sort: sortOption.rawValue,
                       descending: sortDescending, filter: progressFilter.filterValue)
    }

    @ObservationIgnored private var windowQueryKey: WindowQueryKey?
    /// One `Task` per page being fetched, keyed by page index (plan §6.5).
    @ObservationIgnored private var pageTasks: [Int: (token: Int, task: Task<Void, Never>)] = [:]
    /// Distinguishes a page's current fetch from an earlier, cancelled one for the same page.
    @ObservationIgnored private var nextPageToken = 0
    /// The most recent visible index range the view reported; refetched after a refresh, a
    /// total change, or when the server becomes reachable again.
    @ObservationIgnored private var lastVisibleRange: ClosedRange<Int>?
    /// True while `loadItems` is replacing the window; page fetches wait for it so a page
    /// for the new query never merges into the old window.
    @ObservationIgnored private var isResettingWindow = false
    /// One toast per burst of page failures, not one per page (plan §5 "Page fetch failed").
    @ObservationIgnored private var pageFailureBurstActive = false
    @ObservationIgnored private var duplicateRefetchCounts: [Int: Int] = [:]
    @ObservationIgnored private var reconnectWatch: Task<Void, Never>?
    /// Batch 409: the debounced Continue Listening refetch `applyRemoteProgressSnapshot` schedules.
    @ObservationIgnored private var remoteShelfRefreshTask: Task<Void, Never>?

    /// Library browse plan §6.2 (2026-10-05) and §5: true when the current Books query is
    /// paged from the server (the view shows placeholders and the scrubber over `window`),
    /// false when it is a local set (smart filter, Downloaded only, offline fallback,
    /// Recently Played), which `displayWindow(downloads:)` wraps as a fully loaded window.
    var isWindowed: Bool {
        // Recently Played is never stored as a server window (`windowIsServerPaged` is false
        // for it), so it doesn't need re-checking here while a sort change is in flight.
        windowIsServerPaged && !Self.isLocalQuery(
            smartFilterActive: smartFilter != nil, downloadedOnly: downloadedOnly,
            offlineFallback: itemsSource == .offlineFallback, recentlyPlayed: false
        )
    }

    /// Library browse plan §6.2 (2026-10-05): the pure "is this Books query local or
    /// server-paged" decision. A smart filter, Downloaded only, the offline fallback and
    /// Recently Played are all complete lists held on the device; everything else is paged
    /// from the server. Pinned by `LibraryStateTests`.
    nonisolated static func isLocalQuery(
        smartFilterActive: Bool, downloadedOnly: Bool, offlineFallback: Bool, recentlyPlayed: Bool
    ) -> Bool {
        smartFilterActive || downloadedOnly || offlineFallback || recentlyPlayed
    }

    /// The window the Books grid and list render, whichever source it comes from. Library
    /// browse plan §6.2 (2026-10-05): local result sets are wrapped as
    /// `LibraryPageWindow(local:)` so slot rendering and the scrubber share one code path.
    /// Memoised on the same inputs as `displayedItems(downloads:)`.
    func displayWindow(downloads: [LibraryItem]) -> LibraryPageWindow {
        guard smartFilter != nil || showsLocalDownloads else { return window }
        let list = displayedItems(downloads: downloads)
        var hasher = Hasher()
        for item in list { hasher.combine(item.id) }
        let key = hasher.finalize()
        if let cached = localWindowCache, cached.key == key, cached.window.total == list.count {
            return cached.window
        }
        let local = LibraryPageWindow(local: list, pageSize: pageSize)
        localWindowCache = (key, local)
        return local
    }
    @ObservationIgnored private var localWindowCache: (key: Int, window: LibraryPageWindow)?

    /// The slot at `index` in the server window (plan §6.2). For a local set use
    /// `displayWindow(downloads:).slot(at:)`.
    func slot(at index: Int) -> LibraryPageWindow.Slot { window.slot(at: index) }

    /// Whether page fetches may run now. Library browse plan §5 (2026-10-05): no requests
    /// are fired while offline or while the server is unreachable; placeholders stay.
    var canFetchPages: Bool { ReachabilityStore.shared.status == .ok }

    /// Library browse plan §6.5 (2026-10-05): make sure the pages under `visible` (slot
    /// indices) plus one page either side are loaded. Fetches nearest-first, at most
    /// `maxPagesInFlight` at once, cancels fetches for pages that left the ±1 window (they go
    /// back to placeholders, not failed), and evicts far pages above 5,000 books (§6.4).
    /// Offline it fetches nothing and resumes on its own when the server is reachable again.
    func ensurePagesLoaded(around visible: ClosedRange<Int>) {
        _ = startPages(around: visible)
    }

    /// Library browse plan §6.3 (2026-10-05): the scrubber's release. Loads the page holding
    /// `index` first, then its neighbours (nearest-first, via `ensurePagesLoaded`). The
    /// view scrolls to the slot id itself; this only brings the data.
    func jump(to index: Int) {
        guard window.total > 0 else { return }
        let clamped = min(max(0, index), window.total - 1)
        ensurePagesLoaded(around: clamped...clamped)
    }

    /// Plan §11 Q3 (C) counts "a small server result" as local, but `canSelectAll` only
    /// sees it once every page is in memory, so Select All appeared or not depending on
    /// how far the user had scrolled (sim check, Batch 375). Entering select mode calls
    /// this: a server result of at most `selectAllLimit` books (four pages) is fetched in
    /// full, so Select All is there every time. Larger results fetch nothing extra.
    func loadSmallResultForSelectAll() {
        guard isWindowed, window.total > 0, window.total <= Self.selectAllLimit else { return }
        ensurePagesLoaded(around: 0...(window.total - 1))
    }

    /// Tapping a failed placeholder (plan §5): clears that page's failed flag and fetches it.
    func retryPage(containing index: Int) {
        let page = window.page(containing: index)
        if window.failed.contains(page) { window.retry(page) }
        ensurePagesLoaded(around: lastVisibleRange ?? (max(0, index)...max(0, index)))
    }

    @discardableResult
    private func startPages(around visible: ClosedRange<Int>) -> [Task<Void, Never>] {
        let lower = max(0, visible.lowerBound)
        let range = lower...max(lower, visible.upperBound)
        lastVisibleRange = range
        guard windowIsServerPaged, !isResettingWindow, let libraryId = selectedLibrary?.id,
              let key = windowQueryKey, key.libraryId == libraryId, window.total > 0 else { return [] }

        let firstPage = window.page(containing: range.lowerBound)
        let lastPage = window.page(containing: range.upperBound)
        // A jump that leaves a page's ±1 window cancels its fetch (plan §6.5).
        for (page, entry) in pageTasks where page < firstPage - 1 || page > lastPage + 1 {
            entry.task.cancel()
            pageTasks[page] = nil
            window.markCancelled(page)
        }
        // Only touch `window` when something changes: every mutation notifies observers.
        if window.total > LibraryPageWindow.defaultEvictionCeiling,
           window.pages.keys.contains(where: { abs($0 - firstPage) > LibraryPageWindow.defaultEvictionRadius }) {
            window.evict(keepingAround: firstPage)
        }

        guard canFetchPages else {
            scheduleResumeOnReconnect()
            return []
        }

        let budget = Self.maxPagesInFlight - window.inFlight.count
        guard budget > 0 else { return [] }
        // Planned uncapped, then filtered, then capped, so an excluded page doesn't use a slot.
        let plan = window.pagesToFetch(visible: range, prefetch: 1, maxInFlight: window.inFlight.count + window.pageCount)
            .filter { page in
                // A page that keeps repeating ids stays as merged once its budget is spent.
                !(window.stale.contains(page) && (duplicateRefetchCounts[page] ?? 0) >= Self.maxDuplicateRefetches)
            }
            .prefix(budget)
        return plan.map { startPageFetch($0, key: key) }
    }

    private func startPageFetch(_ page: Int, key: WindowQueryKey) -> Task<Void, Never> {
        let generation = loadGeneration
        let limit = window.pageSize
        nextPageToken &+= 1
        let token = nextPageToken
        window.markInFlight(page)
        let task = Task { [weak self] in
            do {
                let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                    libraryId: key.libraryId, limit: limit, page: page,
                    filter: key.filter, sort: key.sort, desc: key.descending
                )
                self?.finishPage(page, token: token, generation: generation, key: key, response: response, error: nil)
            } catch {
                self?.finishPage(page, token: token, generation: generation, key: key, response: nil, error: error)
            }
        }
        pageTasks[page] = (token, task)
        return task
    }

    private func finishPage(
        _ page: Int, token: Int, generation: Int, key: WindowQueryKey,
        response: LibraryItemsResponse?, error: Error?
    ) {
        // A newer query owns the window, or this fetch was cancelled (the page was marked
        // cancelled then, and may have a newer fetch of its own): drop the result.
        guard generation == loadGeneration, windowQueryKey == key,
              selectedLibrary?.id == key.libraryId,
              pageTasks[page]?.token == token else { return }
        pageTasks[page] = nil

        if let response {
            let outcome = window.merge(page: page, results: response.results, reportedTotal: response.total)
            if totalItems != window.total { totalItems = window.total }
            if itemsSource != .server { itemsSource = .server }
            pageFailureBurstActive = false
            SpotlightIndexer.index(response.results)
            if outcome == .duplicateIds {
                duplicateRefetchCounts[page, default: 0] += 1
            }
            // .totalChanged: other pages are now stale and refetch as they become visible;
            // .duplicateIds: this page is stale and refetches. Either way, and for .ok
            // (budget freed), carry on filling the visible window.
            if let visible = lastVisibleRange { ensurePagesLoaded(around: visible) }
            return
        }

        let failure = error ?? URLError(.unknown)
        let cancelled = failure is CancellationError || (failure as? URLError)?.code == .cancelled
        if cancelled {
            window.markCancelled(page)
            return
        }
        window.markFailed(page)
        ShelfLog.error(.network, "Library page \(page) failed: \(failure.localizedDescription)")
        if !pageFailureBurstActive {
            pageFailureBurstActive = true
            refreshFailureMessage = String(localized: "Couldn\u{2019}t load more books right now.", comment: "Library toast when fetching another page of books failed")
        }
        if let visible = lastVisibleRange { ensurePagesLoaded(around: visible) }
    }

    /// Cancels every page fetch and clears their in-flight marks (plan §6.5: sort, filter,
    /// library or account changes).
    private func cancelAllPageTasks() {
        for entry in pageTasks.values { entry.task.cancel() }
        pageTasks = [:]
        if !window.inFlight.isEmpty { window.markCancelledAll() }
    }

    /// Library browse plan §5 (2026-10-05) "Offline": visible pages fill without a tap when
    /// the server is reachable again. Watches `ReachabilityStore.status` until it is `.ok`,
    /// then clears failed pages and refetches the last visible range.
    private func scheduleResumeOnReconnect() {
        guard reconnectWatch == nil else { return }
        reconnectWatch = Task { [weak self] in
            while !Task.isCancelled {
                if ReachabilityStore.shared.status == .ok { break }
                await LibraryViewModel.nextReachabilityChange()
                // `onChange` fires on willSet; let the new value land first.
                await Task.yield()
            }
            guard let self else { return }
            self.reconnectWatch = nil
            guard !Task.isCancelled else { return }
            if !self.window.failed.isEmpty { self.window.retryAllFailed() }
            if let visible = self.lastVisibleRange { self.ensurePagesLoaded(around: visible) }
        }
    }

    private static func nextReachabilityChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = ReachabilityStore.shared.status
            } onChange: {
                continuation.resume()
            }
        }
    }

    func refresh() async {
        invalidateSmartFilterCache()
        if smartFilter != nil { isLoadingSmartFilter = true }  // Review 5 Low (refresh flash): no "No books match" while the personalised view reloads
        await loadItems(preservingWindow: true)
        await loadPersonalizedView()
        if let smartFilter { await selectSmartFilter(smartFilter) }
    }

    /// Re-run the items query after a sort/filter change.
    func applySortFilter() async {
        // Critique 2026-10-05 (Library, 2nd): `items` is no longer cleared first. Emptying it
        // before the request returned flashed the skeleton, and on a failure left a blank
        // list. The old books stay until the new page 0 lands (loadItems replaces them).
        await loadItems()
    }

    // MARK: - Series & Authors

    /// UI-11 (REVIEW_2026-08-12.md): true only when the *most recent* `loadSeries()`
    /// genuinely failed (not cancelled) with nothing to fall back to — lets
    /// `SeriesBrowseView` show a "Couldn't load · Retry" state instead of a false "No
    /// series" empty state indistinguishable from a library that really has none.
    /// Deliberately separate from `seriesLoaded` (which this function still sets `true`
    /// on that same failure branch, unchanged, so `loadBrowseAvailability()`'s
    /// re-fetch guard keeps its existing "don't hammer a failing server on every
    /// appearance" behavior) — the Retry button calls `loadSeries()` directly, bypassing
    /// that guard.
    var seriesLoadFailed = false

    /// Item 14 (REVIEW-2026-09-09-REMAINING.md): `getSeries` is itself paginated
    /// (`limit`/`page`, same shape `getLibraryItems` uses), but this used to fetch only
    /// page 0 and treat that as the whole Series browse mode — any library with more
    /// than 100 series silently truncated at the first page, with no indication
    /// anything was missing. `findSeries` (above) already had to paginate the same
    /// endpoint to find one named series in a large library; this reuses that pattern
    /// to load the *whole* list instead.
    ///
    /// Page-planning is pulled out into `nextPage(after:receivedInPage:accumulatedCount:
    /// total:limit:)` so the "should we fetch another page, and which one" decision is
    /// pure and testable without a live server — see `LibraryViewModelPaginationTests`.
    func loadSeries() async {
        guard let library = selectedLibrary else { return }
        let libraryId = library.id
        isLoadingSeries = true
        seriesLoadFailed = false
        let limit = 100
        // Defensive cap so a pathological/looping server response can't page forever —
        // same reasoning as `findSeries`'s `maxPages` and `fetchAllItemsForSmartFilter`'s
        // 5000-item cap. 200 pages * 100/page = 20,000 series, far beyond any real
        // self-hosted library.
        let maxPages = 200
        var all: [Series] = []
        var page = 0
        do {
            while true {
                let response = try await AudiobookshelfAPI.shared.getSeries(libraryId: libraryId, limit: limit, page: page)
                // Ignore a response for a library we've since switched away from.
                guard selectedLibrary?.id == libraryId else { isLoadingSeries = false; return }
                all.append(contentsOf: response.results)
                guard let next = Self.nextPage(
                    after: page, receivedInPage: response.results.count,
                    accumulatedCount: all.count, total: response.total, limit: limit
                ), next < maxPages else { break }
                page = next
            }
            // Preserve server order (the existing sort) — pages are appended in the
            // order fetched, never re-sorted here.
            seriesList = all
            seriesLoaded = true
        } catch {
            // A cancelled pull-to-refresh (SwiftUI tears down the `.refreshable`
            // task) surfaces as a cancellation error — it must NOT wipe the list.
            // A transient failure also shouldn't blow away content already shown;
            // only clear when we have nothing to fall back to.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                if !all.isEmpty {
                    // A later page failed after earlier ones succeeded — show what we
                    // have rather than discarding pages that loaded fine.
                    seriesList = all
                    seriesLoaded = true
                } else if seriesList.isEmpty {
                    seriesList = []
                    seriesLoaded = true
                    seriesLoadFailed = true
                }
            }
        }
        isLoadingSeries = false
    }

    /// Pure page-plan for `loadSeries()`'s pagination loop: given the page just fetched
    /// and what it returned, decide whether another page is worth fetching and which one.
    /// `nil` means "stop" — either this page was short (last page, matching the
    /// `results.count < pageSize` check `findSeries` uses), or the running total has
    /// already reached the server-reported `total` (matching
    /// `fetchAllItemsForSmartFilter`'s `all.count >= response.total` check). `total` is
    /// optional because `SeriesResponse.total` is: when the server omits it, only the
    /// short-page check can end the loop.
    nonisolated static func nextPage(
        after page: Int, receivedInPage: Int, accumulatedCount: Int, total: Int?, limit: Int
    ) -> Int? {
        guard receivedInPage > 0 else { return nil }
        if let total, accumulatedCount >= total { return nil }
        guard receivedInPage >= limit else { return nil }
        return page + 1
    }

    /// UI-11: true/false pair mirroring `seriesLoadFailed` above, for `filterData`
    /// (author/narrator/genre lists). Previously `loadFilterData()` had no loading or
    /// failure signal at all — `filterData = try? await ...` swallowed every error
    /// identically to "hasn't loaded yet," which is exactly why `AuthorsBrowseView`
    /// showed a false "No authors" during normal loading (no loading check existed) and
    /// `NarratorsBrowseView` was stuck on its loading spinner forever on a real failure
    /// (its `filterData == nil` loading check never had a way to know to stop).
    var isLoadingFilterData = false
    var filterDataLoadFailed = false

    func loadFilterData() async {
        guard let library = selectedLibrary else { return }
        isLoadingFilterData = true
        filterDataLoadFailed = false
        let generation = accountGeneration  // Review 6 Medium 10
        let libraryId = library.id
        func isStale() -> Bool {
            Self.isStaleLoad(startedAccountGeneration: generation, currentAccountGeneration: accountGeneration,
                             startedLibraryId: libraryId, currentLibraryId: selectedLibrary?.id)
        }
        do {
            let fetched = try await AudiobookshelfAPI.shared.getFilterData(libraryId: library.id)
            guard !isStale() else { return }
            filterData = fetched
        } catch {
            guard !isStale() else { return }
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled { filterDataLoadFailed = true }
        }
        isLoadingFilterData = false
    }

    // MARK: - Narrator-first discovery

    /// Books by any narrator starred in `FavoritesStore`, newest-added first — the Home
    /// "From Narrators You Follow" shelf. Empty (not loading) when no narrators are
    /// starred, so the shelf itself just doesn't render rather than showing empty.
    var favoriteNarratorItems: [LibraryItem] = []
    var isLoadingFavoriteNarratorItems = false

    /// `FavoritesStore` only keeps lowercased names (it doesn't care which library they
    /// came from), so this recovers each favorite's real on-server casing from
    /// `filterData.narrators` before building the `APIFilter` query — the server's
    /// narrator filter expects the exact stored name, not a case-insensitive match.
    func loadFavoriteNarratorItems() async {
        guard let library = selectedLibrary else { favoriteNarratorItems = []; return }
        let starred = FavoritesStore.shared.favoriteNarrators
        // Polish pass (J2-4): no starred narrators means nothing to filter for, so don't pay for
        // the filter-data request (it's only needed to recover each starred name's casing).
        guard !starred.isEmpty else { favoriteNarratorItems = []; return }
        if filterData == nil { await loadFilterData() }
        guard let allNarrators = filterData?.narrators, !allNarrators.isEmpty else {
            favoriteNarratorItems = []
            return
        }
        let matchingNames = allNarrators.filter { starred.contains(FavoritesStore.normalized($0)) }
        guard !matchingNames.isEmpty else { favoriteNarratorItems = []; return }

        isLoadingFavoriteNarratorItems = true
        let generation = accountGeneration  // Review 6 Medium 10
        let libraryId = library.id
        var seenIds = Set<String>()
        var results: [LibraryItem] = []
        for name in matchingNames {
            // Review 6 Medium 10: stop (and drop everything) once the account or library moved on.
            if Self.isStaleLoad(startedAccountGeneration: generation, currentAccountGeneration: accountGeneration,
                                startedLibraryId: libraryId, currentLibraryId: selectedLibrary?.id) { return }
            let filter = APIFilter.encode(group: "narrators", value: name)
            guard let books = try? await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: library.id, limit: 40, page: 0, filter: filter, sort: LibrarySort.addedAt.rawValue, desc: true
            ) else { continue }
            for book in books.results where !seenIds.contains(book.id) {
                seenIds.insert(book.id)
                results.append(book)
            }
        }
        if Self.isStaleLoad(startedAccountGeneration: generation, currentAccountGeneration: accountGeneration,
                            startedLibraryId: libraryId, currentLibraryId: selectedLibrary?.id) { return }
        favoriteNarratorItems = results.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        isLoadingFavoriteNarratorItems = false
    }

    /// Front-loads the light browse lists so the Library page can hide modes the library
    /// doesn't actually have (e.g. no Collections/Playlists/Series). Guards avoid re-fetching.
    func loadBrowseAvailability() async {
        if filterData == nil { await loadFilterData() }
        if !seriesLoaded { await loadSeries() }
        if !collectionsLoaded { await loadCollections() }
        if !playlistsLoaded { await loadPlaylists() }
    }

    // MARK: - Collections & Playlists

    var collections: [BookCollection] = []
    var playlists: [Playlist] = []
    var isLoadingCollections = false
    var isLoadingPlaylists = false
    var collectionsLoaded = false
    var playlistsLoaded = false
    /// UI-11: same `seriesLoadFailed` pattern applied to collections/playlists.
    var collectionsLoadFailed = false
    var playlistsLoadFailed = false

    func loadCollections() async {
        guard let library = selectedLibrary else { return }
        let libraryId = library.id
        let generation = accountGeneration  // Review 7 Low (collections/playlists)
        isLoadingCollections = true
        collectionsLoadFailed = false
        do {
            let result = try await AudiobookshelfAPI.shared.getCollections(libraryId: library.id)
            guard selectedLibrary?.id == libraryId, generation == accountGeneration else { isLoadingCollections = false; return }
            collections = result
            collectionsLoaded = true
        } catch {
            // Don't let a cancelled refresh or transient failure wipe the list.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            guard generation == accountGeneration, selectedLibrary?.id == libraryId else { isLoadingCollections = false; return }
            if !cancelled && collections.isEmpty { collectionsLoaded = true; collectionsLoadFailed = true }
        }
        isLoadingCollections = false
    }

    func loadPlaylists() async {
        guard let library = selectedLibrary else { return }
        let libraryId = library.id
        let generation = accountGeneration  // Review 7 Low (collections/playlists)
        isLoadingPlaylists = true
        playlistsLoadFailed = false
        do {
            let result = try await AudiobookshelfAPI.shared.getPlaylists(libraryId: library.id)
            guard selectedLibrary?.id == libraryId, generation == accountGeneration else { isLoadingPlaylists = false; return }
            playlists = result
            playlistsLoaded = true
        } catch {
            // Don't let a cancelled refresh or transient failure wipe the list.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            guard generation == accountGeneration, selectedLibrary?.id == libraryId else { isLoadingPlaylists = false; return }
            if !cancelled && playlists.isEmpty { playlistsLoaded = true; playlistsLoadFailed = true }
        }
        isLoadingPlaylists = false
    }

    /// Loads the books for a given filter (Authors/Narrators/Genres screens).
    /// Returns `nil` on failure so callers can show a retry CTA instead of an
    /// empty state that's indistinguishable from a genuinely empty result.
    func items(filteredBy filter: String, limit: Int = 200, allPages: Bool = true) async -> [LibraryItem]? {
        guard let library = selectedLibrary else { return [] }
        let libraryId = library.id
        let generation = accountGeneration
        var all: [LibraryItem] = []
        var page = 0
        do {
            // Review 7 Low (200 cap): page until `total` rather than stopping at the first page.
            while true {
                let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                    libraryId: libraryId,
                    limit: limit,
                    page: page,
                    filter: filter,
                    sort: LibrarySort.title.rawValue
                )
                guard generation == accountGeneration, selectedLibrary?.id == libraryId else { return nil }
                all += response.results
                page += 1
                if !allPages || response.results.isEmpty || all.count >= response.total { break }
            }
            return all
        } catch {
            return nil
        }
    }

    // MARK: - Personalized View

    func loadPersonalizedView() async {
        guard let library = selectedLibrary else { return }
        // Fix 5 (REVIEW-2026-09-09.md): the generation-plus-library guard `loadItems()`
        // has always had. Without it, a response for the *previous* account arriving after
        // a switch passed the `isEmpty` check below (because `resetForAccountChange()` had
        // just emptied the shelves), so Home filled with the old account's books, the
        // widget published them, and `autoDownloadIfEnabled` started fetching them with
        // the new account's token. One of the callers is a fire-and-forget `Task` in
        // `WatchSessionManager.pushLibraryIfNeeded()` that nothing cancels, so this guard
        // is the only thing standing between that task and the state it would overwrite.
        let generation = accountGeneration
        let libraryId = library.id
        isLoadingPersonalized = true
        // Polish pass (J2-1/J2-4): the progress and stats requests don't depend on the shelves
        // response, so start them now and collect them below. Unstructured tasks (not
        // `async let`) so a failed shelves request still lets the progress load finish, as it did
        // when `loadLibraries()` awaited it up front.
        let progressLoad = Task { await self.loadUserProgress() }
        let statsLoad = Task { await self.listeningStats(maxAge: 0) }

        do {
            let shelves = try await LaunchTrace.interval("PersonalizedView") {
                try await AudiobookshelfAPI.shared.getPersonalizedView(libraryId: library.id)
            }
            guard !Self.isStaleLoad(startedAccountGeneration: generation,
                                    currentAccountGeneration: accountGeneration,
                                    startedLibraryId: libraryId,
                                    currentLibraryId: selectedLibrary?.id) else {
                isLoadingPersonalized = false
                return
            }
            // Don't blank Home on a transient empty response: only replace when we
            // actually got shelves back, or when there was nothing shown to begin with.
            // Polish pass (J2-2): the first real response always replaces cached shelves.
            if !shelves.isEmpty || personalizedShelves.isEmpty || shelvesFromCache {
                personalizedShelves = shelves
            }
            shelvesFromCache = false
            if !shelves.isEmpty {
                HomeShelvesCache.save(shelves, scope: DownloadManager.shared.currentScopeKey(), libraryId: libraryId)
            }
            personalizedLoadFailed = false
            // Merge user progress into shelf items (started above, alongside the shelves request).
            await progressLoad.value

            // Refresh the streak here (with the library load / pull-to-refresh) rather
            // than on every Home header appearance.
            if let stats = await statsLoad.value {
                listeningStreak = stats.currentStreak
                // ASO pass (AppStoreListing.md, 14 Sep 2026): a 7-day streak is the other
                // review-prompt trigger, alongside finishing a book (see
                // `PlayerViewModel`'s `onPlaybackFinished` hook). `LibraryViewModel` is
                // `@MainActor`, matching `ReviewPromptManager`.
                ReviewPromptManager.shared.noteStreak(days: stats.currentStreak)
            }

            // Re-checked after the two awaits above: an account switch during the progress
            // fetch or the stats fetch must not reach the widget publish and the
            // auto-download hand-off below with the previous account's shelf.
            guard !Self.isStaleLoad(startedAccountGeneration: generation,
                                    currentAccountGeneration: accountGeneration,
                                    startedLibraryId: libraryId,
                                    currentLibraryId: selectedLibrary?.id) else {
                isLoadingPersonalized = false
                return
            }

            // Auto-download Continue Listening items if enabled.
            if let continueShelf = personalizedShelves.first(where: { $0.labelStringKey == "LabelContinueListening" }),
               let entities = continueShelf.entities {
                DownloadManager.shared.autoDownloadIfEnabled(entities)
                // Publish the same shelf into the App Group so the widget's configuration
                // intent can offer these books. The widget can't reach the library itself
                // — see `SharedLibrary`. No-ops when the set hasn't actually changed.
                //
                // W2 (REVIEW_2026-09-04_UI.md Pass 4): the progress lookup is not optional
                // in practice. These entities come straight from `getPersonalizedView`,
                // which omits `userMediaProgress` entirely, so publishing them raw sent
                // every Continue Listening book to the widget at position zero. The map is
                // already populated at this point — `loadUserProgress()` is awaited above,
                // before this block — so there is no second publish to schedule.
                WidgetLibraryPublisher.publishContinueListening(entities) { id in
                    self.progressFor(itemId: id)
                }
            }
        } catch {
            // A cancelled pull-to-refresh must not touch the shelves.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                personalizedLoadFailed = true
                // A failed refresh must NOT wipe already-loaded shelves — that made the
                // whole Home screen go blank on any transient hiccup. Keep the last-good
                // content and surface a non-destructive error only when we have shelves;
                // if we truly have nothing yet, leave it empty so the empty-state shows.
                if personalizedShelves.isEmpty {
                    ShelfLog.error(.network, "Personalized view load failed: \(error.localizedDescription)")
                } else {
                    refreshFailureMessage = String(localized: "Couldn\u{2019}t refresh right now. Showing your last loaded books.", comment: "Library refresh failure toast while keeping the last loaded books")
                    ShelfLog.error(.network, "Personalized refresh failed (kept cached shelves): \(error.localizedDescription)")
                }
            }
        }

        isLoadingPersonalized = false
    }

    // MARK: - User Progress

    private var userProgressMap: [String: MediaProgress] = [:] {
        didSet { displayRevision &+= 1 }
    }
    /// Podcast-episode progress, keyed by `episodeId` — a podcast's `libraryItemId` is
    /// shared across every episode, so it can't be the key here the way it is for a
    /// book above (that would collapse every episode's progress onto one record).
    private var episodeProgressMap: [String: MediaProgress] = [:]

    func loadUserProgress() async {
        // Fix 5 (REVIEW-2026-09-09.md): account-generation guard (no library dimension —
        // `/api/me` isn't library-scoped). This is the more dangerous of the two unguarded
        // loaders: a stale response doesn't just repopulate the progress maps with another
        // account's positions, it hands them to `DownloadManager.reconcile`, which can
        // write a foreign position straight into a downloaded book's local manifest.
        let generation = accountGeneration
        do {
            let user = try await LaunchTrace.interval("UserProgress") {
                try await AudiobookshelfAPI.shared.getCurrentUser()
            }
            guard !Self.isStaleLoad(startedAccountGeneration: generation,
                                    currentAccountGeneration: accountGeneration,
                                    startedLibraryId: nil, currentLibraryId: nil) else { return }
            // The payload parsed — clear the one-shot alert guard even if this user
            // genuinely has no progress records yet.
            hasReportedProgressDecodeFailure = false
            lastUserProgressLoadSucceeded = true
            if let progressList = user.mediaProgress {
                let bookProgress = progressList.filter { $0.episodeId == nil }
                let episodeProgress = progressList.filter { $0.episodeId != nil }
                userProgressMap = Dictionary(
                    bookProgress.map { ($0.libraryItemId, $0) },
                    uniquingKeysWith: { a, b in
                        // Keep the most recently updated one
                        (a.lastUpdate ?? 0) > (b.lastUpdate ?? 0) ? a : b
                    }
                )
                episodeProgressMap = Dictionary(
                    episodeProgress.compactMap { p in p.episodeId.map { ($0, p) } },
                    uniquingKeysWith: { a, b in (a.lastUpdate ?? 0) > (b.lastUpdate ?? 0) ? a : b }
                )
                // Reconcile any offline progress with the server (last-write-wins).
                await DownloadManager.shared.reconcile(serverProgress: userProgressMap)
            }
        } catch {
            // §Sync (REVIEW-2026-09-09.md): this used to be a bare `// Non-critical`.
            // It is not. Everything progress-shaped hangs off this one call — every
            // book's progress bar, All Bookmarks, `DownloadManager.reconcile`, and the
            // `lastUpdate` map that decides whether a queued offline position is safe to
            // push — so swallowing the error silently made a fully broken sync look like
            // a user who had simply never listened to anything.
            //
            // Note what is deliberately NOT here: the two progress maps are only
            // assigned inside the `do` block above, so a failed load keeps the
            // last-good progress in memory rather than blanking the library.
            //
            // `DecodingError.localizedDescription` is the useless generic "the data
            // couldn't be read" string; `String(describing:)` carries the coding path and
            // expected type, which is the only thing that makes a payload mismatch
            // diagnosable from an exported diagnostics file.
            let detail = error is DecodingError ? String(describing: error) : error.localizedDescription
            ShelfLog.error(.sync, "User progress load failed: \(detail)")
            lastUserProgressLoadSucceeded = false
            // Offline/transient failures are already covered by the connectivity banner
            // and must not raise an alert; a `DecodingError` is different — it means this
            // server's payload is one we can't read at all, which is both actionable and
            // invisible otherwise. Surfaced through the existing `errorMessage` channel
            // (the Home/Library `errorAlert`), and only once per run so a persistently
            // malformed payload doesn't re-prompt on every refresh.
            if error is DecodingError, !hasReportedProgressDecodeFailure {
                hasReportedProgressDecodeFailure = true
                errorMessage = String(localized: "Couldn't read your listening progress from the server. Your saved positions on this device are unchanged.", comment: "Error alert when the server's progress data could not be decoded")
            }
        }
    }

    /// One-shot guard for the alert above — reset on the next successful load.
    private var hasReportedProgressDecodeFailure = false
    /// Whether the most recent `loadUserProgress()` read `/api/me` successfully. Library
    /// browse plan §6.6 (2026-10-05): the bulk finish diff is only trustworthy against a
    /// fresh read, not the last-good map a failed read leaves in place.
    @ObservationIgnored private var lastUserProgressLoadSucceeded = false

    func progressFor(itemId: String) -> MediaProgress? {
        userProgressMap[itemId]
    }

    /// Progress for one episode of a podcast — see `episodeProgressMap`.
    func progressFor(episodeId: String) -> MediaProgress? {
        episodeProgressMap[episodeId]
    }

    /// Batch 406: a progress record pushed live by the server (`ServerEventSocket`,
    /// `user_item_progress_updated`) from another device or the web player. Updates the
    /// same maps `loadUserProgress()` fills, so every progress bar reading
    /// `progressFor(...)` moves without a refetch. Newer-or-equal `lastUpdate` wins
    /// (`RemoteProgressDecision.replacesCached`) so a late, out-of-order event can't roll
    /// a bar back. Deliberately does NOT call `DownloadManager.reconcile`: that walks
    /// every downloaded book and treats a missing server entry as "push local", so a
    /// one-record map would be wrong there; downloads reconcile on the next full load.
    func applyRemoteProgress(_ progress: MediaProgress) {
        if let episodeId = progress.episodeId {
            guard RemoteProgressDecision.replacesCached(
                existingLastUpdate: episodeProgressMap[episodeId]?.lastUpdate,
                incomingLastUpdate: progress.lastUpdate) else { return }
            episodeProgressMap[episodeId] = progress
        } else {
            guard RemoteProgressDecision.replacesCached(
                existingLastUpdate: userProgressMap[progress.libraryItemId]?.lastUpdate,
                incomingLastUpdate: progress.lastUpdate) else { return }
            userProgressMap[progress.libraryItemId] = progress
        }
    }

    /// Batch 409: the full progress list from a `user_updated` socket event (web "mark
    /// finished", manual edit, reset). Applies only the diff
    /// `RemoteProgressDecision.snapshotDiff` computes, so an echo of state already held
    /// changes nothing and triggers no re-render; a reset (record gone from the snapshot)
    /// removes the cached entry. Like `applyRemoteProgress`, does not call
    /// `DownloadManager.reconcile`. Returns the number of keys changed.
    @discardableResult
    func applyRemoteProgressSnapshot(_ snapshot: [MediaProgress], allRecordsDecoded: Bool) -> Int {
        let diff = RemoteProgressDecision.snapshotDiff(
            cachedItems: userProgressMap, cachedEpisodes: episodeProgressMap,
            snapshot: snapshot, allRecordsDecoded: allRecordsDecoded)
        guard !diff.isEmpty else { return 0 }
        // Continue Listening is the server's shelf, not derived from these maps, so a book
        // finished or reset on the web would sit on it until the next refetch. Refetch once,
        // debounced, when finished status flips or a record goes away.
        let shelfChanged = !diff.removedItemIds.isEmpty || !diff.removedEpisodeIds.isEmpty
            || diff.upserts.contains { record in
                let cached = record.episodeId.map { episodeProgressMap[$0] } ?? userProgressMap[record.libraryItemId]
                return (cached?.isFinished ?? false) != (record.isFinished ?? false)
            }
        if shelfChanged {
            remoteShelfRefreshTask?.cancel()
            remoteShelfRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.loadPersonalizedView()
            }
        }
        var items = userProgressMap
        var episodes = episodeProgressMap
        for record in diff.upserts {
            if let episodeId = record.episodeId { episodes[episodeId] = record }
            else { items[record.libraryItemId] = record }
        }
        for key in diff.removedItemIds { items[key] = nil }
        for key in diff.removedEpisodeIds { episodes[key] = nil }
        // Assign only the maps that changed (userProgressMap's didSet bumps displayRevision).
        if !diff.removedItemIds.isEmpty || diff.upserts.contains(where: { $0.episodeId == nil }) {
            userProgressMap = items
        }
        if !diff.removedEpisodeIds.isEmpty || diff.upserts.contains(where: { $0.episodeId != nil }) {
            episodeProgressMap = episodes
        }
        return diff.upserts.count + diff.removedItemIds.count + diff.removedEpisodeIds.count
    }

    var finishedBooksCount: Int {
        userProgressMap.values.filter { $0.isFinished == true }.count
    }

    // MARK: - Search

    func search() async {
        guard let library = selectedLibrary,
              !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            searchFailed = false
            searchIsLocal = false
            isSearching = false
            return
        }

        searchGeneration &+= 1
        let generation = searchGeneration
        let query = searchQuery
        isSearching = true
        searchFailed = false
        // The two early `return`s below (stale response) used to skip past
        // `isSearching = false` entirely, so a superseded request — which the
        // search-field debounce produces routinely while typing — could leave the
        // spinner stuck on for the rest of the session. `defer` guarantees it clears,
        // but only when we're still the *latest* generation: if a newer search has
        // already started, let that one own clearing the flag when it finishes.
        defer {
            if generation == searchGeneration { isSearching = false }
        }

        // Critique 2026-10-05 (Library): when the device or server is known to be
        // unreachable, don't spend a timeout on a request that cannot succeed — search the
        // downloaded books locally instead.
        if ReachabilityStore.shared.status != .ok {
            searchIsLocal = true
            searchResults = LibraryLocalQuery.search(DownloadManager.shared.downloadedLibraryItems(), query: query)
            return
        }
        searchIsLocal = false

        do {
            let results = try await AudiobookshelfAPI.shared.search(
                libraryId: library.id,
                query: query
            )
            // Ignore a response for a query the user has since changed.
            guard generation == searchGeneration, query == searchQuery else { return }
            searchResults = results
        } catch {
            guard generation == searchGeneration else { return }
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if cancelled { return }
            // A failure is not "no results": flag it, and offer whatever downloaded books
            // match so the person isn't left with nothing.
            searchFailed = true
            searchIsLocal = true
            searchResults = LibraryLocalQuery.search(DownloadManager.shared.downloadedLibraryItems(), query: query)
        }
    }

    // MARK: - Progress Actions

    /// Critique 2026-10-06 (harden, PRODUCT.md principle 2): a single-book Mark Finished
    /// overwrites the listening position, so it now snapshots the prior progress and offers
    /// Undo (`progressUndoMessage`), as bulk Mark Finished already did. No confirmation for
    /// one book: the Undo toast is the safety net (HIG Undo and redo).
    @discardableResult
    func markFinished(item: LibraryItem) async -> Bool {
        let prior = progressSnapshot(for: item)
        let ok = await updateProgress(item: item, progress: 1.0, currentTime: item.duration, isFinished: true, historyAction: .markedFinished)
        if ok {
            offerProgressUndo(prior, action: .markedFinished)
            // Batch 428: finished means heard to the end (listening frontier for transcript features).
            TranscriptStore.raiseHighWater(item.duration, itemId: item.id)
            // Batch 443: single marks only; bulk marking doesn't flood Hardcover.
            ReadingSiteSync.shared.bookFinished(item)
        }
        return ok
    }

    @discardableResult
    func markUnfinished(item: LibraryItem) async -> Bool {
        // Review Low (mark not finished, 30 October 2026): a list item may carry no progress
        // (0 would reset the position); prefer the freshly loaded progress map.
        let current = progressFor(itemId: item.id) ?? item.mediaProgress
        // Review 5 Medium 6: the loaded book's player position is newer than the server's.
        let player = AudioPlayerService.shared
        if player.currentItemId == item.id, player.currentTime > 1, item.duration > 0 {
            return await updateProgress(item: item, progress: min(1, player.currentTime / item.duration), currentTime: player.currentTime, isFinished: false, historyAction: .markedUnfinished)
        }
        return await updateProgress(item: item, progress: current?.progress ?? 0, currentTime: current?.currentTime ?? 0, isFinished: false, historyAction: .markedUnfinished)
    }

    /// Critique 2026-10-06 (harden): Reset Progress shares the single-book Undo with Mark
    /// Finished. Book Detail still confirms first (it clears everything); the toast then
    /// offers the way back.
    @discardableResult
    func resetProgress(item: LibraryItem) async -> Bool {
        let prior = progressSnapshot(for: item)
        let ok = await updateProgress(item: item, progress: 0, currentTime: 0, isFinished: false, historyAction: .resetProgress)
        if ok { offerProgressUndo(prior, action: .resetProgress) }
        return ok
    }

    // MARK: - Loaded-player sync (Review 5 Medium 6)

    enum LoadedPlayerSync: Equatable, Sendable { case none, markFinished, seek(Double) }

    /// What the player must do when a progress write targets `itemId`. Only the loaded book
    /// is touched; finishing closes it out (no autoplay), anything else moves it to the new
    /// position so its next sync writes that, not the old one. Pinned by tests.
    nonisolated static func loadedPlayerSync(loadedItemId: String?, itemId: String, isFinished: Bool, currentTime: Double, duration: Double = 0) -> LoadedPlayerSync {
        guard let loadedItemId, loadedItemId == itemId else { return .none }
        if isFinished { return .markFinished }
        // Review 6 Medium 4: an unfinished write at the very end (a finished book's own position) must not drag the player to its end.
        if duration > 0, currentTime >= duration - 1 { return .none }
        return .seek(max(0, currentTime))
    }

    /// Review 6 Medium 4: "Mark unfinished" restores a finished book's server position, which is
    /// its end. For the loaded book the player's position is the real one, so swap it in.
    nonisolated static func snapshotsForLoadedPlayer(_ snapshots: [LibraryProgressSnapshot], loadedItemId: String?, playerTime: Double) -> [LibraryProgressSnapshot] {
        guard let loadedItemId, playerTime > 1 else { return snapshots }
        return snapshots.map { snap in
            guard snap.itemId == loadedItemId, !snap.isFinished, snap.duration > 0, snap.currentTime >= snap.duration - 1 else { return snap }
            return LibraryProgressSnapshot(itemId: snap.itemId, title: snap.title, currentTime: playerTime,
                                           progress: min(1, playerTime / snap.duration), isFinished: false, duration: snap.duration)
        }
    }

    /// Review 6 Low (rollback jump): put the player back only if it is still where
    /// `movePlayerBeforeWrite` left it (not playing, playhead untouched). Pure.
    nonisolated static func shouldRollbackPlayer(movedTo: Double, currentTime: Double, isPlaying: Bool) -> Bool {
        !isPlaying && abs(currentTime - movedTo) < 1
    }

    /// Seeks then pauses (never plays) the loaded player before the server write, so the pause's
    /// own sync carries the new position, not the old one. Left alone when the position isn't
    /// really moving (Not Finished on the book being played). Returns the prior position for a
    /// rollback if the write fails.
    private func movePlayerBeforeWrite(_ sync: LoadedPlayerSync) -> (prior: Double, movedTo: Double)? {
        guard case .seek(let time) = sync else { return nil }
        let player = AudioPlayerService.shared
        guard !player.mixtapeDriving else { return nil }   // Review 6 Low (mixtape): a clip position isn't the book's
        let prior = player.currentTime
        guard abs(prior - time) >= 1 else { return nil }
        player.seek(to: time)
        player.pause()
        return (prior, time)
    }

    /// The write failed: put the player back, unless the listener has since moved it or started
    /// playing (Review 6 Low (rollback jump)), then pause again so the queued/iCloud position
    /// is the old one, not the rejected one (Review 6 Low (failed write)).
    private func rollbackPlayer(_ move: (prior: Double, movedTo: Double)?) {
        guard let move else { return }
        let player = AudioPlayerService.shared
        guard Self.shouldRollbackPlayer(movedTo: move.movedTo, currentTime: player.currentTime, isPlaying: player.isPlaying) else { return }
        player.seek(to: move.prior)
        player.pause()
    }

    /// Closes the loaded book out in the player after a successful finished write. Skipped while a
    /// mixtape drives the player (Review 6 Low (mixtape)).
    private func finishLoadedPlayer() {
        guard !AudioPlayerService.shared.mixtapeDriving else { return }
        AudioPlayerService.shared.markCurrentBookFinished(source: .library)
    }

    /// Review 6 Low (stale finished entry): an Undo of Mark Finished for the loaded book must not
    /// leave a queued `isFinished: true` that would re-finish it later.
    private func discardQueuedFinish(itemId: String) {
        let scope = PendingBookmarkQueue.currentScope()   // captured now, before the hop
        Task { await PendingProgressQueue.shared.discardAudioEntry(itemId: itemId, scope: scope) }
    }

    // MARK: - One-book Undo (Critique 2026-10-06, harden)

    /// Which single-book change the Undo toast is offering to reverse.
    enum SingleProgressChange: Equatable, Sendable {
        case markedFinished, resetProgress
    }

    /// The toast copy for a single-book change: "Marked “Dune” finished" /
    /// "Reset “Dune” to the start". Pure, pinned by `SingleProgressUndoTests`.
    nonisolated static func progressUndoCopy(for change: SingleProgressChange, title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = name.isEmpty
            ? String(localized: "this book", comment: "Stands in for the book title inside the Undo toast when the title is empty")
            : "\u{201C}\(name)\u{201D}"
        switch change {
        case .markedFinished: return String(localized: "Marked \(quoted) finished", comment: "Undo toast; %@ is the quoted book title, or 'this book'")
        case .resetProgress: return String(localized: "Reset \(quoted) to the start", comment: "Undo toast; %@ is the quoted book title, or 'this book'")
        }
    }

    /// Undo didn't reach the server. Calm, says nothing changed, and where to try again.
    nonisolated static var progressUndoFailureMessage: String {
        String(localized: "Couldn\u{2019}t reach your server, so nothing changed. Try again from Recent Changes.", comment: "Undo toast when the server could not be reached. 'Recent Changes' is a screen name")
    }

    private func offerProgressUndo(_ prior: LibraryProgressSnapshot, action: SingleProgressChange) {
        progressUndoSnapshot = prior
        // `updateProgress` has just recorded this change, so it is the newest entry.
        progressUndoHistoryId = PlaybackHistoryStore.shared.mostRecentEntry(forItemId: prior.itemId)?.id
        progressUndoMessage = Self.progressUndoCopy(for: action, title: prior.title)
    }

    /// The Undo toast's action: puts the book back to the progress it had before the last
    /// single-book Mark Finished / Reset Progress (finished flag and position). While the
    /// change is still the book's latest history entry it goes through
    /// `PlaybackHistoryStore.undo`, which restores and removes that entry, so Recent Changes
    /// doesn't offer it twice; otherwise it restores the snapshot through the bulk path. A
    /// failure is a non-blocking toast that says nothing changed.
    func undoLastProgressChange() {
        guard let snapshot = progressUndoSnapshot else { return }
        let historyId = progressUndoHistoryId
        progressUndoSnapshot = nil
        progressUndoHistoryId = nil
        progressUndoMessage = nil
        Task {
            let history = PlaybackHistoryStore.shared
            let ok: Bool
            if let historyId, let entry = history.entries.first(where: { $0.id == historyId }), history.canUndo(entry) {
                ok = await history.undo(entry, libraryViewModel: self)
            } else {
                ok = await restoreProgress([snapshot], reload: true).isEmpty
            }
            if !ok { refreshFailureMessage = Self.progressUndoFailureMessage }
        }
    }

    /// `historyAction` is only passed by the three explicit, user-initiated actions
    /// above — not by any incidental future caller of this shared helper — since those
    /// are the ones worth recording an undo point for (see `PlaybackHistoryStore`).
    private func updateProgress(item: LibraryItem, progress: Double, currentTime: Double, isFinished: Bool, historyAction: PlaybackHistoryStore.HistoryAction? = nil) async -> Bool {
        // Snapshot the state as it was *before* this change, from whichever source is
        // most current (server progress map, falling back to what the item itself
        // carried) — this is what an undo restores to.
        let previous = progressFor(itemId: item.id) ?? item.mediaProgress
        // Review 5 Medium 6: the loaded book's player would sync its old position over this.
        let sync = Self.loadedPlayerSync(loadedItemId: AudioPlayerService.shared.currentItemId, itemId: item.id, isFinished: isFinished, currentTime: currentTime, duration: item.duration)
        let rollback = movePlayerBeforeWrite(sync)
        let scope = PendingBookmarkQueue.currentScope()
        do {
            try await AudiobookshelfAPI.shared.updateProgress(
                libraryItemId: item.id,
                progress: progress,
                currentTime: currentTime,
                duration: item.duration,
                isFinished: isFinished,
                expectedScope: scope  // Review 5 Low (expectedScope)
            )
            if sync == .markFinished { finishLoadedPlayer() }  // Review 5 Medium 6 (pauses, never autoplays)
            if let historyAction {
                PlaybackHistoryStore.shared.record(
                    itemId: item.id, title: item.title, action: historyAction,
                    previousCurrentTime: previous?.currentTime ?? 0,
                    previousIsFinished: previous?.isFinished ?? false,
                    previousDuration: item.duration
                )
            }
            await loadUserProgress()
            // If this book was the one queued for "resume on launch", drop it from the
            // restore snapshot once it's marked finished or reset.
            if (isFinished || progress == 0), SharedPlayback.read()?.itemId == item.id {
                SharedPlayback.write(nil)
            }
            return true
        } catch {
            rollbackPlayer(rollback)  // Review 5 Medium 6: the write failed, put the player back
            // Polish pass (J1-8): house-style copy; the system error goes to the log only.
            ShelfLog.error(.sync, "Failed to update progress: \(error.localizedDescription)")
            let kind = Self.loadFailureKind(reachability: ReachabilityStore.shared.status, error: error)
            errorMessage = kind == .other
                ? String(localized: "Couldn\u{2019}t update your progress. Try again in a moment.", comment: "Error alert text when marking progress on the server failed")
                : Self.loadFailureMessage(kind)
            return false
        }
    }

    /// Reverts one book's progress to a specific point — used by `PlaybackHistoryStore`'s
    /// undo. Deliberately doesn't record its own history entry (undoing an undo isn't
    /// a supported flow here) and doesn't require the caller to have a full `LibraryItem`,
    /// since a book that's since left the loaded `items` page can still be undone.
    ///
    /// Library browse plan §6.6 (2026-10-05): `reload: false` skips the per-call `/api/me`
    /// read so a bulk undo can restore many books and read progress once at the end.
    @discardableResult
    func restoreProgress(itemId: String, currentTime: Double, isFinished: Bool, duration: Double, reload: Bool = true) async -> Bool {
        let progress = duration > 0 ? min(currentTime / duration, 1.0) : 0
        let sync = Self.loadedPlayerSync(loadedItemId: AudioPlayerService.shared.currentItemId, itemId: itemId, isFinished: isFinished, currentTime: currentTime, duration: duration)  // Review 5 Medium 6
        let rollback = movePlayerBeforeWrite(sync)
        let scope = PendingBookmarkQueue.currentScope()
        do {
            try await AudiobookshelfAPI.shared.updateProgress(
                libraryItemId: itemId, progress: progress, currentTime: currentTime,
                duration: duration, isFinished: isFinished,
                expectedScope: scope  // Review 5 Low (expectedScope)
            )
            if sync == .markFinished { finishLoadedPlayer() }
            else if !isFinished, itemId == AudioPlayerService.shared.currentItemId { discardQueuedFinish(itemId: itemId) }
            if reload { await loadUserProgress() }
            return true
        } catch {
            rollbackPlayer(rollback)
            // Critique 2026-10-06 (harden): every caller now reports a failed undo itself
            // (Recent Changes' Retry alert, the Undo toasts), so this no longer raises the
            // app-wide "Something went wrong" alert, whose Retry reloaded the library
            // instead of retrying the undo.
            ShelfLog.error(.sync, "Undo progress failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Bulk Mark Finished (Library browse plan §3.2, §6.6, 2026-10-05)

    /// Library browse plan §11 (2026-10-05): Mark Finished is disabled offline or while the
    /// server is unreachable ("Needs your server"), deliberately not queued through
    /// `PendingProgressQueue`, which holds listening positions.
    var canMarkFinished: Bool { ReachabilityStore.shared.status == .ok }

    /// How many of `items` have a position that Mark Finished would replace (in progress,
    /// not finished), for the confirmation message (plan §3.2 "Mark Finished: confirm").
    func inProgressCount(of items: [LibraryItem]) -> Int {
        items.filter { progressSnapshot(for: $0).wasInProgress }.count
    }

    /// Library browse plan §6.6 (2026-10-05): marks many books finished with one batch
    /// request (chunks of 50) plus one `/api/me` read, instead of a PATCH and a read per book.
    ///
    /// 1. Snapshots each book's prior progress (the same source the single path uses: the
    ///    server progress map, falling back to what the item carried) for the Undo toast.
    /// 2. Sends `batchUpdateProgress`; on `APIError.notFound` (a server without the batch
    ///    endpoint) falls back to sequential per-item PATCH without per-item reads.
    /// 3. Reads progress once and diffs (`failedIds`): the batch endpoint only logs per-item
    ///    failures server-side, so a requested id not now finished counts as failed.
    /// 4. Records a `PlaybackHistoryStore` entry per success, as `markFinished(item:)` does,
    ///    so each book stays individually undoable from Recent Changes.
    ///
    /// Never sends an empty batch. Offline it sends nothing and reports every id as failed.
    func markFinished(items requested: [LibraryItem]) async -> BulkFinishResult {
        var seen = Set<String>()
        let books = requested.filter { seen.insert($0.id).inserted }
        let ids = books.map(\.id)
        guard !books.isEmpty else { return BulkFinishResult(succeeded: [], failed: [], snapshots: [], verified: true) }
        guard canMarkFinished else { return BulkFinishResult(succeeded: [], failed: ids, snapshots: [], verified: true) }

        let snapshots = books.map { progressSnapshot(for: $0) }
        let payloads = books.map { Self.finishPayload(itemId: $0.id, duration: $0.duration) }
        var transportFailed = Set<String>()
        var requestFailed = false
        let scope = PendingBookmarkQueue.currentScope()
        do {
            try await AudiobookshelfAPI.shared.batchUpdateProgress(payloads)
        } catch APIError.notFound {
            for book in books {
                do {
                    try await AudiobookshelfAPI.shared.updateProgress(
                        libraryItemId: book.id, progress: 1.0, currentTime: book.duration,
                        duration: book.duration, isFinished: true,
                        expectedScope: scope  // Review 5 Low (expectedScope)
                    )
                } catch {
                    transportFailed.insert(book.id)
                }
            }
        } catch {
            // An earlier chunk may still have landed; the diff below decides when it can.
            requestFailed = true
            ShelfLog.error(.sync, "Bulk mark finished failed: \(error.localizedDescription)")
        }

        // Review 5 Medium 6: the loaded book, if it was marked, closes in the player too.
        if let loaded = AudioPlayerService.shared.currentItemId, ids.contains(loaded), !requestFailed, !transportFailed.contains(loaded) {
            finishLoadedPlayer()
        }
        await loadUserProgress()
        let verified = lastUserProgressLoadSucceeded
        let failed: [String]
        if verified {
            failed = Self.failedIds(requested: ids, after: finishedMap(for: ids))
        } else {
            // No fresh read to diff against: trust what the transport said.
            failed = requestFailed ? ids : ids.filter { transportFailed.contains($0) }
        }

        let failedSet = Set(failed)
        let succeeded = snapshots.filter { !failedSet.contains($0.itemId) }
        for snapshot in succeeded {
            PlaybackHistoryStore.shared.record(
                itemId: snapshot.itemId, title: snapshot.title, action: .markedFinished,
                previousCurrentTime: snapshot.currentTime,
                previousIsFinished: snapshot.isFinished,
                previousDuration: snapshot.duration
            )
        }
        // As the single path does: a book marked finished leaves the resume-on-launch snapshot.
        if let resumeId = SharedPlayback.read()?.itemId, succeeded.contains(where: { $0.itemId == resumeId }) {
            SharedPlayback.write(nil)
        }
        return BulkFinishResult(
            succeeded: succeeded.map(\.itemId), failed: failed,
            snapshots: succeeded, verified: verified
        )
    }

    /// Library browse plan §3.2 "Undo" (2026-10-05): puts every book in `snapshots` back to
    /// its prior progress (finished flag, position, fraction) through the same batch endpoint,
    /// falling back per item on an older server. `reload: false` skips the closing
    /// `/api/me` read for a caller that reads progress itself. Returns the ids that could
    /// not be restored (empty on success; unverified ids aren't reported when `reload` is
    /// false or the read fails).
    @discardableResult
    func restoreProgress(_ requestedSnapshots: [LibraryProgressSnapshot], reload: Bool = true) async -> [String] {
        guard !requestedSnapshots.isEmpty else { return [] }
        var failed: [String] = []
        var finishLoadedAfter = false
        var rollback: (prior: Double, movedTo: Double)?
        let loadedId = AudioPlayerService.shared.currentItemId
        // Review 6 Medium 4: the loaded book keeps the player's position, not a finished book's end.
        let snapshots = Self.snapshotsForLoadedPlayer(requestedSnapshots, loadedItemId: loadedId, playerTime: AudioPlayerService.shared.currentTime)
        // Review 5 Medium 6: move the loaded book's player first so its next sync keeps the restored position.
        if let loaded = loadedId, let snap = snapshots.first(where: { $0.itemId == loaded }) {
            let sync = Self.loadedPlayerSync(loadedItemId: loaded, itemId: loaded, isFinished: snap.isFinished, currentTime: snap.currentTime, duration: snap.duration)
            rollback = movePlayerBeforeWrite(sync)
            finishLoadedAfter = sync == .markFinished
        }
        do {
            try await AudiobookshelfAPI.shared.batchUpdateProgress(Self.restorePayloads(snapshots))
            if finishLoadedAfter { finishLoadedPlayer() }
            else if let loaded = loadedId, snapshots.contains(where: { $0.itemId == loaded && !$0.isFinished }) { discardQueuedFinish(itemId: loaded) }
        } catch APIError.notFound {
            for snapshot in snapshots {
                let ok = await restoreProgress(
                    itemId: snapshot.itemId, currentTime: snapshot.currentTime,
                    isFinished: snapshot.isFinished, duration: snapshot.duration, reload: false
                )
                if !ok { failed.append(snapshot.itemId) }
            }
            // Review 6 Medium 3: the loaded book's per-item write failed; put the player back.
            if let loadedId, failed.contains(loadedId) { rollbackPlayer(rollback) }
        } catch {
            // Critique 2026-10-06 (harden): reported by the caller (see the single overload).
            ShelfLog.error(.sync, "Bulk undo failed: \(error.localizedDescription)")
            failed = snapshots.map(\.itemId)
            rollbackPlayer(rollback)  // Review 6 Medium 3
        }
        guard reload else { return failed }
        await loadUserProgress()
        guard lastUserProgressLoadSucceeded else { return failed }
        let diffed = Self.unrestoredIds(snapshots, after: finishedMap(for: snapshots.map(\.itemId)))
        let all = Set(failed).union(diffed)
        return snapshots.map(\.itemId).filter { all.contains($0) }
    }

    /// Prior progress for one book, from the same source `updateProgress` snapshots.
    private func progressSnapshot(for item: LibraryItem) -> LibraryProgressSnapshot {
        Self.progressSnapshot(
            itemId: item.id, title: item.title,
            prior: progressFor(itemId: item.id) ?? item.mediaProgress, duration: item.duration
        )
    }

    private func finishedMap(for ids: [String]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for id in ids { map[id] = progressFor(itemId: id)?.isFinished == true }
        return map
    }

    /// Library browse plan §6.6 step 4 (2026-10-05): every requested id that the refreshed
    /// progress doesn't show as finished, in request order, once each. A missing key counts
    /// as not finished. Pinned by `LibraryBulkFinishTests`.
    nonisolated static func failedIds(requested: [String], after: [String: Bool]) -> [String] {
        var seen = Set<String>()
        return requested.filter { after[$0] != true && seen.insert($0).inserted }
    }

    /// The restore counterpart of `failedIds`: ids whose refreshed finished flag doesn't match
    /// the snapshot it was restored to (a missing key counts as not finished).
    nonisolated static func unrestoredIds(_ snapshots: [LibraryProgressSnapshot], after: [String: Bool]) -> [String] {
        var seen = Set<String>()
        return snapshots.filter { (after[$0.itemId] ?? false) != $0.isFinished && seen.insert($0.itemId).inserted }
            .map(\.itemId)
    }

    /// One book's prior progress, as the single-book path reads it (`previous?.currentTime
    /// ?? 0`, `previous?.isFinished ?? false`). `progress` falls back to
    /// `currentTime / duration` when the record has no fraction.
    nonisolated static func progressSnapshot(
        itemId: String, title: String, prior: MediaProgress?, duration: Double
    ) -> LibraryProgressSnapshot {
        let currentTime = max(0, prior?.currentTime ?? 0)
        let fraction = prior?.progress ?? (duration > 0 ? currentTime / duration : 0)
        return LibraryProgressSnapshot(
            itemId: itemId, title: title, currentTime: currentTime,
            progress: min(max(fraction, 0), 1), isFinished: prior?.isFinished ?? false,
            duration: duration
        )
    }

    /// The batch entry that marks one book finished: the same values `markFinished(item:)`
    /// sends (`progress` 1, `currentTime` = duration).
    nonisolated static func finishPayload(itemId: String, duration: Double) -> AudiobookshelfAPI.BatchProgressPayload {
        AudiobookshelfAPI.BatchProgressPayload(
            libraryItemId: itemId, isFinished: true, currentTime: duration, progress: 1.0, duration: duration
        )
    }

    /// Snapshot → batch entries for Undo (plan §3.2): the prior finished flag, position and
    /// fraction, one entry per book, in order.
    nonisolated static func restorePayloads(_ snapshots: [LibraryProgressSnapshot]) -> [AudiobookshelfAPI.BatchProgressPayload] {
        snapshots.map {
            AudiobookshelfAPI.BatchProgressPayload(
                libraryItemId: $0.itemId, isFinished: $0.isFinished,
                currentTime: $0.currentTime, progress: $0.progress, duration: $0.duration
            )
        }
    }

    // MARK: - Select All (Library browse plan §11 Q3, 2026-10-05)

    /// Select All is offered only for a result set the app holds in full, of at most this many.
    nonisolated static let selectAllLimit = 200

    /// Library browse plan §11 Q3 (C) (2026-10-05): Select All only when the whole result
    /// set is local and holds 1...200 books, so it never selects books the app hasn't seen.
    nonisolated static func selectAllAvailable(isLocal: Bool, count: Int) -> Bool {
        isLocal && count > 0 && count <= selectAllLimit
    }

    /// Whether the view should offer Select All now. A server-paged query counts as local
    /// once every one of its pages is loaded (a small server result, plan §9 Q3 C).
    func canSelectAll(downloads: [LibraryItem]) -> Bool {
        let w = displayWindow(downloads: downloads)
        let fullyLoaded = (0..<w.pageCount).allSatisfy { w.isLoaded(page: $0) } && w.stale.isEmpty
        return Self.selectAllAvailable(isLocal: !isWindowed || fullyLoaded, count: w.total)
    }

    // MARK: - Item Detail

    func getItemDetail(itemId: String) async -> LibraryItem? {
        // Non-critical enrichment: callers fall back to the item they already have.
        // Stay silent on failure so offline (downloaded) books don't pop an error.
        try? await AudiobookshelfAPI.shared.getItem(itemId: itemId)
    }
}

// MARK: - Bulk finish values (Library browse plan §3.2, §6.6, 2026-10-05)

/// One book's progress as it was before a bulk Mark Finished, which the Undo toast restores.
/// Library browse plan §3.2 (2026-10-05).
struct LibraryProgressSnapshot: Equatable, Sendable {
    let itemId: String
    let title: String
    let currentTime: Double
    /// 0...1.
    let progress: Double
    let isFinished: Bool
    let duration: Double

    /// A position Mark Finished would replace: started and not finished.
    var wasInProgress: Bool { !isFinished && (currentTime > 0 || progress > 0) }
}

/// What `LibraryViewModel.markFinished(items:)` achieved. Library browse plan §6.6 (2026-10-05).
struct BulkFinishResult: Equatable, Sendable {
    /// Ids now finished on the server, in request order.
    let succeeded: [String]
    /// Ids that couldn't be updated ("2 books couldn't be updated. Try again."); they stay selected.
    let failed: [String]
    /// Prior progress of the succeeded books, for `restoreProgress(_:reload:)` (Undo).
    let snapshots: [LibraryProgressSnapshot]
    /// False when the closing `/api/me` read failed, so `failed` reflects only what the
    /// transport reported rather than a diff.
    let verified: Bool

    var allSucceeded: Bool { failed.isEmpty }
}

// MARK: - Client-side library queries (pure)

/// Critique 2026-10-05 (Library): pure decision functions behind the Library's honest
/// filter state, pinned by `LibraryStateTests`. Everything here takes plain values (and a
/// progress lookup closure) so it can be tested without a server, a `DownloadManager` or a
/// live view model.
enum LibraryItemsSource: Equatable {
    case server, offlineFallback, failed
}

enum LibraryLocalQuery {
    /// "Recently Played" asks the server for at most this many in-progress books.
    static let recentLimit = 100

    /// Critique 2026-10-05 (Library, 2nd): what `items` is after a failed load. Books already
    /// on screen are kept (source unchanged: the refresh failure is a toast). With nothing on
    /// screen, downloaded books become an explicitly labelled offline fallback; with no
    /// downloads either, the load has plainly failed (never "No books here").
    static func sourceAfterFailure(
        current: LibraryItemsSource, hasItems: Bool, hasDownloads: Bool
    ) -> LibraryItemsSource {
        if hasItems { return current }
        return hasDownloads ? .offlineFallback : .failed
    }

    /// The filters that actually shape the visible result, for the chip row. A chip must
    /// not claim a filter that is being overridden: a smart filter outranks the progress
    /// filter and Downloaded, and "Recently Played" (the in-progress list) ignores the
    /// progress filter on both the server and the local path.
    struct EffectiveFilters: Equatable {
        var smartFilter: SmartFilter?
        var progress: LibraryProgressFilter?   // nil when .all or overridden
        var downloadedOnly: Bool
        var isEmpty: Bool { smartFilter == nil && progress == nil && !downloadedOnly }
    }

    static func effectiveFilters(
        smartFilter: SmartFilter?, progressFilter: LibraryProgressFilter,
        downloadedOnly: Bool, sort: LibrarySort
    ) -> EffectiveFilters {
        if let smartFilter {
            return EffectiveFilters(smartFilter: smartFilter, progress: nil, downloadedOnly: false)
        }
        let progress: LibraryProgressFilter? = (progressFilter == .all || sort == .recent) ? nil : progressFilter
        return EffectiveFilters(smartFilter: nil, progress: progress, downloadedOnly: downloadedOnly)
    }

    /// Sort key for titles: drops a leading English article ("The ", "A ", "An "), like
    /// Audiobookshelf's ignore-prefix sorting, so "The Hobbit" files under H. A title that
    /// is only an article keeps it.
    static func titleSortKey(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        for article in ["the ", "an ", "a "] where trimmed.lowercased().hasPrefix(article) {
            let rest = trimmed.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }

    /// Where a book stands, for the progress filter. Mirrors the server's three buckets.
    static func progressBucket(_ progress: MediaProgress?) -> LibraryProgressFilter {
        guard let progress else { return .notStarted }
        if progress.isFinished == true { return .finished }
        if (progress.progress ?? 0) > 0 || (progress.currentTime ?? 0) > 0 { return .inProgress }
        return .notStarted
    }

    /// Applies the progress filter and sort to a client-held list (the downloaded books).
    /// `.recent` is the "Recently Played" sort: it keeps only in-progress books (matching
    /// what the server's items-in-progress list returns) ordered by last update, newest
    /// first, and ignores direction — exactly like the server-side path it mirrors.
    static func apply(
        _ items: [LibraryItem],
        filter: LibraryProgressFilter,
        sort: LibrarySort,
        descending: Bool,
        progress: (LibraryItem) -> MediaProgress?
    ) -> [LibraryItem] {
        var result = items
        // "Recently Played" is the in-progress list: like the server path it ignores the
        // progress filter (Critique 2026-10-05, Library 2nd).
        if filter != .all && sort != .recent {
            result = result.filter { progressBucket(progress($0)) == filter }
        }
        func byTitle(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
            let c = titleSortKey(a.title).localizedStandardCompare(titleSortKey(b.title))
            if c == .orderedSame { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return c == .orderedAscending
        }
        switch sort {
        case .recent:
            result = result.filter { progressBucket(progress($0)) == .inProgress }
            return result.sorted { a, b in
                let la = progress(a)?.lastUpdate ?? 0, lb = progress(b)?.lastUpdate ?? 0
                return la != lb ? la > lb : byTitle(a, b)
            }
        case .title:
            return result.sorted { descending ? byTitle($1, $0) : byTitle($0, $1) }
        case .author:
            return result.sorted { a, b in
                let c = a.authorName.localizedStandardCompare(b.authorName)
                if c == .orderedSame { return byTitle(a, b) }
                return descending ? c == .orderedDescending : c == .orderedAscending
            }
        case .addedAt:
            return result.sorted { a, b in
                let x = a.addedAt ?? 0, y = b.addedAt ?? 0
                if x == y { return byTitle(a, b) }
                return descending ? x > y : x < y
            }
        case .duration:
            return result.sorted { a, b in
                if a.duration == b.duration { return byTitle(a, b) }
                return descending ? a.duration > b.duration : a.duration < b.duration
            }
        }
    }

    /// Local search over title, author, narrator and series. Every whitespace-separated
    /// token must appear somewhere (case- and diacritic-insensitive), so "sanderson way"
    /// finds "The Way of Kings" by Brandon Sanderson. Blank queries match nothing.
    static func search(_ items: [LibraryItem], query: String) -> [LibraryItem] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return items.filter { item in
            let haystack = [item.title, item.authorName, item.narratorName ?? "", item.seriesName ?? ""]
                .joined(separator: "\n")
            return tokens.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Human description of the active sort, e.g. "Title A–Z" or "Date Added, newest first".
    static func sortDescription(_ sort: LibrarySort, descending: Bool) -> String {
        switch sort {
        case .recent: return String(localized: "Recently Played", comment: "Sort description in the Library count line")
        case .title: return descending
            ? String(localized: "Title Z–A", comment: "Sort description in the Library count line")
            : String(localized: "Title A–Z", comment: "Sort description in the Library count line")
        case .author: return descending
            ? String(localized: "Author Z–A", comment: "Sort description in the Library count line")
            : String(localized: "Author A–Z", comment: "Sort description in the Library count line")
        case .addedAt: return descending
            ? String(localized: "Date Added, newest first", comment: "Sort description in the Library count line")
            : String(localized: "Date Added, oldest first", comment: "Sort description in the Library count line")
        case .duration: return descending
            ? String(localized: "Duration, longest first", comment: "Sort description in the Library count line")
            : String(localized: "Duration, shortest first", comment: "Sort description in the Library count line")
        }
    }

    /// The quiet wayfinding line under the scope bar, e.g. "1,240 books · Title A–Z".
    /// `count` should be the server total, not the number of pages loaded so far.
    static func countAndSortLine(
        count: Int, sort: LibrarySort, descending: Bool,
        downloadedOnly: Bool, smartFilter: SmartFilter?, offlineFallback: Bool = false,
        locale: Locale = .current
    ) -> String {
        let number = count.formatted(.number.locale(locale))
        let one = count == 1
        if let smartFilter {
            return one
                ? String(localized: "\(number) book · \(smartFilter.label)", comment: "Library count line with a Smart Filter, one book; first %@ is the formatted count, second %@ is the filter name")
                : String(localized: "\(number) books · \(smartFilter.label)", comment: "Library count line with a Smart Filter, several books; first %@ is the formatted count, second %@ is the filter name")
        }
        // Critique 2026-10-05 (Library, 2nd): the server's in-progress list is capped, so a
        // full page says what it is rather than passing 100 off as the whole library.
        if sort == .recent, !downloadedOnly, !offlineFallback, count >= recentLimit {
            return String(localized: "\(number) most recent in progress", comment: "Library count line for Recently Played when the server's capped list is full; %@ is the formatted count")
        }
        let lead: String
        if offlineFallback {
            lead = one
                ? String(localized: "\(number) downloaded book (offline)", comment: "Library count line lead, offline fallback, one book; %@ is the formatted count")
                : String(localized: "\(number) downloaded books (offline)", comment: "Library count line lead, offline fallback, several books; %@ is the formatted count")
        } else if downloadedOnly {
            lead = one
                ? String(localized: "\(number) downloaded book", comment: "Library count line lead, downloaded only, one book; %@ is the formatted count")
                : String(localized: "\(number) downloaded books", comment: "Library count line lead, downloaded only, several books; %@ is the formatted count")
        } else {
            lead = one
                ? String(localized: "\(number) book", comment: "Library count line lead, one book; %@ is the formatted count")
                : String(localized: "\(number) books", comment: "Library count line lead, several books; %@ is the formatted count")
        }
        let sortText = sortDescription(sort, descending: descending)
        return sort == .recent
            ? String(localized: "\(lead) · \(sortText), in progress only", comment: "Library count line for Recently Played; first %@ is the count phrase, second %@ is the sort description")
            : String(localized: "\(lead) · \(sortText)", comment: "Library count line; first %@ is the count phrase, second %@ is the sort description")
    }

    /// Label for a sort option in the filter sheet. "Recently Played" is not a sort of the
    /// whole library — it swaps in the in-progress list — so it says so.
    static func sortOptionLabel(_ sort: LibrarySort) -> String {
        sort == .recent ? String(localized: "Recently Played (in progress only)", comment: "Sort option in the Library filter sheet; clarifies it only lists books in progress") : sort.label
    }
}


// MARK: - Home shelves disk cache

/// Polish pass (J2-2): the last personalised-shelves response, kept in `Caches/` so a returning
/// user sees Home's shelves before the network answers. Rules (user-approved with conditions):
/// lives in the Caches directory (never Documents or the App Group); versioned (a file whose
/// `version` isn't `currentVersion` is ignored); a file that fails to decode is deleted; keyed by
/// account scope (the file name is a hash of the scope, and the scope is stored and re-checked
/// inside), so one account can never read another's; and removed on sign-out and on an account
/// or server switch. Fresh network data always replaces it.
enum HomeShelvesCache {
    static let currentVersion = 1

    struct Payload: Codable {
        var version: Int
        var scope: String
        var libraryId: String
        var savedAt: Date
        var shelves: [PersonalizedView]
    }

    /// Only the version, decoded on its own so a future payload shape can't look "corrupt".
    private struct Header: Decodable { var version: Int }

    enum DecodeOutcome {
        case shelves([PersonalizedView])
        /// Readable but not for this version, scope or library: ignore, leave the file.
        case ignore
        /// Not readable at all: the caller deletes the file.
        case corrupt
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("home-shelves", isDirectory: true)
    }

    static func fileName(forScope scope: String) -> String {
        let digest = SHA256.hash(data: Data(scope.utf8))
        return "shelves-" + digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static func fileURL(forScope scope: String, in directory: URL = HomeShelvesCache.directory) -> URL {
        directory.appendingPathComponent(fileName(forScope: scope))
    }

    /// Never cache without a real signed-in scope.
    static func isCacheable(scope: String) -> Bool {
        !scope.isEmpty && scope != "unscoped"
    }

    static func encode(_ shelves: [PersonalizedView], scope: String, libraryId: String, savedAt: Date = Date()) -> Data? {
        try? JSONEncoder().encode(Payload(version: currentVersion, scope: scope, libraryId: libraryId,
                                          savedAt: savedAt, shelves: shelves))
    }

    /// Pure decision: what a file's bytes mean for this scope and library.
    static func decode(_ data: Data, scope: String, libraryId: String) -> DecodeOutcome {
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return .corrupt }
        guard header.version == currentVersion else { return .ignore }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return .corrupt }
        guard payload.scope == scope, payload.libraryId == libraryId else { return .ignore }
        return .shelves(payload.shelves)
    }

    static func load(scope: String, libraryId: String, in directory: URL = HomeShelvesCache.directory) -> [PersonalizedView]? {
        guard isCacheable(scope: scope) else { return nil }
        let url = fileURL(forScope: scope, in: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        switch decode(data, scope: scope, libraryId: libraryId) {
        case .shelves(let shelves): return shelves
        case .ignore: return nil
        case .corrupt:
            try? FileManager.default.removeItem(at: url)   // discard on decode failure
            ShelfLog.info(.storage, "Discarded an unreadable Home shelves cache file")
            return nil
        }
    }

    /// Encodes and writes atomically (a few KB to ~100 KB; written on the main actor on purpose so a
    /// late write can't land after a sign-out's `removeAll`). Best effort: a failed write just means no cache.
    static func save(_ shelves: [PersonalizedView], scope: String, libraryId: String,
                     in directory: URL = HomeShelvesCache.directory) {
        guard isCacheable(scope: scope), let data = encode(shelves, scope: scope, libraryId: libraryId) else { return }
        let url = fileURL(forScope: scope, in: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every scope's file: sign-out and account/server switches.
    static func removeAll(in directory: URL = HomeShelvesCache.directory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
