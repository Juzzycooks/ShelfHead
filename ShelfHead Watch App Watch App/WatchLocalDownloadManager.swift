import Foundation
import os

// MARK: - Standalone on-Watch downloads (Stage 5)

/// One item's local download record — this Watch's own manifest shape, not shared
/// with the phone's `DownloadedBook` (`ShelfHead/Models/DownloadedBook.swift`).
/// Deliberately narrower than the phone's: this Watch's own listening position lives in
/// `WatchPendingProgressQueue`, not here. (Chapters were added by PL-4; the server's
/// position at download time by Critique 2026-10-06 — see `serverProgress`.)
struct WatchLocalDownload: Codable, Identifiable {
    struct Track: Codable {
        let index: Int
        let filename: String
        let duration: Double
        let startOffset: Double
    }

    let id: String   // libraryItemId
    var title: String
    var author: String
    var duration: Double
    var tracks: [Track]
    var totalBytes: Int64
    /// PL-4 follow-up (30 September 2026): the book's chapters, captured from the playback
    /// session that resolved the download's tracks, so Chapters and the end-of-chapter sleep
    /// timer work offline. Optional so manifests written before this existed still decode;
    /// those books simply have no chapters offline.
    var chapters: [WatchChapter]? = nil
    /// Critique 2026-10-06 (harden): the server's position for this book when it was
    /// downloaded (from the playback session that resolved the tracks), refreshed by any
    /// later online check before playing. A download plays with no network call, so
    /// without this the only resume point was the Watch's own last position: a book
    /// taken to 40% on the iPhone started at 0:00 on a run. Optional, so manifests
    /// written before it existed still decode (synthesized `Codable` uses
    /// `decodeIfPresent` for optionals); those books fall back to the old behaviour
    /// until their first online play.
    var serverProgress: WatchServerProgress? = nil
    /// Drives oldest-finished-first eviction (`evictIfNeeded`) — same clock choice as
    /// `DiskCoverCache.evictIfNeeded`'s own doc comment: written-at, not accessed-at.
    var downloadedAt: Date
}

/// Everything `startDownload` resolved that the manifest needs, persisted to
/// `pending.json` inside the item's download directory while the transfer is in flight.
///
/// Review finding High 7 (30 October 2026): this used to live only in memory
/// (`expectedTrackCounts`, `pendingMetadata`, ...). The background session redelivers
/// finished tasks after the app is killed and relaunched, `didFinishDownloadingTo` moved
/// the track into place, found no in-memory state and returned — no manifest, so the book
/// read "not downloaded" with its bytes orphaned and uncounted. Written atomically once
/// the tracks are resolved; deleted when the manifest is written or the download is
/// abandoned/cancelled/removed. See `WatchLocalDownloadManager.pendingDownloadAction`.
struct WatchPendingDownloadState: Codable {
    var itemId: String
    var title: String
    var author: String
    var duration: Double
    var tracks: [WatchLocalDownload.Track]
    var chapters: [WatchChapter]?
    var serverProgress: WatchServerProgress?
}

enum WatchLocalDownloadState: Equatable {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}

/// Small, Watch-specific download manager — addendum §2.4 Option B / the revised
/// stage table's Stage 5, unchanged from what was originally scoped: own background
/// session identifier, simple storage cap with oldest-finished-first eviction, reused
/// *logic* (not the actual shared file — see `checkIntegrity(at:expectedMinBytes:)`'s
/// own doc comment) from the phone's integrity check, kept entirely separate from
/// `DownloadManager` (main app target only, never imported here).
///
/// **Storage cap derives from actual available storage at runtime, per the
/// public-release amendment's §9.4** — not a constant tuned against any specific
/// Watch's own free space. See `evictIfNeeded()`.
@MainActor
@Observable
final class WatchLocalDownloadManager: NSObject {
    // No default value on `api` (build fix precedent, `WatchStore.swift`'s own
    // `private init(companion:)` doc comment, 28 August 2026): a default *parameter*
    // value is evaluated as if `nonisolated` regardless of the enclosing
    // initializer's own actor isolation, so `WatchAudiobookshelfAPI.shared` (itself
    // `@MainActor`-isolated) can't be referenced as a default value here even though
    // this `init` is `@MainActor`. Passed explicitly at the one real call site
    // (`static let shared` below) instead, which — like `WatchStore.shared`'s own
    // static initializer — runs in this type's own isolation and has no such
    // restriction.
    static let shared = WatchLocalDownloadManager(api: WatchAudiobookshelfAPI.shared)

    private(set) var downloads: [String: WatchLocalDownload] = [:]
    private(set) var states: [String: WatchLocalDownloadState] = [:]
    /// User-visible per §9.4's "and/or be user-visible" clause — `StandaloneDownloadsView`
    /// shows this against `availableCapacityBytes` rather than evicting silently with
    /// nothing on screen to explain why an old download disappeared.
    private(set) var totalBytesUsed: Int64 = 0
    private(set) var availableCapacityBytes: Int64?

    /// Build-fix (28 August 2026, first real Xcode build): `lazy var` is rejected
    /// under `@Observable`'s macro expansion — the macro rewrites every stored
    /// property into a computed pair backed by an init-accessor, and a `lazy`
    /// initializer can't participate in that rewrite (the compiler's own error was
    /// "'lazy' cannot be used on a computed property," plus a cascade of
    /// generated-init-accessor errors that were really just this same problem
    /// surfacing twice). Fixed by dropping `lazy` entirely: `@ObservationIgnored`
    /// (this property has no UI to react to it changing — nothing should
    /// re-render because the session object itself was assigned) on a plain,
    /// force-unwrapped `var`, assigned exactly once in `init` right after
    /// `super.init()` — by that point `self` is fully usable, which is all `lazy`
    /// was buying here in the first place.
    @ObservationIgnored
    private var session: URLSession!

    /// Per-task context, encoded directly into `URLSessionTask.taskDescription`
    /// rather than kept in a `[Int: Context]` dictionary on this instance.
    ///
    /// **Build-fix, same real build as above:** the original dictionary approach
    /// failed with "Main actor-isolated property 'taskContext' can not be
    /// referenced from a nonisolated context" at every read inside the
    /// `nonisolated` delegate callbacks below — `didFinishDownloadingTo` in
    /// particular needs the context synchronously, before returning, since the
    /// system deletes the temp file at `location` immediately after, so deferring
    /// the lookup into a `Task { @MainActor in }` wasn't an option for that one.
    /// Re-reading the phone's own `DownloadSessionDelegate.parse(_:)`
    /// (`DownloadManager.swift:18-25`) showed it never has this problem in the
    /// first place: it encodes `"scope|itemId|track"` into `task.taskDescription`
    /// — a plain `String` the task already carries, readable from any thread with
    /// no actor involved at all — rather than maintaining a side table. Mirrored
    /// that exactly here (narrower: no `scope`, matching this Watch's own
    /// no-multi-account design already established in `WatchPendingProgressQueue`'s
    /// doc comment) instead of working around the isolation error with more `Task`
    /// wrappers.
    private static func taskDescription(itemId: String, trackIndex: Int?) -> String {
        "\(itemId)|\(trackIndex.map(String.init) ?? "cover")"
    }

