import SwiftUI
import Charts

/// Stage 3 (REDESIGN_PROPOSAL_2026-08-26.md §2.1): this is now the root screen of the
/// Listening tab — the app's whole retrospective story (stats, Year in Review, your
/// bookmarks, streak) used to be scattered across a Settings menu row, a toolbar link
/// buried inside this screen, and a separate Settings row, which the proposal's point
/// of view called out as "a rich retrospective story about your listening, filed as a
/// preference." Year in Review and All Bookmarks are promoted below from a toolbar
/// link / a Settings row into peer sections on this screen; the listening-streak
/// capsule that used to sit in `HomeView`'s header is now this screen's toolbar
/// instead. `PlaybackHistoryView` was deliberately NOT moved here despite being named
/// in the proposal's list — reading its actual implementation shows it's an undo log
/// for mark-finished/mark-unfinished/reset-progress actions (`PlaybackHistoryStore`),
/// not a listening-session history (that's this screen's own "Recent Sessions" card,
/// via `historyCard` below, which already lived here). An undo tool belongs with its
/// diagnostic siblings (Server diagnostics, Download health), not in a listening
/// retrospective, so it stays under Settings > Diagnostics.
///
/// Perf fix (swiftui-performance audit): `DateFormatter` is expensive to construct,
/// and every one of these has a fixed configuration (a `"yyyy-MM-dd"`/`"EEE"`/
/// `"MMM"`/`"MMM d"` pattern, set once), so they're hoisted to file-scope constants
/// built exactly once instead of per-call. Do NOT mutate any of these instances'
/// `calendar`/`timeZone`/`locale` after this point — a shared `DateFormatter` is not
/// thread-safe to reconfigure concurrently. (`ListeningStats.monthTotal` in
/// BrowseModels.swift has the same hazard, for the same reason, and handles it the
/// same way — see that file.)
private enum StatsDateFormatters {
    /// Plain "yyyy-MM-dd" day key, default locale/time zone — matches `bars(for:)`'s
    /// original unconfigured `keyF`.
    // Critique 2026-10-06 (harden): both day-key formatters are now the one shared POSIX +
    // Gregorian `DayKey.shared`; the unconfigured one broke on Buddhist/Japanese calendars.
    static let dayKey: DateFormatter = DayKey.shared
    /// Same day-key pattern, but POSIX locale + the current time zone pinned at
    /// construction — matches `weekTotalSeconds`'s and `PaceCard`'s original
    /// formatter exactly (both were built from `Calendar.current` per call).
    static let dayKeyPOSIX: DateFormatter = DayKey.shared
    // User-facing chart labels: localized templates (word order / month names follow the locale).
    static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f }()
    static let monthDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f }()
    static let month: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM"); return f }()
}

/// HL-4 (docs/visual-design-review.md, V4): at accessibility text sizes the bar charts'
/// category labels ("SunMonTueWed…") run into each other. Pure so it's unit-tested.
/// The axes are nominal (String-keyed), so the *values* stay unique ("Tue" vs "Thu");
/// only what's drawn changes.
enum ChartAxisLabels {
    /// Evenly-spaced subset of `labels`, at most about `limit` of them, always
    /// starting with the first.
    static func thinned(_ labels: [String], limit: Int) -> [String] {
        guard limit > 0, labels.count > limit else { return labels }
        let step = Int((Double(labels.count) / Double(limit)).rounded(.up))
        return Swift.stride(from: 0, to: labels.count, by: step).map { labels[$0] }
    }

    /// The label as drawn: the very short weekday symbol when `narrow` (S M T W T F S).
    /// Batch 400: looked up from the locale's own symbols rather than taking the first
    /// character, which in Chinese is "周" for every day ("周二" → "二"). Anything that
    /// isn't a short weekday name falls back to its first character.
    static func drawn(_ label: String, narrow: Bool, locale: Locale = .current) -> String {
        guard narrow else { return label }
        let formatter = DateFormatter()
        formatter.locale = locale
        if let index = formatter.shortWeekdaySymbols.firstIndex(of: label),
           index < formatter.veryShortWeekdaySymbols.count {
            return formatter.veryShortWeekdaySymbols[index]
        }
        return String(label.prefix(1))
    }
}

/// Critique 2026-10-06 (harden): wording for a stats screen that couldn't refresh. Pure so
/// it's unit-tested. Offline (the device has no network) and server-unreachable (device
/// online, server silent) are different problems with different fixes, as in
/// `ConnectivityBanner`.
enum StatsStaleness {
    /// Full-screen failure copy (nothing cached to show).
    static func failureSubtitle(status: ReachabilityStore.Status) -> String {
        switch status {
        case .offline: return String(localized: "You\u{2019}re offline. Connect to the internet and try again.")
        case .serverUnreachable: return String(localized: "Your server isn\u{2019}t responding. Try again in a moment.")
        case .ok: return String(localized: "Something went wrong reaching your server. Try again.")
        }
    }

    /// The quiet line above cached figures after a failed refresh.
    /// Critique 2026-10-06 (clarify): three causes. `.ok` means the network and server are
    /// fine by the reachability check, so a failed refresh there (a decode error, say) no
    /// longer blames the server.
    static func message(asOf date: Date?, now: Date, status: ReachabilityStore.Status) -> String {
        let problem: String
        switch status {
        case .offline: problem = String(localized: "You\u{2019}re offline.")
        case .serverUnreachable: problem = String(localized: "Can\u{2019}t reach your server.")
        case .ok: problem = String(localized: "Couldn\u{2019}t refresh.")
        }
        guard let date else {
            return status == .ok ? String(localized: "Couldn\u{2019}t refresh. Showing earlier figures.")
                                 : String(localized: "Showing earlier figures. \(problem)", comment: "%@ is a short problem sentence such as You\u{2019}re offline.")
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        let when = f.localizedString(for: date, relativeTo: now)
        return status == .ok ? String(localized: "Couldn\u{2019}t refresh. Showing figures from \(when).", comment: "%@ is a relative date such as yesterday")
                             : String(localized: "Showing figures from \(when). \(problem)", comment: "%1$@ is a relative date such as yesterday, %2$@ is a short problem sentence such as You\u{2019}re offline.")
    }
}

/// Critique 2026-10-06 (clarify): pure helper for the week comparison's empty-last-week line.
enum StatsWeekComparison {
    /// True when any day with listening time falls before the start of last week.
    static func hasDataBeforeLastWeek(days: [String: Double], now: Date,
                                      calendar: Calendar = .current) -> Bool {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) else { return false }
        return days.contains { key, secs in
            guard secs > 0, let date = StatsDateFormatters.dayKeyPOSIX.date(from: key) else { return false }
            return date < lastWeekStart
        }
    }
}


