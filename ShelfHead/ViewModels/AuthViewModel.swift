import Foundation
import SwiftUI
import Darwin
import Security
import WidgetKit

extension Notification.Name {
    /// Posted after the active account changes (switch / add-and-switch / a fresh
    /// sign-in / sign-out) so views AND non-view listeners can drop the previous
    /// account's in-memory data and reload.
    ///
    /// WATCH-4 (REVIEW_2026-08-12.md): previously only posted from `switchAccount(_:)`
    /// — plain `login()`/`loginWithOIDC()`/`logout()` didn't post it at all. That left
    /// `CarPlayCoordinator` (a non-SwiftUI class that can't use `.onReceive`/
    /// `@Environment`, and has no direct reference to this non-singleton
    /// `AuthViewModel`) with no way to learn "the user just signed in" or "signed out"
    /// while already connected — CarPlay's Home tab stayed frozen on "Sign in on your
    /// phone" for the rest of the drive even after the user completed sign-in on the
    /// phone screen. Now posted from all four transitions.
    static let shelfheadAccountChanged = Notification.Name("shelfhead.accountChanged")
}

@MainActor
@Observable
final class AuthViewModel {
    // PL-9 (docs/design-review.md, Round 5): every path that flips this property is the
    // single source of truth for "is anyone signed in", so hooking its `didSet` — rather
    // than `AuthStore.set`/`clear()` — is the one chokepoint that reliably covers login,
    // OIDC sign-in, an account switch (via `login`/`loginWithOIDC` below), the optimistic
    // Keychain restore in `checkExistingSession`, the LS-3 rejected-token path in
    // `verifyRestoredSession`, Sign Out, and removing the active account (which routes
    // through `finishEndingLiveSession`, like Sign Out). `AuthStore` itself was considered
    // first, but its `set`/`clear` live in `AuthStore.swift`, which is also compiled into
    // the Watch target — and `SharedPlayback.swift` is not part of that target's Sources build phase (it only
    // compiles into the app and the widget extension), so a reference to it from
    // `AuthStore.swift` would fail to build there. This view model only compiles into the
    // iOS app target, so it has no such constraint.
    var isAuthenticated = false {
        didSet {
            // Polish pass (J1-1): nobody signed in → no "Sign in again" sheet for them.
            if !isAuthenticated {
                sessionExpiredPrompt = nil
                sessionNeedsSignIn = false
            }
            guard SharedPlayback.setSignedIn(isAuthenticated) else { return }
            // `tearDownAccountScopedState`'s `WidgetLibraryPublisher.clear()` already
            // reloads timelines for a sign-out/account-switch teardown that runs just
            // before this fires — a second reload here is a little redundant in that one
            // case, but harmless, and this is the only chokepoint that also covers
            // sign-in, the cold-launch restore, and the LS-3 rejected-token path, none of
            // which go through that clear().
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    var isLoading = false
    var errorMessage: String?
    var currentUser: User?
    var serverURL: String = ""
    var username: String = ""

    // Multi-server
    var accounts: [ServerAccount] = []
    var currentAccountId: String? { AccountStore.currentAccountId }

    /// Set by `login()`/`loginWithOIDC()` when the target server is plain HTTP to a
    /// non-local host and the attempt hasn't been explicitly acknowledged yet — no
    /// network request is made in that case. The presenting view should show a warning
    /// (naming the risk: username, password, tokens, and audiobook content all travel
    /// unencrypted) and, only on explicit confirmation, retry with
    /// `acknowledgedInsecureConnection: true`. This is enforced here — not just at the
    /// view layer — so every current and future call site (Add Server, SSO, switching a
    /// saved account) gets the same protection rather than relying on each view
    /// remembering to check first.
    var pendingInsecureConnection: PendingInsecureConnection?
    /// Review 7 Low (double parent gate): the account whose switch already passed the parent gate before
    /// raising the insecure prompt, so confirming it doesn't ask again.
    private var gatePassedForInsecurePromptAccountId: String?

    struct PendingInsecureConnection: Identifiable {
        var id: String { serverURL }
        let serverURL: String
    }

    /// Critique 2026-10-06 (harden): the saved server Sign Out is moving to, while that
    /// sign-in runs. The sign-in screen is already showing by then (the old session has
    /// ended), so its saved-servers list marks this row as in progress.
    var switchingAccountIdAfterSignOut: String?

    /// LS-3 (docs/design-review.md, Round 3): a monotonically increasing counter for the
    /// live session's identity, bumped by every login, OIDC sign-in, sign-out and account
    /// switch (see `tearDownAccountScopedState`, `login`, `loginWithOIDC`). Read by
    /// `verifyRestoredSession(generation:)`, which captures the value in effect when it
    /// starts and checks it again before touching `currentUser`/`isAuthenticated` — a
    /// verification still in flight when the account changes underneath it must not
    /// clobber the new session with a stale result.
    private var sessionGeneration = 0

    /// The background verification kicked off by `checkExistingSession()`. Kept so a
    /// sign-out/switch/login that follows can cancel it rather than let a slow request
    /// keep running against credentials that no longer apply.
    private var sessionVerificationTask: Task<Void, Never>?

    // MARK: Session expired mid-use (Polish pass J1-1, J1-2)

    /// What the "Sign in again" sheet (`SessionExpiredSheet`, in `LoginView.swift`) shows and
    /// signs back into: always the account whose session just ended — same server, same user.
    struct SessionExpiredPrompt: Identifiable, Equatable {
        var id: String { "\(serverURL)|\(username)" }
        let serverURL: String
        let username: String
        /// The server's user id for this session, when known — a re-sign-in as anyone else
        /// is refused (`isSameAccount`).
        let userId: String?
        let usesSingleSignOn: Bool
        let customHeaders: [String: String]
        var host: String { URL(string: serverURL)?.host ?? serverURL }
    }

    /// Polish pass (J1-2): the server and username of a session the cold-launch check found
    /// rejected, so the sign-in screen opens prefilled and says why it's showing.
    struct SessionEndedPrefill: Hashable {
        let serverURL: String
        let username: String
        let customHeaders: [String: String]
        var message: String {
            let host = URL(string: serverURL)?.host ?? serverURL
            return String(localized: "Your session on \(host) ended. Sign in again.", comment: "Sign-in screen line after a saved session was refused at launch; %@ is the server host")
        }
    }

    /// Non-nil while the "Sign in again" sheet should be up. Set when the server refuses the
    /// session mid-use (`.shelfheadSessionExpired`); `isAuthenticated` stays true, so the
    /// player, downloads and the offline progress queue are untouched underneath it.
    var sessionExpiredPrompt: SessionExpiredPrompt?
    /// True from the moment the session was refused until a re-sign-in succeeds — stays true
    /// after "Not Now", so a later surface can still tell the session needs signing in.
    private(set) var sessionNeedsSignIn = false
    /// A sign-in-again attempt is running (drives the sheet's progress state).
    private(set) var isReauthenticating = false
    /// Why the last sign-in-again attempt failed, shown inside the sheet.
    var reauthErrorMessage: String?
    /// See `SessionEndedPrefill`. Read by `LoginView`; cleared by the next successful sign-in.
    var sessionEndedPrefill: SessionEndedPrefill?

    /// After "Not Now", the sheet stays away this long even if more requests are refused.
    nonisolated static let sessionExpiredSnooze: TimeInterval = 10 * 60
    @ObservationIgnored private var sessionExpiredDismissedAt: Date?
    /// The cold-launch check owns a rejection it sees itself (it signs out, J1-2), so the
    /// in-place sheet stays out of its way while it runs.
    @ObservationIgnored private var isVerifyingRestoredSession = false
    /// `switchAccount` is moving to another account: a refusal of the outgoing one is moot.
    @ObservationIgnored private var isSwitchingAccount = false
    @ObservationIgnored private var sessionExpiredObserver: NSObjectProtocol?

    init() {
        // Polish pass (J1-1): `AudiobookshelfAPI` posts this from its own actor; hop to the
        // main actor here. `queue: nil` on purpose — never block the poster on the main queue.
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: .shelfheadSessionExpired, object: nil, queue: nil
        ) { [weak self] note in
            let generation = note.userInfo?["generation"] as? Int
            Task { @MainActor [weak self] in
                await self?.handleSessionExpiredSignal(generation: generation)
            }
        }
    }

    func loadAccounts() async {
        accounts = await AccountStore.accounts()
    }

    /// Normalizes and validates a server URL: trims, defaults to https when no scheme is
    /// given, requires an http/https scheme and a non-empty host, and rebuilds a clean
    /// URL from just scheme + host + explicit port + path — deliberately dropping
    /// (rejecting, not silently stripping) anything else a pasted URL might carry.
    ///
    /// A prior version of this function only checked scheme/host and left everything
    /// else in the string as-is, so `https://user:pass@example.com/base?token=x#frag`
    /// would have passed through untouched — userinfo, a query string, and a fragment
    /// have no legitimate reason to be part of a *server base address*, and silently
    /// keeping them risks sending a leftover token or credential pair as part of every
    /// subsequent request built from this string. Rejecting outright (returning nil,
    /// which surfaces as "enter a valid server address") is safer than guessing which
    /// part the user actually meant.
    ///
    /// A server deployed under a subpath (e.g. `https://example.com/audiobookshelf`) is
    /// supported — the path component is preserved as-is (minus a trailing slash) — but
    /// deployments with query/fragment/userinfo in the base address are not.
    static func normalizedServerURL(_ raw: String) -> String? {
        // Item 22: the implementation moved to `ServerURLRules` (Shared/, both targets);
        // this forwarder keeps the existing call sites and `AuthViewModelURLTests` intact.
        ServerURLRules.normalizedServerURL(raw)
    }

    /// True if `host` is local to this device or on a private network segment — RFC1918
    /// IPv4 ranges, IPv4/IPv6 link-local, IPv6 unique-local, loopback, `localhost`, and
    /// `.local` (mDNS/Bonjour) names. Used to decide whether a plain-HTTP connection can
    /// be allowed without an explicit "I understand the risk" confirmation: a LAN address
    /// or a Tailscale/WireGuard private range is the normal, expected way to reach a
    /// self-hosted server without TLS, but a public hostname over HTTP means credentials,
    /// tokens, and audiobook content travel in the clear over the open internet.
    /// Marked `nonisolated` (rather than inheriting the class's `@MainActor`) because it's a
    /// pure function over a string — no actor-isolated state — and `ServerAccount`, a plain
    /// non-actor struct, calls it synchronously from its own `isInsecureRemoteConnection`
    /// computed property; that call site can't `await` a main-actor-isolated static method.
    nonisolated static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        ServerURLRules.isLocalOrPrivateHost(rawHost)
    }

    /// True when `cleanURL` (already normalized by `normalizedServerURL`) is plain HTTP
    /// to a host that ISN'T local/private — i.e. exactly the case where credentials and
    /// tokens would travel unencrypted over a network an attacker could plausibly
    /// observe. Callers should block the connection until the user explicitly confirms.
    static func requiresInsecureConnectionConfirmation(for cleanURL: String) -> Bool {
        ServerURLRules.requiresInsecureConnectionConfirmation(for: cleanURL)
    }

    // MARK: - Account lifecycle cleanup

    /// Why account-scoped state is being torn down. Fix 5 (REVIEW-2026-09-09.md): sign
    /// out, switching accounts and deleting a saved account used to clean up three
    /// different subsets of the same state — `logout()` did the most, `switchAccount`
    /// less (Up Next, Spotlight and the widget snapshot survived it), and `removeAccount`
    /// least of all (it never touched the removed account's downloads). They now share
    /// `tearDownAccountScopedState(reason:)`, and this is what selects the few
    /// differences that are genuinely intentional.
    enum AccountTeardownReason: Equatable {
        /// Sign Out with no other saved server left, Remove All Servers from This Device,
        /// and removing the current account. The most thorough: per-book speeds and the
        /// cover caches go too. (Sign Out with other servers still saved uses
        /// `.accountSwitch` — see `signOutTeardownReason`.)
        ///
        /// `playbackAlreadyStopped` is `true` only when the caller has already
        /// awaited `stopPlaybackAndTransfers()` itself and this routine must not do
        /// it again — see `removeAccount(_:)`, the one caller that has to flush the
        /// final position *before* the credentials it is deleting go away.
        case signOut(playbackAlreadyStopped: Bool)
        /// Switching to another saved account. Everything account-scoped is dropped, but
        /// caches that are keyed by something already account-unique (cover URLs) and
        /// preferences the user would want back on switching *back* (per-book speeds) are
        /// deliberately kept.
        case accountSwitch
        /// Deleting a saved account, named by its download scope key so the on-disk tree
        /// can be found for an account that isn't the one signed in. Deliberately does
        /// NOT touch the live session: removing the *current* account composes this with
        /// the Sign Out tail (see `removeAccount`), which is where the session teardown belongs.
        ///
        /// `wasActiveScope` is captured by `removeAccount(_:)` *before*
        /// `AccountStore.remove` clears the current-account id, because by the time this
        /// case is handled `DownloadManager.currentScopeKey()` can no longer recognise the
        /// removed account's scope as the one whose books the in-memory download caches
        /// describe (item 12 follow-up, REVIEW-2026-09-09-REMAINING.md).
        case accountRemoval(scopeKey: String, wasActiveScope: Bool)

