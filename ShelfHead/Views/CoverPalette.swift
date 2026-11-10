import SwiftUI
import UIKit

// Extracted out of ShareCard.swift (which had grown to ~2000 lines and become
// load-bearing for more than just the share composer — the full player's per-chapter
// background tint (F8) and Year in Review both depend on `CoverPalette`/`normalizedUp()`
// too). Splitting this out makes those cross-feature dependencies visible at a glance
// instead of buried inside a file whose name suggests it's share-card-only.

// MARK: - Fixed brand fallback colours

private enum Card {
    static let bg      = Color(red: 22/255,  green: 17/255,  blue: 12/255)
    static let panel   = Color(red: 36/255,  green: 27/255,  blue: 18/255)
    static let amber   = Color(red: 232/255, green: 168/255, blue: 56/255)
    static let orange  = Color(red: 224/255, green: 97/255,  blue: 47/255)
    static let cream   = Color(red: 244/255, green: 233/255, blue: 214/255)
    static let ink     = Color(red: 26/255,  green: 22/255,  blue: 16/255)
    static let muted   = Color(red: 168/255, green: 145/255, blue: 119/255)
    static let highlight = Color(red: 246/255, green: 214/255, blue: 150/255)
}

// MARK: - Cover palette (dual-accent)

struct CoverPalette: Sendable {
    var background: Color
    var backgroundDeep: Color
    var primaryAccent: Color
    var secondaryAccent: Color
    var highlight: Color
    var text: Color
    var textMuted: Color
    var onPrimaryAccent: Color
    var onSecondaryAccent: Color
    var isDark: Bool

    static let brand = CoverPalette(
        background: Card.panel,
        backgroundDeep: Card.bg,
        primaryAccent: Card.amber,
        secondaryAccent: Card.orange,
        highlight: Card.highlight,
        text: Card.cream,
        textMuted: Card.muted,
        onPrimaryAccent: Card.ink,
        onSecondaryAccent: Card.cream,
        isDark: true
    )

    /// Readable ink for a given solid fill colour. Delegates to the shared
    /// `ContrastInk` helper (Extensions.swift) so this and `AppTheme.onAccentColor`
    /// agree on both the luminance formula and the ink-selection rule — this file
    /// previously ran its own non-gamma-corrected `0.299/0.587/0.114` luminance with an
    /// arbitrary `0.62` cutoff, the same class of bug as UI-2's `onAccentColor` fix.
    static func ink(on color: Color) -> Color {
        ContrastInk.bestInk(forBackgroundLuminance: Double(luminance(UIColor(color))))
    }

    /// A single foreground that reads acceptably across BOTH accents — used for text on a
    /// primary→secondary gradient fill (where `onPrimaryAccent` alone can fail on the far end).
    var onAccentGradient: Color {
        let dark = Color(white: 0.08), light = Color(white: 0.98)
        let lightGap = Self.minLumaGap(light, [primaryAccent, secondaryAccent])
        let darkGap = Self.minLumaGap(dark, [primaryAccent, secondaryAccent])
        return lightGap >= darkGap ? light : dark
    }

    private static func minLumaGap(_ ink: Color, _ colors: [Color]) -> CGFloat {
        let li = luminance(UIColor(ink))
        return colors.map { abs(li - luminance(UIColor($0))) }.min() ?? 0
    }

