import Foundation
import Observation
import UIKit   // UIDevice battery state for the charging-only download policy

/// Delegate for the background download session. Forwards events to `DownloadManager`.
///
/// NOTE: TLS is validated normally (default handling). We deliberately do NOT blanket-
/// trust the server certificate — that would let anyone with a self-signed cert MITM a
/// download and capture the bearer token. The rest of the app already validates TLS via
/// `URLSession.shared`, so this keeps downloads consistent. Plain-HTTP LAN servers are
/// still reachable via the App Transport Security exception (no cert involved).
// Not `private`: `integrityFailureReason` below is pure and unit-tested directly
// (`DownloadIntegrityTests`, ARCH-4) via `@testable import ShelfHead`, which can only
// reach `internal`-or-broader declarations — `private`/`fileprivate` stay invisible
// even through `@testable`. Everything else about this type is still
// implementation detail only `DownloadManager` (same file) constructs or calls.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    /// Parse "scope|itemId|track" (or legacy "itemId|track") from a task description.
    private func parse(_ task: URLSessionTask) -> (scope: String, id: String, track: Int)? {
        guard let desc = task.taskDescription else { return nil }
        let p = desc.split(separator: "|").map(String.init)
        if p.count == 3, let t = Int(p[2]) { return (p[0], p[1], t) }
        if p.count == 2, let t = Int(p[1]) { return ("", p[0], t) }   // legacy in-flight task
        return nil
    }

    /// A task whose scope no longer matches the active account (e.g. it completed after
    /// an account switch) must not be stored into the current account.
    private func isForeignScope(_ info: (scope: String, id: String, track: Int)) -> Bool {
        !info.scope.isEmpty && info.scope != DownloadManager.shared.currentScopeKey()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = parse(downloadTask), !isForeignScope(info) else { return }
        DownloadManager.shared.trackProgress(itemId: info.id, written: totalBytesWritten, expected: totalBytesExpectedToWrite, trackIndex: info.track)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let info = parse(downloadTask) else { return }
        // Reject a completion that belongs to a different account (account switched mid-download).
        if isForeignScope(info) { downloadTask.cancel(); return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 {
                // Access token expired mid-download — refresh and re-enqueue the track
                // rather than hard-failing (audiobooks can take longer than a token's life).
                DownloadManager.shared.handleAuthFailure(itemId: info.id, trackIndex: info.track)
            } else {
                // Review Medium 25 (30 October 2026): a transient 429/5xx on one track no
                // longer fails the whole book on the first hit; it is retried a few times.
                DownloadManager.shared.handleHTTPStatusFailure(
                    itemId: info.id, trackIndex: info.track, statusCode: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) })
            }
            return
        }
        // A 200-range status code doesn't guarantee a valid audio file is actually
        // sitting at `location` — validate it before trusting it (see
        // `integrityFailureReason`) rather than moving a possibly-corrupt/wrong file
        // into place and (if it's the book's last track) marking the whole book
        // "downloaded" on the strength of it.
        if let failure = Self.integrityFailureReason(at: location, response: downloadTask.response as? HTTPURLResponse) {
            DownloadManager.shared.trackFailed(itemId: info.id, message: failure)
            return
        }
        // Must move the temp file synchronously while `location` is still valid.
        DownloadManager.shared.storeFinishedTrack(from: location, itemId: info.id, trackIndex: info.track)
    }

    /// Redirect gate for the background download session. Refuses to follow any
    /// redirect whose host doesn't match the currently-configured Audiobookshelf
    /// server: `newRequest` carries forward the original request's Authorization
    /// header, and URLSession will happily follow a redirect to a different host with
    /// that header still attached unless a delegate explicitly says otherwise. This app
    /// only ever talks to the user's own configured server (see the TLS-trust comment
    /// above this class), so a same-download redirect landing on a different host means
    /// something is actually wrong — a captive portal intercepting the connection, a
    /// misconfigured reverse proxy, or a hostile middlebox — and the right response is
    /// to refuse the redirect outright (`completionHandler(nil)` cancels following it,
    /// which surfaces as a normal failed-download error) rather than silently handing
    /// the bearer token to whatever host is on the other end.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let redirectHost = request.url?.host,
              let configuredHost = URL(string: AuthStore.shared.serverURL)?.host,
              redirectHost.caseInsensitiveCompare(configuredHost) == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Cheap, synchronous sanity checks on a just-finished download, run while
    /// `location`'s temp file still exists. None of this decodes the audio — that
    /// would be expensive and format-specific — but it catches the common corrupt-
    /// download shapes for near-zero cost: (a) a zero-byte file (connection dropped
    /// right after headers), (b) a size that doesn't match the server-declared
    /// `Content-Length` (a transfer that was truncated but still reported HTTP
    /// success), and (c) an HTML/JSON error or login page served with a 200 status —
    /// unlike the binary audio containers Audiobookshelf serves, those start with
    /// `<` or `{`, so a file starting that way is essentially never a real track.
    static func integrityFailureReason(at location: URL, response: HTTPURLResponse?) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: location.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return String(localized: "Couldn\u{2019}t check the downloaded file. Try again.", comment: "Download failure reason")
        }
        if size == 0 {
            return String(localized: "The server sent an empty file. Try again.", comment: "Download failure reason")
        }
        // ARCH-4: a *resumed* download (`downloadTask(withResumeData:)`, used by both
        // pause/resume across relaunch and the dropped-connection retry path) issues a
        // byte-`Range` request, so the response here is 206 Partial Content whose own
        // `Content-Length` is only the *remaining* bytes still to come at the time the
        // range request was made — not the full track size. But `location`'s file is
        // the fully reassembled track (URLSession stitches the resumed bytes onto what
        // was already downloaded before handing this callback the finished file), so
        // `size` is always larger than a 206's `Content-Length`. Comparing them
        // directly rejected every resumed download as "incomplete," which meant
        // pause/resume across relaunch and the retry-on-dropped-connection path
        // (`maxRetries = 6`) could never actually complete a track. The real total for
        // a 206 lives in `Content-Range: bytes <start>-<end>/<total>` instead.
        if let response {
            let expectedTotal: Int64?
            if response.statusCode == 206 {
                expectedTotal = response.value(forHTTPHeaderField: "Content-Range")?
                    .split(separator: "/").last.flatMap { Int64($0) }
            } else if response.expectedContentLength > 0 {
                expectedTotal = response.expectedContentLength
            } else {
                expectedTotal = nil
            }
            if let expectedTotal, expectedTotal != size {
                // Polish pass (DL-5): byte counts go to the log, not the user.
                ShelfLog.error(.downloads, "Download incomplete: expected \(expectedTotal) bytes, got \(size)")
                return String(localized: "The download didn\u{2019}t finish properly. Try again.", comment: "Download failure reason")
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: location) else {
            return String(localized: "Couldn\u{2019}t check the downloaded file. Try again.", comment: "Download failure reason")
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        if let first = head.first, first == UInt8(ascii: "<") || first == UInt8(ascii: "{") {
            return String(localized: "The server sent an error page instead of the audio. Try again, or check your server.", comment: "Download failure reason")
        }
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = parse(task), !isForeignScope(info) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let ns = error as NSError
        // A dropped connection usually provides resume data — continue from where we
        // left off rather than failing/restarting.
        let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        // Polish pass (DL-5): the system description and code go to the log; the user
        // gets a sentence ("The connection kept dropping…", or the out-of-space hint).
        ShelfLog.error(.downloads, "Track \(info.id)|\(info.track) transfer error \(ns.domain) \(ns.code): \(error.localizedDescription)")
        let detail = DownloadFailureCopy.message(for: error)
        #if DEBUG
        print("[Download] track \(info.id)|\(info.track) error code \(ns.code): \(error.localizedDescription)")
        #endif
        DownloadManager.shared.retryOrFail(itemId: info.id, trackIndex: info.track,
                                           resumeData: resumeData, message: detail)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // `Task { @MainActor in }`, not `DispatchQueue.main.async`: `backgroundCompletionHandler`
        // is main-actor state, and a plain `DispatchQueue.main.async` closure isn't proven
        // to the compiler to run on the main actor even though it happens to execute on
        // the main thread.
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletionHandler?()
            DownloadManager.shared.backgroundCompletionHandler = nil
        }
    }
}

@MainActor
@Observable
final class DownloadManager {
    // `DownloadSessionDelegate`'s `URLSessionDownloadDelegate` callbacks run on a
    // background delegate queue (not main) and must reach `DownloadManager.shared`
    // synchronously — in particular `didFinishDownloadingTo` must move the
    // just-finished temp file into place *before returning*, since the system deletes
    // it right after the delegate call returns, which rules out hopping to the main
    // actor first. Plain `nonisolated` (not `(unsafe)`) is sufficient here: an
    // instance of a `@MainActor`-isolated class is itself Sendable-safe to reference
    // from any isolation domain (its *mutable state* still can't be touched without
    // hopping to main, which is exactly what's enforced elsewhere — see the
    // `nonisolated` instance members below). `(unsafe)` was flagged by the compiler
    // as unnecessary for that reason. This does require `init()` itself to be
    // `nonisolated` too (see its comment) — a `nonisolated static let` still can't
    // call a main-actor-isolated initializer.
    nonisolated static let shared = DownloadManager()

    /// P3-1 (third-pass review, 14 Aug 2026): how young a directory's `manifest.json`
    /// has to be for `sweepOrphanedDownloadDirectories` to leave it alone even though
    /// it isn't in `known`/`liveTaskItemIds` — see that function's own doc comment for
    /// why an unconditional exemption made ARCH-5's reclamation a permanent no-op.
    private static let recentManifestGracePeriod: TimeInterval = 24 * 3600

    var activeDownloads: [String: DownloadTask] = [:]
    var downloadedItems: Set<String> = []
    /// Surfaced to the UI (as a toast) when a download fails, so failures aren't silent.
    var downloadError: String?
    /// Set by `reconcile(serverProgress:)` when a downloaded book's local and server
    /// progress diverge too much to resolve silently via last-write-wins — see that
    /// method's doc comment. `MainTabView` presents this as an alert regardless of
    /// which tab is active, since reconciliation runs from `LibraryViewModel.loadUserProgress()`
    /// on any library load/refresh, not from a specific screen.
    var pendingProgressConflict: ProgressConflict?

    // `FileManager` is safe to use from any thread, and this is read from the
    // `nonisolated` disk-I/O helpers below (which run synchronously on the background
    // download-delegate queue) as well as from main-actor code. A *computed* property
    // rather than a stored `let`: Swift 6 treats a stored `nonisolated` property as
    // needing its value type to be `Sendable`, and `FileManager` isn't (even though
    // it's safe in practice) — a computed property has no stored backing to check, so
    // it sidesteps that without needing `nonisolated(unsafe)`. `.default` is itself a
    // thread-safe shared singleton, so recomputing this on every access is free.
    private nonisolated var fileManager: FileManager { .default }
    /// In-memory cache of manifests, keyed by item id. `nonisolated(unsafe)` (and
    /// Observation-ignored) because it's read/written from both main-actor UI code and
    /// the background download-delegate callbacks/off-main download Tasks — it is NOT
    /// main-actor state, it's protected instead by `cacheLock`, which remains load-bearing
    /// here (see that property's doc comment for why it can't simply become main-actor
    /// state: `storeFinishedTrack` must read/write this cache synchronously on the
    /// delegate's background queue, before the delegate call returns).
    @ObservationIgnored nonisolated(unsafe) private var manifests: [String: DownloadedBook] = [:]

    /// Serializes access to the three in-memory caches (manifests / trackURLs / retryCounts),
    /// which are touched from the main thread, the background download-delegate callbacks,
    /// and off-main download Tasks. Recursive so a locked accessor (e.g. `manifest(for:)`)
    /// can be called from within another locked section without deadlocking.
    ///
    /// This lock is still load-bearing after `@MainActor` was added to this class: it
    /// protects state that genuinely must be read/written synchronously from the
    /// background `URLSessionDownloadDelegate` queue (see `storeFinishedTrack`'s doc
    /// comment) — that access can't be routed through the main actor without breaking
    /// the "move the temp file before the delegate call returns" contract `URLSession`
    /// imposes. It is NOT protecting main-actor-only state (`activeDownloads`,
    /// `downloadedItems`, `downloadError`, etc.), which is left as ordinary main-actor
    /// `var`s and no longer needs (or uses) this lock.
    @ObservationIgnored private nonisolated let cacheLock = NSRecursiveLock()
    @discardableResult
    private nonisolated func withCacheLock<T>(_ body: () -> T) -> T {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return body()
    }

    /// Stored by the app delegate so we can tell the system we're done after a
    /// background download completes while the app was suspended.
    var backgroundCompletionHandler: (() -> Void)?

    /// Background session: downloads continue when the app is suspended or closed, and
    /// the system manages connectivity/retries. Safe here because the server uses a
    /// trusted (Let's Encrypt) certificate, so the daemon validates TLS normally.
    /// Dropped connections are additionally resumed via resume-data retry (see retryOrFail).
    /// The identifier must stay stable so the session reconnects to in-flight tasks on relaunch.
    @ObservationIgnored private lazy var sessionDelegate = DownloadSessionDelegate()
    @ObservationIgnored private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.shelfhead.download")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false                  // run now, don't defer for power/Wi-Fi
        // Session-level default; "Download on Wi-Fi only" is actually enforced per
        // request (`request.allowsCellularAccess`) at every task-creation call site
        // below, since that setting can change mid-download and the config here is
        // fixed once the lazy session is built. One residual gap: a task recreated
        // from `downloadTask(withResumeData:)` (a dropped-connection retry) can't take
        // a URLRequest, so it carries whatever cellular policy was in effect when that
        // resume data was originally generated — this is a URLSession API limitation,
        // not something a request flag can override. The same limitation applies to the
        // Authorization header baked into that resume data: there's no public API to
        // swap in a fresh bearer token for a `withResumeData:` task, so if the token
        // rotates while a dropped-connection retry is using stale resume data, the retry
        // rides on the old token. In practice this is self-healing — a stale/expired
        // token gets a 401 back, which `didFinishDownloadingTo` already routes to
        // `handleAuthFailure` to refresh the token and re-enqueue with a brand-new
        // `AuthStore.shared.authorizedRequest(url:)` (bypassing resume data entirely).
        // Every other retry/resume path in this file that *can* take a URLRequest
        // (`retryOrFail`'s no-resume-data branch, `resumeDownload`, `handleAuthFailure`)
        // already rebuilds it fresh via `authorizedRequest(url:)` rather than reusing
        // anything from the failed attempt. What resume-data-based retries can't rebuild
        // a request for, they also can't be redirected off-host with the stale token
        // silently attached — `DownloadSessionDelegate.urlSession(_:task:
        // willPerformHTTPRedirection:newRequest:completionHandler:)` below refuses any
        // redirect whose host doesn't match the configured server, regardless of which
        // path (fresh request or resume data) originated the task.
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 6        // download multi-file books in parallel
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()
    /// Resume-retry attempts keyed by "itemId|trackIndex". `nonisolated(unsafe)`: see
    /// `manifests` above — guarded by `cacheLock`, read/written from the background
    /// delegate queue.
    @ObservationIgnored nonisolated(unsafe) private var retryCounts: [String: Int] = [:]
    /// Original download URL per "itemId|trackIndex", so a track can be restarted
    /// from scratch when the failure provides no resume data (e.g. a TLS reset).
    /// `nonisolated(unsafe)`: see `manifests` above.
    @ObservationIgnored nonisolated(unsafe) private var trackURLs: [String: URL] = [:]
    /// Resume data captured when a download is paused, keyed by "itemId|trackIndex".
    /// `nonisolated(unsafe)`: see `manifests` above.
    @ObservationIgnored nonisolated(unsafe) private var pausedResumeData: [String: Data] = [:]
    /// When each in-flight download last hopped to the main actor to publish progress,
    /// keyed by item id. Read/written on the background download-delegate queue under
    /// `cacheLock`, exactly like the three caches above (`nonisolated(unsafe)` for the
    /// same reason, and `@ObservationIgnored` because it is throttle bookkeeping, not
    /// state any view should ever be re-rendered for).
    ///
    /// Item 10 (REVIEW-2026-09-09.md): `didWriteData` fires several times a second per
    /// in-flight track, with up to `httpMaximumConnectionsPerHost` (6) tracks in flight,
    /// and every one of those callbacks used to allocate a main-actor `Task`, take
    /// `cacheLock` and write an `@Observable` property. This is what lets the *callback*
    /// be dropped, rather than only the write it would have made.
    @ObservationIgnored nonisolated(unsafe) private var lastProgressHopAt: [String: Date] = [:]
    private nonisolated let maxRetries = 6

    /// `nonisolated` deliberately: `static let shared` (above) needs to construct this
    /// instance without requiring main-actor context, since `shared` itself must be
    /// reachable from `DownloadSessionDelegate`'s background delegate-queue callbacks.
    /// The real per-launch setup this used to do inline (`loadDownloadedItems()`,
    /// `restorePausedDownloads()`) touches main-actor-isolated state (`downloadedItems`,
    /// `activeDownloads`), so it can't live here anymore — it moved to `ensureSessionReady()`,
    /// which is `@MainActor` and already guaranteed to run once, early, on the main
    /// actor at launch (see `ShelfHeadApp.init()`).
    private nonisolated init() {
        // Cover-versioning fix: `CoverVersions.record` (called from `LibraryItem.init(
        // from:)`, AudiobookshelfModels.swift) fires this the moment it sees an item's
        // `updatedAt` move forward — i.e. the server reports newer artwork than this
        // launch had already seen. Hops to main since `refreshLocalCoverIfStale` reads
        // main-actor state (`manifests` via the lock is fine off-main, but
        // `hasLocalCover`/`coverRefreshAttempted` aren't). `DownloadManager.shared` is
        // referenced only inside the closure body, never evaluated here, so this can't
        // recursively re-enter `DownloadManager`'s own `static let shared` init.
        CoverVersions.onVersionObserved = { itemId, updatedAt in
            Task { @MainActor in
                DownloadManager.shared.refreshLocalCoverIfStale(itemId: itemId, serverUpdatedAt: updatedAt)
            }
        }
    }

