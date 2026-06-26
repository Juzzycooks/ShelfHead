import Foundation

@Observable
final class LibraryViewModel {
    var libraries: [Library] = []
    var selectedLibrary: Library?
    var items: [LibraryItem] = []
    var personalizedShelves: [PersonalizedView] = []
    var searchResults: [LibraryItem] = []

    var isLoadingLibraries = false
    var isLoadingItems = false
    var isLoadingPersonalized = false
    var isSearching = false
    var errorMessage: String?

    var searchQuery = ""
    var currentPage = 0
    var totalItems = 0
    private let pageSize = 50

    // Browsing: sort / filter / series / authors
    var sortOption: LibrarySort = .title
    var sortDescending = false
    var progressFilter: LibraryProgressFilter = .all
    var seriesList: [Series] = []
    var isLoadingSeries = false
    var filterData: LibraryFilterData?

    var hasMoreItems: Bool {
        items.count < totalItems
    }

    // MARK: - Libraries

    func loadLibraries() async {
        isLoadingLibraries = true
        errorMessage = nil

        do {
            libraries = try await AudiobookshelfAPI.shared.getLibraries()
            await loadUserProgress()
            // Auto-select first library if none selected
            if selectedLibrary == nil, let first = libraries.first {
                selectedLibrary = first
                await loadItems()
                await loadPersonalizedView()
            }
        } catch {
            errorMessage = "Failed to load libraries: \(error.localizedDescription)"
        }

        isLoadingLibraries = false
    }

    func selectLibrary(_ library: Library) async {
        selectedLibrary = library
        items = []
        personalizedShelves = []
        currentPage = 0
        await loadItems()
        await loadPersonalizedView()
    }

    // MARK: - Library Items

    func loadItems() async {
        guard let library = selectedLibrary else { return }
        isLoadingItems = true
        errorMessage = nil

        do {
            let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: library.id,
                limit: pageSize,
                page: currentPage,
                filter: progressFilter.filterValue,
                sort: sortOption.rawValue,
                desc: sortDescending
            )
            if currentPage == 0 {
                items = response.results
            } else {
                items.append(contentsOf: response.results)
            }
            totalItems = response.total
        } catch {
            // Offline (or server unreachable): fall back to downloaded books so the
            // library still shows what's available, with cached progress.
            let offline = DownloadManager.shared.downloadedLibraryItems()
            if !offline.isEmpty {
                items = offline
                totalItems = offline.count
                mergeOfflineProgress(offline)
            } else {
                errorMessage = "Failed to load books: \(error.localizedDescription)"
            }
        }