    /// WCAG relative luminance (gamma-corrected), via the shared `ContrastInk` formula.
    /// Previously used the non-linear-luma weights (`0.299/0.587/0.114`) applied
    /// directly to non-linearized components — the same under/over-weighting bug as the
    /// old `AppTheme.onAccentColor` (see UI-2), just with a different (also arbitrary)
    /// `0.62` threshold at the two call sites below and in `ink(on:)` above.
    private static func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CGFloat(ContrastInk.relativeLuminance(r: Double(r), g: Double(g), b: Double(b)))
    }

    private static func hsb(_ c: UIColor) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (h, s, v)
    }

    /// From the Cover deck skin (Batch 466): the body and key colours, top to bottom, as
    /// mid-tones of the cover's main hue. `background`/`backgroundDeep` sit at 16% and 7%
    /// brightness, which read as black on the deck (device test DS2), so the deck uses its
    /// own brighter tones. The key's ink comes from `ink(on:)`.
    var deckBodyTones: [Color] { [tone(saturation: 0.6, brightness: 0.34), tone(saturation: 0.65, brightness: 0.20)] }
    // 52% → 44%: a wider span crosses the point where neither ink reaches 3:1 on yellow-green
    // covers; this one clears it for every hue (`DeckSkinTests`).
    var deckKeyTones: [Color] { [tone(saturation: 0.55, brightness: 0.52), tone(saturation: 0.6, brightness: 0.44)] }

    /// The primary accent's hue at a scaled saturation and a fixed brightness.
    private func tone(saturation scale: CGFloat, brightness: CGFloat) -> Color {
        let c = Self.hsb(UIColor(primaryAccent))
        return Color(uiColor: UIColor(hue: c.h, saturation: min(c.s * scale, 1), brightness: brightness, alpha: 1))
    }

    /// Shift the accent hues by a fraction of the wheel (used by the seed for variation).
    func hueShifted(_ frac: Double) -> CoverPalette {
        guard frac != 0 else { return self }
        func shift(_ color: Color) -> Color {
            let c = Self.hsb(UIColor(color))
            var h = c.h + CGFloat(frac)
            h = h.truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
            return Color(uiColor: UIColor(hue: h, saturation: c.s, brightness: c.v, alpha: 1))
        }
        var out = self
        out.primaryAccent = shift(primaryAccent)
        out.secondaryAccent = shift(secondaryAccent)
        out.highlight = shift(highlight)
        // Recompute the on-accent inks for the shifted colours (contrast can flip).
        out.onPrimaryAccent = Self.ink(on: out.primaryAccent)
        out.onSecondaryAccent = Self.ink(on: out.secondaryAccent)
        return out
    }

    /// Accepts a `CGImage` (not `UIImage`) so callers can hand it to a detached task
    /// without moving a non-Sendable `UIImage` across an actor boundary. Callers should
    /// pass `uiImage.normalizedUp().cgImage`.
    static func from(_ cg: CGImage?) -> CoverPalette {
        guard let cg else { return .brand }
        let w = 44, h = 44
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .brand }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var buckets: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]); if a < 16 { continue }
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let key = (Int(r) >> 5) << 10 | (Int(g) >> 5) << 5 | (Int(b) >> 5)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.count += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        guard !buckets.isEmpty else { return .brand }

        // Average each bucket, score by prominence × colourfulness.
        struct Swatch { var color: UIColor; var hsb: (h: CGFloat, s: CGFloat, v: CGFloat); var score: Double }
        var swatches: [Swatch] = []
        for (_, e) in buckets {
            let ui = UIColor(red: e.r / Double(e.count) / 255, green: e.g / Double(e.count) / 255,
                             blue: e.b / Double(e.count) / 255, alpha: 1)
            let c = hsb(ui)
            let score = Double(e.count) * (0.25 + Double(c.s)) * (0.35 + Double(c.v))
            swatches.append(Swatch(color: ui, hsb: c, score: score))
        }
        swatches.sort { $0.score > $1.score }

        // Primary = the most prominent colourful swatch (fall back to overall most prominent).
        let primarySw = swatches.first(where: { $0.hsb.s >= 0.18 }) ?? swatches[0]
        let ph = primarySw.hsb.h
        // Secondary = a distinct hue from the remaining swatches, else the complement.
        let secondarySw = swatches.first(where: {
            $0.hsb.s >= 0.16 && abs(hueDistance($0.hsb.h, ph)) > 0.12
        })

        func color(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> UIColor {
            UIColor(hue: h, saturation: min(max(s, 0), 1), brightness: min(max(v, 0), 1), alpha: 1)
        }

        let primaryUI = color(ph, max(primarySw.hsb.s, 0.6), max(primarySw.hsb.v, 0.82))
        let secondaryUI: UIColor
        if let sec = secondarySw {
            secondaryUI = color(sec.hsb.h, max(sec.hsb.s, 0.55), max(sec.hsb.v, 0.82))
        } else {
            var comp = ph + 0.5; comp = comp.truncatingRemainder(dividingBy: 1)
            secondaryUI = color(comp, 0.7, 0.9)
        }
        let highlightUI = color(ph, max(primarySw.hsb.s * 0.5, 0.3), 1.0)
        let backgroundUI = color(ph, min(primarySw.hsb.s * 0.7 + 0.15, 0.55), 0.16)
        let backgroundDeepUI = color(ph, min(primarySw.hsb.s * 0.6 + 0.1, 0.5), 0.07)
        let onPrimary = ContrastInk.bestInk(forBackgroundLuminance: Double(luminance(primaryUI)))
        let onSecondary = ContrastInk.bestInk(forBackgroundLuminance: Double(luminance(secondaryUI)))

        return CoverPalette(
            background: Color(uiColor: backgroundUI),
            backgroundDeep: Color(uiColor: backgroundDeepUI),
            primaryAccent: Color(uiColor: primaryUI),
            secondaryAccent: Color(uiColor: secondaryUI),
            highlight: Color(uiColor: highlightUI),
            text: Color(white: 0.97),
            textMuted: Color(white: 0.68),
            onPrimaryAccent: onPrimary,
            onSecondaryAccent: onSecondary,
            isDark: true
        )
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = abs(a - b).truncatingRemainder(dividingBy: 1)
        if d > 0.5 { d = 1 - d }
        return d
    }
}

// Non-private (F8): PlayerView.swift needs normalizedUp() too, for its per-chapter
// cover-palette background tint — see PlayerView.backgroundView.
extension UIImage {
    /// Redraw with orientation baked in so raw CoreGraphics sampling isn't sideways.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return out
    }
}
