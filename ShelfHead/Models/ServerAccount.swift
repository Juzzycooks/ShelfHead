import Foundation
import CryptoKit

/// A saved server account for multi-server switching. The password is stored
/// separately in the Keychain (keyed by `passwordKey`), never in this struct.
struct ServerAccount: Codable, Identifiable, Equatable {
    let id: String
    let serverURL: String
    let username: String
    /// Extra HTTP headers sent with every request to this server — e.g. a reverse-proxy
    /// auth header (Cloudflare Access, Authelia forward-auth, an nginx `auth_request`
    /// gate) sitting in front of a self-hosted Audiobookshelf instance. Optional (rather
    /// than a non-optional empty dictionary) so existing Keychain-stored accounts from
    /// before this field existed still decode without a custom `init(from:)`.
    var customHeaders: [String: String]?
    /// True once the user has explicitly confirmed connecting to this server over plain
    /// HTTP to a non-local host (see `AuthViewModel.requiresInsecureConnectionConfirmation`).
    /// Optional (like `customHeaders`) so accounts saved before this field existed still
    /// decode — treated as "not yet acknowledged," which is the safe default: an old
    /// saved HTTP-remote account gets asked once, not silently grandfathered in.
    var insecureConnectionAcknowledged: Bool?
    /// True when this account signs in through the server's OpenID Connect / SSO support
    /// rather than a username + password (see `AuthViewModel.loginWithOIDC`). Optional
    /// (like the two fields above) so accounts saved before this field existed still
    /// decode without a custom `init(from:)` — a `nil` reads as "not known to be SSO,"
    /// which `AuthViewModel.reauthenticationMethod(for:storedPassword:)` then resolves
    /// from the stored password instead (an SSO account saved before this flag existed
    /// has an empty-string password, never a real one).
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): without this, `switchAccount` read an SSO account's
    /// empty stored password as a real one, tore down the live session, and ran a
    /// password login that could only fail.
    var usesSingleSignOn: Bool?

    init(id: String = UUID().uuidString, serverURL: String, username: String,
         customHeaders: [String: String]? = nil, insecureConnectionAcknowledged: Bool? = nil,
         usesSingleSignOn: Bool? = nil) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.customHeaders = customHeaders
        self.insecureConnectionAcknowledged = insecureConnectionAcknowledged
        self.usesSingleSignOn = usesSingleSignOn
    }

    var passwordKey: String { "account_pwd_\(id)" }

    var displayHost: String {
        URL(string: serverURL)?.host ?? serverURL
    }

    var hasAcknowledgedInsecureConnection: Bool { insecureConnectionAcknowledged ?? false }

    /// Whether this account is explicitly marked as SSO. Deliberately NOT the whole
    /// decision — `AuthViewModel.reauthenticationMethod(for:storedPassword:)` also treats
    /// an empty-but-present stored password as SSO, which is how an OIDC account saved
    /// before `usesSingleSignOn` existed looks on disk.
    var isMarkedSingleSignOn: Bool { usesSingleSignOn ?? false }

    /// True when this account's saved connection is plain HTTP to a non-local host — used
    /// to show a persistent warning next to the account row in Settings, independent of
    /// whether it's been acknowledged (acknowledging the risk once doesn't make the risk
    /// go away; it just means the user chose to accept it).
    var isInsecureRemoteConnection: Bool {
        guard let comps = URLComponents(string: serverURL), comps.scheme?.lowercased() == "http",
              let host = comps.host else { return false }
        return !AuthViewModel.isLocalOrPrivateHost(host)
    }
}

/// Persists the list of saved accounts (in the Keychain) and their passwords.
enum AccountStore {
    private static let currentAccountKey = "shelfhead_currentAccountId"

    static func accounts() async -> [ServerAccount] {
        guard let json = try? await KeychainService.shared.get(.accounts),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([ServerAccount].self, from: data) else {
            return []
        }
        return list
    }

