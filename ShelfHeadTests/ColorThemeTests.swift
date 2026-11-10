import XCTest
import SwiftUI
import UIKit
@testable import ShelfHead

/// Tests for the theming primitives added in Milestone 5: hex parsing and the
/// contrast-aware "ink on accent" selection.
/// The accent is set through `ThemeStore.shared.accentHex`, never by writing
/// `SettingsKeys.accentColor` into `UserDefaults` directly. `AppTheme.onAccentColor` and
/// friends read `ThemeStore`'s *cached* colours (UI-8), which are recomputed only in
/// `accentHex`'s `didSet` — a raw defaults write leaves the cache holding the previous
/// accent's ink, so the assertion silently measures the wrong colour.
///
/// `@MainActor` because `AppTheme.accentColor`/`onAccentColor`/`accentTextColor`/
/// `accentDarkColor` are main-actor-isolated — they read `ThemeStore.shared`'s cached
/// colours, and `ThemeStore` became `@MainActor` in CRIT-3 step 2 (REVIEW_2026-08-12.md)
/// without this file being rebuilt against it. Applied at the class rather than to the
/// four individual methods the compiler flagged, so a future test touching any other
/// `AppTheme` accessor doesn't hit the same error again.
@MainActor
final class ColorThemeTests: XCTestCase {

    // MARK: - Helpers

    /// Extracts sRGB components from a SwiftUI Color via UIColor.
    private func rgba(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    // MARK: - Color(hex:)

    func testHexParsesSixDigitRGB() {
        let c = rgba(Color(hex: "FF8800"))
        XCTAssertEqual(c.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.g, 0.533, accuracy: 0.01)
        XCTAssertEqual(c.b, 0.0, accuracy: 0.01)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.01)
    }

