import SwiftUI
import Foundation
import WatchKit

/// Central styling for the Watch app — black background, rounded dark cards, matching
/// the ShelfHead iOS brand and the provided mockups. Keeping this in one file means
/// every screen picks up the same look without duplicating color literals.
///
/// U7 (REVIEW_2026-08-20_UI_SECURITY.md): `background`/`cardBackground`/`cardBorder`/
/// `primaryText`/`secondaryText` below are deliberately hardcoded to dark values with no
/// Light-theme counterpart — this is an intentional platform decision, not an oversight.
/// watchOS's own system surfaces (complications, notifications, the always-on display)
/// are effectively always-dark, and there is no Watch-side equivalent of the phone's
/// Settings > Appearance picker for a user to even ask for a Light watch face. `accent`
/// is the one property that genuinely needs to track a user choice (the phone's Accent
/// picker), which is why it alone is dynamic below.
enum WatchTheme {
    // ID-1 (docs/visual-design-review.md, V5, accepted 26 September 2026): warm the
    // neutrals to the phone's palette while keeping true black behind content (OLED, the
    // watchOS norm). Card is the phone's dark `shelfCard` family (`241B12`), primary text
    // is `shelfCream` (`F4E9D6`), secondary is `shelfMuted` (`A89177`, about 5.6:1 on the
    // card and 6.2:1 on black).
    static let background = Color.black
    static let cardBackground = Color(red: 0x24 / 255, green: 0x1B / 255, blue: 0x12 / 255)
    static let cardBorder = Color(red: 0x3A / 255, green: 0x2E / 255, blue: 0x21 / 255)
    static let primaryText = Color(red: 0xF4 / 255, green: 0xE9 / 255, blue: 0xD6 / 255)
    static let secondaryText = Color(red: 0xA8 / 255, green: 0x91 / 255, blue: 0x77 / 255)
    /// Espresso-to-black wash behind Now Playing, carried by
    /// `containerBackground(_:for: .navigation)` the way Apple's own watchOS apps carry
    /// colour, so the bar and content sit on it instead of a flat black.
    static let nowPlayingBackground = LinearGradient(
        colors: [Color(red: 0x2E / 255, green: 0x21 / 255, blue: 0x14 / 255), .black],
        startPoint: .top, endPoint: .bottom)
    // Critique 2026-10-06 (colorize, third pass): `success` (an off-palette green) is
    // gone. Finished/complete uses `finished` (teal); connected and signed-in are neutral
    // (`icon`), because a state that's fine doesn't need a colour.

    /// Visual polish pass (31 August 2026), direct user request ("make the app look
    /// nicer"): before this, `WatchRow`'s default icon tint was `WatchTheme.accent`
    /// — meaning literally every navigational row icon on every screen (Library,
    /// Settings, Account, Mode Settings, Collections) rendered in the user's chosen
    /// accent color, alongside progress bars, checkmarks, and chapter highlights
    /// also being accent. When everything is accent, nothing reads as emphasized —
    /// the audit that flagged this described it as the color "stopping signaling
    /// anything." `icon` is a plain neutral, brighter than `secondaryText` (which
    /// stays reserved for captions/subtitles) so glyphs remain clearly legible, but
    /// no longer compete with genuine accent usage (an active/current item, an
    /// in-progress download, a primary call-to-action). `WatchRow` now defaults to
    /// this; call sites that explicitly want accent (or `danger`/`warning`) still
    /// pass `tintColor:` explicitly, same as before.
    static let icon = Color(red: 0xD3 / 255, green: 0xC4 / 255, blue: 0xAC / 255)   // ID-1: warm, brighter than `secondaryText`

    /// UI polish pass (28 August 2026): before this, every error/failure state
    /// across the app (downloads, auth, manual sign-in, standalone playback, the
    /// session-expired account state) reached for the system's raw `.red`
    /// independently, and the one warning-tier indicator (the stale-playback-state
    /// dot in `WatchSettingsView`) reached for raw `Color.orange` — `WatchTheme`
    /// had a `success` token but no matching `danger`/`warning`, which is exactly
    /// the asymmetry that let every call site improvise its own red. Constructed
    /// the same way `success` already is (an explicit RGB triple, not a system
    /// color reference), so all three status tones share one consistent
    /// construction style rather than mixing hand-picked RGB with system-color
    /// shorthand.
    ///
    /// Critique 2026-10-06 (colorize, third pass): both were off-palette — `warning` read
    /// as VU Amber (the default *accent*, so a warning looked like a highlight) and
    /// `danger` was a raw red DESIGN.md doesn't have. Both now resolve to `alert`
    /// (Burnt Orange, hue-rotated with the accent). Use them on **glyphs**; a sentence
    /// stays cream or taupe beside an alert glyph (`WatchAlertNotice`).
    @MainActor static var danger: Color { alert }
    @MainActor static var warning: Color { alert }

