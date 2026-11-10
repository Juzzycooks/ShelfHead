import SwiftUI
import UIKit
import Photos
import ImageIO
import UniformTypeIdentifiers

// Shareable "Wrapped-style" cards. The composition is a small design engine: the user
// picks a FORMAT (aspect ratio), a THEME (visual style) and CONTENT (what the card is
// about). A deterministic per-book SEED then varies rotation, gradients, motifs and
// typography so two different books never look identical — while the SAME book always
// renders the same way (unless the user shuffles).
//
// NOTE ON LOCALISATION: localised as of Batch 403 (Simplified Chinese). Runtime `String`
// labels (enum `label`s, `kickerText`, captions, toast text, composed strings like
// "Narrated by …") go through `String(localized:)`; bare literals passed to `Text` resolve
// as `LocalizedStringKey`. Identity strings (rawValues, the English time-of-day keys the
// personality title matches on) stay English. Letter-spacing goes through
// `LocalizedText.tracking` (zero for Chinese/Japanese).

// MARK: - Format / Theme / Content

enum ShareCardFormat: String, CaseIterable, Identifiable {
    case story, square, landscape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .story: return String(localized: "Story", comment: "Share card format picker option")
        case .square: return String(localized: "Square", comment: "Share card format picker option")
        case .landscape: return String(localized: "Landscape", comment: "Share card format picker option")
        }
    }
    /// Target export dimensions (already pixel-sized — the renderer uses scale = 1).
    var exportSize: CGSize {
        switch self {
        case .story: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }
    /// Small dimensions for the on-screen preview so old devices stay smooth.
    var previewSize: CGSize {
        switch self {
        case .story: return CGSize(width: 270, height: 480)
        case .square: return CGSize(width: 324, height: 324)
        case .landscape: return CGSize(width: 384, height: 216)
        }
    }
}

enum ShareCardTheme: String, CaseIterable, Identifiable {
    // Critique 2026-10-06 (shape → bolder): `.yearInReview` is Year in Review's own card
    // (kicker "MY 2026", hours as the big stat, a collage of the year's top covers). It
    // replaces the Persona template that screen used to borrow, which had no cover, a
    // canned persona headline and the lifetime best streak labelled "day streak".
    case spotlight, kineticType, collage, chapterWave, retroPlayer, completionBurst, listeningPersonality, yearInReview
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spotlight: return String(localized: "Spotlight", comment: "Share card theme name (segmented/picker label)")
        case .kineticType: return String(localized: "Kinetic", comment: "Share card theme name (segmented/picker label)")
        case .collage: return String(localized: "Collage", comment: "Share card theme name (segmented/picker label)")
        case .chapterWave: return String(localized: "Chapter", comment: "Share card theme name (segmented/picker label)")
        case .retroPlayer: return String(localized: "Retro", comment: "Share card theme name (segmented/picker label)")
        case .completionBurst: return String(localized: "Finished", comment: "Share card theme name (segmented/picker label)")
        case .listeningPersonality: return String(localized: "Persona", comment: "Share card theme name (segmented/picker label)")
        case .yearInReview: return String(localized: "Year", comment: "Share card theme name (segmented/picker label)")
        }
    }
    var systemImage: String {
        switch self {
        case .spotlight: return "sparkles"
        case .kineticType: return "textformat.size"
        case .collage: return "square.on.square"
        case .chapterWave: return "waveform"
        case .retroPlayer: return "recordingtape"
        case .completionBurst: return "checkmark.seal.fill"
        case .listeningPersonality: return "person.wave.2.fill"
        case .yearInReview: return "calendar"
        }
    }

    /// The themes the composer offers for this context. A Year in Review context gets only
    /// its own card (a book theme has no book to show); a book context never gets it.
    /// Pure, so `ShareYearInReviewTests` pins it.
    static func available(for context: ShareCardContext) -> [ShareCardTheme] {
        if context.yearReview != nil { return [.yearInReview] }
        return allCases.filter { t in
            switch t {
            case .completionBurst: return context.isFinished || context.completion != nil
            case .listeningPersonality: return context.statistics?.hasEnough == true
            case .yearInReview: return false
            default: return true
            }
        }
    }
}

enum ShareCardContent: String, CaseIterable, Identifiable {
    case progress, chapter, quote, completion, streak, booksFinished, listeningPersonality, yearInReview
    var id: String { rawValue }
    var label: String {
        switch self {
        case .progress: return String(localized: "Progress", comment: "Share card content type name")
        case .chapter: return String(localized: "Chapter", comment: "Share card content type name")
        case .quote: return String(localized: "Quote", comment: "Share card content type name")
        case .completion: return String(localized: "Finished", comment: "Share card content type name")
        case .streak: return String(localized: "Streak", comment: "Share card content type name")
        case .booksFinished: return String(localized: "Books finished", comment: "Share card content type name")
        case .listeningPersonality: return String(localized: "Personality", comment: "Share card content type name")
        case .yearInReview: return String(localized: "Year in Review", comment: "Share card content type name")
        }
    }

    /// The content types this context has data for (moved out of `ShareComposerSheet` so
    /// it can be unit-tested). Year in Review is its own content and nothing else.
    static func available(for context: ShareCardContext) -> [ShareCardContent] {
        if context.yearReview != nil { return [.yearInReview] }
        return allCases.filter { c in
            switch c {
            case .progress: return true
            case .chapter: return context.chapter != nil
            case .quote: return (context.quote?.isEmpty == false)
            case .completion: return context.isFinished || context.completion != nil
            case .streak: return (context.statistics?.streakDays ?? 0) > 0
            case .booksFinished: return (context.statistics?.booksFinished ?? context.completion?.bookNumber) != nil
            case .listeningPersonality: return context.statistics?.hasEnough == true
            case .yearInReview: return false
            }
        }
    }
}

enum ShareRenderMode { case preview, export }

// MARK: - Style presets (P-11, REVIEW_2026-09-14_DESIGN.md)

/// One named tap that used to require two separate decisions — a Style
/// (`ShareCardTheme`) row and a Card Type (`ShareCardContent`) row, together showing up
/// to 5-7 style tiles stacked over up to 7 card-type chips. Collapsing them into five
/// presets doesn't touch a single theme/content rendering path — `ShareCardView`'s
/// `themeBody`/`contentFocus` still switch on the exact same `ShareCardTheme`/
/// `ShareCardContent` values they always did. This only changes what the composer sheet
/// *offers* as one combined choice, and what it auto-resolves the paired content to for
/// the given book.
///
/// Deliberately five, not seven: `.collage` and `.kineticType` (`ShareCardTheme`) stay
/// fully working render paths — reachable through Remix on the Spotlight preset (see
/// `remixThemes`) — but aren't offered as a named top-level preset. Five distinct *stories* (default spotlight, chapter,
/// retro/cassette, finished, personality) cover the design space better than seven skins
/// layered over largely the same handful of content types.
enum SharePreset: String, CaseIterable, Identifiable {
    // Critique 2026-10-06 (shape → bolder): `.yearInReview` is offered only for a Year in
    // Review context (its theme is the only one that context gets), so a book share still
    // sees the same five.
    case spotlight, chapter, retro, finished, persona, yearInReview
    var id: String { rawValue }

    var label: String {
        switch self {
        case .spotlight: return String(localized: "Spotlight", comment: "Share card style preset chip label")
        case .chapter:   return String(localized: "Chapter", comment: "Share card style preset chip label")
        case .retro:     return String(localized: "Retro", comment: "Share card style preset chip label")
        case .finished:  return String(localized: "Finished", comment: "Share card style preset chip label")
        case .persona:   return String(localized: "Persona", comment: "Share card style preset chip label")
        case .yearInReview: return String(localized: "Year", comment: "Share card style preset chip label")
        }
    }

    var systemImage: String {
        switch self {
        case .spotlight: return "sparkles"
        case .chapter:   return "waveform"
        case .retro:     return "recordingtape"
        case .finished:  return "checkmark.seal.fill"
        case .persona:   return "person.wave.2.fill"
        case .yearInReview: return "calendar"
        }
    }

    /// The `ShareCardTheme` this preset drives. Rendering itself is untouched — this is
    /// the only line that couples a preset to the existing theme machinery.
    var theme: ShareCardTheme {
        switch self {
        case .spotlight: return .spotlight
        case .chapter:   return .chapterWave
        case .retro:     return .retroPlayer
        case .finished:  return .completionBurst
        case .persona:   return .listeningPersonality
        case .yearInReview: return .yearInReview
        }
    }

    /// Content this preset prefers, most- to least-wanted, so it degrades to something
    /// the current book actually has data for rather than a blank/placeholder card.
    /// Pure and seed-independent, so it's the piece `ShareCardPresetTests` pins.
    private var preferredContent: [ShareCardContent] {
        switch self {
        // Y2 (REVIEW_2026-09-04_UI.md) preserved: a bookmark-note share still opens on
        // the Quote card, now expressed as this preset's first preference rather than a
        // special case bypassing the picker.
        case .spotlight: return [.quote, .progress]
        case .chapter:   return [.chapter, .progress]
        case .retro:     return [.progress]
        case .finished:  return [.completion, .progress]
        case .persona:   return [.listeningPersonality, .streak, .booksFinished, .progress]
        case .yearInReview: return [.yearInReview]
        }
    }

    /// First preferred content actually offered for this book (`available`, i.e. the
    /// composer's `availableContent`), falling back to whatever IS offered rather than a
    /// content type the book has no data for.
    static func resolvedContent(for preset: SharePreset, available: [ShareCardContent]) -> ShareCardContent {
        preset.preferredContent.first(where: available.contains) ?? available.first ?? .progress
    }

    /// A preset is offered only if its theme is (mirrors the old per-theme gating:
    /// `.finished`/`.persona` need `context.isFinished`/`hasEnough` respectively, which
    /// is exactly what already keeps those themes out of `availableThemes`).
    static func isAvailable(_ preset: SharePreset, availableThemes: [ShareCardTheme]) -> Bool {
        availableThemes.contains(preset.theme)
    }

    // MARK: Remix (Critique 2026-10-06, shape → bolder)

    /// The themes Remix cycles through while this preset stays selected. "Shuffle artwork"
    /// and "Try another style" used to be two near-synonym buttons; they're one Remix now.
    /// Spotlight's family carries the two themes that have no preset of their own
    /// (Collage, Kinetic: all three are cover-led layouts over the same content), so those
    /// render paths stay reachable. Every other preset remixes within its own theme.
    var remixThemes: [ShareCardTheme] {
        self == .spotlight ? [.spotlight, .collage, .kineticType] : [theme]
    }

    /// The preset a theme belongs to, so the preset row keeps Spotlight selected while
    /// Remix shows Collage or Kinetic.
    static func preset(for theme: ShareCardTheme) -> SharePreset? {
        allCases.first { $0.remixThemes.contains(theme) }
    }

    /// One Remix tap: always a fresh variation (seed), and the next theme in the current
    /// preset's family. Pure and deterministic, so a captured state reproduces.
    static func remix(theme: ShareCardTheme, shuffle: Int) -> (theme: ShareCardTheme, shuffle: Int) {
        let next = shuffle &+ 1
        guard let family = preset(for: theme)?.remixThemes, family.count > 1,
              let current = family.firstIndex(of: theme) else { return (theme, next) }
        return (family[(current + 1) % family.count], next)
    }
}

// MARK: - Deterministic visual seed

struct ShareVisualSeed: Sendable {
    var layoutVariant: Int        // which composition (varies with shuffle)
    var typographyVariant: Int    // stable per book — keeps a recognisable identity
    var coverRotation: Double
    var gradientAngle: Double
    var motifVariant: Int
    var accentHueOffset: Double   // fraction of the hue wheel, small
    var coverOffsetX: Double
    var coverOffsetY: Double

    /// Stable across launches (FNV-1a — Swift's String.hashValue is per-process randomised).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037   // FNV-1a 64-bit offset basis
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1_099_511_628_211 }
        return h
    }

    /// A base seed fixes the book's core identity; a variation seed (mixing in `shuffle`)
    /// re-rolls rotation, motif and composition so shuffled cards feel related, not random.
    static func make(key: String, shuffle: Int = 0) -> ShareVisualSeed {
        let base = stableHash(key)
        let v = stableHash("\(base)|\(shuffle)")
        return ShareVisualSeed(
            layoutVariant: Int(v % 3),
            typographyVariant: Int(base % 2),
            coverRotation: Double((v >> 3) % 17) - 8,          // -8…8°
            gradientAngle: Double((v >> 7) % 360),
            motifVariant: Int((v >> 11) % 6),
            accentHueOffset: (Double((v >> 17) % 40) - 20) / 360,  // ±~0.055
            coverOffsetX: Double((v >> 23) % 60) - 30,
            coverOffsetY: Double((v >> 29) % 60) - 30
        )
    }
}

