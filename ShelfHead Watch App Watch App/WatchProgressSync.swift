import Foundation
import Network
import os

// MARK: - Standalone progress sync (Stage 6 — the Watch as a third writer)

/// Watch-only durable queue of not-yet-confirmed-pushed progress, mirroring the
/// phone's `PendingProgressQueue` actor (`ShelfHead/Services/PendingProgressQueue.swift`)
/// — same serialized-single-owner shape, for the same reason (no `await` boundary in
/// the middle of a read-modify-write for a racing `record`/`clear` to land in).
///
/// **Deliberately simpler than the phone's version — no `scope` key.**
/// `PendingProgressQueue.Entry.scope` exists to keep two accounts' (or two servers')
/// queued positions from colliding, since the phone supports switching accounts
/// without restarting the app. This Watch app has no equivalent concept —
/// `WatchAudiobookshelfAPI`/`AuthStore` hold exactly one session at a time, and
/// switching servers means re-authenticating, which already goes through
/// `wipeCredentials()` (clearing this queue's on-disk file along with everything
/// else — see `WatchStore.wipeCredentials()`). Adding a scope key here would be
/// copying a mechanism this app has no bug for.
actor WatchPendingProgressQueue {
    static let shared = WatchPendingProgressQueue()

    struct Entry: Codable, Sendable, Equatable {
        let itemId: String
        let currentTime: Double
        let duration: Double
        /// Epoch milliseconds — matches `WatchMediaProgress.lastUpdate`'s unit, so
        /// this compares directly against a server-reported value with no
        /// conversion at the comparison site.
        let updatedAt: Double
    }

    private var entries: [String: Entry] = [:]
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    private static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchPendingProgress", isDirectory: true)
        return dir.appendingPathComponent("queue.json")
    }

    init(fileURL: URL = WatchPendingProgressQueue.defaultFileURL()) {
        self.fileURL = fileURL
    }

    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Same forward-progress-wins guard as the phone's `record(_:)` — an entry only
    /// overwrites what's queued if it's newer by wall clock, or its position has
    /// actually advanced (closes the same clock-regression gap the phone's own
    /// P3-8 fix documents, without repeating that fix's own trial-and-error here).
    func record(_ entry: Entry) {
        loadFromDiskIfNeeded()
        guard entries[entry.itemId].map({ existing in
            existing.updatedAt <= entry.updatedAt || entry.currentTime >= existing.currentTime
        }) ?? true else { return }
        entries[entry.itemId] = entry
        persist()
    }

    func clear(itemId: String, ifNotNewerThan: Double) {
        loadFromDiskIfNeeded()
        guard let existing = entries[itemId], existing.updatedAt <= ifNotNewerThan else { return }
        entries.removeValue(forKey: itemId)
        persist()
    }

    /// One item's queued entry, for the resume-position lookup
    /// (`StandaloneAudioEngine.play(...)`) — the queue is where this device's own
    /// most recent position lives until a push succeeds and clears it.
    func entry(itemId: String) -> Entry? {
        loadFromDiskIfNeeded()
        return entries[itemId]
    }

    func allEntries() -> [Entry] {
        loadFromDiskIfNeeded()
        return Array(entries.values)
    }

    func removeAll() {
        entries = [:]
        hasLoadedFromDisk = true
        persist()
    }
}

/// The three-choice prompt's subject — same shape as the phone's `ProgressConflict`
/// (`DownloadManager.swift:2119`), duplicated rather than shared since that type
/// lives in a main-app-only file this target doesn't compile.
struct WatchProgressConflict: Identifiable, Equatable {
    let itemId: String
    let title: String
    let localTime: Double
    let serverTime: Double
    let duration: Double
    var id: String { itemId }
}

