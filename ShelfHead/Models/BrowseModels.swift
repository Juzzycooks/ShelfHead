import Foundation

// MARK: - Series

struct Series: Codable, Identifiable {
    let id: String
    let name: String?
    let books: [LibraryItem]?
    let addedAt: Int?
    let totalDuration: Double?

    var displayName: String { name ?? String(localized: "Unknown Series", comment: "Fallback name for a series the server returned without a name") }
    var bookCount: Int { books?.count ?? 0 }
}

struct SeriesResponse: Codable {
    let results: [Series]
    let total: Int?
}

// MARK: - Filter data (authors, genres, etc. for a library)

struct NamedEntity: Codable, Identifiable {
    let id: String
    let name: String
}

struct LibraryFilterData: Codable {
    let authors: [NamedEntity]?
    let genres: [String]?
    let tags: [String]?
    let series: [NamedEntity]?
    let narrators: [String]?
    let languages: [String]?
}

struct LibraryDataResponse: Codable {
    let filterdata: LibraryFilterData?
}

// MARK: - Auth sessions (Audiobookshelf 2.36+)

struct AuthSessionsPage: Codable {
    let total: Int
    let page: Int
    let sessions: [AuthSession]
}

struct AuthSession: Codable, Identifiable {
    let id: String
    let ipAddress: String?
    let userAgent: String?
    let deviceInfo: AuthSessionDeviceInfo?
    let createdAt: Int?
    let updatedAt: Int?
    let current: Bool?
}

struct AuthSessionDeviceInfo: Codable {
    let deviceType, model, vendor, osName, osVersion, browserName, clientName: String?
}

extension AuthSession {
    var displayName: String {
        Self.displayName(clientName: deviceInfo?.clientName, vendor: deviceInfo?.vendor, model: deviceInfo?.model, userAgent: userAgent)
    }

    var symbolName: String {
        Self.symbolName(deviceType: deviceInfo?.deviceType, model: deviceInfo?.model, userAgent: userAgent)
    }

    var isThisDevice: Bool { current ?? false }

    /// Pure so the naming precedence can be pinned with a regression test
    /// (see `ServerSessionLabelTests`) instead of only exercised via a live server.
    static func displayName(clientName: String?, vendor: String?, model: String?, userAgent: String?) -> String {
        if let clientName, !clientName.trimmingCharacters(in: .whitespaces).isEmpty {
            return clientName
        }
        let vendorModel = [vendor, model].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !vendorModel.isEmpty {
            return vendorModel
        }
        if let userAgent, !userAgent.isEmpty {
            let cutoff = userAgent.firstIndex(where: { $0 == "(" || $0 == "/" }) ?? userAgent.endIndex
            let prefix = userAgent[userAgent.startIndex..<cutoff].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { return prefix }
        }
        return String(localized: "Unknown device", comment: "Fallback name for a signed-in session whose device the server did not identify")
    }

    static func symbolName(deviceType: String?, model: String?, userAgent: String?) -> String {
        if let model {
            if model.contains("iPhone") { return "iphone" }
            if model.contains("iPad") { return "ipad" }
            if model.contains("Watch") { return "applewatch" }
        }
        if deviceType == "desktop" || (userAgent?.contains("Mozilla") ?? false) {
            return "desktopcomputer"
        }
        return "questionmark.circle"
    }
}

// MARK: - Backups (admin)

struct BackupsResponse: Codable {
    let backups: [ServerBackup]
    let backupLocation: String?
}

struct ServerBackup: Codable, Identifiable {
    let id: String
    let filename: String?
    let fileSize: Int?
    let createdAt: Int?
    let serverVersion: String?
}

// MARK: - Listening Stats

struct ListeningStats: Codable {
    let totalTime: Double?          // seconds
    let today: Double?              // seconds
    let days: [String: Double]?     // "YYYY-MM-DD" -> seconds
}

