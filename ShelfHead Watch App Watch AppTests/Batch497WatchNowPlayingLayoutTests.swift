import XCTest
import SwiftUI
@testable import ShelfHead_Watch

/// Batch 497 (REVIEW 2026-11-11 W10): Now Playing's first-screen layout and the
/// chapter-relative bar, times and Crown range.
///
/// Screen sizes in points (from memory, the same figures the older Watch layout tests use):
/// 40 mm 162×197, 41 mm 176×215, 45 mm 198×242, 46 mm 208×248, 49 mm 205×251.
final class Batch497WatchNowPlayingLayoutTests: XCTestCase {

    private let screens: [(name: String, size: CGSize)] = [
        ("40mm", CGSize(width: 162, height: 197)),
        ("41mm", CGSize(width: 176, height: 215)),
        ("45mm", CGSize(width: 198, height: 242)),
        ("46mm", CGSize(width: 208, height: 248)),
        ("49mm", CGSize(width: 205, height: 251)),
    ]

    private func layout(_ screen: CGSize, _ size: DynamicTypeSize) -> WatchNowPlayingLayout {
        WatchNowPlayingLayout.decide(containerSize: WatchNowPlayingLayout.estimatedContainerSize(screen: screen),
                                     dynamicTypeSize: size)
    }

    // MARK: Layout

    func testSmallWatchesGoCompactAtTheDefaultTextSize() {
        XCTAssertEqual(layout(screens[0].size, .large).style, .compact)
        XCTAssertEqual(layout(screens[1].size, .large).style, .compact)
    }

    func testLargerWatchesKeepTheCoverAndDropToolCaptions() {
        for screen in screens[2...] {
            XCTAssertEqual(layout(screen.size, .large).style, .compactTools, screen.name)
        }
    }

    func testTheChosenLayoutFitsEveryWatchAtTheDefaultTextSize() {
        for screen in screens {
            let container = WatchNowPlayingLayout.estimatedContainerSize(screen: screen.size)
            let chosen = WatchNowPlayingLayout.decide(containerSize: container, dynamicTypeSize: .large)
            let height = WatchNowPlayingLayout.estimatedHeight(style: chosen.style, containerWidth: container.width,
                                                               dynamicTypeSize: .large)
            XCTAssertLessThanOrEqual(height, container.height, screen.name)
        }
    }

    func testRoomierStylesAtSmallerText() {
        XCTAssertEqual(layout(screens[4].size, .xSmall).style, .regular)   // 49 mm
        XCTAssertEqual(layout(screens[3].size, .small).style, .regular)    // 46 mm
        XCTAssertEqual(layout(screens[0].size, .xSmall).style, .compact)   // 40 mm stays compact
    }