/// Owns this Watch's half of the progress-sync problem: queuing local progress
/// durably, deciding push-vs-pull-vs-ask against the server, and surfacing the
/// three-choice prompt when it can't decide safely. See addendum §5's Stage 6 row
/// for the design this implements.
///
/// **Why this Watch needs its own conflict heuristic, not just `ProgressReconciler
/// .reconcile` as-is:** that function (confirmed by direct reading,
/// `ProgressReconciler.swift:93–97`) flags `.conflict` on raw position divergence
/// alone, before ever checking which side's `lastUpdate` is actually newer — the
/// exact reason Stage 3 avoided calling `syncSession`/`closeSession` at all. Now that
/// this Watch is a genuine third writer, that check has to run somewhere, and
/// `AudiobookshelfAPI`/`MediaProgress`/`ListeningSession` carry no device-attribution
/// field (confirmed: neither `AudiobookshelfModels.swift:343–357` nor
/// `BrowseModels.swift:115–131` has a device id, session id, or client name) — so
/// there's no way to tell "the phone changed this since I last pushed" apart from
/// "I changed this myself and haven't told the server yet" with certainty. The
/// pragmatic heuristic below (§5's Stage 6 row): suppress the conflict when the
/// divergence is fully explained by this device's own forward progress since its own
/// last successful push; otherwise ask, the same three-choice prompt the phone
/// already shows for the identical dilemma between phone and server.
/// `[needs external verification against Audiobookshelf's API]` — whether
/// `/api/me/sessions` (found in Stage 2's own work) carries real per-session device
/// info that could replace this heuristic with actual attribution someday; not
/// wired up here, per the addendum's own note that this is worth checking later, not
/// blocking this stage.
@MainActor
@Observable
final class WatchProgressSyncCoordinator {
    /// 5 minutes — identical to the phone's `DownloadManager.conflictThreshold`
    /// (`DownloadManager.swift:1187`), so "how big a gap counts as worth asking
    /// about" means the same thing on both devices.
    private static let conflictThreshold: Double = 5 * 60

    private(set) var pendingConflict: WatchProgressConflict?

    /// Polish pass (WA-4): how many books have progress still waiting to reach the server, as of
    /// the last flush (or `refreshPendingCount()`), and whether that flush hit a failure.
    /// Observable so Settings can say "All progress synced" or "2 updates waiting to sync".
    private(set) var pendingCount = 0
    private(set) var lastFlushFailed = false
    private var isFlushing = false
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?
    private static let log = Logger(subsystem: "com.justin.ShelfHead.watchkitapp", category: "sync")

    private let api: WatchAudiobookshelfAPI
    private let queue: WatchPendingProgressQueue

    /// This device's own last successful push per item — `time` in the same epoch-ms
    /// unit as `WatchMediaProgress.lastUpdate`, `position` the `currentTime` that push
    /// carried. Persisted via `UserDefaults` (small, infrequently-written, unlike the
    /// queue itself) so the "forward-only since my own last push" heuristic still
    /// works correctly across an app relaunch, not just within one playback session.
    private var lastSuccessfulPush: [String: (time: Double, position: Double)] = [:]
    private static let lastPushDefaultsKey = "watchProgressSync.lastSuccessfulPush"

    init(api: WatchAudiobookshelfAPI, queue: WatchPendingProgressQueue = .shared) {
        self.api = api
        self.queue = queue
        loadLastSuccessfulPush()
    }