    func testHexParsesPureColors() {
        XCTAssertEqual(rgba(Color(hex: "000000")).r, 0.0, accuracy: 0.01)
        XCTAssertEqual(rgba(Color(hex: "FFFFFF")).r, 1.0, accuracy: 0.01)
        let red = rgba(Color(hex: "FF0000"))
        XCTAssertEqual(red.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(red.g, 0.0, accuracy: 0.01)
        XCTAssertEqual(red.b, 0.0, accuracy: 0.01)
    }

    func testHexIgnoresLeadingHashAndWhitespace() {
        let withHash = rgba(Color(hex: "#3B82F6"))
        let without = rgba(Color(hex: "3B82F6"))
        XCTAssertEqual(withHash.r, without.r, accuracy: 0.001)
        XCTAssertEqual(withHash.g, without.g, accuracy: 0.001)
        XCTAssertEqual(withHash.b, without.b, accuracy: 0.001)
    }

    func testHexParsesEightDigitARGB() {
        // 80% alpha red.
        let c = rgba(Color(hex: "CCFF0000"))
        XCTAssertEqual(c.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.a, 0.8, accuracy: 0.02)
    }

    // MARK: - AppTheme.onAccentColor (luminance-based ink)

    /// The ink drawn on the accent fill should be dark on light accents and light
    /// on dark accents. We assert via the resolved white/brightness component.
    private func whiteComponent(_ color: Color) -> CGFloat {
        var white: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getWhite(&white, alpha: &alpha)
        return white
    }

    func testOnAccentIsDarkForLightAccent() {
        let original = ThemeStore.shared.accentHex
        defer { ThemeStore.shared.accentHex = original }

        ThemeStore.shared.accentHex = "FFFFFF"   // white accent
        // Dark ink → low white component.
        XCTAssertLessThan(whiteComponent(AppTheme.onAccentColor), 0.5)
    }

    func testOnAccentIsLightForDarkAccent() {
        let original = ThemeStore.shared.accentHex
        defer { ThemeStore.shared.accentHex = original }

        ThemeStore.shared.accentHex = "111827"   // near-black accent
        // Light ink → high white component.
        XCTAssertGreaterThan(whiteComponent(AppTheme.onAccentColor), 0.5)
    }

    func testAmberAccentGetsDarkInk() {
        let original = ThemeStore.shared.accentHex
        defer { ThemeStore.shared.accentHex = original }

        ThemeStore.shared.accentHex = AppTheme.defaultAccentHex
        // The classic amber is bright → dark espresso ink (matches the original design).
        XCTAssertLessThan(whiteComponent(AppTheme.onAccentColor), 0.5)
    }

    // MARK: - Contrast ratio (UI-1 / UI-2, REVIEW_2026-08-12.md)

    /// WCAG contrast ratio between two colors, via the same gamma-corrected luminance
    /// formula `ContrastInk` and `AppTheme` use — this test file intentionally
    /// duplicates rather than reuses `ContrastInk.relativeLuminance` so a regression
    /// that broke the shared helper wouldn't also silently break the test that's
    /// supposed to catch it.
    private func contrastRatio(_ a: Color, _ b: Color) -> Double {
        func luminance(_ c: Color) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(c).getRed(&r, green: &g, blue: &blue, alpha: &alpha)
            func linearize(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linearize(Double(r)) + 0.7152 * linearize(Double(g)) + 0.0722 * linearize(Double(blue))
        }
        let l1 = luminance(a), l2 = luminance(b)
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// UI-2: `onAccentColor` should always pick whichever of black/white ink achieves
    /// higher measured contrast against the accent fill — not just "close enough" via
    /// an arbitrary luminance threshold. This directly pins the review's measured
    /// failures (Teal/Blue/Orange previously chose white ink at 2.5-3.7:1 when black
    /// would have achieved 5.7-8.4:1).
    func testOnAccentPicksTheHigherContrastInk() {
        let original = ThemeStore.shared.accentHex
        defer { ThemeStore.shared.accentHex = original }

        for (name, hex) in AppTheme.accentOptions {
            ThemeStore.shared.accentHex = hex
            let fill = Color(hex: hex)
            let chosenRatio = contrastRatio(AppTheme.onAccentColor, fill)
            let bestPossibleRatio = max(contrastRatio(.white, fill), contrastRatio(Color(white: 0.08), fill))
            XCTAssertEqual(
                chosenRatio, bestPossibleRatio, accuracy: 0.05,
                "\(name) (\(hex)): onAccentColor achieved \(chosenRatio), but \(bestPossibleRatio) was achievable"
            )
        }
    }

    /// UI-1: every selectable accent, used as *text* via `shelfAmberText`, must clear
    /// WCAG AA (4.5:1) against both theme backgrounds. This is what stops a future
    /// swatch addition (or a regression in the darkening factor) from silently
    /// reintroducing an unreadable-in-Light-theme accent.
    func testAccentTextColorMeetsAAOnBothThemeBackgrounds() {
        let original = ThemeStore.shared.accentHex
        defer { ThemeStore.shared.accentHex = original }

        let lightBackground = Color(hex: "F7F2E9")
        let darkBackground = Color(hex: "16110C")

        for (name, hex) in AppTheme.accentOptions {
            ThemeStore.shared.accentHex = hex

            let dynamicUIColor = UIColor(AppTheme.accentTextColor)
            let lightResolved = dynamicUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            let darkResolved = dynamicUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))

            let lightRatio = contrastRatio(Color(uiColor: lightResolved), lightBackground)
            let darkRatio = contrastRatio(Color(uiColor: darkResolved), darkBackground)

            XCTAssertGreaterThanOrEqual(lightRatio, 4.5, "\(name) (\(hex)) fails AA as text on Light background: \(lightRatio):1")
            XCTAssertGreaterThanOrEqual(darkRatio, 4.5, "\(name) (\(hex)) fails AA as text on Dark background: \(darkRatio):1")
        }
    }

    // MARK: - Hue-harmonised secondary palette (F1, REVIEW_2026-09-04_UI.md)

    /// The load-bearing invariant: at the default amber accent, the derived secondary
    /// and emphasis colours must reproduce the literals they replaced *exactly*, so this
    /// change is a no-op for anyone who never picked a custom accent.
    func testDefaultAccentReproducesTheOriginalLiterals() {
        for anchor in [AppTheme.SecondaryAnchor.accentLight, AppTheme.SecondaryAnchor.accentDark,
                       AppTheme.SecondaryAnchor.orangeLight, AppTheme.SecondaryAnchor.orangeDark] {
            XCTAssertEqual(
                AppTheme.hueHarmonizedHex(anchorHex: anchor, accentHex: AppTheme.defaultAccentHex),
                anchor,
                "the default accent must leave \(anchor) untouched")
        }
    }