    /// U7: this used to be a hardcoded orange regardless of the accent the user picked
    /// in the phone's Settings > Accent picker. Now reads the hex mirrored onto
    /// `WatchPlaybackState.accentHex` (`WatchSessionManager.buildPlaybackState()` on the
    /// phone, via `WatchConnectivityStore.shared.playbackState` here), falling back to
    /// the original hardcoded orange if nothing has synced yet (fresh install, or the
    /// phone hasn't pushed a snapshot this launch).
    ///
    /// `@MainActor`: `WatchConnectivityStore` is itself `@MainActor` (its state is only
    /// ever touched after hopping to the main actor from WatchConnectivity callbacks —
    /// see its own doc comment), so reading `.shared.playbackState` requires the same
    /// isolation here. Mirrors `AppTheme.accentColor`'s identical shape on the phone
    /// side (`Extensions.swift`): every call site is already inside a SwiftUI
    /// `View.body` or another already-`@MainActor` context (this type's own
    /// `WatchRow`/`WatchControlButton` default parameter values included, since default
    /// argument expressions are evaluated at the call site), so this needs no call-site
    /// changes.
    @MainActor static var accent: Color {
        guard let hex = WatchConnectivityStore.shared.playbackState?.accentHex else {
            return fallbackAccent
        }
        return color(hex: hex)
    }

    // Critique 2026-10-06 (colorize): was #FF9429, an orange that isn't in DESIGN.md.
    // VU Amber (#E8A838) is the phone's default accent, so a Watch that hasn't heard from
    // the phone yet now shows the same colour it will once it has.
    private static let fallbackAccent = color(rgb: WatchPaletteMath.rgb(hex: WatchPaletteMath.defaultAccentHex))

    /// Critique 2026-10-06 (colorize, third pass): the accent as *text* — a caption, a
    /// current chapter, a live status — on the Watch's dark grounds. The raw accent is for
    /// fills; two of the phone's nine accents (Indigo, Purple) fall just under 4.5:1 as
    /// text on the Now Playing wash. This lifts the accent toward white just enough to
    /// clear 4.5:1 on the lightest dark ground (`WatchPaletteMath.lightestGroundHex`), so
    /// it clears it on the card and on black too. The phone's `shelfAmberText`, re-derived.
    @MainActor static var accentText: Color {
        color(rgb: WatchPaletteMath.readableText(
            accentHex: WatchConnectivityStore.shared.playbackState?.accentHex ?? WatchPaletteMath.defaultAccentHex,
            onHex: WatchPaletteMath.lightestGroundHex))
    }

    /// Critique 2026-10-06 (colorize): DESIGN.md's Teal-Means-Done. `success` (green) had
    /// come to mean finished, downloaded, signed in and connected all at once; finished
    /// gets its own colour, hue-rotated with the accent the way the phone's `shelfAccent`
    /// is, so the interval to the accent holds at any accent. Use it for finished or
    /// complete only. Text and glyphs use it directly: on the Watch's black and card
    /// grounds it clears 4.5:1 (#2FB6A8 measures about 8.4:1 on black).
    @MainActor static var finished: Color {
        color(rgb: WatchPaletteMath.harmonized(anchorHex: WatchPaletteMath.finishedAnchorHex,
                                               accentHex: WatchConnectivityStore.shared.playbackState?.accentHex))
    }

    /// Critique 2026-10-06 (colorize): DESIGN.md's Burnt Orange, for alarm and warning
    /// fills (the stale-state banner). Hue-rotated with the accent like `finished`.
    @MainActor static var alert: Color { color(rgb: alertRGB) }

    /// Contrast-picked ink for text drawn on `alert` — near-black or white, whichever
    /// scores higher, the phone's `shelfOrangeInk` rule. Was a hard-coded black on the
    /// accent.
    @MainActor static var alertInk: Color {
        WatchPaletteMath.prefersDarkInk(on: alertRGB) ? Color(white: WatchPaletteMath.darkInkWhite) : .white
    }

    @MainActor private static var alertRGB: WatchPaletteMath.RGB {
        WatchPaletteMath.harmonized(anchorHex: WatchPaletteMath.alertAnchorHex,
                                    accentHex: WatchConnectivityStore.shared.playbackState?.accentHex)
    }

