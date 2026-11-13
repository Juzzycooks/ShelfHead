import Foundation
// Stage 2 (standalone Watch app): needed for `WCSession.default.sendMessage` in
// `requestHandoffFromPhone()` below. `@preconcurrency` matches
// `WatchConnectivityStore.swift`'s own import — same reason: `WCSession`/its
// related types predate Swift's concurrency checking and aren't `Sendable` in this
// SDK.
@preconcurrency import WatchConnectivity

// MARK: - Concrete store facade (Stage 2 prototype)

/// Concrete facade over the Watch app's two data sources — the existing
/// WatchConnectivity-relay store (`WatchConnectivityStore`, companion mode) and a
/// future standalone store backed by `WatchAudiobookshelfAPI` (`WatchStandaloneStore`,
/// not built yet — see the note on `mode` below). See
/// `WATCH_STANDALONE_PROPOSAL_2026-08-28-ADDENDUM.md` §7.1/§8.1 for the design this
/// implements and why.
///
/// **Why a concrete class instead of a protocol existential:** `@Observable`'s macro
/// expansion generates its access-tracking (the per-property `access()`/
/// `withMutation()` calls SwiftUI's view-diffing depends on) on the concrete type the
/// macro is attached to. Erasing that concrete type behind `any SomeStoreProtocol` in
/// `@Environment` — the shape originally proposed in §7.1 — raises a real question
/// about whether SwiftUI's environment machinery reliably sees through the existential
/// to that tracking, and the failure mode if it doesn't is intermittent stale UI, not a
/// build error: exactly the kind of bug that's easy to miss in a quick manual test and
/// expensive to discover after all thirteen dependent files have already been
/// re-pointed at the pattern. `WatchStore` sidesteps the question entirely: it's a
/// single concrete `@Observable final class`, so every file's `@Environment(...)`
/// declaration stays concrete, and forwarding a read through to `companion`'s own
/// tracked stored properties (see the read surface below) still triggers `companion`'s
/// own Observation registrar during a SwiftUI view body's evaluation — the same
/// mechanism that already makes reading a nested `@Observable` object's property from
/// a computed property work correctly elsewhere in Swift's Observation framework. No
/// existential, no open question.
///
/// **Prototype scope (this file, this batch):** only `WatchSettingsView` has been
/// re-pointed from `@Environment(WatchConnectivityStore.self)` to
/// `@Environment(WatchStore.self)` — it's read-only and touches the smallest slice of
/// the surface below (`playbackState`, `isReachable`, `isStateStale`), making it the
/// cheapest possible proof that a concrete facade behaves correctly in a real,
/// running screen before the other twelve files (per §7.1's per-screen fate table) get
/// re-pointed the same way. The other twelve are deliberately untouched in this batch.
///
/// **`mode` and `WatchStandaloneStore` are not real yet.** `mode` exists so the shape
/// is right when standalone mode does exist, but it's hardcoded to `.companion` below
/// — there is no `WatchStandaloneStore` type in the project yet, and building one
/// speculatively, before the WatchConnectivity credential handoff and manual-entry
/// recovery it would depend on exist, would mean designing its interface against
/// nothing real to call. That's the rest of Stage 2, not this prototype step.
/// `WatchConnectivityStore`'s own optimistic-send-with-rollback internals are
/// completely untouched here — `WatchStore` calls into it, it isn't reshaped to fit.
@MainActor
@Observable
final class WatchStore {
    static let shared = WatchStore(companion: .shared)

    /// Which backend currently answers the read/write surface below for playback
    /// purposes. `companion` reads/writes through `WatchConnectivityStore` (phone
    /// relay); `standalone` means this Watch is running its own audio engine
    /// (`StandaloneAudioEngine`) with no phone involved. This governs only the
    /// playback surface, not the full 15-property/12-command companion surface above
    /// — those still forward to `companion` unconditionally (§10.2's "parallel screen,
    /// not a facade merge" decision: only the new standalone-playback screen reads
    /// `standalone`/`mode` directly, the existing 12 screens are untouched by this).
    enum Mode: Equatable {
        case companion
        case standalone
    }

    /// User-facing mode override (real on-device bug report, 28 August 2026):
    /// `resolveMode()`'s original logic — standalone only when the phone is
    /// unreachable — meant there was no code path to reach `StandaloneLibraryView`
    /// (the only call site for `WatchLocalDownloadManager.startDownload`) or play
    /// locally at all whenever a phone was nearby, even for someone who explicitly
    /// wants this Watch to behave standalone. Both reported symptoms ("can't
    /// download," "playback hands off to the phone") were the same one gate, not
    /// two bugs. `.automatic` preserves the original behavior exactly; the other
    /// two cases are new escape hatches.
    enum ModePreference: String, Codable, CaseIterable, Equatable {
        case automatic
        case alwaysCompanion
        case alwaysStandalone

        // Critique 2026-10-06 (shape → harden): user copy no longer says "Companion" or
        // "Standalone" (the critique's Jordan persona: "Watch Mode / Companion /
        // Standalone" is architecture, not a choice anyone recognises). The setting is
        // "Play On", in Settings, with the raw values unchanged so saved choices carry over.
        var title: String {
            switch self {
            case .automatic: return String(localized: "Automatic", comment: "Play On setting option: choose automatically")
            case .alwaysCompanion: return String(localized: "iPhone", comment: "Play On setting option")
            case .alwaysStandalone: return String(localized: "This Watch", comment: "Play On setting option")
            }
        }

        var subtitle: String {
            switch self {
            case .automatic: return String(localized: "Controls your iPhone when it\u{2019}s nearby, plays on this Watch when it isn\u{2019}t")
            case .alwaysCompanion: return String(localized: "Always controls what\u{2019}s playing on your iPhone")
            case .alwaysStandalone: return String(localized: "Always plays and downloads on this Watch")
            }
        }
    }

    private static let modePreferenceDefaultsKey = "watchStore.modePreference"

    /// Stored, `@Observable`-tracked, backed by `UserDefaults.standard` — same
    /// discipline as `authState`/`mode` themselves and for the identical reason
    /// (an untracked defaults read means views relying on it don't reliably
    /// re-render). Not a `static var`: this is genuinely per-instance state that
    /// has to participate in Observation the same way every other piece of
    /// `WatchStore`'s surface does. Loaded once in `init`, written by
    /// `setModePreference(_:)` — never mutated directly, so every write also runs
    /// through `resolveMode()`'s own `shouldDeferModeChange(...)` guard rather than
    /// bypassing it.
    private(set) var modePreference: ModePreference

    private(set) var mode: Mode = .companion

    /// Stored, `@Observable`-tracked — not computed from `companion.isReachable` or
    /// `authState` on read. Same reasoning as `authState` itself (Batch 250): an
    /// untracked mode flag means views relying on it re-render intermittently rather
    /// than reliably, which is a much worse bug to chase than a build error. Set only
    /// by `resolveMode()`, which is itself only ever called from natural checkpoints
    /// (launch, reachability change, foregrounding) — never mid-playback, per the
    /// original proposal's §2.7 recommendation.
    private let companion: WatchConnectivityStore
    let standalone: StandaloneAudioEngine
    /// Stage 4: kept as its own type rather than folded into `WatchStore` itself —
    /// library-browsing state (paging, search, selected library) is a genuinely
    /// separate concern from playback (`standalone`) and auth (this class's own auth
    /// section below), and cramming all three into one class would make `WatchStore`
    /// the single file that has to know about everything, the same trade-off its own
    /// type doc comment already accepted once for the mode-dispatch job, not a reason
    /// to keep piling more onto it.
    private(set) var library: WatchStandaloneLibraryStore
    /// Stage 5: this Watch's own local download manager (background `URLSession`,
    /// storage-capped cache, integrity check — see that type's own doc comment).
    /// Named `localDownloads`, not `downloads` — that name is already taken by the
    /// existing companion-mirror read-surface property just below (`[WatchDownloadSummary]`,
    /// forwarded from `companion`), which stays untouched: this is a genuinely
    /// separate, standalone-only concern, not a replacement for it.
    let localDownloads: WatchLocalDownloadManager
    /// Stage 6: this Watch's own progress-write path (`syncSession`/`closeSession`
    /// for a live streamed session, direct `updateProgress` writes — queued through
    /// `WatchPendingProgressQueue` when offline — for a Stage 5 local download,
    /// which never has a session to sync at all). See that type's own doc comment
    /// for the conflict heuristic this adds now that the Watch is a genuine third
    /// writer, not just a reader.
    let progressSync: WatchProgressSyncCoordinator

