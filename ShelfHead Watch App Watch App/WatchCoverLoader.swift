import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stage 4 (addendum §4/§10.2) — the standalone Watch's own cover fetch/cache path.
/// The companion mirror lists (`RecentlyAddedView`, the "On iPhone" downloads) get cover bytes
/// pre-fetched by the phone and pushed over WatchConnectivity as embedded `Data`
/// (`WatchBookSummary.coverData` etc.) — there's no equivalent push for standalone
/// library browsing, since nothing on the phone is involved. This Watch has to fetch
/// its own covers directly from the server, same as the phone does for itself, just
/// through a narrower, Watch-appropriate path.
///
/// Reuses `DiskCoverCache.swift` (`ShelfHead/Services/DiskCoverCache.swift`) directly
/// — confirmed pure `Foundation`/`CryptoKit`, zero `UIKit` dependency, so it compiles
/// into this target unchanged (added to this target's Sources phase this batch, same
/// two-line pattern Stage 1 used for `AuthStore.swift`/`KeychainService.swift`). Not
/// reusing the phone's in-memory `CoverImageCache`/`CoverImageView` (`Extensions.swift`)
/// — those are `UIKit`-heavy view-layer types built around the phone's own cache-size
/// assumptions (300-item/96MB `NSCache`), not portable or appropriately sized for a
/// Watch. This file's own in-memory tier is deliberately smaller.
@MainActor
final class WatchCoverLoader {
    // No default value on `api` (build fix, 28 August 2026 — same precedent as
    // `WatchStore.swift`'s own `private init(companion:)` doc comment and
    // `WatchLocalDownloadManager`'s `static let shared`): a default *parameter*
    // value is evaluated as if `nonisolated` regardless of the enclosing
    // initializer's own actor isolation, so `WatchAudiobookshelfAPI.shared`
    // (`@MainActor`-isolated) can't be a default value here even though this
    // `init` is `@MainActor`. Passed explicitly below instead.
    static let shared = WatchCoverLoader(api: WatchAudiobookshelfAPI.shared)