    private static func color(rgb: WatchPaletteMath.RGB?) -> Color {
        guard let rgb else { return Color(red: 0xE8 / 255, green: 0xA8 / 255, blue: 0x38 / 255) }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    /// Minimal hex→Color parsing, mirroring the widget target's own `WidgetTheme.color(hex:)`
    /// — this target doesn't compile against the app's `Extensions.swift`, so it can't
    /// reuse `Color.init(hex:)` from there either.
    private static func color(hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        guard clean.count == 6 else { return fallbackAccent }
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// UI polish pass (28 August 2026) — a small, named scale replacing what had been
/// ad hoc literals scattered across every screen. An inventory pass across all 30
/// files in this target found the same visual role rendered at different values
/// depending on which screen happened to need it, with no discernible rule for
/// which screen got which number: title/subtitle stacking used `spacing: 1` in
/// roughly half of all rows and `spacing: 2` in the other half; row subtitle text
/// was set at 10, 11, *and* 12pt depending on file; the shared rewind/play/forward
/// control row used `spacing: 18` in one screen and `spacing: 20` in two others
/// for what is visually the identical control group; and only `WatchRow`'s own
/// icon got a fixed-width column (26pt) while every hand-built row's icon had no
/// frame constraint at all. None of this was a deliberate per-screen choice
/// recorded anywhere — it was drift, one screen at a time, with nothing central
/// to keep them aligned. These constants are that central place now.
enum WatchMetrics {
    /// Standard spacing between a row's title and its subtitle line.
    static let titleSubtitleSpacing: CGFloat = 2
    /// Horizontal padding around a control screen's scrollable content
    /// (`WatchNowPlayingScreen`, shared by both modes since Critique 2026-10-06; it was
    /// once applied on some of four separate screens and not others).
    static let scrollContentHorizontalPadding: CGFloat = 4
    /// UI polish pass round 2 (29 August 2026): content-list rows (books,
    /// downloads, sessions) used `.padding(.vertical, 2)` — cramped by watchOS
    /// standards for a touch/wrist target, and part of why the app read as
    /// "unfinished" per direct user feedback even after the first polish pass's
    /// spacing/color consistency work. `WatchRow` itself already used 6; this
    /// brings every hand-built content row up to the same breathing room.
    static let rowVerticalPadding: CGFloat = 6
    /// Standard duration for the small state-change animations added in the same
    /// pass (play/pause glyph swap, progress fills) — deliberately short so it
    /// reads as responsive, not sluggish, on a screen this size.
    static let stateChangeAnimationDuration: Double = 0.2
}

// MARK: - Typography (P-13)

/// P-13 (REVIEW_2026-09-14_DESIGN.md, "watchOS uses fixed point sizes throughout").
///
/// Until this pass the Watch app's type scale was five `CGFloat` literals on
/// `WatchMetrics` (`contentRowTitleFontSize: 14`, `navigationRowTitleFontSize: 15`,
/// `subtitleFontSize: 11`, `captionFontSize: 10`) plus a scatter of raw
/// 9/12/13/16/18/20/26/30 values written inline at call sites, all of them fed to
/// `.font(.system(size:))`. A fixed point size opts a view out of Dynamic Type
/// completely: the Watch's own Settings > Display & Brightness > Text Size slider
/// (and the Accessibility "Larger Text" range above it) moved nothing in this app,
/// and a 41mm Series and a 49mm Ultra rendered the same 14pt row title on very
/// different amounts of glass.
///
/// These are watchOS *text styles* instead — `.caption2` / `.caption` / `.footnote`
/// / `.body` / `.headline` / `.title3` / `.title2` / `.largeTitle` — which scale
/// with that setting. They're factories rather than plain `Font` constants because
/// `Font` has no `design(_:)` modifier: a call site that used to write
/// `.system(size: 14, weight: .medium, design: .rounded)` inline still needs to ask
/// for weight and the rounded face, and `Font.system(_:design:weight:)` (watchOS 9+,
/// this target deploys to 10.0) is the only constructor that takes all three. A
/// `nil` weight means "the text style's own weight," so `.headline` stays semibold
/// unless a call site overrides it, exactly as `.system(size:)` behaved.
///
/// The styles were chosen to preserve the old ladder's *order* — caption < subtitle
/// < secondary < content row title < navigation row title < hero title — so the
/// existing visual hierarchy survives even though the absolute sizes now move. The
/// old 12 and 13 both land on `.footnote` (`secondaryFont`) and the old 9 and 10
/// both on `.caption2` (`captionFont`): those pairs were drift, not two deliberate
/// tiers, which is the same judgement the 28 August 2026 pass above already made
/// about the 10/11/12 subtitle spread.
///
/// Deliberately *not* routed through here: `WatchControlButton.size` and the glyph
/// it derives (`size * 0.5`). Those are tap targets with a documented ≥44pt floor
/// (see that type's UI-12/P3-14 comments), not text; scaling them with the text-size
/// slider would push the three-button transport row off a 41mm screen, which is a
/// worse outcome than a fixed-size glyph.
extension WatchMetrics {
    /// One constructor for all of the roles below. The `Font.Design?` is bound to a
    /// local rather than written inline as a ternary purely so the optional type is
    /// stated once, explicitly, instead of being inferred nine times.
    private static func font(_ style: Font.TextStyle, _ weight: Font.Weight?, rounded: Bool) -> Font {
        let design: Font.Design? = rounded ? .rounded : nil
        return .system(style, design: design, weight: weight)
    }

    /// Caption/status text — badge labels, the circular-progress "Complete" caption,
    /// the "Swipe for more" hint. Was 9–10pt.
    static func captionFont(weight: Font.Weight? = nil, rounded: Bool = false) -> Font {
        font(.caption2, weight, rounded: rounded)
    }

    /// Subtitle/secondary-line text for list rows (a book's author under its title).
    /// Was 11pt.
    static func subtitleFont(weight: Font.Weight? = nil, rounded: Bool = false) -> Font {
        font(.caption, weight, rounded: rounded)
    }

    /// Standalone explanatory copy — empty-state messages, inline errors, "N left"
    /// readouts, small button labels. Was 12–13pt.
    static func secondaryFont(weight: Font.Weight? = nil, rounded: Bool = false) -> Font {
        font(.footnote, weight, rounded: rounded)
    }

    /// Row title for content-list rows (books, sessions, downloads — rows the user
    /// scans several of per screen). Was 14pt.
    static func contentRowTitleFont(weight: Font.Weight? = nil, rounded: Bool = false) -> Font {
        font(.body, weight, rounded: rounded)
    }

    /// Row title for navigation/menu rows — `WatchRow`'s own tier. Was 15pt.
    static func navigationRowTitleFont(weight: Font.Weight? = nil, rounded: Bool = true) -> Font {
        font(.headline, weight, rounded: rounded)
    }

    /// A row's leading icon glyph, sized to sit with `navigationRowTitleFont`, plus
    /// the two toolbar glyphs that match it. Was 18pt.
    static func rowIconFont(weight: Font.Weight? = .semibold) -> Font {
        font(.title3, weight, rounded: false)
    }

    /// The single big glyph an empty/error state is built around. Was 30pt.
    static func heroGlyphFont(weight: Font.Weight? = nil) -> Font {
        font(.largeTitle, weight, rounded: false)
    }
}

/// P-13: the icon column was a flat `WatchMetrics.iconColumnWidth: CGFloat = 26`
/// applied to every row's leading glyph. With the row's *title* now scaling and the
/// column not, the icon and text fall out of alignment the moment the user moves the
/// text-size slider — the same failure P-8 describes on the phone's settings rows.
///
/// `@ScaledMetric(relativeTo: .headline)` ties the column to the same text style
/// `navigationRowTitleFont` uses, so they grow together. The `min(_:_:)` cap mirrors
/// the phone's `PlayerView.toolbarIconSlot` pattern: watchOS's own size range tops
/// out well below iOS's AX sizes, but a 2-column tile grid on a 41mm screen has very
/// little slack, so the column stops growing before it can push a row's title into
/// truncation.
private struct WatchIconColumnModifier: ViewModifier {
    @ScaledMetric(relativeTo: .headline) private var width: CGFloat = 26

    func body(content: Content) -> some View {
        content.frame(width: min(width, 34))
    }
}

extension View {
    /// Shared leading-icon column for every row in the app — `WatchRow`'s own and
    /// every hand-built row that matches it. Replaces `.frame(width:
    /// WatchMetrics.iconColumnWidth)`.
    func watchIconColumn() -> some View {
        modifier(WatchIconColumnModifier())
    }
}

// MARK: - Always-On (Batch 490, REVIEW 2026-11-11 W14)

extension WatchTheme {
    /// The Always-On Rule (DESIGN.md): a screen's one amber action drops to Worn Taupe
    /// with the wrist down. Nothing amber stays lit.
    static func prominentTint(isLuminanceReduced: Bool) -> Color {
        isLuminanceReduced ? secondaryText : accent
    }

    /// The Always-On Rule's cover opacity: 60% with the wrist down.
    nonisolated static func coverOpacity(isLuminanceReduced: Bool) -> Double {
        isLuminanceReduced ? 0.6 : 1
    }
}

private struct WatchProminentTintModifier: ViewModifier {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content.tint(WatchTheme.prominentTint(isLuminanceReduced: isLuminanceReduced))
    }
}

private struct WatchAlwaysOnDimModifier: ViewModifier {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content.opacity(WatchTheme.coverOpacity(isLuminanceReduced: isLuminanceReduced))
    }
}

extension View {
    /// Batch 490 (REVIEW 2026-11-11 W14): `.tint(WatchTheme.accent)` for a screen's one
    /// prominent action, dropping to Worn Taupe when luminance is reduced.
    func watchProminentTint() -> some View {
        modifier(WatchProminentTintModifier())
    }

