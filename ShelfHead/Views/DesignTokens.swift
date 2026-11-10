import SwiftUI

/// UI-4 (REVIEW_2026-08-12.md): a shared typography/spacing/radius vocabulary, so a
/// semantic role — "book title in a row", "section header", "page margin" — has exactly
/// one spelling instead of being hand-picked per file. Before this existed, "book title
/// in a row" alone was independently spelled five different ways across four files
/// (13pt semibold rounded, 14pt semibold rounded, `.subheadline.weight(.medium)`,
/// `.subheadline`), and the page margin was 16pt on some tabs and 20pt on others for no
/// reason a user could tell apart from a bug — Home and Library are adjacent tabs with a
/// visible 4pt mismatch.
///
/// This is deliberately a small, real vocabulary populated with the roles this batch's
/// migration (`PlayerView`, `HomeView` — the review's own "migrate highest-traffic files
/// first" staging) actually uses, not a speculative full redesign system invented ahead
/// of any call site. Add a role here when a second file needs it, not before.
enum Typo {
    /// "Book title in a row" — a title next to a cover in a compact horizontal layout
    /// (a shelf's single-item card, the Up Next queue row, etc.). This exact
    /// size/weight/design is the review's own proposed unification target for the five
    /// spellings it found; adopting it doesn't just share code, it makes those five
    /// previously-different-sized titles render at one true size.
    static func rowTitle(_ view: some View) -> some View {
        view.scaledFont(14, weight: .semibold, design: .rounded, relativeTo: .subheadline)
    }

    /// The secondary line under a `rowTitle` — author name, narrator, timestamp.
    static func rowSubtitle(_ view: some View) -> some View {
        view.scaledFont(12, relativeTo: .caption)
    }

    /// A compact pill/chip label — `PlayerView`'s sleep-timer chip and Up Next chip
    /// alone had six near-identical `.font(.system(size: 12, weight: ..., design:
    /// .rounded))` calls before this existed, each independently deciding whether "12pt
    /// rounded" meant `.medium`/`.semibold`/no explicit weight.
    static func chip(_ view: some View, weight: Font.Weight = .regular) -> some View {
        view.scaledFont(12, weight: weight, design: .rounded, relativeTo: .caption)
    }

    // MARK: - Roles added for the 17 Aug 2026 design-direction pass
    //
    // Same principle as above: each of these unifies a spec that was already being
    // independently reinvented in at least two places, not a speculative new size
    // invented ahead of any call site.

    /// A screen's own top-level title — e.g. `HomeView`'s greeting ("Good evening").
    /// Unifies what was a bare `.scaledFont(28, weight: .bold, design: .rounded,
    /// relativeTo: .largeTitle)` at that one call site; named here so a second
    /// page-level title (as opposed to a `navigationTitle`, which stays native per the
    /// design direction's "keep native behavior" point) has the same spelling.
    static func pageTitle(_ view: some View) -> some View {
        view.scaledFont(28, weight: .bold, design: .rounded, relativeTo: .largeTitle)
    }

    /// A small tracked-caps group label — "BROWSE", "THIS CHAPTER", "WHOLE BOOK".
    /// Unifies two independently-spelled versions of the exact same role:
    /// `RetroSectionHeader`'s title text (12pt bold rounded caption, tracking 1.5,
    /// cream @ 0.8 opacity) and `PlayerView.progressCaption` (was 11pt bold rounded
    /// caption2, tracking 1.5, muted @ 0.7 opacity) — a small but real drift between
    /// two labels doing the same job. Standardized on `RetroSectionHeader`'s numbers
    /// since it's the more-established, more-widely-used of the two (Home, Settings,
    /// Diagnostics). Callers still apply their own `.tracking(1.5)` and foreground
    /// color, since `RetroSectionHeader` intentionally uses full cream and
    /// `progressCaption` intentionally uses muted — the *size/weight* is the part that
    /// should never have drifted, not necessarily the color.
    static func sectionTitle(_ view: some View) -> some View {
        view.scaledFont(12, weight: .bold, design: .rounded, relativeTo: .caption)
    }

    /// A panel's own title inside a card — "Recent Sessions", "Listening Heatmap",
    /// "Minutes by Month", "Where you left off". Sentence case, SF Pro Rounded semibold,
    /// `.headline`, no leading glyph. Callers apply `shelfCream`. Design review V3-round
    /// V4 / TY-1, TY-2 (user decision, 26 September 2026): `RetroSectionHeader` (tracked
    /// caps and a rule) is for headers *outside* cards only.
    static func cardTitle(_ view: some View) -> some View {
        view.scaledFont(17, weight: .semibold, design: .rounded, relativeTo: .headline)
    }

    /// A hero element's own title — e.g. Home's Continue Listening card. Unifies what
    /// was a bare `.scaledFont(17, weight: .bold, design: .rounded, relativeTo:
    /// .title3)` at that call site; distinct from `rowTitle` (14pt) because a hero
    /// card is meant to visually dominate its screen (design-direction point 1), not
    /// read as one row among several.
    static func heroTitle(_ view: some View) -> some View {
        view.scaledFont(17, weight: .bold, design: .rounded, relativeTo: .title3)
    }