    /// Build-fix (second real build, 28 August 2026): `static` alone isn't enough
    /// to escape this class's own `@MainActor` annotation — unlike a plain
    /// `actor`'s static members (which are nonisolated by default, since actor
    /// isolation protects *instance* state, not the type itself), `@MainActor` on
    /// a class is a global-actor annotation applied to the whole declaration,
    /// static members included. The compiler's own error was explicit about this:
    /// "Call to main actor-isolated static method 'parseTaskContext' in a
    /// synchronous nonisolated context" — `static` was read as "isolated to
    /// `WatchLocalDownloadManager`'s main-actor context," not "detached from it."
    /// `nonisolated` is the actual keyword that does what the earlier doc comment
    /// on this method described. It only reads `task.taskDescription` (a
    /// parameter, never this instance's own state), so nothing about its behavior
    /// changes — it can now actually be called from the nonisolated delegate
    /// callbacks below and the `@Sendable` closure in `cancelDownload(itemId:)`
    /// without the compiler rejecting the call before it even runs.
    private nonisolated static func parseTaskContext(_ task: URLSessionTask) -> (itemId: String, trackIndex: Int?)? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1] == "cover" ? nil : Int(parts[1]))
    }

    /// Marks an item's download as armed (tracks resolved, manifest not yet written).
    /// Completion is counted from the track files present on disk, not an in-memory
    /// counter, so it survives a relaunch (review finding High 7, 30 October 2026).
    private var expectedTrackCounts: [String: Int] = [:]
    private var pendingMetadata: [String: (title: String, author: String, duration: Double, tracks: [WatchLocalDownload.Track])] = [:]
    /// PL-4 follow-up: chapters from the download's playback session, held until the manifest is written.
    private var pendingChapters: [String: [WatchChapter]] = [:]
    /// Critique 2026-10-06 (harden): the server's position captured when the download
    /// started, written into the manifest on completion (`WatchLocalDownload.serverProgress`).
    private var pendingServerProgress: [String: WatchServerProgress] = [:]

    /// Items whose download has been abandoned (integrity failure, HTTP failure,
    /// explicit cancel) while sibling track tasks may still be in flight.
    ///
    /// Fix (MEDIUM, 9 September 2026 review — "integrity failure deletes the item
    /// directory while sibling track tasks are still writing"): `session.getAllTasks`
    /// is callback-based, so cancellation is *asynchronous* — a sibling that finishes
    /// in the window before the cancel lands would otherwise recreate the directory
    /// we just deleted and drop a stray track file into it. Clearing
    /// `expectedTrackCounts` is what makes a manifest/success-haptic impossible for a
    /// gutted book (the success path is gated on it); this set is what stops the
    /// stray *file* from being left behind, since `didFinishDownloadingTo` has to
    /// move the temp file synchronously before it can consult any state.
    private var abandonedItemIds: Set<String> = []

    /// Held-open `WKURLSessionRefreshBackgroundTask` completions, keyed by session
    /// identifier — see `handleBackgroundSessionEvents(identifier:completion:)`.
    /// `@ObservationIgnored` for the same reason as `session`: nothing renders from it.
    @ObservationIgnored
    private var backgroundEventCompletions: [String: [() -> Void]] = [:]

    /// Distinct identifier from the phone's `"com.shelfhead.download"`
    /// (`DownloadManager.swift`) — a shared identifier would have the OS treat these
    /// as the same background session across two different processes/targets, which
    /// is not what either side wants. Hoisted to a constant (9 September 2026) so the
    /// `WKURLSessionRefreshBackgroundTask` handler can verify the identifier it was
    /// handed is actually this session's.
    static let backgroundSessionIdentifier = "com.shelfhead.watch.download"

    private let api: WatchAudiobookshelfAPI
    private let fileManager = FileManager.default

    init(api: WatchAudiobookshelfAPI) {
        self.api = api
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 7 * 24 * 3600
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        loadManifests()
        reconcilePendingDownloads()
        refreshAvailableCapacity()
    }

    // MARK: - Paths

    private var downloadsRoot: URL {
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func itemDirectory(_ itemId: String) -> URL {
        let dir = downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifestURL(_ itemId: String) -> URL {
        itemDirectory(itemId).appendingPathComponent("manifest.json")
    }

    /// The persisted in-flight state (`WatchPendingDownloadState`) — lives and dies with
    /// the item directory.
    private nonisolated static let pendingFilename = "pending.json"

    private func pendingURL(_ itemId: String) -> URL {
        itemDirectory(itemId).appendingPathComponent(Self.pendingFilename)
    }

    /// Deliberately avoids `itemDirectory(_:)`, which would recreate a directory that was
    /// just removed.
    private func removePendingFile(_ itemId: String) {
        let url = downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
            .appendingPathComponent(Self.pendingFilename)
        try? fileManager.removeItem(at: url)
    }

    private func writePendingState(_ itemId: String) {
        guard let metadata = pendingMetadata[itemId], !metadata.tracks.isEmpty else { return }
        let state = WatchPendingDownloadState(
            itemId: itemId, title: metadata.title, author: metadata.author,
            duration: metadata.duration, tracks: metadata.tracks,
            chapters: pendingChapters[itemId], serverProgress: pendingServerProgress[itemId])
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: pendingURL(itemId), options: .atomic)
    }

    /// Loads `pending.json` back into the in-memory dictionaries (arming the item) when
    /// they are missing, i.e. after a relaunch. Returns whether the item is armed.
    @discardableResult
    private func restorePendingStateIfNeeded(_ itemId: String) -> Bool {
        if expectedTrackCounts[itemId] != nil, pendingMetadata[itemId]?.tracks.isEmpty == false { return true }
        let url = downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
            .appendingPathComponent(Self.pendingFilename)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WatchPendingDownloadState.self, from: data),
              state.itemId == itemId, !state.tracks.isEmpty else { return false }
        expectedTrackCounts[itemId] = state.tracks.count
        pendingMetadata[itemId] = (state.title, state.author, state.duration, state.tracks)
        pendingChapters[itemId] = state.chapters
        pendingServerProgress[itemId] = state.serverProgress
        return true
    }

    /// Indices of the pending item's tracks whose file is on disk and non-empty. A track
    /// file only appears here via `didFinishDownloadingTo`'s move, after its integrity
    /// and status checks, so presence means that track finished.
    private func presentTrackIndices(_ itemId: String) -> Set<Int> {
        guard let tracks = pendingMetadata[itemId]?.tracks else { return [] }
        let dir = downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
        var present: Set<Int> = []
        for track in tracks {
            let path = dir.appendingPathComponent(track.filename).path
            if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64, size > 0 {
                present.insert(track.index)
            }
        }
        return present
    }

    /// Writes the manifest for an armed item whose tracks are all on disk, then clears its
    /// pending state (memory and `pending.json`). Shared by the delegate completion and
    /// the launch reconciliation.
    private func completePendingDownload(itemId: String) {
        guard let metadata = pendingMetadata[itemId] else { return }
        let dir = downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
        var totalBytes: Int64 = 0
        for track in metadata.tracks {
            let url = dir.appendingPathComponent(track.filename)
            totalBytes += (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        let download = WatchLocalDownload(
            id: itemId, title: metadata.title, author: metadata.author,
            duration: metadata.duration, tracks: metadata.tracks,
            totalBytes: totalBytes, chapters: pendingChapters[itemId],
            serverProgress: pendingServerProgress[itemId], downloadedAt: Date())
        writeManifest(download)
        removePendingFile(itemId)
        expectedTrackCounts[itemId] = nil
        pendingMetadata[itemId] = nil
        pendingChapters[itemId] = nil
        pendingServerProgress[itemId] = nil
    }

    /// Fixed filename per item directory, matching the phone's own `DownloadManager
    /// .localCoverURL` convention (`cover.jpg`, not a hashed name — unlike
    /// `DiskCoverCache`, which is a rebuildable cache, this is a permanent artifact
    /// tied to a specific download, same distinction that type's own doc comment
    /// draws for the phone).
    func localCoverURL(itemId: String) -> URL? {
        guard downloads[itemId] != nil else { return nil }
        let url = itemDirectory(itemId).appendingPathComponent("cover.jpg")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func localAudioURL(itemId: String, trackIndex: Int) -> URL? {
        guard let download = downloads[itemId],
              let track = download.tracks.first(where: { $0.index == trackIndex }) else { return nil }
        let url = itemDirectory(itemId).appendingPathComponent(track.filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Ordered list of local track URLs for a fully-downloaded item, in `index` order
    /// — what `StandaloneAudioEngine` needs to build its player without touching the
    /// network at all. `nil` if anything's missing (a partially-cleaned-up download,
    /// or one whose manifest says downloaded but a file was removed out-of-band).
    func localTrackURLs(itemId: String) -> [(index: Int, url: URL, duration: Double, startOffset: Double)]? {
        guard let download = downloads[itemId], states[itemId] == .downloaded else { return nil }
        var result: [(index: Int, url: URL, duration: Double, startOffset: Double)] = []
        for track in download.tracks.sorted(by: { $0.index < $1.index }) {
            guard let url = localAudioURL(itemId: itemId, trackIndex: track.index) else { return nil }
            result.append((track.index, url, track.duration, track.startOffset))
        }
        return result
    }

    func isDownloaded(itemId: String) -> Bool { states[itemId] == .downloaded }

    /// PL-4 follow-up: the chapters saved with a downloaded book, or empty when it has none
    /// (a download made before chapters were recorded, or a book without chapter data).
    func localChapters(itemId: String) -> [WatchChapter] {
        downloads[itemId]?.chapters ?? []
    }

    /// Critique 2026-10-06 (harden): the server's last known position for a downloaded
    /// book, from its manifest. `nil` for a book downloaded before this was recorded.
    func serverProgress(itemId: String) -> WatchServerProgress? {
        downloads[itemId]?.serverProgress
    }

    /// Critique 2026-10-06 (harden): stores a fresher server reading in the manifest, so
    /// the next offline play (and the root hero) starts from it. Ignored when it isn't
    /// newer than what's stored, or the book isn't downloaded.
    func recordServerProgress(itemId: String, _ progress: WatchServerProgress) {
        guard var download = downloads[itemId], states[itemId] == .downloaded else { return }
        guard WatchServerProgressPicker.newest([progress, download.serverProgress]) == progress,
              progress != download.serverProgress else { return }
        download.serverProgress = progress
        guard let data = try? JSONEncoder().encode(download) else { return }
        try? data.write(to: manifestURL(itemId), options: .atomic)
        downloads[itemId] = download
    }

    /// UX fix (31 August 2026): title/author for an item that isn't fully downloaded
    /// yet (queued/downloading/failed) — `downloads[itemId]` only gets an entry once
    /// a download completes (`writeManifest`), so a UI showing in-flight state (see
    /// `StandaloneDownloadsView`'s in-progress section) needs a different source.
    /// Exposes only the two fields a row actually needs, not `pendingMetadata`
    /// itself — that dictionary's tuple shape (duration, tracks too) is this
    /// manager's own internal bookkeeping, not part of its public surface.
    func pendingTitleAuthor(for itemId: String) -> (title: String, author: String)? {
        guard let metadata = pendingMetadata[itemId] else { return nil }
        return (metadata.title, metadata.author)
    }

    // MARK: - Starting a download

    /// Opens its own playback session (separate from whatever `StandaloneAudioEngine`
    /// might also have open for the same item — Audiobookshelf's `/play` endpoint is
    /// stateless bookkeeping per §10.1's own finding, so two independent sessions for
    /// the same item is not a conflict) purely to get track `contentUrl`s and a cover.
    /// Like the playback engine, never calls `syncSession`/`closeSession` on it.
    /// Whether a Download/Retry tap should actually start a transfer, given the item's
    /// current state.
    ///
    /// Fix (MEDIUM, 9 September 2026 review — "second Download tap re-queues the same
    /// item"): the guard here used to be `states[itemId] != .downloading(progress: 0)`,
    /// which — because `WatchLocalDownloadState` is `Equatable` over its *payload* —
    /// only matched a download sitting at exactly zero progress. A tap while the item
    /// was `.queued`, or `.downloading(progress: 0.4)`, sailed straight through and
    /// opened a second playback session, enqueued a second set of track tasks writing
    /// to the same filenames, and reset `expectedTrackCounts`
    /// under the first attempt. Now decided on the *case*, not the payload.
    ///
    /// `nonisolated static` and pure so it can be pinned by the Watch test target
    /// (`WatchLocalDownloadDecisionTests`) — same convention as
    /// `StandaloneAudioEngine.resumePosition(...)` and the phone's
    /// `DownloadManager.shouldReclaimOrphanDirectory`.
    ///
    /// `.failed` is startable on purpose: that's the Retry action
    /// (`StandaloneLibraryView.downloadSwipeAction(for:)`'s `.failed` case).
    nonisolated static func shouldStartDownload(currentState: WatchLocalDownloadState?) -> Bool {
        switch currentState {
        case .none, .notDownloaded, .failed:
            return true
        case .queued, .downloading, .downloaded:
            return false
        }
    }

    /// What to do with a persisted pending download (`WatchPendingDownloadState`).
    nonisolated enum PendingDownloadAction: Equatable {
        /// Every expected track file is on disk: write the manifest.
        case writeManifest
        /// Tracks are missing but a background task for the item is still live.
        case keepWaiting
        /// Tracks are missing and nothing is transferring: surface the existing Retry.
        case markFailed
    }

    /// Review finding High 7 (30 October 2026): decides a pending download's fate from
    /// what is on disk, not an in-memory counter that a relaunch erases. Used on every
    /// track completion (`hasLiveTask` true — more may be coming) and on launch
    /// reconciliation (`hasLiveTask` from `session.getAllTasks`).
    ///
    /// `nonisolated static` and pure so it can be pinned by the Watch test target.
    nonisolated static func pendingDownloadAction(
        expectedTrackIndices: [Int], presentTrackIndices: Set<Int>, hasLiveTask: Bool
    ) -> PendingDownloadAction {
        if !expectedTrackIndices.isEmpty, Set(expectedTrackIndices).isSubset(of: presentTrackIndices) {
            return .writeManifest
        }
        return hasLiveTask ? .keepWaiting : .markFailed
    }

    /// Critique 2026-10-06 (harden): `expectedBytes` is the book's size from the server
    /// (`WatchLibraryItem.size`) when the caller has it. A download that could only fit by
    /// removing a book part-way through is refused before anything is fetched, with the
    /// reason as the row's failure text, instead of evicting that book afterwards.
    /// Review 6 Medium 7: files a fresh attempt must delete before fetching. Empty when a
    /// manifest exists (a completed download is never touched).
    nonisolated static func staleFilenames(hasManifest: Bool, directoryContents: [String]) -> [String] {
        guard !hasManifest else { return [] }
        return directoryContents.filter {
            ($0.hasPrefix("track-") && $0.hasSuffix(".audio")) || $0 == pendingFilename
        }
    }

    func startDownload(itemId: String, title: String, author: String, expectedBytes: Int64? = nil) async {
        guard Self.shouldStartDownload(currentState: states[itemId]) else { return }
        // A fresh attempt un-abandons the item: any in-flight sibling from the
        // previous, failed attempt has already been cancelled, and leaving the id in
        // the set would make this attempt's own completions get thrown away.
        abandonedItemIds.remove(itemId)
        states[itemId] = .queued
        pendingMetadata[itemId] = (title, author, 0, [])
        // Queued first, so a second tap during the check can't start a second attempt.
        if await roomPlan(forBytes: expectedBytes) == .noRoom {
            states[itemId] = .failed(WatchDownloadRoomCopy.noRoom(title: title))
            WatchHaptics.failure()
            return
        }
        // UX fix (31 August 2026): title/author used to only get recorded once the
        // playback session resolved (below), and — on failure — the delegate's
        // `didCompleteWithError` nilled `pendingMetadata` out entirely (see that
        // handler's own comment on this same date). That left `.queued`/
        // `.downloading`/`.failed` rows with no title/author to show at all in
        // `StandaloneDownloadsView`'s new in-progress section: exactly the states a
        // user checking that screen mid-download is most likely to see. Recording it
        // immediately, from the parameters this function already received, means
        // it's never missing for the entire lifecycle of one download attempt.
        pendingMetadata[itemId] = (title, author, 0, [])

        do {
            // Funnelled through `WatchStandaloneCall` (9 September 2026) so a dead
            // session raises `WatchStore.signalSessionExpired()` instead of failing
            // the row with a generic message the user can only retry forever — see
            // that type's own doc comment.
            let session = try await WatchStandaloneCall.perform {
                try await api.startPlaybackSession(itemId: itemId)
            }
            let sortedTracks = (session.audioTracks ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            guard !sortedTracks.isEmpty else {
                states[itemId] = .failed(String(localized: "No playable audio track."))
                WatchHaptics.failure()
                return
            }

            // Review 6 Medium 7: a retry after a failed multi-track attempt kept the old
            // `track-N.audio` files, which `presentTrackIndices` counts as finished. Clear
            // them (and `pending.json`) first; never for an item that has a manifest.
            let dirURL = itemDirectory(itemId)
            let hasManifest = fileManager.fileExists(atPath: manifestURL(itemId).path)
            let staleNames = Self.staleFilenames(hasManifest: hasManifest,
                                                 directoryContents: (try? fileManager.contentsOfDirectory(atPath: dirURL.path)) ?? [])
            // Review 7 Low (stale files): a background task restored after relaunch may still be
            // writing these files; cancel the item's live tasks before deleting under them.
            if !staleNames.isEmpty { cancelTasks(forItemId: itemId) }
            for name in staleNames {
                try? fileManager.removeItem(at: dirURL.appendingPathComponent(name))
            }

            var localTracks: [WatchLocalDownload.Track] = []
            var offset: Double = 0
            expectedTrackCounts[itemId] = sortedTracks.count
            // UX fix (31 August 2026): this used to reset `pendingMetadata[itemId]`
            // to `nil` here, immediately discarding the title/author just recorded
            // above — harmless before, since nothing read `pendingMetadata` until
            // the full tuple was written back a few lines down, but now that title/
            // author are set for the entire lifecycle of a download attempt (see
            // this function's own opening comment), clearing it here would just
            // reintroduce the exact gap that comment describes for the brief window
            // between now and the write below.

            var tasksToResume: [URLSessionDownloadTask] = []
            for track in sortedTracks {
                let filename = "track-\(track.index ?? 0).audio"
                localTracks.append(WatchLocalDownload.Track(
                    index: track.index ?? 0, filename: filename,
                    duration: track.duration ?? 0, startOffset: offset))
                offset += track.duration ?? 0

                guard let contentUrl = track.contentUrl,
                      let url = URL(string: "\(api.serverURL)\(contentUrl)") else { continue }
                var request = AuthStore.shared.authorizedRequest(url: url)
                request.timeoutInterval = 60
                let downloadTask = self.session.downloadTask(with: request)
                downloadTask.taskDescription = Self.taskDescription(itemId: itemId, trackIndex: track.index ?? 0)
                tasksToResume.append(downloadTask)
            }

            pendingMetadata[itemId] = (title, author, session.duration ?? offset, localTracks)
            pendingChapters[itemId] = (session.chapters ?? []).sorted { $0.start < $1.start }
            // Critique 2026-10-06 (harden): the session response carries the server's
            // own resume point for this book; keep it for offline plays.
            if let time = session.currentTime {
                pendingServerProgress[itemId] = WatchServerProgress(
                    currentTime: time,
                    lastUpdateMs: session.libraryItem?.mediaProgress?.lastUpdate.map(Double.init))
            }
            // Persisted before any task starts (review finding High 7, 30 October 2026) so a
            // relaunch mid-download can still write the manifest.
            writePendingState(itemId)
            for task in tasksToResume { task.resume() }
            states[itemId] = .downloading(progress: 0)

            // Cover: best-effort, not tracked toward "all tracks complete" — a
            // missing cover shouldn't block marking the book downloaded and playable.
            if let coverURL = api.coverURL(itemId: itemId, width: 400) {
                let request = AuthStore.shared.authorizedRequest(url: coverURL)
                let coverTask = self.session.downloadTask(with: request)
                coverTask.taskDescription = Self.taskDescription(itemId: itemId, trackIndex: nil)
                coverTask.resume()
            }
        } catch {
            states[itemId] = .failed((error as? WatchAPIError)?.errorDescription ?? String(localized: "Couldn't start download."))
            WatchHaptics.failure()
        }
    }

    /// Cancels every in-flight task belonging to one item (tracks *and* its cover).
    ///
    /// Extracted from `cancelDownload(itemId:)` (9 September 2026) so the failure
    /// paths can use it too — an integrity or HTTP failure used to leave the item's
    /// sibling tracks downloading happily into a directory it had just deleted.
    private func cancelTasks(forItemId itemId: String) {
        // `Self.parseTaskContext` is `static` — no `self` capture, no actor
        // isolation to satisfy inside this `@Sendable` completion handler.
        session.getAllTasks { tasks in
            for task in tasks where Self.parseTaskContext(task)?.itemId == itemId {
                task.cancel()
            }
        }
    }

    /// Abandons one item's in-flight download: stops its siblings, makes a later
    /// sibling completion incapable of writing a manifest or firing the success
    /// haptic, and (optionally) removes what's on disk.
    ///
    /// Fix (MEDIUM, 9 September 2026 review): the integrity-failure branch in
    /// `didFinishDownloadingTo` used to set `.failed`, delete the item directory, and
    /// return — leaving `expectedTrackCounts` intact and every
    /// sibling task still running. The last sibling to finish then hit the success
    /// path, wrote `manifest.json` into a directory holding only its own track, fired
    /// `WatchHaptics.success()`, and marked a gutted book `.downloaded` and playable.
    /// Clearing the counters here is the actual fix (the success path is gated on
    /// `expectedTrackCounts[itemId]` being present); the cancel and the abandoned-set
    /// entry keep the disk tidy while the asynchronous cancel lands.
    ///
    /// `pendingMetadata` is deliberately **kept**: the 31 August 2026 UX fix relies on
    /// it for the title/author of a failed row (`StandaloneDownloadsView`'s
    /// in-progress section, `StandaloneLibraryView`'s accessibility label), it is only
    /// ever *read for display*, and the success path can no longer be reached without
    /// `expectedTrackCounts`. `cancelDownload(itemId:)` — an explicit user action —
    /// remains the thing that clears it.
    private func abandonDownload(itemId: String, reason: String?, removingFiles: Bool) {
        cancelTasks(forItemId: itemId)
        abandonedItemIds.insert(itemId)
        expectedTrackCounts[itemId] = nil
        // A given-up download must not be resurrected by the launch reconciliation.
        removePendingFile(itemId)
        if let reason {
            states[itemId] = .failed(reason)
            WatchHaptics.failure()
        }
        if removingFiles {
            try? fileManager.removeItem(at: itemDirectory(itemId))
        }
    }

    func cancelDownload(itemId: String) {
        abandonDownload(itemId: itemId, reason: nil, removingFiles: true)
        states[itemId] = .notDownloaded
        pendingMetadata[itemId] = nil
        pendingChapters[itemId] = nil
        pendingServerProgress[itemId] = nil
    }

    func removeDownload(itemId: String) {
        // Review Medium 36 (30 October 2026): deleting the files of the book the engine is
        // playing pulled them from under the player. Stop it first (`WatchStore.shared` is
        // already how this manager reaches the progress coordinator).
        let engine = WatchStore.shared.standalone
        if engine.isLoaded, engine.currentItemId == itemId { engine.stop() }
        try? fileManager.removeItem(at: itemDirectory(itemId))
        downloads[itemId] = nil
        states[itemId] = .notDownloaded
        recomputeTotalBytesUsed()
    }

    // MARK: - Manifests

    private func loadManifests() {
        guard let entries = try? fileManager.contentsOfDirectory(at: downloadsRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let manifestPath = entry.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestPath),
                  let download = try? JSONDecoder().decode(WatchLocalDownload.self, from: data) else { continue }
            downloads[download.id] = download
            states[download.id] = .downloaded
        }
        recomputeTotalBytesUsed()
    }

    /// Launch reconciliation for downloads interrupted by a kill/relaunch (review finding
    /// High 7, 30 October 2026): any item directory with `pending.json` and no manifest
    /// is resolved by `pendingDownloadAction` against the files on disk and the session's
    /// live tasks. Failure reuses the existing `.failed` state, so the row offers Retry.
    /// `pending.json` is left in place on failure so a late redelivered completion can
    /// still finish the book.
    private func reconcilePendingDownloads() {
        guard let entries = try? fileManager.contentsOfDirectory(at: downloadsRoot, includingPropertiesForKeys: nil) else { return }
        let candidates = entries.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent(Self.pendingFilename).path)
                && !fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }.map(\.lastPathComponent)
        guard !candidates.isEmpty else { return }
        session.getAllTasks { [weak self] tasks in
            var live: Set<String> = []
            for task in tasks where task.state == .running || task.state == .suspended {
                if let context = Self.parseTaskContext(task), context.trackIndex != nil { live.insert(context.itemId) }
            }
            let liveItems = live
            Task { @MainActor [weak self] in
                guard let self else { return }
                for itemId in candidates where self.downloads[itemId] == nil {
                    guard self.restorePendingStateIfNeeded(itemId),
                          let tracks = self.pendingMetadata[itemId]?.tracks else { continue }
                    switch Self.pendingDownloadAction(
                        expectedTrackIndices: tracks.map(\.index),
                        presentTrackIndices: self.presentTrackIndices(itemId),
                        hasLiveTask: liveItems.contains(itemId)) {
                    case .writeManifest:
                        self.completePendingDownload(itemId: itemId)
                    case .keepWaiting:
                        self.states[itemId] = .downloading(progress: 0)
                    case .markFailed:
                        self.states[itemId] = .failed(String(localized: "Couldn't start download."))
                    }
                }
            }
        }
    }

    private func writeManifest(_ download: WatchLocalDownload) {
        guard let data = try? JSONEncoder().encode(download) else { return }
        try? data.write(to: manifestURL(download.id), options: .atomic)
        downloads[download.id] = download
        states[download.id] = .downloaded
        recomputeTotalBytesUsed()
        evictIfNeeded(newItemId: download.id)
    }

    private func recomputeTotalBytesUsed() {
        totalBytesUsed = downloads.values.reduce(0) { $0 + $1.totalBytes }
    }

    // MARK: - Storage cap (public-release amendment §9.4)

    /// Build-fix (28 August 2026, first real Xcode build): `.volumeAvailableCapacityForImportantUsageKey`
    /// — the "important but evictable" semantics Apple's own on-device media caches
    /// use — does not exist on watchOS at all; the real compiler rejected it
    /// outright ("'volumeAvailableCapacityForImportantUsageKey' is unavailable in
    /// watchOS"), which is stronger evidence than the `[device check]` this file
    /// originally shipped with. Fell back to the plain `.volumeAvailableCapacityKey`
    /// (`URLResourceValues.volumeAvailableCapacity`) — a basic, universally-available
    /// filesystem resource key with no platform-specific "usage class" semantics.
    /// This changes *which* number gets reported (plain free space, not a
    /// tier-adjusted "importantly available" figure some platforms compute
    /// specially), but not the actual requirement it satisfies: §9.4 asks for the
    /// cap to derive from real, runtime-queried available storage, which this still
    /// does. Refreshed at launch and after every completed download, not on a
    /// timer — storage doesn't change fast enough on a Watch to need polling.
    func refreshAvailableCapacity() {
        let values = try? downloadsRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        availableCapacityBytes = values?.volumeAvailableCapacity.map { Int64($0) }
    }

    /// The cap itself: the *smaller* of a fixed ceiling (500MB — generous for spoken
    /// audio, conservative for a device this size) and half of whatever's actually
    /// free right now. Neither number alone satisfies §9.4's instruction on its own —
    /// a pure fixed constant is exactly what was flagged as wrong (tuned to one
    /// Watch's own free space), and a pure fraction-of-available number with no
    /// ceiling would let downloads balloon on a Watch that happens to have a mostly
    /// empty 64GB model. Taking the minimum of both satisfies "derives from actual
    /// available storage at runtime" without also being unbounded.
    private var effectiveCapBytes: Int64 {
        refreshAvailableCapacity()
        // Critique 2026-10-06 (harden): one formula, shared with the before-download
        // check (`WatchDownloadCap`).
        return WatchDownloadCap.capBytes(availableBytes: availableCapacityBytes)
    }

    /// Which downloads to evict, oldest-first, to get back under `capBytes` — never
    /// including `protectedItemId`.
    ///
    /// Fix (MEDIUM, 9 September 2026 review — "eviction can delete the currently-playing
    /// download"): oldest-finished-first is exactly the wrong order for the one item
    /// the user is listening to right now, since a book downloaded weeks ago and only
    /// now being played is the *oldest* candidate. Deleting its files under a live
    /// `AVQueuePlayer` fails playback mid-sentence and leaves `states[itemId]` at
    /// `.notDownloaded` for a book that's on screen playing.
    ///
    /// If the protected item is the only thing left to evict, the cap stays slightly
    /// exceeded. That's the intended trade and matches the review's instruction: the
    /// cap is a soft budget derived from free space (see `effectiveCapBytes`), and
    /// overshooting it by one book is strictly better than breaking playback. The next
    /// completed download re-runs this, so the overshoot resolves as soon as the
    /// protected item stops being the current one.
    ///
    /// `nonisolated static` and pure so it can be pinned by the Watch test target.
    ///
    /// Critique 2026-10-06 (shape → harden): the doc above promised "oldest-finished-
    /// first", but nothing checked finished, so downloading tomorrow's book could quietly
    /// remove today's half-finished one. The order is now finished books (oldest first),
    /// then unstarted ones, and **never** a book part-way through (`listening`,
    /// `WatchDownloadListening`). A book with no entry in `listening` is treated as
    /// unknown and kept too: deleting what we can't classify is the failure being fixed.
    /// `protectedItemIds` covers the loaded book and the one that just finished
    /// downloading. When the cap can't be met without an in-progress book it stays
    /// exceeded; the before-download check (`WatchDownloadRoomPlan`) refuses that case
    /// up front with a message.
    nonisolated static func evictionVictims(
        downloads: [WatchLocalDownload], totalBytesUsed: Int64, capBytes: Int64,
        protectedItemIds: Set<String>, listening: [String: WatchDownloadListening]
    ) -> [String] {
        guard totalBytesUsed > capBytes else { return [] }
        let ranked: [(download: WatchLocalDownload, rank: Int)] = downloads.compactMap { download in
            guard !protectedItemIds.contains(download.id),
                  let rank = listening[download.id]?.evictionRank else { return nil }
            return (download, rank)
        }
        let ordered = ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.download.downloadedAt != b.download.downloadedAt { return a.download.downloadedAt < b.download.downloadedAt }
            return a.download.id < b.download.id
        }
        var remaining = totalBytesUsed
        var victims: [String] = []
        for entry in ordered {
            guard remaining > capBytes else { break }
            victims.append(entry.download.id)
            remaining -= entry.download.totalBytes
        }
        return victims
    }

    /// Critique 2026-10-06 (harden): what eviction last removed, said once on screen
    /// ("Removed “X” to make room.") on the book that caused it and on "On This Watch".
    /// Cleared by `dismissEvictionNotice()`.
    struct EvictionNotice: Equatable, Identifiable {
        let id = UUID()
        /// The download that needed the room.
        let forItemId: String
        let removedTitles: [String]
        var message: String { WatchDownloadRoomCopy.removed(titles: removedTitles) }
    }

    private(set) var evictionNotice: EvictionNotice?

    func dismissEvictionNotice() { evictionNotice = nil }

    /// Critique 2026-10-06 (harden): where each downloaded book stands — finished,
    /// unstarted or part-way — from this Watch's own last position and the server's (the
    /// manifest's reading), newest wins. Async because this Watch's positions live in an
    /// actor (`WatchPendingProgressQueue`).
    func listeningStates() async -> [String: WatchDownloadListening] {
        let progressSync = WatchStore.shared.progressSync
        var result: [String: WatchDownloadListening] = [:]
        for (itemId, download) in downloads {
            let local = await progressSync.lastKnownLocalProgress(itemId: itemId)
            result[itemId] = WatchDownloadListening.classify(
                server: download.serverProgress, localTime: local?.currentTime,
                localUpdatedAtMs: local?.updatedAt, duration: download.duration)
        }
        return result
    }

    /// The loaded book, which eviction never touches.
    private var loadedItemIds: Set<String> {
        let engine = WatchStore.shared.standalone
        guard engine.isLoaded, let id = engine.currentItemId else { return [] }
        return [id]
    }

    /// Critique 2026-10-06 (harden): the before-download check, for a book of
    /// `bytes` (`nil` when the server didn't say: nothing to check, so it's allowed and
    /// the after-download eviction still never takes an in-progress book).
    func roomPlan(forBytes bytes: Int64?) async -> WatchDownloadRoomPlan {
        guard let bytes, bytes > 0 else { return .fits }
        refreshAvailableCapacity()
        let cap = WatchDownloadCap.capBytes(availableBytes: availableCapacityBytes, pendingBytes: bytes)
        let listening = await listeningStates()
        return WatchDownloadRoomPlan.plan(newBytes: bytes, downloads: Array(downloads.values), capBytes: cap,
                                          protectedItemIds: loadedItemIds, listening: listening)
    }

    /// Room for downloads right now: the cap less what's used. For the detail screen's
    /// "320 MB · 180 MB free for downloads".
    var roomForDownloadsBytes: Int64 {
        max(0, WatchDownloadCap.capBytes(availableBytes: availableCapacityBytes) - totalBytesUsed)
    }

    private func evictIfNeeded(newItemId: String) {
        // `WatchStore.shared` is safe to reach here: `evictIfNeeded()` only ever runs
        // from `writeManifest(_:)` (a completed download), long after every singleton
        // has been constructed — this manager's own `init` never calls it, so there's
        // no static-initialisation cycle between the two types.
        //
        // Critique 2026-10-06 (harden): async now (positions live in an actor), and it
        // protects the book that just finished downloading as well as the loaded one.
        Task { @MainActor in
            let listening = await listeningStates()
            let victims = Self.evictionVictims(
                downloads: Array(downloads.values), totalBytesUsed: totalBytesUsed,
                capBytes: effectiveCapBytes, protectedItemIds: loadedItemIds.union([newItemId]),
                listening: listening)
            guard !victims.isEmpty else { return }
            let titles = victims.compactMap { downloads[$0]?.title }
            for itemId in victims {
                removeDownload(itemId: itemId)
            }
            evictionNotice = EvictionNotice(forItemId: newItemId, removedTitles: titles)
        }
    }

    // MARK: - Background relaunch (`WKURLSessionRefreshBackgroundTask`)

    /// Reattaches this process to the background session and holds the system's
    /// background task open until its events have been delivered.
    ///
    /// Fix (HIGH, 9 September 2026 review — "background download session has no
    /// `WKURLSessionRefreshBackgroundTask` handler"): `sessionSendsLaunchEvents = true`
    /// asks watchOS to relaunch this app when a transfer finishes while it isn't
    /// running, but nothing implemented `WKApplicationDelegate.handle(_:)`, so the
    /// event had nowhere to go. See `WatchAppDelegate`.
    ///
    /// Reattachment is implicit rather than a separate step: reaching
    /// `WatchLocalDownloadManager.shared` at all runs `init`, which recreates a
    /// `URLSession` with the *same* identifier and `self` as its delegate — that is
    /// what makes the OS redeliver the finished tasks to
    /// `didFinishDownloadingTo`/`didCompleteWithError`. Touching `session` below
    /// makes that dependency explicit at the point it matters instead of leaving it
    /// as a side effect of the call.
    func handleBackgroundSessionEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else {
            // Not ours (a stale identifier from an older build, say) — completing
            // immediately is the only correct answer; holding a task open for a
            // session that will never report events is what burns the app's
            // background budget.
            completion()
            return
        }
        _ = session
        backgroundEventCompletions[identifier, default: []].append(completion)
        // Watchdog: if the session never calls back (its events were already drained
        // before this launch, say), the task still has to be completed or watchOS
        // counts it against this app. 25s is comfortably inside the few-seconds-to-
        // tens-of-seconds budget a URL-session refresh task gets, and well past the
        // time moving a handful of files and writing one manifest takes.
        // **[device check]** — the exact budget isn't documented and hasn't been
        // measured on hardware here.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
            self?.completeBackgroundEvents(identifier: identifier)
        }
    }

    /// Runs and clears every held completion for one session identifier. Idempotent:
    /// whichever of `urlSessionDidFinishEvents` and the watchdog gets here first wins,
    /// and the second finds nothing to do.
    private func completeBackgroundEvents(identifier: String) {
        guard let completions = backgroundEventCompletions.removeValue(forKey: identifier) else { return }
        for completion in completions { completion() }
    }

    // MARK: - Response acceptance & integrity check

    /// How a finished transfer's HTTP status should be treated.
    nonisolated enum DownloadAcceptance: Equatable {
        case accept
        case sessionExpired
        case rejected(statusCode: Int)
    }

    /// Whether a finished transfer's HTTP status means the bytes at `location` can be
    /// treated as an audio file at all.
    ///
    /// Fix (HIGH, 9 September 2026 review — "download completion accepts an HTTP error
    /// body as an audio track"): `didFinishDownloadingTo` never looked at
    /// `downloadTask.response`. A background download "succeeds" for any status code
    /// — 401, 403, 404, 502 — and the error body gets moved into place as
    /// `track-N.audio`. `integrityFailureReason(at:expectedBytes:)` caught *some* of
    /// those by sniffing a leading `<` or `{`, but a plain-text or empty-ish error
    /// body of the right length slipped through and, if it was the last track, marked
    /// the whole book downloaded and playable. The phone has checked this since it
    /// was written (`ShelfHead/Services/DownloadManager.swift:44–50`); the Watch
    /// simply never got the same guard.
    ///
    /// 401 is called out separately, as it is on the phone — the difference is what
    /// can be done about it. The phone re-enqueues the track after a token refresh;
    /// this Watch's background delegate can't `await` a refresh (that's why these
    /// requests bypass `WatchAudiobookshelfAPI.send` in the first place — see
    /// `CLAUDE.md`'s recognised exceptions), so the honest answer is to fail the item
    /// and raise the session-expired flag so the user is offered a re-handoff or a
    /// manual sign-in instead of an infinitely retryable "Server returned HTTP 401."
    ///
    /// `nonisolated static` and pure so it can be pinned by the Watch test target.
    nonisolated static func acceptance(forStatusCode statusCode: Int) -> DownloadAcceptance {
        if (200...299).contains(statusCode) { return .accept }
        if statusCode == 401 { return .sessionExpired }
        return .rejected(statusCode: statusCode)
    }

    /// What a `.sessionExpired` download response should actually do — Item 21 (9
    /// September 2026 review, "a mid-download 401 hard-fails the item AND flips
    /// authState"). `acceptance(forStatusCode:)` above treats any 401 as evidence the
    /// session is gone, but a reverse proxy in front of Audiobookshelf can gate
    /// media/download URLs differently from the JSON API — a 401 on a track download
    /// while `/api/me` still authenticates fine is a server refusing *that file*, not
    /// an expired session. Since Batch 312, `WatchStore.signalSessionExpired()` also
    /// triggers an automatic re-handoff request to the phone, so treating that case
    /// as a real expiry no longer just shows a spurious "signed out" — it also
    /// churns the phone on every such 401.
    ///
    /// `apiStillAuthenticates` is the result of a cheap authenticated probe
    /// (`WatchAudiobookshelfAPI.verifySessionStillAuthenticates()`) run *before* this
    /// decision is made, so this function itself stays pure and testable — same
    /// split as `acceptance(forStatusCode:)` deciding on a status code someone else
    /// already read off the response.
    nonisolated enum DownloadAuthFailureAction: Equatable {
        /// The probe also failed — the session really is gone. Fail the download and
        /// raise `signalSessionExpired()`.
        case signOutAndFailDownload
        /// The probe succeeded — only this media URL returned 401. Fail just this
        /// download ("the server refused this file"); the session stays intact.
        case failDownloadOnly
        /// Review 2 Medium 6: the probe couldn't tell (offline, timeout, refresh couldn't
        /// complete). Fail just this download with Retry; never sign out on a guess.
        case failDownloadAskRetry
    }

    /// `nonisolated static` and pure so it can be pinned by the Watch test target.
    nonisolated static func downloadAuthFailureAction(sessionProbe: WatchSessionProbeResult) -> DownloadAuthFailureAction {
        switch sessionProbe {
        case .authenticated: return .failDownloadOnly
        case .rejected: return .signOutAndFailDownload
        case .unknown: return .failDownloadAskRetry
        }
    }

    /// Re-implements the phone's `DownloadSessionDelegate.integrityFailureReason`/
    /// `DownloadManager.fileHealthIssue` *logic* (`DownloadManager.swift:100–143,
    /// 974`) rather than sharing that file directly — those functions are private to
    /// a 2143-line file mixing in plenty of main-app-only concerns (the account-scope
    /// manifest layout, `UIDevice.current.batteryState` charging-only policy, etc.).
    /// Confirmed pure `Foundation` (`FileHandle`, no `UIKit`), so the *checks
    /// themselves* — zero-byte file, size mismatch against `Content-Length`, and a
    /// byte-sniff for a leading `<`/`{` (an HTML/JSON error page delivered with a 200,
    /// not actual audio) — carry over exactly; only the surrounding file was too
    /// entangled with phone-only state to import wholesale.
    private func integrityFailureReason(at url: URL, expectedBytes: Int64?) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return String(localized: "Downloaded file is missing.")
        }
        guard size > 0 else { return String(localized: "Downloaded file is empty.") }
        if let expectedBytes, expectedBytes > 0, size != expectedBytes {
            return String(localized: "Downloaded file size doesn't match the server's reported size.")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let firstByte = try? handle.read(upToCount: 1)?.first else { return nil }
        if firstByte == UInt8(ascii: "<") || firstByte == UInt8(ascii: "{") {
            return String(localized: "Server returned an error page instead of an audio file.")
        }
        return nil
    }
}