// MARK: - Layout decisions (Critique 2026-10-06 (distill → layout))
//
// The Stats tab was about eleven same-weight `statPanelStyle` cards. It's now one hero
// card (total listened, today's goal, and the pace line with the book's cover), a row of
// figures on the ground, a quiet Year in Review row, then three `RetroSectionHeader`
// groups with their content on the ground. The decisions below are pure so they're
// unit-tested (`StatsLayoutTests`).

extension StatsWeekComparison {
    /// The week comparison, now the second line of the chart's header.
    struct Line: Equatable {
        /// Drawn: "+38% vs last week (3h 2m)".
        let text: String
        /// Read by VoiceOver: "Up 38% from last week's 3h 2m".
        let spoken: String
    }

    static func line(thisWeek: Double, lastWeek: Double, hasEarlierData: Bool) -> Line {
        guard lastWeek > 0 else {
            let text = hasEarlierData ? String(localized: "No listening last week") : String(localized: "First week with data logged")
            return Line(text: text, spoken: text)
        }
        let last = StatsFormat.hours(lastWeek)
        let delta = ((thisWeek - lastWeek) / lastWeek) * 100
        if abs(delta) < 5 {
            return Line(text: String(localized: "About the same as last week (\(last))", comment: "%@ is last week’s listening time, like 3h 2m"),
                        spoken: String(localized: "About the same as last week’s \(last)", comment: "VoiceOver; %@ is last week’s listening time, like 3h 2m"))
        }
        let percent = Int(abs(delta).rounded())
        let up = delta > 0
        return Line(text: up ? String(localized: "+\(percent)% vs last week (\(last))", comment: "Week comparison, increase; %1$lld is a percentage, %2$@ is last week’s listening time")
                             : String(localized: "\u{2212}\(percent)% vs last week (\(last))", comment: "Week comparison, decrease; %1$lld is a percentage, %2$@ is last week’s listening time"),
                    spoken: up ? String(localized: "Up \(percent)% from last week’s \(last)", comment: "VoiceOver; %1$lld is a percentage, %2$@ is last week’s listening time")
                               : String(localized: "Down \(percent)% from last week’s \(last)", comment: "VoiceOver; %1$lld is a percentage, %2$@ is last week’s listening time"))
    }
}

/// Duration strings shared by every Stats figure.
enum StatsFormat {
    /// "230h 59m", "45m". The tape-counter spelling.
    static func hours(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m", comment: "Compact duration: hours and minutes") }
        return String(localized: "\(minutes)m", comment: "Compact duration: minutes")
    }

    /// "230 hours 59 minutes", "1 hour", "45 minutes" for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        func hourUnit(_ n: Int) -> String { n == 1 ? String(localized: "1 hour") : String(localized: "\(n) hours") }
        func minuteUnit(_ n: Int) -> String { n == 1 ? String(localized: "1 minute") : String(localized: "\(n) minutes") }
        if hours > 0 && minutes > 0 { return String(localized: "\(hourUnit(hours)) \(minuteUnit(minutes))", comment: "Spoken duration: %1$@ is hours (2 hours), %2$@ is minutes (5 minutes)") }
        if hours > 0 { return hourUnit(hours) }
        return minuteUnit(minutes)
    }
}

/// Which body the screen shows.
enum StatsScreenPhase: Equatable {
    case skeleton, failed, content

    static func resolve(isLoading: Bool, loadFailed: Bool, hasStats: Bool) -> StatsScreenPhase {
        if isLoading { return .skeleton }
        if loadFailed && !hasStats { return .failed }
        return .content
    }

    /// Critique 2026-10-06 (distill → layout): whether a (re)load starts on the skeleton.
    /// Try Again from the failure state used to clear `loadFailed` without setting
    /// `isLoading`, so with no stats yet the screen fell through to an all-zero dashboard
    /// while it retried. A load with nothing to show starts on the skeleton; a refresh
    /// over figures already on screen keeps them.
    static func showsSkeletonWhileLoading(hasStats: Bool) -> Bool { !hasStats }
}

/// The row of four figures under the hero.
enum StatsFigureRow {
    struct Item: Equatable, Identifiable {
        let id: String
        let value: String
        let label: String
        let spoken: String
        /// Finished books, the one figure that gets the teal "done" glyph.
        let isFinished: Bool
    }

    enum Arrangement: Equatable {
        /// Four across if they fit, else two by two, else a list.
        case adaptive
        /// A vertical list, used at accessibility text sizes.
        case list
    }

    static func arrangement(isAccessibilitySize: Bool) -> Arrangement {
        isAccessibilitySize ? .list : .adaptive
    }

    static func items(monthSeconds: Double, currentStreak: Int, bestStreak: Int, finished: Int) -> [Item] {
        func days(_ n: Int) -> String { n == 1 ? String(localized: "1 day") : String(localized: "\(n) days") }
        return [
            Item(id: "month", value: StatsFormat.hours(monthSeconds), label: String(localized: "This month"),
                 spoken: String(localized: "This month, \(StatsFormat.spoken(monthSeconds))", comment: "VoiceOver; %@ is a spoken duration"), isFinished: false),
            Item(id: "streak", value: "\(currentStreak)", label: String(localized: "Day streak"),
                 spoken: String(localized: "Current streak, \(days(currentStreak))", comment: "VoiceOver; %@ is a number of days"), isFinished: false),
            Item(id: "best", value: "\(bestStreak)", label: String(localized: "Best streak"),
                 spoken: String(localized: "Best streak, all time, \(days(bestStreak))", comment: "VoiceOver; %@ is a number of days"), isFinished: false),
            Item(id: "finished", value: "\(finished)", label: String(localized: "Finished", comment: "Stats figure label: number of books finished"),
                 spoken: finished == 1 ? String(localized: "1 book finished") : String(localized: "\(finished) books finished"), isFinished: true)
        ]
    }
}

/// The chart's header line and Y axis.
enum StatsChartAxis {
    enum Unit: Equatable { case minutes, hours }

    /// Past two hours, the axis counts in hours ("50h", not "3000m").
    static let hoursAboveMinutes: Double = 120

    static func unit(maxMinutes: Double) -> Unit {
        maxMinutes > hoursAboveMinutes ? .hours : .minutes
    }

    /// Tick positions in minutes: 0 and up to `targetCount` round steps that cover
    /// `maxMinutes`. Steps are whole minutes below the threshold, whole hours above.
    static func ticks(maxMinutes: Double, targetCount: Int = 4) -> [Double] {
        guard maxMinutes > 0, targetCount > 0 else { return [0] }
        let steps: [Double] = unit(maxMinutes: maxMinutes) == .hours
            ? [1, 2, 3, 5, 10, 20, 25, 50, 100, 250, 500, 1000, 2500, 5000].map { $0 * 60 }
            : [5, 10, 15, 20, 30, 60]
        let step = steps.first { (maxMinutes / $0).rounded(.up) <= Double(targetCount) } ?? steps[steps.count - 1]
        let count = max(1, Int((maxMinutes / step).rounded(.up)))
        return (0...count).map { Double($0) * step }
    }

