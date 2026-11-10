import XCTest
@testable import ShelfHead_Watch

/// Critique 2026-10-06 (harden): pins the Watch speed label/cycling and the
/// "replace what's playing?" decision.
@MainActor
final class WatchSpeedAndPlayDecisionTests: XCTestCase {
    func testSpeedLabelKeepsTwoDecimalsAndTrimsZeros() {
        XCTAssertEqual(WatchSpeedCycler.label(for: 1.0), "1×")
        XCTAssertEqual(WatchSpeedCycler.label(for: 0.8), "0.8×")
        XCTAssertEqual(WatchSpeedCycler.label(for: 1.25), "1.25×")
        XCTAssertEqual(WatchSpeedCycler.label(for: 1.5), "1.5×")
        XCTAssertEqual(WatchSpeedCycler.label(for: 1.75), "1.75×")
        XCTAssertEqual(WatchSpeedCycler.label(for: 2.0), "2×")
        XCTAssertEqual(WatchSpeedCycler.label(for: 1.05), "1.05×")
    }

    func testNextSpeedStepsThroughPresetsAndWrapsFromTop() {
        XCTAssertEqual(WatchSpeedCycler.next(after: 1.0), 1.25)
        XCTAssertEqual(WatchSpeedCycler.next(after: 1.75), 2.0)
        XCTAssertEqual(WatchSpeedCycler.next(after: 2.0), 0.8)
    }

    func testNextSpeedFromCustomRateGoesToNearestPresetAbove() {
        XCTAssertEqual(WatchSpeedCycler.next(after: 1.1), 1.25)
        XCTAssertEqual(WatchSpeedCycler.next(after: 0.5), 0.8)
        XCTAssertEqual(WatchSpeedCycler.next(after: 1.6), 1.75)
        XCTAssertEqual(WatchSpeedCycler.next(after: 2.5), 0.8)
    }

    private let scope = WatchAccountScope(serverURL: "https://abs.example.com", accountId: "acct")

    private func state(itemId: String, title: String = "Current", playing: Bool) -> WatchPlaybackState {
        var s = WatchPlaybackState.idle(scope: scope)
        s.itemId = itemId
        s.title = title
        s.isPlaying = playing
        return s
    }

    func testPlaysImmediatelyWhenNothingIsPlaying() {
        XCTAssertEqual(WatchPlayRequestDecision.decide(requestedItemId: "a", current: nil), .playNow)
        let idle = WatchPlaybackState.idle(scope: scope)
        XCTAssertEqual(WatchPlayRequestDecision.decide(requestedItemId: "a", current: idle), .playNow)
    }

    func testPlaysImmediatelyForTheSameBookOrAPausedOne() {
        XCTAssertEqual(WatchPlayRequestDecision.decide(requestedItemId: "a", current: state(itemId: "a", playing: true)), .playNow)
        XCTAssertEqual(WatchPlayRequestDecision.decide(requestedItemId: "b", current: state(itemId: "a", playing: false)), .playNow)
    }

    func testConfirmsBeforeReplacingADifferentPlayingBook() {
        XCTAssertEqual(
            WatchPlayRequestDecision.decide(requestedItemId: "b", current: state(itemId: "a", title: "Dune", playing: true)),
            .confirmReplacing(currentTitle: "Dune"))
    }
}