    /// One-time main-actor bootstrap, run from `ensureSessionReady()` the first time
    /// it's called rather than from `init()` — see that property's comment for why.
    private var hasBootstrapped = false
    /// P3-4 (third-pass review, 14 Aug 2026): `bootstrapIfNeeded()` and
    /// `reloadForActiveScope()` both kick off an async `adoptInFlightDownloads` call
    /// whose completion adopts in-flight tasks and then runs
    /// `sweepOrphanedDownloadDirectories`. Both call sites can genuinely overlap —
    /// `reloadForActiveScope()` is called from `ContentView` on every foreground/login
    /// and from `DownloadHealthView`'s manual "reload" action, so a second reload can
    /// start (a fast account switch, a background-session relaunch racing a foreground
    /// reload, or a user tapping reload twice) before the first's `getAllTasks`
    /// round-trip has returned. Without a guard, the *first* reload's completion fires
    /// later, using a `liveTaskItemIds` snapshot and `adoptInFlight` call that are now
    /// stale — `activeDownloads`/`downloadedItems` already belong to whatever scope
    /// the *second* reload set up. That stale completion could adopt phantom tasks
    /// into the new scope, or — now that P3-1 restored real reclamation — sweep a
    /// genuine, freshly-active download for the new scope as an "orphan."
    ///
    /// Each reload captures the generation counter it started at; a completion whose
    /// generation no longer matches the current one was superseded by a later reload
    /// and must do nothing at all — not adopt, not sweep, not refresh storage — since
    /// every one of those actions assumes state that's since been replaced.
    private var reloadGeneration = 0
    private func bootstrapIfNeeded() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        reloadGeneration += 1
        let generation = reloadGeneration
        loadDownloadedItems()
        // Per-item-size-at-launch fix: rows anywhere that read `itemStorageBytes`
        // (this tab's `DownloadedBooksSection`, Library's `downloadedOnly` filter) used
        // to show duration-only until the Downloads screen's Storage section happened
        // to scroll into view and ran its own `.task` — on a long downloads list, that
        // could be never. `refreshStorageUsed()` is already a `.detached`, off-main,
        // best-effort walk, so kicking it off here alongside the manifest load is
        // cheap and gets real sizes landing during launch rather than on first scroll.
        // Not `force: true`: this is the very first walk of the process (the throttle's
        // `lastStorageWalkStartedAt` is still `nil` here), so it always runs regardless;
        // `hasBootstrapped`'s guard above is what keeps the background-relaunch path
        // (`ensureSessionReady()` called again from the AppDelegate relaunch handler)
        // from calling this a second time, not the throttle.
        refreshStorageUsed()
        loadFailedDownloads()
        restorePausedDownloads()
        // NEW-1 (follow-up review, 14 Aug 2026): `adoptInFlightDownloads()` is
        // asynchronous (it queries the background `URLSession` for outstanding
        // tasks, then hops back to the main actor) — calling the sweep on the very
        // next synchronous line here ran it *before* adoption had populated
        // anything, so a download the background daemon resumed (running, not
        // paused) wasn't yet in `activeDownloads`, looked orphaned, and got its
        // partial files + manifest deleted out from under it. The sweep now runs
        // from adoption's own completion instead, strictly after `activeDownloads`
        // reflects every in-flight task this call found.
        adoptInFlightDownloads(generation: generation) { [weak self] liveTaskItemIds in
            self?.sweepOrphanedDownloadDirectories(additionallyExcluding: liveTaskItemIds)
        }
    }

    /// CRIT-2: `ensureSessionReady()` recreating the background `URLSession` correctly
    /// reattaches the delegate to tasks still running in the system daemon after a
    /// relaunch, but nothing previously rebuilt `activeDownloads` from those tasks —
    /// `restorePausedDownloads()` (above) only reconstructs entries for *paused* ids,
    /// `continue`-ing past everything actually still downloading. Every guard in this
    /// file keys off `activeDownloads[itemId] != nil`
    /// (`trackProgress`/`retryOrFail`/`handleAuthFailure`/`downloadBook`), so a
    /// still-running-but-unadopted download: showed no progress/row in Downloads (looked
    /// dead), silently dropped a subsequent connection failure instead of retrying,
    /// silently dropped a mid-download 401, and let the user start a duplicate download
    /// racing the original onto the same destination paths. Queries the live background
    /// session for its outstanding tasks and reinstates one `DownloadTask` per distinct
    /// item id found, seeded with real progress from disk.
    /// NEW-1 (follow-up review, 14 Aug 2026): takes an optional `completion`, run on
    /// the main actor strictly after `activeDownloads` has been updated with every
    /// in-flight task this call found — callers use it to sequence
    /// `sweepOrphanedDownloadDirectories()` so it never runs while adoption is still
    /// pending. `completion` is passed the raw item ids of every live (running or
    /// suspended) task found, *whether or not* `adoptInFlight` actually adopted each
    /// one (it skips ids that fail its own `manifest(for:)` lookup, already-downloaded
    /// ids, etc.) — the sweep uses this as a second, independent guard against
    /// deleting a directory for a task that's genuinely still live, even in a case
    /// `adoptInFlight` itself didn't turn into an `activeDownloads` entry.
    ///
    /// Previously this returned early (before ever scheduling the `Task { @MainActor
    /// in ... } `) whenever no in-flight tasks were found — the common case on a
    /// normal cold launch — which meant a caller relying on this to *sequence*
    /// something afterward would simply never see that continuation run at all.
    /// Fixed by always hopping to the main actor and always invoking `completion`
    /// exactly once, regardless of whether there was anything to adopt.
    ///
    /// - Parameter generation: the caller's `reloadGeneration` snapshot at the moment
    ///   it started this reload (P3-4, third-pass review, 14 Aug 2026). Checked right
    ///   before touching any state, on the main actor, immediately before both
    ///   `adoptInFlight` and `completion` run — if a later reload has bumped
    ///   `reloadGeneration` in the meantime, this call was superseded mid-flight and
    ///   both are skipped entirely, since acting on a stale `getAllTasks` snapshot
    ///   against a scope's state that's since moved on is exactly the race that made
    ///   the sweep unsafe to run unconditionally.
    private func adoptInFlightDownloads(generation: Int, then completion: (@MainActor (_ liveTaskItemIds: Set<String>) -> Void)? = nil) {
        downloadSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let scope = self.currentScopeKey()
            var itemIds: [String] = []
            var seen = Set<String>()
            var recoveredURLs: [String: URL] = [:]
            for task in tasks {
                guard task.state == .running || task.state == .suspended,
                      let info = Self.parseScopedTaskKey(task.taskDescription),
                      // Same rejection `DownloadSessionDelegate.isForeignScope` applies
                      // to a completing task: a task whose description carries a scope
                      // (not the legacy no-scope form) that doesn't match the currently
                      // active account must not be adopted into it.
                      info.scope.isEmpty || info.scope == scope else { continue }
                // Review Medium 26 (30 October 2026): `trackURLs` is memory-only, so after a
                // relaunch a 401 re-enqueue / restart had no URL and the row stuck.
                // Rebuild it from the live task's original request.
                if let url = Self.sanitizedTrackURL(task.originalRequest?.url) {
                    recoveredURLs["\(info.id)|\(info.track)"] = url
                }
                guard !seen.contains(info.id) else { continue }
                seen.insert(info.id)
                itemIds.append(info.id)
            }
            // Real build error: `itemIds` is a local `var` (built up via `.append` in the
            // loop above) inside this synchronous completion closure, and referencing a
            // `var` from the nested `Task { @MainActor in ... }` closure — itself a
            // separate concurrently-executing closure — requires it to be captured as an
            // immutable value first. Copying to a `let` just before the `Task` gives it
            // its own independent snapshot (an `[String]` is a value type, so this is a
            // real copy, not a reference), which the concurrency checker accepts.
            let idsToAdopt = itemIds
            let urlsToRestore = recoveredURLs
            Task { @MainActor in
                // P3-4: a later reload superseded this one before this completion got
                // a chance to run — its `idsToAdopt`/`liveTaskItemIds` describe a
                // background-session snapshot for a scope that's no longer current.
                guard self.reloadGeneration == generation else { return }
                if !urlsToRestore.isEmpty {
                    self.withCacheLock {
                        for (key, url) in urlsToRestore where self.trackURLs[key] == nil { self.trackURLs[key] = url }
                    }
                }
                if !idsToAdopt.isEmpty {
                    self.adoptInFlight(itemIds: idsToAdopt)
                }
                completion?(Set(idsToAdopt))
            }
        }
    }

    /// Parses "scope|itemId|track" (or legacy "itemId|track") the same way
    /// `DownloadSessionDelegate.parse` does — duplicated rather than shared because
    /// that method is `private` to a different type, and this is the one other place
    /// in the file that needs the scope component (`Self.parseTaskKey` below
    /// deliberately drops it, since none of its other callers need it).
    // Not `private`: exercised directly by `DownloadManagerScopeTests` (`@testable
    // import` still can't reach `private`/`fileprivate` declarations).
    nonisolated static func parseScopedTaskKey(_ desc: String?) -> (scope: String, id: String, track: Int)? {
        guard let desc else { return nil }
        let p = desc.split(separator: "|").map(String.init)
        if p.count == 3, let t = Int(p[2]) { return (p[0], p[1], t) }
        if p.count == 2, let t = Int(p[1]) { return ("", p[0], t) }
        return nil
    }

    /// Review Medium 26 (30 October 2026): the URL to re-request a track from, taken from an
    /// adopted task's original request. Download URLs carry the token in the Authorization
    /// header, not the query, but any `token` query item is dropped defensively so a
    /// streaming-style URL is never replayed or stored.
    nonisolated static func sanitizedTrackURL(_ url: URL?) -> URL? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let items = comps.queryItems {
            let kept = items.filter { $0.name.lowercased() != "token" }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        return comps.url
    }

    private func adoptInFlight(itemIds: [String]) {
        for itemId in itemIds {
            // Don't clobber anything already tracked (e.g. a paused entry
            // `restorePausedDownloads()` just reinstated) or already finished.
            guard activeDownloads[itemId] == nil, !isDownloaded(itemId: itemId) else { continue }
            guard let manifest = manifest(for: itemId) else { continue }
            let task = DownloadTask(itemId: itemId, title: manifest.title)
            let total = max(manifest.tracks.count, 1)
            task.progress = Double(completedTrackCount(itemId: itemId)) / Double(total)
            activeDownloads[itemId] = task
        }
    }

    // MARK: - Persisted paused downloads

    private nonisolated func pausedResumeDir() -> URL { pausedResumeDir(scopeKey: currentScopeKey()) }
    /// S5 (REVIEW_2026-08-20_UI_SECURITY.md): scoped variant used by
    /// `deleteAllPersistedPausedResumeBlobs(scopeKey:)` below, which needs to sweep an
    /// account that isn't necessarily the currently-active one (e.g. a saved account row
    /// being removed in Settings while a different account is signed in).
    private nonisolated func pausedResumeDir(scopeKey: String) -> URL {
        downloadsRoot(scopeKey: scopeKey).appendingPathComponent(".paused")
    }
    nonisolated func pausedResumeFile(key: String) -> URL {
        // SEC-1: sanitize the itemId component of "itemId|trackIndex" the same way
        // `downloadDirectory(for:)` sanitizes it — this previously built its filename
        // straight from the raw, unsanitized key, inconsistent with every other
        // download-related path in this file, and a `.`/`..`/`/`-containing id would
        // sanitize safely for the download directory but not for this one. (The
        // in-memory `pausedResumeData` cache key elsewhere in this file stays the raw,
        // un-sanitized itemId — only this on-disk filename needs to change — so a
        // pathological id whose sanitized form differs from its raw form would fail to
        // round-trip its resume data across a relaunch. Audiobookshelf ids are UUIDs in
        // practice, so `sanitizedPathComponent` is the identity function here and this
        // never bites; the resume-data round trip degrading to "restart this track
        // from scratch" for a hostile id is an acceptable trade for closing the actual
        // traversal.)
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let filename = parts.count == 2
            ? "\(sanitizedPathComponent(parts[0]))__\(parts[1])"
            : sanitizedPathComponent(key)
        return pausedResumeDir().appendingPathComponent(filename + ".resume")
    }
    private nonisolated func loadPausedItems() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pausedItemsKey()) ?? [])
    }
    private nonisolated func markPaused(_ itemId: String, _ paused: Bool) {
        var set = loadPausedItems()
        if paused { set.insert(itemId) } else { set.remove(itemId) }
        UserDefaults.standard.set(Array(set), forKey: pausedItemsKey())
    }
    private nonisolated func persistPausedResume(key: String, data: Data) {
        try? fileManager.createDirectory(at: pausedResumeDir(), withIntermediateDirectories: true)
        let file = pausedResumeFile(key: key)
        // Item 9 (REVIEW-2026-09-09-REMAINING.md): `.atomic`, matching `writeManifest` and
        // the cover write — this was the one store in this file that wrote in place. A
        // resume blob is written from `cancel(byProducingResumeData:)`'s callback, i.e.
        // exactly when the app is being backgrounded or suspended, which is precisely when
        // a non-atomic write can be cut short. A truncated blob is not inert: it is
        // restored on the next launch and handed to `downloadTask(withResumeData:)`, which
        // then throws or silently restarts the track from zero. `.atomic` means the file
        // at `file` is either the previous blob or the complete new one, never a prefix.
        // (`shouldUseResumeBlob` below is the read-side half of the same fix, for blobs
        // truncated by anything an atomic rename can't cover — a full disk, a filesystem
        // corruption, a blob written by a build from before this fix.)
        try? data.write(to: file, options: .atomic)
        // This resume-data blob is opaque system data, but it embeds the original
        // request — including the Authorization header — so it deserves the same
        // protection as the audio/manifest files it'll eventually help reconstruct.
        // (Applied after the write: `.atomic` replaces the file via a rename, so an
        // attribute set on a pre-existing file at this path wouldn't survive it.)
        protectDownloadedFile(at: file)
    }

    /// Whether a `URLSessionDownloadTask` resume blob is safe to hand to
    /// `downloadSession.downloadTask(withResumeData:)`.
    ///
    /// Item 9 (REVIEW-2026-09-09-REMAINING.md). Resume data is documented as opaque, but
    /// on every shipping Apple platform it is a serialized property list (a binary
    /// `bplist00` today; XML historically) whose keys name the partially-downloaded temp
    /// file. That matters here because a bplist's object-offset table and trailer live at
    /// the *end* of the file: a blob truncated by an interrupted write parses as garbage
    /// rather than as a shorter-but-valid blob, and feeding it to
    /// `downloadTask(withResumeData:)` produces either an immediate
    /// `NSURLErrorCannotOpenFile`/`.dataLengthExceedsMaximum`-class failure or a task that
    /// quietly restarts from byte zero — in the first case burning a retry, in the second
    /// re-downloading the whole track while the UI claims it resumed.
    ///
    /// Deliberately strict: the blob must parse as a property list whose root is a
    /// **non-empty dictionary**, which is the shape `URLSession` resume data always has
    /// (`NSURLSessionResumeInfoVersion`, `NSURLSessionResumeCurrentRequest`,
    /// `NSURLSessionResumeInfoTempFileName`, …). Neither half of that is
    /// belt-and-braces, and both were established by probing the real serializer rather
    /// than assumed:
    ///
    /// * `PropertyListSerialization` also reads old-style OpenStep/ASCII plists, under
    ///   which a *single bare token* is a valid plist — so a one-byte torn write, or the
    ///   literal eight bytes `bplist00`, parse happily as the **string** they spell. A
    ///   parse-only check would therefore wave through the most badly truncated blobs of
    ///   all. Requiring a dictionary root rejects those.
    /// * That same parser treats input consisting only of whitespace as an **empty**
    ///   dictionary, so `!isEmpty` on the parsed dictionary is what rejects a blob whose
    ///   bytes survived but whose contents didn't. An empty dictionary would in any case
    ///   be useless to `downloadTask(withResumeData:)`.
    ///
    /// Both binary and XML encodings still pass, and every prefix of a realistically
    /// shaped resume blob is rejected.
    ///
    /// The cost of a false negative is bounded and correct — the callers all fall back to
    /// re-requesting the track from `trackURLs`, which is what happens today whenever no
    /// resume data was produced at all — so the worst case is re-downloading one track,
    /// never a wrong or missing file. The cost of a false positive is the bug above.
    ///
    /// Pure and `static` so it can be unit-tested without disk or instance state — same
    /// precedent as `shouldReclaimOrphanDirectory` / `failureAction`; see
    /// `DownloadResumeBlobTests`.
    nonisolated static func shouldUseResumeBlob(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return false
        }
        return !dictionary.isEmpty
    }
    private nonisolated func deletePersistedPausedResume(forItem itemId: String) {
        guard let files = try? fileManager.contentsOfDirectory(at: pausedResumeDir(), includingPropertiesForKeys: nil) else { return }
        // Matches the sanitized filename `pausedResumeFile(key:)` above now writes.
        let prefix = sanitizedPathComponent(itemId) + "__"
        for f in files where f.lastPathComponent.hasPrefix(prefix) { try? fileManager.removeItem(at: f) }
    }

    /// S5 (REVIEW_2026-08-20_UI_SECURITY.md): deletes every persisted `.resume` blob for
    /// `scopeKey` — not just one item's, the way `deletePersistedPausedResume(forItem:)`
    /// above does on a per-item cancel. Each blob embeds its original download request,
    /// including the `Authorization` header (see `persistPausedResume`'s own comment), so
    /// leaving them behind after a sign-out or a token rotation means an old bearer value
    /// is still sitting on disk — Data-Protected, but outside the Keychain — after the app
    /// itself no longer considers it current.
    ///
    /// Call sites: `AuthViewModel.tearDownAccountScopedState(reason:)` — the one routine
    /// sign-out, account switch and account removal now share (Fix 5,
    /// REVIEW-2026-09-09.md) — which passes the still-active `currentScopeKey()` for
    /// sign-out and switch (it runs before `AuthStore.shared.clear()` changes what that
    /// resolves to) and an explicit scope key for the account row being removed, which
    /// may not be the currently-active one (mirrors why
    /// `DownloadManager.scopeKey(serverURL:accountId:)` is `static`). Also
    /// `AudiobookshelfAPI.performRefresh()` (the OIDC/refresh-token rotation path).
    nonisolated func deleteAllPersistedPausedResumeBlobs(scopeKey: String) {
        let dir = pausedResumeDir(scopeKey: scopeKey)
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "resume" { try? fileManager.removeItem(at: f) }
    }

    /// Restore paused downloads across relaunch: reload their captured resume data and
    /// rebuild paused entries (from the on-disk manifest) so they show as paused and can
    /// be resumed, instead of being silently lost when the app process is killed.
    private func restorePausedDownloads() {
        let paused = loadPausedItems()
        guard !paused.isEmpty else { return }
        if let files = try? fileManager.contentsOfDirectory(at: pausedResumeDir(), includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "resume" {
                let key = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "__", with: "|")
                let data = try? Data(contentsOf: f)
                // Item 9 (REVIEW-2026-09-09-REMAINING.md): validate before caching. A
                // truncated blob (written non-atomically by a build from before the
                // `.atomic` fix above, or by a write that ran out of disk) would otherwise
                // be restored here and fed straight to `downloadTask(withResumeData:)`.
                // Delete it too, so the next launch doesn't re-read the same bad file:
                // dropping it is not data loss, `resumeDownload` just re-requests the
                // track from `trackURLs` exactly as it does when no resume data existed.
                guard Self.shouldUseResumeBlob(data), let data else {
                    ShelfLog.info(.downloads, "Discarding unusable paused-resume blob for \(key); the track will restart instead.")
                    try? fileManager.removeItem(at: f)
                    continue
                }
                withCacheLock { pausedResumeData[key] = data }
            }
        }
        for itemId in paused {
            guard !isDownloaded(itemId: itemId), let manifest = manifest(for: itemId) else {
                markPaused(itemId, false); continue
            }
            let total = manifest.tracks.count
            let task = DownloadTask(itemId: itemId, title: manifest.title)
            task.isPaused = true
            task.progress = total > 0 ? Double(completedTrackCount(itemId: itemId)) / Double(total) : 0
            activeDownloads[itemId] = task
        }
    }

    /// Touch the session so it's recreated (and reconnects to outstanding tasks)
    /// on launch and when the system delivers background events. Also runs the
    /// one-time main-actor bootstrap that used to live in `init()` — see
    /// `bootstrapIfNeeded()`'s comment. Called from `ShelfHeadApp.init()` on every
    /// launch (main actor), and again from `AppDelegate`'s background-session-relaunch
    /// handler (also always main-thread, per `UIApplicationDelegate`'s contract) —
    /// `bootstrapIfNeeded()`'s guard makes the second call a no-op.
    func ensureSessionReady() {
        _ = downloadSession
        bootstrapIfNeeded()
        // Batch 406: the one Live Activity hook. Runs at launch, on a background-session
        // relaunch and from background refresh; from then on the controller follows
        // `activeDownloads`/`downloadedItems`/`failedDownloads` itself (start, progress,
        // pause, cancel, finish, fail), so no other path in this file needs a call.
        LiveActivityController.shared.observeDownloads(of: self)
    }

    // MARK: - Public API

    func downloadBook(_ item: LibraryItem, automatic: Bool = false) {
        guard activeDownloads[item.id] == nil, !isDownloaded(itemId: item.id) else { return }
        // Review Low (auto-download, 30 October 2026): a manual download lifts the
        // "user removed this" mark so auto-download treats the book normally again.
        if !automatic { markUserRemoved([item.id], false) }
        // Honor the "Download on Wi-Fi only" setting for manual downloads too
        // (previously it only gated auto-downloads).
        if SettingsStore.wifiOnlyDownloads && !NetworkMonitor.shared.isOnWiFi {
            // Review 7 Low (auto toast): automatic starts fail silently.
            if !automatic { downloadError = String(localized: "Wi-Fi-only downloads are on. Connect to Wi-Fi, or turn this off in Settings.") }
            return
        }
        // Check free space up front when the server told us the book's size — without
        // this, a multi-GB audiobook on a nearly-full device only fails after the
        // entire file has downloaded (at the final move-into-place step).
        if let sizeBytes = item.size, sizeBytes > 0, !hasSpaceAvailable(atLeast: Int64(sizeBytes)) {
            // Review 7 Low (auto toast): no toast for automatic starts (they re-run on every Home load).
            if !automatic { downloadError = String(localized: "Not enough free space to download “\(item.title)”.", comment: "%@ is the book title") }
            return
        }
        let startedTask = DownloadTask(itemId: item.id, title: item.title)
        activeDownloads[item.id] = startedTask
        // Review 2 Low (cancel-then-restart, 30 October 2026): this start's token.
        let runId = startedTask.runId
        // Fix 9 (REVIEW-2026-09-09.md), superseded by Item 27 (perf review):
        // `SWIFT_APPROACHABLE_CONCURRENCY = YES` turns on `NonisolatedNonsendingByDefault`,
        // which quietly undid ARCH-6: a `nonisolated async` function no longer runs
        // off-main by virtue of being `nonisolated` — it runs on its *caller's* actor, and
        // a plain `Task { }` created here inherits this class's `@MainActor`. So every
        // download start was back to doing `createDirectory`, the manifest JSON encode +
        // atomic write, `protectDownloadedFile` and one `fileExists` per track on the main
        // thread, with `enqueueDownload`'s own `await MainActor.run` hops reduced to
        // no-ops. This used to be worked around with `Task.detached` here; `enqueueDownload`
        // is now itself marked `@concurrent` (see its declaration), which states the "runs
        // off any actor" contract at the declaration instead of at every call site, so a
        // plain `Task { }` is enough — a future caller can't silently put this back on the
        // main thread by forgetting to detach. If `@concurrent` doesn't compile in this
        // project's Swift 5 language mode, revert by removing the `@concurrent` attribute
        // from `enqueueDownload`'s declaration below and changing the line under this
        // comment back to `Task.detached { await self.enqueueDownload(item) }`. The `assert`
        // at the top of `enqueueDownload` stays either way — it makes a regression loud in
        // DEBUG instead of silent.
        Task { await self.enqueueDownload(item, runId: runId) }
    }

    // MARK: Bulk download (library multi-select)

    /// Bytes available on the downloads volume, or nil when it can't be read (the planner
    /// then fails open, like `hasSpaceAvailable`).
    func availableBytes() -> Int64? {
        guard let values = try? downloadsRoot().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return available
    }

    /// Plans a multi-book download. Checked once up front so 50 calls to `downloadBook`
    /// don't overwrite the same banner 50 times. Pure: all state arrives as parameters.
    /// Eligible books beyond `cap` are reported as skipped (`.overCap`), never queued.
    nonisolated static func bulkDownloadPlan(items: [LibraryItem],
                                             isDownloaded: (String) -> Bool,
                                             isDownloading: (String) -> Bool,
                                             wifiOnly: Bool,
                                             onWiFi: Bool,
                                             freeBytes: Int64?,
                                             cap: Int = 50) -> BulkDownloadPlan {
        var toDownload: [LibraryItem] = []
        var skipped: [BulkDownloadPlan.Skipped] = []
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.id).inserted else { continue }   // duplicate selection
            if item.isPodcast { skipped.append(.init(itemId: item.id, reason: .podcast)) }
            else if isDownloaded(item.id) { skipped.append(.init(itemId: item.id, reason: .alreadyDownloaded)) }
            else if isDownloading(item.id) { skipped.append(.init(itemId: item.id, reason: .inFlight)) }
            else if toDownload.count >= max(cap, 0) { skipped.append(.init(itemId: item.id, reason: .overCap)) }
            else { toDownload.append(item) }
        }
        var totalBytes: Int64 = 0
        var unknown = 0
        for item in toDownload {
            if let size = item.size, size > 0 { totalBytes += Int64(size) } else { unknown += 1 }
        }
        var refusal: BulkDownloadPlan.Refusal?
        if toDownload.isEmpty {
            refusal = .nothingToDownload
        } else if wifiOnly && !onWiFi {
            refusal = .wifiOnlyBlocked
        } else if let free = freeBytes, totalBytes > 0, free <= totalBytes + 10_000_000 {
            refusal = .insufficientSpace
        }
        return BulkDownloadPlan(toDownload: toDownload, skipped: skipped, totalKnownBytes: totalBytes,
                                unknownSizeCount: unknown, wifiOnly: wifiOnly, refusal: refusal)
    }

    /// Convenience that feeds the planner from live state.
    func bulkDownloadPlan(for items: [LibraryItem]) -> BulkDownloadPlan {
        Self.bulkDownloadPlan(items: items,
                              isDownloaded: { self.isDownloaded(itemId: $0) },
                              isDownloading: { self.isDownloading(itemId: $0) },
                              wifiOnly: SettingsStore.wifiOnlyDownloads,
                              onWiFi: NetworkMonitor.shared.isOnWiFi,
                              freeBytes: availableBytes())
    }

    /// Enqueues every book in the plan through `downloadBook`. A refused plan sets
    /// `downloadError` once and queues nothing; per-book synchronous failures are
    /// collapsed into a single `downloadError` at the end.
    func downloadBooks(_ plan: BulkDownloadPlan) {
        if let message = plan.refusal?.message {
            downloadError = message
            return
        }
        let prior = downloadError
        var failures = 0
        for item in plan.toDownload {
            downloadError = nil
            downloadBook(item)
            if downloadError != nil { failures += 1 }
        }
        if failures > 0 {
            downloadError = failures == 1 ? String(localized: "1 book couldn't be queued for download.")
                                          : String(localized: "\(failures) books couldn't be queued for download.", comment: "%lld is a number of books (2 or more)")
        } else {
            downloadError = prior
        }
    }

    /// Whether the volume containing the downloads folder reports at least `bytes`
    /// available. Fails open (returns true) if the check itself can't be performed, so
    /// a filesystem quirk never blocks a download outright — this is a best-effort
    /// heads-up, not a hard guarantee (the actual write can still fail).
    private func hasSpaceAvailable(atLeast bytes: Int64) -> Bool {
        guard let values = try? downloadsRoot().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return true
        }
        // Ask for a little headroom beyond the raw file size (manifest/track overhead).
        return available > bytes + 10_000_000
    }

    /// True when download *policies* (Wi-Fi-only, charging-only) currently permit an
    /// automatic download. Manual downloads bypass the charging rule.
    var autoDownloadPolicyAllows: Bool {
        liveAutoDownloadDeferral() == nil
    }

    /// Polish pass (DL-3): the gate that would hold an automatic download back right now.
    private func liveAutoDownloadDeferral() -> AutoDownloadDeferral? {
        let state = UIDevice.current.batteryState
        return DownloadPolicyStatus.autoDownloadDeferral(
            wifiOnly: SettingsStore.wifiOnlyDownloads, onWiFi: NetworkMonitor.shared.isOnWiFi,
            chargingOnly: SettingsStore.downloadWhileChargingOnly,
            isCharging: state == .charging || state == .full)
    }

    /// Polish pass (DL-3): why the last automatic download was deferred, or nil. Set when
    /// an auto-download call is gated, cleared when one is allowed. In-memory only.
    private(set) var autoDownloadDeferral: AutoDownloadDeferral?

    /// Polish pass (DL-3): what the Downloads screen should say, re-checked against the
    /// live gates so a line recorded on cellular disappears once Wi-Fi is back, even
    /// before the next auto-download pass runs.
    var currentAutoDownloadDeferral: AutoDownloadDeferral? {
        autoDownloadDeferral == nil ? nil : liveAutoDownloadDeferral()
    }

    private func noteAutoDownloadGate() -> Bool {
        let deferral = liveAutoDownloadDeferral()
        if autoDownloadDeferral != deferral { autoDownloadDeferral = deferral }
        return deferral == nil
    }

    /// Auto-downloads the given items if enabled and current policies allow it.
    func autoDownloadIfEnabled(_ items: [LibraryItem]) {
        guard SettingsStore.autoDownloadContinueListening, noteAutoDownloadGate() else { return }
        let removed = loadUserRemovedItems()
        let failed = Set(failedDownloads.keys)
        for item in items where Self.shouldAutoDownload(itemId: item.id, isDownloaded: isDownloaded(itemId: item.id),
                                                        isDownloading: isDownloading(itemId: item.id),
                                                        userRemoved: removed, failed: failed) {
            downloadBook(item, automatic: true)
        }
    }

    /// Policy-gated single download used by automatic flows (e.g. series auto-download).
    /// Silently no-ops when Wi-Fi/charging policy isn't met (no error toast).
    func autoDownloadIfAllowed(_ item: LibraryItem) {
        guard noteAutoDownloadGate(),
              Self.shouldAutoDownload(itemId: item.id, isDownloaded: isDownloaded(itemId: item.id),
                                      isDownloading: isDownloading(itemId: item.id),
                                      userRemoved: loadUserRemovedItems(), failed: Set(failedDownloads.keys)) else { return }
        downloadBook(item, automatic: true)
    }

    func cancelDownload(itemId: String) {
        // Mark cancelled synchronously so any in-flight finalize/retry callbacks bail out.
        activeDownloads[itemId]?.isCancelled = true
        // Read before the async hop below — the task is removed from `activeDownloads`
        // inside that closure, so the flag has to be captured while it still exists.
        let isRepair = activeDownloads[itemId]?.isRepair == true
        let cancelledRunId = activeDownloads[itemId]?.runId
        downloadSession.getAllTasks { tasks in
            for task in tasks where Self.parseTaskKey(task.taskDescription)?.id == itemId {
                task.cancel()
            }
            // Clear state and delete files only after the tasks are actually cancelled, so
            // a late didFinishDownloadingTo can't re-insert the item via finalizeIfComplete.
            // `Task { @MainActor in }` rather than `DispatchQueue.main.async` — the latter
            // doesn't prove main-actor isolation to the compiler, and this closure touches
            // `activeDownloads` (main-actor state) below.
            Task { @MainActor in
                // Review 4 Low (cleanup hop): a Retry/restart in this window owns the entry,
                // folder and manifest now; don't clear or delete the new run's state.
                if let current = self.activeDownloads[itemId], current.runId != cancelledRunId { return }
                self.activeDownloads.removeValue(forKey: itemId)
                self.completedTracksCache.removeValue(forKey: itemId)
                self.withCacheLock {
                    self.manifests.removeValue(forKey: itemId)
                    self.retryCounts = self.retryCounts.filter { !$0.key.hasPrefix("\(itemId)|") }
                    self.trackURLs = self.trackURLs.filter { !$0.key.hasPrefix("\(itemId)|") }
                    self.pausedResumeData = self.pausedResumeData.filter { !$0.key.hasPrefix("\(itemId)|") }
                }
                self.markPaused(itemId, false)
                self.deletePersistedPausedResume(forItem: itemId)
                self.clearProgressThrottleState(itemId: itemId)
                // Fix 3 (REVIEW-2026-09-09.md): cancelling a *repair* must not delete
                // the book. `cancelAllActiveDownloads()` runs on every account switch
                // and logout, so a repair in flight at that moment used to take the
                // whole download with it — healthy tracks, cached cover and
                // `manifest.json` (the only store of offline progress) — while leaving
                // the id in `downloadedItems`. Only a genuine first-time download's
                // partial directory is reclaimed here; the invariant that a directory
                // deletion and the `downloadedItems` removal happen together is what
                // makes this safe (see `shouldRemoveItemDirectoryOnFailure`).
                if Self.shouldRemoveItemDirectoryOnFailure(isRepair: isRepair,
                                                           isInDownloadedItems: self.downloadedItems.contains(itemId)) {
                    try? self.fileManager.removeItem(at: self.downloadDirectory(for: itemId))
                }
            }
        }
    }

    /// Pause an in-flight download, capturing resume data so it can continue later.
    func pauseDownload(itemId: String) {
        guard let task = activeDownloads[itemId], !task.isPaused else { return }
        task.isPaused = true
        markPaused(itemId, true)   // survive relaunch
        downloadSession.getTasksWithCompletionHandler { _, _, downloadTasks in
            for dt in downloadTasks {
                guard let info = Self.parseTaskKey(dt.taskDescription), info.id == itemId else { continue }
                let key = "\(info.id)|\(info.track)"   // in-memory cache key (not the scoped task desc)
                dt.cancel(byProducingResumeData: { data in
                    // Cancelling produces a `.cancelled` error the delegate ignores, so
                    // this doesn't trip retry/fail. Store resume data (memory + disk) to
                    // continue from here, even after the app is relaunched.
                    if let data {
                        self.withCacheLock { self.pausedResumeData[key] = data }
                        self.persistPausedResume(key: key, data: data)
                    }
                })
            }
        }
    }

    /// Resume a paused download, continuing each incomplete track from its resume data
    /// (or restarting it from the original URL if none was produced).
    func resumeDownload(itemId: String) {
        guard let task = activeDownloads[itemId], task.isPaused else { return }
        task.isPaused = false
        markPaused(itemId, false)
        deletePersistedPausedResume(forItem: itemId)   // consumed on resume
        guard let manifest = manifest(for: itemId) else { return }
        for idx in manifest.tracks.indices {
            let dest = trackFileURL(itemId: itemId, trackIndex: idx)
            if fileManager.fileExists(atPath: dest.path) { continue }   // already downloaded
            let key = "\(itemId)|\(idx)"
            let cachedResumeData = withCacheLock { pausedResumeData[key] }
            // Item 9 (REVIEW-2026-09-09-REMAINING.md): a blob that won't parse is dropped
            // and this track falls through to the restart-from-`trackURLs` branch below,
            // rather than handing `downloadTask(withResumeData:)` a truncated blob.
            let resumeData = Self.shouldUseResumeBlob(cachedResumeData) ? cachedResumeData : nil
            if cachedResumeData != nil && resumeData == nil {
                withCacheLock { pausedResumeData[key] = nil }
            }
            let newTask: URLSessionDownloadTask
            if let resumeData {
                newTask = downloadSession.downloadTask(withResumeData: resumeData)
                withCacheLock { pausedResumeData[key] = nil }
            } else if let url = withCacheLock({ trackURLs[key] }) {
                var request = AuthStore.shared.authorizedRequest(url: url)
                request.allowsCellularAccess = !SettingsStore.wifiOnlyDownloads
                newTask = downloadSession.downloadTask(with: request)
            } else {
                continue
            }
            newTask.taskDescription = taskDesc(itemId: itemId, track: idx)
            newTask.resume()
        }
    }

    func removeDownload(itemId: String, userInitiated: Bool = true) {
        // Review Low (removing the playing book, 30 October 2026): the player reads this
        // book's files, so stop it first (the same public `stop()` the account paths use)
        // rather than delete files under it. Only when it is playing from local files.
        let player = AudioPlayerService.shared
        if player.currentItemId == itemId,
           player.currentSession?.audioTracks?.contains(where: { $0.contentUrl?.hasPrefix("file://") == true }) == true {
            player.stop()
            // Review 3 Medium 6: the view model owns currentBook / full player / prefetch.
            NotificationCenter.default.post(name: .shelfheadPlayingDownloadRemoved, object: nil, userInfo: ["itemId": itemId])
        }
        // Review Low (auto-download, 30 October 2026): remember a deliberate removal.
        if userInitiated { markUserRemoved([itemId], true) }
        let itemDir = downloadDirectory(for: itemId)
        try? fileManager.removeItem(at: itemDir)
        downloadedItems.remove(itemId)
        completedTracksCache.removeValue(forKey: itemId)
        // Files are gone — drop the cached size immediately rather than let a stale
        // figure show for the moment before `refreshStorageUsed()`'s walk lands.
        itemStorageBytes.removeValue(forKey: itemId)
        // Item 10 (REVIEW-2026-09-09.md): the cover file went with the directory, so the
        // in-memory flag has to go with it — otherwise `localCoverURL(for:)` would keep
        // handing out a `file://` URL for a cover that no longer exists.
        itemsWithLocalCover.remove(itemId)
        clearProgressThrottleState(itemId: itemId)
        withCacheLock { manifests.removeValue(forKey: itemId) }
        markPaused(itemId, false)
        deletePersistedPausedResume(forItem: itemId)
        saveDownloadedItems()
        // Disk state just changed (a directory was removed) — must walk now regardless
        // of when the last screen-appearance walk ran, so the freed bytes and this
        // item's dropped `itemStorageBytes` entry are reflected promptly rather than
        // possibly waiting out the throttle.
        refreshStorageUsed(force: true)
    }

    /// ARCH-5: previously iterated only `downloadedItems`, so any directory this
    /// dictionary didn't know about — a failed download from before `failDownload`
    /// existed to clean up after itself, or any other orphan — survived "Remove All
    /// Downloads" untouched, even though `refreshStorageUsed()`'s real recursive disk
    /// walk counted its bytes anyway. Removing `downloadsRoot()` wholesale (then
    /// recreating + re-applying backup exclusion/file protection) reclaims everything
    /// under it regardless of whether this dictionary ever knew about it.
    func removeAllDownloads(persist: Bool = true) {
        // Review 2 Low (Remove All while playing, 30 October 2026): same guard as
        // `removeDownload` — stop a book playing from local files before its files go.
        let player = AudioPlayerService.shared
        if player.currentSession?.audioTracks?.contains(where: { $0.contentUrl?.hasPrefix("file://") == true }) == true {
            player.stop()
            // Review 3 Medium 6: no itemId means any current book.
            NotificationCenter.default.post(name: .shelfheadPlayingDownloadRemoved, object: nil)
        }
        // Review Medium 28 (30 October 2026): stop in-flight downloads first, otherwise
        // their rows stay on "Downloading" forever with nothing left to finish them.
        cancelAllActiveDownloads()
        // Review Low (auto-download, 30 October 2026): everything removed here was removed
        // on purpose, so auto-download must not fetch it straight back.
        // Review 2 Low (purged keys, 30 October 2026): `persist: false` (account removal) must
        // not re-create the user-removed / downloaded / failed keys `AccountStore.remove` purged.
        if persist { markUserRemoved(downloadedItems, true) }
        try? fileManager.removeItem(at: downloadsRoot())
        try? fileManager.createDirectory(at: downloadsRoot(), withIntermediateDirectories: true)
        excludeFromBackup(downloadsRoot())
        protectDownloadedFile(at: downloadsRoot())
        clearInMemoryDownloadState()
        UserDefaults.standard.removeObject(forKey: pausedItemsKey())
        // Persisted (rather than purged) because the account stays signed in: an empty
        // list under the *current* scope is the correct end state here. Account removal
        // deliberately does NOT do this — see `deleteDownloads(forScopeKey:wasActiveScope:)`.
        if persist {
            saveDownloadedItems()
            saveFailedDownloads()
        }
        // Every download just got deleted — force past the throttle so "Storage used"
        // and every row's size reflect the empty state immediately.
        refreshStorageUsed(force: true)
    }

    /// Every in-memory collection that describes "what this account has on disk".
    ///
    /// Extracted so account removal can reach exactly the same end state as
    /// `removeAllDownloads()` without also re-persisting empty lists under whichever
    /// scope happens to be current by then (item 12 follow-up). All of these are keyed by
    /// bare item id with no scope in the key, so they only ever describe one account at a
    /// time and must be dropped whenever that account's tree goes away — otherwise
    /// `isDownloaded(itemId:)` keeps answering `true` for books whose files are gone,
    /// which is what `BookDetailView`, `DownloadsView`, the Library `downloadedOnly`
    /// filter and CarPlay's Downloads tab all render from.
    ///
    /// `activeDownloads` is deliberately not in here, matching the previous inline body:
    /// in-flight transfers are stopped by `cancelAllActiveDownloads()`, which every
    /// caller of this pairs with (`AuthViewModel.stopPlaybackAndTransfers()` on the
    /// account paths, `reloadForActiveScope()`'s own `activeDownloads.removeAll()` after
    /// a switch).
    private func clearInMemoryDownloadState() {
        downloadedItems.removeAll()
        failedDownloads.removeAll()
        completedTracksCache.removeAll()
        itemsWithLocalCover.removeAll()
        itemStorageBytes.removeAll()
        lastProgressPublishAt.removeAll()
        withCacheLock {
            manifests.removeAll()
            lastProgressHopAt.removeAll()
        }
    }

    // MARK: - Per-scope deletion (account removal)

    /// Deletes one account's entire download tree, named by its scope key rather than by
    /// "whatever is active right now."
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): removing a saved account purged its scoped
    /// `UserDefaults` keys and its paused-resume blobs but never touched
    /// `Downloads/accounts/<scope>` itself. Nothing else walks a non-active scope —
    /// `refreshStorageUsed()` and `removeAllDownloads()` both only ever see the current
    /// one — so a removed account's downloads became invisible *and* unreclaimable:
    /// potentially many gigabytes that only deleting the whole app would recover.
    ///
    /// Delegates to `removeAllDownloads()` when the scope being deleted is *still* the
    /// active one, since that path also has to recreate the root with its
    /// backup-exclusion and file-protection attributes.
    ///
    /// `wasActiveScope` is how the caller says "this scope was the active one when the
    /// removal started", and it exists because the `scopeKey == currentScopeKey()` test
    /// below cannot detect that case on its own. Item 12 follow-up
    /// (REVIEW-2026-09-09-REMAINING.md): `AuthViewModel.removeAccount(_:)` reaches here
    /// only after `AccountStore.remove` has called `clearCurrent()`, so `currentScopeKey()`
    /// has already degraded to `<server>|unknown` and the comparison always failed —
    /// removing the account you were signed in as deleted the tree with a bare
    /// `removeItem` and left `downloadedItems`, `manifests`, `failedDownloads`,
    /// `itemsWithLocalCover` and the completed-track cache still describing books whose
    /// files no longer exist. Every "is this downloaded?" surface kept saying yes until
    /// something else happened to call `reloadForActiveScope()`.
    ///
    /// Pass `nil` (the default) to keep the old "compare against the live scope"
    /// behaviour for callers that have nothing better to offer.
    func deleteDownloads(forScopeKey scopeKey: String, wasActiveScope: Bool? = nil) {
        // `"unscoped"` is the placeholder `currentScopeKey()` returns before an account is
        // configured; deleting that directory here would be deleting a shared bucket, not
        // one account's data. An empty key would resolve to the `accounts/` parent itself.
        guard Self.isDeletableScopeKey(scopeKey) else { return }
        let activeScopeKey = currentScopeKey()
        if scopeKey == activeScopeKey {
            // Still the scope future downloads would use, so the root has to come back.
            removeAllDownloads(persist: false)   // Review 2 Low (purged keys): the account is going away
            return
        }
        try? fileManager.removeItem(at: downloadsRoot(scopeKey: scopeKey))
        TranscriptStore.deleteAll(forScopeKey: scopeKey)   // Phase 1: the removed account's transcripts go too
        ChapterOverrideStore.deleteAll(forScopeKey: scopeKey)   // Batch 427: so do chapters made on this device
        if Self.scopeDeletionClearsLiveState(scopeKey: scopeKey, activeScopeKey: activeScopeKey,
                                             wasActiveScope: wasActiveScope) {
            // The caller vouched that these caches describe the scope just deleted. Drop
            // them, but deliberately do NOT `saveDownloadedItems()`/`saveFailedDownloads()`
            // afterwards the way `removeAllDownloads()` does: those write under
            // `currentScopeKey()`, which is now the `<server>|unknown` placeholder, and
            // would mint exactly the kind of permanent per-scope `UserDefaults` key that
            // `purgeScopedDefaults` exists to prevent. This scope's own persisted keys are
            // already gone — `AccountStore.remove` purges all four before the teardown
            // that calls this runs.
            //
            // The removed account's root is deliberately not recreated either: nobody is
            // going to download into a deleted account, and an empty directory here would
            // only be picked up by the orphan sweep later.
            clearInMemoryDownloadState()
        }
        // An account's entire tree was just removed from disk (or, for the active
        // scope, delegated to `removeAllDownloads()` above, which forces its own
        // walk) — force past the throttle rather than risk a stale total.
        refreshStorageUsed(force: true)
    }

    /// `deleteDownloads`'s guard, extracted so the two keys that must never be treated as
    /// one account's tree are pinned by a test rather than by an inline `guard`.
    nonisolated static func isDeletableScopeKey(_ scopeKey: String) -> Bool {
        !scopeKey.isEmpty && scopeKey != "unscoped"
    }

    /// Whether deleting `scopeKey`'s tree also has to drop the in-memory download caches,
    /// which are keyed by bare item id and therefore only ever describe the active scope.
    ///
    /// Pure decision, extracted per this project's "extract the decision, test the
    /// decision" precedent — the point being that a caller's `wasActiveScope` has to win
    /// over the live comparison, because the live comparison is exactly what
    /// `AccountStore.clearCurrent()` has already broken by the time account removal gets
    /// here. `nil` means "the caller doesn't know", and falls back to the comparison.
    nonisolated static func scopeDeletionClearsLiveState(
        scopeKey: String, activeScopeKey: String, wasActiveScope: Bool?
    ) -> Bool {
        if let wasActiveScope { return wasActiveScope }
        return scopeKey == activeScopeKey
    }

    /// Directory name of every download scope currently on disk under `accounts/`.
    private nonisolated func existingScopeDirectoryNames() -> [String] {
        let parent = applicationSupportDownloadsRoot().appendingPathComponent("accounts", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent)
    }

    /// Pure decision, extracted so the dangerous part of the sweep below is testable
    /// without a real `accounts/` directory — same "extract the decision, test the
    /// decision" precedent as `shouldReclaimOrphanDirectory`.
    ///
    /// `knownScopeKeys` must contain `currentScopeKey`, and that's checked here rather
    /// than trusted: `knownScopeKeys` is derived from the saved-account list, which comes
    /// out of the Keychain and returns `[]` on any decode/read failure. Reading an empty
    /// list as "every scope on disk is an orphan" would delete every download on the
    /// device, so a list that doesn't even contain the account we're signed in as is
    /// treated as untrustworthy and nothing is reclaimed.
    nonisolated static func shouldReclaimScopeDirectory(
        _ name: String, knownScopeKeys: Set<String>, currentScopeKey: String
    ) -> Bool {
        guard canRunOrphanScopeSweep(knownScopeKeys: knownScopeKeys, currentScopeKey: currentScopeKey) else {
            return false
        }
        guard name != currentScopeKey, name != "unscoped", !name.hasPrefix(".") else { return false }
        return !knownScopeKeys.contains(name)
    }

    /// Whether the orphan sweep can be trusted to run at all, split out of
    /// `shouldReclaimScopeDirectory` so the answer is a single named thing that
    /// `reclaimOrphanedDownloadScopes` can also check up front and log about.
    ///
    /// The rule is unchanged: the saved-account list has to contain the account we are
    /// signed in as before it can be believed, because `AccountStore.accounts()` returns
    /// `[]` on any Keychain read/decode failure and reading that as "every scope on disk
    /// is an orphan" would delete every download on the device.
    ///
    /// Item 12 follow-up (REVIEW-2026-09-09-REMAINING.md): this is `false` for the whole
    /// of a *current-account* removal, and now says so out loud rather than by accident.
    /// `AccountStore.remove` has cleared the current-account id before the sweep is
    /// reached, so `currentScopeKey` is the `<server>|unknown` placeholder and no saved
    /// account can match it — and that is the right answer, since with nobody signed in
    /// there is nothing left to vouch for the list. The residue is reclaimed by the next
    /// removal made while signed in. `AuthViewModel` skips the call entirely in that
    /// case; this guard is the backstop for any other caller.
    nonisolated static func canRunOrphanScopeSweep(
        knownScopeKeys: Set<String>, currentScopeKey: String
    ) -> Bool {
        knownScopeKeys.contains(currentScopeKey)
    }

    /// Reclaims download trees belonging to no saved account — the accumulated residue of
    /// accounts removed by a build that predates `deleteDownloads(forScopeKey:)` above.
    /// Called from the account-lifecycle cleanup routine on account *removal* only (see
    /// `AuthViewModel.tearDownAccountScopedState(reason:)`): sign-out deliberately keeps
    /// downloads, and it is also the one moment where the saved-account list is genuinely
    /// authoritative *and* verifiably intact (it still contains the active account).
    @discardableResult
    func reclaimOrphanedDownloadScopes(knownScopeKeys: Set<String>) -> Int {
        let current = currentScopeKey()
        // Explicit rather than implied by every per-directory decision returning `false`:
        // the sweep is a no-op whenever the saved-account list can't be vouched for,
        // which includes the whole of a current-account removal (see
        // `canRunOrphanScopeSweep`).
        guard Self.canRunOrphanScopeSweep(knownScopeKeys: knownScopeKeys, currentScopeKey: current) else {
            ShelfLog.info(.storage, "Skipped the orphaned-scope sweep: no signed-in account to verify the saved-account list against.")
            return 0
        }
        let reclaimable = existingScopeDirectoryNames().filter {
            Self.shouldReclaimScopeDirectory($0, knownScopeKeys: knownScopeKeys, currentScopeKey: current)
        }
        TranscriptStore.reclaimOrphanedScopes(knownScopeKeys: knownScopeKeys)   // Phase 1: same sweep for transcripts
        ChapterOverrideStore.reclaimOrphanedScopes(knownScopeKeys: knownScopeKeys)   // Batch 427
        guard !reclaimable.isEmpty else { return 0 }
        for scope in reclaimable {
            try? fileManager.removeItem(at: downloadsRoot(scopeKey: scope))
            ShelfLog.info(.storage, "Reclaimed orphaned download scope directory")
        }
        // Reclaimed directories are gone from disk — force past the throttle so
        // `otherScopesStorageBytes` drops right away instead of possibly waiting out
        // a recent screen-appearance walk.
        refreshStorageUsed(force: true)
        return reclaimable.count
    }

    // MARK: - Failed downloads (ARCH-5)

    /// A download that failed permanently (retries exhausted, or an unrecoverable
    /// error) and needs an explicit user action rather than silently vanishing. Before
    /// this existed, a failed download was dropped from `activeDownloads` and never
    /// added to `downloadedItems` either — invisible to `DownloadsView` (which renders
    /// exactly those two collections), with no retry and no way to reclaim the bytes
    /// it still occupied on disk.
    struct DownloadFailure: Codable, Identifiable {
        var id: String { itemId }
        let itemId: String
        let title: String
        let message: String
    }

    var failedDownloads: [String: DownloadFailure] = [:]

    private nonisolated func failedDownloadsKey() -> String { Self.failedDownloadsKey(scope: currentScopeKey()) }

    private func loadFailedDownloads() {
        if let data = UserDefaults.standard.data(forKey: failedDownloadsKey()),
           let items = try? JSONDecoder().decode([String: DownloadFailure].self, from: data) {
            failedDownloads = items
        } else {
            failedDownloads = [:]
        }
    }

    private func saveFailedDownloads() {
        if let data = try? JSONEncoder().encode(failedDownloads) {
            UserDefaults.standard.set(data, forKey: failedDownloadsKey())
        }
    }

    /// What a retry attempt should do with the `DownloadFailure` record it started from.
    ///
    /// Item 8 (REVIEW-2026-09-09-REMAINING.md): the record is the *only* thing that keeps
    /// a permanently-failed download visible in `DownloadsView` and retryable at all, so
    /// it must outlive any retry that didn't actually replace it with a live download.
    enum RetryRecordAction: Equatable {
        /// The retry is now a real in-flight (or already-finished) download. The failure
        /// record has been superseded and should be dropped.
        case removeRecord
        /// Nothing is downloading: the item fetch failed, or `downloadBook` declined to
        /// start. Keep the record so the book stays visible and retryable.
        case keepRecord
    }

    /// Pure decision behind `retryFailedDownload`'s ordering. `removeRecord` requires
    /// *both* halves to have happened — see `retryFailedDownload`'s comment for the bug
    /// that "remove first, then try" caused.
    ///
    /// Pure and `static` so it can be unit-tested without the network or this class's
    /// live state — same precedent as `shouldReclaimOrphanDirectory` / `failureAction`;
    /// see `FailedDownloadRetryTests`.
    nonisolated static func retryOutcome(fetchSucceeded: Bool, enqueued: Bool) -> RetryRecordAction {
        (fetchSucceeded && enqueued) ? .removeRecord : .keepRecord
    }

    /// Re-fetches the item fresh from the server and starts a normal download —
    /// simpler and more robust than trying to reconstruct a `LibraryItem` from the
    /// small amount `DownloadFailure` remembers, and `downloadBook`/`enqueueDownload`
    /// already re-fetch full item detail themselves regardless.
    ///
    /// Item 8 (REVIEW-2026-09-09-REMAINING.md): this used to remove the failure record
    /// (and persist that removal to `shelfhead_failedDownloads.<scope>`) *before* the
    /// fetch, so any retry tapped while offline, against a deleted item (404) or with an
    /// expired session made the row vanish from `DownloadsView` — no download, no retry
    /// path, and nothing left on screen tying the toast to the book. The record is now
    /// dropped only once `downloadBook` has actually produced a live `DownloadTask`
    /// (`retryOutcome`), and the error toast names the book, matching how `failDownload`
    /// surfaces the original failure.
    func retryFailedDownload(itemId: String) async {
        guard let failure = failedDownloads[itemId] else { return }

        var item: LibraryItem? = nil
        do {
            item = try await AudiobookshelfAPI.shared.getItem(itemId: itemId)
        } catch {
            downloadError = String(localized: "Couldn't retry \u{201C}\(failure.title)\u{201D} — couldn't reach the server.", comment: "%@ is the book title")
        }

        var enqueued = false
        if let item {
            downloadBook(item)
            // `downloadBook` inserts into `activeDownloads` synchronously before handing
            // off to its detached `enqueueDownload`, so this is a real answer to "did a
            // download start", not a race. It declines silently-ish in three cases: the
            // Wi-Fi-only policy and the free-space check (both of which post their own,
            // more specific `downloadError` — don't overwrite those), and an id that is
            // already downloading or already downloaded, which is the one case where the
            // record is stale and should go even though this call did nothing.
            enqueued = activeDownloads[item.id] != nil || isDownloaded(itemId: item.id)
        }

        switch Self.retryOutcome(fetchSucceeded: item != nil, enqueued: enqueued) {
        case .removeRecord:
            failedDownloads.removeValue(forKey: itemId)
            saveFailedDownloads()
        case .keepRecord:
            // Re-assert rather than merely leave alone: `downloadBook`'s failure paths are
            // synchronous, but this function has awaited in between, and re-writing is
            // both cheap and the only way to be sure the persisted copy still matches.
            failedDownloads[itemId] = failure
            saveFailedDownloads()
        }
    }

    /// Discards a failed download's record and reclaims whatever partial bytes are
    /// still on disk for it (normally none — `failDownload` already deletes the
    /// directory — but this is defensive in case that step itself failed).
    func removeFailedDownload(itemId: String) {
        failedDownloads.removeValue(forKey: itemId)
        saveFailedDownloads()
        // Fix 3 (REVIEW-2026-09-09.md): same invariant as everywhere else — never
        // delete an item directory for an id that's still in `downloadedItems` without
        // dropping the id too. A record left over from before this fix can name a book
        // that IS downloaded (that was the bug's aftermath), and dismissing that record
        // must not delete the book; `removeDownload` is the deliberate way to do that.
        if !downloadedItems.contains(itemId) {
            try? fileManager.removeItem(at: downloadDirectory(for: itemId))
        }
        // May have just deleted partial bytes on disk — force past the throttle rather
        // than risk under-counting until the next screen-appearance walk.
        refreshStorageUsed(force: true)
    }

    /// ARCH-5: any directory under `downloadsRoot()` not accounted for by
    /// `downloadedItems`, `activeDownloads`, or `failedDownloads` is an orphan — disk
    /// usage accounting still counts its bytes, but nothing in the UI can see it,
    /// retry it, or delete it. Swept once per scope reload; a single non-recursive
    /// directory listing, not a walk.
    /// - Parameter liveTaskItemIds: raw item ids of every in-flight (running or
    ///   suspended) background task the caller's `adoptInFlightDownloads` call just
    ///   found, independent of whether each one made it into `activeDownloads` — a
    ///   second, more conservative guard against deleting a directory for a task
    ///   that's genuinely still live (NEW-1, follow-up review, 14 Aug 2026).
    private func sweepOrphanedDownloadDirectories(additionallyExcluding liveTaskItemIds: Set<String> = []) {
        let root = downloadsRoot()
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        // NEW-2 (follow-up review, 14 Aug 2026): directory names are the *sanitized*
        // item id (see `downloadDirectory(for:)`), but `downloadedItems`/
        // `activeDownloads`/`failedDownloads` all key on the *raw* item id. The
        // previous comment here claimed a sanitized-vs-raw mismatch was "the separate
        // scenario `migrateRawNamedDownloadFoldersIfNeeded()` already handles" — the
        // opposite is true: that function runs immediately before this sweep (see
        // both call sites) and renames a raw-named folder *into* this exact sanitized
        // form, so for any id that isn't already path-safe (a space, non-ASCII
        // character, `%`, `#`, …) the two combined to guarantee the folder looked
        // orphaned and got deleted, right after being correctly migrated. Comparing
        // through the same sanitizer on both sides fixes it for the general case, not
        // just Audiobookshelf's current UUID-only ids.
        let known = Set(
            downloadedItems.union(activeDownloads.keys).union(failedDownloads.keys)
                .map(sanitizedPathComponent)
        )
        let liveTaskDirNames = Set(liveTaskItemIds.map(sanitizedPathComponent))
        for entry in entries {
            guard entry.lastPathComponent != ".paused" else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard !known.contains(entry.lastPathComponent) else { continue }
            // NEW-1 hardening: even with the sweep now sequenced strictly after
            // adoption completes, don't delete a directory whose id was just seen as
            // a live background task — belt-and-suspenders alongside the sequencing
            // fix itself, for any future call site that doesn't thread this through.
            guard !liveTaskDirNames.contains(entry.lastPathComponent) else { continue }
            // P3-1 (third-pass review, 14 Aug 2026): this used to exempt ANY directory
            // holding a manifest, unconditionally — but `enqueueDownload` writes the
            // manifest before creating a single download task (`writeManifest(...)`,
            // checked before the per-track loop), so every real download directory has
            // one from the instant it's created. That made the exemption match every
            // genuine orphan too, turning ARCH-5's reclamation into a permanent no-op:
            // "leaving it for a later sweep," as the old comment here put it, doesn't
            // help when every future sweep reaches the exact same evidence and makes
            // the exact same call, forever — there was no condition under which the
            // guard would ever stop applying.
            //
            // Replaced the blanket exemption with an age test: a manifest younger than
            // `recentManifestGracePeriod` still reads as "in progress, from a source
            // this reload doesn't happen to know about" (a task belonging to a
            // different scope this reload correctly excluded, or one that just started
            // moments ago) — genuinely ambiguous, so it's left alone. Past that age, a
            // directory with no live task and no `known` entry has had a full day to
            // either complete or fail visibly; it isn't ambiguous anymore, it's
            // abandoned, and gets reclaimed like the sweep was always meant to.
            let manifestURL = entry.appendingPathComponent("manifest.json")
            let manifestModified = (try? fileManager.attributesOfItem(atPath: manifestURL.path))?[.modificationDate] as? Date
            guard Self.shouldReclaimOrphanDirectory(manifestModificationDate: manifestModified) else { continue }
            ShelfLog.info(.downloads, "Removing orphaned download directory: \(entry.lastPathComponent)")
            try? fileManager.removeItem(at: entry)
        }
    }

    /// P3-1 (third-pass review, 14 Aug 2026): the pure "is this manifest old enough to
    /// treat as abandoned" decision, split out of `sweepOrphanedDownloadDirectories`
    /// specifically so it can be unit-tested without touching the real filesystem or
    /// this class's instance state — see `DownloadOrphanSweepTests`. The `known`/
    /// `liveTaskDirNames` exclusions above this call are simple `Set` membership checks
    /// already covered by inspection; this is the one piece of logic in the sweep that
    /// actually has a decision boundary (the grace period) worth a real test.
    ///
    /// `nil` (no manifest at all) is always reclaimable — the only case that produces a
    /// directory with no manifest is a manifest write that itself failed, which
    /// `enqueueDownload` already treats as a failed download and cleans up after
    /// itself; anything found here with no manifest is stale by construction, not
    /// merely "recent."
    static func shouldReclaimOrphanDirectory(manifestModificationDate: Date?, now: Date = Date()) -> Bool {
        guard let manifestModificationDate else { return true }
        return now.timeIntervalSince(manifestModificationDate) >= recentManifestGracePeriod
    }

    /// Cancel every in-flight download. Called on account switch / logout so a retry
    /// can't send the new account's token to the previous server's URL.
    func cancelAllActiveDownloads() {
        for itemId in Array(activeDownloads.keys) {
            cancelDownload(itemId: itemId)
        }
    }

    /// Cached total bytes used by all downloaded audio (kept current by `refreshStorageUsed()`).
    /// `@Observable`-tracked, so views reading it re-render when it changes — unlike the old
    /// `totalStorageUsed()`/`formattedStorageUsed()` pair, which did a full recursive
    /// `FileManager.enumerator` disk walk (stat-ing every file) synchronously on whatever
    /// thread called them, including from inside a SwiftUI `body` — and `DownloadsView`
    /// observes `activeDownloads`, whose progress updates continuously while downloading,
    /// so that walk re-ran on every progress tick.
    var totalStorageBytes: Int64 = 0

    var formattedStorageUsed: String {
        ByteCountFormatter.string(fromByteCount: totalStorageBytes, countStyle: .file)
    }

    /// Bytes held by download scopes that AREN'T the active account's — i.e. every other
    /// saved (or previously-removed) account's tree under `Downloads/accounts/`.
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): storage accounting only ever walked the current
    /// scope, so another account's downloads — and in particular a *removed* account's
    /// orphaned tree — were invisible in Settings > Downloads while still occupying the
    /// device. Kept as a separate figure rather than folded into `totalStorageBytes`
    /// because "Storage used" sits next to "Remove All Downloads", which acts on the
    /// current account only; conflating them would make that button look broken.
    var otherScopesStorageBytes: Int64 = 0

    /// Critique 2026-10-06 (harden): bytes held by download scopes kept for servers the user signed out of
    /// (`AccountStore.retainedScopeKeys`, minus any saved again). Already part of
    /// `otherScopesStorageBytes`; measured separately so Settings › Downloads can show it
    /// as its own removable row. Set by `measureSignedOutScopes(_:)`.
    var signedOutScopesStorageBytes: Int64 = 0

    var formattedSignedOutScopesStorage: String {
        ByteCountFormatter.string(fromByteCount: signedOutScopesStorageBytes, countStyle: .file)
    }

    /// Walks each signed-out scope's download tree off the main thread. The caller
    /// supplies the scopes (`AuthViewModel.signedOutServerScopeKeys`), since which
    /// scopes are "signed out" depends on the saved-account list `AuthViewModel` holds.
    func measureSignedOutScopes(_ scopes: Set<String>) {
        // Critique 2026-10-06 (polish): a newer call wins. Without the generation check an
        // older walk finishing late (e.g. the one started before Remove) could put the
        // freed bytes back on screen.
        signedOutMeasureGeneration += 1
        let generation = signedOutMeasureGeneration
        guard !scopes.isEmpty else { signedOutScopesStorageBytes = 0; return }
        let roots = scopes.map { downloadsRoot(scopeKey: $0) }
        Task.detached(priority: .utility) {
            let bytes = roots.reduce(Int64(0)) { $0 + Self.diskUsage(of: $1) }
            await MainActor.run { [weak self] in
                guard let self, self.signedOutMeasureGeneration == generation else { return }
                self.signedOutScopesStorageBytes = bytes
            }
        }
    }
    @ObservationIgnored private var signedOutMeasureGeneration = 0

    /// Cached on-disk byte count per downloaded item in the *current* scope, keyed by
    /// item id — Batch 318 follow-up: `DownloadsView`'s per-row detail line
    /// (`DownloadRowDetail.text(forDuration:bytes:)`) wants a size next to the
    /// duration, but a filesystem stat per row on every `body` pass was exactly the
    /// per-row walk that batch deferred. Populated as a side effect of the SAME
    /// recursive walk `refreshStorageUsed()` already does over `downloadsRoot()` — no
    /// second walk of the whole tree — by attributing each file to the item-id
    /// subdirectory it lives directly under (see `diskUsageByItem(of:knownItemIds:)`).
    /// Additionally kept fresh *between* those (async, `.detached`) walks by two cheap
    /// updates scoped to a single item's own directory: `finalizeIfComplete` (a
    /// download just finished — stat just that directory rather than wait for the next
    /// full walk) and `removeDownload`/`clearInMemoryDownloadState` (files just went
    /// away, so the entry is simply dropped). Rebuilt wholesale — not patched — by
    /// every `refreshStorageUsed()` call, so an account switch (`reloadForActiveScope`,
    /// which reassigns `downloadedItems` for the new scope before calling
    /// `refreshStorageUsed()`) replaces this dictionary for the new scope exactly like
    /// `totalStorageBytes` does, rather than leaking the previous account's entries.
    /// `@Observable`-tracked, like `totalStorageBytes`, so a row's size appears the
    /// moment it's known without any other redraw needing to happen along.
    ///
    /// Per-item-size-at-launch fix: first populated by `bootstrapIfNeeded()`'s own
    /// `refreshStorageUsed()` call at launch, then kept current by `DownloadsView`'s and
    /// `DownloadsSettingsView`'s root `.task`s (screen appearance) alongside the
    /// mutation call sites below — not, as before, solely by the Storage section
    /// scrolling into view, which a long downloads list could delay indefinitely.
    private(set) var itemStorageBytes: [String: Int64] = [:]

    /// Timestamp the most recent `refreshStorageUsed()` walk actually started, used by
    /// `shouldStartStorageWalk` to throttle redundant walks — e.g. the Downloads tab and
    /// its "Download Settings" push destination both appearing within the same second of
    /// navigation shouldn't each kick off their own full recursive disk walk.
    /// `@ObservationIgnored`: throttle bookkeeping, not state any view should re-render
    /// for.
    @ObservationIgnored private var lastStorageWalkStartedAt: Date?

    /// How soon a screen-appearance-triggered `refreshStorageUsed()` call may re-walk
    /// after the previous one started. Callers that know disk state actually changed
    /// (a download finishing, a removal, an account switch — see each call site's own
    /// comment) pass `force: true` and bypass this entirely.
    private static let storageWalkMinimumInterval: TimeInterval = 10

    /// Recomputes `totalStorageBytes` (and `otherScopesStorageBytes`, and
    /// `itemStorageBytes`) off the calling thread. Call on view appear and after
    /// anything that changes what's on disk (a download finishing, removal,
    /// remove-all, deleting an account's scope).
    ///
    /// `force` bypasses the throttle below (see `shouldStartStorageWalk`): pass `true`
    /// from any call site where disk state just changed and the walk must run to stay
    /// correct (every mutation call site in this file does this). Leave it `false` (the
    /// default) at "screen appeared" call sites (`DownloadsView`/`DownloadsSettingsView`'s
    /// root `.task`s, and `bootstrapIfNeeded()`'s launch-time call), where a walk that
    /// already ran moments ago for the same reason would be redundant.
    func refreshStorageUsed(force: Bool = false) {
        let now = Date()
        guard Self.shouldStartStorageWalk(
            lastStartedAt: lastStorageWalkStartedAt, now: now, force: force,
            minimumInterval: Self.storageWalkMinimumInterval
        ) else { return }
        lastStorageWalkStartedAt = now
        let root = downloadsRoot()
        // Fix 5 (REVIEW-2026-09-09.md): the parent of every scope, walked in the same
        // detached task so the "other accounts" figure costs one extra off-main walk on
        // the same schedule rather than a second refresh path of its own.
        let accountsRoot = applicationSupportDownloadsRoot().appendingPathComponent("accounts", isDirectory: true)
        // Snapshot the current scope's known item ids before hopping off-main: the
        // detached walk below needs this set to attribute each file it finds to the
        // item-id subdirectory it lives under (the same convention
        // `downloadDirectory(for:)` uses when writing), and `downloadedItems` is
        // main-actor state that can't be touched from the detached task itself.
        let knownItemIds = downloadedItems
        // `.detached`, not a plain `Task { }`: since this method is now main-actor
        // isolated, a plain `Task { }` created here would inherit the main actor and
        // run the (potentially large) recursive disk walk below on the main thread —
        // exactly the synchronous-disk-walk-on-main regression this method's doc
        // comment says it exists to avoid. `.detached` guarantees the walk itself runs
        // off-main; only the final assignment hops back via `MainActor.run`.
        Task.detached(priority: .utility) {
            let (bytes, perItem) = Self.diskUsageByItem(of: root, knownItemIds: knownItemIds)
            let allScopes = Self.diskUsage(of: accountsRoot)
            // The current scope lives inside `accounts/`, so it's already counted in
            // `allScopes` — subtract rather than walk the siblings individually.
            let others = max(0, allScopes - bytes)
            await MainActor.run { [weak self] in
                self?.totalStorageBytes = bytes
                self?.otherScopesStorageBytes = others
                self?.itemStorageBytes = perItem
            }
        }
    }

    /// Pure decision behind `refreshStorageUsed()`'s throttle, extracted per this
    /// project's "extract the decision, test the decision" precedent (same as
    /// `shouldReclaimOrphanDirectory`) so the interval math is pinned by a test rather
    /// than only exercised by whichever screens happen to appear in what order during
    /// manual testing. `force` always short-circuits to `true`: a caller that knows disk
    /// state changed must never be silently skipped just because a screen-appearance
    /// walk happened to run moments ago.
    nonisolated static func shouldStartStorageWalk(
        lastStartedAt: Date?, now: Date, force: Bool, minimumInterval: TimeInterval
    ) -> Bool {
        guard !force else { return true }
        guard let lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= minimumInterval
    }

    private nonisolated static func diskUsage(of root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Like `diskUsage(of:)`, but also attributes each file's size to the item-id
    /// subdirectory it lives directly under — building the per-item byte counts
    /// alongside the same total, in the same single pass over `root`, rather than a
    /// second recursive walk. `knownItemIds` is the current scope's `downloadedItems`
    /// as of when the walk started (see `refreshStorageUsed()`'s snapshot above).
    ///
    /// The reverse mapping from an on-disk directory name back to an item id can't be
    /// derived by undoing `sanitizedPathComponent(_:)` (its hash-collision fallback
    /// isn't reversible), so this instead builds the forward mapping once — item id ->
    /// sanitized directory name, the exact same function `downloadDirectory(for:)` uses
    /// to write there — for every id already known to be downloaded, then looks each
    /// directory name up in that table while it walks. A directory that doesn't match
    /// any known item (one still downloading, a failed download's leftovers, or an
    /// orphan awaiting the next sweep) still counts toward `total` but is simply
    /// unattributed — `DownloadsView` only ever looks this dictionary up for items it
    /// already knows are downloaded, so there's no row that would want that entry.
    private nonisolated static func diskUsageByItem(
        of root: URL,
        knownItemIds: Set<String>
    ) -> (total: Int64, perItem: [String: Int64]) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, [:])
        }
        var dirNameToItemId: [String: String] = [:]
        dirNameToItemId.reserveCapacity(knownItemIds.count)
        for itemId in knownItemIds {
            dirNameToItemId[DownloadPaths.sanitizedPathComponent(itemId)] = itemId
        }
        let rootPath = root.standardizedFileURL.path
        var total: Int64 = 0
        var perItem: [String: Int64] = [:]
        for case let fileURL as URL in enumerator {
            guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            let bytes = Int64(size)
            total += bytes
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = path.dropFirst(rootPath.count + 1)
            guard let dirName = relative.split(separator: "/", maxSplits: 1).first,
                  let itemId = dirNameToItemId[String(dirName)] else { continue }
            perItem[itemId, default: 0] += bytes
        }
        return (total, perItem)
    }

    func isDownloaded(itemId: String) -> Bool {
        downloadedItems.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        activeDownloads[itemId] != nil
    }

    func progress(for itemId: String) -> Double {
        activeDownloads[itemId]?.progress ?? 0
    }

    // MARK: - Download verification & repair

    /// A Sendable snapshot of one track's expected on-disk location, so the actual
    /// `FileHandle` reads (Item 25, perf review) can run inside a `Task.detached`
    /// closure without capturing `self` or any main-actor state.
    private struct TrackVerificationTarget: Sendable {
        let trackIndex: Int
        let filename: String
        let fileURL: URL
    }

    /// The pure classification step shared by `verifyDownload` (sync) and
    /// `verifyDownloadAsync` (off-main) — kept as one function so the two entry points
    /// can never disagree on the health classification for the same on-disk state.
    private nonisolated static func classifyTracks(_ targets: [TrackVerificationTarget]) -> [DownloadTrackHealth] {
        targets.map { target in
            DownloadTrackHealth(trackIndex: target.trackIndex, filename: target.filename,
                                 issue: fileHealthIssue(at: target.fileURL))
        }
    }

    private nonisolated func verificationTargets(for itemId: String, manifest: DownloadedBook) -> [TrackVerificationTarget] {
        manifest.tracks.map { track in
            TrackVerificationTarget(trackIndex: track.index, filename: track.filename,
                                     fileURL: trackFileURL(itemId: itemId, trackIndex: track.index))
        }
    }

    /// Re-runs a disk-only health check any time after a download has finished (not
    /// just once at download time). Corruption after the fact — a killed app mid-write
    /// to an unrelated file, a flaky external-storage file provider, manual tampering —
    /// can leave a track that reported success originally in a bad state later, and
    /// nothing else in this file ever looks at a finished file again.
    ///
    /// Synchronous and `nonisolated`, but per Item 25 (perf review) that only means it
    /// runs wherever it's *called from* — every existing call site (`DownloadHealthView`'s
    /// per-row buttons, and formerly `repairDownload` below) invokes it directly from a
    /// `@MainActor` context, so its per-track `FileHandle` reads still run on the main
    /// thread. `repairDownload` has been switched to `verifyDownloadAsync` below, which
    /// does the same classification off-main; `DownloadHealthView`'s three call sites
    /// are out of this pass's file scope (Views/Diagnostics/DownloadHealthView.swift) —
    /// switching them to `await verifyDownloadAsync(itemId:)` inside their existing
    /// `Task { }` blocks would close the remaining gap.
    nonisolated func verifyDownload(itemId: String) -> DownloadHealthReport {
        guard let manifest = manifest(for: itemId) else {
            return DownloadHealthReport(itemId: itemId, tracks: [])
        }
        let targets = verificationTargets(for: itemId, manifest: manifest)
        return DownloadHealthReport(itemId: itemId, tracks: Self.classifyTracks(targets))
    }

    /// Off-main counterpart to `verifyDownload(itemId:)` (Item 25, perf review): the
    /// manifest lookup and path resolution are cheap and stay on the caller's actor, but
    /// the actual per-track `FileHandle` reads (`classifyTracks` → `fileHealthIssue`) run
    /// inside a `Task.detached`, so a manual repair's health pass no longer blocks the
    /// main thread for every track in the book. Result semantics are identical to
    /// `verifyDownload` — both funnel through the same `classifyTracks`.
    nonisolated func verifyDownloadAsync(itemId: String) async -> DownloadHealthReport {
        guard let manifest = manifest(for: itemId) else {
            return DownloadHealthReport(itemId: itemId, tracks: [])
        }
        let targets = verificationTargets(for: itemId, manifest: manifest)
        let results = await Task.detached(priority: .utility) {
            Self.classifyTracks(targets)
        }.value
        return DownloadHealthReport(itemId: itemId, tracks: results)
    }

    /// Same checks as `DownloadSessionDelegate.integrityFailureReason` (zero-byte /
    /// HTML-JSON-error-page sniff), minus the `Content-Length` comparison — there's no
    /// `HTTPURLResponse` to compare against for a file that isn't actively downloading.
    /// Not `private`: `DownloadIntegrityTests` calls this directly to pin the
    /// classification independent of the async/sync split above (Item 25).
    nonisolated static func fileHealthIssue(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return String(localized: "Missing", comment: "Download file health issue: the file is missing") }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return String(localized: "Couldn't read the file", comment: "Download file health issue")
        }
        if size == 0 { return String(localized: "Empty file", comment: "Download file health issue") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return String(localized: "Couldn't read the file", comment: "Download file health issue") }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        if let first = head.first, first == UInt8(ascii: "<") || first == UInt8(ascii: "{") {
            return String(localized: "Looks like an error page, not audio", comment: "Download file health issue")
        }
        return nil
    }

    /// Re-downloads only the tracks `verifyDownload` flagged as broken, reusing the same
    /// background-session/redirect-gate/integrity-check machinery as a normal download
    /// (the delegate's `didFinishDownloadingTo` → `storeFinishedTrack` → `finalizeIfComplete`
    /// chain already handles a repaired track exactly like a first-time one). Requires a
    /// fresh call to the server for each broken track's `ino` — the manifest doesn't store
    /// it, only the original per-track filename/duration/offset — so this needs network
    /// access; if it's unreachable, the pre-repair report is returned unchanged rather than
    /// failing silently.
    @discardableResult
    func repairDownload(itemId: String) async -> DownloadHealthReport {
        // Item 25 (perf review): was the synchronous `verifyDownload`, whose per-track
        // `FileHandle` reads ran on this (main-actor) function's own thread. Switched to
        // the async variant, which does that work inside a `Task.detached`.
        let before = await verifyDownloadAsync(itemId: itemId)
        guard !before.isHealthy, AuthStore.shared.isConfigured else { return before }
        guard let detail = try? await AudiobookshelfAPI.shared.getItem(itemId: itemId),
              let audioFiles = detail.media?.audioFiles, !audioFiles.isEmpty else { return before }
        // Same sort as `enqueueDownload` — track indices in the manifest are positional
        // (0..<count after sorting), not the server's own `file.index` field, so the
        // broken track's index must be looked up positionally in this same ordering.
        let ordered = audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        let serverURL = AuthStore.shared.serverURL

        // Fix 9 (REVIEW-2026-09-09.md): this block used to be wrapped in `await
        // MainActor.run { }`, which was a no-op that read as if this function ran
        // off-main — `repairDownload` is not `nonisolated`, so it is already main-actor
        // isolated (inherited from the class) from its first line to its last, and the
        // wrapper bought nothing but an extra suspension point. Removing it also removes
        // the misreading. (The disk work this function does *before* here used to be
        // `verifyDownload`'s per-track `FileHandle` reads, genuinely on the main actor;
        // Item 25 switched this call to `verifyDownloadAsync`, which detaches that work,
        // so this is no longer a residual for the repair path specifically.)
        var createdRepairEntry = false   // Review 7 Low (repair stuck)
        if activeDownloads[itemId] == nil {
            createdRepairEntry = true
            let title = manifest(for: itemId)?.title ?? itemId
            let task = DownloadTask(itemId: itemId, title: title)
            // Fix 3 (REVIEW-2026-09-09.md): a repair's re-download must not be
            // treated as a partial first-time download if it fails — see
            // `failureAction(isRepair:isInDownloadedItems:completedTracks:totalTracks:)`.
            task.isRepair = true
            activeDownloads[itemId] = task
        }
        activeDownloads[itemId]?.isPaused = false
        // Item 10: a repair is the one moment the app re-examines a downloaded book's
        // files, so re-sync the in-memory cover flag while we're here — one stat, and it
        // catches a `cover.jpg` that went missing alongside the broken tracks.
        refreshLocalCoverPresence(itemId: itemId)

        var startedTasks = 0
        for broken in before.brokenTracks {
            let index = broken.trackIndex
            guard index >= 0, index < ordered.count else { continue }
            let file = ordered[index]
            let dest = trackFileURL(itemId: itemId, trackIndex: index)
            try? fileManager.removeItem(at: dest)
            guard let ino = file.ino,
                  let url = URL(string: "\(serverURL)/api/items/\(strictPathComponentEncode(itemId))/file/\(strictPathComponentEncode(ino))/download") else { continue }
            let key = "\(itemId)|\(index)"
            withCacheLock { trackURLs[key] = url }
            var request = AuthStore.shared.authorizedRequest(url: url)
            request.allowsCellularAccess = !SettingsStore.wifiOnlyDownloads
            let downloadTask = downloadSession.downloadTask(with: request)
            downloadTask.taskDescription = taskDesc(itemId: itemId, track: index)
            downloadTask.resume()
            startedTasks += 1
        }
        // Review 7 Low (repair stuck): nothing started, so no delegate callback will ever clear the entry.
        if startedTasks == 0 {
            if createdRepairEntry { activeDownloads[itemId] = nil }
            downloadError = String(localized: "Couldn't repair this download. Try again, or delete and re-download it.")
        }
        return before
    }

    /// The real container extension for a track (from the manifest's original
    /// filename), e.g. "m4b"/"mp3". AVFoundation needs a recognizable extension to
    /// identify a *local* file's format — a generic ".audio" name fails to play.
    private nonisolated func trackExtension(itemId: String, trackIndex: Int) -> String {
        let name = manifest(for: itemId)?.tracks.first(where: { $0.index == trackIndex })?.filename ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "m4b" : ext
    }

    /// Destination file for a downloaded track, named with its real extension.
    private nonisolated func trackFileURL(itemId: String, trackIndex: Int) -> URL {
        downloadDirectory(for: itemId)
            .appendingPathComponent("track_\(trackIndex).\(trackExtension(itemId: itemId, trackIndex: trackIndex))")
    }

    // `nonisolated`: touches only disk state (via `trackFileURL`/`fileManager`), not any
    // main-actor UI state, and is called synchronously from `AudioPlayerService` to
    // resolve local playback URLs — keeping this callable off the main actor avoids a
    // hard dependency on every caller already being on the main actor.
    nonisolated func localFileURL(itemId: String, trackIndex: Int) -> URL? {
        let target = trackFileURL(itemId: itemId, trackIndex: trackIndex)
        if fileManager.fileExists(atPath: target.path) { return target }
        // Migrate a legacy ".audio" file (which AVPlayer can't identify) to the real
        // extension so it becomes playable without a re-download.
        let legacy = downloadDirectory(for: itemId).appendingPathComponent("track_\(trackIndex).audio")
        if fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: target)
            return fileManager.fileExists(atPath: target.path) ? target : legacy
        }
        return nil
    }

    /// A locally-cached cover file (saved at download time) so downloaded books
    /// show their artwork with no network. Nil if not cached.
    ///
    /// **Prefer `localCoverURL(for:)` below.** This one still hits the disk (one
    /// `fileExists` per call), which is fine for a one-off caller but not for the render
    /// path: `shelfCoverURL` (Extensions.swift) calls into here for every visible grid
    /// tile on every `LibraryView.body` pass and about twice a second for the book in the
    /// player, which is the `fileExists`-in-`body` problem item 10
    /// (REVIEW-2026-09-09.md) names. Kept working, and kept as the source of truth the
    /// in-memory set is seeded and re-synced from.
    func localCoverURL(itemId: String) -> URL? {
        // Fast path: only downloaded items can have a cached cover. This avoids a
        // filesystem stat for every non-downloaded cell during fast grid scrolling
        // (shelfCoverURL calls this for every cover).
        guard downloadedItems.contains(itemId) else { return nil }
        let cover = coverFileURL(for: itemId)
        return fileManager.fileExists(atPath: cover.path) ? cover : nil
    }

    /// Item ids known to have a `cover.jpg` on disk.
    ///
    /// Item 10 (REVIEW-2026-09-09.md): the in-memory half of the cover lookup, so a
    /// SwiftUI `body` never has to stat the filesystem to find out whether a book has
    /// local artwork. Maintained at the four moments the answer can change: the cover
    /// write landing (`enqueueDownload`'s detached cover task), a scope load
    /// (`loadDownloadedItems`), a download completing (`finalizeIfComplete`), and a
    /// removal (`removeDownload`/`removeAllDownloads`) — plus a re-sync on repair.
    ///
    /// Deliberately **not** `@ObservationIgnored`, unlike the progress-throttle
    /// bookkeeping: it changes at most once per download, and being observed is exactly
    /// what makes a just-downloaded book's artwork appear rather than waiting for some
    /// unrelated redraw to happen along.
    private var itemsWithLocalCover: Set<String> = []

    /// Where a downloaded book's cover lives. `nonisolated` so the detached cover-write
    /// task in `enqueueDownload` and the seeding helpers can both build the same path.
    private nonisolated func coverFileURL(for itemId: String) -> URL {
        downloadDirectory(for: itemId).appendingPathComponent("cover.jpg")
    }

    /// Writes cover bytes atomically to `itemId`'s `cover.jpg`, applying the same file
    /// protection class every other downloaded file gets, and reports whether the write
    /// actually landed. `nonisolated`, like `coverFileURL` above — called from the
    /// detached cover-fetch tasks in both `enqueueDownload` (first download) and
    /// `refreshLocalCoverIfStale` (cover-versioning fix: re-fetching a replaced cover),
    /// which previously would have had to duplicate this write-plus-protect block.
    private nonisolated func writeCoverFile(_ data: Data, itemId: String) -> Bool {
        guard !data.isEmpty else { return false }
        let coverFile = coverFileURL(for: itemId)
        guard (try? data.write(to: coverFile, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: coverFile.path
        )
        return FileManager.default.fileExists(atPath: coverFile.path)
    }

    /// Cheap, synchronous, **memory-only** cover lookup — no filesystem access at all, so
    /// it is safe to call from a SwiftUI `body` (which is where `shelfCoverURL`, and
    /// therefore every cover in the app, calls it from). Item 10 (REVIEW-2026-09-09.md).
    ///
    /// Unlike `localCoverURL(itemId:)` this does not require the book to be in
    /// `downloadedItems`: the cover is fetched in parallel with the audio and written
    /// atomically, so a book still downloading can legitimately already have complete
    /// local artwork, and there's no reason to make it wait for the last track.
    func localCoverURL(for itemId: String) -> URL? {
        guard itemsWithLocalCover.contains(itemId) else { return nil }
        return coverFileURL(for: itemId)
    }

    /// The same answer as `localCoverURL(for:)` without building a `URL` — for callers
    /// that only need to branch on it.
    func hasLocalCover(itemId: String) -> Bool {
        itemsWithLocalCover.contains(itemId)
    }

    /// Records that `itemId`'s cover is now on disk. Called from the detached cover-write
    /// task in `enqueueDownload` the moment the write lands.
    private func recordLocalCover(itemId: String) {
        // Guarded rather than an unconditional `insert`: Observation doesn't compare
        // values, so re-inserting an id already in the set would still invalidate every
        // view reading it for no change at all.
        guard !itemsWithLocalCover.contains(itemId) else { return }
        itemsWithLocalCover.insert(itemId)
    }

    /// Re-reads one item's cover presence from disk (one stat). For the moments where
    /// something other than this class may have changed the answer — a completed
    /// download, a repair — never from a view body.
    private func refreshLocalCoverPresence(itemId: String) {
        let exists = fileManager.fileExists(atPath: coverFileURL(for: itemId).path)
        if exists {
            recordLocalCover(itemId: itemId)
        } else if itemsWithLocalCover.contains(itemId) {
            itemsWithLocalCover.remove(itemId)
        }
    }

    // MARK: - Cover-versioning fix: refreshing a downloaded book's local cover

    /// Item ids this launch has already attempted a cover refresh for, so a burst of
    /// `CoverVersions.record` calls for the same item (re-visiting its detail page,
    /// several shelves carrying it) triggers at most one network re-fetch per item per
    /// launch. Bookkeeping only — not `@ObservationIgnored`-worthy state a view should
    /// redraw for, same category as `lastProgressHopAt` above.
    @ObservationIgnored private var coverRefreshAttempted: Set<String> = []

    /// True only when there's an actual reason to believe the on-disk cover is stale:
    /// both versions are known and the server's is strictly newer, OR the manifest
    /// predates cover versioning entirely (`manifestVersion == nil`) — a one-time refresh
    /// for books downloaded before this build, since there's no recorded version to
    /// compare against. A `nil` server version means nothing new is known, so this stays
    /// conservative and answers `false` rather than refreshing speculatively.
    ///
    /// Pure and `nonisolated` — no I/O, no actor-isolated state — so it's unit-testable
    /// as a truth table without a real manifest or download.
    nonisolated static func shouldRefreshLocalCover(manifestVersion: Int?, serverVersion: Int?) -> Bool {
        guard let serverVersion else { return false }
        guard let manifestVersion else { return true }
        return serverVersion > manifestVersion
    }

    /// Called (via `CoverVersions.onVersionObserved`, wired in `init()`) whenever the
    /// server reports a newer `updatedAt` for an item than this launch had already seen.
    /// Ignores items that aren't downloaded, and items with no cover fetched yet, and
    /// items already attempted this launch — see `coverRefreshAttempted`.
    @MainActor
    func refreshLocalCoverIfStale(itemId: String, serverUpdatedAt: Int?) {
        guard hasLocalCover(itemId: itemId) else { return }
        guard !coverRefreshAttempted.contains(itemId) else { return }
        guard let book = manifest(for: itemId),
              Self.shouldRefreshLocalCover(manifestVersion: book.coverUpdatedAt, serverVersion: serverUpdatedAt)
        else { return }
        coverRefreshAttempted.insert(itemId)

        guard AuthStore.shared.isConfigured,
              let coverURL = URL(string: "\(AuthStore.shared.serverURL)/api/items/\(percentEncodedPathComponent(itemId))/cover?width=600")
        else { return }
        // Not a background-transfer delegate path (same reasoning as the initial cover
        // fetch in `enqueueDownload`), so the `DownloadManager` exception in CLAUDE.md
        // for `URLSessionDownloadDelegate` transfers doesn't apply — this goes through
        // `AudiobookshelfAPI.authorizedData(for:)`, same as every other authenticated
        // fetch.
        // `DownloadManager.shared` is a singleton that lives for the app's lifetime, same
        // as the equivalent detached cover-fetch task in `enqueueDownload` above — an
        // implicit strong `self` capture here isn't a retention concern.
        Task.detached(priority: .utility) {
            guard let data = try? await AudiobookshelfAPI.shared.authorizedData(for: coverURL), !data.isEmpty,
                  self.writeCoverFile(data, itemId: itemId)
            else { return }
            await MainActor.run {
                self.finishCoverRefresh(itemId: itemId, serverUpdatedAt: serverUpdatedAt)
            }
        }
    }

    /// Main-actor half of `refreshLocalCoverIfStale`: updates the manifest's recorded
    /// version and makes the new bitmap actually show up on screen.
    ///
    /// `shelfCoverURL` bakes the manifest's `coverUpdatedAt` into the local cover's URL
    /// (`coverCacheBustedURL`), so bumping it here is what turns "same file path,
    /// different bytes" into "different URL" for every URL-keyed cache tier. That alone
    /// doesn't repaint an already-rendered tile, though: nothing about the *set* of
    /// downloaded covers changed (the item was already in `itemsWithLocalCover`), so
    /// `@Observable`'s change tracking has nothing to fire on for a currently-visible
    /// `CoverImageView` that already read that property this render. The remove+reinsert
    /// below is a deliberate poke — `recordLocalCover`'s own comment already notes that
    /// Observation's generated setter notifies on every assignment, not just a value
    /// change — which is what makes those tiles actually call `shelfCoverURL` again
    /// (picking up the new versioned URL) instead of only refreshing on some unrelated
    /// redraw.
    @MainActor
    private func finishCoverRefresh(itemId: String, serverUpdatedAt: Int?) {
        guard var book = manifest(for: itemId) else { return }
        let previousURL = coverCacheBustedURL(base: coverFileURL(for: itemId), version: book.coverUpdatedAt)
        book.coverUpdatedAt = serverUpdatedAt
        withCacheLock { manifests[itemId] = book }
        writeManifest(book, for: itemId)
        cachedDownloadedLibraryItems = nil
        CoverImageCache.evict(url: previousURL)
        itemsWithLocalCover.remove(itemId)
        itemsWithLocalCover.insert(itemId)
    }

    /// The saved manifest for a downloaded book (title, chapters, tracks, progress).
    /// `nonisolated`: guarded by `cacheLock`, not main-actor state — must stay callable
    /// synchronously from the background download-delegate queue (see `storeFinishedTrack`).
    nonisolated func manifest(for itemId: String) -> DownloadedBook? {
        if let cached = withCacheLock({ manifests[itemId] }) { return cached }
        // Disk read stays outside the lock (two concurrent misses just decode the same
        // file — harmless — rather than blocking on I/O while holding the lock).
        let url = downloadDirectory(for: itemId).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode(DownloadedBook.self, from: data) else {
            return nil
        }
        withCacheLock { manifests[itemId] = book }
        return book
    }

    /// A LibraryItem (with cached progress) for a downloaded book — for listing it
    /// in the Library/Downloads and opening it offline.
    func libraryItem(for itemId: String) -> LibraryItem? {
        manifest(for: itemId)?.asLibraryItem()
    }

    /// UI-9 (REVIEW_2026-08-12.md): `downloadedLibraryItems()` is called from
    /// `DownloadsView.body`, so with the view visible it re-ran on *every* re-render —
    /// including every progress tick from any in-progress download — doing N
    /// `asLibraryItem()` allocations plus an O(N log N) **locale-aware**
    /// `localizedCaseInsensitiveCompare` sort, one of the more expensive comparators in
    /// Foundation. Cached here and invalidated by `saveDownloadedItems()`/
    /// `loadDownloadedItems()` below — the two functions every real mutation of
    /// `downloadedItems` already routes through (`removeDownload`, `removeAllDownloads`,
    /// `finalizeIfComplete` on download completion, and `reloadForActiveScope`'s account
    /// switch), so a future mutation site that forgets to invalidate directly still
    /// can't leave this stale as long as it persists the change the normal way.
    private var cachedDownloadedLibraryItems: [LibraryItem]?

    /// All downloaded books as LibraryItems, title-sorted.
    func downloadedLibraryItems() -> [LibraryItem] {
        if let cached = cachedDownloadedLibraryItems { return cached }
        let items = downloadedItems
            .compactMap { manifest(for: $0)?.asLibraryItem() }
            // UI-9: `localizedCaseInsensitiveCompare` does a full locale-aware
            // comparison (case AND diacritic folding); `localizedStandardCompare` is
            // the one Finder/Foundation actually recommend for sorting user-facing
            // strings — it additionally handles embedded numbers the way a person
            // expects ("Book 2" before "Book 10"), for no extra cost over the
            // comparator this replaces.
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        cachedDownloadedLibraryItems = items
        return items
    }

    /// Builds a fully-offline playback session from local files. `nonisolated`: only
    /// touches the disk-backed manifest cache, not main-actor state.
    nonisolated func localSession(for itemId: String) -> PlaybackSession? {
        guard let book = manifest(for: itemId) else { return nil }
        return book.localSession { [weak self] index in
            self?.localFileURL(itemId: itemId, trackIndex: index)
        }
    }

    /// Persist the last playback position so an offline resume is accurate.
    /// `nonisolated`: called synchronously from `AudioPlayerService`'s playback-progress
    /// path; only touches the disk-backed manifest cache, not main-actor state.
    nonisolated func updateLocalProgress(itemId: String, currentTime: Double) {
        guard var book = manifest(for: itemId) else { return }
        book.currentTime = currentTime
        book.lastUpdate = Date().timeIntervalSince1970 * 1000
        withCacheLock { manifests[itemId] = book }
        writeManifest(book, for: itemId)
    }

    /// Writes the manifest to disk and reports whether it actually landed. Returns
    /// `Bool` (rather than swallowing the failure with a bare `try?`) because the
    /// *first* write of a manifest — done by `enqueueDownload` before any track
    /// downloads are enqueued — is load-bearing: everything downstream (progress
    /// tracking, `finalizeIfComplete`, relaunch recovery) assumes a manifest exists
    /// once a download is "in progress". `@discardableResult` so the routine re-save
    /// in `updateLocalProgress` (encode+persist the current playback position) can
    /// keep ignoring the result — a failed progress save just means resume picks up
    /// from a slightly stale position next time, not a download that silently isn't
    /// tracked at all.
    @discardableResult
    private nonisolated func writeManifest(_ book: DownloadedBook, for itemId: String) -> Bool {
        let url = downloadDirectory(for: itemId).appendingPathComponent("manifest.json")
        guard let data = try? JSONEncoder().encode(book) else { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            ShelfLog.error(.downloads, "Failed to write manifest for \(itemId): \(error.localizedDescription)")
            return false
        }
        protectDownloadedFile(at: url)
        return true
    }

    /// Last-write-wins reconciliation between local (offline) progress and the
    /// server's progress. Pushes newer local progress up; pulls newer server
    /// progress down into the manifest. Silent last-write-wins is right for the common
    /// case (one device, occasional drift), but it can silently throw away real
    /// listening if the two sides diverge by a lot — e.g. you listened offline on a
    /// flight (racking up local progress) while a household member or the web player
    /// also advanced the same book's progress on the server. In that case, whichever
    /// timestamp happens to be a few seconds newer wins and quietly discards the other
    /// side's position instead of asking. When the two positions differ by more than
    /// `conflictThreshold` *and* the gap isn't explained by one side having simply
    /// listened on past the other (see `ProgressReconciler.isUnexplainedDivergence` —
    /// fix 2.3, REVIEW-2026-09-09.md: divergence alone used to be enough, which turned
    /// every offline listen longer than five minutes into a prompt), this skips
    /// auto-resolving that book and surfaces `pendingProgressConflict` instead, letting
    /// `resolveProgressConflict(_:keepLocal:)` make the final call explicitly.
    /// Internal (not `private`) so `AudioPlayerService.flushPendingProgress` can apply
    /// the same threshold to queued offline positions — a queued position more than this
    /// far *behind* the server's must not be pushed while a conflict prompt is pending.
    static let conflictThreshold: Double = 5 * 60   // 5 minutes of listening

    /// Review 6 Medium 5: pure check — an account switch mid-sweep changes the scope key.
    nonisolated static func sweepScopeUnchanged(entry: String, current: String) -> Bool { entry == current }

    /// Polish pass (J2-7): decodes the manifests that aren't in the in-memory cache yet.
    /// `nonisolated` and run off the main actor by `reconcile`; a decode only fills a
    /// cache slot that is still empty (re-checked under the lock), so it can never replace
    /// a manifest the main actor updated meanwhile (e.g. a freshly pulled position).
    nonisolated func preloadManifests(ids: [String]) {
        for itemId in ids {
            if withCacheLock({ manifests[itemId] != nil }) { continue }
            let url = downloadDirectory(for: itemId).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url),
                  let book = try? JSONDecoder().decode(DownloadedBook.self, from: data) else { continue }
            withCacheLock { if manifests[itemId] == nil { manifests[itemId] = book } }
        }
    }

    func reconcile(serverProgress: [String: MediaProgress]) async {
        let entryScope = currentScopeKey()   // Review 6 Medium 5
        // Polish pass (J2-7): the manifest cache starts empty each launch (nothing preloads
        // it), so this sweep's first `manifest(for:)` per book used to read and JSON-decode
        // every manifest synchronously on the main actor during the launch chain. Warm the
        // cache off-main first; the loop below then only hits the cache.
        let uncached = downloadedItems.filter { id in withCacheLock { manifests[id] == nil } }
        if !uncached.isEmpty {
            let ids = Array(uncached)
            await Task.detached(priority: .utility) { [self] in preloadManifests(ids: ids) }.value
        }
        // Books whose divergence the user (or an earlier pass of this function) has
        // already decided, and whose push is only queued for retry — read once per pass,
        // not per book. See the `.conflict` branch below for why that matters.
        let alreadyResolved = await PendingProgressQueue.shared
            .resolvedConflictItemIds(forScope: currentScopeKey())
        // Snapshot ids so we don't mutate the set while iterating (auto-delete below).
        for itemId in Array(downloadedItems) {
            // Review 6 Medium 5: stop if the account changed during an earlier await; this
            // account's progress must not touch the new account's downloads.
            guard Self.sweepScopeUnchanged(entry: entryScope, current: currentScopeKey()) else { return }
            guard var book = manifest(for: itemId) else { continue }
            let server = serverProgress[itemId]
            let serverMs = Double(server?.lastUpdate ?? 0)
            let localMs = book.lastUpdate ?? 0

            // §8 decomposition (REVIEW_2026-08-12.md): the actual push/pull/conflict
            // decision now lives in `ProgressReconciler.reconcile` — a pure, unit-tested
            // function (see `ProgressReconcilerTests.swift`) shared with
            // the "which side is newer" primitive.
            // This function still owns every actual mutation (network call, manifest
            // write, `pendingProgressConflict`) using its own full `server`/`book`
            // values — only the *decision* moved out.
            let outcome = ProgressReconciler.reconcile(
                localTime: book.currentTime, localLastUpdate: localMs, localDuration: book.duration,
                serverEntryExists: server != nil, serverTime: server?.currentTime,
                serverLastUpdate: serverMs, serverIsFinished: server?.isFinished ?? false,
                conflictThreshold: Self.conflictThreshold
            )

            switch outcome {
            case .conflict:
                // Reached only when both sides genuinely have a position to lose: the
                // gap is past the threshold, the server copy isn't finished, and the
                // side that wrote most recently is the side that's *behind*, so neither
                // a push nor a pull can be made without moving the book backwards past
                // the threshold (see `ProgressReconciler`). A fresh download, a book
                // neither side has touched, plain offline listening, and progress made
                // on another device while this one sat idle all resolve silently above
                // and never land here.
                //
                // …with one exception. If the user has *already* answered this book's
                // prompt with "Keep This Device" and that push failed (offline, a
                // transient error), the position is sitting in `PendingProgressQueue`
                // flagged `conflictResolved`, waiting to retry. Nothing about the manifest
                // or the server has changed since, so the inputs above still say
                // `.conflict` — and without this guard the very next library refresh would
                // ask the same question again, and again after that, while the answer they
                // already gave was queued and on its way.
                //
                // Polish pass (DL-6): "Ask Me Later" used to just nil the pending value, so
                // this very block re-raised it on the next reconcile. A snoozed conflict
                // stays quiet until either side's position or timestamp changes; either
                // way it falls through to the `continue` below, so a snoozed book is never
                // pushed or pulled.
                if !alreadyResolved.contains(itemId), pendingProgressConflict == nil {
                    let conflict = ProgressConflict(
                        itemId: itemId, title: book.title,
                        localTime: book.currentTime, serverTime: server?.currentTime ?? 0,
                        duration: book.duration > 0 ? book.duration : (server?.duration ?? 0),
                        localLastUpdate: localMs > 0 ? localMs : nil,
                        serverLastUpdate: serverMs > 0 ? serverMs : nil
                    )
                    if ProgressConflict.shouldRaise(snoozed: snoozedConflicts[itemId], current: conflict.stamp) {
                        snoozedConflicts.removeValue(forKey: itemId)
                        lastRaisedConflicts[itemId] = conflict.stamp
                        pendingProgressConflict = conflict
                    }
                }
                // Leave this one alone until the user decides — don't auto-pick a side.
                continue
            case .pushLocal:
                let progress = min(book.currentTime / book.duration, 1.0)
                // Fix 2.2 (REVIEW-2026-09-09.md): this used to be a bare `try?`. Since
                // fix 2.3 made ordinary offline listening resolve as `.pushLocal` instead
                // of raising a conflict, this branch is now the main way an offline
                // listen gets back to the server — so a failed push has to survive as a
                // queued entry rather than being dropped. Deliberately no toast here
                // (unlike `resolveProgressConflict(_:keepLocal:)`): `reconcile` is a
                // background sweep over every downloaded book, run on any library
                // load/refresh, so a per-book toast for something the user never asked
                // for and that will retry itself would be noise.
                //
                // The scope is captured here, synchronously, before the `await` below —
                // `PendingProgressQueue`'s contract (see its doc comment) is that the
                // caller resolves "which server+account is this for" at the moment it
                // captures the position, never later from inside a suspended task.
                let scope = currentScopeKey()
                // `conflictResolved: true` — this entry is the retry of a decision
                // `ProgressReconciler.reconcile` just made with the full picture (both
                // positions, both timestamps, and `serverIsFinished`), so
                // `AudioPlayerService.flushPendingProgress`'s coarser "is this behind the
                // server?" hold-back must not overrule it. It matters for exactly the
                // shapes the flush can't see: a server copy marked finished (which
                // suppresses `.conflict` outright) while this device is legitimately
                // earlier in the book, and a server entry with no `currentTime`. Ordinary
                // offline listening — the overwhelmingly common `.pushLocal` — is ahead of
                // the server anyway and was never going to be held.
                let entry = PendingProgressQueue.Entry(
                    scope: scope, itemId: itemId, currentTime: book.currentTime,
                    duration: book.duration, updatedAt: Date().timeIntervalSince1970,
                    conflictResolved: true)
                do {
                    try await AudiobookshelfAPI.shared.updateProgress(
                        libraryItemId: itemId,
                        progress: progress,
                        currentTime: book.currentTime,
                        duration: book.duration,
                        isFinished: server?.isFinished ?? false,
                        expectedScope: scope   // Review 5 Low (Keep scope)
                    )
                } catch {
                    ShelfLog.error(.sync, "Couldn't push local progress for \(itemId); queued for retry: \(error.localizedDescription)")
                    await PendingProgressQueue.shared.record(entry)
                }
            case .pullServer:
                book.currentTime = server?.currentTime ?? book.currentTime
                book.lastUpdate = serverMs
                withCacheLock { manifests[itemId] = book }
                writeManifest(book, for: itemId)
            case .noAction:
                break
            }
        }

        // Auto-delete finished downloads (not the one currently playing).
        if SettingsStore.autoDeleteFinished,
           Self.sweepScopeUnchanged(entry: entryScope, current: currentScopeKey()) {   // Review 6 Medium 5
            // No `await` needed: `reconcile` isn't `nonisolated`, so it already runs on
            // the main actor (inherited from `DownloadManager`'s `@MainActor`), same as
            // `AudioPlayerService` — same-actor access doesn't require hopping.
            let playingId = AudioPlayerService.shared.currentItemId
            let finished = Array(downloadedItems).filter {
                serverProgress[$0]?.isFinished == true && $0 != playingId
            }
            // Fix 9 (REVIEW-2026-09-09.md): was `await MainActor.run { }`, another no-op
            // hop — `reconcile` is main-actor isolated already (see the comment just
            // above about `AudioPlayerService`), so the wrapper only added a suspension
            // point in the middle of a deletion loop and suggested, wrongly, that the
            // surrounding sweep runs somewhere else.
            for itemId in finished { removeDownload(itemId: itemId, userInitiated: false) }
        }
    }

    /// Polish pass (DL-6): conflicts the user answered "Ask Me Later", keyed by item id,
    /// with the state they were in. In-memory (a relaunch asks again, which is fine).
    @ObservationIgnored private var snoozedConflicts: [String: ProgressConflict.Stamp] = [:]
    /// The state each conflict was in when last raised, so `snoozeConflict` doesn't depend
    /// on `pendingProgressConflict` still being set (the alert's `isPresented` setter nils
    /// it as the alert dismisses, possibly before the button's action runs).
    @ObservationIgnored private var lastRaisedConflicts: [String: ProgressConflict.Stamp] = [:]

    /// Polish pass (DL-6): "Ask Me Later". Clears the pending prompt and stops `reconcile`
    /// re-raising it until either side's position or timestamp changes. Does not push or
    /// pull anything.
    func snoozeConflict(itemId: String) {
        if let stamp = lastRaisedConflicts[itemId] ?? pendingProgressConflict.flatMap({ $0.itemId == itemId ? $0.stamp : nil }) {
            snoozedConflicts[itemId] = stamp
        }
        if pendingProgressConflict?.itemId == itemId { pendingProgressConflict = nil }
    }

    /// Resolves a progress conflict in the direction the user picked. `keepLocal`
    /// pushes this device's position to the server (same request `reconcile`'s normal
    /// "local is newer" branch makes); otherwise pulls the server's position down into
    /// the local manifest. Either way, the conflict is cleared so it stops blocking that
    /// book's normal reconciliation on the next pass.
    ///
    /// Fix 2.1 (REVIEW-2026-09-09.md): takes the `conflict` as a **parameter** rather
    /// than re-reading `pendingProgressConflict`. SwiftUI's `.alert(_:isPresented:
    /// presenting:)` nils the presented value through its `isPresented` setter
    /// *synchronously* as the alert dismisses — before the `Task` a button action spawns
    /// ever gets to run — so the old `guard let conflict = pendingProgressConflict else
    /// { return }` always bailed out and both "Keep This Device" and "Use Server" were
    /// silent no-ops, with the same prompt returning on the next reconcile. The alert's
    /// button closures already receive the exact `conflict` they were built for, so
    /// passing it in removes the shared-state read entirely.
    ///
    /// The clear is conditional on `pendingProgressConflict` still being *this*
    /// conflict rather than unconditional: by the time this runs it is normally already
    /// nil (dismissal), and a `reconcile` pass that landed in between could have
    /// legitimately queued a *different* book's conflict into the single slot. Nilling
    /// that unconditionally would swallow a prompt the user never saw.
    func resolveProgressConflict(_ conflict: ProgressConflict, keepLocal: Bool) async {
        if pendingProgressConflict?.itemId == conflict.itemId {
            pendingProgressConflict = nil
        }
        if !keepLocal {
            // Review Medium 15 (30 October 2026): Use Server answers the held-back queue
            // entry too; left queued, it lingered as a phantom pending sync.
            await PendingProgressQueue.shared.discardAudioEntry(itemId: conflict.itemId, scope: currentScopeKey())
        }
        if keepLocal {
            let progress = conflict.duration > 0 ? min(conflict.localTime / conflict.duration, 1.0) : 0
            // Fix 2.2: was a bare `try?`, so choosing "Keep This Device" while offline
            // (the single most likely moment to be asked this question) threw the choice
            // away silently and let the next reconcile re-raise the same prompt. Now the
            // position lands in `PendingProgressQueue` — the same queue
            // `AudioPlayerService` uses for a failed live sync, flushed on connectivity
            // restore/foreground — and the failure is surfaced through `downloadError`,
            // which `MainTabView` already presents as a toast. `downloadError` rather
            // than a new channel: it's this type's one existing user-visible error
            // surface, and this is an explicit user action, not a background sweep.
            //
            // Scope captured synchronously before the `await`, per
            // `PendingProgressQueue`'s documented contract.
            let scope = currentScopeKey()
            // `conflictResolved: true` — the user has answered this exact divergence, so
            // the queued retry must not be held back by
            // `AudioPlayerService.flushPendingProgress`'s hold-back (which exists for
            // positions nobody has decided on yet), and `reconcile` above must not re-ask
            // while it's still queued. A *later* server write still wins over it; see
            // `PendingProgressQueue.disposition`.
            let entry = PendingProgressQueue.Entry(
                scope: scope, itemId: conflict.itemId, currentTime: conflict.localTime,
                duration: conflict.duration, updatedAt: Date().timeIntervalSince1970,
                conflictResolved: true)
            do {
                try await AudiobookshelfAPI.shared.updateProgress(
                    libraryItemId: conflict.itemId,
                    progress: progress,
                    currentTime: conflict.localTime,
                    duration: conflict.duration,
                    isFinished: false,
                    expectedScope: scope   // Review 5 Low (Keep scope)
                )
            } catch is AccountChangedError {
                // Review 6 Low (Keep This Device toast): account switched mid-push; the
                // queued entry is fine and "couldn't reach the server" would be wrong.
                await PendingProgressQueue.shared.record(entry)
            } catch {
                ShelfLog.error(.sync, "Couldn't push the kept position for \(conflict.itemId); queued for retry: \(error.localizedDescription)")
                await PendingProgressQueue.shared.record(entry)
                downloadError = String(localized: "Couldn't reach the server — this device's position for \u{201C}\(conflict.title)\u{201D} will be sent when you're back online.", comment: "%@ is the book title")
            }
        } else if var book = manifest(for: conflict.itemId) {
            book.currentTime = conflict.serverTime
            book.lastUpdate = Date().timeIntervalSince1970 * 1000
            withCacheLock { manifests[conflict.itemId] = book }
            writeManifest(book, for: conflict.itemId)
        }
    }

    // MARK: - Download Logic (background URLSession)

    /// Review Medium 27 (30 October 2026): true while the download is still tracked and not
    /// cancelled. Used after each `await` in `enqueueDownload`.
    /// Review 2 Low (cancel-then-restart, 30 October 2026): also requires the entry to be the
    /// same start (`runId`), so a cancel followed by a fresh start of the same book doesn't
    /// let the old `enqueueDownload` carry on alongside the new one.
    private nonisolated func downloadStillWanted(itemId: String, runId: UUID) async -> Bool {
        await MainActor.run {
            Self.isSameLiveRun(entry: activeDownloads[itemId].map { ($0.runId, $0.isCancelled) }, runId: runId)
        }
    }

    /// Pure decision behind `downloadStillWanted` and the retry re-check.
    nonisolated static func isSameLiveRun(entry: (runId: UUID, isCancelled: Bool)?, runId: UUID) -> Bool {
        guard let entry else { return false }
        return entry.runId == runId && !entry.isCancelled
    }

    /// Fetches the item, writes the manifest up front, then enqueues a background
    /// download task per audio file. Completion is handled by the session delegate
    /// (so it survives app suspension/relaunch).
    ///
    /// ARCH-6 (follow-up review, 14 Aug 2026): `nonisolated`, per the original
    /// review's ask — this used to be a plain (main-actor-isolated, inherited from
    /// `DownloadManager`'s own `@MainActor`) `private func`, so its several `await
    /// MainActor.run { … }` blocks were no-op hops: the surrounding function was
    /// already running on the main actor, so wrapping something in
    /// `MainActor.run` from inside it didn't move that work anywhere. That meant
    /// `createDirectory`, the full manifest JSON encode + atomic write, and a
    /// `fileExists` check per track all ran on the main thread for every single
    /// download start. Every other call this function makes was confirmed
    /// nonisolated-safe already: `AuthStore` (its own `@unchecked Sendable` class
    /// with internal locking), `AudiobookshelfAPI` (its own actor), `SettingsStore`
    /// (a plain enum reading `UserDefaults` directly), and this file's own
    /// `fileManager`/`writeManifest`/`trackFileURL`/`excludeFromBackup`/
    /// `protectDownloadedFile`/`taskDesc`/`downloadsRoot`/`withCacheLock`-guarded
    /// caches (all already `nonisolated`). The one genuine exception is
    /// `downloadSession` itself — a plain (main-actor-isolated) `lazy var` — hopped
    /// once before the per-track loop below instead of per-iteration.
    ///
    /// Fix 9 (REVIEW-2026-09-09.md): `nonisolated` on its own is **no longer sufficient**
    /// to keep any of that off the main thread — with `NonisolatedNonsendingByDefault`
    /// (on via `SWIFT_APPROACHABLE_CONCURRENCY`) a plain `nonisolated async` function runs
    /// wherever its caller runs. Originally worked around by requiring `downloadBook` (the
    /// only caller) to start this with `Task.detached`, with an `assert` below as the
    /// backstop against a future caller forgetting to detach.
    ///
    /// Item 27 (perf review): `@concurrent` states the same "runs off any actor" contract
    /// at the declaration instead of at the call site, so `downloadBook` now starts this
    /// with a plain `Task { }`. If `@concurrent` turns out not to compile in this
    /// project's Swift 5 language mode / `SWIFT_STRICT_CONCURRENCY = targeted` setup,
    /// revert by removing the `@concurrent` attribute below and changing `downloadBook`'s
    /// `Task { await self.enqueueDownload(item, runId: runId) }` back to
    /// `Task.detached { await self.enqueueDownload(item) }`. The `assert` stays either way.
    @concurrent
    private nonisolated func enqueueDownload(_ item: LibraryItem, runId: UUID) async {
        #if DEBUG
        assert(!Thread.isMainThread,
               "enqueueDownload must run off the main actor — it's marked @concurrent and started from downloadBook; if this fires, that contract broke.")
        #endif
        guard AuthStore.shared.isConfigured else {
            await MainActor.run {
                // Review 3 Low (enqueue runId): only the live run may drop the row.
                if Self.isSameLiveRun(entry: activeDownloads[item.id].map { ($0.runId, $0.isCancelled) }, runId: runId) {
                    _ = activeDownloads.removeValue(forKey: item.id)
                }
                downloadError = "You're not signed in."
            }
            return
        }
        let serverURL = AuthStore.shared.serverURL

        do {
            let detail = try await AudiobookshelfAPI.shared.getItem(itemId: item.id)
            // Review Medium 27 (30 October 2026): the user may have cancelled while the
            // details loaded; bail before anything is created on disk.
            guard await downloadStillWanted(itemId: item.id, runId: runId) else { return }
            guard let audioFiles = detail.media?.audioFiles, !audioFiles.isEmpty else {
                await MainActor.run {
                    // Review 3 Low (enqueue runId)
                    if Self.isSameLiveRun(entry: activeDownloads[item.id].map { ($0.runId, $0.isCancelled) }, runId: runId) {
                        _ = activeDownloads.removeValue(forKey: item.id)
                    }
                    downloadError = String(localized: "No audio files were returned for “\(item.title)”.", comment: "%@ is the book title")
                }
                return
            }
            let ordered = audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            let itemDir = downloadDirectory(for: item.id)
            try? fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)
            excludeFromBackup(downloadsRoot())
            // File-protection class is applied recursively-by-convention here (every
            // write into `itemDir` below re-applies it to the specific file it just
            // wrote, since the OS doesn't propagate a directory's protection class to
            // files created inside it after the fact) — see `protectDownloadedFile`.
            protectDownloadedFile(at: itemDir)

            // Build + persist the manifest immediately so completion checks work even
            // if the app is relaunched in the background mid-download.
            var tracks: [DownloadedBook.DownloadedTrack] = []
            var offset: Double = 0
            for (index, file) in ordered.enumerated() {
                let dur = file.duration ?? 0
                tracks.append(.init(index: index, startOffset: offset, duration: dur,
                                    filename: file.metadata?.filename ?? "track_\(index)"))
                offset += dur
            }
            let manifest = DownloadedBook(
                id: item.id, title: detail.title, author: detail.authorName,
                narrator: detail.narratorName, duration: detail.duration,
                chapters: detail.chapters, tracks: tracks,
                currentTime: detail.currentTime,
                lastUpdate: detail.mediaProgress?.lastUpdate.map(Double.init),
                // Item 11 (REVIEW-2026-09-09-REMAINING.md): `detail.chapters` is the
                // already-filtered list — any chapter the server sent in an unusable
                // shape was dropped when this payload decoded. Recording how many were
                // dropped is the only way the offline book can still explain why its
                // chapter list is short; there is no server payload to re-derive it from
                // once the download is playing offline.
                droppedChapterCount: detail.droppedChapterCount,
                // Cover-versioning fix: the cover about to be fetched below is whatever
                // the server had at this `updatedAt` — recording it here means a later
                // artwork replacement (a newer `updatedAt` seen through `CoverVersions`)
                // is detectable by `shouldRefreshLocalCover` without a separate fetch
                // just to find out.
                coverUpdatedAt: detail.updatedAt
            )
            // Batch 422: the manifest doesn't carry the book's language, so record it for
            // the transcriber (overnight runs never see the LibraryItem).
            if let language = detail.media?.metadata?.language, !language.isEmpty {
                TranscriptStore.updateMeta(itemId: item.id) { $0.bookLanguage = language }
            }
            // The manifest write is load-bearing, not best-effort: `finalizeIfComplete`,
            // `completedTrackCount`, and every relaunch-time reconstruction of "is this
            // book downloaded" all read the manifest back off disk. A `try?`-and-forge-
            // ahead here used to mean a full disk / permissions failure would silently
            // start downloading tracks for a book with no manifest to ever mark complete
            // — after relaunch (or even immediately, since `manifest(for:)` re-reads from
            // disk on a cache miss) the in-progress download would just vanish with no
            // error shown. Treat a failed manifest write as a failed download instead.
            guard writeManifest(manifest, for: item.id) else {
                await MainActor.run {
                    // Review 4 Low (manifest failure guard): only the live run may drop the row.
                    guard Self.isSameLiveRun(entry: activeDownloads[item.id].map { ($0.runId, $0.isCancelled) }, runId: runId) else { return }
                    _ = activeDownloads.removeValue(forKey: item.id)
                    downloadError = String(localized: "Couldn't start the download for “\(item.title)” (couldn't save its manifest).", comment: "%@ is the book title")
                }
                return
            }
            withCacheLock { manifests[item.id] = manifest }

            // Cache the cover art for offline display (best-effort; build the remote
            // URL directly so we don't pick up a not-yet-written local file). Token rides
            // in the Authorization header, not the query string. A failed cover write is
            // deliberately left as `try?`/best-effort (unlike the manifest above): the
            // only consequence is falling back to a network fetch for the cover image
            // next time it's shown, not a book that silently isn't downloaded.
            //
            // ARCH-6: fired as its own detached task rather than `await`ed inline — this
            // used to block the track-enqueue loop below behind a full cover fetch
            // (network round trip + disk write) before the first audio byte ever started
            // downloading. The cover and the tracks don't depend on each other, so there's
            // no reason for one to serialize behind the other; `protectDownloadedFile`
            // and the file write are both nonisolated/thread-safe already.
            let coverItemId = item.id
            if let coverURL = URL(string: "\(serverURL)/api/items/\(percentEncodedPathComponent(item.id))/cover?width=600") {
                Task.detached(priority: .utility) {
                    // Item 6 (REVIEW-2026-09-09 remaining, integration sweep): this was a
                    // raw `URLSession.shared.data(for:)` that ignored the HTTP status, so
                    // an expired token's 401 body (HTML/JSON) was written to disk as
                    // `cover.jpg` and served as the offline cover until the book was
                    // re-downloaded. `authorizedData` refreshes-and-retries once on 401
                    // and throws on any non-2xx, so only a real image reaches the write.
                    // Not a background-transfer delegate path, so the DownloadManager
                    // exception in CLAUDE.md doesn't apply here.
                    guard let coverData = try? await AudiobookshelfAPI.shared.authorizedData(for: coverURL), !coverData.isEmpty else { return }
                    // Cover-versioning fix: extracted into `writeCoverFile` so
                    // `refreshLocalCoverIfStale`'s re-fetch of a replaced cover writes
                    // the file identically (same atomic write, same protection class)
                    // instead of duplicating this block.
                    guard self.writeCoverFile(coverData, itemId: coverItemId) else { return }
                    // Item 10 (REVIEW-2026-09-09.md): record the cover in memory the
                    // moment it lands, so `localCoverURL(for:)` — the accessor
                    // `shelfCoverURL` is meant to use from a SwiftUI `body` — never has
                    // to stat the disk to find out. Only hops when the write actually
                    // succeeded; a failed cover write leaves the flag clear and the
                    // remote URL keeps being used, exactly as before.
                    await MainActor.run { self.recordLocalCover(itemId: coverItemId) }
                }
            }

            // Enqueue a background task per missing track.
            //
            // ARCH-6: `downloadSession` is a plain (main-actor-isolated) `lazy var` —
            // the one dependency in this now-`nonisolated` function that actually
            // needs a hop. Hoisted once here, outside the loop, instead of per
            // iteration: one real hop per download start, not one per track.
            let session = await MainActor.run { downloadSession }
            // Review Medium 27: re-check after the hop, and undo what was written above if
            // the user cancelled in the meantime (cancel's own cleanup may already have run).
            guard await downloadStillWanted(itemId: item.id, runId: runId) else {
                await MainActor.run {
                    // Review 5 Low (enqueue cleanup): a newer run now owns the directory.
                    if let current = activeDownloads[item.id], current.runId != runId { return }
                    if !downloadedItems.contains(item.id) { try? fileManager.removeItem(at: itemDir) }
                    withCacheLock { manifests.removeValue(forKey: item.id) }
                }
                return
            }
            for (index, file) in ordered.enumerated() {
                let dest = trackFileURL(itemId: item.id, trackIndex: index)
                if fileManager.fileExists(atPath: dest.path) { continue }
                // `percentEncodedPathComponent` (Extensions.swift) uses `.urlPathAllowed`,
                // which permits `/` through unescaped — fine for building a multi-segment
                // path, wrong here where `item.id`/`ino` must each collapse to exactly one
                // path segment. `strictPathComponentEncode` closes that gap for this
                // audio-download URL (the cover URL above already only needs the weaker
                // guarantee, since Audiobookshelf ids in practice never contain `/`, but
                // hardening this call site — which is a raw file byte-stream, higher value
                // to an attacker than a cover thumbnail — is free).
                guard let ino = file.ino,
                      let url = URL(string: "\(serverURL)/api/items/\(strictPathComponentEncode(item.id))/file/\(strictPathComponentEncode(ino))/download") else { continue }
                let key = "\(item.id)|\(index)"
                withCacheLock { trackURLs[key] = url }
                var request = AuthStore.shared.authorizedRequest(url: url)
                // The session-level `allowsCellularAccess` was previously always true —
                // "Download on Wi-Fi only" was only checked once at enqueue time, so a
                // download that started on Wi-Fi kept going over cellular after the user
                // left the house. Per-request is the fix that also covers retries below.
                request.allowsCellularAccess = !SettingsStore.wifiOnlyDownloads
                let task = session.downloadTask(with: request)
                task.taskDescription = taskDesc(itemId: item.id, track: index)
                task.resume()
            }

            // If everything was already on disk, finalize now.
            await MainActor.run { finalizeIfComplete(itemId: item.id) }
        } catch {
            await MainActor.run {
                // Review 3 Low (enqueue runId)
                if Self.isSameLiveRun(entry: activeDownloads[item.id].map { ($0.runId, $0.isCancelled) }, runId: runId) {
                    _ = activeDownloads.removeValue(forKey: item.id)
                }
                // Polish pass (DL-5): log the detail, show a sentence.
                ShelfLog.error(.downloads, "Couldn't start download for \(item.id): \(error.localizedDescription)")
                downloadError = DownloadFailureCopy.isOutOfSpace(error)
                    ? DownloadFailureCopy.outOfSpace
                    : String(localized: "Couldn\u{2019}t start the download. Check your connection and try again.", comment: "Download failure toast")
            }
        }
    }

    // MARK: - Delegate callbacks (called from the background session delegate)

    // `nonisolated`: called directly and synchronously from `DownloadSessionDelegate`'s
    // `URLSessionDownloadDelegate` methods, which run on the background session's
    // delegate queue, not main. The actual `activeDownloads`/`downloadError` mutations
    // (main-actor state) are funneled through `Task { @MainActor in }` rather than
    // `DispatchQueue.main.async`, since the latter doesn't prove main-actor isolation to
    // the compiler for the property accesses inside.
    nonisolated func trackProgress(itemId: String, written: Int64, expected: Int64, trackIndex: Int? = nil) {
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        let now = Date()
        // Polish pass (DL-2): remember this track's bytes so the hop below can publish a
        // book-level "written of expected". Updated on every callback (a dictionary write
        // under the lock); the sum over tracks is only computed when the hop is taken.
        if let trackIndex {
            withCacheLock {
                trackBytes[itemId, default: [:]][trackIndex] = (written, expected)
            }
        }
        // Item 10 (REVIEW-2026-09-09.md), write side. Two gates, in the two places they
        // can each do the most good:
        //
        // 1. Here, on the delegate queue: should this callback hop to the main actor at
        //    all? This is the gate that removes the per-callback `Task` allocation, the
        //    `cacheLock` acquisition inside it and the main-actor hop itself — the cost
        //    that was being paid dozens of times a second per download regardless of
        //    whether the progress bar moved a single pixel.
        // 2. In the hop below: should the `@Observable` `progress` actually be written?
        //    Observation doesn't compare values, so writing the same (or a lower) number
        //    still invalidates every view reading it — and `LibraryView`/`BookDetailView`
        //    read exactly this. Hence the separate percentage-level check.
        //
        // The book-level number can only be computed on the main actor (it needs
        // `completedTrackCount`'s cache), which is why gate 1 is time-only.
        let shouldHop: Bool = withCacheLock {
            guard Self.shouldHopForProgress(
                fraction: fraction, lastHopAt: lastProgressHopAt[itemId], now: now) else { return false }
            lastProgressHopAt[itemId] = now
            return true
        }
        guard shouldHop else { return }
        // Polish pass (DL-2): byte totals for the hop (zeros when the caller gave no track).
        let byteTotals: (written: Int64, expected: Int64, tracks: Int) = withCacheLock {
            guard let perTrack = trackBytes[itemId] else { return (0, 0, 0) }
            var w: Int64 = 0, e: Int64 = 0
            for value in perTrack.values { w += value.written; e += max(value.expected, 0) }
            return (w, e, perTrack.count)
        }
        Task { @MainActor in
            guard let task = self.activeDownloads[itemId], !task.isPaused,
                  let manifest = self.manifest(for: itemId) else { return }
            let total = max(manifest.tracks.count, 1)
            let done = self.completedTrackCount(itemId: itemId)
            let computed = min(1.0, (Double(done) + fraction) / Double(total))
            guard Self.shouldPublishProgress(
                previous: task.progress, next: computed,
                lastPublishedAt: self.lastProgressPublishAt[itemId] ?? .distantPast,
                now: now) else { return }
            self.lastProgressPublishAt[itemId] = now
            // Only advance — several tracks download in parallel, so a single track's
            // fraction can otherwise make the bar jump backward. (`shouldPublishProgress`
            // already refuses a value that doesn't move it forward; the `max` stays as
            // the belt-and-braces version of the same rule at the point of the write.)
            task.progress = max(task.progress, computed)
            // Polish pass (DL-2): bytes + ETA ride the same throttled publish.
            if byteTotals.tracks > 0 {
                let expectedTotal = DownloadPolicyStatus.expectedTotalBytes(
                    knownExpectedSum: byteTotals.expected, tracksReported: byteTotals.tracks,
                    totalTracks: total, written: byteTotals.written, progress: task.progress)
                task.record(written: byteTotals.written, expected: expectedTotal, at: now)
            }
        }
    }

    /// Polish pass (DL-2): per-track (written, expected) bytes for in-flight downloads,
    /// guarded by `cacheLock` and cleared with the throttle state. In-memory only.
    @ObservationIgnored nonisolated(unsafe) private var trackBytes: [String: [Int: (written: Int64, expected: Int64)]] = [:]

    /// When each item's `DownloadTask.progress` was last actually published.
    /// `@ObservationIgnored`, deliberately: this is the throttle's own bookkeeping, and
    /// letting Observation see it would re-invalidate every view reading `activeDownloads`
    /// on precisely the ticks the throttle exists to suppress.
    @ObservationIgnored private var lastProgressPublishAt: [String: Date] = [:]

    /// Item 10 (REVIEW-2026-09-09.md): ~4 Hz — at most one published progress change per
    /// download per 250 ms. Chosen to be under a display refresh interval's worth of
    /// perceptible difference for a progress bar while being an order of magnitude fewer
    /// re-renders than `didWriteData`'s own callback rate.
    nonisolated static let progressPublishInterval: TimeInterval = 0.25

    /// Pure decision (gate 1): should a `didWriteData` callback hop to the main actor?
    ///
    /// Rate-limited per item rather than per track on purpose — the published number is
    /// per *book*, so six parallel tracks reporting at once are six callbacks with one
    /// possible visible outcome between them.
    ///
    /// A callback whose track has just finished (`fraction >= 1`) always gets through:
    /// that's the last thing that track will ever report, and it's the one that carries
    /// the book to its next whole-track boundary. Extracted and `static` so the boundary
    /// is testable without a live download — same "extract the decision, test the
    /// decision" precedent as `shouldReclaimOrphanDirectory`.
    nonisolated static func shouldHopForProgress(fraction: Double, lastHopAt: Date?, now: Date) -> Bool {
        if fraction >= 1.0 { return true }
        guard let lastHopAt else { return true }   // first callback for this download
        return now.timeIntervalSince(lastHopAt) >= progressPublishInterval
    }

    /// Pure decision (gate 2): should `next` actually be written to the observable
    /// `DownloadTask.progress`?
    ///
    /// - Completion always lands (once): 100% is the one value the UI must not miss, and
    ///   `finalizeIfComplete` writing it as well is not something to rely on here.
    /// - A value that doesn't move the bar forward never publishes. Parallel tracks each
    ///   report their own fraction, so this is the common case, and Observation would
    ///   otherwise re-render every reader for a write of the same number.
    /// - Otherwise the whole percentage must have changed **and** at least
    ///   `progressPublishInterval` must have passed. Requiring both is what makes this a
    ///   coalescer rather than just a rate limiter: a fast download publishes at 4 Hz
    ///   carrying whatever the latest value is, and a slow one publishes on the percent
    ///   change (the elapsed-time half being long satisfied) instead of 4× a second.
    nonisolated static func shouldPublishProgress(
        previous: Double, next: Double, lastPublishedAt: Date, now: Date
    ) -> Bool {
        if next >= 1.0 { return previous < 1.0 }
        guard next > previous else { return false }
        guard Int(next * 100) > Int(previous * 100) else { return false }
        return now.timeIntervalSince(lastPublishedAt) >= progressPublishInterval
    }

    /// Drops one item's progress-throttle bookkeeping. Called from every path that ends a
    /// download (completion, cancel, failure, removal) so neither map outlives the
    /// download it describes — and so a book downloaded a second time starts from a clean
    /// slate rather than inheriting a stale "last published at" that would suppress its
    /// first tick.
    private func clearProgressThrottleState(itemId: String) {
        lastProgressPublishAt.removeValue(forKey: itemId)
        withCacheLock {
            lastProgressHopAt.removeValue(forKey: itemId)
            trackBytes.removeValue(forKey: itemId)
        }
    }

    /// Move the finished temp file into place. Called synchronously on the delegate
    /// queue while `location` is still valid. `nonisolated`: this MUST run synchronously,
    /// not hop to the main actor first — `URLSession` deletes the temp file at `location`
    /// as soon as this delegate call returns, so there's no `await`ing back to main
    /// before doing the move. Only the disk/cache-lock-protected helpers it calls
    /// (`downloadDirectory`, `trackFileURL`, `fileManager`, `protectDownloadedFile`) are
    /// touched here; the main-actor bookkeeping afterward is hopped via
    /// `Task { @MainActor in }`.
    nonisolated func storeFinishedTrack(from location: URL, itemId: String, trackIndex: Int) {
        let dir = downloadDirectory(for: itemId)
        let dest = trackFileURL(itemId: itemId, trackIndex: trackIndex)
        // Move the temp file into place, surfacing a failure (full disk, permissions)
        // instead of silently continuing to a "complete" check that can never pass.
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path) { try? fileManager.removeItem(at: dest) }
            try fileManager.moveItem(at: location, to: dest)
        } catch {
            // Polish pass (DL-5): a sentence, not the system description; log the detail.
            ShelfLog.error(.downloads, "Couldn't save track \(trackIndex) of \(itemId): \(error.localizedDescription)")
            trackFailed(itemId: itemId, message: DownloadFailureCopy.isOutOfSpace(error)
                ? DownloadFailureCopy.outOfSpace
                : String(localized: "Couldn\u{2019}t save this book to your device. Try again.", comment: "Download failure reason"))
            return
        }
        // Applied after the move (not before, since `moveItem` writes into `dest` fresh —
        // a protection attribute set on a not-yet-existent path would be a no-op).
        protectDownloadedFile(at: dest)
        Task { @MainActor in
            let key = "\(itemId)|\(trackIndex)"
            self.withCacheLock {
                self.retryCounts[key] = nil
                self.trackURLs[key] = nil
            }
            // ARCH-6: keep the in-memory completed-tracks cache current instead of
            // invalidating it wholesale — the whole point is avoiding a re-walk here.
            self.completedTracksCache[itemId, default: []].insert(trackIndex)
            self.finalizeIfComplete(itemId: itemId)
        }
    }

    // `nonisolated`: called from `storeFinishedTrack` (background delegate queue, see
    // above) as well as from the delegate's `didFinishDownloadingTo`/`didCompleteWithError`
    // forwarding. Hops to the main actor for the `activeDownloads`/`downloadError` writes.
    nonisolated func trackFailed(itemId: String, message: String) {
        Task { @MainActor in
            // Review 5 Low (trackFailed): a late failure after cancel must not toast or
            // tear down a newer run. Delegate callbacks carry no runId, so this checks
            // the live entry only.
            guard let entry = self.activeDownloads[itemId], !entry.isCancelled else { return }
            self.failDownload(itemId: itemId, message: message)
        }
    }

    /// On a dropped connection, resume from where we stopped (up to `maxRetries`),
    /// otherwise surface the failure. `nonisolated`: called synchronously from
    /// `DownloadSessionDelegate.urlSession(_:task:didCompleteWithError:)` on the
    /// background delegate queue; hops to the main actor internally.
    nonisolated func retryOrFail(itemId: String, trackIndex: Int, resumeData: Data?, message: String) {
        Task { @MainActor in
            let key = "\(itemId)|\(trackIndex)"
            // Don't retry if this track already finished, or the whole download was cancelled.
            guard self.activeDownloads[itemId] != nil else { return }
            let attempts = self.withCacheLock { self.retryCounts[key] ?? 0 }

            if attempts < self.maxRetries {
                self.withCacheLock { self.retryCounts[key] = attempts + 1 }
                let task: URLSessionDownloadTask
                // Item 9 (REVIEW-2026-09-09-REMAINING.md): the resume blob here comes
                // straight out of `NSURLSessionDownloadTaskResumeData` in the error's
                // userInfo rather than off disk, but the same rule applies — an
                // unparseable blob would burn one of the `maxRetries` on a task that
                // can't start, where restarting the track from `trackURLs` (the branch
                // below, already the no-resume-data path) actually makes progress.
                if let resumeData, Self.shouldUseResumeBlob(resumeData) {
                    // Continue from where it dropped.
                    task = self.downloadSession.downloadTask(withResumeData: resumeData)
                } else if let url = self.withCacheLock({ self.trackURLs[key] }) {
                    // No resume data (e.g. a TLS reset) — restart the track from scratch.
                    // `trackProgress`'s `max(task.progress, computed)` exists to stop
                    // parallel tracks from jittering the bar backward, but that same
                    // floor would otherwise keep crediting the book's progress for bytes
                    // this restart just discarded. Floor it back down to what's actually
                    // still on disk (fully completed tracks only) before the restart begins.
                    if let manifest = self.manifest(for: itemId) {
                        let total = max(manifest.tracks.count, 1)
                        let done = self.completedTrackCount(itemId: itemId)
                        let floor = Double(done) / Double(total)
                        if let current = self.activeDownloads[itemId]?.progress, current > floor {
                            self.activeDownloads[itemId]?.progress = floor
                        }
                    }
                    var request = AuthStore.shared.authorizedRequest(url: url)
                    request.allowsCellularAccess = !SettingsStore.wifiOnlyDownloads
                    task = self.downloadSession.downloadTask(with: request)
                } else {
                    self.failPermanently(itemId: itemId, message: message)
                    return
                }
                task.taskDescription = self.taskDesc(itemId: itemId, track: trackIndex)
                // Resume immediately — a delayed retry can't fire while the app is
                // suspended, and the background session already paces connectivity.
                task.resume()
                return
            }
            self.failPermanently(itemId: itemId, message: message)
        }
    }

    /// A track returned HTTP 401 (access token expired mid-download). Refresh the token
    /// and re-enqueue the track with a fresh Authorization header, up to `maxRetries`.
    /// `nonisolated`: called synchronously from `DownloadSessionDelegate.
    /// urlSession(_:downloadTask:didFinishDownloadingTo:)` on the background delegate
    /// queue; the body below already hops to `@MainActor` for everything it touches.
    nonisolated func handleAuthFailure(itemId: String, trackIndex: Int) {
        let key = "\(itemId)|\(trackIndex)"
        Task { @MainActor in
            guard activeDownloads[itemId] != nil, activeDownloads[itemId]?.isCancelled != true else { return }
            let attempts = withCacheLock { retryCounts[key] ?? 0 }
            guard attempts < maxRetries else {
                failPermanently(itemId: itemId, message: DownloadFailureCopy.signInAgain)
                return
            }
            withCacheLock { retryCounts[key] = attempts + 1 }
            await AudiobookshelfAPI.shared.ensureFreshAccessToken(force: true)
            // Re-check: the download may have been cancelled while the refresh was in flight.
            guard activeDownloads[itemId] != nil, activeDownloads[itemId]?.isCancelled != true,
                  let url = withCacheLock({ trackURLs[key] }) else {
                return
            }
            var request = AuthStore.shared.authorizedRequest(url: url)
            request.allowsCellularAccess = !SettingsStore.wifiOnlyDownloads
            let task = downloadSession.downloadTask(with: request)
            task.taskDescription = taskDesc(itemId: itemId, track: trackIndex)
            task.resume()
        }
    }

    /// Review Medium 25 (30 October 2026): what to do with a track that came back with an
    /// HTTP error other than 401.
    nonisolated enum HTTPStatusRetryDecision: Equatable {
        case retry(delay: TimeInterval)
        case fail
    }

    /// Pure retry-versus-fail decision. Only 429 and transient 5xx (500/502/503/504) are
    /// retried, at most `maxAttempts` times, with exponential backoff (2, 4, 8 s) that a
    /// server `Retry-After` (seconds, capped at 60) can lengthen. Anything else (404, 403,
    /// 501 ...) is a real failure.
    nonisolated static func httpStatusRetryDecision(statusCode: Int, attempts: Int, retryAfter: TimeInterval?,
                                                    maxAttempts: Int = 3) -> HTTPStatusRetryDecision {
        guard [429, 500, 502, 503, 504].contains(statusCode), attempts >= 0, attempts < maxAttempts else { return .fail }
        let backoff = 2.0 * pow(2.0, Double(attempts))
        let delay = max(backoff, min(max(retryAfter ?? 0, 0), 60))
        return .retry(delay: delay)
    }

    /// Review Medium 25: whether a first-time download that failed should keep its finished
    /// tracks (so Retry only fetches the missing ones) instead of deleting the directory.
    nonisolated static func shouldKeepPartialTracks(completedTracks: Int) -> Bool {
        completedTracks > 0
    }

    /// Called from the delegate on a non-2xx, non-401 response. Hops to the main actor.
    nonisolated func handleHTTPStatusFailure(itemId: String, trackIndex: Int, statusCode: Int, retryAfter: TimeInterval?) {
        let key = "\(itemId)|\(trackIndex)"
        Task { @MainActor in
            guard activeDownloads[itemId] != nil, activeDownloads[itemId]?.isCancelled != true else { return }
            // Polish pass (DL-5): never show the code; log it.
            ShelfLog.error(.downloads, "Track \(trackIndex) of \(itemId) returned HTTP \(statusCode)")
            let message = DownloadFailureCopy.message(forHTTPStatus: statusCode)
            let attempts = withCacheLock { retryCounts[key] ?? 0 }
            switch Self.httpStatusRetryDecision(statusCode: statusCode, attempts: attempts, retryAfter: retryAfter) {
            case .fail:
                failDownload(itemId: itemId, message: message)
            case .retry(let delay):
                withCacheLock { retryCounts[key] = attempts + 1 }
                // Review 2 Medium 7 (30 October 2026): a suspended app would freeze this wait
                // and could later let the orphan sweep delete the partial tracks. Ask for
                // background time (delay is at most 60 s). If iOS ends it early, the
                // expiration handler cuts the wait short and the download is recorded as a
                // retryable failure (finished tracks kept) rather than left stranded.
                //
                // The expiration handler runs synchronously on the main thread just before
                // suspension, and the task must be ended inside it or iOS kills the app
                // (UIApplication.beginBackgroundTask(withName:expirationHandler:) docs). So the
                // failure is recorded and the task ended there, not after the sleep returns.
                let runId = activeDownloads[itemId]?.runId
                let sleeper = Task { try? await Task.sleep(for: .seconds(delay)) }
                let bgTask = RetryBackgroundTask()
                bgTask.id = UIApplication.shared.beginBackgroundTask(withName: "ShelfHead.downloadRetry") {
                    sleeper.cancel()
                    MainActor.assumeIsolated {
                        if let current = self.activeDownloads[itemId], current.runId == runId,
                           !current.isCancelled, !current.isPaused {
                            self.failDownload(itemId: itemId, message: message)
                        }
                        bgTask.end()
                    }
                }
                await sleeper.value
                bgTask.end()
                // Re-check: cancelled, restarted (different run), paused or failed by the
                // expiration handler while waiting.
                guard !sleeper.isCancelled, let current = activeDownloads[itemId], current.runId == runId,
                      !current.isCancelled, !current.isPaused else { return }
                // Review 2 Low (pause during retry): a pause then resume while waiting already
                // restarted this track; don't start a duplicate.
                if await hasLiveTask(itemId: itemId, trackIndex: trackIndex) { return }
                guard let current = activeDownloads[itemId], current.runId == runId,
                      !current.isCancelled, !current.isPaused else { return }
                guard let url = withCacheLock({ trackURLs[key] }) else {
                    failDownload(itemId: itemId, message: message)
                    return
                }
                var request = AuthStore.shared.authorizedRequest(url: url)
                request.allowsCellularAccess = !SettingsStore.wifiOnlyDownloads
                let task = downloadSession.downloadTask(with: request)
                task.taskDescription = taskDesc(itemId: itemId, track: trackIndex)
                task.resume()
            }
        }
    }

    /// Review 2 Medium 7: one background-task id, ended exactly once from whichever of the
    /// expiration handler or the finished wait gets there first (both on the main thread).
    @MainActor private final class RetryBackgroundTask {
        var id: UIBackgroundTaskIdentifier = .invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    /// Review 2 Low (pause during retry): whether the session already has a task for this track.
    private func hasLiveTask(itemId: String, trackIndex: Int) async -> Bool {
        let desc = taskDesc(itemId: itemId, track: trackIndex)
        return await withCheckedContinuation { cont in
            downloadSession.getAllTasks { tasks in
                cont.resume(returning: tasks.contains { $0.taskDescription == desc && $0.state != .completed })
            }
        }
    }

    private func failPermanently(itemId: String, message: String) {
        // Polish pass (DL-5): callers now pass a complete sentence, so no wrapper prefix.
        failDownload(itemId: itemId, message: message)
    }

    /// What `failDownload` should do with a download that has just failed for good.
    /// Fix 3 (REVIEW-2026-09-09.md): the old body had no such distinction — it always
    /// deleted the item directory.
    enum DownloadFailureAction: Equatable {
        /// Every track is already on disk: this is a late callback for a download that
        /// actually finished. Do nothing.
        case ignore
        /// A failed *repair* (or any future partial re-fetch of a book that's already
        /// in `downloadedItems`): report it, but leave the item directory, its
        /// `manifest.json`, its cached cover and its healthy tracks exactly as they are.
        case keepFiles
        /// A first-time download that never completed: report it, delete the partial
        /// directory, and drop the id from `downloadedItems` in the same step.
        case discardFiles
    }

    /// The directory half of the failure decision, shared by `failDownload` and
    /// `cancelDownload` so both enforce one rule: **never delete an item directory for
    /// an id that's still in `downloadedItems`** unless the id is dropped from
    /// `downloadedItems` at the same time. `downloadBook` refuses to start a download
    /// for an already-downloaded id, so "in `downloadedItems` *and* has a live task" is
    /// precisely the repair case (the `isRepair` flag catches it directly; the
    /// `downloadedItems` check also catches a second broken track's failure arriving
    /// after the first one already removed the `DownloadTask`).
    ///
    /// Pure and `static` so the decision can be unit-tested without the filesystem or
    /// this class's live state — same precedent as `shouldReclaimOrphanDirectory`; see
    /// `DownloadRepairFailureTests`.
    static func shouldRemoveItemDirectoryOnFailure(isRepair: Bool, isInDownloadedItems: Bool) -> Bool {
        !isRepair && !isInDownloadedItems
    }

    /// Pure decision for `failDownload`, split out for the same reason as
    /// `shouldReclaimOrphanDirectory` (unit-testable without disk or instance state).
    /// `totalTracks == 0` means there's no readable manifest, which the pre-fix guard
    /// also treated as "nothing to fail" (`0 < 0` is false) — preserved deliberately.
    static func failureAction(isRepair: Bool, isInDownloadedItems: Bool,
                              completedTracks: Int, totalTracks: Int) -> DownloadFailureAction {
        guard totalTracks > 0, completedTracks < totalTracks else { return .ignore }
        return shouldRemoveItemDirectoryOnFailure(isRepair: isRepair, isInDownloadedItems: isInDownloadedItems)
            ? .discardFiles
            : .keepFiles
    }

    /// ARCH-5: the shared "give up on this download" path for both `trackFailed` (an
    /// unrecoverable per-callback failure — a bad HTTP status, a disk write error) and
    /// `failPermanently` (retries exhausted). Previously each independently just
    /// dropped the item from `activeDownloads` and posted a toast: sibling tracks kept
    /// downloading into the same item directory, the partial directory was never
    /// deleted, and the item landed in neither `activeDownloads` nor `downloadedItems`
    /// — invisible to `DownloadsView`, with no retry and no way to reclaim the bytes
    /// even via "Remove All Downloads" (which only ever walked `downloadedItems`).
    ///
    /// Fix 3 (REVIEW-2026-09-09.md): what happens after the failure is recorded is now
    /// `failureAction(...)`'s call, because deleting the directory unconditionally was
    /// actively destructive for a failed repair. `repairDownload` deletes only the
    /// broken track files and re-enqueues them through this same session/delegate, so a
    /// re-download that failed (a server rescan changed the file's `ino` → HTTP 404,
    /// retries exhausted, auth expired) arrived here with `completedTracks <
    /// totalTracks` satisfied and removed `downloadDirectory(for:)` — every healthy
    /// track, the cached cover and `manifest.json`, which is the only store of offline
    /// progress. It also never removed the id from `downloadedItems`, so `isDownloaded`
    /// stayed true while `localSession(for:)` returned nil: a book the UI showed as
    /// downloaded and could not play.
    private func failDownload(itemId: String, message: String) {
        let bookManifest = manifest(for: itemId)
        let completedBefore = completedTrackCount(itemId: itemId)
        let action = Self.failureAction(
            isRepair: activeDownloads[itemId]?.isRepair == true,
            isInDownloadedItems: downloadedItems.contains(itemId),
            completedTracks: completedBefore,
            totalTracks: bookManifest?.tracks.count ?? 0
        )
        guard action != .ignore else { return }   // already finished
        let title = bookManifest?.title ?? itemId

        activeDownloads.removeValue(forKey: itemId)
        completedTracksCache.removeValue(forKey: itemId)
        withCacheLock {
            retryCounts = retryCounts.filter { !$0.key.hasPrefix("\(itemId)|") }
            trackURLs = trackURLs.filter { !$0.key.hasPrefix("\(itemId)|") }
            pausedResumeData = pausedResumeData.filter { !$0.key.hasPrefix("\(itemId)|") }
        }
        markPaused(itemId, false)
        deletePersistedPausedResume(forItem: itemId)
        clearProgressThrottleState(itemId: itemId)
        ShelfLog.error(.downloads, "Download failed for \(itemId): \(message)")

        guard action == .discardFiles else {
            // Failed repair. Nothing to clean up and nothing to cancel: the broken track
            // `repairDownload` deleted before re-enqueueing is simply still missing, so
            // `verifyDownload` reports it as "Missing" again and Download Health shows
            // "needs repair" — the honest state — with no extra bookkeeping to restore.
            // Sibling repair tasks for this book's other broken tracks are deliberately
            // left running; the blanket cancel below exists only to stop a task writing
            // into a directory that's about to be deleted, and this one isn't.
            //
            // Deliberately not recorded in `failedDownloads`: that collection means "a
            // download that produced no usable book", and both of its actions
            // (`retryFailedDownload`, `removeFailedDownload`) operate on the whole book.
            // A toast naming the book plus the restored needs-repair state is the right
            // signal for a book that is still perfectly playable apart from one track.
            downloadError = String(localized: "Couldn't repair \u{201C}\(title)\u{201D}. \(message) It still needs repair.", comment: "First %@ is the book title, second a detail message")
            return
        }

        withCacheLock { manifests.removeValue(forKey: itemId) }
        downloadError = String(localized: "Couldn't download \u{201C}\(title)\u{201D}. \(message)", comment: "First %@ is the book title, second a detail message")
        failedDownloads[itemId] = DownloadFailure(itemId: itemId, title: title, message: message)
        saveFailedDownloads()

        // Cancel every remaining sibling task so one that's still mid-flight doesn't
        // keep writing into a directory this is about to delete out from under it,
        // then remove the partial directory once they've actually stopped.
        downloadSession.getAllTasks { tasks in
            for task in tasks where Self.parseTaskKey(task.taskDescription)?.id == itemId {
                task.cancel()
            }
            Task { @MainActor in
                // Review 4 Low (cleanup hop): the entry was removed above, so any entry now
                // is a newer run (Retry) that owns the folder; leave it alone.
                if self.activeDownloads[itemId] != nil { return }
                // Review Medium 25 (30 October 2026): one failed track used to delete every
                // finished track too. Keep them; the failed record makes the book
                // retryable, and `enqueueDownload` skips tracks already on disk, so Retry
                // only re-fetches the missing ones. `removeFailedDownload` reclaims the
                // bytes if the user dismisses instead.
                if Self.shouldKeepPartialTracks(completedTracks: completedBefore) {
                    self.refreshStorageUsed(force: true)
                    return
                }
                // `removeDownload` rather than a bare `removeItem`: it already deletes
                // the item directory, drops the id from `downloadedItems`, clears the
                // manifest/completed-track caches, persists and re-counts storage — all
                // in one place. Reusing it is what keeps "directory gone" and "id gone
                // from `downloadedItems`" from coming apart, which is the half of fix 3
                // the old bare `removeItem` here got wrong.
                self.removeDownload(itemId: itemId, userInitiated: false)
            }
        }
    }

    /// ARCH-6: in-memory cache of which track indices are already on disk for a book,
    /// keyed by item id. Previously every call to `completedTrackCount` re-ran a fresh
    /// `FileManager.fileExists` walk over every track (two checks each, for the
    /// current and legacy filename convention) — for a 120-track audiobook that's
    /// ~240 syscalls per call, and `trackProgress` (which calls this) fires several
    /// times a second per in-flight track while up to `httpMaximumConnectionsPerHost`
    /// (6) tracks download in parallel — precisely while the user might be scrolling
    /// Downloads watching progress. Lazily seeded per item on first access (one real
    /// FS walk), then kept current by `storeFinishedTrack` inserting the newly-landed
    /// index directly instead of forcing a re-walk. Main-actor-only state, since every
    /// caller of `completedTrackCount`/`completedTracks(for:)` already is (see their
    /// call sites) — `verifyDownload`'s real per-file health check is untouched by
    /// this, since that's a integrity check, not an existence check.
    private var completedTracksCache: [String: Set<Int>] = [:]

    private func completedTrackCount(itemId: String) -> Int {
        completedTracks(for: itemId).count
    }

    private func completedTracks(for itemId: String) -> Set<Int> {
        if let cached = completedTracksCache[itemId] { return cached }
        guard let manifest = manifest(for: itemId) else { return [] }
        let dir = downloadDirectory(for: itemId)
        let onDisk = Set(manifest.tracks.indices.filter { idx in
            fileManager.fileExists(atPath: trackFileURL(itemId: itemId, trackIndex: idx).path)
                || fileManager.fileExists(atPath: dir.appendingPathComponent("track_\(idx).audio").path)
        })
        completedTracksCache[itemId] = onDisk
        return onDisk
    }

    private func finalizeIfComplete(itemId: String) {
        // A late track-finish arriving after cancellation must not re-mark the item downloaded.
        guard activeDownloads[itemId]?.isCancelled != true else { return }
        guard let manifest = manifest(for: itemId) else { return }
        let total = manifest.tracks.count
        let done = completedTrackCount(itemId: itemId)
        activeDownloads[itemId]?.progress = total > 0 ? Double(done) / Double(total) : 0
        if total > 0 && done == total {
            activeDownloads.removeValue(forKey: itemId)
            downloadedItems.insert(itemId)
            saveDownloadedItems()
            // Review Low (failed record, 30 October 2026): a later successful download of
            // a book that once failed must not leave its stale "failed" row behind.
            if failedDownloads.removeValue(forKey: itemId) != nil { saveFailedDownloads() }
            markPaused(itemId, false)
            deletePersistedPausedResume(forItem: itemId)
            clearProgressThrottleState(itemId: itemId)
            // Item 10: the cover is fetched by its own detached task in
            // `enqueueDownload`, which normally records itself — this covers the ordering
            // where the audio finished first (or the record hop was skipped because the
            // app was relaunched in between). One stat, once per completed download.
            refreshLocalCoverPresence(itemId: itemId)
            // Opt-in "download complete" notification (no-op unless enabled + authorized).
            NotificationManager.notifyDownloadComplete(title: manifest.title)
            // Give this item's row an immediate size rather than waiting for
            // `refreshStorageUsed()`'s full (`.detached`, async) walk over every
            // downloaded item to land — scoped to just the directory that changed, so
            // it's one small, synchronous stat pass (a handful of files: tracks, cover,
            // manifest), not the per-render, whole-library walk this feature exists to
            // avoid. `refreshStorageUsed()` below still runs and will overwrite this
            // with the authoritative figure once its walk completes.
            itemStorageBytes[itemId] = Self.diskUsage(of: downloadDirectory(for: itemId))
            // A download just finished — disk state changed, so force past the
            // throttle rather than let the authoritative totals lag behind the
            // synchronous single-item stat just above.
            refreshStorageUsed(force: true)
        }
    }

    // MARK: - Storage (account/server scoped)

    /// Filesystem/pipe-safe key for the active (server + user) scope. `"unscoped"` until an
    /// account is configured — reloadForActiveScope() re-reads once it is.
    // `nonisolated`: pure computation over external singletons (`AuthStore`,
    // `AccountStore`), no main-actor state — called synchronously from
    // `DownloadSessionDelegate.isForeignScope` on the background delegate queue, as
    // well as from every path/key helper below.
    nonisolated func currentScopeKey() -> String {
        let server = AuthStore.shared.serverURL
        let live = server.isEmpty ? nil : Self.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
        return Self.resolveScopeKey(liveKey: live,
                                    lastActiveKey: UserDefaults.standard.string(forKey: Self.lastActiveScopeDefaultsKey))
    }

    /// The scope `reloadForActiveScope()` last loaded for a signed-in account, removed when
    /// a reload finds nobody signed in.
    nonisolated static let lastActiveScopeDefaultsKey = "shelfhead_lastActiveDownloadScope"

    /// Review finding High 1/2 (30 October 2026): `AuthStore` is in memory only and is
    /// seeded by `ContentView.task` or `configureFromKeychainIfNeeded`. A headless launch
    /// (background URLSession relaunch, BG refresh) bootstraps downloads before either runs,
    /// so the scope used to read `"unscoped"`: every finished track was cancelled as foreign
    /// and the downloaded-items list was loaded (and could be saved) under the wrong key.
    /// The live server/account wins; until it's known, the last signed-in scope stands in.
    nonisolated static func resolveScopeKey(liveKey: String?, lastActiveKey: String?) -> String {
        if let liveKey { return liveKey }
        if let lastActiveKey, !lastActiveKey.isEmpty { return lastActiveKey }
        return "unscoped"
    }

    /// Static so callers that don't have this scope active (e.g. `AccountStore.remove`,
    /// deleting an account that isn't the current one) can still compute the same key
    /// `currentScopeKey()` would produce for an arbitrary server/account pair.
    /// `nonisolated`: static members of a `@MainActor` type are main-actor-isolated by
    /// default too; this is pure string manipulation, safe to call from anywhere.
    nonisolated static func scopeKey(serverURL: String, accountId: String) -> String {
        // §8 decomposition (REVIEW_2026-08-12.md): pure string logic moved to
        // `DownloadPaths` — see that type's doc comment. Signature unchanged.
        DownloadPaths.scopeKey(serverURL: serverURL, accountId: accountId)
    }

    // MARK: Scoped `UserDefaults` keys (one source of truth)

    /// Every `UserDefaults.standard` key this class writes per download scope, derived in
    /// exactly one place.
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): `purgeScopedDefaults` below used to spell its two
    /// keys out as string literals, independently of the functions that *write* them — so
    /// when `shelfhead_failedDownloads.<scope>` was added later, account deletion never
    /// learned to purge it and the removed account's failed-download records (including
    /// book titles) stayed in `UserDefaults` forever. That's exactly the unbounded
    /// per-account key growth this purge exists to prevent. Every builder below and the
    /// purge now read this one list, so a new scoped key can't be added without the purge
    /// picking it up automatically.
    nonisolated static func scopedDefaultsKeys(scope: String) -> [String] {
        [
            downloadedItemsKey(scope: scope),
            pausedItemsKey(scope: scope),
            failedDownloadsKey(scope: scope),
            userRemovedItemsKey(scope: scope),
            applicationSupportMigrationKey(scope: scope)
        ]
    }

    nonisolated static func downloadedItemsKey(scope: String) -> String { "shelfhead_downloadedItems.\(scope)" }
    nonisolated static func pausedItemsKey(scope: String) -> String { "shelfhead_pausedDownloads.\(scope)" }
    nonisolated static func failedDownloadsKey(scope: String) -> String { "shelfhead_failedDownloads.\(scope)" }
    /// Review Low (auto-download, 30 October 2026): ids the user deliberately removed, so
    /// auto-download doesn't quietly fetch them again.
    nonisolated static func userRemovedItemsKey(scope: String) -> String { "shelfhead_userRemovedDownloads.\(scope)" }
    /// The one-shot "this scope's downloads have been moved to Application Support" flag
    /// (see `migrateDownloadsToApplicationSupportIfNeeded()`). Included in the purge list
    /// because it's per-scope too: keeping it after the account is gone serves no purpose,
    /// and re-adding the same server+account later should re-run the (now no-op) migration
    /// rather than trust a flag left over from a deleted account.
    nonisolated static func applicationSupportMigrationKey(scope: String) -> String {
        "shelfhead_downloadsMigratedToAppSupport.\(scope)"
    }

    /// Removes the scoped `UserDefaults` entries for an account that's being deleted
    /// entirely (not just switched away from). Without this, every account ever added
    /// leaves permanent `shelfhead_downloadedItems.*`/`shelfhead_pausedDownloads.*`/
    /// `shelfhead_failedDownloads.*` keys behind in `UserDefaults.standard` — unbounded
    /// growth over the life of the app.
    /// `nonisolated`: called by `AccountStore` during account deletion, no main-actor
    /// state touched.
    nonisolated static func purgeScopedDefaults(serverURL: String, accountId: String) {
        let scope = scopeKey(serverURL: serverURL, accountId: accountId)
        for key in scopedDefaultsKeys(scope: scope) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Legacy (pre-3.1) unscoped root: `Documents/ShelfHead/Downloads`.
    private nonisolated func legacyDownloadsRoot() -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShelfHead/Downloads")
    }

    /// Housekeeping batch (REVIEW_2026-08-12.md, §10 "files to change" table + item 15 of
    /// the fix sequencing): the *current* (post-3.1, pre-this-fix) scoped root also lived
    /// under `Documents` — `Documents/ShelfHead/Downloads/accounts/<scope>`. That's the
    /// wrong directory per Apple's Data Storage Guidelines: downloaded audio/covers/
    /// manifests are re-downloadable from the user's own server, not user-generated
    /// content, so they belong under `Library/Application Support`, not `Documents`
    /// (`Documents` is for content the user created and would expect to find via the
    /// Files app / iTunes file sharing — one `UIFileSharingEnabled` plist key away from
    /// exposing every downloaded audiobook there, which this app deliberately doesn't
    /// enable, but the directory choice should be correct on its own regardless).
    /// `legacyScopedDownloadsRoot()` — the *previous* value `downloadsRoot()` returned,
    /// kept only as the source side of `migrateDownloadsToApplicationSupportIfNeeded()`
    /// below, exactly mirroring how `legacyDownloadsRoot()` above is kept only for the
    /// unscoped→scoped migration it feeds.
    private nonisolated func legacyScopedDownloadsRoot() -> URL {
        legacyDownloadsRoot().appendingPathComponent("accounts/\(currentScopeKey())")
    }

    /// New base: `Library/Application Support/ShelfHead/Downloads`. Still gets
    /// `excludeFromBackup`/`protectDownloadedFile` applied by `reloadForActiveScope()`
    /// exactly as before — `Application Support`, like `Documents`, is included in
    /// backups by default, so the exclusion is still required, just on the corrected
    /// base directory.
    private nonisolated func applicationSupportDownloadsRoot() -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShelfHead/Downloads")
    }

    /// Marks a directory excluded from iCloud/iTunes-Finder backups. The exclusion is
    /// recursive (applies to everything already inside, and anything added later), so
    /// it only needs to be (re-)applied to the root, not per file. Downloaded audio can
    /// be tens of GB and is trivially re-downloadable from the user's own server, so
    /// backing it up wastes the user's iCloud storage and risks App Review rejection
    /// under the iOS Data Storage Guidelines.
    private nonisolated func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Applies `.completeUntilFirstUserAuthentication` file-protection to a downloaded
    /// file (or directory), rather than leaving it on whatever iOS's implicit default
    /// happens to be. That class is a deliberate middle ground, not the strictest
    /// option: `.complete` would make the file unreadable the instant the device locks,
    /// which would silently kill lock-screen/background audio playback mid-book — a
    /// regression far worse than the threat being mitigated.
    /// `.completeUntilFirstUserAuthentication` still blocks access before the *first*
    /// unlock since boot
    /// (so a downloaded audiobook can't be pulled off a freshly-booted, still-locked
    /// phone) while staying readable for the rest of the device's uptime, including
    /// while locked later — which is exactly what background playback needs. Safe to
    /// call on a path that doesn't exist yet (a `try?`, matching this file's existing
    /// tolerance for best-effort filesystem attribute calls); callers apply it after
    /// the file/directory in question actually exists on disk.
    private nonisolated func protectDownloadedFile(at url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// Scoped root: `Application Support/ShelfHead/Downloads/accounts/<scope>`. The
    /// `accounts` segment keeps scope folders unambiguous vs. legacy item-id folders
    /// during migration. Moved off `Documents` (see `applicationSupportDownloadsRoot()`'s
    /// doc comment) — every other download path (`downloadDirectory(for:)`,
    /// `pausedResumeDir()`, `localCoverURL`, `manifest(for:)`) derives from this one
    /// function, so correcting the base here is sufficient; nothing else needed to
    /// change its own path-building logic.
    nonisolated func downloadsRoot() -> URL {
        downloadsRoot(scopeKey: currentScopeKey())
    }

    /// S5 (REVIEW_2026-08-20_UI_SECURITY.md): scoped variant taking an explicit key
    /// rather than always reading `currentScopeKey()` — needed by
    /// `deleteAllPersistedPausedResumeBlobs(scopeKey:)` to target an account that isn't
    /// necessarily the one currently signed in.
    nonisolated func downloadsRoot(scopeKey: String) -> URL {
        applicationSupportDownloadsRoot().appendingPathComponent("accounts/\(scopeKey)")
    }

    // Not `private`: exercised directly by `DownloadPathsTests` (SEC-1) via
    // `@testable import`, which can't reach `private`/`fileprivate` declarations.
    nonisolated func downloadDirectory(for itemId: String) -> URL {
        // Audiobookshelf ids are UUIDs in practice, so this isn't exploitable via a
        // compromised server today — but the threat model this file adopts elsewhere
        // (a hostile server controls `LibraryItem.id` completely) is worth actually
        // closing, and hardening it is free. Every other download path
        // (`trackFileURL`, `localCoverURL`, etc.) derives from this function, so
        // sanitising once here covers all of them.
        let dir = downloadsRoot().appendingPathComponent(sanitizedPathComponent(itemId))
        // SEC-1: defense in depth on top of `sanitizedPathComponent`'s own guarantees
        // (below) — assert the result never actually resolves outside
        // `downloadsRoot()`, so a future change to the sanitiser (or a case it
        // doesn't anticipate) can't silently regress into a traversal instead of
        // being caught here. `standardizedFileURL` resolves any `.`/`..` components
        // before the comparison.
        let root = downloadsRoot().standardizedFileURL.path
        let resolved = dir.standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            // Unreachable in practice given the sanitiser below, but fail safe to a
            // clearly-scoped fallback directory rather than ever returning a path
            // outside the downloads root.
            return downloadsRoot().appendingPathComponent("id_" + safeIdentifierHash(itemId))
        }
        return dir
    }

    /// Collapses a server-supplied id into something safe to use as a single path
    /// component: percent-encodes it, then also flattens any remaining `/` (which
    /// percent-encoding of `.urlPathAllowed` doesn't escape, since `/` is a valid path
    /// separator character for that character set) so it can't be read as multiple
    /// path segments (e.g. a crafted id containing `../`).
    ///
    /// SEC-1: `.` and `..` survive that flattening unchanged (`.urlPathAllowed`
    /// explicitly permits `.` unescaped, and neither string contains a `/` to begin
    /// with) — so `itemId == ".."` previously resolved to `downloadsRoot()`'s own
    /// parent directory, and `removeDownload(itemId: "..")` calling
    /// `fileManager.removeItem(at:)` on the result deleted **every account's**
    /// downloads; `itemId == "."` resolved to the scope root and wiped the current
    /// account's entire download folder plus its `.paused` resume state. Reject both
    /// explicitly (and, for completeness, an empty result) and fall back to a
    /// collision-resistant encoding of the raw id instead of ever returning something
    /// that could be interpreted as "here" or "up one level."
    nonisolated func sanitizedPathComponent(_ itemId: String) -> String {
        // §8 decomposition (REVIEW_2026-08-12.md): pure string logic moved to
        // `DownloadPaths` — see that type's doc comment (this is the exact SEC-1 fix,
        // now testable independent of `DownloadManager`/`FileManager`). Signature and
        // every call site (including `DownloadPathsTests.swift`) unchanged.
        DownloadPaths.sanitizedPathComponent(itemId)
    }

    /// Base64-encodes `value` into a string that's always safe as a single path
    /// component — used as `sanitizedPathComponent`'s fallback for an id that would
    /// otherwise sanitize to `.`, `..`, or empty. Not reversible-in-practice back to
    /// the original id (nor does anything need it to be); just collision-resistant and
    /// filesystem-safe.
    private nonisolated func safeIdentifierHash(_ value: String) -> String {
        // §8 decomposition: moved to `DownloadPaths`. Signature unchanged.
        DownloadPaths.safeIdentifierHash(value)
    }

    /// Percent-encodes a value for use as exactly one URL path segment — stricter than
    /// the shared `percentEncodedPathComponent` (Extensions.swift), which uses
    /// `.urlPathAllowed` and (as the comment on `sanitizedPathComponent` above notes)
    /// deliberately leaves `/` un-escaped, since that helper is meant for building a
    /// path that's *allowed* to span multiple segments. The audio-download URL built
    /// from this (`.../file/<ino>/download`) substitutes a server-supplied `item.id`
    /// and `ino` into what must stay a single segment each — an id or ino containing
    /// `/` (or `../`) must be escaped, not read as a path separator, or a
    /// compromised/malicious server response could point the request somewhere other
    /// than the intended `/file/<ino>/download` endpoint. Removing `/` from the
    /// allowed set (vs. reusing `.urlPathAllowed` as-is) is the only difference.
    private nonisolated func strictPathComponentEncode(_ value: String) -> String {
        // §8 decomposition: moved to `DownloadPaths`. Signature unchanged.
        DownloadPaths.strictPathComponentEncode(value)
    }

    // The active scope's keys, all three built from `scopedDefaultsKeys(scope:)`'s
    // builders rather than their own literals — see that function's doc comment.
    private nonisolated func downloadedItemsKey() -> String { Self.downloadedItemsKey(scope: currentScopeKey()) }
    private nonisolated func pausedItemsKey() -> String { Self.pausedItemsKey(scope: currentScopeKey()) }
    private nonisolated func userRemovedItemsKey() -> String { Self.userRemovedItemsKey(scope: currentScopeKey()) }

    /// Review Low (auto-download, 30 October 2026): per-scope set of items the user removed.
    private nonisolated func loadUserRemovedItems() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: userRemovedItemsKey()) ?? [])
    }
    private nonisolated func markUserRemoved(_ itemIds: Set<String>, _ removed: Bool) {
        guard !itemIds.isEmpty else { return }
        var set = loadUserRemovedItems()
        let updated = removed ? set.union(itemIds) : set.subtracting(itemIds)
        guard updated != set else { return }
        set = updated
        UserDefaults.standard.set(Array(set), forKey: userRemovedItemsKey())
    }

    /// Review Low (auto-download, 30 October 2026): whether an automatic flow may start this
    /// book. Skips books the user removed (until they download it by hand again) and books
    /// with a failed record (a retry is the user's call, not a loop).
    nonisolated static func shouldAutoDownload(itemId: String, isDownloaded: Bool, isDownloading: Bool,
                                               userRemoved: Set<String>, failed: Set<String>) -> Bool {
        !isDownloaded && !isDownloading && !userRemoved.contains(itemId) && !failed.contains(itemId)
    }

    /// Background-task description carries the scope so a task that completes after an
    /// account switch can be rejected rather than stored into the wrong account.
    private nonisolated func taskDesc(itemId: String, track: Int) -> String { "\(currentScopeKey())|\(itemId)|\(track)" }

    /// Parse a task description ("scope|itemId|track", or legacy "itemId|track") into the
    /// in-memory cache identity (itemId, track).
    // `static` since it doesn't touch instance state — lets tests exercise this parsing
    // logic directly without instantiating `DownloadManager.shared` (which does real
    // filesystem/UserDefaults work in `init()`). `nonisolated` since it's also called
    // (as `Self.parseTaskKey`) from `cancelDownload`/`pauseDownload`'s `URLSession`
    // completion-handler closures, which run on a background queue.
    nonisolated static func parseTaskKey(_ desc: String?) -> (id: String, track: Int)? {
        guard let desc else { return nil }
        let p = desc.split(separator: "|").map(String.init)
        if p.count == 3, let t = Int(p[2]) { return (p[1], t) }
        if p.count == 2, let t = Int(p[1]) { return (p[0], t) }
        return nil
    }

    /// The scope `downloadedItems` was last loaded from. High 2: a save under a different
    /// scope would overwrite that account's list with this one's.
    private var loadedScopeKey: String?

    /// Reloads when the scope resolved since the last load (a headless launch that
    /// bootstrapped before the Keychain seed). BG refresh calls this after seeding.
    func reloadIfScopeChanged() {
        guard hasBootstrapped, loadedScopeKey != currentScopeKey() else { return }
        reloadForActiveScope()
    }

    private func loadDownloadedItems() {
        loadedScopeKey = currentScopeKey()
        if let data = UserDefaults.standard.data(forKey: downloadedItemsKey()),
           let items = try? JSONDecoder().decode(Set<String>.self, from: data) {
            downloadedItems = items
        } else {
            downloadedItems = []   // nothing for this scope — don't keep the previous account's set
        }
        // UI-9: this is the account-switch/bootstrap path, which reassigns
        // `downloadedItems` directly rather than going through `saveDownloadedItems()`.
        cachedDownloadedLibraryItems = nil
        // Item 10 (REVIEW-2026-09-09.md): seed the in-memory cover-presence set for this
        // scope. One stat per downloaded book, once per scope load (bootstrap / account
        // switch) — which is the entire point: it replaces one stat per cover per
        // `LibraryView.body` pass. Assigned as a whole set rather than inserted id by id
        // so Observation sees a single change, not N.
        itemsWithLocalCover = Set(
            downloadedItems.filter { fileManager.fileExists(atPath: coverFileURL(for: $0).path) }
        )
    }

    private func saveDownloadedItems() {
        guard loadedScopeKey == currentScopeKey() else {
            ShelfLog.info(.downloads, "Skipped saving downloaded items: scope changed since they were loaded.")
            return
        }
        if let data = try? JSONEncoder().encode(downloadedItems) {
            UserDefaults.standard.set(data, forKey: downloadedItemsKey())
        }
        // UI-9: every real mutation of `downloadedItems` (add, remove, remove-all)
        // already calls this immediately afterward, so invalidating the cache here
        // covers all of them in one place instead of at each call site individually.
        cachedDownloadedLibraryItems = nil
    }

    // MARK: - Scope reload + one-time migration

    private static let migratedKey = "shelfhead_downloadsMigratedToScoped"

    /// Reload downloaded/paused state for the currently-active account. Call after login
    /// and on account switch (the caller should also `cancelAllActiveDownloads()` first).
    func reloadForActiveScope() {
        pendingProgressConflict = nil   // Review 6 Low (conflict across accounts)
        snoozedConflicts.removeAll()    // Polish pass (DL-6)
        lastRaisedConflicts.removeAll()
        // P3-4: bump before any synchronous state mutation below, so a reload that
        // starts later (even one that finishes its own synchronous section before
        // this one's async `adoptInFlightDownloads` completion fires) always wins —
        // see `reloadGeneration`'s doc comment on `bootstrapIfNeeded()`.
        reloadGeneration += 1
        let generation = reloadGeneration
        // High 1/2: remember this scope for headless launches (see `resolveScopeKey`).
        // Forget it when nobody is signed in, so a signed-out app doesn't keep the old one.
        if AuthStore.shared.serverURL.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.lastActiveScopeDefaultsKey)
        } else {
            UserDefaults.standard.set(currentScopeKey(), forKey: Self.lastActiveScopeDefaultsKey)
        }
        migrateLegacyDownloadsIfNeeded()
        migrateDownloadsToApplicationSupportIfNeeded()
        // Re-applied on every reload (login/switch/relaunch) — cheap, and it's how a
        // build that predates this fix gets existing downloads excluded from backup
        // without the user needing to redownload anything.
        try? fileManager.createDirectory(at: downloadsRoot(), withIntermediateDirectories: true)
        excludeFromBackup(downloadsRoot())
        // Same "re-applied on every reload, cheap, retroactively covers pre-fix
        // installs" reasoning as the backup exclusion just above, but for file
        // protection instead of iCloud backup.
        protectDownloadedFile(at: downloadsRoot())
        activeDownloads.removeAll()
        completedTracksCache.removeAll()
        lastProgressPublishAt.removeAll()
        withCacheLock {
            manifests.removeAll()
            lastProgressHopAt.removeAll()
        }
        // `loadDownloadedItems()` reseeds `itemsWithLocalCover` for the new scope (item
        // 10) — the previous account's cover flags must not survive a switch, for the
        // same reason its `downloadedItems` must not.
        loadDownloadedItems()
        loadFailedDownloads()
        migrateRawNamedDownloadFoldersIfNeeded()
        restorePausedDownloads()
        // NEW-1 (follow-up review, 14 Aug 2026): see `bootstrapIfNeeded()`'s comment —
        // same sequencing bug, same fix. `refreshStorageUsed()` moves into the
        // completion too, so it accounts for disk state *after* the sweep runs
        // rather than possibly-mid-sweep.
        adoptInFlightDownloads(generation: generation) { [weak self] liveTaskItemIds in
            self?.sweepOrphanedDownloadDirectories(additionallyExcluding: liveTaskItemIds)
            // The scope just changed (or the sweep just deleted orphans) — force past
            // the throttle so this account's real totals replace the previous scope's
            // stale figures immediately, rather than possibly waiting out a walk that
            // ran moments ago for a different account entirely.
            self?.refreshStorageUsed(force: true)
        }
    }

    /// `downloadDirectory(for:)` started sanitizing item ids (percent-encoding,
    /// flattening `/`) after some installs already had downloads on disk under the raw,
    /// unsanitized item id. For Audiobookshelf's UUID-style ids `sanitizedPathComponent`
    /// is the identity function, so this never bites in practice — but if any server
    /// ever hands out an id containing a space, a non-ASCII character, or anything else
    /// that gets percent-encoded, the two would silently diverge: `downloadedItems`
    /// (UserDefaults) still says the book is downloaded, `localFileURL()` looks in the
    /// now-differently-named folder and comes up empty, and the audio sits on disk
    /// forever — invisible to storage accounting and impossible to remove from the UI.
    /// One-time-per-reload sweep: if the sanitized folder is missing but a raw-named
    /// one exists for the same id, move it into place.
    private func migrateRawNamedDownloadFoldersIfNeeded() {
        for itemId in downloadedItems {
            let sanitizedDir = downloadDirectory(for: itemId)
            guard !fileManager.fileExists(atPath: sanitizedDir.path) else { continue }
            let rawDir = downloadsRoot().appendingPathComponent(itemId)
            guard rawDir.path != sanitizedDir.path, fileManager.fileExists(atPath: rawDir.path) else { continue }
            try? fileManager.moveItem(at: rawDir, to: sanitizedDir)
        }
    }

    /// Move any pre-3.1 unscoped downloads into the current account's scope, once.
    /// Moves (never delete-then-copy) and skips when the destination already exists.
    private func migrateLegacyDownloadsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migratedKey) else { return }
        guard currentScopeKey() != "unscoped" else { return }   // wait for a real account
        let legacy = legacyDownloadsRoot()
        let scoped = downloadsRoot()
        try? fileManager.createDirectory(at: scoped, withIntermediateDirectories: true)
        excludeFromBackup(scoped)
        if let children = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                let name = child.lastPathComponent
                if name == "accounts" { continue }
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: child.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                if name == ".paused" {
                    let dstPaused = scoped.appendingPathComponent(".paused")
                    try? fileManager.createDirectory(at: dstPaused, withIntermediateDirectories: true)
                    if let files = try? fileManager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) {
                        for f in files {
                            let dst = dstPaused.appendingPathComponent(f.lastPathComponent)
                            if !fileManager.fileExists(atPath: dst.path) { try? fileManager.moveItem(at: f, to: dst) }
                        }
                    }
                    try? fileManager.removeItem(at: child)
                    continue
                }
                let dst = scoped.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: dst.path) { try? fileManager.moveItem(at: child, to: dst) }
            }
        }
        // Move the global index/paused keys into this scope's keys.
        if let data = UserDefaults.standard.data(forKey: "shelfhead_downloadedItems") {
            UserDefaults.standard.set(data, forKey: downloadedItemsKey())
            UserDefaults.standard.removeObject(forKey: "shelfhead_downloadedItems")
        }
        if let arr = UserDefaults.standard.stringArray(forKey: "shelfhead_pausedDownloads") {
            UserDefaults.standard.set(arr, forKey: pausedItemsKey())
            UserDefaults.standard.removeObject(forKey: "shelfhead_pausedDownloads")
        }
        UserDefaults.standard.set(true, forKey: Self.migratedKey)
    }

    /// Housekeeping batch (REVIEW_2026-08-12.md): moves a *previously-migrated* scoped
    /// download tree — `Documents/ShelfHead/Downloads/accounts/<scope>`, where
    /// `downloadsRoot()` itself used to point before this fix — into the corrected
    /// `Application Support`-based location `downloadsRoot()` now returns. Distinct from
    /// `migrateLegacyDownloadsIfNeeded()` above (which only ever ran once, globally,
    /// before per-account scoping existed): this one is keyed *per scope*, since
    /// different accounts on the same device reach this migration independently as each
    /// becomes the active account, exactly like `downloadedItemsKey()`/`pausedItemsKey()`
    /// are already per-scope.
    ///
    /// A brand-new install (or one that's never run `migrateLegacyDownloadsIfNeeded()`
    /// before, i.e. `Self.migratedKey` was never set) doesn't need this step at all: by
    /// the time this function runs, `migrateLegacyDownloadsIfNeeded()` immediately above
    /// has already moved everything straight from the pre-3.1 unscoped `Documents` root
    /// into the current (now `Application Support`-based) `downloadsRoot()`, since that
    /// function also reads `downloadsRoot()` for its destination. This function only has
    /// real work to do for installs that already completed the *old* scoped migration on
    /// a previous version and therefore have data sitting in the old
    /// `Documents`-based scoped location.
    private func migrateDownloadsToApplicationSupportIfNeeded() {
        let scope = currentScopeKey()
        guard scope != "unscoped" else { return }   // wait for a real account
        let migratedKey = Self.applicationSupportMigrationKey(scope: scope)
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        let oldScoped = legacyScopedDownloadsRoot()
        let newScoped = downloadsRoot()
        guard oldScoped.path != newScoped.path else {
            // Can't happen given the two base directories differ, but guards against a
            // future change accidentally collapsing them into the same path, which
            // would otherwise make the move-and-remove below destroy the very data
            // it's meant to preserve.
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        try? fileManager.createDirectory(at: newScoped, withIntermediateDirectories: true)
        excludeFromBackup(newScoped)
        if let children = try? fileManager.contentsOfDirectory(at: oldScoped, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                let name = child.lastPathComponent
                if name == ".paused" {
                    let dstPaused = newScoped.appendingPathComponent(".paused")
                    try? fileManager.createDirectory(at: dstPaused, withIntermediateDirectories: true)
                    if let files = try? fileManager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) {
                        for f in files {
                            let dst = dstPaused.appendingPathComponent(f.lastPathComponent)
                            if !fileManager.fileExists(atPath: dst.path) { try? fileManager.moveItem(at: f, to: dst) }
                        }
                    }
                    try? fileManager.removeItem(at: child)
                    continue
                }
                let dst = newScoped.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: dst.path) { try? fileManager.moveItem(at: child, to: dst) }
            }
            // Best-effort cleanup of the now-(hopefully-)empty old scoped directory —
            // `try?` since a leftover file this didn't anticipate (or a permissions
            // hiccup) shouldn't block the migration from being marked done; anything
            // left behind here is orphaned but harmless (already excluded from backup,
            // and `downloadsRoot()` never points at it again).
            try? fileManager.removeItem(at: oldScoped)
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}

