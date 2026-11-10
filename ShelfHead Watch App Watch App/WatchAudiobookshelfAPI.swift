import Foundation
#if canImport(WatchKit)
import WatchKit
#endif

// MARK: - Watch standalone API client (Stage 1 groundwork)

/// Narrow, Watch-only Audiobookshelf API client for the standalone Watch app.
/// See WATCH_STANDALONE_PROPOSAL_2026-08-28-ADDENDUM.md §1 and §7 for the design
/// this implements.
///
/// This deliberately does NOT reuse the main app's `AudiobookshelfAPI.swift`. The
/// transitive-closure audit in the addendum found that file has real (not vestigial)
/// coupling to two things that don't exist on watchOS: `AudiobookshelfModels.swift`'s
/// `DeviceInfo` (built from `UIDevice.current`) and `DownloadManager.shared` (finding
/// S5, invoked from `performRefresh()` to sweep stale paused-download resume blobs on
/// a successful token rotation). Rather than thread a Watch/iOS-specific device-info
/// provider and a no-op download manager into shared code, this is a separate, narrow
/// actor covering only the endpoints the Watch app actually needs. Neither
/// `AudiobookshelfAPI.swift` nor `AudiobookshelfModels.swift` is touched by this file.
///
/// Shares `AuthStore` (in-memory token holder, `ShelfHead/Services/AuthStore.swift`)
/// and `KeychainService` (`ShelfHead/Services/KeychainService.swift`) with the iOS
/// app — both were confirmed during the addendum's transitive-closure audit to have
/// zero non-portable dependencies (Foundation/Security only) and are now compiled
/// into this Watch target too (see project.pbxproj Sources phase, Stage 1). Left at
/// their existing `ShelfHead/Services/` path rather than moved into a new `Shared/`
/// folder — see this stage's CHANGES_IMPLEMENTED.md entry for why that's a deliberate
/// deviation from the addendum's original (non-binding) suggestion.
///
/// This file lives directly in the Watch target's synchronized folder
/// (`ShelfHead Watch App Watch App/`), so it needed zero project.pbxproj edits to
/// start compiling — unlike `AuthStore.swift`/`KeychainService.swift`, which live
/// outside that folder and needed explicit `PBXBuildFile` + Sources-phase wiring.
///
/// Deliberately excludes `/api/me/sessions` (list/revoke sessions) — that's Stage 2
/// work per the addendum's §7.2, gated on real on-Watch login existing to test
/// against. Also excludes progress *writes* (`PATCH /api/me/progress/:id`) and
/// bookmark writes — Stage 1 is read/session plumbing only; nothing here is called
/// from any UI yet.
///
/// Token refresh has no username/password fallback, unlike the iOS app's
/// `AudiobookshelfAPI.reauthenticateWithStoredCredentials()`. Per the addendum's
/// threat model (§3), the Watch never receives or stores the plaintext account
/// password — only the access + refresh tokens handed off over WatchConnectivity —
/// so there is nothing to silently re-authenticate with here. A rejected refresh
/// token surfaces as `WatchAPIError.sessionExpired`, a distinct case Stage 2 will
/// wire up to an explicit "reconnect" UI state (addendum §7.3) rather than crash,
/// spin, or silently fail every subsequent request.
///
/// **`@MainActor final class`, not `actor` (build-fix, 28 August 2026).** Originally
/// written as a plain custom `actor`, mirroring the iOS app's `AudiobookshelfAPI` —
/// that broke the real build with a wall of "main actor-isolated ... cannot be
/// referenced on a nonisolated actor instance" errors, none of them guesses fixed
/// away; the root cause, found in `project.pbxproj`, is that the two targets have
/// different `SWIFT_DEFAULT_ACTOR_ISOLATION` settings: the main app target
/// (`ShelfHead`) is explicitly `nonisolated`, matching `AudiobookshelfAPI`'s
/// plain-actor design, while the Watch target (`ShelfHead Watch`) is explicitly
/// `MainActor` — matching `WatchConnectivityStore`'s own `@MainActor @Observable`
/// design, but incompatible with a plain, non-Main custom actor calling into it (or
/// into anything else in this module, including this file's own model structs below,
/// which the same default silently makes MainActor-isolated too). A custom actor
/// fighting its own target's default isolation, rather than one more class that goes
/// along with it, was the wrong shape for this file from the start — `@MainActor`
/// matches both the target's own setting and every other piece of Watch app state
/// (`WatchConnectivityStore`, `WatchStore`), and costs nothing here: this is a small,
/// UI-driven client with no heavy concurrent-access pattern that would justify
/// fighting the target's own default to get actor-based isolation instead.
@MainActor
final class WatchAudiobookshelfAPI {
    static let shared = WatchAudiobookshelfAPI()

    /// In-flight refresh, so concurrent 401s trigger only a single refresh — same
    /// rationale as the iOS app's `AudiobookshelfAPI.refreshTask`.
    private var refreshTask: Task<WatchRefreshOutcome, Never>?

    var serverURL: String { AuthStore.shared.serverURL }
    var isConfigured: Bool { AuthStore.shared.isConfigured }

    private init() {}

    // MARK: - Bootstrapping from Keychain

    /// Seeds `AuthStore` from the Keychain if not already configured. Stage 2 will
    /// call this on Watch app launch, after WatchConnectivity handoff has (on first
    /// pairing) written the access/refresh tokens + server URL into this Watch's own
    /// Keychain — mirrors the iOS app's `AudiobookshelfAPI.configureFromKeychainIfNeeded()`.
    /// Unused until Stage 2 wires up the handoff and launch path; included now so the
    /// read side of that plumbing exists alongside the rest of this actor.
    func configureFromKeychainIfNeeded() async {
        guard !isConfigured else { return }
        guard let serverURL = try? await KeychainService.shared.get(.serverURL),
              let accessToken = try? await KeychainService.shared.get(.authToken) else { return }
        let refresh = try? await KeychainService.shared.get(.refreshToken)
        // §9.0 fix (public-release amendment, folded into Stage 7 after being
        // confirmed still outstanding — see this file's own Stage 7 note below):
        // this used to restore serverURL/token/refresh only, silently dropping back
        // to no custom headers on every relaunch. For anyone behind a reverse proxy
        // gating on a header (Cloudflare Access, Basic Auth, etc.), every request
        // after the first relaunch was rejected at the proxy, before ever reaching
        // Audiobookshelf — and nothing named "missing custom header" as the cause,
        // so it presented as an opaque network failure. Mirrors the phone's own
        // `AudiobookshelfAPI.configureFromKeychainIfNeeded()` exactly (same Keychain
        // key, same load-then-seed order).
        let headers = await Self.loadCustomHeadersFromKeychain()
        AuthStore.shared.set(serverURL: serverURL, accessToken: accessToken, refreshToken: refresh ?? nil, customHeaders: headers)
    }

    /// Mirrors the phone's `AudiobookshelfAPI.loadCustomHeadersFromKeychain()`/
    /// `persistCustomHeadersToKeychain(_:)` exactly — same Keychain key
    /// (`.customHeaders`, already shared via `KeychainService.swift` since Stage 1),
    /// same JSON-encoded-dictionary shape. See §9.0's fix above for why this pair
    /// exists at all: without it, custom headers set at login never survive a
    /// relaunch on this Watch.
    static func loadCustomHeadersFromKeychain() async -> [String: String] {
        guard let json = try? await KeychainService.shared.get(.customHeaders),
              let data = json.data(using: .utf8),
              let headers = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return headers
    }