extension ListeningStats {
    /// Pre-built day-key formatters, shared rather than constructed per call.
    /// `DateFormatter` is expensive to create, and `currentStreak`/`bestStreak`/
    /// `monthTotal` each used to allocate one every time they were read — which was on
    /// the Listening tab's `body` path (see `StatsDateFormatters` in StatsView.swift for
    /// the matching change on that side).
    ///
    /// Safe to share: a `DateFormatter` is thread-safe to *use* as long as nobody
    /// reconfigures it after construction, so these are never mutated below. The one
    /// tradeoff is that locale/time zone are snapshotted at first use rather than read
    /// per call — irrelevant for these fixed-pattern parses in practice, but it's why
    /// `monthTotal`'s injectable-calendar path deliberately does NOT use a shared one.
    // Critique 2026-10-06 (harden): was an unconfigured formatter, which on a Buddhist/Japanese-
    // calendar device writes "2569-10-06" and never matches the server's Gregorian keys.
    private static let dayKey: DateFormatter = DayKey.shared

    /// `monthTotal`'s default (`Calendar.current`) path only — the injected-calendar
    /// path builds its own, because reconfiguring a shared formatter isn't thread-safe.
    // Critique 2026-10-06 (harden): server day keys are Gregorian, so parse them with the
    // POSIX/Gregorian `DayKey` formatter, not the device calendar.
    private static let monthDayKeyCurrent: DateFormatter = DayKey.makeFormatter(timeZone: Calendar.current.timeZone)

    /// Consecutive days with listening up to today (today counts if >0; otherwise
    /// counting starts from yesterday so the streak isn't lost before you listen).
    var currentStreak: Int {
        guard let days else { return 0 }
        let f = Self.dayKey
        var streak = 0
        var date = Date()
        if (days[f.string(from: date)] ?? 0) <= 0 {
            date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        }
        while (days[f.string(from: date)] ?? 0) > 0 {
            streak += 1
            date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return streak
    }

    /// Total listening in the calendar month containing `date` (default: now), summed
    /// from the per-day map. G7 (REVIEW_2026-09-04_UI.md): backs the Listening tab's
    /// "This Month" tile. Pure so it can be pinned by a test; `calendar` is injectable
    /// for the same reason.
    func monthTotal(containing date: Date = Date(), calendar: Calendar = .current) -> Double {
        guard let days, let month = calendar.dateInterval(of: .month, for: date) else { return 0 }
        // Shared formatter on the default path; an injected calendar (which is what the
        // unit tests pin) gets a fresh one, since configuring the shared instance from a
        // caller-supplied calendar would mutate state other callers are reading.
        let f: DateFormatter
        if calendar == Calendar.current {
            f = Self.monthDayKeyCurrent
        } else {
            f = DayKey.makeFormatter(timeZone: calendar.timeZone)
        }
        return days.reduce(0) { sum, entry in
            // Half-open on purpose: `DateInterval.contains` is inclusive of `end`, which
            // is midnight on the 1st of the *next* month — exactly the day key that must
            // not count. The unit test caught this on the first run.
            guard let day = f.date(from: entry.key),
                  day >= month.start, day < month.end else { return sum }
            return sum + max(entry.value, 0)
        }
    }

    /// Longest run of consecutive listening days on record.
    var bestStreak: Int {
        guard let days else { return 0 }
        let f = Self.dayKey
        let cal = Calendar.current
        let active = Set(days.filter { $0.value > 0 }
            .keys.compactMap { f.date(from: $0) }
            .map { cal.startOfDay(for: $0) })
        var best = 0
        for day in active {
            // Only start counting from the first day of a run.
            if let prev = cal.date(byAdding: .day, value: -1, to: day), active.contains(prev) { continue }
            var length = 1
            var cursor = day
            while let next = cal.date(byAdding: .day, value: 1, to: cursor), active.contains(next) {
                length += 1
                cursor = next
            }
            best = max(best, length)
        }
        return best
    }
}

// MARK: - Listening Sessions (history)

struct ListeningSessionsResponse: Decodable {
    let total: Int?
    let numPages: Int?
    let page: Int?
    let itemsPerPage: Int?
    let sessions: [ListeningSession]