// MARK: - Download health

/// One track's on-disk health, from `DownloadManager.verifyDownload`.
struct DownloadTrackHealth: Identifiable {
    var id: Int { trackIndex }
    let trackIndex: Int
    let filename: String
    /// Nil when the track file is fine; otherwise a short, user-facing reason.
    let issue: String?
}

/// Result of a `DownloadManager.verifyDownload` pass over one downloaded book.
struct DownloadHealthReport {
    let itemId: String
    let tracks: [DownloadTrackHealth]
    var brokenTracks: [DownloadTrackHealth] { tracks.filter { $0.issue != nil } }
    var isHealthy: Bool { brokenTracks.isEmpty }
}

/// A downloaded book whose local and server progress diverged too much for
/// `DownloadManager.reconcile(serverProgress:)` to resolve silently — see that
/// method's doc comment for when this fires.
/// `Sendable` (fix 2.1, REVIEW-2026-09-09.md): the alert's button closures now capture
/// this value into a `Task` to hand it to `DownloadManager.resolveProgressConflict(_:
/// keepLocal:)`, so it crosses a concurrency boundary. All-`let` `String`/`Double`
/// fields, so the conformance is free.
struct ProgressConflict: Identifiable, Sendable {
    let itemId: String
    let title: String
    let localTime: Double
    let serverTime: Double
    let duration: Double
    /// Polish pass (DL-6): epoch milliseconds each side last wrote its position (nil when
    /// unknown), so the alert can say "This iPhone: 2 hours ago · Server: yesterday".
    /// In-memory only (this value is never persisted); defaulted so existing
    /// constructions keep compiling.
    var localLastUpdate: Double? = nil
    var serverLastUpdate: Double? = nil
    var id: String { itemId }