    /// Batch 490 (REVIEW 2026-11-11 W14): dims a cover to 60% when luminance is reduced.
    /// Not for the Shelf's sleeves or Now Playing's cover, which already do this.
    func watchAlwaysOnDimmed() -> some View {
        modifier(WatchAlwaysOnDimModifier())
    }
}

/// UI polish pass round 2 (29 August 2026): centralizes the Watch app's haptic
/// feedback. Before this, `WatchConnectivityStore.playHaptic(success:)` was the
/// ONLY haptic call site anywhere in the target (see that file's own WATCH-4 doc
/// comment) — and it only fires for phone-relayed command acknowledgments, never
/// for anything the user does directly on the Watch itself (play/pause, skip,
/// bookmark, download finishing, signing in). A watch app with zero tactile
/// confirmation on its own primary actions is one of the most immediately
/// noticeable "this feels unfinished" signals — per direct user feedback after
/// the first UI polish pass (which only addressed spacing/color/list-style
/// consistency, not this). Named by intent (`tap`/`success`/`failure`) rather
/// than exposing `WKHapticType` directly at every call site, matching this file's
/// existing pattern of naming things by role (`WatchTheme.danger`, not
/// `Color(red:...)` inline).
enum WatchHaptics {
    /// A light acknowledgment for a direct, momentary action — play/pause, skip,
    /// adding a bookmark, switching a mode preference.
    static func tap() { WKInterfaceDevice.current().play(.click) }
    /// A completed, positive outcome — a download finishing, a sign-in succeeding.
    static func success() { WKInterfaceDevice.current().play(.success) }
    /// A failed outcome the user should notice without having to be looking at the
    /// screen — a download failing, a sign-in being rejected.
    static func failure() { WKInterfaceDevice.current().play(.failure) }
}

/// Rounded dark card container used throughout (rows, now-playing card, etc.).
struct WatchCard<Content: View>: View {
    var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        content()
            .padding(10)
            .background(WatchTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(WatchTheme.cardBorder, lineWidth: 0.5)
            )
    }
}