    static func persistCustomHeadersToKeychain(_ headers: [String: String]) async {
        guard let data = try? JSONEncoder().encode(headers), let json = String(data: data, encoding: .utf8) else { return }
        try? await KeychainService.shared.save(json, for: .customHeaders)
    }

    // MARK: - Authentication

    /// Direct username/password login. Stage 2 note: on-Watch login is a fallback path
    /// only (addendum §2.6/§7.3's "manual re-entry" recovery state) — the primary path
    /// is WatchConnectivity handoff from an already-signed-in phone.
    ///
    /// **9 September 2026, review HIGH ("no URL validation"):** the address is now run
    /// through `ServerURLRules.normalizedServerURL(_:)` rather than merely having its slashes
    /// trimmed. That rejects userinfo/query/fragment, rejects a non-HTTP scheme instead
    /// of prepending `https://` in front of it, defaults a bare host to `https`, and
    /// lowercases the host. The *plain-HTTP acknowledgement* gate lives one level up in
    /// `WatchStore.loginManually(...)`, which is the only caller that has a user to ask;
    /// normalising here too means a future direct caller can't skip it.
    ///
    /// **9 September 2026, review MEDIUM ("manual sign-in destroys handed-off
    /// reverse-proxy headers"):** an empty `customHeaders` now means "keep whatever
    /// this Watch already has" rather than "the correct set of headers is none."
    /// `WatchStore.loginManually` passes none, so signing in again behind a Cloudflare
    /// Access / Authelia / `auth_request` gate used to overwrite `AuthStore`'s
    /// in-memory headers *and* the Keychain mirror with `[:]` — after which every
    /// request was rejected at the proxy, presenting as an opaque network failure with
    /// nothing naming the real cause (the same symptom §9.0's fix already documented
    /// once for the relaunch path). A caller that genuinely means "no headers" is the
    /// handoff path, which uses `configureAndPersist(...)` and is left authoritative:
    /// the phone's own header set is the truth there, empty or not.
    func login(serverURL: String, username: String, password: String, customHeaders: [String: String] = [:]) async throws -> WatchLoginResponse {
        guard let url = ServerURLRules.normalizedServerURL(serverURL),
              let requestURL = URL(string: "\(url)/login") else {
            throw WatchAPIError.invalidURL
        }

        // Item 10 (10 September 2026): captured *before* anything is overwritten, so a
        // session this Watch owns outright can be closed server-side once the
        // replacement is confirmed working. Snapshotting first (rather than logging out
        // first) means a failed sign-in leaves the working session it was trying to
        // replace completely untouched.
        let superseded = currentSessionSnapshot()

        var effectiveHeaders = customHeaders
        if effectiveHeaders.isEmpty {
            let inMemory = AuthStore.shared.customHeaders
            effectiveHeaders = inMemory.isEmpty ? await Self.loadCustomHeadersFromKeychain() : inMemory
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ask the server (v2.26+) to return the refresh token in the body — same as
        // the iOS app's login; the Watch is just as unable to rely on an HTTP-only
        // cookie as any other native client.
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.applyCustomHeaders(effectiveHeaders)
        request.httpBody = try JSONEncoder().encode(WatchLoginRequest(username: username, password: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        // Cleanup (Stage 1 review, 28 August 2026): was routed through a separate
        // `validateResponse(_:)` wrapper that existed only for this one call site and
        // did nothing `send`'s own `validateStatus` doesn't already do — a login
        // request is the one call in this file that can't go through `send`/
        // `buildRequest` (there's no token yet to authorize it with), but it can still
        // reuse the same status-code check directly.
        guard let http = response as? HTTPURLResponse else {
            throw WatchAPIError.invalidResponse
        }
        // Bug fix (Stage 2, 28 August 2026), found while writing `loginManually`'s
        // own error mapping: `validateStatus` maps ANY 401 to `.sessionExpired` —
        // correct for `send()`'s authenticated-request path (where a 401 always
        // means "this session, which existed, no longer works"), wrong here. A
        // wrong password on `/login` also returns 401, and has never had a session
        // to expire — it's `.unauthorized` (bad credentials), a different case with
        // a different user-facing message. `send()` avoids this by intercepting 401
        // itself before ever calling `validateStatus`; `login()` needs the same
        // special-case, not a shared call that silently mismaps this one status
        // code for this one endpoint.
        if http.statusCode == 401 {
            throw WatchAPIError.unauthorized
        }
        try validateStatus(http.statusCode)

        let loginResponse = try JSONDecoder().decode(WatchLoginResponse.self, from: data)
        guard let access = loginResponse.user.effectiveAccessToken else {
            throw WatchAPIError.unauthorized
        }

        AuthStore.shared.set(serverURL: url, accessToken: access, refreshToken: loginResponse.user.refreshToken, customHeaders: effectiveHeaders)
        try await persistTokens(serverURL: url, access: access, refresh: loginResponse.user.refreshToken)
        // Item 10: a manual sign-in on the Watch is by definition a session this Watch
        // created for itself. With a refresh token it's `.dedicated` (its own rotation
        // chain, nobody else's to break); without one the server issued its permanent
        // user token instead, which is `.durable` — it never expires, so this Watch
        // needs neither a refresh token nor the phone nearby, but it is *not* exclusive
        // and must never be logged out from here.
        WatchSessionKindStore.set((loginResponse.user.refreshToken?.isEmpty == false) ? .dedicated : .durable)
        // §9.0 fix — see `configureFromKeychainIfNeeded()`'s own doc comment.
        await Self.persistCustomHeadersToKeychain(effectiveHeaders)
        await closeSupersededSession(superseded, replacedBy: access)
        return loginResponse
    }

    /// Seeds `AuthStore` + Keychain directly from a token pair handed off over
    /// WatchConnectivity, bypassing `/login` entirely. This is the primary Stage 2
    /// credential path (addendum §3) — included here, next to `login`, since both
    /// end at the same `persistTokens` call.
    ///
    /// **`sessionKind` (item 10, 10 September 2026).** The handoff reply now says which
    /// kind of credential it carried (`WatchSessionKind`), and that classification has
    /// to be persisted alongside the tokens themselves — it's what later decides
    /// whether an incoming access-token-only handoff may replace this one
    /// (`WatchStore.applyHandoff(existing:incoming:)`), what the account screen tells
    /// the user about needing their iPhone, and whether signing out should close the
    /// session server-side. Defaulted to `.shared` because that's the safe answer for
    /// any caller that doesn't know: it never claims a durability this Watch might not
    /// have, and it never authorises a `POST /logout` on a credential the phone may
    /// also be using.
    func configureAndPersist(serverURL: String, accessToken: String, refreshToken: String?,
                             customHeaders: [String: String] = [:],
                             sessionKind: WatchSessionKind = .shared,
                             superseded suppliedSnapshot: WatchSessionSnapshot?? = nil) async throws {
        // Review 2 Low (handoff retry, 30 October 2026): a caller that retries passes the
        // snapshot it took before the first attempt; otherwise a second attempt would
        // snapshot the already-overwritten `AuthStore` and never close the old session.
        let superseded = suppliedSnapshot ?? currentSessionSnapshot()
        AuthStore.shared.set(serverURL: serverURL, accessToken: accessToken, refreshToken: refreshToken, customHeaders: customHeaders)
        try await persistTokens(serverURL: serverURL, access: accessToken, refresh: refreshToken)
        WatchSessionKindStore.set(sessionKind)
        // §9.0 fix — see `configureFromKeychainIfNeeded()`'s own doc comment. This
        // is the primary Stage 2 credential path (WatchConnectivity handoff), so
        // it's the one call site that matters most in practice — a handoff from a
        // phone whose own server sits behind a header-gated proxy is exactly the
        // case this fix exists for.
        await Self.persistCustomHeadersToKeychain(customHeaders)
        await closeSupersededSession(superseded, replacedBy: accessToken)
    }

    /// Bug fix (Stage 2, 28 August 2026), found while auditing the Keychain
    /// accessibility classes each new credential gets (per Stage 2's build
    /// instructions, item 4): this used to only save `.authToken`/`.refreshToken`,
    /// never `.serverURL` — meaning `configureFromKeychainIfNeeded()`, which
    /// requires *both* `.serverURL` and `.authToken` to be present (its own
    /// `guard let`, above), would find `.serverURL` missing on every relaunch after
    /// the very first one, and silently return without restoring the session at
    /// all. The Watch would have authenticated successfully, then "forgotten" it
    /// the moment the app was closed and reopened. Traced this exact shape back to
    /// the main app: `AudiobookshelfAPI.persistTokens(access:refresh:)` has the
    /// identical omission, but it's harmless there only because
    /// `AuthViewModel.login`/`loginWithOIDC` separately save `.serverURL`
    /// themselves right after calling it (`AuthViewModel.swift:319`/`:436`). This
    /// Watch target has no equivalent second layer — `WatchAudiobookshelfAPI` *is*
    /// the whole auth layer here — so the save has to happen inside this method
    /// directly rather than being assumed to happen somewhere else the way it does
    /// on iOS.
    private func persistTokens(serverURL: String, access: String, refresh: String?) async throws {
        try await KeychainService.shared.save(serverURL, for: .serverURL)
        try await KeychainService.shared.save(access, for: .authToken)
        if let refresh {
            try await KeychainService.shared.save(refresh, for: .refreshToken)
        } else {
            // Review Medium 23 (30 October 2026): a sign-in with no refresh token must not
            // leave the previous session's refresh token behind in the Keychain.
            try? await KeychainService.shared.delete(.refreshToken)
        }
    }

    /// Clears this Watch's own credential entirely — in-memory (`AuthStore`) and on
    /// disk (`KeychainService`). Called by `WatchStore.wipeCredentials()`, itself
    /// triggered by the phone's sign-out/account-switch signal (see
    /// `WatchConnectivityStore.apply(context:)`'s `"wipeCredentials"` branch and
    /// `WatchSessionManager.clearWatchState()` on the phone side). Reuses
    /// `KeychainService.deleteAll()` — the same call the iOS app's own `logout()`
    /// makes — rather than deleting keys one at a time: this Watch never writes
    /// `.username`/`.password`/`.userId`/`.accounts` in the first place (see this
    /// type's own doc comment on the threat model), so deleting those is a
    /// harmless no-op here, and reusing the existing method means there's only one
    /// place that has to know the full key list.
    ///
    /// **Item 10 (10 September 2026): the session is now closed server-side too, when
    /// — and only when — this Watch owns it outright.** Before item 10 that question
    /// couldn't even be asked: the Watch was using the phone's own session, and a
    /// `POST /logout` would have signed the *phone* out as a side effect of the phone
    /// signing itself out. Now a `.dedicated` session is one the phone minted
    /// specifically for this Watch (or that this Watch created by signing in itself)
    /// and then forgot, so nothing else is using it and leaving it open would strand a
    /// live session in the user's "Manage Sessions" list forever. `.durable`
    /// (Audiobookshelf's permanent user token) and `.shared` (a copy of the phone's
    /// access token) are deliberately *not* closed — both are credentials the phone is
    /// very likely still authenticating with.
    ///
    /// Best-effort in the strict sense: the local wipe happens first and unconditionally,
    /// so an unreachable server, a Watch with no network, or an already-invalid token
    /// can never leave a credential behind on the device. The logout is a short,
    /// timeout-bounded courtesy call afterwards, and its result is ignored.
    func wipeCredentials() async {
        let closing = currentSessionSnapshot()
        AuthStore.shared.clear()
        try? await KeychainService.shared.deleteAll()
        WatchSessionKindStore.clear()
        guard let closing, closing.kind?.ownedExclusivelyByThisWatch == true else { return }
        await Self.closeSessionOnServer(serverURL: closing.serverURL,
                                        accessToken: closing.accessToken,
                                        refreshToken: closing.refreshToken,
                                        customHeaders: closing.customHeaders)
    }

    // MARK: - Session teardown (item 10)

    /// Everything needed to close a session *after* it has stopped being this Watch's
    /// current one. Taken before any overwrite, because by the time the replacement is
    /// in place `AuthStore` no longer remembers what it replaced.
    struct WatchSessionSnapshot {
        let serverURL: String
        let accessToken: String
        let refreshToken: String?
        let customHeaders: [String: String]
        let kind: WatchSessionKind?
    }

    func currentSessionSnapshot() -> WatchSessionSnapshot? {
        guard AuthStore.shared.isConfigured else { return nil }
        return WatchSessionSnapshot(serverURL: AuthStore.shared.serverURL,
                                    accessToken: AuthStore.shared.accessToken,
                                    refreshToken: AuthStore.shared.refreshToken,
                                    customHeaders: AuthStore.shared.customHeaders,
                                    kind: WatchSessionKindStore.current)
    }

    /// Closes a session that has just been replaced by a new one — the orphan case:
    /// re-handing-off or signing in again over a `.dedicated` session would otherwise
    /// leave the old one live on the server with nothing on any device using it.
    ///
    /// Skipped when the credential is unchanged (a re-handoff that happened to return
    /// the same token would otherwise log out the session that was just adopted) and
    /// whenever the superseded session wasn't exclusively this Watch's.
    /// Review 2 Low (handoff retry, 30 October 2026): puts `AuthStore` back to `snapshot`
    /// (or empties it when there was no session) after a handoff whose Keychain save failed.
    /// Review 4 Low (restore vs refresh): `installedAccessToken` is the handoff token that failed to
    /// save; if `AuthStore` no longer holds it, a 401 refresh rotated the tokens meanwhile and the
    /// stale snapshot must not overwrite them.
    func restoreSession(_ snapshot: WatchSessionSnapshot?, installedAccessToken: String? = nil) async {
        if let installedAccessToken, AuthStore.shared.accessToken != installedAccessToken { return }
        // Review 3 Low (handoff keychain): the failed save may have left a half-written token set
        // on disk, so put the Keychain back too (or clear it), or the next launch lands on it.
        if let snapshot {
            AuthStore.shared.set(serverURL: snapshot.serverURL, accessToken: snapshot.accessToken,
                                 refreshToken: snapshot.refreshToken, customHeaders: snapshot.customHeaders)
            try? await persistTokens(serverURL: snapshot.serverURL, access: snapshot.accessToken, refresh: snapshot.refreshToken)
            await Self.persistCustomHeadersToKeychain(snapshot.customHeaders)
        } else {
            AuthStore.shared.clear()
            try? await KeychainService.shared.deleteAll()
        }
    }

    private func closeSupersededSession(_ superseded: WatchSessionSnapshot?, replacedBy newAccessToken: String) async {
        guard let superseded,
              superseded.kind?.ownedExclusivelyByThisWatch == true,
              !superseded.accessToken.isEmpty,
              superseded.accessToken != newAccessToken else { return }
        await Self.closeSessionOnServer(serverURL: superseded.serverURL,
                                        accessToken: superseded.accessToken,
                                        refreshToken: superseded.refreshToken,
                                        customHeaders: superseded.customHeaders)
    }

    /// Best-effort `POST /logout` for one specific set of credentials.
    ///
    /// Takes them explicitly rather than reading `AuthStore` (the way the phone's
    /// `AudiobookshelfAPI.logout()` does) because every caller here is closing a
    /// session that is *no longer* the current one — reading the store would either
    /// log out the wrong session or find nothing at all. Sends the refresh token in
    /// `x-refresh-token` alongside the bearer token, matching the phone's `logout()`,
    /// since that's the header Audiobookshelf uses to identify which refresh session
    /// to invalidate for a client that can't use the web cookie.
    ///
    /// Short `timeoutInterval`: this runs inside sign-out, which the user is watching,
    /// and in the account-switch case is triggered from a background
    /// `transferUserInfo` delivery. Nothing depends on the outcome, so waiting out the
    /// default 60 seconds for an unreachable server would be pure cost.
    ///
    /// No token appears in any log line on this path — same rule as every other
    /// credential path in this file.
    ///
    /// `nonisolated` so it doesn't depend on any of this class's state, and can't
    /// accidentally be given "whatever the current session is" instead of the specific
    /// one it's meant to close.
    nonisolated static func closeSessionOnServer(serverURL: String, accessToken: String,
                                                 refreshToken: String?, customHeaders: [String: String]) async {
        guard !serverURL.isEmpty, !accessToken.isEmpty,
              let url = URL(string: "\(serverURL)/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        // Custom headers first, `Authorization` last — the same last-write-wins
        // ordering (and the same reason for it) as `AuthStore.authorizedRequest(url:)`.
        request.applyCustomHeaders(customHeaders)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let refreshToken, !refreshToken.isEmpty {
            request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Token refresh (no password fallback — see type doc comment)

    private func refreshOutcome() async -> WatchRefreshOutcome {
        if let task = refreshTask { return await task.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Item 10 (10 September 2026): with a `.dedicated` session this is now a rotation
    /// chain that belongs to this Watch alone — the phone is rotating its own,
    /// separately, and neither can invalidate the other. Two properties this path
    /// already had are what make that work, so don't lose them: the rotated pair is
    /// persisted (below) rather than only held in memory, and the phone never
    /// overwrites it, because the credential handoff reply is the only message the
    /// phone sends that contains a token at all (audited in
    /// `WatchSessionManager.buildCredentialHandoffReply()`'s doc comment) and it is
    /// only ever sent in reply to a request this Watch made.
    ///
    /// With a `.shared` session there is no refresh token by construction, so this
    /// returns `false` at the first guard and the 401 becomes
    /// `WatchAPIError.sessionExpired` → `WatchStore.signalSessionExpired()`, which asks
    /// the phone for a fresh handoff instead.
    /// Review Medium 35 (30 October 2026): a transport error, 5xx, 429 or undecodable 200
    /// used to return `false`, which the caller turned into `.sessionExpired` (and so a
    /// "reconnect" dead end). Only 401/403 or no refresh token is a rejection. Mirrors
    /// `AudiobookshelfAPI.classifyRefreshResult` on iOS.
    nonisolated static func classifyRefreshResult(statusCode: Int?, transportError: Error?, decodedToken: Bool) -> WatchRefreshOutcome {
        if transportError != nil { return .couldNotComplete }
        guard let statusCode else { return .couldNotComplete }
        if statusCode == 401 || statusCode == 403 { return .rejected }
        if statusCode == 200 && decodedToken { return .refreshed }
        return .couldNotComplete
    }

    private func performRefresh() async -> WatchRefreshOutcome {
        guard let refresh = AuthStore.shared.refreshToken, !refresh.isEmpty,
              let url = URL(string: "\(AuthStore.shared.serverURL)/auth/refresh") else {
            return .rejected
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.applyCustomHeaders()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return Self.classifyRefreshResult(statusCode: nil, transportError: error, decodedToken: false)
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        let lr = status == 200 ? try? JSONDecoder().decode(WatchLoginResponse.self, from: data) : nil
        guard let lr, let access = lr.user.effectiveAccessToken,
              Self.classifyRefreshResult(statusCode: status, transportError: nil, decodedToken: true) == .refreshed else {
            return Self.classifyRefreshResult(statusCode: status, transportError: nil, decodedToken: false)
        }

        let newRefresh = lr.user.refreshToken ?? refresh
        AuthStore.shared.updateTokens(accessToken: access, refreshToken: newRefresh)
        // `serverURL` doesn't actually change on a token refresh, but `persistTokens`
        // now always writes it (see that method's own doc comment on why the write
        // has to happen unconditionally rather than being assumed already-there) —
        // re-saving the same value here is harmless, and keeps this call site
        // identical in shape to `login()`/`configureAndPersist()` rather than
        // needing a third, narrower persistence helper just for this one path.
        try? await persistTokens(serverURL: AuthStore.shared.serverURL, access: access, refresh: newRefresh)
        return .refreshed
    }

    /// Cheap authenticated probe used by `WatchLocalDownloadManager` (Item 21, 9
    /// September 2026 review) to tell a genuinely expired session apart from a 401
    /// that only a media/download URL returned — a reverse proxy in front of
    /// Audiobookshelf can gate streaming/download endpoints differently from the JSON
    /// API, and a background download delegate can't itself distinguish the two (it
    /// bypasses `send(...)` entirely — see `CLAUDE.md`'s recognised exception for
    /// background transfers). `/api/me` is the smallest authenticated `GET` this type
    /// has; `get(...)` already goes through `send(...)`'s standard silent
    /// refresh-and-retry-once on a 401, so a `true` here means the access token —
    /// refreshed or not — is still good, regardless of what the media host returned.
    ///
    /// Review 2 Medium 6 (30 October 2026): this used to return a `Bool` that was `false`
    /// for *any* error, so a transport failure or a refresh that couldn't complete read
    /// as a dead session and signed the Watch out. It now says which of three things
    /// happened (`WatchSessionProbeResult`).
    func verifySessionStillAuthenticates() async -> WatchSessionProbeResult {
        do {
            _ = try await get("/api/me") as WatchUser
            return .authenticated
        } catch {
            return Self.sessionProbeResult(forError: error)
        }
    }

    /// Pure classification of a failed probe. Only `.sessionExpired` (a 401 that survived
    /// `send(...)`'s refresh-and-retry, or a refresh the server rejected) is proof the
    /// session is dead. Transport failures, a refresh that couldn't complete (which
    /// `send(...)` surfaces as `.transportError`), 403/5xx and anything else are unknown.
    nonisolated static func sessionProbeResult(forError error: Error) -> WatchSessionProbeResult {
        if case WatchAPIError.sessionExpired = error { return .rejected }
        return .unknown
    }

    // MARK: - Libraries

    func getLibraries() async throws -> [WatchLibrary] {
        struct LibrariesResponse: Codable { let libraries: [WatchLibrary] }
        let response: LibrariesResponse = try await get("/api/libraries")
        return response.libraries
    }

    func getLibraryItems(libraryId: String, limit: Int = 50, page: Int = 0, sort: String = "media.metadata.title", desc: Bool = false) async throws -> WatchLibraryItemsResponse {
        // Cleanup (Stage 1 review, 28 August 2026): was building this query string
        // inline via a now-removed `encodedQuery(_:)` helper — a second, parallel
        // encoding mechanism alongside `buildRequest`'s own `queryItems` handling. Two
        // ways to attach a query string to the same request is a latent footgun (see
        // `buildRequest`'s doc comment on `percentEncodedQuery`): nothing currently
        // combines both on one call, but the day something does, whichever runs second
        // silently wins. Routed through the one mechanism instead.
        let queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "desc", value: desc ? "1" : "0")
        ]
        return try await get("/api/libraries/\(pc(libraryId))/items", queryItems: queryItems)
    }

    // MARK: - Items

    /// Percent-encode a server-provided identifier before interpolating it into a URL
    /// path — same rationale as `AudiobookshelfAPI.pc(_:)`.
    private func pc(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    func getItem(itemId: String) async throws -> WatchLibraryItem {
        try await get("/api/items/\(pc(itemId))", queryItems: [
            URLQueryItem(name: "expanded", value: "1"),
            URLQueryItem(name: "include", value: "progress")
        ])
    }

    /// Stage 4 (addendum §4/§10.2): mirrors `shelfCoverURL(itemId:width:)`
    /// (`Extensions.swift:496–504`) exactly — same path shape, same reasoning for
    /// keeping the token out of the query string (Bearer header instead, via
    /// `AuthStore.shared.authorizedRequest(url:)`, applied by `WatchCoverLoader`, not
    /// here). Deliberately narrower than the phone version: no `DownloadManager
    /// .localCoverURL` check, since standalone Watch downloads don't exist yet
    /// (Stage 5) — `WatchCoverLoader` is the seam where that check gets added once
    /// they do, not this pure URL-construction helper.
    func coverURL(itemId: String, width: Int = 200) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        return URL(string: "\(serverURL)/api/items/\(pc(itemId))/cover?width=\(width)")
    }

    /// Real on-device bug fix (31 August 2026): "no book covers shown in library at
    /// all." `WatchCoverLoader.loadCoverData` used to fetch cover bytes via a raw
    /// `URLSession.shared.data(for:)` call built from `coverURL(itemId:width:)`
    /// above, bypassing `send(...)` entirely — the one place in this class that knows
    /// how to refresh an aged-out access token and retry once on a 401
    /// (`send(path:method:...)`, above). Every other endpoint (item lists, playback
    /// sessions, search) self-heals through that retry automatically; covers didn't.
    /// Once the Watch's access token aged out mid-session, every cover request would
    /// 401 forever, and `loadCoverData`'s own catch-all `return nil` (by design, so a
    /// missing cover degrades to a fallback glyph instead of surfacing an error)
    /// silently absorbed it — which matches the reported symptom exactly: titles,
    /// authors, and playback kept working (they go through `send`), but not a single
    /// cover ever rendered, with nothing in the failure to distinguish "no covers due
    /// to expired token" from "no covers because this server has none." Routing cover
    /// fetches through `send` gives them the same automatic refresh-and-retry, and the
    /// same `WatchAPIError.transportError` classification for ATS/TLS failures, as
    /// every other request this class makes.
    func coverData(itemId: String, width: Int = 200) async throws -> Data {
        try await send(path: "/api/items/\(pc(itemId))/cover", method: "GET", queryItems: [
            URLQueryItem(name: "width", value: "\(width)")
        ])
    }

    // MARK: - Playback session

    func startPlaybackSession(itemId: String) async throws -> WatchPlaybackSession {
        try await post("/api/items/\(pc(itemId))/play", body: WatchPlaybackSessionRequest())
    }

    /// Starts a session for one episode of a podcast — see
    /// `AudiobookshelfAPI.startPlaybackSession(itemId:episodeId:)` for why this is a
    /// distinct endpoint from the book path above.
    func startPlaybackSession(itemId: String, episodeId: String) async throws -> WatchPlaybackSession {
        try await post("/api/items/\(pc(itemId))/play/\(pc(episodeId))", body: WatchPlaybackSessionRequest())
    }

    func syncSession(sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = WatchSyncSessionRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        try await postNoResponse("/api/session/\(pc(sessionId))/sync", body: body)
    }

    func closeSession(sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = WatchSyncSessionRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        try await postNoResponse("/api/session/\(pc(sessionId))/close", body: body)
    }

    // MARK: - Progress writes (Stage 6 — the Watch as a third writer)

    /// Direct progress write, no playback session involved — mirrors the phone's
    /// `AudiobookshelfAPI.updateProgress(libraryItemId:progress:currentTime:duration:
    /// isFinished:)` exactly (same endpoint, same body shape). This is the only
    /// progress-writing path available for a Stage 5 offline/local download: that
    /// playback never opens a session at all (`StandaloneAudioEngine`'s own doc
    /// comment on `local:` playback), so there is no session id to `syncSession`/
    /// `closeSession` against — `WatchProgressSyncCoordinator` calls this instead,
    /// queuing through `WatchPendingProgressQueue` when it fails.
    func updateProgress(itemId: String, progress: Double, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        struct ProgressUpdate: Codable {
            let progress: Double
            let currentTime: Double
            let isFinished: Bool
            let duration: Double
        }
        let body = ProgressUpdate(progress: progress, currentTime: currentTime, isFinished: isFinished, duration: duration)
        _ = try await send(path: "/api/me/progress/\(pc(itemId))", method: "PATCH", body: try JSONEncoder().encode(body))
    }

    /// Batch 413: Book Details' Mark as Finished. Only `isFinished` is sent, as the ABS web
    /// client does, so the server keeps the listening position, stamps `finishedAt`, and
    /// (for a book with no progress yet) records progress as 1
    /// (`User.createUpdateMediaProgressFromPayload`, ABS 2.36 source).
    func markFinished(itemId: String) async throws {
        struct FinishedUpdate: Codable { let isFinished: Bool }
        _ = try await send(path: "/api/me/progress/\(pc(itemId))", method: "PATCH", body: try JSONEncoder().encode(FinishedUpdate(isFinished: true)))
    }

    // MARK: - Bookmarks (PL-4 follow-up)

    /// `POST /api/me/item/{id}/bookmark`, the phone's own create call (`AudiobookshelfAPI`).
    func createBookmark(itemId: String, time: Double, title: String) async throws {
        struct Body: Encodable { let time: Double; let title: String }
        _ = try await send(path: "/api/me/item/\(pc(itemId))/bookmark", method: "POST",
                           body: try JSONEncoder().encode(Body(time: time, title: title)))
    }

    /// This item's bookmarks from `GET /api/me` (the user object carries them all).
    func getBookmarks(itemId: String) async throws -> [StandaloneBookmark] {
        struct Me: Decodable {
            struct Row: Decodable { let libraryItemId: String; let title: String?; let time: Double }
            let bookmarks: [Row]?
        }
        let me: Me = try await get("/api/me")
        return (me.bookmarks ?? []).filter { $0.libraryItemId == itemId }
            .map { StandaloneBookmark(itemId: $0.libraryItemId, title: $0.title ?? "", time: $0.time, isPending: false) }
    }

    // MARK: - Auth sessions (revocation, Stage 2)

    /// Lists this account's active *login* sessions — distinct from, and unrelated
    /// to, `getListeningSessions()` in the main app's `AudiobookshelfAPI.swift`
    /// (`/api/me/listening-sessions`, playback history feeding Stats). Same
    /// "sessions" word, different resource: this is `GET /api/me/sessions`, added
    /// in Audiobookshelf v2.36.0 specifically for auth-session management
    /// (list/revoke — the mechanism that makes handing the refresh token off to
    /// this Watch defensible at all, per the addendum's §3 threat model).
    ///
    /// **Schema verification, honestly stated:** this sandbox has no network path
    /// to the real self-hosted Audiobookshelf server this app talks to — no
    /// credentials for it, no route from this environment to a private/LAN/
    /// self-hosted host. "Check the response schema against the live server," as
    /// committed to in the addendum's §7.2, wasn't literally possible here. What
    /// was checked instead: Audiobookshelf's own public server source on GitHub —
    /// `server/controllers/MeController.js`, `getSessions`/`deleteSession`,
    /// `master` branch, fetched 28 August 2026 — which is the actual code that
    /// constructs this response, not a single sample of it. `WatchAuthSession`
    /// below matches that handler's `sessions.map(...)` shape field-for-field
    /// (`id`, `ipAddress`, `userAgent`, `createdAt`, `updatedAt`, `current`),
    /// deliberately omitting `deviceInfo` (a `parseUserAgent()` object this Watch
    /// UI doesn't need — Codable silently ignores response keys a struct doesn't
    /// declare, so leaving it out is safe, not a gap). This is source-verified,
    /// not live-server-verified: `master` could in principle differ from
    /// whatever exact build the real server is running, though the field
    /// shape here looks stable since the endpoint's introduction. Recorded as
    /// `[needs a live spot-check against the real server before this ships]` in
    /// this stage's `CHANGES_IMPLEMENTED.md` — if a real request ever returns a
    /// shape that doesn't match, the effect is a decode failure surfaced as
    /// `WatchAPIError.invalidResponse`, not silent corruption or a crash.
    ///
    /// Named `getAuthSessions`/`revokeAuthSession` throughout — not
    /// `getSessions`/`deleteSession`, which would echo `getListeningSessions` far
    /// too closely for how unrelated the two resources actually are — specifically
    /// so the two can never be confused at a call site.
    /// §9.1 item 1 (public-release amendment) — **capability detection, not a
    /// hardcoded version string.** `GET`/`DELETE /api/me/sessions` require
    /// Audiobookshelf v2.36.0+; probing once at connect time and treating a 404 as
    /// "sessions API absent" is a reliable, low-maintenance signal that doesn't
    /// require keeping a version table in sync with future server releases —
    /// Audiobookshelf has no dedicated capabilities endpoint to ask instead.
    ///
    /// Returns `nil` (not `false`) on any failure other than a clean 404 — a
    /// timeout, a 500, or no network at all says nothing about whether the *route*
    /// exists, and treating those the same as "definitely absent" would hide the
    /// sessions screen for a server that actually supports it, just because this one
    /// probe happened to fail. Callers should treat `nil` as "leave the previous
    /// answer in place" (default to showing the screen until proven otherwise), not
    /// as its own third UI state.
    ///
    /// **Documented minimum supported version for standalone Watch mode:
    /// Audiobookshelf 2.36.0.** Not 2.26.0 (the floor for the JWT/refresh-token
    /// model itself) — session management is the harder-required feature of the
    /// two, since a server between 2.26.0 and 2.36.0 would have working auth but a
    /// permanently-hidden sessions screen, a worse asymmetry than drawing the floor
    /// here and treating anything older as "phone-tethered only, no standalone Watch
    /// auth." Not enforced anywhere as a parsed version check — this probe is the
    /// actual mechanism; the number above is documentation for a human, not a
    /// runtime gate.
    func probeSessionsAPISupported() async -> Bool? {
        do {
            _ = try await getAuthSessions(page: 0, itemsPerPage: 1)
            return true
        } catch WatchAPIError.notFound {
            return false
        } catch {
            return nil
        }
    }

    func getAuthSessions(page: Int = 0, itemsPerPage: Int = 20) async throws -> [WatchAuthSession] {
        let queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "itemsPerPage", value: "\(itemsPerPage)")
        ]
        let response: WatchAuthSessionsResponse = try await get("/api/me/sessions", queryItems: queryItems)
        return response.sessions
    }

    /// Revokes a single login session by id. The verified server handler
    /// (`deleteSession`, above) replies with a bare `200` and no body on success —
    /// `send`'s own `validateStatus` already treats any 2xx as success, so there's
    /// nothing to decode here.
    func revokeAuthSession(id: String) async throws {
        _ = try await send(path: "/api/me/sessions/\(pc(id))", method: "DELETE")
    }

    // MARK: - Progress (read only — see type doc comment)

    func getItemsInProgress(limit: Int = 20) async throws -> [WatchLibraryItem] {
        struct Response: Codable { let libraryItems: [WatchLibraryItem] }
        let response: Response = try await get("/api/me/items-in-progress", queryItems: [URLQueryItem(name: "limit", value: "\(max(1, limit))")])
        return response.libraryItems
    }

    // MARK: - Search

    func search(libraryId: String, query: String) async throws -> [WatchLibraryItem] {
        struct SearchResponse: Codable {
            let book: [BookResult]?
            struct BookResult: Codable { let libraryItem: WatchLibraryItem }
        }
        // `libraryId` is server-supplied (came back from `getLibraries()`), not
        // user-typed, so this wasn't a live bug — but every other path-segment
        // interpolation in this file routes through `pc(_:)`, and an inconsistency
        // like that is exactly the kind of thing that gets copied into the next new
        // method without anyone noticing it was ever an exception.
        let response: SearchResponse = try await get("/api/libraries/\(pc(libraryId))/search", queryItems: [URLQueryItem(name: "q", value: query)])
        return response.book?.map(\.libraryItem) ?? []
    }

    // MARK: - Networking helpers

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path: path, method: "GET", queryItems: queryItems)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let data = try await send(path: path, method: "POST", body: try JSONEncoder().encode(body))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postNoResponse<B: Encodable>(_ path: String, body: B) async throws {
        _ = try await send(path: path, method: "POST", body: try JSONEncoder().encode(body))
    }

    /// Central request executor with one automatic refresh-and-retry on 401 — same
    /// shape as `AudiobookshelfAPI.send`, minus the password-reauth fallback.
    private func send(path: String, method: String, queryItems: [URLQueryItem] = [], body: Data? = nil, allowRetry: Bool = true) async throws -> Data {
        let request = try buildRequest(path: path, method: method, queryItems: queryItems, body: body)
        let data: Data
        let response: URLResponse
        // Real on-device bug fix (29 August 2026): this used to let a raw `URLError`
        // propagate straight out of `URLSession.shared.data(for:)` — which failed the
        // `as? WatchAPIError` cast in `WatchStandaloneLibraryStore.message(for:)`, so
        // every transport-layer failure (including the App Transport Security block
        // that was the actual root cause of "Retry" appearing with the Watch's Wi-Fi
        // confirmed connected — see the Watch Info.plist's own comment on
        // `NSAppTransportSecurity`) collapsed into the same generic "Couldn't reach the
        // server," indistinguishable from a genuine no-network condition. Wrapping and
        // classifying it here means a future transport failure (a self-signed cert
        // this app still doesn't have a trust delegate for, say) surfaces a distinct,
        // more actionable message instead of the same catch-all.
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw WatchAPIError.transportError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WatchAPIError.invalidResponse
        }

        if http.statusCode == 401 {
            guard allowRetry else { throw WatchAPIError.sessionExpired }
            switch await refreshOutcome() {
            case .refreshed:
                return try await send(path: path, method: method, queryItems: queryItems, body: body, allowRetry: false)
            case .couldNotComplete:
                // Review Medium 35: a flaky refresh is not a dead session.
                throw WatchAPIError.transportError(URLError(.networkConnectionLost))
            case .rejected:
                throw WatchAPIError.sessionExpired
            }
        }

        try validateStatus(http.statusCode)
        return data
    }

    private func buildRequest(path: String, method: String, queryItems: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard !AuthStore.shared.serverURL.isEmpty,
              var components = URLComponents(string: "\(AuthStore.shared.serverURL)\(path)") else {
            throw WatchAPIError.invalidURL
        }

        if !queryItems.isEmpty {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let parts = queryItems.map { item -> String in
                let key = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
                let rawValue = item.value ?? ""
                let value = rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
                return "\(key)=\(value)"
            }
            components.percentEncodedQuery = parts.joined(separator: "&")
        }

        guard let url = components.url, url.host != nil else {
            throw WatchAPIError.invalidURL
        }

        var request = AuthStore.shared.authorizedRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200...299:
            return
        case 401:
            throw WatchAPIError.sessionExpired
        case 403:
            throw WatchAPIError.forbidden
        case 404:
            throw WatchAPIError.notFound
        case 500...599:
            throw WatchAPIError.serverError(statusCode)
        default:
            throw WatchAPIError.httpError(statusCode)
        }
    }
}

// MARK: - Session probe result

/// Outcome of `WatchAudiobookshelfAPI.verifySessionStillAuthenticates()` (Review 2 Medium 6).
nonisolated enum WatchSessionProbeResult: Equatable {
    /// `/api/me` succeeded (after a silent refresh if one was needed).
    case authenticated
    /// The server definitively refused the credentials.
    case rejected
    /// Couldn't tell: offline, timeout, a refresh that couldn't complete, a gate answering 403, 5xx.
    case unknown
}

// MARK: - Errors

enum WatchAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    /// A login response with no usable access token (e.g. a server rejecting the
    /// credentials outright — a normal, expected outcome of `login()`, not a bug).
    /// Build fix (28 August 2026): this file referenced `.unauthorized` at `login()`'s
    /// one call site since it was first written, but the case itself was never
    /// declared — an unbuilt file's missing-case error that only a real compile could
    /// have caught, and did.
    case unauthorized
    /// A 401 that survived one refresh attempt (or arrived with no refresh token to
    /// try in the first place) on an already-established session. Distinct from
    /// `.unauthorized` above — Stage 2 routes this specific case to the "reconnect"
    /// dead-end UI (addendum §7.3) rather than treating it like any other failed
    /// request.
    case sessionExpired
    case forbidden
    case notFound
    case serverError(Int)
    case httpError(Int)
    /// A transport-layer failure below the HTTP level — never got an
    /// `HTTPURLResponse` at all. Classified by `URLError.Code` so App Transport
    /// Security blocks and certificate-trust failures read as something the user can
    /// actually act on, instead of the same message a plain "no network" condition
    /// would show.
    case transportError(URLError)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid server URL")
        case .invalidResponse:
            return String(localized: "Invalid response from server")
        case .unauthorized:
            return String(localized: "Authentication failed. Please check your credentials.")
        case .sessionExpired:
            return String(localized: "Your session has expired. Please reconnect.")
        case .forbidden:
            return String(localized: "Access denied")
        case .notFound:
            return String(localized: "Resource not found")
        case .serverError(let code):
            return String(localized: "Server error (\(code))", comment: "%lld is an HTTP status code")
        case .httpError(let code):
            return String(localized: "HTTP error (\(code))", comment: "%lld is an HTTP status code")
        case .transportError(let urlError):
            switch urlError.code {
            case .appTransportSecurityRequiresSecureConnection:
                return String(localized: "Blocked by this Watch app's security settings. Please update the app.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected:
                return String(localized: "Couldn't verify the server's security certificate.")
            default:
                return String(localized: "Couldn't reach the server.")
            }
        }
    }
}

