import XCTest
@testable import ShelfHead

/// Batch 399 (App Store review request): `AudioPlayerService.chapterSkipTarget` decides
/// the timed chapter skip — trim N seconds off every chapter's start and M off its end
/// during ordinary playback, but never react to a deliberate seek.
final class ChapterSkipDecisionTests: XCTestCase {

    /// `Chapter` only has a `Decodable` init (no memberwise one), same as
    /// `CurrentChapterResolutionTests`.
    private func chapters(_ ranges: [(Double, Double)]) throws -> [Chapter] {
        let objects = ranges.enumerated().map { #"{"id": \#($0.offset), "start": \#($0.element.0), "end": \#($0.element.1), "title": "Chapter \#($0.offset)"}"# }
        return try JSONDecoder().decode([Chapter].self, from: Data("[\(objects.joined(separator: ","))]".utf8))
    }

    private var book: [Chapter] {
        get throws { try chapters([(0, 600), (600, 1200), (1200, 1800)]) }
    }

    private func target(_ previous: Double?, _ current: Double, start: Int = 0, end: Int = 0,
                        in chapters: [Chapter]? = nil) throws -> Double? {
        AudioPlayerService.chapterSkipTarget(chapters: try chapters ?? book, previousTime: previous,
                                             currentTime: current, skip: ChapterSkip(start: start, end: end))
    }

    // MARK: - Start trim

    func testCrossingIntoAChapterSkipsItsStart() throws {
        XCTAssertEqual(try target(599.8, 600.3, start: 15), 615)
    }

    func testTheFirstChapterOfAFreshBookIsTrimmed() throws {
        // `startPlayback` seeds the tracker just before the first chapter.
        XCTAssertEqual(try target(-0.01, 0.5, start: 15), 15)
    }

    func testASeekToAChapterStartIsNotTrimmed() throws {
        // `seek(to:)` records its own target as the previous position.
        XCTAssertNil(try target(600, 600.5, start: 15))
    }

    func testAJumpAcrossTheBoundaryIsNotTrimmed() throws {
        // A scrub from mid-chapter-0 into the start of chapter 1 is too large a step.
        XCTAssertNil(try target(300, 601, start: 15))
    }

    func testPastTheTrimNothingHappens() throws {
        XCTAssertNil(try target(615, 615.5, start: 15))
    }

    func testBackwardStepIsIgnored() throws {
        XCTAssertNil(try target(601, 599, start: 15))
    }

    // MARK: - End trim

    func testReachingTheEndTrimJumpsToTheNextChapter() throws {
        XCTAssertEqual(try target(589.8, 590.3, end: 10), 600.05)
    }

    func testEndJumpLandsPastTheNextChaptersStartTrim() throws {
        XCTAssertEqual(try target(579.8, 580.3, start: 15, end: 20), 615)
    }

    func testASeekIntoTheEndTrimIsLeftAlone() throws {
        XCTAssertNil(try target(595, 595.5, end: 10))
    }

    func testTheLastChapterIsNeverEndTrimmed() throws {
        // Jumping off the end of the book would mark it finished early.
        XCTAssertNil(try target(1789.8, 1790.3, end: 10))
    }

    // MARK: - Guards

    func testOffNeverSkips() throws {
        XCTAssertNil(try target(599.8, 600.3))
        XCTAssertNil(try target(589.8, 590.3))
    }

    func testNoPreviousPositionNeverSkips() throws {
        XCTAssertNil(try target(nil, 600.3, start: 15))
    }

    func testAShortChapterIsNotTrimmed() throws {
        // 30s chapter, 15 + 10 trimmed would leave 5s (< 10s kept).
        let short = try chapters([(0, 600), (600, 630), (630, 1200)])
        XCTAssertNil(try target(599.8, 600.3, start: 15, end: 10, in: short))
        XCTAssertNil(try target(619.8, 620.3, start: 15, end: 10, in: short))
    }

    func testEndJumpIntoAShortChapterSkipsOnlyTheBoundary() throws {
        let short = try chapters([(0, 600), (600, 630), (630, 1200)])
        XCTAssertEqual(try target(589.8, 590.3, start: 15, end: 10, in: short), 600.05)
    }

    func testNoChaptersNeverSkips() throws {
        XCTAssertNil(try target(10, 10.5, start: 15, end: 10, in: []))
    }

    // MARK: - Resolution

    func testOverrideBeatsDefaultAndNilRemovesIt() {
        let item = "chapter-skip-test-\(UUID().uuidString)"
        let savedDefault = SettingsStore.defaultChapterSkip
        defer {
            SettingsStore.setChapterSkipOverride(nil, forItem: item)
            SettingsStore.defaultChapterSkip = savedDefault
        }
        SettingsStore.defaultChapterSkip = ChapterSkip(start: 5, end: 0)
        XCTAssertNil(SettingsStore.chapterSkipOverride(forItem: item))
        XCTAssertEqual(SettingsStore.resolvedChapterSkip(forItem: item), ChapterSkip(start: 5, end: 0))

        SettingsStore.setChapterSkipOverride(.off, forItem: item)
        XCTAssertEqual(SettingsStore.resolvedChapterSkip(forItem: item), .off)

        SettingsStore.setChapterSkipOverride(ChapterSkip(start: 20, end: 30), forItem: item)
        XCTAssertEqual(SettingsStore.resolvedChapterSkip(forItem: item), ChapterSkip(start: 20, end: 30))

        SettingsStore.setChapterSkipOverride(nil, forItem: item)
        XCTAssertEqual(SettingsStore.resolvedChapterSkip(forItem: item), ChapterSkip(start: 5, end: 0))
    }

    func testLabels() {
        XCTAssertEqual(ChapterSkip.label(0), "Off")
        XCTAssertEqual(ChapterSkip.label(15), "15 s")
        XCTAssertEqual(ChapterSkip.label(60), "1 min")
        XCTAssertEqual(ChapterSkip.label(90), "1 min 30 s")
    }
}
