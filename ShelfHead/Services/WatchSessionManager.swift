import Foundation
// Build fix (Stage 2, standalone Watch app, 28 August 2026): `@preconcurrency` —
// same fix, same reason, as the Watch-side `WatchConnectivityStore.swift`'s
// identical import (its own CRIT-3 comment explains it first). `WatchConnectivity`'s
// types predate Swift's concurrency checking and aren't `Sendable`-audited in this
// SDK; without this, adding a second branch to `session(_:didReceiveMessage:
// replyHandler:)` (the credential-handoff dispatch, this stage) was enough to make
// the compiler newly analyze this delegate method's existing `Task { @MainActor in
// ... replyHandler(...) }` pattern under full Sendable checking, surfacing "Capture
// of 'replyHandler' with non-Sendable type" — a pre-existing latent issue with this
// file's plain `import WatchConnectivity`, not something introduced by the new
// branch itself, just newly triggered by it needing this exact call shape a second
// time in the same function.
@preconcurrency import WatchConnectivity
import UIKit

// MARK: - Credential handoff vocabulary (item 10, 10 September 2026)

/// What kind of server session the Watch is being handed, sent as the additive
/// `sessionKind` key in the credential-handoff reply.
///
/// The Watch holds its own copy of these raw values (`WatchSessionKind` in
/// `ShelfHead Watch App Watch App/WatchSessionKind.swift`) rather than sharing this
/// file, for the same reason the Watch used to duplicate the phone's URL rules (now shared as `ServerURLRules`): the
/// Watch target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and this
/// file is phone-only (it imports `UIKit` and the whole phone service graph). **The
/// raw strings are the wire contract — change them in both places or not at all.**
enum WatchHandoffSessionKind: String, Equatable, Sendable {
    /// A second, independent server session minted for the Watch alone. It has its
    /// own rotating refresh token, so both devices can refresh without touching each
    /// other's chain.
    case dedicated
    /// A credential that doesn't rotate or expire (the legacy `User.token`). Not
    /// exclusive to the Watch, but nothing either device does can invalidate it, so
    /// there's no chain to break and no "bring your iPhone nearby" to warn about.
    case durable
    /// The phone's current access token, handed over **without** its refresh token.
    /// Works until that token expires, after which the Watch needs a fresh handoff.
    case shared
}

/// Which credential `WatchSessionManager.buildCredentialHandoffReply()` should hand
/// the Watch. See `WatchSessionManager.handoffCredentialPlan(...)` for the decision
/// and the reasoning behind the preference order.
enum WatchHandoffCredentialPlan: Equatable, Sendable {
    /// Mint a brand-new session with a fresh `POST /login` and hand over *that*
    /// session's access + refresh pair.
    case dedicatedLogin
    /// Hand over the legacy, non-rotating API token (carried inline).
    case legacyAPIToken(String)
    /// Hand over the phone's current access token and nothing else. `isDurable` is
    /// true when that access token *is* the server's permanent user token (a pre-2.26
    /// server, where `effectiveAccessToken == token`), so it won't expire and the
    /// Watch needs no "reconnect via iPhone" expectations set.
    case sharedAccessTokenOnly(isDurable: Bool)

    /// Always false. Stated as code, and pinned by a test, because "the phone's
    /// refresh token never leaves the phone" is the entire fix — a future plan case
    /// that wanted to hand one over would have to change this property to do it.
    var handsOverPhoneRefreshToken: Bool { false }
}

/// iPhone-side half of the ShelfHead <-> Apple Watch bridge.
///
/// SYNC BOUNDARY (iPhone -> Watch): this is the only place on the phone that talks
/// WatchConnectivity. It reads playback/library/download state from the existing
/// services (`AudioPlayerService`, `PlayerViewModel`, `LibraryViewModel`,
/// `DownloadManager`) via light polling rather than the services pushing to it — this
/// keeps the Watch feature fully additive: nothing in the existing playback stack needs
/// to know the Watch exists, so the Watch app can be deleted again with zero blast
/// radius, exactly as documented in `CHANGES_IMPLEMENTED.md`'s prior removal.
///
/// SYNC BOUNDARY (Watch -> iPhone): `session(_:didReceiveMessage:replyHandler:)` is the
/// single entry point for commands from the Watch. Every command is re-validated here
/// against the phone's *actual current* account scope/item/session before being applied
/// — see `WatchCommandValidator`. A command that fails validation is answered with a
/// failure payload (never silently dropped) so the Watch can show "out of date, open
/// ShelfHead on iPhone" instead of assuming success.
@MainActor
final class WatchSessionManager: NSObject {
    static let shared = WatchSessionManager()

    private weak var playerViewModel: PlayerViewModel?
    private weak var libraryViewModel: LibraryViewModel?

    private var pollTimer: Timer?
    private var lastPushedState: WatchPlaybackState?
    private var lastPushedDownloadsHash: Int?
    private var lastPushedLibraryHash: Int?
    /// P3-5 (third-pass review, 14 Aug 2026): NEW-7 made `collections` retry as its own
    /// transfer instead of being dropped, but `session(_:didFinish:error:)` had no
    /// attempt counter and re-enters on the retry's own failure — a `payloadTooLarge`
    /// transfer whose retry is rebuilt byte-for-byte identical (stripping already-`nil`
    /// `coverData` for a `["collections": data]`-only transfer, or a cover-stripped
    /// retry that's STILL too large) gets decoded by the same handler and re-sent
    /// forever. Tracks which top-level payload keys ("downloads", "recentlyAdded",
    /// "collections") have already had their one retry for the *current* push cycle —
    /// `transferWatchUserInfo(_:label:)` clears a key the moment a genuinely new push
    /// for it goes out, so the next real data change still gets its own fresh retry
    /// chance; only a retry racing against itself is blocked.
    private var retriedTransferKeys: Set<String> = []

    /// Small in-memory cover-art cache keyed by libraryItemId, used for the Now Playing
    /// snapshot (fetched at `WatchCoverArt.maxDimension`).
    private var coverCache: [String: Data] = [:]
    /// WATCH-3 (REVIEW_2026-08-12.md): separate, smaller-resolution cache for Downloads/
    /// Recently Added rows (`WatchCoverArt.listRowMaxDimension`) — kept apart from
    /// `coverCache` so a book that's both currently playing AND in one of those lists
    /// gets an appropriately-sized image for each context instead of the two uses
    /// fighting over one cached size.
    private var listCoverCache: [String: Data] = [:]
    /// WATCH-5: when a cover fetch fails (404/offline/decode failure), the timestamp of
    /// that failure — see `loadCover`'s cooldown check, which stops a permanently-
    /// missing cover from being re-requested on literally every poll tick forever.
    private var failedCoverFetches: [String: Date] = [:]
    private static let coverFailureCooldown: TimeInterval = 120
    /// Guards against firing a duplicate fetch for the same item (at the same size)
    /// while one is already in flight (the poll timer runs every 2s, faster than a
    /// cover fetch completes). Keyed by "itemId|dimension" since the two caches above
    /// can independently be fetching the same item at different sizes at once.
    private var coversInFlight: Set<String> = []

    /// WATCH-4 (REVIEW_2026-08-12.md): `pushLibraryIfNeeded()` used to call
    /// `library.loadPersonalizedView()` unconditionally, with no guard, every single
    /// time `personalizedShelves` was empty — which includes every 2s poll tick until
    /// the load actually succeeds. Since the poll timer fires every 2s and a network
    /// load can easily take longer than that, this could spawn a new overlapping load
    /// on nearly every tick, and if the server/library genuinely returns nothing (or
    /// the phone is offline), it would retry *forever*, silently — including
    /// `DownloadManager.autoDownloadIfEnabled` side effects and an `errorMessage` toast
    /// surfacing in the PHONE UI for a background refresh the phone user never asked
    /// for. `isLoadingPersonalizedView` is the in-flight guard; `attemptedPersonalizedViewLoadThisLaunch`
    /// caps it to one attempt per app launch so a persistently-empty library doesn't
    /// retry indefinitely. Mirrored for collections with `isLoadingCollections` (the
    /// existing `library.collectionsLoaded` flag already prevents infinite retries
    /// there, but had no in-flight guard against overlapping calls).
    private var isLoadingPersonalizedView = false
    private var attemptedPersonalizedViewLoadThisLaunch = false
    private var isLoadingCollections = false

    /// Cap on how many collections (and books per collection) are mirrored to the Watch
    /// — this stays a companion controller, not a full library browser, so a very large
    /// library just shows its first N of each rather than paginating over
    /// WatchConnectivity.
    private static let recentlyAddedCap = 20
    private static let collectionsCap = 15
    private static let collectionBookCap = 30

    /// Polling cadence for diffing playback state and deciding whether to push again.
    /// "Do not over-sync" (spec) — this is not the resolution of the Watch's own
    /// countdown display (that's estimated locally via `WatchProgressEstimator`), just
    /// how often we check whether the phone's truth has moved enough to be worth a
    /// fresh push.
    private let pollInterval: TimeInterval = 2.0