// MARK: - Models

// Deliberately a separate, narrower model set from `AudiobookshelfModels.swift` (main
// app target only) — see this file's top-level doc comment. Named with a `Watch`
// prefix throughout to avoid any ambiguity with the main app's identically-shaped
// types, even though the two targets don't actually share a module namespace.

struct WatchLoginRequest: Codable {
    let username: String
    let password: String
}

struct WatchLoginResponse: Codable {
    let user: WatchUser
    let userDefaultLibraryId: String?
}

struct WatchUser: Codable, Identifiable {
    let id: String
    let username: String
    let token: String?
    let accessToken: String?
    let refreshToken: String?
    let mediaProgress: [WatchMediaProgress]?

    var effectiveAccessToken: String? { accessToken ?? token }
}

struct WatchLibrary: Codable, Identifiable {
    let id: String
    let name: String
    let mediaType: String?
    let icon: String?
}

struct WatchLibraryItemsResponse: Decodable {
    let results: [WatchLibraryItem]
    let total: Int
    let page: Int

    enum CodingKeys: String, CodingKey { case results, total, page }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A single malformed item shouldn't fail the whole library screen — same
        // lossy-decode rationale as the iOS app's `LibraryItemsResponse`.
        results = (try? c.decode(WatchLossyArray<WatchLibraryItem>.self, forKey: .results))?.elements ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? results.count
        page = (try? c.decode(Int.self, forKey: .page)) ?? 0
    }
}

