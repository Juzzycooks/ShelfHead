import Foundation

/// On-device cache for a book's ebook file, plus the local EPUB reading position
/// (Batch 430, Section G part 1).
///
/// The file lives beside the transcript, at `TranscriptStore.itemDirectory(...)/ebook.<ext>`,
/// so account removal, the orphan sweep and storage accounting that already cover that
/// folder cover the ebook too. `TranscriptStore.prepareDirectory` is private, so the few
/// lines it needs (create, backup exclusion on the root, file protection) are repeated here.
///
/// EPUB positions are deliberately local only (`UserDefaults`). Audiobookshelf's own web
/// reader stores an epub.js CFI in `ebookLocation`, which this reader cannot produce
/// faithfully; writing any other shape would break resume in the web UI. PDF keeps its
/// existing server page sync in `EbookReaderView`.
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

    /// The cached file, or a fresh download of it (through `authorizedData`, so a 401
    /// refreshes and retries once). Thrown errors are for
    /// `EbookReaderView.downloadFailureMessage(for:)`.
    @MainActor
    static func fetch(item: LibraryItem) async throws -> URL {
        guard let file = item.media?.ebookFile else { throw StoreError.noFile }
        let ext = file.metadata?.normalizedExtension ?? ""
        let scopeKey = TranscriptStore.currentScopeKey()
        if let cached = cachedURL(itemId: item.id, ext: ext, scopeKey: scopeKey) { return cached }
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
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    static func savePosition(_ position: EPUBPosition, itemId: String,
                             scopeKey: String = TranscriptStore.currentScopeKey()) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        UserDefaults.standard.set(data, forKey: positionKey(itemId, scopeKey))
    }
}