    /// Polish pass (DL-6): what "Ask Me Later" remembers about a conflict. While both
    /// sides still read exactly this, `reconcile` does not ask again.
    struct Stamp: Equatable, Sendable {
        let localTime: Double
        let serverTime: Double
        let localLastUpdate: Double
        let serverLastUpdate: Double
    }
    var stamp: Stamp {
        Stamp(localTime: localTime, serverTime: serverTime,
              localLastUpdate: localLastUpdate ?? 0, serverLastUpdate: serverLastUpdate ?? 0)
    }

    /// Pure decision: should `reconcile` raise the prompt for a conflict whose current
    /// state is `current`, given what (if anything) the user snoozed? Raised again only
    /// when either side's position or timestamp has changed since the snooze.
    nonisolated static func shouldRaise(snoozed: Stamp?, current: Stamp) -> Bool {
        guard let snoozed else { return true }
        return snoozed != current
    }

    /// Polish pass (DL-6): "This iPhone: 2 hours ago · Server: yesterday". A side with no
    /// timestamp is left out; nil when neither has one.
    nonisolated static func lastPlayedSummary(localLastUpdate: Double?, serverLastUpdate: Double?,
                                              now: Date = Date()) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        func ago(_ ms: Double?) -> String? {
            guard let ms, ms > 0 else { return nil }
            return formatter.localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: now)
        }
        let local = ago(localLastUpdate).map { String(localized: "This device: \($0)", comment: "Progress conflict alert; %@ is a relative time such as '2 hours ago'") }
        let server = ago(serverLastUpdate).map { String(localized: "Server: \($0)", comment: "Progress conflict alert; %@ is a relative time such as 'yesterday'") }
        let parts = [local, server].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Polish pass (DL-1, DL-2, DL-3, DL-5): pure copy/decision helpers