        /// Whether `tearDownAccountScopedState` is itself responsible for stopping
        /// playback and awaiting the final position flush. False for account removal
        /// (which deliberately leaves the live session alone — the removal path stops
        /// playback *before* it ever gets here) and for the sign-out that follows such
        /// a removal, where the flush has already been awaited once.
        var stopsPlayback: Bool {
            switch self {
            case .signOut(let alreadyStopped): return !alreadyStopped
            case .accountSwitch: return true
            case .accountRemoval: return false
            }
        }

        /// Payload-insensitive `== .signOut`, kept as a property so adding the
        /// `playbackAlreadyStopped` payload didn't turn one readable check into a
        /// `if case` in the middle of the routine.
        var isSignOut: Bool {
            if case .signOut = self { return true }
            return false
        }
    }

    /// The one cleanup routine shared by sign-out, account switch and account removal.
    ///
    /// Ordering is deliberate: playback stops *and its final position finishes being
    /// written* first, then in-flight transfers are cancelled (so nothing keeps writing
    /// while state is being dismantled), then in-memory/shared surfaces (Up Next, the
    /// widget's App Group snapshot, Spotlight), then per-account persistent state on
    /// disk. That first step is why this routine is `async`: `AudioPlayerService`
    /// `stopAndFlush()` awaits the position sync and session close, and every caller has
    /// to hold off swapping or clearing `AuthStore` until it returns.
    ///
    /// Posting `.shelfheadAccountChanged` is deliberately NOT part of this
    /// routine and stays with each caller, because "after everything" means something
    /// different in each: Sign Out (`finishEndingLiveSession`) and Remove All Servers post
    /// it after clearing the session, `switchAccount` only once the *new* login has succeeded (posting mid-switch would kick a reload
    /// against half-swapped credentials), and removing a non-current account changes
    /// nothing about the live session so posts nothing at all.
    func tearDownAccountScopedState(reason: AccountTeardownReason) async {
        switch reason {
        case .signOut, .accountSwitch:
            // 0. LS-3: the session that any in-flight `verifyRestoredSession(generation:)`
            // captured is ending — bump the generation so it drops its result instead of
            // signing this (now different, or absent) session out, and cancel it outright
            // so it stops making a request against credentials about to be cleared.
            sessionGeneration += 1
            sessionVerificationTask?.cancel()
            // Polish pass (J1-1, J1-2): the session a prompt or prefill was about is ending.
            sessionExpiredPrompt = nil
            sessionNeedsSignIn = false
            sessionEndedPrefill = nil

            // 1. Stop playback and transfers — `stopPlaybackAndTransfers()` below.
            //
            // Skipped when the caller has already run that step itself. The only
            // caller that does is `removeAccount(_:)` deleting the account it is
            // signed in as: item 12 (REVIEW-2026-09-09-REMAINING.md) — the flush has
            // to happen before `AccountStore.remove` clears the current-account id,
            // because the final position's *local* write lands in
            // `Downloads/accounts/<scope>/<item>/manifest.json` by way of
            // `currentScopeKey()`, and that key stops resolving to the removed
            // account the moment the id is gone. The flag is what keeps this routine
            // from issuing a second `stop()` racing the flush that already ran.
            if reason.stopsPlayback {
                await stopPlaybackAndTransfers()
            }

            // 2. In-memory + shared-container surfaces.
            //
            // SEC-4 (REVIEW_2026-08-12.md) is why sign-out clears the Up Next queue and
            // the Watch's mirrored state at all: both survived a "sign out" and stayed
            // readable/playable by whoever signed in next. Fix 5's contribution is that
            // an account *switch* now runs the same steps.
            //
            // Up Next before the widget snapshot, not after: `clearQueue()` persists the
            // emptied queue, which republishes it into `SharedLibrary` — doing it the
            // other way round would re-populate the snapshot immediately after clearing
            // it. `PlaybackCoordinator.shared.playerViewModel` is the same weak,
            // loosely-coupled hook `PlaybackIntents.swift` uses to reach the live view
            // model from outside the view hierarchy.
            //
            // The queue is cleared rather than scoped per account: `upNext.json` lives in
            // the App Group under one unscoped name, and making it per-scope would need a
            // reload hook on `PlayerViewModel` (which only reads the file in `init`) plus
            // its own eviction story for accounts that no longer exist — more machinery
            // than "switching accounts empties Up Next" is worth. Before this, the
            // outgoing account's books stayed queued and auto-advance could try to play
            // another server's item id.
            PlaybackCoordinator.shared.playerViewModel?.clearQueue()
            // Sign-out never called this directly — the only clear path was a
            // `MainTabView.onReceive` on the very view `isAuthenticated = false` was
            // dismantling, so the previous account's titles and cover JPEGs could stay
            // pickable on the Home Screen.
            WidgetLibraryPublisher.clear()
            // Indexing is additive under one domain per account, so without this both
            // servers' titles stayed searchable system-wide after a switch and tapping a
            // stale result silently did nothing.
            SpotlightIndexer.removeAll()

            // 3. Persistent state for the outgoing account.
            //
            // S5 (REVIEW_2026-08-20_UI_SECURITY.md): a paused download's resume blob
            // embeds its original request's `Authorization` header. Swept while
            // `currentScopeKey()` still resolves to the outgoing account — callers must
            // not clear `AuthStore` before this runs.
            DownloadManager.shared.deleteAllPersistedPausedResumeBlobs(
                scopeKey: DownloadManager.shared.currentScopeKey())
            // Stage 2 (standalone Watch app): an account switch used to leave the
            // outgoing account's session cached in the Watch's own Keychain
            // indefinitely. Deliberately cleared *before* the new login is attempted (see
            // `switchAccount`), so a failed switch fails toward "the Watch has no
            // session" rather than "the Watch still has the old one."
            WatchSessionManager.shared.clearWatchState()

            if reason.isSignOut {
                // Per-book speeds are keyed by book id, so they're harmless across
                // accounts — kept on a switch precisely so switching back restores them,
                // dropped on sign-out because nobody is signed in to own them.
                SettingsStore.clearPerBookSpeeds()
                SettingsStore.clearPerBookChapterSkips()   // Batch 399: same reasoning
                // Covers are keyed by their full URL (server host included), so a switch
                // has no cross-account confusion to fix and clearing would just force a
                // re-download of the visible grid. Sign-out is different: the artwork of
                // a server nobody is signed into shouldn't sit in `Caches/`.
                DiskCoverCache.clear()
                CoverImageCache.shared.removeAllObjects()
                // Batch 315: the cover-version registry is keyed by item id, and ids are
                // per-server — a new account must not inherit the old one's versions.
                CoverVersions.reset()
            }

        case .accountRemoval(let scopeKey, let wasActiveScope):
            // Everything here is addressed by the removed account's own scope key rather
            // than `currentScopeKey()`, since the account being deleted usually isn't the
            // one signed in.
            DownloadManager.shared.deleteAllPersistedPausedResumeBlobs(scopeKey: scopeKey)
            SpotlightIndexer.remove(scopeKey: scopeKey)
            // The finding this fix is named for: nothing deleted
            // `Downloads/accounts/<scope>`, and neither storage accounting nor Remove All
            // walks a non-current scope, so a removed account's downloads became
            // gigabytes that were both invisible and unreclaimable.
            //
            // `wasActiveScope` is the item 12 follow-up: it tells `deleteDownloads` to
            // also drop the in-memory `downloadedItems`/`manifests`/`failedDownloads`/
            // cover-flag caches, which describe the removed account's books and would
            // otherwise keep every "is this downloaded?" surface answering yes for files
            // that are gone. `currentScopeKey()` can't work this out for itself here —
            // `AccountStore.remove` cleared the current-account id one step earlier.
            DownloadManager.shared.deleteDownloads(forScopeKey: scopeKey, wasActiveScope: wasActiveScope)
            // Same class of residue left behind by every removal made before that fix
            // existed. Safe because it only ever reclaims scopes absent from a
            // saved-account list that has been verified to still contain the active
            // account — see `DownloadManager.canRunOrphanScopeSweep`.
            //
            // Skipped outright when the account being removed was the active one: with
            // nobody signed in there is no account left to verify the saved-account list
            // against, so the sweep could only be a no-op. Saying so here beats letting it
            // walk `accounts/` and decide `false` for every directory by accident — and
            // the residue it would have reclaimed is picked up by the next removal made
            // while signed in.
            if !wasActiveScope {
                DownloadManager.shared.reclaimOrphanedDownloadScopes(knownScopeKeys: savedScopeKeys())
            }
        }
    }

    /// Stops playback, waits for the final position to finish being written, and
    /// cancels in-flight transfers. Step 1 of every teardown that ends a live session,
    /// extracted so `removeAccount(_:)` can run it at the one moment that is correct
    /// for a *current-account* removal (before the credentials and the download tree
    /// are deleted) without duplicating it.
    ///
    /// LOW (REVIEW-2026-09-09.md, now fixed): this was a bare `stop()`, which
    /// flushes the final position through unawaited tasks that read `AuthStore`
    /// when they *run* — so the outgoing account's last position could still be
    /// lost, or pushed to whichever server the token had meanwhile become, on a
    /// switch or a sign-out. `stopAndFlush()` (see its doc comment) is `stop()`
    /// plus a wait for exactly those writes, so by the time this returns the
    /// position sync, the session close and the offline-queue drain have all
    /// finished against the *outgoing* account's credentials. Every caller
    /// awaits this routine before touching `AuthStore`.
    ///
    /// Deliberately the service-level stop, not `PlayerViewModel.stop()`: the view
    /// model's stop is `playerService.stop()` plus clearing `currentBook`/
    /// `showFullPlayer`, and calling it here would issue a *second* `stop()`
    /// racing the awaited flush. The view-model half is already handled by
    /// `ContentView`'s `.shelfheadAccountChanged` receiver (`currentBook = nil`
    /// plus the navigation reset), which each caller posts once the transition is
    /// actually complete.
    /// Called on every successful sign-in, after `AccountStore.upsert` made the new account
    /// current and before `.shelfheadAccountChanged`. Clears the unscoped App Group records
    /// (playback snapshot + cover, widget library, Up Next) when another or an unknown
    /// account left them — a session that ended without `tearDownAccountScopedState` — then
    /// records the new owner. See `SharedPlayback.ownerAccountId`.
    private func claimSharedPlaybackRecords() {
        let incoming = AccountStore.currentAccountId
        if SharedPlayback.recordsNeedClearing(owner: SharedPlayback.ownerAccountId, incoming: incoming) {
            SharedPlayback.write(nil)
            SharedPlayback.writeCover(nil)
            PlaybackCoordinator.shared.playerViewModel?.clearQueue()
            WidgetLibraryPublisher.clear()   // after the queue: `clearQueue()` republishes it
        }
        SharedPlayback.setOwnerAccountId(incoming)
    }

    private func stopPlaybackAndTransfers() async {
        await AudioPlayerService.shared.stopAndFlush()
        // Cancel in-flight downloads so their retries don't send the new account's
        // token to the previous server — and, on an account removal, so nothing is
        // still writing into a download tree that is about to be deleted.
        DownloadManager.shared.cancelAllActiveDownloads()
    }

    /// Download scope keys of every currently-saved account. `accounts` is refreshed from
    /// the Keychain by `loadAccounts()`, which `removeAccount` calls before teardown.
    private func savedScopeKeys() -> Set<String> {
        // Plus signed-out accounts' scopes, which wait for a sign-in to the same server
        // (sign-out fix, 6 Oct 2026) and must not be swept as orphans meanwhile.
        Set(accounts.map { DownloadManager.scopeKey(serverURL: $0.serverURL, accountId: $0.id) })
            .union(AccountStore.retainedScopeKeys())
    }

    // MARK: - Switching accounts

    /// How a saved account can be signed back into.
    enum ReauthenticationMethod: Equatable {
        case password(String)
        case singleSignOn
        /// Nothing on this device can re-authenticate this account (password storage is
        /// off, or the entry was lost) — the user has to enter credentials again.
        case unavailable
    }

