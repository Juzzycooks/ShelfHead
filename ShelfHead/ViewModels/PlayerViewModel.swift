import Foundation
import SwiftUI   // Array.move(fromOffsets:toOffset:) for queue reordering

@MainActor
@Observable
final class PlayerViewModel {
    private let playerService = AudioPlayerService.shared

    // HIG audit 2026-09-17 M2: clearing `seekUndoTime` here (rather than at every call
    // site that changes book or dismisses the player) is what makes "a track/book change"
    // and "the full player closing" reliable dismissals for the "Jump back" chip — see
    // that property's own doc comment below.
    var currentBook: LibraryItem? {
        didSet {
            seekUndoTime = nil
            sleepUndo = nil
            // Critique 2026-10-05 (Mini player): a different book on the bar retires the
            // "Stopped … Undo" offer (`undoStop()` clears it before assigning).
            if currentBook != nil, stopUndo != nil {
                stopUndo = nil
                stopUndoMessage = nil
            }
            // Critique 2026-10-06 (harden): the "Playing instead of … Undo" offer belongs to
            // the book that replaced; any other change (stop, another book) retires it.
            if let r = replaceUndo, currentBook?.id != r.replacementId {
                replaceUndo = nil
                replaceUndoMessage = nil
            }
            if oldValue?.id != currentBook?.id {
                currentEpisode = nil
            }
            // LS-9 (docs/design-review.md): only wipe the bookmarks list when the book
            // itself changed — a same-book reassignment (e.g. a session refresh) shouldn't
            // blank a list that's still valid while a fresh `loadBookmarks()` re-fetches
            // it, but a real book switch must not leave the previous book's list on screen.
            if oldValue?.id != currentBook?.id {
                bookmarks = []
                bookmarksLoadFailed = false
            }
        }
    }
    var showFullPlayer = false {
        didSet {
            if !showFullPlayer {
                seekUndoTime = nil
                sleepUndo = nil
            }
        }
    }
    var isLoadingSession = false
    /// LS-2 (docs/design-review.md): the item a `startPlayback`/`startEpisodePlayback`
    /// call is in flight for, published synchronously before any network `await` (see
    /// `beginLoading(for:)`) so the mini player can show the tapped book's cover and
    /// title immediately instead of waiting for the session round trip. Cleared on every
    /// exit path of that call, success or failure — see `displayedBook`.
    private(set) var pendingBook: LibraryItem?
    var errorMessage: String?
    /// A playback start that failed after reaching the server stage — shown as an alert with
    /// Retry at the app root (critique 2026-10-05, second run) rather than a 3-second toast
    /// VoiceOver never heard. Guard-rail messages (offline, cellular off) stay toasts.
    var startFailureMessage: String?
    /// What `retryFailedStart()` retries. Kept apart from `startFailureMessage` because the
    /// alert clears its message before calling Retry.
    private var lastFailedStart: (item: LibraryItem, episode: PodcastEpisode?)?
    /// Transient positive confirmation (e.g. "Added to Up Next"), shown as a success toast.
    var infoMessage: String?

    // Restored-but-not-yet-loaded state: after the app is relaunched we show the last
    // book in the mini-player at its saved position, ready to resume on play.
    private var restoredCurrentTime: Double = 0
    private var restoredDuration: Double = 0

    /// True when a book is shown (e.g. restored on launch) but no live session exists yet.
    var isAwaitingResume: Bool { currentBook != nil && playerService.currentSession == nil }

    /// LS-2: what the mini player (and anything else showing "the current book") should
    /// display — the book a start is in flight for, if any, otherwise the book with a
    /// live or restored session. Falls back to `currentBook` so nothing changes once a
    /// start resolves one way or the other.
    var displayedBook: LibraryItem? { pendingBook ?? currentBook }

    /// LS-2: whether the mini player should be mounted at all.
    var hasMiniPlayer: Bool { displayedBook != nil }

    /// Critique 2026-10-06 (distill): Book Detail screens whose pinned Play bar is on screen
    /// register here, and the app shell hides the mini player while one is showing in the
    /// selected tab (see `MiniPlayerSuppression`). UI state only: it changes what the shell
    /// draws, never `hasMiniPlayer`, so Magic Tap and everything else keyed on "a book is
    /// loaded" keeps working.
    var miniPlayerSuppression = MiniPlayerSuppression()

    /// Critique 2026-10-06 (harden): pushed Book Detail screens (any pinned bar, ebook Read
    /// included) register here while on screen, and host the single-book Undo toast above
    /// their pinned bar; `ContentView`'s root copy of that toast stands down while one is
    /// showing in the selected tab. Same per-owner, token-checked registry as
    /// `miniPlayerSuppression`, reused for its bookkeeping.
    var progressToastHosts = MiniPlayerSuppression()

    // Playback state (proxied from service, falling back to the restored snapshot).
    var isPlaying: Bool { playerService.isPlaying }
    /// True while playback is intended but AVPlayer is waiting on data — proxies
    /// `AudioPlayerService.isBuffering` (see that property's own doc comment for how
    /// it's derived).
    var isBuffering: Bool { playerService.isBuffering }
    /// LS-1/LS-2 (docs/design-review.md): the single flag both the mini player and the
    /// full player transport read to decide whether to show the buffering ring around
    /// the play button — true while a session is being started (`isLoadingSession`) as
    /// well as while one is stalled (`isBuffering`), so both transports pick up "starting
    /// playback" feedback for free without another call-site change.
    var isTransportWaiting: Bool { isLoadingSession || isBuffering }
    var currentTime: Double { playerService.currentSession != nil ? playerService.currentTime : restoredCurrentTime }
    var duration: Double { playerService.currentSession != nil ? playerService.duration : restoredDuration }
    var playbackRate: Float { playerService.playbackRate }

    /// Chapters come from the live session when playing, else from the current
    /// book itself — so the Now Playing screen shows chapter-relative progress
    /// immediately instead of switching from whole-book once you hit play.
    var chapters: [Chapter] {
        playerService.currentSession != nil
            ? playerService.chapters
            // Batch 427: chapters made on this device apply before a session exists too.
            : ChapterOverrideStore.resolvedChapters(itemId: currentBook?.id, server: currentBook?.chapters ?? [])
    }
    /// The chapter covering the current position, resolved at most once per distinct
    /// `currentTime` (see `resolvedCurrentChapter()`).
    var currentChapter: Chapter? { resolvedCurrentChapter()?.chapter }

    /// The current chapter's index in `chapters`, from the same resolution
    /// `currentChapter` uses.
    ///
    /// Item 10 (REVIEW-2026-09-09.md): `PlayerView.chapterHueShiftFraction` was
    /// recovering this with its own `chapters.firstIndex(where: { $0.id == current.id })`
    /// — a second O(chapters) scan, per render, for an index the resolution above had
    /// already computed and thrown away.
    var currentChapterIndex: Int? { resolvedCurrentChapter()?.index }

    /// A cheap stand-in for "is this the same chapter list the cache was built from" —
    /// count plus the first chapter's id and the last one's end. O(1) to build and
    /// compare, where comparing the arrays themselves would be O(n) (and `Chapter` isn't
    /// `Equatable` to begin with). It only has to distinguish one book's chapter list
    /// from another's, or `currentBook.chapters` from the live session's — not detect an
    /// arbitrary in-place edit, which nothing in this app performs.
    struct ChapterListSignature: Equatable {
        let count: Int
        let firstId: Int?
        let lastEnd: Double?
        /// Batch 427: chapters made on this device replace a list in place (same book, maybe
        /// the same count), which the three fields above can't see.
        let overrideGeneration: Int

        init(_ chapters: [Chapter]) {
            overrideGeneration = ChapterOverrideStore.generation
            count = chapters.count
            firstId = chapters.first?.id
            lastEnd = chapters.last?.end
        }
    }

    /// Which chapter covers `time`, as an index into `chapters`.
    ///
    /// Item 10: pure and `static` so the resolution rule itself can be pinned by a test
    /// rather than only exercised through a live player. Keeps exactly the half-open
    /// `[start, end)` "first chapter that contains `time`" rule of the two linear scans
    /// it replaces (this one and `AudioPlayerService.currentChapter`) rather than
    /// assuming the list is sorted and binary-searching it: same answer for the ordered,
    /// non-overlapping lists Audiobookshelf actually sends, and no new failure mode for a
    /// malformed one. `nonisolated` because it touches no instance state — it is a
    /// function of its two arguments and nothing else.
    nonisolated static func chapterIndex(in chapters: [Chapter], at time: Double) -> Int? {
        chapters.firstIndex { time >= $0.start && time < $0.end }
    }

    /// The resolved current chapter and its index, memoised against the chapter list and
    /// the position that produced it.
    ///
    /// Item 10 (REVIEW-2026-09-09.md): `currentChapter` used to re-scan the chapter list
    /// on *every* access, and `PlayerView` reads it — directly, and through
    /// `hasChapters`/`chapterStart`/`chapterEnd`/`chapterLength`/`chapterElapsed`/
    /// `chapterProgress`, each of which resolved it again from scratch — a dozen-odd
    /// times per render, at two renders a second, on books that routinely ship 80+
    /// chapters. `ChapterListSheet` added one resolution per visible row on top of that.
    /// Resolving once per distinct position collapses all of it into a single scan, and
    /// then only when the position has actually left the cached chapter's bounds.
    ///
    /// The live-session branch this replaces (`if playerService.currentSession != nil {
    /// return playerService.currentChapter }`) is not lost, just unified: with a session
    /// live, `chapters` *is* `playerService.chapters` and `currentTime` *is*
    /// `playerService.currentTime`, so the service's own scan and the scan below were
    /// already computing the same answer from the same two inputs.
    ///
    /// `@ObservationIgnored` on the cache is load-bearing rather than an optimisation:
    /// this getter runs inside SwiftUI view updates, and writing an *observed* stored
    /// property there registers a mutation mid-render — the classic "modifying state
    /// during view update" invalidation loop. Ignored, the cache is what it looks like: a
    /// memo of a pure function, with no observable state of its own. Every dependency
    /// the views actually track (`playerService.currentTime`, `currentSession`,
    /// `currentBook`) is still read on every call, so nothing stops invalidating.
    @ObservationIgnored
    private var chapterCache: (signature: ChapterListSignature, index: Int, chapter: Chapter)?

    private func resolvedCurrentChapter() -> (index: Int, chapter: Chapter)? {
        let list = chapters
        let signature = ChapterListSignature(list)
        let time = currentTime
        if let cached = chapterCache, cached.signature == signature,
           time >= cached.chapter.start, time < cached.chapter.end {
            return (cached.index, cached.chapter)
        }
        guard let index = Self.chapterIndex(in: list, at: time) else {
            chapterCache = nil
            return nil
        }
        let chapter = list[index]
        chapterCache = (signature, index, chapter)
        return (index, chapter)
    }

    // MARK: - Chapter-relative position
    // The player scrubber/times reflect the CURRENT CHAPTER rather than the whole
    // book when chapter data exists (falls back to whole-book otherwise).

    var hasChapters: Bool { currentChapter != nil }
    var chapterStart: Double { currentChapter?.start ?? 0 }
    var chapterEnd: Double { currentChapter?.end ?? duration }
    var chapterLength: Double { max(chapterEnd - chapterStart, 0.001) }
    var chapterElapsed: Double { min(max(currentTime - chapterStart, 0), chapterLength) }
    var chapterProgress: Double { chapterLength > 0 ? chapterElapsed / chapterLength : 0 }

    /// Seek within the current chapter using a 0...1 fraction of the chapter.
    func seekWithinChapter(fraction: Double) {
        seek(to: chapterStart + fraction * chapterLength)
    }
    var sleepTimerOption: SleepTimerOption { playerService.sleepTimerOption }
    var sleepTimerRemaining: TimeInterval { playerService.sleepTimerRemaining }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Up Next queue

    /// Books queued to play after the current one. Persisted to a file in the App Group
    /// container (via `persistQueue()`) so it survives the frequent iOS relaunch cycle
    /// the mini-player is designed around.
    var upNext: [LibraryItem] = []

    private func persistQueue() {
        Self.saveQueue(upNext)
        // Mirror the queue into `SharedLibrary` alongside its own persistence, so the
        // widget's "Up Next" option resolves against published data rather than needing
        // `LibraryItem` (and its whole media graph) in the widget target.
        WidgetLibraryPublisher.publishUpNext(upNext)
    }

    /// ARCH-7 (REVIEW_2026-08-12.md): this used to be `JSONEncoder().encode(items)`
    /// written into App Group `UserDefaults` under this key. `UserDefaults` is a plist
    /// read whole into memory by every process that opens the suite — including the
    /// widget extension, which opens it on every timeline render and never even reads
    /// this key — and `[LibraryItem]` serializes its full `media.chapters`/
    /// `media.audioFiles`/`media.episodes` graph, so a 10-book queue was comfortably
    /// hundreds of KB to low MB against the widget's ~30 MB ceiling.
    /// `SharedPlayback.swift` already learned this exact lesson for the widget cover
    /// image (see its doc comment) — the queue now follows the same fix: a file in the
    /// App Group container, read/written directly, never touching `UserDefaults`.
    private static let legacyQueueKey = "shelfhead.upNextQueue"

