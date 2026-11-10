import CryptoKit
import Foundation
import UIKit

/// Opt-in iCloud fallback for the last-known playback position of a book, using
/// `NSUbiquitousKeyValueStore` (not CloudKit — no schema/container, dependency-free,
/// ≤1 MB total). This is strictly a *fallback*: the server stays the source of truth
/// whenever it answers; the cloud record only gets adopted when the server can't be
/// reached and it's actually newer/further along than what's known locally (see
/// `shouldAdoptCloudPosition`). Disabled by default (`SettingsStore.cloudPositionSync`)
/// because the iCloud Key-Value Storage capability has to be added to the app target in
/// Xcode before `NSUbiquitousKeyValueStore` calls do anything — without it, `synchronize()`
/// and reads/writes just silently no-op, so every method here has to tolerate that instead
/// of assuming success.
@MainActor
@Observable
final class CloudPositionStore {
    static let shared = CloudPositionStore()

    struct Record: Equatable, Sendable {
        var currentTime: Double
        var duration: Double
        var updatedAt: Date
        var deviceName: String
    }

    /// Bumped when `NSUbiquitousKeyValueStore.didChangeExternallyNotification` fires.
    /// No UI/merge work happens here — callers that care read `position(forItemId:)`
    /// fresh when they need it.
    private(set) var lastExternalChange: Date?

    private var lastWriteAt: [String: Date] = [:]
    private var changeObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?