    /// Pure decision extracted for testability: which sign-in path `switchAccount` should
    /// take for a saved account, given whatever password entry the Keychain holds for it.
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): `switchAccount` used to accept *any* non-nil stored
    /// password, and `loginWithOIDC` stores `""` for an SSO account — so switching to an
    /// SSO account tore down the live session and then ran a username/password login with
    /// an empty password, which could only fail. An explicit `usesSingleSignOn` flag now
    /// marks new SSO accounts, and an empty-but-present password entry (the on-disk
    /// fingerprint of an SSO account saved before that flag existed) is read the same way
    /// rather than as a real credential.
    ///
    /// A *missing* entry stays `.unavailable`: that's what "Stay signed in" being off
    /// looks like for a password account, and the caller's existing "add it again"
    /// message is the right answer for it.
    nonisolated static func reauthenticationMethod(
        for account: ServerAccount, storedPassword: String?
    ) -> ReauthenticationMethod {
        if account.isMarkedSingleSignOn { return .singleSignOn }
        guard let storedPassword else { return .unavailable }
        if storedPassword.isEmpty { return .singleSignOn }
        return .password(storedPassword)
    }

    /// `reauthenticationMethod(for:storedPassword:)` with the Keychain read done for the
    /// caller. Critique 2026-10-06 (harden): every switch entry point asks this BEFORE
    /// showing its "Switch to …?" confirmation, so a server with nothing stored to sign in
    /// with opens a prefilled sign-in instead of a "Switch" that can't work.
    func reauthenticationMethod(for account: ServerAccount) async -> ReauthenticationMethod {
        Self.reauthenticationMethod(for: account, storedPassword: await AccountStore.password(for: account))
    }

    /// What a saved-server tap should open first. Pure, pinned by `ServerSwitchOutcomeTests`.
    enum SwitchEntry: Equatable {
        /// The shared `ServerSwitchConfirmation`, then `switchAccount`.
        case confirmSwitch
        /// Nothing stored to sign in with ("Stay signed in" off, or the entry was lost):
        /// Add Server prefilled with this server and username, asking for the password.
        /// Its Connect runs the same switch confirmation (`addServerSignInKind`).
        case askForPassword
    }

    nonisolated static func switchEntry(for method: ReauthenticationMethod) -> SwitchEntry {
        if case .unavailable = method { return .askForPassword }
        return .confirmSwitch
    }

    /// Critique 2026-10-06 (harden): what `switchAccount` did. It used to report only
    /// through `errorMessage`, which only the first-run sign-in screen renders, so a switch
    /// started from Settings, Other Servers or Home failed without a word.
    enum AccountSwitchOutcome: Equatable {
        case switched
        /// Nothing stored to sign in with. Nothing was touched.
        case needsPassword
        /// The plain-HTTP-to-a-public-host gate is up (`pendingInsecureConnection`).
        /// Nothing was sent and nothing was touched.
        case awaitingInsecureConfirmation
        /// The SSO sheet was closed. Nothing was touched: the teardown runs only once the
        /// identity provider has answered (`loginWithOIDC`).
        case cancelled
        case failed(AccountSwitchFailure)
    }

    /// A failed switch, with what the alert needs to say where the user now is.
    struct AccountSwitchFailure: Equatable {
        enum Reason: Equatable {
            /// The reachability check before the teardown failed, so nothing was stopped.
            case unreachable(failure: ServerConnectionFailure?, resolvedURL: String?)
            /// The sign-in itself failed (`loginFriendlyMessage` wording).
            case signInFailed(String)
        }
        /// The server the user tried to switch to.
        let targetHost: String
        /// The server still signed in afterwards, or nil when nobody is.
        let currentHost: String?
        /// True when the account-switch teardown ran before the failure: playback stopped
        /// (its position flushed) and Up Next was cleared.
        let stoppedPlayback: Bool
        /// The book that was loaded when that happened, if any.
        let stoppedBookTitle: String?
        let reason: Reason
    }

    /// Critique 2026-10-06 (harden): whether the reachability check `switchAccount` makes
    /// before its teardown should stop the switch there. Only for failures where the
    /// sign-in could not get through either (no network, DNS, refused, timeout, TLS) — so
    /// an unreachable server leaves the current book playing. NOT for an HTTP status or a
    /// non-Audiobookshelf answer: a proxy gate can block or rewrite `/ping` while the
    /// sign-in itself works (the reason Add Server has "Sign in anyway"), so those go on
    /// to the sign-in and its own result. Pure, pinned by `ServerSwitchOutcomeTests`.
    @MainActor
    static func switchPreflightBlocks(_ result: ReachabilityStore.ConnectionTestResult) -> Bool {
        switch result.outcome {
        case .invalidURL:
            return true
        case .unreachable:
            switch result.failure {
            case .secureConnection, .timedOut, .hostNotFound, .cannotConnect, .offline:
                return true
            case .httpStatus, .other, nil:
                return false
            }
        case .reachable, .reachableInsecure, .notAudiobookshelf:
            return false
        }
    }

    /// True when the last `login`/`loginWithOIDC` ran the account-switch teardown (the old
    /// book stopped, Up Next cleared) before it returned. Read by `switchAccount` to say
    /// so in a failure.
    private(set) var lastSignInEndedSession = false

    /// Switches to a saved account by re-authenticating it — with its stored password, or
    /// through a fresh SSO sign-in for an account that has no password on this device.
    ///
    /// Critique 2026-10-06 (harden): returns what happened, and leaves `errorMessage` clear
    /// (the reason travels in the result), so the surface that started the switch can say
    /// it and a stale message can't turn up later on the sign-in screen. Order:
    /// 1. Nothing stored to sign in with → `.needsPassword`, before anything is touched
    ///    (Fix 5 ordering). Callers check `switchEntry` first, so this is a backstop.
    /// 2. The plain-HTTP gate, before anything is sent (not even the check below: it
    ///    would carry the proxy headers over plain HTTP).
    /// 3. A reachability check (`ReachabilityStore.testConnection`, the Add Server test)
    ///    BEFORE the teardown. Chosen so an unreachable server (Tailscale off, wrong
    ///    Wi-Fi) fails with the book still playing, at the cost of one `/ping` (plus
    ///    `/status` when it answers) on every switch. `switchPreflightBlocks` says which
    ///    failures stop it here.
    /// 4. The sign-in, through `login`/`loginWithOIDC` with `endingCurrentSession`, which
    ///    tear down only once nothing else can stop them (for SSO, after the sheet).
    ///
    /// `userAllowedInsecureConnection`: the user has just allowed this plain-HTTP
    /// connection (`confirmInsecureConnectionAndSwitch`), whether or not that choice
    /// reached the Keychain.
    ///
    /// Parent gate (kids profiles): leaving a child's account for an adult one asks for the parent's
    /// Face ID / passcode first, before anything else runs; a failed or cancelled check returns `.cancelled`
    /// (nothing touched, nothing to show). `parentGateChecked`: the caller already ran it.
    @discardableResult
    func switchAccount(_ account: ServerAccount,
                       userAllowedInsecureConnection: Bool = false,
                       parentGateChecked: Bool = false) async -> AccountSwitchOutcome {
        guard await passesParentGate(switchingTo: account, alreadyChecked: parentGateChecked) else { return .cancelled }
        // Polish pass (J1-1): a refusal of the outgoing session mid-switch must not raise the sheet.
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        // Fix 5 ordering: work out whether a login is even possible BEFORE any
        // destructive teardown. This used to stop playback, cancel downloads and wipe the
        // Watch credential first and *then* discover there was nothing to log in with.
        let method = await reauthenticationMethod(for: account)
        guard method != .unavailable else { return .needsPassword }

        let acknowledged = account.hasAcknowledgedInsecureConnection || userAllowedInsecureConnection
        if let clean = Self.normalizedServerURL(account.serverURL),
           Self.requiresInsecureConnectionConfirmation(for: clean), !acknowledged {
            errorMessage = nil
            pendingInsecureConnection = PendingInsecureConnection(serverURL: clean)
            gatePassedForInsecurePromptAccountId = account.id   // Review 7 Low (double parent gate)
            return .awaitingInsecureConfirmation
        }

        let wasSignedIn = isAuthenticated
        let previousHost = wasSignedIn ? (URL(string: serverURL)?.host ?? serverURL) : nil
        let test = await ReachabilityStore.testConnection(rawURL: account.serverURL,
                                                          customHeaders: account.customHeaders ?? [:])
        if Self.switchPreflightBlocks(test) {
            ShelfLog.error(.servers, "Switch to account \(account.id) stopped before teardown: server unreachable (\(String(describing: test.failure))).")
            return .failed(AccountSwitchFailure(
                targetHost: account.displayHost, currentHost: previousHost,
                stoppedPlayback: false, stoppedBookTitle: nil,
                reason: .unreachable(failure: test.failure, resolvedURL: test.resolvedURL)))
        }

        // Nobody signed in (the first-run screen's saved servers, or Sign Out moving on):
        // run the teardown up front as this always has, so nothing a previous session
        // left (the Watch's cached session, resume blobs) survives into the new one.
        // With a live session, `login`/`loginWithOIDC` run it at the last safe moment.
        if !wasSignedIn {
            await tearDownAccountScopedState(reason: .accountSwitch)
        }
        let bookTitle = PlaybackCoordinator.shared.playerViewModel?.currentBook?.title

        let didSignIn: Bool
        switch method {
        case .password(let password):
            didSignIn = await login(serverURL: account.serverURL, username: account.username, password: password,
                                    customHeaders: account.customHeaders ?? [:],
                                    acknowledgedInsecureConnection: acknowledged,
                                    endingCurrentSession: true)
        case .singleSignOn:
            didSignIn = await loginWithOIDC(
                serverURL: account.serverURL,
                customHeaders: account.customHeaders ?? [:],
                acknowledgedInsecureConnection: acknowledged,
                endingCurrentSession: true)
        case .unavailable:
            return .needsPassword   // unreachable: guarded above.
        }
        // `login`/`loginWithOIDC` post `.shelfheadAccountChanged` themselves on success
        // (this used to post it a second time, reloading everything twice).
        if didSignIn { return .switched }
        if pendingInsecureConnection != nil { return .awaitingInsecureConfirmation }

        let reason = errorMessage
        errorMessage = nil
        // A closed SSO sheet leaves no message and, since the teardown now waits for the
        // identity provider, nothing stopped.
        if reason == nil, case .singleSignOn = method, !lastSignInEndedSession { return .cancelled }
        let stopped = lastSignInEndedSession
        return .failed(AccountSwitchFailure(
            targetHost: account.displayHost,
            currentHost: isAuthenticated ? (URL(string: serverURL)?.host ?? serverURL) : nil,
            stoppedPlayback: stopped,
            stoppedBookTitle: stopped ? bookTitle : nil,
            reason: .signInFailed(reason ?? String(localized: "Couldn\u{2019}t sign in."))))
    }

    /// What a sign-in from the Add Server form does to the session that's already live.
    enum AddServerSignInKind: Equatable {
        /// Nobody is signed in (first run, or after Sign Out): a plain sign-in.
        case firstSignIn
        /// The same server and username as the live session: a re-sign-in that replaces
        /// its tokens. Nothing account-scoped changes, so nothing is torn down.
        case sameAccount
        /// A different server or user: an account switch, which stops the current book and
        /// clears Up Next, so it confirms first and tears down before signing in.
        case switchesAccount
    }

    /// Critique 2026-10-06 (harden): Add Server used to sign in over a live session with no
    /// confirmation and no teardown, so the old book kept playing with its position writes
    /// racing the new credentials. This is the decision the form and `login`/`loginWithOIDC`
    /// act on. `newUsername` is nil for SSO, where the user isn't known until the identity
    /// provider answers, so an SSO sign-in over a live session always counts as a switch.
    /// Addresses compare by `AccountStore.identityAddress` (scheme-insensitive, like the
    /// retained-id identity). Pure, pinned by `AddServerSwitchTests`.
    nonisolated static func addServerSignInKind(isAuthenticated: Bool,
                                                currentServerURL: String, currentUsername: String,
                                                newServerURL: String, newUsername: String?) -> AddServerSignInKind {
        guard isAuthenticated else { return .firstSignIn }
        guard let newUsername else { return .switchesAccount }
        let newAddress = ServerURLRules.normalizedServerURL(newServerURL) ?? newServerURL
        let sameServer = AccountStore.identityAddress(newAddress) == AccountStore.identityAddress(currentServerURL)
        return sameServer && newUsername == currentUsername ? .sameAccount : .switchesAccount
    }

    /// Runs the account-switch teardown for a sign-in that replaces the live session, when
    /// `endingCurrentSession` says it does and someone is signed in. Called by `login` and
    /// `loginWithOIDC` after their checks that send nothing (address, insecure-connection
    /// gate) and before the network sign-in, because a successful sign-in writes the new
    /// tokens into `AuthStore` at once: the old book's final position has to be flushed
    /// against the old credentials first (the same order `switchAccount` uses).
    ///
    /// Returns whether it tore down. If the new sign-in then fails, the previous server's
    /// session is still live (nothing touched `AuthStore` or the Keychain), its book has
    /// stopped with its place saved, and Up Next is empty; the callers then drop the
    /// stopped book from the UI (`clearStoppedBookAfterFailedSwitch`). The Watch's
    /// cached session is cleared either way, which fails toward "the Watch has no session"
    /// as `switchAccount` does. (A failure *after* the new tokens are written — a Keychain
    /// write, or SSO's profile fetch — keeps each path's existing rollback.)
    private func tearDownForReplacedSession(_ endingCurrentSession: Bool) async -> Bool {
        guard endingCurrentSession, isAuthenticated else { return false }
        await tearDownAccountScopedState(reason: .accountSwitch)
        lastSignInEndedSession = true
        return true
    }

    /// Critique 2026-10-06 (harden): after a teardown whose sign-in then failed, the same
    /// account is still signed in, so this drops only the stopped book from the mini
    /// player (what `ContentView`'s `.shelfheadAccountChanged` receiver does with
    /// `currentBook = nil`). It used to post `.shelfheadAccountChanged`, whose receiver
    /// also resets every tab's navigation: that popped Settings > Account & Security and
    /// Other Servers, and with them the Add Server sheet and the failure alert, so the
    /// reason was never seen. Spotlight and the widget snapshot, cleared by the teardown,
    /// come back on the next library load.
    private func clearStoppedBookAfterFailedSwitch() {
        guard let player = PlaybackCoordinator.shared.playerViewModel else { return }
        player.showFullPlayer = false
        player.currentBook = nil
    }

    /// Kids profiles: true when the switch may go ahead, after asking the parent when it leaves a child's account for
    /// an adult one (`ParentGate.switchNeedsGate(from:to:)`).
    private func passesParentGate(switchingTo account: ServerAccount, alreadyChecked: Bool) async -> Bool {
        guard !alreadyChecked,
              ParentGate.switchNeedsGate(from: AccountStore.currentAccountId, to: account.id) else { return true }
        return await ParentGate.authenticate(reason: String(localized: "Open a grown-up's account", comment: "Reason shown in the Face ID / passcode prompt when leaving a child's profile"))
    }

    /// Re-attempts `switchAccount` after the user has explicitly confirmed an insecure
    /// (plain-HTTP, non-local) connection from the `pendingInsecureConnection` prompt,
    /// and persists that acknowledgement on the saved account so switching to it again
    /// later doesn't re-prompt every time.
    /// Returns whether the acknowledgement itself was persisted — `false` means the
    /// switch still goes ahead, but the user will be asked to confirm this same insecure
    /// connection again next time.
    ///
    /// Item 4: not surfaced via `errorMessage`, because the switch below calls
    /// `login()`/`loginWithOIDC()`, both of which clear `errorMessage` as their first act
    /// — anything set here would be wiped a line later. The caller shows its own alert
    /// once the switch has finished.
    ///
    /// Critique 2026-10-06 (harden): also returns the switch's outcome, so the caller can
    /// say why it failed. The switch is told the user just allowed the connection, so a
    /// failed acknowledgement write no longer raises the same prompt again straight away.
    @discardableResult
    func confirmInsecureConnectionAndSwitch(_ account: ServerAccount) async
        -> (acknowledged: Bool, outcome: AccountSwitchOutcome) {
        // Gate before the acknowledgement is written, so a cancelled check leaves the account untouched.
        // Review 7 Low (double parent gate): skip it when this account's switch already passed it.
        let gateDone = gatePassedForInsecurePromptAccountId == account.id
        gatePassedForInsecurePromptAccountId = nil
        guard await passesParentGate(switchingTo: account, alreadyChecked: gateDone) else { return (false, .cancelled) }
        let acknowledged = await AccountStore.setInsecureConnectionAcknowledged(true, for: account.id)
        if !acknowledged {
            ShelfLog.error(.servers, "Couldn't persist the insecure-connection acknowledgement for account \(account.id); it will be asked again.")
        }
        await loadAccounts()
        let refreshed = accounts.first(where: { $0.id == account.id }) ?? account
        let outcome = await switchAccount(refreshed, userAllowedInsecureConnection: true, parentGateChecked: true)
        return (acknowledged, outcome)
    }

    /// Current custom headers for the active connection (Settings screen reads this to
    /// prefill its editor).
    var customHeaders: [String: String] { AuthStore.shared.customHeaders }

    /// Updates the active connection's custom headers — used by Settings to add/edit
    /// reverse-proxy headers without a full re-login. Applies immediately in memory,
    /// persists to the Keychain mirror the CarPlay/Siri boot path reads, and updates the
    /// saved account entry so it's remembered next time this account is switched to.
    /// Returns whether the change was actually persisted for the saved account. Item 4:
    /// this was a discarded call. A failure means the headers work for the rest of this
    /// session but are gone from the saved account, so the next switch to this server
    /// connects without them and fails at the proxy.
    ///
    /// Reported as a return value rather than via `errorMessage` on purpose. The only
    /// caller is the Account & Security settings screen, and `errorMessage` is rendered
    /// only by `LoginView` and `AddServerView` — setting it here would show the user
    /// nothing now and then surface a stale, contextless banner the next time they
    /// reached a sign-in screen. `AccountSecuritySettingsView` shows an inline warning
    /// under the header editor instead, matching the invalid-header-name warning already
    /// in that section.
    @discardableResult
    func updateCustomHeaders(_ headers: [String: String]) async -> Bool {
        AuthStore.shared.setCustomHeaders(headers)
        await AudiobookshelfAPI.persistCustomHeadersToKeychain(headers)
        guard let id = currentAccountId else {
            // No saved account to update (signed out, or a session with no account
            // entry) — the in-memory + Keychain-mirror writes above are all there is to
            // do, so this isn't a failure.
            return true
        }
        let saved = await AccountStore.updateCustomHeaders(headers, for: id)
        await loadAccounts()
        return saved
    }

    /// Item 4: logs whichever half of an `AccountStore.upsert` didn't reach the Keychain.
    /// Both are non-fatal to the sign-in that just succeeded, which is why neither is
    /// surfaced as `errorMessage` from `login()`/`loginWithOIDC()` — see the call site.
    private static func logAccountPersistenceGaps(_ outcome: AccountStore.UpsertOutcome) {
        if !outcome.listSaved {
            ShelfLog.error(.servers, "Signed in, but the saved-server list didn't reach the Keychain; account \(outcome.account.id) won't be remembered.")
        }
        if !outcome.passwordStored {
            ShelfLog.error(.servers, "Signed in, but the password entry for account \(outcome.account.id) couldn't be written or cleared as requested.")
        }
    }

    /// Pure decision extracted for testability: whether removing `removedId` should also
    /// clear the live session, given the account that's currently active (`currentId`).
    /// T1 (REVIEW_2026-09-04_UI.md).
    nonisolated static func removalAlsoSignsOut(removedId: String, currentId: String?) -> Bool {
        removedId == currentId
    }

    /// One step of `removeAccount(_:)`. The function body below is a loop over
    /// `removalSteps(isCurrent:)` rather than a straight-line sequence precisely so the
    /// *order* — the whole substance of item 12 (REVIEW-2026-09-09-REMAINING.md) — is a
    /// pure value that can be pinned by a unit test, instead of the reading order of a
    /// function that also touches the Keychain, the filesystem and a live AVPlayer.
    enum AccountRemovalStep: Equatable, Hashable {
        /// `stopPlaybackAndTransfers()`: stop, await the final position flush, cancel
        /// in-flight downloads. Current-account removal only.
        case stopAndFlushPlayback
        /// `AccountStore.remove` + `loadAccounts()`. Also clears the current-account id
        /// (when the removed account *is* current) and purges the scope's `UserDefaults`
        /// keys, which is why nothing that resolves a scope key may run after it.
        case removeCredentials
        /// `tearDownAccountScopedState(reason: .accountRemoval(scopeKey:wasActiveScope:))` — resume
        /// blobs, Spotlight entries and the whole `Downloads/accounts/<scope>` tree.
        case deleteAccountScopedState
        /// End the live session (`finishEndingLiveSession`) and post
        /// `.shelfheadAccountChanged`, then move to another saved server the same way Sign
        /// Out does. Current-account removal only.
        ///
        /// Critique 2026-10-06 (harden): this used to call `logout()`, the full wipe — so
        /// removing the one server you were signed in to also removed every *other* saved
        /// server and password. It now ends only the removed server's session.
        case signOutSession
    }

    /// The order `removeAccount(_:)` performs its steps in.
    ///
    /// Item 12 (REVIEW-2026-09-09-REMAINING.md): removing the account you are signed in
    /// as used to delete its download tree — every book's `manifest.json`, which is the
    /// only local progress store and the only thing an offline resume reads — and only
    /// *then* sign out, whose teardown is what awaits
    /// `AudioPlayerService.stopAndFlush()`. So the currently-playing book's final
    /// position was flushed after its local manifest was already gone: the server write
    /// still landed, but nothing local survived, and any position that failed to reach
    /// the server sat in a scope whose files and credentials had both been deleted.
    ///
    /// The flush is therefore first, and specifically ahead of `.removeCredentials`, not
    /// merely ahead of the tree deletion: `AccountStore.remove` calls `clearCurrent()`,
    /// and both `DownloadManager.currentScopeKey()` and
    /// `AudioPlayerService.currentProgressScope()` read `AccountStore.currentAccountId`.
    /// After that call the manifest write inside `syncProgress()` would resolve to a
    /// different (nonexistent) `…|unknown` scope directory and the queued fallback entry
    /// would be filed under that scope too — i.e. flushing "after remove but before
    /// delete" would still lose the local write. This is also why the removal branch of
    /// `tearDownAccountScopedState` can't be the thing that flushes: by the time it runs,
    /// the current-account id is already gone.
    ///
    /// A non-current removal is unchanged and deliberately so — it must not interrupt
    /// playback of the account the user *is* signed in as.
    nonisolated static func removalSteps(isCurrent: Bool) -> [AccountRemovalStep] {
        guard isCurrent else {
            return [.removeCredentials, .deleteAccountScopedState]
        }
        return [.stopAndFlushPlayback, .removeCredentials, .deleteAccountScopedState, .signOutSession]
    }

    /// Removes a saved account. T1 (REVIEW_2026-09-04_UI.md): removing the *currently
    /// active* account previously only dropped its Keychain password and its entry in
    /// the saved-account list — the live session (`serverURL`/`username`, tokens,
    /// playback) was untouched, so "Current Account" kept showing the just-removed
    /// account and playback kept working with orphaned credentials until the user
    /// backgrounded the app or tapped Sign Out. Now, when the removed account is the
    /// current one, this also ends the live session — that server's only, since the
    /// 2026-10-06 critique (see `AccountRemovalStep.signOutSession`).
    ///
    /// Order matters, and lives in `removalSteps(isCurrent:)` above; see its doc comment
    /// for why the flush is first. Capturing `wasCurrent` BEFORE calling
    /// `AccountStore.remove` matters for the same reason: `remove` calls `clearCurrent()`
    /// when the removed id matches, so checking after would always read `false`.
    ///
    /// Playback is stopped exactly once and exactly one flush is awaited (the
    /// `.signOut` teardown is told the stop already happened), and
    /// `.shelfheadAccountChanged` is posted by `finishEndingLiveSession` at the end (and again
    /// by `switchAccount` if it then signs in to another saved server)
    /// — a non-current removal changes nothing about the live session and posts nothing.
    func removeAccount(_ account: ServerAccount) async {
        let wasCurrent = Self.removalAlsoSignsOut(removedId: account.id, currentId: AccountStore.currentAccountId)
        // Computed up front from the account's own fields (a pure static), so it stays
        // correct after `AccountStore.remove` has cleared the current-account id.
        let scopeKey = DownloadManager.scopeKey(serverURL: account.serverURL, accountId: account.id)
        // Captured for the same reason, and separately from `wasCurrent`: that flag is
        // about the *session* (removed id == current id), this one is about the *download
        // scope* whose books the in-memory caches describe. They agree in practice, but
        // each is used for what it actually means — and `currentScopeKey()` stops naming
        // the removed account the moment `AccountStore.remove` calls `clearCurrent()`.
        let wasActiveScope = scopeKey == DownloadManager.shared.currentScopeKey()

        for step in Self.removalSteps(isCurrent: wasCurrent) {
            switch step {
            case .stopAndFlushPlayback:
                // The fix for item 12: the removed account's credentials, its download
                // tree and its manifests are all still intact here, so the final position
                // reaches both the server and the local manifest before either goes away.
                await stopPlaybackAndTransfers()

            case .removeCredentials:
                // `AccountStore.remove` reports whether the updated account list actually
                // made it to the Keychain (see `AccountStore.save` for why that write
                // matters) — surface it so the user isn't left believing a removal worked
                // when a relaunch would show the account still there. Nothing after this
                // point may assume `currentScopeKey()` still names the removed account.
                let removed = await AccountStore.remove(account)
                await loadAccounts()
                if removed { KidProfileStore.standard.remove(accountId: account.id) }   // Review 7 Low (orphan kid profile)
                guard removed else {
                    // Deliberately returns rather than continuing: the download tree must
                    // never be deleted for an account that is still in the saved list.
                    errorMessage = String(localized: "Couldn't remove that server. Please try again.")
                    return
                }

            case .deleteAccountScopedState:
                // Fix 5 (REVIEW-2026-09-09.md): the removed account's paused-resume blobs
                // (S5, REVIEW_2026-08-20_UI_SECURITY.md — they embed an `Authorization`
                // header), its Spotlight entries and its whole download tree, all
                // addressed by this specific account's scope key rather than
                // `currentScopeKey()`, since the account being removed usually isn't the
                // one signed in. Runs BEFORE the sign-out step below (whose own teardown
                // pass sweeps the *active* scope's resume blobs and needs `AuthStore`
                // still intact), so the two passes each operate on the scope they mean to.
                await tearDownAccountScopedState(reason: .accountRemoval(
                    scopeKey: scopeKey, wasActiveScope: wasActiveScope))

            case .signOutSession:
                // The removed account was the live session. Critique 2026-10-06 (harden):
                // ends *that* session only — the same tail as Sign Out (this server), not
                // Remove All Servers, so the other saved servers and their passwords stay.
                // The teardown is told playback already stopped so it doesn't issue a
                // second `stop()` racing the flush awaited above. Its id is NOT retained:
                // the account was removed on purpose and `AccountStore.remove` already
                // forgot it, and its downloads were deleted one step earlier.
                let remaining = accounts.filter { $0.id != account.id }.count
                await tearDownAccountScopedState(reason: Self.signOutTeardownReason(
                    remainingSavedServers: remaining, playbackAlreadyStopped: true))
                await AudiobookshelfAPI.shared.logout()
                errorMessage = nil   // Critique 2026-10-06 (harden): as in `signOut`.
                await finishEndingLiveSession(leftBehind: [])
            }
        }
    }

    func checkExistingSession() async {
        // Polish pass (CR-4): `try?` used to read a locked Keychain (errSecInteractionNotAllowed —
        // e.g. a launch in the background before the first unlock since boot) as "no stored
        // credentials", which landed a signed-in user on the sign-in screen. Only a genuine
        // "not found" means signed out now; any other read error waits and retries, and never
        // deletes anything.
        let savedURL: String
        let savedToken: String
        switch await readStoredSession() {
        case .found(let url, let token):
            savedURL = url
            savedToken = token
        case .missing:
            // No stored credentials → require login.
            // PL-9: `isAuthenticated` is already false here and is never assigned on
            // this path, so its `didSet` never runs. A fresh install that has never
            // signed in would otherwise leave the flag unwritten, and the widget would
            // keep the account-agnostic "Start a book" copy instead of "Sign in".
            if SharedPlayback.setSignedIn(false) { WidgetCenter.shared.reloadAllTimelines() }
            return
        case .unavailable:
            // Still unreadable after the retries: show the sign-in screen for this run only.
            // The Keychain is untouched, so the next launch restores the session as normal.
            return
        }
        let savedRefresh: String? = try? await KeychainService.shared.get(.refreshToken)
        let savedUsername: String? = try? await KeychainService.shared.get(.username)
        let savedHeaders = await AudiobookshelfAPI.loadCustomHeadersFromKeychain()

        // Seed the in-memory store; the API layer will auto-refresh on 401.
        await AudiobookshelfAPI.shared.configure(
            serverURL: savedURL,
            accessToken: savedToken,
            refreshToken: savedRefresh,
            customHeaders: savedHeaders
        )
        // Live progress sync started at launch before these credentials existed; wake it.
        ServerEventSocket.shared.credentialsRestored()
        serverURL = savedURL
        username = savedUsername ?? ""
        // Review Medium 21 (30 October 2026): the Keychain survives a delete + reinstall but
        // `AccountStore.currentAccountId` (UserDefaults) doesn't, which left a live session
        // with no current account (downloads under `|unknown`, wrong sign-out branch).
        // Re-adopt the saved account this session belongs to. No saved account -> nothing to
        // adopt; `login()`'s `AccountStore.upsert` creates one on the next sign-in.
        if AccountStore.currentAccountId == nil,
           let id = Self.matchingAccountId(in: await AccountStore.accounts(), serverURL: savedURL, username: savedUsername) {
            AccountStore.setCurrent(id)
        }
        // Restore the session immediately from stored credentials so the app works
        // offline; only sign out if the server *actively rejects* us below.
        isAuthenticated = true
        // A restored session owns whatever its own last run left in the App Group. Seeds
        // the owner for records written before `SharedPlayback.ownerAccountId` existed, so
        // only a genuinely foreign sign-in clears them (`claimSharedPlaybackRecords`).
        if SharedPlayback.ownerAccountId == nil, let current = AccountStore.currentAccountId {
            SharedPlayback.setOwnerAccountId(current)
        }

        // LS-3 (docs/design-review.md, Round 3): the splash gates on this method, so it
        // must return as soon as the Keychain restore above completes — verifying the
        // token against the server used to be `await`ed right here too, which held a
        // static, spinner-less splash for the full request timeout on a slow or
        // unreachable self-hosted server. That verification now runs in the background,
        // captured so a sign-out/switch/login before it finishes can cancel it (see
        // `tearDownAccountScopedState`, `login`, `loginWithOIDC`).
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionVerificationTask?.cancel()
        sessionVerificationTask = Task { [weak self] in
            await self?.verifyRestoredSession(generation: generation)
        }
    }

    /// Review Medium 21: which saved account a restored Keychain session belongs to. Exact
    /// server URL first, then the scheme-insensitive identity (`AccountStore.identityKey`),
    /// both with the same username. Nil when the username is unknown or nothing matches.
    nonisolated static func matchingAccountId(in accounts: [ServerAccount], serverURL: String, username: String?) -> String? {
        guard let username, !username.isEmpty else { return nil }
        if let exact = accounts.first(where: { $0.serverURL == serverURL && $0.username == username }) { return exact.id }
        let identity = AccountStore.identityKey(serverURL: serverURL, username: username)
        return accounts.first(where: { AccountStore.identityKey(serverURL: $0.serverURL, username: $0.username) == identity })?.id
    }

    /// LS-3: verifies a Keychain-restored session against the server, off the splash's
    /// critical path — `checkExistingSession()` has already dropped the splash and moved
    /// on by the time this runs, so the user can be interacting with the app already. Any
    /// state change this makes is guarded by `generation` against the account having
    /// since changed underneath it (a sign-out, a switch, or a fresh login all bump
    /// `sessionGeneration`), so a late result for an old session can neither sign the new
    /// one out nor overwrite its `currentUser`.
    private func verifyRestoredSession(generation: Int) async {
        // Polish pass (J1-1): this check handles its own rejection (below), so the in-place
        // "Sign in again" sheet doesn't also appear for it.
        isVerifyingRestoredSession = true
        defer { isVerifyingRestoredSession = false }
        do {
            let user = try await AudiobookshelfAPI.shared.getCurrentUser()
            guard generation == sessionGeneration else { return }
            currentUser = user
            username = user.username
        } catch APIError.unauthorized {
            guard generation == sessionGeneration else { return }
            // Token genuinely rejected (and refresh/re-auth failed) — require login.
            // LS-3: unlike before, this now lands after ContentView's `.task` has
            // already restored the last-played book and reloaded the account's
            // downloads, so stop that playback and any transfers before the
            // credentials go — otherwise a paused, rejected-account session stays
            // loaded underneath the login screen. Re-checked after the await in case
            // the user switched account or signed in meanwhile.
            await stopPlaybackAndTransfers()
            guard generation == sessionGeneration else { return }
            // Polish pass (J1-2): say why the sign-in screen is back, prefilled with this
            // session's server and username — captured before the store is cleared below.
            let endedServer = serverURL.isEmpty ? AuthStore.shared.serverURL : serverURL
            if !endedServer.isEmpty {
                sessionEndedPrefill = SessionEndedPrefill(serverURL: endedServer, username: username,
                                                          customHeaders: AuthStore.shared.customHeaders)
            }
            // Item 5: `deleteAll()` is now best-effort across every key and throws one
            // aggregate error naming the ones it couldn't clear, instead of stopping at
            // the first. Still not fatal here — the session is being torn down either
            // way — but a leftover token is worth a log line rather than a bare `try?`.
            do {
                try await KeychainService.shared.deleteAll()
            } catch {
                ShelfLog.error(.auth, "Rejected-session cleanup left Keychain items behind: \(error.localizedDescription)")
            }
            AuthStore.shared.clear()
            currentUser = nil
            isAuthenticated = false
        } catch {
            // Offline, a transient/server error, or this verification was cancelled
            // because the session moved on — keep whatever the (possibly newer) session
            // already has.
        }
    }

    /// Returns `true` only when the sign-in succeeded and the session is live. UX-4: the
    /// Add Server form used to infer success from "no `errorMessage` and nothing pending",
    /// so anything else clearing that state (see `AccountSecuritySettingsView`) read as a
    /// success and dismissed the sheet. It now acts on this result instead.
    ///
    /// `endingCurrentSession`: pass `true` from Add Server when `addServerSignInKind` says
    /// this sign-in switches account (after the user confirmed it), and from
    /// `switchAccount` (Critique 2026-10-06: it used to tear down itself, before its
    /// reachability check existed).
    @discardableResult
    func login(serverURL: String, username: String, password: String, customHeaders: [String: String] = [:],
               acknowledgedInsecureConnection: Bool = false, endingCurrentSession: Bool = false) async -> Bool {
        // Polish pass (J1-6): autofill and paste leave a trailing space or newline, which the
        // server reads as a different user ("Incorrect username or password"). Passwords are
        // sent exactly as typed.
        let username = Self.normalizedUsername(username)
        isLoading = true
        errorMessage = nil
        pendingInsecureConnection = nil
        lastSignInEndedSession = false
        // LS-3: a login/sign-in call not routed through `switchAccount` (Add Server, a
        // fresh sign-in after Sign Out) still ends whatever session was live before it —
        // bump the generation and cancel any cold-launch verification still in flight for
        // that old session so it can't act on it once this one is live. `switchAccount`'s
        // own `tearDownAccountScopedState` call already does this before reaching here;
        // bumping again is harmless (the counter only needs to move forward).
        sessionGeneration += 1
        sessionVerificationTask?.cancel()

        guard let cleanURL = Self.normalizedServerURL(serverURL) else {
            errorMessage = String(localized: "Enter a valid server address, e.g. https://library.example.com")
            isLoading = false
            return false
        }

        // Block by default, before anything is transmitted — not just a warning label
        // after the fact. A plain-HTTP connection to a host that isn't local/private
        // means the password about to be sent, and every token/bookmark/progress update
        // after it, would travel unencrypted. The view is responsible for presenting
        // `pendingInsecureConnection` and re-calling this with the flag set to true only
        // after the user explicitly confirms.
        if Self.requiresInsecureConnectionConfirmation(for: cleanURL) && !acknowledgedInsecureConnection {
            pendingInsecureConnection = PendingInsecureConnection(serverURL: cleanURL)
            isLoading = false
            return false
        }

        // Critique 2026-10-06 (harden): Add Server over a live session is an account switch.
        // A failure after the teardown drops the stopped book from the UI (success posts
        // the account change below, as it always has) — see
        // `clearStoppedBookAfterFailedSwitch` for why it no longer posts the change.
        let tornDown = await tearDownForReplacedSession(endingCurrentSession)
        var signedIn = false
        defer {
            if tornDown && !signedIn { clearStoppedBookAfterFailedSwitch() }
        }

        do {
            let response = try await AudiobookshelfAPI.shared.login(
                serverURL: cleanURL,
                username: username,
                password: password,
                customHeaders: customHeaders
            )

            // The API layer already stored the server URL + tokens (AuthStore + Keychain).
            // Persist the remaining values, including the password for silent re-auth.
            // If any of these fail, roll everything back so we never leave a half-committed
            // session (tokens set but credentials missing → a login that "worked" then
            // silently dies on next launch).
            do {
                try await KeychainService.shared.save(cleanURL, for: .serverURL)
                try await KeychainService.shared.save(username, for: .username)
                // Only keep the password for silent re-login when the user allows it
                // (default on). Off → store empty; silent re-auth then no-ops and the
                // user re-enters it if the session lapses.
                try await KeychainService.shared.save(SettingsStore.storePassword ? password : "", for: .password)
                try await KeychainService.shared.save(response.user.id, for: .userId)
            } catch {
                // Item 5: the rollback is best-effort but no longer silent — if the
                // rollback *itself* fails, a half-written credential set survives a login
                // the user was told didn't work, which is precisely the state this
                // rollback exists to prevent.
                // Review 7 Low (rollback generation): via the API first, so an in-flight refresh can't
                // write tokens back after the wipe; Review 7 Low (current account): the wipe tears down
                // whichever account was current, so the id must not keep naming it.
                await AudiobookshelfAPI.shared.clearLocalCredentials()
                AccountStore.clearCurrent()
                do {
                    try await KeychainService.shared.deleteAll()
                } catch let rollbackError {
                    ShelfLog.error(.auth, "Login rollback couldn't clear every Keychain item: \(rollbackError.localizedDescription)")
                }
                AuthStore.shared.clear()
                isAuthenticated = false
                errorMessage = String(localized: "Couldn't securely save your credentials. Please try again.")
                ShelfLog.error(.auth, "Login persistence failed; rolled back: \(error.localizedDescription)")
                isLoading = false
                return false
            }

            // Remember this account for multi-server switching. Pass `nil` (not `[:]`)
            // when no headers were supplied so a plain re-login doesn't wipe out headers
            // configured separately in Settings for an already-saved account.
            let upsert = await AccountStore.upsert(
                serverURL: cleanURL, username: username, password: password,
                customHeaders: customHeaders.isEmpty ? nil : customHeaders,
                acknowledgedInsecureConnection: acknowledgedInsecureConnection ? true : nil,
                // Explicitly false, not nil: this account has a real password, so a
                // switch to it must take the password path even if it was an SSO
                // account before.
                usesSingleSignOn: false)
            // Item 4: `upsert` used to discard both Keychain outcomes. Deliberately NOT
            // routed to `errorMessage`: the sign-in itself succeeded and the session is
            // live, so the view is already being replaced by the main UI — an error
            // banner there would read as "login failed" and, since `LoginView` is gone,
            // would only surface much later out of context. Logged instead, which is
            // what makes it recoverable from Diagnostics if a user reports "my server
            // keeps disappearing from the list".
            Self.logAccountPersistenceGaps(upsert)
            await loadAccounts()

            currentUser = response.user
            self.serverURL = cleanURL
            self.username = username
            isAuthenticated = true
            signedIn = true
            clearSessionEndedState()   // Polish pass (J1-1, J1-2)
            claimSharedPlaybackRecords()
            NotificationCenter.default.post(name: .shelfheadAccountChanged, object: nil)
            isLoading = false
            return true
        } catch {
            // L8 (REVIEW_2026-08-20_UI_SECURITY.md): never `localizedDescription` on screen —
            // it stays in the log line for Diagnostics. Polish pass (J1-5, ST-12): TLS, timeout,
            // DNS, an HTML proxy page and a non-Audiobookshelf host each get their own
            // what-happened-and-what-to-do line instead of "Connection failed…".
            errorMessage = Self.signInErrorMessage(for: error, serverURL: cleanURL,
                                                   deviceIsOnline: NetworkMonitor.shared.isConnected)
            ShelfLog.error(.auth, "Login failed: \(error.localizedDescription)")
        }

        isLoading = false
        return false
    }

    /// L8 (REVIEW_2026-08-20_UI_SECURITY.md): maps `APIError` to copy consistent with
    /// this file's other hand-written login/OIDC error messages, instead of forwarding
    /// `errorDescription` (which is fine for a log line but includes raw status codes
    /// and, for `.decodingError`, an arbitrary nested error description) straight to the
    /// user-facing banner. Shared by both `login()` and `loginWithOIDC()`.
    nonisolated private static func loginFriendlyMessage(for error: APIError) -> String {
        switch error {
        case .unauthorized:
            return String(localized: "Incorrect username or password.")
        case .forbidden:
            return String(localized: "Access denied. Check your account's permissions on the server.")
        case .notFound:
            return String(localized: "That server address looks reachable, but the login endpoint couldn't be found. Check the URL.")
        case .invalidURL:
            return String(localized: "Enter a valid server address, e.g. https://library.example.com")
        case .serverError:
            // Polish pass (ST-12): was "Something went wrong".
            return String(localized: "Your server answered with an error. Check that Audiobookshelf is running, then try again.")
        case .invalidResponse, .httpError, .decodingError:
            return notAudiobookshelfMessage
        }
    }

    /// Polish pass (ST-12): an HTML page (a reverse proxy's sign-in gate, a router, another
    /// web app) or an unexpected status where Audiobookshelf's JSON should be.
    nonisolated static var notAudiobookshelfMessage: String {
        String(localized: "Something answered at that address, but not Audiobookshelf. Check the address, and any headers your proxy (Cloudflare Access, Authelia) needs.")
    }

    /// Polish pass (J1-5, ST-12): the one line a failed sign-in shows, for every error
    /// `login()`, `loginWithOIDC()` and the sign-in-again sheet can see. A real 401 on login
    /// stays "Incorrect username or password."; transport failures reuse the connection
    /// test's classification (`ServerConnectionFailure.classify`) and its copy
    /// (`ServerConnectionRules.failureAdvice`), so sign-in and Test Connection say the same
    /// thing about the same failure. Pure, pinned by `PolishAuthTests`.
    nonisolated static func signInErrorMessage(for error: Error, serverURL: String, deviceIsOnline: Bool) -> String {
        if let apiError = error as? APIError { return loginFriendlyMessage(for: apiError) }
        if error is DecodingError { return notAudiobookshelfMessage }
        if let oidcError = error as? OIDCAuthService.OIDCError {
            if case .connectionFailed(let urlError) = oidcError {
                return signInErrorMessage(for: urlError, serverURL: serverURL, deviceIsOnline: deviceIsOnline)
            }
            return oidcError.errorDescription ?? String(localized: "Couldn\u{2019}t sign in. Try again.")
        }
        if error is URLError {
            let failure = ServerConnectionFailure.classify(error, deviceIsOnline: deviceIsOnline)
            if failure == .offline {
                return String(localized: "You\u{2019}re offline. Connect to Wi-Fi or mobile data, then try again.")
            }
            let advice = ServerConnectionRules.failureAdvice(failure: failure, resolvedURL: serverURL, triedPlainHTTP: false)
            return "\(advice.message) \(advice.nextStep)"
        }
        return String(localized: "Couldn\u{2019}t sign in. Check the server address and try again.")
    }

    /// Signs in via the server's OpenID Connect / SSO support (see `OIDCAuthService`)
    /// instead of a username/password. Audiobookshelf handles the whole OIDC/PKCE
    /// exchange with the identity provider itself; this just launches the system
    /// sign-in sheet and then mirrors what `login()` does with the resulting session —
    /// persist to Keychain, remember the account for multi-server switching, fetch the
    /// user profile (the username isn't known until after sign-in completes).
    ///
    /// Unlike a password account, there's no password to save for silent re-auth if the
    /// refresh token is ever rejected — an SSO account's session relies solely on the
    /// refresh token; if that's exhausted, the user taps "Sign in with SSO" again rather
    /// than the app silently re-authenticating in the background.
    /// Returns whether sign-in actually succeeded. Callers shouldn't infer success from
    /// `errorMessage == nil` alone — a user-cancelled sign-in sheet intentionally leaves
    /// no error message (it's not a failure to report), but it also isn't success.
    ///
    /// `endingCurrentSession`: as for `login()` — `true` from Add Server for a confirmed
    /// account switch.
    @discardableResult
    func loginWithOIDC(serverURL: String, customHeaders: [String: String] = [:],
                        acknowledgedInsecureConnection: Bool = false,
                        endingCurrentSession: Bool = false) async -> Bool {
        isLoading = true
        errorMessage = nil
        pendingInsecureConnection = nil
        lastSignInEndedSession = false
        // LS-3: a login/sign-in call not routed through `switchAccount` (Add Server, a
        // fresh sign-in after Sign Out) still ends whatever session was live before it —
        // bump the generation and cancel any cold-launch verification still in flight for
        // that old session so it can't act on it once this one is live. `switchAccount`'s
        // own `tearDownAccountScopedState` call already does this before reaching here;
        // bumping again is harmless (the counter only needs to move forward).
        sessionGeneration += 1
        sessionVerificationTask?.cancel()

        guard let cleanURL = Self.normalizedServerURL(serverURL) else {
            errorMessage = String(localized: "Enter a valid server address, e.g. https://library.example.com")
            isLoading = false
            return false
        }

        // Same gate as `login()` — the OIDC initiation/callback/token-exchange legs all
        // still traverse this same connection, so a non-local HTTP server needs the same
        // explicit confirmation before anything is sent.
        if Self.requiresInsecureConnectionConfirmation(for: cleanURL) && !acknowledgedInsecureConnection {
            pendingInsecureConnection = PendingInsecureConnection(serverURL: cleanURL)
            isLoading = false
            return false
        }

        // Critique 2026-10-06 (harden): as in `login()`, but the teardown waits until the
        // identity provider has answered. `OIDCAuthService.signIn` only runs the sheet and
        // returns tokens (it writes nothing to `AuthStore`), so the old session is intact
        // until `configureAndPersist` below — and closing the sheet now leaves the book
        // playing instead of stopped behind a switch that never happened.
        var tornDown = false
        var signedIn = false
        // Review Medium 20 (30 October 2026): true once the new tokens went into `AuthStore`
        // and the Keychain, i.e. the point after which a failure leaves a half-switched session.
        var credentialsWritten = false
        defer {
            if tornDown && !signedIn { clearStoppedBookAfterFailedSwitch() }
        }

        do {
            let result = try await OIDCAuthService.signIn(serverURL: cleanURL, customHeaders: customHeaders)
            tornDown = await tearDownForReplacedSession(endingCurrentSession)
            credentialsWritten = true
            try await AudiobookshelfAPI.shared.configureAndPersist(
                serverURL: cleanURL,
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                customHeaders: customHeaders
            )
            let user = try await AudiobookshelfAPI.shared.getCurrentUser()

            do {
                try await KeychainService.shared.save(cleanURL, for: .serverURL)
                try await KeychainService.shared.save(user.username, for: .username)
                // No password to save — an SSO account never has one on this device.
                try await KeychainService.shared.save("", for: .password)
                try await KeychainService.shared.save(user.id, for: .userId)
            } catch {
                // Item 5: same as `login()`'s rollback above — surface a rollback that
                // itself couldn't finish instead of swallowing it.
                // Review 7 Low (rollback generation / current account): as in `login()`'s rollback.
                await AudiobookshelfAPI.shared.clearLocalCredentials()
                AccountStore.clearCurrent()
                do {
                    try await KeychainService.shared.deleteAll()
                } catch let rollbackError {
                    ShelfLog.error(.auth, "OIDC login rollback couldn't clear every Keychain item: \(rollbackError.localizedDescription)")
                }
                AuthStore.shared.clear()
                isAuthenticated = false
                errorMessage = String(localized: "Couldn't securely save your session. Please try again.")
                ShelfLog.error(.auth, "OIDC login persistence failed; rolled back: \(error.localizedDescription)")
                isLoading = false
                return false
            }

            let upsert = await AccountStore.upsert(
                serverURL: cleanURL, username: user.username, password: "",
                customHeaders: customHeaders.isEmpty ? nil : customHeaders,
                acknowledgedInsecureConnection: acknowledgedInsecureConnection ? true : nil,
                // Fix 5 (REVIEW-2026-09-09.md): marks the account so `switchAccount`
                // routes it to a fresh SSO sign-in instead of a password login with
                // the `""` above.
                usesSingleSignOn: true)
            Self.logAccountPersistenceGaps(upsert)   // Item 4 — see `login()`.
            await loadAccounts()

            currentUser = user
            self.serverURL = cleanURL
            self.username = user.username
            isAuthenticated = true
            signedIn = true
            clearSessionEndedState()   // Polish pass (J1-1, J1-2)
            claimSharedPlaybackRecords()   // see `login()`
            NotificationCenter.default.post(name: .shelfheadAccountChanged, object: nil)
            isLoading = false
            return true
        } catch let error as OIDCAuthService.OIDCError {
            if credentialsWritten && !signedIn { await rollbackFailedSSOSignIn() }
            // A user-cancelled sign-in sheet has no message — nothing went wrong.
            if error.errorDescription != nil {
                // Polish pass (J1-5): a `.connectionFailed` says which kind (TLS, timeout, DNS…).
                errorMessage = Self.signInErrorMessage(for: error, serverURL: cleanURL,
                                                       deviceIsOnline: NetworkMonitor.shared.isConnected)
                ShelfLog.error(.auth, "OIDC login failed: \(error)")
            }
        } catch {
            if credentialsWritten && !signedIn { await rollbackFailedSSOSignIn() }
            // L8 / Polish pass (J1-5, ST-12): as in `login()`.
            errorMessage = Self.signInErrorMessage(for: error, serverURL: cleanURL,
                                                   deviceIsOnline: NetworkMonitor.shared.isConnected)
            ShelfLog.error(.auth, "OIDC login failed: \(error.localizedDescription)")
        }

        isLoading = false
        return false
    }

    /// Review Medium 20 (30 October 2026): the same rollback the Keychain-failure path in
    /// `loginWithOIDC` uses, for a failure after the new tokens were saved (e.g. `/api/me`
    /// failed). Without it the app kept a signed-in-looking store and Keychain for a
    /// session that never completed.
    private func rollbackFailedSSOSignIn() async {
        // Review 6 Low (SSO rollback): via the API, first, so the credential generation moves on
        // and an in-flight refresh can't write tokens back after the Keychain is cleared.
        await AudiobookshelfAPI.shared.clearLocalCredentials()
        AccountStore.clearCurrent()   // Review 7 Low (current account): the wipe below tears the previous session down too.
        do {
            try await KeychainService.shared.deleteAll()
        } catch let rollbackError {
            ShelfLog.error(.auth, "OIDC login rollback couldn't clear every Keychain item: \(rollbackError.localizedDescription)")
        }
        AuthStore.shared.clear()
        isAuthenticated = false
    }

    // MARK: - Sign in again, in place (Polish pass J1-1)

    /// Pure: whether a `.shelfheadSessionExpired` signal should raise the "Sign in again"
    /// sheet. Not when nobody is signed in, while a sign-in / sign-in-again / account switch
    /// is running (`isSigningIn`), while the cold-launch check owns the rejection, while the
    /// sheet is already up (a burst of refused requests raises it once), or within
    /// `snooze` of the user choosing "Not Now". Pinned by `PolishAuthTests`.
    nonisolated static func shouldPresentSessionExpired(isAuthenticated: Bool, isSigningIn: Bool,
                                                        isVerifyingRestoredSession: Bool, isPresented: Bool,
                                                        dismissedAt: Date?, now: Date,
                                                        snooze: TimeInterval = sessionExpiredSnooze) -> Bool {
        guard isAuthenticated, !isSigningIn, !isVerifyingRestoredSession, !isPresented else { return false }
        if let dismissedAt, now.timeIntervalSince(dismissedAt) < snooze { return false }
        return true
    }

    /// Pure: whether a sign-in-again landed on the account whose session ended. By server
    /// user id when it's known, otherwise by username (case-insensitive, as Audiobookshelf
    /// matches usernames). Pinned by `PolishAuthTests`.
    nonisolated static func isSameAccount(expectedUserId: String?, expectedUsername: String,
                                          signedInUserId: String, signedInUsername: String) -> Bool {
        if let expectedUserId, !expectedUserId.isEmpty { return expectedUserId == signedInUserId }
        return normalizedUsername(expectedUsername).caseInsensitiveCompare(normalizedUsername(signedInUsername)) == .orderedSame
    }

    /// Polish pass (J1-6): a username as it's sent to the server — surrounding spaces and
    /// newlines (autofill, paste) removed. Pure, pinned by `PolishAuthTests`.
    nonisolated static func normalizedUsername(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func differentAccountMessage(username: String) -> String {
        String(localized: "That signed in as someone else. Sign in as \(username) to keep this session, or use Settings to switch accounts.", comment: "Sign in again sheet: the identity provider or server returned a different user; %@ is the expected username")
    }

    /// Turns the API's "session refused" signal into the sheet. Silent recovery has already
    /// been tried by then: the API only posts after the refresh token was refused AND the
    /// opt-in stored-password re-login was refused or isn't available (SSO accounts never
    /// have one — their only silent path is the refresh token).
    private func handleSessionExpiredSignal(generation: Int?) async {
        if let generation, !(await AudiobookshelfAPI.shared.isCurrentCredentialGeneration(generation)) { return }
        guard Self.shouldPresentSessionExpired(isAuthenticated: isAuthenticated,
                                               isSigningIn: isLoading || isReauthenticating || isSwitchingAccount,
                                               isVerifyingRestoredSession: isVerifyingRestoredSession,
                                               isPresented: sessionExpiredPrompt != nil,
                                               dismissedAt: sessionExpiredDismissedAt, now: Date()) else { return }
        let server = serverURL.isEmpty ? AuthStore.shared.serverURL : serverURL
        guard !server.isEmpty else { return }
        let headers = AuthStore.shared.customHeaders
        let capturedGeneration = sessionGeneration
        if accounts.isEmpty { await loadAccounts() }
        let account = accounts.first { $0.id == AccountStore.currentAccountId }
        var usesSSO = false
        if let account { usesSSO = await reauthenticationMethod(for: account) == .singleSignOn }
        let storedUserId = try? await KeychainService.shared.get(.userId)
        // Re-checked after the awaits: the session may have moved on meanwhile.
        guard capturedGeneration == sessionGeneration, isAuthenticated, sessionExpiredPrompt == nil else { return }
        let name = username.isEmpty ? (account?.username ?? "") : username
        sessionNeedsSignIn = true
        reauthErrorMessage = nil
        sessionExpiredPrompt = SessionExpiredPrompt(serverURL: server, username: name,
                                                    userId: currentUser?.id ?? storedUserId,
                                                    usesSingleSignOn: usesSSO, customHeaders: headers)
    }

    /// "Not Now": the sheet goes; the session stays signed in (downloads play, progress
    /// queues) and the sheet won't come back for `sessionExpiredSnooze`.
    func dismissSessionExpiredPrompt() {
        guard sessionExpiredPrompt != nil, !isReauthenticating else { return }
        sessionExpiredPrompt = nil
        reauthErrorMessage = nil
        sessionExpiredDismissedAt = Date()
    }

    /// Sign in again with a password, for the account in `sessionExpiredPrompt` only. Reuses
    /// `AudiobookshelfAPI.login` (which installs and saves the new tokens) with
    /// `requiringUserId`, so a different user is refused before anything is written. Unlike
    /// `login()` this is not an account change: no teardown, no `.shelfheadAccountChanged`,
    /// so the player, Up Next, downloads and the progress queue stay exactly as they are.
    @discardableResult
    func reauthenticateExpiredSession(password: String) async -> Bool {
        guard let prompt = sessionExpiredPrompt, !isReauthenticating, !password.isEmpty else { return false }
        isReauthenticating = true
        reauthErrorMessage = nil
        defer { isReauthenticating = false }
        do {
            let response = try await AudiobookshelfAPI.shared.login(
                serverURL: prompt.serverURL, username: prompt.username, password: password,
                customHeaders: prompt.customHeaders, requiringUserId: prompt.userId)
            // The tokens are saved by the API; refresh what `login()` keeps beside them.
            // Best-effort: the session is already live either way.
            do {
                try await KeychainService.shared.save(prompt.username, for: .username)
                try await KeychainService.shared.save(SettingsStore.storePassword ? password : "", for: .password)
                try await KeychainService.shared.save(response.user.id, for: .userId)
            } catch {
                ShelfLog.error(.auth, "Sign in again: couldn't update the saved sign-in details: \(error.localizedDescription)")
            }
            // Same server + username, so this updates the saved account (a changed password
            // included) rather than adding one.
            Self.logAccountPersistenceGaps(await AccountStore.upsert(
                serverURL: prompt.serverURL, username: prompt.username, password: password,
                customHeaders: nil, acknowledgedInsecureConnection: nil, usesSingleSignOn: false))
            currentUser = response.user
            finishSessionReauthentication()
            return true
        } catch is DifferentAccountError {
            reauthErrorMessage = Self.differentAccountMessage(username: prompt.username)
            ShelfLog.error(.auth, "Sign in again refused: the server returned a different user")
        } catch {
            reauthErrorMessage = Self.signInErrorMessage(for: error, serverURL: prompt.serverURL,
                                                         deviceIsOnline: NetworkMonitor.shared.isConnected)
            ShelfLog.error(.auth, "Sign in again failed: \(error.localizedDescription)")
        }
        return false
    }

    /// Sign in again through SSO, for the account in `sessionExpiredPrompt` only. There is no
    /// silent OIDC path: the browser sheet is ephemeral (SEC-5) and the refresh token has
    /// already been refused, so this runs the existing `OIDCAuthService` flow, then checks
    /// the identity provider signed in the same user (`fetchUser`) BEFORE the new tokens
    /// replace anything.
    @discardableResult
    func reauthenticateExpiredSessionWithSSO() async -> Bool {
        guard let prompt = sessionExpiredPrompt, !isReauthenticating else { return false }
        isReauthenticating = true
        reauthErrorMessage = nil
        defer { isReauthenticating = false }
        let generation = sessionGeneration
        do {
            let result = try await OIDCAuthService.signIn(serverURL: prompt.serverURL, customHeaders: prompt.customHeaders)
            let user = try await AudiobookshelfAPI.shared.fetchUser(serverURL: prompt.serverURL,
                                                                     accessToken: result.accessToken,
                                                                     customHeaders: prompt.customHeaders)
            guard Self.isSameAccount(expectedUserId: prompt.userId, expectedUsername: prompt.username,
                                     signedInUserId: user.id, signedInUsername: user.username) else {
                reauthErrorMessage = Self.differentAccountMessage(username: prompt.username)
                ShelfLog.error(.auth, "SSO sign in again refused: the identity provider returned a different user")
                return false
            }
            guard generation == sessionGeneration, isAuthenticated else { return false }
            do {
                try await AudiobookshelfAPI.shared.configureAndPersist(
                    serverURL: prompt.serverURL, accessToken: result.accessToken,
                    refreshToken: result.refreshToken, customHeaders: prompt.customHeaders)
                try await KeychainService.shared.save(user.id, for: .userId)
            } catch {
                // The new tokens are live in memory, so this run works; only the next cold
                // launch could ask again.
                ShelfLog.error(.auth, "SSO sign in again: couldn't save the new session: \(error.localizedDescription)")
            }
            currentUser = user
            finishSessionReauthentication()
            return true
        } catch let error as OIDCAuthService.OIDCError {
            // A closed sign-in sheet (`.cancelled`) has no message.
            if error.errorDescription != nil {
                reauthErrorMessage = Self.signInErrorMessage(for: error, serverURL: prompt.serverURL,
                                                             deviceIsOnline: NetworkMonitor.shared.isConnected)
                ShelfLog.error(.auth, "SSO sign in again failed: \(error)")
            }
        } catch {
            reauthErrorMessage = Self.signInErrorMessage(for: error, serverURL: prompt.serverURL,
                                                         deviceIsOnline: NetworkMonitor.shared.isConnected)
            ShelfLog.error(.auth, "SSO sign in again failed: \(error.localizedDescription)")
        }
        return false
    }

    /// The session is back: drop the sheet, wake live sync, and push what queued while it
    /// was signed out — the same flushes a return to the foreground runs (`ShelfHeadApp`).
    private func finishSessionReauthentication() {
        clearSessionEndedState()
        ServerEventSocket.shared.credentialsRestored()
        AudioPlayerService.shared.flushPendingProgress()
        Task { await BookmarkSyncService.shared.flush() }
    }

    /// Any successful sign-in ends both the in-place prompt and the launch prefill.
    private func clearSessionEndedState() {
        sessionExpiredPrompt = nil
        sessionNeedsSignIn = false
        sessionExpiredDismissedAt = nil
        reauthErrorMessage = nil
        sessionEndedPrefill = nil
    }

    // MARK: - Stored session read (Polish pass CR-4)

    enum StoredSessionRead: Equatable {
        case found(serverURL: String, accessToken: String)
        /// Genuinely not in the Keychain (`errSecItemNotFound`): signed out.
        case missing
        /// The Keychain wouldn't answer (locked, or another error) even after retrying.
        case unavailable
    }

    /// Pure (CR-4): how long to wait before reading the Keychain again after a failed read,
    /// or nil to stop. A device that hasn't been unlocked since boot answers
    /// `errSecInteractionNotAllowed` until it is, so that waits (every 2 s, up to ~5 min of
    /// the app actually running); anything else gets two quick retries. Pinned by
    /// `PolishAuthTests`.
    nonisolated static func keychainReadRetryDelay(afterAttempt attempt: Int, status: OSStatus) -> TimeInterval? {
        if status == errSecInteractionNotAllowed { return attempt < 150 ? 2 : nil }
        return attempt < 3 ? 0.5 : nil
    }

    private func readStoredSession() async -> StoredSessionRead {
        var attempt = 0
        while true {
            attempt += 1
            do {
                guard let url = try await KeychainService.shared.get(.serverURL),
                      let token = try await KeychainService.shared.get(.authToken) else { return .missing }
                return .found(serverURL: url, accessToken: token)
            } catch {
                var status = errSecInternalError
                if let keychainError = error as? KeychainError, case .readFailed(let code) = keychainError { status = code }
                guard !Task.isCancelled,
                      let delay = Self.keychainReadRetryDelay(afterAttempt: attempt, status: status) else {
                    ShelfLog.error(.auth, "Couldn't read the saved session from the Keychain (status \(status)); keeping it for next launch")
                    return .unavailable
                }
                if attempt == 1 {
                    ShelfLog.error(.auth, "Keychain read failed at launch (status \(status)); retrying instead of signing out")
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Sign Out (this server only)

    /// Which server sessions Sign Out ends on the server itself.
    enum ServerLogoutScope: Equatable {
        /// `POST /logout`: this device's session only (Account & Security > Sign Out).
        case thisDevice
        /// `POST /logout?allDevices=1`: every session for this account on this server
        /// (Active Sessions > Sign Out All Devices).
        case everyDevice
    }

    /// What Sign Out will do, worked out before anything is torn down so the confirmation
    /// can say it (`AccountSecuritySettingsView.signOutMessage`).
    struct SignOutPlan: Equatable {
        /// The server being signed out of.
        let host: String
        /// The saved server Sign Out signs in to straight afterwards, or nil when it lands
        /// on the sign-in screen.
        let nextHost: String?
        /// Saved servers that stay on this device.
        let remainingServers: Int
    }

    /// Critique 2026-10-06 (harden): the saved server to move to after signing out of
    /// `signingOutId` — the most recently used of the others (`AccountStore.lastUsedDates`).
    /// Accounts never made current since that was recorded sort last; among those, the one
    /// added most recently (later in the saved list) wins. Pure, pinned by
    /// `SignOutRoutingTests`.
    nonisolated static func nextAccountAfterSignOut(signingOutId: String?, accounts: [ServerAccount],
                                                    lastUsed: [String: Date]) -> ServerAccount? {
        accounts.enumerated()
            .filter { $0.element.id != signingOutId }
            .max { lhs, rhs in
                let l = lastUsed[lhs.element.id] ?? .distantPast
                let r = lastUsed[rhs.element.id] ?? .distantPast
                return l == r ? lhs.offset < rhs.offset : l < r
            }?.element
    }

    /// Whether Sign Out signs in to the next saved server by itself. Only with a stored
    /// password, which signs in silently. An SSO account would open the identity
    /// provider's sign-in sheet unasked, straight after the user chose to sign *out*, and
    /// an account with no stored password has nothing to sign in with: both land on the
    /// sign-in screen, where the saved servers are listed one tap away. Pure, pinned by
    /// `SignOutRoutingTests`.
    nonisolated static func switchesAutomaticallyAfterSignOut(_ method: ReauthenticationMethod) -> Bool {
        if case .password = method { return true }
        return false
    }

    /// Which teardown Sign Out (or removing the current account) runs. With other servers
    /// still saved on this device it is the account-switch teardown, which keeps per-book
    /// speeds and the cover caches (both keyed by something already unique to a server,
    /// and wanted back on those servers). With none left it is the full `.signOut`.
    ///
    /// When the caller has already stopped playback and awaited the flush (removing the
    /// current account, item 12), it is always `.signOut(playbackAlreadyStopped: true)`:
    /// that is the only reason that skips the stop, and a second stop must not race the
    /// flush. The cost is that removing the current server also clears per-book speeds and
    /// the cover caches when other servers remain. Pure, pinned by `SignOutRoutingTests`.
    nonisolated static func signOutTeardownReason(remainingSavedServers: Int,
                                                  playbackAlreadyStopped: Bool) -> AccountTeardownReason {
        remainingSavedServers > 0 && !playbackAlreadyStopped
            ? .accountSwitch
            : .signOut(playbackAlreadyStopped: playbackAlreadyStopped)
    }

    /// The message left on the sign-in screen when Sign Out couldn't finish signing in to
    /// the next saved server. Pure, pinned by `SignOutRoutingTests`.
    nonisolated static func signOutSwitchFailedMessage(nextHost: String, reason: String?) -> String {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return String(localized: "Signed out. Couldn\u{2019}t sign in to \(nextHost). Tap it under Saved servers to try again.", comment: "Sign-in screen message after Sign Out couldn't switch to the next saved server; %@ is that server's host")
        }
        return String(localized: "Signed out. Couldn\u{2019}t sign in to \(nextHost): \(reason)", comment: "Sign-in screen message after Sign Out couldn't switch to the next saved server; first %@ is the host, second is the failure reason")
    }

    /// What Sign Out will do right now. Read by the Sign Out and Sign Out All Devices
    /// confirmations before they are shown.
    func signOutPlan() async -> SignOutPlan {
        await loadAccounts()
        let currentId = AccountStore.currentAccountId
        let host = accounts.first { $0.id == currentId }?.displayHost
            ?? URL(string: serverURL)?.host ?? serverURL
        let remaining = accounts.filter { $0.id != currentId }
        var nextHost: String?
        if let next = Self.nextAccountAfterSignOut(signingOutId: currentId, accounts: accounts,
                                                   lastUsed: AccountStore.lastUsedDates()) {
            let method = Self.reauthenticationMethod(for: next, storedPassword: await AccountStore.password(for: next))
            if Self.switchesAutomaticallyAfterSignOut(method) { nextHost = next.displayHost }
        }
        return SignOutPlan(host: host, nextHost: nextHost, remainingServers: remaining.count)
    }

    /// Critique 2026-10-06 (harden): Sign Out means **this server only** (user decision,
    /// 6 Oct 2026). It used to be `logout()`, which removed every saved server, every
    /// password and the whole Keychain set.
    ///
    /// Order:
    /// 1. Teardown first, while `AuthStore` still resolves to this account: playback stops
    ///    and its final position is flushed against *this* server's credentials, and the
    ///    paused-resume sweep finds this account's scope.
    /// 2. End the session on the server (`scope`) — after the flush, because a revoked
    ///    token can't save the final position. (Sign Out All Devices used to revoke first.)
    /// 3. Retain the account id (Batch 382) and take this account off the saved list with
    ///    its password (`AccountStore.removeForSignOut`). Its downloads and queued
    ///    positions stay and come back on a sign-in to the same server and username.
    /// 4. Clear the live session (`finishEndingLiveSession`), then sign in to the most
    ///    recently used other saved server when that can happen silently; otherwise land
    ///    on the sign-in screen with the saved servers listed.
    ///
    /// Callers: Account & Security > Sign Out (`.thisDevice`) and Active Sessions > Sign
    /// Out All Devices (`.everyDevice`). Removing the current account shares steps 1, 2
    /// and 4 (`removeAccount`). A session the server rejects on launch
    /// (`verifyRestoredSession`) deliberately calls none of this: the user didn't ask to
    /// sign out, so the saved server and its password stay for a one-tap sign-in.
    func signOut(scope: ServerLogoutScope = .thisDevice) async {
        // Critique 2026-10-06 (harden): the sign-in screen renders `errorMessage`, so a
        // message left by something earlier in this session (a failed removal, say) must
        // not turn up there as if Sign Out had produced it.
        errorMessage = nil
        await loadAccounts()
        let currentId = AccountStore.currentAccountId
        let current = accounts.first { $0.id == currentId }
        let remaining = accounts.filter { $0.id != currentId }.count
        await tearDownAccountScopedState(reason: Self.signOutTeardownReason(
            remainingSavedServers: remaining, playbackAlreadyStopped: false))
        switch scope {
        case .thisDevice: await AudiobookshelfAPI.shared.logout()
        case .everyDevice: await AudiobookshelfAPI.shared.logoutAllDevices()
        }
        var leftBehind: [String] = []
        if let current {
            let outcome = await AccountStore.removeForSignOut(current)
            if !outcome.passwordRemoved {
                leftBehind.append(String(localized: "the saved password for \(current.displayHost)", comment: "Fragment in a sign-out Keychain warning, joined with 'and'; %@ is a server host"))
            }
            if !outcome.listSaved {
                leftBehind.append(String(localized: "\(current.displayHost) in your saved servers", comment: "Fragment in a sign-out Keychain warning, joined with 'and'; %@ is a server host"))
                ShelfLog.error(.auth, "Sign out couldn't update the saved-account list for account \(current.id).")
            }
        } else {
            // A live session with no saved entry (its list write failed at sign-in).
            AccountStore.clearCurrent()
        }
        await finishEndingLiveSession(leftBehind: leftBehind)
    }

    /// The shared tail of Sign Out and of removing the current account, run after their
    /// teardown and server logout: clears this device's session Keychain items and
    /// `AuthStore`, lands on the sign-in screen, posts `.shelfheadAccountChanged`, then
    /// signs in to the next saved server when that can happen silently
    /// (`switchesAutomaticallyAfterSignOut`).
    ///
    /// A Keychain item that wouldn't go is reported on the sign-in screen and the
    /// automatic sign-in is skipped, so the warning isn't wiped by the next attempt
    /// (`login()` clears `errorMessage` first).
    private func finishEndingLiveSession(leftBehind initial: [String]) async {
        var leftBehind = initial
        do {
            try await KeychainService.shared.deleteAll()
        } catch {
            leftBehind.append(String(localized: "this device\u{2019}s sign-in details", comment: "Fragment in a sign-out Keychain warning, joined with 'and'"))
            ShelfLog.error(.auth, "Sign out couldn't clear every Keychain item: \(error.localizedDescription)")
        }
        AuthStore.shared.clear()
        currentUser = nil
        await loadAccounts()
        isAuthenticated = false
        if !leftBehind.isEmpty {
            errorMessage = String(localized: "Signed out, but \(leftBehind.joined(separator: " and ")) couldn\u{2019}t be removed from the Keychain. Unlock your device and use Remove All Servers from This Device in Settings next time you\u{2019}re signed in.", comment: "Sign-out warning; %@ is a list of items joined with 'and' (e.g. 'the saved password for host and this device's sign-in details')")
        }
        // WATCH-4: see the doc comment on `.shelfheadAccountChanged`.
        NotificationCenter.default.post(name: .shelfheadAccountChanged, object: nil)

        guard leftBehind.isEmpty,
              let next = Self.nextAccountAfterSignOut(signingOutId: nil, accounts: accounts,
                                                      lastUsed: AccountStore.lastUsedDates()) else { return }
        let method = Self.reauthenticationMethod(for: next, storedPassword: await AccountStore.password(for: next))
        guard Self.switchesAutomaticallyAfterSignOut(method) else { return }
        switchingAccountIdAfterSignOut = next.id
        // Sign-out is already behind the Settings gate for a child's account, so no second prompt here.
        let outcome = await switchAccount(next, parentGateChecked: true)
        switchingAccountIdAfterSignOut = nil
        guard !isAuthenticated else { return }
        // Nothing on the sign-in screen owns a retry for an insecure-connection prompt
        // raised by this automatic sign-in; tapping the server in the list raises it again.
        pendingInsecureConnection = nil
        // Critique 2026-10-06 (harden): the reason comes back in the outcome now
        // (`switchAccount` leaves `errorMessage` clear).
        var reason: String?
        if case .failed(let failure) = outcome { reason = ServerSwitchFailureCopy.reason(failure.reason) }
        errorMessage = Self.signOutSwitchFailedMessage(nextHost: next.displayHost, reason: reason)
    }

    // MARK: - Remove All Servers from This Device

    /// Critique 2026-10-06 (harden): the full wipe that Sign Out used to be, now its own,
    /// clearly named act (Account & Security > Remove All Servers from This Device). Ends
    /// the live session and removes every saved server, every saved password and every
    /// session Keychain item. Downloads stay: every saved account's id is retained first,
    /// so each server's downloads and queued positions come back on a sign-in to it.
    ///
    /// The one caller is that button. It no longer has a `playbackAlreadyStopped`
    /// parameter: its only other caller was removing the current account, which now ends
    /// that server's session only (`removeAccount`).
    func removeAllServersFromThisDevice() async {
        errorMessage = nil   // Critique 2026-10-06 (harden): as in `signOut`.
        // Fix 5 (REVIEW-2026-09-09.md): playback, downloads, Up Next, the widget
        // snapshot, Spotlight, the paused-resume blobs, the Watch's mirrored state, the
        // per-book speeds and the cover caches were all torn down by hand here, which is
        // how sign-out drifted into doing more than an account switch did. They now live
        // in one routine shared by all three paths. It runs first, while `AuthStore` still
        // resolves to this account — the resume-blob sweep depends on that.
        await tearDownAccountScopedState(reason: .signOut(playbackAlreadyStopped: false))
        await AudiobookshelfAPI.shared.logout()
        // Must remove every saved server's credentials, not just the active session's.
        // `deleteAll()` only covers the primary keys — the saved-account list and each
        // account's own password (stored under a separate per-account key) were
        // previously left behind, so a "signed out" device still had every saved
        // server's plaintext password in the Keychain.
        //
        // Item 5 (REVIEW-2026-09-09-REMAINING.md): all three credential-clearing steps
        // below used to be `try?`-and-forget, and `deleteAll()` itself stopped at the
        // first key it couldn't remove — so a transient failure on `.serverURL` (first in
        // its list) left the access token, refresh token, password and custom headers on
        // the device while the user was shown a clean sign-out. Each step now runs
        // regardless of the others, and what survived is collected and reported *after*
        // the rest of the teardown, so nothing here can short-circuit it.
        var leftBehind: [String] = []
        // Sign-out fix (6 Oct 2026): remember each saved account's id under a one-way
        // hash of its server and username before the list goes, so signing back in to the
        // same server reuses it and this device's downloads and queued positions come back
        // (`AccountStore.upsert`). Nothing readable about the server is kept.
        AccountStore.retainAccountIds(of: await AccountStore.accounts())
        let passwordHosts = await AccountStore.deleteAllPasswords()
        if !passwordHosts.isEmpty {
            leftBehind.append(String(localized: "saved passwords for \(passwordHosts.joined(separator: ", "))", comment: "Fragment in a Keychain warning, joined with 'and'; %@ is a comma-separated list of server hosts"))
        }
        do {
            try await KeychainService.shared.delete(.accounts)
        } catch {
            leftBehind.append(String(localized: "your saved server list", comment: "Fragment in a Keychain warning, joined with 'and'"))
            ShelfLog.error(.auth, "Remove All Servers couldn't delete the saved-account list: \(error.localizedDescription)")
        }
        do {
            try await KeychainService.shared.deleteAll()
        } catch {
            leftBehind.append(String(localized: "this device\u{2019}s sign-in details", comment: "Fragment in a sign-out Keychain warning, joined with 'and'"))
            ShelfLog.error(.auth, "Remove All Servers couldn't clear every Keychain item: \(error.localizedDescription)")
        }
        AuthStore.shared.clear()
        AccountStore.clearCurrent()
        currentUser = nil
        accounts = []
        isAuthenticated = false
        // Set after `isAuthenticated = false` so this lands on `LoginView`, which is the
        // one screen that actually renders `errorMessage` — and after every other
        // teardown step, so a Keychain that won't let go of one item can't stop it.
        // `login()` clears `errorMessage` on the next attempt.
        if !leftBehind.isEmpty {
            errorMessage = String(localized: "Signed out, but \(leftBehind.joined(separator: " and ")) couldn\u{2019}t be removed from the Keychain. Unlock your device, sign in, and remove all servers again to clear them.", comment: "Remove-all-servers warning; %@ is a list of items joined with 'and'")
        }
        // WATCH-4: see the doc comment on `.shelfheadAccountChanged` — signing out
        // while CarPlay is connected previously left its tabs showing the just-signed-
        // out account's stale data indefinitely.
        NotificationCenter.default.post(name: .shelfheadAccountChanged, object: nil)
    }

    // MARK: - Downloads from signed-out servers

    /// Critique 2026-10-06 (harden): download scopes kept for servers that were signed out
    /// of (Batch 382) and not signed back into. Their files are counted in Settings >
    /// Downloads' storage, so they need a way out besides signing back in.
    var signedOutServerScopeKeys: Set<String> {
        AccountStore.reclaimableRetainedScopes(
            retained: AccountStore.retainedScopeKeys(),
            savedScopes: Set(accounts.map { DownloadManager.scopeKey(serverURL: $0.serverURL, accountId: $0.id) }),
            currentScope: DownloadManager.shared.currentScopeKey())
    }

    /// Deletes the downloads kept for signed-out servers and forgets their retained ids,
    /// so signing in to one of them later starts fresh. Never touches a saved server's or
    /// the live session's scope (`AccountStore.reclaimableRetainedScopes`). Returns how
    /// many servers' downloads were removed.
    ///
    /// Each scope goes the way an account removal's does (resume blobs, Spotlight, the
    /// download tree, its scoped `UserDefaults` keys). Positions still queued for those
    /// scopes in `PendingProgressQueue` are left to its 30-day expiry.
    @discardableResult
    func removeDownloadsFromSignedOutServers() async -> Int {
        await loadAccounts()
        let scopes = signedOutServerScopeKeys
        guard !scopes.isEmpty else { return 0 }
        for scope in scopes {
            DownloadManager.shared.deleteAllPersistedPausedResumeBlobs(scopeKey: scope)
            SpotlightIndexer.remove(scopeKey: scope)
            DownloadManager.shared.deleteDownloads(forScopeKey: scope, wasActiveScope: false)
            for key in DownloadManager.scopedDefaultsKeys(scope: scope) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        AccountStore.forgetRetainedScopes(scopes, keepingIds: Set(accounts.map(\.id)))
        return scopes.count
    }
}
