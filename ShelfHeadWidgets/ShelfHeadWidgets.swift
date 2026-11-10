import WidgetKit
import SwiftUI
import UIKit
import AppIntents
import Foundation

// Home-Screen widget showing the current book, styled to match the app's
// retro tape-deck theme. The widget target can't see the app's Color palette
// (Extensions.swift), so the equivalent pieces it needs are re-derived locally here:
// the user's chosen accent (read from the App Group, mirroring ThemeStore) and the
// same light/dark hex pairs as `Color.adaptive(light:dark:)` in the main target,
// so the widget actually matches the app's theme instead of always looking dark (M10).

// Widened from `private` to internal (N-2, REVIEW_2026-09-14_DESIGN.md): the new
// Control Center control (`ShelfHeadPlaybackControl.swift`) needs `color(hex:)` and
// `accentHex` to tint its play/pause glyph the same way the Home Screen widget does.
// Still not visible outside this extension target — just no longer file-scoped.
enum WidgetTheme {
    /// Same hex→Color parsing as the app's `Color.init(hex:)`, duplicated here since the
    /// widget target doesn't compile against the app's Extensions.swift.
    static func color(hex: String) -> Color {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (232, 168, 56)   // fall back to the classic amber
        }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }

    /// WATCH-5 (REVIEW_2026-08-12.md): this used to ALWAYS resolve through a
    /// `UIColor` dynamic provider keyed on the SYSTEM trait collection at render time
    /// — meaning a user who explicitly forced Light or Dark in Settings > Appearance
    /// (mirrored into the App Group by `ThemeStore`, read here as `appearanceRaw`)
    /// still got whichever palette matched the PHONE'S system appearance, because
    /// `.preferredColorScheme(_:)` on `ShelfHeadWidgetView` doesn't reliably propagate
    /// through to how WidgetKit resolves dynamic `UIColor`s the way it would inside the
    /// main app's own view hierarchy. Mirrors `ThemeStore`/`AppAppearance`'s own
    /// resolution on the phone side: when the user picked an explicit theme (not
    /// "system"), resolve directly to that hex — no trait collection involved at all.
    /// Only "system" still defers to the live trait collection, which is the one case
    /// where following the system's current appearance is actually correct.
    static func adaptive(light: String, dark: String) -> Color {
        switch appearanceRaw {
        case "light": return color(hex: light)
        case "dark": return color(hex: dark)
        default:
            return Color(UIColor { traits in
                UIColor(color(hex: traits.userInterfaceStyle == .dark ? dark : light))
            })
        }
    }

    /// The App Group suite both the app and widget share (see SharedPlayback).
    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedPlayback.appGroup) }

    /// User-selected accent, mirrored into the App Group by `ThemeStore`. Falls back to
    /// the classic amber if the app hasn't written a value yet (e.g. very first install).
    static var accentHex: String { defaults?.string(forKey: "settings_accentColor") ?? "E8A838" }

    /// "system" | "light" | "dark", mirrored into the App Group by `ThemeStore`.
    static var appearanceRaw: String { defaults?.string(forKey: "settings_appearance") ?? "system" }

    /// nil means "follow the system", matching `AppAppearance.system`.
    static var preferredColorScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    // U1 (REVIEW_2026-08-20_UI_SECURITY.md): the widget target had no equivalent of
    // the app's `shelfAmberText` — a WCAG-safe text/icon variant of the (user-selectable)
    // accent — so three foregrounds rendered the raw accent directly (1.70:1–1.87:1 in
    // Light, against a 4.5:1/3:1 floor). Ported from `AppTheme.adjustedHexForContrast`
    // (Extensions.swift ~359-390) rather than shared, for the same reason `color(hex:)`
    // above is duplicated: the widget target doesn't compile against Extensions.swift
    // (it pulls in `scaledFont`/`ThemeStore` and the rest of the app's dependency graph).

    private static func rgbComponents(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        return (
            Double((int >> 16) & 0xFF) / 255.0,
            Double((int >> 8) & 0xFF) / 255.0,
            Double(int & 0xFF) / 255.0
        )
    }

    private static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Code review fix (26 August 2026, finding 19): the widget's play/pause glyph used
    /// to hardcode `Retro.bg` as its foreground on top of the `amber` fill — a
    /// "background-as-ink" idiom that reads fine in Dark theme (where `Retro.bg` is a
    /// near-black `16110C`) but is near-invisible in Light theme, where `Retro.bg`
    /// resolves to `F7F2E9` (near-white paper) against the default amber `E8A838`
    /// (~1.6:1 contrast). Mirrors the app-side `bestInk` pattern: pick whichever of
    /// pure black or pure white actually contrasts against the live accent, instead of
    /// assuming the background color always will.
    static var onAccent: Color {
        let c = rgbComponents(accentHex)
        let lum = relativeLuminance(r: c.r, g: c.g, b: c.b)
        // Mirrors the app-side fix in `ContrastInk.bestInk`: the dark option's contrast
        // was computed as if the ink were pure black (`/ 0.05`), but the ink actually
        // returned is `Color(white: 0.08)`, luminance ~0.0072. That overstated it by ~14%
        // and gave Indigo (6366F1) dark ink at 4.11:1 where white achieves 4.47:1.
        let darkInkLuminance = relativeLuminance(r: 0.08, g: 0.08, b: 0.08)
        let withWhite = 1.05 / (lum + 0.05)
        let withDarkInk = (lum + 0.05) / (darkInkLuminance + 0.05)
        return withDarkInk >= withWhite ? Color(white: 0.08) : .white
    }

    /// Nudges `hex` toward black or white (whichever increases contrast against
    /// `backgroundHex`) in small linear-RGB steps until it clears `targetRatio`, or
    /// until it reaches that endpoint. Identical algorithm to `AppTheme.adjustedHexForContrast`.
    static func adjustedHexForContrast(_ hex: String, backgroundHex: String, targetRatio: Double = 4.5) -> String {
        let bg = rgbComponents(backgroundHex)
        let backgroundLuminance = relativeLuminance(r: bg.r, g: bg.g, b: bg.b)
        let original = rgbComponents(hex)

        func ratio(_ luminance: Double) -> Double {
            let lighter = max(luminance, backgroundLuminance), darker = min(luminance, backgroundLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }

        let originalLuminance = relativeLuminance(r: original.r, g: original.g, b: original.b)
        guard ratio(originalLuminance) < targetRatio else { return hex }

        // The loop below must judge the colour it will actually *return*. Stepping until
        // the float components clear the target, then quantizing to 8-bit in
        // `hexString`, can round the luminance back under it — that is how Teal (2FB6A8)
        // came out at 4.4973:1 against the Light background for a 4.5 target. Measuring
        // the quantized value makes the returned hex genuinely satisfy the contract.
        func quantizedLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func q(_ v: Double) -> Double { (min(1, max(0, v)) * 255).rounded() / 255 }
            return relativeLuminance(r: q(r), g: q(g), b: q(b))
        }

        let stepsTowardBlack = ratio(0) >= ratio(1)
        var (r, g, b) = original
        var t = 0.0
        while ratio(quantizedLuminance(r, g, b)) < targetRatio && t < 1.0 {
            t += 0.02
            if stepsTowardBlack {
                r = original.r * (1 - t)
                g = original.g * (1 - t)
                b = original.b * (1 - t)
            } else {
                r = original.r + (1 - original.r) * t
                g = original.g + (1 - original.g) * t
                b = original.b + (1 - original.b) * t
            }
        }
        func channel(_ v: Double) -> UInt64 { UInt64((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// The accent, darkened just enough to clear 4.5:1 against whichever background is
    /// actually behind it — one hex per theme, resolved the same way `adaptive(light:dark:)`
    /// already resolves the *background* colors against `appearanceRaw`.
    static var amberTextHex: (light: String, dark: String) {
        (adjustedHexForContrast(accentHex, backgroundHex: "F7F2E9"),
         adjustedHexForContrast(accentHex, backgroundHex: "16110C"))
    }
}

/// U10 (REVIEW_2026-08-20_UI_SECURITY.md): mirrors `Radius.chip` from the main target's
/// `DesignTokens.swift` — duplicated rather than shared for the same reason `color(hex:)`
/// above is: that file's sibling `Typo` functions depend on `scaledFont`
/// (Extensions.swift), which this target doesn't compile against.
// Batch 403: widget target doesn't compile Extensions.swift; mirrors LocalizedText.tracking (no letter-spacing for zh/ja).
private enum WidgetText {
    static func tracking(_ v: CGFloat) -> CGFloat {
        let lang = Bundle.main.preferredLocalizations.first ?? ""
        return (lang.hasPrefix("zh") || lang.hasPrefix("ja")) ? 0 : v
    }
}

private enum WidgetRadius {
    static let chip: CGFloat = 8
}

/// W4 (REVIEW_2026-09-04_UI.md Pass 4): mirrors `ScaledFontModifier`/`View.scaledFont`
/// from the main target's `Extensions.swift` — duplicated rather than shared for the
/// same reason `WidgetTheme.color(hex:)` and `WidgetRadius.chip` above already are:
/// `scaledFont` itself is trivial (just `@ScaledMetric`), but it lives in a file that
/// pulls in the rest of the app's dependency graph, which this target doesn't compile
/// against. Before this existed, the Home Screen families were the one surface in the
/// app built entirely on bare `.font(.system(size: N, …))` — no `relativeTo:`, no
/// `@ScaledMetric` — so none of it moved for Dynamic Type at all (the three accessory
/// families were already fine: `.headline`/`.caption2` are real text styles).
private struct WidgetScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

private extension View {
    /// Drop-in replacement for `.font(.system(size:weight:design:))` that still scales
    /// with Dynamic Type. Deliberately keeps every call site's existing base `size` (so
    /// the default-size, default-appearance render is unchanged) and only adds scaling
    /// behavior — see `homeScreen`'s `.dynamicTypeSize(...)` cap for how the Home Screen
    /// families keep that scaling from overflowing their fixed boxes at the largest
    /// accessibility sizes.
    func widgetScaledFont(_ size: CGFloat,
                          weight: Font.Weight = .regular,
                          design: Font.Design = .default,
                          relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(WidgetScaledFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

private enum Retro {
    // WATCH-3 / palette staleness (follow-up review, 14 Aug 2026): these five were
    // `static let`, computed once and cached for the lifetime of the widget
    // extension's process — unlike `amber` just below, which was already `static var`.
    // WidgetKit extension processes are frequently reused across many timeline
    // reloads rather than relaunched per-render, so a user switching Settings >
    // Appearance while the extension process was still warm kept seeing the OLD
    // theme's cream/background/card/surface/muted colors (mismatched against the
    // live `amber`, which always re-read the App Group) until the process happened
    // to be killed and relaunched. Changed to `static var` so every access re-reads
    // `WidgetTheme.appearanceRaw` live, matching `amber`'s existing pattern.
    static var amber:   Color { WidgetTheme.color(hex: WidgetTheme.accentHex) }
    /// Finding 19 (code review, 26 August 2026): black-or-white ink for content sitting
    /// directly ON TOP of the `amber` fill (e.g. the play/pause glyph) — distinct from
    /// `amberText` above, which is amber-on-background, not background-on-amber.
    static var onAccent: Color { WidgetTheme.onAccent }
    /// U1 (REVIEW_2026-08-20_UI_SECURITY.md): text/icon-safe accent, mirroring
    /// `Color.shelfAmberText` on the app side — use for foregrounds (labels, glyphs);
    /// `amber` above stays reserved for fills. No `.opacity()` on top of this (see U2's
    /// reasoning, which applies here too — it's computed to just clear 4.5:1 and stop).
    static var amberText: Color {
        let hexes = WidgetTheme.amberTextHex
        return WidgetTheme.adaptive(light: hexes.light, dark: hexes.dark)
    }
    static var cream:   Color { WidgetTheme.adaptive(light: "2A211A", dark: "F4E9D6") }
    static var bg:      Color { WidgetTheme.adaptive(light: "F7F2E9", dark: "16110C") }
    static var card:    Color { WidgetTheme.adaptive(light: "FFFFFF", dark: "241B12") }
    static var surface: Color { WidgetTheme.adaptive(light: "EAE1D2", dark: "32261A") }
    static var muted:   Color { WidgetTheme.adaptive(light: "6E5E49", dark: "A89177") }

    /// W8 (REVIEW_2026-09-04_UI.md Pass 4): the progress track's own adaptive pair —
    /// it used to be `cream.opacity(0.14)`, which in Light composited to ≈1.15:1
    /// against the container gradient (`cream` in Light IS the dark-brown ink color;
    /// an opacity on it has no headroom, the same point U2 already made about this
    /// token family). Chosen to clear the WCAG 1.4.11 non-text 3:1 floor against BOTH
    /// ends of the container gradient (`card` → `bg`):
    /// Light `8A7A64` measures ≈4.16:1 against `card` (FFFFFF, L 1.0) and ≈3.73:1
    /// against `bg` (F7F2E9, L 0.892) — its own luminance is ≈0.203.
    /// Dark `7A6A4E` measures ≈3.23:1 against `card` (241B12, L 0.012) and ≈3.57:1
    /// against `bg` (16110C, L 0.006) — its own luminance is ≈0.150 (Dark wasn't
    /// flagged as broken, but it's moved off the same non-adaptive-opacity pattern too).
    static var progressTrack: Color { WidgetTheme.adaptive(light: "8A7A64", dark: "7A6A4E") }

    /// W8 (REVIEW_2026-09-04_UI.md Pass 4): the cassette band behind the spool line —
    /// was a non-adaptive `.black.opacity(0.5)` literal (the exact landmine U12 already
    /// removed `shell` for, just not caught here). Worse than just being non-adaptive:
    /// because it's translucent, it composited with whatever *adaptive* background sat
    /// behind it, so it rendered as a light mid-grey band in Light (≈0.5 × the Light
    /// background's own ≈0.89 luminance) and a near-black band in Dark (≈0.5 × ≈0.006) —
    /// two very different surfaces for one line color to read against. Opaque and
    /// genuinely adaptive now, and deliberately dark in BOTH themes so `tapeLine` below
    /// can be one light color that reads everywhere instead of flipping with `cream`.
    static var tapeBand: Color { WidgetTheme.adaptive(light: "3C2E21", dark: "120D08") }

    /// W8 (REVIEW_2026-09-04_UI.md Pass 4): the spool line — was `cream.opacity(0.25)`,
    /// which is exactly why it flipped legibility with theme: `cream` itself flips from
    /// a light tone in Dark to a dark brown in Light, so the *same* opacity measured
    /// ≈2.5:1 in Dark and ≈1.35:1 in Light. Now a light warm cream at full strength (no
    /// opacity — see U2 on this token family having no headroom for one) against the
    /// now-uniformly-dark `tapeBand`: ≈10.4:1 in Light (`F0E4CC` on `3C2E21`) and
    /// ≈16.1:1 in Dark (`F4E9D6` on `120D08`).
    static var tapeLine: Color { WidgetTheme.adaptive(light: "F0E4CC", dark: "F4E9D6") }

    // U12 (REVIEW_2026-08-20_UI_SECURITY.md): `shell` used to be a non-adaptive raw
    // literal among six adaptive siblings — a landmine for whoever next reached for it
    // assuming (reasonably, given its neighbours and the M10 comment above) that it was
    // already theme-safe. Confirmed zero call sites anywhere in this target; deleted
    // rather than made adaptive, since nothing uses it.
}

struct PlaybackEntry: TimelineEntry {
    /// W1 (REVIEW_2026-09-04_UI.md Pass 4): which configuration produced a pinned entry,
    /// so the eyebrow can be honest about it ("UP NEXT" vs "PINNED") instead of claiming
    /// "NOW PLAYING" over a book that isn't the live session.
    enum PinnedSource {
        case upNext
        case specificBook
    }

    let date: Date
    let snapshot: SharedPlayback.Snapshot?
    /// Set when the widget is pinned to a book that isn't the live session, so the view
    /// reads that book's cover from `SharedLibrary` instead of the now-playing cover file.
    /// `nil` means "draw the live session's cover", which is every pre-configuration case.
    var pinnedItemId: String? = nil
    /// Which pinned mode produced this entry. `nil` whenever `pinnedItemId` is `nil`.
    var pinnedSource: PinnedSource? = nil
    /// Item 32: true only for the synthetic sample shown while `context.isPreview` (the
    /// widget gallery) — never for a real placeholder/snapshot/timeline entry. Threaded
    /// down to `WidgetCassette` so it can skip reading the App Group entirely for the
    /// gallery card rather than reading a real cover file that has nothing to do with the
    /// sample book being shown.
    var isGalleryPreview: Bool = false
    /// True when the entry describes a pinned book rather than an active session — the
    /// view uses it to show a "resume" affordance instead of live transport state.
    var isPinned: Bool { pinnedItemId != nil }

    /// PL-9 (docs/design-review.md, Round 5): whether the main app was signed in, as
    /// resolved by `PlaybackProvider.resolvePlaybackAndSignedIn(rawSnapshot:)` at the
    /// point this entry was built. Only meaningful — and only consulted by the empty-state
    /// views — when `snapshot` is `nil`: `false` shows "sign in" copy instead of "start a
    /// book", `nil` (the legacy/unknown case) keeps the original account-agnostic copy so
    /// a signed-in user is never told to sign in. Left at its default `nil` wherever the
    /// entry already carries a snapshot, since that branch never reads it.
    var isSignedIn: Bool? = nil

    /// W9 (REVIEW_2026-09-04_UI.md Pass 4): true when the user configured a pin (Up
    /// Next, or a specific book) that can't currently be honoured — the queue is
    /// empty, or the chosen book dropped out of `SharedLibrary`'s published set
    /// (finished, or pushed past `SharedLibrary.maxBooks`) — so this entry fell back
    /// to the live session. `isPinned` is `false` on an entry like this (there's no
    /// book to draw), but silently reverting to an unqualified "NOW PLAYING" is the
    /// bug: the user asked for a pin and the widget stopped honouring it with nothing
    /// anywhere saying so. See `PlaybackProvider.isUnresolvedPin(for:)`.
    var lostPin: Bool = false

    /// W1 (REVIEW_2026-09-04_UI.md Pass 4): the eyebrow label above the title.
    ///
    /// This used to be a hardcoded `Text("NOW PLAYING")` in both `medium(_:)` and
    /// `large(_:)`, drawn over whatever the entry held — including a pinned book that is,
    /// by construction, *not* what's playing (see `PlaybackProvider.resolved(for:at:)`,
    /// which prefers the live snapshot whenever the pinned book IS the session). Only the
    /// live case keeps the "NOW PLAYING" wording; both pinned modes get a label that
    /// describes what the tile actually is. Kept to two short words so the
    /// `tracking(2)` eyebrow still fits one line at systemSmall's width.
    var eyebrow: String {
        // W9 (REVIEW_2026-09-04_UI.md Pass 4): checked before `pinnedSource` — a
        // `lostPin` entry never has a `pinnedSource` (there's no resolved pin to
        // attribute one to), so without this it fell through to the same unqualified
        // "NOW PLAYING" as a widget nobody ever configured.
        if lostPin { return String(localized: "NO PIN SET", comment: "Widget eyebrow (uppercase label) when the pinned book is unavailable") }
        guard let pinnedSource else { return String(localized: "NOW PLAYING", comment: "Widget eyebrow (uppercase label) above the current book title") }
        switch pinnedSource {
        case .upNext:       return String(localized: "UP NEXT", comment: "Widget eyebrow (uppercase label): the next book in the queue")
        case .specificBook: return String(localized: "PINNED", comment: "Widget eyebrow (uppercase label): a specific pinned book")
        }
    }

    /// W1 (REVIEW_2026-09-04_UI.md Pass 4): where the whole tile taps through to.
    ///
    /// Was unconditionally `shelfhead://nowplaying`, which on a pinned tile opened the
    /// player on a *different* book than the one drawn. A pinned entry routes to
    /// `shelfhead://book/<id>` instead — a route the app already handles
    /// (`ContentView.handleDeepLink`, `case "book"`), which presents that book's detail
    /// sheet, where a real Play button exists. The live case is unchanged.
    var deepLinkURL: URL? {
        if let id = pinnedItemId,
           let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "shelfhead://book/\(escaped)") {
            return url
        }
        return URL(string: "shelfhead://nowplaying")
    }

    /// Item 32: the widget gallery (`context.isPreview`) used to render this widget's
    /// real empty state ("No tape loaded, Start a book in ShelfHead") — a fresh install
    /// or a signed-out device with no App Group data yet showed that same unhelpful card
    /// to someone just browsing widgets to add, instead of a plausible sample of what the
    /// widget actually looks like once configured. Deliberately synthetic: no
    /// `SharedPlayback.read()`/`SharedLibrary.read()` call, so building this touches
    /// neither the App Group nor the network. `SharedPlayback.Snapshot` carries no
    /// chapter field (nor does anything else this widget renders), so the sample only
    /// needs to cover what the views actually draw: title, author, and time-based
    /// progress — a plausible ~46% through an ~11-hour audiobook.
    static func galleryPreview(date: Date = Date()) -> PlaybackEntry {
        var entry = PlaybackEntry(
            date: date,
            snapshot: SharedPlayback.Snapshot(
                itemId: "shelfhead.gallery-preview",
                title: "The Fellowship of the Ring",
                author: "J.R.R. Tolkien",
                currentTime: 3 * 3600 + 24 * 60,       // 3h 24m in
                duration: 11 * 3600 + 5 * 60,          // ~11h 5m total
                isPlaying: true,
                updatedAt: date,
                rate: 1,
                skipBackwardInterval: 15,
                skipForwardInterval: 30))
        entry.isGalleryPreview = true
        return entry
    }
}

struct PlaybackProvider: AppIntentTimelineProvider {
    typealias Intent = SelectWidgetContentIntent
    typealias Entry = PlaybackEntry

    func placeholder(in context: Context) -> PlaybackEntry {
        // Item 32: the widget gallery renders this (and/or `snapshot(for:in:)` below)
        // with `context.isPreview == true` — return the synthetic sample instead of the
        // real empty state so someone browsing widgets to add sees a plausible card.
        //
        // PL-7 (docs/design-review.md, Round 5): the non-preview branch used to return the
        // empty entry (`snapshot: nil`). WidgetKit renders `placeholder(in:)`'s entry as a
        // redacted placeholder on first display ("a generic representation of your
        // widget" — developer.apple.com/documentation/widgetkit/timelineprovider/
        // placeholder(in:), iOS 14.0+), keeping its shape, so a newly added widget
        // shimmered the "No tape loaded" layout instead of cover, title and progress. The
        // sample entry is synthetic (no App Group read, no cover data), so it's safe in
        // both branches.
        return .galleryPreview()
    }

    func snapshot(for configuration: SelectWidgetContentIntent, in context: Context) async -> PlaybackEntry {
        // Item 32: same reasoning as `placeholder(in:)` above — checked first so the
        // gallery preview never touches `resolved(for:at:)`, which reads `SharedLibrary`
        // and `SharedPlayback` from the App Group.
        if context.isPreview { return .galleryPreview() }
        if let resolved = resolved(for: configuration, at: Date()) { return resolved }
        // W9 (REVIEW_2026-09-04_UI.md Pass 4): `resolved` returning `nil` here means
        // either "nothing configured" (`.nowPlaying`) or "configured, but unresolvable"
        // — `isUnresolvedPin` is what tells those apart so the fallback entry can say so.
        let (snapshot, signedIn) = resolvePlaybackAndSignedIn(rawSnapshot: SharedPlayback.read())
        var fallback = PlaybackEntry(date: Date(), snapshot: snapshot)
        fallback.isSignedIn = signedIn
        fallback.lostPin = isUnresolvedPin(for: configuration)
        return fallback
    }

    /// PL-9 (docs/design-review.md, Round 5): resolves a raw `SharedPlayback.read()`
    /// against the signed-in flag `AuthViewModel` publishes on every sign-in/out
    /// transition (`SharedPlayback.setSignedIn(_:)`). Two things happen here: the
    /// legacy/unknown gap for a device that updated from a build before the flag existed
    /// is filled by `SharedPlayback.resolvedSignedIn(hasSnapshot:)`, and — independently
    /// of how that resolves — a `false` result always wins over whatever snapshot is
    /// still on disk. That second part matters even though sign-out already clears the
    /// snapshot (`AudioPlayerService.stop()` → `SharedPlayback.write(nil)`, run from
    /// every real sign-out/account-switch teardown): it's a defensive backstop for a
    /// process killed mid-teardown or any other case where that write didn't land, so a
    /// signed-out widget can never show a stale book regardless of what's stored.
    private func resolvePlaybackAndSignedIn(
        rawSnapshot: SharedPlayback.Snapshot?
    ) -> (snapshot: SharedPlayback.Snapshot?, isSignedIn: Bool?) {
        let signedIn = SharedPlayback.resolvedSignedIn(hasSnapshot: rawSnapshot != nil)
        return (signedIn == false ? nil : rawSnapshot, signedIn)
    }

    /// W9 (REVIEW_2026-09-04_UI.md Pass 4): true when the user picked "Up Next" or "A
    /// Specific Book" but `resolved(for:at:)` couldn't find a book to honour it with —
    /// as opposed to `.nowPlaying`, where there was never a pin to lose. Kept separate
    /// from `resolved(for:at:)` itself (rather than changing what it returns) so the
    /// existing, already-relied-on "nil ⇒ fall back to the live session" contract for
    /// both callers below stays exactly as it was; this only adds the extra bit of
    /// information callers need to render that fallback honestly.
    private func isUnresolvedPin(for configuration: SelectWidgetContentIntent) -> Bool {
        guard configuration.mode != .nowPlaying else { return false }
        // PL-17 (docs/design-review.md, follow-up): a signed-out widget doesn't have a
        // "lost" pin — `resolved(for:at:)` below now returns `nil` for the signed-out
        // case too (checked before it ever looks at the pin), and that's a different
        // situation from a pin that genuinely dropped out of `SharedLibrary` while
        // still signed in. Without this guard, every pinned widget would flip to "NO
        // PIN SET" the moment the user signed out, instead of the dedicated signed-out
        // empty state. `nil`/unknown (see `SharedPlayback.isSignedIn`'s doc comment)
        // falls through to the original check, matching today's behaviour.
        guard SharedPlayback.isSignedIn != false else { return false }
        return resolved(for: configuration, at: Date()) == nil
    }

    /// Turns the user's configuration into the entry to render.
    ///
    /// Returns `nil` for `.nowPlaying`, and for any pinned selection that can't be
    /// satisfied (queue empty, book no longer published) — the caller then falls through
    /// to the live session, a more useful widget than a card explaining why it's empty.
    private func resolved(for configuration: SelectWidgetContentIntent, at date: Date) -> PlaybackEntry? {
        // PL-17 (docs/design-review.md, follow-up): checked before the pinned-book
        // lookup below, for every mode that can pin (Up Next and a specific book) — a
        // signed-out widget must not keep showing a previous account's book just
        // because `SharedLibrary` hasn't been emptied yet (e.g. the app was killed
        // mid sign-out teardown). `nil` (unknown/legacy — see `SharedPlayback
        // .isSignedIn`'s doc comment) intentionally falls through unchanged: only a
        // definite `false` blocks the pin, matching how `resolvePlaybackAndSignedIn`
        // treats the same flag just below. Callers (`snapshot(for:in:)`,
        // `timeline(for:in:)`) already read `nil` here as "fall back to the live
        // session", which lands them on the fallback entry's own signed-out empty
        // state via `resolvePlaybackAndSignedIn`.
        guard SharedPlayback.isSignedIn != false else { return nil }
        let payload = SharedLibrary.read()
        let pinned: SharedLibrary.PinnableBook?
        // W1 (REVIEW_2026-09-04_UI.md Pass 4): the mode is carried onto the entry now, so
        // the view can label a pinned tile honestly instead of saying "NOW PLAYING".
        let source: PlaybackEntry.PinnedSource
        switch configuration.mode {
        case .nowPlaying:
            return nil
        case .upNext:
            pinned = payload.upNextIds.first.flatMap { id in payload.books.first { $0.id == id } }
            source = .upNext
        case .specificBook:
            pinned = configuration.book.flatMap { entity in payload.books.first { $0.id == entity.id } }
            source = .specificBook
        }
        guard let pinned else { return nil }

        // If the pinned book happens to be what's actually playing, prefer the live
        // snapshot — it has a current position and real transport state, where the
        // published record is only as fresh as the last publish.
        if let live = SharedPlayback.read(), live.itemId == pinned.id {
            return PlaybackEntry(date: date, snapshot: live)
        }

        return PlaybackEntry(
            date: date,
            snapshot: SharedPlayback.Snapshot(
                itemId: pinned.id, title: pinned.title, author: pinned.author,
                currentTime: pinned.currentTime, duration: pinned.duration,
                isPlaying: false, updatedAt: pinned.updatedAt),
            pinnedItemId: pinned.id,
            pinnedSource: source)
    }

    func timeline(for configuration: SelectWidgetContentIntent, in context: Context) async -> Timeline<PlaybackEntry> {
        let now = Date()

        // A pinned book is static — nothing advances until the user opens it — so it needs
        // one entry and a slow refresh, not the per-minute progress extrapolation below.
        if let pinnedEntry = resolved(for: configuration, at: now), pinnedEntry.isPinned {
            return Timeline(entries: [pinnedEntry], policy: .after(now.addingTimeInterval(60 * 60)))
        }

        // W9 (REVIEW_2026-09-04_UI.md Pass 4): computed once and stamped onto every
        // fallback entry built below (the empty-session case and both branches of the
        // live-timeline case) so a configured-but-unresolvable pin stays honestly
        // labelled across the whole timeline, not just its first entry.
        let lostPin = isUnresolvedPin(for: configuration)

        let (snapshot, signedIn) = resolvePlaybackAndSignedIn(rawSnapshot: SharedPlayback.read())
        guard let snapshot else {
            var empty = PlaybackEntry(date: now, snapshot: nil)
            empty.isSignedIn = signedIn
            empty.lostPin = lostPin
            return Timeline(entries: [empty], policy: .after(now.addingTimeInterval(60 * 15)))
        }

        // If the snapshot claims playback is active but hasn't been refreshed in a
        // while, the app is very likely no longer running to actually be playing it —
        // e.g. the user force-quit it. `AudioPlayerService` touches this snapshot at
        // least every ~20s during real playback specifically so this check is safe
        // (see `updateCurrentTime`'s periodic touch); a threshold well above that
        // catches "app is gone" without false-positiving on normal jitter. Without
        // this, a terminated app left the widget stuck forever showing a pause icon
        // and a frozen (or wrongly-extrapolated) position — this is that fix.
        let staleThreshold: TimeInterval = 90
        let isStale = now.timeIntervalSince(snapshot.updatedAt) > staleThreshold
        var effectiveSnapshot = snapshot
        if isStale, snapshot.isPlaying {
            effectiveSnapshot.isPlaying = false
        }

        // While playing, generate future entries that advance the position (≈1×) so the
        // widget's progress ticks forward on its own, in step with the lock screen,
        // instead of freezing until the app next writes a snapshot.
        //
        // Cadence is 1 minute, not 30 seconds: at widget scale (a progress bar a few
        // dozen points wide) a 30s step is close to visually identical to a 1min step,
        // but the finer cadence used to mean 61 timeline entries instead of ~31 —
        // roughly 2x the entries for very little visible difference, against the
        // widget extension's tight memory ceiling for the persisted timeline.
        var entries: [PlaybackEntry] = []
        if effectiveSnapshot.isPlaying {
            let rate = effectiveSnapshot.rate ?? 1               // advance at the real speed
            // Polish pass (WG-1): 8 minutes, not 30. After a force-quit mid-playback nothing
            // rewrites the snapshot, so the reload at the end of this window re-reads it and the
            // 90 s staleness check above flips it to paused. (No pre-generated "paused" entry:
            // during real background playback the app refreshes the snapshot but doesn't reload
            // timelines, so such an entry would show paused while the book is playing.)
            let playingWindow = 60 * 8
            for offset in stride(from: 0, through: playingWindow, by: 60) {
                var s = effectiveSnapshot
                s.currentTime = min(effectiveSnapshot.currentTime + Double(offset) * rate, effectiveSnapshot.duration)
                var entry = PlaybackEntry(date: now.addingTimeInterval(Double(offset)), snapshot: s)
                entry.lostPin = lostPin
                entries.append(entry)
            }
        } else {
            var entry = PlaybackEntry(date: now, snapshot: effectiveSnapshot)
            entry.lostPin = lostPin
            entries = [entry]
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 8 + 1)))
    }
}

// MARK: - Dynamic skip icon/label (WATCH-3, follow-up review 14 Aug 2026)
//
// P3-6 (third-pass review, 14 Aug 2026): this used to be a widget-only private
// implementation — the one surface of four that actually reflected the user's real
// skip interval. Now hoisted into `Shared/SkipLabels.swift` (added directly to this
// target's Sources build phase, not hand-duplicated) so the main iOS player and the
// Watch app can share the identical logic instead of each carrying their own
// hardcoded 15/30 glyph and label.

// MARK: - Cassette-styled cover

private struct WidgetCassette: View {
    let size: CGFloat
    /// The pinned book whose cover to draw, or `nil` for the live session's cover file.
    /// Threaded from `PlaybackEntry.pinnedItemId` so a widget pinned to a book that isn't
    /// playing shows that book's art rather than whatever was last played.
    var pinnedItemId: String? = nil
    /// Item 32: threaded from `PlaybackEntry.isGalleryPreview` — true only for the
    /// widget-gallery sample entry. Skips both cover lookups below entirely (no App
    /// Group read for a book that was never actually published) and falls straight to
    /// the placeholder treatment, since this target has no bundled sample cover asset.
    var isGalleryPreview: Bool = false

    /// W11 (REVIEW_2026-09-04_UI.md Pass 4): iOS 18's tinted Home Screen mode
    /// (`.accented`) and Lock Screen's `.vibrant` mode desaturate a widget's own
    /// non-accentable content to the system's tint automatically — but a full-color
    /// JPEG cover is exactly the kind of content that can look broken (wrong hue mixed
    /// with the system's own tint math) if left to that default rather than explicitly
    /// handled. Forcing `.saturation(0)` below when not `.fullColor` is the deliberate,
    /// explicit choice — belt-and-suspenders alongside whatever the system already does
    /// for photos — so the cover always degrades to a clean grayscale silhouette under
    /// tinting instead of relying on unverified default behavior. Genuinely unverifiable
    /// from here (no way to render a tinted Home Screen or a Lock Screen from the CLI).
    ///
    /// PS-1 (docs/visual-design-review.md, Round V2): that assumption was wrong for
    /// `.accented`. Apple's `WidgetRenderingMode.accented` page says the system treats the
    /// widget's views "as if they were template images … preserving the view's alpha
    /// channel", so an opaque cover became a flat tinted square whatever its saturation.
    /// On iOS 18+ the cover now opts out with `widgetAccentedRenderingMode(.accentedDesaturated)`
    /// (iOS 18.0, Apple docs `Image/widgetAccentedRenderingMode(_:)`), which keeps the
    /// artwork's detail and tints it. `.saturation(0)` stays only for iOS 17.6–17.x, which
    /// has no tinted Home Screen but does render accessory widgets `.vibrant`.
    @Environment(\.widgetRenderingMode) private var renderingMode

    @ViewBuilder private func coverImage(_ ui: UIImage) -> some View {
        if #available(iOS 18.0, *) {
            // `resizable()` first: `widgetAccentedRenderingMode` is on `Image` but returns
            // `some View`.
            Image(uiImage: ui)
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .aspectRatio(contentMode: .fill)
        } else {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
                .saturation(renderingMode == .fullColor ? 1 : 0)
        }
    }

    // §9.1 (REDESIGN_PROPOSAL_2026-08-26.md): this used to be a `ZStack(alignment:
    // .bottom)` with the band drawn *over* the cover — the exact pattern `CassetteTile`
    // (RetroComponents.swift) was fixed to move away from in D1b, just never ported to
    // the widget. At `.systemSmall` the old `max(16, size * 0.26)` band occluded ~26%
    // of the cover, and on a Home Screen widget the cover is the entire visual payload
    // (no title text to fall back on), so that's the worst place in the app to be doing
    // it. Now a sibling strip beneath the cover, same as the phone tile: the cover
    // renders full-width and unoccluded, sized to fill what's left of the square after
    // the band, instead of bleeding under it.
    private var bandHeight: CGFloat { max(10, size * 0.14) }

    var body: some View {
        // Read the cover straight from the App Group container file at render time,
        // rather than from the timeline entry — the cover doesn't change between
        // entries (only on track change), so there's no reason to carry it on each one.
        // See SharedPlayback.writeCover/readCover, and SharedLibrary.writeCover for the
        // per-book files the app publishes for pinnable books.
        let data = Self.coverData(pinnedItemId: pinnedItemId, isGalleryPreview: isGalleryPreview)
        VStack(spacing: 0) {
            Group {
                if let data, let ui = UIImage(data: data) {
                    coverImage(ui)
                        // W10 (REVIEW_2026-09-04_UI.md Pass 4): cover art on a Home
                        // Screen widget is visible without unlocking the phone at all —
                        // see `accessoryRectangular`'s title for the same App-Lock
                        // inconsistency and why this is unconditional rather than gated.
                        .privacySensitive()
                } else {
                    Retro.surface.overlay(
                        Image(systemName: "book.closed.fill").foregroundStyle(Retro.muted)
                    )
                }
            }
            .frame(width: size, height: size - bandHeight)
            .clipped()

            HStack(spacing: 5) {
                hub
                // W8 (REVIEW_2026-09-04_UI.md Pass 4): was `cream.opacity(0.25)` over a
                // `.black.opacity(0.5)` band — see `Retro.tapeLine`/`tapeBand` for the
                // measured before/after contrast.
                Rectangle().fill(Retro.tapeLine).frame(height: 2)
                hub
            }
            .padding(.horizontal, 7)
            .frame(height: bandHeight)
            .frame(maxWidth: .infinity)
            .background(Retro.tapeBand)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: WidgetRadius.chip))
        .overlay(RoundedRectangle(cornerRadius: WidgetRadius.chip).strokeBorder(Retro.cream.opacity(0.16), lineWidth: 1))
    }

    private var hub: some View {
        Circle()
            .fill(Retro.surface)
            .overlay(Circle().strokeBorder(Retro.cream.opacity(0.5), lineWidth: 1.5))
            .overlay(Circle().fill(Retro.cream.opacity(0.8)).frame(width: 3, height: 3))
            .frame(width: max(8, bandHeight * 0.75), height: max(8, bandHeight * 0.75))
    }

    /// Item 19: which cover file (if any) to draw for this cassette, pulled out as its own
    /// small function so the rule is stated once rather than inline in `body`.
    ///
    /// The bug: `pinnedItemId.flatMap { SharedLibrary.readCover(for: $0) } ??
    /// SharedPlayback.readCover()` treated "this pinned book has no cover of its own" the
    /// same as "there's no pin at all" — `flatMap` returns `nil` either way, so a pinned
    /// widget whose book had never had a cover published for it silently fell through to
    /// `SharedPlayback.readCover()`, the CURRENTLY PLAYING book's cover file, and showed
    /// the wrong book's art. A pinned widget must never draw another book's cover: when
    /// `pinnedItemId` is set, the only acceptable outcomes are "that book's cover" or "no
    /// data" (the view's existing `Retro.surface` + `book.closed.fill` placeholder below),
    /// never a fallback to whatever happens to be loaded in the live session.
    ///
    /// Untestable from `ShelfHeadTests`: this type lives in the widget extension module,
    /// which that test target cannot `@testable import`.
    static func coverData(pinnedItemId: String?, isGalleryPreview: Bool) -> Data? {
        guard !isGalleryPreview else { return nil }
        guard let pinnedItemId else { return SharedPlayback.readCover() }
        return SharedLibrary.readCover(for: pinnedItemId)
    }
}

// MARK: - Shared bits

private func timeString(_ seconds: Double) -> String {
    // Polish pass (CR-1): Int(NaN/∞) traps.
    let total = seconds.isFinite ? max(0, Int(min(seconds, 1e9))) : 0
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private struct ProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // W8 (REVIEW_2026-09-04_UI.md Pass 4): was `cream.opacity(0.14)`, which
                // in Light measured ≈1.15:1 against the container gradient — see
                // `Retro.progressTrack` for the chosen values and measured ratios.
                Capsule().fill(Retro.progressTrack)
                Capsule().fill(Retro.amber).frame(width: geo.size.width * min(max(progress, 0), 1))
                    // W11 (REVIEW_2026-09-04_UI.md Pass 4): the filled portion is the
                    // widget's one quantitative element — marking it accentable keeps it
                    // rendered in the system's chosen tint (full opacity) under iOS 18's
                    // tinted Home Screen mode instead of falling to the same desaturated
                    // outline tier as the (intentionally unmarked) track behind it.
                    .widgetAccentable()
            }
        }
        .frame(height: 4)
        // AX-8 (docs/design-review.md, Round 4): this bar was an unlabelled VoiceOver
        // stop between the title and the time. Verified at all three call sites
        // (small/medium/large Home Screen widgets) that the text immediately after
        // the bar already states progress as remaining (and, in medium/large,
        // elapsed) time, so hiding the bar here loses no information.
        .accessibilityHidden(true)
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    let diameter: CGFloat
    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                Circle().fill(Retro.amber)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    // Finding 19 (code review, 26 August 2026): was `Retro.bg`, a
                    // "background-as-ink" idiom that reads fine in Dark theme but drops
                    // to ~1.6:1 contrast in Light theme against the default amber fill.
                    // `onAccent` picks black or white based on the live accent instead.
                    .foregroundStyle(Retro.onAccent)
                    .offset(x: isPlaying ? 0 : 1)
            }
            // Finding 20 (code review, 26 August 2026): the small widget's PlayButton
            // was rendered at a 38pt `diameter` — below the 44pt minimum tappable
            // target. `max(44, diameter)` floors both the circle and its tap area at
            // 44pt without shrinking any layout that already passes a larger diameter.
            .frame(width: max(44, diameter), height: max(44, diameter))
            // W5 (REVIEW_2026-09-04_UI.md Pass 4): `TogglePlaybackIntent.perform()`
            // deliberately holds `perform()` open for up to 5s on a cold start
            // (`postDarwinAndAwaitHandling`, `WidgetPlaybackIntents.swift`) so a
            // relaunched app has time to actually resume — but the glyph rendered here
            // comes from the *timeline entry*, which nothing invalidated while that
            // ran. On the common warm path the icon flips in ~25ms and this was
            // invisible; on a cold start the button sat there as an unchanged triangle
            // for the whole window, which reads as a dead tap and invites a second one
            // — exactly the double-tap that immediately re-pauses the book that just
            // started. `.invalidatableContent()` opts this into WidgetKit's standard
            // pending treatment for the duration of the intent.
            .invalidatableContent()
            // W11 (REVIEW_2026-09-04_UI.md Pass 4): the primary transport control —
            // keeps it in the system's accent tint (not the desaturated outline tier)
            // under iOS 18's tinted Home Screen mode.
            .widgetAccentable()
        }
        .buttonStyle(.plain)
        // WATCH-5 (REVIEW_2026-08-12.md): icon-only `Button(intent:)` with
        // `.buttonStyle(.plain)` announced nothing to VoiceOver — the Watch target
        // does this correctly everywhere (see `WatchControlButton`'s
        // `.accessibilityLabel`), making the widget's omission an inconsistency
        // rather than a blind spot nobody had already solved in this codebase.
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// W1 (REVIEW_2026-09-04_UI.md Pass 4): the pinned-mode stand-in for `PlayButton`.
///
/// A pinned entry is by construction "book B drawn while book A is the loaded session" —
/// `PlaybackProvider.resolved(for:at:)` returns the live snapshot instead whenever the
/// pinned book *is* the session. So the transport intents must not be drawn on a pinned
/// tile: `TogglePlaybackIntent`/`SkipForwardIntent`/`SkipBackwardIntent`
/// (`WidgetPlaybackIntents.swift`) post *name-only* Darwin notifications, which
/// `AudioPlayerService` (:132-151) handles against whatever it currently has loaded.
/// Tapping the old play triangle on a pinned tile therefore resumed book A while the
/// tile went on showing book B and a play triangle until the next timeline (an hour
/// later, `policy: .after(now + 1h)`).
///
/// Why a link and not a "play THIS book" intent: there is no channel for one from this
/// target. The Darwin names carry no payload, so the widget can't say *which* book; the
/// app-side `PlayAudiobookIntent` (`ShelfHead/Services/PlaybackIntents.swift`) is in the
/// app target (not compiled into this extension) and matches on a spoken *title*, not an
/// id. Wiring a real one would mean a new App-Group request record plus a new observer in
/// `AudioPlayerService` — app-target changes, outside this extension. Until that exists,
/// the honest affordance is navigation: one tap opens this book in the app, where a real
/// Play button lives. Labelled as "open", not "play", so it doesn't make the same promise
/// the old triangle did.
private struct PinnedOpenButton: View {
    @Environment(\.widgetFamily) private var family
    /// `PlaybackEntry.deepLinkURL` — `shelfhead://book/<id>` for this pinned book.
    let url: URL?
    let diameter: CGFloat

