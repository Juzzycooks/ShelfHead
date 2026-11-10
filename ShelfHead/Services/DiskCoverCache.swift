import Foundation
import CryptoKit

/// A small disk-backed cache of cover JPEGs, sitting behind the in-memory
/// `CoverImageCache` (Extensions.swift). Before this, covers were memory-only — an
/// `NSCache`, evicted under memory pressure and always empty at process start — so
/// every cold launch re-downloaded the entire visible library grid from the user's
/// own server (F3). This adds a `Caches/covers/` disk tier so a cold launch can render
/// instantly from disk while the existing network path keeps it current.
///
/// Deliberately separate from `DownloadManager.localCoverURL` (which persists cover
/// art only for *downloaded* books, permanently, alongside the audio files) — this is
/// a pure cache: bounded, evictable, and rebuildable from the server at any time.
///
/// **Explicitly `nonisolated` (fix 9, REVIEW-2026-09-09.md).** Same reasoning as
/// `AuthStore` (see that type's own header, which documents the build break this
/// prevents): this file compiles into two targets with different
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` — the app (`ShelfHead`) is `nonisolated`, the Watch
/// app (`ShelfHead Watch`) is `MainActor` — so without an annotation it was silently
/// nonisolated on iOS and implicitly `@MainActor` on watchOS, i.e. the same source
/// declaring two different contracts depending on who was compiling it. Everything here
/// is pure `Foundation`/`CryptoKit` file I/O with no shared mutable state (the one
/// stored member is a `let URL`), meant to be callable from any isolation domain —
/// notably `CoverImageCache.coverData`, which is `nonisolated async` and is exactly the
/// caller that must be able to read this cache off the main actor. Pinning it here makes
/// it behave identically in both targets rather than depending on the two agreeing.
///
/// Note this pins the *isolation*, not the *thread*: `data(for:)`/`store(_:for:)` are
/// synchronous, so they still block whichever thread calls them. Callers that are on the
/// main actor (`WatchCoverLoader`, `@MainActor`) therefore still do their disk read on
/// the main thread — a separate, still-open review item on the Watch side.
nonisolated enum DiskCoverCache {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Keyed on the full cover URL (same identity `CoverImageCache`'s `NSCache` uses),
    /// so different requested widths for the same book get separate cached files. A
    /// SHA-256 hex digest keeps the filename short and filesystem-safe regardless of
    /// how long or unusual the server's hostname/path is.
    private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex + ".jpg")
    }

    static func data(for url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    static func store(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)
    }

    // MARK: - Revalidation (item 15, REVIEW-2026-09-09-REMAINING.md)
    //
    // This cache never revalidated: a cover fetched once was served from disk forever
    // (or until LRU eviction happened to reach it), so replaced server artwork never
    // showed up in the app. There's no separate sidecar/index file for a per-entry
    // "stored at" timestamp — `store(_:for:)` already leaves a real write-time
    // filesystem mtime behind, and `evictIfNeeded()` below already reads that same
    // field (`contentModificationDateKey`) as its LRU proxy, so reusing it here is the
    // simplest layout that fits: no new files, no index to keep in sync with `clear()`.
    //
    // Revalidation itself is a plain re-fetch-and-compare, not an ETag/If-None-Match
    // conditional request: `AudiobookshelfAPI.authorizedData(for:)` returns only decoded
    // body bytes, not response headers, so there's nothing cheap to condition on without
    // widening that method's contract. A full re-fetch past the TTL is the accepted
    // trade — see `CoverImageCache.revalidateIfNeeded` (Extensions.swift), the caller
    // that actually performs it; this type only tracks and judges staleness.

    /// How long a cached cover is served without question before a background
    /// revalidation fetch is worth kicking off. A cover check is cheap for us but not
    /// free for the user's own server, so this isn't tiny — most self-hosted libraries
    /// don't get new artwork for a book more than a few times a year.
    static let coverTTL: TimeInterval = 7 * 24 * 60 * 60

    /// When `url`'s cached bytes were last written (by `store(_:for:)`) or confirmed
    /// still current (by `touch(_:)`). `nil` when there's no cached entry at all.
    static func storedAt(for url: URL) -> Date? {
        (try? fileURL(for: url).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// Refreshes `url`'s cached-at timestamp without rewriting its bytes — used when a
    /// revalidation fetch confirms the server's copy hasn't changed, so the next read
    /// doesn't re-check again for another full TTL window.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: fileURL(for: url).path)
    }

    /// Pure staleness predicate — no filesystem access — so it's unit-testable without a
    /// real cache directory. "Older than" is deliberately strict (`>`, not `>=`): an
    /// entry exactly `ttl` old is still within its freshness window.
    nonisolated static func needsRevalidation(storedAt: Date, now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(storedAt) > ttl
    }

    /// Drops every cached cover JPEG.
    ///
    /// Fix 5 (REVIEW-2026-09-09.md): nothing cleared this directory on sign-out or
    /// account removal, so a signed-out server's artwork sat in `Caches/covers/` until
    /// LRU eviction happened to reach it. Called from
    /// `AuthViewModel.tearDownAccountScopedState(reason:)` for sign-out and account
    /// removal — deliberately NOT for an account *switch*: entries are keyed by the full
    /// cover URL (server host included), so there's no cross-account confusion to fix,
    /// and throwing them away would make switching back re-download the whole visible
    /// grid from the user's own server for no benefit.
    ///
    /// Removes the directory's contents rather than the directory itself, so `directory`
    /// (resolved once, lazily) stays valid afterwards.
    static func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Keeps the cache bounded (unlike the UserDefaults growth fixed in M7 — this is
    /// exactly the kind of thing that needs a cap). Call occasionally (e.g. once at
    /// launch), not on every write — this walks the whole directory.
    static func evictIfNeeded(limitBytes: Int64 = 200 * 1024 * 1024) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }

        var entries: [(url: URL, date: Date, size: Int64)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, date, Int64(size))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return }

        // "Oldest" here means oldest-*written-or-revalidated* (modification date), not
        // oldest-accessed — `data(for:)` doesn't touch a file's mtime on read; only
        // `store(_:for:)` (a real write) and `touch(_:)` (item 15: a revalidation that
        // confirmed the server's copy is unchanged) do. A cover read on every launch but
        // last confirmed current months ago is evicted before one confirmed current last
        // week and never looked at since. That's a defensible proxy for a cache like this
        // (LRU-by-access would need a read-time mtime touch, adding a write on every
        // cache hit), just worth knowing which clock it is. No separate metadata file
        // exists for `clear()`/this walk to account for — `storedAt`/`touch` above both
        // read and write this same mtime field, nothing new was added alongside it.
        entries.sort { $0.date < $1.date }   // oldest-written first
        for entry in entries {
            guard total > limitBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
