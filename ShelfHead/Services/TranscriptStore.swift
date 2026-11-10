import Foundation

/// File storage for on-device transcripts (Phase 1, Section A).
///
/// Layout: `Application Support/ShelfHead/Transcripts/accounts/<scopeKey>/<sanitizedItemId>/`
/// holding `transcript.json` (the `Transcript`) and `meta.json` (`TranscriptMeta`: language
/// override, listening high-water mark, and a few cheap status fields so the UI never has
/// to decode a whole transcript just to show "Transcribed" or "62 %").
///
/// Deliberately a sibling of `Downloads/`, not inside it: deleting a download keeps the
/// transcript, and captions/search keep working while streaming (transcripts use book
/// time). The root is excluded from backup and uses
/// `.completeUntilFirstUserAuthentication`, exactly like `DownloadManager`'s tree.
///
/// Everything here is `nonisolated` and uses `FileManager` plus one lock around the
/// read-modify-write of `meta.json`, so the transcription actor, the main actor and the
/// background-task handlers can all call it. Decode failures and an older
/// `Transcript.version` read as "absent".
nonisolated struct TranscriptMeta: Codable, Equatable, Sendable {
    /// BCP-47 identifier the user forced for this book; nil = follow the default/book.
    var languageOverride: String?
    /// ABS `metadata.language` noted when the book was last seen, for background runs
    /// where no `LibraryItem` is at hand (the download manifest doesn't carry language).
    var bookLanguage: String?
    /// Furthest book time (seconds) the listener has heard; spoiler frontier input.
    var highWater: Double?
    /// Mirrors `Transcript.isComplete` at the last save.
    var isComplete: Bool = false
    /// 0...1 share of the book's audio transcribed at the last save.
    var fraction: Double = 0
    /// When the last run failed, so the overnight pass doesn't hammer a broken book.
    var lastFailure: Date?
    var lastFailureMessage: String?
}