// MARK: - Privacy

struct SharePrivacyOptions: Equatable {
    var showProgress = true
    var showRemainingTime = true
    var showSpeed = true
    var showStreak = true
    var showAuthor = true
    var showNarrator = true
    var showBranding = true
    /// Y4 (REVIEW_2026-09-04_UI.md): the completion card's time-listened/days-to-finish/
    /// book-count numbers had no privacy gate at all — every other stat did.
    var showCompletionDetails = true
    /// Critique 2026-10-06 (shape → bolder): the Year in Review card's own figures (hours
    /// listened, books played). Off under Hide Stats and Cover Only, like every other stat.
    var showListeningTotals = true

    /// Y1 (REVIEW_2026-09-04_UI.md): single source of truth for whether a theme may print
    /// the raw headline value for a given content type. Mirrors the pre-existing Spotlight
    /// `contentFocus` behaviour exactly — only `.streak` is gated by a privacy flag;
    /// `.booksFinished` (and everything else) already rendered unconditionally there
    /// (`bigStat(..., show: true)`), so it stays unconditional here too.
    static func headlineIsVisible(content: ShareCardContent, privacy: SharePrivacyOptions) -> Bool {
        switch content {
        case .streak: return privacy.showStreak
        case .yearInReview: return privacy.showListeningTotals
        default: return true
        }
    }
}

// MARK: - Content data

struct ChapterShareData {
    var index: Int?
    var total: Int?
    var title: String?
}

struct ProgressShareData {
    var progress: Double          // source of truth
    var listened: String
    var remaining: String
    var speed: String
    var chapters: Int
    var percent: Int { Int((min(max(progress, 0), 1) * 100).rounded()) }
}

struct CompletionShareData {
    var totalTime: String
    var finishedInDays: Int?
    var bookNumber: Int?          // lifetime finished count → "My Nth audiobook"
}

struct ListeningStatistics {
    var streakDays: Int = 0
    var minutesThisWeek: Int?
    var favouriteNarrator: String?
    var topGenre: String?
    var longestSessionMinutes: Int?
    var timeOfDay: String?
    var percentAboveAverage: Int?
    var booksFinished: Int?       // lifetime; NOT year-scoped (a per-year count exists in `FinishedBookCatalog`, Batch 459)
    /// Whether there is a real *behavioural* signal for the Persona card. Lifetime
    /// `booksFinished` alone does NOT count — it would unlock Persona with nothing to say.
    var hasEnough: Bool {
        streakDays > 0 || minutesThisWeek != nil || longestSessionMinutes != nil
            || timeOfDay != nil || topGenre != nil
    }
}

// MARK: - Stats adapter

extension ListeningStatistics {
    /// Single source of truth: convert the app's existing stats models into the share
    /// engine's `ListeningStatistics`. The card must never recompute account statistics —
    /// it only consumes this. Fields with no existing source stay `nil`.
    ///
    /// - `stats`:    `AudiobookshelfAPI.getListeningStats()` (per-day seconds + streak).
    /// - `sessions`: `AudiobookshelfAPI.getListeningSessions()` (history rows).
    /// - `finishedBooks`: `LibraryViewModel.finishedBooksCount` (lifetime; the catalog's `finishedAt` now allows a per-year count).
    /// - `streak`:   `LibraryViewModel.listeningStreak` (falls back to `stats.currentStreak`).
    @MainActor
    static func from(stats: ListeningStats?, sessions: [ListeningSession],
                     finishedBooks: Int, streak: Int) -> ListeningStatistics {
        var out = ListeningStatistics()
        out.streakDays = streak > 0 ? streak : (stats?.currentStreak ?? 0)
        out.minutesThisWeek = weeklyMinutes(stats?.days)
        out.longestSessionMinutes = longestSessionMinutes(sessions)
        out.timeOfDay = dominantTimeOfDay(sessions)
        out.booksFinished = finishedBooks > 0 ? finishedBooks : nil
        // Batch 463: top genre and favourite narrator come from the finished-book catalog (the
        // Listening Passport's rules). Empty until the catalog has loaded once, so nil then.
        let passport = PassportStamps.summary(FinishedBookCatalog.shared.books)
        out.topGenre = passport.topGenre
        out.favouriteNarrator = passport.favouriteNarrator
        // percentAboveAverage: no existing source → left nil.
        return out
    }

    /// Minutes listened in the CURRENT calendar week (not just the 7 most recent dated
    /// entries, which could span far longer than a week for sparse listeners).
    private static func weeklyMinutes(_ days: [String: Double]?) -> Int? {
        guard let days, !days.isEmpty else { return nil }
        let cal = Calendar.current
        guard let week = cal.dateInterval(of: .weekOfYear, for: Date()) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        let total = days.compactMap { key, secs in f.date(from: key).map { ($0, secs) } }
            .filter { week.contains($0.0) }
            .reduce(0.0) { $0 + $1.1 }
        return total > 0 ? Int(total / 60) : nil
    }

    private static func longestSessionMinutes(_ sessions: [ListeningSession]) -> Int? {
        // Clamp each session to its book duration — some servers report a corrupted
        // `timeListening` that would otherwise yield an absurd "longest session".
        let values = sessions.compactMap { s -> Double? in
            guard let t = s.timeListening, t > 0 else { return nil }
            if let d = s.duration, d > 0 { return min(t, d) }
            return t
        }
        guard let m = values.max(), m > 0 else { return nil }
        return Int(m / 60)
    }

    /// Time-of-day personality, weighted by listened DURATION (a 3-hour night beats a
    /// 5-minute morning) with a deterministic tie-break so dictionary order can't decide it.
    private static func dominantTimeOfDay(_ sessions: [ListeningSession]) -> String? {
        let cal = Calendar.current
        func bucket(_ h: Int) -> String {
            switch h {
            case 5..<12:  return "Morning"
            case 12..<17: return "Afternoon"
            case 17..<22: return "Evening"
            default:      return "Night"
            }
        }
        var secondsByBucket: [String: Double] = [:]
        for s in sessions {
            guard let date = s.date, let secs = s.timeListening, secs > 0 else { continue }
            secondsByBucket[bucket(cal.component(.hour, from: date)), default: 0] += secs
        }
        guard !secondsByBucket.isEmpty else { return nil }
        let order = ["Morning", "Afternoon", "Evening", "Night"]
        // Highest duration wins; ties resolve by the fixed `order` for reproducibility.
        return secondsByBucket.max { a, b in
            a.value != b.value ? a.value < b.value
                               : (order.firstIndex(of: a.key) ?? 0) > (order.firstIndex(of: b.key) ?? 0)
        }?.key
    }
}

/// One figure cell on a share card: the value, and the caption under it.
struct ShareStatCell: Equatable {
    var value: String
    var caption: String
}

/// Critique 2026-10-06 (shape → bolder): what the Year in Review card shows. Built by
/// `YearInReviewView.shareContext(covers:)` from figures that screen already
/// computed; the card never recomputes them.
struct YearReviewShareData {
    var year: Int
    /// The big stat, already split for display: "212" + "hours" (or "45" + "minutes").
    var hoursValue: String
    var hoursUnit: String
    /// nil when the sessions fetch failed (the screen shows "Unavailable" then).
    var booksPlayed: Int?
    var topAuthor: String?
    /// LIFETIME best streak: the server doesn't say which year it happened in, so the
    /// caption says "all-time".
    var bestStreakDays: Int?
    /// The year's most-played covers, most-played first (up to four are drawn).
    var covers: [UIImage] = []

    /// `String(year)`, so no grouping separator ("MY 2,026").
    static func kicker(year: Int) -> String {
        String(localized: "MY \(String(year))", comment: "Year in Review share-card kicker. %@ is a four-digit year, e.g. 2026.")
    }

    /// The big stat, or nil when Privacy hides listening totals.
    func headline(privacy: SharePrivacyOptions) -> ShareStatCell? {
        guard privacy.showListeningTotals else { return nil }
        return ShareStatCell(value: hoursValue, caption: String(localized: "\(hoursUnit) listened", comment: "Year in Review headline caption. %@ is a unit word already localised, e.g. hours or minutes."))
    }

    /// The figure cells under the collage, in order, honouring every privacy flag.
    func cells(privacy: SharePrivacyOptions) -> [ShareStatCell] {
        var out: [ShareStatCell] = []
        if privacy.showListeningTotals, let n = booksPlayed, n > 0 {
            out.append(ShareStatCell(value: "\(n)", caption: n == 1 ? String(localized: "book played", comment: "Year in Review stat caption, singular") : String(localized: "books played", comment: "Year in Review stat caption, plural")))
        }
        if privacy.showAuthor, let a = topAuthor, !a.isEmpty {
            out.append(ShareStatCell(value: a, caption: String(localized: "top author", comment: "Year in Review stat caption")))
        }
        if privacy.showStreak, let d = bestStreakDays, d > 0 {
            out.append(ShareStatCell(value: d == 1 ? String(localized: "1 day", comment: "Streak length, singular") : String(localized: "\(String(d)) days", comment: "Streak length. %@ is a number of days (2 or more)."), caption: String(localized: "best streak \u{00B7} all-time", comment: "Year in Review stat caption: lifetime best listening streak")))
        }
        return out
    }
}

struct ShareCardContext {
    var itemId: String
    var serverId: String = ""
    var userId: String = ""
    var cover: UIImage?
    var title: String
    var author: String
    var narrator: String?
    var quote: String?
    var quoteAttribution: String?   // e.g. a passage source; nil → falls back to author
    var quoteIsUserNote: Bool = false  // a personal bookmark note, not a book passage
    var quoteIsPassage: Bool = false   // Batch 426: transcript text from a quote clip
    var chapter: ChapterShareData?
    var progress: ProgressShareData
    var completion: CompletionShareData?
    var statistics: ListeningStatistics?
    var tagline: String = String(localized: "Just one more chapter.", comment: "Share card default tagline")
    var isFinished: Bool = false
    /// Set only by Year in Review; switches the composer to the `.yearInReview` card.
    var yearReview: YearReviewShareData? = nil

    var seedKey: String { "\(serverId)|\(userId)|\(itemId)" }
}

// MARK: - Configuration

struct ShareCardConfiguration {
    var format: ShareCardFormat
    var theme: ShareCardTheme
    var content: ShareCardContent
    var palette: CoverPalette
    var seed: ShareVisualSeed
    var privacy: SharePrivacyOptions
}

// MARK: - Cover palette

// `CoverPalette` and `UIImage.normalizedUp()` moved to CoverPalette.swift (N15) — both
// are used well beyond this file now (PlayerView's per-chapter background tint, Year in
// Review), so they no longer belong under a "share card" name.

// MARK: - Motifs

struct ShareBlobMotif: View {
    let palette: CoverPalette; let seed: ShareVisualSeed
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                blob(palette.primaryAccent, 0.9, x: 0.15, y: 0.2, size: 0.9, w: w, h: h)
                blob(palette.secondaryAccent, 0.7, x: 0.85, y: 0.75, size: 0.8, w: w, h: h)
                blob(palette.highlight, 0.4, x: 0.7, y: 0.15, size: 0.5, w: w, h: h)
            }
        }
    }
    private func blob(_ c: Color, _ op: Double, x: Double, y: Double, size: Double, w: CGFloat, h: CGFloat) -> some View {
        let d = min(w, h) * size
        return Circle().fill(c).frame(width: d, height: d)
            .position(x: w * x, y: h * y).blur(radius: d * 0.35).opacity(op)
    }
}

struct ShareStripeMotif: View {
    let palette: CoverPalette; let seed: ShareVisualSeed
    var body: some View {
        GeometryReader { geo in
            let n = 7
            let span = max(geo.size.width, geo.size.height) * 1.6
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    Capsule()
                        .fill(i % 2 == 0 ? palette.primaryAccent : palette.secondaryAccent)
                        .frame(width: span, height: span / CGFloat(n) * 0.55)
                        .position(x: geo.size.width / 2,
                                  y: CGFloat(i) / CGFloat(n - 1) * geo.size.height)
                        .opacity(0.22)
                }
            }
            .rotationEffect(.degrees(-20 + seed.gradientAngle.truncatingRemainder(dividingBy: 40)))
        }
    }
}

