import XCTest
@testable import ShelfHead

/// P-1 / P-3 and Batch 317's deferred tab badge (REVIEW_2026-09-14_DESIGN.md): pins the
/// pure helpers the player's scrubber rewrite and the legacy tab bar's badge rest on.
///
/// Same line this project already draws (see `CurrentChapterResolutionTests`' own note):
/// the decision functions get tests, the SwiftUI rendering around them doesn't. What a
/// rail *looks* like and what VoiceOver actually speaks both need a device; what string
/// is handed to `.accessibilityValue`, and where a tick is placed within a range, do not.
final class PlayerScrubberFormattingTests: XCTestCase {

    /// `Chapter` only has a `Decodable` init (no memberwise one) — same fixture approach
    /// as `CurrentChapterResolutionTests`.
    private func chapters(_ triples: [(Int, Double, Double)]) throws -> [Chapter] {
        let objects = triples.map { #"{"id": \#($0.0), "start": \#($0.1), "end": \#($0.2), "title": "Chapter \#($0.0)"}"# }
        let json = "[\(objects.joined(separator: ","))]"
        return try JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
    }

    // MARK: - P-3: spoken playback times

    func testSpokenTimeReadsMinutesAndSeconds() {
        // The review's own example: the scrubber used to announce "38 percent" where the
        // counters beside it read 12:44 / −2:28.
        XCTAssertEqual(PlayerView.spokenTime(12 * 60 + 44), "12 minutes 44 seconds")
        XCTAssertEqual(PlayerView.spokenTime(2 * 60 + 28), "2 minutes 28 seconds")
    }

    func testSpokenTimeSingularises() {
        XCTAssertEqual(PlayerView.spokenTime(61), "1 minute 1 second")
        XCTAssertEqual(PlayerView.spokenTime(3600), "1 hour")
    }

    func testSpokenTimeDropsZeroComponents() {
        XCTAssertEqual(PlayerView.spokenTime(45), "45 seconds")
        XCTAssertEqual(PlayerView.spokenTime(5 * 60), "5 minutes")
        // Past an hour the seconds are dropped deliberately — see `spokenTime`'s comment.
        XCTAssertEqual(PlayerView.spokenTime(3 * 3600 + 2 * 60 + 17), "3 hours 2 minutes")
        XCTAssertEqual(PlayerView.spokenTime(2 * 3600), "2 hours")
    }

    func testSpokenTimeZeroIsStillSpoken() {
        // An empty announcement would leave VoiceOver silent at the start of a chapter.
        XCTAssertEqual(PlayerView.spokenTime(0), "0 seconds")
    }

    func testSpokenTimeSurvivesHostileValues() {
        // Same guarantee `Double.safeSeconds` exists for (S2/S4): a server-supplied NaN
        // or infinity must not reach `Int(_:)`, which traps.
        XCTAssertEqual(PlayerView.spokenTime(.nan), "0 seconds")
        XCTAssertEqual(PlayerView.spokenTime(-90), "0 seconds")
        XCTAssertFalse(PlayerView.spokenTime(.infinity).isEmpty)
    }

    func testScrubberAccessibilityValueJoinsElapsedAndRemaining() {
        XCTAssertEqual(
            PlayerView.scrubberAccessibilityValue(elapsed: 12 * 60 + 44, remaining: 2 * 60 + 28),
            "12 minutes 44 seconds, 2 minutes 28 seconds remaining")
    }

    // MARK: - P-1: chapter ticks within the scrubber's current range

    func testWholeBookRangeMarksEveryInteriorBoundary() throws {
        let list = try chapters([(0, 0, 100), (1, 100, 250), (2, 250, 400)])
        let ticks = PlayerView.scrubberChapterTicks(chapters: list, rangeStart: 0, rangeEnd: 400)
        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(ticks[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(ticks[1], 0.625, accuracy: 0.0001)
    }

    func testBoundariesAtTheRangeEndsAreNotTicks() throws {
        // The first chapter starts exactly at the range start; that's the rail's own end
        // cap, not a mark inside it.
        let list = try chapters([(0, 0, 100), (1, 100, 250)])
        XCTAssertEqual(PlayerView.scrubberChapterTicks(chapters: list, rangeStart: 0, rangeEnd: 250).count, 1)
    }

    func testChapterScopedRangeHasNothingToMark() throws {
        // The player binds the scrubber to the *current chapter* whenever a book has
        // chapters, so its window contains no other chapter's boundary. This is the
        // normal case, and an empty array is the honest answer for it.
        let list = try chapters([(0, 0, 100), (1, 100, 250), (2, 250, 400)])
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: list, rangeStart: 100, rangeEnd: 250).isEmpty)
    }

    func testDegenerateRangesAndSingleChapterProduceNoTicks() throws {
        let list = try chapters([(0, 0, 100), (1, 100, 250)])
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: list, rangeStart: 0, rangeEnd: 0).isEmpty)
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: list, rangeStart: 200, rangeEnd: 100).isEmpty)
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: list, rangeStart: 0, rangeEnd: .nan).isEmpty)
        let single = try chapters([(0, 0, 100)])
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: single, rangeStart: 0, rangeEnd: 100).isEmpty)
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: [], rangeStart: 0, rangeEnd: 100).isEmpty)
    }

    func testVeryDenseChapterListsDrawNoTicksRatherThanASmear() throws {
        // Same 80-boundary density cap, and the same reasoning, as `BookPositionRail`.
        let dense = try chapters((0..<200).map { ($0, Double($0) * 10, Double($0 + 1) * 10) })
        XCTAssertTrue(PlayerView.scrubberChapterTicks(chapters: dense, rangeStart: 0, rangeEnd: 2000).isEmpty)
        let justUnderTheCap = try chapters((0..<81).map { ($0, Double($0) * 10, Double($0 + 1) * 10) })
        XCTAssertEqual(
            PlayerView.scrubberChapterTicks(chapters: justUnderTheCap, rangeStart: 0, rangeEnd: 810).count, 80)
    }

    // MARK: - Waveform bar texture (restored after the user's device pass)

    /// The bars are decoration, but they have to be *stable* decoration — a texture that
    /// reshuffled while you watched, or between launches, is the bug the pre-318 call site
    /// actually shipped (it seeded from `String.hashValue`, which Swift seeds per process).
    func testBarHeightsAreDeterministicForASeed() {
        let a = TapeScrubber.barHeights(seed: 12345)
        let b = TapeScrubber.barHeights(seed: 12345)
        XCTAssertEqual(a, b)
    }

    func testDifferentSeedsDrawDifferentPatterns() {
        XCTAssertNotEqual(TapeScrubber.barHeights(seed: 1), TapeScrubber.barHeights(seed: 2))
    }

    func testBarHeightsCountAndRange() {
        let heights = TapeScrubber.barHeights(seed: 0xDEAD_BEEF)
        XCTAssertEqual(heights.count, 44)
        XCTAssertEqual(TapeScrubber.barCount, 44)
        for height in heights {
            XCTAssertGreaterThanOrEqual(height, TapeScrubber.minBarHeight)
            XCTAssertLessThanOrEqual(height, TapeScrubber.maxBarHeight)
        }
        XCTAssertEqual(TapeScrubber.minBarHeight, 6)
        XCTAssertEqual(TapeScrubber.maxBarHeight, 28)
    }

    func testZeroSeedStillDrawsVariedBars() {
        // 0 is xorshift's fixed point: seeded naively it would draw 44 identical bars.
        let heights = TapeScrubber.barHeights(seed: 0)
        XCTAssertEqual(heights.count, 44)
        XCTAssertGreaterThan(Set(heights).count, 1)
    }

    func testWaveformSeedIsStableAndBookSpecific() {
        // Stable across calls (and, unlike `hashValue`, across processes — that's the
        // point of hashing the bytes ourselves rather than asking the stdlib).
        XCTAssertEqual(
            TapeScrubber.waveformSeed(forBookID: "li_abc123"),
            TapeScrubber.waveformSeed(forBookID: "li_abc123"))
        XCTAssertNotEqual(
            TapeScrubber.waveformSeed(forBookID: "li_abc123"),
            TapeScrubber.waveformSeed(forBookID: "li_abc124"))
        // Nothing playing: the default pattern, not a crash and not a random one.
        XCTAssertEqual(TapeScrubber.waveformSeed(forBookID: nil), 0)
        XCTAssertEqual(TapeScrubber.waveformSeed(forBookID: ""), 0)
    }

    // MARK: - Batch 317 deferred: legacy tab bar badge

    func testBadgeTextCapsAtNinetyNinePlus() {
        XCTAssertEqual(RetroTabBar.badgeText(1), "1")
        XCTAssertEqual(RetroTabBar.badgeText(99), "99")
        XCTAssertEqual(RetroTabBar.badgeText(100), "99+")
    }

    func testBadgeAccessibilityValueNamesWhatItCounts() {
        XCTAssertEqual(
            RetroTabBar.badgeAccessibilityValue(count: 3, description: "downloading"), "3 downloading")
        // No description: announce the number rather than inventing a noun.
        XCTAssertEqual(RetroTabBar.badgeAccessibilityValue(count: 3, description: nil), "3")
        // The spoken count is NOT capped the way the drawn one is — "150 downloading" is
        // useful; "99+ downloading" is a rendering constraint leaking into speech.
        XCTAssertEqual(
            RetroTabBar.badgeAccessibilityValue(count: 150, description: "downloading"), "150 downloading")
    }

    func testNoBadgeMeansNoAnnouncement() {
        XCTAssertNil(RetroTabBar.badgeAccessibilityValue(count: nil, description: "downloading"))
        XCTAssertNil(RetroTabBar.badgeAccessibilityValue(count: 0, description: "downloading"))
        XCTAssertNil(RetroTabBar.badgeAccessibilityValue(count: -2, description: "downloading"))
    }
}
