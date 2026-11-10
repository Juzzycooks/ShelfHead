import SwiftUI

/// PL-4 follow-up (docs/design-review.md): bookmarks for standalone Watch playback. The list is
/// the server's bookmarks for the playing book plus anything made offline that hasn't synced yet.
/// The decisions (naming, merging, the offline queue) are pure or file-backed so they're unit-tested.

nonisolated struct StandaloneBookmark: Identifiable, Equatable, Sendable {
    let itemId: String
    let title: String
    let time: Double
    let isPending: Bool

    /// Same identity the phone uses (`AudioBookmark.id`): item plus whole seconds. Two bookmarks in
    /// the same second are the same bookmark on the server, so they are here too.
    var id: String { "\(itemId)-\(StandaloneBookmarkRules.wholeSeconds(time))" }
}

nonisolated enum StandaloneBookmarkRules {
    /// Whole seconds without trapping on NaN, infinity or out-of-range values (server JSON).
    static func wholeSeconds(_ time: Double) -> Int {
        guard time.isFinite else { return 0 }
        return Int(max(0, min(time, 10_000_000)))
    }

    /// The title given to a bookmark made on the Watch: the chapter it's in, else the time.
    static func defaultTitle(chapterTitle: String?, time: Double) -> String {
        let trimmed = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "Bookmark at \(time.watchFormattedTime)", comment: "Default title of a bookmark made on the Watch; %@ is the position, like 1:02:03") : trimmed
    }

    /// Review Low (bookmarks, 30 October 2026): whether a failed send will never succeed on
    /// retry, so the queued bookmark should be dropped rather than block the ones behind it.
    /// Review 2 Medium 10 (30 October 2026): 403 is transient: a reverse-proxy gate answers 403
    /// when its own token has expired. Review 3 Low (proxy 404/400): only 410 and 422 drop at
    /// once; 400 and 404 go through `shouldDrop`'s failure count. Everything else (auth, 408,
    /// 429, other 4xx, 5xx, network) is kept and retried.
    static func isPermanentFailure(_ error: Error) -> Bool {
        guard let api = error as? WatchAPIError else { return false }
        switch api {
        case .httpError(let code): return [410, 422].contains(code)
        default: return false
        }
    }

    /// Review 3 Low (proxy 404/400): a reverse proxy answers 404 (backend down) or 400 too, so
    /// those two only count as permanent after this many failed flushes in a row.
    static let ambiguousFailureLimit = 5

    /// Whether `error` is one of the ambiguous "permanent-looking" failures (400/404).
    static func isAmbiguousFailure(_ error: Error) -> Bool {
        guard let api = error as? WatchAPIError else { return false }
        switch api {
        case .notFound: return true
        case .httpError(let code): return code == 400 || code == 404
        default: return false
        }
    }

    /// Review 4 Low (ambiguous window): the 400/404 count alone could be reached in minutes, so
    /// the first one must also be at least this old.
    static let ambiguousFailureWindow: TimeInterval = 24 * 60 * 60

    /// Whether to drop the entry now, given the failure, how many times it has already failed
    /// ambiguously (not counting this one) and when the first of those happened.
    static func shouldDrop(after error: Error, priorAmbiguousFailures: Int,
                           firstAmbiguousFailureAt: Date? = nil, now: Date = Date()) -> Bool {
        if isPermanentFailure(error) { return true }
        guard isAmbiguousFailure(error) else { return false }
        guard priorAmbiguousFailures + 1 >= ambiguousFailureLimit else { return false }
        // No timestamp yet (queued by Batch 474): this failure starts the clock instead.
        guard let first = firstAmbiguousFailureAt else { return false }
        return now.timeIntervalSince(first) >= ambiguousFailureWindow
    }

    /// Review 2 Low (Watch offline flush, 30 October 2026): whether a failed send says the
    /// *connection or session* is the problem, so the remaining entries would fail the same
    /// way (each after its own timeout). Per-item errors (4xx, 5xx) let the flush carry on.
    static func shouldStopFlush(after error: Error) -> Bool {
        if error is URLError { return true }
        guard let api = error as? WatchAPIError else { return false }
        switch api {
        case .sessionExpired, .unauthorized, .transportError: return true
        default: return false
        }
    }

    /// Server bookmarks with queued ones on top: a queued bookmark replaces a server one at the
    /// same second, and the result is sorted by position.
    static func merged(server: [StandaloneBookmark], pending: [StandaloneBookmark]) -> [StandaloneBookmark] {
        var byID: [String: StandaloneBookmark] = [:]
        for bookmark in server { byID[bookmark.id] = bookmark }
        for bookmark in pending { byID[bookmark.id] = bookmark }
        return byID.values.sorted { $0.time < $1.time }
    }
}