/// A compact list row: icon + title + optional subtitle + trailing accessory,
/// sized for a watchOS-friendly hit target (avoids "tiny tap targets").
///
/// UI polish pass (28 August 2026): generic over its trailing accessory
/// (`Trailing`, defaulting to `EmptyView` via the extension below) so screens that
/// need a checkmark, status glyph, or small progress indicator at the end of a row
/// can use this component directly instead of hand-rolling their own icon+title
/// HStack with slightly different spacing/sizing each time — the inventory for
/// this pass found roughly two-thirds of the app's rows doing exactly that.
/// Every existing call site (`WatchRow(systemImage:title:subtitle:tintColor:)`)
/// keeps compiling unchanged via that extension's initializer.
struct WatchRow<Trailing: View>: View {
    let systemImage: String
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource? = nil
    // U7 (REVIEW_2026-08-20_UI_SECURITY.md): `WatchTheme.accent` is `@MainActor` now
    // that it reads live connectivity state (see its doc comment) — CRIT-3's own
    // documented lesson (`SettingsComponents.swift`'s `menuRow`) is that a stored
    // property's default VALUE expression is checked against the declaring type's own
    // (nonisolated) lexical context, not the call site, so `= WatchTheme.accent` here
    // would fail to compile even though every real call site is already on the main
    // actor. Defaulting to `nil` and resolving the real default inside `body` (which
    // genuinely is main-actor-isolated) sidesteps that, exactly like `menuRow` did.
    var tintColor: Color? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(systemImage: String, title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil,
         tintColor: Color? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.tintColor = tintColor
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(WatchMetrics.rowIconFont())
                // UI polish pass round 2: hierarchical rendering gives every row
                // icon a subtle depth cue (varying layer opacity within the same
                // tint) instead of the flat, single-tone glyph every icon in the
                // app rendered as before — near-zero cost, but one of the more
                // immediately "this looks native" signals on watchOS.
                .symbolRenderingMode(.hierarchical)
                // Visual polish pass (31 August 2026): default changed from
                // `WatchTheme.accent` to the neutral `WatchTheme.icon` — see that
                // token's own doc comment. Call sites that want emphasis (the
                // account row's `.danger` on a session-expired state, for example)
                // still pass `tintColor:` explicitly and are unaffected.
                .foregroundStyle(tintColor ?? WatchTheme.icon)
                .watchIconColumn()
            VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                // Visual polish pass (31 August 2026): `design: .rounded` was
                // previously confined to two "hero" screens (`NowPlayingView`/
                // `StandaloneNowPlayingView`'s titles), leaving every navigational
                // row — the majority of the app's screens — on the plain system
                // design. Applying it here means the app's typographic personality
                // shows up everywhere `WatchRow` is used, not just two screens.
                Text(title)
                    .font(WatchMetrics.navigationRowTitleFont(weight: .medium))
                    .foregroundStyle(WatchTheme.primaryText)
                    // Batch 412: two lines, not one — "Recently Added" truncated to
                    // "Recently Ad…" on 40 mm.
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(WatchMetrics.subtitleFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                        // Batch 490 (REVIEW 2026-11-11 W14): one line cut explanatory
                        // subtitles ("Session expired — tap to reconnect"). Two lines,
                        // three at accessibility sizes.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map {
            String(localized: "\(String(localized: title)), \(String(localized: $0))",
                   comment: "VoiceOver label for a row: title, then subtitle")
        } ?? String(localized: title))
    }
}

extension WatchRow where Trailing == EmptyView {
    init(systemImage: String, title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil, tintColor: Color? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, tintColor: tintColor, trailing: { EmptyView() })
    }

}

/// Large circular play/pause/skip control button — sized generously for watchOS.
struct WatchControlButton: View {
    let systemImage: String
    let label: LocalizedStringResource
    // UI-12/WATCH-4 (REVIEW_2026-08-12.md): defaulted to 34pt with `.buttonStyle(.plain)`
    // (no implicit hit-area padding), below the ~44pt minimum recommended tap target —
    // the smallest, most error-prone controls to miss on a watch face while walking/
    // driving/exercising. `NowPlayingView` already overrides this to 46 for the
    // play/pause button; every OTHER caller (rewind/forward here, and anywhere else
    // that doesn't pass an explicit `size`) now gets 44 by default instead.
    //
    // P3-14 (third-pass review, 14 Aug 2026): this comment previously said 42, not the
    // actual 46 `NowPlayingView` passes, and claimed "every other caller now gets 44" —
    // but `PlaybackControlsView.swift` was passing an explicit 40 to three buttons
    // (below this file's own documented minimum), which this comment's claim papered
    // over instead of catching. Fixed the three call sites to pass 44 explicitly (see
    // that file), and corrected this comment's own numbers.
    var size: CGFloat = 44
    /// Critique 2026-10-06 (adapt): Always-On. The HIG's Always On page asks for
    /// nonessential content to dim while the layout stays put ("prefer transitioning an
    /// interactive component to an unavailable appearance — don't just remove it"). With
    /// the wrist down a transport button is not something anyone can press, so its glyph
    /// steps down to the secondary colour; the book and the time stay bright.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// LS-1 (docs/design-review.md, Round 2): true while the item this button
    /// controls is buffering (companion mode only — mirrors
    /// `WatchPlaybackState.isBuffering`). Purely additive: defaults to `false`, so
    /// every existing call site (skip/bookmark buttons, `StandaloneNowPlayingView`)
    /// is unaffected. See `WatchBufferingRing` for the ring itself — the glyph and
    /// tap target here never change while it's showing, only the ring overlay does.
    var showsBufferingRing: Bool = false
    var action: () -> Void

