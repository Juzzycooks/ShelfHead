import Foundation
import UIKit
import WidgetKit

/// Keeps `SharedLibrary` — the set of books the widget's configuration intent can offer —
/// in step with what the user is actually part-way through.
///
/// Split into two entry points because the two halves have different owners: Continue
/// Listening belongs to `LibraryViewModel` (it already extracts that shelf to drive
/// auto-download), and the Up Next queue belongs to `PlayerViewModel`. Each publishes its
/// own half when it changes; this merges them so neither has to know about the other.
///
/// Covers are fetched here rather than in the widget because the widget has neither
/// credentials nor a network budget — see `SharedLibrary`'s doc comment.
@MainActor
enum WidgetLibraryPublisher {

    /// Matches the downscale `AudioPlayerService` already applies before writing the
    /// now-playing cover: at widget scale nothing larger is visible, and the App Group
    /// container holds up to `SharedLibrary.maxBooks` of these.
    private static let coverPixelSize = CGSize(width: 240, height: 240)
    private static let coverCompressionQuality: CGFloat = 0.7

    /// Republish the Continue Listening half. Safe to call on every personalized-view
    /// load; it no-ops when nothing has actually changed.
    ///
    /// W2 (REVIEW_2026-09-04_UI.md Pass 4): `progress` exists because the shelf entities
    /// `getPersonalizedView` returns carry no `userMediaProgress` at all — `item.current
    /// Time` is `mediaProgress?.currentTime ?? 0`, so every book on the *Continue
    /// Listening* shelf was published at position zero. A widget pinned to one of them
    /// drew an empty bar and the whole book duration as time left. `LibraryViewModel`
    /// already holds the real positions in the side map it builds in `loadUserProgress()`;
    /// the caller passes that lookup in so it can be merged before publishing.
    static func publishContinueListening(
        _ items: [LibraryItem],
        progress: (String) -> MediaProgress? = { _ in nil }
    ) {
        var payload = SharedLibrary.read()
        let existingUpNext = payload.books.filter { payload.upNextIds.contains($0.id) }
        let listening = items.map { pinnable($0, progress: progress($0.id)) }
        payload.books = merge(continueListening: listening, upNext: existingUpNext)
        commit(payload)
    }

    /// Republish the Up Next half. Called from every queue mutation, alongside the
    /// queue's own persistence.
    ///
    /// No progress lookup here (unlike `publishContinueListening`): a queued book is a
    /// fully-fetched `getLibraryItem` result, so it carries its own `userMediaProgress`
    /// and `item.currentTime` is already the real position.
    static func publishUpNext(_ items: [LibraryItem]) {
        var payload = SharedLibrary.read()
        let queued = items.map { pinnable($0, progress: nil) }
        let existingContinue = payload.books.filter { !payload.upNextIds.contains($0.id) }
        payload.upNextIds = queued.map(\.id)
        payload.books = merge(continueListening: existingContinue, upNext: queued)
        commit(payload)
    }

