import Foundation
import Observation

/// Starred authors/narrators, used by the "New From Favourites" smart filter (see
/// `SmartFilter.favoriteNewArrivals`) to surface recently-added books by people whose
/// work you specifically want to keep up with. Deliberately global (not per-account/
/// per-library, unlike downloads or progress) — an author or narrator's name is a
/// preference about *you*, not about a particular server, and re-adding the same
/// account later shouldn't lose it. Names are matched case-insensitively so "Brandon
/// Sanderson" and a differently-cased duplicate from another server both count as the
/// same favourite.
// CRIT-3 step 2 (REVIEW_2026-08-12.md): de-facto main-actor state (read/written
// exclusively from SwiftUI views).
//
// Real build errors, two rounds of them (see `ThemeStore.swift` for the full,
// corrected account): the `nonisolated static let shared` / `nonisolated init()`
// pattern copied from `DownloadManager`/`AudioPlayerService` does not actually work
// for assigning an `@Observable` type's own properties from within that `init()` —
// `@Observable`'s macro expansion turns every `var` into a computed property backed by
// `ObservationRegistrar` calls, so assigning one is a main-actor-isolated accessor
// call, not a trivial stored-property write, regardless of whether the property has an
// in-line default. That's true independent of isolation-exemption rules for
// initializers, so no combination of removing defaults or adding more `nonisolated`
// annotations fixes it. Since every real caller of `.shared` here is already
// main-actor (SwiftUI views — this store isn't reached from `URLSessionDelegate`
// callbacks or background `NotificationCenter` observers the way `DownloadManager`/
// `AudioPlayerService` are), the actually-correct fix is simpler than the pattern this
// was modeled on: don't mark `shared`/`init()` `nonisolated` at all. With both left
// main-actor-isolated (the class's default), `init()`'s body runs in the same
// isolation domain as the property setters it calls — no cross-isolation exemption is
// needed in the first place.
@MainActor
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    private static let authorsKey = "shelfhead_favoriteAuthors"
    private static let narratorsKey = "shelfhead_favoriteNarrators"

    private(set) var favoriteAuthors: Set<String> = []
    private(set) var favoriteNarrators: Set<String> = []

    private init() {
        reload()
    }

    /// Re-reads both sets from `UserDefaults`. Called from `init` and after a settings
    /// import (`SettingsExport.apply` writes the raw keys behind this store's back).
    func reload() {
        favoriteAuthors = Set((UserDefaults.standard.stringArray(forKey: Self.authorsKey) ?? []).map { Self.normalized($0) })
        favoriteNarrators = Set((UserDefaults.standard.stringArray(forKey: Self.narratorsKey) ?? []).map { Self.normalized($0) })
    }

    /// Review 6 Low (favourites whitespace): stored names are lowercased and trimmed.
    nonisolated static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isFavoriteAuthor(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return favoriteAuthors.contains(Self.normalized(name))
    }

    func isFavoriteNarrator(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return favoriteNarrators.contains(Self.normalized(name))
    }

    func toggleFavoriteAuthor(_ name: String) {
        setFavoriteAuthor(name, isFavorite: !isFavoriteAuthor(name))
    }

    func toggleFavoriteNarrator(_ name: String) {
        setFavoriteNarrator(name, isFavorite: !isFavoriteNarrator(name))
    }

    func setFavoriteAuthor(_ name: String, isFavorite: Bool) {
        let key = Self.normalized(name)
        guard !key.isEmpty else { return }
        if isFavorite { favoriteAuthors.insert(key) } else { favoriteAuthors.remove(key) }
        UserDefaults.standard.set(Array(favoriteAuthors), forKey: Self.authorsKey)
    }

    func setFavoriteNarrator(_ name: String, isFavorite: Bool) {
        let key = Self.normalized(name)
        guard !key.isEmpty else { return }
        if isFavorite { favoriteNarrators.insert(key) } else { favoriteNarrators.remove(key) }
        UserDefaults.standard.set(Array(favoriteNarrators), forKey: Self.narratorsKey)
    }

    /// Splits `items` into starred and the rest, preserving input order in both. Starred
    /// items are NOT repeated in `rest` (library-browse plan §11 Q6). Names are passed to
    /// `isStarred` lowercased, matching how this store keeps its sets (see `reload()`), so
    /// the match is case-insensitive when `isStarred` is backed by a favourites set. An
    /// empty name is never starred. Pure, so it can run off the main actor.
    nonisolated static func starredFirst<T>(
        _ items: [T],
        name: (T) -> String,
        isStarred: (String) -> Bool
    ) -> (starred: [T], rest: [T]) {
        var starred: [T] = []
        var rest: [T] = []
        for item in items {
            let key = normalized(name(item))
            if !key.isEmpty, isStarred(key) { starred.append(item) } else { rest.append(item) }
        }
        return (starred, rest)
    }
}