    private init() {
        NSUbiquitousKeyValueStore.default.synchronize()
        changeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastExternalChange = Date()
            }
        }
        // Review 2 Low (Sync) (30 October 2026): the scope cache used to stay cold until the
        // first online play resolved it, so a cold launch that starts offline had no scope for
        // `position(forItemId:)`. Warm it now, and again whenever the account changes.
        warmScopeCache()
        accountObserver = NotificationCenter.default.addObserver(
            forName: .shelfheadAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.warmScopeCache() }
        }
    }

    /// Resolves and caches the cross-device scope for the current account, if there is one.
    func warmScopeCache() {
        guard let accountId = AccountStore.currentAccountId else { return }
        Task { @MainActor in _ = await self.resolveCloudScope(for: accountId) }
    }

    var isEnabled: Bool { SettingsStore.cloudPositionSync }

    /// The store key for one book's position. `NSUbiquitousKeyValueStore` raises an
    /// `NSException` (not an error, and nothing Swift can catch) when a key is too long
    /// — Apple's class overview documents the limit as 128 UTF-16 characters, and the
    /// older `set(_:forKey:)` reference gave 64 bytes. The original `"pos.<scope>.<id>"`
    /// format embedded `DownloadPaths.scopeKey` — base64 of `serverURL|accountUUID`,
    /// ~90 characters for an ordinary hostname — plus a 36-character item UUID, which
    /// blew past both figures and crashed the app on the first progress write with
    /// iCloud position sync on (TestFlight crash F396FC99, 17 September 2026, 6.1 build 1,
    /// on the background progress flush). The scope is now folded to 16 hex characters
    /// of its SHA-256, and an item id longer than `maxVerbatimItemIdLength` is folded to
    /// 32 hex the same way, so the key is at most 61 characters whatever the server
    /// address or account looks like. The item id stays readable in the common case so
    /// the store is still legible in a debugger. Records written under the old format
    /// by 6.0/6.1 build 1 are simply not found any more — this is a fallback cache, and
    /// the server remains the source of truth.
    nonisolated static func key(scope: String, itemId: String) -> String {
        let foldedScope = digest(scope, hexLength: 16)
        let id = itemId.utf16.count <= maxVerbatimItemIdLength ? itemId : digest(itemId, hexLength: 32)
        return "pos.\(foldedScope).\(id)"
    }

    /// Upper bound on `key(scope:itemId:)`'s result, in UTF-16 code units. Kept below
    /// the stricter of the two documented store limits (64), with tests pinning it.
    nonisolated static let maxKeyLength = 4 + 16 + 1 + maxVerbatimItemIdLength

    /// Item ids at or below this length go into the key verbatim; longer ones are hashed
    /// to 32 hex. 40 keeps a 36-character UUID (every Audiobookshelf 2.x item id) readable.
    nonisolated static let maxVerbatimItemIdLength = 40

    nonisolated private static func digest(_ string: String, hexLength: Int) -> String {
        let hex = SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(hexLength))
    }

    nonisolated static func encode(_ record: Record) -> [String: Any] {
        [
            "t": record.currentTime,
            "d": record.duration,
            "u": record.updatedAt.timeIntervalSince1970,
            "dev": record.deviceName,
        ]
    }

    nonisolated static func decode(_ any: Any?) -> Record? {
        guard let dict = any as? [String: Any],
              let t = dict["t"] as? Double,
              let d = dict["d"] as? Double,
              let u = dict["u"] as? Double
        else { return nil }
        let dev = dict["dev"] as? String ?? ""
        return Record(currentTime: t, duration: d, updatedAt: Date(timeIntervalSince1970: u), deviceName: dev)
    }

    /// Writes the current position for `itemId`, throttled to at most once per 20s per
    /// item unless `force` is true (pause/stop pass `force: true` so the final position
    /// of a listen isn't lost to the throttle). No-op when disabled.
    func record(itemId: String, currentTime: Double, duration: Double, force: Bool = false) {
        guard isEnabled else { return }
        let now = Date()
        if !force, let last = lastWriteAt[itemId], now.timeIntervalSince(last) < 20 { return }
        lastWriteAt[itemId] = now
        let record = Record(currentTime: currentTime, duration: duration, updatedAt: now, deviceName: UIDevice.current.name)
        // Review Medium 16 (30 October 2026): the scope is now server + username, which needs
        // the Keychain account list (async). With it cached this writes immediately; on the
        // very first call it resolves and then writes.
        // Review 2 Low (Sync) (30 October 2026): the account id is captured here, before the
        // `await`, so a switch while the Keychain read is in flight can't file this record
        // under the new account's scope.
        guard let accountId = AccountStore.currentAccountId else { return }
        if let scope = cachedCloudScope() {
            NSUbiquitousKeyValueStore.default.set(Self.encode(record), forKey: Self.key(scope: scope, itemId: itemId))
        } else {
            Task { @MainActor in
                guard let scope = await self.resolveCloudScope(for: accountId) else { return }
                NSUbiquitousKeyValueStore.default.set(Self.encode(record), forKey: Self.key(scope: scope, itemId: itemId))
            }
        }
    }

    // MARK: Cross-device scope (review Medium 16, 30 October 2026)

    /// The key used to be built from `DownloadManager.currentScopeKey()`, whose account id is
    /// a per-install UUID, so two devices never computed the same key and the iCloud record
    /// could not be found on another device. The scope is now the scheme-insensitive server
    /// address plus the username, both identical on every device signed in the same way.
    /// `key(scope:itemId:)` still hashes it, so the 128-character limit is unaffected.
    /// Records written under the old per-install scope are simply never read again.
    nonisolated static func crossDeviceScope(serverURL: String, username: String) -> String {
        "\(AccountStore.identityAddress(serverURL))|\(username)"
    }

    private static let cloudScopeDefaultsKey = "shelfhead_cloudPositionScope"

    /// The scope for the current account, from a small cache (account id -> scope) so the
    /// synchronous read/write paths don't wait on the Keychain. Kicks off a refresh and
    /// returns nil when the cache doesn't match the current account yet.
    private func cachedCloudScope() -> String? {
        guard let accountId = AccountStore.currentAccountId else { return nil }
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cloudScopeDefaultsKey) as? [String: String],
           let scope = cached[accountId] {
            return scope
        }
        Task { @MainActor in _ = await self.resolveCloudScope(for: accountId) }
        return nil
    }

    private func resolveCloudScope(for accountId: String) async -> String? {
        guard let account = await AccountStore.accounts().first(where: { $0.id == accountId })
        else { return nil }
        let scope = Self.crossDeviceScope(serverURL: account.serverURL, username: account.username)
        var cached = UserDefaults.standard.dictionary(forKey: Self.cloudScopeDefaultsKey) as? [String: String] ?? [:]
        cached[accountId] = scope
        UserDefaults.standard.set(cached, forKey: Self.cloudScopeDefaultsKey)
        return scope
    }

    /// Reads the last-known cloud position for `itemId`, if any. Not gated on
    /// `isEnabled` — a caller mid-decision should still be able to read a record left
    /// over from when the toggle was on.
    func position(forItemId itemId: String) -> Record? {
        guard let scope = cachedCloudScope() else { return nil }
        return Self.decode(NSUbiquitousKeyValueStore.default.dictionary(forKey: Self.key(scope: scope, itemId: itemId)))
    }

    /// Pure decision: should the cloud position replace the locally-resolved start time?
    /// Only when the server can't answer for itself (it stays authoritative when
    /// reachable), the cloud record exists, it's meaningfully ahead of the local
    /// position (`minimumGapSeconds`, avoiding churn from near-identical positions), and
    /// the local position isn't already known to be newer.
    nonisolated static func shouldAdoptCloudPosition(
        cloud: Record?, localCurrentTime: Double, localUpdatedAt: Date?, serverReachable: Bool,
        minimumGapSeconds: Double = 30
    ) -> Bool {
        guard let cloud else { return false }
        if serverReachable { return false }
        // Review Medium 17 (30 October 2026): this used `abs(...)`, so a cloud position
        // *behind* the local one also passed, and a missing local timestamp skipped the
        // recency check. Only a cloud position meaningfully ahead of local is adopted, and
        // when a local timestamp exists the cloud record must also be newer.
        if cloud.currentTime - localCurrentTime < minimumGapSeconds { return false }
        if let localUpdatedAt, localUpdatedAt >= cloud.updatedAt { return false }
        return true
    }
}
