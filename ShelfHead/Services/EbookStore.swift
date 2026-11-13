import Foundation

/// On-device cache for a book's ebook file, plus the local EPUB reading position
/// (Batch 430, Section G part 1).
///
/// The file lives beside the transcript, at `TranscriptStore.itemDirectory(...)/ebook.<ext>`,
/// so account removal, the orphan sweep and storage accounting that already cover that
/// folder cover the ebook too. `TranscriptStore.prepareDirectory` is private, so the few
/// lines it needs (create, backup exclusion on the root, file protection) are repeated here.
///
/// EPUB positions are saved locally (`UserDefaults`). Audiobookshelf's own web
/// reader stores an epub.js CFI in `ebookLocation`, which this reader cannot produce
/// faithfully; writing any other shape would break resume in the web UI. PDF keeps its
/// existing server page sync in `EbookReaderView`.
///
/// Batch 495 (REVIEW 2026-11-11 L11/L12): PDF and CBZ (and EPUB on iOS 17–25) are cached
/// here too, so they open offline and count in the same storage. The EPUB reader sends
/// `ebookProgress` only (a 0–1 fraction) and, with iCloud position sync on, carries the
/// spine position between the listener's devices through `CloudPositionStore`.
nonisolated enum EbookStore {
    nonisolated enum StoreError: LocalizedError {
        case noFile, missingInfo, badURL

        var errorDescription: String? {
            switch self {
            case .noFile: return String(localized: "No ebook file found for this item.")
            case .missingInfo: return String(localized: "This ebook file is missing required information.")
            case .badURL: return String(localized: "Couldn't build a download URL for this file.")
            }
        }
    }

    // MARK: - Paths

    private static func safeExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "bin" : cleaned
    }

    private static func fileURL(itemId: String, ext: String, scopeKey: String) -> URL {
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey)
            .appendingPathComponent("ebook.\(safeExtension(ext))")
    }

    private static func prepareDirectory(itemId: String, scopeKey: String) {
        let fm = FileManager.default
        let root = TranscriptStore.rootDirectory()
        let dir = TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey)
        let existed = fm.fileExists(atPath: root.path)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !existed {
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        for target in [root, TranscriptStore.scopeDirectory(scopeKey: scopeKey), dir] {
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: target.path)
        }
    }

    // MARK: - File

    /// The cached ebook file, when it exists on disk.
    static func cachedURL(itemId: String, ext: String,
                          scopeKey: String = TranscriptStore.currentScopeKey()) -> URL? {
        let url = fileURL(itemId: itemId, ext: ext, scopeKey: scopeKey)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Freshness (Batch 497, REVIEW 2026-11-11 L11)

    /// What the server says about the ebook file, kept beside the cached copy so a replaced
    /// file is noticed. Audiobookshelf's `EBookFile` is `{ino, metadata, ebookFormat, addedAt,
    /// updatedAt}` and `metadata` is `FileMetadata` `{filename, ext, path, relPath, size, mtimeMs,
    /// ctimeMs, birthtimeMs}` (server/objects/files/EBookFile.js, server/objects/metadata/
    /// FileMetadata.js). Every field is optional: a field either side lacks is not compared.
    nonisolated struct Fingerprint: Codable, Equatable, Sendable {
        var ino: String?
        var size: Int64?
        var mtimeMs: Double?
        var updatedAt: Double?

        init(ino: String?, size: Int64? = nil, mtimeMs: Double? = nil, updatedAt: Double? = nil) {
            self.ino = ino
            self.size = size
            self.mtimeMs = mtimeMs
            self.updatedAt = updatedAt
        }

        init(file: EbookFile) {
            self.init(ino: file.ino, size: file.stampSize, mtimeMs: file.stampMtimeMs, updatedAt: file.stampUpdatedAt)
        }
    }

    nonisolated enum FreshnessDecision: Equatable, Sendable {
        /// The cached copy is the server's file; nothing to store.
        case keep
        /// Same file as far as anyone can tell, but the current fingerprint knows more (or the
        /// copy predates fingerprints): store it, don't download.
        case adopt
        /// The server's file differs: download again.
        case refetch
    }

    /// Pure: whether a cached copy is still the server's file. No stored fingerprint (saved by
    /// Batch 495) adopts the current one. Otherwise only fields present on both sides are compared,
    /// so an older server that omits fields never forces a download. Pinned by `Batch497EbookCacheTests`.
    nonisolated static func freshness(stored: Fingerprint?, current: Fingerprint) -> FreshnessDecision {
        guard let stored else { return .adopt }
        func differs<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
            guard let a, let b else { return false }
            return a != b
        }
        if differs(stored.ino, current.ino) || differs(stored.size, current.size)
            || differs(stored.mtimeMs, current.mtimeMs) || differs(stored.updatedAt, current.updatedAt) {
            return .refetch
        }
        return stored == current ? .keep : .adopt
    }

    /// Pure: a saved PDF page made valid for the document now on disk. nil when there is no
    /// page to open at (no pages, or nothing saved). A page past the end of a shorter, replaced
    /// file lands on its last page rather than being dropped.
    nonisolated static func clampedPage(_ page: Int?, pageCount: Int) -> Int? {
        guard let page, pageCount > 0 else { return nil }
        return min(max(0, page), pageCount - 1)
    }

    /// Pure: a saved EPUB position made valid for the package now on disk (spine index into
    /// range, fraction 0...1). nil when there is no position or no spine.
    nonisolated static func clampedPosition(_ position: EPUBPosition?, spineCount: Int) -> EPUBPosition? {
        guard let position, spineCount > 0 else { return nil }
        return EPUBPosition(spineIndex: min(max(0, position.spineIndex), spineCount - 1),
                            fraction: position.fraction)
    }

    private static func fingerprintURL(itemId: String, scopeKey: String) -> URL {
        // Starts with "ebook." so `delete(itemId:)` removes it with the file.
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey)
            .appendingPathComponent("ebook.fingerprint.json")
    }

    private static func storedFingerprint(itemId: String, scopeKey: String) -> Fingerprint? {
        guard let data = try? Data(contentsOf: fingerprintURL(itemId: itemId, scopeKey: scopeKey)) else { return nil }
        return try? JSONDecoder().decode(Fingerprint.self, from: data)
    }

    private static func saveFingerprint(_ fingerprint: Fingerprint, itemId: String, scopeKey: String) {
        guard let data = try? JSONEncoder().encode(fingerprint) else { return }
        try? data.write(to: fingerprintURL(itemId: itemId, scopeKey: scopeKey),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The cached file, or a fresh download of it (through `authorizedData`, so a 401
    /// refreshes and retries once). Thrown errors are for
    /// `EbookReaderView.downloadFailureMessage(for:)`.
    ///
    /// Batch 497 (L11): a cached copy is compared with `item`'s ebook file (`freshness`). The
    /// item is the caller's: Book Detail's is the expanded `getItem` fetched when the screen opened,
    /// the player's is the one its session started with, so no extra request is made here. A
    /// changed file is downloaded to a temporary name and swapped in only once complete; offline,
    /// unreachable or failing, the old copy is used.
    @MainActor
    static func fetch(item: LibraryItem) async throws -> URL {
        guard let file = item.media?.ebookFile else { throw StoreError.noFile }
        let ext = file.metadata?.normalizedExtension ?? ""
        let scopeKey = TranscriptStore.currentScopeKey()
        let current = Fingerprint(file: file)
        if let cached = cachedURL(itemId: item.id, ext: ext, scopeKey: scopeKey) {
            let stored = storedFingerprint(itemId: item.id, scopeKey: scopeKey)
            switch freshness(stored: stored, current: current) {
            case .keep:
                return cached
            case .adopt:
                saveFingerprint(current, itemId: item.id, scopeKey: scopeKey)
                return cached
            case .refetch:
                guard ReachabilityStore.shared.status == .ok else { return cached }
                do {
                    return try await download(item: item, file: file, ext: ext, scopeKey: scopeKey, fingerprint: current)
                } catch {
                    ShelfLog.error(.storage, "Ebook refresh failed for \(ShelfLog.redact(item.id)); using the cached copy: \(error)")
                    return cached
                }
            }
        }
        return try await download(item: item, file: file, ext: ext, scopeKey: scopeKey, fingerprint: current)
    }

    @MainActor
    private static func download(item: LibraryItem, file: EbookFile, ext: String, scopeKey: String,
                                 fingerprint: Fingerprint) async throws -> URL {
        guard let ino = file.ino else { throw StoreError.missingInfo }
        let serverURL = AuthStore.shared.serverURL
        let itemPart = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.id
        let inoPart = ino.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ino
        guard let url = URL(string: "\(serverURL)/api/items/\(itemPart)/file/\(inoPart)/download") else {
            throw StoreError.badURL
        }
        let data = try await AudiobookshelfAPI.shared.authorizedData(for: url)
        prepareDirectory(itemId: item.id, scopeKey: scopeKey)
        let destination = fileURL(itemId: item.id, ext: ext, scopeKey: scopeKey)
        // Written beside the destination, then swapped in: a failure leaves the old copy readable.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("ebook.download.tmp")
        try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        // A replacement with another extension leaves the old file behind; remove it.
        let keep: Set<String> = [destination.lastPathComponent, fingerprintURL(itemId: item.id, scopeKey: scopeKey).lastPathComponent]
        let dir = destination.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("ebook.") && !keep.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        saveFingerprint(fingerprint, itemId: item.id, scopeKey: scopeKey)
        return destination
    }

    /// Removes the cached ebook file(s) for one book, leaving the transcript alone.
    static func delete(itemId: String, scopeKey: String = TranscriptStore.currentScopeKey()) {
        let dir = TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("ebook.") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Reading position

    private static func positionKey(_ itemId: String, _ scopeKey: String) -> String {
        "epubReader.position.\(scopeKey).\(itemId)"
    }

    static func position(itemId: String, scopeKey: String = TranscriptStore.currentScopeKey()) -> EPUBPosition? {
        guard let data = UserDefaults.standard.data(forKey: positionKey(itemId, scopeKey)) else { return nil }
        return try? JSONDecoder().decode(EPUBPosition.self, from: data)
    }

    /// Batch 495 (L12): `savedAt` is kept beside the position so a newer iCloud position
    /// (`CloudPositionStore.shouldAdoptCloudEPUBPosition`) can be told apart from an older one.
    static func savePosition(_ position: EPUBPosition, itemId: String, savedAt: Date = Date(),
                             scopeKey: String = TranscriptStore.currentScopeKey()) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        UserDefaults.standard.set(data, forKey: positionKey(itemId, scopeKey))
        UserDefaults.standard.set(savedAt.timeIntervalSince1970, forKey: positionKey(itemId, scopeKey) + ".at")
    }

    /// When `savePosition` last ran for this book; nil for a position saved before Batch 495.
    static func positionSavedAt(itemId: String, scopeKey: String = TranscriptStore.currentScopeKey()) -> Date? {
        let seconds = UserDefaults.standard.double(forKey: positionKey(itemId, scopeKey) + ".at")
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    // MARK: - Reading progress sent to the server (Batch 495, REVIEW 2026-11-11 L12)

    /// Pure: whether the EPUB reader should send `ebookProgress` now. `lastSent` is the
    /// last value sent this session, or the server's known value on open (nil if none).
    /// Nothing is sent for a book still at the very start that the server has no value for.
    /// While reading, a move of a whole percent; on close or backgrounding (`isFinal`) any
    /// visible change. Pinned by `Batch495ReaderProgressTests`.
    static func shouldSendReadingProgress(current: Double, lastSent: Double?, isFinal: Bool) -> Bool {
        guard current.isFinite else { return false }
        guard let lastSent else { return current >= 0.005 }
        // The epsilon keeps an exact step (0.41 after 0.40 is 0.00999… in binary) on the sending side.
        let delta = abs(current - lastSent) + 1e-9
        return isFinal ? delta >= 0.005 : delta >= 0.01
    }
}

// Batch 497 (L11): what the fingerprint reads from the server's ebook file record: the file's
// own identity (`ino`), size and modified time. The record's `updatedAt` is deliberately not
// used: it is the server's bookkeeping time for the record, not the file, so a rescan that
// touches the record would force a download of an unchanged file.
extension EbookFile {
    nonisolated var stampSize: Int64? { metadata?.size }
    nonisolated var stampMtimeMs: Double? { metadata?.mtimeMs }
    nonisolated var stampUpdatedAt: Double? { nil }
}