    static func label(minutes: Double, unit: Unit) -> String {
        switch unit {
        case .minutes:
            return String(localized: "\(Int(minutes.rounded()))m", comment: "Chart axis label: minutes")
        case .hours:
            let h = minutes / 60
            return h == h.rounded() ? String(localized: "\(Int(h))h", comment: "Chart axis label: hours") : String(format: String(localized: "%.1fh", comment: "Chart axis label: fractional hours"), h)
        }
    }

    /// The chart header's title for each range.
    static func title(for range: StatsView.StatRange) -> String {
        switch range {
        case .week: return String(localized: "This week")
        case .month: return String(localized: "Last 30 days")
        case .year: return String(localized: "Last 12 months")
        }
    }
}

/// "At this pace you'll finish …" for the book that's playing.
enum StatsPace {
    /// Days to finish at the average of the last seven days that had any listening. Nil
    /// when the book is essentially done (≤ 5 minutes left) or there's no recent listening.
    static func daysToFinish(remainingSeconds: Double, days: [String: Double]?, today: Date,
                             calendar: Calendar = .current,
                             keyFormatter: DateFormatter = DayKey.shared) -> Int? {
        guard remainingSeconds > 300, let days, !days.isEmpty else { return nil }
        let recentActive = (0..<7).compactMap { offset -> Double? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let secs = days[keyFormatter.string(from: date)] ?? 0
            return secs > 0 ? secs : nil
        }
        guard !recentActive.isEmpty else { return nil }
        let average = recentActive.reduce(0, +) / Double(recentActive.count)
        guard average > 0 else { return nil }
        return max(1, Int((remainingSeconds / average).rounded(.up)))
    }

    static func sentence(title: String, days: Int) -> String {
        days == 1
            ? String(localized: "At this pace you\u{2019}ll finish \u{201C}\(title)\u{201D} in about 1 day.", comment: "%@ is a book title")
            : String(localized: "At this pace you\u{2019}ll finish \u{201C}\(title)\u{201D} in about \(days) days.", comment: "%1$@ is a book title, %2$lld is a number of days")
    }
}

/// The hero's last line: the pace sentence when there is one (it's the most
/// ShelfHead-specific thing on the screen), else the recent session length, else nothing.
enum StatsHeroLine: Equatable {
    case pace(String)
    case sessions(String)
    case none

    static func choose(pace: String?, sessionSummary: String?) -> StatsHeroLine {
        if let pace, !pace.isEmpty { return .pace(pace) }
        if let sessionSummary, !sessionSummary.isEmpty { return .sessions(sessionSummary) }
        return .none
    }
}