    enum CodingKeys: String, CodingKey { case total, numPages, page, itemsPerPage, sessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try? c.decode(Int.self, forKey: .total)
        numPages = try? c.decode(Int.self, forKey: .numPages)
        page = try? c.decode(Int.self, forKey: .page)
        itemsPerPage = try? c.decode(Int.self, forKey: .itemsPerPage)
        // Skip any malformed session rather than failing the whole history response.
        sessions = (try? c.decode(LossyArray<ListeningSession>.self, forKey: .sessions))?.elements ?? []
    }
}

struct ListeningSession: Codable, Identifiable {
    let id: String
    let libraryItemId: String?
    let displayTitle: String?
    let displayAuthor: String?
    let duration: Double?          // total book duration, seconds
    let timeListening: Double?     // seconds listened in this session
    let currentTime: Double?       // position at end of session, seconds
    let startedAt: Double?         // epoch millis
    let updatedAt: Double?         // epoch millis

    /// Best-effort session end time from the epoch-millis timestamp.
    var date: Date? {
        guard let ms = updatedAt ?? startedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

// MARK: - Sorting & Filtering options

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "__recentlyPlayed"   // client-side: uses items-in-progress (recency order)
    case title = "media.metadata.title"
    case author = "media.metadata.authorName"
    case addedAt = "addedAt"
    case duration = "media.duration"

    var id: String { rawValue }

    /// True for the special client-side "Recently Played" ordering (not a server sort key).
    var isRecentlyPlayed: Bool { self == .recent }

    var label: String {
        switch self {
        case .recent: return String(localized: "Recently Played", comment: "Library sort option")
        case .title: return String(localized: "Title", comment: "Library sort option: by book title")
        case .author: return String(localized: "Author", comment: "Library sort option: by author name")
        case .addedAt: return String(localized: "Date Added", comment: "Library sort option")
        case .duration: return String(localized: "Duration", comment: "Library sort option: by book length")
        }
    }
}

enum LibraryProgressFilter: String, CaseIterable, Identifiable {
    case all
    case notStarted = "not-started"
    case inProgress = "in-progress"
    case finished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "All", comment: "Library progress filter: no filtering by progress")
        case .notStarted: return String(localized: "Unplayed", comment: "Library progress filter: books with no listening progress")
        case .inProgress: return String(localized: "In Progress", comment: "Library progress filter: books that are started but not finished")
        case .finished: return String(localized: "Finished", comment: "Library progress filter: books marked finished")
        }
    }

    /// The encoded `filter` query value, or nil for "all".
    var filterValue: String? {
        guard self != .all else { return nil }
        return APIFilter.encode(group: "progress", value: rawValue)
    }
}

/// Ready-made "smart collections" — cross-cutting views over the whole library that
/// aren't expressible as a single server-side sort/filter combination (they mix
/// progress, duration, series membership, favourites, and cover presence). Unlike
/// `LibraryProgressFilter`, these are evaluated client-side against a bulk-fetched
/// snapshot of the library (see `LibraryViewModel.selectSmartFilter`), since criteria
/// like "no progress in 30 days" or "unplayed in a started series" need to inspect
/// every book at once rather than filtering one page of a paginated request.
enum SmartFilter: String, CaseIterable, Identifiable {
    case downloadedUnfinished
    case nearlyFinished
    case stale
    case shortListens
    case longListens
    case unplayedInStartedSeries
    case missingCovers
    case favoriteNewArrivals

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downloadedUnfinished: return String(localized: "Downloaded, Not Finished", comment: "Smart filter name")
        case .nearlyFinished: return String(localized: "Nearly Finished", comment: "Smart filter name")
        case .stale: return String(localized: "No Progress in 30 Days", comment: "Smart filter name")
        case .shortListens: return String(localized: "Short Listens (< 2h)", comment: "Smart filter name: books shorter than two hours")
        case .longListens: return String(localized: "Long Listens (> 20h)", comment: "Smart filter name: books longer than twenty hours")
        case .unplayedInStartedSeries: return String(localized: "Unplayed in a Started Series", comment: "Smart filter name")
        case .missingCovers: return String(localized: "Missing Covers", comment: "Smart filter name: books without cover art")
        case .favoriteNewArrivals: return String(localized: "New From Favourites", comment: "Smart filter name: recent additions by starred authors or narrators")
        }
    }

    var icon: String {
        switch self {
        case .downloadedUnfinished: return "arrow.down.circle"
        case .nearlyFinished: return "flag.checkered"
        case .stale: return "clock.badge.exclamationmark"
        case .shortListens: return "hare"
        case .longListens: return "tortoise"
        case .unplayedInStartedSeries: return "square.stack.3d.up.badge.a"
        case .missingCovers: return "photo.badge.exclamationmark"
        case .favoriteNewArrivals: return "star.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .downloadedUnfinished: return String(localized: "On your device, but you haven't finished them", comment: "Smart filter description")
        case .nearlyFinished: return String(localized: "90% or further, not yet marked finished", comment: "Smart filter description")
        case .stale: return String(localized: "Started, but no progress update in over a month", comment: "Smart filter description")
        case .shortListens: return String(localized: "Quick books under two hours", comment: "Smart filter description")
        case .longListens: return String(localized: "Big commitments over twenty hours", comment: "Smart filter description")
        case .unplayedInStartedSeries: return String(localized: "Books in a series you've started, but haven't opened", comment: "Smart filter description")
        case .missingCovers: return String(localized: "Books with no cover art from your server", comment: "Smart filter description")
        case .favoriteNewArrivals: return String(localized: "Added in the last 30 days by an author or narrator you've starred", comment: "Smart filter description")
        }
    }
}