// MARK: - URLSessionDownloadDelegate

extension WatchLocalDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // `Self.parseTaskContext` reads `downloadTask.taskDescription` synchronously
        // — no actor hop needed just to know which item/track this is (see that
        // method's own doc comment on why this replaced a MainActor-isolated
        // dictionary lookup here).
        guard let context = Self.parseTaskContext(downloadTask),
              context.trackIndex != nil, totalBytesExpectedToWrite > 0 else { return }
        // Coarse progress: bytes written for *this* track against its own
        // expected size — not a true whole-item percentage across every track,
        // since sizes aren't known for tracks that haven't started yet. Good
        // enough for a progress bar; not claimed to be more precise than that.
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            // Review Medium 37 (30 October 2026): a late callback must not flip an abandoned
            // (failed/cancelled) item back to Downloading, which hides Retry. Only armed,
            // non-abandoned items take progress.
            guard !self.abandonedItemIds.contains(context.itemId),
                  self.expectedTrackCounts[context.itemId] != nil else { return }
            self.states[context.itemId] = .downloading(progress: progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must move the file synchronously, on this callback, before it returns — the
        // system deletes `location` immediately after. Everything else (manifest
        // update, state, integrity check) can hop to the main actor.
        guard let context = Self.parseTaskContext(downloadTask) else { return }
        // Status code first: a 401/404/502 body is not an audio file, and moving it
        // into place at all is what let it be counted as a completed track (see
        // `acceptance(forStatusCode:)`). The temp file is simply left for the system
        // to delete.
        if let http = downloadTask.response as? HTTPURLResponse {
            switch Self.acceptance(forStatusCode: http.statusCode) {
            case .accept:
                break
            case .sessionExpired:
                Task { @MainActor in
                    // Item 21 (9 September 2026 review): this used to raise
                    // `signalSessionExpired()` unconditionally on any 401 — but a
                    // reverse proxy can gate media/download URLs differently from the
                    // JSON API, so a 401 here doesn't necessarily mean the session
                    // itself is gone. Verify with a cheap authenticated call before
                    // deciding: if the API still authenticates, this is the server
                    // refusing *this file*, not an expired session, and since Batch
                    // 312 a false expiry also triggers an automatic re-handoff from
                    // the phone — a cost this check now avoids paying needlessly.
                    let probe = await self.api.verifySessionStillAuthenticates()
                    switch Self.downloadAuthFailureAction(sessionProbe: probe) {
                    case .signOutAndFailDownload:
                        // A failed *cover* fetch never fails the whole download (same
                        // rule as `didCompleteWithError`), but it's still evidence the
                        // session is gone, so the flag is raised either way.
                        if context.trackIndex != nil {
                            self.abandonDownload(
                                itemId: context.itemId,
                                reason: String(localized: "Your session expired — sign in again, then retry this download."),
                                removingFiles: true)
                        }
                        WatchStore.shared.signalSessionExpired()
                    case .failDownloadAskRetry:
                        // Review 2 Medium 6 (30 October 2026): couldn't verify, so don't sign out.
                        if context.trackIndex != nil {
                            self.abandonDownload(
                                itemId: context.itemId,
                                reason: String(localized: "Couldn't confirm your session — check the connection, then retry this download."),
                                removingFiles: true)
                        }
                    case .failDownloadOnly:
                        if context.trackIndex != nil {
                            self.abandonDownload(
                                itemId: context.itemId,
                                reason: String(localized: "The server refused this file, but your session is still signed in — try downloading again."),
                                removingFiles: true)
                        }
                    }
                }
                return
            case .rejected(let statusCode):
                Task { @MainActor in
                    guard context.trackIndex != nil else { return }
                    // Polish pass: the code was shown to the listener; it is logged instead.
                    Self.log.error("download rejected by server, status \(statusCode)")
                    self.abandonDownload(
                        itemId: context.itemId,
                        reason: Self.rejectedDownloadReason(),
                        removingFiles: true)
                }
                return
            }
        }
        let destinationName = context.trackIndex != nil ? "track-\(context.trackIndex!).audio" : "cover.jpg"
        let itemId = context.itemId
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(itemId, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(destinationName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in
                // Routed through `abandonDownload` (9 September 2026) for the same
                // reason as the integrity branch below: a track that can't be saved
                // must not leave its siblings downloading toward a success path that
                // can never legitimately complete.
                self.abandonDownload(itemId: itemId, reason: String(localized: "Couldn't save the downloaded file."), removingFiles: false)
            }
            return
        }

        let expectedBytes = downloadTask.response?.expectedContentLength
        Task { @MainActor in
            // An abandoned item's stragglers get their file deleted rather than left
            // in a directory nothing will ever write a manifest for — see
            // `abandonedItemIds`. Checked before anything else, since every branch
            // below is meaningless for a download that's already been given up on.
            if self.abandonedItemIds.contains(itemId) {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            if context.trackIndex != nil, let reason = self.integrityFailureReason(at: destination, expectedBytes: expectedBytes) {
                // Was: set `.failed`, delete the directory, return — with the sibling
                // tasks still running and the counters still armed. See
                // `abandonDownload(itemId:reason:removingFiles:)`.
                self.abandonDownload(itemId: itemId, reason: reason, removingFiles: true)
                return
            }
            guard context.trackIndex != nil else { return }   // cover completing doesn't count toward "all tracks done"

            // Rebuilt from `pending.json` when a relaunch erased the in-memory state
            // (review finding High 7, 30 October 2026); counted from files on disk.
            guard self.restorePendingStateIfNeeded(itemId),
                  let tracks = self.pendingMetadata[itemId]?.tracks,
                  Self.pendingDownloadAction(
                      expectedTrackIndices: tracks.map(\.index),
                      presentTrackIndices: self.presentTrackIndices(itemId),
                      hasLiveTask: true) == .writeManifest else { return }

            self.completePendingDownload(itemId: itemId)
            // UI polish pass round 2 (29 August 2026): the one, single point where a
            // book transitions to fully downloaded (the pending state is cleared above, so
            // this fires exactly once per download, not once per track) — the natural
            // place for a completion haptic, distinct from `loadManifests()`'s startup
            // reconciliation of already-downloaded items, which never fires this.
            WatchHaptics.success()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let context = Self.parseTaskContext(task) else { return }
        Task { @MainActor in
            guard context.trackIndex != nil else { return }   // a failed cover fetch doesn't fail the whole download
            // A cancelled task is the *result* of abandoning an item, not a new
            // failure — without this, cancelling or failing one track would stomp the
            // real reason with "cancelled" once its siblings' cancellations arrived.
            if self.abandonedItemIds.contains(context.itemId) { return }
            // 9 September 2026: routed through `abandonDownload` so one track's
            // failure also stops its siblings, instead of leaving them downloading
            // (and burning radio and battery) for a book already showing as failed.
            // `removingFiles: false` keeps the previous behaviour of leaving what's on
            // disk alone — a retry rewrites the same deterministic filenames.
            // Polish pass: `localizedDescription` ("The operation couldn't be completed. (NSURLErrorDomain
            // error -1009.)") was shown on the row. Mapped to house-style copy; detail goes to the log.
            Self.log.error("download transfer failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            self.abandonDownload(itemId: context.itemId, reason: Self.transferFailureReason(for: error), removingFiles: false)
            // UX fix (31 August 2026): this used to also clear `pendingMetadata`
            // here, which meant a failed download's title/author vanished the
            // instant it failed — the exact moment `StandaloneDownloadsView`'s new
            // in-progress section (and `StandaloneLibraryView`'s failed-row
            // accessibility label) needs them to show *which* book failed and why.
            // Left in place now; `cancelDownload(itemId:)` (an explicit user action —
            // "Dismiss" on a failed row, or removing/retrying it) is what actually
            // clears it, not an automatic side effect of the failure itself.
        }
    }

    // MARK: - Failure copy (Polish pass)

    nonisolated private static let log = Logger(subsystem: "com.justin.ShelfHead.watchkitapp", category: "downloads")

    /// What the row says when a transfer fails: what happened, then what to do, with no error
    /// text or codes. Pure, so it can be pinned by tests.
    nonisolated static func transferFailureReason(for error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .dataNotAllowed?, .internationalRoamingOff?:
            return String(localized: "You\u{2019}re offline. Reconnect, then retry this download.")
        case .timedOut?, .cannotConnectToHost?, .cannotFindHost?, .networkConnectionLost?, .dnsLookupFailed?:
            return String(localized: "Can\u{2019}t reach your server. Check your connection and retry this download.")
        default:
            return String(localized: "This download couldn\u{2019}t finish. Retry to try again.")
        }
    }

    nonisolated static func rejectedDownloadReason() -> String {
        String(localized: "Your server couldn\u{2019}t send this file. Retry to try again.")
    }

    /// The system has finished redelivering every event for this background session
    /// after a relaunch — the point at which the held
    /// `WKURLSessionRefreshBackgroundTask` may be completed (see
    /// `handleBackgroundSessionEvents(identifier:completion:)`). Without this, the
    /// process could be suspended between the relaunch and the manifest write.
    ///
    /// The identifier is read out here, before the actor hop, so nothing captures the
    /// `URLSession` itself into the `Task`.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            self.completeBackgroundEvents(identifier: identifier)
        }
    }
}