    init(systemImage: String, label: LocalizedStringResource, size: CGFloat = 44,
         showsBufferingRing: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.size = size
        self.showsBufferingRing = showsBufferingRing
        self.action = action
    }

    /// PS-3 (V5): on watchOS 26+ the system glass button draws the circle, so the card
    /// fill is only painted on earlier systems.
    private var glyph: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isLuminanceReduced ? WatchTheme.secondaryText : WatchTheme.primaryText)
            .frame(width: size, height: size)
            .modifier(WatchTransportBackground())
    }

    var body: some View {
        Button {
            // UI polish pass round 2: this one button type backs play/pause, skip
            // forward/back, and "add bookmark" everywhere in the app
            // (`WatchNowPlayingScreen`, shared by both modes)
            // — centralizing the haptic here means every one of those primary,
            // direct-tap actions gets tactile confirmation for free, rather than
            // needing the same `WatchHaptics.tap()` call added at each call site.
            WatchHaptics.tap()
            action()
        } label: {
            glyph
                // LS-1: overlay, not in-flow, so the ring never nudges the button's
                // own layout size — it just sits a few points outside the circle.
                .overlay {
                    if showsBufferingRing {
                        WatchBufferingRing(diameter: size + 6)
                    }
                }
        }
        .modifier(WatchTransportButtonStyle())
        .accessibilityLabel(Text(label))
        // LS-1: lets VoiceOver announce the stall on the one button it's shown on,
        // without a second accessibility element competing with `label` above.
        .accessibilityValue(showsBufferingRing ? Text("Buffering") : Text(verbatim: ""))
    }
}

/// PS-3 (V5, accepted "transport controls only", 26 September 2026): the Now Playing
/// transport buttons take the system Liquid Glass button style on watchOS 26+
/// (`PrimitiveButtonStyle.glass`, watchOS 26.0) and keep the card circle with the press
/// scale below that. List rows keep their current styles.
private struct WatchTransportButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(WatchPressScaleButtonStyle())
        }
    }
}

private struct WatchTransportBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *) {
            content
        } else {
            content.background(Circle().fill(WatchTheme.cardBackground))
        }
    }
}

/// LS-1 (docs/design-review.md, Round 2): the buffering indicator for companion-mode
/// playback. `AudioPlayerService.isBuffering` on the phone (mirrored onto
/// `WatchPlaybackState.isBuffering` by `WatchSessionManager.buildPlaybackState()`) was
/// already tracked but never shown anywhere on the Watch, so a stall looked identical
/// to an ordinary pause. Settled design: a spinner ring around the play/pause button
/// rather than swapping the glyph — the button stays legible and tappable throughout.
///
/// Revealed only after `revealDelay` of continuous buffering so a micro-stall that
/// clears before a user could ever perceive it doesn't flicker the ring on and
/// immediately back off; hides the instant the caller stops mounting this view
/// (`showsBufferingRing`/`state.isBuffering` turning false), which also cancels the
/// in-flight `Task.sleep` below for free, so a stall that ends mid-delay never reveals
/// a ring at all.
///
/// PL-16 (docs/design-review.md, follow-up round): the rotation used to be a
/// `withAnimation(.linear.repeatForever(...))` kicked off in `.onAppear`, gated only on
/// Reduce Motion — so with the wrist down (Always-On) it kept spinning on the dimmed
/// screen, same battery/attention issue as PL-10 on `WatchSpinningReelBadge`
/// (NowPlayingView.swift). A `repeatForever` animation has no way to be paused by a
/// later environment change once started, so this now follows the same `TimelineView`
/// pattern PL-10 landed: `isLuminanceReduced` folds into `animate` alongside Reduce
/// Motion, and `paused:` on the `TimelineView` stops the timer being scheduled at all
/// (not just stops it being drawn) the instant the wrist drops, and resumes it on
/// wrist-raise. Per
/// developer.apple.com/documentation/swiftui/environmentvalues/isluminancereduced
/// (checked via scripts/appledoc.sh; watchOS 8.0+), watchOS sets this `true` while the
/// wrist is down but the view is still on screen rather than blurred, which is exactly
/// this case.
struct WatchBufferingRing: View {
    var diameter: CGFloat = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var isRevealed = false

    private static let revealDelay: Duration = .milliseconds(300)
    private static let rotationDuration: Double = 0.9
    // PL-16: 30 fps rather than the 15 fps `WatchSpinningReelBadge` uses — that badge
    // turns once every 4s (90°/s), so 15 fps lands a new frame every 6°; this ring
    // turns once every 0.9s, where 15 fps would land one every ~24° (visibly stepped
    // at that speed). 30 fps halves that to ~12° per frame, still cheap to schedule.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        let animate = !reduceMotion && !isLuminanceReduced
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !animate)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / Self.rotationDuration
            // Rests at a fixed 0° rather than the angle mid-spin when it stopped —
            // matches the pre-existing Reduce Motion behaviour, so wrist-down doesn't
            // introduce a second "stuck at an arbitrary angle" look.
            let degrees = animate ? turns.truncatingRemainder(dividingBy: 1) * 360 : 0
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(degrees))
        }
        .frame(width: diameter, height: diameter)
        .opacity(isRevealed ? 1 : 0)
        .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: isRevealed)
        // Purely decorative and must never steal the tap from the button it
        // overlays, or add a second VoiceOver stop next to it.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: Self.revealDelay)
            // A cancelled sleep (this view removed — buffering ended — before
            // the delay elapsed) must not reveal the ring; SwiftUI cancels this
            // task automatically when the view disappears.
            guard !Task.isCancelled else { return }
            isRevealed = true
        }
    }
}