struct WatchLibraryItem: Codable, Identifiable {
    let id: String
    let libraryId: String?
    let mediaType: String?
    let media: WatchMedia?
    let addedAt: Int?
    let updatedAt: Int?
    let mediaProgress: WatchMediaProgress?
    /// Critique 2026-10-06 (harden): the item's size on the server in bytes (Audiobookshelf
    /// sends `size` on library items, minified or not). Optional, and a `Double` because
    /// JSON numbers decode as one either way; used only for the before-download room check.
    var size: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, libraryId, mediaType, media, addedAt, updatedAt, size
        case mediaProgress = "userMediaProgress"
    }

    var isPodcast: Bool { mediaType == "podcast" }

    /// `size` as whole bytes, or `nil` when the server didn't send a usable one.
    var sizeBytes: Int64? {
        guard let size, size.isFinite, size > 0 else { return nil }
        return Int64(size)
    }
}

struct WatchMedia: Codable {
    let metadata: WatchMediaMetadata?
    let coverPath: String?
    let duration: Double?
    let chapters: [WatchChapter]?
    let numChapters: Int?
    let numAudioFiles: Int?
}

struct WatchMediaMetadata: Codable {
    let title: String?
    let subtitle: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let description: String?
    let publishedYear: String?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, description
        case authorName, narratorName, seriesName, publishedYear
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant decode, matching `AudiobookshelfModels.MediaMetadata` — an
        // unexpected shape on one field shouldn't fail the whole item.
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        authorName = (try? c.decodeIfPresent(String.self, forKey: .authorName)) ?? nil
        narratorName = (try? c.decodeIfPresent(String.self, forKey: .narratorName)) ?? nil
        seriesName = (try? c.decodeIfPresent(String.self, forKey: .seriesName)) ?? nil
        publishedYear = (try? c.decodeIfPresent(String.self, forKey: .publishedYear)) ?? nil
    }
}

