import Foundation

/// Batch 445: drives the "Ask" scope of Library search. Holds one snapshot of the whole library (fetched
/// once per library, the same paging `LibraryViewModel` uses for smart filters), reads the sentence with
/// `MoodQueryModel`, and ranks with `MoodFilter`. Everything after the snapshot runs on device.
@MainActor
@Observable
final class MoodSearchViewModel {
    enum Phase: Equatable {
        case idle
        case searching
        case done
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var matches: [MoodMatch] = []
    private(set) var understood: MoodQuery?
    /// The text the current results are for; the view compares it with the search field.
    private(set) var answeredText = ""

    private var snapshot: [LibraryItem] = []
    private var snapshotLibraryId: String?
    private var runGeneration = 0

    func reset() {
        runGeneration += 1
        phase = .idle
        matches = []
        understood = nil
        answeredText = ""
    }

    /// Forget the snapshot (library switch, account switch, refresh).
    func invalidateSnapshot() {
        snapshot = []
        snapshotLibraryId = nil
    }

    func ask(_ text: String, libraryId: String, progress: @escaping (LibraryItem) -> MediaProgress?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { reset(); return }
        runGeneration += 1
        let generation = runGeneration
        phase = .searching
        answeredText = text

        if snapshotLibraryId != libraryId || snapshot.isEmpty {
            do {
                let fetched = try await Self.fetchSnapshot(libraryId: libraryId)
                guard generation == runGeneration else { return }
                snapshot = fetched
                snapshotLibraryId = libraryId
            } catch {
                guard generation == runGeneration else { return }
                if !(error is CancellationError) {
                    ShelfLog.error(.network, "Mood search snapshot failed: \(error.localizedDescription)")
                }
                phase = .failed
                return
            }
        }

        let items = snapshot
        let genres = MoodFilter.genreList(items)
        let query = await MoodQueryModel.interpret(trimmed, knownGenres: genres)
        guard generation == runGeneration else { return }

        let favorites = FavoritesStore.shared
        let result = MoodFilter.rank(
            query: query, items: items, progress: progress,
            isStarredNarrator: { favorites.isFavoriteNarrator($0) },
            isStarredAuthor: { favorites.isFavoriteAuthor($0) })
        understood = query
        matches = result
        phase = .done
    }

    /// Pages through the whole library (capped at 5000 books), throwing on any failed page.
    private static func fetchSnapshot(libraryId: String) async throws -> [LibraryItem] {
        var all: [LibraryItem] = []
        var page = 0
        let limit = 200
        while all.count < 5000 {
            let response = try await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: libraryId, limit: limit, page: page, sort: LibrarySort.title.rawValue)
            guard !response.results.isEmpty else { break }
            all.append(contentsOf: response.results)
            page += 1
            if all.count >= response.total { break }
        }
        return all
    }
}
