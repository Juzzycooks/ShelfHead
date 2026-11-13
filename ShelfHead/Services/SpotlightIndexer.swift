import Foundation
import CoreSpotlight
import AppIntents
import UniformTypeIdentifiers
import ImageIO

/// Indexes the audiobook library into Core Spotlight so books show in system search and
/// deep-link into their detail page. The searchable item's identifier is the book id;
/// `ContentView` resolves it in `onContinueUserActivity(CSSearchableItemActionType)`.
///
/// Add this file to the ShelfHead target in Xcode (see ShelfHeadExtras/SETUP.md notes).
enum SpotlightIndexer {
    /// The single, account-agnostic domain every build before Fix 5
    /// (REVIEW-2026-09-09.md) indexed into. Still the fallback when there's no real
    /// account scope yet, and still swept by `removeAll()` so items written by an older
    /// build don't become unreachable leftovers.
    private static let baseDomain = "books"

    /// Per-account domain identifier, so one account's indexed books can be dropped
    /// without touching another's — and so a stale id can't be resurrected by a
    /// re-index under the same domain. Derived from the download scope key (server +
    /// account), which is the app's existing identity for "one account's data."
    /// `nonisolated`-safe: `DownloadManager.shared` is a `nonisolated static let` and
    /// `currentScopeKey()` is pure computation over `AuthStore`/`AccountStore`.
    static func domain(forScopeKey scopeKey: String) -> String {
        guard !scopeKey.isEmpty, scopeKey != "unscoped" else { return baseDomain }
        return baseDomain + "." + scopeKey
    }

    private static var currentDomain: String {
        domain(forScopeKey: DownloadManager.shared.currentScopeKey())
    }