    private override init() {
        super.init()
        // Concurrency/lifecycle review (9 September 2026): `attemptedPersonalizedViewLoadThisLaunch`
        // is a *launch*-scoped cap, and `clearWatchState()` (called from
        // `AuthViewModel.tearDownAccountScopedState`) only resets it on the sign-out and
        // account-switch paths. Adding a server from Settings and signing straight into
        // it posts `.shelfheadAccountChanged` without going through that teardown, so the
        // cap set by the *previous* account's one attempt survived — and the Watch got no
        // personalized load at all for the new account until the app was relaunched.
        // Observing the notification directly covers every account transition regardless
        // of which `AuthViewModel` path caused it (same reasoning, and the same
        // selector-based pattern, as `CarPlayCoordinator.startObservingAppState` — this
        // is a non-view type with no reference to the non-singleton `AuthViewModel`).
        // No matching `removeObserver`: this is a `static let shared` that lives for the
        // life of the process.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAccountChanged),
            name: .shelfheadAccountChanged, object: nil)
    }

    /// Lets the next `pushLibraryIfNeeded()` re-attempt the personalized-shelves load for
    /// the account that just became current.
    ///
    /// Deliberately *only* the launch cap: the in-flight flags are left alone so a load
    /// still running for the outgoing account isn't joined by a second one — it clears its
    /// own flag when it finishes, and the next poll tick then starts exactly one fresh
    /// load. Caches and queued transfers are `clearWatchState()`'s job, and the
    /// sign-out/switch paths have already run it by the time this fires.
    @objc private func handleAccountChanged() {
        // Item 23 (REVIEW-2026-09-09-REMAINING, Batch 313): this method is already
        // main-actor-isolated (the class is @MainActor), so the former `Task { @MainActor in }`
        // wrapper only deferred the reset by one run-loop turn. Reset synchronously.
        attemptedPersonalizedViewLoadThisLaunch = false
    }

    /// Call once, early in app launch (see `ShelfHeadApp.init`). Safe to call on a
    /// device/simulator without a paired Watch — `WCSession` handles that gracefully.
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        // Batch 399 follow-up: keep the Watch's copy of the timed-chapter-skip settings current.
        //
        // Batch 416: `queue: nil` plus an async hop, NOT `queue: .main`. With an operation
        // queue, the *posting* thread waits until the block has run there
        // (`_CFXNotificationPost` → `-[NSOperation waitUntilFinished]` in the crash logs).
        // `SharedPlayback.performWrite` posts this notification from its background
        // `writeQueue` while the main thread sits in `SharedPlayback.flush()`
        // (`writeQueue.sync`, from `reloadControlCenterControls()` on playback start), so
        // the two waited on each other until the scene-update watchdog killed the app
        // (0x8BADF00D, 6.9 build 1, every phone/CarPlay play). `object: .standard` also
        // stops App Group writes from waking this at all — the settings live in `.standard`.
        chapterSkipDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
        ) { [weak self] _ in
            // Rebind the weak capture as a `let`: the Task can't capture the closure's
            // `self` var itself (Swift 6 "captured var in concurrently-executing code").
            let manager = self
            Task { @MainActor in manager?.pushChapterSkipSettingsIfNeeded() }
        }
    }

    /// Observer token for `UserDefaults.didChangeNotification` (see `activate()`).
    private var chapterSkipDefaultsObserver: NSObjectProtocol?
    /// The last chapter-skip payload handed to `transferUserInfo`, so the (very chatty)
    /// defaults-changed notification only causes a send when the payload really differs.
    private var lastSentChapterSkipSettings: Data?

    /// Batch 399 follow-up: sends the timed chapter skip settings (default start/end plus
    /// per-book overrides) under `"chapterSkipSettings"` so the Watch's standalone
    /// engine can honour them. Reads the same UserDefaults keys `SettingsStore` writes.
    ///
    /// Channel: `transferUserInfo`, deliberately NOT `updateApplicationContext`. Per the
    /// WATCH-3 notes on `send(_:)`, application context is reserved for `playbackState`
    /// and each call REPLACES the whole context dictionary, so a settings-only call would
    /// clobber it (and a merged dictionary is the design WATCH-3 removed). The payload is
    /// tiny and send-on-change only, so queued, ordered delivery (last one delivered wins
    /// on the Watch, which overwrites its persisted copy) is exactly enough.
    private func pushChapterSkipSettingsIfNeeded() {
        guard hasReachableWatchApp, WCSession.default.activationState == .activated else { return }
        let defaults = UserDefaults.standard
        let settings = WatchChapterSkipSettings(
            defaultStart: defaults.integer(forKey: SettingsKeys.chapterSkipStart),
            defaultEnd: defaults.integer(forKey: SettingsKeys.chapterSkipEnd),
            overrides: (defaults.dictionary(forKey: SettingsKeys.perBookChapterSkip) as? [String: [Int]]) ?? [:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys   // stable bytes, so the diff below is meaningful
        guard let data = try? encoder.encode(settings), data != lastSentChapterSkipSettings else { return }
        lastSentChapterSkipSettings = data
        transferWatchUserInfo(["chapterSkipSettings": data], label: "chapterSkipSettings")
    }

    /// Call once the iPhone-side view models exist (see `ShelfHeadApp.init`). Held
    /// weakly — this manager must never be the thing keeping a view model alive.
    func attach(playerViewModel: PlayerViewModel, libraryViewModel: LibraryViewModel) {
        self.playerViewModel = playerViewModel
        self.libraryViewModel = libraryViewModel
        refreshPollingState()
    }

    /// True only when there's an actual Watch app to talk to. The vast majority of
    /// installs have no Apple Watch paired at all, so this gate — not just cheap no-op
    /// diffing inside `pushIfNeeded()` — is what keeps this feature from costing those
    /// users anything: without it, every install would run a 2s timer, JSON-encode a
    /// playback snapshot, and make a `WCSession` IPC call indefinitely for the entire
    /// life of the app process (including the full duration of any background audio
    /// session), for a Watch that will never receive or use any of it.
    private var hasReachableWatchApp: Bool {
        WCSession.isSupported() && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }

    /// Starts or stops the poll timer to match whether a Watch app is actually
    /// present. Called on attach, on activation completing, and whenever
    /// `sessionWatchStateDidChange` fires (pairing/installing/uninstalling the Watch
    /// app at runtime) — so this stays correct without polling the pairing state itself.
    private func refreshPollingState() {
        if hasReachableWatchApp {
            startPolling()
        } else {
            stopPolling()
        }
        // Also covers a Watch app being installed/paired after launch (dedupe makes it cheap).
        pushChapterSkipSettingsIfNeeded()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // `[weak self]` on BOTH closures. The Task's own capture list re-reads the
            // outer weak binding at creation time (not concurrently), which is why this
            // doesn't trip strict concurrency's "captured var in concurrently-executing
            // code" — and Swift 6.4 (#ImplicitStrongCapture) now flags the old shape,
            // where only the inner closure was weak and the Timer closure implicitly
            // held `self` strongly. Same pattern as `AudioPlayerService.startPeriodicSync()`.
            Task { @MainActor [weak self] in self?.pushIfNeeded() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Current scope

    /// The account scope currently active on the phone, or nil if signed out. Every
    /// outbound snapshot and every inbound command is checked against this.
    private var currentScope: WatchAccountScope? {
        guard AuthStore.shared.isConfigured, let accountId = AccountStore.currentAccountId else { return nil }
        return WatchAccountScope(serverURL: AuthStore.shared.serverURL, accountId: accountId)
    }

    // MARK: - Outbound: playback state

    /// How often a still-playing session gets a fresh push even without a "meaningful"
    /// change (see `isMeaningfulChange`) — just often enough to keep `lastUpdated`
    /// honest for the Watch's staleness check, since the Watch estimates its own
    /// second-by-second position locally (see `WatchProgressEstimator`) from
    /// `currentTime`/`lastUpdated`/`playbackRate` rather than needing a fresh position
    /// every poll tick. Previously this was meant to be ~10s, but `isEquivalent`'s
    /// 0.5s `currentTime` tolerance was tighter than the 2s poll interval itself —
    /// `currentTime` advances by ~2s every tick while playing, so that comparison was
    /// false almost every time, and `pushIfNeeded()` ended up pushing (full JSON encode
    /// + `WCSession.updateApplicationContext` IPC call) on essentially every 2s tick
    /// for the entire session instead of the intended periodic cadence.
    private let playbackRefreshInterval: TimeInterval = 20

    private func pushIfNeeded() {
        guard WCSession.default.activationState == .activated else { return }
        let state = buildPlaybackState()
        guard let last = lastPushedState else {
            push(state)
            return
        }
        // WATCH-1: previously gated on `state.isPlaying`, so `lastUpdated` was never
        // refreshed at all while paused. `WatchStaleness.threshold` (45s) is checked
        // against this same `lastUpdated`, and the *only* thing that advances it is
        // this periodic refresh (a real state change also updates it, but "paused and
        // untouched" is precisely the case with no real changes to report) — so
        // leaving a paused book open for longer than the threshold made every
        // position-dependent Watch command fail `.staleState` permanently, with
        // nothing left to make it self-heal (see the `pushIfNeeded()` force-push fix
        // in `handle(_:)` below for the other half of this). Dropping the
        // `isPlaying` condition means a paused session's `lastUpdated` keeps
        // advancing every `playbackRefreshInterval` just like a playing one's does.
        let periodicRefresh = Date().timeIntervalSince(last.lastUpdated) >= playbackRefreshInterval
        guard isMeaningfulChange(state, last) || periodicRefresh else { return }
        push(state)
    }

    private func push(_ state: WatchPlaybackState) {
        // Chapters/bookmarks are book-specific and were previously only refreshed as
        // a side effect of handling an inbound Watch command (see `handle(_:)`) — so
        // starting a new book from the phone (not from the Watch) left the Watch's
        // Chapters/Bookmarks pages showing the *previous* book's data even though Now
        // Playing had already moved on, until some unrelated command happened to
        // trigger a refresh. Detecting the itemId change here means it's driven by
        // the same push path that already updates Now Playing, so both stay in sync.
        let itemChanged = lastPushedState?.itemId != state.itemId
        lastPushedState = state
        send(state)
        pushDownloadsIfNeeded()
        pushLibraryIfNeeded()
        // WATCH-4: `pushBookAuxiliaryState()` now does a real network fetch for
        // bookmarks (see its doc comment below), so it's `async` — wrapped in a `Task`
        // here since `push(_:)` itself stays synchronous (it's called from the 2s poll
        // timer and from `handle(_:)`, neither of which should block on this).
        if itemChanged { Task { await pushBookAuxiliaryState() } }
    }

    /// True for anything a user would actually notice on the Watch — play/pause, a
    /// seek or chapter change, a new book/track, a speed change. Deliberately excludes
    /// `currentTime`: ordinary playback progression (the position simply advancing
    /// tick to tick) is not itself a "change" worth an immediate push — that's what
    /// `playbackRefreshInterval` is for instead.
    private func isMeaningfulChange(_ a: WatchPlaybackState, _ b: WatchPlaybackState) -> Bool {
        a.scope != b.scope || a.itemId != b.itemId || a.sessionId != b.sessionId ||
        a.title != b.title || a.author != b.author || a.chapterTitle != b.chapterTitle ||
        a.duration != b.duration || a.playbackRate != b.playbackRate || a.isPlaying != b.isPlaying ||
        // WATCH-5: skip-interval/sleep-timer changes are exactly the kind of thing a
        // user would notice going stale on the Watch (a countdown that stopped moving,
        // or a rewind button that still skips the old amount) — worth an immediate
        // push rather than waiting for the next `playbackRefreshInterval` tick.
        a.skipBackwardInterval != b.skipBackwardInterval || a.skipForwardInterval != b.skipForwardInterval ||
        a.sleepTimerOption != b.sleepTimerOption ||
        // U7 (REVIEW_2026-08-20_UI_SECURITY.md): an accent change should reach the
        // Watch promptly, the same reasoning as the skip-interval/sleep-timer checks
        // just above — otherwise it waits for the next `playbackRefreshInterval` tick.
        a.accentHex != b.accentHex ||
        // LS-1 (docs/design-review.md, Round 2): a stall starting or clearing should
        // reach the Watch on the very next poll tick rather than sitting until the
        // next `playbackRefreshInterval` — otherwise the buffering ring could lag
        // well behind the real state, or (worse) not clear promptly once data resumes.
        a.isBuffering != b.isBuffering
    }

    private func buildPlaybackState() -> WatchPlaybackState {
        guard let scope = currentScope else {
            return .idle(scope: WatchAccountScope(serverURL: "", accountId: ""), accentHex: AppTheme.accentHex)
        }
        let player = AudioPlayerService.shared
        guard let session = player.currentSession, let itemId = player.currentItemId else {
            return .idle(scope: scope, accentHex: AppTheme.accentHex)
        }
        return WatchPlaybackState(
            scope: scope,
            itemId: itemId,
            sessionId: session.id,
            title: session.libraryItem?.title ?? String(localized: "Unknown", comment: "Fallback title sent to the Watch for a book with no title"),
            author: session.libraryItem?.authorName ?? "",
            chapterTitle: player.currentChapter?.title,
            duration: player.duration,
            currentTime: player.currentTime,
            playbackRate: Double(player.playbackRate),
            isPlaying: player.isPlaying,
            lastUpdated: Date(),
            // P3-9 (third-pass review, 14 Aug 2026): this is a genuine, phone-confirmed
            // snapshot, so `lastConfirmedUpdate` gets the same timestamp as
            // `lastUpdated` — see `WatchPlaybackState`'s doc comment on why the Watch's
            // own optimistic-apply code must never write this field itself.
            lastConfirmedUpdate: Date(),
            coverData: lastPushedState?.itemId == itemId ? lastPushedState?.coverData : nil,
            // WATCH-5: real configured values instead of the Watch guessing/hardcoding
            // 15s for both directions (see `WatchConnectivityStore.rewind()`/`forward()`
            // and `WatchSettingsView`, which previously showed a literal "15 Seconds").
            skipBackwardInterval: SettingsStore.skipBackwardInterval,
            skipForwardInterval: SettingsStore.skipForwardInterval,
            sleepTimerOption: watchSleepOption(from: player.sleepTimerOption),
            sleepTimerRemaining: player.sleepTimerRemaining,
            // U7: the phone's user-selected accent, so `WatchTheme.accent` can follow
            // it instead of being hardcoded regardless of what's picked on the phone.
            accentHex: AppTheme.accentHex,
            // LS-1 (docs/design-review.md, Round 2): `AudioPlayerService.isBuffering`
            // was already tracked but never surfaced anywhere on the Watch — mirroring
            // it here is the whole fix; the Watch side just renders it.
            isBuffering: player.isBuffering
        )
    }

    /// WATCH-5: the phone's sleep timer (`SleepTimerOption`) has two cases the Watch's
    /// smaller `WatchSleepTimerOption` doesn't model (`.chapters(n)`, `.endOfBook`) —
    /// approximated as `.endOfChapter` (the closest "stops at a chapter-ish boundary"
    /// meaning) rather than dropping to `.off`, which would make the Watch wrongly show
    /// no timer running at all while one actually is.
    private func watchSleepOption(from option: SleepTimerOption) -> WatchSleepTimerOption {
        switch option {
        case .off: return .off
        case .minutes(let m): return .minutes(m)
        case .endOfChapter, .chapters: return .endOfChapter
        case .endOfBook: return .endOfChapter
        }
    }

    /// WATCH-3 (REVIEW_2026-08-12.md): `playbackState` is now the ONLY thing that goes
    /// through `updateApplicationContext` — previously it shared one ever-growing
    /// merged dictionary with downloads/library/chapters/bookmarks (see the removed
    /// `applicationContextMerging`), so a single position refresh re-transmitted
    /// everything, worst case ~250-270KB against WCSession's ~256KB ceiling, and a
    /// `payloadTooLarge` failure there silently killed ALL future pushes of every kind,
    /// playback included. `updateApplicationContext` is exactly the right channel for
    /// *this* one payload specifically (small, "latest wins," delivered even if the
    /// Watch app isn't foreground) — everything else now moves over `transferUserInfo`
    /// instead (see `pushDownloadsIfNeeded`/`pushLibraryIfNeeded`/
    /// `pushBookAuxiliaryState`), which queues reliably without competing for this same
    /// small ceiling.
    private func send(_ state: WatchPlaybackState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        do {
            try WCSession.default.updateApplicationContext(["playbackState": data])
        } catch let error as WCError where error.code == .payloadTooLarge {
            // WATCH-3: previously just logged and swallowed — the Watch would then
            // never receive another update of any kind until the next full app
            // relaunch. A playback-only payload should essentially never be this large
            // (cover art is capped at `WatchCoverArt.maxDimension`/`.jpegQuality`,
            // everything else is a handful of primitives), but if it somehow is
            // (corrupt/oversized cover data, a pathological title/author string),
            // stripping the cover and retrying once is a self-healing fallback instead
            // of a permanent silent outage.
            ShelfLog.error(.watch, "Watch context update payloadTooLarge (playbackState) — retrying without cover art")
            var stripped = state
            stripped.coverData = nil
            guard let strippedData = try? JSONEncoder().encode(stripped) else { return }
            do {
                try WCSession.default.updateApplicationContext(["playbackState": strippedData])
            } catch {
                ShelfLog.error(.watch, "Watch context update failed even without cover art (playbackState): \(error.localizedDescription)")
            }
        } catch {
            ShelfLog.error(.watch, "Watch context update failed (playbackState): \(error.localizedDescription)")
        }
        // Fetch and attach cover art lazily/once per item, then push again with it —
        // avoids fetching+encoding an image on every 2s poll tick.
        if state.hasActiveItem, state.coverData == nil {
            Task {
                guard let jpeg = await loadCover(itemId: state.itemId, maxDimension: WatchCoverArt.maxDimension) else { return }
                guard var current = self.lastPushedState, current.itemId == state.itemId else { return }
                current.coverData = jpeg
                current.lastUpdated = Date()
                self.lastPushedState = current
                self.send(current)
            }
        }
    }

    /// Fetches (and downscales/JPEG-encodes) a small cover thumbnail for `itemId` at
    /// `maxDimension`. WATCH-3: this used to always fetch at the Now Playing card's
    /// `WatchCoverArt.maxDimension` (88pt) even for Downloads/Recently Added list rows
    /// that render at ~32pt (`WatchDownloadsView.downloadRow`'s `CoverThumbnail(side: 32)`)
    /// — 7x the pixels those rows can even display, multiplied across up to 40 rows,
    /// which was a large share of what pushed the merged context near its size ceiling.
    /// Callers now pass the size that's actually needed; the cache is split into
    /// `coverCache` (Now Playing, full size) vs. `listCoverCache` (rows, smaller) so the
    /// two uses don't fight over one cached resolution for the same item id.
    private func loadCover(itemId: String, maxDimension: CGFloat) async -> Data? {
        let isListSize = maxDimension <= WatchCoverArt.listRowMaxDimension
        let cache: [String: Data] = isListSize ? listCoverCache : coverCache
        if let cached = cache[itemId] { return cached }
        // WATCH-5 (REVIEW_2026-08-12.md): a cover that failed (404, offline, decode
        // failure) used to have no memory of that at all — every single 2s poll tick
        // that referenced this item id (via `primeCovers`) fired a brand new network
        // request for it, forever, 8 at a time. A short cooldown after a failure means
        // a persistently-missing cover gets retried occasionally (in case it becomes
        // available — e.g. the server comes back, or the book finishes downloading)
        // rather than hammered every 2s indefinitely.
        if let failedAt = failedCoverFetches[itemId], Date().timeIntervalSince(failedAt) < Self.coverFailureCooldown {
            return nil
        }
        let inFlightKey = "\(itemId)|\(Int(maxDimension))"
        guard !coversInFlight.contains(inFlightKey) else { return nil }
        coversInFlight.insert(inFlightKey)
        defer { coversInFlight.remove(inFlightKey) }

        // WATCH-5: `shelfCoverURL` is the SAME helper the phone's own UI uses for
        // every other cover in the app — it prefers `DownloadManager.localCoverURL`
        // (a file already on disk for a downloaded book) before falling back to a
        // network request. `loadCover` previously always built a network URL
        // unconditionally, so a fully-downloaded, offline book showed no Watch cover
        // at all even though the exact bytes needed were sitting on the phone's disk.
        guard let url = shelfCoverURL(itemId: itemId, width: Int(maxDimension * 2)) else {
            failedCoverFetches[itemId] = Date()
            return nil
        }

        let image: UIImage?
        if url.isFileURL {
            // Polish pass: the file read ran on the main actor; it's off it now.
            let fileData = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            image = fileData.flatMap(UIImage.init(data:))
        } else {
            // Item 6 (REVIEW-2026-09-09 remaining, integration sweep): was a raw
            // `URLSession.shared.data(for:)` on an authorized request — the same headers,
            // but no refresh-and-retry on 401 and no status check, so behind a proxy with
            // short-lived tokens the Watch got no cover (or a 401 body fed to `UIImage`).
            // `authorizedData` throws on non-2xx, so `try?` → nil → `failedCoverFetches`.
            image = (try? await AudiobookshelfAPI.shared.authorizedData(for: url)).flatMap(UIImage.init(data:))
        }
        guard let image else {
            failedCoverFetches[itemId] = Date()
            return nil
        }
        // Polish pass: `preparingThumbnail(of:)` is synchronous and this class is main-actor
        // isolated, so the downscale of a full-size cover blocked the UI. The async variant
        // (iOS 15+) does the same work off the main thread.
        let thumb = await image.byPreparingThumbnail(
            ofSize: CGSize(width: maxDimension, height: maxDimension)
        ) ?? image
        guard let jpeg = thumb.jpegData(compressionQuality: WatchCoverArt.jpegQuality) else {
            failedCoverFetches[itemId] = Date()
            return nil
        }
        failedCoverFetches.removeValue(forKey: itemId)
        if isListSize {
            listCoverCache[itemId] = jpeg
        } else {
            coverCache[itemId] = jpeg
        }
        return jpeg
    }

    // MARK: - Outbound: downloads

    private func pushDownloadsIfNeeded() {
        let summaries = buildDownloadSummaries()
        // P3-17 (third-pass review, 14 Aug 2026): `coverData != nil` here is now a
        // constant `false` for every summary — `buildDownloadSummaries()` always
        // passes `coverData: nil` since the later WATCH-3 follow-up (see its own doc
        // comment) — so this term can never actually change the hash anymore. Left in
        // place rather than removed: it's inert, not incorrect, and removing it isn't
        // worth touching this dedup key without a build to confirm nothing downstream
        // (persisted hash values, if any ever were) depends on its exact shape.
        let hash = summaries.map { "\($0.id)-\($0.status)-\($0.coverData != nil)" }.joined().hashValue
        guard hash != lastPushedDownloadsHash else { return }
        lastPushedDownloadsHash = hash
        guard let data = try? JSONEncoder().encode(summaries) else { return }
        // WATCH-3: `transferUserInfo`, not `updateApplicationContext` — downloads don't
        // need "latest wins, delivered even backgrounded" semantics, they need reliable
        // queued delivery that doesn't share the same ~256KB ceiling `playbackState`
        // depends on (see `send(_:)`'s doc comment).
        transferWatchUserInfo(["downloads": data], label: "downloads")
        // WATCH-3 (follow-up review, 14 Aug 2026): no longer primes/ships covers for
        // these rows at all — see `buildDownloadSummaries`'s doc comment for why.
    }

    /// WATCH-3: the outbound channel for everything EXCEPT `playbackState` — downloads,
    /// recently-added, collections, chapters, and bookmarks. `transferUserInfo` queues
    /// reliably (unlike `updateApplicationContext`, which only ever keeps the latest
    /// value and previously had to be shared with `playbackState` under one
    /// ever-growing merged dictionary — see the removed `applicationContextMerging`).
    /// It doesn't throw synchronously; delivery failures (including `payloadTooLarge`)
    /// surface later via `session(_:didFinish:error:)` below, which logs
    /// them and retries once — see that method's own doc comment for what the retry
    /// actually strips today (P3-17, third-pass review, 14 Aug 2026: this used to say
    /// "the two kinds known to carry cover art," which was accurate when written but
    /// no longer is — see that comment for the current, corrected version).
    private func transferWatchUserInfo(_ userInfo: [String: Any], label: String) {
        guard WCSession.default.activationState == .activated else {
            ShelfLog.error(.watch, "Watch transferUserInfo skipped (\(label)): session not activated")
            return
        }
        // P3-5: this is a genuinely new push (call sites only reach here when their own
        // content hash actually changed), so any key it carries gets a fresh one-shot
        // retry chance again if THIS attempt reports `payloadTooLarge` — see
        // `retriedTransferKeys`'s doc comment. The retry itself is issued directly via
        // `WCSession.default.transferUserInfo` in `session(_:didFinish:error:)`, not
        // through this method, so retrying never re-clears its own key.
        for key in userInfo.keys { retriedTransferKeys.remove(key) }
        WCSession.default.transferUserInfo(userInfo)
    }

    // MARK: - Sign-out

    /// SEC-4 (REVIEW_2026-08-12.md): `AuthViewModel.logout()` is thorough about
    /// credentials (Keychain, per-account passwords, per-book speeds, Spotlight index)
    /// but previously left the signed-out account's book titles, authors, covers,
    /// downloads, recently-added, collections, and now-playing state sitting on the
    /// Watch indefinitely. Called from `AuthViewModel.tearDownAccountScopedState` on sign-out
    /// (one server or all) and on an account switch.
    ///
    /// WATCH-3: downloads/library/chapters/bookmarks no longer live in the merged
    /// `updateApplicationContext` dictionary this comment used to describe — they're
    /// `transferUserInfo` pushes now, which the Watch overwrites its local arrays with
    /// on receipt, not merges. So clearing them here means: (1) push a fresh empty
    /// payload for each so the *next* thing the Watch receives for this key is empty,
    /// and (2) cancel any not-yet-delivered transfers already queued from the previous
    /// account, so a stale payload can't land on the Watch after sign-out completes.
    func clearWatchState() {
        lastPushedState = nil
        lastPushedDownloadsHash = nil
        lastPushedLibraryHash = nil
        coverCache.removeAll()
        listCoverCache.removeAll()
        failedCoverFetches.removeAll()
        coversInFlight.removeAll()
        // NEW-11: cancel any debounced cover-triggered push still pending from the
        // previous account — letting it fire after sign-out would re-push whatever
        // downloads/library summaries it captured before this call ran.
        coverTriggeredPushTask?.cancel()
        coverTriggeredPushTask = nil
        attemptedPersonalizedViewLoadThisLaunch = false
        isLoadingPersonalizedView = false
        isLoadingCollections = false
        // Cancel anything still queued from the previous account — `transferUserInfo`
        // delivers eventually even if the Watch is unreachable right now, so without
        // this a queued "downloads" transfer from the old account could still land on
        // the Watch after the new account has already signed in.
        for transfer in WCSession.default.outstandingUserInfoTransfers {
            transfer.cancel()
        }
        guard WCSession.default.activationState == .activated else { return }
        let idle = WatchPlaybackState.idle(scope: WatchAccountScope(serverURL: "", accountId: ""))
        guard let data = try? JSONEncoder().encode(idle) else { return }
        try? WCSession.default.updateApplicationContext(["playbackState": data])
        if let emptyDownloads = try? JSONEncoder().encode([WatchDownloadSummary]()),
           let emptyBooks = try? JSONEncoder().encode([WatchBookSummary]()),
           let emptyCollections = try? JSONEncoder().encode([WatchCollectionSummary]()),
           let emptyChapters = try? JSONEncoder().encode([WatchChapterSummary]()),
           let emptyBookmarks = try? JSONEncoder().encode([WatchBookmarkSummary]()) {
            transferWatchUserInfo(["downloads": emptyDownloads], label: "clearWatchState.downloads")
            transferWatchUserInfo(["recentlyAdded": emptyBooks, "collections": emptyCollections], label: "clearWatchState.library")
            transferWatchUserInfo(["chapters": emptyChapters, "bookmarks": emptyBookmarks], label: "clearWatchState.bookAuxiliaryState")
        }
        // Stage 2 (standalone Watch app, addendum §3): the Watch's own on-device
        // session (added this stage) had no sign-out flow of its own until now — same
        // gap this whole method exists to close for book/library data, now real for a
        // credential too. Deliberately the OPPOSITE channel choice from the credential
        // *handoff* itself (see `buildCredentialHandoffReply`'s doc comment, which uses
        // `sendMessage`): a wipe instruction carries no secret (there's no token inside
        // it, just a signal to delete one), but it DOES need guaranteed eventual
        // delivery, since the Watch is very plausibly unreachable at the exact moment a
        // phone-side sign-out or account switch happens — that's precisely why this
        // method can't just directly clear something on the Watch itself.
        // `transferUserInfo`'s queue-outside-the-app-process durability, the exact
        // property that made it wrong for the credential payload (§3's threat model),
        // is the property that makes it right here. Called from both sign-out and
        // account switches (via `tearDownAccountScopedState`) — a cross-account credential
        // left behind is worse than a stale one, so this fires on both, not just
        // sign-out.
        if let wipeSignal = try? JSONEncoder().encode(Date()) {
            transferWatchUserInfo(["wipeCredentials": wipeSignal], label: "clearWatchState.wipeCredentials")
        }
    }

    /// WATCH-5 (REVIEW_2026-08-12.md): previously iterated ONLY
    /// `downloadedLibraryItems()`, which by construction returns already-downloaded ids
    /// — so `status` was always `.downloaded`, and `WatchDownloadStatus.queued`/
    /// `.downloading`/`.failed` (plus the Watch's own `.downloading` inline progress
    /// bar in `WatchDownloadsView`) were unreachable dead code; a download actually in
    /// progress didn't even appear on the Watch until it finished. Now unions in
    /// `DownloadManager.activeDownloads` (in-flight, with real progress) and
    /// `.failedDownloads` — the two collections `DownloadsView` itself renders from on
    /// the phone — so the Watch mirrors the same three-state reality instead of only
    /// ever showing the "done" state. Active/failed entries have no `LibraryItem`
    /// (`DownloadTask`/`DownloadFailure` only carry an id + title), so `author` is
    /// empty for those rows — acceptable for a transient in-progress/failed state.
    ///
    /// WATCH-3 (follow-up review, 14 Aug 2026): `coverData` is now always `nil` here —
    /// these rows render at `CoverThumbnail(..., side: 32)`, and `CoverThumbnail`
    /// already has a clean icon fallback for a nil cover, so there was never a real
    /// need to ship per-row cover bytes over WatchConnectivity at all. Shrinking them
    /// to `listRowMaxDimension` (64px) cut the per-cover cost but didn't address the
    /// review's actual ask — stop shipping them for a 32pt row — and multiplied across
    /// up to 20 downloads + 20 recently-added rows was still a meaningful share of the
    /// payload. `primeCovers`/`listCoverCache`/the per-cover debounced re-push in
    /// `scheduleCoverTriggeredPush` are unused now as a result (no longer called from
    /// here or `pushLibraryIfNeeded`) — left in place rather than deleted, since
    /// removing them touches several interconnected pieces this pass can't verify
    /// compiles without Xcode open; they're inert, not wrong.
    private func buildDownloadSummaries() -> [WatchDownloadSummary] {
        let manager = DownloadManager.shared
        var summaries: [WatchDownloadSummary] = []
        var seen = Set<String>()

        for (itemId, task) in manager.activeDownloads {
            guard seen.insert(itemId).inserted else { continue }
            summaries.append(WatchDownloadSummary(
                id: itemId, title: task.title, author: "",
                status: task.isPaused ? .queued : .downloading(progress: task.progress),
                coverData: nil))
        }
        for (itemId, failure) in manager.failedDownloads {
            guard seen.insert(itemId).inserted else { continue }
            summaries.append(WatchDownloadSummary(
                id: itemId, title: failure.title, author: "",
                status: .failed, coverData: nil))
        }
        for item in manager.downloadedLibraryItems() {
            guard seen.insert(item.id).inserted else { continue }
            summaries.append(WatchDownloadSummary(
                id: item.id, title: item.title, author: item.authorName,
                status: .downloaded, coverData: nil))
        }
        return Array(summaries.prefix(20))
    }

    // MARK: - Outbound: recently added / collections

    /// Pushes "Recently Added" and "Collections" alongside the regular poll cycle.
    /// Kicks off a background load on the phone's `LibraryViewModel` the first time
    /// either is empty, so opening the Watch app doesn't depend on the user having
    /// already visited Home/Collections on the phone this session.
    private func pushLibraryIfNeeded() {
        guard let library = libraryViewModel else { return }
        // WATCH-4: guarded with an in-flight flag AND a "already tried this launch"
        // flag — see the properties' doc comment. Without both, an empty shelf list
        // (offline, server hiccup, a genuinely-empty library) retried on literally
        // every poll tick and every inbound Watch command forever, each retry able to
        // trigger `DownloadManager.autoDownloadIfEnabled` and surface an `errorMessage`
        // toast in the PHONE UI for a background refresh nobody asked for.
        if library.personalizedShelves.isEmpty, !isLoadingPersonalizedView, !attemptedPersonalizedViewLoadThisLaunch {
            isLoadingPersonalizedView = true
            attemptedPersonalizedViewLoadThisLaunch = true
            Task {
                await library.loadPersonalizedView()
                isLoadingPersonalizedView = false
            }
        }
        if library.collections.isEmpty, !library.collectionsLoaded, !isLoadingCollections {
            isLoadingCollections = true
            Task {
                await library.loadCollections()
                isLoadingCollections = false
            }
        }

        let recentlyAdded = buildRecentlyAddedSummaries()
        let collections = buildCollectionSummaries()
        // P3-17: same as `pushDownloadsIfNeeded`'s own dedup hash — `coverData != nil`
        // is now a constant `false`, since `buildRecentlyAddedSummaries()` always
        // passes `coverData: nil` too. See that hash's comment for why this is left as
        // inert rather than removed.
        let hash = (recentlyAdded.map { "\($0.id)-\($0.coverData != nil)" }
            + collections.map { "\($0.id)-\($0.bookCount)" }).joined().hashValue
        guard hash != lastPushedLibraryHash else { return }
        lastPushedLibraryHash = hash

        guard let recentData = try? JSONEncoder().encode(recentlyAdded),
              let collectionsData = try? JSONEncoder().encode(collections) else { return }
        // WATCH-3: `transferUserInfo`, not the merged `updateApplicationContext` — see
        // `send(_:)`'s doc comment.
        transferWatchUserInfo(["recentlyAdded": recentData, "collections": collectionsData], label: "library")
        // WATCH-3 (follow-up review, 14 Aug 2026): no longer primes/ships covers for
        // these rows either — see `buildRecentlyAddedSummaries`'s doc comment.
    }

    /// WATCH-3 (follow-up review, 14 Aug 2026): `coverData` always `nil` — see
    /// `buildDownloadSummaries`'s doc comment.
    private func buildRecentlyAddedSummaries() -> [WatchBookSummary] {
        guard let shelf = libraryViewModel?.personalizedShelves.first(where: { $0.labelStringKey == "LabelRecentlyAdded" }),
              let entities = shelf.entities else { return [] }
        return entities.prefix(Self.recentlyAddedCap).map { item in
            WatchBookSummary(
                id: item.id, title: item.title, author: item.authorName,
                durationSeconds: item.duration, progress: item.progressPercent,
                coverData: nil)
        }
    }

    private func buildCollectionSummaries() -> [WatchCollectionSummary] {
        guard let collections = libraryViewModel?.collections else { return [] }
        return collections.prefix(Self.collectionsCap).map { collection in
            let books = (collection.books ?? []).prefix(Self.collectionBookCap).map { item in
                WatchBookSummary(
                    id: item.id, title: item.title, author: item.authorName,
                    durationSeconds: item.duration, progress: item.progressPercent,
                    coverData: nil)
            }
            return WatchCollectionSummary(
                id: collection.id, name: collection.displayName,
                books: Array(books), bookCount: collection.bookCount)
        }
    }

    /// Fires background cover fetches for any of the given item ids not already
    /// cached, then re-pushes downloads/library once they land — capped so opening a
    /// long Downloads/Recently Added list doesn't fire dozens of concurrent requests.
    /// WATCH-3: fetches at `WatchCoverArt.listRowMaxDimension`, not the Now Playing
    /// card's larger size — see `loadCover`'s doc comment.
    ///
    /// P3-17 (third-pass review, 14 Aug 2026): this comment used to claim `listCoverCache`
    /// (written here) is "the cache actually read by `buildDownloadSummaries`/
    /// `buildRecentlyAddedSummaries`" — no longer true. The later WATCH-3 follow-up made
    /// both of those always pass `coverData: nil` (see their own doc comments), so
    /// neither one reads `listCoverCache` anymore. `primeCovers` — and every caller of
    /// it — is dead code as a result, left in place rather than deleted since removing
    /// it touches several interconnected pieces this pass can't verify against a real
    /// build; see the doc comment on this file's cover-priming section for the fuller
    /// accounting of what's now unreachable.
    private func primeCovers(for itemIds: [String]) {
        let uncached = itemIds.filter { listCoverCache[$0] == nil && !coversInFlight.contains("\($0)|\(Int(WatchCoverArt.listRowMaxDimension))") }
        guard !uncached.isEmpty else { return }
        for itemId in uncached.prefix(8) {
            Task {
                guard await self.loadCover(itemId: itemId, maxDimension: WatchCoverArt.listRowMaxDimension) != nil else { return }
                // NEW-11 (follow-up review, 14 Aug 2026): debounced, not called
                // directly — see `scheduleCoverTriggeredPush`'s doc comment for why
                // calling both push functions straight from here, once per landed
                // cover, sent up to 16 `transferUserInfo` payloads for one batch of
                // up to 8 concurrently-primed covers.
                self.scheduleCoverTriggeredPush()
            }
        }
    }

    /// NEW-11 (follow-up review, 14 Aug 2026): `primeCovers` above fires up to 8
    /// concurrent cover fetches, and each one landing is independently a reason to
    /// re-push downloads/library (a summary's `coverData` just became available).
    /// But `pushDownloadsIfNeeded`/`pushLibraryIfNeeded`'s own dedup hash includes
    /// `coverData != nil`, so EVERY landing cover changes that hash and forces a
    /// fresh `transferUserInfo` for both — calling them straight from each of the 8
    /// completions independently produced up to 16 payloads for one refresh batch.
    /// Debouncing collapses a burst of near-simultaneous completions into a single
    /// re-push after they settle, cancelling and rescheduling this same task on
    /// every new completion rather than letting each one fire its own.
    ///
    /// P3-17 (third-pass review, 14 Aug 2026): the scenario this comment describes no
    /// longer happens in practice. The later WATCH-3 follow-up made both dedup hashes'
    /// `coverData != nil` term a constant `false` (see their own comments) and made
    /// `primeCovers` itself dead code (nothing calls it anymore) — so no cover ever
    /// "lands" to trigger this path today. Left as an accurate historical record of why
    /// this debounce exists, not a claim that it's currently exercised; see
    /// `primeCovers`'s own doc comment for the fuller accounting.
    private var coverTriggeredPushTask: Task<Void, Never>?
    private func scheduleCoverTriggeredPush() {
        coverTriggeredPushTask?.cancel()
        coverTriggeredPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pushDownloadsIfNeeded()
            self.pushLibraryIfNeeded()
        }
    }

    // MARK: - Outbound: chapters / bookmarks (sent on request, not polled)

    /// WATCH-4 (REVIEW_2026-08-12.md): this used to read `playerViewModel.bookmarks`,
    /// which is only ever populated as a side effect of the PHONE's own bookmark sheet
    /// appearing (`PlayerView`'s sheet calls `loadBookmarks()`) — normally empty, so
    /// the Watch was actively pushed `bookmarks: []` on every book change regardless of
    /// what bookmarks actually existed for that book. Now fetches the real per-book
    /// list directly from the same API the phone's bookmark sheet itself calls
    /// (`AudiobookshelfAPI.getBookmarks(itemId:)`), keyed off the actual active item —
    /// independent of whether any phone UI happens to be open. Now `async` (a real
    /// network call) — every call site wraps it in `Task { await ... }`.
    private func pushBookAuxiliaryState() async {
        guard let player = playerViewModel else { return }
        let chapters = player.chapters.map {
            WatchChapterSummary(id: $0.id, title: $0.title, start: $0.start, end: $0.end)
        }
        var bookmarkSummaries: [WatchBookmarkSummary] = []
        if let itemId = AudioPlayerService.shared.currentItemId,
           let bookmarks = try? await AudiobookshelfAPI.shared.getBookmarks(itemId: itemId) {
            bookmarkSummaries = bookmarks.map {
                WatchBookmarkSummary(id: $0.id, title: $0.title, time: $0.time)
            }
        }
        guard let chapterData = try? JSONEncoder().encode(chapters),
              let bookmarkData = try? JSONEncoder().encode(bookmarkSummaries) else { return }
        // WATCH-3: `transferUserInfo`, not the merged `updateApplicationContext`.
        transferWatchUserInfo(["chapters": chapterData, "bookmarks": bookmarkData], label: "bookAuxiliaryState")
    }

    // MARK: - Inbound: commands from the Watch

    /// Applies a validated command. Returns a small reply describing success/failure so
    /// the Watch's optimistic UI can roll back on failure instead of assuming the phone
    /// applied it. `async` specifically so `.playItem` can await the real outcome of
    /// fetching the item and starting playback — this used to fire that work as a
    /// detached `Task` and return `["ok": true]` immediately regardless of what
    /// actually happened, so a failed item fetch (e.g. the item was deleted, or the
    /// request failed) reported success to the Watch anyway.
    private func handle(_ command: WatchPlaybackCommand) async -> [String: Any] {
        let player = AudioPlayerService.shared

        // WATCH-2: a Watch `sendMessage` relaunches the iOS app in the background if
        // it had been terminated. On that cold launch `player.currentItemId` is nil
        // until something restores a session, so `.playPause`/`.play` would otherwise
        // fail `WatchCommandValidator`'s `.noActiveItem` check every single time —
        // "press play on the Watch after the phone app was swiped away" is arguably
        // the single most likely thing a user does with a watch remote, and it was a
        // guaranteed silent no-op. `PlaybackCoordinator.toggleFromWidget()` already
        // solves exactly this for the widget's play button (restore the last-played
        // snapshot, or fall back to a server query for the most recent in-progress
        // book) — route through that same recovery path here instead of duplicating
        // it, rather than running the normal validate/apply path against a player
        // that has nothing loaded yet.
        if player.currentItemId == nil, command.kind == .playPause || command.kind == .play {
            // NEW-12 (follow-up review, 14 Aug 2026): this branch bypasses
            // `WatchCommandValidator.validate` below entirely — its `.noActiveItem`
            // check would otherwise always reject here, defeating the whole point
            // of this recovery path — but that also skipped the SCOPE check the
            // validator would normally enforce, so a stale command from a Watch
            // still showing a previous account's scope (before its next snapshot
            // corrects it) reported `["ok": true]` and actually toggled playback
            // against whatever account happens to be signed in on the phone right
            // now, always reporting success regardless. Checking scope alone here
            // (not the full validator, which would still reject on
            // `.noActiveItem`) closes that gap without reintroducing the bug this
            // branch exists to fix.
            guard let activeScope = currentScope, let commandScope = command.scope,
                  activeScope.matches(commandScope) else {
                lastPushedState = nil
                pushIfNeeded()
                return ["ok": false, "reason": String(describing: WatchCommandValidator.Failure.scopeMismatch)]
            }
            await PlaybackCoordinator.shared.toggleFromWidget()
            pushIfNeeded()
            await pushBookAuxiliaryState()
            return ["ok": true]
        }

        let result = WatchCommandValidator.validate(
            command,
            activeScope: currentScope,
            activeItemId: player.currentItemId,
            stateLastUpdated: lastPushedState?.lastUpdated
        )

        if case .failure(let reason) = result {
            // Fail safe: never apply a command whose scope/item/staleness doesn't check
            // out. Immediately push a fresh snapshot so the Watch can recover.
            //
            // WATCH-1: `pushIfNeeded()` alone doesn't actually push anything here in
            // the exact case this exists to recover from — a `.staleState` failure
            // means, by definition, nothing about the state has changed recently
            // (that's what "stale" means), so `isMeaningfulChange` is false and the
            // periodic-refresh window likely hasn't elapsed either; `pushIfNeeded()`
            // would just return without pushing, leaving the Watch stuck failing this
            // same command forever with no way to self-heal. Forcing `lastPushedState`
            // to `nil` first (the same trick `.requestSnapshot` already uses below)
            // makes the very next `pushIfNeeded()` push unconditionally.
            lastPushedState = nil
            pushIfNeeded()
            return ["ok": false, "reason": String(describing: reason)]
        }

        switch command.kind {
        case .playPause:
            player.togglePlayPause()
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .rewind(let seconds):
            player.skipBackward(seconds)
        case .forward(let seconds):
            player.skipForward(seconds)
        case .seek(let time):
            player.seek(to: time)
        case .seekToChapter(_, let startTime):
            player.seek(to: startTime)
        case .addBookmark:
            // WATCH-4: previously fired the add as an unawaited `Task` and fell
            // through to the generic `pushIfNeeded(); pushBookAuxiliaryState()` at the
            // bottom of this function — which ran (and replied to the Watch)
            // immediately, before the fire-and-forget add had actually completed on
            // the server. `pushBookAuxiliaryState()`'s bookmark fetch (see its doc
            // comment) could then win the race and push a list that doesn't include
            // the bookmark the user just added. Awaiting the add here, then the
            // auxiliary push, then returning directly (skipping the generic push at
            // the bottom) guarantees the Watch's bookmark list reflects the add before
            // this command's reply — and before it — ever reaches the Watch.
            await playerViewModel?.addBookmarkAtCurrentTime(note: nil)
            await pushBookAuxiliaryState()
            pushIfNeeded()
            return ["ok": true]
        case .seekToBookmark(let time):
            player.seek(to: time)
        case .setPlaybackSpeed(let rate):
            // Through the view model, not `player` directly (9 September 2026): the
            // service-level call applies whatever arrives verbatim, so a speed set from
            // the Watch skipped `PlayerViewModel.setPlaybackRate`'s 0.5–3.0 clamp, its
            // rounding to the nearest 0.05, and — the user-visible half — the per-book
            // speed write to `SettingsStore`. A speed chosen on the Watch therefore
            // didn't stick when the same book was reopened, unlike the identical change
            // made on the phone. Same shape as `.setSleepTimer` just below.
            playerViewModel?.setPlaybackRate(rate)
        case .setSleepTimer(let option):
            playerViewModel?.setSleepTimer(mapSleepOption(option))
        case .extendSleepTimer(let seconds):
            // Batch 490 (REVIEW 2026-11-11 F29): "Add 15 Minutes" from the Watch's Sleep
            // sheet. Through the view model so the phone's own rules apply (an
            // end-of-chapter timer becomes a countdown, no timer → no-op); the generic push
            // below sends the new remaining time back.
            playerViewModel?.extendSleepTimer(by: seconds)
        case .markFinished:
            // `AudioPlayerService.markCurrentBookFinished(source:)` is the explicit,
            // out-of-band completion path — it replaced an earlier seek-to-duration trick
            // that tried to reuse `moveToNextTrack`'s natural end-of-book handling by
            // faking the player's position. That trick was fragile (seeking to exactly
            // `duration` matches no track's `time < trackStart + trackDuration` window, so
            // it could silently no-op) and, being an indirect side effect of a seek, would
            // also have inherited natural completion's autoplay-to-next-item behaviour —
            // not what a user tapping "Mark as Finished" on the Watch is asking for. `.watch`
            // labels this call's origin for diagnostics; it deliberately does not autoplay.
            player.markCurrentBookFinished(source: .watch)
        case .markItemFinished(let itemId):
            let ok = await markFinished(itemId: itemId)
            pushIfNeeded()
            await pushBookAuxiliaryState()
            return ["ok": ok]
        case .playItem(let itemId):
            let started = await startPlayback(itemId: itemId)
            pushIfNeeded()
            await pushBookAuxiliaryState()
            return ["ok": started]
        case .requestSnapshot:
            // Force every payload kind to re-send unconditionally, even if nothing
            // actually changed since the last push — the Watch app was just opened
            // and shouldn't have to wait for a real change to get current data.
            lastPushedState = nil
            lastPushedDownloadsHash = nil
            lastPushedLibraryHash = nil
        }

        pushIfNeeded()
        await pushBookAuxiliaryState()
        return ["ok": true]
    }

    private func mapSleepOption(_ option: WatchSleepTimerOption) -> SleepTimerOption {
        switch option {
        case .off: return .off
        case .minutes(let m): return .minutes(m)
        case .endOfChapter: return .endOfChapter
        }
    }

    /// Batch 414: `.markItemFinished`. The book that is loaded goes through the player's own
    /// completion path, as `.markFinished` does (no autoplay). Any other book goes through
    /// `LibraryViewModel.markFinished(item:)`, the phone's Book Detail path, so the phone's
    /// shelves and its one-book Undo toast stay in step. The reply is the real outcome.
    private func markFinished(itemId: String) async -> Bool {
        if AudioPlayerService.shared.currentItemId == itemId {
            AudioPlayerService.shared.markCurrentBookFinished(source: .watch)
            return true
        }
        guard let library = libraryViewModel,
              let item = try? await AudiobookshelfAPI.shared.getItem(itemId: itemId) else { return false }
        return await library.markFinished(item: item)
    }

    /// Returns whether playback actually started, so `.playItem`'s reply to the Watch
    /// reflects reality instead of always claiming success.
    private func startPlayback(itemId: String) async -> Bool {
        guard let item = try? await AudiobookshelfAPI.shared.getItem(itemId: itemId) else { return false }
        await playerViewModel?.startPlayback(for: item, prefetched: nil, openPlayer: false)
        // Review 2 Low (Playback), 30 October 2026: report success only if the book is now loaded.
        // Review 3 Medium 5: a restored book is already `currentBook` before any start, so also require a live
        // session (an early return in `startPlayback` leaves it awaiting resume).
        guard let player = playerViewModel else { return false }
        return player.currentBook?.id == item.id && !player.isAwaitingResume
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            guard activationState == .activated else { return }
            self.refreshPollingState()
            self.pushIfNeeded()
        }
    }

    /// Bug fix (26 August 2026): the console reported "delegate
    /// ShelfHead.WatchSessionManager does not implement
    /// session:didReceiveApplicationContext:" — this optional `WCSessionDelegate`
    /// requirement was simply never implemented on the phone side. Every actual
    /// phone->Watch push in this app is outgoing (`send(_:)` below calls
    /// `WCSession.default.updateApplicationContext(...)`, one-directional); nothing in
    /// this codebase currently has the Watch call `updateApplicationContext` back
    /// toward the phone, so no known feature is silently losing data today. Still a
    /// real gap worth closing rather than leaving unimplemented: application context
    /// delivery is genuinely bidirectional at the framework level (the system can
    /// still attempt to hand this session a context — e.g. a stale one queued from a
    /// prior run/pairing exchange — independent of what this specific build's code
    /// happens to call), and a missing delegate method means any such delivery is
    /// just dropped with a console warning instead of being observably handled.
    /// Logged only, not parsed into `apply(context:)` — that parser expects the
    /// phone's own outgoing shape (`["playbackState": Data]`), not anything a Watch
    /// -originated context would contain, and no such format exists anywhere in this
    /// codebase to parse.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ShelfLog.info(.watch, "Received unexpected application context from Watch: keys=\(applicationContext.keys.sorted())")
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Fires when the Watch pairing/app-installed state changes at runtime (pairing a
    /// new Watch, installing/deleting the Watch app) — re-evaluates whether the poll
    /// timer should be running rather than leaving it on for a Watch that just got
    /// unpaired, or leaving it off after one gets paired mid-session.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshPollingState()
            if self.hasReachableWatchApp { self.pushIfNeeded() }
        }
    }

    /// Immediate, ack'd commands from the Watch (play/pause/seek/etc.), plus — as of
    /// Stage 2 of the standalone Watch app — the credential-handoff request. Both
    /// share this one entry point because `WCSessionDelegate` only allows one
    /// `didReceiveMessage:replyHandler:` implementation per session; dispatch is by
    /// which top-level key the message carries (`"command"` vs. `"type"`).
    /// Batch 471 (review 30 Oct 2026, High 3): a Watch `sendMessage` can wake a phone app
    /// that has no UI yet, and only `ContentView`'s `.task` restores the session. Without
    /// this, `AuthStore` was empty on that path, so a handoff request answered
    /// `notSignedIn` and a cold Play failed the scope check. Same Keychain seed CarPlay,
    /// Siri and background refresh use; a no-op once the session is configured.
    private static func restoreSessionIfNeeded() async {
        await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
        await MainActor.run { DownloadManager.shared.reloadIfScopeChanged() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Build-fix (Stage 3, third round on this exact issue — 28 August 2026):
        // `replyHandler` is a plain, non-`@Sendable`-annotated closure (`WCSessionDelegate`'s
        // own protocol signature, unchanged by `@preconcurrency import WatchConnectivity`
        // above), so capturing it into a `Task { @MainActor in ... }` closure — itself
        // required to be `@Sendable` — is rejected under Swift 6 no matter how the
        // capturing closure's body is internally structured. The previous two rounds
        // each "fixed" one occurrence (line 971, then 983) only for the *next*
        // occurrence in this same function to surface on the following build — in
        // hindsight, strong evidence the compiler was masking the remaining instances
        // of one root cause behind whichever error it reported first, not that each
        // fix was independently incomplete. Fixing the actual root cause once, for
        // every call site in this function, rather than waiting for a fourth round:
        // `WCSessionDelegate`'s `replyHandler` is documented safe to invoke from any
        // thread (that's the entire point of a completion-handler-style reply) — the
        // compiler has no way to verify that from its plain, unannotated closure type.
        // `nonisolated(unsafe)` on a local binding is the correct tool for precisely
        // this situation: it tells the concurrency checker this one, specific capture
        // is known-safe, without disabling checking anywhere else in this file.
        // Shadows the parameter of the same name so every existing call site below is
        // unchanged.
        nonisolated(unsafe) let replyHandler = replyHandler

        if message["type"] as? String == "requestCredentialHandoff" {
            Task { @MainActor in
                await Self.restoreSessionIfNeeded()
                replyHandler(await self.buildCredentialHandoffReply())
            }
            return
        }
        guard let data = message["command"] as? Data,
              let command = try? JSONDecoder().decode(WatchPlaybackCommand.self, from: data) else {
            replyHandler(["ok": false, "reason": "malformed"])
            return
        }
        Task { @MainActor in
            await Self.restoreSessionIfNeeded()
            let reply = await self.handle(command)
            replyHandler(reply)
        }
    }

    /// Stage 2 (standalone Watch app, addendum §2.1 Option A / §3): replies to the
    /// Watch's `"requestCredentialHandoff"` message with the current account's
    /// server URL + tokens, so the Watch can hold and renew its own session without
    /// the phone present. Deliberately hands off the **refresh token, not the
    /// plaintext password** — per §3's threat model, the Watch never receives or
    /// stores the password at all. Uses `sendMessage`, not `transferUserInfo`
    /// (item 1 of the Stage 2 build instructions): a credential handoff is by
    /// definition an interactive operation with both devices reachable right now —
    /// it has no legitimate use for `transferUserInfo`'s store-and-forward queue,
    /// which (per §3) the OS persists outside this app's process for an
    /// unpublished duration with no confirmed at-rest Data Protection class. If the
    /// Watch isn't reachable, `sendMessage` simply never gets called (the Watch
    /// itself checks `isReachable` before sending — see `WatchStore.
    /// requestHandoffFromPhone()`), which is the correct "try again with your
    /// iPhone nearby" outcome rather than a token sitting in a queue for however
    /// long that takes.
    ///
    /// No token appears in any log statement here or anywhere else on this path —
    /// see this stage's `CHANGES_IMPLEMENTED.md` entry for the explicit
    /// no-credential-logging audit.
    ///
    /// Real on-device bug fix (29 August 2026): this used to snapshot whatever was
    /// already sitting in `AuthStore` with no validity check. Audiobookshelf's
    /// refresh tokens are rotating/single-use, and `performTokenRefreshOrReauth()`'s
    /// own doc comment (`AudiobookshelfAPI.swift`) documents the known "lost
    /// rotation" failure mode where a token this app is holding has already been
    /// superseded server-side — invisible on the phone, since a 401 there silently
    /// falls back to a full password re-login (`reauthenticateWithStoredCredentials()`),
    /// but the Watch deliberately has no such fallback (it's never given the
    /// plaintext password, per this file's own doc comment above). A user who did a
    /// completely fresh handoff, then immediately switched to Always Standalone,
    /// still hit "Your session has expired" on the very first request — the
    /// handed-off token was fresh only in the sense of "just read out of memory,"
    /// not "just confirmed live." Forcing a refresh (with its own reauth fallback)
    /// right before building the reply means the Watch always receives a token this
    /// device has just confirmed actually works, closing that race.
    ///
    /// **Item 10 (10 September 2026) — the two devices no longer share one session.**
    /// The 29 August fix above closed the "handed-off token was already stale" race,
    /// but not the deeper one it was a symptom of: the phone handed over its *own*
    /// access **and refresh** token and then kept using the same pair. Refresh tokens
    /// rotate and are single-use per session, so the first device to refresh
    /// invalidated the other's — the phone silently recovered via a password
    /// re-login, the Watch (which by design never gets the password) hit "Your
    /// session has expired" through no fault of the user. Fixed by giving the Watch
    /// a session of its own, in preference order:
    ///
    /// 1. **Dedicated** — a fresh `POST /login` for this account
    ///    (`AudiobookshelfAPI.mintDedicatedSession()`), possible whenever a password
    ///    is stored on this device. The Watch gets that new session's access +
    ///    refresh pair; this device's own pair is never touched, so neither device
    ///    can rotate the other out. Note this branch deliberately *skips* the forced
    ///    refresh below: `/login` is unauthenticated, so nothing here needs this
    ///    device's access token to be fresh, and not refreshing means a handoff no
    ///    longer rotates the phone's own chain as a side effect.
    /// 2. **Durable** — the legacy, non-rotating API token
    ///    (`User.token`, still returned by servers for backwards compatibility).
    ///    Judged an acceptable second preference precisely because it does *not*
    ///    rotate: sharing it cannot break the phone's chain, and unlike an access
    ///    token it doesn't expire out from under a Watch that's away from its phone
    ///    for a week. The cost is that it's long-lived — which is why it's second,
    ///    not first, and why it's only used when there's no password to mint a real
    ///    session with. It's revocable the same way it always was (rotating the
    ///    user's token server-side), and it lands in the Watch's Keychain under the
    ///    same protection class as every other credential there.
    /// 3. **Shared access token, never the refresh token** — SSO/OIDC accounts, no
    ///    stored password, no legacy token. The Watch gets a working access token and
    ///    no ability to rotate anything, so the phone's chain is safe by
    ///    construction. The Watch is told (`sessionKind`) so it can ask for a fresh
    ///    handoff when that token expires instead of showing a dead end.
    ///
    /// **Wire compatibility:** the four keys an older Watch build reads (`ok`,
    /// `serverURL`, `accessToken`, `refreshToken`, `customHeaders`) keep their exact
    /// previous meanings; `sessionKind` and `handoffVersion` are additive. An older
    /// Watch paired with this build gets a dedicated pair (strictly better than
    /// before) or an access token with no refresh token — the same shape it already
    /// handles for a pre-2.26 server.
    ///
    /// **This is the only place the phone ever sends a credential to the Watch.**
    /// Audited 10 September 2026 for item 10's "check every place the phone sends
    /// credentials, not only the explicit handoff request": the periodic
    /// `updateApplicationContext` push carries a `WatchPlaybackState` whose
    /// `WatchAccountScope` holds a server URL and an account id and no token at all,
    /// and every `transferUserInfo` payload is book/library/download data or the
    /// tokenless `wipeCredentials` signal. So a Watch that has rotated its own
    /// dedicated pair can never be overwritten by a routine state push.
    @MainActor
    private func buildCredentialHandoffReply() async -> [String: Any] {
        guard AuthStore.shared.isConfigured else {
            return ["ok": false, "reason": "notSignedIn"]
        }
        let api = AudiobookshelfAPI.shared

        // Preference 1 — mint a session that belongs to the Watch alone.
        let preferred = Self.handoffCredentialPlan(
            hasStoredPassword: await api.hasStoredLoginPassword(),
            legacyToken: nil,
            accessToken: AuthStore.shared.accessToken,
            refreshToken: AuthStore.shared.refreshToken)
        if preferred == .dedicatedLogin, let minted = await api.mintDedicatedSession() {
            var reply = Self.baseHandoffReply()
            reply["accessToken"] = minted.accessToken
            if let refresh = minted.refreshToken, !refresh.isEmpty {
                reply["refreshToken"] = refresh
                reply["sessionKind"] = WatchHandoffSessionKind.dedicated.rawValue
            } else {
                // A server that issues no refresh token issued the permanent user
                // token instead — durable rather than exclusive, and the Watch is
                // told so rather than being left to infer it from a missing key.
                reply["sessionKind"] = WatchHandoffSessionKind.durable.rawValue
            }
            return reply
        }

        // Preferences 2 and 3 — nothing exclusive is available, so whatever we do hand
        // over has to at least be confirmed live (the 29 August fix, above).
        await api.ensureFreshAccessToken(force: true)
        guard AuthStore.shared.isConfigured else {
            // The force-refresh above can itself fail all the way through
            // (refresh AND password reauth both rejected) and sign this device
            // out — re-check rather than handing off a token that no longer exists.
            return ["ok": false, "reason": "notSignedIn"]
        }
        let accessToken = AuthStore.shared.accessToken
        let fallback = Self.handoffCredentialPlan(
            hasStoredPassword: false,
            legacyToken: await api.currentLegacyAPIToken(),
            accessToken: accessToken,
            refreshToken: AuthStore.shared.refreshToken)

        var reply = Self.baseHandoffReply()
        switch fallback {
        case .dedicatedLogin:
            // Unreachable — `hasStoredPassword: false` can't produce this case. Handled
            // as the safest option rather than with a `fatalError` on a path whose only
            // job is to keep a Watch listening.
            reply["accessToken"] = accessToken
            reply["sessionKind"] = WatchHandoffSessionKind.shared.rawValue
        case .legacyAPIToken(let token):
            reply["accessToken"] = token
            reply["sessionKind"] = WatchHandoffSessionKind.durable.rawValue
        case .sharedAccessTokenOnly(let isDurable):
            reply["accessToken"] = accessToken
            reply["sessionKind"] = isDurable
                ? WatchHandoffSessionKind.durable.rawValue
                : WatchHandoffSessionKind.shared.rawValue
        }
        // No `refreshToken` key on either of these paths — that is the whole point of
        // preferences 2 and 3: the Watch can't break a rotation chain it was never
        // given a link to.
        return reply
    }

    /// The parts of a successful handoff reply that don't depend on which credential
    /// was chosen. Split out so the three success paths above can't drift on the
    /// server URL, the proxy headers, or the version marker.
    @MainActor
    private static func baseHandoffReply() -> [String: Any] {
        var reply: [String: Any] = [
            "ok": true,
            "serverURL": AuthStore.shared.serverURL,
            // Additive: lets a future Watch build tell "this phone knows about session
            // kinds" from "this phone predates them and a missing `sessionKind` has to
            // be inferred." See `WatchStore.handoffSessionKind(fromReply:refreshToken:)`.
            "handoffVersion": 2,
        ]
        if !AuthStore.shared.customHeaders.isEmpty {
            reply["customHeaders"] = AuthStore.shared.customHeaders
        }
        return reply
    }

    /// Which credential the Watch should be handed — the pure decision behind
    /// `buildCredentialHandoffReply()`, extracted so the preference order can be
    /// pinned by `ShelfHeadTests` rather than only exercised on a paired device.
    ///
    /// `refreshToken` is taken and deliberately never used. That is the point: the
    /// decision *sees* the phone's refresh token and still never returns a plan that
    /// hands it over, and `WatchHandoffCredentialPlanTests` pins exactly that. The
    /// only refresh token that may ever reach the Watch comes from a session the
    /// phone minted *for* it (`AudiobookshelfAPI.mintDedicatedSession()`), which this
    /// function never sees because it doesn't exist yet when the decision is made.
    ///
    /// The legacy-token gate ("non-empty **and** distinct from the access token") is
    /// what keeps `.legacyAPIToken` meaningful. On a pre-2.26 server `User
    /// .effectiveAccessToken` *is* `User.token`, so the two are the same string and
    /// there is nothing to prefer — but that same equality is proof the credential
    /// doesn't rotate, which is why the fallback carries `isDurable: true` there
    /// instead of collapsing into the ordinary shared case. The Watch uses that to
    /// pick its copy: a durable credential never needs the phone brought nearby.
    nonisolated static func handoffCredentialPlan(
        hasStoredPassword: Bool,
        legacyToken: String?,
        accessToken: String,
        refreshToken: String?
    ) -> WatchHandoffCredentialPlan {
        if hasStoredPassword { return .dedicatedLogin }
        if let legacy = legacyToken, !legacy.isEmpty {
            // Defensive, integration fix: a "legacy" token that is byte-identical to the
            // phone's *refresh* token cannot be the non-rotating API token — whatever it
            // is, handing it over would reshare the rotating credential this whole
            // decision exists to protect. Treat it as absent and fall through to the
            // plain shared case. (No known server produces this shape; the guard exists
            // so the invariant "no plan ever carries `refreshToken`" holds by
            // construction rather than by assumption.)
            if let refreshToken, legacy == refreshToken {
                return .sharedAccessTokenOnly(isDurable: false)
            }
            if legacy != accessToken { return .legacyAPIToken(legacy) }
            return .sharedAccessTokenOnly(isDurable: true)
        }
        return .sharedAccessTokenOnly(isDurable: false)
    }

    /// WATCH-3: `transferUserInfo` doesn't throw synchronously (unlike
    /// `updateApplicationContext` in `send(_:)`) — a delivery failure, including
    /// `payloadTooLarge`, only ever surfaces here, asynchronously, after the fact. This
    /// used to not exist at all, so a failed downloads/library/bookAuxiliaryState
    /// transfer had zero diagnostic trail. A `payloadTooLarge` failure retries once
    /// (see P3-5's doc comment just below on why it's now capped at one retry per push
    /// cycle), rather than leaving that payload kind stuck failing on every future push
    /// too.
    ///
    /// P3-17 (third-pass review, 14 Aug 2026): this used to say the retry strips
    /// `coverData` for "the two kinds known to carry cover art" ("downloads",
    /// "recentlyAdded") — accurate when written, but the later WATCH-3 follow-up made
    /// both of those always pass `coverData: nil` already (see their own build
    /// functions' doc comments), so the strip below is now a no-op for both: it still
    /// runs (harmless), but it can no longer be what makes a retried payload smaller.
    /// A retry can still succeed if the ORIGINAL failure was itself transient (a
    /// momentary size spike, a connectivity hiccup reported as `payloadTooLarge`), just
    /// not because of anything this code strips out anymore.
    // Real build error: the SDK this project is building against exposes this
    // `WCSessionDelegate` requirement with the external label `didFinish`, not
    // `didFinishUserInfoTransfer` (the underlying Objective-C selector is still
    // `session:didFinishUserInfoTransfer:error:` — only the Swift-facing parameter
    // label changed). Renamed to match; the parameter's local name (`userInfoTransfer`,
    // used throughout the body below) is unchanged.
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
        guard let error else { return }
        ShelfLog.error(.watch, "Watch transferUserInfo failed: \(error.localizedDescription)")
        guard let wcError = error as? WCError, wcError.code == .payloadTooLarge else { return }
        // CRIT-3 follow-up (this pass, 15 Aug 2026): `userInfoTransfer.userInfo` is
        // `[String: Any]`, which isn't `Sendable` (`Any` can hold anything, including
        // non-Sendable types) — capturing the whole dictionary into the `Task {
        // @MainActor in ... }` below was flagged as an error. Every branch only ever
        // reads one specific key back out as `Data`, so pulling those three `Data?`
        // values out HERE (synchronously, before the `Task` exists) and capturing only
        // those — `Data` is a genuinely `Sendable` value type — avoids capturing the
        // non-Sendable dictionary at all.
        let downloadsData = userInfoTransfer.userInfo["downloads"] as? Data
        let recentlyAddedData = userInfoTransfer.userInfo["recentlyAdded"] as? Data
        let collectionsData = userInfoTransfer.userInfo["collections"] as? Data
        Task { @MainActor in
            // P3-5: each branch below retries a given key at most once per push cycle —
            // without this, a transfer whose retry is itself still too large (or, for
            // "collections", byte-for-byte identical since it never carried cover data
            // to strip) gets decoded by this same handler again and re-sent forever.
            if let data = downloadsData,
               !self.retriedTransferKeys.contains("downloads"),
               var summaries = try? JSONDecoder().decode([WatchDownloadSummary].self, from: data) {
                self.retriedTransferKeys.insert("downloads")
                for i in summaries.indices { summaries[i].coverData = nil }
                if let stripped = try? JSONEncoder().encode(summaries) {
                    WCSession.default.transferUserInfo(["downloads": stripped])
                }
            }
            if let data = recentlyAddedData,
               !self.retriedTransferKeys.contains("recentlyAdded"),
               var summaries = try? JSONDecoder().decode([WatchBookSummary].self, from: data) {
                self.retriedTransferKeys.insert("recentlyAdded")
                for i in summaries.indices { summaries[i].coverData = nil }
                if let stripped = try? JSONEncoder().encode(summaries) {
                    WCSession.default.transferUserInfo(["recentlyAdded": stripped])
                }
            }
            // NEW-7 (follow-up review, 14 Aug 2026): `collections` is sent in the SAME
            // transfer as `recentlyAdded` (see `pushLibraryIfNeeded`'s
            // `transferWatchUserInfo(["recentlyAdded": ..., "collections": ...])`), but
            // the retry above only ever re-sent "recentlyAdded" — on the stated
            // assumption that "collections" "can't have been what tipped this transfer
            // over the limit" since its entries never carry cover data
            // (`buildCollectionSummaries` always passes `coverData: nil`). That
            // reasoning only shows collections isn't the CAUSE of the overflow; it
            // doesn't follow that collections should be silently dropped from the
            // retry — with `collectionsCap = 15` collections × `collectionBookCap = 30`
            // books each (`WatchModels.swift`), that's up to 450 `WatchBookSummary`
            // rows omitted, permanently (nothing else ever retries this specific
            // failed transfer). Retried here as its own independent transfer — not
            // re-bundled with `recentlyAdded` — so one half failing again (still too
            // large even after stripping covers) can't take the other down with it. No
            // stripping needed since collections never carry cover data to begin with.
            if let collectionsData,
               !self.retriedTransferKeys.contains("collections") {
                self.retriedTransferKeys.insert("collections")
                WCSession.default.transferUserInfo(["collections": collectionsData])
            }
        }
    }
}
