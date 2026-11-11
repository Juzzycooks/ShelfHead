import SwiftUI
import Charts
import UIKit

/// A "Year in Review" summary (F5), built entirely from data the app already fetches
/// for `StatsView` — no new server endpoints.
///
/// **Card grid restored 15 September 2026.** Batch 318 (P-12,
/// REVIEW_2026-09-14_DESIGN.md) replaced this screen's card grid with a full-bleed
/// `TabView(.page)` pager — one stat per swipe — on the argument that the grid was
/// indistinguishable from the Listening tab. Seen on device, the pager read as ugly,
/// so by user decision the grid is back: a hero year card, a two-column matrix of
/// stat tiles, then the full-width Most-Listened Author and Minutes-by-Month cards.
/// Two things from P-12 are deliberately *kept* rather than reverted with it:
///
/// - The all-time "Books Finished" card and its inline apology ("your server doesn't
///   record a completion date…") stay removed. Batch 459 corrected the premise behind
///   them: `/api/me`'s `mediaProgress[].finishedAt` IS a completion date, so the screen
///   now shows a year-scoped "finished this year" count and spine row from
///   `FinishedBookCatalog` (see `finishedThisYearSection`) instead of the all-time figure.
/// - Best Streak is still a lifetime record, and that caveat still lives behind an ⓘ
///   popover (plus an "(all-time)" suffix on the card's own label) rather than as
///   inline body copy.
///
/// The share flow is also kept as P-12 left it — the real `ShareCardRenderer`
/// machinery rather than an `ImageRenderer` screenshot of this screen — but collapsed
/// back to a single toolbar Share button rendering one summary card, since there are
/// no longer per-page share affordances to hang it off.
///
/// **Critique 2026-10-06 (shape → bolder).** This is the app's one celebratory moment, and
/// it read as a fifth Stats screen: a hero that repeated the year picker, four identical
/// tiles, and no covers. Now: the year's hours as the big tape-counter figure, the year's
/// most-played covers as hero art, the secondary figures as a hairline spec list on the
/// ground (no cards), then the monthly chart. Sharing opens the shared composer on a
/// dedicated `.yearInReview` card (ShareCard.swift) with those covers.
struct YearInReviewView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Batch 459: books finished per year, from `/api/me` `finishedAt`.
    private let finishedCatalog = FinishedBookCatalog.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // LS-7 (docs/design-review.md, Round 3): needed to animate the year-switch
    // refresh (dim/undim, numeric cross-fade) the same Reduce-Motion-aware way as
    // the rest of the app.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var bottomInset: CGFloat = 0

    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var stats: ListeningStats?
    @State private var yearSessions: [ListeningSession] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    // LS-7 (docs/design-review.md, Round 3): a year switch (`.onChange(of:
    // selectedYear)`) no longer blanks the grid — it calls `load(showLoader:
    // false)`, which drives this instead of `isLoading` so the old grid can stay up,
    // dimmed, while the new figures load.
    @State private var isRefreshing = false
    // LS-7: bumped by every `load()` call; a call that finds itself no longer the
    // latest generation when its network work finishes discards its result instead
    // of overwriting a newer year's figures.
    @State private var loadGeneration = 0
    // Y7 (REVIEW_2026-09-04_UI.md): set from `loadSessions(forYear:)`'s returned
    // `mayBeIncomplete` when the 20-page cap was hit before paging reached the start
    // of the selected year, so the stats derived from `yearSessions` may be
    // undercounted.
    @State private var sessionsMayBeIncomplete = false
    // Critique 2026-10-06 (harden): a failed sessions fetch used to read as "0 Books Touched".
    // Set when the very first page couldn't be fetched; session-derived figures show an
    // honest "unavailable" instead of 0.
    @State private var sessionsUnavailable = false
    // Critique 2026-10-06 (harden): when the last good stats landed, for the stale-figures line.
    @State private var statsLoadedAt: Date?
    // January default (see `defaultYear`): picked once, on the first load.
    @State private var didPickDefaultYear = false
    @State private var skipNextYearChange = false
    private let reachability = ReachabilityStore.shared

    // MARK: - Share (one summary card, from the toolbar)

    @State private var isSharing = false
    // Critique 2026-10-06 (shape → bolder): the share opens `ShareComposerSheet` on the
    // `.yearInReview` card (format, privacy, Remix, live preview) instead of a fixed
    // one-image preview sheet.
    @State private var shareSession: ShareSession?
    /// Batch 462: the "Make a Video" sheet's data, set when the toolbar button is tapped.
    @State private var reelData: YearInReviewReelData?

    /// The content column's width, for sizing the top covers.
    @State private var contentWidth: CGFloat = 0

    // MARK: - Info popover (the lifetime caveat lives here, not inline body copy)

    @State private var infoPresentedKind: YearInReviewCard.Kind?

    /// UI-12: now the shared `bottomBarClearance` helper (Extensions.swift) instead of
    /// an independently-maintained copy.
    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    /// The current year plus the two before it — a self-hosted server's listening
    /// history realistically only goes back a few years for most users.
    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return [current, current - 1, current - 2]
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading {
                // LS-6 (docs/design-review.md, Round 3): a card-shaped skeleton
                // mirroring `grid`'s real layout (year picker row, hero, tile grid,
                // wide cards, monthly chart) in place of the shapeless centred
                // spinner. This is the full first-load/account-change path only —
                // LS-7's year-switch refresh uses `isRefreshing` and keeps `grid`
                // itself on screen (dimmed), never routing through here.
                YearInReviewSkeleton()
                    .transition(.opacity)
            } else if loadFailed && stats == nil {
                // Critique 2026-10-06 (harden): offline vs server-unreachable wording, and the
                // retry is EmptyStateView's own 44pt primary button (it used to float at a
                // fixed 40pt, ignoring the mini-player/tab-bar clearance).
                EmptyStateView(icon: "sparkles", title: LocalizedStringResource("Couldn’t load this year"),
                               subtitle: .verbatim(StatsStaleness.failureSubtitle(status: reachability.status)),
                               actionTitle: LocalizedStringResource("Retry"),
                               action: { Task { await load() } })
                    .padding(.bottom, bottomClearance)
            } else {
                grid
                    .transition(.opacity)
            }
        }
        // LS-6 (docs/design-review.md, Round 3): cross-fades the skeleton into the
        // loaded grid (and back, on an account-change reload). LS-7's year-switch
        // refresh has its own `isRefreshing`-driven dim/undim animation on `grid`
        // itself (see `grid`'s `.shelfAnimation(.default, value: isRefreshing)`) and
        // never touches `isLoading`, so the two animations don't collide.
        .shelfAnimation(.easeInOut(duration: 0.25), value: isLoading)
        .navigationTitle("Year in Review")
        .navigationBarTitleDisplayMode(.inline)
        // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { videoToolbarButton }.shelfVisibilityPriority(.low)
            ToolbarItem(placement: .topBarTrailing) { shareToolbarButton }.shelfVisibilityPriority(.high)
        }
        .sheet(item: $reelData) { data in
            YearInReviewVideoSheet(data: data)
        }
        // Y5 (REVIEW_2026-09-04_UI.md) kept: the card is previewed before anything is
        // written to disk; the composer's live preview does that now, and it presents the
        // activity sheet from inside itself (sheet-over-sheet).
        .sheet(item: $shareSession) { session in
            ShareComposerSheet(context: session.context)
        }
        .task { await load() }
        .task { await finishedCatalog.refresh() }
        // LS-7 (docs/design-review.md, Round 3): `showLoader: false` so a year switch
        // keeps the existing grid on screen (dimmed via `isRefreshing`, see `grid`)
        // instead of replacing it with the full-screen "Building your year…" loader.
        .onChange(of: selectedYear) { _, _ in
            if skipNextYearChange { skipNextYearChange = false; return }
            Task { await load(showLoader: false) }
        }
        // Design review 2026-09-23 UX-2: if the account switches while this screen is
        // still on the nav stack, drop the stale account's figures (and any per-account
        // preview) and reload for the new one — mirrors StatsView.swift's handler
        // (~204-213) for the same notification.
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
            stats = nil
            statsLoadedAt = nil
            yearSessions = []
            sessionsUnavailable = false
            shareSession = nil
            isLoading = true
            // LS-7: an account change is always a full reload, never a refresh — make
            // sure a mid-flight year-switch refresh from the old account can't land
            // afterwards and stomp the new account's figures.
            isRefreshing = false
            Task { await load() }
        }
        .reexpandsTabBarOnAppear()
    }

    // MARK: - Loading

    /// `showLoader == true` (the initial `.task`, and the account-change reload)
    /// replaces the whole screen with `LoadingView`. `.onChange(of: selectedYear)`
    /// instead calls this with `showLoader: false` — LS-7 (docs/design-review.md,
    /// Round 3): the previous grid stays up, dimmed and disabled via `isRefreshing`
    /// while this runs, with a small inline spinner by the year picker, rather than
    /// being blanked by the full-screen loader on every year switch.
    private func load(showLoader: Bool = true) async {
        // LS-7: a generation counter so a rapid year switch can't let an older,
        // still in-flight refresh land after — and overwrite the figures from — a
        // newer one. (The year picker only exists once `grid` is on screen, i.e.
        // once the first `showLoader: true` load has already finished, so a full
        // load and a refresh can never actually race here — only refresh-vs-refresh
        // needs guarding.)
        loadGeneration += 1
        let generation = loadGeneration
        var year = selectedYear
        if showLoader {
            isLoading = true
        } else {
            isRefreshing = true
        }
        loadFailed = false
        var fetchedStats: ListeningStats?
        do {
            fetchedStats = try await AudiobookshelfAPI.shared.getListeningStats()
        } catch {
            guard generation == loadGeneration else { return }
            loadFailed = true
        }
        // Critique 2026-10-06 (harden): in January, with nothing logged yet this year, open
        // on last year's review (the one people are actually there to read).
        if !didPickDefaultYear, let days = (fetchedStats ?? stats)?.days {
            didPickDefaultYear = true
            let pick = Self.defaultYear(now: Date(), days: days, calendar: Calendar.current)
            if pick != year {
                year = pick
                skipNextYearChange = true
                selectedYear = pick
            }
        }
        let (sessions, incomplete, unavailable) = await loadSessions(forYear: year)
        guard generation == loadGeneration else { return }
        if fetchedStats != nil { statsLoadedAt = Date() }

        if showLoader {
            if let fetchedStats { stats = fetchedStats }
            yearSessions = sessions
            sessionsMayBeIncomplete = incomplete
            sessionsUnavailable = unavailable
            isLoading = false
        } else {
            // LS-7: cross-fade the headline figures in as the new numbers land
            // instead of snapping — `.contentTransition(.numericText())` on the
            // value Texts (hero/figureRow) needs an animation context around the
            // values actually changing in order to animate rather than jump.
            withAnimation(reduceMotion ? nil : .default) {
                if let fetchedStats { stats = fetchedStats }
                yearSessions = sessions
                sessionsMayBeIncomplete = incomplete
                sessionsUnavailable = unavailable
                isRefreshing = false
            }
        }
        // A card that existed for the previous year (e.g. Most-Listened Author, which
        // only appears when there's data) may not exist for this one; the grid is
        // rebuilt from `cards` every pass, so nothing here needs resetting — but an
        // open popover could otherwise outlive its card.
        infoPresentedKind = nil
    }

    // Y7 (REVIEW_2026-09-04_UI.md): paging bounds for `loadSessions(forYear:)`, kept as
    // named constants so the incomplete-data caption below can state the exact number
    // of sessions the cap represents.
    private static let sessionPageCap = 20
    private static let sessionsPerPage = 50

    /// Sessions are returned newest-first, so paging stops as soon as a page's oldest
    /// session predates the target year — bounded to `sessionPageCap` pages so a
    /// long-lived account can't turn this into an unbounded fetch. If the cap is hit
    /// before that year-boundary break fires, the returned `mayBeIncomplete` flag is
    /// set so the UI can flag that the figures below may be undercounted (Y7).
    ///
    /// LS-7 (docs/design-review.md, Round 3): returns the flag rather than assigning
    /// straight to `sessionsMayBeIncomplete`, so `load()` can commit it together with
    /// `yearSessions` behind its stale-result generation guard instead of a call that
    /// turns out to be superseded writing it directly.
    private func loadSessions(forYear year: Int) async -> (sessions: [ListeningSession], mayBeIncomplete: Bool, unavailable: Bool) {
        var all: [ListeningSession] = []
        var page = 0
        let maxPages = Self.sessionPageCap
        var reachedYearStart = false
        var failed = false
        while page < maxPages {
            // Critique 2026-10-06 (harden): was `try?`, which turned a failed fetch into an
            // empty history and so "0 Books Touched".
            let batch: [ListeningSession]
            do {
                batch = try await AudiobookshelfAPI.shared.getListeningSessions(page: page, itemsPerPage: Self.sessionsPerPage)
            } catch {
                failed = true
                break
            }
            if batch.isEmpty { break }
            all.append(contentsOf: batch)
            let oldestInBatch = batch.compactMap(\.date).min()
            page += 1
            if let oldest = oldestInBatch, Calendar.current.component(.year, from: oldest) < year {
                reachedYearStart = true
                break
            }
        }
        // First page failed: nothing to show, so "unavailable". A later page failing leaves
        // partial data, which is the existing "may be undercounted" case.
        let unavailable = failed && page == 0
        let mayBeIncomplete = !unavailable && (failed
            || Self.sessionsAreIncomplete(pagesFetched: page, maxPages: maxPages, reachedYearStart: reachedYearStart))
        let filtered = all.filter { session in
            guard let date = session.date else { return false }
            return Calendar.current.component(.year, from: date) == year
        }
        return (filtered, mayBeIncomplete, unavailable)
    }

    /// Critique 2026-10-06 (harden): in January with no listening logged under the current
    /// year yet, the review worth showing is last year's. Pure so it's unit-tested.
    static func defaultYear(now: Date, days: [String: Double], calendar: Calendar) -> Int {
        let current = calendar.component(.year, from: now)
        guard calendar.component(.month, from: now) == 1 else { return current }
        let prefix = String(format: "%04d-", current)
        let hasData = days.contains { $0.key.hasPrefix(prefix) && $0.value > 0 }
        return hasData ? current : current - 1
    }

    /// Y7 (REVIEW_2026-09-04_UI.md): pure predicate pulled out of `loadSessions(forYear:)`
    /// so it can be unit-tested without going through the network call — the loop can
    /// exit either because it reached the target year's start (`reachedYearStart`,
    /// figures are complete) or because it ran out of pages first (figures may be
    /// undercounted).
    static func sessionsAreIncomplete(pagesFetched: Int, maxPages: Int, reachedYearStart: Bool) -> Bool {
        pagesFetched >= maxPages && !reachedYearStart
    }

    // MARK: - Aggregation

    private var totalSecondsThisYear: Double {
        guard let days = stats?.days else { return 0 }
        let keyF = DayKey.shared
        return days.reduce(0.0) { sum, entry in
            guard let d = keyF.date(from: entry.key) else { return sum }
            return Calendar.current.component(.year, from: d) == selectedYear ? sum + entry.value : sum
        }
    }

    private var distinctBooksThisYear: Int {
        Set(yearSessions.compactMap(\.libraryItemId)).count
    }

    private var topAuthorThisYear: (name: String, seconds: Double)? {
        var totals: [String: Double] = [:]
        for session in yearSessions {
            guard let author = session.displayAuthor, !author.isEmpty else { continue }
            totals[author, default: 0] += clampedListened(session)
        }
        return totals.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    private var longestSessionThisYear: Double {
        yearSessions.map(clampedListened).max() ?? 0
    }

    private func clampedListened(_ session: ListeningSession) -> Double {
        Self.clampedListened(session)
    }

    /// A single session can't have listened longer than the book itself — some servers
    /// report a corrupted/unsynced `timeListening`; clamp to the book's duration
    /// (same guard `StatsView.clampedListened` uses).
    static func clampedListened(_ session: ListeningSession) -> Double {
        let raw = max(session.timeListening ?? 0, 0)
        if let d = session.duration, d > 0 { return min(raw, d) }
        return raw
    }

    /// Critique 2026-10-06 (shape → bolder): the year's books, most-played first.
    private var rankedBooksThisYear: [YearInReviewTopBook] {
        Self.rankedBooks(from: yearSessions)
    }

    /// Ranks the books in `sessions` by total (clamped) listening time, most first. Ties
    /// break by title, then id, so the order is stable. Sessions with no item id, and
    /// books with no listening time at all, aren't ranked (they still count towards
    /// Books Played). Pure, so `YearInReviewTopBooksTests` pins it.
    static func rankedBooks(from sessions: [ListeningSession]) -> [YearInReviewTopBook] {
        var books: [String: YearInReviewTopBook] = [:]
        for session in sessions {
            guard let id = session.libraryItemId, !id.isEmpty else { continue }
            let seconds = clampedListened(session)
            let title = session.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let author = session.displayAuthor?.trimmingCharacters(in: .whitespacesAndNewlines)
            if var book = books[id] {
                book.seconds += seconds
                if book.title.isEmpty { book.title = title }
                if book.author?.isEmpty != false, let author, !author.isEmpty { book.author = author }
                books[id] = book
            } else {
                books[id] = YearInReviewTopBook(id: id, title: title,
                                                author: (author?.isEmpty == false) ? author : nil,
                                                seconds: seconds)
            }
        }
        return books.values
            .filter { $0.seconds > 0 }
            .sorted { a, b in
                if a.seconds != b.seconds { return a.seconds > b.seconds }
                if a.title != b.title { return a.title < b.title }
                return a.id < b.id
            }
    }

    /// The hero figure: whole hours ("212" "hours"), or minutes under an hour ("45"
    /// "minutes"). Pure and unit-tested.
    static func heroFigure(totalSeconds: Double) -> (value: String, unit: String) {
        // Polish pass (CR-1): Int(Double) traps on NaN/infinity.
        let seconds = totalSeconds.isFinite ? max(totalSeconds, 0) : 0
        let hours = Int(seconds) / 3600
        if hours >= 1 { return (String(hours), hours == 1 ? String(localized: "hour", comment: "Unit word under a big number (singular)") : String(localized: "hours", comment: "Unit word under a big number (plural)")) }
        let minutes = Int(seconds) / 60
        return (String(minutes), minutes == 1 ? String(localized: "minute", comment: "Unit word under a big number (singular)") : String(localized: "minutes", comment: "Unit word under a big number (plural)"))
    }

    private var monthlyBarsThisYear: [Bar] {
        guard let days = stats?.days else { return [] }
        let cal = Calendar.current
        let keyF = DayKey.shared
        let lf = DateFormatter(); lf.setLocalizedDateFormatFromTemplate("MMM")
        return (1...12).map { month in
            var comps = DateComponents(); comps.year = selectedYear; comps.month = month; comps.day = 1
            let monthDate = cal.date(from: comps) ?? Date()
            let total = days.reduce(0.0) { sum, entry in
                guard let d = keyF.date(from: entry.key) else { return sum }
                let c = cal.dateComponents([.year, .month], from: d)
                return (c.year == selectedYear && c.month == month) ? sum + entry.value : sum
            }
            return Bar(label: lf.string(from: monthDate), minutes: total / 60)
        }
    }

    /// Shown in place of a session-derived figure when the sessions fetch failed.
    static let unavailableValue = "\u{2014}"

    static func formatHours(_ seconds: Double) -> String {
        // Polish pass (CR-1): Int(Double) traps on NaN/infinity.
        let whole = seconds.isFinite ? Int(max(seconds, 0)) : 0
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m", comment: "Compact duration: hours and minutes") }
        return String(localized: "\(minutes)m", comment: "Compact duration: minutes")
    }

    /// Y7's undercount caveat, worded once here so every card that needs it (anything
    /// derived from `yearSessions`) states the same figure.
    private var incompleteSessionsNote: String {
        String(localized: "Based on your most recent \(Self.sessionPageCap * Self.sessionsPerPage) sessions — you may have listened more than we fetched.", comment: "%lld is a number of sessions")
    }

    /// The stat cards for the selected year, in display order. Built by the pure,
    /// unit-tested `YearInReviewView.buildCards(...)` — this computed property just
    /// supplies it with the view's already-fetched, already-aggregated numbers.
    private var cards: [YearInReviewCard] {
        let author = topAuthorThisYear
        return Self.buildCards(
            year: selectedYear,
            totalSeconds: totalSecondsThisYear,
            distinctBooks: distinctBooksThisYear,
            topAuthor: author,
            longestSessionSeconds: longestSessionThisYear,
            bestStreakDays: stats?.bestStreak ?? 0,
            monthlyBars: monthlyBarsThisYear,
            sessionsMayBeIncomplete: sessionsMayBeIncomplete,
            incompleteSessionsNote: incompleteSessionsNote,
            sessionsUnavailable: sessionsUnavailable,
            topAuthorCoverItemId: author.flatMap { a in rankedBooksThisYear.first { $0.author == a.name }?.id }
        )
    }

    /// Pure card-building function — no network, no view state beyond its arguments —
    /// so it's pinned by `YearInReviewPagesTests.swift` rather than only exercised
    /// through the live view. Follows this project's "extract a pure function when a
    /// bug fix needs a regression test" precedent (see `DownloadManager
    /// .shouldReclaimOrphanDirectory`, `sessionsAreIncomplete` above).
    ///
    /// Returns cards in *display* order: the hero (total listened), then the figures
    /// (Books Played, Longest Session, Most-Listened Author, Best Streak), then the chart,
    /// so the view lays the screen out by filtering on `placement`.
    static func buildCards(
        year: Int,
        totalSeconds: Double,
        distinctBooks: Int,
        topAuthor: (name: String, seconds: Double)?,
        longestSessionSeconds: Double,
        bestStreakDays: Int,
        monthlyBars: [Bar],
        sessionsMayBeIncomplete: Bool,
        incompleteSessionsNote: String,
        sessionsUnavailable: Bool = false,
        topAuthorCoverItemId: String? = nil
    ) -> [YearInReviewCard] {
        var cards: [YearInReviewCard] = []
        // Critique 2026-10-06 (harden): figures derived from sessions are "unavailable", not 0,
        // when the sessions fetch failed. Same inline-note slot as the undercount caveat.
        let unavailableNote = String(localized: "Couldn\u{2019}t load your listening sessions, so figures based on them are unavailable.")
        let sessionNote: String? = sessionsUnavailable ? unavailableNote
            : (sessionsMayBeIncomplete ? incompleteSessionsNote : nil)

        // Critique 2026-10-06 (shape → bolder): the hero. The screen draws it as the big
        // figure (`heroFigure`); the label is what VoiceOver and the tests read.
        cards.append(YearInReviewCard(
            kind: .totalListened,
            placement: .hero,
            icon: "headphones",
            value: formatHours(totalSeconds),
            label: String(localized: "Listened in \(String(year))", comment: "Year in Review hero caption; %@ is a year such as 2026")
        ))

        // Critique 2026-10-06 (shape → bolder): "Books Touched" was jargon. Books Played.
        cards.append(YearInReviewCard(
            kind: .booksListened,
            placement: .figure,
            icon: "books.vertical.fill",
            value: sessionsUnavailable ? unavailableValue : "\(distinctBooks)",
            label: distinctBooks == 1 && !sessionsUnavailable ? String(localized: "Book Played") : String(localized: "Books Played"),
            incompleteNote: sessionNote
        ))

        cards.append(YearInReviewCard(
            kind: .longestSession,
            placement: .figure,
            icon: "waveform",
            value: sessionsUnavailable ? unavailableValue : formatHours(longestSessionSeconds),
            label: String(localized: "Longest Session"),
            incompleteNote: sessionNote
        ))

        if let topAuthor, !sessionsUnavailable {
            cards.append(YearInReviewCard(
                kind: .topAuthor,
                placement: .figure,
                icon: "person.fill",
                value: topAuthor.name,
                label: String(localized: "Most-Listened Author"),
                detail: String(localized: "\(formatHours(topAuthor.seconds)) this year", comment: "%@ is a duration such as 12h 5m"),
                incompleteNote: sessionNote,
                coverItemId: topAuthorCoverItemId
            ))
        }

        // Kept (it's a real number people want), but never presented as year-scoped:
        // the label says "(all-time)" and the full explanation sits behind the row's
        // ⓘ popover rather than as inline body copy. The all-time "Books Finished"
        // card is gone entirely (removed, not hidden); Batch 459 replaced it with the
        // year-scoped `finishedThisYearSection`, built on `finishedAt` from `/api/me`
        // (the earlier "no completion-date source" belief was wrong).
        cards.append(YearInReviewCard(
            kind: .bestStreak,
            placement: .figure,
            icon: "flame.fill",
            value: String(localized: "\(max(bestStreakDays, 0)) days", comment: "Streak length; %lld is a number of days"),
            label: String(localized: "Best Streak (all-time)"),
            caveat: String(localized: "This is a lifetime record — your server doesn’t track which year a streak happened in, so it may not have happened in \(String(year)).", comment: "%@ is a year such as 2026")
        ))

        cards.append(YearInReviewCard(
            kind: .monthlyChart,
            placement: .chart,
            icon: "chart.bar.fill",
            value: "",
            // Batch 490 (REVIEW 2026-11-11 A4): the axis counts hours past two hours, so not "Minutes".
            label: String(localized: "Listening by month")
        ))

        return cards
    }

    // MARK: - Layout

    /// The segmented year control plus a fixed-size slot for the LS-7 in-flight
    /// spinner, so the picker doesn't reflow when the spinner appears or disappears.
    private var yearPickerRow: some View {
        HStack(spacing: Space.s) {
            Picker("Year", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.segmented)

            // LS-7: delayed so a fast refresh never flashes it, matching this
            // project's other transport/loading spinners.
            ZStack {
                if isRefreshing {
                    DelayedProgressView(delay: .milliseconds(250)) {
                        ProgressView()
                            .shelfSpinner()   // LS-15: shared brand-spinner tint
                    }
                    .accessibilityLabel("Loading \(String(selectedYear))")
                }
            }
            .frame(width: 20, height: 20)
        }
    }

    /// The screen proper: year picker, then the hero figure, the top covers, the figure
    /// list and the monthly chart. Critique 2026-10-06 (shape → bolder): only the chart
    /// keeps `statPanelStyle()`; the hero, covers and figures sit on the ground, so the
    /// covers carry the colour and the screen stops reading as a wall of equal tiles.
    private var grid: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                yearPickerRow
                // Critique 2026-10-06 (harden): a failed refresh with figures already on
                // screen keeps them and says so, instead of replacing the screen.
                if loadFailed, stats != nil {
                    Typo.fine(Text(StatsStaleness.message(asOf: statsLoadedAt, now: Date(), status: reachability.status)))
                        .foregroundStyle(Color.shelfMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // LS-7 (docs/design-review.md, Round 3): while a year switch
                // refreshes in the background, keep the previous screen up rather than
                // blanking it — dim and disable it instead, undimming
                // (Reduce-Motion-aware) once the new figures land.
                VStack(spacing: Space.xl) {
                    hero
                    topCoversSection
                    figureList
                    finishedThisYearSection
                    if let note = cards.compactMap(\.incompleteNote).first {
                        // Shown once here rather than repeated on every affected row (it's
                        // the same sentence). Each affected row still speaks it in its own
                        // VoiceOver label, so the association isn't lost for non-visual use.
                        Typo.fine(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(cards.filter { $0.placement == .chart }) { card in
                        chartCard(card)
                    }
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .opacity(isRefreshing ? 0.5 : 1)
                .disabled(isRefreshing)
                .shelfAnimation(.default, value: isRefreshing)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            .padding(.bottom, bottomClearance + Space.l)
        }
    }

    // MARK: Finished this year

    /// Batch 459: how many books were finished in the selected year (from the catalog's
    /// `finishedAt`) and a row of their spines, linking to the Cassette Wall. Hidden when
    /// the year has none.
    @ViewBuilder private var finishedThisYearSection: some View {
        let finished = finishedCatalog.books
            .filter { Calendar.current.component(.year, from: $0.finishedAt) == selectedYear }
            .sorted(by: CassetteWallLayout.isNewer)
        if !finished.isEmpty {
            NavigationLink {
                CassetteWallView()
            } label: {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Typo.cardTitle(Text("Books finished this year"))
                            .foregroundStyle(Color.shelfCream)
                        Spacer(minLength: Space.s)
                        Typo.cardTitle(Text(finished.count, format: .number))
                            .foregroundStyle(Color.shelfCream)
                        Image(systemName: "chevron.right")
                            .scaledFont(13, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Color.shelfMuted)
                            .accessibilityHidden(true)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s) {
                            ForEach(finished.prefix(12)) { book in
                                CassetteSpineView(book: book, width: 30)
                            }
                        }
                    }
                    .scrollDisabled(true)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Books finished this year: \(finished.count)")
            .accessibilityHint("Opens the Cassette Wall")
        }
    }

    // MARK: Hero

    /// Critique 2026-10-06 (shape → bolder): the year's hours as the screen's one big
    /// tape-counter figure ("212 hours", "in 2026"). It replaces a hero that only
    /// repeated the year already selected in the picker above it. Cream, not amber: the
    /// figure is a readout, not a control (One Light).
    private var hero: some View {
        let figure = Self.heroFigure(totalSeconds: totalSecondsThisYear)
        let year = String(selectedYear)
        let figureLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.s))
        return VStack(spacing: Space.s) {
            figureLayout {
                Text(figure.value)
                    // A scaled display size (relative to Large Title, so it still grows
                    // with Dynamic Type); there is no Typo role this large.
                    .scaledFont(76, weight: .bold, design: .monospaced, relativeTo: .largeTitle)
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                Text(figure.unit)
                    .scaledFont(24, weight: .semibold, design: .rounded, relativeTo: .title2)
                    .foregroundStyle(Color.shelfCream)
            }
            Typo.metadata(Text("in \(year)"))
                .foregroundStyle(Color.shelfMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(figure.value) \(figure.unit) listened in \(year)")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Top covers

    /// Critique 2026-10-06 (shape → bolder): the year's most-played books, as hero art.
    /// Hidden when the sessions couldn't be loaded (the note below says so) or there's
    /// nothing ranked yet.
    @ViewBuilder private var topCoversSection: some View {
        let books = Array(rankedBooksThisYear.prefix(3))
        if !books.isEmpty, !sessionsUnavailable {
            VStack(alignment: .leading, spacing: Space.m) {
                RetroSectionHeader(title: LocalizedStringResource("Most Played", comment: "Year in Review section header"))
                    .accessibilityAddTraits(.isHeader)
                topCovers(books)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Three books: a big #1 beside a stacked #2/#3. Two: side by side. One: alone. At
    /// accessibility sizes the books stack, so their titles have room to wrap.
    @ViewBuilder private func topCovers(_ books: [YearInReviewTopBook]) -> some View {
        let width = contentWidth > 0 ? contentWidth : 343
        let gap = Space.m
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Space.l) {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                    coverTile(book, rank: index + 1, side: width * 0.6, compact: false)
                }
            }
        } else if books.count >= 3 {
            let small = floor((width - 2 * gap) / 3)
            let big = 2 * small + gap
            HStack(alignment: .top, spacing: gap) {
                coverTile(books[0], rank: 1, side: big, compact: false)
                VStack(alignment: .leading, spacing: gap) {
                    coverTile(books[1], rank: 2, side: small, compact: true)
                    coverTile(books[2], rank: 3, side: small, compact: true)
                }
            }
        } else if books.count == 2 {
            let side = floor((width - gap) / 2)
            HStack(alignment: .top, spacing: gap) {
                coverTile(books[0], rank: 1, side: side, compact: false)
                coverTile(books[1], rank: 2, side: side, compact: false)
            }
        } else if let book = books.first {
            coverTile(book, rank: 1, side: floor(width * 0.62), compact: false)
        }
    }

    /// A square, uncropped cover (`CoverImageView`, hairline edge, no overlay) with the
    /// title and this year's listening time under it.
    private func coverTile(_ book: YearInReviewTopBook, rank: Int, side: CGFloat, compact: Bool) -> some View {
        let time = Self.formatHours(book.seconds)
        let title = book.title.isEmpty ? String(localized: "Untitled", comment: "Placeholder for a book with no title") : book.title
        return VStack(alignment: .leading, spacing: 4) {
            CoverImageView(itemId: book.id, width: side, height: side)
                .padding(.bottom, 2)
            Typo.rowTitle(Text(title))
                .foregroundStyle(Color.shelfCream)
                .lineLimit(compact ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
            Typo.figure(Text(time))
                .foregroundStyle(Color.shelfMuted)
        }
        .frame(width: side, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.topBookAccessibilityLabel(book, rank: rank))
    }

    /// "Number 1: Title, by Author. 12h 5m this year."
    static func topBookAccessibilityLabel(_ book: YearInReviewTopBook, rank: Int) -> String {
        let title = book.title.isEmpty ? String(localized: "Untitled", comment: "Placeholder for a book with no title") : book.title
        let by = book.author.map { String(localized: ", by \($0)", comment: "VoiceOver: appended after a book title; %@ is the author") } ?? ""
        return String(localized: "Number \(rank): \(title)\(by). \(formatHours(book.seconds)) this year.", comment: "VoiceOver for a top-books tile: %1$lld is the rank, %2$@ the title, %3$@ is \", by Author\" or empty, %4$@ a duration")
    }

    // MARK: Figures

    /// Critique 2026-10-06 (shape → bolder): the secondary figures as a hairline spec
    /// list on the ground instead of four identical stat cards.
    private var figureList: some View {
        let figures = cards.filter { $0.placement == .figure }
        return VStack(spacing: 0) {
            ForEach(Array(figures.enumerated()), id: \.element.id) { index, card in
                if index > 0 {
                    Rectangle()
                        .fill(Color.shelfCream.opacity(0.12))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                if card.kind == .topAuthor {
                    authorRow(card)
                } else {
                    figureRow(card)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label on the leading edge, the tape-counter figure on the trailing edge. At
    /// accessibility sizes the figure drops under its label.
    private func figureRow(_ card: YearInReviewCard) -> some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        let layout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.m))
        return layout {
            HStack(spacing: 4) {
                Typo.metadata(Text(card.label))
                    .foregroundStyle(Color.shelfMuted)
                if let caveat = card.caveat { infoButton(card: card, caveat: caveat) }
            }
            if !isAX { Spacer(minLength: Space.s) }
            // LS-7 (docs/design-review.md, Round 3): cross-fade rather than snap when a
            // year-switch refresh lands new figures — the `withAnimation` around the
            // `load()` commit above provides the animation context this needs.
            Text(card.value)
                .font(.title2.weight(.bold))
                // ID-2 (V5): tape-counter (monospaced) figures.
                .fontDesign(.monospaced)
                .foregroundStyle(Color.shelfCream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: card))
    }

    /// Most-Listened Author with the cover of their most-played book this year.
    private func authorRow(_ card: YearInReviewCard) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            if let id = card.coverItemId {
                CoverImageView(itemId: id, width: 56, height: 56)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Typo.metadata(Text(card.label))
                    .foregroundStyle(Color.shelfMuted)
                Text(card.value)
                    .font(.title3.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(2)
                if let detail = card.detail {
                    Typo.figure(Text(detail))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: card))
    }

    private func chartCard(_ card: YearInReviewCard) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // TY-2 (V4): a panel title inside a card: `cardTitle`, no chart glyph (the
            // chart below already says "chart").
            Typo.cardTitle(Text(card.label))
                .foregroundStyle(Color.shelfCream)
            // HIG audit 2026-09-17 L11: `.combine` + the label now scope to just this
            // header, not the whole card (matches StatsView.swift's chartCard, which
            // never combines its `Chart` at all). `monthlyChart` below stays outside the
            // group so its `BarMark`s remain individually reachable by VoiceOver.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: card))
            monthlyChart
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .statPanelStyle()
    }

    // LS-14 (docs/design-review.md, Round 3): shared by the chart frame and its
    // empty-state placeholder so switching between an empty and a populated year
    // doesn't change the card's height.
    fileprivate static let chartHeight: CGFloat = 180

    @ViewBuilder private var monthlyChart: some View {
        let data = monthlyBarsThisYear
        if data.allSatisfy({ $0.minutes == 0 }) {
            Typo.supporting(Text("No listening logged in \(String(selectedYear)) yet."))
                .foregroundStyle(Color.shelfMuted)
                .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
                // HIG audit 2026-09-17 L11: the header label above already states
                // "No listening logged yet." — hide this visual-only duplicate so
                // VoiceOver doesn't speak it twice.
                .accessibilityHidden(true)
        } else {
            // Batch 490 (REVIEW 2026-11-11 A4): the Stats chart's axis — hours past two hours
            // ("50h", not "3000"), round ticks, every tick with its unit (`StatsChartAxis`).
            let maxMinutes = data.map(\.minutes).max() ?? 0
            let unit = StatsChartAxis.unit(maxMinutes: maxMinutes)
            let yTicks = StatsChartAxis.ticks(maxMinutes: maxMinutes)
            Chart(data) { bar in
                BarMark(x: .value("Month", bar.label), y: .value("Minutes", bar.minutes))
                    // Critique 2026-10-06 (colorize): data fill is shelfAmber, same as the heatmap.
                    .foregroundStyle(Color.shelfAmber)
                    .cornerRadius(3)
                    // HIG audit 2026-09-17 L11: per-bar label/value so VoiceOver can
                    // step through months individually, matching StatsView.swift's
                    // chartCard (~586-594).
                    .accessibilityLabel(bar.label)
                    // Batch 490 (REVIEW 2026-11-11 A4): "52 hours", not "3120 minutes".
                    .accessibilityValue(StatsFormat.spoken(bar.minutes * 60))
            }
            .chartYScale(domain: 0...(yTicks.last ?? max(maxMinutes, 1)))
            // HL-4 (V4): 12 month labels collide at accessibility sizes; show every third.
            .chartXAxis {
                AxisMarks(values: dynamicTypeSize.isAccessibilitySize
                          ? ChartAxisLabels.thinned(data.map(\.label), limit: 4)
                          : data.map(\.label)) {
                    AxisValueLabel().foregroundStyle(Color.shelfMuted)
                }
            }
            .chartYAxis {
                AxisMarks(values: yTicks) { value in
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(StatsChartAxis.label(minutes: minutes, unit: unit))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                }
            }
            .frame(height: YearInReviewView.chartHeight)
        }
    }

    /// The lifetime caveat, kept out of the card's body copy. `.combine` above keeps
    /// this button reachable as a VoiceOver custom action on the card.
    private func infoButton(card: YearInReviewCard, caveat: String) -> some View {
        Button {
            Haptics.selection()
            infoPresentedKind = card.kind
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(Color.shelfMuted)
                // Critique 2026-10-06 (shape → bolder): a 44pt target (was the glyph's size).
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Why this figure might not be from \(String(selectedYear))")
        .popover(isPresented: Binding(
            get: { infoPresentedKind == card.kind },
            set: { if !$0 { infoPresentedKind = nil } }
        )) {
            Text(caveat)
                .font(.callout)
                .foregroundStyle(Color.shelfCream)
                .padding()
                .frame(maxWidth: 280)
                .background(Color.shelfBackground)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func accessibilityLabel(for card: YearInReviewCard) -> String {
        var parts: [String] = []
        if card.kind == .monthlyChart {
            // Batch 490 (REVIEW 2026-11-11 A4): matches the retitled chart.
            parts.append(String(localized: "Listening by month, \(String(selectedYear)).", comment: "VoiceOver; %@ is a year such as 2026"))
            // HIG audit 2026-09-17 L11: this header label used to also list every
            // month's minutes, which duplicated the per-bar VoiceOver stops the chart
            // now exposes directly. Keep the no-data case (the chart shows no bars to
            // step through then) and drop the redundant per-bar listing otherwise.
            if monthlyBarsThisYear.allSatisfy({ $0.minutes == 0 }) {
                parts.append(String(localized: "No listening logged yet."))
            }
        } else {
            let spoken = card.value == Self.unavailableValue ? String(localized: "Unavailable") : card.value
            parts.append(String(localized: "\(spoken), \(card.label).", comment: "VoiceOver: %1$@ is a figure value, %2$@ is its caption"))
            if let detail = card.detail { parts.append(detail) }
        }
        if let note = card.incompleteNote { parts.append(note) }
        if let caveat = card.caveat { parts.append(caveat) }
        return LocalizedText.sentences(parts)
    }

    // MARK: - Share

    /// Batch 462: opens the 30-second video sheet with this year's figures.
    private var videoToolbarButton: some View {
        Button {
            Haptics.selection()
            reelData = makeReelData()
        } label: {
            Label("Make a Video", systemImage: "film")
        }
        .monochromeToolbarItem()
        .disabled(isLoading || isRefreshing || stats == nil)
    }

    /// Batch 462: the reel's data, from the same figures this screen shows. Covers load in the
    /// sheet. Session-derived figures are left out when the sessions couldn't be loaded.
    private func makeReelData() -> YearInReviewReelData {
        let top = sessionsUnavailable ? [] : rankedBooksThisYear.prefix(3).map {
            YearInReviewReelData.TopBook(id: $0.id, title: $0.title, author: $0.author, seconds: $0.seconds)
        }
        let months = monthlyBarsThisYear.enumerated().map {
            YearInReviewReelData.Month(id: $0.offset, label: $0.element.label, minutes: $0.element.minutes)
        }
        let finished = finishedCatalog.books
            .filter { Calendar.current.component(.year, from: $0.finishedAt) == selectedYear }
            .sorted(by: CassetteWallLayout.isNewer)
        return YearInReviewReelData(
            year: selectedYear,
            totalSeconds: totalSecondsThisYear,
            booksPlayed: sessionsUnavailable ? nil : distinctBooksThisYear,
            topBooks: Array(top),
            months: months,
            finishedBooks: finished
        )
    }

    private var shareToolbarButton: some View {
        Button {
            Haptics.selection()
            Task { await presentShare() }
        } label: {
            if isSharing {
                ProgressView()
            } else {
                Label("Share your year", systemImage: "square.and.arrow.up")   // iPhone Duo (§2)
            }
        }
        .monochromeToolbarItem()
        // LS-7 (docs/design-review.md, Round 3): also disabled while a year-switch
        // refresh is in flight, so it can't share half-updated figures.
        .disabled(isSharing || isLoading || isRefreshing)
    }

    /// Critique 2026-10-06 (shape → bolder): loads the year's top covers (through
    /// `ShareCardRenderer.loadCover`, which goes via `AudiobookshelfAPI` with its
    /// refresh-and-retry), then opens the shared composer on the `.yearInReview` card.
    /// Covers load one at a time: usually from the cover cache, and at most four.
    @MainActor
    private func presentShare() async {
        isSharing = true
        defer { isSharing = false }
        let year = selectedYear
        let books = sessionsUnavailable ? [] : Array(rankedBooksThisYear.prefix(4))
        var covers: [UIImage] = []
        for book in books {
            if Task.isCancelled { return }
            if let image = await ShareCardRenderer.loadCover(itemId: book.id) {
                covers.append(image)
            }
        }
        // A year switch while covers loaded would pair one year's covers with another's
        // figures; drop it (the button is tappable again for the new year).
        guard year == selectedYear, !isRefreshing else { return }
        shareSession = ShareSession(context: shareContext(covers: covers))
    }

    /// The `.yearInReview` share context. Only honest, year-scoped figures plus the
    /// lifetime best streak, which the card captions "best streak · all-time":
    ///
    /// - hours: from the per-day stats, year-scoped (the hero figure's split).
    /// - books played / top author: from this year's sessions; omitted when the sessions
    ///   couldn't be loaded, rather than shown as 0.
    /// - best streak: lifetime (the server has no year for it), so captioned all-time.
    ///
    /// Deliberately NOT included: lifetime books finished (the all-time count isn't
    /// year-scoped; the year's finished books live in `finishedThisYearSection`) and
    /// this week's minutes (a this-week figure on a whole-year card).
    private func shareContext(covers: [UIImage]) -> ShareCardContext {
        let figure = Self.heroFigure(totalSeconds: totalSecondsThisYear)
        let year = String(selectedYear)
        let review = YearReviewShareData(
            year: selectedYear,
            hoursValue: figure.value,
            hoursUnit: figure.unit,
            booksPlayed: sessionsUnavailable ? nil : distinctBooksThisYear,
            topAuthor: sessionsUnavailable ? nil : topAuthorThisYear?.name,
            bestStreakDays: stats.map { max($0.bestStreak, 0) },
            covers: covers
        )
        var context = ShareCardContext(
            itemId: "yearinreview|\(year)",
            // The #1 cover is the card's ground and the source of its palette.
            cover: covers.first,
            title: "My \(year) in audiobooks",
            author: "",
            progress: ProgressShareData(progress: 0, listened: "", remaining: "", speed: "", chapters: 0)
        )
        context.yearReview = review
        return context
    }
}

// MARK: - Card model

/// One card of the Year in Review screen. Plain data — no view code — so
/// `YearInReviewView.buildCards(...)` can be pinned by a unit test.
struct YearInReviewCard: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Hashable {
        case totalListened, booksListened, topAuthor, longestSession, monthlyChart, bestStreak
    }

    /// Where the card sits. Critique 2026-10-06 (shape → bolder): the big hero figure,
    /// a row in the figure list, or the chart panel. Kept on the model (rather than
    /// switched on `kind` in the view) so the layout and the unit tests agree.
    enum Placement: Equatable { case hero, figure, chart }

    var kind: Kind
    var placement: Placement
    var icon: String
    /// The card's headline figure. Empty for `.monthlyChart`, which renders a chart
    /// instead of a single number.
    var value: String
    /// The caption beside the value — "Listened in 2026", "Books Played".
    var label: String
    /// An optional second caption line (the author's time this year). Explicitly
    /// `= nil` so the synthesized memberwise initializer lets trailing fields be omitted.
    var detail: String? = nil
    /// Y7's "may be undercounted" caveat, marking which figures are session-derived.
    /// Rendered once below the figures (see `YearInReviewView.grid`) and spoken by each
    /// affected row's VoiceOver label.
    var incompleteNote: String? = nil
    /// A caveat about a LIFETIME figure shown on a year-scoped screen — behind the
    /// row's ⓘ popover, never inline body copy.
    var caveat: String? = nil
    /// The cover shown beside Most-Listened Author: their most-played book this year.
    var coverItemId: String? = nil

    var id: Kind { kind }
}

/// One of the year's most-played books (Critique 2026-10-06, shape → bolder).
struct YearInReviewTopBook: Identifiable, Equatable {
    /// The library item id (covers load from it).
    var id: String
    var title: String
    var author: String?
    /// Total clamped listening time this year.
    var seconds: Double
}

/// A single month's listening total. Non-private so `YearInReviewPagesTests.swift`
/// can construct it directly.
struct Bar: Identifiable, Equatable {
    var label: String
    var minutes: Double
    var id: String { label }
}

// MARK: - LS-6 skeleton (docs/design-review.md, Round 3)

/// A placeholder for the first-load/account-change path of `YearInReviewView`'s `body`,
/// mirroring `grid`'s real layout (year picker, hero figure, top covers, figure rows,
/// monthly chart) instead of a shapeless centred spinner. LS-7's year-switch refresh
/// never shows this — it keeps `grid` itself on screen, dimmed via `isRefreshing`.
///
/// Pulses exactly like `SkeletonTile` (Extensions.swift): a single Reduce-Motion-guarded
/// `repeatForever` opacity pulse over the whole stack rather than per bar.
private struct YearInReviewSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var width: CGFloat = 0

    private func bar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.shelfSurface)
            .frame(width: width, height: height)
    }

    private func square(_ side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.cover(side: side))
            .fill(Color.shelfSurface)
            .frame(width: side, height: side)
    }

    private var yearPickerRowSkeleton: some View {
        RoundedRectangle(cornerRadius: Radius.chip)
            .fill(Color.shelfSurface)
            .frame(height: 32)
    }

    private var heroSkeleton: some View {
        VStack(spacing: Space.s) {
            bar(width: 180, height: 64)
            bar(width: 70, height: 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
    }

    private var coversSkeleton: some View {
        let w = width > 0 ? width : 343
        let small = floor((w - 2 * Space.m) / 3)
        return VStack(alignment: .leading, spacing: Space.m) {
            bar(width: 110, height: 10)
            HStack(alignment: .top, spacing: Space.m) {
                square(2 * small + Space.m)
                VStack(spacing: Space.m) { square(small); square(small) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var figureRowsSkeleton: some View {
        VStack(spacing: Space.l) {
            ForEach(0..<3, id: \.self) { _ in
                HStack {
                    bar(width: 110, height: 10)
                    Spacer()
                    bar(width: 70, height: 20)
                }
            }
        }
        .padding(.vertical, Space.s)
    }

    private var chartCardSkeleton: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            bar(width: 140, height: 12)
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(Color.shelfSurface)
                .frame(maxWidth: .infinity)
                .frame(height: YearInReviewView.chartHeight)
        }
        .padding(Space.l)
        .statPanelStyle()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                yearPickerRowSkeleton
                VStack(spacing: Space.xl) {
                    heroSkeleton
                    coversSkeleton
                    figureRowsSkeleton
                    chartCardSkeleton
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
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
        .accessibilityLabel("Building your year…")
    }
}