struct WatchChapter: Codable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let title: String

    enum CodingKeys: String, CodingKey { case id, start, end, title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
    }
}

struct WatchMediaProgress: Codable, Identifiable {
    let id: String
    let libraryItemId: String
    let episodeId: String?
    let duration: Double?
    let progress: Double?
    let currentTime: Double?
    let isFinished: Bool?
    let lastUpdate: Int?
}

struct WatchPlaybackSessionRequest: Codable {
    let deviceInfo: WatchDeviceInfo
    let forceDirectPlay: Bool
    let forceTranscode: Bool
    let mediaPlayer: String
    let supportedMimeTypes: [String]

    init() {
        self.deviceInfo = WatchDeviceInfo()
        self.forceDirectPlay = true
        self.forceTranscode = false
        self.mediaPlayer = "ShelfHead Watch"
        self.supportedMimeTypes = [
            "audio/mpeg",
            "audio/mp4",
            "audio/aac",
            "audio/x-m4a",
            "audio/x-m4b",
            "audio/ogg",
            "audio/flac"
        ]
    }
}

/// watchOS analog of `AudiobookshelfModels.DeviceInfo` — that type builds its
/// `deviceId`/`model` from `UIDevice.current`, which doesn't exist on watchOS. This
/// uses `WKInterfaceDevice.current()` instead; everything else about the shape (and
/// the fields the server expects) is identical.
struct WatchDeviceInfo: Codable {
    let deviceId: String
    let clientName: String
    let clientVersion: String
    let manufacturer: String
    let model: String
    let sdkVersion: Int