    /// Secondary descriptive text under a title — author/narrator name, a short
    /// explanatory line ("Pick up where you left off"). Already the most consistent
    /// role in the app before this token existed (several call sites already
    /// independently converged on `.scaledFont(13, relativeTo: .subheadline)`),
    /// which is exactly why it belongs here — naming the already-correct convention
    /// so it stays that way as more files adopt it.
    static func metadata(_ view: some View) -> some View {
        view.scaledFont(13, relativeTo: .subheadline)
    }

    /// A secondary, non-primary action's label — "Jump back to...", a sign-in link,
    /// "Retry download." Unifies a `.font(.caption.weight(.semibold))` spelling
    /// already independently repeated across `PlayerView`, `LoginView` (three call
    /// sites), and `DownloadsView` before this existed. Deliberately not routed
    /// through `scaledFont` — every one of those existing call sites used the plain
    /// `Font.caption` text style directly, and this role names that existing,
    /// already-consistent convention rather than silently changing its scaling
    /// behavior out from under five call sites at once.
    static func secondaryAction(_ view: some View) -> some View {
        view.font(.caption.weight(.semibold))
    }

    // MARK: - Small-copy roles (Batch 362, the `.caption`/`.caption2` sweep)
    //
    // The ~165 bare `.font(.caption…)` sites left after TY-1 did four jobs that had no
    // name. These name them. Each one keeps the system text style the sites already
    // used (no `scaledFont`), so the sweep changes no rendered size or Dynamic Type
    // behaviour; it only makes the role searchable and changeable in one place.

    /// Supporting copy at caption size: an explanation under a control or field, an
    /// empty-state hint, a status line, a small labelled fact ("12 chapters", "Total
    /// Listened"). The default home for a `.caption` that isn't a row subtitle.
    static func supporting(_ view: some View, weight: Font.Weight = .regular) -> some View {
        view.font(.caption.weight(weight))
    }

    /// Fine print at `.caption2`: timestamps, provenance ("Written on device"), unit
    /// labels beside a figure, the smallest footnote under a section.
    static func fine(_ view: some View, weight: Font.Weight = .regular) -> some View {
        view.font(.caption2.weight(weight))
    }

    /// A small number that updates or lines up in a column — a time, a duration, a byte
    /// count. Monospaced digits so the figure doesn't jitter as it changes.
    static func figure(_ view: some View, fine: Bool = false, weight: Font.Weight = .regular) -> some View {
        view.font((fine ? Font.caption2 : Font.caption).weight(weight).monospacedDigit())
    }

    /// Machine text shown for inspection — a resolved URL, a header name, an id.
    /// Fully monospaced, unlike `figure`.
    static func code(_ view: some View) -> some View {
        view.font(.caption2.monospaced())
    }
}

/// Spacing scale. `pageH` exists specifically because of the review's page-margin
/// finding: `HomeView`/`DownloadsView` use 20pt, `LibraryView`/`BookDetailView` use
/// 16pt. `HomeView`'s existing margins already happen to be on the 20pt side of that
/// split, so migrating it to `Space.pageH` here names that value as the standard for
/// whichever file adopts the token next, rather than silently picking a new number.
enum Space {
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let pageH: CGFloat = 20
}

/// Corner-radius scale, named by role rather than by number — a small chip, a card, and
/// a "hero" element (the cassette deck's face, a hero card) are visually distinct roles
/// that happened to reuse 8 different literal radii across the app before this existed.
enum Radius {
    /// Small list thumbnails (a cover ≤ 48 pt). Design review V3 / IC-1 (30 September 2026).
    static let thumb: CGFloat = 6
    static let chip: CGFloat = 8
    static let card: CGFloat = 12
    /// A padded content/stat panel (StatsView's/YearInReviewView's summary cards) —
    /// iOS 26/27 Liquid Glass polish pass (26 August 2026): these files had
    /// independently reinvented this exact role with a mix of raw `14`/`16` literals
    /// across 9 call sites before this token existed. Sits between `.card` (12, a
    /// tighter row/thumbnail radius) and `.hero` (18, a full hero element).
    static let panel: CGFloat = 14
    static let hero: CGFloat = 18
    /// A large, full-width action button (the share composer's Save and Share buttons).
    /// VD-3 (docs/design-review.md, Round 6): those buttons were spelling a raw `16`
    /// that had no token; kept separate from `.hero` (18) because they're a different
    /// role, not a hero element.
    static let button: CGFloat = 16
    static let pill: CGFloat = 22

    /// The corner radius for a cover drawn `side` points across: ≤ 48 → `thumb`,
    /// ≤ 80 → `chip`, larger → `card`. One scale so a cover's edge doesn't change from
    /// screen to screen (V3 / IC-1). Grid tiles use `chip` directly; the player uses `panel`.
    static func cover(side: CGFloat) -> CGFloat {
        side <= 48 ? thumb : (side <= 80 ? chip : card)
    }
}
