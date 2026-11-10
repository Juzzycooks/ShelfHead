import Foundation
import Observation

/// Batch 442: drives the release radar. Refreshes at most once a day, only when the user opted in,
/// and keeps the last good result when offline. Only series names / ASINs / author names reach Audible.
@MainActor
@Observable
final class ReleaseRadarViewModel {
    static let shared = ReleaseRadarViewModel()

    private(set) var entries: [ReleaseRadarPlanner.RadarEntry] = []
    private(set) var lastChecked: Date?
    private(set) var isRefreshing = false
    /// Review 7 Low (Radar): scope of the run in flight, so another account's refresh isn't blocked by it.
    private var refreshingScope: String?
    private(set) var lastError: String?

    /// Series asked about per refresh; the rest are covered on later days (rotation).
    static let seriesPerRefresh = 25
    static let refreshInterval: TimeInterval = 20 * 3600
    private static let maxChildrenPerSeries = 40

    /// Cached per account scope, so an account switch never shows another account's radar.
    struct Cache: Codable, Equatable {
        var lastChecked: Date?
        var rotation: Int = 0
        var region: String = ""
        /// normalised series key -> Audible series ASIN
        var seriesASINs: [String: String] = [:]
        /// normalised series key -> candidate products (later books only)
        var catalog: [String: [CatalogProduct]] = [:]
    }

    private var cache = Cache()
    private var loadedScope: String?
    private var books: [ReleaseRadarPlanner.LibraryBook] = []

    // MARK: Cache file

    static func cacheURL(scope: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("ReleaseRadar", isDirectory: true)
            .appendingPathComponent("\(scope).json")
    }

    /// Scope for the current server + account (same keying as downloads).
    static func currentScope() -> String {
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty else { return "unscoped" }
        return DownloadPaths.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
    }