/// Polish pass (DL-1): why an in-flight download isn't moving, as the row should say it.
enum DownloadWaitReason: Equatable {
    case wifi, network
}

/// Polish pass (DL-3): why the last automatic download was held back.
enum AutoDownloadDeferral: Equatable {
    case wifi, power

    var message: String {
        switch self {
        case .wifi: return String(localized: "Auto-downloads are waiting for Wi\u{2011}Fi.", comment: "Downloads screen: automatic downloads are held back by the Wi-Fi-only setting")
        case .power: return String(localized: "Auto-downloads are waiting until this iPhone is charging.", comment: "Downloads screen: automatic downloads are held back by the charging-only setting")
        }
    }
}

enum DownloadPolicyStatus {
    /// Polish pass (DL-1): `nil` when the download is paused (the row says "Paused") or
    /// nothing is blocking it. Offline outranks Wi-Fi-only: with no network at all the
    /// honest thing to say is "network". The charging-only setting only gates *starting*
    /// automatic downloads (`autoDownloadPolicyAllows`), never one already running, so
    /// there is no "Waiting for power" for an active row.
    nonisolated static func waitReason(isPaused: Bool, wifiOnly: Bool, isConnected: Bool, isOnWiFi: Bool) -> DownloadWaitReason? {
        guard !isPaused else { return nil }
        if !isConnected { return .network }
        if wifiOnly && !isOnWiFi { return .wifi }
        return nil
    }

