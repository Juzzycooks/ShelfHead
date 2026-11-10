import Foundation

// MARK: - The Shelf (Batch 411, docs/design/watch-redesign-2026-10-21.md)

/// One book as the Shelf shows it, whichever list it came from.
nonisolated struct WatchShelfBook: Equatable, Sendable, Identifiable {
    let itemId: String
    let title: String
    let author: String
    /// 0...1
    let progress: Double
    /// The phone's mirror carries cover bytes; everything else loads by item id.
    var coverData: Data? = nil

    var id: String { itemId }
}

/// What a sleeve is, and so what tapping it does.
nonisolated enum WatchShelfSleeveKind: Equatable, Sendable {
    /// The book loaded on the iPhone or on this Watch. A tap shows Now Playing without
    /// restarting it.
    case current(source: WatchBookPlayTarget, isPlaying: Bool)
    /// Any other book. A tap plays it where `target` says; `isAvailable` is false when
    /// that place can't take it right now (the iPhone is out of reach, or the Watch would
    /// have to stream without a session of its own).
    case book(target: WatchBookPlayTarget, isAvailable: Bool)
    /// The last sleeve: the full library and search.
    case browse
    /// The only sleeve on a Watch with no sign-in, no phone and no downloads.
    case setup
}

nonisolated struct WatchShelfSleeve: Equatable, Sendable, Identifiable {
    let id: String
    let kind: WatchShelfSleeveKind
    let book: WatchShelfBook?

    static let browseId = "shelf.browse"
    static let setupId = "shelf.setup"

    /// The source glyph under the cover. Dimmed sleeves get the crossed-out phone, the one
    /// reason a sleeve can't play.
    var sourceSystemImage: String? {
        switch kind {
        case .current(let source, _):
            return source.systemImage
        case .book(let target, let isAvailable):
            return isAvailable ? target.systemImage : "iphone.slash"
        case .browse, .setup:
            return nil
        }
    }

    var isAvailable: Bool {
        if case .book(_, let isAvailable) = kind { return isAvailable }
        return true
    }
}

/// Everything the Shelf knows, gathered by `WatchShelfView` from both stacks.
nonisolated struct WatchShelfInput: Equatable, Sendable {
    /// The iPhone's book, only when its snapshot is fresh and has an item.
    var phoneCurrent: WatchShelfBook?
    var phoneIsPlaying = false
    /// The book loaded in this Watch's own engine.
    var watchCurrent: WatchShelfBook?
    var watchIsPlaying = false
    /// `/api/me/items-in-progress` for the selected library, newest first (needs a Watch
    /// session).
    var serverInProgress: [WatchShelfBook] = []
    /// Part-played books from the iPhone's Recently Added mirror: the in-progress source a
    /// Watch without its own sign-in still has.
    var mirroredInProgress: [WatchShelfBook] = []
    /// Finished downloads on this Watch, in shelf order (`orderedDownloads`).
    var downloads: [WatchShelfBook] = []
    var isStandaloneMode = false
    var phoneIsReachable = false
    var hasWatchSession = false
}