    private func loadCache(scope: String) {
        guard loadedScope != scope else { return }
        loadedScope = scope
        cache = Cache()
        if let url = Self.cacheURL(scope: scope), let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = decoded
        }
        lastChecked = cache.lastChecked
    }

    private func saveCache(scope: String) {
        guard let url = Self.cacheURL(scope: scope) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Refresh

    /// Recomputes `entries` from the cache for this snapshot (no network).
    func rebuild(items: [LibraryItem], now: Date = Date(), calendar: Calendar = .current) {
        loadCache(scope: Self.currentScope())
        books = items.filter { !$0.isPodcast }.map(ReleaseRadarPlanner.LibraryBook.init(item:))
        let (targets, _) = ReleaseRadarPlanner.seriesToCheck(books: books, cap: .max)
        entries = ReleaseRadarPlanner.plan(targets: targets, catalog: cache.catalog, today: now, calendar: calendar)
    }

    /// Opt-in gate + once-a-day throttle. `force` is "Check now".
    func refreshIfNeeded(items: [LibraryItem], force: Bool = false) async {
        guard SettingsStore.releaseRadarEnabled else { return }
        let scope = Self.currentScope()
        loadCache(scope: scope)
        rebuild(items: items)
        let regionChanged = cache.region != SettingsStore.releaseRadarRegion.rawValue
        if !force, !regionChanged, let last = cache.lastChecked, Date().timeIntervalSince(last) < Self.refreshInterval { return }
        guard Self.mayStartRefresh(runningScope: isRefreshing ? refreshingScope : nil, requested: scope) else { return }
        isRefreshing = true
        refreshingScope = scope
        defer {
            // Only the run that owns the flag clears it (a newer scope's run may have taken over).
            if refreshingScope == scope { isRefreshing = false; refreshingScope = nil }
        }

        let region = SettingsStore.releaseRadarRegion
        if regionChanged {
            // ASINs and catalogs are per storefront.
            cache = Cache(lastChecked: nil, rotation: 0, region: region.rawValue)
        }
        let api = AudibleCatalogAPI(region: region)
        let (targets, next) = ReleaseRadarPlanner.seriesToCheck(books: books, cap: Self.seriesPerRefresh, rotation: cache.rotation)
        var anySuccess = targets.isEmpty
        var checked = 0   // Review 2 Low (Release Radar): series actually processed this run
        lastError = nil
        for target in targets {
            if Task.isCancelled { break }
            // Review 6 Low (Release Radar scope): an account switch mid-run ends it before it touches the new scope's cache.
            if Self.scopeChanged(started: scope, current: Self.currentScope()) { return }
            do {
                try await check(target, api: api, scope: scope)
                anySuccess = true
                checked += 1
            } catch {
                if Self.scopeChanged(started: scope, current: Self.currentScope()) { return }
                lastError = error.localizedDescription
                // Offline or blocked: stop early rather than hammering, keep the cache.
                if Self.shouldStopRun(after: error) { break }
                checked += 1
            }
        }
        // Review 3 Low (Release Radar all-error): a run that ended on its own with every series failing for a
        // non-network reason (per-series 404 or bad body) still stamps lastChecked so it isn't retried on every
        // open. Offline/throttled/cancelled runs (stopped early) return as before and retry next open.
        if Self.scopeChanged(started: scope, current: Self.currentScope()) { return }
        if !anySuccess {
            guard checked >= targets.count, !Task.isCancelled else { return }
            cache.region = region.rawValue
            cache.lastChecked = Date()
            lastChecked = cache.lastChecked
            saveCache(scope: scope)
            return
        }
        // Review 2 Low (Release Radar, 30 October 2026): an early stop moves the rotation only past the
        // series checked and doesn't stamp the day's throttle, so the next open continues the run.
        let total = ReleaseRadarPlanner.seriesToCheck(books: books, cap: .max).targets.count
        let completedRun = checked >= targets.count
        cache.rotation = Self.rotationAfterRun(rotation: cache.rotation, checked: checked,
                                               planned: targets.count, total: total, plannedNext: next)
        cache.region = region.rawValue
        if completedRun { cache.lastChecked = Date() }
        lastChecked = cache.lastChecked
        saveCache(scope: scope)
        rebuild(items: items)
    }

    /// Rotation to store after a run: the planner's `plannedNext` when every planned series was checked,
    /// otherwise the old start advanced by only the series actually checked.
    nonisolated static func rotationAfterRun(rotation: Int, checked: Int, planned: Int, total: Int, plannedNext: Int) -> Int {
        if checked >= planned || total <= 0 { return plannedNext }
        let start = ((rotation % total) + total) % total
        return (start + max(0, checked)) % total
    }

    /// Review Low (Release Radar, 30 October 2026): stop the run, keeping partial results, on an offline/blocked
    /// error or when Audible throttles (429) or fails (5xx), instead of firing the remaining series at it.
    /// Other errors (404, a malformed body) are per-series and don't end the run.
    nonisolated static func shouldStopRun(after error: Error) -> Bool {
        if error is URLError { return true }
        if let catalog = error as? AudibleCatalogAPI.CatalogError, case .badResponse(let code) = catalog {
            return code == 429 || (500..<600).contains(code)
        }
        return false
    }

    /// Review 6 Low (Release Radar scope): true when the account/server changed since a refresh began.
    /// Review 7 Low (Radar): a refresh may start unless one for the SAME scope is already running.
    nonisolated static func mayStartRefresh(runningScope: String?, requested: String) -> Bool { runningScope != requested }

    nonisolated static func scopeChanged(started: String, current: String) -> Bool { started != current }

    private func check(_ target: ReleaseRadarPlanner.SeriesTarget, api: AudibleCatalogAPI, scope: String) async throws {
        var seriesASIN = cache.seriesASINs[target.key]
        // Each await below may straddle an account switch; `cache` then belongs to the new scope.
        func stillCurrent() throws { if Self.scopeChanged(started: scope, current: Self.currentScope()) { throw CancellationError() } }
        if seriesASIN == nil {
            if let sample = target.sampleASIN, let p = try await api.product(asin: sample) {
                seriesASIN = p.series.first { ReleaseRadarPlanner.normalisedSeriesKey($0.title ?? "") == target.key }?.asin
            }
            try stillCurrent()
            if seriesASIN == nil {
                let found = try await api.search(keywords: "\(target.name) \(target.author)")
                try stillCurrent()
                seriesASIN = found.lazy.compactMap { p in
                    p.series.first { ReleaseRadarPlanner.normalisedSeriesKey($0.title ?? "") == target.key }?.asin
                }.first
            }
            if let seriesASIN { cache.seriesASINs[target.key] = seriesASIN }
        }
        guard let seriesASIN else { cache.catalog[target.key] = []; return }
        let children = try await api.seriesChildren(seriesASIN: seriesASIN)
        try stillCurrent()
        let wanted = children
            .filter { ($0.sequence ?? 0) > target.maxOwnedSequence && !target.ownedASINs.contains($0.asin) }
            .sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
            .prefix(Self.maxChildrenPerSeries)
            .map(\.asin)
        let products = wanted.isEmpty ? [] : try await api.products(asins: Array(wanted))
        try stillCurrent()
        cache.catalog[target.key] = products
    }

    // MARK: Reminders

    /// ASINs with a pending release-day reminder.
    private(set) var reminders: Set<String> = []

    func loadReminders() async {
        var set: Set<String> = []
        for e in entries where await NotificationManager.hasReleaseReminder(asin: e.asin) { set.insert(e.asin) }
        reminders = set
    }

    /// Turns the reminder off, or tries to set it and returns why it couldn't (nil when it was set or
    /// removed), so the sheet can explain a denied permission instead of doing nothing.
    @discardableResult
    func toggleReminder(_ entry: ReleaseRadarPlanner.RadarEntry) async -> NotificationManager.ReleaseReminderResult? {
        if reminders.contains(entry.asin) {
            NotificationManager.cancelReleaseReminder(asin: entry.asin)
            reminders.remove(entry.asin)
            return nil
        }
        let result = await NotificationManager.scheduleReleaseReminder(
            asin: entry.asin, title: entry.title, seriesName: entry.seriesName,
            sequenceLabel: Self.sequenceLabel(entry.sequence), releaseDate: entry.releaseDate)
        if result == .scheduled {
            reminders.insert(entry.asin)
            return nil
        }
        return result
    }

    /// "Book 5", "Book 3.5". Number goes in as a String to avoid digit grouping.
    static func sequenceLabel(_ sequence: Double) -> String {
        let n = sequence == sequence.rounded() ? String(Int(sequence)) : String(sequence)
        return String(localized: "Book \(n)", comment: "Series position label on the release radar. %@ is the number, e.g. 5 or 3.5.")
    }

    /// "in 12 days" / "Out now", localised.
    static func releaseLabel(_ status: ReleaseRadarPlanner.Status) -> String {
        switch status {
        case .outNotInLibrary:
            return String(localized: "Out now", comment: "Release radar: the book is already released")
        case .upcoming(let days):
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return f.localizedString(from: DateComponents(day: days))
        }
    }
}