/// Bookmarks made while the server is unreachable, kept on disk until they can be sent.
actor WatchPendingBookmarkQueue {
    static let shared = WatchPendingBookmarkQueue()

    struct Entry: Codable, Equatable, Sendable {
        /// Review 4 Low (overlapping flushes): stable identity, so a flush matches its entry even
        /// after another flush changed the entry's counters. Old queues lack it (fresh UUID).
        var id: UUID = UUID()
        let itemId: String
        let title: String
        let time: Double
        /// Review 3 Low (proxy 404/400): flushes that failed with 400/404. Old queues lack it.
        var ambiguousFailures: Int = 0
        /// Review 4 Low (ambiguous window): when the first of those happened.
        var firstAmbiguousFailureAt: Date?

        init(itemId: String, title: String, time: Double, ambiguousFailures: Int = 0,
             firstAmbiguousFailureAt: Date? = nil) {
            self.itemId = itemId; self.title = title; self.time = time
            self.ambiguousFailures = ambiguousFailures
            self.firstAmbiguousFailureAt = firstAmbiguousFailureAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemId = try c.decode(String.self, forKey: .itemId)
            title = try c.decode(String.self, forKey: .title)
            time = try c.decode(Double.self, forKey: .time)
            ambiguousFailures = try c.decodeIfPresent(Int.self, forKey: .ambiguousFailures) ?? 0
            firstAmbiguousFailureAt = try c.decodeIfPresent(Date.self, forKey: .firstAmbiguousFailureAt)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        }
    }

    private var entries: [Entry] = []
    private var hasLoaded = false
    /// Review 4 Low (overlapping flushes): `add()` and the view's load can both flush; a second
    /// flush while one is suspended in `send` skips, since the first is already working the queue.
    private var isFlushing = false
    /// Review 7 Medium 4: ids a flush delivered, so `addOutcome` can tell "sent" from "dropped".
    private var recentlySentIds: [UUID] = []
    private let fileURL: URL

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchPendingBookmarks", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    init(fileURL: URL = WatchPendingBookmarkQueue.defaultFileURL()) {
        self.fileURL = fileURL
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Queues a bookmark, replacing a queued one at the same item and second.
    func add(_ entry: Entry) {
        load()
        let second = StandaloneBookmarkRules.wholeSeconds(entry.time)
        // Review 5 Low (Watch duplicate): reuse the replaced entry's id so an in-flight flush's
        // success removes this one too. Counters stay the new entry's (fresh, zero).
        var entry = entry
        if let old = entries.first(where: { $0.itemId == entry.itemId && StandaloneBookmarkRules.wholeSeconds($0.time) == second }) {
            entry.id = old.id
        }
        entries.removeAll { $0.itemId == entry.itemId && StandaloneBookmarkRules.wholeSeconds($0.time) == second }
        entries.append(entry)
        persist()
    }

    func pending(itemId: String? = nil) -> [Entry] {
        load()
        guard let itemId else { return entries }
        return entries.filter { $0.itemId == itemId }
    }

    /// Sends every queued bookmark with `send`, oldest first, dropping each that succeeds (or fails
    /// permanently) and keeping the rest queued in order. Returns how many went.
    @discardableResult
    func flush(using send: (Entry) async throws -> Void) async -> Int {
        load()
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }
        // Review Low (bookmarks, 30 October 2026): one entry that keeps failing used to block
        // every bookmark behind it. A permanent failure drops that entry; a transient one keeps
        // it (still queued, in order) and carries on with the rest.
        var sent = 0
        // Snapshot, then remove each resolved entry from the live list by value, so a bookmark
        // added while suspended in `send` (actor re-entrancy) isn't lost.
        for next in entries {
            do {
                try await send(next)
                sent += 1
                recentlySentIds.append(next.id)
                if recentlySentIds.count > 50 { recentlySentIds.removeFirst(recentlySentIds.count - 50) }
            } catch {
                // Review 2 Low (Watch offline flush): a transport/session error means the rest
                // would fail too (one timeout each), so stop; the entry stays queued.
                if StandaloneBookmarkRules.shouldStopFlush(after: error) { break }
                if !StandaloneBookmarkRules.shouldDrop(after: error, priorAmbiguousFailures: next.ambiguousFailures,
                                                               firstAmbiguousFailureAt: next.firstAmbiguousFailureAt) {
                    // Transient (or not yet enough 400/404s): keep it queued, counting the 400/404.
                    if StandaloneBookmarkRules.isAmbiguousFailure(error),
                       let index = entries.firstIndex(where: { $0.id == next.id }) {
                        entries[index].ambiguousFailures += 1
                        if entries[index].firstAmbiguousFailureAt == nil { entries[index].firstAmbiguousFailureAt = Date() }
                        persist()
                    } else if !StandaloneBookmarkRules.isAmbiguousFailure(error),
                              let index = entries.firstIndex(where: { $0.id == next.id }),
                              entries[index].ambiguousFailures > 0 {
                        // Review 5 Low (Watch count): the server answered with something else
                        // (5xx, 403...), so the 400/404s were not "in a row". Transport errors
                        // break above and don't reset: being offline says nothing about the run.
                        entries[index].ambiguousFailures = 0
                        entries[index].firstAmbiguousFailureAt = nil
                        persist()
                    }
                    continue
                }
            }
            // Review 6 Low (same-second re-add): a re-add reuses the id, so remove only while the
            // queued entry still matches what was sent (a replacement stays queued).
            if let index = entries.firstIndex(where: { $0.id == next.id }),
               Self.matchesSent(entries[index], next) {
                entries.remove(at: index)
            }
            persist()
        }
        return sent
    }

    /// Review 6 Low (same-second re-add): whether a queued entry is still the one that was sent.
    nonisolated static func matchesSent(_ queued: Entry, _ sent: Entry) -> Bool {
        queued.id == sent.id && queued.title == sent.title && queued.time == sent.time
    }

    /// Review 7 Medium 4: whether a flush delivered this entry (consumes the record).
    func consumeSent(id: UUID) -> Bool {
        guard let i = recentlySentIds.firstIndex(of: id) else { return false }
        recentlySentIds.remove(at: i)
        return true
    }

    /// Whether an entry is still queued (after an immediate flush).
    func contains(id: UUID) -> Bool {
        load()
        return entries.contains { $0.id == id }
    }

    func clear() {
        load()
        entries = []
        persist()
    }
}