    /// Adds or updates an account (matched by serverURL + username) and stores its
    /// password — unless the user has opted out of password storage
    /// (`SettingsStore.storePassword == false`), in which case any previously saved
    /// password for this account is removed instead. This mirrors the same setting's
    /// effect on the primary `.password` Keychain entry (see `AuthViewModel.login`);
    /// account switching then re-prompts for a password when the setting is off.
    ///
    /// Item 4 (REVIEW-2026-09-09-REMAINING.md): the return type used to be a bare
    /// `ServerAccount`, so both the account-list write and the per-account password write
    /// were dropped on the floor — the caller got an account back that looked saved
    /// whether or not anything reached the Keychain. It now reports both outcomes; the
    /// account itself is `outcome.account`.
    @discardableResult
    static func upsert(serverURL: String, username: String, password: String, customHeaders: [String: String]? = nil,
                        acknowledgedInsecureConnection: Bool? = nil,
                        usesSingleSignOn: Bool? = nil) async -> UpsertOutcome {
        var list = await accounts()
        let existingIndex = list.firstIndex { $0.serverURL == serverURL && $0.username == username }
        // Sign-out fix (6 Oct 2026): a server signed out of and signed back into gets its
        // old account id back, so its download scope (`serverURL|accountId`) and any
        // positions still queued in `PendingProgressQueue` belong to it again. Before, a
        // fresh UUID orphaned both: the downloads never showed and couldn't be freed.
        //
        // Critique 2026-10-06 (harden): looked up under the scheme-insensitive identity, and
        // under the exact-URL hash Batch 382 wrote, so an entry kept by that build still
        // resolves. Never reuses an id a saved account already has (an http and an https
        // entry for the same server can both be saved).
        let retained = retainedAccountIds()
        let identity = identityKey(serverURL: serverURL, username: username)
        let legacyIdentity = legacyIdentityKey(serverURL: serverURL, username: username)
        let retainedIdentity = retained[identity] != nil ? identity : legacyIdentity
        var account = existingIndex.map { list[$0] }
            ?? ServerAccount(id: resolveNewAccountId(identity: retainedIdentity, retained: retained,
                                                     inUseIds: Set(list.map(\.id))),
                             serverURL: serverURL, username: username)
        // Only overwrite previously-saved headers when the caller actually supplied some —
        // re-logging in to an existing account (e.g. a token refresh re-auth) shouldn't
        // silently wipe headers that were configured separately in Settings.
        if let customHeaders { account.customHeaders = customHeaders }
        // Once acknowledged, stays acknowledged — a plain re-login shouldn't un-acknowledge
        // it (`acknowledgedInsecureConnection` is only ever passed `true` or `nil` by
        // callers, never an explicit `false`).
        if acknowledgedInsecureConnection == true { account.insecureConnectionAcknowledged = true }
        // Unlike the acknowledgement above, this one IS applied in both directions: an
        // explicit `false` from the password path (`AuthViewModel.login`) is how an
        // account that used to sign in with SSO but now has a real saved password stops
        // being routed to the SSO sheet on the next switch. `nil` (no caller opinion)
        // still leaves whatever was stored untouched.
        if let usesSingleSignOn { account.usesSingleSignOn = usesSingleSignOn }
        if let existingIndex { list[existingIndex] = account } else { list.append(account) }

        var passwordStored = true
        if SettingsStore.storePassword {
            do {
                try await KeychainService.shared.save(password, account: account.passwordKey)
            } catch {
                passwordStored = false
                ShelfLog.error(.servers, "Couldn't save the password for account \(account.id): \(error.localizedDescription)")
            }
        } else {
            do {
                try await KeychainService.shared.delete(account: account.passwordKey)
            } catch {
                passwordStored = false
                ShelfLog.error(.servers, "Couldn't remove the stored password for account \(account.id): \(error.localizedDescription)")
            }
        }
        let listSaved = await save(list)
        // Back in the saved list, so the retained entry has done its job.
        //
        // Only the scope this sign-in actually uses is forgotten. When the server was signed
        // out of over http and comes back over https (or the other way round), the id comes
        // back but the download scope key still includes the scheme
        // (`DownloadPaths.scopeKey`), so the old-scheme scope stays retained: protected from
        // the orphan sweep, and counted and removable under "Downloads from signed-out
        // servers" (`AuthViewModel.removeDownloadsFromSignedOutServers`).
        if listSaved, retained[identity] != nil || retained[legacyIdentity] != nil {
            forgetRetainedAccountId(identities: [identity, legacyIdentity],
                                    scopeKey: DownloadPaths.scopeKey(serverURL: serverURL, accountId: account.id))
        }
        setCurrent(account.id)
        return UpsertOutcome(account: account, listSaved: listSaved, passwordStored: passwordStored)
    }

    // MARK: Account ids retained across sign-out

    private static let retainedAccountIdsKey = "shelfhead_retainedAccountIds"
    private static let retainedScopeKeysKey = "shelfhead_retainedScopeKeys"

