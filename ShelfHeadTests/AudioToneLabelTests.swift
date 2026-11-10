import XCTest
@testable import ShelfHead

/// T5 (REVIEW_2026-09-04_UI.md): Bass and Treble sliders showed no numeric value,
/// unlike Volume Boost's "+N dB" / "Off" readout. Pins the pure label function the
/// two rows now render, split out of `AudioSettingsSection` so it's testable without
/// a view hierarchy.
final class AudioToneLabelTests: XCTestCase {

    func testToneLabelAtZeroIsFlat() {
        XCTAssertEqual(AudioSettingsSection.toneLabel(0), "Flat")
    }

    func testToneLabelRoundsPositiveValue() {
        XCTAssertEqual(AudioSettingsSection.toneLabel(3.4), "+3 dB")
    }

    func testToneLabelRoundsNegativeValueWithMinusSign() {
        XCTAssertEqual(AudioSettingsSection.toneLabel(-2.6), "\u{2212}3 dB")
    }

    /// Batch 400: the spoken value has its own strings (it used to swap "dB" for "decibels"
    /// in the readout, which can't survive translation). English output is unchanged.
    func testToneAccessibilityValueSpellsOutDecibels() {
        XCTAssertEqual(AudioSettingsSection.toneAccessibilityValue(0), "Flat")
        XCTAssertEqual(AudioSettingsSection.toneAccessibilityValue(3.4), "+3 decibels")
        XCTAssertEqual(AudioSettingsSection.toneAccessibilityValue(-2.6), "\u{2212}3 decibels")
    }
}