    // No default value on `companion` (build fix, 28 August 2026): a default
    // *parameter* value is evaluated as if `nonisolated`, regardless of the enclosing
    // initializer's own actor isolation — Swift treats default arguments as
    // conceptually inlined at each call site, so they can't rely on the function
    // they're attached to being `@MainActor`. `WatchConnectivityStore.shared` is
    // `@MainActor`-isolated, so it couldn't be referenced as a default value here even
    // though this `init` itself is `@MainActor` (inherited from the class). The
    // static property initializer above doesn't have this restriction — `static let
    // shared = WatchStore(companion: .shared)` runs in this MainActor type's own
    // isolation, the same reason `WatchConnectivityStore.shared = WatchConnectivityStore()`
    // itself compiles fine — so passing the argument explicitly there, rather than
    // defaulting it here, sidesteps the rule entirely. This `init` has exactly one call
    // site (the static property above), so losing the default costs nothing.
    private init(companion: WatchConnectivityStore) {
        self.companion = companion
        self.modePreference = ModePreference(rawValue: UserDefaults.standard.string(forKey: Self.modePreferenceDefaultsKey) ?? "") ?? .automatic
        // `progressSync` constructed before `standalone` (build order, not just
        // declaration order): `StandaloneAudioEngine` takes it as an init
        // dependency (Stage 6 — see that type's own doc comment) rather than
        // reaching back through a stored `WatchStore` reference, so it has to
        // already exist by the time `standalone`'s initializer runs.
        self.progressSync = WatchProgressSyncCoordinator(api: WatchAudiobookshelfAPI.shared)
        self.standalone = StandaloneAudioEngine(api: WatchAudiobookshelfAPI.shared, progressSync: self.progressSync)
        self.library = WatchStandaloneLibraryStore(api: WatchAudiobookshelfAPI.shared)
        self.localDownloads = WatchLocalDownloadManager.shared
    }

    // MARK: - Read surface (§7.1's 15-property enumeration, forwarded to `companion`
    // for now — each of these is a computed property, not a stored duplicate, so there
    // is nothing here that can drift out of sync with `companion`'s own state, and
    // reading one during a SwiftUI view body's evaluation still registers a real
    // Observation dependency on `companion`'s underlying stored property, not on
    // `WatchStore` itself — see the type doc comment for why that's sufficient.)

    var playbackState: WatchPlaybackState? { companion.playbackState }
    var chapters: [WatchChapterSummary] { companion.chapters }
    var bookmarks: [WatchBookmarkSummary] { companion.bookmarks }
    var downloads: [WatchDownloadSummary] { companion.downloads }
    var recentlyAdded: [WatchBookSummary] { companion.recentlyAdded }
    var collections: [WatchCollectionSummary] { companion.collections }
    var isActivated: Bool { companion.isActivated }
    var isReachable: Bool { companion.isReachable }
    var hasReceivedAnySnapshot: Bool { companion.hasReceivedAnySnapshot }
    var lastCommandFailed: String? { companion.lastCommandFailed }
    var phoneUnreachableNotice: Bool { companion.phoneUnreachableNotice }
    var currentScope: WatchAccountScope? { companion.currentScope }
    var isStateStale: Bool { companion.isStateStale }
    var estimatedCurrentTime: Double { companion.estimatedCurrentTime }
    var estimatedProgress: Double { companion.estimatedProgress }
    var tick: Int { companion.tick }

    // MARK: - Command surface (§7.1's 12-command enumeration, forwarded to `companion`)

    func togglePlayPause() { companion.togglePlayPause() }
    func rewind(_ seconds: Double? = nil) { companion.rewind(seconds) }
    func forward(_ seconds: Double? = nil) { companion.forward(seconds) }
    func seek(to time: Double) { companion.seek(to: time) }
    func seekToChapter(_ chapter: WatchChapterSummary) { companion.seekToChapter(chapter) }
    func seekToBookmark(_ bookmark: WatchBookmarkSummary) { companion.seekToBookmark(bookmark) }
    func addBookmarkAtCurrentPosition(completion: @escaping (Bool) -> Void = { _ in }) {
        companion.addBookmarkAtCurrentPosition(completion: completion)
    }
    func cyclePlaybackSpeed() { companion.cyclePlaybackSpeed() }
    func setSleepTimer(_ option: WatchSleepTimerOption) { companion.setSleepTimer(option) }
    func markFinished() { companion.markFinished() }
    /// Batch 413: marks any book finished with this Watch's own session (Book Details), then
    /// reloads In Progress so the Shelf and Library drop it.
    func markFinishedOnServer(itemId: String) async throws {
        try await WatchStandaloneCall.perform { try await api.markFinished(itemId: itemId) }
        await library.loadInProgress()
    }
    func playItem(itemId: String) { companion.playItem(itemId: itemId) }
    func dismissCommandFailure() { companion.dismissCommandFailure() }

    // MARK: - Auth (Stage 2, standalone Watch app)

    // Everything below is genuinely new state — not a forwarding wrapper over
    // `companion` like the read/write surface above. `WatchConnectivityStore` has
    // no concept of an HTTP session/token; this is `WatchAudiobookshelfAPI`'s
    // domain, orthogonal to companion-vs-standalone `mode` (even in companion mode,
    // *this* Watch app instance still needs to track whether it holds a usable
    // on-Watch session, e.g. to react to a phone-side sign-out). Deliberately
    // implemented as real, `@Observable`-tracked *stored* properties, not values
    // computed from `AuthStore`/`WatchAudiobookshelfAPI` on read: `AuthStore` is a
    // plain `nonisolated` class synchronized with `NSLock`, not `@Observable` —
    // reading it inside a computed property here would give the right answer at
    // the moment of the read, but would never itself trigger a SwiftUI view to
    // re-render when the underlying value changes later, since nothing would tell
    // the Observation system a dependency changed. Every method below that changes
    // auth state sets these properties explicitly instead, so views reading them
    // update correctly.

    /// One `WatchAuthFailureReason` per distinct cause — mirrors
    /// `WatchConnectivityStore.failureMessage(for:)`'s existing convention (a
    /// specific string per specific cause, not one generic message), per Stage 2's
    /// build instructions (item 7).
    enum WatchAuthFailureReason: Equatable {
        case notReachable
        case phoneNotSignedIn
        case sessionExpired
        case invalidCredentials
        /// The typed server address isn't usable as a server base address — see
        /// `ServerURLRules.normalizedServerURL(_:)` for what's rejected and why.
        case invalidServerURL
        /// Plain HTTP to a non-local host, not yet acknowledged by the user.
        case insecureConnectionNotAcknowledged
        /// Item 10 (10 September 2026): this Watch is running on a *shared* access
        /// token — the phone couldn't mint it a session of its own (an SSO/OIDC
        /// account, or no stored password), so it was handed an access token with no
        /// refresh token deliberately, to keep it from breaking the phone's rotation
        /// chain. That token has now expired and the phone isn't reachable, so there
        /// is genuinely nothing this Watch can do alone. Distinct from
        /// `.sessionExpired` because the action is different and specific: bring the
        /// iPhone near, don't go hunting for a password.
        ///
        /// Only ever reachable with the phone *unreachable* — see
        /// `WatchStore.sessionExpiryRecovery(...)`, which returns `.requestHandoff`
        /// whenever the phone is there. That's what keeps this standalone-only copy
        /// off the screen in companion mode.
        case needsPhoneNearby
        /// Item 10: transient, shown while the automatic re-handoff triggered by an
        /// expiry is in flight, so the account screen doesn't flash a dead end for a
        /// session that is about to be replaced.
        case reconnectingViaPhone
        case network
        case unknown