    private func loadLastSuccessfulPush() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.lastPushDefaultsKey) as? [String: [String: Double]] else { return }
        for (itemId, values) in raw {
            guard let time = values["time"], let position = values["position"] else { continue }
            lastSuccessfulPush[itemId] = (time, position)
        }
    }

    private func persistLastSuccessfulPush() {
        var raw: [String: [String: Double]] = [:]
        for (itemId, entry) in lastSuccessfulPush {
            raw[itemId] = ["time": entry.time, "position": entry.position]
        }
        UserDefaults.standard.set(raw, forKey: Self.lastPushDefaultsKey)
    }

    // MARK: - Recording (called from `StandaloneAudioEngine` while playing)

    /// Queues the current position durably. Cheap and safe to call often — every
    /// periodic tick, matching the phone's own "queue on every sync attempt, not
    /// just on failure" belt-and-suspenders pattern (`AudioPlayerService`'s periodic
    /// timer both syncs live and records into `PendingProgressQueue`).
    func recordLocalProgress(itemId: String, currentTime: Double, duration: Double) {
        let entry = WatchPendingProgressQueue.Entry(
            itemId: itemId, currentTime: currentTime, duration: duration,
            updatedAt: Date().timeIntervalSince1970 * 1000)
        // Capture `queue` into a local before forming the `Task` — this method is
        // synchronous, so the `Task` closure below isn't itself MainActor-isolated,
        // and `self.queue` is a `@MainActor`-isolated property read even though the
        // actor reference it holds is `Sendable` once obtained. Same fix shape as
        // `StandaloneAudioEngine.stop()`'s own `let api = self.api` extraction.
        let queue = self.queue
        Task { await queue.record(entry) }
    }

    /// This device's own last known position for `itemId`, or `nil` if it has never
    /// recorded one.
    ///
    /// Added for the resume-position fix (CRITICAL, 9 September 2026 review):
    /// `StandaloneAudioEngine` had no local position to compare the server's against,
    /// so it started every book at 0:00. There are two places a locally-recorded
    /// position can be, and which one holds it depends only on whether a push has
    /// succeeded since: `WatchPendingProgressQueue` while it's still un-pushed, and
    /// `lastSuccessfulPush` afterwards (`push(...)` clears the queue entry on
    /// success). This returns the newer of the two rather than picking one, so the
    /// answer doesn't change meaning depending on connectivity. Deliberately no new
    /// store: the Stage 5 download manifest holds no progress at all (see
    /// `WatchLocalDownload`'s own doc comment), and adding a third writer of the
    /// same fact is how these get out of step.
    ///
    /// `duration` is `0` when only `lastSuccessfulPush` knows the position (it never
    /// recorded a duration); callers treat `0` as "unknown", the same way the push
    /// path already does.
    func lastKnownLocalProgress(itemId: String) async -> (currentTime: Double, updatedAt: Double, duration: Double)? {
        let queued = await queue.entry(itemId: itemId)
        let pushed = lastSuccessfulPush[itemId]
        switch (queued, pushed) {
        case (let queued?, let pushed?):
            return queued.updatedAt >= pushed.time
                ? (queued.currentTime, queued.updatedAt, queued.duration)
                : (pushed.position, pushed.time, 0)
        case (let queued?, nil):
            return (queued.currentTime, queued.updatedAt, queued.duration)
        case (nil, let pushed?):
            return (pushed.position, pushed.time, 0)
        default:
            return nil
        }
    }

    /// Critique 2026-10-06 (harden): called when playback resumed from the server's
    /// position (a download's manifest reading, a fresh fetch, or the iPhone's snapshot)
    /// rather than this Watch's own. That reading becomes the baseline the push heuristic
    /// compares against, exactly as if this Watch had pushed it: everything listened to
    /// from here is this Watch's own forward progress. Without it, a run that started
    /// where the iPhone left off still ended in "Progress Doesn't Match", because the
    /// server had moved since this Watch's last push. Older queued positions for the book
    /// are dropped too: the server's newer one superseded them, and leaving them queued
    /// would raise the same prompt on the next flush.
    func adoptServerBaseline(itemId: String, progress: WatchServerProgress) async {
        let at = progress.lastUpdateMs ?? Date().timeIntervalSince1970 * 1000
        if let existing = lastSuccessfulPush[itemId], existing.time > at { return }
        lastSuccessfulPush[itemId] = (at, progress.currentTime)
        persistLastSuccessfulPush()
        await queue.clear(itemId: itemId, ifNotNewerThan: at)
    }

    // MARK: - Pushing (direct write, no session — Stage 5 offline path's only option)

    /// Attempts to push everything currently queued. Call sites: `WatchStore
    /// .bootstrapAuth()` (launch) and `resolveMode()`'s own natural checkpoints
    /// (foregrounding, reachability change) — the same "flush at natural
    /// checkpoints, not on a timer" convention `resolveMode()` itself already
    /// follows, rather than adding a new polling loop.
    func flushPendingProgress() async {
        guard api.isConfigured else { return }
        // Polish pass (WA-5): launch, foreground, a reachability edge and a regained network
        // can all ask at once; one flush at a time keeps two passes from pushing the same entry.
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        var anyFailed = false
        for entry in await queue.allEntries() {
            let ok = await evaluateAndPush(itemId: entry.itemId, localTime: entry.currentTime, localDuration: entry.duration, localUpdatedAt: entry.updatedAt)
            if !ok { anyFailed = true }
        }
        lastFlushFailed = anyFailed
        await refreshPendingCount()
    }

    /// Polish pass (WA-4): re-reads the queue so the status line is right when Settings opens.
    func refreshPendingCount() async {
        pendingCount = await queue.allEntries().count
    }

    /// Polish pass (WA-5): flush when the network comes back while the app is running (the
    /// Watch has no other trigger between launch, foreground and a phone-reachability edge).
    /// Only the unsatisfied-to-satisfied edge triggers; the first path report just records.
    func startWatchingConnectivity() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let regained = Self.shouldFlushOnPathChange(previouslySatisfied: self.lastPathSatisfied, nowSatisfied: satisfied)
                self.lastPathSatisfied = satisfied
                if regained { await self.flushPendingProgress() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "watch.progress.path"))
    }

    /// Batch 495 (REVIEW 2026-11-11 W6): false only once the path monitor has reported no
    /// network; unknown (before its first report) counts as available. Observable through
    /// `lastPathSatisfied`, so the Shelf redraws when the network drops or returns.
    var isNetworkAvailable: Bool { lastPathSatisfied != false }

    /// Pure: flush only on a real loss-to-regain edge.
    nonisolated static func shouldFlushOnPathChange(previouslySatisfied: Bool?, nowSatisfied: Bool) -> Bool {
        previouslySatisfied == false && nowSatisfied
    }

    /// Polish pass (WA-4): the Settings status line.
    nonisolated static func statusText(pendingCount: Int) -> String {
        switch pendingCount {
        case ..<1: return String(localized: "All progress synced", comment: "Watch Settings status: nothing waiting to upload")
        case 1: return String(localized: "1 update waiting to sync", comment: "Watch Settings status: one book's progress waiting")
        default: return String(localized: "\(pendingCount) updates waiting to sync", comment: "Watch Settings status: several books' progress waiting")
        }
    }

    /// The core decision, run once per item: fetch the server's current progress,
    /// decide push / suppress-as-already-consistent / ask, per this type's own doc
    /// comment on the heuristic.
    @discardableResult
    private func evaluateAndPush(itemId: String, localTime: Double, localDuration: Double, localUpdatedAt: Double) async -> Bool {
        // Funnelled through `WatchStandaloneCall` (9 September 2026, review MEDIUM):
        // both calls in this file are best-effort `try?`/`catch`-and-requeue, which is
        // exactly why a dead session was invisible here — the queue just silently
        // stopped draining forever. The retry behaviour is unchanged; the session-expired
        // flag is now raised alongside it.
        guard let item = try? await WatchStandaloneCall.perform({ try await api.getItem(itemId: itemId) }) else {
            // Polish pass (WA-4): was a silent return. Still queued; logged without the book id.
            Self.log.info("progress flush: couldn't read the server's progress; the entry stays queued")
            return false
        }
        let server = item.mediaProgress
        let serverTime = server?.currentTime
        let serverLastUpdate = Double(server?.lastUpdate ?? 0)
        let serverIsFinished = server?.isFinished ?? false

        // Heuristic: if the server hasn't moved past this device's own last
        // successful push for this item, any divergence is explained by this
        // device's own subsequent forward listening, not a write from elsewhere —
        // safe to push without asking.
        //
        // Critique 2026-10-06 (harden): "hasn't moved" also counts when the server's
        // position is still the one this Watch adopted at resume
        // (`adoptServerBaseline`) — that baseline may carry the iPhone's clock rather
        // than the server's, so the timestamp comparison alone would flag a run as a
        // conflict. See `WatchProgressBaseline`.
        if let lastPush = lastSuccessfulPush[itemId],
           WatchProgressBaseline.serverUnchanged(serverTime: serverTime, serverLastUpdateMs: serverLastUpdate,
                                                 baselinePosition: lastPush.position, baselineTimeMs: lastPush.time),
           localTime >= lastPush.position {
            return await push(itemId: itemId, localTime: localTime, localDuration: localDuration, localUpdatedAt: localUpdatedAt, isFinished: serverIsFinished)
        }

        if server != nil, !serverIsFinished, localTime > 0, let serverTime, serverTime > 0,
           abs(localTime - serverTime) > Self.conflictThreshold {
            if pendingConflict == nil {
                pendingConflict = WatchProgressConflict(
                    itemId: itemId, title: item.media?.metadata?.title ?? String(localized: "This book", comment: "fallback book title in a progress conflict prompt"),
                    localTime: localTime, serverTime: serverTime,
                    duration: localDuration > 0 ? localDuration : (server?.duration ?? 0))
            }
            return true   // leave it queued until the user decides (not a failure)
        }

        // No conflict-sized gap (or no server entry at all yet) — push through.
        return await push(itemId: itemId, localTime: localTime, localDuration: localDuration, localUpdatedAt: localUpdatedAt, isFinished: serverIsFinished)
    }

    @discardableResult
    private func push(itemId: String, localTime: Double, localDuration: Double, localUpdatedAt: Double, isFinished: Bool) async -> Bool {
        let progress = localDuration > 0 ? min(localTime / localDuration, 1.0) : 0
        do {
            try await WatchStandaloneCall.perform {
                try await api.updateProgress(itemId: itemId, progress: progress, currentTime: localTime, duration: localDuration, isFinished: isFinished)
            }
            lastSuccessfulPush[itemId] = (Date().timeIntervalSince1970 * 1000, localTime)
            persistLastSuccessfulPush()
            await queue.clear(itemId: itemId, ifNotNewerThan: localUpdatedAt)
            return true
        } catch {
            // Stays queued — the next `flushPendingProgress()` checkpoint retries it.
            // Polish pass (WA-4): was swallowed; now recorded for the status line and logged.
            lastFlushFailed = true
            Self.log.error("progress push failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    // MARK: - Resolving the three-choice prompt

    /// Mirrors the phone's `DownloadManager.resolveProgressConflict(keepLocal:)`
    /// exactly: `keepLocal` pushes this device's position; otherwise the server's
    /// position wins and the queued entry is simply dropped (nothing local to pull
    /// into — this Watch has no durable manifest of its own position the way a
    /// downloaded book's `WatchLocalDownload` doesn't track progress either, per
    /// §10.1's original standalone-progress-writing decision).
    func resolveConflict(keepLocal: Bool) async {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        if keepLocal {
            await push(itemId: conflict.itemId, localTime: conflict.localTime, localDuration: conflict.duration, localUpdatedAt: Date().timeIntervalSince1970 * 1000, isFinished: false)
        } else {
            await queue.clear(itemId: conflict.itemId, ifNotNewerThan: Date().timeIntervalSince1970 * 1000)
        }
        await refreshPendingCount()
    }

    func dismissConflict() {
        pendingConflict = nil
    }

    /// Called from `WatchStore.wipeCredentials()` — a phone-initiated sign-out or
    /// account switch means every queued position and remembered "my last push"
    /// timestamp belongs to a session that no longer exists on this Watch. Leaving
    /// them would let a stale entry from the *previous* account's book silently
    /// resurface (and get pushed, or trigger a conflict prompt) the next time this
    /// Watch signs into a new one — the exact class of cross-account mis-attribution
    /// bug the phone's own `PendingProgressQueue` scope key exists to prevent (see
    /// this type's own doc comment on why a scope key itself isn't needed here: this
    /// Watch never holds two sessions at once, but it does hold one *after another*,
    /// which is exactly when a wipe like this has to actually clear state rather
    /// than just stop referencing it).
    func wipeAll() async {
        await queue.removeAll()
        lastSuccessfulPush = [:]
        UserDefaults.standard.removeObject(forKey: Self.lastPushDefaultsKey)
        pendingConflict = nil
        pendingCount = 0
        lastFlushFailed = false
    }
}
