import XCTest
@testable import ShelfHead

final class ListeningHeatmapTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    // Fixed "today": Wednesday 2026-09-16 (matches this batch's date).
    private var today: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 16
        comps.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: comps)!
    }

    func testLevelThresholds() {
        XCTAssertEqual(ListeningHeatmap.level(minutes: 0), 0)
        XCTAssertEqual(ListeningHeatmap.level(minutes: 14), 1)
        XCTAssertEqual(ListeningHeatmap.level(minutes: 29), 2)
        XCTAssertEqual(ListeningHeatmap.level(minutes: 59), 3)
        XCTAssertEqual(ListeningHeatmap.level(minutes: 60), 4)
        XCTAssertEqual(ListeningHeatmap.level(minutes: 120), 4)
    }

    func testWeeksReturnsRequestedColumnCount() {
        let weeks = ListeningHeatmap.weeks(days: [:], weekCount: 20, today: today, calendar: calendar)
        XCTAssertEqual(weeks.count, 20)
    }

    func testFirstColumnHasSevenCells() {
        let weeks = ListeningHeatmap.weeks(days: [:], weekCount: 20, today: today, calendar: calendar)
        XCTAssertEqual(weeks.first?.count, 7)
    }

    func testLastColumnEndsAtToday() throws {
        let weeks = ListeningHeatmap.weeks(days: [:], weekCount: 20, today: today, calendar: calendar)
        let lastCell = try XCTUnwrap(weeks.last?.last)
        XCTAssertEqual(calendar.startOfDay(for: lastCell.date), calendar.startOfDay(for: today))
    }

    func testMinutesConvertedFromSeconds() {
        let key = "2026-09-16"
        let weeks = ListeningHeatmap.weeks(days: [key: 3600], weekCount: 1, today: today, calendar: calendar)
        let cell = try? XCTUnwrap(weeks.last?.last)
        XCTAssertEqual(cell?.minutes, 60)
        XCTAssertEqual(cell?.level, 4)
    }

    func testMissingDayIsZeroLevel() {
        let weeks = ListeningHeatmap.weeks(days: [:], weekCount: 1, today: today, calendar: calendar)
        let cell = try? XCTUnwrap(weeks.last?.last)
        XCTAssertEqual(cell?.minutes, 0)
        XCTAssertEqual(cell?.level, 0)
    }

    func testMonthLabelsMarkFirstColumnAndMonthChanges() {
        let weeks = ListeningHeatmap.weeks(days: [:], weekCount: 20, today: today, calendar: calendar)
        let labels = ListeningHeatmap.monthLabels(for: weeks, calendar: calendar)
        XCTAssertEqual(labels.first?.column, 0)
        // Every emitted column's first cell's month must differ from the previous
        // labeled column's, i.e. no consecutive duplicate labels.
        for i in 1..<labels.count {
            XCTAssertNotEqual(labels[i].label, labels[i - 1].label)
        }
    }
}
