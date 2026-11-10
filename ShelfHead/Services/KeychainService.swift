import Foundation
import Security
import os

/// Keychain access, serialized through an actor so concurrent readers/writers can't
/// interleave a delete-then-add pair (see `save`).
///
/// **Isolation is pinned deliberately (fix 9, REVIEW-2026-09-09.md).** This file compiles
/// into both the app (`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`) and the Watch app
/// (`= MainActor`); `AuthStore`'s header documents the real build break that divergence
/// caused for the other file shared with that target. The `actor` declaration itself is
/// immune — an actor has its own isolation domain and a module-wide default can't move it
/// onto the main actor — which is why there's no annotation on the type below. Its two
/// *supporting enums* are not immune, so both are marked `nonisolated` explicitly rather
/// than inheriting whichever default the compiling target happens to carry: `KeychainKey`
/// is read from inside this actor's own isolation (`key.accessibility` in `save`), and
/// `KeychainError` is thrown across isolation boundaries to callers on the main actor,
/// the Watch's `WatchAudiobookshelfAPI`, and background token-refresh paths. Neither has
/// any state to protect.
actor KeychainService {
    static let shared = KeychainService()

    private let service = "com.shelfhead.app"

    nonisolated enum KeychainKey: String {
        case serverURL = "server_url"
        case authToken = "auth_token"        // access token
        case refreshToken = "refresh_token"
        case username = "username"
        case password = "password"           // used only for silent re-auth on refresh failure
        case userId = "user_id"
        case accounts = "accounts"           // JSON list of saved server accounts (multi-server)
        case customHeaders = "custom_headers" // JSON-encoded [String: String] for the active connection

        /// The Keychain accessibility class used when storing this key's value. This used
        /// to be a single blanket `AfterFirstUnlockThisDeviceOnly` class for everything,
        /// justified by background playback/token-refresh needing to read the access and
        /// refresh tokens while the phone is locked (as long as it's been unlocked once
        /// since boot). That justification holds for the tokens, but not for `.password`:
        /// nothing ever reads the saved login password from a background context — it's
        /// only used for an interactive re-login while the user is present, driving the
        /// app in the foreground, which means the phone is necessarily unlocked at that
        /// moment anyway. Scoping `.password` to `WhenUnlockedThisDeviceOnly` costs nothing
        /// functionally but shrinks the window: on a device that's locked (even if it's
        /// been unlocked since boot and so would still yield up the tokens), the actual
        /// login password can no longer be extracted from the Keychain at all.
        var accessibility: CFString {
            switch self {
            case .password:
                return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            default:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    func save(_ value: String, for key: KeychainKey) throws {
        try write(Data(value.utf8), account: key.rawValue, accessibility: key.accessibility)
    }

    // MARK: - Write primitive

    /// The single write path behind both `save` overloads: **update first, add only when
    /// the item genuinely isn't there**, with delete-then-add kept strictly as a last
    /// resort for an update that failed for some *other* reason.
    ///
    /// Item 4 (REVIEW-2026-09-09-REMAINING.md). This used to be an unconditional
    /// `SecItemDelete` followed by `SecItemAdd`. That sequence has a window in which the
    /// old secret is already gone and the new one hasn't landed, so *any* failure of the
    /// add — `errSecInteractionNotAllowed` because the device locked mid-write, an
    /// `errSecMissingEntitlement` after a provisioning change, plain Keychain contention —
    /// destroyed the previous value instead of leaving it alone. For `.accounts` that's
    /// not one credential but the entire saved-server list, and the callers in
    /// `AccountStore` (`upsert`, `updateCustomHeaders`, `setInsecureConnectionAcknowledged`)
    /// discarded the failure, so the app carried on believing the write had happened.
    ///
    /// `SecItemUpdate` has no such window: it either replaces the value in place or
    /// changes nothing at all. `kSecAttrAccessible` is deliberately part of the *attributes*
    /// dictionary rather than the query — it is not a primary-key attribute for a generic
    /// password (the primary key is service + account, plus access group and
    /// synchronizable), so it can be updated in place, and it *must* be, otherwise an item
    /// written under an older accessibility class would keep it forever. Notably
    /// `.password` moved from `AfterFirstUnlockThisDeviceOnly` to
    /// `WhenUnlockedThisDeviceOnly` in an earlier release; the update path is what
    /// re-applies that tightening to an already-stored password on the next write.
    ///
    /// The query dictionary is identical on iOS and watchOS — service + account under
    /// `kSecClassGenericPassword`, no access group, no `kSecUseDataProtectionKeychain`
    /// (which is macOS-only in effect) — so this file needs no per-platform branch.
    private func write(_ data: Data, account: String, accessibility: CFString) throws {
        // Query: primary-key attributes only. Adding `kSecValueData`/`kSecAttrAccessible`
        // here would narrow the *match* instead of describing the change.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch Self.writeRecovery(forUpdateStatus: updateStatus) {
        case .done:
            return
        case .add:
            // Nothing stored under this account yet — the normal first-write path.
            try add(data, account: account, accessibility: accessibility)
        case .deleteThenAdd:
            // Something other than "not there" went wrong. A stale/duplicate/corrupt item
            // can wedge `SecItemUpdate` in ways only a delete clears, so fall back to the
            // old behaviour — but only here, where an update has already been tried, and
            // never silently: this is the one remaining path that can lose the previous
            // value, so it gets a log line naming the OSStatus that led to it.
            //
            // `ShelfLog` is deliberately not used: this file is compiled into the Watch
            // target too, and `ShelfLog.swift` is not (see `KeychainService`'s header for
            // the other consequences of that dual membership). `os.Logger` is built on
            // both platforms. Constructed inline rather than held as a static so there's
            // no shared mutable/Sendable state to reason about across the two targets'
            // different default isolation.
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.shelfhead.app", category: "keychain")
                .error("SecItemUpdate failed (status \(updateStatus, privacy: .public)); falling back to delete-then-add")
            SecItemDelete(query as CFDictionary)
            try add(data, account: account, accessibility: accessibility)
        }
    }

    /// What `write` does after `SecItemUpdate` returns a given status.
    nonisolated enum WriteRecovery: Equatable {
        /// The value was replaced in place. Nothing else to do.
        case done
        /// No such item — add it. The only path that legitimately reaches `SecItemAdd`
        /// without an existing value being at risk.
        case add
        /// The update failed for some other reason. Last resort, and the only remaining
        /// path where the previous value can be lost, so `write` logs the status first.
        case deleteThenAdd
    }

    /// Pure decision function behind `write` (item 4), extracted so the update → add →
    /// delete-then-add ordering can be pinned by tests without a real Keychain. In
    /// particular `errSecItemNotFound` must map to `.add`, never `.deleteThenAdd`: that
    /// distinction is the whole point of the fix, since the delete-then-add path is the
    /// one that can destroy a previous value.
    nonisolated static func writeRecovery(forUpdateStatus status: OSStatus) -> WriteRecovery {
        switch status {
        case errSecSuccess: return .done
        case errSecItemNotFound: return .add
        default: return .deleteThenAdd
        }
    }

    private func add(_ data: Data, account: String, accessibility: CFString) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func get(_ key: KeychainKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }

    func delete(_ key: KeychainKey) throws {
        let status = rawDelete(account: key.rawValue)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Issues the `SecItemDelete` and hands back the raw status without interpreting it.
    /// `deleteAll()` needs every key's status, not a throw on the first one.
    private func rawDelete(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    // MARK: - Arbitrary-account access (per-server passwords for multi-server)

    // Every caller of this ad-hoc `account:` overload (see `ServerAccount.passwordKey` /
    // `AccountStore`) stores a saved-account *password* — there's no other use of it in
    // the codebase. Unlike `.password` in `KeychainKey`, that's not enforced by the type
    // system here, but the accessibility class should be identical for the same reason:
    // a saved account's password is only ever read back for an interactive "switch
    // account" re-login while the app is frontmost and the phone is unlocked, never from
    // a background context, so `WhenUnlockedThisDeviceOnly` is safe and tighter than the
    // `AfterFirstUnlockThisDeviceOnly` class used for the tokens.
    func save(_ value: String, account: String) throws {
        // Same update-first-then-add path as the `KeychainKey` overload (item 4) — see
        // `write` for why the previous unconditional delete-then-add was a data-loss risk.
        try write(Data(value.utf8), account: account,
                  accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else { return nil }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }

    func delete(account: String) throws {
        let status = rawDelete(account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Bulk delete (sign-out)

    /// The primary (non-per-account) keys `deleteAll()` clears. Deliberately excludes
    /// `.accounts`: the saved-server list is cleared by
    /// `AuthViewModel.removeAllServersFromThisDevice()` in its own explicit step (Sign Out
    /// of one server only drops that server from the list, Batch 384), and the Watch's sign-out (`WatchAudiobookshelfAPI.signOut`)
    /// calls `deleteAll()` for the session keys only.
    nonisolated static let primaryKeys: [KeychainKey] = [
        .serverURL, .authToken, .refreshToken, .username, .password, .userId, .customHeaders
    ]

    /// Clears every primary key, best-effort.
    ///
    /// Item 5 (REVIEW-2026-09-09-REMAINING.md). This was `for key in … { try delete(key) }`,
    /// which aborts on the *first* failing key — a transient `errSecInteractionNotAllowed`
    /// on `.serverURL` (the first in the list) left `authToken`, `refreshToken`, `password`
    /// and `customHeaders` sitting in the Keychain while the `try?` caller in
    /// `AuthViewModel.logout()` (now `removeAllServersFromThisDevice()`) carried on and told the user they were signed out. Now
    /// every key is attempted, `errSecItemNotFound` counts as success (nothing to remove
    /// is the desired end state), and a single aggregate error naming the keys that
    /// actually failed is thrown at the end.
    func deleteAll() throws {
        let results = Self.primaryKeys.map { (key: $0.rawValue, status: rawDelete(account: $0.rawValue)) }
        if let error = Self.deleteOutcome(for: results) { throw error }
    }

    /// Pure decision function behind `deleteAll()` (statuses in → aggregate outcome out),
    /// extracted so the aggregation is unit-testable without a real Keychain — the
    /// simulator test host has no Keychain entitlement, so `SecItem*` itself can't be
    /// exercised there. Returns `nil` when every key reached the desired end state
    /// (deleted, or already absent), otherwise a `.bulkDeleteFailed` naming each key that
    /// genuinely failed together with its `OSStatus`.
    nonisolated static func deleteOutcome(for results: [(key: String, status: OSStatus)]) -> KeychainError? {
        let failures = results
            .filter { $0.status != errSecSuccess && $0.status != errSecItemNotFound }
            .map { KeychainDeleteFailure(key: $0.key, status: $0.status) }
        return failures.isEmpty ? nil : .bulkDeleteFailed(failures)
    }
}

/// One key that `deleteAll()` couldn't clear. `nonisolated` for the same reason as
/// `KeychainError` below — it is part of an error that crosses isolation boundaries, in a
/// file with two different ambient isolation defaults depending on the compiling target.
nonisolated struct KeychainDeleteFailure: Equatable, Sendable {
    let key: String
    let status: OSStatus
}

/// `nonisolated` for the reason spelled out in `KeychainService`'s header: this file has
/// two different ambient defaults depending on which target is compiling it, and an error
/// type that crosses isolation boundaries by definition must not be one of them.
nonisolated enum KeychainError: Error, LocalizedError, Equatable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    /// Item 5: one or more keys survived `deleteAll()`. Aggregate rather than
    /// first-failure so a caller (and its log line) can see exactly what is still stored.
    case bulkDeleteFailed([KeychainDeleteFailure])

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return String(localized: "Failed to save to Keychain (status: \(status))", comment: "%lld is the OSStatus code")
        case .readFailed(let status):
            return String(localized: "Failed to read from Keychain (status: \(status))", comment: "%lld is the OSStatus code")
        case .deleteFailed(let status):
            return String(localized: "Failed to delete from Keychain (status: \(status))", comment: "%lld is the OSStatus code")
        case .bulkDeleteFailed(let failures):
            let detail = failures.map { "\($0.key) (status: \($0.status))" }.joined(separator: ", ")
            return failures.count == 1
                ? String(localized: "Failed to delete 1 Keychain item: \(detail)", comment: "%@ is a list of failed item keys and status codes")
                : String(localized: "Failed to delete \(failures.count) Keychain items: \(detail)", comment: "%lld is the number of items (2 or more), then %@ is a list of failed item keys and status codes")
        }
    }
}
