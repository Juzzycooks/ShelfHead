import Foundation
import CoreSpotlight
import AppIntents
import UniformTypeIdentifiers

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
        let signature = Self.signature(for: items)
        guard Self.shouldIndex(newSignature: signature,
                               lastSignature: UserDefaults.standard.string(forKey: Self.signatureDefaultsKey(domain: domain))) else { return }
        let searchable: [CSSearchableItem] = items.map { item in
            let fields = AudiobookEntityFields(item)
            let attrs = attributeSet(for: fields)
            // Batch 406: on iOS 18+ tie the item to its App Intents entity so Siri,
            // Shortcuts and Apple Intelligence can act on the result. Identifier and
            // domain stay as before (book id / per-account domain), so removal paths and
            // the `CSSearchableItemActionType` tap handler are untouched. iOS 17 unchanged.
            if #available(iOS 18.0, *) {
                attrs.associateAppEntity(AudiobookEntity(id: item.id, fields: fields))
            }
            return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: domain, attributeSet: attrs)
        }
        guard !searchable.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(searchable) { error in
            if let error {
                ShelfLog.error(.storage, "Spotlight index failed: \(error.localizedDescription)")
            } else {
                // Recorded only once the system accepted the batch, so a failure retries next time.
                UserDefaults.standard.set(signature, forKey: Self.signatureDefaultsKey(domain: domain))
            }
        }
    }

    /// UserDefaults cache key for "what this domain last indexed" (J2-16).
    static func signatureDefaultsKey(domain: String) -> String {
        "shelfhead_spotlightIndexedSignature." + domain
    }

    /// Stable (not the per-process-seeded `Hasher`) FNV-1a 64-bit digest over each item's id,
    /// title and description, in order. Cheap enough to run on every call.
    static func signature(for items: [LibraryItem]) -> String {
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
        }
        return String(hash, radix: 16) + "-" + String(items.count)
    }

    /// Pure: index unless the signature is exactly what was indexed last time.
    static func shouldIndex(newSignature: String, lastSignature: String?) -> Bool {
        newSignature != lastSignature
    }

    /// Pure field -> attribute-set mapping shared by the Spotlight item and the entity's
    /// `attributeSet`. Same title/description/keywords as before Batch 406.
    static func attributeSet(for fields: AudiobookEntityFields) -> CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .audio)
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