    /// Polish pass (DL-3): the single source of the auto-download gates (Wi-Fi, then power).
    nonisolated static func autoDownloadDeferral(wifiOnly: Bool, onWiFi: Bool, chargingOnly: Bool, isCharging: Bool) -> AutoDownloadDeferral? {
        if wifiOnly && !onWiFi { return .wifi }
        if chargingOnly && !isCharging { return .power }
        return nil
    }

    /// Polish pass (DL-2): the expected total for the "120 MB of 1.4 GB" line. When every
    /// track has reported, the sum of their sizes is exact; before that it is extrapolated
    /// from the book-level fraction (needs a little progress to be meaningful). 0 = unknown.
    nonisolated static func expectedTotalBytes(knownExpectedSum: Int64, tracksReported: Int, totalTracks: Int,
                                               written: Int64, progress: Double) -> Int64 {
        if totalTracks > 0, tracksReported >= totalTracks { return knownExpectedSum }
        guard progress >= 0.01, written > 0 else { return 0 }
        return Int64(Double(written) / progress)
    }

    /// Polish pass (DL-2): a remaining-time estimate, only once the smoothed speed is
    /// trustworthy (at least `minSamples` one-second-plus samples) and the answer is
    /// plausible (under two days). Otherwise nil, and the row shows bytes only.
    nonisolated static func etaSeconds(remainingBytes: Int64, bytesPerSecond: Double, samples: Int, minSamples: Int = 5) -> TimeInterval? {
        guard samples >= minSamples, bytesPerSecond > 1_000, remainingBytes > 0 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        return seconds <= 48 * 3600 ? seconds : nil
    }

