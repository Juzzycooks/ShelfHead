import Foundation
import CarPlay
import UIKit

// =============================================================================
// ShelfHead • CarPlay cover-art loader
// =============================================================================

/// Loads cover artwork for a `CPListItem`, reusing the app's `shelfCoverURL`
/// (offline covers + bearer-header auth via `authorizedCoverRequest`) and `CoverImageCache`.
///
/// Safe with missing artwork: the completion simply isn't called, leaving whatever
/// image the row was built with — see `placeholder`, C10 below.
enum CarPlayImageLoader {
    /// CarPlay list thumbnails are small; 200 px keeps memory and bandwidth low.
    static let coverWidth = 200

    /// C10 (REVIEW_2026-09-04_UI.md Pass 4): rows used to build with NO image at all,
    /// and this loader's failure path was a bare `return` that never called the
    /// completion — so a list rendered text-only and covers popped in one at a time as
    /// each request landed, which reads as broken rather than loading, and changes
    /// while the driver is looking at it. Every row is now built with this placeholder
    /// (`CarPlayCoordinator.makeBookRow`) and `loadCover` replaces it once real art
    /// lands. Same glyph the widget uses for its own no-cover state
    /// (`ShelfHeadWidgets.swift:418` — `book.closed.fill`), so a book without art reads
    /// the same way in the car as it does on the Home Screen. Sized off
    /// `CPListItem.maximumImageSize` (the system's real row-image slot, not a guessed
    /// pixel value) rather than drawing a filled square in an unverified color — this
    /// batch has no way to see the result on a real head unit, and a plain SF Symbol at
    /// the right scale is the safer default than a custom composition that might read
    /// wrong at car-display contrast. **[device check]** confirm this doesn't look
    /// undersized/oversized against a real cover at `CPListItem.maximumImageSize`.
    static let placeholder: UIImage = {
        let size = CPListItem.maximumImageSize
        let pointSize = max(min(size.width, size.height) * 0.55, 1)
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: "book.closed.fill", withConfiguration: config) ?? UIImage()
    }()

    /// HIG audit 2026-09-17 L16b: the Chapters list's `CPListTemplateDetailsHeader`
    /// thumbnail (`CarPlayCoordinator.attachChaptersHeader`) used `placeholder` above,
    /// which is sized off `CPListItem.maximumImageSize` — the ROW slot, confirmed
    /// smaller than the header slot per the in-code `[device check]` note this
    /// replaces. Checked both `CPListTemplate` and `CPListImageRowItem` (developer.apple
    /// .com/documentation/carplay/{cplisttemplate,cplistimagerowitem}) for a
    /// header/large-image size constant: neither exposes one. `CPThumbnailImage
    /// .maximumImageSize(forAspectRatio:)` (developer.apple.com/documentation/carplay/
    /// cpthumbnailimage/maximumimagesize(foraspectratio:)) is the one Apple does
    /// publish for this exact slot — "recommended maximum image size for a
    /// CPThumbnailImage" — but it's iOS 27+ only, same gate already used for the real
    /// cover fetch in `loadChaptersHeaderCover`. Below that OS (26.4, where
    /// `CPListTemplateDetailsHeader` itself first exists), Apple documents no header
    /// size constant, so this doubles the row slot — the same "400 px is double the
    /// 200 px row width" fallback `loadChaptersHeaderCover` already uses for the real
    /// cover — rather than inventing a new heuristic, and renders it `compatibleWith:
    /// carTraitCollection` (`CPInterfaceController.carTraitCollection`, documented:
    /// "use this trait collection to derive metrics, such as display scale, for your
    /// CarPlay templates... rather than the scale of the user's iPhone screen") so the
    /// glyph rasterizes for the car display's scale, not the phone process's.
    static func headerPlaceholder(carTraitCollection: UITraitCollection?) -> UIImage {
        var size = CPListItem.maximumImageSize
        if #available(iOS 27.0, *) {
            let recommended = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
            if recommended.width > 0, recommended.height > 0 {
                size = recommended
            } else {
                size = CGSize(width: size.width * 2, height: size.height * 2)
            }
        } else {
            size = CGSize(width: size.width * 2, height: size.height * 2)
        }
        let pointSize = max(min(size.width, size.height) * 0.55, 1)
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let base = UIImage(systemName: "book.closed.fill", compatibleWith: carTraitCollection)
        return base?.withConfiguration(config) ?? placeholder
    }

    /// `@MainActor`: calls `shelfCoverURL`, which is now `@MainActor` too. Its only
    /// caller, `CarPlayCoordinator`, is already `@MainActor`.
    ///
    /// Batch 327: `width` is now a parameter, defaulted to `coverWidth` so the existing
    /// row call site (`CarPlayCoordinator.makeBookRow`) is unchanged. The iOS 26.4
    /// `CPListTemplateDetailsHeader` on the Chapters list needs a much bigger cover than
    /// a 200 px list thumbnail — see `CarPlayCoordinator.loadChaptersHeaderCover`, which
    /// asks iOS 27 for the size the thumbnail pipeline actually wants. A server cover is
    /// cached per width (`shelfCoverURL` puts `?width=` in the URL, and the cache is keyed
    /// on the URL), so a header request never evicts or downgrades the row-sized entry; a
    /// DOWNLOADED book's cover is one local file at whatever size it was written, which
    /// `shelfCoverURL` returns regardless of `width` — the header then gets the same
    /// bitmap the rows do, which is correct, just not header-sized.
    @MainActor
    static func loadCover(itemId: String, width: Int = CarPlayImageLoader.coverWidth,
                          completion: @escaping (UIImage) -> Void) {
        guard let url = shelfCoverURL(itemId: itemId, width: width) else { return }

        if let cached = CoverImageCache.shared.object(forKey: url as NSURL) {
            completion(cached)
            return
        }

        Task.detached(priority: .utility) {
            guard let image = await fetchImage(url: url) else { return }
            CoverImageCache.shared.setObject(image, forKey: url as NSURL, cost: CoverImageCache.decodedCost(of: image))
            await MainActor.run { completion(image) }
        }
    }

    /// C10 (REVIEW_2026-09-04_UI.md Pass 4): this was a bare `URLSession.shared.data(for:)`
    /// — the bypass CLAUDE.md names as a known bug class (no 401 refresh-and-retry, so
    /// behind a reverse proxy with short-lived tokens covers never arrived). It now goes
    /// through `AudiobookshelfAPI.authorizedData(for:)`, the API type's own contract for
    /// absolute URLs: custom headers plus one refresh and one retry on 401, the same code
    /// path `send` uses. `file://` covers for downloaded books take the local branch there.
    private static func fetchImage(url: URL) async -> UIImage? {
        guard let data = try? await AudiobookshelfAPI.shared.authorizedData(for: url) else { return nil }
        return UIImage(data: data)
    }
}
