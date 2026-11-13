import Foundation
import UIKit

extension Notification.Name {
    /// Polish pass (J1-1): posted when the server definitively refused this device's session
    /// mid-use — the single-flight refresh came back `.rejected` (the refresh token was refused
    /// AND the opt-in stored-password re-login, if any, was refused or unavailable) for the
    /// credentials that are still current. Never posted for a network failure or timeout
    /// (`.couldNotComplete`), for a secondary "Other Servers" client, or for a refresh that
    /// outlived a sign-out / account switch. `userInfo["generation"]` is the credential
    /// generation it was raised for; `AuthViewModel` checks it is still current
    /// (`AudiobookshelfAPI.isCurrentCredentialGeneration`) before asking the user to sign in.
    static let shelfheadSessionExpired = Notification.Name("shelfhead.sessionExpired")
}

/// Polish pass (J1-1): a "sign in again" attempt authenticated a different user than the
/// session it was meant to restore. Thrown before anything is written, so the two accounts'
/// data can't mix.
struct DifferentAccountError: Error {}

actor AudiobookshelfAPI {
    static let shared = AudiobookshelfAPI()

    /// This instance's credential store — `.shared` uses the app-wide `AuthStore.shared`;
    /// a secondary client (multi-server "Other Servers" browsing) is given its own private
    /// `AuthStore` so it never reads or overwrites the primary account's session.
    private let store: AuthStore
    /// False for a secondary, non-persisting client: it must never write to the Keychain,
    /// mirror custom headers there, silently re-auth from the primary account's stored
    /// credentials, or seed itself from the primary account's Keychain slots.
    private let persistsCredentials: Bool

    init(store: AuthStore = AuthStore.shared, persistsCredentials: Bool = true) {
        self.store = store
        self.persistsCredentials = persistsCredentials
    }

    /// In-flight refresh, so concurrent 401s trigger only a single refresh
    /// (avoids same-second refresh-token collisions on the server).
    private var refreshTask: Task<RefreshOutcome, Never>?

    /// Review Medium 22 (30 October 2026): bumped whenever the credentials are replaced
    /// (`configure`, `login`, `logout`). A refresh captures it before its network round trip
    /// and writes tokens back only if it still matches, so a refresh that outlives a sign-out
    /// or an account switch can't resurrect the old account's tokens.
    private var credentialGeneration = 0

    /// Short-lived cache of the `/api/me` user object. Bookmark reads (player + CarPlay)
    /// previously refetched the whole user on every call; this coalesces bursts. Cleared
    /// on logout and whenever bookmarks change.
    private var cachedUser: User?
    private var cachedUserAt: Date?
    private let userCacheTTL: TimeInterval = 30
    func invalidateUserCache() { cachedUser = nil; cachedUserAt = nil }

    /// Polish pass Phase 2a #3: the last book positions this device saw from the server
    /// (`/api/me`), kept apart from `cachedUser` because that cache is dropped on every
    /// bookmark change. Used only as the floor for a local start when the server doesn't
    /// answer in time, so a downloaded book never starts behind what the server last said.
    /// In memory only; cleared whenever the credentials change.
    private var lastKnownProgress: [String: MediaProgress] = [:]
    func lastKnownServerProgress(itemId: String) -> MediaProgress? { lastKnownProgress[itemId] }

    // Credentials live in AuthStore (in-memory, seeded from Keychain).
    var serverURL: String { store.serverURL }
    var authToken: String { store.accessToken }
    var isConfigured: Bool { store.isConfigured }

    /// Seed the in-memory store (used on launch when restoring a saved session).
    func configure(serverURL: String, accessToken: String, refreshToken: String?, customHeaders: [String: String] = [:]) {
        // Credentials are (re)seeded — drop any cached user so a switched account
        // never reads the previous one's cached /api/me.
        invalidateUserCache()
        // Review Medium 22: orphan any in-flight refresh for the previous credentials.
        credentialGeneration += 1
        lastKnownProgress = [:]
        refreshTask = nil
        store.set(serverURL: serverURL, accessToken: accessToken, refreshToken: refreshToken, customHeaders: customHeaders)
    }

    /// Seed server URL + tokens straight from the Keychain when not already configured.
    /// Scenes that can launch *without* the main SwiftUI UI — CarPlay and Siri — call
    /// this so they can reach the server before `AuthViewModel.checkExistingSession` runs.
    /// (An expired access token self-heals via the normal 401 → refresh path.) A secondary,
    /// non-persisting client never does this — it must never read the primary account's
    /// Keychain slots.
    func configureFromKeychainIfNeeded() async {
        guard persistsCredentials, !isConfigured else { return }
        guard let serverURL = try? await KeychainService.shared.get(.serverURL),
              let accessToken = try? await KeychainService.shared.get(.authToken) else { return }
        let refresh = try? await KeychainService.shared.get(.refreshToken)
        let headers = await Self.loadCustomHeadersFromKeychain()
        configure(serverURL: serverURL, accessToken: accessToken, refreshToken: refresh ?? nil, customHeaders: headers)
    }

    /// The active connection's custom headers are mirrored into a dedicated Keychain
    /// entry (alongside `.serverURL`/`.authToken`/etc.) so CarPlay/Siri's early,
    /// AccountStore-free boot path (`configureFromKeychainIfNeeded`) can read them
    /// synchronously-ish without needing to decode the full saved-accounts list.
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

    /// Polish pass (J1-3, J1-4): sign-in requests (`/login`, the OIDC initiation and token
    /// exchange, the post-SSO `/api/me` check) give up after 20 s instead of URLSession's
    /// 60 s default, so a dead server fails while the user is still looking at the form.
    nonisolated static let signInTimeout: TimeInterval = 20
    /// Polish pass (J1-3): `/auth/refresh` is single-flighted, so every request that hit a
    /// 401 waits on it; 15 s caps how long one hung refresh can stall all of them.
    nonisolated static let refreshTimeout: TimeInterval = 15

    /// Polish pass (J1-1): `requiringUserId` (the "sign in again" sheet) makes a login that
    /// authenticates anyone else throw `DifferentAccountError` before it touches the store
    /// or the Keychain.
    func login(serverURL: String, username: String, password: String, customHeaders: [String: String] = [:],
               requiringUserId: String? = nil) async throws -> LoginResponse {
        try await login(serverURL: serverURL, username: username, password: password,
                        customHeaders: customHeaders, expectedGeneration: nil, requiringUserId: requiringUserId)
    }

    /// Polish pass (J1-1): whether `generation` (from a `.shelfheadSessionExpired` post) still
    /// names the live credentials — false once a sign-in, sign-out or account switch moved on.
    func isCurrentCredentialGeneration(_ generation: Int) -> Bool { generation == credentialGeneration }

    /// Review 5 Medium 7: with `expectedGeneration`, a login that completes after the credentials
    /// changed (sign-out / account switch) throws before it writes the store or Keychain.
    private func login(serverURL: String, username: String, password: String,
                       customHeaders: [String: String], expectedGeneration: Int?,
                       requiringUserId: String? = nil) async throws -> LoginResponse {
        let url = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let requestURL = URL(string: "\(url)/login") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ask the server (v2.26+) to return the refresh token in the body —
        // mobile clients can't use the HTTP-only cookie the web client relies on.
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        // A reverse proxy in front of the server (Cloudflare Access, Authelia, an nginx
        // auth_request gate) needs its own header on *every* request, including the
        // very first login — otherwise the proxy itself rejects this call before it
        // ever reaches Audiobookshelf.
        request.applyCustomHeaders(customHeaders)

        request.httpBody = try JSONEncoder().encode(LoginRequest(username: username, password: password))
        request.timeoutInterval = Self.signInTimeout   // Polish pass (J1-3)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard let access = loginResponse.user.effectiveAccessToken else {
            throw APIError.unauthorized
        }
        // Polish pass (J1-1): the sign-in-again sheet restores one account only.
        if let requiringUserId, !requiringUserId.isEmpty, loginResponse.user.id != requiringUserId {
            throw DifferentAccountError()
        }

        if let expectedGeneration, expectedGeneration != credentialGeneration { throw AccountChangedError() }   // Review 5 Medium 7
        // Review 6 Medium 2: a same-account silent re-login (expectedGeneration set) keeps the
        // generation, so the caller's in-flight `getCurrentUser` isn't turned into AccountChangedError.
        if expectedGeneration == nil { credentialGeneration += 1 }   // review Medium 22
        lastKnownProgress = [:]
        let generationAfterSet = credentialGeneration
        store.set(serverURL: url, accessToken: access, refreshToken: loginResponse.user.refreshToken, customHeaders: customHeaders)
        // New credentials → drop any cached /api/me so a different account can't read
        // the previous account's cached user/progress/bookmarks.
        invalidateUserCache()
        // Propagate a Keychain failure at login (don't swallow) — otherwise the session
        // would look successful but silently vanish on next launch when the token isn't
        // found in the Keychain.
        try await persistTokens(access: access, refresh: loginResponse.user.refreshToken)
        // A secondary, non-persisting client must never mirror its headers into the
        // primary account's Keychain slot.
        // Review 6 Low (stale re-login): skip the headers write if the account moved meanwhile.
        if persistsCredentials, generationAfterSet == credentialGeneration {
            await Self.persistCustomHeadersToKeychain(customHeaders)
        }
        return loginResponse
    }

    nonisolated static let logoutTimeout: TimeInterval = 10

    func logout() async {
        invalidateUserCache()
        credentialGeneration += 1   // review Medium 22
        lastKnownProgress = [:]
        refreshTask = nil
        let server = store.serverURL
        guard let url = URL(string: "\(server)/logout") else { return }
        var request = store.authorizedRequest(url: url)
        request.httpMethod = "POST"
        // Review Low (Accounts, 30 October 2026): without a timeout an unreachable server
        // held sign-out for URLSession's 60 s default. Best-effort only.
        request.timeoutInterval = Self.logoutTimeout
        if let refresh = store.refreshToken {
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Seeds `AuthStore` *and* persists to the Keychain in one call — used by the OIDC
    /// sign-in path (`AuthViewModel.loginWithOIDC`), which unlike `login()` doesn't go
    /// through Audiobookshelf's own `/login` endpoint, so nothing else does this
    /// persistence for it.
    func configureAndPersist(serverURL: String, accessToken: String, refreshToken: String?, customHeaders: [String: String] = [:]) async throws {
        configure(serverURL: serverURL, accessToken: accessToken, refreshToken: refreshToken, customHeaders: customHeaders)
        try await persistTokens(access: accessToken, refresh: refreshToken)
        await Self.persistCustomHeadersToKeychain(customHeaders)
    }

    /// Polish pass (J1-1): `GET /api/me` with tokens that are NOT installed yet — the SSO
    /// "sign in again" path uses it to confirm the identity provider signed in the same user
    /// before `configureAndPersist` replaces anything. No store, cache or Keychain access, and
    /// no refresh-and-retry: the token is seconds old.
    func fetchUser(serverURL: String, accessToken: String, customHeaders: [String: String]) async throws -> User {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/me"), url.host != nil else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.applyCustomHeaders(customHeaders)
        // After the custom headers, so a proxy header can never replace the bearer token.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.signInTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        do {
            return try JSONDecoder().decode(User.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Review 6 Low (SSO rollback): clears the in-memory credentials and orphans any in-flight
    /// refresh (bumps the generation) without contacting the server. Keychain is the caller's job.
    func clearLocalCredentials() {
        invalidateUserCache()
        credentialGeneration += 1
        lastKnownProgress = [:]
        refreshTask = nil
        store.clear()
    }

    private func persistTokens(access: String, refresh: String?) async throws {
        // A secondary, non-persisting client must never write into the primary
        // account's Keychain slots.
        guard persistsCredentials else { return }
        let generation = credentialGeneration   // Review 3 Low (persistTokens)
        try await KeychainService.shared.save(access, for: .authToken)
        // A sign-out during the first save must not leave the token behind.
        if generation != credentialGeneration, !store.isConfigured {
            try? await KeychainService.shared.delete(.authToken)
            return
        }
        if let refresh {
            try await KeychainService.shared.save(refresh, for: .refreshToken)
        } else {
            // Review Medium 23 (30 October 2026): a sign-in that returns no refresh token
            // (pre-2.26 server) must not leave the previous account's one behind.
            try await KeychainService.shared.delete(.refreshToken)
        }
        if generation != credentialGeneration, !store.isConfigured {
            try? await KeychainService.shared.delete(.authToken)
            try? await KeychainService.shared.delete(.refreshToken)
        }
    }

    // MARK: - Token Refresh

    /// Ensures a single refresh runs at a time; returns true if a usable token is now available.
    /// Callers that must tell "the server said no" from "we never got an answer" use
    /// `refreshOutcome()` instead.
    private func refreshIfPossible() async -> Bool {
        await refreshOutcome() == .refreshed
    }

    /// The single-flight refresh, with the three-way result. Everyone who awaits it while a
    /// refresh is in flight gets the same outcome.
    private func refreshOutcome() async -> RefreshOutcome {
        if let task = refreshTask { return await task.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        let result = await task.value
        if refreshTask == task { refreshTask = nil }   // review Medium 22: don't clobber a newer task
        return result
    }

    /// What a 401-retry path does when the refresh didn't produce a token: `rejected` falls
    /// through to the original 401 (`validateStatus` -> `.unauthorized`, which signs a cold
    /// launch out); `couldNotComplete` throws a transport error instead, so a flaky
    /// refresh is never read as a rejected session.
    private func refreshFailureError(_ outcome: RefreshOutcome) -> Error? {
        outcome == .couldNotComplete ? URLError(.networkConnectionLost) : nil
    }

    /// Review finding High 6 (30 October 2026): any failure of the `/auth/refresh` POST — a
    /// timeout, a dropped connection, a proxy 502/503, an undecodable body — used to look
    /// exactly like "the server rejected the refresh token". It fell through to the stored
    /// password and then surfaced `.unauthorized`, which `AuthViewModel.verifyRestoredSession`
    /// treats as a genuinely dead session and wipes the Keychain for, so one flaky refresh on
    /// a cold launch signed the user out (an SSO user has no password to get back in with).
    /// Only a 401/403 from the refresh endpoint (or no refresh token at all) is a rejection;
    /// everything else couldn't complete and must not touch credentials.
    /// `transportError` is whatever `URLSession` threw, `statusCode` is nil without an
    /// HTTP response, `decodedToken` is whether a 200 body held a usable access token.
    nonisolated static func classifyRefreshResult(statusCode: Int?, transportError: Error?, decodedToken: Bool) -> RefreshOutcome {
        if transportError != nil { return .couldNotComplete }
        guard let statusCode else { return .couldNotComplete }
        if statusCode == 401 || statusCode == 403 { return .rejected }
        if statusCode == 200 && decodedToken { return .refreshed }
        return .couldNotComplete
    }

    /// Refreshes the access token if it expires within `minRemaining` seconds (or always
    /// when `force` is true). Keeps a streamed AVPlayer URL's token valid, since the token
    /// is baked into the asset URL and access tokens expire ~hourly.
    func ensureFreshAccessToken(minRemaining: TimeInterval = 600, force: Bool = false) async {
        if force { _ = await refreshIfPossible(); return }
        guard let exp = Self.jwtExpiry(store.accessToken) else { return }
        if exp.timeIntervalSinceNow < minRemaining { _ = await refreshIfPossible() }
    }

    /// Decodes the `exp` (seconds since epoch) claim from a JWT, if present.
    private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Polish pass (J1-1): whether a finished refresh should tell the app the session has
    /// ended. Only a definitive rejection, only for the primary (persisting) client, only
    /// while it still holds credentials, and only when they are the same credentials the
    /// refresh started with — a refresh that outlived a sign-out, an account switch or a
    /// fresh sign-in says nothing about the session that is live now.
    nonisolated static func shouldSignalSessionExpired(outcome: RefreshOutcome, persistsCredentials: Bool,
                                                       isConfigured: Bool, refreshGeneration: Int,
                                                       currentGeneration: Int) -> Bool {
        outcome == .rejected && persistsCredentials && isConfigured && refreshGeneration == currentGeneration
    }

    private func performRefresh() async -> RefreshOutcome {
        let startGeneration = credentialGeneration   // Polish pass (J1-1)
        let outcome = await performTokenRefreshOrReauth()
        if Self.shouldSignalSessionExpired(outcome: outcome, persistsCredentials: persistsCredentials,
                                           isConfigured: store.isConfigured, refreshGeneration: startGeneration,
                                           currentGeneration: credentialGeneration) {
            // Polish pass (J1-1): nothing is cleared here — the store, Keychain, downloads and
            // the offline progress queue all stay. `AuthViewModel` asks the user to sign in
            // again in place; until then requests keep failing with `.unauthorized`.
            ShelfLog.error(.auth, "Session refused by the server (refresh and silent re-login both rejected); asking to sign in again")
            NotificationCenter.default.post(name: .shelfheadSessionExpired, object: nil,
                                            userInfo: ["generation": startGeneration])
        }
        let success = outcome == .refreshed
        // A secondary, non-persisting client shares no scope with the primary account's
        // downloads, so it must never touch `DownloadManager`'s singleton state.
        if success, persistsCredentials {
            // S5 (REVIEW_2026-08-20_UI_SECURITY.md): "the OIDC/refresh-token flow
            // re-issues a token" — this is that flow. A paused download's resume blob
            // embeds the *previous* Authorization header (see
            // `DownloadManager.persistPausedResume`'s comment), so once the token has
            // rotated, that blob holds a value the app itself no longer considers
            // current. Sweep it rather than leave a stale bearer token on disk.
            // `currentScopeKey()` is unaffected by a token rotation (it's keyed on
            // server URL + account id, not the token), so this targets the right account
            // whether we're on the main actor or not.
            DownloadManager.shared.deleteAllPersistedPausedResumeBlobs(scopeKey: DownloadManager.shared.currentScopeKey())
        }
        return outcome
    }

    private func performTokenRefreshOrReauth() async -> RefreshOutcome {
        // 1) Try the refresh token.
        let generation = credentialGeneration   // review Medium 22
        if let refresh = store.refreshToken, !refresh.isEmpty,
           let url = URL(string: "\(store.serverURL)/auth/refresh") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            request.setValue("true", forHTTPHeaderField: "x-return-tokens")
            request.applyCustomHeaders(store.customHeaders)
            request.timeoutInterval = Self.refreshTimeout   // Polish pass (J1-3)

            var status: Int?
            var transportError: Error?
            var decoded: LoginResponse?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode
                if status == 200 { decoded = try? JSONDecoder().decode(LoginResponse.self, from: data) }
            } catch {
                transportError = error
            }
            let access = decoded?.user.effectiveAccessToken
            switch Self.classifyRefreshResult(statusCode: status, transportError: transportError, decodedToken: access != nil) {
            case .refreshed:
                if let decoded, let access {
                    // Review Medium 22: the credentials changed while the request was in
                    // flight (sign-out / account switch) — drop the result.
                    guard generation == credentialGeneration else { return .couldNotComplete }
                    let newRefresh = decoded.user.refreshToken ?? refresh
                    store.updateTokens(accessToken: access, refreshToken: newRefresh)
                    // Polish pass (J1-7): the server has already rotated the old refresh token
                    // out, so a failed save would leave a dead one in the Keychain and sign the
                    // user out on the next cold launch. Log it and try once more.
                    do {
                        try await persistTokens(access: access, refresh: newRefresh)
                    } catch {
                        ShelfLog.error(.auth, "Couldn't save refreshed tokens to the Keychain; retrying once: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if generation == credentialGeneration {
                            do {
                                try await persistTokens(access: access, refresh: newRefresh)
                            } catch {
                                ShelfLog.error(.auth, "Retry saving refreshed tokens failed; the next cold launch may ask to sign in again: \(error.localizedDescription)")
                            }
                        }
                    }
                    return .refreshed
                }
                return .couldNotComplete
            case .couldNotComplete:
                // Not a rejection: leave the stored credentials alone (see High 6 above).
                return .couldNotComplete
            case .rejected:
                break
            }
        }

        // Review 2 Low (Accounts): a stale refresh that was rejected must not re-authenticate once the credentials
        // changed mid-flight (sign-out / account switch).
        guard generation == credentialGeneration else { return .couldNotComplete }

        // 2) Fall back to stored credentials. ABS native clients commonly hit a
        // "lost rotation" logout where the refresh token is rejected; silently
        // re-authenticating with the saved credentials avoids kicking the user out.
        return await reauthenticateWithStoredCredentials()
    }

    /// Review 6 Medium 1: tri-state result of the stored-credentials re-login. Only "no stored
    /// credentials" or a 401/403 from `/login` is a rejection; a Keychain read error, timeout,
    /// 5xx or dropped connection couldn't complete and must not sign the user out.
    nonisolated static func classifyReauthResult(keychainReadFailed: Bool, hasStoredCredentials: Bool,
                                                 loginSucceeded: Bool, loginError: Error?) -> RefreshOutcome {
        if keychainReadFailed { return .couldNotComplete }
        if !hasStoredCredentials { return .rejected }
        if loginSucceeded { return .refreshed }
        if let api = loginError as? APIError {
            switch api {
            case .unauthorized, .forbidden: return .rejected
            default: return .couldNotComplete
            }
        }
        return .couldNotComplete
    }

    private func reauthenticateWithStoredCredentials() async -> RefreshOutcome {
        // A secondary, non-persisting client must never read the primary account's
        // stored username/password out of the Keychain.
        guard persistsCredentials else { return .rejected }
        // Review 5 Medium 7: capture the account before the Keychain reads, re-check after.
        let generation = credentialGeneration
        let server = store.serverURL
        let headers = store.customHeaders
        let username: String?
        let password: String?
        do {
            username = try await KeychainService.shared.get(.username)
            password = try await KeychainService.shared.get(.password)
        } catch {
            return Self.classifyReauthResult(keychainReadFailed: true, hasStoredCredentials: false, loginSucceeded: false, loginError: error)
        }
        guard let username, let password, !username.isEmpty, !password.isEmpty else {
            return Self.classifyReauthResult(keychainReadFailed: false, hasStoredCredentials: false, loginSucceeded: false, loginError: nil)
        }
        guard generation == credentialGeneration else { return .couldNotComplete }
        do {
            _ = try await login(serverURL: server, username: username, password: password,
                                customHeaders: headers, expectedGeneration: generation, requiringUserId: nil)
            return .refreshed
        } catch {
            return Self.classifyReauthResult(keychainReadFailed: false, hasStoredCredentials: true, loginSucceeded: false, loginError: error)
        }
    }

    // MARK: - Watch credential handoff (item 10, 10 September 2026)

    /// Whether this device can mint a *second*, independent server session for the
    /// active account without asking the user for anything.
    ///
    /// Exactly the same gate `reauthenticateWithStoredCredentials()` above uses, and
    /// deliberately so: `.password` holds a real password only when the user opted in
    /// to storing it (`SettingsStore.storePassword`; `AuthViewModel.login` writes an
    /// empty string otherwise), and OIDC/SSO accounts never write one at all. So a
    /// `true` here means "there is a password on this device that `POST /login` will
    /// accept," which is precisely the precondition for `mintDedicatedSession()`.
    func hasStoredLoginPassword() async -> Bool {
        guard let username = try? await KeychainService.shared.get(.username),
              let password = try? await KeychainService.shared.get(.password) else { return false }
        return !username.isEmpty && !password.isEmpty
    }

    /// The legacy, **non-rotating** API token Audiobookshelf still returns on the user
    /// object for backwards compatibility (`User.token`), or `nil` when this server no
    /// longer sends one.
    ///
    /// Read through `getCurrentUser()` so it shares the 30-second `/api/me` cache
    /// rather than adding a request of its own on a path that has just made two.
    /// Never logged — see `WatchSessionManager.buildCredentialHandoffReply()`'s
    /// no-credential-logging note.
    func currentLegacyAPIToken() async -> String? {
        guard let user = try? await getCurrentUser(), let token = user.token, !token.isEmpty else { return nil }
        return token
    }

    /// Performs a **fresh `POST /login`** for the active account and returns that new
    /// session's tokens *without touching this device's own session at all* — no
    /// `AuthStore` write, no Keychain write, no `/api/me` cache invalidation.
    ///
    /// This exists for one caller: `WatchSessionManager.buildCredentialHandoffReply()`.
    /// Audiobookshelf's refresh tokens rotate and are single-use per session (see
    /// `performTokenRefreshOrReauth()` above and its "lost rotation" note), so handing
    /// the Watch *this* device's refresh token means whichever device refreshes first
    /// silently invalidates the other's. The phone survives that (it falls back to
    /// `reauthenticateWithStoredCredentials()`); the Watch, which deliberately never
    /// receives the password, does not — it just reaches "Your session has expired"
    /// through no fault of the user. Minting a second session gives the Watch its own
    /// rotation chain, so neither device can invalidate the other.
    ///
    /// Deliberately **not** implemented by calling `login(...)`: that method's whole job
    /// is to install the session it just created as this device's session (`AuthStore
    /// .set` + `persistTokens` + `invalidateUserCache`), which is exactly the side
    /// effect this must not have. The request itself is a copy of `login`'s — same
    /// endpoint, same `x-return-tokens` header, same custom headers — because it has to
    /// be: a reverse proxy in front of the server gates `/login` too.
    ///
    /// Returns `nil` on any failure (no stored password, unreachable server, a password
    /// that has since changed, a non-2xx response, a body with no usable token). The
    /// caller treats that as "no dedicated session available" and falls back; nothing
    /// about this device's own session is disturbed either way.
    func mintDedicatedSession() async -> DedicatedSessionTokens? {
        guard let username = try? await KeychainService.shared.get(.username),
              let password = try? await KeychainService.shared.get(.password),
              !username.isEmpty, !password.isEmpty else { return nil }
        let server = store.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let requestURL = URL(string: "\(server)/login") else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.applyCustomHeaders(store.customHeaders)
        guard let body = try? JSONEncoder().encode(LoginRequest(username: username, password: password)) else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let loginResponse = try? JSONDecoder().decode(LoginResponse.self, from: data),
              let access = loginResponse.user.effectiveAccessToken, !access.isEmpty else {
            // No token in this line, by construction — only the fact that the attempt
            // failed. The caller falls back to an access-token-only handoff.
            ShelfLog.error(.watch, "Couldn't mint a dedicated Watch session; falling back to an access-token-only handoff.")
            return nil
        }
        let refresh = (loginResponse.user.refreshToken?.isEmpty == false) ? loginResponse.user.refreshToken : nil
        return DedicatedSessionTokens(accessToken: access, refreshToken: refresh)
    }

    // MARK: - Libraries

    func getLibraries() async throws -> [Library] {
        struct LibrariesResponse: Codable {
            let libraries: [Library]
        }
        let response: LibrariesResponse = try await get("/api/libraries")
        return response.libraries
    }

    func getLibraryItems(libraryId: String, limit: Int = 50, page: Int = 0, filter: String? = nil, sort: String = "media.metadata.title", desc: Bool = false) async throws -> LibraryItemsResponse {
        var params: [(String, String)] = [
            ("limit", "\(limit)"),
            ("page", "\(page)"),
            ("sort", sort),
            ("desc", desc ? "1" : "0")
        ]
        if let filter { params.append(("filter", filter)) }
        return try await get("/api/libraries/\(libraryId)/items\(encodedQuery(params))")
    }

    func getSeries(libraryId: String, limit: Int = 100, page: Int = 0, sort: String = "name", desc: Bool = false, filter: String? = nil) async throws -> SeriesResponse {
        var params: [(String, String)] = [
            ("limit", "\(limit)"),
            ("page", "\(page)"),
            ("sort", sort),
            ("desc", desc ? "1" : "0")
        ]
        // Batch 496 (REVIEW 2026-11-11 L8): the server's series `filter` (e.g. `progress.<base64>`).
        if let filter { params.append(("filter", filter)) }
        return try await get("/api/libraries/\(libraryId)/series\(encodedQuery(params))")
    }

    /// Finds a series by its (display) name, paginating so libraries with more than one
    /// page of series (>100) still resolve — the smart "next in series" / "download
    /// series" features previously only inspected the first page. Returns nil if not
    /// found within `maxPages`.
    func findSeries(libraryId: String, matching name: String, maxPages: Int = 50) async throws -> Series? {
        let pageSize = 100
        var page = 0
        while page < maxPages {
            let response = try await getSeries(libraryId: libraryId, limit: pageSize, page: page)
            if let match = response.results.first(where: { $0.name == name || $0.displayName == name }) {
                return match
            }
            if response.results.count < pageSize { break }   // last page reached
            page += 1
        }
        return nil
    }

    /// Authors / genres / series lists for building filter pickers and browse screens.
    func getFilterData(libraryId: String) async throws -> LibraryFilterData {
        let response: LibraryDataResponse = try await get("/api/libraries/\(libraryId)?include=filterdata")
        return response.filterdata ?? LibraryFilterData(authors: nil, genres: nil, tags: nil, series: nil, narrators: nil, languages: nil)
    }

    /// ID-3 (docs/visual-design-review.md, V5): what an author row needs to draw itself, in one
    /// request: whether the server has a photo for them, and the ids of their books.
    /// `GET /api/authors/{id}?include=items` returns `imagePath` and `libraryItems`.
    struct AuthorArtwork {
        let hasImage: Bool
        let itemIds: [String]
    }

    private struct AuthorArtworkResponse: Decodable {
        struct Item: Decodable { let id: String }
        let imagePath: String?
        let libraryItems: [Item]?
    }

    func getAuthorArtwork(authorId: String) async throws -> AuthorArtwork {
        let response: AuthorArtworkResponse = try await get(
            "/api/authors/\(percentEncodedPathComponent(authorId))", queryItems: [URLQueryItem(name: "include", value: "items")])
        return AuthorArtwork(hasImage: !(response.imagePath ?? "").isEmpty,
                             itemIds: (response.libraryItems ?? []).map(\.id))
    }

    func getListeningStats() async throws -> ListeningStats {
        return try await get("/api/me/listening-stats")
    }

    // Batch 490 (REVIEW 2026-11-11 F11a): `GET /api/libraries/:id/stats` (LibraryController.stats; any user with
    // access to the library). Books and podcasts both answer; the Stats tab only shows book libraries.
    func getLibraryStats(libraryId: String) async throws -> LibraryStats {
        try await get("/api/libraries/\(percentEncodedPathComponent(libraryId))/stats")
    }

    // Batch 490 (REVIEW 2026-11-11 F11a): the e-reader devices this user may send to. The server has no GET for
    // them: `ereaderDevices` rides on the login/`POST /api/authorize` payload (Auth.getUserLoginResponsePayload,
    // filtered by `EmailSettings.getEReaderDevices(user)`), so the signed-in session re-reads it here.
    func getEReaderDevices() async throws -> [EReaderDevice] {
        let data = try await send(path: "/api/authorize", method: "POST")
        return try JSONDecoder().decode(AuthorizeEReaderDevices.self, from: data).ereaderDevices ?? []
    }

    /// `POST /api/emails/send-ebook-to-device` with `{ libraryItemId, deviceName }` (EmailController.sendEBookToDevice).
    /// 200 on success; 404 (device/item/ebook missing), 403, or 400 with the mail error as plain text on failure.
    func sendEbookToDevice(itemId: String, deviceName: String) async throws {
        struct Body: Encodable { let libraryItemId: String; let deviceName: String }
        _ = try await send(path: "/api/emails/send-ebook-to-device", method: "POST",
                           body: try JSONEncoder().encode(Body(libraryItemId: itemId, deviceName: deviceName)))
    }

    /// Recent listening sessions (newest first), for the history screen.
    func getListeningSessions(page: Int = 0, itemsPerPage: Int = 50) async throws -> [ListeningSession] {
        let params = [("page", "\(page)"), ("itemsPerPage", "\(itemsPerPage)")]
        let response: ListeningSessionsResponse = try await get("/api/me/listening-sessions\(encodedQuery(params))")
        return response.sessions
    }

    // MARK: - Auth sessions (Audiobookshelf 2.36+)

    /// Active login sessions for the current user. `current` is only populated `true`
    /// by the server when the request also carries `x-refresh-token`, so it's attached
    /// here whenever one is available.
    func getAuthSessions(page: Int = 0) async throws -> AuthSessionsPage {
        var headers: [String: String] = [:]
        if let refresh = store.refreshToken, !refresh.isEmpty {
            headers["x-refresh-token"] = refresh
        }
        return try await get("/api/me/sessions", queryItems: [URLQueryItem(name: "page", value: "\(page)")], extraHeaders: headers)
    }

    func deleteAuthSession(id: String) async throws {
        _ = try await send(path: "/api/me/sessions/\(pc(id))", method: "DELETE")
    }

    /// Mirrors `logout()` above exactly, just against the "all devices" endpoint —
    /// same deliberate direct-`URLSession` exception (a non-`/api` path), kept beside it.
    func logoutAllDevices() async {
        let server = store.serverURL
        guard let url = URL(string: "\(server)/logout?allDevices=1") else { return }
        var request = store.authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.logoutTimeout   // review Low (Accounts)
        if let refresh = store.refreshToken {
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
        }
        _ = try? await URLSession.shared.data(for: request)
        invalidateUserCache()
    }

    // MARK: - Backups (admin)

    func getBackups() async throws -> BackupsResponse {
        try await get("/api/backups")
    }

    func createBackup() async throws -> [ServerBackup] {
        let data = try await send(path: "/api/backups", method: "POST")
        return try JSONDecoder().decode(BackupsResponse.self, from: data).backups
    }

    func getCollections(libraryId: String) async throws -> [BookCollection] {
        let response: CollectionsResponse = try await get("/api/libraries/\(libraryId)/collections")
        return response.collections
    }

    func getPlaylists(libraryId: String) async throws -> [Playlist] {
        let response: PlaylistsResponse = try await get("/api/libraries/\(libraryId)/playlists")
        return response.playlists
    }

    func getPersonalizedView(libraryId: String) async throws -> [PersonalizedView] {
        // Lossy decode: skip any shelf that doesn't parse instead of failing the
        // whole response (the personalized feed mixes book/series/author shelves).
        let data = try await send(path: "/api/libraries/\(libraryId)/personalized", method: "GET")
        return try JSONDecoder().decode(LossyArray<PersonalizedView>.self, from: data).elements
    }

    // MARK: - Items

    /// Percent-encode a server-provided identifier before interpolating it into a URL path,
    /// so an id containing `/`, `?`, `#`, etc. can't break or redirect the request.
    private func pc(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    func getItem(itemId: String) async throws -> LibraryItem {
        return try await get("/api/items/\(pc(itemId))", queryItems: [
            URLQueryItem(name: "expanded", value: "1"),
            URLQueryItem(name: "include", value: "progress")
        ])
    }

    // MARK: - Playback Session

    func startPlaybackSession(itemId: String) async throws -> PlaybackSession {
        let body = PlaybackSessionRequest()
        return try await post("/api/items/\(pc(itemId))/play", body: body)
    }

    /// Starts a session for one episode of a podcast — a distinct endpoint from the
    /// book path above, since a podcast `LibraryItem` covers the whole show, not a
    /// single continuous listen. The returned session's `audioTracks`/`duration` cover
    /// just this episode, and syncing/closing it (same `syncSession`/`closeSession`
    /// calls as a book) updates this episode's progress specifically — the server
    /// already knows which episode a session belongs to, so nothing else in the sync
    /// path needs to change for podcasts.
    func startPlaybackSession(itemId: String, episodeId: String) async throws -> PlaybackSession {
        let body = PlaybackSessionRequest()
        return try await post("/api/items/\(pc(itemId))/play/\(pc(episodeId))", body: body)
    }

    func syncSession(sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = SyncSessionRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        try await postNoResponse("/api/session/\(pc(sessionId))/sync", body: body)
    }

    func closeSession(sessionId: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = SyncSessionRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        try await postNoResponse("/api/session/\(pc(sessionId))/close", body: body)
    }

    // MARK: - User/Progress

    func getCurrentUser(forceRefresh: Bool = false) async throws -> User {
        if !forceRefresh, let cachedUser, let cachedUserAt,
           Date().timeIntervalSince(cachedUserAt) < userCacheTTL {
            return cachedUser
        }
        let generation = credentialGeneration   // Review 3 Medium 7
        let user: User = try await get("/api/me")
        // Don't cache a user fetched for credentials that were replaced mid-request.
        guard generation == credentialGeneration else { throw AccountChangedError() }
        cachedUser = user
        cachedUserAt = Date()
        for p in user.mediaProgress ?? [] where p.episodeId == nil {
            lastKnownProgress[p.libraryItemId] = p
        }
        return user
    }

    /// Books started but not finished, most-recent first. `limit` defaults to 5 (Siri
    /// "resume" only needs the top one); the Library "Recently Played" sort passes more.
    func getItemsInProgress(limit: Int = 5) async throws -> [LibraryItem] {
        // §Sync (REVIEW-2026-09-09.md): the same one-bad-record-kills-everything shape
        // the `/api/me` user object had. This feeds Siri's "resume listening" and the
        // Library "Recently Played" sort, so one unexpected item shape used to empty
        // both. Lossy: skip the item that doesn't parse, keep the rest.
        struct Response: Decodable {
            let libraryItems: [LibraryItem]

            enum CodingKeys: String, CodingKey { case libraryItems }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let list = try c.decode(LossyArray<LibraryItem>.self, forKey: .libraryItems)
                for skip in list.skipped {
                    ShelfLog.error(.sync, "Dropped items-in-progress[\(skip.index)]: \(skip.reason)")
                }
                libraryItems = list.elements
            }
        }
        let response: Response = try await get("/api/me/items-in-progress?limit=\(max(1, limit))")
        return response.libraryItems
    }

    func updateProgress(libraryItemId: String, progress: Double, currentTime: Double, duration: Double, isFinished: Bool, expectedScope: String? = nil) async throws {
        let body = ProgressUpdate(progress: progress, currentTime: currentTime, isFinished: isFinished, duration: duration)
        // Review 3 Low (progress scope): same account check as bookmarks (same scope derivation).
        try await patchNoResponse("/api/me/progress/\(pc(libraryItemId))", body: body, expectedScope: expectedScope)
        // Progress lives on the user object; drop the cache so the next /api/me read
        // reflects this change (mark finished / reset progress were showing stale for ~30s).
        invalidateUserCache()
    }

    // MARK: - Batch progress (library-browse-shape plan, 6.6)

    /// One entry of `PATCH /api/me/progress/batch/update`. Nil fields are omitted from the JSON.
    struct BatchProgressPayload: Codable, Sendable, Equatable {
        let libraryItemId: String
        let isFinished: Bool
        let currentTime: Double?
        let progress: Double?
        let duration: Double?

        init(libraryItemId: String, isFinished: Bool, currentTime: Double? = nil, progress: Double? = nil, duration: Double? = nil) {
            self.libraryItemId = libraryItemId
            self.isFinished = isFinished
            self.currentTime = currentTime
            self.progress = progress
            self.duration = duration
        }
    }

    /// Server-side batch size cap used by `batchUpdateProgress`.
    nonisolated static let batchProgressChunkSize = 50

    /// JSON array body for the batch endpoint. Synthesized Codable uses `encodeIfPresent`, so nil fields are omitted.
    nonisolated static func batchProgressBody(_ payloads: [BatchProgressPayload]) -> Data {
        (try? JSONEncoder().encode(payloads)) ?? Data("[]".utf8)
    }

    /// Splits payloads into chunks of at most `size`. Empty input yields no chunks.
    nonisolated static func batchChunks(_ payloads: [BatchProgressPayload], size: Int = 50) -> [[BatchProgressPayload]] {
        let step = max(1, size)
        return stride(from: 0, to: payloads.count, by: step).map {
            Array(payloads[$0..<min($0 + step, payloads.count)])
        }
    }

    /// Sends progress for many items in chunks of 50. Never sends an empty batch (ABS 2.36
    /// answers 400). Throws `APIError.notFound` on a 404 (older server without the endpoint)
    /// so the caller can fall back to per-item PATCH. Per-item failures are only logged
    /// server-side; callers should re-read `/api/me` and diff.
    func batchUpdateProgress(_ payloads: [BatchProgressPayload]) async throws {
        let chunks = Self.batchChunks(payloads, size: Self.batchProgressChunkSize)
        guard !chunks.isEmpty else { return }
        defer { invalidateUserCache() }
        for chunk in chunks {
            _ = try await send(path: "/api/me/progress/batch/update", method: "PATCH", body: Self.batchProgressBody(chunk))
        }
    }

    // MARK: - Ebook Progress (P-15, REVIEW_2026-09-14_DESIGN.md)

    /// Sibling to `updateProgress` above, for `Views/EbookReaderView.swift`. Same endpoint
    /// (`PATCH /api/me/progress/{id}`) — Audiobookshelf accepts `ebookLocation` (a string;
    /// this app always sends a PDF page index) and `ebookProgress` (0–1) on that same
    /// route, as a disjoint pair of fields from the audio ones `ProgressUpdate` carries, so
    /// this is a stand-alone request rather than a bolt-on to that type.
    ///
    /// Goes through `patchNoResponse` → `send(...)`, so it gets the same auth headers and
    /// silent refresh-and-retry-once on 401 as every other authenticated call.
    ///
    /// Follow-up (P-15 offline gap): a write that fails here (offline, refresh failure,
    /// etc.) used to be only logged by `EbookReaderView.persistPDFProgressIfNeeded()`,
    /// with no retry — `PendingProgressQueue.Entry` had no room for an ebook
    /// location/progress pair. `Entry` now carries optional `ebookLocation`/`ebookProgress`
    /// (defaulted `nil` on decode, so a queue file from before this change keeps decoding)
    /// plus `isEbook`; the reader `record`s an `Entry.ebook(...)` on failure, and
    /// `AudioPlayerService.flushPendingProgress()`'s drain routes any `isEbook` entry back
    /// to this same method instead of `updateProgress`. Ebook entries skip the audio
    /// conflict-hold path in `drain(...)` entirely (there's no `currentTime` to reconcile
    /// against a server position) — see `PendingProgressQueue.swift` for both changes.
    func updateEbookProgress(itemId: String, location: String, progress: Double, expectedScope: String? = nil) async throws {
        struct EbookProgressUpdate: Codable {
            let ebookLocation: String
            let ebookProgress: Double
        }
        let clamped = min(max(progress, 0), 1)
        let body = EbookProgressUpdate(ebookLocation: location, ebookProgress: clamped)
        try await patchNoResponse("/api/me/progress/\(pc(itemId))", body: body, expectedScope: expectedScope)
        invalidateUserCache()
    }

    /// Batch 495 (REVIEW 2026-11-11 L12): the EPUB reader's write. Sends `ebookProgress` only,
    /// never `ebookLocation`: the web reader keeps an epub.js CFI there, which this reader
    /// can't produce (Batch 430). Audiobookshelf applies only the keys present
    /// (`MediaProgress.applyProgressUpdate` → `this.set(payload)`; a new record gets
    /// `ebookLocation: null` in `User.createUpdateMediaProgressFromPayload`), so the CFI stays.
    func updateEbookReadingProgress(itemId: String, progress: Double, expectedScope: String? = nil) async throws {
        struct EbookReadingProgressUpdate: Codable {
            let ebookProgress: Double
        }
        let clamped = min(max(progress.isFinite ? progress : 0, 0), 1)
        try await patchNoResponse("/api/me/progress/\(pc(itemId))",
                                  body: EbookReadingProgressUpdate(ebookProgress: clamped),
                                  expectedScope: expectedScope)
        invalidateUserCache()
    }

    /// Reads back the ebook-specific fields Audiobookshelf attaches to an item's
    /// `userMediaProgress` — the PDF page (as a string) and 0–1 fraction last written by
    /// `updateEbookProgress(itemId:location:progress:)` from this or another device/the web
    /// UI. Decoded independently of `Models/AudiobookshelfModels.swift`'s `MediaProgress`,
    /// which doesn't carry these two fields (see `updateEbookProgress`'s doc comment for
    /// why extending it is out of this pass's scope); this hits the exact same
    /// `/api/items/{id}?expanded=1&include=progress` route `getItem(itemId:)` already uses,
    /// just decoded into a narrower, local shape.
    func getEbookProgress(itemId: String) async throws -> (location: String?, progress: Double?) {
        struct ItemProgressEnvelope: Decodable {
            let userMediaProgress: Progress?
            struct Progress: Decodable {
                let ebookLocation: String?
                let ebookProgress: Double?
            }
        }
        let envelope: ItemProgressEnvelope = try await get("/api/items/\(pc(itemId))", queryItems: [
            URLQueryItem(name: "expanded", value: "1"),
            URLQueryItem(name: "include", value: "progress")
        ])
        return (envelope.userMediaProgress?.ebookLocation, envelope.userMediaProgress?.ebookProgress)
    }

    // MARK: - Bookmarks

    /// Bookmarks for one item, with any not-yet-synced local operations folded in.
    ///
    /// The merge lives here rather than at each caller because there are seven read sites
    /// (player, book detail ×3, All Bookmarks, CarPlay, the Watch bridge) and a bookmark
    /// that vanished from the list until the network returned would be a worse experience
    /// than the silent loss this replaced. These two methods already do client-side
    /// filtering and sorting, so folding in local state is in keeping with what they are.
    func getBookmarks(itemId: String) async throws -> [AudioBookmark] {
        // Pending work is read BEFORE the network call, and the failure path below still
        // returns it. The first version of this fetched the user first and merged after —
        // which meant that offline, where `getCurrentUser()` throws, the merge was never
        // reached at all and every call site's `try? ... ?? []` produced an empty list.
        // A bookmark made offline only appeared once the connection came back, which is
        // the one moment this whole queue exists to cover.
        let pending = await PendingBookmarkQueue.shared.pending(
            forScope: PendingBookmarkQueue.currentScope(), itemId: itemId)
        do {
            let user = try await getCurrentUser()
            let server = (user.bookmarks ?? []).filter { $0.libraryItemId == itemId }
            return Self.merging(server: server, pending: pending).sorted { $0.time < $1.time }
        } catch {
            // Nothing queued means there is genuinely nothing to show and the error is the
            // only useful answer — rethrow so callers that surface load failures still do.
            guard !pending.isEmpty else { throw error }
            return Self.merging(server: [], pending: pending).sorted { $0.time < $1.time }
        }
    }

    /// Every bookmark across all books on the account, newest first.
    func getAllBookmarks() async throws -> [AudioBookmark] {
        // Same offline-first ordering as `getBookmarks(itemId:)` above, for the same reason.
        let pending = await PendingBookmarkQueue.shared.pending(forScope: PendingBookmarkQueue.currentScope())
        do {
            let user = try await getCurrentUser()
            return Self.merging(server: user.bookmarks ?? [], pending: pending)
                .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        } catch {
            guard !pending.isEmpty else { throw error }
            return Self.merging(server: [], pending: pending)
                .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        }
    }

    /// Applies queued operations on top of the server's list: a queued `.save` replaces (or
    /// adds) that position, a queued `.delete` removes it.
    ///
    /// Matching is on `(libraryItemId, whole seconds)` — the identity `AudioBookmark.id`
    /// and the delete endpoint already use, so a pending entry lines up with the server row
    /// it supersedes instead of appearing twice alongside it.
    ///
    /// A synthesized bookmark carries `createdAt` from the moment it was queued, so it
    /// sorts into All Bookmarks where the user would expect rather than at the very end.
    nonisolated static func merging(
        server: [AudioBookmark], pending: [PendingBookmarkQueue.Entry]
    ) -> [AudioBookmark] {
        guard !pending.isEmpty else { return server }
        func identity(_ itemId: String, _ time: Double) -> String { "\(itemId)-\(time.safeSeconds)" }

        var result = server
        for entry in pending.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let key = identity(entry.itemId, entry.time)
            result.removeAll { identity($0.libraryItemId, $0.time) == key }
            if entry.operation != .delete {
                // `Int(someDouble)` traps on non-finite/out-of-range input (S2/S4,
                // REVIEW_2026-08-20_UI_SECURITY.md). `updatedAt` is written by this app,
                // but it round-trips through a JSON file on disk that could be truncated
                // or corrupted, and this feeds a `ForEach` id — clamped rather than trusted.
                let createdAtMs = entry.updatedAt.isFinite
                    ? Int(max(0, min(entry.updatedAt, 4_102_444_800)) * 1000)   // cap at year 2100
                    : 0
                result.append(AudioBookmark(
                    libraryItemId: entry.itemId, title: entry.title, time: entry.time,
                    createdAt: createdAtMs))
            }
        }
        return result
    }

    /// Review 2 Low (Sync) (30 October 2026): `expectedScope`, when given, is the bookmark
    /// queue scope (`PendingBookmarkQueue.currentScope()`) the caller captured. `send` checks
    /// it inside the actor, immediately before building each request, so an account switch
    /// after the caller's own check can't send the write to the new account.
    func addBookmark(itemId: String, time: Double, title: String, expectedScope: String? = nil) async throws {
        struct Body: Codable { let time: Double; let title: String }
        _ = try await send(path: "/api/me/item/\(pc(itemId))/bookmark", method: "POST",
                           body: try JSONEncoder().encode(Body(time: time, title: title)),
                           expectedScope: expectedScope)
        invalidateUserCache()   // bookmarks live on the user object
    }

    /// Edits an existing bookmark's note (its `title`), keyed by its `time`.
    func updateBookmark(itemId: String, time: Double, title: String, expectedScope: String? = nil) async throws {
        struct Body: Codable { let time: Double; let title: String }
        _ = try await send(path: "/api/me/item/\(pc(itemId))/bookmark", method: "PATCH",
                           body: try JSONEncoder().encode(Body(time: time, title: title)),
                           expectedScope: expectedScope)
        invalidateUserCache()
    }

    func deleteBookmark(itemId: String, time: Double, expectedScope: String? = nil) async throws {
        _ = try await send(path: "/api/me/item/\(pc(itemId))/bookmark/\(Self.bookmarkPathComponent(forTime: time))", method: "DELETE",
                           expectedScope: expectedScope)
        invalidateUserCache()
    }

    /// The `:time` path segment for `DELETE /api/me/item/:id/bookmark/:time`.
    ///
    /// Batch 329: this used to be `time.safeSeconds` (whole seconds), and that silently broke
    /// every delete of a bookmark with a fractional time. Verified against Audiobookshelf
    /// 2.36: the server stores the `time` exactly as `addBookmark` posted it (e.g.
    /// `100.437`) and matches the delete path by numeric equality — `.../bookmark/100`
    /// returns 404, `.../bookmark/100.437` returns 200. Every in-app bookmark is created from
    /// the raw playback position, so almost all of them are fractional, and the 404 was
    /// being classified as "offline" and queued forever (`BookmarkSyncService.perform`).
    /// The Lock Screen star's un-bookmark tap (Batch 328) is what made it visible.
    ///
    /// Keeps S4's guarantee (never traps on `.nan`/`.infinity`/absurd values — those clamp
    /// the same way `safeSeconds` does) but sends the exact value: an integral time as a
    /// plain integer, anything else via `String(Double)`, whose shortest-round-trip digits
    /// are what `JSONEncoder` sent on creation, so `Number()` on the server parses back the
    /// identical double. Pinned by `BookmarkDeletePathTests`.
    nonisolated static func bookmarkPathComponent(forTime time: Double) -> String {
        guard time.isFinite else { return "0" }
        let clamped = Swift.max(0, Swift.min(time, 86_400 * 365))
        if clamped == clamped.rounded(.towardZero) { return String(Int(clamped)) }
        return String(clamped)
    }

    // MARK: - Search

    func search(libraryId: String, query: String) async throws -> [LibraryItem] {
        // Batch 490 (REVIEW 2026-11-11 L1): a thin wrapper over the grouped search so CarPlay,
        // Siri and the view model keep their book-only call shape.
        let groups = try await searchGrouped(libraryId: libraryId, query: query)
        return groups.books + groups.podcasts   // a library has one kind; the other is empty
    }

    /// Batch 490 (REVIEW 2026-11-11 L1): server cap for one search. ABS's
    /// `LibraryController.search` uses `req.query.limit || 12`, so without this the
    /// Library search showed at most 12 books.
    static let searchResultLimit = 50

    /// Batch 490 (REVIEW 2026-11-11 L1): the grouped online search. `GET
    /// /api/libraries/:id/search?q=&limit=` returns, for a book library,
    /// `{book:[{libraryItem}], series:[{series, books}], authors:[author], narrators:[{name,numBooks}], tags, genres}`;
    /// a podcast library returns `{podcast, tags, genres, episodes}` instead, which decodes to empty groups.
    func searchGrouped(libraryId: String, query: String) async throws -> SearchGroups {
        let queryItems = [URLQueryItem(name: "q", value: query),
                          URLQueryItem(name: "limit", value: String(Self.searchResultLimit))]
        let data = try await send(path: "/api/libraries/\(pc(libraryId))/search", method: "GET", queryItems: queryItems)
        return try SearchGroups.decode(data)
    }

    /// Batch 490 (REVIEW 2026-11-11 L1): one search's grouped results. Each group decodes
    /// leniently, so one unexpected author or narrator shape can't empty the book list.
    struct SearchGroups {
        struct Person: Equatable, Hashable {
            let id: String?
            let name: String
            let numBooks: Int?
        }
        /// Batch 492 (REVIEW 2026-11-11 L1): a genre or tag match, `{name, numItems}`.
        struct Facet: Equatable, Hashable {
            let name: String
            let numItems: Int?
        }
        var books: [LibraryItem] = []
        var authors: [Person] = []
        var narrators: [Person] = []
        var genres: [Facet] = []
        var tags: [Facet] = []
        /// Batch 492 (REVIEW 2026-11-11 L2): a podcast library's `podcast` group (shows).
        /// Decoded as `[{libraryItem}]` like `book`; the server source
        /// (`libraryItemsPodcastFilters.search`) builds `itemMatches` of `{libraryItem}`.
        var podcasts: [LibraryItem] = []
        /// Batch 493: a podcast library's `episodes` group. The server
        /// (`libraryItemsPodcastFilters.search`) sends `{libraryItem}` with the matching episode
        /// as `libraryItem.recentEpisode`; an entry without a decodable episode is dropped alone.
        var episodes: [EpisodeMatch] = []

        struct EpisodeMatch: Identifiable {
            let item: LibraryItem
            let episode: PodcastEpisode
            var id: String { "\(item.id)/\(episode.id)" }
        }

        nonisolated static func decode(_ data: Data) throws -> SearchGroups {
            struct BookResult: Decodable { let libraryItem: LibraryItem }
            struct SeriesResult: Decodable { let books: LossyArray<LibraryItem>? }
            struct EpisodeResult: Decodable {
                let match: EpisodeMatch
                enum CodingKeys: String, CodingKey { case libraryItem }
                enum ItemKeys: String, CodingKey { case recentEpisode }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    let item = try c.decode(LibraryItem.self, forKey: .libraryItem)
                    let ic = try c.nestedContainer(keyedBy: ItemKeys.self, forKey: .libraryItem)
                    let episode = try ic.decode(PodcastEpisode.self, forKey: .recentEpisode)
                    match = EpisodeMatch(item: item, episode: episode)
                }
            }
            struct PersonResult: Decodable {
                let id: String?
                let name: String?
                let numBooks: Int?
            }
            struct LabelResult: Decodable {
                let name: String?
                let numItems: Int?
            }
            struct Response: Decodable {
                let podcast: LossyArray<BookResult>?
                let episodes: LossyArray<EpisodeResult>?
                let genres: LossyArray<LabelResult>?
                let tags: LossyArray<LabelResult>?
                let book: LossyArray<BookResult>?
                let series: LossyArray<SeriesResult>?
                let authors: LossyArray<PersonResult>?
                let narrators: LossyArray<PersonResult>?

                enum CodingKeys: String, CodingKey { case podcast, episodes, genres, tags, book, series, authors, narrators }
                // Batch 492: each group decodes on its own, so one group of an unexpected
                // shape (not an array) loses only itself.
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    podcast = try? c.decodeIfPresent(LossyArray<BookResult>.self, forKey: .podcast)
                    episodes = try? c.decodeIfPresent(LossyArray<EpisodeResult>.self, forKey: .episodes)
                    genres = try? c.decodeIfPresent(LossyArray<LabelResult>.self, forKey: .genres)
                    tags = try? c.decodeIfPresent(LossyArray<LabelResult>.self, forKey: .tags)
                    book = try? c.decodeIfPresent(LossyArray<BookResult>.self, forKey: .book)
                    series = try? c.decodeIfPresent(LossyArray<SeriesResult>.self, forKey: .series)
                    authors = try? c.decodeIfPresent(LossyArray<PersonResult>.self, forKey: .authors)
                    narrators = try? c.decodeIfPresent(LossyArray<PersonResult>.self, forKey: .narrators)
                }
            }
            let response = try JSONDecoder().decode(Response.self, from: data)

            // Direct book matches first, then books surfaced via matching series (so a
            // series name search returns its books). De-duplicated by id.
            var books = response.book?.elements.map(\.libraryItem) ?? []
            var seen = Set(books.map(\.id))
            for book in (response.series?.elements ?? []).flatMap({ $0.books?.elements ?? [] }) where !seen.contains(book.id) {
                books.append(book)
                seen.insert(book.id)
            }
            func people(_ list: [PersonResult]?, needsId: Bool) -> [Person] {
                var seenNames = Set<String>()
                return (list ?? []).compactMap { p in
                    let name = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !(needsId && (p.id ?? "").isEmpty) else { return nil }
                    guard seenNames.insert(name.lowercased()).inserted else { return nil }
                    return Person(id: p.id, name: name, numBooks: p.numBooks)
                }
            }
            func labels(_ list: [LabelResult]?) -> [Facet] {
                var seenNames = Set<String>()
                return (list ?? []).compactMap { l in
                    let name = (l.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, seenNames.insert(name.lowercased()).inserted else { return nil }
                    return Facet(name: name, numItems: l.numItems)
                }
            }
            return SearchGroups(books: books,
                                authors: people(response.authors?.elements, needsId: true),
                                narrators: people(response.narrators?.elements, needsId: false),
                                genres: labels(response.genres?.elements),
                                tags: labels(response.tags?.elements),
                                podcasts: response.podcast?.elements.map(\.libraryItem) ?? [],
                                episodes: response.episodes?.elements.map(\.match) ?? [])
        }
    }

    // MARK: - Continue Listening (Batch 490, REVIEW 2026-11-11 F1)

    /// Batch 490 (REVIEW 2026-11-11 F1): hides one book from the server's Continue Listening shelf.
    /// ABS routes the hide by the *media-progress* id, not the item id:
    /// `GET /api/me/progress/:id/remove-from-continue-listening` (`MeController.removeItemFromContinueListening`,
    /// 404 when no progress has that id). The progress id comes from `GET /api/me/progress/:libraryItemId`
    /// (`MeController.getMediaProgress`), because a decoded `MediaProgress.id` may be synthesised.
    func removeItemFromContinueListening(libraryItemId: String) async throws {
        struct ProgressID: Decodable { let id: String }
        let progress: ProgressID = try await get("/api/me/progress/\(pc(libraryItemId))")
        _ = try await send(path: "/api/me/progress/\(pc(progress.id))/remove-from-continue-listening", method: "GET")
        invalidateUserCache()
    }

    /// Batch 490 (REVIEW 2026-11-11 F1): the Undo for the hide above. `PATCH /api/me/progress/:libraryItemId`
    /// with `{"hideFromContinueListening": false}` — `MediaProgress.applyProgressUpdate` sets the
    /// payload's fields, and the flag is part of the documented `ProgressUpdatePayload`.
    func readdItemToContinueListening(libraryItemId: String) async throws {
        struct Body: Codable { let hideFromContinueListening: Bool }
        try await patchNoResponse("/api/me/progress/\(pc(libraryItemId))", body: Body(hideFromContinueListening: false))
        invalidateUserCache()
    }

    /// Batch 490 (REVIEW 2026-11-11 F1): `GET /api/me/series/:id/remove-from-continue-listening`
    /// (`MeController.removeSeriesFromContinueListening`) hides a series from the Continue Series shelf.
    func removeSeriesFromContinueListening(seriesId: String) async throws {
        _ = try await send(path: "/api/me/series/\(pc(seriesId))/remove-from-continue-listening", method: "GET")
        invalidateUserCache()
    }

    /// Batch 490 (REVIEW 2026-11-11 F1): `GET /api/me/series/:id/readd-to-continue-listening`
    /// (`MeController.readdSeriesFromContinueListening`), the Undo for the series hide.
    func readdSeriesToContinueListening(seriesId: String) async throws {
        _ = try await send(path: "/api/me/series/\(pc(seriesId))/readd-to-continue-listening", method: "GET")
        invalidateUserCache()
    }

    // MARK: - Networking Helpers

    // Phase 2 (Batches 436+): internal, not private, so feature endpoints in
    // `AudiobookshelfAPI+<Feature>.swift` extensions go through the same auth and 401 retry.

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = [], extraHeaders: [String: String] = [:]) async throws -> T {
        let data = try await send(path: path, method: "GET", queryItems: queryItems, extraHeaders: extraHeaders)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let data = try await send(path: path, method: "POST", body: try JSONEncoder().encode(body))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postNoResponse<B: Codable>(_ path: String, body: B) async throws {
        _ = try await send(path: path, method: "POST", body: try JSONEncoder().encode(body))
    }

    func patchNoResponse<B: Codable>(_ path: String, body: B, expectedScope: String? = nil) async throws {
        _ = try await send(path: path, method: "PATCH", body: try JSONEncoder().encode(body), expectedScope: expectedScope)
    }

    /// Central request executor with one automatic refresh-and-retry on 401.
    func send(path: String, method: String, queryItems: [URLQueryItem] = [], body: Data? = nil, extraHeaders: [String: String] = [:], allowRetry: Bool = true, expectedScope: String? = nil) async throws -> Data {
        // Review 2 Low (Sync): no `await` between this check and `buildRequest`, so the
        // request is built for the account the caller expected (or not at all).
        if let expectedScope, expectedScope != PendingBookmarkQueue.currentScope() {
            throw AccountChangedError()
        }
        let request = try buildRequest(path: path, method: method, queryItems: queryItems, body: body, extraHeaders: extraHeaders)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 401 && allowRetry {
            let outcome = await refreshOutcome()
            if outcome == .refreshed {
                // Rebuild with the fresh token and retry once.
                return try await send(path: path, method: method, queryItems: queryItems, body: body, extraHeaders: extraHeaders, allowRetry: false, expectedScope: expectedScope)
            }
            if let error = refreshFailureError(outcome) { throw error }
        }

        try validateStatus(http.statusCode)
        return data
    }

    /// The same refresh-and-retry contract as `send(path:...)`, for an *absolute* URL the
    /// caller already has — cover images (`shelfCoverURL`) are the case. Goes through
    /// `AuthStore.authorizedRequest(url:)` so per-account custom headers apply, and on a
    /// 401 refreshes once and retries once, exactly like `send`.
    ///
    /// C10 (REVIEW_2026-09-04_UI.md Pass 4) / CLAUDE.md: `CarPlayImageLoader` and the full
    /// player's palette fetch each called `URLSession.shared.data(for:)` directly — the
    /// known "bypasses the API type" bug class that put Watch covers out for a whole
    /// release. This is the one entry point they route through now; anything else that
    /// needs authenticated bytes from an absolute URL should use it rather than copying
    /// the retry shape.
    func authorizedData(for url: URL, allowRetry: Bool = true) async throws -> Data {
        // `file://` (downloaded covers) can't 401 and needs no headers.
        guard url.scheme == "http" || url.scheme == "https" else {
            return try Data(contentsOf: url)
        }
        let request = store.authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 && allowRetry {
            let outcome = await refreshOutcome()
            if outcome == .refreshed {
                return try await authorizedData(for: url, allowRetry: false)
            }
            if let error = refreshFailureError(outcome) { throw error }
        }
        try validateStatus(http.statusCode)
        return data
    }

    /// Batch 444: `POST /api/upload` (multipart). The body is built on disk by `MultipartBody` and
    /// streamed with `URLSession.upload(for:fromFile:delegate:)`, so a large audiobook never sits in
    /// memory. Same auth as `send`: the request comes from `AuthStore.authorizedRequest(url:)` (bearer
    /// token plus the account's custom headers), the token is refreshed first when it is about to
    /// lapse (a long upload that fails with a 401 only at the end is the worst case), and a 401 still
    /// refreshes once and re-sends from the same body file. `progress` gets (bytesSent, bytesTotal).
    /// The server answers a plain-text 200 "OK"; 400 (bad form), 403 (no upload permission or no
    /// access to the library), 404 (library or folder gone) and 500 (could not create the folder)
    /// surface as `APIError`.
    func uploadMultipart(body: MultipartBody, bodyFile: URL, expectedScope: String? = nil, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        // Review 4 Medium 4: the account the upload was started for must still be the active one
        // before every request build, or a retry would send the new account's token to the old URL.
        func checkScope() throws {
            if let expectedScope, expectedScope != PendingBookmarkQueue.currentScope() { throw AccountChangedError() }
        }
        try checkScope()
        guard !store.serverURL.isEmpty, let url = URL(string: "\(store.serverURL)/api/upload"), url.host != nil else {
            throw APIError.invalidURL
        }
        await ensureFreshAccessToken(minRemaining: 300)
        try checkScope()
        var allowRetry = true
        while true {
            try checkScope()
            var request = store.authorizedRequest(url: url)
            request.httpMethod = "POST"
            // URLSession's timeout is an idle timeout between bytes, not for the whole transfer.
            request.timeoutInterval = 120
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFile,
                                                                   delegate: UploadProgressDelegate(progress))
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            if http.statusCode == 401, allowRetry {
                let outcome = await refreshOutcome()
                try checkScope()
                if outcome == .refreshed {
                    allowRetry = false
                    continue
                }
                if let error = refreshFailureError(outcome) { throw error }
            }
            try validateStatus(http.statusCode)
            return
        }
    }

    /// Batch 406: the WebSocket upgrade request for `ServerEventSocket`, plus the access
    /// token it must send in socket.io's `auth` event. Built through
    /// `AuthStore.authorizedRequest(url:)` like every other authenticated request, so the
    /// per-account custom headers (Cloudflare Access, Authelia, an nginx `auth_request`
    /// gate) reach the upgrade and the app's bearer token always wins over them. The token
    /// is refreshed first when it's within two minutes of expiry: ABS validates it once,
    /// at `auth`, so a reconnect must never present one that is about to lapse. Nil when
    /// no account is configured or the server URL can't be turned into a ws(s) URL.
    func serverEventSocketRequest() async -> (request: URLRequest, accessToken: String)? {
        guard isConfigured else { return nil }
        await ensureFreshAccessToken(minRemaining: 120)
        guard isConfigured, !store.accessToken.isEmpty,
              let url = SocketIOEndpoint.url(serverURL: store.serverURL) else { return nil }
        var request = store.authorizedRequest(url: url)
        request.timeoutInterval = 30
        return (request, store.accessToken)
    }

    /// Builds a query string with strict percent-encoding so Base64 filter values
    /// (which contain `+`, `/`, `=`) survive transport intact.
    private func encodedQuery(_ params: [(String, String)]) -> String {
        guard !params.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics
        let parts = params.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }
        return "?" + parts.joined(separator: "&")
    }

    private func buildRequest(path: String, method: String, queryItems: [URLQueryItem] = [], body: Data? = nil, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        // Real device log: `Task <...> finished with error [-1002] ... "unsupported URL"
        // ... NSErrorFailingURLStringKey=/api/me` — this guard didn't actually catch that
        // case. When `AuthStore.shared.serverURL` is empty (not configured yet — a cold
        // launch racing ahead of keychain/session restore, or a call before sign-in),
        // `URLComponents(string: "/api/me")` parses just fine: a bare path with no
        // scheme/host is a perfectly valid *relative* URL reference per RFC 3986, so this
        // `guard` never fired and `components.url` below also succeeded — the malformed
        // request only failed later, deep in `URLSession`, as the cryptic -1002 above,
        // rather than here with a clear, already-handled `APIError.invalidURL`. Checking
        // for a `host` (which only a real `scheme://host` URL has) catches the empty/
        // not-yet-configured case explicitly, right where it's easy to diagnose.
        guard !store.serverURL.isEmpty,
              var components = URLComponents(string: "\(store.serverURL)\(path)") else {
            throw APIError.invalidURL
        }

        if !queryItems.isEmpty {
            // `URLComponents.queryItems` percent-encodes with `.urlQueryAllowed`, which
            // (per RFC 3986) leaves `+` as a literal, unencoded character in the query —
            // but most servers parse query strings with form-encoding conventions, where
            // a literal `+` means a space. A search for "rock + roll" would silently
            // become "rock   roll" server-side. Encode manually with `+`/`&`/`=` also
            // escaped, so values containing them can't corrupt the query string or get
            // reinterpreted.
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let parts = queryItems.map { item -> String in
                let key = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
                let rawValue = item.value ?? ""
                let value = rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
                return "\(key)=\(value)"
            }
            components.percentEncodedQuery = parts.joined(separator: "&")
        }

        // Belt-and-suspenders alongside the `serverURL.isEmpty` check above: a `host`
        // only exists on a real `scheme://host/...` URL, so this also catches any other
        // way `serverURL` could end up set to something scheme/host-less without needing
        // to enumerate those cases individually.
        guard let url = components.url, url.host != nil else {
            throw APIError.invalidURL
        }

        var request = store.authorizedRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        try validateStatus(httpResponse.statusCode)
    }

    private func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 500...599:
            throw APIError.serverError(statusCode)
        default:
            throw APIError.httpError(statusCode)
        }
    }
}