/// The screen's state: loads the playing book's bookmarks, adds new ones, and syncs the queue.
@MainActor
@Observable
final class StandaloneBookmarkStore {
    private(set) var bookmarks: [StandaloneBookmark] = []
    private(set) var isLoading = false
    /// True after the last attempt to reach the server failed, so the list may be out of date.
    private(set) var isOffline = false

    private let api: WatchAudiobookshelfAPI
    private let queue: WatchPendingBookmarkQueue

    // No default arguments: `WatchAudiobookshelfAPI.shared` is main-actor isolated and default
    // argument expressions are evaluated as nonisolated (same note as `WatchLocalDownloadManager.shared`).
    init(api: WatchAudiobookshelfAPI, queue: WatchPendingBookmarkQueue) {
        self.api = api
        self.queue = queue
    }

    /// Sends anything queued, then loads the server's list for `itemId` and folds in what's still queued.
    func load(itemId: String) async {
        isLoading = true
        defer { isLoading = false }
        let api = self.api
        await queue.flush { entry in
            try await WatchStandaloneCall.perform {
                try await api.createBookmark(itemId: entry.itemId, time: entry.time, title: entry.title)
            }
        }
        let pending = await queue.pending(itemId: itemId).map {
            StandaloneBookmark(itemId: $0.itemId, title: $0.title, time: $0.time, isPending: true)
        }
        do {
            let server = try await WatchStandaloneCall.perform { try await api.getBookmarks(itemId: itemId) }
            isOffline = false
            bookmarks = StandaloneBookmarkRules.merged(server: server, pending: pending)
        } catch {
            isOffline = true
            bookmarks = StandaloneBookmarkRules.merged(server: bookmarks.filter { !$0.isPending }, pending: pending)
        }
    }

    /// Review 6 Low (add truth): what happened to an added bookmark.
    enum AddOutcome: Equatable, Sendable { case sent, queued, dropped }

    /// Bookmarks `time` in `itemId`: tries the server, queues it when that fails. Returns whether it
    /// reached the server. Use `addOutcome` to tell "queued" from "dropped by the server".
    @discardableResult
    func add(itemId: String, time: Double, chapterTitle: String?) async -> Bool {
        await addOutcome(itemId: itemId, time: time, chapterTitle: chapterTitle) == .sent
    }

    /// Review 6 Low (add truth): `.queued` only when the entry is still queued after the immediate
    /// flush; `.dropped` when the flush discarded it (410/422).
    func addOutcome(itemId: String, time: Double, chapterTitle: String?) async -> AddOutcome {
        let title = StandaloneBookmarkRules.defaultTitle(chapterTitle: chapterTitle, time: time)
        let api = self.api
        var outcome = AddOutcome.sent
        var queuedId: UUID?
        do {
            try await WatchStandaloneCall.perform { try await api.createBookmark(itemId: itemId, time: time, title: title) }
        } catch {
            let entry = WatchPendingBookmarkQueue.Entry(itemId: itemId, title: title, time: time)
            await queue.add(entry)
            // `add` may reuse an older entry's id; find the stored one by item and time.
            queuedId = await queue.pending(itemId: itemId).first {
                StandaloneBookmarkRules.wholeSeconds($0.time) == StandaloneBookmarkRules.wholeSeconds(time)
            }?.id
            outcome = .queued
        }
        await load(itemId: itemId)
        if outcome == .queued {
            let stillQueued: Bool
            if let queuedId { stillQueued = await queue.contains(id: queuedId) } else { stillQueued = false }
            if !stillQueued {
                // Review 7 Medium 4: the load's flush may have delivered it; that is success.
                let wasSent: Bool
                if let queuedId { wasSent = await queue.consumeSent(id: queuedId) } else { wasSent = false }
                outcome = wasSent ? .sent : .dropped
            }
        }
        return outcome
    }
}

// Batch 410: `StandaloneBookmarksView` was here. Both modes now use the shared
// `WatchBookmarksSheet` (`WatchNowPlayingSheets.swift`), fed from this store.