// MARK: - Collections & Playlists

struct BookCollection: Codable, Identifiable {
    let id: String
    let name: String?
    let books: [LibraryItem]?

    var displayName: String { name ?? String(localized: "Untitled Collection", comment: "Fallback name for a collection without a name") }
    var bookCount: Int { books?.count ?? 0 }
}

struct CollectionsResponse: Codable {
    let collections: [BookCollection]
}

struct Playlist: Codable, Identifiable {
    let id: String
    let name: String?
    let items: [PlaylistItem]?

    var displayName: String { name ?? String(localized: "Untitled Playlist", comment: "Fallback name for a playlist without a name") }
    var libraryItems: [LibraryItem] { (items ?? []).compactMap { $0.libraryItem } }
}

struct PlaylistItem: Codable {
    let libraryItemId: String?
    let episodeId: String?
    let libraryItem: LibraryItem?
}

struct PlaylistsResponse: Codable {
    let playlists: [Playlist]
}

enum BrowseMode: String, CaseIterable, Identifiable {
    case books = "Books"
    case series = "Series"
    case authors = "Authors"
    case narrators = "Narrators"
    case collections = "Collections"
    case playlists = "Playlists"
    var id: String { rawValue }

    /// The localized scope name. `rawValue` stays the English identifier (never shown).
    var label: String {
        switch self {
        case .books: return String(localized: "Books", comment: "Library browse scope")
        case .series: return String(localized: "Series", comment: "Library browse scope (book series)")
        case .authors: return String(localized: "Authors", comment: "Library browse scope")
        case .narrators: return String(localized: "Narrators", comment: "Library browse scope")
        case .collections: return String(localized: "Collections", comment: "Library browse scope")
        case .playlists: return String(localized: "Playlists", comment: "Library browse scope")
        }
    }

    var icon: String {
        switch self {
        case .books: return "books.vertical"
        case .series: return "square.stack.3d.up"
        case .authors: return "person.2"
        case .narrators: return "mic"
        case .collections: return "rectangle.stack"
        case .playlists: return "music.note.list"
        }
    }
}

/// Helper for Audiobookshelf's `group.base64(value)` filter format.
enum APIFilter {
    static func encode(group: String, value: String) -> String {
        let base64 = Data(value.utf8).base64EncodedString()
        return "\(group).\(base64)"
    }
}

// MARK: - Tolerant decoding for the Collections/Playlists responses

// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): `CollectionsResponse.collections` and
// `PlaylistsResponse.playlists` were plain arrays of records with a required `id`, so a
// single malformed row — one collection whose `id` came back `null`, one playlist row
// carrying an unexpected shape — failed the whole `/api/libraries/<id>/collections` or
// `/playlists` decode and the Library tab's Collections/Playlists mode showed *nothing*.
// Same failure the `/api/me` progress and bookmark arrays had before Batch 310, and the
// same fix: `LossyArray` drops only the row that doesn't parse, and logs which one.
//
// `LossyArray` itself lives in `Models/AudiobookshelfModels.swift` with the rest of the
// tolerant decoding (`User`, `MediaProgress`, `Media.chapters`, `PlaybackSession`);
// these two initializers sit next to the types they decode. Both are `init(from:)` in an
// extension rather than in the struct body, so the memberwise initializers still exist
// and `Encodable` is still synthesized.