    func testHarmonizedHueTracksTheAccentsOffset() {
        // Indigo is ~230°, the default amber ~38°, so the teal (~174°) should move by
        // roughly the same delta rather than staying teal.
        let derived = AppTheme.hueHarmonizedHex(
            anchorHex: AppTheme.SecondaryAnchor.accentLight, accentHex: "6366F1")
        XCTAssertNotEqual(derived, AppTheme.SecondaryAnchor.accentLight)

        func hue(_ hex: String) -> CGFloat {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(Color(hex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return h
        }
        func wrapped(_ d: CGFloat) -> CGFloat {
            var d = d.truncatingRemainder(dividingBy: 1)
            if d < 0 { d += 1 }
            return d
        }
        let accentDelta = wrapped(hue("6366F1") - hue(AppTheme.defaultAccentHex))
        let anchorDelta = wrapped(hue(derived) - hue(AppTheme.SecondaryAnchor.accentLight))
        XCTAssertEqual(Double(accentDelta), Double(anchorDelta), accuracy: 0.01,
                       "the anchor should rotate by the same delta the accent did")
    }

    func testHarmonizationPreservesAnchorSaturationAndBrightness() {
        // Character is carried by S/B — teal stays the muted one, orange the vivid one —
        // so only hue may move.
        func sb(_ hex: String) -> (s: CGFloat, b: CGFloat) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(Color(hex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return (s, b)
        }
        for anchor in [AppTheme.SecondaryAnchor.accentLight, AppTheme.SecondaryAnchor.orangeDark] {
            let before = sb(anchor)
            let after = sb(AppTheme.hueHarmonizedHex(anchorHex: anchor, accentHex: "6366F1"))
            XCTAssertEqual(Double(before.s), Double(after.s), accuracy: 0.02)
            XCTAssertEqual(Double(before.b), Double(after.b), accuracy: 0.02)
        }
    }

    func testAchromaticAccentLeavesTheAnchorAlone() {
        // A grey/white accent has no meaningful hue; rotating by an arbitrary amount
        // would be worse than not rotating at all.
        for accent in ["FFFFFF", "808080", "000000"] {
            XCTAssertEqual(
                AppTheme.hueHarmonizedHex(anchorHex: AppTheme.SecondaryAnchor.accentLight, accentHex: accent),
                AppTheme.SecondaryAnchor.accentLight,
                "achromatic accent \(accent) should not rotate the anchor")
        }
    }

    /// The derived secondary must still clear AA as text on both backgrounds for every
    /// selectable accent — the same guarantee `testAccentTextColorMeetsAAOnBothTheme
    /// Backgrounds` gives the primary, now that this colour moves too.
    func testDerivedSecondaryTextMeetsAAForEveryAccent() {
        let lightBackground = Color(hex: "F7F2E9")
        let darkBackground = Color(hex: "16110C")

        for (name, hex) in AppTheme.accentOptions {
            let dynamic = UIColor(AppTheme.computeSecondaryAccentTextColor(accentHex: hex))
            let light = dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            let dark = dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))

            XCTAssertGreaterThanOrEqual(
                contrastRatio(Color(uiColor: light), lightBackground), 4.5,
                "\(name): derived secondary fails AA on Light")
            XCTAssertGreaterThanOrEqual(
                contrastRatio(Color(uiColor: dark), darkBackground), 4.5,
                "\(name): derived secondary fails AA on Dark")
        }
    }

    // MARK: - AppTheme accessors

    func testAccentDefaultsToAmberWhenUnset() {
        let original = ThemeStore.shared.accentHex
        defer { ThemeStore.shared.accentHex = original }

        ThemeStore.shared.accentHex = AppTheme.defaultAccentHex
        XCTAssertEqual(AppTheme.accentHex, AppTheme.defaultAccentHex)
    }

    /// `AppTheme.appearance` falls back to `.dark` for any stored value it can't map to
    /// an `AppAppearance` — the absent case (`string(forKey:) ?? ""`) and the
    /// unrecognised case both land on the same `AppAppearance(rawValue:) ?? .dark`.
    ///
    /// This used to assert the absent case via `removeObject(forKey:)`, which is not
    /// deterministic here: `settings_appearance` is written by a *different process run*
    /// every time the user changes the theme (`ThemeStore.appearanceRaw.didSet`), and an
    /// in-process removal doesn't reliably beat cfprefsd re-reading the domain from disk.
    /// The result was a test that passed only on a simulator whose theme had never been
    /// changed — green on fresh CI runners, red on any working device, failing with
    /// `("light") is not equal to ("dark")`. Verified 4 September 2026: the failure
    /// reproduces whenever the key exists on the device beforehand, and `synchronize()`
    /// does not fix it. Asserting the unrecognised case exercises the identical fallback
    /// without depending on removal winning that race.
    func testAppearanceDefaultsToDark() {
        let original = UserDefaults.standard.string(forKey: SettingsKeys.appearance)
        defer { UserDefaults.standard.set(original, forKey: SettingsKeys.appearance) }

        UserDefaults.standard.set("not-an-appearance", forKey: SettingsKeys.appearance)
        XCTAssertEqual(AppTheme.appearance, .dark)
    }

    func testAppearanceColorSchemeMapping() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
}