/// Reads Settings → Accessibility → Reduce Motion so `.animation(_:value:)` call sites
/// on the Watch don't each have to declare their own
/// `@Environment(\.accessibilityReduceMotion)` to respect it. Mirrors the iOS
/// `shelfAnimation` helper in `Extensions/Extensions.swift` — that helper lives in the
/// iOS target and isn't visible to the Watch target, so it's re-declared here rather than
/// shared. When Reduce Motion is on, this passes `nil` instead of `animation`, so
/// SwiftUI still applies the state change but without animating it.
private struct WatchReduceMotionAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Drop-in, Reduce-Motion-aware replacement for `.animation(_:value:)`.
    func watchAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(WatchReduceMotionAnimationModifier(animation: animation, value: value))
    }
}

/// UI polish pass round 2: `.buttonStyle(.plain)` gave every transport button zero
/// visual acknowledgment of a press beyond whatever the system's default dimming
/// does — buttons felt "dead" under a thumb, one of the concrete "feels
/// unfinished" signals from direct user feedback. A brief scale-down on press,
/// same idea as iOS's own button press feedback, closes that gap without needing
/// per-button state.
struct WatchPressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: configuration.isPressed)
    }
}

/// A thin horizontal progress bar (used on Now Playing), orange accent, rounded ends.
struct WatchLinearProgressBar: View {
    /// 0...1
    var progress: Double
    /// Critique 2026-10-06 (adapt): a large accent fill is exactly what the HIG's Always
    /// On page says to dim; the bar keeps its length (the layout doesn't change) but the
    /// fill drops to the secondary colour with the wrist down.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(WatchTheme.cardBorder)
                Capsule()
                    .fill(isLuminanceReduced ? WatchTheme.secondaryText : WatchTheme.accent)
                    .frame(width: max(2, proxy.size.width * min(max(progress, 0), 1)))
                    // UI polish pass round 2: this used to jump straight to each new
                    // width with no animation — every progress tick (playback
                    // position, download percentage) snapped instead of flowing,
                    // which read as unpolished next to how every native watchOS
                    // progress indicator eases between values.
                    .watchAnimation(.easeInOut(duration: WatchMetrics.stateChangeAnimationDuration), value: progress)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Shared "phone hasn't told us anything useful yet" empty state, used across several
/// screens (chapters, downloads, bookmarks) when the relevant data hasn't synced.
struct WatchOpenOniPhoneEmptyState: View {
    var systemImage: String = "iphone.gen3"
    var message: LocalizedStringResource = "Open ShelfHead on iPhone to sync"

    init(systemImage: String = "iphone.gen3", message: LocalizedStringResource = "Open ShelfHead on iPhone to sync") {
        self.systemImage = systemImage
        self.message = message
    }