struct ShareOrbitMotif: View {
    let palette: CoverPalette; let seed: ShareVisualSeed
    var body: some View {
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .strokeBorder(i % 2 == 0 ? palette.primaryAccent : palette.secondaryAccent,
                                      lineWidth: base * 0.012)
                        .frame(width: base * (0.5 + Double(i) * 0.35),
                               height: base * (0.5 + Double(i) * 0.35))
                        .opacity(0.28)
                }
            }
            .position(x: geo.size.width * (seed.layoutVariant % 2 == 0 ? 0.85 : 0.15),
                      y: geo.size.height * 0.2)
        }
    }
}

struct ShareWaveMotif: View {
    let palette: CoverPalette; let seed: ShareVisualSeed
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Canvas { ctx, _ in
                for (idx, cfg) in [(0, 0.55), (1, 0.62)].enumerated() {
                    var path = Path()
                    let amp = h * 0.05
                    let baseY = h * cfg.1
                    path.move(to: CGPoint(x: 0, y: baseY))
                    var x: CGFloat = 0
                    while x <= w {
                        let y = baseY + amp * CGFloat(sin(Double(x) / Double(w) * .pi * 4 + Double(idx)))
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 8
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                    ctx.fill(path, with: .color((idx == 0 ? palette.primaryAccent : palette.secondaryAccent).opacity(0.25)))
                }
            }
        }
    }
}

struct ShareBurstMotif: View {
    let palette: CoverPalette; let seed: ShareVisualSeed
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cx = w / 2, cy = h * 0.42
            let r = max(w, h)
            Canvas { ctx, _ in
                let spokes = 28
                for i in 0..<spokes {
                    let a = Double(i) / Double(spokes) * 2 * .pi
                    let a2 = a + 0.06
                    var path = Path()
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r))
                    path.addLine(to: CGPoint(x: cx + CGFloat(cos(a2)) * r, y: cy + CGFloat(sin(a2)) * r))
                    path.closeSubpath()
                    ctx.fill(path, with: .color((i % 2 == 0 ? palette.primaryAccent : palette.highlight).opacity(0.14)))
                }
            }
        }
    }
}

struct ShareHalftoneMotif: View {
    let palette: CoverPalette; let seed: ShareVisualSeed
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Canvas { ctx, _ in
                let cols = 12
                let step = w / CGFloat(cols)
                let rows = Int(h / step) + 1
                for r in 0..<rows {
                    for c in 0..<cols {
                        let frac = Double(r) / Double(max(rows - 1, 1))
                        let dot = step * CGFloat(0.12 + frac * 0.34)
                        let x = CGFloat(c) * step + step / 2
                        let y = CGFloat(r) * step + step / 2
                        let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                        ctx.fill(Path(ellipseIn: rect), with: .color(palette.primaryAccent.opacity(0.18)))
                    }
                }
            }
        }
    }
}

// MARK: - Cover-fragment treatments

/// Seeded decorative treatments built from the cover artwork itself — the big lever for
/// making Collage/Kinetic feel like generative artwork rather than one image + text.
enum CoverFragmentKind: Int, CaseIterable { case slices, circles, duotone, mirror, tiles, ribbons }

struct ShareCoverFragments: View {
    let image: UIImage
    let palette: CoverPalette
    let seed: ShareVisualSeed
    let kind: CoverFragmentKind

    /// Deterministic 0…1 value per element index.
    private func rnd(_ i: Int) -> Double {
        let h = ShareVisualSeed.stableHash("\(seed.gradientAngle)-\(seed.motifVariant)-\(i)")
        return Double(h % 1000) / 1000.0
    }

    private func cover(_ wd: CGFloat, _ ht: CGFloat) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(width: wd, height: ht).clipped()
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Group {
                switch kind {
                case .slices:  slices(w, h)
                case .circles: circles(w, h)
                case .duotone: duotone(w, h)
                case .mirror:  mirror(w, h)
                case .tiles:   tiles(w, h)
                case .ribbons: ribbons(w, h)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func slices(_ w: CGFloat, _ h: CGFloat) -> some View {
        let n = 6
        let stripW = w / CGFloat(n)
        return HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { i in
                // Each strip reveals its own contiguous source column (full-size image
                // offset left by i strips, then clipped) rather than a repeated whole cover.
                Color.clear
                    .frame(width: stripW, height: h)
                    .overlay(
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: w, height: h)
                            .offset(x: -CGFloat(i) * stripW)
                    )
                    .clipped()
                    .offset(y: CGFloat(rnd(i) * 120 - 60))   // vertical glitch nudge
                    .opacity(0.5)
            }
        }
        .frame(width: w, height: h).clipped()
    }

    private func circles(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                let d = min(w, h) * (0.28 + rnd(i) * 0.22)
                cover(d, d).clipShape(Circle())
                    .overlay(Circle().strokeBorder(palette.highlight.opacity(0.4), lineWidth: 3))
                    .position(x: w * (0.15 + rnd(i * 2) * 0.7), y: h * (0.12 + rnd(i * 3) * 0.7))
                    .opacity(0.85)
            }
        }
    }

    private func duotone(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let wd = w * (0.4 + rnd(i) * 0.3)
                cover(wd, wd * 1.2)
                    .grayscale(0.9).colorMultiply(i % 2 == 0 ? palette.primaryAccent : palette.secondaryAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .rotationEffect(.degrees(rnd(i * 5) * 24 - 12))
                    .position(x: w * (0.2 + rnd(i * 2) * 0.6), y: h * (0.2 + rnd(i * 3) * 0.6))
                    .opacity(0.5)
            }
        }
    }

    private func mirror(_ w: CGFloat, _ h: CGFloat) -> some View {
        HStack(spacing: 0) {
            cover(w / 2, h)
            cover(w / 2, h).scaleEffect(x: -1, y: 1)
        }
        .frame(width: w, height: h).clipped().opacity(0.4)
    }

    private func tiles(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let d = min(w, h) * 0.22
                // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 12pt radius → `Radius.card`
                // (one of the two literals the review explicitly names here — this
                // file's many OTHER raw sizes are deliberately left alone, since they
                // scale via this file's own `f()` proportional helper for the export
                // image's pixel scale, a genuinely different context from screen text).
                cover(d, d).clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .rotationEffect(.degrees(rnd(i * 7) * 30 - 15))
                    .position(x: w * (0.1 + rnd(i) * 0.8), y: h * (0.1 + rnd(i * 2) * 0.8))
                    .opacity(0.55)
            }
        }
    }

    private func ribbons(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                cover(w * 1.4, h * 0.16)
                    .clipShape(Capsule())
                    .blur(radius: 18)
                    .rotationEffect(.degrees(-24 + rnd(i) * 48))
                    .position(x: w * 0.5, y: h * (0.25 + Double(i) * 0.25))
                    .opacity(0.5)
            }
        }
    }
}

// MARK: - The card

struct ShareCardView: View {
    let context: ShareCardContext
    let configuration: ShareCardConfiguration
    var size: CGSize
    var renderMode: ShareRenderMode = .export

    private var p: CoverPalette { configuration.palette }
    private var seed: ShareVisualSeed { configuration.seed }
    private var pr: SharePrivacyOptions { configuration.privacy }
    private var k: CGFloat { min(size.width, size.height) / 1080 }
    private func f(_ v: CGFloat) -> CGFloat { v * k }
    private var isWide: Bool { configuration.format == .landscape }

