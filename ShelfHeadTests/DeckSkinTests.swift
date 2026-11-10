import XCTest
import SwiftUI
@testable import ShelfHead

/// Batch 460: deck skins registry, defaults and pure maths.
final class DeckSkinTests: XCTestCase {
    func testRegistryHasSixSkins() {
        XCTAssertEqual(DeckSkin.allCases.count, 6)
        XCTAssertEqual(Set(DeckSkin.allCases.map(\.symbolName)).count, 6)
    }

    func testDefaultsAreClassicAndSoundsOff() {
        let keys = [SettingsKeys.deckSkin, SettingsKeys.deckButtonSounds]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertEqual(DeckSkin.default, .classic)
        XCTAssertEqual(SettingsStore.deckSkin, .classic)
        XCTAssertFalse(SettingsStore.deckButtonSounds)
    }

    func testRawValueRoundTrip() {
        for skin in DeckSkin.allCases {
            XCTAssertEqual(DeckSkin(rawValue: skin.rawValue), skin)
        }
        XCTAssertNil(DeckSkin(rawValue: "nonsense"))
    }

    /// Batch 466 (DS2): From the Cover's deck is a mid-tone of the cover's hue (it read as black
    /// on the 16%/7% background tones), and its keys' ink stays readable (3:1) for any hue.
    func testFromTheCoverTonesFollowTheCoverAndInkReads() {
        func comps(_ c: Color) -> (h: CGFloat, b: CGFloat, l: Double) {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
            let ui = UIColor(c)
            ui.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            ui.getRed(&r, green: &g, blue: &bl, alpha: &a)
            return (h, v, ContrastInk.relativeLuminance(r: Double(r), g: Double(g), b: Double(bl)))
        }
        for step in 0..<40 {
            var palette = CoverPalette.brand
            palette.primaryAccent = Color(uiColor: UIColor(hue: CGFloat(step) / 40, saturation: 0.9, brightness: 0.9, alpha: 1))
            let key = palette.deckKeyTones.map(comps)
            XCTAssertEqual(key[0].h, CGFloat(step) / 40, accuracy: 0.02, "hue \(step)")
            XCTAssertEqual(key[0].b, 0.52, accuracy: 0.01)
            XCTAssertGreaterThan(comps(palette.deckBodyTones[0]).b, 0.3)
            let ink = comps(DeckSkin.fromTheCover.keyInk(palette: palette)).l
            for end in key {
                let contrast = (max(ink, end.l) + 0.05) / (min(ink, end.l) + 0.05)
                XCTAssertGreaterThanOrEqual(contrast, 3, "hue \(step)")
            }
        }
    }

    func testBoomboxInkIsFixedCream() {
        XCTAssertEqual(DeckSkin.boombox.keyInk(palette: nil), Color.deckCream)
    }

    func testReelSpeedScalesWithRateAndClamps() {
        XCTAssertEqual(DeckSkin.reelDegreesPerSecond(rate: 1), 60, accuracy: 0.001)
        XCTAssertEqual(DeckSkin.reelDegreesPerSecond(rate: 2), 120, accuracy: 0.001)
        XCTAssertEqual(DeckSkin.reelDegreesPerSecond(rate: 0.1), 30, accuracy: 0.001)
        XCTAssertEqual(DeckSkin.reelDegreesPerSecond(rate: 9), 180, accuracy: 0.001)
    }

    func testProgramNumberIsChapterIndexModFour() {
        XCTAssertEqual(DeckSkin.programNumber(chapterIndex: nil), 1)
        XCTAssertEqual(DeckSkin.programNumber(chapterIndex: 0), 1)
        XCTAssertEqual(DeckSkin.programNumber(chapterIndex: 3), 4)
        XCTAssertEqual(DeckSkin.programNumber(chapterIndex: 4), 1)
        XCTAssertEqual(DeckSkin.programNumber(chapterIndex: 10), 3)
    }

    func testSynthesisIsDeterministicAndBounded() {
        for sound in DeckSound.allCases {
            let a = DeckSynth.samples(for: sound)
            let b = DeckSynth.samples(for: sound)
            XCTAssertEqual(a, b)
            XCTAssertFalse(a.isEmpty)
            XCTAssertTrue(a.allSatisfy { abs($0) <= 1 && $0.isFinite })
            XCTAssertGreaterThan(a.map(abs).max() ?? 0, 0.05)
        }
    }

    /// Batch 466: the key sounds are clicks, not tones: two transients (the contact, then the
    /// key landing), and nearly silent by the last quarter rather than ringing like a beep.
    func testKeySoundsAreDryTwoStepClicks() {
        for sound in DeckSound.allCases {
            let r = DeckSynth.recipe(for: sound)
            XCTAssertGreaterThanOrEqual(r.transients.count, 2, "\(sound)")
            XCTAssertGreaterThan(r.transients.map(\.delay).max() ?? 0, 0.004, "\(sound)")
            let a = DeckSynth.samples(for: sound).map { abs($0) }
            let peak = a.max() ?? 0
            let tail = a.suffix(a.count / 4).max() ?? 0
            XCTAssertLessThan(tail, peak * 0.35, "\(sound)")
        }
    }

    // MARK: Batch 465: keys and reel wind

    func testWindPeaksAtOnceAndEasesToZero() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let peak = DeckCue.peakWindDegreesPerSecond
        XCTAssertEqual(DeckCue.windDegreesPerSecond(direction: 1, since: start, now: start), peak, accuracy: 0.001)
        XCTAssertEqual(DeckCue.windDegreesPerSecond(direction: -1, since: start, now: start), -peak, accuracy: 0.001)
        let mid = DeckCue.windDegreesPerSecond(direction: 1, since: start, now: start.addingTimeInterval(DeckCue.windSeconds / 2))
        XCTAssertEqual(mid, peak * 0.25, accuracy: 0.001)
        XCTAssertEqual(DeckCue.windDegreesPerSecond(direction: 1, since: start, now: start.addingTimeInterval(DeckCue.windSeconds)), 0)
        XCTAssertEqual(DeckCue.windDegreesPerSecond(direction: 1, since: start, now: start.addingTimeInterval(-0.1)), 0)
        XCTAssertEqual(DeckCue.windDegreesPerSecond(direction: 1, since: nil, now: start), 0)
        XCTAssertEqual(DeckCue.windDegreesPerSecond(direction: 0, since: start, now: start), 0)
    }

    func testGlyphOpacityOnSkinKeys() {
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .skip, enabled: true, onSkin: true), 1)
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .chapter, enabled: true, onSkin: true), 0.85)
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .skip, enabled: false, onSkin: true), 0.25)
        // Classic is unchanged.
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .skip, enabled: true), 0.7)
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .chapter, enabled: true), 0.55)
    }

    func testEverySkinKeyTravelsAndOnlyReelIsRound() {
        for skin in DeckSkin.allCases { XCTAssertGreaterThan(skin.keyTravel, 0, "\(skin)") }
        XCTAssertEqual(DeckSkin.allCases.filter(\.hasRoundKeys), [.reelToReel])
    }
}
