import Foundation

/// Batch 443: pure book matching shared by the Hardcover sync and the CSV "already on your
/// server" check. Order of trust: ISBN, then ASIN, then normalised title plus author.
nonisolated enum ReadingSiteMatcher {

    struct Candidate: Equatable, Sendable {
        var id: String
        var title: String
        var author: String
        var isbn: String?
        var asin: String?
    }

    // MARK: Normalising

    private static func folded(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Lowercase, accent-folded, bracketed text and "unabridged" removed, punctuation collapsed.
    static func normalizedTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        s = folded(s)
        s = s.replacingOccurrences(of: "unabridged", with: " ")
        s = s.replacingOccurrences(of: "&", with: " and ")
        return collapse(s)
    }

    /// The part before the first colon ("dune: book one" -> "dune"), normalised.
    static func coreTitle(_ raw: String) -> String {
        let head = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
        var core = normalizedTitle(head)
        for article in ["the ", "a ", "an "] where core.hasPrefix(article) { core.removeFirst(article.count); break }
        return core
    }

    private static func collapse(_ s: String) -> String {
        let letters = s.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// Name words, lowercase and accent-folded; single-letter initials dropped so "J. R. R. Tolkien"
    /// still lines up with "J.R.R. Tolkien" and "Tolkien, J.R.R.".
    static func authorTokens(_ raw: String) -> Set<String> {
        let words = collapse(folded(raw.replacingOccurrences(of: ".", with: " "))).split(separator: " ").map(String.init)
        return Set(words.filter { $0.count > 1 && $0 != "and" })
    }

    static func authorsMatch(_ a: String, _ b: String) -> Bool {
        let x = authorTokens(a), y = authorTokens(b)
        if x.isEmpty || y.isEmpty { return false }
        if x.isSubset(of: y) || y.isSubset(of: x) { return true }
        // Several authors listed on one side: any shared surname-sized overlap of half or more.
        let shared = x.intersection(y).count
        return Double(shared) / Double(min(x.count, y.count)) >= 0.5
    }

    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizedTitle(a), nb = normalizedTitle(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        let ca = coreTitle(a), cb = coreTitle(b)
        return !ca.isEmpty && ca == cb
    }

    /// ISBN-10 or 13 reduced to a 13-digit string; nil when not a valid-length ISBN.
    static func isbn13(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        if s.count == 13, s.allSatisfy(\.isNumber) { return s }
        if s.count == 10 {
            let body = "978" + s.prefix(9)
            guard body.allSatisfy(\.isNumber) else { return nil }
            let digits = body.compactMap { $0.wholeNumberValue }
            let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
            return body + String((10 - sum % 10) % 10)
        }
        return nil
    }

    static func normalizedASIN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return s.count == 10 && s.allSatisfy({ $0.isLetter || $0.isNumber }) ? s : nil
    }

    // MARK: Matching

    /// The id of the best candidate, or nil. ISBN, then ASIN, then title plus author.
    static func match(title: String, author: String, isbn: String?, asin: String?, in candidates: [Candidate]) -> String? {
        if let want = isbn13(isbn), let hit = candidates.first(where: { isbn13($0.isbn) == want }) { return hit.id }
        if let want = normalizedASIN(asin), let hit = candidates.first(where: { normalizedASIN($0.asin) == want }) { return hit.id }
        let titleHits = candidates.filter { titlesMatch($0.title, title) }
        if let hit = titleHits.first(where: { authorsMatch($0.author, author) }) { return hit.id }
        return nil
    }

    // MARK: Throttle

    static let progressInterval: TimeInterval = 10 * 60

    /// At most one progress write per book per ten minutes.
    static func shouldSendProgress(lastSent: Date?, now: Date, interval: TimeInterval = progressInterval) -> Bool {
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= interval
    }

    /// Hardcover rating: half stars from 0.5 to 5.
    static func clampedRating(_ value: Double) -> Double? {
        guard value > 0 else { return nil }
        return min(5, max(0.5, (value * 2).rounded() / 2))
    }
}

/// Batch 443: remembers which Hardcover book each library item matched, so a book is searched once.
/// A miss is remembered too (and retried after a week) so an unmatched book doesn't hit the API
/// on every progress tick.
nonisolated struct ReadingMatchCache: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var bookID: Int?
        var at: Date
    }
    var entries: [String: Entry] = [:]
    static let missRetry: TimeInterval = 7 * 24 * 3600

    enum Lookup: Equatable { case unknown, hit(Int), recentMiss }

    func lookup(_ itemID: String, now: Date = Date()) -> Lookup {
        guard let e = entries[itemID] else { return .unknown }
        if let id = e.bookID { return .hit(id) }
        return now.timeIntervalSince(e.at) < Self.missRetry ? .recentMiss : .unknown
    }

    mutating func record(_ itemID: String, bookID: Int?, now: Date = Date()) {
        entries[itemID] = Entry(bookID: bookID, at: now)
    }
}

// MARK: - Settings

