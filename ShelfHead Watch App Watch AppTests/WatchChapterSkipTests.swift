import XCTest
@testable import ShelfHead_Watch

/// Batch 399 follow-up: `WatchChapterSkipRule.target` is a port of the iOS
/// `AudioPlayerService.chapterSkipTarget`; these cases mirror `ChapterSkipDecisionTests`
/// so both implementations are pinned to the same behaviour.
@MainActor
final class WatchChapterSkipTests: XCTestCase {
    private func chapters(_ ranges: [(Double, Double)]) -> [WatchChapterSkipRule.Bounds] {
        ranges.map { WatchChapterSkipRule.Bounds(start: $0.0, end: $0.1) }
    }

    private var book: [WatchChapterSkipRule.Bounds] { chapters([(0, 600), (600, 1200), (1200, 1800)]) }

    private func target(_ previous: Double?, _ current: Double, start: Int = 0, end: Int = 0,
                        in list: [WatchChapterSkipRule.Bounds]? = nil) -> Double? {
        WatchChapterSkipRule.target(chapters: list ?? book, previousTime: previous,
                                    currentTime: current, start: start, end: end)
    }

    // MARK: Start trim

    func testCrossingIntoAChapterSkipsItsStart() {
        XCTAssertEqual(target(599.8, 600.3, start: 15), 615)
    }

    func testTheFirstChapterOfAFreshBookIsTrimmed() {
        XCTAssertEqual(target(-0.01, 0.5, start: 15), 15)
    }

    func testASeekToAChapterStartIsNotTrimmed() {
        XCTAssertNil(target(600, 600.5, start: 15))
    }

    func testAJumpAcrossTheBoundaryIsNotTrimmed() {
        XCTAssertNil(target(300, 601, start: 15))
    }

    func testPastTheTrimNothingHappens() {
        XCTAssertNil(target(615, 615.5, start: 15))
    }

    func testBackwardStepIsIgnored() {
        XCTAssertNil(target(601, 599, start: 15))
    }

    // MARK: End trim

    func testReachingTheEndTrimJumpsToTheNextChapter() {
        XCTAssertEqual(target(589.8, 590.3, end: 10), 600.05)
    }

    func testEndJumpLandsPastTheNextChaptersStartTrim() {
        XCTAssertEqual(target(579.8, 580.3, start: 15, end: 20), 615)
    }

    func testASeekIntoTheEndTrimIsLeftAlone() {
        XCTAssertNil(target(595, 595.5, end: 10))
    }

    func testTheLastChapterIsNeverEndTrimmed() {
        XCTAssertNil(target(1789.8, 1790.3, end: 10))
    }

    // MARK: Guards

    func testOffNeverSkips() {
        XCTAssertNil(target(599.8, 600.3))
        XCTAssertNil(target(589.8, 590.3))
    }

    func testNoPreviousPositionNeverSkips() {
        XCTAssertNil(target(nil, 600.3, start: 15))
    }

    func testAShortChapterIsNotTrimmed() {
        let short = chapters([(0, 600), (600, 630), (630, 1200)])
        XCTAssertNil(target(599.8, 600.3, start: 15, end: 10, in: short))
        XCTAssertNil(target(619.8, 620.3, start: 15, end: 10, in: short))
    }

    func testEndJumpIntoAShortChapterSkipsOnlyTheBoundary() {
        let short = chapters([(0, 600), (600, 630), (630, 1200)])
        XCTAssertEqual(target(589.8, 590.3, start: 15, end: 10, in: short), 600.05)
    }

    func testNoChaptersNeverSkips() {
        XCTAssertNil(target(10, 10.5, start: 15, end: 10, in: []))
    }

    // MARK: Settings

    func testOverrideBeatsDefaultAndFallsBackWhenAbsent() {
        let settings = WatchChapterSkipSettings(defaultStart: 5, defaultEnd: 0,
                                                overrides: ["a": [20, 30], "off": [0, 0]])
        XCTAssertEqual(settings.resolved(forItem: "other").start, 5)
        XCTAssertEqual(settings.resolved(forItem: "other").end, 0)
        XCTAssertEqual(settings.resolved(forItem: "a").start, 20)
        XCTAssertEqual(settings.resolved(forItem: "a").end, 30)
        XCTAssertEqual(settings.resolved(forItem: "off").start, 0)
        XCTAssertEqual(settings.resolved(forItem: "off").end, 0)
    }

    func testMalformedOverrideFallsBackToDefault() {
        let settings = WatchChapterSkipSettings(defaultStart: 5, defaultEnd: 10, overrides: ["bad": [1]])
        XCTAssertEqual(settings.resolved(forItem: "bad").start, 5)
        XCTAssertEqual(settings.resolved(forItem: "bad").end, 10)
    }

    func testCodableAndPersistenceRoundTrip() throws {
        let suite = "WatchChapterSkipTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WatchChapterSkipSettings.load(from: defaults), WatchChapterSkipSettings())
        let settings = WatchChapterSkipSettings(defaultStart: 15, defaultEnd: 10, overrides: ["x": [5, 0]])
        settings.save(to: defaults)
        XCTAssertEqual(WatchChapterSkipSettings.load(from: defaults), settings)
    }
}
