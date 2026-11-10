import XCTest
@testable import ShelfHead

/// Cleanup pass (Batch N-5 redundancy close-out, REVIEW_2026-09-14_DESIGN.md): pins
/// `PlayerView.speedLabel(_:)` — the playback-rate formatter that used to be duplicated,
/// byte-for-byte, between `PlayerView+BottomRegion.swift`'s `speedLabel` and
/// `SpeedSheet.label(_:)` in `PlayerView+Sheets.swift`. Both call sites now share this one
/// static helper (`PlayerView+Formatting.swift`); these values are exactly what each of the
/// two duplicated bodies produced before the merge, so a regression here would have
/// changed the toolbar's speed pill and the speed sheet's readout/presets identically.
final class PlayerSpeedLabelTests: XCTestCase {

    func testWholeNumbersRenderWithNoFractionDigits() {
        XCTAssertEqual(PlayerView.speedLabel(1.0), "1×")
        XCTAssertEqual(PlayerView.speedLabel(2.0), "2×")
        XCTAssertEqual(PlayerView.speedLabel(3.0), "3×")
    }

    func testFractionalRatesRenderWithUpToTwoFractionDigits() {
        XCTAssertEqual(PlayerView.speedLabel(1.5), "1.5×")
        XCTAssertEqual(PlayerView.speedLabel(1.75), "1.75×")
        XCTAssertEqual(PlayerView.speedLabel(0.5), "0.5×")
        XCTAssertEqual(PlayerView.speedLabel(1.25), "1.25×")
        XCTAssertEqual(PlayerView.speedLabel(2.5), "2.5×")
    }
}