    // Prefetched session for the next queued book (warmed near the end of the current
    // one) so auto-advance is gapless. Consumed on advance.
    //
    // Item 3 (REVIEW-2026-09-09-REMAINING.md): a warmed session is a *server* row —
    // `POST /api/items/<id>/play` opens a listening session on Audiobookshelf before a
    // single sample has been played. Only the auto-advance hand-off ever consumed one;
    // every other outcome (the user stops, reorders or clears Up Next, starts a
    // different book, signs out, the prefetch task is cancelled) simply dropped the
    // reference, leaving a zero-time open session behind on the server, visible in
    // Listening Sessions and skewing that book's stats. These two slots are now only
    // ever cleared through `resolvePrefetchedSession(for:)`, which closes what it drops.
    private var prefetchedSession: PlaybackSession?
    private var prefetchedItemId: String?
    /// ARCH-8 (REVIEW_2026-08-12.md): previously a bare fire-and-forget `Task` with no
    /// stored handle — `onNearEnd` can fire more than once near the end of a book (it's
    /// driven by a periodic time check, not a one-shot boundary), so a second call
    /// while the first `startPlaybackSession` was still in flight had nothing to
    /// cancel the first one, and whichever request happened to complete *last* won,
    /// even if it was for a since-changed `upNext.first`. Stored so a new prefetch
    /// cancels any still-running one first.
    private var prefetchTask: Task<Void, Never>?

    // MARK: - Prefetched session lifetime (Item 3)

    /// What should happen to a prefetched playback session that is currently in hand.
    ///
    /// Item 3: separated from the call sites because "is this warmed session still the
    /// one we want" is the entire bug — every leak was a call site that answered it
    /// implicitly by assigning over the slot or returning early.
    enum PrefetchedSessionDisposition: Equatable {
        /// Nothing held, or what's held is still the right session — leave it alone.
        case keep
        /// Give the session to the caller; it becomes the live session and is closed
        /// through `AudioPlayerService`'s normal `closeSession()` path.
        case handOff
        /// The session will never be played — close it on the server.
        case close
    }

    /// The things that can happen to a warmed session between opening it and playing it.
    enum PrefetchEvent: Equatable {
        /// Playback of `itemId` is about to start (auto-advance, a tap on a queued book,
        /// or any manual play). Only an exact item match can be handed off.
        case startingPlayback(itemId: String)
        /// A fresh prefetch for `itemId` is about to begin — anything held for a
        /// different book is being replaced.
        case prefetching(itemId: String)
        /// The head of Up Next changed (reorder, removal, "Play Next", clear, or an
        /// account teardown emptying the queue). `nil` means the queue is now empty.
        case queueHeadChanged(newHeadItemId: String?)
        /// The prefetch task that produced this session was cancelled before the session
        /// could be stored — the request still reached the server, so the row exists.
        case prefetchCancelled
        /// The session is being abandoned outright: playback stopped, autoplay is off, a
        /// podcast episode was started, or auto-advance declined to advance.
        case discarded
    }

    /// Whether a held prefetched session should be kept, handed to the player, or closed.
    ///
    /// Pure and `static` per the project's testing convention (see `chapterIndex(in:at:)`
    /// above and `ProgressReconciler`): the decision is a function of "which book is the
    /// warmed session for" and "what just happened", so it can be pinned by
    /// `PrefetchedSessionLifetimeTests` rather than only exercised through a live player
    /// talking to a real server. Left main-actor-isolated (unlike `chapterIndex`) purely
    /// because its two argument types are nested in this main-actor type; every call site
    /// and the tests are already on the main actor, so nothing wants for it.
    ///
    /// `heldItemId == nil` means nothing is warmed, which is always `.keep` — there is
    /// nothing to hand off and nothing to close. Every other answer is deliberately
    /// biased toward `.close`: an extra close of a session the server has already
    /// finished is harmless (Audiobookshelf ignores it), whereas a missed close is a
    /// permanent open row.
    static func prefetchedSessionDisposition(
        heldItemId: String?,
        event: PrefetchEvent
    ) -> PrefetchedSessionDisposition {
        guard let heldItemId else { return .keep }
        switch event {
        case .startingPlayback(let itemId):
            return itemId == heldItemId ? .handOff : .close
        case .prefetching(let itemId):
            return itemId == heldItemId ? .keep : .close
        case .queueHeadChanged(let newHeadItemId):
            return newHeadItemId == heldItemId ? .keep : .close
        case .prefetchCancelled, .discarded:
            return .close
        }
    }

    /// Applies `prefetchedSessionDisposition` to the held session: returns it for a
    /// hand-off, closes it for a drop, and clears both slots either way.
    @discardableResult
    private func resolvePrefetchedSession(for event: PrefetchEvent) -> PlaybackSession? {
        switch Self.prefetchedSessionDisposition(heldItemId: prefetchedItemId, event: event) {
        case .keep:
            return nil
        case .handOff:
            let session = prefetchedSession
            prefetchedSession = nil
            prefetchedItemId = nil
            return session
        case .close:
            if let session = prefetchedSession { Self.closeOrphanedSession(session) }
            prefetchedSession = nil
            prefetchedItemId = nil
            return nil
        }
    }

    /// Best-effort close of a session that was opened but never played.
    ///
    /// `currentTime` is the position the server itself reported when it opened the
    /// session, and `timeListened` is 0 — so this reports "nothing was listened to",
    /// leaving the book's progress exactly where the server already had it. Anything
    /// else would write a bogus position for a book the user never actually started.
    ///
    /// Fire-and-forget by design: this runs on paths (stop, sign-out, queue edits) that
    /// must not block the UI on a network round trip, and a failure is self-correcting —
    /// the server expires stale open sessions on its own. Errors are swallowed for the
    /// same reason `AudioPlayerService.closeSession()` swallows them.
    // Review 2 Low (Playback), 30 October 2026: internal so CarPlay can close a session whose start was refused.
    static func closeOrphanedSession(_ session: PlaybackSession) {
        // Offline sessions are a local construct built by `DownloadManager.localSession`
        // and have no server row to close — the same `offline-` prefix guard
        // `AudioPlayerService.closeSession()` uses.
        guard !session.id.hasPrefix("offline-") else { return }
        let sessionId = session.id
        let currentTime = session.currentTime ?? 0
        let duration = session.duration ?? 0
        ShelfLog.debug(.playback, "Closing unused prefetched session \(sessionId)")
        Task {
            try? await AudiobookshelfAPI.shared.closeSession(
                sessionId: sessionId,
                currentTime: currentTime,
                timeListened: 0,
                duration: duration
            )
        }
    }

    /// Close a warmed session that the queue has since moved away from. Called from every
    /// queue mutation *except* `advanceQueue`'s own `removeFirst()`, which changes the
    /// head precisely because it is about to hand the session off.
    private func dropPrefetchIfQueueHeadChanged() {
        resolvePrefetchedSession(for: .queueHeadChanged(newHeadItemId: upNext.first?.id))
    }

    /// Close and forget any warmed session, for callers outside this type.
    ///
    /// Item 3, app-termination half: this file imports only `Foundation`/`SwiftUI`, so it
    /// cannot observe `UIApplication.willTerminateNotification` itself without pulling
    /// UIKit into a view model that has deliberately never needed it. The hook is exposed
    /// here instead, so wiring it to the app's existing `scenePhase`/`willTerminate`
    /// handling is a one-line change in `ShelfHeadApp`/`ContentView` (files this change
    /// deliberately does not touch).
    ///
    /// Note for whoever wires it: `.background` is *not* a valid trigger for this app —
    /// audio keeps playing in the background, so the queue (and the warm session it is
    /// about to hand off) is still live there. Only actual termination is.
    func discardPrefetchedSession() {
        prefetchTask?.cancel()
        resolvePrefetchedSession(for: .discarded)
    }