nonisolated enum TranscriptStore {
    private static let metaLock = NSLock()

    // MARK: - Paths

    /// Same scope key `DownloadManager.currentScopeKey()` produces. Duplicated (four lines)
    /// rather than called because `DownloadManager.shared` is main-actor isolated and this
    /// type must stay callable from the transcription actor.
    nonisolated static func currentScopeKey() -> String {
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty else { return "unscoped" }
        return DownloadPaths.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
    }

    nonisolated static func rootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShelfHead/Transcripts", isDirectory: true)
    }

    nonisolated static func scopeDirectory(scopeKey: String) -> URL {
        rootDirectory().appendingPathComponent("accounts/\(scopeKey)", isDirectory: true)
    }

    nonisolated static func itemDirectory(itemId: String, scopeKey: String) -> URL {
        scopeDirectory(scopeKey: scopeKey)
            .appendingPathComponent(DownloadPaths.sanitizedPathComponent(itemId), isDirectory: true)
    }

    private nonisolated static func transcriptURL(_ itemId: String, _ scopeKey: String) -> URL {
        itemDirectory(itemId: itemId, scopeKey: scopeKey).appendingPathComponent("transcript.json")
    }

    private nonisolated static func metaURL(_ itemId: String, _ scopeKey: String) -> URL {
        itemDirectory(itemId: itemId, scopeKey: scopeKey).appendingPathComponent("meta.json")
    }

    /// Creates the item directory, applying backup exclusion to the root and file
    /// protection to the root and scope directory (both recursive/inherited by new files).
    private nonisolated static func prepareDirectory(itemId: String, scopeKey: String) {
        let fm = FileManager.default
        let root = rootDirectory()
        let dir = itemDirectory(itemId: itemId, scopeKey: scopeKey)
        let existed = fm.fileExists(atPath: root.path)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !existed {
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        for target in [root, scopeDirectory(scopeKey: scopeKey), dir] {
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: target.path)
        }
    }

    // MARK: - Transcript

    /// The stored transcript, or nil when absent, undecodable, or from an older version.
    nonisolated static func load(itemId: String, scopeKey: String = currentScopeKey()) -> Transcript? {
        guard let data = try? Data(contentsOf: transcriptURL(itemId, scopeKey)),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              transcript.version >= Transcript.currentVersion else { return nil }
        return transcript
    }

    /// Atomic write of the transcript, plus the cheap status fields in `meta.json`.
    /// `totalDuration` (book seconds) turns coverage into the 0...1 `fraction`.
    @discardableResult
    nonisolated static func save(_ transcript: Transcript, totalDuration: Double?,
                                 scopeKey: String = currentScopeKey()) -> Bool {
        prepareDirectory(itemId: transcript.itemId, scopeKey: scopeKey)
        do {
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: transcriptURL(transcript.itemId, scopeKey),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            ShelfLog.error(.storage, "Transcript save failed: \(error.localizedDescription)")
            return false
        }
        let complete = transcript.isComplete
        var fraction = complete ? 1.0 : 0.0
        if !complete, let total = totalDuration, total > 0 {
            fraction = min(1, max(0, transcript.coveredUntil / total))
        }
        updateMeta(itemId: transcript.itemId, scopeKey: scopeKey) {
            $0.isComplete = complete
            $0.fraction = fraction
            if complete || !transcript.segments.isEmpty { $0.lastFailure = nil; $0.lastFailureMessage = nil }
        }
        return true
    }

    /// Removes the transcript and its meta for one book (keeps nothing, including the override).
    nonisolated static func delete(itemId: String, scopeKey: String = currentScopeKey()) {
        metaLock.lock(); defer { metaLock.unlock() }
        try? FileManager.default.removeItem(at: itemDirectory(itemId: itemId, scopeKey: scopeKey))
    }

    /// Removes only the transcript file, keeping the user's language override and high-water mark.
    nonisolated static func deleteTranscriptKeepingMeta(itemId: String, scopeKey: String = currentScopeKey()) {
        try? FileManager.default.removeItem(at: transcriptURL(itemId, scopeKey))
        updateMeta(itemId: itemId, scopeKey: scopeKey) {
            $0.isComplete = false
            $0.fraction = 0
            $0.lastFailure = nil
            $0.lastFailureMessage = nil
        }
    }

    /// Deletes every transcript of the current scope.
    nonisolated static func deleteAll() {
        deleteAll(forScopeKey: currentScopeKey())
    }

    /// Deletes every transcript of one scope (account removal, "Delete all transcripts").
    nonisolated static func deleteAll(forScopeKey scopeKey: String) {
        guard DownloadManager.isDeletableScopeKey(scopeKey) else { return }
        metaLock.lock(); defer { metaLock.unlock() }
        try? FileManager.default.removeItem(at: scopeDirectory(scopeKey: scopeKey))
    }

    // MARK: - Orphan sweep

    /// Reclaims transcript scopes belonging to no saved account. Uses the same trust rules as
    /// `DownloadManager.shouldReclaimScopeDirectory` (the saved-account list must contain the
    /// signed-in account, otherwise nothing is reclaimed). Returns how many scopes were removed.
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
        if removed > 0 { ShelfLog.info(.storage, "Reclaimed \(removed) orphaned transcript scope(s)") }
        return removed
    }

    // MARK: - Storage size

    /// Bytes used by one scope's transcripts (current scope by default).
    nonisolated static func storageBytes(scopeKey: String = currentScopeKey()) -> Int64 {
        directorySize(scopeDirectory(scopeKey: scopeKey))
    }

    /// Bytes used by all scopes' transcripts.
    nonisolated static func totalStorageBytes() -> Int64 {
        directorySize(rootDirectory())
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Meta (override, high-water, status)

    nonisolated static func meta(itemId: String, scopeKey: String = currentScopeKey()) -> TranscriptMeta {
        metaLock.lock(); defer { metaLock.unlock() }
        return readMeta(itemId, scopeKey)
    }

    /// Read-modify-write under the lock; creates the directory when needed.
    nonisolated static func updateMeta(itemId: String, scopeKey: String = currentScopeKey(),
                                       _ change: (inout TranscriptMeta) -> Void) {
        metaLock.lock(); defer { metaLock.unlock() }
        var meta = readMeta(itemId, scopeKey)
        let before = meta
        change(&meta)
        guard meta != before else { return }
        prepareDirectory(itemId: itemId, scopeKey: scopeKey)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(itemId, scopeKey),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private nonisolated static func readMeta(_ itemId: String, _ scopeKey: String) -> TranscriptMeta {
        guard let data = try? Data(contentsOf: metaURL(itemId, scopeKey)),
              let meta = try? JSONDecoder().decode(TranscriptMeta.self, from: data) else { return TranscriptMeta() }
        return meta
    }

    nonisolated static func languageOverride(itemId: String, scopeKey: String = currentScopeKey()) -> String? {
        meta(itemId: itemId, scopeKey: scopeKey).languageOverride
    }

    nonisolated static func setLanguageOverride(_ identifier: String?, itemId: String,
                                                scopeKey: String = currentScopeKey()) {
        updateMeta(itemId: itemId, scopeKey: scopeKey) { $0.languageOverride = identifier }
    }

    nonisolated static func highWater(itemId: String, scopeKey: String = currentScopeKey()) -> Double? {
        meta(itemId: itemId, scopeKey: scopeKey).highWater
    }

    /// Raises the high-water mark; never lowers it. Writes only on a real increase.
    nonisolated static func raiseHighWater(_ seconds: Double, itemId: String, scopeKey: String = currentScopeKey()) {
        guard seconds.isFinite, seconds > 0 else { return }
        updateMeta(itemId: itemId, scopeKey: scopeKey) {
            if seconds > ($0.highWater ?? 0) { $0.highWater = seconds }
        }
    }
}