        var message: String {
            switch self {
            case .notReachable:
                return String(localized: "Your iPhone isn't nearby. Open ShelfHead on your iPhone and try again.")
            case .phoneNotSignedIn:
                return String(localized: "You're not signed in on your iPhone. Sign in there, then try again.")
            case .sessionExpired:
                return String(localized: "Your ShelfHead session has expired. Reconnect via iPhone or sign in again.")
            case .needsPhoneNearby:
                return String(localized: "Bring your iPhone nearby to keep listening — this Watch is using your iPhone's session and can't renew it on its own.")
            case .reconnectingViaPhone:
                return String(localized: "Reconnecting through your iPhone…")
            case .invalidCredentials:
                return String(localized: "That server, username, or password wasn't right.")
            case .invalidServerURL:
                return String(localized: "Enter a valid server address, like https://abs.example.com.")
            case .insecureConnectionNotAcknowledged:
                return String(localized: "This server uses an unencrypted connection.")
            case .network:
                return String(localized: "Couldn't reach the server. Check your connection and try again.")
            case .unknown:
                return String(localized: "Something went wrong. Please try again.")
            }
        }
    }

    enum WatchAuthState: Equatable {
        /// Haven't finished checking the Keychain yet — the very first moment after
        /// launch, before `bootstrapAuth()` completes.
        case checking
        case noSession
        case active
        /// The dead-end state from §7.3 — a 401 that survived one refresh attempt,
        /// or a refresh token the server rejected outright. Distinct from
        /// `.noSession`: this Watch *did* have a session, and lost it, which is why
        /// `authFailureMessage` accompanies this case specifically (set by
        /// `signalSessionExpired()`), vs. `.noSession`'s neutral "sign in" framing.
        case sessionExpired
    }

    private(set) var authState: WatchAuthState = .checking {
        didSet {
            guard authState != oldValue else { return }
            // Batch 496 (REVIEW 2026-11-11 W13): a new session answers "Signed out on iPhone".
            if authState == .active, signedOutOnPhone { setSignedOutOnPhone(false) }
            // After the current synchronous step, so `sessionKind` set alongside is included.
            Task { @MainActor in self.publishSetupReport() }
        }
    }
    private(set) var authFailureMessage: String?

    /// Batch 496 (REVIEW 2026-11-11 W13): the iPhone's account switch or sign-out wiped a
    /// session this Watch held. The Shelf says so, with the action, until the listener sets
    /// up again or taps Not Now (`WatchRunSetupPrompt.prompt`).
    private(set) var signedOutOnPhone = UserDefaults.standard.bool(forKey: WatchRunSetupPrompt.signedOutOnPhoneDefaultsKey)

    /// Batch 496 (W13): the iPhone account id the current session was handed over from.
    static let handoffAccountIdDefaultsKey = "watchSetup.handoffAccountId"
    /// §9.1 items 1–2 (public-release amendment) — `nil` until the first probe
    /// completes (screens should default to showing the sessions row rather than
    /// flashing it in after a delay); `true`/`false` once `probeServerCapabilities()`
    /// gets a definitive answer. Deliberately never regresses from a definitive
    /// answer back to `nil` on a later failed probe — see that method's own doc
    /// comment.
    private(set) var serverSupportsAuthSessions: Bool?
    /// §9.1 item 3 — set at handoff time, not discovered an hour later when the
    /// first background token refresh silently fails. Distinct from
    /// `authFailureMessage`: this isn't a failure (the handoff succeeded, `authState`
    /// is `.active`), it's an informational heads-up that this Watch can't refresh
    /// its own session without the phone nearby, because the phone's own server
    /// didn't hand back a refresh token at all (pre-2.26.0, or a server-side
    /// refresh-token policy that omits it).
    private(set) var noRefreshTokenWarning: String?

    /// Item 10 (10 September 2026) — which kind of credential this Watch is holding.
    /// `nil` when there's no session at all (or when one was stored by a build that
    /// predates the classification; `bootstrapAuth()` reads whatever
    /// `WatchSessionKindStore` has). Tracked as `@Observable` state, not read from
    /// `UserDefaults` in a computed property, for the same reason as every other
    /// property in this block: a computed read gives the right answer but never tells
    /// SwiftUI a dependency changed.
    private(set) var sessionKind: WatchSessionKind?

    /// Guard against stacking automatic re-handoffs: a burst of 401s (library page +
    /// playback session + progress push all failing at once) would otherwise fire one
    /// `requestHandoffFromPhone()` each. Also the "we already tried" input to
    /// `sessionExpiryRecovery(...)`, so a failed automatic attempt falls through to a
    /// real dead-end message instead of retrying forever on every subsequent failure.
    private var isRecoveringSession = false
    private var lastAutomaticHandoffAttempt: Date?
    /// How long a failed automatic re-handoff suppresses the next one. Long enough
    /// that a burst of failures produces one attempt, short enough that walking back
    /// into range and tapping something recovers without a relaunch.
    private static let automaticHandoffCooldown: TimeInterval = 60

    private let api = WatchAudiobookshelfAPI.shared

    /// Called once at launch (mirrors the iOS app's own
    /// `AuthViewModel.checkExistingSession` pattern) — seeds `AuthStore` from this
    /// Watch's own Keychain if a credential is already there (e.g. from a prior
    /// handoff), without making a network call.
    func bootstrapAuth() async {
        // Polish pass (WA-5): flush the progress queue when connectivity returns.
        progressSync.startWatchingConnectivity()
        await api.configureFromKeychainIfNeeded()
        authState = api.isConfigured ? .active : .noSession
        // Item 10: the credential's classification is restored alongside the credential
        // itself. A session written by a build that predates `WatchSessionKindStore`
        // reads back `nil`, which `applyHandoff` treats as `.shared` — the conservative
        // answer, since such a session really was a copy of the phone's.
        sessionKind = api.isConfigured ? WatchSessionKindStore.current : nil
        resolveMode()
        await progressSync.flushPendingProgress()
        if authState == .active {
            await probeServerCapabilities()
        }
    }

    /// §9.1 items 1–2. Called whenever this Watch newly confirms it has a usable
    /// session (`bootstrapAuth()`, a successful `requestHandoffFromPhone()`,
    /// a successful `loginManually()`) — a fresh probe each time rather than caching
    /// across relaunches, since the *server* could change version independently of
    /// anything this Watch does.
    func probeServerCapabilities() async {
        guard let result = await api.probeSessionsAPISupported() else { return }
        serverSupportsAuthSessions = result
    }