        isLoadingItems = false
    }

    /// Seed the progress map from downloaded manifests so cached progress shows
    /// when we couldn't reach the server.
    private func mergeOfflineProgress(_ offlineItems: [LibraryItem]) {
        for item in offlineItems where userProgressMap[item.id] == nil {
            if let mp = item.mediaProgress { userProgressMap[item.id] = mp }
        }
    }

    func loadMoreIfNeeded(currentItem: LibraryItem) async {
        guard let lastItem = items.last,
              lastItem.id == currentItem.id,
              hasMoreItems else { return }

        currentPage += 1
        await loadItems()
    }

    func refresh() async {
        currentPage = 0
        await loadItems()
        await loadPersonalizedView()
    }

    /// Re-run the items query after a sort/filter change.
    func applySortFilter() async {
        currentPage = 0
        items = []
        await loadItems()
    }

    // MARK: - Series & Authors

    func loadSeries() async {
        guard let library = selectedLibrary else { return }
        isLoadingSeries = true
        do {
            let response = try await AudiobookshelfAPI.shared.getSeries(libraryId: library.id)
            seriesList = response.results
        } catch {
            seriesList = []
        }
        isLoadingSeries = false
    }

    func loadFilterData() async {
        guard let library = selectedLibrary else { return }
        filterData = try? await AudiobookshelfAPI.shared.getFilterData(libraryId: library.id)
    }

    // MARK: - Collections & Playlists

    var collections: [BookCollection] = []
    var playlists: [Playlist] = []
    var isLoadingCollections = false
    var isLoadingPlaylists = false

    func loadCollections() async {
        guard let library = selectedLibrary else { return }
        isLoadingCollections = true
        collections = (try? await AudiobookshelfAPI.shared.getCollections(libraryId: library.id)) ?? []
        isLoadingCollections = false
    }

    func loadPlaylists() async {
        guard let library = selectedLibrary else { return }
        isLoadingPlaylists = true
        playlists = (try? await AudiobookshelfAPI.shared.getPlaylists(libraryId: library.id)) ?? []
        isLoadingPlaylists = false
    }

    /// Loads the books for a given filter (used by the Authors browse screen).
    func items(filteredBy filter: String) async -> [LibraryItem] {
        guard let library = selectedLibrary else { return [] }
        do {
            let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: library.id,
                limit: 200,
                page: 0,
                filter: filter,
                sort: LibrarySort.title.rawValue
            )
            return response.results
        } catch {
            return []
        }
    }

    // MARK: - Personalized View

    func loadPersonalizedView() async {
        guard let library = selectedLibrary else { return }
        isLoadingPersonalized = true

        do {
            personalizedShelves = try await AudiobookshelfAPI.shared.getPersonalizedView(libraryId: library.id)
            // Fetch user progress and merge into shelf items
            await loadUserProgress()

            // Auto-download Continue Listening items if enabled.
            if let continueShelf = personalizedShelves.first(where: { $0.labelStringKey == "LabelContinueListening" }),
               let entities = continueShelf.entities {
                DownloadManager.shared.autoDownloadIfEnabled(entities)
            }
        } catch {
            personalizedShelves = []
        }

        isLoadingPersonalized = false
    }

    // MARK: - User Progress

    private var userProgressMap: [String: MediaProgress] = [:]

    func loadUserProgress() async {
        do {
            let user = try await AudiobookshelfAPI.shared.getCurrentUser()
            if let progressList = user.mediaProgress {
                userProgressMap = Dictionary(
                    progressList.map { ($0.libraryItemId, $0) },
                    uniquingKeysWith: { a, b in
                        // Keep the most recently updated one
                        (a.lastUpdate ?? 0) > (b.lastUpdate ?? 0) ? a : b
                    }
                )
                // Reconcile any offline progress with the server (last-write-wins).
                await DownloadManager.shared.reconcile(serverProgress: userProgressMap)
            }
        } catch {
            // Non-critical
        }
    }

    func progressFor(itemId: String) -> MediaProgress? {
        userProgressMap[itemId]
    }

    var finishedBooksCount: Int {
        userProgressMap.values.filter { $0.isFinished == true }.count
    }

    // MARK: - Search

    func search() async {
        guard let library = selectedLibrary,
              !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }

        isSearching = true

        do {
            searchResults = try await AudiobookshelfAPI.shared.search(
                libraryId: library.id,
                query: searchQuery
            )
        } catch {
            searchResults = []
        }

        isSearching = false
    }

    // MARK: - Progress Actions

    @discardableResult
    func markFinished(item: LibraryItem) async -> Bool {
        await updateProgress(item: item, progress: 1.0, currentTime: item.duration, isFinished: true)
    }

    @discardableResult
    func markUnfinished(item: LibraryItem) async -> Bool {
        await updateProgress(item: item, progress: item.progressPercent, currentTime: item.currentTime, isFinished: false)
    }

    @discardableResult
    func resetProgress(item: LibraryItem) async -> Bool {
        await updateProgress(item: item, progress: 0, currentTime: 0, isFinished: false)
    }

    private func updateProgress(item: LibraryItem, progress: Double, currentTime: Double, isFinished: Bool) async -> Bool {
        do {
            try await AudiobookshelfAPI.shared.updateProgress(
                libraryItemId: item.id,
                progress: progress,
                currentTime: currentTime,
                duration: item.duration,
                isFinished: isFinished
            )
            await loadUserProgress()
            // If this book was the one queued for "resume on launch", drop it from the
            // restore snapshot once it's marked finished or reset.
            if (isFinished || progress == 0), SharedPlayback.read()?.itemId == item.id {
                SharedPlayback.write(nil)
            }
            return true
        } catch {
            errorMessage = "Failed to update progress: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Item Detail

    func getItemDetail(itemId: String) async -> LibraryItem? {
        // Non-critical enrichment: callers fall back to the item they already have.
        // Stay silent on failure so offline (downloaded) books don't pop an error.
        try? await AudiobookshelfAPI.shared.getItem(itemId: itemId)
    }
}