extension CollectionsResponse {

    /// Named `LossyKeys` rather than `CodingKeys` so the `Encodable` half of this type
    /// keeps using the keys the compiler synthesizes for it, untouched by this decoder.
    /// Audiobookshelf 2.36 returns the library's collections as a paginated `{ "results": [...] }`;
    /// older servers use `{ "collections": [...] }`. The missing key used to decode to an empty
    /// list, which hid the Library's "More" scopes menu on 2.36. Either key is read now.
    private enum LossyKeys: String, CodingKey { case collections, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LossyKeys.self)
        let key: LossyKeys = c.contains(.collections) ? .collections : .results
        let lossy = (try? c.decodeIfPresent(LossyArray<BookCollection>.self, forKey: key)) ?? nil
        for skip in lossy?.skipped ?? [] {
            ShelfLog.error(.sync, "Dropped collections[\(skip.index)]: \(skip.reason)")
        }
        collections = lossy?.elements ?? []
    }
}

extension PlaylistsResponse {

    /// Same `results` / `playlists` handling as `CollectionsResponse` above.
    private enum LossyKeys: String, CodingKey { case playlists, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LossyKeys.self)
        let key: LossyKeys = c.contains(.playlists) ? .playlists : .results
        let lossy = (try? c.decodeIfPresent(LossyArray<Playlist>.self, forKey: key)) ?? nil
        for skip in lossy?.skipped ?? [] {
            ShelfLog.error(.sync, "Dropped playlists[\(skip.index)]: \(skip.reason)")
        }
        playlists = lossy?.elements ?? []
    }
}

// MARK: - Library page window (Library browse plan §6.2, 2026-10-05)

/// A position-addressed, sparse store of the Books scope's server pages. Pure value type:
/// the view model owns the fetch tasks and calls the mutating helpers as they start, fail,
/// are cancelled or return. Library browse plan §6.2 (2026-10-05).
///
/// Indices are 0-based throughout. Not `nonisolated`: it holds `LibraryItem`, which is
/// main-actor isolated under the target's default isolation.
struct LibraryPageWindow {

    /// What a not-yet-loaded slot is doing. Library browse plan §5 (2026-10-05).
    enum PlaceholderState: Equatable {
        case loading, failed, notRequested
    }

    /// One position in the full-length result list. Library browse plan §6.2 (2026-10-05).
    enum Slot {
        case item(LibraryItem)
        case placeholder(index: Int, state: PlaceholderState)

        var item: LibraryItem? {
            if case .item(let item) = self { return item }
            return nil
        }
    }

    /// Result of `merge`. Library browse plan §6.5 (2026-10-05).
    enum MergeOutcome: Equatable {
        case ok
        /// The server total changed while other pages were loaded: those pages are now stale.
        case totalChanged(old: Int, new: Int)
        /// The page repeated ids already held by another page (an insert shifted a
        /// boundary); the repeats were dropped and the page marked stale.
        case duplicateIds
    }

    static let defaultPageSize = 50
    /// Library browse plan §6.4 (2026-10-05): keep every page up to this many books.
    static let defaultEvictionCeiling = 5_000
    static let defaultEvictionRadius = 10

    let pageSize: Int
    private(set) var total: Int
    private(set) var pages: [Int: [LibraryItem]] = [:]
    private(set) var inFlight: Set<Int> = []
    private(set) var failed: Set<Int> = []
    private(set) var stale: Set<Int> = []

    /// An empty window; `total` is unknown (0) until the first page merges.
    init(pageSize: Int = LibraryPageWindow.defaultPageSize, total: Int = 0) {
        self.pageSize = max(1, pageSize)
        self.total = max(0, total)
    }

    /// A fully loaded window over a local result set (smart filter, downloaded-only,
    /// offline fallback, Recently Played) so slot rendering and the scrubber share one
    /// code path. Library browse plan §6.2 (2026-10-05).
    init(local items: [LibraryItem], pageSize: Int = LibraryPageWindow.defaultPageSize) {
        self.pageSize = max(1, pageSize)
        self.total = items.count
        var start = 0
        var page = 0
        while start < items.count {
            pages[page] = Array(items[start..<min(start + self.pageSize, items.count)])
            start += self.pageSize
            page += 1
        }
    }