    func testAccessibilitySizesAlwaysGetTheAccessibilityLayout() {
        for screen in screens {
            for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
                XCTAssertEqual(layout(screen.size, size).style, .accessibility, screen.name)
            }
        }
    }

    func testNothingFitsFallsBackToCompactAndAHugeScreenGetsRegular() {
        XCTAssertEqual(WatchNowPlayingLayout.decide(containerSize: CGSize(width: 150, height: 60), dynamicTypeSize: .large).style, .compact)
        XCTAssertEqual(WatchNowPlayingLayout.decide(containerSize: CGSize(width: 300, height: 400), dynamicTypeSize: .large).style, .regular)
    }

    func testToolTargetsNeverDropBelowTheHIGMinimum() {
        for style in [WatchNowPlayingLayoutStyle.regular, .compactTools, .compact, .accessibility] {
            XCTAssertGreaterThanOrEqual(WatchNowPlayingLayout(style: style).toolMinHeight, 28)
        }
        XCTAssertEqual(WatchNowPlayingLayout(style: .regular).toolMinHeight, 44)
        XCTAssertEqual(WatchNowPlayingLayout(style: .accessibility).toolMinHeight, 44)
    }

    func testWhatEachStyleSheds() {
        let compact = WatchNowPlayingLayout(style: .compact)
        XCTAssertFalse(compact.showsCover)
        XCTAssertEqual(compact.titleLineLimit, 1)
        XCTAssertFalse(compact.showsToolCaptions)
        XCTAssertEqual(compact.playSizeCap, WatchTransportLayout.minimumPlay)

        let tools = WatchNowPlayingLayout(style: .compactTools)
        XCTAssertTrue(tools.showsCover)
        XCTAssertEqual(tools.titleLineLimit, 2)
        XCTAssertFalse(tools.showsToolCaptions)
        XCTAssertNil(tools.playSizeCap)

        let regular = WatchNowPlayingLayout(style: .regular)
        XCTAssertTrue(regular.showsToolCaptions)
        XCTAssertNil(regular.playSizeCap)

        let accessibility = WatchNowPlayingLayout(style: .accessibility)
        XCTAssertFalse(accessibility.showsCover)
        XCTAssertFalse(accessibility.showsToolCaptions)
    }

    func testEstimatedContainerTakesOffTheTopBar() {
        XCTAssertEqual(WatchNowPlayingLayout.estimatedContainerSize(screen: CGSize(width: 162, height: 197)),
                       CGSize(width: 162, height: 153))
    }

    // MARK: Chapter window

    private let chapters = [
        WatchChapterRow(id: 0, title: "Opening", start: 0, end: 600),
        WatchChapterRow(id: 1, title: "  Middle  ", start: 600, end: 1500),
        WatchChapterRow(id: 2, title: "", start: 1500, end: 2000),
    ]

    func testResolvesTheChapterAndTrimsItsTitle() {
        let window = WatchChapterWindow.resolve(chapters: chapters, at: 900, duration: 2000)
        XCTAssertEqual(window.start, 600)
        XCTAssertEqual(window.end, 1500)
        XCTAssertEqual(window.chapterIndex, 1)
        XCTAssertEqual(window.title, "Middle")
        XCTAssertTrue(window.isChapter)
    }

    func testABlankChapterTitleIsNil() {
        let window = WatchChapterWindow.resolve(chapters: chapters, at: 1600, duration: 2000)
        XCTAssertTrue(window.isChapter)
        XCTAssertNil(window.title)
    }

    func testNoChaptersMeansTheWholeBook() {
        let window = WatchChapterWindow.resolve(chapters: [], at: 100, duration: 3600)
        XCTAssertFalse(window.isChapter)
        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.end, 3600)
        XCTAssertEqual(window.elapsed(at: 100), 100)
        XCTAssertEqual(window.remaining(at: 100), 3500)
    }

    func testInvalidChaptersAreIgnored() {
        let bad = [WatchChapterRow(id: 0, title: "Zero", start: 10, end: 10),
                   WatchChapterRow(id: 1, title: "Backwards", start: 50, end: 20),
                   WatchChapterRow(id: 2, title: "NaN", start: .nan, end: 30)]
        XCTAssertFalse(WatchChapterWindow.resolve(chapters: bad, at: 15, duration: 100).isChapter)
    }

    func testAGapBetweenChaptersFallsBackToTheWholeBook() {
        let gappy = [WatchChapterRow(id: 0, title: "A", start: 0, end: 100),
                     WatchChapterRow(id: 1, title: "B", start: 200, end: 300)]
        XCTAssertFalse(WatchChapterWindow.resolve(chapters: gappy, at: 150, duration: 300).isChapter)
    }

    func testTheLastChapterOwnsItsEnd() {
        let window = WatchChapterWindow.resolve(chapters: chapters, at: 2000, duration: 2000)
        XCTAssertEqual(window.chapterIndex, 2)
        XCTAssertEqual(window.remaining(at: 2000), 0)
        XCTAssertEqual(window.progress(at: 2000), 1)
    }

    func testABoundaryBelongsToTheNextChapter() {
        XCTAssertEqual(WatchChapterWindow.resolve(chapters: chapters, at: 600, duration: 2000).chapterIndex, 1)
        XCTAssertEqual(WatchChapterWindow.resolve(chapters: chapters, at: 599.9, duration: 2000).chapterIndex, 0)
    }

    func testElapsedRemainingAndProgressAreClampedToTheChapter() {
        let window = WatchChapterWindow.resolve(chapters: chapters, at: 900, duration: 2000)
        XCTAssertEqual(window.elapsed(at: 900), 300)
        XCTAssertEqual(window.remaining(at: 900), 600)
        XCTAssertEqual(window.progress(at: 900), 300.0 / 900.0, accuracy: 0.0001)
        XCTAssertEqual(window.elapsed(at: 100), 0)        // before the chapter
        XCTAssertEqual(window.elapsed(at: 1900), 900)     // after it
        XCTAssertEqual(window.remaining(at: 1900), 0)
        XCTAssertEqual(window.progress(at: .nan), 0)
    }

    func testAChapterRunningPastTheBookEndsWithTheBook() {
        let long = [WatchChapterRow(id: 0, title: "Only", start: 0, end: 5000)]
        XCTAssertEqual(WatchChapterWindow.resolve(chapters: long, at: 10, duration: 4000).end, 4000)
    }

    func testCrownRangeReachesOneSecondIntoThePreviousChapterAndUpToTheNext() {
        let middle = WatchChapterWindow.resolve(chapters: chapters, at: 900, duration: 2000)
        XCTAssertEqual(middle.crownRange(bookDuration: 2000), 599...1500)
        // Turning to either edge lands in the neighbour, so the window follows.
        XCTAssertEqual(WatchChapterWindow.resolve(chapters: chapters, at: 599, duration: 2000).chapterIndex, 0)
        XCTAssertEqual(WatchChapterWindow.resolve(chapters: chapters, at: 1500, duration: 2000).chapterIndex, 2)
    }

    func testCrownRangeStopsAtTheBooksEnds() {
        let first = WatchChapterWindow.resolve(chapters: chapters, at: 10, duration: 2000)
        XCTAssertEqual(first.crownRange(bookDuration: 2000), 0...600)
        let last = WatchChapterWindow.resolve(chapters: chapters, at: 1800, duration: 2000)
        XCTAssertEqual(last.crownRange(bookDuration: 2000), 1499...2000)
    }

    func testCrownRangeWithoutChaptersIsTheWholeBook() {
        XCTAssertEqual(WatchChapterWindow.wholeBook(duration: 3600).crownRange(bookDuration: 3600), 0...3600)
        XCTAssertEqual(WatchChapterWindow.wholeBook(duration: 0).crownRange(bookDuration: 0), 0...1)
    }

    func testSeeksCrossChaptersButNotTheBooksEnds() {
        XCTAssertEqual(WatchChapterWindow.clampedSeek(615, duration: 2000), 615)   // across 600
        XCTAssertEqual(WatchChapterWindow.clampedSeek(-15, duration: 2000), 0)
        XCTAssertEqual(WatchChapterWindow.clampedSeek(2015, duration: 2000), 2000)
        XCTAssertEqual(WatchChapterWindow.clampedSeek(.nan, duration: 2000), 0)
    }

    func testTheDisplayFollowsTheCrownOnlyWhileScrubbing() {
        XCTAssertEqual(WatchChapterWindow.displayTime(elapsed: 100, crownPosition: 700, isScrubbing: true), 700)
        XCTAssertEqual(WatchChapterWindow.displayTime(elapsed: 100, crownPosition: 700, isScrubbing: false), 100)
        XCTAssertEqual(WatchChapterWindow.displayTime(elapsed: 100, crownPosition: .nan, isScrubbing: true), 100)
    }
}