    /// Index (or refresh) the given items. No-op when the user disabled Spotlight or
    /// indexing isn't available. Redacts nothing sensitive — titles/authors only.
    static func index(_ items: [LibraryItem]) {
        guard SettingsStore.spotlightIndexingEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        let domain = currentDomain
        // Polish pass (J2-16): page 0 was re-indexed on every launch even when nothing changed.
        // Skip when this exact set (ids + titles + descriptions) is what this domain last indexed.
        // `signatureDefaultsKey` is a cache only: it's dropped whenever the index is cleared.
        // Batch 496 (REVIEW 2026-11-11 Y6): which items have a cover file already on disk (one stat
        // each, no network). Resolved here, against the current account, so a cover is only ever
        // attached under the domain it was resolved for.
        let sources = thumbnailSources(for: items)
        let signature = Self.signature(for: items, thumbnailIDs: Set(sources.keys))
        guard Self.shouldIndex(newSignature: signature,
                               lastSignature: UserDefaults.standard.string(forKey: Self.signatureDefaultsKey(domain: domain))) else { return }
        guard !items.isEmpty else { return }
        // Chunked and off the caller's thread: each chunk decodes and downsizes at most
        // `chunkSize` thumbnails and releases them before the next, so memory stays bounded.
        Task.detached(priority: .utility) {
            for start in stride(from: 0, to: items.count, by: Self.chunkSize) {
                // Turned off, signed out or switched account mid-run: stop writing into that index.
                guard SettingsStore.spotlightIndexingEnabled, currentDomain == domain else { return }
                let chunk = items[start..<min(start + Self.chunkSize, items.count)]
                let searchable: [CSSearchableItem] = chunk.map { item in
                    let fields = AudiobookEntityFields(item)
                    let thumb = sources[item.id].flatMap { Self.thumbnailData(from: $0) }
                    let attrs = attributeSet(for: fields, thumbnailData: thumb)
                    // Batch 406: on iOS 18+ tie the item to its App Intents entity so Siri,
                    // Shortcuts and Apple Intelligence can act on the result. Identifier and
                    // domain stay as before (book id / per-account domain), so removal paths and
                    // the `CSSearchableItemActionType` tap handler are untouched. iOS 17 unchanged.
                    if #available(iOS 18.0, *) {
                        attrs.associateAppEntity(AudiobookEntity(id: item.id, fields: fields))
                    }
                    return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: domain, attributeSet: attrs)
                }
                do {
                    try await CSSearchableIndex.default().indexSearchableItems(searchable)
                } catch {
                    ShelfLog.error(.storage, "Spotlight index failed: \(error.localizedDescription)")
                    return   // signature not recorded, so a failure retries next time
                }
            }
            // Recorded only once the system accepted every chunk.
            guard currentDomain == domain else { return }
            UserDefaults.standard.set(signature, forKey: Self.signatureDefaultsKey(domain: domain))
        }
    }

    // MARK: - Thumbnails (Batch 496, REVIEW 2026-11-11 Y6)

    static let chunkSize = 50
    /// Spotlight shows a small square; 256 px covers 2x/3x without carrying a 600 px JPEG per item.
    static let thumbnailMaxPixel = 256
    /// Widths the app requests covers at (`shelfCoverURL` call sites); each is its own cache file.
    static let cachedCoverWidths = [300, 600, 700, 900, 120, 80]

    /// Pure: which file to read a thumbnail from. A downloaded book's local `cover.jpg` wins
    /// (600 px, kept for the life of the download); else the cached width closest above
    /// `target` (smallest that is big enough, otherwise the largest). `nil` keeps the app icon.
    /// `cached` holds only entries known to exist on disk.
    static func chooseThumbnailSource(downloadedCover: URL?, cached: [(width: Int, url: URL)],
                                      target: Int = thumbnailMaxPixel) -> URL? {
        if let downloadedCover { return downloadedCover }
        if let fit = cached.filter({ $0.width >= target }).min(by: { $0.width < $1.width }) { return fit.url }
        return cached.max(by: { $0.width < $1.width })?.url
    }

    /// Item id -> the on-disk source for its thumbnail. Only stats files; never reads bytes
    /// or touches the network. The cache is keyed by full cover URL (server host included), so
    /// another server's cover for the same id is never found.
    private static func thumbnailSources(for items: [LibraryItem]) -> [String: URL] {
        let server = AuthStore.shared.serverURL
        var result: [String: URL] = [:]
        for item in items {
            let local = DownloadManager.shared.downloadDirectory(for: item.id).appendingPathComponent("cover.jpg")
            let downloaded = FileManager.default.fileExists(atPath: local.path) ? local : nil
            var cached: [(width: Int, url: URL)] = []
            if downloaded == nil {
                for width in cachedCoverWidths {
                    guard let base = URL(string: "\(server)/api/items/\(percentEncodedPathComponent(item.id))/cover?width=\(width)")
                    else { continue }
                    let key = coverCacheBustedURL(base: base, version: CoverVersions.version(for: item.id))
                    if DiskCoverCache.contains(key) { cached.append((width, key)) }
                }
            }
            if let source = chooseThumbnailSource(downloadedCover: downloaded, cached: cached) {
                result[item.id] = source
            }
        }
        return result
    }

    /// Reads the cached bytes (file URL, or the remote-keyed `DiskCoverCache` entry) and
    /// downsizes to a small JPEG with ImageIO (thread-safe, decodes only at thumbnail size).
    /// We hand Spotlight bytes (`thumbnailData`) instead of a path so it never needs read
    /// access to our cache file, which is file-protected until first unlock.
    private static func thumbnailData(from source: URL) -> Data? {
        let raw = source.isFileURL ? (try? Data(contentsOf: source)) : DiskCoverCache.data(for: source)
        guard let raw else { return nil }
        return downscaledJPEG(from: raw, maxPixel: thumbnailMaxPixel)
    }

    static func downscaledJPEG(from data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// UserDefaults cache key for "what this domain last indexed" (J2-16).
    static func signatureDefaultsKey(domain: String) -> String {
        "shelfhead_spotlightIndexedSignature." + domain
    }

    /// Stable (not the per-process-seeded `Hasher`) FNV-1a 64-bit digest over each item's id,
    /// title and description, in order. Cheap enough to run on every call.
    /// `thumbnailIDs` (Batch 496): ids that have a cover source on disk. Each item mixes a
    /// has-thumbnail flag, so an item whose cover gets cached later changes the signature of
    /// the batch it is in (re-indexing that page only), while an unchanged page stays skipped.
    static func signature(for items: [LibraryItem], thumbnailIDs: Set<String> = []) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0xff   // field separator
            hash = hash &* 0x100000001b3
        }
        for item in items {
            let fields = AudiobookEntityFields(item)
            mix(item.id)
            mix(fields.title)
            mix(fields.contentDescription)
            if !thumbnailIDs.isEmpty { mix(thumbnailIDs.contains(item.id) ? "t" : "-") }
        }
        return String(hash, radix: 16) + "-" + String(items.count)
    }

    /// Pure: index unless the signature is exactly what was indexed last time.
    static func shouldIndex(newSignature: String, lastSignature: String?) -> Bool {
        newSignature != lastSignature
    }

    /// Pure field -> attribute-set mapping shared by the Spotlight item and the entity's
    /// `attributeSet`. Same title/description/keywords as before Batch 406.
    static func attributeSet(for fields: AudiobookEntityFields, thumbnailData: Data? = nil) -> CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .audio)
        attrs.thumbnailData = thumbnailData
        attrs.title = fields.title
        attrs.contentDescription = fields.contentDescription
        attrs.keywords = fields.keywords
        return attrs
    }

    /// Remove all indexed books — sign-out, account switch, or the user turning
    /// indexing off in Settings.
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): this was only reachable from `logout()`, so after an
    /// account switch both servers' titles stayed searchable system-wide and tapping a
    /// stale result silently did nothing (the id doesn't exist on the new server). It now
    /// also runs on switch, via `AuthViewModel.tearDownAccountScopedState(reason:)`.
    /// Deletes everything this app has indexed rather than one domain: the previous
    /// per-domain call couldn't reach items written by a build that used the old bare
    /// `"books"` domain, and every remaining book is re-indexed on the next library load
    /// anyway.
    static func removeAll() {
        clearSignatures()   // Polish pass (J2-16): the index is empty, so "already indexed" no longer holds.
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }

    /// Removes just one account's indexed books, for deleting a saved account that isn't
    /// the one currently signed in — the current account's Spotlight results shouldn't
    /// disappear because a different server was removed from Settings.
    static func remove(scopeKey: String) {
        UserDefaults.standard.removeObject(forKey: signatureDefaultsKey(domain: domain(forScopeKey: scopeKey)))
        CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [domain(forScopeKey: scopeKey)]) { _ in }
    }

    /// Drops every recorded signature (J2-16).
    private static func clearSignatures() {
        let prefix = signatureDefaultsKey(domain: "")
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