    // MARK: Geometry

    var pageCount: Int { total == 0 ? 0 : (total + pageSize - 1) / pageSize }

    func page(containing index: Int) -> Int { max(0, index) / pageSize }

    /// How many items the server should return for `page` at the current total.
    func expectedCount(inPage page: Int) -> Int {
        guard page >= 0, page < pageCount else { return 0 }
        return min(pageSize, total - page * pageSize)
    }

    func isLoaded(page: Int) -> Bool { pages[page] != nil }

    // MARK: Reading

    func slot(at index: Int) -> Slot {
        let page = page(containing: index)
        if index >= 0, let items = pages[page] {
            let offset = index - page * pageSize
            if offset < items.count { return .item(items[offset]) }
        }
        let state: PlaceholderState
        if inFlight.contains(page) { state = .loading }
        else if failed.contains(page) { state = .failed }
        else { state = .notRequested }
        return .placeholder(index: index, state: state)
    }

    /// Every loaded item, ordered by page then position: what `items` returns for readers
    /// that don't care about slots (B-side shelf, `hasUnstartedBooks`).
    var loadedInOrder: [LibraryItem] {
        pages.keys.sorted().flatMap { pages[$0] ?? [] }
    }

    // MARK: Planning

    /// Pages to start fetching now: the pages under `visible` plus `prefetch` on each side,
    /// that are missing or stale and neither in flight nor failed (failed pages wait for an
    /// explicit `retry`). Nearest to the visible range first, then lowest index, capped so
    /// that `inFlight.count + result.count <= maxInFlight`. Library browse plan §6.5 (2026-10-05).
    func pagesToFetch(visible: ClosedRange<Int>, prefetch: Int = 1, maxInFlight: Int = 2) -> [Int] {
        guard pageCount > 0 else { return [] }
        let budget = maxInFlight - inFlight.count
        guard budget > 0 else { return [] }
        let first = page(containing: visible.lowerBound)
        let last = page(containing: visible.upperBound)
        let lo = max(0, first - max(0, prefetch))
        let hi = min(pageCount - 1, last + max(0, prefetch))
        guard lo <= hi else { return [] }
        func distance(_ p: Int) -> Int { p < first ? first - p : (p > last ? p - last : 0) }
        let wanted = (lo...hi).filter { p in
            (pages[p] == nil || stale.contains(p)) && !inFlight.contains(p) && !failed.contains(p)
        }
        let ordered = wanted.sorted { (distance($0), $0) < (distance($1), $1) }
        return Array(ordered.prefix(budget))
    }

    // MARK: Fetch lifecycle

    mutating func markInFlight(_ page: Int) {
        guard page >= 0, page < max(pageCount, 1) else { return }
        inFlight.insert(page)
        failed.remove(page)
    }

    mutating func markFailed(_ page: Int) {
        inFlight.remove(page)
        failed.insert(page)
    }

    /// A cancelled fetch leaves the page a placeholder, not failed. Library browse plan §6.5 (2026-10-05).
    mutating func markCancelled(_ page: Int) {
        inFlight.remove(page)
    }

    mutating func markCancelledAll() {
        inFlight.removeAll()
    }

    /// Clears a page's failed flag so `pagesToFetch` offers it again (tap on a failed placeholder).
    mutating func retry(_ page: Int) {
        failed.remove(page)
    }

    mutating func retryAllFailed() {
        failed.removeAll()
    }

    mutating func markStale(_ page: Int) {
        if pages[page] != nil { stale.insert(page) }
    }

    // MARK: Merging