    /// Requests the phone hand off its current session. Uses `sendMessage`, not
    /// `transferUserInfo` — see `WatchSessionManager.buildCredentialHandoffReply()`'s
    /// doc comment (phone side) for the full reasoning (Stage 2 build instruction
    /// item 1): a credential handoff is interactive-only, so a non-reachable phone
    /// is a legitimate "try again nearby" failure, not a reason to queue a bearer
    /// token on disk for an indeterminate time. Checks `companion.isReachable`
    /// *before* sending, rather than relying on `sendMessage`'s own error handler,
    /// so the failure path never depends on a round trip to the (already known to
    /// be absent) counterpart.
    @discardableResult
    func requestHandoffFromPhone() async -> Bool {
        guard companion.isReachable else {
            authFailureMessage = WatchAuthFailureReason.notReachable.message
            return false
        }
        return await withCheckedContinuation { continuation in
            var didResume = false
            func resume(_ value: Bool) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }
            WCSession.default.sendMessage(["type": "requestCredentialHandoff"], replyHandler: { reply in
                Task { @MainActor in
                    guard let ok = reply["ok"] as? Bool, ok,
                          let serverURL = reply["serverURL"] as? String,
                          let accessToken = reply["accessToken"] as? String else {
                        let reason = (reply["reason"] as? String) == "notSignedIn" ? WatchAuthFailureReason.phoneNotSignedIn : .unknown
                        self.authFailureMessage = reason.message
                        WatchHaptics.failure()
                        resume(false)
                        return
                    }
                    let refreshToken = reply["refreshToken"] as? String
                    let customHeaders = (reply["customHeaders"] as? [String: String]) ?? [:]
                    let incomingKind = Self.handoffSessionKind(fromReply: reply, refreshToken: refreshToken)

                    // Item 10: a dedicated session this Watch already holds and can
                    // still use must not be thrown away for a borrowed access token.
                    // `sessionKind == nil` with a configured session means one stored by
                    // a build that predates the classification — which really was a copy
                    // of the phone's, so `.shared` is both accurate and conservative.
                    let existingSession: WatchStore.ExistingWatchSession? = AuthStore.shared.isConfigured
                        ? WatchStore.ExistingWatchSession(kind: self.sessionKind ?? .shared,
                                                    isUsable: self.authState == .active,
                                                    serverURL: AuthStore.shared.serverURL)
                        : nil
                    let decision = Self.applyHandoff(
                        existing: existingSession,
                        incoming: WatchStore.IncomingHandoff(kind: incomingKind, serverURL: serverURL))
                    guard decision == .adopt else {
                        // Nothing changed and nothing is wrong — the session already
                        // here is the better of the two.
                        self.authFailureMessage = nil
                        WatchHaptics.success()
                        resume(true)
                        return
                    }

                    // Review Low (Keychain save, 30 October 2026): a failed save used to
                    // be swallowed (`try?`), so the handoff reported success and the
                    // session vanished at the next relaunch. Retry once, then report it.
                    // Review 2 Low (handoff retry, 30 October 2026): snapshot the session once,
                    // before the first attempt, so a retry still closes the old session (the
                    // first attempt overwrites `AuthStore`) and a final failure can restore it.
                    let previousSession = self.api.currentSessionSnapshot()
                    let switchesServer = Self.handoffSwitchesAccount(existingServerURL: existingSession?.serverURL,
                                                                     incomingServerURL: serverURL)
                    // Review 7 Medium 5: write the standalone engine's progress to the OLD server
                    // while the old token still works, before configureAndPersist replaces it.
                    if switchesServer { await self.standalone.stopAndWriteOutProgress() }
                    var persisted = false
                    for _ in 0..<2 where !persisted {
                        do {
                            try await self.api.configureAndPersist(serverURL: serverURL, accessToken: accessToken,
                                                                   refreshToken: refreshToken, customHeaders: customHeaders,
                                                                   sessionKind: incomingKind,
                                                                   superseded: previousSession)
                            persisted = true
                        } catch {
                            // Both attempts failed; reported below as a failed handoff.
                        }
                    }
                    guard persisted else {
                        // Revert `AuthStore` to the pre-handoff session rather than leave it
                        // holding tokens that were never saved.
                        await self.api.restoreSession(previousSession, installedAccessToken: accessToken)
                        self.authFailureMessage = WatchAuthFailureReason.unknown.message
                        WatchHaptics.failure()
                        resume(false)
                        return
                    }
                    // Review 6 Medium 8: an adopted session for a different server must not
                    // keep the old library on screen or flush old queues under the new token.
                    if switchesServer { await self.resetAccountScopedState() }
                    // Batch 496 (W13): which iPhone account this is, for its Settings › Apple
                    // Watch status. Additive key; an older iPhone build sends none.
                    UserDefaults.standard.set(reply["accountId"] as? String, forKey: Self.handoffAccountIdDefaultsKey)
                    self.sessionKind = incomingKind
                    self.authState = .active
                    self.publishSetupReport()
                    self.authFailureMessage = nil
                    // §9.1 item 3 — surfaced at this exact moment, not discovered
                    // later when a background refresh silently fails against a
                    // refresh token that was never there. Item 10 changed what
                    // "no refresh token" *means*, so the copy is chosen by session
                    // kind now rather than by the token's presence alone: a `.durable`
                    // credential has no refresh token and needs none, whereas a
                    // `.shared` one is a deliberate, temporary loan from the phone.
                    self.noRefreshTokenWarning = Self.reconnectExpectation(for: incomingKind)
                    await self.probeServerCapabilities()
                    // UI polish pass round 2 (29 August 2026): a successful handoff
                    // used to complete with zero tactile confirmation — the only
                    // feedback was the screen itself changing, easy to miss on a
                    // glance-and-tap interaction.
                    WatchHaptics.success()
                    resume(true)
                }
            }, errorHandler: { _ in
                Task { @MainActor in
                    self.authFailureMessage = WatchAuthFailureReason.notReachable.message
                    WatchHaptics.failure()
                    resume(false)
                }
            })
        }
    }

    // MARK: - Handoff application (item 10, 10 September 2026)

    // The four types in this section are explicitly `nonisolated`. This target compiles
    // with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `WatchStore` is `@MainActor`
    // on top of that, so an unannotated nested type here inherits that isolation — and
    // then its *synthesized memberwise initializer and `==`* are main-actor-isolated
    // members, which the `nonisolated static` decision functions below (and the Watch
    // test bundle, which is where those decisions are actually pinned) can't reach.
    // Same trap `HANDOFF.md`'s "Gotchas learned today" describes for every type that
    // crosses the isolation boundary.

    /// The session this Watch already holds, reduced to the three things the decision
    /// below actually depends on.
    nonisolated struct ExistingWatchSession: Equatable {
        let kind: WatchSessionKind
        /// `authState == .active` — a session that has not (yet) been rejected.
        let isUsable: Bool
        let serverURL: String
    }

    /// The session a handoff reply is offering.
    nonisolated struct IncomingHandoff: Equatable {
        let kind: WatchSessionKind
        let serverURL: String
    }

    nonisolated enum HandoffApplication: Equatable {
        /// Store the incoming credential, replacing whatever is here.
        case adopt
        /// Keep what's already here — the incoming credential would be a downgrade.
        case keepExisting
    }

    /// Whether an arriving credential handoff should replace this Watch's current
    /// session.
    ///
    /// The case that makes this necessary: this Watch holds a `.dedicated` session
    /// (its own rotating pair, minted for it by the phone or created by a manual
    /// sign-in) and something asks the phone for a handoff while the phone can only
    /// offer `.shared` — a borrowed access token that expires within the hour and
    /// can't be renewed away from the phone. Blindly overwriting would trade a session
    /// that works alone for one that doesn't, which is the exact failure item 10 set
    /// out to remove.
    ///
    /// The rules, in order:
    /// 1. Nothing stored → adopt. Any session beats none.
    /// 2. A different server → adopt. The phone switched account or server; following
    ///    it is the whole point of a handoff, and keeping a credential for a server the
    ///    user has moved off is worse than a short-lived one for the server they're on.
    ///    (Compared leniently — trailing slashes and case differences between what the
    ///    phone sends and what this Watch normalised at sign-in are not a server change.)
    /// 3. The incoming credential survives without the phone (`.dedicated`/`.durable`)
    ///    → adopt. Always at least as good as what's here.
    /// 4. Otherwise the incoming credential is `.shared`, so keep the existing one only
    ///    if it both survives without the phone *and* still works. A `.dedicated`
    ///    session the server has already rejected is worth less than a fresh borrowed
    ///    token, so that case adopts too — which is also what makes the automatic
    ///    re-handoff in `signalSessionExpired()` able to recover anything at all.
    ///
    /// Note this needs no "was the user explicit about it" input: the only manual entry
    /// point, `WatchAccountView`'s "Reconnect via iPhone", is shown only while
    /// `authState != .active`, so `isUsable` is already false there and rule 4 adopts.
    ///
    /// `nonisolated static` and pure so the Watch test target can pin it.
    nonisolated static func applyHandoff(existing: ExistingWatchSession?, incoming: IncomingHandoff) -> HandoffApplication {
        guard let existing else { return .adopt }
        guard comparableServerURL(existing.serverURL) == comparableServerURL(incoming.serverURL) else { return .adopt }
        if incoming.kind.survivesWithoutThePhone { return .adopt }
        return (existing.kind.survivesWithoutThePhone && existing.isUsable) ? .keepExisting : .adopt
    }

    /// Loose equality for "is this the same server," used only by `applyHandoff`. The
    /// phone sends `AuthStore.shared.serverURL` verbatim; this Watch may have stored a
    /// `ServerURLRules.normalizedServerURL(_:)` form of the same address from a manual sign-in.
    /// Treating `https://ABS.example.com/` and `https://abs.example.com` as different
    /// servers would silently discard a good dedicated session on every handoff.
    nonisolated static func comparableServerURL(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    /// Reads the handoff reply's additive `sessionKind` key, falling back to what an
    /// older phone build's reply implies.
    ///
    /// Backwards compatibility runs both ways here. A phone that predates item 10
    /// sends no `sessionKind` at all, and what it *did* send was its own pair: an
    /// access token plus, usually, its own refresh token. Inferring `.dedicated` from
    /// that refresh token isn't strictly accurate — it's shared, which is the bug —
    /// but it is exactly the behaviour this Watch had before item 10, so an old phone
    /// paired with a new Watch is no worse off than it is today, and it keeps the
    /// Watch from immediately discarding a working pair as if it were a loan. With no
    /// refresh token and no `sessionKind`, `.shared` is both the accurate and the
    /// conservative answer.
    nonisolated static func handoffSessionKind(fromReply reply: [String: Any], refreshToken: String?) -> WatchSessionKind {
        if let raw = reply["sessionKind"] as? String, let kind = WatchSessionKind(rawValue: raw) {
            return kind
        }
        return (refreshToken?.isEmpty == false) ? .dedicated : .shared
    }

    /// What to tell the user about reconnecting, given the kind of session they just
    /// got. `nil` means there is nothing to warn about.
    ///
    /// Replaces the old "is the refresh token nil" test, which conflated two very
    /// different situations now that the phone deliberately withholds its refresh
    /// token: a pre-2.26 server (durable token, no refresh token needed, nothing to
    /// warn about) and a borrowed access token (works for about an hour away from the
    /// phone). Informational, not an error — `authState` is `.active` in every case
    /// here.
    nonisolated static func reconnectExpectation(for kind: WatchSessionKind) -> String? {
        switch kind {
        case .dedicated, .durable:
            return nil
        case .shared:
            return String(localized: "This Watch is borrowing your iPhone's session, so it can't renew on its own. Keep your iPhone nearby now and then, or sign in on the Watch to listen away from it.")
        }
    }

    /// The sign-in gate: what a typed server address is allowed to do before a single
    /// byte leaves the Watch.
    ///
    /// Added 9 September 2026 for the review's HIGH "Watch standalone sign-in has no
    /// URL validation and no plain-HTTP gate." `loginManually` used to hand the raw
    /// string straight to `WatchAudiobookshelfAPI.login`, which trimmed slashes and
    /// string-built `"\(url)/login"` — so `http://public.host` POSTed the username
    /// and password in the clear with no warning at all, and a pasted deep link or
    /// token-bearing URL was accepted as a base address. The phone has had both
    /// checks since it was written; this is the Watch's own copy of the decision (see
    /// `ServerURLRules` in Shared/, one definition compiled into both targets since Batch 314).
    ///
    /// `nonisolated static` and pure so the Watch test target can pin it
    /// (`WatchSignInGateTests`).
    enum SignInGateDecision: Equatable {
        case invalidURL
        /// Plain HTTP to a non-local host with no acknowledgement yet. Carries the
        /// normalised URL so the view can name the host it's about to trust.
        case needsInsecureAcknowledgement(cleanURL: String)
        /// Safe to send: HTTPS, or plain HTTP to a local/private host, or an insecure
        /// host the user has explicitly accepted.
        case proceed(cleanURL: String)
    }

    nonisolated static func signInGate(rawServerURL: String, acknowledgedInsecureConnection: Bool) -> SignInGateDecision {
        guard let cleanURL = ServerURLRules.normalizedServerURL(rawServerURL) else { return .invalidURL }
        if ServerURLRules.requiresInsecureConnectionConfirmation(for: cleanURL), !acknowledgedInsecureConnection {
            return .needsInsecureAcknowledgement(cleanURL: cleanURL)
        }
        return .proceed(cleanURL: cleanURL)
    }

    private static let acknowledgedInsecureURLsDefaultsKey = "watchStore.acknowledgedInsecureServerURLs"

    /// Whether the user has already accepted plain HTTP for this exact normalised
    /// address on this Watch. Mirrors the phone's per-account
    /// `ServerAccount.insecureConnectionAcknowledged` (`ShelfHead/Models/ServerAccount
    /// .swift`) — keyed by URL rather than account id, since this Watch holds one
    /// session at a time and has no account list of its own.
    private static func hasAcknowledgedInsecureConnection(cleanURL: String) -> Bool {
        let stored = UserDefaults.standard.stringArray(forKey: acknowledgedInsecureURLsDefaultsKey) ?? []
        return stored.contains(cleanURL)
    }

    private static func rememberInsecureAcknowledgement(cleanURL: String) {
        var stored = UserDefaults.standard.stringArray(forKey: acknowledgedInsecureURLsDefaultsKey) ?? []
        guard !stored.contains(cleanURL) else { return }
        stored.append(cleanURL)
        UserDefaults.standard.set(stored, forKey: acknowledgedInsecureURLsDefaultsKey)
    }

    /// Manual-entry recovery path (addendum §2.1 Option B / §7.3) — direct
    /// username/password login on the Watch itself, for when the phone isn't
    /// reachable at all (so handoff isn't an option) or the recovery screen is
    /// reached from a fresh install with no paired-phone session to request.
    /// `WatchAudiobookshelfAPI.login(_:)` already never persists the password
    /// itself (only the resulting tokens) — see that method's own doc comment —
    /// so nothing extra is needed here to honor the addendum's "no plaintext
    /// password on the Watch" rule.
    ///
    /// `acknowledgedInsecureConnection` is the user's explicit "yes, connect anyway"
    /// from `WatchManualSignInView`'s confirmation alert. Throws
    /// `WatchAPIError.invalidURL` for an unusable address and
    /// `WatchSignInGateRefusal.insecureConnectionNotAcknowledged` when the gate needs
    /// an answer — the view catches the latter specifically to raise the alert.
    func loginManually(serverURL: String, username: String, password: String,
                       acknowledgedInsecureConnection: Bool = false) async throws {
        // Deliberately an `if let` rather than `Optional.map(Self.hasAcknowledged…)`:
        // passing a reference to a `@MainActor`-isolated static method where a plain
        // synchronous closure is expected is exactly the kind of isolation conversion
        // `SWIFT_STRICT_CONCURRENCY = targeted` rejects.
        var alreadyAcknowledged = false
        if let candidate = ServerURLRules.normalizedServerURL(serverURL) {
            alreadyAcknowledged = Self.hasAcknowledgedInsecureConnection(cleanURL: candidate)
        }
        let cleanURL: String
        switch Self.signInGate(rawServerURL: serverURL,
                               acknowledgedInsecureConnection: acknowledgedInsecureConnection || alreadyAcknowledged) {
        case .invalidURL:
            authFailureMessage = WatchAuthFailureReason.invalidServerURL.message
            WatchHaptics.failure()
            throw WatchAPIError.invalidURL
        case .needsInsecureAcknowledgement(let url):
            authFailureMessage = WatchAuthFailureReason.insecureConnectionNotAcknowledged.message
            throw WatchSignInGateRefusal.insecureConnectionNotAcknowledged(cleanURL: url)
        case .proceed(let url):
            cleanURL = url
        }

        do {
            // Fix (MEDIUM, 9 September 2026 review — "Watch manual sign-in destroys
            // handed-off reverse-proxy headers"): no `customHeaders` argument is
            // passed, and `login` now treats an empty dictionary as "keep whatever
            // this Watch already has" rather than as "the correct headers are none."
            // See `WatchAudiobookshelfAPI.login(...)`.
            let response = try await api.login(serverURL: cleanURL, username: username, password: password)
            if ServerURLRules.requiresInsecureConnectionConfirmation(for: cleanURL) {
                // Recorded only after a *successful* sign-in, so a typo'd host the
                // user acknowledged and then failed to reach doesn't silently become
                // pre-approved.
                Self.rememberInsecureAcknowledgement(cleanURL: cleanURL)
            }
            // Batch 496 (W13): this Watch's own sign-in, not an iPhone account's.
            UserDefaults.standard.removeObject(forKey: Self.handoffAccountIdDefaultsKey)
            authState = .active
            authFailureMessage = nil
            // Polish pass (WA-3): a fresh sign-in must not show the previous sign-in's cached shelf.
            WatchInProgressCache.clear()
            // Item 10: a manual sign-in always produces a session this Watch owns.
            // `WatchAudiobookshelfAPI.login` has already persisted the same
            // classification; mirror it into the observed property so the UI sees it
            // without a relaunch.
            sessionKind = (response.user.refreshToken?.isEmpty == false) ? .dedicated : .durable
            // §9.1 item 3 — same reasoning as `requestHandoffFromPhone()`'s own
            // handling: a server old enough to omit the refresh token from `/login`
            // is caught here, not an hour later on the first background refresh.
            // Kept as its own copy rather than routed through `reconnectExpectation
            // (for:)`: a `.durable` credential obtained by *signing in on the Watch*
            // still warrants saying the session can't be renewed automatically, and
            // this path — unlike a handoff — has no phone to fall back on.
            noRefreshTokenWarning = response.user.refreshToken == nil
                ? String(localized: "Your server is too old for the Watch to keep its own session — you'll need to sign in again whenever your session expires.")
                : nil
            await probeServerCapabilities()
            // UI polish pass round 2 (29 August 2026): same reasoning as
            // `requestHandoffFromPhone()`'s identical addition just above — a
            // successful sign-in used to have no tactile confirmation of its own.
            WatchHaptics.success()
        } catch let error as WatchAPIError {
            let reason: WatchAuthFailureReason
            switch error {
            case .unauthorized: reason = .invalidCredentials
            case .invalidURL: reason = .invalidServerURL
            case .invalidResponse, .httpError, .serverError, .transportError: reason = .network
            case .sessionExpired, .forbidden, .notFound: reason = .unknown
            }
            authFailureMessage = reason.message
            WatchHaptics.failure()
            throw error
        }
    }

    /// The §7.3 dead-end: call when any standalone API call fails with
    /// `WatchAPIError.sessionExpired` (a 401 that survived one refresh attempt).
    /// Distinct named state + specific message, not folded into a generic
    /// network-error path, per Stage 2's build instructions (item 7). The actual
    /// recovery UI (checking `isReachable` to decide whether to offer re-handoff
    /// alongside manual entry) lives in the view that observes `authState`, not
    /// here — this method's only job is to raise the flag.
    ///
    /// **Item 10 (10 September 2026): a dead end is now the last resort, not the only
    /// outcome.** Since the phone may deliberately have handed this Watch an access
    /// token with *no* refresh token (to keep the Watch from rotating the phone's
    /// single-use refresh token out from under it), "the token expired" is an expected,
    /// routine event for a `.shared` session rather than a failure — and the fix for it
    /// is a fresh handoff, which is free whenever the phone is reachable. So:
    ///
    /// - **Phone reachable** → ask for a new session automatically, showing transient
    ///   "Reconnecting through your iPhone…" copy rather than a dead end. This is also
    ///   why companion mode can never show the standalone-only "bring your iPhone
    ///   nearby" message: with the phone there, that branch is unreachable.
    /// - **No phone, no refresh token** → the honest dead end, with copy that names the
    ///   actual remedy (`.needsPhoneNearby`) instead of the generic "your session has
    ///   expired," which invites the user to go hunting for a password they may not
    ///   even have (SSO accounts).
    /// - **Anything else** → the original message. This Watch had its own refresh chain
    ///   and the server rejected it, so signing in again really is the way out.
    ///
    /// Still synchronous with the same signature, so every existing call site
    /// (`WatchStandaloneCall.perform`, `WatchLocalDownloadManager`) is unchanged; the
    /// automatic re-handoff runs in a `Task` and is rate-limited by
    /// `automaticHandoffCooldown` so a burst of simultaneous 401s produces one attempt,
    /// not one per failed request.
    func signalSessionExpired() {
        let hasRefreshToken = !(AuthStore.shared.refreshToken ?? "").isEmpty
        var recentlyAttempted = isRecoveringSession
        if !recentlyAttempted, let last = lastAutomaticHandoffAttempt {
            recentlyAttempted = Date().timeIntervalSince(last) < Self.automaticHandoffCooldown
        }
        switch Self.sessionExpiryRecovery(hasRefreshToken: hasRefreshToken,
                                          phoneIsReachable: companion.isReachable,
                                          recentlyAttemptedHandoff: recentlyAttempted) {
        case .requestHandoff:
            authState = .sessionExpired
            authFailureMessage = WatchAuthFailureReason.reconnectingViaPhone.message
            isRecoveringSession = true
            lastAutomaticHandoffAttempt = Date()
            Task { @MainActor in
                let recovered = await self.requestHandoffFromPhone()
                self.isRecoveringSession = false
                if recovered {
                    // `requestHandoffFromPhone()` has already set `.active` and cleared
                    // the message on the adopt path; on the keep-existing path there was
                    // never anything wrong with the credential, so clear the flag too.
                    self.authState = .active
                    self.authFailureMessage = nil
                } else {
                    // It set its own, more specific failure message (phone not signed
                    // in, went out of range mid-request) — leave that; only fill in the
                    // generic one if nothing was said.
                    self.authState = .sessionExpired
                    if self.authFailureMessage == nil
                        || self.authFailureMessage == WatchAuthFailureReason.reconnectingViaPhone.message {
                        self.authFailureMessage = WatchAuthFailureReason.sessionExpired.message
                    }
                }
            }
        case .bringPhoneNearby:
            authState = .sessionExpired
            authFailureMessage = WatchAuthFailureReason.needsPhoneNearby.message
        case .signInAgain:
            authState = .sessionExpired
            authFailureMessage = WatchAuthFailureReason.sessionExpired.message
        }
    }

    /// What a Watch that just got a 401 it couldn't refresh past should do about it.
    nonisolated enum SessionExpiryRecovery: Equatable {
        /// Ask the phone for a fresh session — it's right there.
        case requestHandoff
        /// Nothing this Watch can do alone: it holds a borrowed access token with no
        /// refresh token and the phone isn't reachable.
        case bringPhoneNearby
        /// This Watch had its own refresh chain (or has already tried the phone) and
        /// it didn't work — manual sign-in is the way out.
        case signInAgain
    }

    /// The pure decision behind `signalSessionExpired()`.
    ///
    /// `recentlyAttemptedHandoff` is what stops a loop: without it, a phone that is
    /// reachable but can't help (signed out on the phone, say) would be asked again on
    /// every subsequent failed request, forever, and the screen would never settle on
    /// anything the user could act on.
    ///
    /// Note `.bringPhoneNearby` requires the phone to be *un*reachable, which is the
    /// invariant that keeps that standalone-only copy from ever appearing in companion
    /// mode — `WatchAccountView`/`WatchSettingsView` render `authFailureMessage` in
    /// both modes, so the message has to be right by construction rather than by which
    /// screen happens to show it.
    ///
    /// `nonisolated static` and pure so the Watch test target can pin it.
    nonisolated static func sessionExpiryRecovery(hasRefreshToken: Bool,
                                                  phoneIsReachable: Bool,
                                                  recentlyAttemptedHandoff: Bool) -> SessionExpiryRecovery {
        if phoneIsReachable && !recentlyAttemptedHandoff { return .requestHandoff }
        if !hasRefreshToken && !phoneIsReachable { return .bringPhoneNearby }
        return .signInAgain
    }

    /// Phone-initiated credential wipe (sign-out or account switch) — see
    /// `WatchConnectivityStore.apply(context:)`'s `"wipeCredentials"` branch, which
    /// is this method's only real caller.
    /// **Ordering matters, and it was wrong (MEDIUM, 9 September 2026 review — "phone-side
    /// sign-out wipes queued progress and leaves Watch playback running").** This used
    /// to wipe the tokens and then `progressSync.wipeAll()`, with standalone playback
    /// left running on a credential that no longer existed: the audio kept going, the
    /// periodic `syncSession` started failing silently, and the listener's position
    /// for the book playing *right now* was dropped from the queue without ever
    /// having been offered to the server.
    ///
    /// What is and isn't recoverable once the token is gone, and the choice made here:
    /// - the **currently playing item's** position is recoverable *only before* the
    ///   wipe, so `stopAndWriteOutProgress()` runs first and is awaited — it records
    ///   the position locally, closes the server session at the real position, and
    ///   flushes;
    /// - **other queued positions** get their one last chance in the same flush;
    /// - anything still queued after that is **not** recoverable: it belongs to the
    ///   account that just signed out, and keeping it would push another account's
    ///   listening position under a new session the next time this Watch signs in —
    ///   the cross-account mis-attribution `wipeAll()`'s own doc comment describes. So
    ///   it is still cleared, but now only after the write-out has had its chance.
    /// Review 6 Medium 8: the library swap and queue wipes shared by `wipeCredentials()` and a
    /// handoff that adopts a different server.
    private func resetAccountScopedState() async {
        library = WatchStandaloneLibraryStore(api: api)
        UserDefaults.standard.removeObject(forKey: WatchStandaloneLibraryStore.selectedLibraryDefaultsKey)
        // Polish pass (WA-3): the cached in-progress shelf belongs to the account that left.
        WatchInProgressCache.clear()
        await progressSync.wipeAll()
        await WatchPendingBookmarkQueue.shared.clear()   // queued bookmarks belong to the previous account
    }

    /// Review 6 Medium 8: whether adopting a handoff moves this Watch to another server
    /// (comparable form). The reply carries no user id, so a same-server user change can't be
    /// detected here. False when there was no session before.
    nonisolated static func handoffSwitchesAccount(existingServerURL: String?, incomingServerURL: String) -> Bool {
        guard let existingServerURL else { return false }
        return comparableServerURL(existingServerURL) != comparableServerURL(incomingServerURL)
    }

    /// Batch 496 (REVIEW 2026-11-11 W13): `initiatedByPhone` is true for the iPhone's
    /// `wipeCredentials` signal (account switch or sign-out). When it wiped a session this
    /// Watch held, the Shelf says "Signed out on iPhone" with Set Up Again. It does not ask
    /// for a new credential by itself: see `WatchShelfView.signedOutPage`.
    func wipeCredentials(initiatedByPhone: Bool = false) async {
        let hadSession = api.isConfigured
        // Before `api.wipeCredentials()`: this is the last moment the access token
        // still works.
        await standalone.stopAndWriteOutProgress()
        // Item 10: `api.wipeCredentials()` also closes the session server-side when
        // this Watch owned it exclusively (a `.dedicated` one), and clears the stored
        // classification — see that method's own doc comment for why `.durable` and
        // `.shared` are deliberately left open.
        await api.wipeCredentials()
        // Batch 496 (W13): a sign-out on this Watch is the wearer's own choice and says nothing.
        UserDefaults.standard.removeObject(forKey: Self.handoffAccountIdDefaultsKey)
        if initiatedByPhone {
            if hadSession { setSignedOutOnPhone(true) }
        } else {
            setSignedOutOnPhone(false)
        }
        authState = .noSession
        authFailureMessage = nil
        sessionKind = nil
        // A cooldown belonging to the account that just signed out must not suppress
        // the first automatic re-handoff after the next one signs in.
        isRecoveringSession = false
        lastAutomaticHandoffAttempt = nil
        // A wiped session's server-capability answer and refresh-token warning
        // belong to whatever account/server just got signed out of — carrying them
        // into a fresh sign-in would be stale information presented as current.
        serverSupportsAuthSessions = nil
        noRefreshTokenWarning = nil
        // Review Medium 34 (30 October 2026): the standalone library store has no reset
        // of its own, so swap in a fresh one (and forget the remembered library id) or the
        // previous account's books stay on screen.
        await resetAccountScopedState()
        // Review 6 Low (complication): the signed-out account's book must not stay on the face.
        WatchComplicationStore.publish(nil)
        // A Watch left in `.standalone` with no session is pointed at
        // the standalone stack with nothing behind it. `resolveMode()` now has
        // something to say here because the engine was actually stopped above — its
        // `shouldDeferModeChange(...)` guard would otherwise have refused, which is
        // half of why this was left inconsistent before.
        resolveMode()
        publishSetupReport()
    }

    // MARK: - Setup state (Batch 496, REVIEW 2026-11-11 W13)

    private func setSignedOutOnPhone(_ value: Bool) {
        signedOutOnPhone = value
        UserDefaults.standard.set(value, forKey: WatchRunSetupPrompt.signedOutOnPhoneDefaultsKey)
    }

    /// "Not Now" on the Shelf's "Signed out on iPhone" page.
    func dismissSignedOutOnPhone() {
        setSignedOutOnPhone(false)
        publishSetupReport()
    }

    /// The iPhone's Settings › Apple Watch "Send Sign-In to Watch": a tokenless nudge that
    /// asks this Watch to request the hand-over through the usual interactive path
    /// (`requestHandoffFromPhone`, which keeps a working dedicated session over a borrowed one).
    func acceptSignInOfferFromPhone() async {
        await requestHandoffFromPhone()
    }

    /// The setup state as `WatchSetupReport`, or nil while still checking.
    nonisolated static func setupReport(authState: WatchAuthState, sessionKind: WatchSessionKind?,
                                        serverURL: String?, handoffAccountId: String?,
                                        signedOutOnPhone: Bool, now: Int64) -> WatchSetupReport? {
        let state: WatchSetupReport.State
        switch authState {
        case .checking: return nil
        case .noSession: state = .notSetUp
        case .active: state = .active
        case .sessionExpired: state = .expired
        }
        let hasSession = state != .notSetUp
        return WatchSetupReport(state: state,
                                sessionKind: hasSession ? sessionKind?.rawValue : nil,
                                serverURL: hasSession ? serverURL : nil,
                                handoffAccountId: hasSession ? handoffAccountId : nil,
                                signedOutOnPhone: !hasSession && signedOutOnPhone,
                                updatedAt: now)
    }

    /// Sends the setup state to the iPhone. `updateApplicationContext` replaces the last
    /// one and may be called while the iPhone is out of reach; it needs an activated session.
    func publishSetupReport() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let report = Self.setupReport(authState: authState, sessionKind: sessionKind,
                                            serverURL: AuthStore.shared.isConfigured ? AuthStore.shared.serverURL : nil,
                                            handoffAccountId: UserDefaults.standard.string(forKey: Self.handoffAccountIdDefaultsKey),
                                            signedOutOnPhone: signedOutOnPhone,
                                            now: Int64(Date().timeIntervalSince1970)),
              let data = try? JSONEncoder().encode(report) else { return }
        try? WCSession.default.updateApplicationContext([WatchSetupReport.contextKey: data])
    }

    // MARK: - Auth session management (Stage 2 revocation UI)

    /// Wraps `WatchAudiobookshelfAPI.getAuthSessions()` with the one piece of
    /// cross-cutting behavior every standalone API call needs: a `.sessionExpired`
    /// failure routes to `signalSessionExpired()` rather than surfacing as an
    /// undifferentiated thrown error the caller has to remember to check for
    /// individually.
    ///
    /// 9 September 2026: the hand-written `catch` these two used to carry is now
    /// `WatchStandaloneCall.perform` — the same wrapper every *other* standalone call
    /// site was missing, which is why `.sessionExpired` never reached
    /// `signalSessionExpired()` from library browsing, playback, downloads or the
    /// progress push. Behaviour here is unchanged; the difference is that the rule
    /// now lives in one place instead of being re-typed per call.
    func getAuthSessions() async throws -> [WatchAuthSession] {
        try await WatchStandaloneCall.perform { try await api.getAuthSessions() }
    }

    func revokeAuthSession(id: String) async throws {
        try await WatchStandaloneCall.perform { try await api.revokeAuthSession(id: id) }
    }

    // MARK: - Mode (Stage 3, addendum §10.2 / original proposal §2.7)

    /// Decides companion-vs-standalone at a natural checkpoint — launch, a
    /// `companion.isReachable` transition, or the app returning to the foreground (see
    /// this method's three call sites: `bootstrapAuth()` below, and
    /// `ShelfHeadWatchApp.swift`'s `.task`/`.onChange` hooks). Never re-decided while a
    /// standalone book is loaded (9 September 2026: *loaded*, not merely playing — see
    /// `shouldDeferModeChange(standaloneIsLoaded:standaloneIsPlaying:)`), per §2.7's
    /// explicit recommendation: interrupting a Watch that's mid-book the instant a
    /// phone becomes reachable would yank control away from whatever the user is
    /// actually doing, the same failure mode `decideRootOnce()`
    /// (`ShelfHeadWatchApp.swift`) already avoids for the nowPlaying-vs-library root
    /// choice this mirrors.
    ///
    /// Standalone only when the phone genuinely isn't reachable AND this Watch holds a
    /// usable session (`authState == .active`) — otherwise companion, since the phone
    /// relay is the faster, already-proven path whenever a phone is actually present.
    /// A Watch with no valid session and no reachable phone stays `.companion` here too
    /// (there's nothing standalone to fall back to) — that degraded state isn't new or
    /// solved by this method; it's the same "open ShelfHead on iPhone" empty states the
    /// existing companion screens already show.
    /// The only way `modePreference` changes. Persists to `UserDefaults` and then
    /// calls `resolveMode()` immediately — deliberately not deferred to "the next
    /// natural checkpoint" as a separate mechanism, because `resolveMode()`
    /// already *is* that checkpoint mechanism: its own
    /// `shouldDeferModeChange(standaloneIsLoaded:standaloneIsPlaying:)` guard means a
    /// preference change while a standalone book is loaded simply doesn't take effect
    /// until that book is stopped (or the next reachability/foreground checkpoint
    /// fires), exactly per §2.7's recommendation, with no second guard needed here.
    func setModePreference(_ preference: ModePreference) {
        guard preference != modePreference else { return }
        modePreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: Self.modePreferenceDefaultsKey)
        WatchHaptics.tap()
        resolveMode()
    }

    /// Critique 2026-10-06 (shape → harden): what starting a book on this Watch does to
    /// the iPhone (`WatchPlayOnWatchPhoneAction`), from the companion snapshot.
    func phoneActionForPlayingOnWatch(itemId: String) -> WatchPlayOnWatchPhoneAction {
        let state = companion.playbackState
        return WatchPlayOnWatchPhoneAction.decide(
            requestedItemId: itemId,
            phoneIsReachable: companion.isReachable,
            phoneIsPlaying: state?.isPlaying == true && state?.hasActiveItem == true,
            phoneItemId: state?.itemId,
            phoneTitle: state?.title ?? "",
            phoneStateIsStale: companion.isStateStale)
    }

    /// Pauses the iPhone through the existing command channel (`togglePlayPause`, which
    /// carries the item id the phone checks) when it's reachable and playing. A no-op
    /// otherwise, so it never raises "Command Failed" for a phone that isn't there.
    func pausePhoneIfPlaying() {
        guard companion.isReachable, !companion.isStateStale,
              let state = companion.playbackState, state.hasActiveItem, state.isPlaying else { return }
        companion.togglePlayPause()
    }

    /// Whether a mode re-decision must be deferred because standalone playback would
    /// be orphaned by it.
    ///
    /// Fix (MEDIUM, 9 September 2026 review — "mode can flip out from under a
    /// loaded-but-paused standalone book"): this guard used to be `!standalone
    /// .isPlaying` alone. `WatchRootView` switches roots live on `mode`, so a book
    /// that was loaded and *paused* — the user having tapped pause, or the engine
    /// having paused for a route change — could have its root swapped to
    /// the companion stack the instant the phone came back into range, leaving a
    /// live `AVQueuePlayer` and an open server session with no screen able to reach
    /// them (and, once the router owns Now Playing, no glance either). `isLoaded`
    /// covers both cases: it's true from the moment `play(...)` builds the queue until
    /// `resetPlaybackState()` runs, playing or not.
    ///
    /// The deferral is not a dead end — `resolveMode()` runs again at the next natural
    /// checkpoint (foregrounding, a reachability edge, a preference change), and
    /// stopping the book (`stop()`, which clears `isLoaded`) releases the guard
    /// immediately.
    ///
    /// `nonisolated static` and pure so the Watch test target can pin it.
    nonisolated static func shouldDeferModeChange(standaloneIsLoaded: Bool, standaloneIsPlaying: Bool) -> Bool {
        standaloneIsLoaded || standaloneIsPlaying
    }

    /// The mode decision itself, extracted as a pure function (9 September 2026) so
    /// the three-way preference × reachability × session matrix can be pinned by the
    /// Watch test target rather than only exercised on a real paired device.
    nonisolated static func resolvedMode(preference: ModePreference, phoneIsReachable: Bool, hasUsableSession: Bool) -> Mode {
        switch preference {
        case .alwaysCompanion:
            return .companion
        case .alwaysStandalone:
            // Same hard requirement as Automatic's own standalone branch: no amount
            // of user preference makes standalone playback possible with no usable
            // session on this Watch. Falls back to companion rather than leaving
            // `mode` pointed at a dead end — the degraded-companion empty states
            // (existing "open ShelfHead on iPhone" screens) already cover "nothing
            // standalone to fall back to."
            return hasUsableSession ? .standalone : .companion
        case .automatic:
            return (!phoneIsReachable && hasUsableSession) ? .standalone : .companion
        }
    }

    /// Critique 2026-10-06 (shape → harden): the whole decision, including the hold.
    ///
    /// "Play on Watch" is now the primary action for a downloaded book in both modes, so
    /// this Watch's engine can load a book while `mode` is `.companion`. A loaded engine
    /// means the Watch is the player, so the mode **holds `.standalone` while it's
    /// loaded** (playing or paused), whatever the preference or the phone's reachability:
    /// Now Playing, the remote commands and the Now Playing glance all follow the book on
    /// the wrist. The hold releases when the book is stopped or unloaded (`isLoaded`
    /// false), and the decision falls back to `resolvedMode(...)` — Automatic behaviour
    /// again. `WatchRootView` re-runs `resolveMode()` on every `isLoaded` edge, so both
    /// the hold and the release land at once rather than at the next checkpoint.
    ///
    /// Before this, a loaded engine only ever *deferred* a change (`shouldDeferModeChange`,
    /// still true and still pinned); since the engine could only be loaded in standalone,
    /// deferring and holding were the same thing. They differ now only for a book started
    /// from companion mode, which is the case being fixed.
    nonisolated static func nextMode(current: Mode, preference: ModePreference, phoneIsReachable: Bool,
                                     hasUsableSession: Bool, standaloneIsLoaded: Bool,
                                     standaloneIsPlaying: Bool) -> Mode {
        if standaloneIsLoaded { return .standalone }
        if shouldDeferModeChange(standaloneIsLoaded: standaloneIsLoaded, standaloneIsPlaying: standaloneIsPlaying) {
            return current
        }
        return resolvedMode(preference: preference, phoneIsReachable: phoneIsReachable, hasUsableSession: hasUsableSession)
    }

    func resolveMode() {
        let previousMode = mode
        mode = Self.nextMode(current: mode,
                             preference: modePreference,
                             phoneIsReachable: companion.isReachable,
                             hasUsableSession: authState == .active,
                             standaloneIsLoaded: standalone.isLoaded,
                             standaloneIsPlaying: standalone.isPlaying)
        if mode != previousMode {
            // One owner for `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter`, told
            // exactly once per transition — see `WatchRemoteCommandRouter`.
            WatchRemoteCommandRouter.shared.modeDidChange(to: mode)
        }
        // Stage 6: one of this method's three natural checkpoints (launch,
        // reachability change, foregrounding — see this method's own doc comment)
        // is as good a point as any to retry flushing whatever's queued in
        // `WatchPendingProgressQueue`. `flushPendingProgress()` is cheap to call
        // speculatively: it no-ops immediately if `api.isConfigured` is false, and
        // if there's genuinely no network right now the per-item `getItem`/
        // `updateProgress` calls just fail and stay queued for the next checkpoint
        // — no different from not calling it at all in that case.
        let progressSync = self.progressSync
        Task { await progressSync.flushPendingProgress() }
    }
}

// Item 22 (Batch 314): moved here from the deleted `WatchServerURL.swift`, whose URL
// helpers now live in the shared `ServerURLRules` (Shared/ServerURLRules.swift).
/// Raised by `WatchStore.loginManually(...)` when the plain-HTTP gate needs an answer
/// before anything is sent. Its own error type rather than a `WatchAPIError` case: no
/// request has been made, so it isn't an API error, and `WatchManualSignInView`
/// catches exactly this to raise its confirmation alert (every other thrown error
/// falls through to the existing "show `store.authFailureMessage`" path).
enum WatchSignInGateRefusal: Error, Equatable {
    case insecureConnectionNotAcknowledged(cleanURL: String)
}
