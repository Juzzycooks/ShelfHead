import XCTest
@testable import ShelfHead

/// Pins the player's sleep-timer menu grouping (critique 2026-10-05, distill): at most four
/// picks at the top level, the rest under "More", nothing lost from the old dialog except
/// "Off" (which became the active-only "Turn Off" action).
final class SleepTimerMenuTests: XCTestCase {

    func testTopLevelHoldsAtMostFourPicks() {
        XCTAssertEqual(SleepTimerOption.menuQuickPicks(hasChapters: true),
                       [.minutes(15), .minutes(30), .minutes(60), .endOfChapter])
        XCTAssertLessThanOrEqual(SleepTimerOption.menuQuickPicks(hasChapters: true).count, 4)
    }

    func testEveryPresetExceptOffIsStillReachable() {
        let menu = SleepTimerOption.menuQuickPicks(hasChapters: true) + SleepTimerOption.menuMorePicks(hasChapters: true)
        let expected = SleepTimerOption.presets.filter { $0 != .off }
        XCTAssertEqual(menu.count, expected.count)
        for option in expected {
            XCTAssertTrue(menu.contains(option), "\(option.label) missing from the menu")
        }
        XCTAssertFalse(menu.contains(.off))
    }

    func testChapterOptionsAreHiddenWithoutChapters() {
        let menu = SleepTimerOption.menuQuickPicks(hasChapters: false) + SleepTimerOption.menuMorePicks(hasChapters: false)
        XCTAssertFalse(menu.contains(.endOfChapter))
        XCTAssertFalse(menu.contains(.chapters(1)))
        XCTAssertFalse(menu.contains(.chapters(2)))
        XCTAssertTrue(menu.contains(.endOfBook))
    }

    func testMenuRowsHaveUniqueLabels() {
        // The menu's `ForEach` is keyed by label.
        let labels = (SleepTimerOption.menuQuickPicks(hasChapters: true) + SleepTimerOption.menuMorePicks(hasChapters: true)).map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