    /// Sign-out / account switch. The published set is per-account by nature — leaving one
    /// account's books pickable while another is signed in would be both wrong and a
    /// small privacy leak onto the Home Screen.
    static func clear() {
        SharedLibrary.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Internals

    /// Up Next first, then Continue Listening, de-duplicated by id and capped.
    ///
    /// Order matters: it decides what survives the cap and how the widget's picker reads.
    /// A queued book is a more deliberate signal of intent than one that merely has
    /// progress, so it wins both the ordering and the last slot.
    static func merge(
        continueListening: [SharedLibrary.PinnableBook], upNext: [SharedLibrary.PinnableBook]
    ) -> [SharedLibrary.PinnableBook] {
        var seen = Set<String>()
        var result: [SharedLibrary.PinnableBook] = []
        for book in upNext + continueListening where seen.insert(book.id).inserted {
            result.append(book)
            if result.count == SharedLibrary.maxBooks { break }
        }
        return result
    }

    private static func pinnable(_ item: LibraryItem, progress: MediaProgress?) -> SharedLibrary.PinnableBook {
        let resolved = resolvedProgress(
            for: progress,
            itemCurrentTime: item.currentTime,
            itemDuration: item.duration,
            itemUpdatedAtMilliseconds: item.updatedAt)
        return SharedLibrary.PinnableBook(
            id: item.id,
            title: item.title,
            // Non-optional, and already falls back to "Unknown Author" itself — so a book
            // with no author metadata reads the same in the widget's picker as it does
            // everywhere else in the app, rather than showing a blank subtitle.
            author: item.authorName,
            currentTime: resolved.currentTime,
            duration: resolved.duration,
            updatedAt: resolved.updatedAt)
    }

    /// Position, length and freshness stamp for one published book.
    struct ResolvedProgress: Equatable {
        var currentTime: Double
        var duration: Double
        var updatedAt: Date
    }

    /// W2 (REVIEW_2026-09-04_UI.md Pass 4). Pure, so the three rules below are testable
    /// without a live shelf response:
    ///
    /// - **Position.** The side progress map wins when the caller supplies one — it is the
    ///   authority (re-fetched from `getCurrentUser` moments earlier) and the shelf entity
    ///   simply has nothing. Falls back to the item's own value, which is what an Up Next
    ///   book — fetched whole, progress included — carries.
    /// - **Duration.** `media.duration` first, since it is the book's true length, then the
    ///   progress record's copy. Publishing `0` here would collapse `PinnableBook.progress`
    ///   to zero even with a correct position, which is the same empty bar by another road.
    /// - **Stamp.** Derived from the data, never `Date()`. Stamping it made every republish
    ///   differ from the last, which silently defeated `commit`'s `previous != payload`
    ///   guard — the whole point of which is to *not* ask WidgetKit for a reload on every
    ///   pull-to-refresh, against a budget WidgetKit rate-limits. `lastUpdate`/`updatedAt`
    ///   are both epoch **milliseconds** in Audiobookshelf (cf. `LibraryViewModel`'s
    ///   30-day smart filter, which divides by 1000 for the same reason).
    static func resolvedProgress(
        for progress: MediaProgress?,
        itemCurrentTime: Double,
        itemDuration: Double,
        itemUpdatedAtMilliseconds: Int?
    ) -> ResolvedProgress {
        let currentTime = progress?.currentTime ?? itemCurrentTime
        let duration = itemDuration > 0 ? itemDuration : (progress?.duration ?? 0)
        let stamp: Date
        if let lastUpdate = progress?.lastUpdate, lastUpdate > 0 {
            stamp = Date(timeIntervalSince1970: Double(lastUpdate) / 1000)
        } else if let itemUpdatedAtMilliseconds, itemUpdatedAtMilliseconds > 0 {
            stamp = Date(timeIntervalSince1970: Double(itemUpdatedAtMilliseconds) / 1000)
        } else {
            // Nothing to date it by. `.distantPast` rather than `Date()` so it stays
            // stable across republishes — an unknown stamp must not be a change.
            stamp = .distantPast
        }
        return ResolvedProgress(
            currentTime: max(currentTime, 0),
            duration: max(duration, 0),
            updatedAt: stamp)
    }

    private static func commit(_ payload: SharedLibrary.Payload) {
        let previous = SharedLibrary.read()
        SharedLibrary.write(payload)
        SharedLibrary.pruneCovers(keeping: Set(payload.books.map(\.id)))
        fetchMissingCovers(for: payload.books)
        // Only nudge WidgetKit when the pickable set actually changed — `publishContinue
        // Listening` runs on every personalized-view load, including pull-to-refresh, and
        // WidgetKit rate-limits reload requests.
        //
        // W2 (REVIEW_2026-09-04_UI.md Pass 4): this comparison was dead. `PinnableBook` is
        // `Equatable` over all its fields including `updatedAt`, and `pinnable` stamped
        // that with `Date()` on every call — so `previous != payload` was true every time
        // and the guard reloaded unconditionally. `resolvedProgress` derives the stamp
        // from the data instead, which is what makes this line mean something.
        if previous != payload {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Fetches and stores a cover for any published book that doesn't have one yet.
    /// Best-effort and fire-and-forget: a book with no cover file renders the same
    /// placeholder the widget already shows when the now-playing cover is missing.
    ///
    /// Fix 9 (REVIEW-2026-09-09.md): the loop body used to run on the main actor. This
    /// type is `@MainActor` and the `Task { }` here inherited it — so a blocking
    /// `DiskCoverCache` read, a full JPEG decode, a `preparingThumbnail` resample, a
    /// re-encode and an App Group file write happened on the main thread, per missing
    /// cover, on every personalized-view load including pull-to-refresh. (The trailing
    /// `reloadAllTimelines()` was itself the evidence that this was *believed* to be
    /// off-main.) `Task.detached` puts all of it on the cooperative pool; the only hop
    /// back is for WidgetKit.
    ///
    /// Fix 10 (same review, CarPlay/Widgets pass): that reload was also unconditional, so
    /// every pull-to-refresh asked WidgetKit for a reload even when nothing was fetched —
    /// which defeated `commit`'s `previous != payload` guard, whose entire purpose is to
    /// stay inside WidgetKit's rate-limited reload budget. Now it only fires when at
    /// least one cover was actually written, i.e. when the widget genuinely has something
    /// new to draw.
    ///
    /// Batch 315 (cover-versioning fix): "missing" now also means "published at an older
    /// cover version than the server currently reports". Before this, a cover replaced on
    /// the server never reached the widget because the file for that id already existed.
    /// The version a cover was *published at* is remembered here, app-side, in
    /// `UserDefaults` (`publishedCoverVersionsKey`) — the widget never needs it, so
    /// `SharedLibrary.PinnableBook` is unchanged. The current version comes from
    /// `CoverVersions` (populated as `LibraryItem`s decode).
    private static let publishedCoverVersionsKey = "shelfhead_widgetPublishedCoverVersions"

    private static func publishedCoverVersions() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: publishedCoverVersionsKey) as? [String: Int]) ?? [:]
    }