    /// One-way identity for a (server, username) pair: SHA-256 of
    /// `"<identityAddress(serverURL)>|<username>"`. Only this hash is kept after sign-out,
    /// never the server address or the username, which sign-out deletes.
    ///
    /// Critique 2026-10-06 (harden): Batch 382 hashed the exact URL string, so signing out
    /// after an http-fallback sign-in and back in over https (Batch 377's scheme-less LAN
    /// addresses try both) looked like a different server and minted a new id. The identity
    /// is now the scheme-insensitive address (`identityAddress`). The download scope key is
    /// deliberately unchanged (`DownloadPaths.scopeKey`, still the stored URL + id), so no
    /// existing download moves.
    static func identityKey(serverURL: String, username: String) -> String {
        sha256Hex("\(identityAddress(serverURL))|\(username)")
    }

    /// Batch 382's identity: the exact URL string. Only read, so ids retained by that
    /// build still resolve; never written any more.
    static func legacyIdentityKey(serverURL: String, username: String) -> String {
        sha256Hex("\(serverURL)|\(username)")
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A server address with everything that doesn't change *which server* it is taken
    /// out: the scheme, a port that is the default for that scheme (80 for http, 443 for
    /// https), the host's letter case, and a trailing slash on the path. Host, any other
    /// port and the path stay, so two servers on one host (different ports or subpaths)
    /// stay distinct. An address that won't parse is compared as its trimmed, lowercased
    /// text. Pure, pinned by `AccountIdRetentionTests`.
    static func identityAddress(_ serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let rawHost = comps.host, !rawHost.isEmpty else {
            return trimmed.lowercased()
        }
        let host = rawHost.lowercased()
        let scheme = comps.scheme?.lowercased()
        let defaultPort: Int? = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        var address = host
        if let port = comps.port, port != defaultPort {
            address += ":\(port)"
        }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        return address + path
    }

    /// The id a newly added account should get: the one it had before sign-out if this
    /// server and username were saved then, otherwise a fresh UUID. A retained id that a
    /// saved account already uses (`inUseIds`) is never handed out twice. Pure, for tests.
    static func resolveNewAccountId(identity: String, retained: [String: String],
                                    inUseIds: Set<String> = [],
                                    makeId: () -> String = { UUID().uuidString }) -> String {
        if let id = retained[identity], !inUseIds.contains(id) { return id }
        return makeId()
    }

    static func retainedAccountIds() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: retainedAccountIdsKey) as? [String: String] ?? [:]
    }

    /// Called by Sign Out for the one account it signs out of (`removeForSignOut`) and by
    /// Remove All Servers for every saved account, before they leave the saved list. Merges
    /// into whatever an earlier sign-out kept, so signing out twice doesn't forget the
    /// first set.
    static func retainAccountIds(of accounts: [ServerAccount]) {
        var map = retainedAccountIds()
        var scopes = retainedScopeKeys()
        for account in accounts {
            map[identityKey(serverURL: account.serverURL, username: account.username)] = account.id
            scopes.insert(DownloadPaths.scopeKey(serverURL: account.serverURL, accountId: account.id))
        }
        UserDefaults.standard.set(map, forKey: retainedAccountIdsKey)
        UserDefaults.standard.set(Array(scopes), forKey: retainedScopeKeysKey)
    }

    /// Download scopes of signed-out accounts that may still be signed back into. The
    /// orphaned-scope sweep treats these as known, so it can't delete downloads that are
    /// waiting for their account to come back. (A scope key is already the name of the
    /// download directory on disk, so keeping it exposes nothing new.)
    static func retainedScopeKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: retainedScopeKeysKey) ?? [])
    }

    static func forgetRetainedAccountId(identities: [String], scopeKey: String) {
        var map = retainedAccountIds()
        for identity in identities { map.removeValue(forKey: identity) }
        UserDefaults.standard.set(map, forKey: retainedAccountIdsKey)
        var scopes = retainedScopeKeys()
        scopes.remove(scopeKey)
        UserDefaults.standard.set(Array(scopes), forKey: retainedScopeKeysKey)
    }

    /// Critique 2026-10-06 (harden): which retained scopes "Remove downloads from
    /// signed-out servers" may delete — every retained scope except one a saved account
    /// (or the live session) is using again. Pure, pinned by `AccountIdRetentionTests`.
    static func reclaimableRetainedScopes(retained: Set<String>, savedScopes: Set<String>,
                                          currentScope: String) -> Set<String> {
        retained.subtracting(savedScopes).filter { $0 != currentScope && !$0.isEmpty && $0 != "unscoped" }
    }

    /// Forgets the retained ids and scopes for `scopes` (just reclaimed by
    /// `AuthViewModel.removeDownloadsFromSignedOutServers`), so signing in to one of those
    /// servers later starts fresh. Ids still used by a saved account are kept.
    static func forgetRetainedScopes(_ scopes: Set<String>, keepingIds savedIds: Set<String>) {
        var remaining = retainedScopeKeys()
        remaining.subtract(scopes)
        UserDefaults.standard.set(Array(remaining), forKey: retainedScopeKeysKey)
        // The id map is keyed by a one-way hash, so it can't be matched back to a scope.
        // Everything left in it belongs to a signed-out server; keep only ids that a
        // remaining retained scope or a saved account still needs.
        let map = retainedAccountIds().filter { _, id in
            savedIds.contains(id) || remaining.contains { scopeKey($0, belongsToAccountId: id) }
        }
        UserDefaults.standard.set(map, forKey: retainedAccountIdsKey)
    }

    /// Whether a download scope key (`DownloadPaths.scopeKey`, URL-safe base64 of
    /// `"<serverURL>|<accountId>"`) was made for `accountId`. Pure, for tests.
    static func scopeKey(_ key: String, belongsToAccountId accountId: String) -> Bool {
        var base64 = key.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let raw = String(data: data, encoding: .utf8) else {
            return false
        }
        return raw.hasSuffix("|\(accountId)")
    }

    /// What `upsert` actually managed to persist. `listSaved == false` means this account
    /// won't be in the saved-server list after a relaunch even though the sign-in itself
    /// succeeded; `passwordStored == false` means switching back to it will re-prompt for
    /// the password (or, in the opt-out case, that a previously saved password is still
    /// on the device despite the user turning storage off — the security-relevant half).
    struct UpsertOutcome {
        let account: ServerAccount
        let listSaved: Bool
        let passwordStored: Bool
    }

    /// Updates just the custom-headers field for an already-saved account — used by the
    /// Settings screen to add/edit reverse-proxy headers without re-authenticating.
    ///
    /// Item 4: returns whether the change actually reached the Keychain. `false` also
    /// covers "no such saved account", which is equally a case of the caller's edit not
    /// being persisted anywhere.
    @discardableResult
    static func updateCustomHeaders(_ headers: [String: String], for accountId: String) async -> Bool {
        var list = await accounts()
        guard let index = list.firstIndex(where: { $0.id == accountId }) else {
            ShelfLog.error(.servers, "Can't update custom headers: no saved account with that id.")
            return false
        }
        list[index].customHeaders = headers.isEmpty ? nil : headers
        return await save(list)
    }

    /// Persists the user's explicit "yes, connect over insecure HTTP anyway" choice for a
    /// saved account, so switching to it again doesn't re-prompt every time.
    ///
    /// Item 4: returns whether it was actually persisted — a silent failure here means the
    /// user gets asked to confirm the same insecure connection again on every switch.
    @discardableResult
    static func setInsecureConnectionAcknowledged(_ acknowledged: Bool, for accountId: String) async -> Bool {
        var list = await accounts()
        guard let index = list.firstIndex(where: { $0.id == accountId }) else {
            ShelfLog.error(.servers, "Can't record the insecure-connection acknowledgement: no saved account with that id.")
            return false
        }
        list[index].insecureConnectionAcknowledged = acknowledged
        return await save(list)
    }

    /// Deletes every saved account's password (not just the active session's). Used by
    /// Remove All Servers from This Device (Sign Out until Critique 2026-10-06, which made
    /// Sign Out this server only — `removeForSignOut`) and when the user turns off "Stay
    /// signed in" — a stated privacy control
    /// must not leave plaintext passwords behind under a different key.
    ///
    /// Each per-account delete is still best-effort: this loops over every saved account,
    /// and one entry's delete failing (e.g. transient Keychain contention) is not a reason
    /// to abort the rest — the goal is "delete as many as possible," not all-or-nothing,
    /// and the removal proceeds regardless since staying signed in isn't an option once
    /// the user has asked to leave.
    ///
    /// Item 4/5 (REVIEW-2026-09-09-REMAINING.md): what changed is that a partial failure
    /// is no longer *invisible*. It used to be a bare `try?`, so a password surviving Sign
    /// Out left no trace anywhere. Now each failure is logged and the display hosts of the
    /// accounts whose passwords are still on the device are returned, so
    /// `AuthViewModel.removeAllServersFromThisDevice()` can tell the user rather than
    /// reporting a clean removal.
    @discardableResult
    static func deleteAllPasswords() async -> [String] {
        var failed: [String] = []
        for account in await accounts() {
            do {
                try await KeychainService.shared.delete(account: account.passwordKey)
            } catch {
                // Item 5's sibling: still best-effort (the loop keeps going), but no
                // longer invisible — a password left behind after Sign Out is exactly the
                // kind of thing the caller should be able to tell the user about.
                failed.append(account.displayHost)
                // Logged by account id, not host: `ShelfLog.exportDiagnostics` only
                // redacts scheme-prefixed URLs and the *currently configured* server's
                // host, so a bare hostname for some other saved account would survive
                // into an exported report. The host goes only to the returned array,
                // which is for on-device display.
                ShelfLog.error(.servers, "Couldn't delete the stored password for account \(account.id): \(error.localizedDescription)")
            }
        }
        return failed
    }

    @discardableResult
    static func remove(_ account: ServerAccount) async -> Bool {
        var list = await accounts()
        list.removeAll { $0.id == account.id }
        do {
            try await KeychainService.shared.delete(account: account.passwordKey)
        } catch {
            // Not fatal to the removal itself (the list write below is what the caller's
            // `Bool` reports), but it must not vanish: a removed account whose password
            // is still in the Keychain is a leftover secret with nothing left in the UI
            // pointing at it.
            ShelfLog.error(.servers, "Couldn't delete the stored password for removed account \(account.id): \(error.localizedDescription)")
        }
        let saved = await save(list)
        // Removed on purpose (its downloads are deleted too), so a later sign-in to the
        // same server starts fresh rather than reusing this id.
        forgetRetainedAccountId(identities: [identityKey(serverURL: account.serverURL, username: account.username),
                                             legacyIdentityKey(serverURL: account.serverURL, username: account.username)],
                                scopeKey: DownloadPaths.scopeKey(serverURL: account.serverURL, accountId: account.id))
        forgetLastUsed(account.id)
        // Deleting the account entirely (not just switching away from it) — clean up its
        // scoped download-tracking UserDefaults keys too, or they accumulate forever (M7).
        // The account's download *tree* on disk is deleted by
        // `AuthViewModel.tearDownAccountScopedState(reason: .accountRemoval(...))`, which
        // owns every other account-lifecycle cleanup step in one place (Fix 5,
        // REVIEW-2026-09-09.md) — this stays here because it's the one step that also has
        // to run when `remove` is reached from somewhere other than that routine.
        DownloadManager.purgeScopedDefaults(serverURL: account.serverURL, accountId: account.id)
        // Don't leave the UI pointing at a deleted account.
        if currentAccountId == account.id { clearCurrent() }
        return saved
    }

    /// Critique 2026-10-06 (harden): Sign Out now means *this server only*. Takes `account`
    /// off the saved list and deletes its saved password, but — unlike `remove` — keeps
    /// everything a sign-in back to the same server needs to find its downloads again: its
    /// id is retained first (`retainAccountIds`), its scoped download keys are not purged,
    /// and nothing on disk is touched. Clears the current-account id when it was current.
    ///
    /// Returns what didn't make it, for `AuthViewModel.signOut` to report: `listSaved ==
    /// false` means the server would reappear after a relaunch; `passwordRemoved == false`
    /// means its password is still in the Keychain.
    struct SignOutOutcome: Equatable {
        let listSaved: Bool
        let passwordRemoved: Bool
    }

    static func removeForSignOut(_ account: ServerAccount) async -> SignOutOutcome {
        retainAccountIds(of: [account])
        var passwordRemoved = true
        do {
            try await KeychainService.shared.delete(account: account.passwordKey)
        } catch {
            passwordRemoved = false
            ShelfLog.error(.servers, "Couldn't delete the stored password for signed-out account \(account.id): \(error.localizedDescription)")
        }
        var list = await accounts()
        list.removeAll { $0.id == account.id }
        let saved = await save(list)
        forgetLastUsed(account.id)
        if currentAccountId == account.id { clearCurrent() }
        return SignOutOutcome(listSaved: saved, passwordRemoved: passwordRemoved)
    }

    static func password(for account: ServerAccount) async -> String? {
        (try? await KeychainService.shared.get(account: account.passwordKey)) ?? nil
    }

    static var currentAccountId: String? {
        UserDefaults.standard.string(forKey: currentAccountKey)
    }

    static func setCurrent(_ id: String) {
        UserDefaults.standard.set(id, forKey: currentAccountKey)
        markUsed(id)
    }

    // MARK: Last used

    /// Critique 2026-10-06 (harden): when each saved account was last made current, so
    /// signing out of one server can move to the most recently used of the others
    /// (`AuthViewModel.nextAccountAfterSignOut`). Account ids only, in UserDefaults.
    private static let lastUsedKey = "shelfhead_accountLastUsed"

    static func lastUsedDates() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: lastUsedKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func markUsed(_ id: String, at date: Date = Date()) {
        var raw = UserDefaults.standard.dictionary(forKey: lastUsedKey) as? [String: Double] ?? [:]
        raw[id] = date.timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: lastUsedKey)
    }

    private static func forgetLastUsed(_ id: String) {
        var raw = UserDefaults.standard.dictionary(forKey: lastUsedKey) as? [String: Double] ?? [:]
        raw.removeValue(forKey: id)
        UserDefaults.standard.set(raw, forKey: lastUsedKey)
    }

    static func clearCurrent() {
        UserDefaults.standard.removeObject(forKey: currentAccountKey)
    }

    /// Writes the full saved-account list to the Keychain. Returns whether it actually
    /// succeeded — this used to be a silent `try?`-and-forget, but a failure here is
    /// security-relevant in a way most other Keychain writes in this file aren't: every
    /// caller (`upsert`, `remove`, `updateCustomHeaders`, `setInsecureConnectionAcknowledged`)
    /// has already mutated its own in-memory `list` and assumes this call is what makes
    /// that change durable. If the `SecItemAdd` here silently failed, the caller would
    /// believe (e.g.) an account was removed or a password-storage opt-out was applied,
    /// when the previous on-disk list — possibly still containing the stale account or a
    /// since-revoked acknowledgement — is what a relaunch would actually read back. That's
    /// exactly the kind of "app believes X, Keychain still says not-X" gap this whole
    /// finding is about, so it's now surfaced as a return value instead of swallowed.
    ///
    /// Item 4 (REVIEW-2026-09-09-REMAINING.md) adds the log line: the return value only
    /// helps a caller that reads it, and until this pass three of the four callers threw
    /// it away. `KeychainError.errorDescription` carries the raw `OSStatus`, which is the
    /// piece that actually distinguishes "device was locked mid-write"
    /// (`errSecInteractionNotAllowed`, -25308) from a provisioning/entitlement problem
    /// (`errSecMissingEntitlement`, -34018) when a user reports it.
    @discardableResult
    private static func save(_ list: [ServerAccount]) async -> Bool {
        guard let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) else {
            ShelfLog.error(.servers, "Couldn't encode the saved-account list; nothing written to the Keychain.")
            return false
        }
        do {
            try await KeychainService.shared.save(json, for: .accounts)
            return true
        } catch {
            ShelfLog.error(.servers, "Couldn't persist the saved-account list: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Export / import connection settings

/// A single exported connection: server URL + username only — deliberately NOT the
/// password (never leaves the Keychain) or any token. This is onboarding-friction
/// removal for sharing setup with family on a self-hosted server, not a credential
/// export; whoever imports it still has to type their own password once.
struct ExportedConnection: Codable, Identifiable {
    var id: String { serverURL + "|" + username }
    let serverURL: String
    let username: String
}

/// Top-level shape of the exported file, versioned in case the format needs to grow.
struct ConnectionExportFile: Codable {
    let version: Int
    let connections: [ExportedConnection]

    init(connections: [ExportedConnection]) {
        self.version = 1
        self.connections = connections
    }
}

enum ConnectionExport {
    /// Builds the export file's JSON and writes it to a fresh temp file, ready for
    /// `ShareLink`/`UIActivityViewController`. Mirrors `ShareCard.writeData`'s pattern
    /// of a fresh UUID-named temp file plus cleanup of previous exports.
    static func writeExportFile(accounts: [ServerAccount]) -> URL? {
        cleanupTempFiles()
        let file = ConnectionExportFile(connections: accounts.map {
            ExportedConnection(serverURL: $0.serverURL, username: $0.username)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfHead-connections-\(UUID().uuidString).json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Parses a previously exported file. Returns an empty array (not nil) for a
    /// structurally valid-but-empty file; nil only for unparseable content, so the
    /// caller can distinguish "nothing to import" from "not a ShelfHead export".
    static func parseImportFile(at url: URL) -> [ExportedConnection]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ConnectionExportFile.self, from: data) else {
            return nil
        }
        return file.connections
    }

    private static func cleanupTempFiles() {
        let dir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("ShelfHead-connections-") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