    // Visual polish pass (31 August 2026), direct user request ("make the app look
    // nicer"): this was a bare glyph + gray caption floating on the plain black
    // background — no different from a placeholder that forgot to load. Wrapped in
    // `WatchCard` (the app's one elevation component, previously used in exactly one
    // place — `NowPlayingView`'s cover/title block) and bumped the glyph size/tint so
    // an empty state reads as a designed screen state, not an afterthought.
    var body: some View {
        WatchCard {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(WatchMetrics.heroGlyphFont())
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WatchTheme.icon)
                Text(message)
                    .font(WatchMetrics.secondaryFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Visual polish pass (31 August 2026), direct user request ("make the app look
/// nicer"): a small colored capsule chip, used in place of several screens' bare
/// status `Text`/`Label` combos (queued/finished/downloaded/failed) — a
/// background-tinted capsule reads as a deliberate status indicator, where plain
/// colored text next to plain colored text (per the audit that flagged this: "the
/// only differentiator ... is a caption string") reads as an afterthought.
/// Deliberately not used everywhere a status appears — a row's trailing-edge glyph
/// slot (`StandaloneLibraryView.downloadStatusGlyph`) and a genuinely long failure
/// message both stay as they were, since a badge that has to truncate real content
/// isn't an improvement over the text it replaced.
/// Critique 2026-10-06 (colorize, third pass): an error or warning sentence. The alert
/// hue goes on the glyph only; the words stay cream, so a long message is read at body
/// contrast instead of in orange (or the old raw red).
struct WatchAlertNotice: View {
    let text: LocalizedStringResource
    var systemImage: String = "exclamationmark.triangle.fill"
    var alignment: TextAlignment = .leading
    var font: Font = WatchMetrics.subtitleFont()

    init(text: LocalizedStringResource, systemImage: String = "exclamationmark.triangle.fill",
         alignment: TextAlignment = .leading, font: Font = WatchMetrics.subtitleFont()) {
        self.text = text
        self.systemImage = systemImage
        self.alignment = alignment
        self.font = font
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(WatchTheme.alert)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(WatchTheme.primaryText)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .accessibilityElement(children: .combine)
    }
}

struct WatchStatusBadge: View {
    let text: LocalizedStringResource
    var systemImage: String? = nil
    let tint: Color

    init(text: LocalizedStringResource, systemImage: String? = nil, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(WatchMetrics.captionFont(weight: .semibold))
            }
            Text(text)
                .font(WatchMetrics.captionFont(weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.18), in: Capsule())
    }
}

/// Batch 412 (Watch redesign, docs/design/watch-redesign-2026-10-21.md §6): the one book
/// row for every list (Library, Recently Added, a collection, Downloads). A 40pt cover
/// (was 32), a title that gets two lines before it truncates, the author, then the
/// book's state: Finished, a progress bar, or whatever `detail` the screen passes (a
/// download's status). The cover is passed in because each list has its own source
/// (mirror bytes, this Watch's file, or the server).
struct WatchBookRow<Cover: View, Detail: View, Trailing: View>: View {
    static var coverSide: CGFloat { 40 }

    let title: String
    let author: String
    /// 0...1, or nil when the list doesn't know it.
    var progress: Double? = nil
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, author: String, progress: Double? = nil,
         @ViewBuilder cover: @escaping () -> Cover,
         @ViewBuilder detail: @escaping () -> Detail,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.author = author
        self.progress = progress
        self.cover = cover
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            cover()
                .frame(width: Self.coverSide, height: Self.coverSide)
                // Batch 490 (REVIEW 2026-11-11 W14): the Always-On Rule for every list's covers.
                .watchAlwaysOnDimmed()
            VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                Text(verbatim: title)
                    .font(WatchMetrics.contentRowTitleFont(weight: .medium, rounded: true))
                    .foregroundStyle(WatchTheme.primaryText)
                    .lineLimit(2)
                if !author.isEmpty {
                    Text(verbatim: author)
                        .font(WatchMetrics.subtitleFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                        .lineLimit(1)
                }
                if let progress, progress >= 0.99 {
                    // The phone's finished line; teal is for finished only (DESIGN.md).
                    WatchStatusBadge(text: "Finished", systemImage: "checkmark", tint: WatchTheme.finished)
                } else if let progress, progress > 0 {
                    WatchLinearProgressBar(progress: progress)
                        .padding(.top, 2)
                }
                detail()
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, WatchMetrics.rowVerticalPadding)
    }
}

extension WatchBookRow where Detail == EmptyView, Trailing == EmptyView {
    init(title: String, author: String, progress: Double? = nil, @ViewBuilder cover: @escaping () -> Cover) {
        self.init(title: title, author: author, progress: progress, cover: cover, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension WatchBookRow where Trailing == EmptyView {
    init(title: String, author: String, progress: Double? = nil,
         @ViewBuilder cover: @escaping () -> Cover, @ViewBuilder detail: @escaping () -> Detail) {
        self.init(title: title, author: author, progress: progress, cover: cover, detail: detail, trailing: { EmptyView() })
    }
}

extension WatchBookRow where Detail == EmptyView {
    init(title: String, author: String, progress: Double? = nil,
         @ViewBuilder cover: @escaping () -> Cover, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, author: author, progress: progress, cover: cover, detail: { EmptyView() }, trailing: trailing)
    }
}

extension Double {
    /// "H:MM:SS" / "MM:SS" formatting for durations, matching iOS's `formattedTime`.
    nonisolated var watchFormattedTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Verbatim text (Batch 400)

extension LocalizedStringResource {
    /// Text that must be shown as-is — a book, author or server name, or a string that is
    /// already localized. A string literal passed where a `LocalizedStringResource` is
    /// expected is a catalog key; a runtime value has to say so explicitly, because the
    /// `@_disfavoredOverload` `String` bridges this replaced were sometimes chosen for
    /// literals too, which kept those literals out of the String Catalog.
    /// `nonisolated`: the Watch target defaults to MainActor isolation, and call sites pass
    /// this as an unapplied reference to `Optional.map`, which is a nonisolated context.
    nonisolated static func verbatim(_ text: some StringProtocol) -> LocalizedStringResource {
        LocalizedStringResource(stringLiteral: String(text))
    }
}

/// Batch 413: the cover for a book with no artwork, at sizes where words fit (the Shelf,
/// Book Details). The title set on espresso, a short rule, then the author, so the book
/// still reads as itself instead of as a generic book glyph. Decorative: callers hide it
/// from VoiceOver, since the title is always printed beside it.
struct WatchTitleCover: View {
    let title: String
    var author: String? = nil
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(WatchTheme.cardBackground)
            .overlay {
                VStack(spacing: 6) {
                    Text(verbatim: title)
                        .font(WatchMetrics.secondaryFont(weight: .semibold, rounded: true))
                        .foregroundStyle(WatchTheme.primaryText)
                        .lineLimit(4)
                    if let author, !author.isEmpty {
                        Rectangle()
                            .fill(WatchTheme.cardBorder)
                            .frame(width: 20, height: 1)
                        Text(verbatim: author)
                            .font(WatchMetrics.captionFont())
                            .foregroundStyle(WatchTheme.secondaryText)
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .padding(10)
            }
            .accessibilityHidden(true)
    }

    /// Below this side a title can't be read; the small book glyph stays.
    static let minimumSide: CGFloat = 72
}
