// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and every sibling file in
// this target.
//
// Batch 410 (Watch redesign, The Shelf): pins the pure decisions behind the shared Now
// Playing sheets — the speed list, the current-chapter rule the Chapters sheet opens on,
// and the header cover size now that the screen fits one viewport.
import XCTest
@testable import ShelfHead_Watch

final class WatchNowPlayingSheetDecisionsTests: XCTestCase {

    // MARK: - Sheets

    func testSheetIdsAreDistinct() {
        let ids = WatchNowPlayingSheet.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "sheet(item:) needs a distinct id per sheet")
    }

    // MARK: - Speed options

    func testStandardSpeedsSpanThePhonesClamp() {
        let speeds = WatchSpeedOptions.standard
        XCTAssertEqual(speeds.first, 0.5)
        XCTAssertEqual(speeds.last, 3.0)
        XCTAssertEqual(speeds, speeds.sorted(), "the sheet lists slowest first")
        XCTAssertEqual(Set(speeds).count, speeds.count, "no duplicate rows")
    }

    func testStandardSpeedsIncludeTheOldPresets() {
        // `WatchSpeedCycler.speeds` was the whole choice before the sheet.
        for preset in WatchSpeedCycler.speeds {
            XCTAssertTrue(WatchSpeedOptions.standard.contains { WatchSpeedOptions.matches($0, preset) },
                          "\(preset)× should still be one tap away")
        }
    }

    func testStandardSpeedsHaveNoFloatingPointNoise() {
        // stride(by: 0.1) in Double would give 0.7999999…; the list is built from tenths.
        XCTAssertTrue(WatchSpeedOptions.standard.contains(0.8))
        XCTAssertTrue(WatchSpeedOptions.standard.contains(1.1))
        XCTAssertEqual(WatchSpeedCycler.label(for: WatchSpeedOptions.standard[3]), "0.8×")
    }

    func testCustomPhoneRateIsAddedInOrder() {
        let options = WatchSpeedOptions.options(including: 1.15)
        XCTAssertEqual(options.count, WatchSpeedOptions.standard.count + 1)
        XCTAssertTrue(options.contains(1.15), "the current speed is always a row")
        XCTAssertEqual(options, options.sorted())
    }

    func testListedRateIsNotDuplicated() {
        XCTAssertEqual(WatchSpeedOptions.options(including: 1.25), WatchSpeedOptions.standard)
        XCTAssertEqual(WatchSpeedOptions.options(including: 1.0000001), WatchSpeedOptions.standard,
                       "rounding noise from the phone's snapshot isn't a new row")
    }

    func testOutOfRangeOrMissingRateLeavesTheList() {
        XCTAssertEqual(WatchSpeedOptions.options(including: nil), WatchSpeedOptions.standard)
        XCTAssertEqual(WatchSpeedOptions.options(including: 4.0), WatchSpeedOptions.standard)
        XCTAssertEqual(WatchSpeedOptions.options(including: .nan), WatchSpeedOptions.standard)
    }

    // MARK: - Current chapter

    private let chapters = [
        WatchChapterRow(id: 0, title: "One", start: 0, end: 100),
        WatchChapterRow(id: 1, title: "Two", start: 100, end: 250),
        WatchChapterRow(id: 2, title: "Three", start: 250, end: 400),
    ]

    func testCurrentChapterIsHalfOpen() {
        XCTAssertEqual(WatchChapterRow.current(in: chapters, at: 0)?.id, 0)
        XCTAssertEqual(WatchChapterRow.current(in: chapters, at: 99.9)?.id, 0)
        XCTAssertEqual(WatchChapterRow.current(in: chapters, at: 100)?.id, 1, "a boundary belongs to the next chapter")
    }

    func testLastChapterOwnsTheBooksEnd() {
        XCTAssertEqual(WatchChapterRow.current(in: chapters, at: 400)?.id, 2)
        XCTAssertNil(WatchChapterRow.current(in: chapters, at: 401))
        XCTAssertNil(WatchChapterRow.current(in: [], at: 10))
    }

    func testCurrentChapterMatchesTheStandaloneSleepRule() {
        // The Chapters sheet and End of Chapter must agree on "this chapter".
        let engineChapters = chapters.map { (start: $0.start, end: $0.end) }
        for time in stride(from: 0.0, through: 400, by: 12.5) {
            let shared = WatchChapterRow.current(in: chapters, at: time)
            let index = engineChapters.firstIndex { time >= $0.start && time < $0.end }
                ?? (time == engineChapters.last?.end ? engineChapters.count - 1 : nil)
            XCTAssertEqual(shared?.id, index, "at \(time)s")
        }
    }

    // MARK: - Short sleep text

    func testShortSleepTextMatchesTheLongFormsRounding() {
        XCTAssertEqual(WatchSleepStatus.shortText(seconds: 1_380), "23m")
        XCTAssertEqual(WatchSleepStatus.shortText(seconds: 870), "15m", "rounds up like remainingText")
        XCTAssertEqual(WatchSleepStatus.shortText(seconds: 30), "30s")
        XCTAssertNil(WatchSleepStatus.shortText(seconds: 0))
        XCTAssertNil(WatchSleepStatus.shortText(seconds: .nan))
    }

    // MARK: - Header cover

    func testCoverKeepsAThumbnailOnTheSmallestScreen() {
        // 40 mm: 162 × 197 pt.
        XCTAssertEqual(WatchNowPlayingHeaderLayout.coverSide(screenWidth: 162, screenHeight: 197),
                       WatchNowPlayingHeaderLayout.minimumCoverSide)
    }

    func testCoverGrowsWithTheScreenUpToTheBriefsShare() {
        let w41 = WatchNowPlayingHeaderLayout.coverSide(screenWidth: 176, screenHeight: 215)
        let w45 = WatchNowPlayingHeaderLayout.coverSide(screenWidth: 198, screenHeight: 242)
        let ultra = WatchNowPlayingHeaderLayout.coverSide(screenWidth: 205, screenHeight: 251)
        XCTAssertLessThanOrEqual(w41, w45)
        XCTAssertLessThanOrEqual(w45, ultra)
        XCTAssertGreaterThan(ultra, WatchNowPlayingHeaderLayout.minimumCoverSide)
        XCTAssertLessThanOrEqual(ultra, (205 * 0.45).rounded(.down), "never past 45% of the width")
    }
}