    var body: some View {
        ZStack { themeBody }
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    @ViewBuilder private var themeBody: some View {
        switch configuration.theme {
        case .spotlight:            spotlight
        case .kineticType:          kinetic
        case .collage:              collage
        case .chapterWave:          chapterWave
        case .retroPlayer:          retroPlayer
        case .completionBurst:      completionBurst
        case .listeningPersonality: personality
        case .yearInReview:         yearInReviewCard
        }
    }

    // MARK: Shared building blocks

    /// Preview renders at a small canvas, so scale blur/shadow down to stay smooth.
    private var blurK: CGFloat { renderMode == .preview ? 0.55 : 1 }
    private var shadowK: CGFloat { renderMode == .preview ? 0.5 : 1 }

    /// Theme picks a motif from a compatible set using the seed, so Shuffle changes the
    /// decorative treatment — not just the colour.
    private var resolvedMotif: ShareMotif {
        let options: [ShareMotif]
        switch configuration.theme {
        case .spotlight:            options = [.blob, .orbit, .stripe]
        case .kineticType:          options = [.stripe, .halftone, .burst]
        case .collage:              options = [.halftone, .blob, .stripe]
        case .chapterWave:          options = [.wave, .orbit, .stripe]
        case .retroPlayer:          options = [.orbit, .halftone]
        case .completionBurst:      options = [.burst, .stripe, .blob]
        case .listeningPersonality: options = [.halftone, .burst, .blob]
        case .yearInReview:         options = [.halftone, .orbit, .blob]
        }
        return options[seed.motifVariant % options.count]
    }

    /// Collage and Kinetic build decorative treatments from the cover art itself.
    private var fragmentKind: CoverFragmentKind? {
        switch configuration.theme {
        case .collage:     return CoverFragmentKind.allCases[seed.motifVariant % CoverFragmentKind.allCases.count]
        case .kineticType: return [.slices, .ribbons, .duotone][seed.layoutVariant % 3]
        default:           return nil
        }
    }

    @ViewBuilder private func coverFragments() -> some View {
        if let ui = context.cover, let kind = fragmentKind {
            ShareCoverFragments(image: ui, palette: p, seed: seed, kind: kind)
        }
    }

    /// P-11 (REVIEW_2026-09-14_DESIGN.md): the cover is the card's GROUND now, for every
    /// format. It used to render so blurred/faint here (up to 80pt blur, 0.5 opacity)
    /// that it read as ambient tint rather than artwork — the only *sharp* cover was a
    /// small per-layout thumbnail (`coverArt()`), leaving a large empty gradient in
    /// between it and the stats block. A much lighter blur at full opacity fills the
    /// whole frame with real, recognisable artwork behind every layout. The scrim below
    /// is strengthened to compensate — darkest exactly where every layout actually
    /// places text (top brand/kicker, bottom stats/title), lighter through the middle so
    /// the ground cover still reads as a photo instead of disappearing under a panel.
    /// Text drawn over it uses `p.text`/`p.textMuted`/`onAccentGradient` — the
    /// WCAG-checked tokens `CoverPalette` already hands out (see its `ink(on:)` /
    /// `onAccentGradient`, both routed through `Extensions.swift`'s `ContrastInk`) — so
    /// AA contrast holds against this darker scrim in both the shipped dark card theme
    /// and a future lighter one, since the scrim is keyed to `p.backgroundDeep`/
    /// `p.background`, not a hardcoded color.
    private func backdrop(coverBlur: CGFloat = 80) -> some View {
        ZStack {
            p.backgroundDeep
            if let ui = context.cover {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: coverBlur * 0.22 * blurK).saturation(1.15)
            }
            LinearGradient(colors: [p.primaryAccent.opacity(0.28), .clear, p.secondaryAccent.opacity(0.24)],
                           startPoint: gradientStart, endPoint: gradientEnd)
            motifView(resolvedMotif).opacity(0.7)
            coverFragments()
            LinearGradient(colors: [
                p.backgroundDeep.opacity(0.80), p.backgroundDeep.opacity(0.38),
                p.backgroundDeep.opacity(0.30), p.backgroundDeep.opacity(0.58),
                p.backgroundDeep.opacity(0.94)
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var gradientStart: UnitPoint {
        let a = seed.gradientAngle * .pi / 180
        return UnitPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a))
    }
    private var gradientEnd: UnitPoint {
        let a = seed.gradientAngle * .pi / 180
        return UnitPoint(x: 0.5 - 0.5 * cos(a), y: 0.5 - 0.5 * sin(a))
    }

    @ViewBuilder private func motifView(_ m: ShareMotif) -> some View {
        switch m {
        case .blob:     ShareBlobMotif(palette: p, seed: seed)
        case .stripe:   ShareStripeMotif(palette: p, seed: seed)
        case .orbit:    ShareOrbitMotif(palette: p, seed: seed)
        case .wave:     ShareWaveMotif(palette: p, seed: seed)
        case .burst:    ShareBurstMotif(palette: p, seed: seed)
        case .halftone: ShareHalftoneMotif(palette: p, seed: seed)
        }
    }

    /// Cover that preserves the artwork's real aspect ratio (never crops printed text).
    @ViewBuilder private func coverArt(maxSide: CGFloat, corner: CGFloat, tilt: Bool = false) -> some View {
        Group {
            if let ui = context.cover {
                Image(uiImage: ui).resizable()
                    .aspectRatio(ui.size.width / max(ui.size.height, 1), contentMode: .fit)
                    .frame(maxWidth: maxSide, maxHeight: maxSide)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(p.text.opacity(0.18), lineWidth: f(1.5)))
            } else {
                RoundedRectangle(cornerRadius: corner).fill(p.background)
                    .frame(width: maxSide, height: maxSide)
                    .overlay(Image(systemName: "book.closed.fill").font(.system(size: maxSide * 0.28)).foregroundStyle(p.textMuted))
            }
        }
        // D4 (design brief 2026-08-12) shadow audit note, covering every `.shadow(` in
        // this file: these are deliberate glow/atmosphere effects for a shareable
        // *exported image*, keyed to the book's own extracted palette (`p.primaryAccent`
        // etc.), not to the app's live system Light/Dark theme — a share card has its
        // own fixed art direction per book regardless of which theme generated it.
        // Out of scope for D4's in-app Light/Dark surface audit.
        .shadow(color: p.primaryAccent.opacity(0.5), radius: f(45) * shadowK, x: 0, y: f(18) * shadowK)
        // The hero cover always renders upright — never rotated — regardless of `tilt`
        // or the seed. (Seeded rotation is kept only for decorative background fragments.)
    }

    @ViewBuilder private func brandMark() -> some View {
        if pr.showBranding {
            HStack(spacing: f(12)) {
                Image(systemName: "headphones.circle.fill").font(.system(size: f(38))).foregroundStyle(p.primaryAccent)
                Text("ShelfHead").font(.system(size: f(32), weight: .bold, design: .rounded)).foregroundStyle(p.text)
                Spacer()
            }
        }
    }

    private func kicker(_ text: String) -> some View {
        Text(text).font(.system(size: f(26), weight: .heavy, design: .rounded)).tracking(LocalizedText.tracking(f(3)))
            .foregroundStyle(p.highlight)
    }

    /// Content-aware label at the top of each card.
    private var kickerText: String {
        switch configuration.content {
        case .progress:             return String(localized: "NOW LISTENING", comment: "Share card kicker (all caps)")
        case .chapter:              return String(localized: "CURRENT CHAPTER", comment: "Share card kicker (all caps)")
        case .quote:
            if context.quoteIsUserNote { return String(localized: "MY NOTE", comment: "Share card kicker (all caps) for a user-written bookmark note") }
            if context.quoteIsPassage { return String(localized: "FROM THE BOOK", comment: "Share card kicker (all caps) for a passage clipped from the audiobook") }
            return String(localized: "BOOKMARKED MOMENT", comment: "Share card kicker (all caps) for a bookmarked moment")
        case .completion:           return String(localized: "BOOK FINISHED", comment: "Share card kicker (all caps)")
        case .streak:               return String(localized: "LISTENING STREAK", comment: "Share card kicker (all caps)")
        case .booksFinished:        return String(localized: "BOOKS FINISHED", comment: "Share card kicker (all caps)")
        case .listeningPersonality: return String(localized: "MY LISTENING PERSONALITY", comment: "Share card kicker (all caps)")
        case .yearInReview:
            return YearReviewShareData.kicker(year: context.yearReview?.year ?? Calendar.current.component(.year, from: Date()))
        }
    }

    /// Progress bars only make sense for progress/chapter content (and only if allowed).
    private var showsProgressBar: Bool {
        pr.showProgress && (configuration.content == .progress || configuration.content == .chapter)
    }

    private var byline: String {
        var parts: [String] = []
        if pr.showAuthor, !context.author.isEmpty { parts.append(context.author) }
        if pr.showNarrator, let n = context.narrator, !n.isEmpty { parts.append(String(localized: "Narrated by \(n)", comment: "Share card byline. %@ is the narrator's name.")) }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private func titleBlock(_ titleSize: CGFloat, align: TextAlignment = .leading) -> some View {
        VStack(alignment: align == .center ? .center : .leading, spacing: f(8)) {
            Text(context.title).font(.system(size: f(titleSize), weight: .bold, design: .serif))
                .foregroundStyle(p.text).lineLimit(3).minimumScaleFactor(0.5).multilineTextAlignment(align)
            if !byline.isEmpty {
                Text(byline).font(.system(size: f(26))).foregroundStyle(p.textMuted)
                    .lineLimit(2).multilineTextAlignment(align)
            }
        }
    }

    private func accentPill<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(.horizontal, f(28)).padding(.vertical, f(16))
            .background(LinearGradient(colors: [p.primaryAccent, p.secondaryAccent],
                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
    }

    private func progressBar(height: CGFloat = 18) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(p.text.opacity(0.14)).frame(height: f(height))
                Capsule().fill(LinearGradient(colors: [p.primaryAccent, p.secondaryAccent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(max(context.progress.progress, 0), 1), height: f(height))
                    .shadow(color: p.primaryAccent.opacity(0.6), radius: f(8) * shadowK)
            }
        }
        .frame(height: f(height))
    }

    private func progressRing(diameter: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(p.text.opacity(0.14), lineWidth: f(line))
            Circle().trim(from: 0, to: CGFloat(min(max(context.progress.progress, 0), 1)))
                .stroke(AngularGradient(colors: [p.primaryAccent, p.secondaryAccent, p.primaryAccent], center: .center),
                        style: StrokeStyle(lineWidth: f(line), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: p.primaryAccent.opacity(0.6), radius: f(12) * shadowK)
            VStack(spacing: 0) {
                (Text("\(context.progress.percent)").font(.system(size: f(diameter * 0.32), weight: .bold, design: .rounded))
                 + Text("%").font(.system(size: f(diameter * 0.15), weight: .bold, design: .rounded)))
                    .foregroundStyle(p.text)
                Text("complete").font(.system(size: f(diameter * 0.085), weight: .semibold, design: .rounded))
                    .tracking(LocalizedText.tracking(f(1))).foregroundStyle(p.textMuted)
            }
        }
        .frame(width: f(diameter), height: f(diameter))
    }

    // Code review fix (26 August 2026): removed dead `statChips()` + `statValues` —
    // ~30 lines with exactly one reference to their own name (their own definition).
    // The share-card styles that actually ship build their stat rows independently
    // (`bigStat`, `retroBadge`, and the cells array further down), each reading
    // `pr.showSpeed`/`pr.showStreak` directly rather than through these. Looked like a
    // layout superseded during the share-card style work and never removed.

    private func ordinal(_ n: Int) -> String {
        let ff = NumberFormatter(); ff.numberStyle = .ordinal
        // Format in the app's resolved localisation (not the device region) so English reads "10th" and Chinese "第10".
        ff.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return ff.string(from: NSNumber(value: n)) ?? "\(n)th"
    }

    // Content-driven headline value + caption.
    private var headline: (value: String, caption: String) {
        switch configuration.content {
        case .progress:
            return ("\(context.progress.percent)%", String(localized: "complete", comment: "Share card headline caption after a percentage"))
        case .chapter:
            if let ch = context.chapter {
                let cap: String
                if let i = ch.index, let t = ch.total { cap = String(localized: "Chapter \(String(i)) of \(String(t))", comment: "Share card chapter caption. First %@ is the chapter number, second is the total chapters.") }
                else if let i = ch.index { cap = String(localized: "Chapter \(String(i))", comment: "Share card chapter caption. %@ is the chapter number.") }
                else { cap = String(localized: "Now listening", comment: "Share card caption when the chapter number is unknown") }
                return (ch.title ?? String(localized: "This chapter", comment: "Share card headline when the chapter has no title"), cap)
            }
            return ("\(context.progress.percent)%", String(localized: "complete", comment: "Share card headline caption after a percentage"))
        case .quote:
            let attribution: String
            if context.quoteIsUserNote { attribution = String(localized: "My note", comment: "Share card quote attribution for a note the user wrote") }
            else if let a = context.quoteAttribution, !a.isEmpty { attribution = "— \(a)" }
            else if pr.showAuthor, !context.author.isEmpty { attribution = "— \(context.author)" }
            else { attribution = context.title }
            return (context.quote ?? context.tagline, attribution)
        case .completion:
            return (String(localized: "Finished", comment: "Share card headline for a finished book"), context.completion?.totalTime ?? context.progress.listened)
        case .streak:
            return ("\(max(context.statistics?.streakDays ?? 0, 0))", String(localized: "day streak", comment: "Share card stat caption under a number of days"))
        case .booksFinished:
            if let n = context.statistics?.booksFinished ?? context.completion?.bookNumber {
                return ("\(n)", n == 1 ? String(localized: "book finished", comment: "Share card stat caption, singular") : String(localized: "books finished", comment: "Share card stat caption, plural"))
            }
            return ("\(context.progress.percent)%", String(localized: "complete", comment: "Share card headline caption after a percentage"))
        case .listeningPersonality:
            return (personalityTitle, personalityCaption)
        case .yearInReview:
            let h = context.yearReview?.headline(privacy: pr)
            return (h?.value ?? "\u{2014}", h?.caption ?? String(localized: "listened", comment: "Share card stat caption after a listening-time figure"))
        }
    }

    private var personalityTitle: String {
        let stats = context.statistics
        if let tod = stats?.timeOfDay, !tod.isEmpty {
            switch tod.lowercased() {
            case let s where s.contains("night"): return String(localized: "The Night Owl", comment: "Listening personality title")
            case let s where s.contains("morning"): return String(localized: "The Early Bird", comment: "Listening personality title")
            case let s where s.contains("evening"): return String(localized: "The Wind-Down Reader", comment: "Listening personality title")
            case let s where s.contains("afternoon"): return String(localized: "The Afternoon Listener", comment: "Listening personality title")
            default: return String(localized: "The \(tod) Listener", comment: "Listening personality title. %@ is a time of day.")
            }
        }
        if let m = stats?.longestSessionMinutes, m >= 120 { return String(localized: "The Marathoner", comment: "Listening personality title") }
        if let s = stats?.streakDays, s >= 7 { return String(localized: "The Devotee", comment: "Listening personality title") }
        if let g = stats?.topGenre, !g.isEmpty { return String(localized: "\(g) Explorer", comment: "Listening personality title. %@ is a genre name, e.g. Fantasy.") }
        return String(localized: "The Bookworm", comment: "Listening personality title")
    }

    private var personalityCaption: String {
        var bits: [String] = []
        if let m = context.statistics?.minutesThisWeek { bits.append(String(localized: "\(String(m)) min this week", comment: "Share card caption. %@ is a number of minutes.")) }
        if let g = context.statistics?.topGenre, !g.isEmpty { bits.append(g) }
        if let n = context.statistics?.favouriteNarrator, !n.isEmpty, pr.showNarrator { bits.append(n) }
        return bits.isEmpty ? String(localized: "Your listening personality", comment: "Share card caption fallback") : bits.joined(separator: " • ")
    }

    // MARK: Content focus — a content-aware block reused across themes

    @ViewBuilder private func contentFocus() -> some View {
        switch configuration.content {
        case .progress:             progressFocus
        case .chapter:              chapterFocus
        case .quote:                quoteFocus
        case .completion:           completionFocus
        // Y1 (REVIEW_2026-09-04_UI.md): routed through the single headlineIsVisible gate.
        case .streak:               bigStat("\(max(context.statistics?.streakDays ?? 0, 0))", String(localized: "day streak", comment: "Share card stat caption under a number of days"), show: SharePrivacyOptions.headlineIsVisible(content: configuration.content, privacy: pr))
        case .booksFinished:        bigStat("\(context.statistics?.booksFinished ?? context.completion?.bookNumber ?? 0)", String(localized: "books finished", comment: "Share card stat caption, plural"), show: SharePrivacyOptions.headlineIsVisible(content: configuration.content, privacy: pr))
        case .listeningPersonality: personalityFocus
        case .yearInReview:
            VStack(alignment: .leading, spacing: f(20)) {
                yearHeadline(valueSize: 150)
                statGrid(yearCells, columns: 2)
            }
        }
    }

    @ViewBuilder private var progressFocus: some View {
        if pr.showProgress {
            HStack(spacing: f(34)) {
                progressRing(diameter: 190, line: 22)
                VStack(alignment: .leading, spacing: f(10)) {
                    Text(context.progress.listened).font(.system(size: f(50), weight: .bold, design: .rounded)).foregroundStyle(p.text)
                    Text("listened").font(.system(size: f(26))).foregroundStyle(p.textMuted)
                    if pr.showRemainingTime {
                        Text(context.progress.remaining).font(.system(size: f(26), weight: .semibold)).foregroundStyle(p.primaryAccent).padding(.top, f(6))
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            accentPill { Text(context.tagline).font(.system(size: f(30), weight: .semibold, design: .serif)).foregroundStyle(p.onAccentGradient) }
        }
    }

    private var chapterFocus: some View {
        VStack(alignment: .leading, spacing: f(8)) {
            Text(headline.value).font(.system(size: f(56), weight: .bold, design: .serif))
                .foregroundStyle(p.text).lineLimit(3).minimumScaleFactor(0.5)
            Text(headline.caption).font(.system(size: f(28), weight: .semibold, design: .rounded)).foregroundStyle(p.primaryAccent)
            if showsProgressBar { progressBar().padding(.top, f(10)) }
        }
    }

    private var quoteFocus: some View {
        VStack(alignment: .leading, spacing: f(14)) {
            Text("“\(context.quote ?? context.tagline)”")
                .font(.system(size: f(44), weight: .semibold, design: .serif)).italic()
                .foregroundStyle(p.text).lineLimit(6).minimumScaleFactor(0.5)
            Text(headline.caption).font(.system(size: f(28))).foregroundStyle(p.textMuted)
        }
    }

    private var completionFocus: some View {
        VStack(alignment: .leading, spacing: f(8)) {
            // Y4 (REVIEW_2026-09-04_UI.md): `completionSubtitle` is entirely numeric (total
            // time, days-to-finish) — gate it like every other stat, but keep a plain
            // "Finished" line rather than leaving this block empty when hidden.
            Text(pr.showCompletionDetails ? completionSubtitle : String(localized: "Finished", comment: "Share card headline for a finished book")).font(.system(size: f(32), weight: .semibold)).foregroundStyle(p.text)
            if pr.showCompletionDetails, let n = context.completion?.bookNumber ?? context.statistics?.booksFinished {
                Text(String(localized: "My \(ordinal(n)) audiobook", comment: "Share card line. %@ is a locale-formatted ordinal (English 10th; in Chinese it already includes 第, so translate like 我的%@本有声书).")).font(.system(size: f(28))).foregroundStyle(p.primaryAccent)
            }
        }
    }

    @ViewBuilder private func bigStat(_ value: String, _ caption: String, show: Bool) -> some View {
        // Y1 (REVIEW_2026-09-04_UI.md): always render the block — a hidden stat used to leave
        // just the kicker with nothing under it. Show a neutral "—" fallback instead.
        VStack(alignment: .leading, spacing: f(2)) {
            Text(show ? value : "—").font(.system(size: f(190), weight: .black, design: .rounded))
                .foregroundStyle(p.primaryAccent).lineLimit(1).minimumScaleFactor(0.3)
                .shadow(color: p.primaryAccent.opacity(0.5), radius: f(18) * shadowK)
            Text(caption).font(.system(size: f(34), weight: .semibold, design: .rounded)).foregroundStyle(p.text)
        }
    }

    private var personalityFocus: some View {
        VStack(alignment: .leading, spacing: f(14)) {
            // Y9 (REVIEW_2026-09-04_UI.md): a long caption ("X min this week • Genre • Narrator")
            // had lineLimit(2) with no shrink, so it could clip mid-word instead of fitting.
            Text(personalityCaption).font(.system(size: f(28), weight: .semibold)).foregroundStyle(p.text).lineLimit(2).minimumScaleFactor(0.6)
            personalityGrid
        }
    }

    /// Landscape scaffold: cover on the left, a content column on the right.
    @ViewBuilder private func wideScaffold<R: View>(coverSide: CGFloat, tilt: Bool = true, @ViewBuilder right: () -> R) -> some View {
        HStack(alignment: .center, spacing: f(56)) {
            coverArt(maxSide: coverSide, corner: f(28), tilt: tilt)
            VStack(alignment: .leading, spacing: f(16)) { right() }
            Spacer(minLength: 0)
        }
    }

    // MARK: Spotlight

    private var spotlight: some View {
        ZStack {
            backdrop()
            content(padding: f(72)) {
                if isWide { spotlightWide }
                else {
                    switch seed.layoutVariant {
                    case 0:  spotlightCentered
                    case 1:  spotlightOffset
                    default: spotlightEditorial
                    }
                }
            }
        }
    }

    private var spotlightCentered: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandMark().padding(.bottom, f(40))
            coverArt(maxSide: f(600), corner: f(28), tilt: true).frame(maxWidth: .infinity)
            Spacer(minLength: f(40))
            kicker(kickerText)
            titleBlock(64).padding(.top, f(8))
            contentFocus().padding(.top, f(30))
        }
    }

    private var spotlightOffset: some View {
        VStack(alignment: .leading, spacing: f(18)) {
            brandMark()
            HStack {
                coverArt(maxSide: f(460), corner: f(24), tilt: true).offset(x: f(seed.coverOffsetX))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            kicker(kickerText)
            titleBlock(58)
            contentFocus()
        }
    }

    private var spotlightEditorial: some View {
        VStack(alignment: .leading, spacing: f(16)) {
            brandMark()
            kicker(kickerText)
            titleBlock(80)
            Spacer(minLength: f(20))
            HStack(alignment: .bottom, spacing: f(40)) {
                coverArt(maxSide: f(420), corner: f(24), tilt: true)
                contentFocus()
            }
            Spacer(minLength: 0)
        }
    }

    private var spotlightWide: some View {
        wideScaffold(coverSide: f(680)) {
            brandMark(); kicker(kickerText); titleBlock(56)
            Spacer(minLength: f(8)); contentFocus(); Spacer(minLength: 0)
        }
    }

    // MARK: Kinetic typography

    private var kinetic: some View {
        ZStack {
            backdrop(coverBlur: 60)
            content(padding: f(72)) {
                VStack(alignment: .leading, spacing: f(6)) {
                    HStack(alignment: .top) {
                        brandMark()
                        Spacer()
                        coverArt(maxSide: f(200), corner: f(16), tilt: true)
                    }
                    Spacer(minLength: 0)
                    kicker(kickerText)
                    // Y3 (REVIEW_2026-09-04_UI.md): `.chapter` puts a real chapter title in this
                    // slot, not a giant number like streak/booksFinished — treat it as prose
                    // (same reduced size as `.quote`) instead of crushing it at size 300 / 1 line.
                    let usesProseHeadline = configuration.content == .quote || configuration.content == .chapter
                    // Y1 (REVIEW_2026-09-04_UI.md): gate the raw headline value on privacy.
                    Text(SharePrivacyOptions.headlineIsVisible(content: configuration.content, privacy: pr) ? headline.value : "—")
                        .font(.system(size: f(usesProseHeadline ? 96 : 300), weight: .black, design: .rounded))
                        .foregroundStyle(p.primaryAccent)
                        .lineLimit(configuration.content == .quote ? 5 : (configuration.content == .chapter ? 3 : 1))
                        .minimumScaleFactor(0.3)
                        .shadow(color: p.primaryAccent.opacity(0.5), radius: f(20) * shadowK)
                    Text(context.title.uppercased())
                        .font(.system(size: f(48), weight: .heavy, design: .rounded))
                        .foregroundStyle(p.text).lineLimit(2).minimumScaleFactor(0.5)
                        .padding(.top, f(10))
                    if !byline.isEmpty {
                        Text(byline).font(.system(size: f(28))).foregroundStyle(p.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if showsProgressBar { progressBar().padding(.top, f(10)) }
                }
            }
        }
    }

    // MARK: Collage

    private var collage: some View {
        ZStack {
            backdrop(coverBlur: 70)
            // Oversized ghost value behind the cover (progress content only).
            if pr.showProgress && configuration.content == .progress {
                Text("\(context.progress.percent)%")
                    .font(.system(size: f(420), weight: .black, design: .rounded))
                    .foregroundStyle(p.primaryAccent.opacity(0.14))
                    .rotationEffect(.degrees(-12))
                    .offset(x: f(seed.coverOffsetX * 2), y: f(-40))
            }
            content(padding: f(72)) {
                if isWide {
                    wideScaffold(coverSide: f(620)) {
                        brandMark(); kicker(kickerText); collageBadge; titleBlock(50)
                        if showsProgressBar { progressBar() }
                    }
                } else {
                    VStack(alignment: .leading, spacing: f(20)) {
                        brandMark()
                        Spacer(minLength: 0)
                        ZStack(alignment: .bottomLeading) {
                            coverArt(maxSide: f(540), corner: f(24), tilt: true)
                                .offset(x: f(seed.coverOffsetX), y: 0)
                            collageBadge.rotationEffect(.degrees(-4)).offset(x: f(-24), y: f(30))
                        }
                        Spacer(minLength: 0)
                        kicker(kickerText)
                        titleBlock(52)
                        if showsProgressBar { progressBar() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var collageBadge: some View {
        if configuration.content == .progress && pr.showProgress {
            accentPill {
                Text("\(context.progress.percent)% • \(context.progress.listened)")
                    .font(.system(size: f(30), weight: .bold, design: .rounded)).foregroundStyle(p.onAccentGradient)
            }
        } else {
            // Y1 (REVIEW_2026-09-04_UI.md): gate the raw headline value on privacy.
            accentPill {
                Text(SharePrivacyOptions.headlineIsVisible(content: configuration.content, privacy: pr) ? headline.value : "—")
                    .font(.system(size: f(30), weight: .bold, design: .rounded)).foregroundStyle(p.onAccentGradient)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
        }
    }

    // MARK: Chapter wave

    private var chapterWave: some View {
        ZStack {
            backdrop(coverBlur: 80)
            content(padding: f(72)) {
                if isWide {
                    wideScaffold(coverSide: f(560)) {
                        brandMark()
                        kicker(kickerText)
                        Text(headline.value).font(.system(size: f(58), weight: .bold, design: .serif))
                            .foregroundStyle(p.text).lineLimit(3).minimumScaleFactor(0.5)
                        titleBlock(32)
                        if showsProgressBar { chapterProgressRow }
                    }
                } else {
                    VStack(alignment: .leading, spacing: f(18)) {
                        brandMark()
                        coverArt(maxSide: f(460), corner: f(24), tilt: true).frame(maxWidth: .infinity, alignment: .center)
                        Spacer(minLength: 0)
                        kicker(kickerText)
                        Text(headline.value)
                            .font(.system(size: f(64), weight: .bold, design: .serif))
                            .foregroundStyle(p.text).lineLimit(3).minimumScaleFactor(0.5)
                        titleBlock(34)
                        Spacer(minLength: 0)
                        if showsProgressBar { chapterProgressRow }
                    }
                }
            }
        }
    }

    private var chapterProgressRow: some View {
        VStack(alignment: .leading, spacing: f(14)) {
            progressBar()
            HStack {
                Text("\(context.progress.listened) listened").foregroundStyle(p.text)
                Spacer()
                if pr.showRemainingTime { Text(context.progress.remaining).foregroundStyle(p.textMuted) }
            }.font(.system(size: f(26), weight: .semibold, design: .rounded))
        }
    }

    // MARK: Retro player

    private var retroPlayer: some View {
        ZStack {
            backdrop(coverBlur: 70)
            content(padding: f(64)) {
                if isWide {
                    HStack(spacing: f(56)) {
                        coverArt(maxSide: f(560), corner: f(20), tilt: false)
                            .overlay(RoundedRectangle(cornerRadius: f(20)).strokeBorder(p.highlight.opacity(0.4), lineWidth: f(6)))
                        VStack(alignment: .leading, spacing: f(20)) {
                            brandMark(); titleBlock(40)
                            if showsProgressBar { progressBar(height: 14) }
                            retroTransport
                            retroBadges
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: f(24)) {
                        brandMark()
                        Spacer(minLength: 0)
                        coverArt(maxSide: f(520), corner: f(20), tilt: false)
                            .overlay(RoundedRectangle(cornerRadius: f(20)).strokeBorder(p.highlight.opacity(0.4), lineWidth: f(6)))
                        titleBlock(46, align: .center).frame(maxWidth: .infinity)
                        if showsProgressBar { progressBar(height: 14) }
                        retroTransport
                        retroBadges
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var retroTransport: some View {
        HStack(spacing: f(40)) {
            Image(systemName: "backward.fill")
            Image(systemName: "play.circle.fill").font(.system(size: f(90)))
            Image(systemName: "forward.fill")
        }
        .font(.system(size: f(48)))
        .foregroundStyle(p.primaryAccent)
    }

    @ViewBuilder private var retroBadges: some View {
        if configuration.content == .progress {
            HStack(spacing: f(16)) {
                if pr.showSpeed { retroBadge("\(context.progress.speed)") }
                if pr.showProgress { retroBadge("\(context.progress.percent)%") }
                if pr.showRemainingTime { retroBadge(context.progress.remaining) }
            }
        } else {
            // Y1 (REVIEW_2026-09-04_UI.md): gate the raw headline value on privacy.
            retroBadge(SharePrivacyOptions.headlineIsVisible(content: configuration.content, privacy: pr) ? headline.value : "—")
        }
    }

    private func retroBadge(_ s: String) -> some View {
        Text(s).font(.system(size: f(26), weight: .bold, design: .monospaced))
            .foregroundStyle(p.text)
            .padding(.horizontal, f(20)).padding(.vertical, f(10))
            .background(p.text.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(p.text.opacity(0.2), lineWidth: 1))
    }

    // MARK: Completion burst

    private var completionBurst: some View {
        ZStack {
            backdrop(coverBlur: 90)
            content(padding: f(72)) {
                if isWide {
                    HStack(spacing: f(56)) {
                        completionCover(f(600))
                        VStack(alignment: .leading, spacing: f(16)) {
                            brandMark(); kicker(kickerText)
                            Text(context.title).font(.system(size: f(56), weight: .bold, design: .serif))
                                .foregroundStyle(p.text).lineLimit(3).minimumScaleFactor(0.5)
                            // Y4 (REVIEW_2026-09-04_UI.md): the title above stays; only the
                            // numeric time/day-count and book-number pill are gated.
                            if pr.showCompletionDetails {
                                Text(completionSubtitle).font(.system(size: f(30))).foregroundStyle(p.textMuted)
                                completionYearPill
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: f(28)) {
                        brandMark()
                        Spacer(minLength: 0)
                        kicker(kickerText)
                        completionCover(f(560))
                        Text(context.title).font(.system(size: f(60), weight: .bold, design: .serif))
                            .foregroundStyle(p.text).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5).padding(.top, f(20))
                        // Y4 (REVIEW_2026-09-04_UI.md): title above stays; numeric details gated.
                        if pr.showCompletionDetails {
                            Text(completionSubtitle).font(.system(size: f(30))).foregroundStyle(p.textMuted)
                            completionYearPill.padding(.top, f(10))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func completionCover(_ side: CGFloat) -> some View {
        coverArt(maxSide: side, corner: f(28), tilt: true)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: f(60), weight: .bold)).foregroundStyle(p.onAccentGradient)
                    .frame(width: f(130), height: f(130))
                    .background(LinearGradient(colors: [p.primaryAccent, p.secondaryAccent], startPoint: .top, endPoint: .bottom), in: Circle())
                    .shadow(color: p.primaryAccent.opacity(0.6), radius: f(16) * shadowK)
                    .offset(x: f(26), y: f(26))
            }
    }

    @ViewBuilder private var completionYearPill: some View {
        if let n = context.completion?.bookNumber ?? context.statistics?.booksFinished {
            accentPill { Text(String(localized: "My \(ordinal(n)) audiobook", comment: "Share card line. %@ is a locale-formatted ordinal (English 10th; in Chinese it already includes 第, so translate like 我的%@本有声书).")).font(.system(size: f(30), weight: .bold, design: .rounded)).foregroundStyle(p.onAccentGradient) }
        }
    }

    private var completionSubtitle: String {
        let total = context.completion?.totalTime.isEmpty == false ? context.completion!.totalTime : context.progress.listened
        if let d = context.completion?.finishedInDays {
            return d == 1
                ? String(localized: "\(total) • Finished in 1 day", comment: "Share card completion line, singular. %@ is a total listening time string.")
                : String(localized: "\(total) • Finished in \(String(d)) days", comment: "Share card completion line, plural. First %@ is a total listening time string, second is the number of days (2 or more).")
        }
        return total
    }

    // MARK: Listening personality

    private var personality: some View {
        ZStack {
            backdrop(coverBlur: 70)
            content(padding: f(72)) {
                if isWide {
                    HStack(spacing: f(56)) {
                        VStack(alignment: .leading, spacing: f(14)) {
                            brandMark(); kicker(kickerText)
                            Text(personalityTitle).font(.system(size: f(84), weight: .black, design: .rounded))
                                .foregroundStyle(p.primaryAccent).lineLimit(2).minimumScaleFactor(0.4)
                                .shadow(color: p.primaryAccent.opacity(0.5), radius: f(18) * shadowK)
                            Text(personalityCaption).font(.system(size: f(28), weight: .semibold)).foregroundStyle(p.text).lineLimit(2).minimumScaleFactor(0.6)
                        }
                        VStack(spacing: f(16)) { personalityGrid }.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: f(18)) {
                        brandMark()
                        Spacer(minLength: 0)
                        kicker(kickerText)
                        Text(personalityTitle)
                            .font(.system(size: f(96), weight: .black, design: .rounded))
                            .foregroundStyle(p.primaryAccent).lineLimit(2).minimumScaleFactor(0.4)
                            .shadow(color: p.primaryAccent.opacity(0.5), radius: f(18) * shadowK)
                        Text(personalityCaption).font(.system(size: f(30), weight: .semibold)).foregroundStyle(p.text).lineLimit(2).minimumScaleFactor(0.6)
                        Spacer(minLength: 0)
                        personalityGrid
                        Spacer(minLength: 0)
                        HStack(spacing: f(20)) {
                            coverArt(maxSide: f(150), corner: f(14), tilt: true)
                            VStack(alignment: .leading, spacing: f(4)) {
                                Text(context.title).font(.system(size: f(30), weight: .bold, design: .serif)).foregroundStyle(p.text).lineLimit(2)
                                if !byline.isEmpty {
                                    Text(byline).font(.system(size: f(24))).foregroundStyle(p.textMuted).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var personalityGrid: some View {
        let stats = context.statistics
        var cells: [(String, String)] = []
        if let m = stats?.minutesThisWeek { cells.append(("\(m)", String(localized: "min this week", comment: "Share card stat caption"))) }
        if pr.showStreak, let s = stats?.streakDays, s > 0 { cells.append(("\(s)", String(localized: "day streak", comment: "Share card stat caption"))) }
        if let g = stats?.topGenre, !g.isEmpty { cells.append((g, String(localized: "top genre", comment: "Share card stat caption"))) }
        if pr.showNarrator, let n = stats?.favouriteNarrator, !n.isEmpty { cells.append((n, String(localized: "top narrator", comment: "Share card stat caption"))) }
        if let n = stats?.booksFinished { cells.append(("\(n)", String(localized: "books finished", comment: "Share card stat caption"))) }
        if let ls = stats?.longestSessionMinutes { cells.append(("\(ls)m", String(localized: "longest session", comment: "Share card stat caption"))) }
        if let pa = stats?.percentAboveAverage { cells.append(("\(pa > 0 ? "+" : "")\(pa)%", String(localized: "vs. your average", comment: "Share card stat caption: percent above the user's own average"))) }
        let shown = Array(cells.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: f(16)) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: f(4)) {
                    Text(c.0).font(.system(size: f(48), weight: .bold, design: .rounded)).foregroundStyle(p.primaryAccent).lineLimit(1).minimumScaleFactor(0.5)
                    Text(c.1).font(.system(size: f(22))).foregroundStyle(p.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(f(22))
                .background(p.text.opacity(0.07), in: RoundedRectangle(cornerRadius: f(20)))
                .overlay(RoundedRectangle(cornerRadius: f(20)).strokeBorder(p.text.opacity(0.12), lineWidth: 1))
            }
        }
    }

    // MARK: Year in Review (Critique 2026-10-06, shape → bolder)

    /// "MY 2026", the year's hours as the big stat, the top covers as a collage (the
    /// covers carry the colour), then books played / top author / best streak (all-time).
    /// Every figure goes through the privacy options; Cover Only leaves kicker + collage.
    private var yearInReviewCard: some View {
        ZStack {
            backdrop(coverBlur: 90)
            content(padding: f(72)) {
                if configuration.format == .story { yearStory } else { yearWide }
            }
        }
    }

    private var yearCells: [ShareStatCell] {
        context.yearReview?.cells(privacy: pr) ?? []
    }

    private var yearStory: some View {
        VStack(alignment: .leading, spacing: f(28)) {
            brandMark()
            Spacer(minLength: 0)
            kicker(kickerText)
            yearHeadline(valueSize: 230)
            yearCollage(width: size.width - f(144), maxHeight: f(820))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if !yearCells.isEmpty { statGrid(yearCells, columns: min(yearCells.count, 3)) }
        }
    }

    private var yearWide: some View {
        let collageWidth = isWide ? f(820) : f(440)
        return HStack(alignment: .center, spacing: f(48)) {
            VStack(alignment: .leading, spacing: f(20)) {
                brandMark()
                Spacer(minLength: 0)
                kicker(kickerText)
                yearHeadline(valueSize: isWide ? 210 : 160)
                Spacer(minLength: 0)
                if !yearCells.isEmpty { statGrid(yearCells, columns: isWide ? 2 : 1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            yearCollage(width: collageWidth, maxHeight: size.height - f(144))
        }
    }

    @ViewBuilder private func yearHeadline(valueSize: CGFloat) -> some View {
        if let h = context.yearReview?.headline(privacy: pr) {
            VStack(alignment: .leading, spacing: f(2)) {
                Text(h.value)
                    .font(.system(size: f(valueSize), weight: .black, design: .rounded)).monospacedDigit()
                    .foregroundStyle(p.primaryAccent).lineLimit(1).minimumScaleFactor(0.3)
                    .shadow(color: p.primaryAccent.opacity(0.5), radius: f(18) * shadowK)
                Text(h.caption).font(.system(size: f(40), weight: .semibold, design: .rounded))
                    .foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.6)
            }
        } else {
            // Privacy hides the totals: a line of New York (share cards only) instead of "—".
            Text("My year in audiobooks").font(.system(size: f(72), weight: .bold, design: .serif))
                .foregroundStyle(p.text).lineLimit(2).minimumScaleFactor(0.5)
        }
    }

    /// The year's top covers: one alone, two side by side, three as a big #1 beside a
    /// stacked #2/#3 (mirrored by the seed), four as a 2×2. Covers are fitted, never
    /// cropped, over a soft fill of themselves. No covers, no collage.
    @ViewBuilder private func yearCollage(width: CGFloat, maxHeight: CGFloat) -> some View {
        let covers = Array((context.yearReview?.covers ?? []).prefix(4))
        let gap = f(20)
        switch covers.count {
        case 0:
            EmptyView()
        case 1:
            collageTile(covers[0], side: min(width * 0.72, maxHeight))
        case 2:
            let side = min((width - gap) / 2, maxHeight)
            HStack(spacing: gap) {
                collageTile(covers[0], side: side)
                collageTile(covers[1], side: side)
            }
        case 3:
            let small = min((width - 2 * gap) / 3, (maxHeight - gap) / 2)
            let big = 2 * small + gap
            HStack(alignment: .top, spacing: gap) {
                if seed.layoutVariant % 2 == 0 { collageTile(covers[0], side: big) }
                VStack(spacing: gap) {
                    collageTile(covers[1], side: small)
                    collageTile(covers[2], side: small)
                }
                if seed.layoutVariant % 2 != 0 { collageTile(covers[0], side: big) }
            }
        default:
            let side = min((width - gap) / 2, (maxHeight - gap) / 2)
            VStack(spacing: gap) {
                HStack(spacing: gap) { collageTile(covers[0], side: side); collageTile(covers[1], side: side) }
                HStack(spacing: gap) { collageTile(covers[2], side: side); collageTile(covers[3], side: side) }
            }
        }
    }

    private func collageTile(_ image: UIImage, side: CGFloat) -> some View {
        let corner = f(24)
        return ZStack {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: side, height: side).clipped()
                .blur(radius: f(30) * blurK).opacity(0.6)
            Image(uiImage: image).resizable()
                .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                .frame(maxWidth: side, maxHeight: side)
        }
        .frame(width: side, height: side)
        .background(p.background)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(p.text.opacity(0.18), lineWidth: f(1.5)))
        // Exported-image atmosphere, like `coverArt`'s shadow (see the D4 note there).
        .shadow(color: .black.opacity(0.35), radius: f(24) * shadowK, x: 0, y: f(12) * shadowK)
    }

    /// Figure cells in the Persona grid's style, for any list of cells.
    private func statGrid(_ cells: [ShareStatCell], columns: Int) -> some View {
        let count = max(columns, 1)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: f(16)), count: count), spacing: f(16)) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: f(4)) {
                    Text(c.value).font(.system(size: f(48), weight: .bold, design: .rounded))
                        .foregroundStyle(p.primaryAccent).lineLimit(2).minimumScaleFactor(0.4)
                    Text(c.caption).font(.system(size: f(22))).foregroundStyle(p.textMuted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(f(22))
                .background(p.text.opacity(0.07), in: RoundedRectangle(cornerRadius: f(20)))
                .overlay(RoundedRectangle(cornerRadius: f(20)).strokeBorder(p.text.opacity(0.12), lineWidth: 1))
            }
        }
    }

    // MARK: Content frame

    private func content<V: View>(padding: CGFloat, @ViewBuilder _ inner: () -> V) -> some View {
        inner()
            .padding(padding)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Motif identifiers used both by the seed (`motifVariant`) and by themes that force one.
enum ShareMotif: Int, CaseIterable { case blob, stripe, orbit, wave, burst, halftone }

// MARK: - Rendering + cover loading

enum ShareCardRenderer {
    /// Load a cover, reusing the app's in-memory cover cache.
    ///
    /// Item 6 (REVIEW-2026-09-09 remaining): this was the fourth instance of the
    /// "bypasses the API type" bug class CLAUDE.md names — it built its request with
    /// `authorizedCoverRequest` and called `URLSession.shared.data(for:)` itself, so the
    /// share card's cover fetch got the right headers but none of
    /// `AudiobookshelfAPI`'s silent refresh-and-retry-once on a 401. Behind a reverse
    /// proxy, or simply with an access token that had rotated, building a share card
    /// produced a card with no artwork until something else refreshed the token.
    /// `authorizedData(for:)` builds the identical request (bearer + per-account custom
    /// headers via `AuthStore.authorizedRequest(url:)`) and adds that one retry.
    ///
    /// Semantics deliberately unchanged: the `file://` and in-memory-cache fast paths
    /// above still short-circuit first; this path still does *not* touch
    /// `DiskCoverCache` (the share card wants the full 600px image, not the grid's
    /// downsampled one) and still caches only a successful decode. The explicit
    /// `(200..<300)` check is gone because `authorizedData` throws on any non-2xx
    /// (`validateStatus`), which the `catch` below already turns into `nil` — so an
    /// error body still can't reach `UIImage(data:)` or the cache. Cancellation is
    /// likewise unchanged: a cancelled fetch throws out of the `do` rather than being
    /// swallowed by a `try?`.
    static func loadCover(itemId: String) async -> UIImage? {
        // `await`: `shelfCoverURL` is `@MainActor` (reads `DownloadManager` state);
        // this function itself stays plain `async`/nonisolated since the rest of its
        // body (network fetch, decode, cache) is deliberately off the main actor.
        guard let url = await shelfCoverURL(itemId: itemId, width: 600) else { return nil }
        if url.isFileURL { return UIImage(contentsOfFile: url.path) }
        if let cached = CoverImageCache.shared.object(forKey: url as NSURL) { return cached }
        do {
            try Task.checkCancellation()
            let data = try await AudiobookshelfAPI.shared.authorizedData(for: url)
            try Task.checkCancellation()
            guard let image = UIImage(data: data) else { return nil }
            CoverImageCache.shared.setObject(image, forKey: url as NSURL, cost: CoverImageCache.decodedCost(of: image))
            return image
        } catch {
            // Cancellation and genuine failures both yield nil, but cancellation now stops
            // the request rather than being swallowed by `try?`.
            return nil
        }
    }

    /// Render to a single reusable temp file (previous card is purged first).
    @MainActor
    static func render(context: ShareCardContext, configuration: ShareCardConfiguration) -> UIImage? {
        let size = configuration.format.exportSize
        let view = ShareCardView(context: context, configuration: configuration, size: size, renderMode: .export)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1                 // sizes are already the target pixel dimensions
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Render to a `CGImage` on the main actor (view creation must be main-actor). The
    /// caller then hands the CGImage to a detached task for the expensive PNG encode.
    @MainActor
    static func renderCGImage(context: ShareCardContext, configuration: ShareCardConfiguration) -> CGImage? {
        let size = configuration.format.exportSize
        let view = ShareCardView(context: context, configuration: configuration, size: size, renderMode: .export)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// PNG-encode off the main actor via ImageIO (avoids `UIImage.pngData()` on main).
    static func pngData(from cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Writes PNG data to a fresh temp file after clearing older share PNGs.
    static func writeData(_ data: Data?) -> URL? {
        guard let data else { return nil }
        cleanupTempCards()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfHead-share-\(UUID().uuidString).png")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Remove previously exported share cards so the temp dir doesn't grow unbounded.
    static func cleanupTempCards() {
        let dir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("ShelfHead-share-") || f.lastPathComponent.hasPrefix("ShelfHead-story-")
            || f.lastPathComponent.hasPrefix("ShelfHead-square-") || f.lastPathComponent.hasPrefix("ShelfHead-landscape-")
            || f.lastPathComponent.hasPrefix("ShelfHead-completion-") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Identifiable wrapper so a rendered card URL can drive a `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Identifiable wrapper carrying the prepared context (cover already loaded) so a
/// `.sheet(item:)` can present the composer.
struct ShareSession: Identifiable {
    let id = UUID()
    let context: ShareCardContext
    /// Batch 426: extra files shared with the image (a quote clip's audio).
    var attachments: [URL] = []
}

// MARK: - Wrapping chip layout (P-11, REVIEW_2026-09-14_DESIGN.md, item 6)

/// A plain left-to-right wrap: fills a row until the next chip wouldn't fit, then starts
/// a new line. Used so a chip row (the preset row below) can never clip a label at large
/// Dynamic Type sizes the way a fixed-width tile in a horizontal `ScrollView` could —
/// worst case here is an extra line, never truncated/cut-off text.
struct ShareChipFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                widestRow = max(widestRow, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widestRow = max(widestRow, rowWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Composer sheet

struct ShareComposerSheet: View {
    let context: ShareCardContext
    /// Batch 426: extra files shared with the image (a quote clip's audio).
    var attachments: [URL] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var format: ShareCardFormat = .story
    @State private var theme: ShareCardTheme = .spotlight
    @State private var content: ShareCardContent = .progress
    @State private var privacy = SharePrivacyOptions()
    @State private var shuffle = 0
    @State private var showCustomise = false
    @State private var isRendering = false
    @State private var renderError = false
    // Critique 2026-10-06 (shape → bolder): "Photos access denied" was a dead-end toast.
    // It's an alert with a route to Settings now.
    @State private var photosDenied = false
    @State private var payload: SharePayload?
    // Critique 2026-10-06 (shape → bolder): the composer's own amber capsule toast is gone;
    // it uses the app's shared `.toast` (glass, announced to VoiceOver), with a style per
    // message.
    @State private var toast: String?
    @State private var toastStyle: ToastStyle = .success
    @State private var hasPickedDefaults = false
    /// Extracted once (off-main) and cached — not recomputed on every state change.
    @State private var basePalette: CoverPalette = .brand

    private var configuration: ShareCardConfiguration {
        let seed = ShareVisualSeed.make(key: context.seedKey, shuffle: shuffle)
        return ShareCardConfiguration(
            format: format, theme: theme, content: content,
            palette: basePalette.hueShifted(seed.accentHueOffset),
            seed: seed, privacy: privacy
        )
    }

    private var availableThemes: [ShareCardTheme] { ShareCardTheme.available(for: context) }

    // Which privacy toggles are relevant to the currently-selected content.
    private var showsProgressToggle: Bool { content == .progress || content == .chapter }
    private var showsRemainingToggle: Bool { content == .progress || content == .chapter }
    private var showsSpeedToggle: Bool { content == .progress }
    private var showsStreakToggle: Bool {
        content == .streak || content == .listeningPersonality || content == .yearInReview
    }

    private var availableContent: [ShareCardContent] { ShareCardContent.available(for: context) }

    // MARK: Presets (P-11, REVIEW_2026-09-14_DESIGN.md)

    private var availablePresets: [SharePreset] {
        SharePreset.allCases.filter { SharePreset.isAvailable($0, availableThemes: availableThemes) }
    }

    /// The preset the current theme belongs to. Remix can land Spotlight on Collage or
    /// Kinetic; those are Spotlight's family (`SharePreset.remixThemes`), so Spotlight
    /// stays selected.
    private var selectedPreset: SharePreset? {
        guard let preset = SharePreset.preset(for: theme), availablePresets.contains(preset) else { return nil }
        return preset
    }

    /// Applies a preset's theme and its resolved content together — the single place
    /// that replaces the old separate Style-row-then-Card-Type-row flow. `haptic: false`
    /// is for `pickDefaults()`, which runs on `onAppear` and shouldn't buzz the phone
    /// before the user has touched anything.
    private func applyPreset(_ preset: SharePreset, haptic: Bool = true) {
        if haptic { Haptics.selection() }
        theme = preset.theme
        content = SharePreset.resolvedContent(for: preset, available: availableContent)
    }

    var body: some View {
        // Critique 2026-10-06 (shape → bolder): system chrome. The hand-built header (a
        // "Share" label, an unlabelled sliders glyph and an amber ✕ on a cream disc) is
        // a NavigationStack with an inline title and the system Close button
        // (`SheetCloseButton`: `Button(role: .close)` on iOS 26+, "Done" before), and
        // Privacy is a labelled control in the options below.
        //
        // User report (28 August 2026), kept: only the options below the preview scroll.
        // The sheet's swipe-to-dismiss pan sat over a non-scrolling segmented Picker and
        // swallowed taps; a ScrollView fixes that. The preview stays outside it because
        // it's a GeometryReader that needs the leftover height (a ScrollView proposes
        // unbounded height and collapsed it to a thumbnail).
        NavigationStack {
            VStack(spacing: f14) {
                preview
                ScrollView {
                    VStack(spacing: f14) {
                        groupLabel(String(localized: "Format", comment: "Share composer section heading"))
                        formatPicker
                        // A Year in Review share has one style: no one-chip row.
                        if availablePresets.count > 1 {
                            groupLabel(String(localized: "Style", comment: "Share composer section heading"))
                            presetRow
                        }
                        controls
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom) {
                    actionBar
                        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
                        .background(Color.shelfBackground)
                }
            }
            .padding(.top, Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle(context.yearReview != nil ? String(localized: "Share Your Year", comment: "Share composer navigation title for a Year in Review") : String(localized: "Share", comment: "Share composer navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }.monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
            .sheet(item: $payload) { ActivityView(items: [$0.url] + attachments) }
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .alert("Couldn’t Create Image", isPresented: $renderError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Something went wrong rendering the card. Please try again.") }
            .systemChromeTint()
            .alert("Photos Access Is Off", isPresented: $photosDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To save cards, allow ShelfHead to add photos in Settings.")
            }
            .systemChromeTint()
            .sheet(isPresented: $showCustomise) { customiseSheet }
        }
        // Sits above the pinned Save/Share bar.
        .toast(message: $toast, style: toastStyle, duration: 2.5, bottomInset: 84)
        .onAppear(perform: pickDefaults)
        .task {
            // Extract the (Sendable-safe) CGImage on main, extract the palette off-main.
            let cg = context.cover?.normalizedUp().cgImage
            let pal = await Task.detached(priority: .userInitiated) { CoverPalette.from(cg) }.value
            await MainActor.run { basePalette = pal }
        }
    }

    private var f14: CGFloat { 14 }

    private var preview: some View {
        GeometryReader { geo in
            let size = format.previewSize
            let scale = min(geo.size.width / size.width, geo.size.height / size.height)
            ShareCardView(context: context, configuration: configuration, size: size, renderMode: .preview)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 18pt radius → `Radius.hero`
                // (the other of the two literals the review names in this file).
                .clipShape(RoundedRectangle(cornerRadius: Radius.hero))
                // Critique 2026-10-06 (shape → bolder): was a raw black shadow in both
                // themes. Theme-aware elevation: a shadow in Dark, a hairline in Light.
                // (The card image keeps its own internal shadows: it's exported art.)
                .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.hero))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shelfAnimation(.easeInOut(duration: 0.25), value: shuffle)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Card preview")
                .accessibilityAddTraits(.isImage)
        }
        .padding(.horizontal, 20)
    }

    /// P-11 (REVIEW_2026-09-14_DESIGN.md): replaces the old Style row (theme tiles) +
    /// Card Type row (content chips) with one row of named presets — see
    /// `SharePreset`. Built on `ShareChipFlowLayout` rather than a horizontal
    /// `ScrollView` so a label never clips at large Dynamic Type: it wraps to a second
    /// line instead (item 6, same finding).
    private var presetRow: some View {
        ShareChipFlowLayout(spacing: 10, lineSpacing: 10) {
            ForEach(availablePresets) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: preset.systemImage).font(.title3)
                        Typo.fine(Text(preset.label), weight: .semibold)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minWidth: 76, minHeight: 62)
                    .foregroundStyle(selectedPreset == preset ? Color.onAccent : Color.shelfCream)
                    .background(selectedPreset == preset ? Color.shelfAmber : Color.shelfCream.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: Radius.panel))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPreset == preset ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 20)
    }

    /// Small tracked-caps label above each option group (Format/Style).
    private func groupLabel(_ title: String) -> some View {
        Typo.sectionTitle(Text(title.uppercased()))
            .tracking(LocalizedText.tracking(1.5))
            .foregroundStyle(Color.shelfMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
    }

    /// One-tap privacy presets, offered in the Privacy menu (and at the top of the
    /// "Choose What's Shown" sheet, beside the fine-grained toggles).
    private enum PrivacyPreset: String, CaseIterable, Identifiable {
        case standard, hideStats, coverOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return String(localized: "Standard", comment: "Privacy preset name in the share-card composer")
            case .hideStats: return String(localized: "Hide Stats", comment: "Privacy preset name in the share-card composer")
            case .coverOnly: return String(localized: "Cover Only", comment: "Privacy preset name in the share-card composer")
            }
        }
    }

    /// Which preset (if any) the current toggle combination matches — nil once someone
    /// has hand-picked a combination that doesn't line up with one of the three presets,
    /// so the menu reads "Custom" and shows no false checkmark.
    private var selectedPrivacyPreset: PrivacyPreset? {
        for preset in PrivacyPreset.allCases where privacyOptions(for: preset) == privacy {
            return preset
        }
        return nil
    }

    private var privacyPresetSelection: Binding<PrivacyPreset?> {
        Binding(
            get: { selectedPrivacyPreset },
            set: { preset in
                guard let preset else { return }
                Haptics.selection()
                privacy = privacyOptions(for: preset)
            }
        )
    }

    private func privacyOptions(for preset: PrivacyPreset) -> SharePrivacyOptions {
        var opts = SharePrivacyOptions()
        switch preset {
        case .standard:
            break   // all defaults (true)
        case .hideStats:
            opts.showProgress = false
            opts.showRemainingTime = false
            opts.showSpeed = false
            opts.showStreak = false
            opts.showCompletionDetails = false   // Y4 (REVIEW_2026-09-04_UI.md)
            opts.showListeningTotals = false     // Critique 2026-10-06: Year in Review figures
        case .coverOnly:
            opts.showProgress = false
            opts.showRemainingTime = false
            opts.showSpeed = false
            opts.showStreak = false
            opts.showAuthor = false
            opts.showNarrator = false
            opts.showCompletionDetails = false   // Y4 (REVIEW_2026-09-04_UI.md)
            opts.showListeningTotals = false     // Critique 2026-10-06: Year in Review figures
        }
        return opts
    }

    private var formatPicker: some View {
        Picker("Format", selection: $format) {
            // Code review fix (26 August 2026): `.pickerStyle(.segmented)` drops a
            // `Label`'s text and shows only its SF Symbol, so plain `Text`.
            ForEach(ShareCardFormat.allCases) { fm in
                Text(fm.label).tag(fm)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    /// Critique 2026-10-06 (shape → bolder): Remix and a labelled Privacy menu, side by
    /// side, stacking at large Dynamic Type sizes. "Shuffle artwork" and "Try another
    /// style" were near-synonyms; Remix is both (`SharePreset.remix`). Privacy used to
    /// hide behind an unlabelled sliders glyph in the header.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) { remixButton; privacyMenu }
            VStack(spacing: Space.m) { remixButton; privacyMenu }
        }
        .padding(.horizontal, Space.pageH).padding(.bottom, Space.m)
    }

    private var remixButton: some View {
        Button { remix() } label: {
            Label("Remix", systemImage: "shuffle")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 4)
                .background(Color.shelfCream.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.panel))
                .foregroundStyle(Color.shelfCream)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tries a new layout and artwork for this style, keeping what the card says.")
    }

    private var privacyMenu: some View {
        Menu {
            Picker("Privacy", selection: privacyPresetSelection) {
                ForEach(PrivacyPreset.allCases) { preset in
                    Text(preset.label).tag(Optional(preset))
                }
            }
            Divider()
            Button("Choose What\u{2019}s Shown\u{2026}") { showCustomise = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").accessibilityHidden(true)
                Text("Privacy:")
                Text(selectedPrivacyPreset?.label ?? String(localized: "Custom", comment: "Privacy menu value when the toggles match no preset")).fontWeight(.regular)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .background(Color.shelfCream.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.panel))
            .foregroundStyle(Color.shelfCream)
            .contentShape(Rectangle())
        }
        .systemChromeTint()   // CO-7: menus take the label colour, not amber
        .accessibilityLabel("Privacy")
        .accessibilityValue(selectedPrivacyPreset?.label ?? String(localized: "Custom", comment: "Privacy menu value when the toggles match no preset"))
    }

    // R2 (REVIEW_2026-09-04_UI.md): actions pinned; they were the last row of the scroll and never on screen at first open.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { saveImage() } label: {
                Image(systemName: "square.and.arrow.down").font(.headline)
                    .frame(width: 56, height: 52)
                    .background(Color.shelfCream.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.button))
                    .foregroundStyle(Color.shelfCream)
            }.buttonStyle(.plain).disabled(isRendering).accessibilityLabel("Save to Photos")
            Button { shareImage() } label: {
                HStack {
                    if isRendering { ProgressView().tint(Color.onAccent) }
                    else { Image(systemName: "square.and.arrow.up") }
                    Text(isRendering ? String(localized: "Rendering…", comment: "Share button title while the card image renders") : String(localized: "Share", comment: "Share button title"))
                }
                .font(.headline).foregroundStyle(Color.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Color.shelfAmber, in: RoundedRectangle(cornerRadius: Radius.button))
            }.buttonStyle(.plain).disabled(isRendering)
        }
    }

    /// The presets plus the granular toggles, reached from the Privacy menu's
    /// "Choose What's Shown…". Only toggles the selected content can use are listed.
    private var customiseSheet: some View {
        NavigationStack {
            Form {
                Section("Quick presets") {
                    ForEach(PrivacyPreset.allCases) { preset in
                        Button {
                            Haptics.selection()
                            privacy = privacyOptions(for: preset)
                        } label: {
                            HStack {
                                Text(preset.label).foregroundStyle(Color.shelfCream)
                                Spacer()
                                if selectedPrivacyPreset == preset {
                                    Image(systemName: "checkmark").foregroundStyle(Color.shelfAmberText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedPrivacyPreset == preset ? [.isButton, .isSelected] : .isButton)
                    }
                }
                Section("Show on the card") {
                    if content == .yearInReview {
                        Toggle("Listening time & books played", isOn: $privacy.showListeningTotals)
                    }
                    if showsProgressToggle { Toggle("Progress", isOn: $privacy.showProgress) }
                    if showsRemainingToggle { Toggle("Remaining time", isOn: $privacy.showRemainingTime) }
                    if showsSpeedToggle { Toggle("Playback speed", isOn: $privacy.showSpeed) }
                    if showsStreakToggle {
                        Toggle(content == .yearInReview ? String(localized: "Best streak", comment: "Privacy toggle for the Year in Review card") : String(localized: "Listening streak", comment: "Privacy toggle"), isOn: $privacy.showStreak)
                    }
                    // Y4 (REVIEW_2026-09-04_UI.md): the completion card's time/day-count/
                    // book-number stats previously had no toggle of their own.
                    if content == .completion { Toggle("Time & book count", isOn: $privacy.showCompletionDetails) }
                    Toggle(content == .yearInReview ? String(localized: "Top author", comment: "Privacy toggle for the Year in Review card") : String(localized: "Author", comment: "Privacy toggle"), isOn: $privacy.showAuthor)
                    if content != .yearInReview { Toggle("Narrator", isOn: $privacy.showNarrator) }
                    Toggle("ShelfHead branding", isOn: $privacy.showBranding)
                }
            }
            .navigationTitle("Choose What\u{2019}s Shown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { showCustomise = false }.monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private func pickDefaults() {
        guard !hasPickedDefaults else { return }
        hasPickedDefaults = true
        // Y2 (REVIEW_2026-09-04_UI.md), preserved under the P-11 preset model: a share
        // triggered from a bookmark's note still opens straight to the Quote card, and a
        // finished book with no quote still opens on the completion card. A Year in
        // Review share opens on its own card.
        let defaultPreset: SharePreset
        if context.yearReview != nil {
            defaultPreset = .yearInReview
        } else if context.quote?.isEmpty == false {
            defaultPreset = .spotlight
        } else if (context.isFinished || context.completion != nil), availablePresets.contains(.finished) {
            defaultPreset = .finished
        } else {
            defaultPreset = .spotlight
        }
        applyPreset(defaultPreset, haptic: false)
    }

    /// One tap: a fresh variation, and within Spotlight the next of its cover-led
    /// layouts. Content and format are left as they are.
    private func remix() {
        Haptics.selection()
        let next = SharePreset.remix(theme: theme, shuffle: shuffle)
        if availableThemes.contains(next.theme) { theme = next.theme }
        shuffle = next.shuffle
    }

    private func showToast(_ text: String, style: ToastStyle) {
        toastStyle = style
        toast = text
    }

    private func shareImage() {
        guard !isRendering else { return }
        isRendering = true
        let cfg = configuration, ctx = context
        Task {
            // Y8 (REVIEW_2026-09-04_UI.md): `isRendering` was set and the very next line
            // blocked the main actor doing the actual render — SwiftUI never got a frame
            // to paint the "Rendering…" spinner state first. `ImageRenderer` has no async
            // variant, so the render call itself is still synchronous by API design; this
            // just guarantees the spinner is visible before that happens.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(40))
            // Render the CGImage on main (view creation must be), then PNG-encode + write
            // the file off-main so the expensive compression doesn't stall the UI.
            let cg = await MainActor.run { ShareCardRenderer.renderCGImage(context: ctx, configuration: cfg) }
            let fileURL: URL? = await Task.detached(priority: .userInitiated) {
                guard let cg, let data = ShareCardRenderer.pngData(from: cg) else { return nil }
                return ShareCardRenderer.writeData(data)
            }.value
            await MainActor.run {
                isRendering = false
                if let fileURL { payload = SharePayload(url: fileURL) } else { renderError = true }
            }
        }
    }

    private func saveImage() {
        guard !isRendering else { return }
        isRendering = true
        let cfg = configuration, ctx = context
        Task {
            // Y8 (REVIEW_2026-09-04_UI.md): give the "Rendering…" spinner a frame to paint
            // before the synchronous render blocks the main actor — see the fuller comment
            // in `shareImage()`.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(40))
            guard let image = await MainActor.run(body: { ShareCardRenderer.render(context: ctx, configuration: cfg) }) else {
                await MainActor.run { isRendering = false; renderError = true }
                return
            }
            // Ask only for add-only access, then save and report the ACTUAL result.
            let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { cont.resume(returning: $0) }
            }
            guard status == .authorized || status == .limited else {
                // Critique 2026-10-06 (shape → bolder): denied/restricted gets an alert with
                // "Open Settings" (the only place to change it), not a 1.8 s toast.
                await MainActor.run { isRendering = false; photosDenied = true }
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                await MainActor.run { isRendering = false; Haptics.success(); showToast(String(localized: "Saved to Photos", comment: "Toast after saving a share card to Photos"), style: .success) }
            } catch {
                await MainActor.run { isRendering = false; showToast(String(localized: "Couldn’t save to Photos", comment: "Toast when saving a share card to Photos fails"), style: .error) }
            }
        }
    }
}

/// UIActivityViewController bridge for sharing the rendered image.
///
/// Batch 464: SharePlay is excluded by default. Since Batch 456 the app supports Group
/// Activities, so iOS offers SharePlay in every share sheet, and a SwiftUI `ShareLink` can't
/// remove it (device test PP1: it appeared when sharing the passport). Only Listen Together
/// should offer SharePlay; it keeps its own `ShareLink`. `UIActivity.ActivityType.sharePlay`
/// is iOS 15.4+ (UIKit `UIActivity.h`, `UIActivityTypeSharePlay API_AVAILABLE(ios(15.4))`; the
/// documentation page couldn't be fetched).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType] = [.sharePlay]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