    /// Smoothing for the speed estimate (exponential moving average).
    nonisolated static func smoothedSpeed(previous: Double, samples: Int, instant: Double) -> Double {
        samples == 0 ? instant : 0.3 * instant + 0.7 * previous
    }
}

enum DownloadFailureCopy {
    static let notFound = String(localized: "This book\u{2019}s files aren\u{2019}t on the server any more.", comment: "Download failure reason")
    static let outOfSpace = String(localized: "Not enough storage. Free up space and try again.", comment: "Download failure reason")
    static let signInAgain = String(localized: "Your sign-in has expired. Sign in again, then try again.", comment: "Download failure reason")
    static let serverBusy = String(localized: "Your server is busy. Try again in a moment.", comment: "Download failure reason")
    static let serverRefused = String(localized: "Your server couldn\u{2019}t send this book. Try again later.", comment: "Download failure reason")
    static let connection = String(localized: "The connection kept dropping. Check your connection and try again.", comment: "Download failure reason")
    static let generic = String(localized: "The download didn\u{2019}t finish. Try again.", comment: "Download failure reason")

    /// Polish pass (DL-5): house-style sentence for an HTTP failure. The code itself is
    /// never shown (the caller logs it).
    nonisolated static func message(forHTTPStatus code: Int) -> String {
        switch code {
        case 404, 410: return notFound
        case 401, 403: return signInAgain
        case 429, 500, 502, 503, 504: return serverBusy
        default: return serverRefused
        }
    }

