import Foundation
import Observation

/// A rolling log of state-changing progress actions (mark finished, mark unfinished,
/// reset progress) so a mis-tap can be undone instead of requiring the user to manually
/// re-scrub back to where they were. Deliberately narrow in scope: this is not a full
/// "listening history" of every session (see `StatsView`/`ListeningStatistics` for
/// that) — it only tracks the handful of destructive, one-tap actions that are easy to
/// fire by accident from a swipe action or context menu.
///
/// Persisted (UserDefaults, JSON-encoded) so the log — and the ability to undo the most
/// recent action per book — survives a relaunch. Capped at `maxEntries` entries,
/// oldest dropped first.
// CRIT-3 step 2 (REVIEW_2026-08-12.md): de-facto main-actor state (read/written
// exclusively from SwiftUI views).
//
// Real build errors, corrected after two wrong rounds — see `FavoritesStore.swift`/
// `ThemeStore.swift` for the full account: `@Observable` transforms every `var`
// property into a main-actor-isolated computed accessor, so a `nonisolated init()`
// can never assign one, regardless of in-line defaults. Since every real caller of
// `.shared` here is already main-actor (SwiftUI views), the fix is to not mark
// `shared`/`init()` `nonisolated` at all.
@MainActor
@Observable
final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()

    enum HistoryAction: String, Codable {
        case markedFinished
        case markedUnfinished
        case resetProgress

        var label: String {
            switch self {
            case .markedFinished:   return String(localized: "Marked Finished", comment: "History row label")
            case .markedUnfinished: return String(localized: "Marked Unfinished", comment: "History row label")
            case .resetProgress:    return String(localized: "Progress Reset", comment: "History row label")
            }
        }

        var icon: String {
            switch self {
            case .markedFinished:   return "checkmark.circle.fill"
            case .markedUnfinished: return "circle"
            case .resetProgress:    return "arrow.counterclockwise.circle.fill"
            }
        }
    }

    struct HistoryEntry: Codable, Identifiable, Equatable {
        let id: UUID
        let itemId: String
        let title: String
        let action: HistoryAction
        let timestamp: Date
        /// The book's progress immediately *before* this action — what an undo restores.
        let previousCurrentTime: Double
        let previousIsFinished: Bool
        let previousDuration: Double
        /// Critique 2026-10-06 (harden): the saved account (`AccountStore.currentAccountId`)
        /// the change was made on. Item ids are per server, so an undo is only safe on that
        /// same account. Optional, and absent from entries recorded before it existed:
        /// those decode as nil, an unknown account (synthesized `Codable` uses
        /// `decodeIfPresent` for an optional).
        var accountId: String? = nil
        /// That server's host, for the "On <host>" heading. Optional for the same reason.
        var serverHost: String? = nil
    }

    /// Critique 2026-10-06 (harden): one group of Recent Changes.
    struct HistorySection: Identifiable, Equatable {
        enum Kind: Equatable {
            /// The account signed in now: these can be undone.
            case current
            /// Another saved server's changes, shown for reference.
            case otherServer(host: String)
            /// Recorded before entries carried an account.
            case unknownServer
        }
        /// "current", "unknown", or "account:<id>" — two accounts on one host are two groups.
        let id: String
        let kind: Kind
        let entries: [HistoryEntry]
    }

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []
    private let maxEntries = 50
    private static let storageKey = "shelfhead_playbackHistory"

    /// False until a load has actually established what's in storage. `persist()` refuses to
    /// write while it's false — see `loadIfNeeded()`.
    @ObservationIgnored
    private var hasLoadedFromDisk = false

    private init() {
        loadIfNeeded()
    }

    /// Reads the stored log at most once per successful attempt.
    ///
    /// This used to be `entries = Self.load()`, a static that `try?`-swallowed the decode and
    /// returned `[]` — so a corrupt blob read as "no history" and the next `record()`
    /// overwrote it. `PersistedStoreLoad` (bottom of `PendingBookmarkQueue.swift`) tells the
    /// three cases apart; the corrupt bytes are moved to a `<key>.corrupt` defaults key before
    /// anything starts empty, and a blob we couldn't establish at all leaves
    /// `hasLoadedFromDisk` false so `persist()` won't clobber it.
    private func loadIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        let outcome: PersistedStoreLoad.Outcome<[HistoryEntry]> = PersistedStoreLoad.load(
            defaults: .standard, key: Self.storageKey, label: "PlaybackHistoryStore"
        ) { try JSONDecoder().decode([HistoryEntry].self, from: $0) }

        switch outcome {
        case .loaded(let decoded):
            entries = decoded
            hasLoadedFromDisk = true
        case .empty:
            hasLoadedFromDisk = true
        case .unavailable:
            break
        }
    }

    /// Critique 2026-10-06 (harden): stamps the entry with the account and server it was
    /// made on, read here so the callers (`LibraryViewModel`, `SeriesBrowseView`) don't
    /// change. Recent Changes used to be one global log, so after a switch it offered an
    /// Undo for another server's books that could only fail.
    func record(itemId: String, title: String, action: HistoryAction,
                previousCurrentTime: Double, previousIsFinished: Bool, previousDuration: Double) {
        loadIfNeeded()
        let entry = HistoryEntry(
            id: UUID(), itemId: itemId, title: title, action: action, timestamp: Date(),
            previousCurrentTime: previousCurrentTime, previousIsFinished: previousIsFinished,
            previousDuration: previousDuration,
            accountId: AccountStore.currentAccountId,
            serverHost: URL(string: AuthStore.shared.serverURL)?.host
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        persist()
    }

    /// The most recent entry recorded for a given book on the account signed in now, if
    /// any — used to decide whether an older entry for that same book is still safe to
    /// undo (see `canUndo`). Scoped to the account (Critique 2026-10-06): another server
    /// can have an item with the same id.
    func mostRecentEntry(forItemId itemId: String) -> HistoryEntry? {
        let account = AccountStore.currentAccountId
        return entries.first { $0.itemId == itemId && $0.accountId == account }
    }

    /// An entry is only undoable while it's still the *latest* recorded action for that
    /// book — undoing an older entry after a newer one has already changed the book's
    /// progress again would silently discard that newer action, which is more confusing
    /// than just not offering the button. And only on the account it was made on
    /// (Critique 2026-10-06, `isUndoable`).
    func canUndo(_ entry: HistoryEntry) -> Bool {
        Self.isUndoable(entry, in: entries, currentAccountId: AccountStore.currentAccountId)
    }

    /// Pure half of `canUndo`, pinned by `PlaybackHistoryScopeTests`: the entry belongs to
    /// the account signed in now (an entry with no account, recorded before they carried
    /// one, never does — it could be any server's) and is that account's newest entry for
    /// the book.
    static func isUndoable(_ entry: HistoryEntry, in entries: [HistoryEntry], currentAccountId: String?) -> Bool {
        guard let currentAccountId, entry.accountId == currentAccountId else { return false }
        return entries.first { $0.itemId == entry.itemId && $0.accountId == currentAccountId }?.id == entry.id
    }

    /// Critique 2026-10-06 (harden): Recent Changes grouped for display — this account's
    /// first, then each other server's (most recently changed first), then entries with no
    /// recorded account. Empty groups are left out; entries keep their newest-first order.
    /// Other servers are grouped by account id and headed by the newest entry's host.
    /// Pure, pinned by `PlaybackHistoryScopeTests`.
    static func sections(for entries: [HistoryEntry], currentAccountId: String?) -> [HistorySection] {
        var current: [HistoryEntry] = []
        var unknown: [HistoryEntry] = []
        var otherOrder: [String] = []
        var others: [String: [HistoryEntry]] = [:]
        for entry in entries {
            guard let account = entry.accountId else { unknown.append(entry); continue }
            if account == currentAccountId {
                current.append(entry)
            } else {
                if others[account] == nil { otherOrder.append(account) }
                others[account, default: []].append(entry)
            }
        }
        var result: [HistorySection] = []
        if !current.isEmpty { result.append(HistorySection(id: "current", kind: .current, entries: current)) }
        for account in otherOrder {
            let group = others[account] ?? []
            let host = group.lazy.compactMap(\.serverHost).first ?? String(localized: "another server", comment: "Fallback name for a server whose host is unknown")
            result.append(HistorySection(id: "account:\(account)", kind: .otherServer(host: host), entries: group))
        }
        if !unknown.isEmpty { result.append(HistorySection(id: "unknown", kind: .unknownServer, entries: unknown)) }
        return result
    }

    /// Reverts the book to its pre-action state via `LibraryViewModel.restoreProgress`
    /// and removes the entry (it's no longer "the latest change" once undone). Returns
    /// whether the revert actually happened.
    @discardableResult
    func undo(_ entry: HistoryEntry, libraryViewModel: LibraryViewModel) async -> Bool {
        loadIfNeeded()
        guard canUndo(entry) else { return false }
        let ok = await libraryViewModel.restoreProgress(
            itemId: entry.itemId, currentTime: entry.previousCurrentTime,
            isFinished: entry.previousIsFinished, duration: entry.previousDuration
        )
        if ok {
            entries.removeAll { $0.id == entry.id }
            persist()
        }
        return ok
    }

    func clear() {
        loadIfNeeded()
        entries = []
        persist()
    }

    private func persist() {
        // Same guard as the two queue actors: never write over storage whose contents we
        // failed to establish. Retried on the next `loadIfNeeded()`.
        guard hasLoadedFromDisk else {
            ShelfLog.error(.storage, "PlaybackHistoryStore: skipping persist — the stored history has not been read yet, writing now would destroy it")
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