    init() {
        #if canImport(WatchKit)
        self.deviceId = WKInterfaceDevice.current().identifierForVendor?.uuidString ?? UUID().uuidString
        self.model = WKInterfaceDevice.current().model
        #else
        self.deviceId = UUID().uuidString
        self.model = "Apple Watch"
        #endif
        self.clientName = "ShelfHead Watch"
        self.clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.manufacturer = "Apple"
        self.sdkVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
}

struct WatchPlaybackSession: Codable, Identifiable {
    let id: String
    let libraryItemId: String?
    let mediaType: String?
    let duration: Double?
    let playMethod: Int?
    let audioTracks: [WatchAudioTrack]?
    let currentTime: Double?
    let startTime: Double?
    let chapters: [WatchChapter]?
    let libraryItem: WatchLibraryItem?
}

struct WatchAudioTrack: Codable, Identifiable {
    // Combine index and contentUrl so two nil-index tracks don't collide on "0" —
    // same rationale as `AudiobookshelfModels.AudioTrack`.
    var id: String { "\(index ?? -1)-\(contentUrl ?? "")" }
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let title: String?
    let contentUrl: String?
    let mimeType: String?
}

struct WatchSyncSessionRequest: Codable {
    let currentTime: Double
    let timeListened: Double
    let duration: Double
}

/// `GET /api/me/sessions`'s response envelope — see `getAuthSessions()`'s doc
/// comment for how this shape was verified without access to the real server.
struct WatchAuthSessionsResponse: Decodable {
    let total: Int
    let sessions: [WatchAuthSession]
}

/// One entry from `GET /api/me/sessions` — an active *login* session (JWT
/// refresh-token record), not a listening/playback session. Field set matches
/// Audiobookshelf's `MeController.getSessions` handler exactly (see
/// `getAuthSessions()`'s doc comment); `deviceInfo` is deliberately not decoded
/// here (unused by this Watch UI, and Codable safely ignores it either way).
struct WatchAuthSession: Decodable, Identifiable {
    let id: String
    let ipAddress: String?
    let userAgent: String?
    /// Epoch milliseconds, matching Audiobookshelf's other `*At` fields elsewhere
    /// in this file/the main app's models.
    let createdAt: Int?
    let updatedAt: Int?
    /// True for the session backing *this specific request* (the server compares
    /// against the caller's own `x-refresh-token`/cookie) — used to label "This
    /// device" in the revocation list rather than let a user accidentally revoke
    /// their own active session without knowing that's what they're doing.
    let current: Bool
}

/// Decodes a JSON array element-by-element, skipping any element that fails to
/// decode instead of failing the whole array. Duplicated from
/// `AudiobookshelfModels.LossyArray` rather than shared, since that file isn't part
/// of this target (see this file's top-level doc comment).
struct WatchLossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let before = container.currentIndex
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(WatchAnyJSON.self)
            }
            if container.currentIndex == before { break }
        }
        elements = result
    }
}

/// Consumes any single JSON value so `WatchLossyArray`'s unkeyed cursor advances past
/// a skipped element.
private struct WatchAnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
        if (try? c.decode(Bool.self)) != nil { return }
        if (try? c.decode(Double.self)) != nil { return }
        if (try? c.decode(String.self)) != nil { return }
        if (try? c.decode([WatchAnyJSON].self)) != nil { return }
        _ = try? c.decode([String: WatchAnyJSON].self)
    }
}

/// Result of one `/auth/refresh` attempt (review Medium 35, 30 October 2026); the Watch
/// equivalent of the iOS `RefreshOutcome`.
nonisolated enum WatchRefreshOutcome: Equatable, Sendable {
    case refreshed
    /// 401/403 from the server, or no refresh token.
    case rejected
    /// Transport error, timeout, 5xx, 429, other non-200, or an undecodable 200.
    case couldNotComplete
}