nonisolated enum WatchShelf {
    /// The user's decision (21 October): up to 10 books, then the Browse Library sleeve.
    static let maxBooks = 10

    /// Order: what's loaded (this Watch's book first when it's the player), then in
    /// progress on the server, then the iPhone's part-played mirror, then downloads.
    /// De-duplicated by item id, first appearance wins; capped at `maxBooks`.
    static func sleeves(for input: WatchShelfInput) -> [WatchShelfSleeve] {
        var seen = Set<String>()
        var sleeves: [WatchShelfSleeve] = []
        let downloadedIds = Set(input.downloads.map(\.itemId))

        func appendCurrent(_ book: WatchShelfBook?, source: WatchBookPlayTarget, isPlaying: Bool) {
            guard let book, !book.itemId.isEmpty, seen.insert(book.itemId).inserted else { return }
            sleeves.append(WatchShelfSleeve(id: book.itemId, kind: .current(source: source, isPlaying: isPlaying), book: book))
        }

        let watchFirst = input.isStandaloneMode || input.watchIsPlaying
        if watchFirst {
            appendCurrent(input.watchCurrent, source: .watch, isPlaying: input.watchIsPlaying)
            appendCurrent(input.phoneCurrent, source: .iPhone, isPlaying: input.phoneIsPlaying)
        } else {
            appendCurrent(input.phoneCurrent, source: .iPhone, isPlaying: input.phoneIsPlaying)
            appendCurrent(input.watchCurrent, source: .watch, isPlaying: input.watchIsPlaying)
        }

        for book in input.serverInProgress + input.mirroredInProgress + input.downloads {
            guard sleeves.count < maxBooks else { break }
            guard !book.itemId.isEmpty, seen.insert(book.itemId).inserted else { continue }
            let isDownloaded = downloadedIds.contains(book.itemId)
            let target = WatchBookPlayOptions.decide(isDownloaded: isDownloaded,
                                                     isStandaloneMode: input.isStandaloneMode,
                                                     phoneIsReachable: input.phoneIsReachable).primary
            let isAvailable: Bool
            switch target {
            case .watch: isAvailable = isDownloaded || input.hasWatchSession
            case .iPhone: isAvailable = input.phoneIsReachable
            }
            sleeves.append(WatchShelfSleeve(id: book.itemId, kind: .book(target: target, isAvailable: isAvailable), book: book))
        }
        sleeves = Array(sleeves.prefix(maxBooks))

        if sleeves.isEmpty && !input.hasWatchSession && !input.phoneIsReachable {
            return [WatchShelfSleeve(id: WatchShelfSleeve.setupId, kind: .setup, book: nil)]
        }
        sleeves.append(WatchShelfSleeve(id: WatchShelfSleeve.browseId, kind: .browse, book: nil))
        return sleeves
    }

    /// Downloads in shelf order: part-played ones by last play (newest first), then
    /// unstarted ones by download date (newest first). Finished downloads are left off;
    /// they're still in Downloads. Same "finished" rule as the cold-launch resume pick.
    static func orderedDownloads(_ inputs: [WatchResumeInput]) -> [WatchShelfBook] {
        func isFinished(_ input: WatchResumeInput) -> Bool {
            guard let position = input.lastPosition, input.duration > 0 else { return false }
            return input.duration - position <= WatchResumeCandidate.finishedTailSeconds
        }
        func book(_ input: WatchResumeInput) -> WatchShelfBook {
            let progress = (input.duration > 0 ? (input.lastPosition ?? 0) / input.duration : 0)
            return WatchShelfBook(itemId: input.itemId, title: input.title, author: input.author,
                                  progress: min(max(progress, 0), 1))
        }
        let started = inputs
            .filter { ($0.lastPosition ?? 0) > 0 && !isFinished($0) }
            .sorted { a, b in
                let at = a.lastPlayedAt ?? 0, bt = b.lastPlayedAt ?? 0
                return at == bt ? a.downloadedAt > b.downloadedAt : at > bt
            }
        let unstarted = inputs
            .filter { ($0.lastPosition ?? 0) <= 0 }
            .sorted { $0.downloadedAt > $1.downloadedAt }
        return (started + unstarted).map(book)
    }

    /// Part-played books in the iPhone's mirror. Within 1% of the end counts as finished,
    /// the same line `BookSummaryRow` draws its Finished badge at.
    static func mirroredInProgress(_ books: [WatchBookSummary]) -> [WatchShelfBook] {
        books.compactMap { book in
            guard let progress = book.progress, progress > 0, progress < 0.99 else { return nil }
            return WatchShelfBook(itemId: book.id, title: book.title, author: book.author,
                                  progress: progress, coverData: book.coverData)
        }
    }

    /// "42%", the figure beside the ring. Whole percent, rounded down so a book is never
    /// shown as 100% before it's finished.
    static func percentText(_ progress: Double) -> String {
        let clamped = min(max(progress.isFinite ? progress : 0, 0), 1)
        return (Double(Int(clamped * 100)) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The cover's side on a sleeve: about 70% of the width (the brief), but never so tall
    /// that the title and ring under it leave the screen. Half the width at accessibility
    /// text sizes, where the title needs the room.
    static let reservedHeight: CGFloat = 96
    static let minimumCoverSide: CGFloat = 56

    static func coverSide(screenWidth: CGFloat, screenHeight: CGFloat, isAccessibilitySize: Bool) -> CGFloat {
        let widthShare: CGFloat = isAccessibilitySize ? 0.5 : 0.7
        let byWidth = (screenWidth * widthShare).rounded(.down)
        let byHeight = (screenHeight - reservedHeight).rounded(.down)
        return max(minimumCoverSide, min(byWidth, byHeight))
    }
}
