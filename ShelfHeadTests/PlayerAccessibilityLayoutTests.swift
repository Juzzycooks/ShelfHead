import XCTest
@testable import ShelfHead

/// Tests for the pure helpers behind `PlayerView`'s H3/H4 fixes
/// (`REVIEW_2026-09-04_UI.md` "Pass 3 — the full player at accessibility sizes").
///
/// Following this codebase's established precedent (see `FormattingAndModelsTests`'
/// `toolbarIconSlotSide`/`accessibilityArtworkSize` coverage from the H1/H2 fixes in the
/// same file): these pin the decision math directly rather than exercising the view
/// itself, since the view's actual on-screen fit can only be confirmed by a real
/// build/render at AX5, which this environment doesn't have.
final class PlayerAccessibilityLayoutTests: XCTestCase {

    // MARK: - H3: `cappedTransportMetric` — the transport row's scaled-but-capped sizes

    func testCappedTransportMetricIsUnchangedAtTheDefaultTextSize() {
        // `@ScaledMetric` returns exactly `base` at `.large`, so this must too — the
        // guarantee the whole H3 fix leans on for "default size renders unchanged".
        XCTAssertEqual(PlayerView.cappedTransportMetric(64, base: 64), 64, accuracy: 0.001)
        XCTAssertEqual(PlayerView.cappedTransportMetric(24, base: 24), 24, accuracy: 0.001)
        XCTAssertEqual(PlayerView.cappedTransportMetric(22, base: 22), 22, accuracy: 0.001)
        XCTAssertEqual(PlayerView.cappedTransportMetric(16, base: 16), 16, accuracy: 0.001)
    }

    func testCappedTransportMetricTracksTheScaledValueBelowTheCap() {
        // Between the base and 1.4×, this passes the scaled metric straight through.
        XCTAssertEqual(PlayerView.cappedTransportMetric(80, base: 64), 80, accuracy: 0.001)
    }

    func testCappedTransportMetricStopsAt1_4x() {
        // AX5's real growth on a 64pt base (`@ScaledMetric` with no `relativeTo`, same as
        // `npTitleSize` above it in the file, roughly triples at AX5) would run far past
        // 1.4× if left uncapped — this is the ceiling the review called load-bearing.
        XCTAssertEqual(PlayerView.cappedTransportMetric(64 * 3, base: 64), 64 * 1.4, accuracy: 0.001)
        XCTAssertEqual(PlayerView.cappedTransportMetric(64 * 1.4, base: 64), 64 * 1.4, accuracy: 0.001)
    }

    // MARK: - H3: `transportRowSpacing` — the row still has to fit at AX5

    func testTransportRowSpacingIsUnchangedAtTheDefaultTextSize() {
        // At `.large` the play circle is exactly 64 and every supported phone (≥375pt)
        // clears the ~320pt this needs, so this must return the current literal, 18.
        XCTAssertEqual(PlayerView.transportRowSpacing(columnWidth: 327, playCircleDiameter: 64), 18, accuracy: 0.001)
        XCTAssertEqual(PlayerView.transportRowSpacing(columnWidth: 354, playCircleDiameter: 64), 18, accuracy: 0.001)
    }

    func testTransportRowSpacingHoldsAtBaseOnTheScreenTheReviewCaptured() {
        // The review's own AX5 screenshot measured a 402pt screen (354pt column, i.e.
        // 402 - 2×24pt side padding — the same convention `accessibilityArtworkSize`'s
        // own tests already use). At the 1.4× cap the play circle is 64 * 1.4 = 89.6, and
        // 4×46 (fixed skip/chapter frames) + 89.6 + 4×18 (base spacing) = 345.6, which
        // already fits inside 354 — base spacing holds, unreduced, on this device.
        let cappedCircle = PlayerView.cappedTransportMetric(64 * 3, base: 64)
        XCTAssertEqual(PlayerView.transportRowSpacing(columnWidth: 354, playCircleDiameter: cappedCircle), 18, accuracy: 0.001)
    }

    func testTransportRowSpacingShrinksOnTheNarrowestSupportedPhone() {
        // 327 (375 - 48) is this app's narrowest supported column (see
        // `toolbarLabelPointSize`'s own comment). At the AX5 cap (89.6), base spacing
        // would need 345.6 of the 327 available, so this must shrink: the exact-fit value
        // is (327 - 184 - 89.6) / 4 = 13.35, floored to 13pt — verified to still fit.
        let cappedCircle: CGFloat = 64 * 1.4
        let spacing = PlayerView.transportRowSpacing(columnWidth: 327, playCircleDiameter: cappedCircle)
        XCTAssertEqual(spacing, 13, accuracy: 0.001)
        let totalRowWidth = 4 * 46 + cappedCircle + 4 * spacing
        XCTAssertLessThanOrEqual(totalRowWidth, 327)
    }

    func testTransportRowSpacingNeverDropsBelowTheLegibilityFloor() {
        // An unrealistically narrow column shouldn't be able to collapse the gaps to
        // nothing — 8pt is the floor regardless of how tight the math gets.
        let spacing = PlayerView.transportRowSpacing(columnWidth: 200, playCircleDiameter: 64 * 1.4)
        XCTAssertEqual(spacing, 8, accuracy: 0.001)
    }

    // MARK: - H4: the header menu button's reserved slot

    func testHeaderMenuReservedTrailingWidthIsComputedFromTheButtonsOwnGeometry() {
        // 44 (the button's own hit-target side, `playerHeaderMenu`'s `.frame`) + 16 (its
        // `.padding(.trailing, ...)` off the column edge) — named constants, not a second,
        // independently-typed magic number that could drift from the button's real size.
        XCTAssertEqual(PlayerView.headerMenuButtonSide, 44, accuracy: 0.001)
        XCTAssertEqual(PlayerView.headerMenuButtonTrailingPadding, 16, accuracy: 0.001)
        XCTAssertEqual(PlayerView.headerMenuReservedTrailingWidth, 60, accuracy: 0.001)
    }

    func testContinueListeningFitsTheReservedColumnAtAX5ByArithmetic() {
        // Arithmetic only — not a rendered/on-device confirmation. The review measured
        // "CONTINUE LISTENING" (the resuming variant of the wordmark, ~64% wider than
        // "NOW PLAYING") needing roughly 420pt inside the 354pt column on its captured
        // AX5 screen (402pt wide), independent of the header menu button. Reserving the
        // button's slot (60pt, pinned above) narrows that to 354 - 60 = 294pt, so the
        // required shrink is 294 / 420 ≈ 0.70. `PlayerView`'s `.minimumScaleFactor(0.5)`
        // at accessibility sizes is comfortably below that, so `.lineLimit(1)` +
        // `.minimumScaleFactor` can shrink the wordmark to fit fully rather than
        // truncating it — the integrator should confirm this on a real AX5 render.
        let reviewMeasuredColumn: CGFloat = 354
        let continueListeningNeededWidth: CGFloat = 420
        let narrowedColumn = reviewMeasuredColumn - PlayerView.headerMenuReservedTrailingWidth
        let requiredScale = narrowedColumn / continueListeningNeededWidth
        let appliedMinimumScaleFactor: CGFloat = 0.5
        XCTAssertGreaterThan(requiredScale, appliedMinimumScaleFactor,
                              "minimumScaleFactor floor must sit below the scale CONTINUE LISTENING needs to fit, or it will truncate instead of shrinking")
    }
}