struct StatsView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Height reserved so content clears the floating mini-player + tab bar.
    var bottomInset: CGFloat = 0
    @State private var stats: ListeningStats?
    @State private var sessions: [ListeningSession] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    // Critique 2026-10-06 (harden): when `stats` last loaded, for the stale-figures line.
    @State private var statsLoadedAt: Date?
    private let reachability = ReachabilityStore.shared
    @State private var range: StatRange = .week
    @AppStorage(SettingsKeys.dailyListeningGoalMinutes) private var dailyGoalMinutes = 30

    // Perf fix: these used to be computed straight in `body` (`stats?.monthTotal()`,
    // `stats?.currentStreak`, `stats?.bestStreak`, `bars(for: range)`), each of which
    // scans the *entire* `stats.days` map (with a date parse per entry — up to 12x
    // over for the Year chart via `monthlyBars`). `body` re-evaluates at playback-tick
    // frequency because of `currentBookPaceText`'s old read of `playerViewModel`
    // (see `HeroPaceLine` below, which now isolates that read), so every one of those
    // scans was re-running 2-6 times a second during playback for no reason — none of
    // these four values depend on playback state at all. `@State` here is an explicit
    // cache with an explicit owner and refresh trigger (`refreshStatsDerivedValues()`/
    // `refreshChartBars()`, called from `load()`, the account-change handler, and
    // `range`'s `onChange` below) — not an unspecified cache of body's own computation.
    @State private var cachedMonthTotal: Double = 0
    @State private var cachedCurrentStreak: Int = 0
    @State private var cachedBestStreak: Int = 0
    @State private var cachedBars: [Bar] = []

    /// UI-12: now the shared `bottomBarClearance` helper (Extensions.swift) instead of
    /// an independently-maintained copy.
    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    enum StatRange: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", year = "Year"
        var id: String { rawValue }
        /// Localized segment title (`rawValue` stays the stable identity).
        var title: LocalizedStringResource {
            switch self {
            case .week: "Week"
            case .month: "Month"
            // Batch 403: its own key — "Year" alone is the book-detail "year published"
            // label, which reads 年份 in Chinese; a range picker wants 年 beside 周 / 月.
            case .year: LocalizedStringResource("stats.range.year", defaultValue: "Year", comment: "Stats range picker segment, next to Week and Month")
            }
        }
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            switch StatsScreenPhase.resolve(isLoading: isLoading, loadFailed: loadFailed, hasStats: stats != nil) {
            case .skeleton:
                // LS-6 (docs/design-review.md, Round 3): a skeleton that mirrors this
                // screen's real layout, so the first load (and now Try Again) already reads
                // as "this page" rather than "something's loading".
                StatsSkeleton()
                    .transition(.opacity)
            case .failed:
                // Critique 2026-10-06 (harden): offline vs unreachable wording, and the retry
                // is EmptyStateView's own 44pt button, lifted clear of the mini-player/tab
                // bar (it used to float at a fixed 40pt).
                EmptyStateView(icon: "chart.bar", title: LocalizedStringResource("Couldn’t load stats"),
                               subtitle: .verbatim(StatsStaleness.failureSubtitle(status: reachability.status)),
                               actionTitle: LocalizedStringResource("Retry"),
                               action: { Task { await load() } })
                    .padding(.bottom, bottomClearance)
            case .content:
                ScrollView {
                    // Critique 2026-10-06 (distill → layout): one hero card, then everything
                    // else on the ground. Tight spacing inside a group, generous between.
                    VStack(alignment: .leading, spacing: Space.xl) {
                        // Critique 2026-10-06 (harden): a failed refresh with cached figures
                        // keeps them on screen and says so quietly.
                        if loadFailed, stats != nil {
                            Typo.fine(Text(StatsStaleness.message(asOf: statsLoadedAt, now: Date(), status: reachability.status)))
                                .foregroundStyle(Color.shelfMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        hero

                        figureRow

                        // Critique 2026-10-06 (peak-end): Year in Review stays near the top.
                        // Now a quiet row on the ground rather than a card.
                        NavigationLink(destination: YearInReviewView(bottomInset: bottomInset)) {
                            quietLinkRow(icon: "sparkles", title: "Year in Review",
                                         subtitle: "Your listening, looked back on")
                        }
                        .buttonStyle(.plain)

                        listeningSection
                            // `range` isn't a per-tick value — it only changes when the user
                            // taps the segmented picker — so recomputing here (rather than in
                            // `body`) still satisfies "explicit refresh trigger" without adding
                            // any staleness window.
                            .onChange(of: range) { _, _ in refreshChartBars() }

                        historySection

                        moreSection
                    }
                    .padding(.horizontal, Space.pageH)
                    .padding(.top, Space.m)
                    .padding(.bottom, Space.xl + bottomClearance)
                }
                .refreshable { await load() }
                .transition(.opacity)
            }
        }
        // LS-6 (docs/design-review.md, Round 3): cross-fades the skeleton into the
        // loaded content (and back, on an account-change reload) instead of a hard cut.
        .shelfAnimation(.easeInOut(duration: 0.25), value: isLoading)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        // G7 (REVIEW_2026-09-04_UI.md): the nav-bar streak capsule (Stage 3 moved it here
        // from Home's header) is gone — it duplicated the streak figure below it.
        .task { await load() }
        // If the account switches while this screen happens to still be on the nav
        // stack, drop the stale account's numbers and reload for the new one — the
        // scope check in `load()` above only stops stale results from landing, it
        // doesn't by itself trigger a fresh load for the account that's now active.
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
            stats = nil
            statsLoadedAt = nil
            sessions = []
            isLoading = true
            // Drop the stale account's cached derived figures too — otherwise the old
            // account's streaks/month total/chart would flash on screen for one frame
            // before `load()`'s refresh lands.
            refreshStatsDerivedValues()
            Task { await load() }
        }
        .reexpandsTabBarOnAppear()
    }

    /// Identifies the currently active server+account, so an in-flight `load()` can tell
    /// whether the account switched underneath it before its results land (this screen
    /// can be left open across an account switch reachable from Settings).
    private func activeStatsScope() -> String {
        "\(AuthStore.shared.serverURL)|\(AccountStore.currentAccountId ?? "")"
    }

    private func load() async {
        let scope = activeStatsScope()
        // Critique 2026-10-06 (distill → layout): with nothing on screen yet (Try Again
        // after a failed first load), show the skeleton while retrying instead of falling
        // through to an all-zero dashboard. See `StatsScreenPhase.showsSkeletonWhileLoading`.
        if StatsScreenPhase.showsSkeletonWhileLoading(hasStats: stats != nil) { isLoading = true }
        loadFailed = false
        do {
            let fetched = try await AudiobookshelfAPI.shared.getListeningStats()
            if scope == activeStatsScope() {
                stats = fetched
                statsLoadedAt = Date()
                // `stats` just landed — this is the refresh trigger for the cached
                // streaks/month total/chart bars (see the `cached*` @State above).
                refreshStatsDerivedValues()
            }
        } catch {
            if scope == activeStatsScope() { loadFailed = true }
        }
        // History is a nice-to-have; don't fail the whole screen if it errors, and
        // keep the last-loaded sessions rather than blanking on a failed refresh.
        if let fresh = try? await AudiobookshelfAPI.shared.getListeningSessions(itemsPerPage: 25),
           scope == activeStatsScope() {
            sessions = fresh
        }
        if libraryViewModel.finishedBooksCount == 0 {
            await libraryViewModel.loadUserProgress()
        }
        if scope == activeStatsScope() { isLoading = false }
    }

    /// Recomputes the cached figures that scan the whole `stats.days` map. Called when
    /// `stats` itself changes (`load()`) and when it's cleared on an account switch —
    /// never from `body`. See the `cached*` `@State` declarations above for why these
    /// aren't plain computed properties.
    ///
    /// Reads `stats` once and folds the chart bars in via `refreshChartBars()` so there's
    /// a single entry point for "stats changed, redo the derived numbers".
    private func refreshStatsDerivedValues() {
        cachedMonthTotal = stats?.monthTotal() ?? 0
        cachedCurrentStreak = stats?.currentStreak ?? 0
        cachedBestStreak = stats?.bestStreak ?? 0
        refreshChartBars()
    }

    /// Recomputes just the chart bars — the one cached value that depends on `range` as
    /// well as `stats`, so the segmented picker needs to refresh it without redoing the
    /// streak scans. Falls out to `[]` when there are no stats, matching `bars(for:)`.
    private func refreshChartBars() {
        cachedBars = bars(for: range)
    }

    // MARK: - Hero

    /// Critique 2026-10-06 (distill → layout): the screen's one hero, and its only card.
    /// Total listened (a tape-counter figure), today's goal ring folded in from the old
    /// Daily Goal card that sat above it, and the pace line with the playing book's cover
    /// (covers are the brand). The goal menu is its own 44pt control, outside the
    /// combined accessibility elements, so VoiceOver and Voice Control can reach it.
    /// Light gets a hairline, not a shadow (`shelfElevation`).
    private var hero: some View {
        let total = stats?.totalTime ?? 0
        return VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Typo.supporting(Text("Total listened"))
                    .foregroundStyle(Color.shelfMuted)
                // ID-2 (V5): the hero figure is a tape-counter readout, monospaced.
                Text(formatHours(total))
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total listened")
            .accessibilityValue(StatsFormat.spoken(total))

            goalRow

            // The only part of this screen that reads playback state; see `HeroPaceLine`.
            HeroPaceLine(days: stats?.days, sessionSummary: sessionLengthSummary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Color.shelfCard)
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero))
        .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.hero))
    }

    // Daily goal (ShelfPlayer/AudioBooth both ship this; `stats.today` and the existing
    // streak infrastructure already have everything a ring needs.)

    private var goalLine: String {
        let todayMinutes = Int((stats?.today ?? 0) / 60)
        guard dailyGoalMinutes > 0 else { return String(localized: "Daily goal off") }
        return todayMinutes >= dailyGoalMinutes
            ? String(localized: "Goal hit \u{00B7} \(todayMinutes) min today", comment: "%lld is minutes listened today")
            : String(localized: "\(todayMinutes) of \(dailyGoalMinutes) min today", comment: "%1$lld is minutes listened today, %2$lld is the daily goal in minutes")
    }

    private var goalRow: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                DailyGoalRing(progressMinutes: (stats?.today ?? 0) / 60, goalMinutes: Double(dailyGoalMinutes))
                    .frame(width: 36, height: 36)
                Typo.metadata(Text(goalLine))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Daily goal")
            .accessibilityValue(goalLine)

            Spacer(minLength: Space.s)

            Menu {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button {
                        dailyGoalMinutes = minutes
                        Haptics.selection()
                    } label: {
                        if dailyGoalMinutes == minutes {
                            Label("\(minutes) min", systemImage: "checkmark")
                        } else {
                            Text("\(minutes) min")
                        }
                    }
                }
                Divider()
                Button("Off") {
                    dailyGoalMinutes = 0
                    Haptics.selection()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    // On the hero card, so the surface-tuned accent text token.
                    .foregroundStyle(Color.shelfAmberTextOnSurface)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            // CO-7 (Batch 353): the checkmark and item text in the label colour on the menu's
            // glass. The button's own glyph keeps its explicit amber above.
            .systemChromeTint()
            .accessibilityLabel("Change daily goal")
            .accessibilityValue(dailyGoalMinutes > 0 ? Text("\(dailyGoalMinutes) minutes") : Text("Off", comment: "Daily goal is switched off"))
        }
    }

    // MARK: - Figure row

    /// Critique 2026-10-06 (distill → layout): the 2×2 tile matrix (four more cards, in
    /// fixed HStacks that didn't reflow at accessibility sizes) is now one row of figures
    /// on the ground. Four across when they fit, two by two when they don't, and a
    /// vertical list at accessibility sizes, so "230h 59m" never truncates.
    @ViewBuilder
    private var figureRow: some View {
        let items = StatsFigureRow.items(monthSeconds: cachedMonthTotal,
                                         currentStreak: cachedCurrentStreak,
                                         bestStreak: cachedBestStreak,
                                         finished: libraryViewModel.finishedBooksCount)
        switch StatsFigureRow.arrangement(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
        case .list:
            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(items) { figureCell($0) }
            }
        case .adaptive:
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Space.l) {
                    ForEach(items) { figureCell($0) }
                }
                Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.m) {
                    GridRow { figureCell(items[0]); figureCell(items[1]) }
                    GridRow { figureCell(items[2]); figureCell(items[3]) }
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(items) { figureCell($0) }
                }
            }
        }
    }

    private func figureCell(_ item: StatsFigureRow.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.value)
                .font(.title3.weight(.semibold))
                .fontDesign(.monospaced)
                .foregroundStyle(Color.shelfCream)
                .lineLimit(1)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                .minimumScaleFactor(0.5)
            Typo.supporting(HStack(spacing: 4) {
                if item.isFinished {
                    // Critique 2026-10-06 (colorize): teal means done.
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.shelfAccentText)
                }
                Text(item.label)
                    .foregroundStyle(Color.shelfMuted)
            })
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spoken)
    }

    // MARK: - Listening (chart)

    private var weekLine: StatsWeekComparison.Line? {
        let thisWeek = weekTotalSeconds(weeksAgo: 0)
        let lastWeek = weekTotalSeconds(weeksAgo: 1)
        guard thisWeek > 0 || lastWeek > 0 else { return nil }
        return StatsWeekComparison.line(
            thisWeek: thisWeek, lastWeek: lastWeek,
            hasEarlierData: StatsWeekComparison.hasDataBeforeLastWeek(days: stats?.days ?? [:], now: Date()))
    }

    /// The figure beside the chart header: this calendar week for Week (matching the
    /// comparison under it), otherwise the sum of the bars shown.
    private var rangeTotalSeconds: Double {
        range == .week ? weekTotalSeconds(weeksAgo: 0) : cachedBars.reduce(0) { $0 + $1.minutes * 60 }
    }

    /// Critique 2026-10-06 (distill → layout): the "This Week vs Last" card is merged into
    /// the chart's header ("This week 4h 12m", then "+38% vs last week (3h 2m)"). The
    /// section is titled "Listening" rather than "This week" because the picker also
    /// shows 30 days and 12 months; the header line names whichever range is showing.
    private var listeningSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RetroSectionHeader(title: LocalizedStringResource("Listening", comment: "Stats section header"))

            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Typo.cardTitle(Text(StatsChartAxis.title(for: range)))
                            .foregroundStyle(Color.shelfCream)
                        Spacer(minLength: Space.s)
                        rangeFigure
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Typo.cardTitle(Text(StatsChartAxis.title(for: range)))
                            .foregroundStyle(Color.shelfCream)
                        rangeFigure
                    }
                }
                if range == .week, let line = weekLine {
                    Typo.supporting(Text(line.text))
                        .foregroundStyle(Color.shelfMuted)
                        .accessibilityLabel(line.spoken)
                }
            }
            .accessibilityElement(children: .combine)

            Picker("Range", selection: $range) {
                ForEach(StatRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            chart
        }
    }

    private var rangeFigure: some View {
        Text(formatHours(rangeTotalSeconds))
            .font(.headline.weight(.bold))
            .fontDesign(.monospaced)
            // Critique 2026-10-06 (colorize): a figure, not an accent. Cream.
            .foregroundStyle(Color.shelfCream)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(StatsFormat.spoken(rangeTotalSeconds))
    }

    // MARK: - History

    /// Critique 2026-10-06 (peak-end): inline cap of 5 rows (was 15) with a "See all" push
    /// to the full fetched history.
    private static let inlineSessionCount = 5

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RetroSectionHeader(title: LocalizedStringResource("History", comment: "Stats section header"))

            // GitHub-style calendar heatmap of daily listening minutes, last 20 weeks.
            Typo.supporting(Text("Last 20 weeks"))
                .foregroundStyle(Color.shelfMuted)
            ListeningHeatmapView(days: stats?.days)

            if !sessions.isEmpty {
                recentSessions
                    .padding(.top, Space.l)
            }
        }
    }

    /// Recent Sessions on the ground (was a card). Each row with a book id opens that
    /// book's detail page, the same push Home and Library use.
    private var recentSessions: some View {
        let shown = Array(sessions.prefix(Self.inlineSessionCount))
        return VStack(alignment: .leading, spacing: Space.s) {
            Typo.cardTitle(Text("Recent sessions"))
                .foregroundStyle(Color.shelfCream)
                .accessibilityAddTraits(.isHeader)

            ForEach(shown) { session in
                SessionLinkRow(session: session)
                if session.id != shown.last?.id {
                    Divider().overlay(Color.shelfSurface)
                }
            }

            if sessions.count > shown.count {
                NavigationLink {
                    SessionsListView(sessions: sessions, bottomClearance: bottomClearance)
                } label: {
                    HStack {
                        Typo.secondaryAction(Text("See all \(sessions.count) sessions"))
                            .foregroundStyle(Color.shelfAmberText)
                        Spacer(minLength: Space.s)
                        Image(systemName: "chevron.right")
                            .scaledFont(13, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Color.shelfMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Critique 2026-10-06 (polish): "See all" alone doesn't say what.
                .accessibilityLabel("See all recent sessions")
            }
        }
    }

    // MARK: - More

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RetroSectionHeader(title: LocalizedStringResource("More", comment: "Stats section header for extra links"))
            // Stage 3: All Bookmarks used to be its own row on the Settings root menu —
            // moved here alongside the rest of the listening retrospective.
            NavigationLink(destination: AllBookmarksView()) {
                quietLinkRow(icon: "bookmark", title: "All Bookmarks",
                             subtitle: "Every bookmark, across every book")
            }
            .buttonStyle(.plain)
            // Batch 459: every finished book as a cassette on a shelf, grouped by year.
            NavigationLink(destination: CassetteWallView()) {
                quietLinkRow(icon: "books.vertical", title: "Cassette Wall",
                             subtitle: "Every book you’ve finished, on a shelf")
            }
            .buttonStyle(.plain)
            // Batch 463: stamps for every genre, narrator and decade you have finished a book in.
            NavigationLink(destination: ListeningPassportView()) {
                quietLinkRow(icon: "airplane.departure", title: "Listening Passport",
                             subtitle: "Stamps for the genres, narrators and decades you’ve finished")
            }
            .buttonStyle(.plain)
            // Batch 458: clips from different books, played in order and shared as a link.
            NavigationLink(destination: MixtapesView()) {
                quietLinkRow(icon: "music.note.list", title: "Mixtapes",
                             subtitle: "Your favourite moments, played in order")
            }
            .buttonStyle(.plain)
        }
    }

    fileprivate static func sessionSubtitle(_ session: ListeningSession) -> String {
        let listened = formatHoursText(clampedListenedSeconds(session))
        if let author = session.displayAuthor, !author.isEmpty {
            return String(localized: "\(author) · \(listened) listened", comment: "Session subtitle: %1$@ is the author, %2$@ is a duration")
        }
        return String(localized: "\(listened) listened", comment: "Session subtitle: %@ is a duration")
    }

    /// A single session can't have listened longer than the book itself. Some servers
    /// report a corrupted/unsynced `timeListening` (e.g. 294h); clamp to the book's
    /// duration so the history row shows a sane figure instead of a nonsense total.
    private func clampedListened(_ session: ListeningSession) -> Double {
        Self.clampedListenedSeconds(session)
    }

    fileprivate static func clampedListenedSeconds(_ session: ListeningSession) -> Double {
        let raw = max(session.timeListening ?? 0, 0)
        if let d = session.duration, d > 0 { return min(raw, d) }
        return raw
    }

    // MARK: - Audiobook-specific insights (derived from existing data only — no new
    // fetch path; see `load()`'s `stats`/`sessions` and `libraryViewModel`)

    /// Average length of a listening session, from the same recent-session history the
    /// "Recent sessions" list already shows (up to 25 sessions) — not a lifetime average,
    /// since the API doesn't expose one, but a meaningful recent figure.
    private var averageSessionMinutes: Int? {
        guard !sessions.isEmpty else { return nil }
        let total = sessions.reduce(0.0) { $0 + clampedListened($1) }
        let avg = total / Double(sessions.count)
        return avg > 0 ? Int(avg / 60) : nil
    }

    /// Longest single session on record (within the loaded history) — shown only as a
    /// fallback when there isn't enough history for a meaningful average (e.g. exactly
    /// one session logged, where "average" and "longest" would just repeat the same card).
    private var longestSessionMinutes: Int? {
        let values = sessions.compactMap { s -> Double? in
            let v = clampedListened(s)
            return v > 0 ? v : nil
        }
        guard let m = values.max(), sessions.count > 1 else { return nil }
        return Int(m / 60)
    }

    /// The hero's fallback last line when there's no pace to show — Pass 3 item 4
    /// (REVIEW_2026-09-04_UI.md) folded the old "Avg Session" tile into the hero.
    private var sessionLengthSummary: String? {
        if let avgSession = averageSessionMinutes { return String(localized: "\(avgSession)m average session", comment: "%lld is minutes") }
        if let longest = longestSessionMinutes { return String(localized: "\(longest)m longest session", comment: "%lld is minutes") }
        return nil
    }

    /// Total seconds listened within the calendar week that started `weeksAgo` weeks
    /// before the current one (0 = this week, 1 = last week).
    private func weekTotalSeconds(weeksAgo: Int) -> Double {
        guard let days = stats?.days, !days.isEmpty else { return 0 }
        let cal = Calendar.current
        guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start,
              let targetStart = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: thisWeekStart),
              let interval = cal.dateInterval(of: .weekOfYear, for: targetStart) else { return 0 }
        return days.compactMap { key, secs in StatsDateFormatters.dayKeyPOSIX.date(from: key).map { ($0, secs) } }
            .filter { interval.contains($0.0) }
            .reduce(0.0) { $0 + $1.1 }
    }

    /// Critique 2026-10-06 (distill → layout): a quiet row on the ground for Year in
    /// Review and All Bookmarks (they were cards, the same weight as the stats).
    private func quietLinkRow(icon: String, title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.shelfMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Typo.rowTitle(Text(title))
                    .foregroundStyle(Color.shelfCream)
                Typo.rowSubtitle(Text(subtitle))
                    .foregroundStyle(Color.shelfMuted)
            }
            Spacer(minLength: Space.s)
            Image(systemName: "chevron.right")
                // VD-7 (docs/design-review.md, Round 4): trailing disclosure chevron
                // scales with the row like the app's other row chevrons.
                .scaledFont(13, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(Color.shelfMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chart

    fileprivate struct Bar: Identifiable {
        // Critique 2026-10-06 (harden): stable id (day key / "yyyy-MM"), was UUID() — every
        // refresh rebuilt every mark and broke chart transitions.
        let id: String
        let label: String
        let minutes: Double
    }

    // LS-14 (docs/design-review.md, Round 3): shared by the chart frame and its
    // empty-state placeholder so switching between an empty and a populated range
    // doesn't change the chart's height.
    fileprivate static let chartHeight: CGFloat = 160

    @ViewBuilder
    private var chart: some View {
        // `cachedBars`, not `bars(for: range)` — the whole point of the cache is
        // that this scan doesn't re-run per body pass. Refreshed by
        // `refreshChartBars()` from `load()` and from `range`'s `onChange`.
        let data = cachedBars
        if data.allSatisfy({ $0.minutes == 0 }) {
            Typo.supporting(Text("No listening logged in this range yet."))
                .foregroundStyle(Color.shelfMuted)
                .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
        } else {
            // Critique 2026-10-06 (distill → layout): past two hours the Y axis counts in
            // hours ("50h", not "3000m"), on round ticks (`StatsChartAxis`).
            let maxMinutes = data.map(\.minutes).max() ?? 0
            let unit = StatsChartAxis.unit(maxMinutes: maxMinutes)
            let yTicks = StatsChartAxis.ticks(maxMinutes: maxMinutes)
            Chart(data) { bar in
                BarMark(
                    x: .value("Period", bar.label),
                    y: .value("Minutes", bar.minutes)
                )
                // Critique 2026-10-06 (colorize): data fill is shelfAmber.
                .foregroundStyle(Color.shelfAmber)
                .cornerRadius(3)
                .accessibilityLabel(bar.label)
                .accessibilityValue(StatsFormat.spoken(bar.minutes * 60))
            }
            .chartYScale(domain: 0...(yTicks.last ?? max(maxMinutes, 1)))
            .chartXAxis {
                // Bug fix (26 August 2026): `x: .value("Period", bar.label)` is a
                // *nominal* (`String`-keyed) axis, where `.automatic(desiredCount:)` has
                // no effect, so the only way to thin it is to list which category values
                // get a mark. Week (7 "EEE") and Year (12 "MMM") fit; Month (30 "MMM d")
                // shows `monthAxisTickLabels(data)`'s evenly-spaced subset.
                // HL-4 (V4): at accessibility sizes the week's labels shrink to their
                // first letter and the month and year axes show fewer marks.
                let large = dynamicTypeSize.isAccessibilitySize
                let values: [String] = {
                    switch range {
                    case .week:  return data.map(\.label)
                    case .month: return large ? ChartAxisLabels.thinned(data.map(\.label), limit: 3) : monthAxisTickLabels(data)
                    case .year:  return large ? ChartAxisLabels.thinned(data.map(\.label), limit: 4) : data.map(\.label)
                    }
                }()
                AxisMarks(values: values) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(ChartAxisLabels.drawn(label, narrow: large && range == .week))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                }
            }
            .chartYAxis {
                // Bare numbers ("150") are ambiguous — minutes, hours, sessions? Every
                // tick carries its unit.
                AxisMarks(values: yTicks) { value in
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(StatsChartAxis.label(minutes: minutes, unit: unit))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                }
            }
            .frame(height: StatsView.chartHeight)
        }
    }

    // MARK: - Derived data

    private func bars(for range: StatRange) -> [Bar] {
        guard let days = stats?.days else { return [] }
        let cal = Calendar.current
        // Shared, pre-built formatters (see `StatsDateFormatters` at the top of this
        // file) rather than a fresh `DateFormatter()` per call — constructing one is
        // expensive, and this is called for every chart refresh.
        let keyF = StatsDateFormatters.dayKey

        switch range {
        case .week:  return dailyBars(count: 7, labelFormatter: StatsDateFormatters.weekday, days: days, cal: cal, keyF: keyF)
        // "d" alone (bare day-of-month number) silently resets from 31 back to 1 once
        // the trailing-30-day window crosses a month boundary, with nothing on the axis
        // to signal the jump — looked like the chart was broken rather than just showing
        // a new month. "MMM d" fixes that; the x-axis only ever shows a handful of the
        // 30 labels anyway (see `monthAxisTickLabels(_:)`, used by `chart`'s
        // `.chartXAxis`), so this doesn't crowd the axis.
        case .month: return dailyBars(count: 30, labelFormatter: StatsDateFormatters.monthDay, days: days, cal: cal, keyF: keyF)
        case .year:  return monthlyBars(days: days, cal: cal, keyF: keyF)
        }
    }

    /// Evenly-spaced subset of Month's 30 daily bar labels to actually show on the
    /// x-axis — see `chart`'s `.chartXAxis` for why this exists (a nominal/
    /// `String`-keyed axis doesn't thin itself the way a continuous one does).
    /// Picks roughly 5 labels (index 0, then every `stride`-th) rather than a fixed
    /// list of indices, so this still degrades sanely if `dailyBars(count:)` is ever
    /// called with a different count than 30.
    private func monthAxisTickLabels(_ data: [Bar]) -> [String] {
        guard data.count > 1 else { return data.map(\.label) }
        let desiredTicks = 5
        let stride = max(1, data.count / desiredTicks)
        return Swift.stride(from: 0, to: data.count, by: stride).map { data[$0].label }
    }

    /// `labelFormatter` is passed in (rather than a format *string* built into a local
    /// `DateFormatter` here) so callers hand over one of the shared
    /// `StatsDateFormatters` instances instead of allocating one per call.
    private func dailyBars(count: Int, labelFormatter lf: DateFormatter, days: [String: Double],
                           cal: Calendar, keyF: DateFormatter) -> [Bar] {
        return (0..<count).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = keyF.string(from: date)
            return Bar(id: key, label: lf.string(from: date), minutes: (days[key] ?? 0) / 60)
        }
    }

    private func monthlyBars(days: [String: Double], cal: Calendar, keyF: DateFormatter) -> [Bar] {
        let lf = StatsDateFormatters.month
        return (0..<12).reversed().map { offset in
            let monthDate = cal.date(byAdding: .month, value: -offset, to: Date()) ?? Date()
            let target = cal.dateComponents([.year, .month], from: monthDate)
            let total = days.reduce(0.0) { sum, entry in
                guard let d = keyF.date(from: entry.key) else { return sum }
                let c = cal.dateComponents([.year, .month], from: d)
                return (c.year == target.year && c.month == target.month) ? sum + entry.value : sum
            }
            return Bar(id: "\(target.year ?? 0)-\(target.month ?? 0)", label: lf.string(from: monthDate), minutes: total / 60)
        }
    }

    private func formatHours(_ seconds: Double) -> String { Self.formatHoursText(seconds) }

    fileprivate static func formatHoursText(_ seconds: Double) -> String { StatsFormat.hours(seconds) }
}

