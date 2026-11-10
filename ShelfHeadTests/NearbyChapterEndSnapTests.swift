import XCTest
@testable import ShelfHead

/// Item 26 (REVIEW-2026-09-09-REMAINING.md): `nearbyChapterEnd(near:window:)` (the F2
/// "smart" sleep timer's snap-to-chapter-boundary logic) filtered candidate chapter ends
/// with `$0 >= currentTime`, so a boundary sitting exactly at (or a hair past, from
/// tick/rounding timing) the current position could be picked as the "nearest" snap
/// target and then read as already-elapsed on the very next tick — the same class of bug
/// fix 6.F (REVIEW-2026-09-09.md) already fixed for `chapterSleepTarget`'s `end >
/// currentTime` boundary. The fix adds a small epsilon (0.5s, matching the `<= 0.5`
/// "has the timer arrived" threshold `updateCurrentTime` already uses) so a boundary has
/// to be genuinely ahead of now, not just not-technically-behind, to be selectable.
///
/// `nearestUpcomingChapterEnd(chapterEnds:currentTime:target:window:epsilon:)` is the
/// pure half of `nearbyChapterEnd(near:window:)`, pulled out the same way
/// `chapterSleepTarget` was.
final class NearbyChapterEndSnapTests: XCTestCase {

    private func nearest(
        _ ends: [Double], currentTime: Double, target: Double, window: Double, epsilon: Double = 0.5
    ) -> Double? {
        AudioPlayerService.nearestUpcomingChapterEnd(
            chapterEnds: ends, currentTime: currentTime, target: target, window: window, epsilon: epsilon)
    }

    // MARK: - The regression: boundary exactly at "now"

    func testABoundaryExactlyAtCurrentTimeIsNotSelectable() {
        // Old behaviour (`>= currentTime`) would have picked 600 here; it must not.
        XCTAssertNil(nearest([600], currentTime: 600, target: 600, window: 180))
    }

    // MARK: - Just inside / outside the epsilon window

    func testABoundaryJustInsideTheEpsilonIsTreatedAsAlreadyPassed() {
        // 0.3s ahead of now, epsilon 0.5s: still "already passed".
        XCTAssertNil(nearest([600.3], currentTime: 600, target: 600, window: 180, epsilon: 0.5))
    }

    func testABoundaryJustOutsideTheEpsilonIsSelectable() {
        // 0.6s ahead of now, epsilon 0.5s: genuinely ahead.
        XCTAssertEqual(nearest([600.6], currentTime: 600, target: 600, window: 180, epsilon: 0.5), 600.6)
    }

    func testABoundaryBehindCurrentTimeIsNeverSelectable() {
        XCTAssertNil(nearest([590], currentTime: 600, target: 600, window: 180))
    }

    // MARK: - Normal case

    func testTheNearestUpcomingBoundaryWithinTheWindowWins() {
        // Target is 900 (a 15-minute timer from currentTime 600); 920 is closer to the
        // target than 1500, and both are ahead of "now".
        let ends = [601.0, 920.0, 1500.0]
        XCTAssertEqual(nearest(ends, currentTime: 600, target: 900, window: 180), 920)
    }

    func testNoBoundaryWithinTheWindowMeansNoSnap() {
        // 1500 is ahead of now but far outside a 180s window around target 900.
        XCTAssertNil(nearest([1500.0], currentTime: 600, target: 900, window: 180))
    }

    func testEmptyChapterListNeverSnaps() {
        XCTAssertNil(nearest([], currentTime: 600, target: 900, window: 180))
    }

    /// `nearbyChapterEnd(near:window:)` itself only reaches this with candidates already
    /// filtered — but the pure function's own default `epsilon` is what a caller gets
    /// without specifying one, so pin it against the instance method's actual boundary.
    func testDefaultEpsilonMatchesTheHalfSecondSleepTimerThreshold() {
        XCTAssertNil(AudioPlayerService.nearestUpcomingChapterEnd(
            chapterEnds: [600.4], currentTime: 600, target: 600, window: 180))
        XCTAssertEqual(AudioPlayerService.nearestUpcomingChapterEnd(
            chapterEnds: [600.6], currentTime: 600, target: 600, window: 180), 600.6)
    }
}
