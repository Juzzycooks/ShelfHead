import Foundation

extension Notification.Name {
    /// Batch 427: posted (object = the item id, `String`) after chapters made on this device
    /// are saved or removed for a book, so the live player can re-resolve its chapter list.
    static let shelfheadChapterOverrideChanged = Notification.Name("shelfheadChapterOverrideChanged")
}

/// Batch 427 (Section E): chapters the listener made on this device for a book whose own
/// chapters are missing or useless. Saved per account, never sent to the server.
///
/// Layout: `Application Support/ShelfHead/ChapterOverrides/accounts/<scopeKey>/<sanitizedItemId>.json`.
/// A sibling of `Transcripts/` and `Downloads/`, excluded from backup, and
/// `.completeUntilFirstUserAuthentication`, the same recipe as `TranscriptStore`.
///
/// Views call `resolvedChapters(itemId:server:)` on every render, so reads go through a small
/// in-memory cache (including "no override" answers) guarded by a lock.
nonisolated enum ChapterOverrideStore {
    private static let lock = NSLock()
    /// Key: "<scopeKey>/<itemId>". `.some(nil)` caches "there is no override".
    private nonisolated(unsafe) static var cache: [String: ChapterOverride?] = [:]

    private nonisolated(unsafe) static var changeCount = 0
    /// Bumps on every save/delete/clear; lets memoised per-chapter-list work notice an
    /// in-place swap that count/first id/last end can't.
    nonisolated static var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return changeCount
    }

    // MARK: - Paths

    nonisolated static func currentScopeKey() -> String { TranscriptStore.currentScopeKey() }

    nonisolated static func rootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShelfHead/ChapterOverrides", isDirectory: true)
    }

    nonisolated static func scopeDirectory(scopeKey: String) -> URL {
        rootDirectory().appendingPathComponent("accounts/\(scopeKey)", isDirectory: true)
    }

    private nonisolated static func fileURL(_ itemId: String, _ scopeKey: String) -> URL {
        scopeDirectory(scopeKey: scopeKey)
            .appendingPathComponent(DownloadPaths.sanitizedPathComponent(itemId))
            .appendingPathExtension("json")
    }

    private nonisolated static func cacheKey(_ itemId: String, _ scopeKey: String) -> String {
        "\(scopeKey)/\(itemId)"
    }

    private nonisolated static func prepareDirectory(scopeKey: String) {
        let fm = FileManager.default
        let root = rootDirectory()
        let existed = fm.fileExists(atPath: root.path)
        try? fm.createDirectory(at: scopeDirectory(scopeKey: scopeKey), withIntermediateDirectories: true)
        if !existed {
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        for target in [root, scopeDirectory(scopeKey: scopeKey)] {
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: target.path)
        }
    }

    // MARK: - Read / write

    /// The saved override, or nil when absent, undecodable, or from another version.
    nonisolated static func load(itemId: String, scopeKey: String = currentScopeKey()) -> ChapterOverride? {
        let key = cacheKey(itemId, scopeKey)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        var loaded: ChapterOverride?
        if let data = try? Data(contentsOf: fileURL(itemId, scopeKey)),
           let decoded = try? JSONDecoder().decode(ChapterOverride.self, from: data),
           decoded.version == ChapterOverride.currentVersion {
            loaded = decoded
        }
        lock.lock(); cache[key] = .some(loaded); lock.unlock()
        return loaded
    }

    @discardableResult
    nonisolated static func save(_ override: ChapterOverride, scopeKey: String = currentScopeKey()) -> Bool {
        prepareDirectory(scopeKey: scopeKey)
        do {
            let data = try JSONEncoder().encode(override)
            try data.write(to: fileURL(override.itemId, scopeKey),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            ShelfLog.error(.storage, "Chapter override save failed: \(error.localizedDescription)")
            return false
        }
        lock.lock(); cache[cacheKey(override.itemId, scopeKey)] = .some(override); changeCount += 1; lock.unlock()
        notifyChanged(itemId: override.itemId)
        return true
    }

    nonisolated static func delete(itemId: String, scopeKey: String = currentScopeKey()) {
        try? FileManager.default.removeItem(at: fileURL(itemId, scopeKey))
        lock.lock(); cache[cacheKey(itemId, scopeKey)] = .some(nil); changeCount += 1; lock.unlock()
        notifyChanged(itemId: itemId)
    }

    /// Deletes every override of one scope (account removal).
    nonisolated static func deleteAll(forScopeKey scopeKey: String) {
        guard DownloadManager.isDeletableScopeKey(scopeKey) else { return }
        try? FileManager.default.removeItem(at: scopeDirectory(scopeKey: scopeKey))
        clearCache()
    }

    /// Reclaims override scopes belonging to no saved account; same trust rules as
    /// `TranscriptStore.reclaimOrphanedScopes`. Returns how many scopes were removed.
    @discardableResult
    nonisolated static func reclaimOrphanedScopes(knownScopeKeys: Set<String>) -> Int {
        let current = currentScopeKey()
        guard DownloadManager.canRunOrphanScopeSweep(knownScopeKeys: knownScopeKeys, currentScopeKey: current) else {
            return 0
        }
        let parent = rootDirectory().appendingPathComponent("accounts", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)
        var removed = 0
        for name in names where DownloadManager.shouldReclaimScopeDirectory(
            name, knownScopeKeys: knownScopeKeys, currentScopeKey: current) {
            try? FileManager.default.removeItem(at: scopeDirectory(scopeKey: name))
            removed += 1
        }
        if removed > 0 {
            clearCache()
            ShelfLog.info(.storage, "Reclaimed \(removed) orphaned chapter-override scope(s)")
        }
        return removed
    }

    private nonisolated static func clearCache() {
        lock.lock(); cache.removeAll(); changeCount += 1; lock.unlock()
    }

    private nonisolated static func notifyChanged(itemId: String) {
        let post: @Sendable () -> Void = { NotificationCenter.default.post(name: .shelfheadChapterOverrideChanged, object: itemId) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    // MARK: - Resolution

    /// The chapters to show: the saved ones when they still apply, else the server's.
    nonisolated static func resolvedChapters(itemId: String?, server: [Chapter]) -> [Chapter] {
        guard let itemId else { return server }
        return ChapterOverrideResolver.resolve(server: server, override: load(itemId: itemId))
    }

    nonisolated static func isApplied(itemId: String?, server: [Chapter]) -> Bool {
        guard let itemId else { return false }
        return ChapterOverrideResolver.isApplied(server: server, override: load(itemId: itemId))
    }
}