    /// True for a full disk: Cocoa's write-out-of-space (640), POSIX ENOSPC (28), or either
    /// as the underlying error.
    nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    /// Polish pass (DL-5): sentence for a transport/disk error. Never includes the system
    /// description or code.
    nonisolated static func message(for error: Error) -> String {
        if isOutOfSpace(error) { return outOfSpace }
        if error is URLError { return connection }
        return generic
    }
}

// MARK: - Download Task

@Observable
final class DownloadTask: Identifiable {
    let id: String
    let title: String
    var progress: Double = 0
    var isCancelled = false
    var isPaused = false
    /// Fix 3 (REVIEW-2026-09-09.md): true when this task was created by
    /// `DownloadManager.repairDownload` re-fetching only the tracks `verifyDownload`
    /// flagged as broken, rather than by a first-time `downloadBook`. The book's other
    /// tracks, its cached cover and its `manifest.json` are already on disk and must
    /// survive a failed repair, so `failDownload`/`cancelDownload` consult this (and
    /// `downloadedItems` membership, which covers a sibling failure arriving after this
    /// task has already been dropped) before deleting anything.
    var isRepair = false
    /// Review 2 Low (cancel-then-restart, 30 October 2026): unique per start, so async work
    /// begun for one start can tell it from a cancel-then-restart of the same book.
    let runId = UUID()

    /// Polish pass (DL-2): in-memory byte counts for "120 MB of 1.4 GB" (0 = unknown),
    /// published together with `progress` so they share its 0.25 s throttle.
    var bytesWritten: Int64 = 0
    var bytesExpected: Int64 = 0
    /// Polish pass (DL-2): smoothed bytes/second and the sample bookkeeping behind it.
    /// Ignored by Observation: only the published `etaSeconds` is view state.
    var etaSeconds: TimeInterval?
    @ObservationIgnored private var speed: Double = 0
    @ObservationIgnored private var speedSamples = 0
    @ObservationIgnored private var lastSample: (at: Date, bytes: Int64)?

    /// Polish pass (DL-2): folds one published reading into the smoothed speed and ETA.
    /// A sample only counts once at least a second has passed since the last one, so the
    /// estimate isn't driven by 0.25 s bursts; shorter gaps accumulate into the next.
    func record(written: Int64, expected: Int64, at now: Date) {
        bytesWritten = max(bytesWritten, written)
        bytesExpected = expected
        guard let last = lastSample else { lastSample = (now, written); return }
        let dt = now.timeIntervalSince(last.at)
        guard dt >= 1 else { return }
        let delta = written - last.bytes
        lastSample = (now, written)
        guard delta >= 0 else { return }   // a track restarted; skip this sample
        speed = DownloadPolicyStatus.smoothedSpeed(previous: speed, samples: speedSamples, instant: Double(delta) / dt)
        speedSamples += 1
        etaSeconds = expected > 0
            ? DownloadPolicyStatus.etaSeconds(remainingBytes: max(expected - bytesWritten, 0), bytesPerSecond: speed, samples: speedSamples)
            : nil
    }

    init(itemId: String, title: String) {
        self.id = itemId
        self.title = title
    }
}


/// Result of `DownloadManager.bulkDownloadPlan`: what to queue, what was skipped and why,
/// and whether the whole action is refused.
struct BulkDownloadPlan: Equatable {
    struct Skipped: Equatable {
        enum Reason: Equatable { case alreadyDownloaded, inFlight, podcast, overCap }
        let itemId: String
        let reason: Reason
    }
    enum Refusal: Equatable {
        case wifiOnlyBlocked, insufficientSpace, nothingToDownload

        var message: String {
            switch self {
            case .wifiOnlyBlocked: return String(localized: "Wi-Fi-only downloads are on. Connect to Wi-Fi, or turn this off in Settings.")
            case .insufficientSpace: return String(localized: "Not enough free space for these downloads.")
            case .nothingToDownload: return String(localized: "Nothing to download. These books are already downloaded or downloading.")
            }
        }
    }

    /// Above this many books the UI asks first.
    static let confirmationThreshold = 5

    let toDownload: [LibraryItem]
    let skipped: [Skipped]
    let totalKnownBytes: Int64
    let unknownSizeCount: Int
    let wifiOnly: Bool
    let refusal: Refusal?

    static func == (lhs: BulkDownloadPlan, rhs: BulkDownloadPlan) -> Bool {
        lhs.toDownload.map(\.id) == rhs.toDownload.map(\.id) && lhs.skipped == rhs.skipped
            && lhs.totalKnownBytes == rhs.totalKnownBytes && lhs.unknownSizeCount == rhs.unknownSizeCount
            && lhs.wifiOnly == rhs.wifiOnly && lhs.refusal == rhs.refusal
    }

    var needsConfirmation: Bool { toDownload.count > Self.confirmationThreshold }
    var overCapCount: Int { skipped.filter { $0.reason == .overCap }.count }

    /// e.g. "Download 12 books? About 4.8 GB. Respects your Wi-Fi-only setting."
    var summary: String {
        if let refusal { return refusal.message }
        let n = toDownload.count
        // One whole localized sentence per clause (no word-by-word assembly), joined by a space.
        var parts: [String] = [
            n == 1 ? String(localized: "Download 1 book?")
                   : String(localized: "Download \(n) books?", comment: "Bulk download confirmation. %lld is the number of books (2 or more)")
        ]
        if totalKnownBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: totalKnownBytes, countStyle: .file)
            parts.append(unknownSizeCount > 0
                ? String(localized: "About \(size) plus \(unknownSizeCount) of unknown size.", comment: "Bulk download size estimate. First %@ is a file size such as 4.8 GB, then %lld is how many books have an unknown size")
                : String(localized: "About \(size).", comment: "Bulk download size estimate. %@ is a file size such as 4.8 GB"))
        }
        if wifiOnly { parts.append(String(localized: "Respects your Wi-Fi-only setting.")) }
        let already = skipped.filter { $0.reason == .alreadyDownloaded || $0.reason == .inFlight }.count
        if already > 0 { parts.append(String(localized: "\(already) already downloaded or downloading.", comment: "Bulk download note. %lld is a number of books")) }
        let podcasts = skipped.filter { $0.reason == .podcast }.count
        if podcasts > 0 {
            parts.append(podcasts == 1 ? String(localized: "1 podcast can't be downloaded.")
                                       : String(localized: "\(podcasts) podcasts can't be downloaded.", comment: "Bulk download note. %lld is a number of podcasts (2 or more)"))
        }
        if overCapCount > 0 { parts.append(String(localized: "Only the first \(n) will be downloaded; \(overCapCount) left out.", comment: "Bulk download cap note. First %lld is how many will be downloaded, second is how many are left out")) }
        let text = LocalizedText.sentences(parts)
        return text
    }
}


extension Notification.Name {
    /// Review 3 Medium 6: posted when a download whose files are playing is removed.
    /// `userInfo["itemId"]` is the book; absent means Remove All.
    static let shelfheadPlayingDownloadRemoved = Notification.Name("shelfhead.playingDownloadRemoved")
}