/// One Recent Sessions row, shared by the inline list and the "See all" list.
private struct SessionRow: View {
    let session: ListeningSession

    var body: some View {
        HStack(spacing: Space.m) {
            if let itemId = session.libraryItemId {
                CoverImageView(itemId: itemId, width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: Radius.thumb).fill(Color.shelfSurface)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "waveform").foregroundStyle(Color.shelfMuted))
            }
            VStack(alignment: .leading, spacing: 2) {
                Typo.rowTitle(session.displayTitle.map { Text(verbatim: $0) } ?? Text("Unknown title"))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)
                Typo.rowSubtitle(Text(StatsView.sessionSubtitle(session)))
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            if let date = session.date {
                Typo.fine(Text(date, format: .relative(presentation: .named)))
                    .foregroundStyle(Color.shelfMuted)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(minHeight: 44)
    }
}

/// Critique 2026-10-06 (distill → layout): a session row that opens its book, when the
/// session names one. Same `NavigationLink(destination: BookDetailView(...))` push as
/// Home and Library; the item is resolved on arrival by `SessionBookDestination`.
private struct SessionLinkRow: View {
    let session: ListeningSession

    var body: some View {
        if let itemId = session.libraryItemId {
            NavigationLink {
                SessionBookDestination(itemId: itemId, title: session.displayTitle)
            } label: {
                HStack(spacing: Space.s) {
                    SessionRow(session: session)
                    Image(systemName: "chevron.right")
                        .scaledFont(13, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(Color.shelfMuted)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the book")
        } else {
            SessionRow(session: session)
                .accessibilityElement(children: .combine)
        }
    }
}

/// Resolves a session's book and shows its detail page. A downloaded copy is used
/// first (works offline, as All Bookmarks does), else the server's item through
/// `LibraryViewModel.getItemDetail` (the API type, with its refresh-and-retry).
private struct SessionBookDestination: View {
    let itemId: String
    let title: String?

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var item: LibraryItem?
    @State private var failed = false

    var body: some View {
        Group {
            if let item {
                BookDetailView(item: item)
            } else {
                ZStack {
                    Color.shelfBackground.ignoresSafeArea()
                    if failed {
                        EmptyStateView(icon: "book.closed", title: LocalizedStringResource("Couldn\u{2019}t open this book"),
                                       subtitle: .verbatim(StatsStaleness.failureSubtitle(status: ReachabilityStore.shared.status)),
                                       actionTitle: LocalizedStringResource("Retry"),
                                       action: { Task { await resolve() } })
                    } else {
                        if let title {
                            LoadingView("Opening \(title)\u{2026}")
                        } else {
                            LoadingView("Opening book\u{2026}")
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard item == nil else { return }
        failed = false
        if let local = DownloadManager.shared.libraryItem(for: itemId) {
            item = local
        } else if let fetched = await libraryViewModel.getItemDetail(itemId: itemId) {
            item = fetched
        } else {
            failed = true
        }
    }
}

/// Critique 2026-10-06 (peak-end): the full fetched session history behind "See all".
private struct SessionsListView: View {
    let sessions: [ListeningSession]
    let bottomClearance: CGFloat

    var body: some View {
        List(sessions) { session in
            SessionLinkRow(session: session)
                .listRowBackground(Color.shelfBackground)
                .listRowSeparatorTint(Color.shelfSurface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.shelfBackground.ignoresSafeArea())
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .navigationTitle("Recent Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The hero's last line, and the *only* thing on the Stats tab that reads playback state:
/// the pace sentence beside the playing book's cover, or (with no pace) the recent
/// session length (`StatsHeroLine.choose`).
///
/// Deliberately its own view (it replaced `PaceCard`, which replaced a computed property
/// on `StatsView`). It reads `playerViewModel.currentTime`, which updates 2-6 times a
/// second while audio is playing. Read from `StatsView.body`, Observation tracked the
/// player against the whole screen's body, so every tick re-ran the streak/month/chart
/// scans over the entire `stats.days` map. Isolating the read here means only this small
/// body re-evaluates on tick. `days` and `sessionSummary` are handed over as plain values
/// for the same reason.
private struct HeroPaceLine: View {
    let days: [String: Double]?
    let sessionSummary: String?

    @Environment(PlayerViewModel.self) private var playerViewModel

    /// Computed inline rather than cached: it genuinely depends on `currentTime`, and the
    /// work is a bounded 7-iteration lookup against a shared pre-built formatter.
    private var paceText: String? {
        guard let book = playerViewModel.currentBook, playerViewModel.duration > 60 else { return nil }
        let remaining = max(0, playerViewModel.duration - playerViewModel.currentTime)
        guard let daysToFinish = StatsPace.daysToFinish(remainingSeconds: remaining, days: days, today: Date()) else { return nil }
        return StatsPace.sentence(title: book.title, days: daysToFinish)
    }

    var body: some View {
        switch StatsHeroLine.choose(pace: paceText, sessionSummary: sessionSummary) {
        case .pace(let text):
            HStack(spacing: Space.m) {
                if let book = playerViewModel.currentBook {
                    CoverImageView(itemId: book.id, width: 44, height: 44)
                        .accessibilityHidden(true)
                }
                Typo.metadata(Text(text))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .sessions(let text):
            Typo.supporting(Label(text, systemImage: "timer"))
                .foregroundStyle(Color.shelfMuted)
        case .none:
            EmptyView()
        }
    }
}

/// A small ring showing today's listening progress toward `goalMinutes`. `goalMinutes
/// <= 0` means the goal is off — shown as a dim, empty ring rather than hidden
/// entirely, so the affordance to turn it back on (the goal menu beside it) stays visible.
private struct DailyGoalRing: View {
    let progressMinutes: Double
    let goalMinutes: Double

    private var fraction: Double {
        guard goalMinutes > 0 else { return 0 }
        return min(progressMinutes / goalMinutes, 1)
    }
    private var isGoalOff: Bool { goalMinutes <= 0 }
    private var isComplete: Bool { !isGoalOff && progressMinutes >= goalMinutes }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.shelfSurface, lineWidth: 5)
            Circle()
                .trim(from: 0, to: isGoalOff ? 0 : max(0.02, fraction))
                // Live state, so the accent fill (the One Light Rule).
                .stroke(Color.shelfAmber, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // AN-8 (docs/design-review.md, Round 6): the trim used to snap. Filling is
                // part of the reward for an Activity-style ring. Scoped to the filled arc
                // and keyed on `fraction`; Reduce Motion gets the new value instantly.
                .shelfAnimation(.easeOut(duration: 0.6), value: fraction)
            if isComplete {
                Image(systemName: "checkmark")
                    // Critique 2026-10-06 (harden): scales with Dynamic Type (was a fixed 18pt).
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.shelfAmberTextOnSurface)
            }
        }
        .accessibilityHidden(true)   // the goal row's own label and value cover this
    }
}

// MARK: - LS-6 skeleton (docs/design-review.md, Round 3)

/// A placeholder for `StatsView`'s first load (and Try Again), mirroring the real screen:
/// the hero card, the figure row on the ground, then the Listening section's header,
/// picker and chart. Stops after roughly one screen.
///
/// Pulses exactly like `SkeletonTile` (Extensions.swift): a single Reduce-Motion-guarded
/// `repeatForever` opacity pulse, applied once to the whole stack rather than per bar.
private struct StatsSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private func bar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.shelfSurface)
            .frame(width: width, height: height)
    }

    private var heroSkeleton: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                bar(width: 90, height: 9)
                bar(width: 170, height: 32)
            }
            HStack(spacing: Space.m) {
                Circle().fill(Color.shelfSurface).frame(width: 36, height: 36)
                bar(width: 130, height: 10)
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.m) {
                RoundedRectangle(cornerRadius: Radius.thumb).fill(Color.shelfSurface).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 180, height: 10)
                    bar(width: 120, height: 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Color.shelfCard)
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero))
        .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.hero))
    }

    private var figureSkeleton: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(width: 52, height: 20)
            bar(width: 60, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                heroSkeleton
                HStack(spacing: Space.l) { figureSkeleton; figureSkeleton; figureSkeleton; figureSkeleton }
                VStack(alignment: .leading, spacing: Space.m) {
                    bar(width: 90, height: 9)
                    bar(width: 160, height: 14)
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(Color.shelfSurface)
                        .frame(height: 32)   // segmented-picker-shaped bar
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(Color.shelfSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: StatsView.chartHeight)
                }
            }
            .padding(.horizontal, Space.pageH)
            .padding(.top, Space.m)
        }
        .scrollDisabled(true)   // static placeholder — nothing real to scroll to yet
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        // Internals are decorative shapes with no individual meaning; `.ignore`
        // collapses them out of the accessibility tree entirely, leaving this single
        // labelled element in their place.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading stats\u{2026}")
    }
}