    /// Warm the next queued book's play session + cover shortly before the current one
    /// ends. Best-effort; a failure just falls back to the normal start path.
    private func prefetchNext() {
        guard let next = upNext.first else {
            dropPrefetchIfQueueHeadChanged()
            return
        }
        CoverImageCache.prefetch(itemId: next.id)
        guard prefetchedItemId != next.id else { return }
        // Item 3: a session warmed for a book that is no longer next used to be dropped
        // by the assignment at the bottom of this function. Close it as part of deciding
        // to replace it.
        resolvePrefetchedSession(for: .prefetching(itemId: next.id))
        // Only pre-start a server session for streamed books (offline books build their
        // session locally on demand, so there's nothing to warm).
        guard !DownloadManager.shared.isDownloaded(itemId: next.id),
              NetworkMonitor.shared.isConnected else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor [weak self] in
            guard let session = try? await AudiobookshelfAPI.shared.startPlaybackSession(itemId: next.id) else { return }
            guard let self else {
                // The view model went away mid-flight; nobody is left to hand this to.
                Self.closeOrphanedSession(session)
                return
            }
            // Review Low (Playback), 30 October 2026: the queue head can change while the
            // POST is in flight (book removed, reordered, started by hand). Those paths
            // can't see a session that hasn't landed yet, so check here and close it
            // rather than adopting a warm session for a book that is no longer next.
            guard self.upNext.first?.id == next.id else {
                Self.closeOrphanedSession(session)
                return
            }
            // Anything still held here is stale by construction: this prefetch only ran
            // because `upNext.first` was not what was warmed. Close it rather than
            // assigning over it (one of the original leaks).
            self.resolvePrefetchedSession(for: .discarded)
            self.prefetchedSession = session
            self.prefetchedItemId = next.id
            // Item 3: `!Task.isCancelled` used to be checked *after* the `await` and a
            // cancelled prefetch simply returned — but the POST had already reached the
            // server, so the row existed and nothing ever closed it. Adopting the session
            // into the slots first and then resolving means a cancelled prefetch closes
            // it through exactly the same path as every other drop (all synchronous on
            // the main actor, so no window where it is visible as "warmed").
            if Task.isCancelled {
                self.resolvePrefetchedSession(for: .prefetchCancelled)
            }
        }
    }

    /// If the current book belongs to a series with auto-download enabled, download the
    /// next unfinished, not-yet-downloaded book in that series (policy-gated).
    private func maybeAutoDownloadNextInSeries() {
        guard let book = currentBook, let series = book.seriesName,
              SettingsStore.seriesAutoDownloadEnabled(series),
              let libraryId = book.libraryId else { return }
        Task {
            guard let match = try? await AudiobookshelfAPI.shared.findSeries(libraryId: libraryId, matching: series),
                  let seriesBooks = match.books else { return }
            // Strictly later in the series — this used to take the first unfinished book
            // anywhere in the series, so finishing #5 with #2 unfinished fetched #2.
            // No `isDownloaded` preference here: the point is to reach something that
            // *isn't* on disk yet (`autoDownloadIfAllowed` no-ops on one that already is).
            if let next = seriesBooks.nextUnfinishedInSeries(after: book, seriesName: series) {
                DownloadManager.shared.autoDownloadIfAllowed(next)
            }
        }
    }

    /// Same App Group container `SharedPlayback` writes the widget cover into — a
    /// small file here costs nothing extra to any process, unlike a key in the shared
    /// `UserDefaults` suite.
    private static var queueContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedPlayback.appGroup)
    }

    /// Deliberately one unscoped file, not one per account.
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): the queue used to survive an account switch, so the
    /// outgoing account's books stayed queued and auto-advance could try to play another
    /// server's item id. The fix is that
    /// `AuthViewModel.tearDownAccountScopedState(reason:)` now clears the queue on sign
    /// out, switch and removal alike (it already did on sign out). Scoping the *file* by
    /// the downloads scope key was considered and rejected: this type only reads it once,
    /// in `init`, so per-account files would need a reload hook plus their own eviction
    /// story for accounts that no longer exist — and the widget's mirror of the queue in
    /// `SharedLibrary` is a single unscoped payload regardless.
    private static var queueFileURL: URL? { queueContainerURL?.appendingPathComponent("upNext.json") }

    private static func saveQueue(_ items: [LibraryItem]) {
        guard let queueFileURL else { return }
        if items.isEmpty {
            try? FileManager.default.removeItem(at: queueFileURL)
        } else if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: queueFileURL, options: .atomic)
        }
    }

    private static func loadQueue() -> [LibraryItem] {
        if let queueFileURL,
           let data = try? Data(contentsOf: queueFileURL),
           let items = decodeQueue(data) {
            return items
        }
        // One-time migration off the old App Group `UserDefaults` storage: a queue
        // saved by a previous version of the app would otherwise sit in the App Group
        // plist forever, un-migrated and still bloating every process that opens the
        // suite — exactly the problem this fix exists to remove. Reading it once here,
        // writing it to the new file, and deleting the old key closes that gap instead
        // of just not making it worse for new writes.
        return migrateLegacyQueueIfNeeded()
    }

    /// Review Low (Playback), 30 October 2026: decoding the queue as one `[LibraryItem]`
    /// meant a single undecodable entry threw away the whole queue. Decodes element by
    /// element and drops only the bad ones; the file format (a JSON array of
    /// `LibraryItem`) is unchanged. `nil` only when the data isn't an array at all.
    nonisolated static func decodeQueue(_ data: Data) -> [LibraryItem]? {
        struct Lossy: Decodable {
            let item: LibraryItem?
            init(from decoder: Decoder) throws { item = try? LibraryItem(from: decoder) }
        }
        guard let entries = try? JSONDecoder().decode([Lossy].self, from: data) else { return nil }
        return entries.compactMap(\.item)
    }

    private static func migrateLegacyQueueIfNeeded() -> [LibraryItem] {
        guard let defaults = UserDefaults(suiteName: SharedPlayback.appGroup),
              let data = defaults.data(forKey: legacyQueueKey) else { return [] }
        defer { defaults.removeObject(forKey: legacyQueueKey) }
        guard let items = decodeQueue(data) else { return [] }
        saveQueue(items)
        return items
    }

    @ObservationIgnored private var chapterOverrideObserver: NSObjectProtocol?
    @ObservationIgnored private var downloadRemovedObserver: NSObjectProtocol?

    /// Review 3 Medium 6: whether a removed download should tear down the player.
    nonisolated static func shouldStopForRemovedDownload(removedId: String?, currentId: String?) -> Bool {
        guard let currentId else { return false }
        return removedId == nil || removedId == currentId
    }

    init() {
        // Review 3 Medium 6: a removed download under the player clears the bar too.
        downloadRemovedObserver = NotificationCenter.default.addObserver(
            forName: .shelfheadPlayingDownloadRemoved, object: nil, queue: .main
        ) { [weak self] note in
            let removed = note.userInfo?["itemId"] as? String
            MainActor.assumeIsolated {
                guard let self, Self.shouldStopForRemovedDownload(removedId: removed, currentId: self.currentBook?.id) else { return }
                self.stop()
            }
        }
        // Batch 427 (Section E): chapters made on this device were saved or reset; the live
        // session re-resolves its chapter list (Now Playing, scrubber, sleep timer, CarPlay).
        chapterOverrideObserver = NotificationCenter.default.addObserver(
            forName: .shelfheadChapterOverrideChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let itemId = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, self.currentBook?.id == itemId else { return }
                self.playerService.reloadChapterOverride()
            }
        }
        // ARCH-8 (REVIEW_2026-08-12.md): `[weak self]` previously sat on the *inner*
        // `Task` closure, not this outer one — for the inner closure to actually form a
        // weak reference when it eventually runs, this outer closure has to hold `self`
        // to begin with, and by default a closure captures strongly. Since
        // `AudioPlayerService.shared` is an immortal singleton holding both of these
        // closures forever, that made it strongly retain this view model for the
        // lifetime of the process — harmless with exactly one instance, but
        // `ContentView`'s `#Preview` constructs a second `PlayerViewModel`, and because
        // `onPlaybackFinished`/`onNearEnd` are single-assignment slots, the most
        // recently constructed instance silently steals both callbacks from whichever
        // one is actually live. `[weak self]` now sits on this outer closure, so the
        // singleton no longer keeps any `PlayerViewModel` alive by itself.
        //
        // When the current book finishes, roll into the queue automatically.
        playerService.onPlaybackFinished = { [weak self] in
            // ASO pass (AppStoreListing.md, 14 Sep 2026): "finished a book" is one of the
            // two review-prompt triggers. `AudioPlayerService` is `@MainActor` and calls
            // `onPlaybackFinished?()` directly (not via `Task`), so this closure body is
            // already on the main actor — safe to call straight into the (also
            // `@MainActor`) `ReviewPromptManager` without hopping through another `Task`.
            ReviewPromptManager.shared.noteBookFinished()
            // Batch 443: read before advanceQueue swaps the current book.
            if let book = self?.currentBook { ReadingSiteSync.shared.bookFinished(book) }
            Task { @MainActor in self?.advanceQueue() }
        }
        // Batch 443: reading-site sync rides the regular progress sync. The first sync of a
        // book marks it Currently Reading (once per session); both calls no-op unless the
        // listener connected Hardcover and turned syncing on.
        playerService.onProgressSynced = { [weak self] itemId, currentTime, duration in
            guard let book = self?.currentBook, book.id == itemId, duration > 0 else { return }
            ReadingSiteSync.shared.bookStarted(book)
            ReadingSiteSync.shared.progressChanged(book, fraction: currentTime / duration)
        }
        // Near the end of the current book, warm the next queued book and, if the
        // current book's series has auto-download enabled, fetch the next unheard book.
        playerService.onNearEnd = { [weak self] in
            Task { @MainActor in
                self?.prefetchNext()
                self?.maybeAutoDownloadNextInSeries()
            }
        }
        // Batch 490 (REVIEW 2026-11-11 F20): resuming a book a sleep timer stopped, well
        // past where the timer was set, offers "Jump back" there. An offer only — it
        // never seeks by itself.
        playerService.onSleepResumeOffer = { [weak self] itemId, armedAt in
            guard let self, self.currentBook?.id == itemId else { return }
            let now = self.currentTime
            self.seekUndoTime = armedAt
            self.seekUndoReason = .sleepTimer
            self.seekUndoTarget = now
            self.seekUndoTargetChapterId = self.chapters.last(where: { $0.start <= now })?.id
        }
        // Restore a queue persisted from a previous launch (assignment in init does
        // not trigger didSet, so this doesn't re-save).
        upNext = Self.loadQueue()
    }

    /// Put a book at the front of the queue ("Play Next").
    func playNext(_ item: LibraryItem) {
        upNext.removeAll { $0.id == item.id }
        upNext.insert(item, at: 0)
        persistQueue()
        dropPrefetchIfQueueHeadChanged()
        infoMessage = String(localized: "Playing next", comment: "Toast after Play Next puts a book at the head of the Up Next queue")
    }

    /// Append a book to the end of the queue ("Add to Up Next").
    func addToQueue(_ item: LibraryItem) {
        guard !upNext.contains(where: { $0.id == item.id }) else {
            infoMessage = String(localized: "Already in Up Next", comment: "Toast when the book is already in the Up Next queue")
            return
        }
        upNext.append(item)
        persistQueue()
        // Only moves the head when the queue was empty (so nothing was warmed), but the
        // check is cheap and keeps every queue mutation on the same rule.
        dropPrefetchIfQueueHeadChanged()
        infoMessage = String(localized: "Added to Up Next", comment: "Toast after a book is added to the Up Next queue")
    }

    /// Result of a bulk "Add to Up Next" (Library select mode, plan 2026-10-05 §3.2).
    struct QueueAddPlan: Equatable {
        /// Ids to append, in the order given. Resolve against `adding` via `items(from:)`.
        let idsToAppend: [String]
        /// Books left out: the current book, already queued, or duplicated within the batch.
        let skippedCount: Int
        /// The single toast for the whole action.
        let message: String
    }

    /// Pure decision for a bulk add. Mirrors the single add's rule (already queued is a
    /// no-op) and also skips the current book, since queuing what is playing is pointless.
    nonisolated static func queueAddPlan(addingIds: [String], existingIds: [String],
                                         currentId: String?) -> QueueAddPlan {
        var seen = Set(existingIds)
        if let currentId { seen.insert(currentId) }
        var append: [String] = []
        for id in addingIds where seen.insert(id).inserted { append.append(id) }
        let skipped = addingIds.count - append.count
        let message: String
        if append.isEmpty {
            message = String(localized: "Already in Up Next", comment: "Toast when the book is already in the Up Next queue")
        } else {
            let added = append.count == 1 ? String(localized: "Added to Up Next", comment: "Toast after a book is added to the Up Next queue")
                : String(localized: "Added \(append.count) books to Up Next", comment: "Toast after several books are added to Up Next. %lld is the count (not 1)")
            if skipped == 0 {
                message = added
            } else if skipped == 1 {
                message = String(localized: "\(added) \u{00B7} 1 was already queued", comment: "Bulk add toast suffix. %@ is the 'Added …' sentence; exactly one book was skipped because it was already queued")
            } else {
                message = String(localized: "\(added) \u{00B7} \(skipped) were already queued", comment: "Bulk add toast suffix. First %@ is the 'Added …' sentence, %lld is how many books were skipped because they were already queued")
            }
        }
        return QueueAddPlan(idsToAppend: append, skippedCount: skipped, message: message)
    }

    /// `LibraryItem` convenience over `queueAddPlan(addingIds:existingIds:currentId:)`.
    nonisolated static func queueAddPlan(adding: [LibraryItem], existing: [LibraryItem],
                                         currentId: String?) -> QueueAddPlan {
        queueAddPlan(addingIds: adding.map(\.id), existingIds: existing.map(\.id), currentId: currentId)
    }

    /// Append several books in one mutation: one persist, one toast.
    func addToQueue(_ items: [LibraryItem]) {
        let plan = Self.queueAddPlan(adding: items, existing: upNext, currentId: currentBook?.id)
        if !plan.idsToAppend.isEmpty {
            var byId: [String: LibraryItem] = [:]
            for item in items where byId[item.id] == nil { byId[item.id] = item }
            upNext.append(contentsOf: plan.idsToAppend.compactMap { byId[$0] })
            persistQueue()
            dropPrefetchIfQueueHeadChanged()
        }
        infoMessage = plan.message
    }

    func removeFromQueue(_ item: LibraryItem) {
        upNext.removeAll { $0.id == item.id }
        persistQueue()
        dropPrefetchIfQueueHeadChanged()
    }

    // MARK: Queue removal with undo (Critique 2026-10-06, harden)

    /// What `undoQueueRemoval()` puts back, and where.
    struct QueueRemovalUndo: Equatable {
        let item: LibraryItem
        let index: Int
        static func == (l: Self, r: Self) -> Bool { l.item.id == r.item.id && l.index == r.index }
    }

    /// Critique 2026-10-06 (harden): the Up Next sheet's swipe (a full-swipe `.onDelete`) and
    /// long-press Remove dropped a queued book with no way back. Set by
    /// `removeFromQueueWithUndo(_:)`; the sheet hosts the toast.
    private(set) var queueRemovalUndo: QueueRemovalUndo?
    var queueRemovalUndoMessage: String?

    nonisolated static func queueRemovalMessage(title: String) -> String {
        String(localized: "Removed \(title) from Up Next", comment: "Toast with Undo after removing a book from Up Next. %@ is the book title")
    }

    /// Where a removed book goes back: its old place, clamped to the queue as it is now.
    nonisolated static func queueReinsertIndex(original: Int, count: Int) -> Int {
        min(max(original, 0), count)
    }

    func removeFromQueueWithUndo(_ item: LibraryItem) {
        guard let index = upNext.firstIndex(where: { $0.id == item.id }) else { return }
        removeFromQueue(item)
        queueRemovalUndo = QueueRemovalUndo(item: item, index: index)
        queueRemovalUndoMessage = Self.queueRemovalMessage(title: item.title)
    }

    func undoQueueRemoval() {
        guard let undo = queueRemovalUndo else { return }
        queueRemovalUndo = nil
        queueRemovalUndoMessage = nil
        // Already back (re-added meanwhile) or now the loaded book: nothing to restore.
        guard !upNext.contains(where: { $0.id == undo.item.id }), currentBook?.id != undo.item.id else { return }
        upNext.insert(undo.item, at: Self.queueReinsertIndex(original: undo.index, count: upNext.count))
        persistQueue()
        dropPrefetchIfQueueHeadChanged()
        Haptics.selection()
    }

    /// Empties Up Next. Also called from `AuthViewModel.tearDownAccountScopedState` on
    /// sign-out, account switch and account removal — which is why the warmed session has
    /// to be closed here rather than only in the UI's "Clear" button: those paths run
    /// while the outgoing account's credentials are still installed (the teardown
    /// deliberately clears `AuthStore` only after this returns), so this is the last
    /// moment the session can be closed against the server that opened it.
    func clearQueue() {
        upNext.removeAll()
        persistQueue()
        dropPrefetchIfQueueHeadChanged()
    }

    /// Reorder the queue (drag-to-reorder in the queue editor).
    func moveInQueue(from source: IndexSet, to destination: Int) {
        upNext.move(fromOffsets: source, toOffset: destination)
        persistQueue()
        dropPrefetchIfQueueHeadChanged()
    }

    /// Play a queued book now, removing it from the queue.
    ///
    /// Deliberately no `dropPrefetchIfQueueHeadChanged()` here: `startPlayback` resolves
    /// the warmed session itself, so tapping the book that was warmed hands the session
    /// over (gapless, and no wasted session), and tapping any other queued book closes it.
    func playFromQueue(_ item: LibraryItem) {
        // Review Low (Playback), 30 October 2026: the book used to leave the queue before
        // the start was attempted, so a start refused because another was already loading
        // dropped it and played nothing. It now leaves only once it is the current book.
        Task {
            await startPlayback(for: item)
            removeFromQueueIfStarted(item)
        }
    }

    /// Removes `item` from Up Next once it is actually the loaded book (see `playFromQueue`).
    private func removeFromQueueIfStarted(_ item: LibraryItem) {
        guard currentBook?.id == item.id, upNext.contains(where: { $0.id == item.id }) else { return }
        upNext.removeAll { $0.id == item.id }
        persistQueue()
        // Review 2 Low (Playback), 30 October 2026: the head may have changed; close a stale warm session.
        dropPrefetchIfQueueHeadChanged()
    }

    /// Review 2 Medium 5, 30 October 2026: after the server wait in `advanceQueue`, only
    /// continue if nothing else took over playback meanwhile — the player is still on the
    /// book that finished, it isn't playing, and no session start is loading.
    nonisolated static func shouldContinueAdvance(finishedItemId: String?, currentItemId: String?,
                                                  isPlaying: Bool, isLoadingSession: Bool) -> Bool {
        finishedItemId == currentItemId && !isPlaying && !isLoadingSession
    }

    /// Review Medium 11, 30 October 2026: a queued entry's finished flag is a snapshot from
    /// when it was queued. Asks the server for the book's current progress; `nil` when it
    /// can't be reached in time (offline, slow), so the caller keeps the snapshot's answer.
    /// Review 7 Low (advance wait): with the next session already warmed the check is a nicety, so cap
    /// the wait at 1 s; otherwise keep 4 s. Pure, for tests.
    nonisolated static func freshFinishedWait(holdingPrefetchedSession: Bool) -> Double { holdingPrefetchedSession ? 1 : 4 }

    private static func freshFinishedState(for itemId: String, wait: Double = 4) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                guard let fresh = try? await AudiobookshelfAPI.shared.getItem(itemId: itemId) else { return nil }
                return fresh.isFinished
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(wait))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Auto-advance to the next queued book when playback finishes.
    private func advanceQueue() {
        guard SettingsStore.autoplayNext else {
            // Autoplay off: the book that just finished is the end of it, so a session
            // warmed by `onNearEnd` will never be played. (`onNearEnd` fires regardless
            // of this setting — the same warm-up also serves a manual tap in Up Next —
            // so this is a real leak path, not a theoretical one.)
            resolvePrefetchedSession(for: .discarded)
            return
        }
        // Drop any already-finished entries from the front of the queue before picking
        // what to play — a queued book can end up finished by the time it's reached
        // (finished from another device, marked finished manually, synced from the
        // server) without ever being removed from `upNext`, since queue membership and
        // finished-state are tracked independently. Silently starting a finished book
        // from autoplay would be a worse experience than skipping it, so these are
        // dropped here rather than played.
        var skippedAny = false
        while let candidate = upNext.first, candidate.isFinished {
            upNext.removeFirst()
            skippedAny = true
        }
        if skippedAny {
            persistQueue()
            // The head moved past whatever was warmed — close it before picking again.
            dropPrefetchIfQueueHeadChanged()
            infoMessage = String(localized: "Skipped a finished title in Up Next", comment: "Toast when auto-advance skips a book already finished")
        }
        guard let next = upNext.first else {
            // Nothing left to play: a session warmed for a book the skip loop just
            // dropped is already closed above, but an empty queue with something still
            // held (a book removed elsewhere) needs the same treatment.
            resolvePrefetchedSession(for: .discarded)
            // Queue is empty (or emptied by the skip above) — see if the book that just
            // finished was part of a series with an obvious next book to line up.
            maybeAutoQueueNextInSeries()
            return
        }
        // Don't auto-advance to a streamed book we can't reach while offline — keep it
        // in the queue so it plays once connectivity returns / the user taps it.
        if !DownloadManager.shared.isDownloaded(itemId: next.id), !NetworkMonitor.shared.isConnected {
            // Staying put: the book keeps its place in the queue but nothing is going to
            // play now, so the warmed session would sit open until the user comes back.
            // (Best-effort — we're offline, so this close will usually fail and the
            // server's own stale-session expiry is the backstop.)
            resolvePrefetchedSession(for: .discarded)
            return
        }
        // Review Medium 11, 30 October 2026: confirm with the server that the next book
        // isn't already finished (e.g. on another device since it was queued). Falls back
        // to the queued snapshot (not finished, per the loop above) if it can't answer.
        let finishedItemId = currentBook?.id
        Task { @MainActor in
            var freshFinished: Bool?
            if NetworkMonitor.shared.isConnected {
                freshFinished = await Self.freshFinishedState(
                    for: next.id, wait: Self.freshFinishedWait(holdingPrefetchedSession: prefetchedSession != nil && prefetchedItemId == next.id))
            }
            // The queue may have changed while we waited; whoever changed it owns the head.
            guard upNext.first?.id == next.id else { return }
            // Review 2 Medium 5: the user (or Siri/CarPlay/Watch) may have started something
            // else during the wait; leave the queue alone then.
            guard Self.shouldContinueAdvance(finishedItemId: finishedItemId, currentItemId: currentBook?.id,
                                             isPlaying: isPlaying, isLoadingSession: isLoadingSession) else { return }
            if freshFinished == true {
                upNext.removeFirst()
                persistQueue()
                dropPrefetchIfQueueHeadChanged()
                infoMessage = String(localized: "Skipped a finished title in Up Next", comment: "Toast when auto-advance skips a book already finished")
                advanceQueue()
                return
            }
            // Deliberately NOT `dropPrefetchIfQueueHeadChanged()`: this book is about to
            // play. `startPlayback` hands the warmed session over on an item match and
            // closes it on a mismatch.
            // Auto-advance: keep whatever player state the user was in (don't force-open).
            // Review Low (Playback): leave the queue only once the start has taken hold.
            await startPlayback(for: next, openPlayer: false)
            removeFromQueueIfStarted(next)
        }
    }

    /// When the queue runs out right as a book finishes, and that book was part of a
    /// series, automatically add the next unfinished book in the series to Up Next —
    /// mirrors `maybeAutoDownloadNextInSeries()`'s series lookup, but queues instead of
    /// (or in addition to) downloading. Opt-in (off by default since 28 Oct 2026) via `SettingsStore.autoContinueSeries`
    /// (default on) for anyone who'd rather queue the next book themselves.
    private func maybeAutoQueueNextInSeries() {
        guard SettingsStore.autoContinueSeries, upNext.isEmpty,
              let book = currentBook, let series = book.seriesName,
              let libraryId = book.libraryId else { return }
        Task { @MainActor in
            guard let match = try? await AudiobookshelfAPI.shared.findSeries(libraryId: libraryId, matching: series),
                  let seriesBooks = match.books else { return }
            // Re-check the queue is still empty — `onNearEnd`/`advanceQueue` can race with
            // this async lookup if the user manually queues something in the meantime.
            // `nextUnfinishedInSeries` is strictly later in the series: this used to take
            // the first unfinished book anywhere in it, so finishing #5 with #2 unfinished
            // queued #2 rather than #6.
            guard upNext.isEmpty,
                  let next = seriesBooks.nextUnfinishedInSeries(after: book, seriesName: series)
            else { return }
            upNext.append(next)
            persistQueue()
            infoMessage = String(localized: "Added the next book in \(series) to Up Next", comment: "Toast when the next book of a series is queued automatically. %@ is the series name")
        }
    }

    /// Restores the last-played book into the mini-player on launch (paused, ready to
    /// resume), reading the snapshot persisted in the App Group. Skips books that look
    /// finished so a completed title doesn't reappear.
    func restoreLastSession() {
        guard currentBook == nil, playerService.currentSession == nil,
              let snap = SharedPlayback.read(), !snap.itemId.isEmpty,
              snap.progress < 0.985 else { return }

        restoredCurrentTime = snap.currentTime
        restoredDuration = snap.duration
        // Polish pass (J2-15): a downloaded book already has its chapters on disk, so use that
        // copy first. The placeholder below is chapterless until `getItem` answers, which
        // offline is never.
        let localCopy = DownloadManager.shared.libraryItem(for: snap.itemId)
        if let localCopy, !localCopy.chapters.isEmpty {
            restoredDuration = localCopy.duration > 0 ? localCopy.duration : snap.duration
        }
        currentBook = (localCopy.flatMap { $0.chapters.isEmpty ? nil : $0 }) ?? LibraryItem(
            id: snap.itemId, ino: nil, libraryId: nil, mediaType: "book",
            media: Media(
                metadata: MediaMetadata(
                    title: snap.title, subtitle: nil, authorName: snap.author, narratorName: nil,
                    seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
                    language: nil, genres: nil, isbn: nil, asin: nil, series: nil
                ),
                coverPath: nil, duration: snap.duration, chapters: [],
                audioFiles: nil, numChapters: 0, numAudioFiles: 0, episodes: nil, ebookFile: nil
            ),
            numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: nil
        )

        // Fetch full detail (chapters/duration) so the Now Playing screen can show
        // chapter-relative progress before playback starts — avoids the whole-book
        // → chapter length "swap" when you press play on a restored book.
        Task { @MainActor in
            if let full = try? await AudiobookshelfAPI.shared.getItem(itemId: snap.itemId),
               playerService.currentSession == nil {
                currentBook = full
                restoredDuration = full.duration > 0 ? full.duration : restoredDuration
            }
        }
    }

    /// Adopt a session that's already playing in `AudioPlayerService` but that the UI
    /// doesn't know about yet — e.g. a book started from CarPlay or a Siri intent before
    /// the phone app's UI was ever opened. Without this the phone shows nothing playing.
    /// Safe to call whenever the app becomes active; it no-ops if the UI already has a book.
    func adoptActiveSessionIfNeeded() {
        guard currentBook == nil,
              playerService.currentSession != nil,
              let itemId = playerService.currentItemId else { return }
        Task { @MainActor in
            if let full = try? await AudiobookshelfAPI.shared.getItem(itemId: itemId),
               currentBook == nil {   // re-check: user may have opened a book meanwhile
                currentBook = full
            }
        }
    }

    /// Batch 406: a position another device or the web player just synced
    /// (`ServerEventSocket`). Moves the player only when `RemoteProgressDecision` allows
    /// it — the loaded item and episode, paused (never a playing or starting book), not
    /// this device's own session echoing back, and the remote write newer than this
    /// device's last local write (the App Group snapshot / download manifest stamps, by
    /// `ProgressReconciler`'s newer-wins rule). A restored book with no live session only
    /// gets its displayed position moved; Play then starts from the server's position anyway.
    /// No "Jump back" chip: the user didn't make this jump, and the old spot is stale.
    @discardableResult
    func applyRemoteProgress(_ progress: MediaProgress, sessionId: String?, ownSessionIds: Set<String>) -> RemoteProgressDecision.PlayerAction {
        let itemId = currentBook?.id
        let snapshot = SharedPlayback.read()
        let snapshotMs = snapshot.flatMap { $0.itemId == itemId ? $0.updatedAt.timeIntervalSince1970 * 1000 : nil }
        let manifestMs = itemId.flatMap { DownloadManager.shared.manifest(for: $0)?.lastUpdate }
        let localMs = [snapshotMs, manifestMs].compactMap { $0 }.max()
        let action = RemoteProgressDecision.playerAction(
            eventSessionId: sessionId, ownSessionIds: ownSessionIds,
            eventItemId: progress.libraryItemId, eventEpisodeId: progress.episodeId,
            loadedItemId: itemId, loadedEpisodeId: currentEpisode?.id,
            isPlayingOrStarting: isPlaying || isLoadingSession || pendingBook != nil,
            localTime: currentTime, localLastUpdateMs: localMs,
            remoteTime: progress.currentTime, remoteLastUpdateMs: progress.lastUpdate.map(Double.init),
            remoteIsFinished: progress.isFinished ?? false)
        if case .moveTo(let time) = action {
            seekUndoTime = nil
            if playerService.currentSession != nil { playerService.seek(to: time) } else { restoredCurrentTime = time }
        }
        return action
    }

    var remainingTime: Double {
        max(0, duration - currentTime)
    }

    // MARK: - Time-left / finish-by estimate

    /// Wall-clock listening time remaining, scaled by the current playback speed.
    var remainingListeningTime: Double {
        remainingTime / max(Double(playbackRate), 0.1)
    }

    /// The clock time the book is projected to finish — only while actively playing
    /// (a paused estimate would be misleading, so callers hide it then).
    /// The alert's Retry: starts the same book or episode again.
    func retryFailedStart() {
        guard let failed = lastFailedStart else { return }
        lastFailedStart = nil
        Task {
            if let episode = failed.episode {
                await startEpisodePlayback(for: failed.item, episode: episode)
            } else {
                await startPlayback(for: failed.item)
            }
        }
    }

    /// True when the current book is playing from the server rather than a download, so a
    /// long stall can honestly be put down to the server.
    var isStreamingCurrentBook: Bool {
        guard let id = currentBook?.id else { return false }
        return !DownloadManager.shared.isDownloaded(itemId: id)
    }

    /// Plain-language copy for a playback start that failed (critique 2026-10-05,
    /// clarify). It used to be "Failed to start playback: " plus `localizedDescription`,
    /// which surfaced strings like "HTTP error (502)" or "Failed to parse response: …".
    /// Each message says what failed and what to do; the raw error goes to the log.
    /// Pure so `PlaybackErrorCopyTests` pins it.
    nonisolated static func playbackStartFailureMessage(for error: Error, isEpisode: Bool) -> String {
        let thing = isEpisode ? String(localized: "this episode", comment: "Noun phrase inserted into error messages (podcast episode)")
                              : String(localized: "this book", comment: "Noun phrase inserted into error messages (audiobook)")
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "Your connection dropped while starting \(thing). Check your connection and try again.", comment: "Playback start error. %@ is 'this book' or 'this episode'")
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return String(localized: "Couldn't reach your server. Check that it's running, then try again.", comment: "Playback start error when the server is unreachable")
            default:
                break
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                return String(localized: "Your server didn't accept your sign-in. Sign in again in Settings, then try again.", comment: "Playback start error for a 401")
            case .forbidden:
                return String(localized: "Your account on this server doesn't have access to \(thing).", comment: "Playback start error for a 403. %@ is 'this book' or 'this episode'")
            case .notFound:
                return String(localized: "Couldn't find \(thing) on your server. It may have been moved or removed.", comment: "Playback start error for a 404. %@ is 'this book' or 'this episode'")
            case .serverError:
                return String(localized: "Your server had a problem starting \(thing). Try again in a moment.", comment: "Playback start error for a 5xx. %@ is 'this book' or 'this episode'")
            default:
                break
            }
        }
        return String(localized: "Couldn't start \(thing). Try again, or check Settings > Diagnostics.", comment: "Generic playback start error. %@ is 'this book' or 'this episode'")
    }

    var estimatedFinishDate: Date? {
        guard isPlaying, duration > 0, remainingListeningTime > 1 else { return nil }
        return Date().addingTimeInterval(remainingListeningTime)
    }

    /// e.g. "1.5×" / "2×" for the current rate.
    var playbackRateLabel: String {
        String(format: "%g×", playbackRate)
    }

    // MARK: - Playback Actions

    /// `openPlayer` controls whether the full player is presented. It's true for an
    /// explicit user play, but false for automatic advances (queue/widget/CarPlay) so
    /// the player doesn't pop open over whatever the user is doing.
    func startPlayback(for item: LibraryItem, prefetched: PlaybackSession? = nil, openPlayer: Bool = true) async {
        await startPlayback(for: item, prefetched: prefetched, openPlayer: openPlayer, alreadyBegun: false)
    }

    /// LS-2 (docs/design-review.md): the real implementation. `alreadyBegun` exists only
    /// for `togglePlayPause()`'s `isAwaitingResume` branch, which has to publish
    /// `pendingBook`/`isLoadingSession` synchronously — before creating the `Task` that
    /// calls this — so two rapid taps on a restored book can't both slip past
    /// `beginLoading(for:)`'s single-flight guard before the first `Task` gets a chance
    /// to run. Every other caller goes through the public overload above, which passes
    /// `false` and lets this method do its own guarding.
    private func startPlayback(for item: LibraryItem, prefetched: PlaybackSession?, openPlayer: Bool, alreadyBegun: Bool) async {
        errorMessage = nil

        // Respect the cellular-streaming preference (downloaded books always allowed).
        if !DownloadManager.shared.isDownloaded(itemId: item.id),
           !SettingsStore.allowCellularStreaming,
           NetworkMonitor.shared.isConnected, !NetworkMonitor.shared.isOnWiFi {
            errorMessage = String(localized: "Streaming on cellular is off. Download this book or connect to Wi-Fi.", comment: "Error when streaming a book over cellular is disabled in settings")
            // LS-2: `alreadyBegun` means the caller already published pendingBook/
            // isLoadingSession before this guard could refuse — undo that here so it
            // doesn't leak. A fresh (non-alreadyBegun) call never published anything yet,
            // so there's nothing to clear.
            if alreadyBegun { endLoading() }
            return
        }

        // Fail fast when offline and the book isn't available locally — otherwise
        // startPlaybackSession waits out a 30s network timeout before falling back.
        if !DownloadManager.shared.isDownloaded(itemId: item.id),
           !NetworkMonitor.shared.isConnected {
            errorMessage = String(localized: "You're offline. Download this book to listen without a connection.", comment: "Error when starting a non-downloaded book while offline")
            if alreadyBegun { endLoading() }
            return
        }

        if alreadyBegun {
            // pendingBook/isLoadingSession were already published synchronously by
            // togglePlayPause() before it created the Task that reached here.
        } else {
            // LS-2: single-flight guard, and publish `pendingBook` before any network
            // await so the mini player can show the tapped book's cover/title
            // immediately. The guards above run first, so a refused start never
            // publishes a pending book.
            guard beginLoading(for: item) else { return }
        }
        defer { endLoading() }
        // A new attempt replaces any earlier failure, so Driving Mode's line and the root
        // alert never show a failure for a book that then started fine (fourth run).
        startFailureMessage = nil
        lastFailedStart = nil

        // Keep the access token fresh for streamed playback — the token is embedded in
        // the AVPlayer asset URL and expires ~hourly. Skipped for downloads/offline.
        if !DownloadManager.shared.isDownloaded(itemId: item.id), NetworkMonitor.shared.isConnected {
            await AudiobookshelfAPI.shared.ensureFreshAccessToken()
        }

        // Item 3: resolve the warmed session here rather than only in `advanceQueue`, so
        // that *every* way of starting a book settles it — starting the warmed book by
        // hand hands the session over, and starting any other book closes it instead of
        // orphaning it. Placed after the cellular/offline guards above so a refused start
        // leaves the queue (and its warm session) untouched. `prefetched` is still honoured
        // for callers that pass one explicitly.
        let held = resolvePrefetchedSession(for: .startingPlayback(itemId: item.id))
        let warmed: PlaybackSession?
        if let prefetched {
            // An explicitly supplied session wins, but a *different* one held here still
            // has to be closed rather than dropped.
            if let held, held.id != prefetched.id { Self.closeOrphanedSession(held) }
            warmed = prefetched
        } else {
            warmed = held
        }

        do {
            // Polish pass Phase 2a #3: one resolver picks the session and the start position
            // (shared with CarPlay). A downloaded book waits at most a few seconds for the
            // server; the older catch-and-fall-back-to-local path lives inside it now.
            let start = try await Self.resolveStart(for: item, warmed: warmed)
            // Review Medium 10 (30 October 2026): a session with no audio tracks is refused
            // before the player changes anything; close it and report the failure.
            guard playerService.startPlayback(session: start.session, startTime: start.startTime) else {
                Self.closeOrphanedSession(start.session)
                throw URLError(.badServerResponse)
            }
            currentBook = item
            applyDefaultSpeed()
            if openPlayer { showFullPlayer = true }
        } catch {
            ShelfLog.error(.playback, "Start playback failed: \(error)")
            lastFailedStart = (item, nil)
            startFailureMessage = Self.playbackStartFailureMessage(for: error, isEpisode: false)
        }
    }

    /// The session a book starts with and the position it starts from.
    struct ResolvedStart {
        let session: PlaybackSession
        let startTime: Double
        /// True when this is the downloaded copy's `offline-` session.
        let isLocal: Bool
    }

    /// How long a downloaded book waits for the server before starting from the download.
    nonisolated static let downloadedServerWait: TimeInterval = 3

    /// Polish pass Phase 2a #3 (4 November 2026): picks the session and start position for
    /// a book, for the phone player and CarPlay alike.
    ///
    ///   - A warmed (prefetched) session for this book counts as the server's answer.
    ///   - A downloaded book skips the server when it's known to be unreachable, and
    ///     otherwise waits at most `downloadedServerWait`. A server answer that arrives
    ///     after that is closed, so it doesn't sit open on the server.
    ///   - A book that isn't downloaded needs the server and waits for it as before.
    /// The position is `ProgressReconciler.startPosition` over the server's answer, the
    /// downloaded copy, anything still queued for upload, and the last server position
    /// this device saw. Throws only when there's neither a server session nor a download.
    static func resolveStart(for item: LibraryItem, warmed: PlaybackSession?) async throws -> ResolvedStart {
        let itemId = item.id
        let dm = DownloadManager.shared
        let local = dm.isDownloaded(itemId: itemId) ? dm.localSession(for: itemId) : nil

        var serverSession: PlaybackSession?
        var serverError: Error?
        if let warmed, (warmed.libraryItemId ?? warmed.libraryItem?.id) == itemId {
            serverSession = warmed
        } else {
            // A warmed session for another book is unusable here; close it, don't drop it.
            if let warmed { closeOrphanedSession(warmed) }
            if local == nil {
                serverSession = try await AudiobookshelfAPI.shared.startPlaybackSession(itemId: itemId)
            } else if !PlaybackCoordinator.shouldTryDownloadsFirst(
                status: ReachabilityStore.shared.trustedStatus,
                deviceIsOnline: NetworkMonitor.shared.isConnected) {
                do {
                    serverSession = try await raceServerSession(itemId: itemId, seconds: downloadedServerWait)
                } catch {
                    serverError = error
                }
            }
        }

        let scope = AudioPlayerService.currentProgressScope()
        let queued = await PendingProgressQueue.shared.audioEntry(itemId: itemId, scope: scope)
        let manifest = dm.manifest(for: itemId)
        let known = await AudiobookshelfAPI.shared.lastKnownServerProgress(itemId: itemId)

        // The last server position this device saw: the furthest of the item's own copy
        // and the API's record (both are server answers; either may be missing).
        let lastKnown = [item.mediaProgress, known].compactMap { p -> ProgressReconciler.StartCandidate? in
            guard let p, let t = p.currentTime else { return nil }
            return .init(time: t, updatedAtMs: p.lastUpdate.flatMap { $0 > 0 ? Double($0) : nil })
        }.max { $0.time < $1.time }

        let serverCandidate: ProgressReconciler.StartCandidate? = serverSession.map { session in
            let time = session.currentTime ?? 0
            // `/play` carries no progress timestamp of its own; borrow one from a server
            // record at the same position, otherwise leave it unknown (never zero).
            let stamp = session.libraryItem?.mediaProgress?.lastUpdate
                ?? [item.mediaProgress, known].compactMap { $0 }
                    .first { abs(($0.currentTime ?? -10) - time) < 1 }?.lastUpdate
            return .init(time: time, updatedAtMs: stamp.flatMap { $0 > 0 ? Double($0) : nil })
        }
        let localCandidate = manifest.map {
            ProgressReconciler.StartCandidate(time: $0.currentTime, updatedAtMs: $0.lastUpdate.flatMap { $0 > 0 ? $0 : nil })
        }
        let queuedCandidate = queued.map {
            ProgressReconciler.StartCandidate(time: $0.currentTime, updatedAtMs: $0.updatedAt > 0 ? $0.updatedAt * 1000 : nil)
        }

        guard let session = serverSession ?? local else {
            throw serverError ?? URLError(.cannotConnectToHost)
        }
        let duration = session.duration ?? manifest?.duration ?? 0
        let startTime = ProgressReconciler.startPosition(
            serverAnswered: serverSession != nil,
            server: serverCandidate, local: localCandidate, queued: queuedCandidate,
            lastKnownServer: lastKnown, duration: duration)
        ShelfLog.info(.playback, "Start \(itemId) at \(Int(startTime))s (\(serverSession != nil ? "server answered" : "local"))")
        return ResolvedStart(session: session, startTime: startTime, isLocal: serverSession == nil)
    }

    /// Starts a `/play` session but stops waiting after `seconds`. The request itself is
    /// left running; if it answers after the deadline, that session is closed rather than
    /// orphaned on the server. Returns nil on timeout; rethrows the request's own error.
    private static func raceServerSession(itemId: String, seconds: TimeInterval) async throws -> PlaybackSession? {
        let request = Task { try await AudiobookshelfAPI.shared.startPlaybackSession(itemId: itemId) }
        let outcome: Result<PlaybackSession, Error>? = await withTaskGroup(of: Result<PlaybackSession, Error>?.self) { group in
            group.addTask {
                do { return .success(try await request.value) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let outcome else {
            Task { @MainActor in
                if let late = try? await request.value { closeOrphanedSession(late) }
            }
            return nil
        }
        return try outcome.get()
    }

    /// Starts playback of one podcast episode. Deliberately narrower than
    /// `startPlayback(for:)` — episodes aren't downloadable in this initial pass (see
    /// `CHANGES_IMPLEMENTED.md`'s podcast-support entry for the honest scope note), so
    /// there's no offline-session fallback or download-aware cellular check to make.
    func startEpisodePlayback(for item: LibraryItem, episode: PodcastEpisode, openPlayer: Bool = true) async {
        errorMessage = nil

        if !SettingsStore.allowCellularStreaming, NetworkMonitor.shared.isConnected, !NetworkMonitor.shared.isOnWiFi {
            errorMessage = String(localized: "Streaming on cellular is off. Connect to Wi-Fi to listen.", comment: "Error when streaming a podcast episode over cellular is disabled in settings")
            return
        }
        if !NetworkMonitor.shared.isConnected {
            errorMessage = String(localized: "You're offline. Podcast episodes can't be downloaded yet, so this needs a connection.", comment: "Error when starting a podcast episode while offline")
            return
        }

        // LS-2: single-flight guard, and publish `pendingBook` before any network await —
        // see `startPlayback`'s equivalent guard above.
        guard beginLoading(for: item) else { return }
        defer { endLoading() }
        startFailureMessage = nil
        lastFailedStart = nil

        // Starting an episode abandons whatever book was warmed for Up Next.
        resolvePrefetchedSession(for: .discarded)
        await AudiobookshelfAPI.shared.ensureFreshAccessToken()

        do {
            let session = try await AudiobookshelfAPI.shared.startPlaybackSession(itemId: item.id, episodeId: episode.id)
            guard playerService.startPlayback(session: session, startTime: session.currentTime ?? 0) else {
                Self.closeOrphanedSession(session)
                throw URLError(.badServerResponse)
            }
            currentBook = item
            currentEpisode = episode
            playerService.setPlaybackRate(Float(SettingsStore.resolvedSpeed(forItem: item.id)))
            if openPlayer { showFullPlayer = true }
        } catch {
            ShelfLog.error(.playback, "Start episode failed: \(error)")
            lastFailedStart = (item, episode)
            startFailureMessage = Self.playbackStartFailureMessage(for: error, isEpisode: true)
        }
    }

    /// LS-2: single-flight guard shared by `startPlayback` and `startEpisodePlayback` —
    /// returns `false` (doing nothing) if a start is already in flight, so a double-tap
    /// can't begin a second session. Otherwise publishes `pendingBook`/`isLoadingSession`
    /// synchronously, before any network `await`, so the mini player can show the tapped
    /// book immediately.
    private func beginLoading(for item: LibraryItem) -> Bool {
        guard !isLoadingSession else { return false }
        isLoadingSession = true
        pendingBook = item
        return true
    }

    /// LS-2: clears the state `beginLoading(for:)` (or, for `togglePlayPause()`'s resume
    /// branch, the caller directly) published — called on every exit path of a start,
    /// success or failure, so the mini player reverts to the previous book (or
    /// disappears) once the attempt is over.
    private func endLoading() {
        isLoadingSession = false
        pendingBook = nil
    }

    /// Apply the remembered speed for this book (falling back to the global default).
    private func applyDefaultSpeed() {
        guard let id = currentBook?.id else { return }
        var speed = SettingsStore.resolvedSpeed(forItem: id)
        // Batch 437: in WPM mode the target, not the remembered multiplier, decides the rate
        // when the book's transcript is long enough to measure the narrator's pace.
        if SettingsStore.speedModeIsWPM, let pace = narratorPace(forItem: id) {
            speed = NarratorPace.rate(targetWPM: Double(SettingsStore.targetWPM), paceWPM: pace)
            // Batch 456: during SharePlay the group sets the rate; don't remember it as this book's.
            if !playerService.isCoordinatingPlayback { SettingsStore.setSpeed(speed, forItem: id) }
        }
        playerService.setPlaybackRate(Float(speed))
    }

    // MARK: - Narrator pace (Batch 437)

    @ObservationIgnored private var narratorPaceCache: [String: Double] = [:]

    /// Words per minute the narrator reads at, measured from the cached transcript, or nil
    /// when there is no transcript or under 5 minutes of speech. Only successes are cached,
    /// so a transcript that is still growing is re-read next time.
    func narratorPace(forItem itemId: String) -> Double? {
        if let cached = narratorPaceCache[itemId] { return cached }
        guard let transcript = TranscriptStore.load(itemId: itemId),
              let pace = NarratorPace.wordsPerMinute(segments: transcript.segments) else { return nil }
        narratorPaceCache[itemId] = pace
        return pace
    }

    /// Pace of the book that is playing now.
    var currentNarratorPace: Double? {
        guard let id = currentBook?.id else { return nil }
        return narratorPace(forItem: id)
    }

    func togglePlayPause() {
        // If this is a book restored on launch (no live session yet), load + resume it.
        if isAwaitingResume, let book = currentBook {
            // LS-2: publish pendingBook/isLoadingSession synchronously, before the Task
            // is created, so a second rapid tap here can't also pass `beginLoading`'s
            // guard before this first call gets scheduled — `startPlayback` is then told
            // (`alreadyBegun: true`) not to re-run that guard itself.
            guard beginLoading(for: book) else { return }
            Task { await startPlayback(for: book, prefetched: nil, openPlayer: true, alreadyBegun: true) }
            return
        }
        // LS-2: while a start is in flight, ignore the tap rather than starting a second
        // session or toggling a stale/absent player — the button stays visually tappable.
        if isLoadingSession { return }
        playerService.togglePlayPause()
    }

    func skipForward() {
        playerService.skipForward()
    }

    func skipBackward() {
        playerService.skipBackward()
    }

    // MARK: - Jump back (undo an accidental scrub)

    /// The position to return to after a large seek; drives a transient "Jump back" pill.
    ///
    /// HIG audit 2026-09-17 M2: this used to auto-dismiss on a fixed 6-second timer
    /// (`seekUndoTask`, now removed). Apple's Accessibility (Cognitive) guidance asks to
    /// "minimize use of time-boxed interface elements" and "prefer dismissing views with
    /// an explicit action" — someone who needs longer to notice or reach the chip
    /// (including anyone driving VoiceOver or Switch Control through the rest of the
    /// screen) could lose the offer before acting on it. The chip now only clears on an
    /// explicit action or an equally explicit state change: tapping it (`undoSeek()`), a
    /// new seek (below — even a small one replaces/clears the previous offer rather than
    /// leaving a stale one on screen), a track/book change or `stop()` (both via
    /// `currentBook`'s `didSet`), or the full player closing (`showFullPlayer`'s `didSet`).
    var seekUndoTime: Double? = nil
    /// What made the jump `seekUndoTime` would undo — only changes the chip's VoiceOver
    /// hint, so the visible "Jump back to 41:12" stays one short, stable label.
    private(set) var seekUndoReason: SeekUndoReason = .scrub

    enum SeekUndoReason {
        case scrub, chapterSkip, chapterPick, bookmark
        /// Batch 424: a jump to a transcript search result (in-app or Siri).
        case search
        /// Batch 425: a tap on a caption line.
        case caption
        /// Batch 426: previewing a quote clip from the clip editor.
        case clip
        /// Batch 427: "play from here" on a suggested chapter in the chapter reviewer.
        case chapterReview
        /// Batch 428: "Rewind" on the I Zoned Out sheet, back to the start of the passage it summarised.
        case zonedOut
        /// Batch 429: a tap on "First mentioned at" in the X-Ray sheet.
        case xray
        /// Batch 429: a tap on a citation chip under an Ask the Book answer.
        case ask
        /// Batch 431: Listen from Here in the ebook reader.
        case readAlong
        /// The offer that follows tapping "Jump back" itself: a way forward again, so a
        /// mis-tapped Jump back is as recoverable as the jump it undid (critique
        /// 2026-10-05, third run).
        case undo
        /// Batch 490 (REVIEW 2026-11-11 F20): offered on resuming a book a sleep timer
        /// stopped, back to where the timer was set.
        case sleepTimer

        var accessibilityHint: String {
            switch self {
            case .scrub:       return String(localized: "Returns to where you were before the last skip", comment: "VoiceOver hint on the Jump back chip after a scrub or skip")
            case .chapterSkip: return String(localized: "Returns to where you were before the chapter skip", comment: "VoiceOver hint on the Jump back chip after a chapter skip")
            case .chapterPick: return String(localized: "Returns to where you were before you picked a chapter", comment: "VoiceOver hint on the Jump back chip after choosing a chapter")
            case .bookmark:    return String(localized: "Returns to where you were before you opened the bookmark", comment: "VoiceOver hint on the Jump back chip after opening a bookmark")
            case .search:      return String(localized: "Returns to where you were before you jumped to the search result", comment: "VoiceOver hint on the Jump back chip after choosing a transcript search result")
            case .caption:     return String(localized: "Returns to where you were before you tapped the caption", comment: "VoiceOver hint on the Jump back chip after tapping a caption line to play from it")
            case .clip:        return String(localized: "Returns to where you were before you previewed the clip", comment: "VoiceOver hint on the Jump back chip after previewing a quote clip")
            case .chapterReview: return String(localized: "Returns to where you were before you played a suggested chapter", comment: "VoiceOver hint on the Jump back chip after playing a suggested chapter from the chapter reviewer")
            case .zonedOut:    return String(localized: "Returns to where you were before you rewound to the passage", comment: "VoiceOver hint on the Jump back chip after rewinding from the I Zoned Out sheet")
            case .xray:        return String(localized: "Returns to where you were before you jumped to where this was first mentioned", comment: "VoiceOver hint on the Jump back chip after jumping to a first mention from the X-Ray sheet")
            case .ask:         return String(localized: "Returns to where you were before you jumped to the passage that answered your question", comment: "VoiceOver hint on the Jump back chip after tapping a citation under an Ask the Book answer")
            case .readAlong:   return String(localized: "Returns to where you were before you listened from a spot in the ebook", comment: "VoiceOver hint on the Jump back chip after Listen from Here in the ebook reader")
            case .undo:        return String(localized: "Goes forward again to where you jumped back from", comment: "VoiceOver hint on the chip that undoes a Jump back")
            case .sleepTimer:  return String(localized: "Returns to where you were when you set the sleep timer", comment: "VoiceOver hint on the Jump back chip offered after a sleep timer stopped playback")
            }
        }

    }

    /// Where the offered jump landed, so the offer can retire once it's stale.
    private(set) var seekUndoTarget: Double?

    /// Whether the "Jump back" offer still makes sense (critique 2026-10-05, third run). It
    /// used to stay up until the player closed, so an hour after a ⏭ it could still offer
    /// to rewind to "chapter 5", right above the transport row. It now retires once the
    /// listener has played on 2 minutes past where the jump landed, or the chapter changes
    /// on its own. That's measured in listening, not on a clock, so HIG audit M2's "no
    /// time-boxed offers" still holds: pausing never makes it disappear. Pure; pinned by
    /// `JumpBackOfferTests`.
    ///
    /// Fourth run: only a *forward* chapter change retires it — playing on into the next
    /// chapter. Skipping back past a chapter start while correcting an overshoot keeps the
    /// offer, because that's exactly when it's wanted.
    nonisolated static func seekUndoStillOffered(target: Double, currentTime: Double,
                                                 targetChapterId: Int?, currentChapterId: Int?) -> Bool {
        if let targetChapterId, let currentChapterId, targetChapterId != currentChapterId,
           currentTime > target { return false }
        return currentTime - target < 120
    }

    /// Retires a stale offer for good. `activeSeekUndoTime` alone recomputed staleness on
    /// every read and never cleared it, so after it had retired, one ⟲15 (which doesn't go
    /// through `seek(to:)`) brought it back (critique 2026-10-05, fourth run). Called by the
    /// status row when `isSeekUndoStale` turns true.
    func retireStaleSeekUndo() {
        guard isSeekUndoStale else { return }
        seekUndoTime = nil
        seekUndoTarget = nil
    }

    var isSeekUndoStale: Bool { seekUndoTime != nil && activeSeekUndoTime == nil }

    /// Whether taking the offer moves later in the book — the chip then says "Go forward to"
    /// with ↷ instead of "Jump back to" with ↶. Wording follows direction, not what caused
    /// the jump: after ⏮ the undo moves *forward* (user decision, fourth run).
    nonisolated static func seekUndoGoesForward(undoTime: Double, currentTime: Double) -> Bool {
        undoTime > currentTime
    }

    /// The chapter the jump landed in (for `seekUndoStillOffered`).
    private(set) var seekUndoTargetChapterId: Int?

    /// `seekUndoTime` while the offer is still current, else `nil`. Read by the chip view
    /// only (it ticks with `currentTime`), never by `PlayerView.body` (Item 13).
    var activeSeekUndoTime: Double? {
        guard let undo = seekUndoTime, let target = seekUndoTarget else { return seekUndoTime }
        return Self.seekUndoStillOffered(target: target, currentTime: currentTime,
                                         targetChapterId: seekUndoTargetChapterId,
                                         currentChapterId: currentChapter?.id) ? undo : nil
    }

    /// The transport has been waiting for 10 s (WAITING FOR SERVER) / for 2 s (Driving
    /// Mode's "Loading"). One clock, here (critique 2026-10-05, fourth run): it used to be a
    /// view task in the header plus a second one in Driving Mode — two sources of truth for
    /// one state, and business logic in views. `ContentView` (always mounted) reports
    /// `isTransportWaiting` changes via `transportWaitingChanged(_:)`.
    private(set) var transportStalled = false
    private(set) var transportWaitingLong = false
    @ObservationIgnored private var stallTask: Task<Void, Never>?

    func transportWaitingChanged(_ waiting: Bool) {
        stallTask?.cancel()
        transportStalled = false
        transportWaitingLong = false
        guard waiting else { return }
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.transportWaitingLong = true
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.transportStalled = true
        }
    }

    /// True while Driving Mode is on screen. Its full-screen cover hides the root alert, so
    /// the alert binding stands down and Driving Mode shows the failure itself.
    var isDrivingModePresented = false

    /// Batch 490 (REVIEW 2026-11-11): a request from outside the player (a deep link,
    /// shortcut or CarPlay hand-off) to open Driving Mode. `PlayerView` opens it through
    /// `openDrivingMode()` while it's on screen — including when this was already true as
    /// the player appeared — and sets it back to false.
    var pendingDrivingModeRequest = false

    /// Batch 490 (REVIEW 2026-11-11 P2): Driving Mode keeps the screen on while it's up.
    /// `AudioPlayerService` stays the one writer of `isIdleTimerDisabled`.
    func drivingModeVisibilityChanged(_ visible: Bool) {
        isDrivingModePresented = visible
        playerService.setDrivingModeHoldsScreenAwake(visible)
    }

    /// Whether a seek from `from` to `to` is large enough to offer "Jump back". Pure so the
    /// threshold is pinned by `SeekUndoPolicyTests` rather than by a screenshot.
    nonisolated static func offersSeekUndo(from: Double, to: Double) -> Bool {
        abs(to - from) >= 15
    }

    /// The one seek path for every jump the player screen can make — the scrubber, the
    /// chapter buttons, a chapter-list row, a bookmark row. Critique 2026-10-05 P1: only the
    /// scrubber used to come through here; ⏮/⏭ and the two sheets called the service
    /// directly, so the largest and likeliest accidental jumps (a chapter restart, a run to
    /// the end of the book from the last chapter, a mis-tapped row) were the ones with no
    /// undo. Any seek — big or small — replaces whatever the previous offer was, so the chip
    /// never lingers pointing at a jump that's no longer the most recent one.
    func seek(to time: Double, reason: SeekUndoReason = .scrub) {
        // A run of scrubs (each VoiceOver swipe on the scrubber is its own seek) keeps the
        // position from before the run started, so "Jump back" undoes the whole adjustment
        // rather than only the last swipe (critique 2026-10-05, fourth run).
        let from = (reason == .scrub && seekUndoReason == .scrub ? activeSeekUndoTime : nil) ?? currentTime  // Review 5 Low (jump back anchor): stale offer must not anchor a run
        if reason == .clip { playerService.clearPausedAtForClipSeek() }   // Review 7 Low (clip smart rewind)
        playerService.seek(to: time)
        if Self.offersSeekUndo(from: from, to: time), playerService.currentSession != nil {
            seekUndoTime = from
            seekUndoReason = reason
            seekUndoTarget = time
            seekUndoTargetChapterId = chapters.last(where: { $0.start <= time })?.id
        } else {
            seekUndoTime = nil
            seekUndoTarget = nil
        }
    }

    /// Return to the pre-seek position and dismiss the pill.
    func undoSeek() {
        guard let t = seekUndoTime else { return }
        // Through `seek(to:reason:)` so undoing offers the way forward again (`.undo`).
        seek(to: t, reason: .undo)
        Haptics.selection()
    }

    func seekToChapter(_ chapter: Chapter) {
        seek(to: chapter.start, reason: .chapterPick)
    }

    // MARK: - Bookmarks

    var bookmarks: [AudioBookmark] = []
    /// LS-9 (docs/design-review.md): true for the duration of a `loadBookmarks()` fetch,
    /// so the sheet can tell "still loading" apart from "genuinely no bookmarks" instead
    /// of reading an empty `bookmarks` array as a confirmed empty state.
    private(set) var isLoadingBookmarks = false
    /// Polish pass (CR-2): true when the last `loadBookmarks()` threw (offline / unreachable
    /// with nothing queued). The list keeps what it had, and the sheet says so with a Retry
    /// instead of reading the gap as "No bookmarks".
    private(set) var bookmarksLoadFailed = false

    /// LS-9: bumped on every `loadBookmarks()` call and captured before the `await`, so
    /// an older, slower call landing after a newer one can't overwrite the newer result
    /// or flip `isLoadingBookmarks` false while the newer call is still in flight — a
    /// plain `defer { isLoadingBookmarks = false }` would do exactly that on overlap.
    private var bookmarksLoadGeneration = 0

    func loadBookmarks() async {
        guard let id = currentBook?.id else {
            bookmarks = []
            bookmarksLoadFailed = false
            isLoadingBookmarks = false
            return
        }
        bookmarksLoadGeneration += 1
        let generation = bookmarksLoadGeneration
        isLoadingBookmarks = true
        defer { if generation == bookmarksLoadGeneration { isLoadingBookmarks = false } }
        let fetched: [AudioBookmark]?
        do {
            fetched = try await AudiobookshelfAPI.shared.getBookmarks(itemId: id)
        } catch {
            ShelfLog.error(.playback, "Bookmarks load failed: \(error)")
            fetched = nil
        }
        // Stale guard: only apply this result if it's still the latest call for the book
        // that's still current — a book switch mid-fetch must not overwrite the new
        // book's list with the old book's (now-arrived) response.
        guard generation == bookmarksLoadGeneration, currentBook?.id == id else { return }
        // Polish pass (CR-2): a failed fetch must not wipe the list already on screen.
        if let fetched {
            bookmarks = fetched
            bookmarksLoadFailed = false
        } else {
            bookmarksLoadFailed = true
        }
    }

    /// Bookmark a specific moment. An optional `note` becomes the bookmark title;
    /// otherwise we fall back to the chapter title (or the timestamp).
    ///
    /// Routed through `BookmarkSyncService`, so a bookmark made offline is queued rather
    /// than dropped — and `loadBookmarks()` below shows it immediately either way, since
    /// the read path folds the queue in.
    ///
    /// S3 (REVIEW_2026-09-04_UI.md): split out of `addBookmarkAtCurrentTime` so a caller
    /// (the bookmarks sheet) can capture `time` when the user taps "Bookmark this
    /// moment" rather than at Save time — otherwise a slow typist ends up bookmarking
    /// wherever playback drifted to while the note prompt was open.
    enum BookmarkSaveResult { case synced, queued }

    /// `nil` when there's no book to bookmark, so callers don't confirm a save that didn't
    /// happen (critique 2026-10-05, second run: the quick bookmark used to buzz and say
    /// "Bookmarked" regardless).
    @discardableResult
    func addBookmark(at time: Double, note: String? = nil) async -> BookmarkSaveResult? {
        guard let id = currentBook?.id else { return nil }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Batch 490 (REVIEW 2026-11-11 V8): no note → "‹chapter› · ‹time›", shared with
        // the lock screen and CarPlay. The chapter is the one at `time` (captured when the
        // note prompt opened), not wherever playback has drifted to since.
        let chapterAtTime = chapters.last(where: { $0.start <= time })?.title ?? currentChapter?.title
        let title = (trimmed?.isEmpty == false ? trimmed! : nil)
            ?? BookmarkDefaultTitle.make(chapterTitle: chapterAtTime, time: time)
        let synced = await BookmarkSyncService.shared.create(itemId: id, time: time, title: title)
        if !synced { infoMessage = String(localized: "Bookmark saved — will sync when you're back online", comment: "Toast when a bookmark is queued offline") }
        await loadBookmarks()
        return Self.bookmarkSaveResult(synced: synced)
    }

    /// Convenience wrapper kept for callers (e.g. `WatchSessionManager`) that bookmark
    /// "now" rather than a previously captured time.
    @discardableResult
    func addBookmarkAtCurrentTime(note: String? = nil) async -> BookmarkSaveResult? {
        await addBookmark(at: currentTime, note: note)
    }

    // Critique 2026-10-06 (polish): `deleteBookmark(_:)` lived here. Every surface now
    // deletes through the shared `BookmarkDeleteUndo` (Extensions.swift), so it had no
    // callers left.

    /// Edit an existing bookmark's note.
    ///
    /// Critique 2026-10-06 (harden): returns what happened, as `addBookmark` does, so the
    /// Edit Bookmark sheet closes and buzzes only after a real save. `.synced` / `.queued`
    /// (offline: `BookmarkSyncService` holds it and replays it), `nil` when there's nothing
    /// to save it against (no item, or no signed-in server, so a queued edit could never
    /// replay). Was `Void`, and the sheet closed before the save and always said success.
    @discardableResult
    func updateBookmark(_ bookmark: AudioBookmark, note: String) async -> BookmarkSaveResult? {
        guard Self.canSaveBookmarkEdit(itemId: bookmark.libraryItemId,
                                       serverURL: AuthStore.shared.serverURL) else { return nil }
        let synced = await BookmarkSyncService.shared.update(
            itemId: bookmark.libraryItemId,
            time: bookmark.time,
            title: Self.editedBookmarkTitle(note: note, time: bookmark.time))
        if !synced { infoMessage = String(localized: "Note saved — will sync when you're back online", comment: "Toast when a bookmark note edit is queued offline") }
        await loadBookmarks()
        return Self.bookmarkSaveResult(synced: synced)
    }

    /// An edit needs an item and a signed-in server (the offline queue is scoped to it).
    /// Pure, pinned by `BookmarkUndoTests`.
    nonisolated static func canSaveBookmarkEdit(itemId: String, serverURL: String) -> Bool {
        !itemId.trimmingCharacters(in: .whitespaces).isEmpty
            && !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `BookmarkSyncService`'s Bool (true = the server took it) as a save result.
    nonisolated static func bookmarkSaveResult(synced: Bool) -> BookmarkSaveResult {
        synced ? .synced : .queued
    }

    /// A blank title falls back to the timestamp, as a new bookmark's does.
    nonisolated static func editedBookmarkTitle(note: String, time: Double) -> String {
        let title = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? time.formattedTime : title
    }

    func seekToBookmark(_ bookmark: AudioBookmark) {
        seek(to: bookmark.time, reason: .bookmark)
    }

    /// Whether the chapter buttons and the Chapters tool have anything to act on. The
    /// transport disables them rather than letting ⏮/⏭ quietly fall back to the skip
    /// intervals (which ⟲/⟳ already sit beside) while VoiceOver still says "chapter".
    var hasChapterList: Bool { !chapters.isEmpty }

    /// Review Medium 14, 30 October 2026: whether a chapter starts after `currentTime`. On
    /// the last chapter "next chapter" used to seek to the end of the book, which can mark
    /// it finished and start the next Up Next book. Pure, pinned by `NextChapterGuardTests`.
    nonisolated static func hasNextChapter(chapters: [Chapter], currentTime: Double) -> Bool {
        chapters.contains { $0.start > currentTime + 0.5 }
    }

    /// False on the last chapter, so the transport can disable ⏭ there. True when there is
    /// no chapter list (the button then falls back to the forward skip interval).
    var canSkipToNextChapter: Bool {
        let chapters = playerService.currentSession?.chapters ?? []
        guard !chapters.isEmpty else { return true }
        return Self.hasNextChapter(chapters: chapters, currentTime: currentTime)
    }

    func nextChapter() {
        let chapters = playerService.currentSession?.chapters ?? []
        guard !chapters.isEmpty else { playerService.skipToNextChapter(); return }
        guard Self.hasNextChapter(chapters: chapters, currentTime: currentTime),
              let target = AudioPlayerService.nextChapterTarget(
            chapters: chapters, currentTime: currentTime, duration: playerService.duration
        ) else { return }
        seek(to: target, reason: .chapterSkip)
    }

    func previousChapter() {
        let chapters = playerService.currentSession?.chapters ?? []
        guard !chapters.isEmpty else { playerService.skipToPreviousChapter(); return }
        seek(to: AudioPlayerService.previousChapterTarget(chapters: chapters, currentTime: currentTime),
             reason: .chapterSkip)
    }

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        setPlaybackRate(speed.rawValue)
    }

    /// Set an arbitrary playback rate (0.5×–3.0×) and remember it for this book.
    func setPlaybackRate(_ rate: Double) {
        let clamped = min(max(rate, 0.5), 3.0)
        // Round to the nearest 0.05 so the fine stepper doesn't accumulate drift.
        let stepped = (clamped * 20).rounded() / 20
        playerService.setPlaybackRate(Float(stepped))
        if let id = currentBook?.id, !playerService.isCoordinatingPlayback {
            SettingsStore.setSpeed(stepped, forItem: id)
        }
    }

    /// Polish pass (J3-12): true while a SharePlay session drives playback. The group sets the
    /// rate on purpose, so `setPlaybackRate` does not save it as this book's speed; the speed
    /// sheet reads this to say so rather than promise "remembered next time".
    var isListeningTogether: Bool { playerService.isCoordinatingPlayback }

    /// Nudge the current rate by `delta` (used by the −/+ stepper).
    func nudgeSpeed(by delta: Double) {
        setPlaybackRate(Double(playbackRate) + delta)
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepUndo = nil
        ListeningProfileManager.shared.profileSleepTimerReplaced()
        playerService.setSleepTimer(option)
    }

    // MARK: - Sleep timer "Undo" (critique 2026-10-05)

    /// The timer the chip's ✕ just turned off, so the player can offer it back. The worst
    /// outcome for someone dozing off is waking to silence at an unknown point because a
    /// half-asleep tap hit ✕ instead of +15m. Same dismissal contract as `seekUndoTime`
    /// (HIG audit M2: no time-boxed offers): cleared by tapping Undo, setting any timer, a
    /// book change, or the full player closing.
    private(set) var sleepUndo: SleepUndo?

    struct SleepUndo: Equatable {
        let option: SleepTimerOption
        let remaining: TimeInterval
    }

    /// The chip's ✕. Cancels the timer and keeps what it was for `undoSleepTimerOff()`.
    func turnOffSleepTimer() {
        let option = sleepTimerOption
        guard option != .off else { return }
        let undo = SleepUndo(option: option, remaining: sleepTimerRemaining)
        ListeningProfileManager.shared.profileSleepTimerReplaced()
        playerService.setSleepTimer(.off)
        sleepUndo = undo
    }

    func undoSleepTimerOff() {
        guard let undo = sleepUndo else { return }
        sleepUndo = nil
        playerService.restoreSleepTimer(undo.option, remaining: undo.remaining)
        Haptics.selection()
    }

    /// Add time to a running countdown sleep timer (e.g. "+15m").
    func extendSleepTimer(by seconds: TimeInterval) {
        playerService.extendSleepTimer(by: seconds)
    }

    /// Batch 490 (REVIEW 2026-11-11 F20): "+1 chapter" for an end-of-chapter / +N
    /// chapters timer.
    func extendSleepTimerByOneChapter() {
        playerService.extendSleepTimerByOneChapter()
    }

    /// Whether a sleep timer is currently armed.
    var isSleepTimerActive: Bool { sleepTimerOption != .off }

    /// Re-arm the active sleep timer from now (used by shake-to-reset).
    func resetSleepTimer() {
        playerService.resetSleepTimer()
    }

    /// "Skip tonight" for the scheduled (time-of-day) sleep timer — see
    /// `AudioPlayerService.skipScheduledSleepTimerTonight`.
    func skipScheduledSleepTimerTonight() {
        playerService.skipScheduledSleepTimerTonight()
    }

    func stop() {
        playerService.stop()
        // Item 3: a session warmed by `onNearEnd` for the next queued book is not the
        // live session, so `playerService.stop()` knows nothing about it. Stopping is the
        // single most likely way to strand one (the near-end warm-up has usually already
        // run by the time the user dismisses the player).
        prefetchTask?.cancel()
        resolvePrefetchedSession(for: .discarded)
        currentBook = nil
        showFullPlayer = false
    }

    // MARK: - Stop with undo (mini player)

    /// What `undoStop()` needs to put the bar back as it was.
    struct StopUndoSnapshot: Equatable {
        let book: LibraryItem
        let currentTime: Double
        let duration: Double
        // Critique 2026-10-05 (Mini player, 2nd): undo restores what was running, not just
        // the book — whether it was playing and which sleep timer was armed.
        var wasPlaying: Bool = false
        var sleepOption: SleepTimerOption = .off
        var sleepRemaining: TimeInterval = 0
        static func == (l: Self, r: Self) -> Bool { l.book.id == r.book.id && l.currentTime == r.currentTime }
    }

    /// Critique 2026-10-05 (Mini player, 2nd): the pure snapshot -> restore decision,
    /// pinned by `MiniPlayerStateTests`. A sleep timer is only re-armed when playback
    /// resumes (its chapter/book targets need a live session to resolve against), and a
    /// timer that was `.off` is never "restored".
    struct StopUndoPlan: Equatable {
        let resume: Bool
        let rearmSleep: Bool
        let sleepOption: SleepTimerOption
        let sleepRemaining: TimeInterval
    }

    nonisolated static func stopUndoPlan(wasPlaying: Bool, sleepOption: SleepTimerOption,
                                         sleepRemaining: TimeInterval) -> StopUndoPlan {
        StopUndoPlan(resume: wasPlaying,
                     rearmSleep: wasPlaying && sleepOption != .off,
                     sleepOption: sleepOption, sleepRemaining: sleepRemaining)
    }

    /// Critique 2026-10-05 (Mini player): swipe-down and the VoiceOver "Stop Playback"
    /// action ended the session with no way back. Set by `stopWithUndo()`, cleared when
    /// another book appears or the undo is used. (Critique 2026-10-06: swipe-down no longer
    /// stops; Stop is in the mini player's long-press menu and the VoiceOver action.)
    private(set) var stopUndo: StopUndoSnapshot?
    /// Text for the undo toast (bound by `ContentView`); the toast clears it when it times out.
    var stopUndoMessage: String?

    /// Stops playback like `stop()`, remembering the book and position so `undoStop()` can
    /// restore it paused. `stop()` has already synced progress to the server by then.
    func stopWithUndo() {
        guard let book = currentBook else { stop(); return }
        let snapshot = StopUndoSnapshot(book: book, currentTime: currentTime, duration: duration,
                                        wasPlaying: isPlaying, sleepOption: sleepTimerOption,
                                        sleepRemaining: sleepTimerRemaining)
        stop()
        stopUndo = snapshot
        stopUndoMessage = String(localized: "Stopped \(book.title)", comment: "Toast with Undo after playback is stopped. %@ is the book title")
    }

    /// Restores the book from `stopWithUndo()` into the paused restored-but-not-loaded
    /// state the app already uses after a relaunch (press play to resume at that spot).
    /// Critique 2026-10-06 (polish): an account switch retires every player Undo offer, as
    /// `LibraryViewModel.resetForAccountChange()` does for progress. Clearing the player
    /// already retires the replace offer (`currentBook` didSet), but a pending "Stopped …
    /// Undo" or "Removed … from Up Next" would otherwise put the previous server's book back
    /// on the new one.
    func retireUndoOffersForAccountChange() {
        stopUndo = nil
        stopUndoMessage = nil
        replaceUndo = nil
        replaceUndoMessage = nil
        queueRemovalUndo = nil
        queueRemovalUndoMessage = nil
    }

    func undoStop() {
        guard let snap = stopUndo else { return }
        stopUndo = nil
        stopUndoMessage = nil
        restore(snap)
    }

    /// Shared by `undoStop()` and `undoReplace()`: the restored-but-not-loaded state the app
    /// uses after a relaunch, resumed the normal way if it was playing.
    private func restore(_ snap: StopUndoSnapshot) {
        guard currentBook == nil, pendingBook == nil, playerService.currentSession == nil else { return }
        restoredCurrentTime = snap.currentTime
        restoredDuration = snap.duration
        currentBook = snap.book
        // Critique 2026-10-05 (Mini player, 2nd): if it was playing, resume it the normal way
        // (no full-player pop-open), then re-arm the sleep timer against the live session.
        let plan = Self.stopUndoPlan(wasPlaying: snap.wasPlaying, sleepOption: snap.sleepOption,
                                     sleepRemaining: snap.sleepRemaining)
        if plan.resume {
            let book = snap.book
            Task {
                await startPlayback(for: book, openPlayer: false)
                guard plan.rearmSleep, currentBook?.id == book.id else { return }
                playerService.restoreSleepTimer(plan.sleepOption, remaining: plan.sleepRemaining)
            }
        }
    }

    // MARK: - Replace with undo (Critique 2026-10-06, harden)

    /// The episode a `startEpisodePlayback` call loaded, so a replace-undo can put the same
    /// episode back. `PlaybackSession` carries no episode id, so this is nil after a relaunch
    /// restore; cleared whenever the loaded item changes.
    private(set) var currentEpisode: PodcastEpisode?

    /// What `undoReplace()` needs to put the previous book (or episode) back.
    struct ReplaceUndoSnapshot: Equatable {
        let previous: StopUndoSnapshot
        let previousEpisode: PodcastEpisode?
        /// The item that replaced it; the offer only stands while that item is loaded.
        let replacementId: String
        static func == (l: Self, r: Self) -> Bool {
            l.previous == r.previous && l.previousEpisode?.id == r.previousEpisode?.id
                && l.replacementId == r.replacementId
        }
    }

    /// Critique 2026-10-06 (harden): B-side, Book Detail's Play Instead and podcast episode
    /// rows replaced the loaded book with no way back. Set after such a start succeeds.
    private(set) var replaceUndo: ReplaceUndoSnapshot?
    /// Text for the undo toast (bound by `ContentView`); the toast clears it when it times out.
    var replaceUndoMessage: String?

    /// Whether starting `newId`/`newEpisodeId` replaces something that Undo could put back.
    /// Nothing loaded, or the same book (or episode) again, is not a replacement. A podcast
    /// whose loaded episode is unknown (restored after a relaunch) can't be put back exactly,
    /// so it gets no offer rather than a wrong one.
    nonisolated static func offersReplaceUndo(currentId: String?, currentIsPodcast: Bool,
                                              currentEpisodeId: String?, newId: String,
                                              newEpisodeId: String?) -> Bool {
        guard let currentId else { return false }
        if currentIsPodcast && currentEpisodeId == nil { return false }
        return currentId != newId || currentEpisodeId != newEpisodeId
    }

    /// "Playing instead of <previous>", the toast that carries Undo.
    nonisolated static func replaceUndoMessage(previousTitle: String) -> String {
        String(localized: "Playing instead of \(previousTitle)", comment: "Toast with Undo after a new book replaces the current one. %@ is the previous book title")
    }

    /// "Plays instead of <title>": the visible note on a control that will replace the loaded
    /// book (B-side on Home and Library). Nil when nothing is loaded or it is the same book.
    nonisolated static func playsInsteadSubtitle(loadedTitle: String?) -> String? {
        guard let t = loadedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(localized: "Plays instead of \(t)", comment: "Subtitle on a B-side control that would replace the loaded book. %@ is the loaded book title")
    }

    /// Starts `item` (or one of its episodes) like `startPlayback`/`startEpisodePlayback`, and,
    /// when that replaced another loaded book, offers a 6 s "Playing instead of … Undo" toast
    /// that puts the previous book back at its position (`undoReplace()`).
    func startPlaybackOfferingUndo(for item: LibraryItem, episode: PodcastEpisode? = nil,
                                   openPlayer: Bool = true) async {
        var snapshot: ReplaceUndoSnapshot?
        if let book = currentBook, pendingBook == nil,
           Self.offersReplaceUndo(currentId: book.id, currentIsPodcast: book.isPodcast,
                                  currentEpisodeId: currentEpisode?.id, newId: item.id,
                                  newEpisodeId: episode?.id) {
            snapshot = ReplaceUndoSnapshot(
                previous: StopUndoSnapshot(book: book, currentTime: currentTime, duration: duration,
                                           wasPlaying: isPlaying, sleepOption: sleepTimerOption,
                                           sleepRemaining: sleepTimerRemaining),
                previousEpisode: currentEpisode,
                replacementId: item.id)
        }
        if let episode {
            await startEpisodePlayback(for: item, episode: episode, openPlayer: openPlayer)
        } else {
            await startPlayback(for: item, openPlayer: openPlayer)
        }
        // Only a start that really loaded the new item replaced anything; a refused or failed
        // start leaves the previous book where it was.
        guard let snapshot, currentBook?.id == item.id, !isAwaitingResume,
              episode == nil || currentEpisode?.id == episode?.id else { return }
        replaceUndo = snapshot
        replaceUndoMessage = Self.replaceUndoMessage(previousTitle: snapshot.previous.book.title)
    }

    /// Puts the replaced book back: stops the replacement (which saves its position), then
    /// restores the previous book the way `undoStop()` does — paused at its spot, or resumed
    /// if it was playing. A replaced episode is started again and moved to its position.
    func undoReplace() {
        guard let undo = replaceUndo else { return }
        replaceUndo = nil
        replaceUndoMessage = nil
        guard currentBook?.id == undo.replacementId, pendingBook == nil else { return }
        stop()
        // `stop()` cleared `currentBook`, which retires any stop-undo; nothing else to clear.
        let snap = undo.previous
        if let episode = undo.previousEpisode {
            Task {
                await startEpisodePlayback(for: snap.book, episode: episode, openPlayer: false)
                guard currentBook?.id == snap.book.id, currentEpisode?.id == episode.id else { return }
                // Straight to the service: putting a book back isn't a jump to offer "Jump
                // back" for.
                playerService.seek(to: snap.currentTime)
                if !snap.wasPlaying, isPlaying { togglePlayPause() }
            }
        } else {
            restore(snap)
        }
    }
}

/// Critique 2026-10-06 (distill, user decision): while Book Detail's pinned Play / Resume /
/// Play This Book Instead bar is showing, the mini player is hidden so the screen has one
/// play control. Each visible Book Detail registers under its own owner id with the tab it
/// lives in; the mini player is suppressed while any registration belongs to the selected
/// tab. Keyed per owner (a set, not a count), so nested details (series → book → book) and
/// an interrupted back-swipe can't unbalance it, and a release carries the token of the
/// registration it ends, so a late release from an earlier appearance can't cancel a newer
/// one (Book Detail defers its release by a run-loop turn to avoid a show/hide flicker
/// between two details).
struct MiniPlayerSuppression: Equatable {
    struct Registration: Equatable {
        /// The tab whose navigation stack holds the screen; nil when unknown, which
        /// suppresses in every tab.
        var tab: Int?
        var token: UUID
    }

    private(set) var registrations: [UUID: Registration] = [:]

    /// Registers (or re-registers) `owner`. Returns the token its release must quote.
    @discardableResult
    mutating func register(_ owner: UUID, tab: Int?, token: UUID = UUID()) -> UUID {
        registrations[owner] = Registration(tab: tab, token: token)
        return token
    }

    /// Ends `owner`'s registration if `token` is still the current one.
    mutating func release(_ owner: UUID, token: UUID) {
        guard registrations[owner]?.token == token else { return }
        registrations[owner] = nil
    }

    func isSuppressed(selectedTab: Int) -> Bool {
        registrations.values.contains { $0.tab == nil || $0.tab == selectedTab }
    }

    /// Whether a Book Detail's pinned bar competes with the mini player. Audiobook and
    /// podcast bars carry a play control; the ebook-only bar is a Read button, so the mini
    /// player stays. In a sheet the sheet already covers the mini player, so no change.
    static func detailSuppresses(isPodcast: Bool, isEbookOnly: Bool, inSheet: Bool) -> Bool {
        guard !inSheet else { return false }
        return isPodcast || !isEbookOnly
    }

    /// What the shell draws. `canHide` is false on iOS 26.0, whose
    /// `tabViewBottomAccessory(content:)` has no `isEnabled:` and would paint an empty
    /// glass pill if its content went away, so the mini player stays visible there.
    static func showsMiniPlayer(hasMiniPlayer: Bool, suppressed: Bool, canHide: Bool) -> Bool {
        hasMiniPlayer && !(suppressed && canHide)
    }
}
