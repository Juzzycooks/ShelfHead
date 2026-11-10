import Foundation

/// Serialized owner of the offline/failed-sync bookmark queue — the bookmark counterpart
/// to `PendingProgressQueue`.
///
/// Before this existed, every bookmark mutation in the app was a bare
/// `try? await AudiobookshelfAPI.shared.addBookmark(...)` — eight such call sites across
/// six files (the player, book detail, All Bookmarks, CarPlay's Now Playing button, and
/// the lock-screen/headphone `MPRemoteCommandCenter` handler). A bookmark made with no
/// connection, on a flaky one, or against an expired session was discarded with no error,
/// no retry, and no trace. That is the same class of loss `PendingProgressQueue` was built
/// to stop for listening positions, and it matters at least as much here: a lost position
/// costs a few seconds of scrubbing, a lost bookmark costs the thing the user deliberately
/// marked — and the two most likely places to make one (the car, headphones while walking)
/// are exactly where connectivity is worst.
///
/// Structure deliberately mirrors `PendingProgressQueue`, for the same reasons documented
/// at length there: a single serialized owner so no read-modify-write can interleave, a
/// `scope` captured synchronously by the caller and handed over as plain data (never read
/// from `AuthStore`/`AccountStore` inside the actor, where an account switch could have
/// landed in between), and a real file rather than `UserDefaults`.
///
/// Where it differs: progress is a single value per item that only ever moves forward, so
/// a newer entry simply wins. A bookmark is an *operation* — save or delete — against a
/// specific position, so `record` has to fold operations together rather than overwrite
/// blindly. See `record(_:)`.
actor PendingBookmarkQueue {

    /// The shared instance every call site uses. Tests construct their own instance with a
    /// scratch `fileURL` instead of touching this one — same seam `PendingProgressQueue` has.
    static let shared = PendingBookmarkQueue()

    /// Kept distinct rather than collapsed into one "save" because the server exposes
    /// create and edit as different endpoints (`POST` vs `PATCH` on
    /// `/api/me/item/<id>/bookmark`). Whether `POST` happens to upsert is not something
    /// this app can verify, and replaying an edit as a create — or a create as an edit
    /// against a bookmark the server has never seen — would fail in a way the user would
    /// only discover as a missing bookmark. `record(_:)` folds a create followed by an
    /// edit back down to a single create, which is the case that would otherwise need
    /// upsert semantics to work.
    enum Operation: String, Codable, Sendable {
        case create
        case update
        case delete
    }

    struct Entry: Codable, Sendable, Equatable {
        let scope: String
        let itemId: String
        /// The bookmark's position, kept as the original `Double` so replay posts exactly
        /// what the user marked. Identity is the whole-second form — see `key(itemId:time:)`.
        let time: Double
        /// Ignored for `.delete`; carried anyway so a queued delete can be shown in a
        /// diagnostics list without a second lookup.
        let title: String
        let operation: Operation
        let updatedAt: Double
    }

    private var entries: [String: Entry] = [:]
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    /// `Application Support/PendingBookmarks/queue.json` — a real file rather than
    /// `UserDefaults`, for the persistence reason spelled out in `PendingProgressQueue`.
    private static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingBookmarks", isDirectory: true)
        return dir.appendingPathComponent("queue.json")
    }

    init(fileURL: URL = PendingBookmarkQueue.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// The scope key a caller must capture **synchronously, before any `await`**, exactly
    /// as `AudioPlayerService.currentProgressScope()` does for progress. Identical
    /// derivation, so a bookmark and a position queued in the same moment are scoped the
    /// same way and are dropped together if that account is removed.
    nonisolated static func currentScope() -> String {
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty else { return "unscoped" }
        return DownloadManager.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
    }

    /// Identity is `(scope, itemId, whole seconds)`. Whole seconds — not the raw `Double` —
    /// because that is what the app's UI treats as a bookmark's identity (`AudioBookmark.id`
    /// is built from `time.safeSeconds`). Keying this queue on the raw `Double` would let a
    /// queued delete fail to cancel the queued save it was meant to undo, purely because of
    /// float noise. Note the *server* side is different since Batch 329: `deleteBookmark`
    /// now addresses the server by the exact stored time, because Audiobookshelf keeps the
    /// fraction and 404s on a truncated one — the whole-second key here is only this
    /// queue's dedupe identity, and the entry still carries the exact `time` it replays.
    private static func key(scope: String, itemId: String, time: Double) -> String {
        "\(scope)|\(itemId)|\(time.safeSeconds)"
    }

    /// Loads the queue file at most once per successful read.
    ///
    /// The flag is deliberately set *after* the read, and only when the read told us
    /// something — see `PersistedStoreLoad` at the bottom of this file for the failure mode
    /// the old `hasLoadedFromDisk = true` first line caused. A file we couldn't read leaves
    /// the flag false, which both blocks `persist()` from overwriting it and lets the next
    /// call try again (protected data becoming available, a transient I/O error clearing).
    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        let outcome: PersistedStoreLoad.Outcome<[String: Entry]> = PersistedStoreLoad.load(
            fileURL: fileURL, label: "PendingBookmarkQueue"
        ) { try JSONDecoder().decode([String: Entry].self, from: $0) }

        switch outcome {
        case .loaded(let decoded):
            // In-memory wins on a key collision. Normally `entries` is empty here and this
            // is plain assignment; it only differs on a retry after an unreadable read, and
            // there anything already in `entries` is a bookmark operation the user performed
            // *after* the file was last written, so it is the newer of the two.
            entries = decoded.merging(entries) { _, inMemory in inMemory }
            hasLoadedFromDisk = true
        case .empty:
            // Nothing on disk, or the unreadable bytes are now quarantined. Whatever is
            // already in `entries` (again, only non-empty on a retry) stands.
            hasLoadedFromDisk = true
        case .unavailable:
            break
        }
    }

    private func persist() {
        // Refusing to write is the entire fix: an unreadable queue file must be left exactly
        // as it is rather than replaced with whatever this process happens to hold.
        guard hasLoadedFromDisk else {
            ShelfLog.error(.storage, "PendingBookmarkQueue: skipping persist — the queue file has not been read yet, writing now would destroy it")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Folds a new operation into whatever is already queued for the same bookmark.
    ///
    /// Two cases need real care, both arising from a bookmark whose *creation* is still
    /// queued — the server has never heard of it, so any later operation has to be
    /// expressed in terms the server can actually accept:
    ///
    /// - **create then delete.** Replaying both would create a bookmark purely to remove
    ///   it, and leave a window where another device sees one the user already deleted.
    ///   They annihilate instead, which is also the only outcome matching what was asked.
    /// - **create then edit.** The edit must not replay as a `PATCH` against a bookmark the
    ///   server doesn't have. It collapses into the pending create, carrying the new title.
    ///
    /// A stale entry (older `updatedAt` than what's queued) is dropped rather than applied,
    /// so an out-of-order replay can't resurrect a deleted bookmark.
    func record(_ entry: Entry) {
        loadFromDiskIfNeeded()
        let key = Self.key(scope: entry.scope, itemId: entry.itemId, time: entry.time)

        var entry = entry
        if let existing = entries[key] {
            guard existing.updatedAt <= entry.updatedAt else { return }
            if existing.operation == .create {
                switch entry.operation {
                case .delete:
                    entries.removeValue(forKey: key)
                    persist()
                    return
                case .update:
                    // Still an unsynced create — keep the operation, take the new title.
                    entry = Entry(
                        scope: entry.scope, itemId: entry.itemId, time: entry.time,
                        title: entry.title, operation: .create, updatedAt: entry.updatedAt)
                case .create:
                    break
                }
            }
        }

        entries[key] = entry
        persist()
    }

    /// Removes the queued operation for this bookmark **only if** it hasn't been superseded
    /// since the caller captured `ifNotNewerThan` — the same guard, for the same reason, as
    /// `PendingProgressQueue.clear(itemId:scope:ifNotNewerThan:)`: a flush's own success
    /// must not delete an edit that raced in while its network call was still in flight.
    func clear(itemId: String, time: Double, scope: String, ifNotNewerThan: Double) {
        loadFromDiskIfNeeded()
        let key = Self.key(scope: scope, itemId: itemId, time: time)
        guard let existing = entries[key], existing.updatedAt <= ifNotNewerThan else { return }
        entries.removeValue(forKey: key)
        persist()
    }

    /// Everything queued for `activeScope`, for a flush to replay. Also evicts entries old
    /// enough that they can never match a live scope again (a removed account), which is
    /// the only way those would ever leave the file.
    ///
    /// Ordered oldest-first so replay preserves the order the user actually performed the
    /// operations in — unlike progress, where entries are independent per item, two
    /// operations here can address the same bookmark.
    func drain(activeScope: String, maxAge: TimeInterval = 30 * 24 * 3600) -> [Entry] {
        loadFromDiskIfNeeded()
        let now = Date().timeIntervalSince1970
        var changed = false
        var result: [Entry] = []
        for (key, entry) in entries {
            if now - entry.updatedAt > maxAge {
                entries.removeValue(forKey: key)
                changed = true
                continue
            }
            guard entry.scope == activeScope else { continue }
            result.append(entry)
        }
        if changed { persist() }
        return result.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Queued operations for one item, so a read can show what the user has done but the
    /// server hasn't seen yet. Read-only: unlike `drain`, this evicts nothing, because it
    /// runs on every render of a bookmark list.
    func pending(forScope activeScope: String, itemId: String) -> [Entry] {
        loadFromDiskIfNeeded()
        return entries.values.filter { $0.scope == activeScope && $0.itemId == itemId }
    }

    /// Queued operations across every item in `activeScope`, for the All Bookmarks screen.
    func pending(forScope activeScope: String) -> [Entry] {
        loadFromDiskIfNeeded()
        return entries.values.filter { $0.scope == activeScope }
    }

    /// Count for `activeScope`, for the same "is my stuff saved?" reassurance
    /// `PendingProgressQueue.count(forScope:)` provides.
    func count(forScope activeScope: String) -> Int {
        loadFromDiskIfNeeded()
        return entries.values.filter { $0.scope == activeScope }.count
    }

    /// Test-only accessor, matching `PendingProgressQueue.allEntries()`'s precedent of
    /// loosening to `internal` for `@testable import` rather than adding a `#if DEBUG` seam.
    func allEntries() -> [String: Entry] {
        loadFromDiskIfNeeded()
        return entries
    }
}

// MARK: - Shared persisted-store loading

/// Load-time handling for the app's three lazily-reloaded persisted stores:
/// `PendingBookmarkQueue` (above), `PendingProgressQueue` and `PlaybackHistoryStore`.
///
/// **Why it lives here.** The iOS app target is a plain Xcode group, not a
/// `PBXFileSystemSynchronizedRootGroup` (only the test, Watch and widget folders are), so a
/// new source file under `ShelfHead/` would need a hand edit of `project.pbxproj` — which
/// this project deliberately avoids. Putting the helper at the bottom of the first store
/// that uses it keeps the change to already-referenced files. If the app target ever gains
/// a synchronized group, lift this into `Services/PersistedStoreLoad.swift` unchanged.
///
/// **The bug it exists to prevent.** All three stores used to set `hasLoadedFromDisk = true`
/// *before* reading, then `try?`-swallow both the read and the decode. An unreadable or
/// corrupt blob therefore loaded as "empty", and the very next `persist()` wrote that
/// emptiness straight back over the file — turning a transient I/O error, or one truncated
/// write, into permanent loss of every queued bookmark, every unsynced listening position,
/// or the whole undo history. Three outcomes have to be told apart, and only two of them
/// are safe to treat as "start empty":
///
/// - **absent** — nothing has been written yet. Start empty, mark loaded, persist freely.
/// - **decode failed** — the bytes exist but aren't what we expect (a truncated write, a
///   format change, real corruption). The original bytes are moved aside to
///   `<name>.corrupt` first, so nothing is destroyed and the file can be recovered from a
///   device backup or a diagnostics pull; only then do we start empty and allow persisting.
/// - **read failed** — the blob is there and we couldn't get at it (I/O error, protected
///   data unavailable at launch, a quarantine rename that itself failed). This is the
///   dangerous one: we know nothing about the contents, so the store must *not* mark itself
///   loaded and must *not* persist. The next access retries the load.
///
/// Everything here is `nonisolated` and free of shared mutable state, so an `actor`
/// (`PendingBookmarkQueue`, `PendingProgressQueue`) and a `@MainActor` `@Observable` class
/// (`PlaybackHistoryStore`) can both call it synchronously from their own isolation domain.
enum PersistedStoreLoad {

    /// The suffix appended when a blob that failed to decode is quarantined:
    /// `queue.json` becomes `queue.json.corrupt`, defaults key `k` becomes `k.corrupt`.
    /// A previous quarantine is replaced — keeping the *newest* unreadable copy is the more
    /// useful one to have around, and an unbounded `.corrupt.corrupt.corrupt` chain would
    /// just consume storage the user can't see.
    static let corruptSuffix = ".corrupt"

    /// What was found where the store's persisted blob should be. Purely a description of
    /// the world; `decision(for:)` turns it into a course of action.
    enum Finding: String, Equatable, Sendable {
        /// No blob has ever been written (or it has been deleted).
        case absent
        /// A blob was read and decoded.
        case decoded
        /// A blob was read but could not be decoded into the expected shape.
        case decodeFailed
        /// A blob exists but could not be read — or could be read but not quarantined,
        /// which is the same thing from the store's point of view: we must not overwrite it.
        case readFailed
    }

    /// What the store should do about a `Finding`.
    struct Decision: Equatable, Sendable {
        /// Whether the store may set `hasLoadedFromDisk = true`. False means "retry on the
        /// next access", which is the whole point of not latching the flag before reading.
        let markLoaded: Bool
        /// Whether the existing bytes must be moved aside before starting empty.
        let quarantine: Bool
        /// Whether `persist()` may write. False protects bytes we couldn't read.
        let persistAllowed: Bool
    }

    /// The pure decision, extracted so it can be pinned by tests with no filesystem at all —
    /// the precedent set by `DownloadManager.shouldReclaimOrphanDirectory`.
    ///
    /// `markLoaded` and `persistAllowed` move together by design: a store that hasn't
    /// established what's on disk has no business writing over it, and a store that has
    /// (even if what it found was garbage that is now safely quarantined) does.
    nonisolated static func decision(for finding: Finding) -> Decision {
        switch finding {
        case .absent, .decoded:
            return Decision(markLoaded: true, quarantine: false, persistAllowed: true)
        case .decodeFailed:
            return Decision(markLoaded: true, quarantine: true, persistAllowed: true)
        case .readFailed:
            return Decision(markLoaded: false, quarantine: false, persistAllowed: false)
        }
    }

    /// The result handed back to a store. `Value` is intentionally unconstrained: this is a
    /// synchronous call made from within the caller's own isolation domain, so nothing
    /// crosses an actor boundary and `Sendable` would only get in the way of
    /// `PlaybackHistoryStore.HistoryEntry`, which is `Codable` but not `Sendable`.
    enum Outcome<Value> {
        /// Decoded cleanly — adopt this value.
        case loaded(Value)
        /// Nothing to load (never written), or the unreadable bytes have been safely moved
        /// aside. Start empty, mark loaded, persist normally.
        case empty
        /// The blob could not be read, or could not be quarantined. Do **not** mark loaded
        /// and do **not** persist; retry on the next access.
        case unavailable
    }

    /// Where a quarantined copy of `fileURL` goes.
    nonisolated static func quarantineURL(for fileURL: URL) -> URL {
        URL(fileURLWithPath: fileURL.path + corruptSuffix)
    }

    /// Which defaults key a quarantined copy of `key` goes to.
    nonisolated static func quarantineKey(for key: String) -> String { key + corruptSuffix }

    /// File-backed stores (`PendingBookmarkQueue`, `PendingProgressQueue`).
    ///
    /// `label` only ever appears in log lines, so callers can tell the three stores apart in
    /// a diagnostics export.
    nonisolated static func load<Value>(
        fileURL: URL,
        label: String,
        fileManager: FileManager = .default,
        decode: (Data) throws -> Value
    ) -> Outcome<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Absent is the overwhelmingly common case (first launch) and is not an error;
            // anything else means bytes we can't see, which is.
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return apply(.absent)
            }
            ShelfLog.error(.storage, "\(label): could not read \(fileURL.lastPathComponent) — \(error.localizedDescription). Not loading and not persisting, will retry.")
            return apply(.readFailed)
        }

        do {
            let value = try decode(data)
            return .loaded(value)
        } catch {
            ShelfLog.error(.storage, "\(label): \(fileURL.lastPathComponent) failed to decode (\(data.count) bytes) — \(error.localizedDescription). Moving it aside as \(fileURL.lastPathComponent)\(corruptSuffix).")
            if decision(for: .decodeFailed).quarantine,
               !quarantineFile(at: fileURL, fileManager: fileManager, label: label) {
                // The bytes are still where they were and we can't move them; treat this
                // exactly like a failed read so nothing overwrites them.
                return apply(.readFailed)
            }
            return apply(.decodeFailed)
        }
    }

    /// `UserDefaults`-backed stores (`PlaybackHistoryStore`). Reading defaults can't fail the
    /// way a file read can — `data(forKey:)` is nil or bytes — so the only paths here are
    /// absent, decoded, and decode-failed. The quarantine write is still verified by reading
    /// it back, because silently dropping the only copy of the corrupt bytes and *then*
    /// overwriting the original would put us right back in the bug this helper prevents.
    nonisolated static func load<Value>(
        defaults: UserDefaults,
        key: String,
        label: String,
        decode: (Data) throws -> Value
    ) -> Outcome<Value> {
        guard let data = defaults.data(forKey: key) else { return apply(.absent) }
        do {
            let value = try decode(data)
            return .loaded(value)
        } catch {
            ShelfLog.error(.storage, "\(label): defaults key \(key) failed to decode (\(data.count) bytes) — \(error.localizedDescription). Moving it aside as \(quarantineKey(for: key)).")
            if decision(for: .decodeFailed).quarantine {
                let corruptKey = quarantineKey(for: key)
                defaults.set(data, forKey: corruptKey)
                guard defaults.data(forKey: corruptKey) == data else {
                    ShelfLog.error(.storage, "\(label): could not quarantine \(key); leaving it untouched rather than overwriting it.")
                    return apply(.readFailed)
                }
                defaults.removeObject(forKey: key)
            }
            return apply(.decodeFailed)
        }
    }

    /// Moves `fileURL` aside to `<name>.corrupt`, replacing any older quarantine.
    /// Returns whether the original bytes are now safely out of the way.
    private nonisolated static func quarantineFile(
        at fileURL: URL, fileManager: FileManager, label: String
    ) -> Bool {
        let destination = quarantineURL(for: fileURL)
        // `moveItem` fails outright if the destination exists, so clear it first. A failure
        // here is not fatal on its own — the move below is the step that has to succeed.
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
            return true
        } catch {
            ShelfLog.error(.storage, "\(label): could not move \(fileURL.lastPathComponent) aside — \(error.localizedDescription). Leaving it untouched rather than overwriting it.")
            return false
        }
    }

    /// Turns a non-`decoded` finding into the outcome the store acts on, so the two wrappers
    /// above share one mapping and the pure `decision(for:)` stays the single source of truth.
    private nonisolated static func apply<Value>(_ finding: Finding) -> Outcome<Value> {
        decision(for: finding).markLoaded ? .empty : .unavailable
    }
}