extension SettingsKeys {
    /// Set when a Hardcover token is saved; avoids a Keychain read just to ask "connected?".
    static let readingSiteConnected = "settings_readingSiteConnected"
    static let readingSiteSyncProgress = "settings_readingSiteSyncProgress"
    static let readingSiteMarkFinished = "settings_readingSiteMarkFinished"
    static let readingSiteAskRating = "settings_readingSiteAskRating"
}

extension SettingsStore {
    static var readingSiteConnected: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.readingSiteConnected) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.readingSiteConnected) }
    }
    static var readingSiteSyncProgress: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.readingSiteSyncProgress) }
    static var readingSiteMarkFinished: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.readingSiteMarkFinished) }
    static var readingSiteAskRating: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.readingSiteAskRating) }
}

// MARK: - Coordinator

/// A just-finished book waiting for a star rating.
struct PendingReadingRating: Identifiable, Equatable {
    let id: String
    let title: String
    let bookID: Int
}

/// Batch 443: pushes reading state to Hardcover. Off unless connected and the matching toggle is
/// on. Everything is best effort: a failure is logged (token redacted by `ShelfLog`) and never
/// reaches playback.
@MainActor
@Observable
final class ReadingSiteSync {
    static let shared = ReadingSiteSync()

    /// Set after a finish when "Ask to rate" is on; the root view shows a rating sheet for it.
    var pendingRating: PendingReadingRating?

    private var cache: ReadingMatchCache
    private var lastProgressSent: [String: Date] = [:]
    private var markedReading: Set<String> = []
    private let api: HardcoverAPI

    init(api: HardcoverAPI = .shared) {
        self.api = api
        self.cache = Self.loadCache()
    }

    // Review 7 Medium 11: nothing goes to the reading site from a kid account.
    private var connected: Bool {
        SettingsStore.readingSiteConnected && !KidProfileStore.standard.isKid(AccountStore.currentAccountId)
    }

    // MARK: Entry points

    /// A book began playing: mark it "Currently Reading" once per session.
    func bookStarted(_ item: LibraryItem) {
        guard connected, SettingsStore.readingSiteSyncProgress, !item.isPodcast,
              markedReading.insert(item.id).inserted else { return }
        Task { [weak self] in
            guard let self, let id = await self.resolve(item) else { return }
            await self.run("status reading") { try await self.api.setStatus(bookID: id, status: .currentlyReading) }
        }
    }

    /// Playback moved on. `fraction` is 0...1 of the whole book.
    func progressChanged(_ item: LibraryItem, fraction: Double) {
        guard connected, SettingsStore.readingSiteSyncProgress, !item.isPodcast, fraction > 0, fraction < 1,
              ReadingSiteMatcher.shouldSendProgress(lastSent: lastProgressSent[item.id], now: Date()) else { return }
        lastProgressSent[item.id] = Date()
        let seconds = Int((fraction * item.duration).rounded())
        Task { [weak self] in
            guard let self, let id = await self.resolve(item) else { return }
            await self.run("progress") { try await self.api.updateProgress(bookID: id, seconds: seconds) }
        }
    }

    /// The book was finished (played to the end or marked finished).
    func bookFinished(_ item: LibraryItem) {
        guard connected, SettingsStore.readingSiteMarkFinished, !item.isPodcast else { return }
        let ask = SettingsStore.readingSiteAskRating
        Task { [weak self] in
            guard let self, let id = await self.resolve(item) else { return }
            let finished = await self.run("finish") { try await self.api.finish(bookID: id, on: Date()) }
            // Review 4 Low (Hardcover mutation errors): only ask for a rating once the finish landed.
            if ask, finished { self.pendingRating = PendingReadingRating(id: item.id, title: item.title, bookID: id) }
        }
    }

    /// Called by the rating sheet. `stars` nil = skip.
    func submitRating(_ stars: Double?) {
        guard let pending = pendingRating else { return }
        pendingRating = nil
        guard let stars, let value = ReadingSiteMatcher.clampedRating(stars) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.run("rate") { try await self.api.rate(bookID: pending.bookID, rating: value) }
        }
    }

    // MARK: Matching

    private func resolve(_ item: LibraryItem) async -> Int? {
        switch cache.lookup(item.id) {
        case .hit(let id): return id
        case .recentMiss: return nil
        case .unknown: break
        }
        do {
            let found = try await api.findBook(isbn: item.media?.metadata?.isbn, asin: item.asin,
                                               title: item.title, author: item.authorName)
            cache.record(item.id, bookID: found?.id)
            saveCache()
            return found?.id
        } catch {
            ShelfLog.error(.sync, "Hardcover match failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func run(_ what: String, _ work: () async throws -> Void) async -> Bool {
        do { try await work(); return true } catch {
            ShelfLog.error(.sync, "Hardcover \(what) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Cache file

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("reading-site-matches.json")
    }

    private static func loadCache() -> ReadingMatchCache {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ReadingMatchCache.self, from: data) else { return ReadingMatchCache() }
        return cache
    }

    private func saveCache() {
        guard let url = Self.cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forget matches (on disconnect).
    func resetCache() {
        cache = ReadingMatchCache()
        lastProgressSent = [:]
        markedReading = []
        if let url = Self.cacheURL { try? FileManager.default.removeItem(at: url) }
    }
}