    var body: some View {
        // systemSmall has exactly one tap target — the whole widget, via `widgetURL` —
        // and `Link` is inert there, so only medium/large wrap the glyph in one. Both
        // paths end at the same URL: on small, the surrounding `.widgetURL` (which is
        // this same book URL for a pinned entry) handles the tap.
        if family == .systemSmall || url == nil {
            glyph
        } else if let url {
            Link(destination: url) { glyph }
        }
    }

    private var glyph: some View {
        ZStack {
            Circle().fill(Retro.amber)
            Image(systemName: "play.fill")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(Retro.onAccent)
                .offset(x: 1)
        }
        // Same 44pt tap-target floor as `PlayButton` (finding 20, code review 26 Aug 2026).
        .frame(width: max(44, diameter), height: max(44, diameter))
        .contentShape(Rectangle())
        .accessibilityLabel("Open in ShelfHead")
        // W11 (REVIEW_2026-09-04_UI.md Pass 4): this is the pinned-mode stand-in for
        // `PlayButton` — same accent treatment under iOS 18's tinted Home Screen mode.
        .widgetAccentable()
    }
}

// MARK: - Layouts

struct ShelfHeadWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PlaybackEntry

    var body: some View {
        // Makes the whole widget surface tappable → opens the app (not just the
        // title). Interactive buttons on the Home Screen medium widget still take
        // precedence within their own regions.
        //
        // `preferredColorScheme` mirrors the app's own Settings > Appearance choice
        // (light/dark/system) via the App Group — without it, the widget only ever
        // followed the *system* setting, ignoring a user who'd deliberately forced
        // light or dark in-app (M10).
        content
            // W1 (REVIEW_2026-09-04_UI.md Pass 4): was a hardcoded
            // `shelfhead://nowplaying`, which opened the player on the live book even
            // from a tile pinned to a different one. `entry.deepLinkURL` keeps that URL
            // for every live entry and routes a pinned one to `shelfhead://book/<id>`.
            .widgetURL(entry.deepLinkURL)
            .preferredColorScheme(WidgetTheme.preferredColorScheme)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            // W6 (REVIEW_2026-09-04_UI.md Pass 4): was `AccessoryWidgetBackground()` —
            // the circular "plate" treatment meant for `accessoryCircular` just below.
            // On rectangular it drew a filled rounded rect behind three lines of text,
            // heavier than the system's own Lock Screen widgets sitting beside it.
            // `.clear` matches what `accessoryInline` already does.
            accessoryRectangular.containerBackground(.clear, for: .widget)
        case .accessoryCircular:
            accessoryCircular.containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline:
            accessoryInline.containerBackground(.clear, for: .widget)
        default:
            homeScreen
                // W4 (REVIEW_2026-09-04_UI.md Pass 4): the Home Screen families are a
                // fixed-size box (unlike a scrolling app screen), so letting text scale
                // without limit at the largest accessibility sizes would overflow the
                // tile rather than just wrap. Same ceiling `PlayerView` already uses at
                // `.dynamicTypeSize(...DynamicTypeSize.accessibility1)` (PlayerView.swift
                // :2016) for the same reason. The three accessory families are already
                // fine (real text styles) and deliberately excluded from this cap.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Retro.card, Retro.bg], startPoint: .top, endPoint: .bottom)
                }
        }
    }

    @ViewBuilder
    private var homeScreen: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall: small(snapshot)
            case .systemLarge: large(snapshot)
            default:           medium(snapshot)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Lock Screen (accessory) families

    @ViewBuilder
    private var accessoryRectangular: some View {
        Group {
            if let s = entry.snapshot {
                VStack(alignment: .leading, spacing: 3) {
                    // Cassette glyph + title picks up the Lock Screen accent tint,
                    // echoing the app's tape-deck identity.
                    Label {
                        Text(s.title).font(.headline).lineLimit(1)
                            // W10 (REVIEW_2026-09-04_UI.md Pass 4): App Lock
                            // (`AppLockManager`) ships as a feature — a user who turned
                            // on Face ID specifically so nobody sees their library
                            // still had the current title readable from a LOCKED
                            // phone's Lock Screen. `AppLockManager`'s own enabled flag
                            // is stored in `UserDefaults.standard` (`SettingsStore
                            // .appLockEnabled`), not mirrored into the App Group the
                            // way `settings_appearance`/`settings_accentColor` are, so
                            // gating this on it isn't available from this target
                            // without an app-side change — out of scope for a
                            // widget-only pass. Applied unconditionally instead.
                            .privacySensitive()
                    } icon: {
                        // W1 (REVIEW_2026-09-04_UI.md Pass 4): the accessory families
                        // carry no "NOW PLAYING" eyebrow to correct, but this glyph is
                        // the tile's only state cue and a pinned tile is not the live
                        // session. A pin reads as "a book I put here"; `recordingtape`
                        // (the live case, unchanged) reads as "the tape that's loaded".
                        Image(systemName: entry.isPinned ? "pin.fill" : "recordingtape")
                    }
                    .widgetAccentable()

                    Gauge(value: s.progress) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)

                    Text(s.author.isEmpty
                         ? "-\(timeString(s.duration - s.currentTime)) left"
                         : "\(s.author) · -\(timeString(s.duration - s.currentTime))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // W10: the author name is as identifying as the title.
                        .privacySensitive()
                }
            } else if entry.isSignedIn == false {
                // PL-9 (docs/design-review.md, Round 5): rectangular has room for two
                // short lines — "No tape loaded" alone reads as "nothing played yet",
                // which is the wrong advice for someone who isn't signed in.
                VStack(alignment: .leading, spacing: 2) {
                    Label("Signed out", systemImage: "recordingtape").font(.caption)
                    Text("Open ShelfHead to sign in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Label("No tape loaded", systemImage: "recordingtape").font(.caption)
            }
        }
        // Fill the whole widget so the entire surface (not just the text) taps
        // through to the widgetURL that opens the app.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var accessoryCircular: some View {
        Gauge(value: entry.snapshot?.progress ?? 0) {
            // W1 (REVIEW_2026-09-04_UI.md Pass 4): a pinned entry's `isPlaying` is the
            // provider's hardcoded `false`, so this always fell to `headphones` for a
            // pinned book — indistinguishable from a paused live session. Live cases
            // (`pause.fill` / `headphones`) are untouched.
            //
            // W7 (REVIEW_2026-09-04_UI.md Pass 4): "nothing loaded" (`entry.snapshot ==
            // nil`) and "a book paused at 0:00" used to render pixel-identical — empty
            // ring, `headphones` glyph either way — even though the accessibility label
            // just below already told them apart ("Not playing" vs "«title», paused, 0
            // percent"). `recordingtape` for the true-empty case matches every other
            // empty state in this file (`accessoryRectangular`'s "No tape loaded",
            // `accessoryInline`'s "Not playing", `emptyState`'s icon).
            Image(systemName: entry.isPinned
                  ? "pin.fill"
                  : (entry.snapshot == nil
                     ? "recordingtape"
                     : (entry.snapshot?.isPlaying == true ? "pause.fill" : "headphones")))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        // W7: dims the ring itself, not just the glyph, so the true-empty case reads as
        // visually hollow rather than merely swapping one icon for another.
        .opacity(entry.snapshot == nil ? 0.45 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // P3-18 (third-pass review, 14 Aug 2026): the gauge's label was a bare
        // `Image(systemName:)`, and the whole gauge is made tappable via
        // `.contentShape(Rectangle())` above — with no `accessibilityLabel`, VoiceOver
        // announced only a bare percentage, with nothing to say what it's a percentage
        // OF. Mirrors `accessoryInline`'s own title/status phrasing below.
        // W1 (REVIEW_2026-09-04_UI.md Pass 4): a pinned entry announced "paused" — a
        // playback-state claim about a book that isn't loaded — because `isPlaying` is
        // the provider's hardcoded `false`. Pinned entries now announce why they're here.
        // W9 (REVIEW_2026-09-04_UI.md Pass 4): a lost-pin entry (see `PlaybackEntry
        // .lostPin`) is showing the live session as a fallback — say so instead of
        // announcing an unqualified playing/paused state as if nothing had been asked for.
        .accessibilityLabel(entry.snapshot.map { (s: SharedPlayback.Snapshot) -> String in
            if entry.lostPin {
                let transport = s.isPlaying ? String(localized: "playing", comment: "VoiceOver widget state, lowercase") : String(localized: "paused", comment: "VoiceOver widget state, lowercase")
                return String(localized: "No pinned book available, showing Now Playing: \(s.title), \(transport), \(Int((s.progress * 100).rounded())) percent", comment: "VoiceOver label for a widget. %1$@ is the book title, %2$@ is playing/paused, %3$lld is the progress percentage.")
            }
            let state = entry.isPinned
                ? entry.eyebrow.lowercased()
                : (s.isPlaying ? String(localized: "playing", comment: "VoiceOver widget state, lowercase") : String(localized: "paused", comment: "VoiceOver widget state, lowercase"))
            return String(localized: "\(s.title), \(state), \(Int((s.progress * 100).rounded())) percent", comment: "VoiceOver label for a widget. %1$@ is the book title, %2$@ is the state (playing, paused, up next, pinned), %3$lld is the progress percentage.")
        // PL-9 (docs/design-review.md, Round 5): the glyph itself is unchanged (still
        // "recordingtape", dimmed) for this family — there's no room here to add a
        // second visual cue — but VoiceOver can say what "Not playing" doesn't: why.
        } ?? (entry.isSignedIn == false ? String(localized: "Sign in to ShelfHead") : String(localized: "Not playing")))
    }

    @ViewBuilder
    private var accessoryInline: some View {
        if let s = entry.snapshot {
            // W6 (REVIEW_2026-09-04_UI.md Pass 4): was
            // `"\(s.title) · -\(timeString(...))"` — title first. The inline slot is a
            // single line sharing width with the date above the clock, roughly 25-30
            // characters; real titles run 39-40 characters in this account, so the
            // title ate the whole line and truncated away the remaining time — the one
            // thing this widget adds that the Lock Screen doesn't already show
            // elsewhere. Leading with the time lets the title (visible in full on the
            // rectangular/circular families and in the app) be what truncates instead.
            // PL-12 (docs/design-review.md, Round 5): the glyph follows the pinned state
            // like `accessoryCircular` and `accessoryRectangular` do, so the three Lock
            // Screen widgets agree about the same book.
            Label("-\(timeString(s.duration - s.currentTime)) · \(s.title)",
                  systemImage: entry.isPinned ? "pin.fill" : "recordingtape")
                // W10 (REVIEW_2026-09-04_UI.md Pass 4): see `accessoryRectangular`'s
                // title for why this is unconditional rather than gated on App Lock.
                .privacySensitive()
        } else {
            // PL-9 (docs/design-review.md, Round 5): inline has room for one short line —
            // long enough to say "sign in" instead of the generic "Not playing".
            Label(entry.isSignedIn == false ? "Sign in to ShelfHead" : "Not playing",
                  systemImage: "recordingtape")
        }
    }

    // Square
    private func small(_ s: SharedPlayback.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                WidgetCassette(size: 62, pinnedItemId: entry.pinnedItemId, isGalleryPreview: entry.isGalleryPreview)
                Spacer()
                // W1 (REVIEW_2026-09-04_UI.md Pass 4): a pinned tile drives a book that
                // isn't loaded, so it gets the open affordance rather than transport.
                // The live path is byte-for-byte what it was.
                if entry.isPinned {
                    PinnedOpenButton(url: entry.deepLinkURL, diameter: 38)
                } else {
                    PlayButton(isPlaying: s.isPlaying, diameter: 38)
                }
            }
            // W1 (REVIEW_2026-09-04_UI.md Pass 4): systemSmall carries no eyebrow row of
            // its own, so a pinned small tile would otherwise be indistinguishable from
            // the live one. Wrapping title (+ the pinned eyebrow) in a tight inner stack
            // rather than adding a sibling at the outer `spacing: 8` keeps the extra line
            // to ~12pt on the one tile that needs it. In the live case this stack holds a
            // single child and the outer layout is unchanged.
            // W9 (REVIEW_2026-09-04_UI.md Pass 4): also shown for a lost pin (`entry
            // .lostPin`), even though `isPinned` is false there — a lost pin still needs
            // this row to say "NO PIN SET" instead of silently looking like the
            // unconfigured live tile.
            VStack(alignment: .leading, spacing: 2) {
                if entry.isPinned || entry.lostPin {
                    Text(entry.eyebrow)
                        // W4 (REVIEW_2026-09-04_UI.md Pass 4): scales with Dynamic Type
                        // now; base size (8pt) is unchanged, so default rendering is
                        // identical. See `homeScreen`'s `.dynamicTypeSize` cap for why
                        // this can't grow without bound in a fixed-size tile.
                        .widgetScaledFont(8, weight: .heavy, design: .rounded, relativeTo: .caption2)
                        .tracking(WidgetText.tracking(1.5))
                        // U1 (REVIEW_2026-08-20_UI_SECURITY.md): `amberText`, not raw
                        // `amber` — same contrast-safe token the other eyebrows use.
                        .foregroundStyle(Retro.amberText)
                        .lineLimit(1)
                }
                Text(s.title)
                    .widgetScaledFont(13, weight: .bold, design: .rounded, relativeTo: .subheadline)
                    .foregroundStyle(Retro.cream)
                    .lineLimit(2)
                    // W10 (REVIEW_2026-09-04_UI.md Pass 4): "consider the Home Screen"
                    // widgets too — a Home Screen tile is visible without unlocking the
                    // phone at all, the same App-Lock inconsistency as the Lock Screen
                    // families (see `accessoryRectangular`'s title for the gating note).
                    .privacySensitive()
                    // StandBy pass: the small tile's only text line — without this it
                    // fell to the system's default outline tier in StandBy Night Mode
                    // (`.accented`), which read too faint next to the accented PlayButton
                    // and progress bar beside it.
                    .widgetAccentable()
            }
            Spacer(minLength: 0)
            ProgressBar(progress: s.progress)
            Text("-\(timeString(s.duration - s.currentTime))")
                .widgetScaledFont(9, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                .foregroundStyle(Retro.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // Wide — tape-deck strip
    private func medium(_ s: SharedPlayback.Snapshot) -> some View {
        HStack(spacing: 14) {
            WidgetCassette(size: 84, pinnedItemId: entry.pinnedItemId, isGalleryPreview: entry.isGalleryPreview)

            VStack(alignment: .leading, spacing: 5) {
                // W1 (REVIEW_2026-09-04_UI.md Pass 4): was a hardcoded "NOW PLAYING"
                // drawn over pinned books too. `entry.eyebrow` still returns exactly
                // "NOW PLAYING" for every live entry — same string, same styling.
                Text(entry.eyebrow)
                    // W4 (REVIEW_2026-09-04_UI.md Pass 4): base sizes unchanged
                    // throughout — only scaling behavior is new.
                    .widgetScaledFont(9, weight: .heavy, design: .rounded, relativeTo: .caption2)
                    .tracking(WidgetText.tracking(2))
                    // U1/U2 (REVIEW_2026-08-20_UI_SECURITY.md): raw amber + 0.85 opacity
                    // measured 1.70:1 in Light. `amberText` (no opacity — it has zero
                    // headroom for one) is the contrast-safe token.
                    .foregroundStyle(Retro.amberText)
                Text(s.title)
                    .widgetScaledFont(15, weight: .bold, design: .rounded, relativeTo: .subheadline)
                    .foregroundStyle(Retro.cream)
                    .lineLimit(2)
                    // W10 (REVIEW_2026-09-04_UI.md Pass 4): see `small(_:)`'s title.
                    .privacySensitive()
                Text(s.author)
                    .widgetScaledFont(11, relativeTo: .caption)
                    .foregroundStyle(Retro.muted)
                    .lineLimit(1)
                    .privacySensitive()
                Spacer(minLength: 2)
                ProgressBar(progress: s.progress)
                HStack {
                    Text(timeString(s.currentTime))
                    Spacer()
                    Text("-\(timeString(s.duration - s.currentTime))")
                }
                .widgetScaledFont(10, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                .foregroundStyle(Retro.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isPinned {
                // W1 (REVIEW_2026-09-04_UI.md Pass 4): the skip buttons skipped inside the
                // *live* book, not the pinned one — see `PinnedOpenButton`. Not drawn.
                PinnedOpenButton(url: entry.deepLinkURL, diameter: 46)
            } else {
                VStack(spacing: 10) {
                    PlayButton(isPlaying: s.isPlaying, diameter: 46)
                    // Finding 20 (code review, 26 August 2026): spacing tightened from 16
                    // to 4 to absorb the two skip buttons growing to 44pt tap targets below
                    // (they previously rendered at their un-framed glyph size, ~18-20pt).
                    HStack(spacing: 4) {
                        Button(intent: SkipBackwardIntent()) {
                            Image(systemName: SkipLabels.symbolName(backward: true, seconds: s.skipBackwardInterval))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Retro.cream.opacity(0.7))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                // W5 (REVIEW_2026-09-04_UI.md Pass 4): the skip icons
                                // never change on tap — the review's point was exactly
                                // that this makes a real tap indistinguishable from a
                                // dead one. `.invalidatableContent()` still gives it
                                // WidgetKit's pending treatment for the intent's
                                // duration, so a tap reads as "acknowledged" even when
                                // there's nothing else here to visibly change.
                                .invalidatableContent()
                        }
                        .buttonStyle(.plain)
                        // WATCH-5: icon-only skip buttons had no accessibility label.
                        // WATCH-3: label (and the icon above) now reflect the real
                        // configured skip interval instead of a hardcoded 15/30.
                        .accessibilityLabel(SkipLabels.accessibilityLabel(backward: true, seconds: s.skipBackwardInterval))
                        Button(intent: SkipForwardIntent()) {
                            Image(systemName: SkipLabels.symbolName(backward: false, seconds: s.skipForwardInterval))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Retro.cream.opacity(0.7))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .invalidatableContent()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SkipLabels.accessibilityLabel(backward: false, seconds: s.skipForwardInterval))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
    }

    // Tall — big cover over full transport, for the large Home-Screen slot.
    private func large(_ s: SharedPlayback.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                WidgetCassette(size: 150, pinnedItemId: entry.pinnedItemId, isGalleryPreview: entry.isGalleryPreview)
                Spacer()
            }

            // W1 (REVIEW_2026-09-04_UI.md Pass 4): see `medium(_:)` — identical string
            // for every live entry, honest label for a pinned one.
            Text(entry.eyebrow)
                // W4 (REVIEW_2026-09-04_UI.md Pass 4): base sizes unchanged throughout —
                // only scaling behavior is new.
                .widgetScaledFont(10, weight: .heavy, design: .rounded, relativeTo: .caption)
                .tracking(WidgetText.tracking(2))
                // U1/U2 (REVIEW_2026-08-20_UI_SECURITY.md): raw amber + 0.85 opacity
                // measured 1.70:1 in Light. `amberText` (no opacity — it has zero
                // headroom for one) is the contrast-safe token.
                .foregroundStyle(Retro.amberText)
            Text(s.title)
                .widgetScaledFont(19, weight: .bold, design: .rounded, relativeTo: .title3)
                .foregroundStyle(Retro.cream)
                .lineLimit(2)
                // W10 (REVIEW_2026-09-04_UI.md Pass 4): see `small(_:)`'s title.
                .privacySensitive()
            Text(s.author)
                .widgetScaledFont(13, relativeTo: .subheadline)
                .foregroundStyle(Retro.muted)
                .lineLimit(1)
                .privacySensitive()

            Spacer(minLength: 2)

            ProgressBar(progress: s.progress)
            HStack {
                Text(timeString(s.currentTime))
                Spacer()
                Text("-\(timeString(s.duration - s.currentTime))")
            }
            .widgetScaledFont(11, weight: .semibold, design: .monospaced, relativeTo: .caption)
            .foregroundStyle(Retro.muted)

            if entry.isPinned {
                // W1 (REVIEW_2026-09-04_UI.md Pass 4): the whole transport cluster acted
                // on the live session, not the book drawn above it — see
                // `PinnedOpenButton`. One honest affordance replaces all three.
                HStack {
                    Spacer()
                    PinnedOpenButton(url: entry.deepLinkURL, diameter: 58)
                    Spacer()
                }
                .padding(.top, 2)
            } else {
                HStack {
                    Spacer()
                    Button(intent: SkipBackwardIntent()) {
                        Image(systemName: SkipLabels.symbolName(backward: true, seconds: s.skipBackwardInterval))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Retro.cream.opacity(0.75))
                            // Finding 20 (code review, 26 August 2026): un-framed glyph was
                            // only ~22-26pt of actual tap area — floored at 44pt.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            // W5 (REVIEW_2026-09-04_UI.md Pass 4): see `medium(_:)`'s
                            // identical skip buttons for why this is here.
                            .invalidatableContent()
                    }
                    .buttonStyle(.plain)
                    // WATCH-5 (REVIEW_2026-08-12.md): icon-only skip buttons had no
                    // accessibility label — see the identical fix in `medium(_:)`.
                    // WATCH-3 (follow-up review, 14 Aug 2026): label (and icon above) now
                    // reflect the real configured skip interval instead of a hardcoded 15/30.
                    .accessibilityLabel(SkipLabels.accessibilityLabel(backward: true, seconds: s.skipBackwardInterval))
                    Spacer()
                    PlayButton(isPlaying: s.isPlaying, diameter: 58)
                    Spacer()
                    Button(intent: SkipForwardIntent()) {
                        Image(systemName: SkipLabels.symbolName(backward: false, seconds: s.skipForwardInterval))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Retro.cream.opacity(0.75))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .invalidatableContent()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SkipLabels.accessibilityLabel(backward: false, seconds: s.skipForwardInterval))
                    Spacer()
                }
                .padding(.top, 2)

                // Chapter row: mirrors the transport row above it, but chapter-relative
                // rather than time-relative. Only drawn when there's a chapter to name —
                // a chapterless book/episode (`s.chapterTitle == nil`) keeps today's
                // layout untouched. Not drawn for a pinned tile, same reason as the
                // transport row just above: these buttons act on the *live* session, not
                // the pinned book drawn at the top of this tile (see `PinnedOpenButton`).
                if let chapterTitle = s.chapterTitle {
                    HStack {
                        Button(intent: PreviousChapterIntent()) {
                            Image(systemName: "backward.end.fill")
                                // VD-7 (docs/design-review.md, Round 4): flanks the chapter
                                // title, which scales (`.caption`), so the glyph scales with
                                // it. 16 pt at the default size; the family's Dynamic Type
                                // cap keeps it inside the 44 pt frame.
                                .widgetScaledFont(16, weight: .semibold, relativeTo: .caption)
                                .foregroundStyle(Retro.cream.opacity(0.75))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .invalidatableContent()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Previous chapter")

                        Text(chapterTitle)
                            .widgetScaledFont(11, relativeTo: .caption)
                            .foregroundStyle(Retro.cream.opacity(0.8))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .invalidatableContent()

                        Button(intent: NextChapterIntent()) {
                            Image(systemName: "forward.end.fill")
                                // VD-7 (docs/design-review.md, Round 4): flanks the chapter
                                // title, which scales (`.caption`), so the glyph scales with
                                // it. 16 pt at the default size; the family's Dynamic Type
                                // cap keeps it inside the 44 pt frame.
                                .widgetScaledFont(16, weight: .semibold, relativeTo: .caption)
                                .foregroundStyle(Retro.cream.opacity(0.75))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .invalidatableContent()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Next chapter")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "recordingtape")
                // VD-7 (docs/design-review.md, Round 4): sits above "No tape loaded"
                // (`.subheadline`), so it scales with it; 26 pt at the default size.
                .widgetScaledFont(26, relativeTo: .subheadline)
                // U1 (REVIEW_2026-08-20_UI_SECURITY.md): raw amber measured 1.87:1 in
                // Light, under the 3:1 non-text floor for this 26pt icon.
                .foregroundStyle(Retro.amberText)
            Text("No tape loaded")
                // W4 (REVIEW_2026-09-04_UI.md Pass 4): base sizes unchanged — only
                // scaling behavior is new.
                .widgetScaledFont(12, weight: .semibold, design: .rounded, relativeTo: .subheadline)
                .foregroundStyle(Retro.cream)
            // PL-9 (docs/design-review.md, Round 5): "Start a book" is the wrong advice
            // for someone who isn't signed in yet — the title above stays the same either
            // way, only this line changes. `nil` (unknown/legacy) keeps the original copy
            // so a signed-in user is never told to sign in — see `SharedPlayback
            // .resolvedSignedIn(hasSnapshot:)`.
            Text(entry.isSignedIn == false ? "Sign in to ShelfHead" : "Start a book in ShelfHead")
                .widgetScaledFont(10, relativeTo: .caption2)
                .foregroundStyle(Retro.muted)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct ShelfHeadWidget: Widget {
    let kind = "ShelfHeadWidget"
    var body: some WidgetConfiguration {
        // The `kind` string is unchanged from the previous `StaticConfiguration`, so
        // widgets already on someone's Home Screen keep working and simply adopt the
        // intent's default (`.nowPlaying`) — which is exactly what they showed before.
        AppIntentConfiguration(kind: kind, intent: SelectWidgetContentIntent.self, provider: PlaybackProvider()) { entry in
            ShelfHeadWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Your current audiobook, tape-deck style. Long-press to pin a specific book.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()   // fill edge-to-edge instead of the default inset border
    }
}

@main
struct ShelfHeadWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShelfHeadWidget()
        // Batch 406: Lock Screen / Dynamic Island Live Activities (ShelfHeadLiveActivities.swift),
        // started and ended by the app's `LiveActivityController`. iOS 16.1+, so no gate.
        SleepTimerLiveActivity()
        DownloadsLiveActivity()
        // N-2: Control Center support, gated to iOS 18+ (deployment target stays 17.6).
        // See ShelfHeadPlaybackControl.swift and ShelfHeadControls.swift.
        if #available(iOS 18.0, *) {
            ShelfHeadPlaybackControl()
            ShelfHeadResumeControl()
            ShelfHeadSleepTimerControl()
            ShelfHeadOpenNowPlayingControl()
        }
    }
}