// MARK: - Dedicated session (Watch credential handoff)

/// The tokens of a server session minted for *another* device — see
/// `AudiobookshelfAPI.mintDedicatedSession()`. Never written to this device's
/// `AuthStore` or Keychain: it exists only long enough to be put on the wire to the
/// Watch, which then owns it outright.
///
/// `refreshToken` is `nil` when the server didn't return one (pre-2.26, or a
/// refresh-token policy that omits it) — in that case the "session" is really just
/// this server's permanent user token, which doesn't rotate, so it is safe to share
/// even though it isn't exclusive. `WatchSessionManager` distinguishes the two on the
/// wire (`sessionKind`) so the Watch can tell the user the right thing.
struct DedicatedSessionTokens: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
}

// MARK: - API Errors

/// Result of one `/auth/refresh` attempt; see `AudiobookshelfAPI.classifyRefreshResult`.
enum RefreshOutcome: Equatable, Sendable {
    case refreshed
    /// The server answered 401/403, or there was no refresh token, and the stored-credentials fallback failed too.
    case rejected
    /// Transport error, timeout, 5xx, 429, other non-200, or an undecodable 200.
    case couldNotComplete
}

/// Review 2 Low (Sync) (30 October 2026): thrown by `send` when the caller's `expectedScope`
/// no longer matches the active account. Nothing was sent.
struct AccountChangedError: Error {}

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case serverError(Int)
    case httpError(Int)
    case decodingError(Error)

    /// Polish pass (ST-5): one plain sentence each — what happened, then what to do. No
    /// status codes or nested error text (they're in the cases for logic and logging); and
    /// `.unauthorized` no longer says "check your credentials", which was wrong mid-session.
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "That server address isn\u{2019}t valid. Check it in Settings.", comment: "API error: malformed server address")
        case .invalidResponse:
            return String(localized: "Your server sent a reply ShelfHead couldn\u{2019}t read. Try again.", comment: "API error: response that isn't HTTP")
        case .unauthorized:
            return String(localized: "Your session has ended. Sign in again to keep syncing.", comment: "API error: 401 after refresh and re-login failed")
        case .forbidden:
            return String(localized: "Your account doesn\u{2019}t have access to this. Ask your server\u{2019}s admin.", comment: "API error: 403")
        case .notFound:
            return String(localized: "That isn\u{2019}t on your server any more. It may have been moved or removed.", comment: "API error: 404")
        case .serverError:
            return String(localized: "Your server ran into a problem. Try again in a moment.", comment: "API error: 5xx")
        case .httpError:
            return String(localized: "Your server couldn\u{2019}t complete that. Try again.", comment: "API error: other non-2xx status")
        case .decodingError:
            return String(localized: "Your server sent a reply ShelfHead couldn\u{2019}t read. Check that Audiobookshelf is up to date.", comment: "API error: undecodable response")
        }
    }
}


/// Batch 444: per-task delegate reporting `didSendBodyData` for `AudiobookshelfAPI.uploadMultipart`
/// (the async `upload(for:fromFile:delegate:)` calls it as the body is written to the socket).
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Int64, Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64, Int64) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }
}
