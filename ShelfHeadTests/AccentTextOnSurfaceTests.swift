import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (colorize): `shelfAmberTextOnSurface` clears WCAG AA (4.5:1) on
/// `shelfSurface` and `shelfCard` for every selectable accent in both appearances.
final class AccentTextOnSurfaceTests: XCTestCase {
    private func luminance(_ hex: String) -> Double {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&v)
        return ContrastInk.relativeLuminance(r: Double((v >> 16) & 0xFF) / 255,
                                             g: Double((v >> 8) & 0xFF) / 255,
                                             b: Double(v & 0xFF) / 255)
    }

    private func ratio(_ a: String, _ b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testClearsAAOnSurfaceAndCardForEveryAccentAndTheme() {
        let backgrounds: [(dark: Bool, hexes: [String])] = [
            (false, [AppTheme.surfaceLightHex, "FFFFFF"]),
            (true, [AppTheme.surfaceDarkHex, "2A2016"])
        ]
        for option in AppTheme.accentOptions {
            for (dark, hexes) in backgrounds {
                let text = AppTheme.accentTextOnSurfaceHex(hex: option.hex, dark: dark)
                for bg in hexes {
                    XCTAssertGreaterThanOrEqual(ratio(text, bg), 4.5,
                                                "\(option.name) \(dark ? "dark" : "light") on \(bg)")
                }
            }
        }
    }
}