    /// Small on purpose — a Watch screen shows at most a handful of rows at once, not
    /// a scrolling grid of dozens. `NSCache` evicts under memory pressure regardless.
    private let memoryCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 60
        return cache
    }()

    /// Cap for the on-disk cover tier, much smaller than the phone's 200MB default
    /// (`DiskCoverCache.evictIfNeeded`): covers shouldn't compete with downloads for a
    /// Watch's storage. Applied once per cold launch by `WatchAppDelegate`, the same
    /// "occasional, not per-write" pattern the phone uses. Nothing applied it before
    /// 30 October 2026, so the Watch's cover cache had no cap at all.
    nonisolated static let diskCacheLimitBytes: Int64 = 20 * 1024 * 1024

    private let api: WatchAudiobookshelfAPI

    init(api: WatchAudiobookshelfAPI) {
        self.api = api
    }

    /// Returns decoded image data for `itemId`, or `nil` if it can't be fetched
    /// (offline, 404, decode failure). Never throws — a missing cover is a
    /// `CoverThumbnail`-style fallback glyph, not an error worth surfacing to the
    /// user.
    ///
    /// Real on-device bug fix (31 August 2026): this used to build its own request
    /// from `coverURL(itemId:width:)` and fire it directly via
    /// `URLSession.shared.data(for:)` — bypassing `WatchAudiobookshelfAPI.send(...)`,
    /// the only place that refreshes an expired access token and retries once on a
    /// 401. That meant a cover fetch could silently 401-forever the moment the Watch's
    /// token aged out mid-session, while every other request kept working (they all go
    /// through `send`) — reported as "no book covers shown in library at all." Now
    /// goes through `api.coverData(itemId:width:)`, which gets the same
    /// refresh-and-retry and the same ATS/transport-error classification as every
    /// other endpoint. `coverURL(itemId:width:)` is still used, but only to compute the
    /// cache key below — the network request itself no longer touches it directly.
    func loadCoverData(itemId: String, width: Int = 200) async -> Data? {
        guard let url = api.coverURL(itemId: itemId, width: width) else { return nil }

        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached as Data
        }
        // Concurrency review (9 September 2026): the disk tier runs off the main actor.
        // `DiskCoverCache.data(for:)` is a SHA-256 of the URL plus a blocking
        // `Data(contentsOf:)`, and this class is `@MainActor` — `StandaloneCoverThumbnail`
        // calls in from a SwiftUI `.task`, so reading inline held the main actor for the
        // whole read, once per visible list row, with a cold `Caches/` page on a Watch
        // being exactly where that is slowest. Same detached-read shape the phone's
        // `CachedCover` disk tier uses (`Extensions.swift`), minus the decode/downsample:
        // this path hands raw `Data` straight to the view. The memory tier above stays
        // synchronous (an `NSCache` hit is cheap and wants to render on the first frame),
        // and the network tier below still goes through
        // `WatchAudiobookshelfAPI.coverData` — see the doc comment above for why that
        // routing must not be disturbed.
        let diskData = await Task.detached(priority: .userInitiated) {
            DiskCoverCache.data(for: url)
        }.value
        if let diskData {
            memoryCache.setObject(diskData as NSData, forKey: url as NSURL)
            return diskData
        }

        do {
            let data = try await api.coverData(itemId: itemId, width: width)
            memoryCache.setObject(data as NSData, forKey: url as NSURL)
            // Same reason as the read: `store` is a blocking atomic `Data.write(to:)`.
            // Awaited rather than fired and forgotten so the write can't outlive the
            // caller unobserved — awaiting suspends this task, it doesn't hold the main
            // actor, so nothing else on the Watch's UI is blocked while it lands.
            await Task.detached(priority: .utility) {
                DiskCoverCache.store(data, for: url)
            }.value
            return data
        } catch {
            return nil
        }
    }
}

#if canImport(UIKit)
/// Polish pass (WA-7): `UIImage(data:)` used to run inside view bodies, so every re-evaluation
/// (Now Playing's 1 s tick, a shelf refresh) re-created the image object from the same bytes.
/// This keeps the decoded image per cover bytes. `NSData` hashing/equality is cheap for a
/// few-kilobyte cover, and `NSCache` evicts under memory pressure.
@MainActor
enum WatchDecodedCoverCache {
    private static let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 24
        return cache
    }()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
#endif

/// Async-loading counterpart to `CoverThumbnail` (`NowPlayingView.swift:286–320`) for
/// standalone library rows, which have an item id + server round trip instead of
/// already-in-hand `Data`. Deliberately a separate type rather than adding a
/// `URL`/itemId case to `CoverThumbnail` itself — that type's contract (`data: Data?`,
/// synchronous, no loading state) is simple and correct for its own callers; bolting
/// an async path onto it would make every existing call site carry complexity it
/// doesn't need.
import SwiftUI

struct StandaloneCoverThumbnail: View {
    let itemId: String
    var side: CGFloat = 44
    /// Batch 413: with a title, a large thumbnail with no artwork shows `WatchTitleCover`.
    var title: String? = nil
    var author: String? = nil

    @State private var data: Data?

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let data, let image = WatchDecodedCoverCache.image(for: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
        // Design review 2026-09-23 AN-1: fade the fallback→cover swap instead of a
        // hard pop once the async fetch lands.
        .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: data != nil)
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
        .task(id: itemId) {
            data = await WatchCoverLoader.shared.loadCoverData(itemId: itemId, width: Int(side * 2))
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let title, side >= WatchTitleCover.minimumSide {
            WatchTitleCover(title: title, author: author, cornerRadius: 6)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(WatchTheme.cardBorder)
                .overlay(Image(systemName: "book.closed.fill").foregroundStyle(WatchTheme.secondaryText))
        }
    }
}