    /// Pure: should this book's widget cover be (re)fetched? Missing file -> yes. Present
    /// file with no known server version -> no (nothing to compare against). Present file
    /// whose published version is unknown or older than the server's -> yes.
    nonisolated static func needsCoverRefresh(hasCover: Bool, publishedVersion: Int?, currentVersion: Int?) -> Bool {
        guard hasCover else { return true }
        guard let currentVersion else { return false }
        guard let publishedVersion else { return true }
        return currentVersion > publishedVersion
    }

    private static func fetchMissingCovers(for books: [SharedLibrary.PinnableBook]) {
        let published = publishedCoverVersions()
        let missing = books.filter { book in
            needsCoverRefresh(hasCover: SharedLibrary.hasCover(for: book.id),
                              publishedVersion: published[book.id],
                              currentVersion: CoverVersions.version(for: book.id))
        }
        guard !missing.isEmpty else { return }
        // Resolved here, on the main actor, because `shelfCoverURL` is `@MainActor` (it
        // reads `DownloadManager`'s downloaded-items state). It's pure string work plus a
        // dictionary hit; what follows it is the expensive part, and the detached task
        // below is handed nothing but plain values.
        let targets: [(id: String, url: URL, version: Int?)] = missing.compactMap { book in
            shelfCoverURL(itemId: book.id, width: 300).map { (id: book.id, url: $0, version: CoverVersions.version(for: book.id)) }
        }
        guard !targets.isEmpty else { return }
        // Same reason: `coverPixelSize`/`coverCompressionQuality` are members of this
        // `@MainActor` type, so they're read once here rather than hopping per book.
        let pixelSize = coverPixelSize
        let quality = coverCompressionQuality
        Task.detached(priority: .utility) {
            var wroteAnyCover = false
            var written: [String: Int] = [:]
            for target in targets {
                guard let data = await CoverImageCache.coverData(for: target.url),
                      let image = UIImage(data: data) else { continue }
                let thumbnail = image.preparingThumbnail(of: pixelSize) ?? image
                guard let jpeg = thumbnail.jpegData(compressionQuality: quality) else { continue }
                SharedLibrary.writeCover(jpeg, for: target.id)
                if let version = target.version { written[target.id] = version }
                wroteAnyCover = true
            }
            guard wroteAnyCover else { return }
            // `let` snapshot: a `var` captured by the main-actor closure is a Swift 6
            // error ("reference to captured var in concurrently-executing code").
            let writtenVersions = written
            await MainActor.run {
                if !writtenVersions.isEmpty {
                    var versions = publishedCoverVersions()
                    versions.merge(writtenVersions) { _, new in new }
                    UserDefaults.standard.set(versions, forKey: publishedCoverVersionsKey)
                }
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