    /// Stores a fetched page. Total drift and repeated ids are handled per
    /// Library browse plan §6.5 (2026-10-05):
    /// - If `reportedTotal` differs from `total`, the window resizes, pages past the new end
    ///   are dropped, and every other loaded page is marked stale (`.totalChanged`), but only
    ///   when other pages exist; the very first merge just sets the total (`.ok`).
    /// - Ids already held by another non-stale page are dropped from this page and it is
    ///   marked stale (`.duplicateIds`, unless the total also changed).
    @discardableResult
    mutating func merge(page: Int, results: [LibraryItem], reportedTotal: Int) -> MergeOutcome {
        inFlight.remove(page)
        failed.remove(page)
        stale.remove(page)

        let oldTotal = total
        let newTotal = max(0, reportedTotal)
        var outcome = MergeOutcome.ok
        if newTotal != oldTotal {
            total = newTotal
            let count = pageCount
            for key in pages.keys where key >= count { pages[key] = nil }
            inFlight = inFlight.filter { $0 < count }
            failed = failed.filter { $0 < count }
            stale = stale.filter { $0 < count }
            if !pages.isEmpty {
                for key in pages.keys where key != page { stale.insert(key) }
                outcome = .totalChanged(old: oldTotal, new: newTotal)
            }
        }

        guard page >= 0, page < pageCount else { return outcome }

        var held = Set<String>()
        for (key, items) in pages where key != page && !stale.contains(key) {
            for item in items { held.insert(item.id) }
        }
        var seen = Set<String>()
        var kept: [LibraryItem] = []
        var dropped = false
        for item in results {
            if held.contains(item.id) || !seen.insert(item.id).inserted {
                dropped = true
            } else {
                kept.append(item)
            }
        }
        pages[page] = Array(kept.prefix(pageSize))
        if dropped {
            stale.insert(page)
            if outcome == .ok { outcome = .duplicateIds }
        }
        return outcome
    }

    // MARK: Eviction

    /// Library browse plan §6.4 (2026-10-05): up to `ceiling` books everything stays loaded;
    /// above it, pages more than `radius` from `page` go back to placeholders.
    mutating func evict(
        keepingAround page: Int,
        radius: Int = LibraryPageWindow.defaultEvictionRadius,
        ceiling: Int = LibraryPageWindow.defaultEvictionCeiling
    ) {
        guard total > ceiling else { return }
        for key in pages.keys where abs(key - page) > radius {
            pages[key] = nil
            stale.remove(key)
        }
    }
}

// MARK: - Library scrubber math (Library browse plan §3.1, 2026-10-05)

/// Pure decisions behind the Books position scrubber. Indices are 0-based; display is
/// 1-based. Library browse plan §3.1 (2026-10-05).
nonisolated enum LibraryScrubberMath {

    /// Minimum result count that shows the scrubber (plan §11).
    static let threshold = 120
    /// Default VoiceOver step, one server page (plan §11).
    static let defaultVoiceOverStep = 50

    static func showsScrubber(count: Int) -> Bool { count >= threshold }

    /// `round(fraction * (count - 1))`, clamped to `0..<count`; 0 when empty.
    static func index(forFraction fraction: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let clamped = min(max(fraction.isNaN ? 0 : fraction, 0), 1)
        return min(count - 1, max(0, Int((clamped * Double(count - 1)).rounded())))
    }

    /// Inverse of `index(forFraction:count:)`, in 0...1; 0 when `count <= 1`.
    static func fraction(forIndex index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return min(max(Double(index) / Double(count - 1), 0), 1)
    }

    /// First index of the grid row containing `index`, so the target row lands at the top.
    static func rowSnappedIndex(_ index: Int, columns: Int) -> Int {
        let cols = max(1, columns)
        let i = max(0, index)
        return i - i % cols
    }

    /// "Book 1,450 of 3,000" for 0-based `index`, numbers formatted for `locale`.
    static func positionText(index: Int, total: Int, locale: Locale = .current) -> String {
        let shown = total <= 0 ? 0 : min(max(index, 0), total - 1) + 1
        let style = IntegerFormatStyle<Int>.number.locale(locale)
        return String(localized: "Book \(shown.formatted(style)) of \(max(total, 0).formatted(style))", comment: "Library position scrubber readout; first %@ is the 1-based book position, second %@ is the total number of books, both already formatted")
    }

    /// VoiceOver adjustable step: 50 books, or 5% of the library above 5,000.
    static func voiceOverStep(total: Int) -> Int {
        total > 5_000 ? max(defaultVoiceOverStep, total / 20) : defaultVoiceOverStep
    }

    /// True when a drag from `from` to `to` crosses a page boundary (fires one haptic tick).
    static func crossedPageBoundary(from: Int, to: Int, pageSize: Int = 50) -> Bool {
        let size = max(1, pageSize)
        return max(0, from) / size != max(0, to) / size
    }
}
