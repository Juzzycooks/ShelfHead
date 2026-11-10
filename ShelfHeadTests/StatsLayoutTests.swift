import XCTest
@testable import ShelfHead

// Critique 2026-10-06 (distill → layout): pins the Stats redesign's pure layout decisions —
// the Try Again skeleton, the figure row, the chart header and Y axis, the hero's last line
// and pace, and the heatmap's legend and level contrast.
@MainActor
final class StatsLayoutTests: XCTestCase {

    // MARK: - Screen phase (Try Again regression)

    func testTryAgainWithNoStatsShowsSkeletonNotZeroDashboard() {
        // Failure state: no stats, load failed.
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: false, loadFailed: true, hasStats: false), .failed)
        // Try Again: with nothing on screen the load starts on the skeleton...
        XCTAssertTrue(StatsScreenPhase.showsSkeletonWhileLoading(hasStats: false))
        // ...and while `isLoading` is set, the skeleton wins even though `loadFailed` was cleared.
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: true, loadFailed: false, hasStats: false), .skeleton)
    }

    func testRefreshOverCachedFiguresKeepsContent() {
        XCTAssertFalse(StatsScreenPhase.showsSkeletonWhileLoading(hasStats: true))
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: false, loadFailed: true, hasStats: true), .content)
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: false, loadFailed: false, hasStats: true), .content)
    }

    // MARK: - Formatting

    func testHoursFormatting() {
        XCTAssertEqual(StatsFormat.hours(0), "0m")
        XCTAssertEqual(StatsFormat.hours(45 * 60), "45m")
        XCTAssertEqual(StatsFormat.hours(230 * 3600 + 59 * 60), "230h 59m")
        XCTAssertEqual(StatsFormat.hours(-10), "0m")
    }

    func testSpokenDuration() {
        XCTAssertEqual(StatsFormat.spoken(230 * 3600 + 59 * 60), "230 hours 59 minutes")
        XCTAssertEqual(StatsFormat.spoken(3600), "1 hour")
        XCTAssertEqual(StatsFormat.spoken(60), "1 minute")
        XCTAssertEqual(StatsFormat.spoken(0), "0 minutes")
    }

    // MARK: - Figure row

    func testFigureRowItemsInOrderWithLabelsUnderneath() {
        let items = StatsFigureRow.items(monthSeconds: 230 * 3600 + 59 * 60, currentStreak: 1, bestStreak: 31, finished: 57)
        XCTAssertEqual(items.map(\.id), ["month", "streak", "best", "finished"])
        XCTAssertEqual(items.map(\.value), ["230h 59m", "1", "31", "57"])
        XCTAssertEqual(items.map(\.label), ["This month", "Day streak", "Best streak", "Finished"])
        XCTAssertEqual(items.filter(\.isFinished).map(\.id), ["finished"])
        XCTAssertEqual(items[1].spoken, "Current streak, 1 day")
        XCTAssertEqual(items[2].spoken, "Best streak, all time, 31 days")
        XCTAssertEqual(items[3].spoken, "57 books finished")
        XCTAssertEqual(StatsFigureRow.items(monthSeconds: 0, currentStreak: 0, bestStreak: 0, finished: 1)[3].spoken,
                       "1 book finished")
    }

    func testFigureRowBecomesListAtAccessibilitySizes() {
        XCTAssertEqual(StatsFigureRow.arrangement(isAccessibilitySize: true), .list)
        XCTAssertEqual(StatsFigureRow.arrangement(isAccessibilitySize: false), .adaptive)
    }

    // MARK: - Chart axis

    func testAxisUnitSwitchesToHoursPastTwoHours() {
        XCTAssertEqual(StatsChartAxis.unit(maxMinutes: 120), .minutes)
        XCTAssertEqual(StatsChartAxis.unit(maxMinutes: 121), .hours)
        XCTAssertEqual(StatsChartAxis.unit(maxMinutes: 3000), .hours)
    }

    func testAxisLabels() {
        XCTAssertEqual(StatsChartAxis.label(minutes: 90, unit: .minutes), "90m")
        XCTAssertEqual(StatsChartAxis.label(minutes: 3000, unit: .hours), "50h")
        XCTAssertEqual(StatsChartAxis.label(minutes: 90, unit: .hours), "1.5h")
    }

    func testAxisTicksAreRoundAndCoverTheMaximum() {
        XCTAssertEqual(StatsChartAxis.ticks(maxMinutes: 120), [0, 30, 60, 90, 120])
        XCTAssertEqual(StatsChartAxis.ticks(maxMinutes: 45), [0, 15, 30, 45])
        // 50 hours → 20-hour steps, labelled in hours.
        let year = StatsChartAxis.ticks(maxMinutes: 3000)
        XCTAssertEqual(year, [0, 1200, 2400, 3600])
        XCTAssertEqual(year.map { StatsChartAxis.label(minutes: $0, unit: .hours) }, ["0h", "20h", "40h", "60h"])
        // 2.5 hours → whole hours.
        XCTAssertEqual(StatsChartAxis.ticks(maxMinutes: 150), [0, 60, 120, 180])
        XCTAssertEqual(StatsChartAxis.ticks(maxMinutes: 0), [0])
        for maxMinutes in [1.0, 7, 59, 61, 119, 121, 500, 1440, 9000, 100_000] {
            let ticks = StatsChartAxis.ticks(maxMinutes: maxMinutes)
            XCTAssertGreaterThanOrEqual(ticks.last ?? 0, maxMinutes, "ticks must cover \(maxMinutes)")
            XCTAssertLessThanOrEqual(ticks.count, 5, "at most four steps above zero for \(maxMinutes)")
        }
    }

    func testChartHeaderTitles() {
        XCTAssertEqual(StatsChartAxis.title(for: .week), "This week")
        XCTAssertEqual(StatsChartAxis.title(for: .month), "Last 30 days")
        XCTAssertEqual(StatsChartAxis.title(for: .year), "Last 12 months")
    }

    // MARK: - Week comparison line

    func testWeekComparisonLine() {
        let up = StatsWeekComparison.line(thisWeek: 138 * 60, lastWeek: 100 * 60, hasEarlierData: true)
        XCTAssertEqual(up.text, "+38% vs last week (1h 40m)")
        XCTAssertEqual(up.spoken, "Up 38% from last week’s 1h 40m")
        let down = StatsWeekComparison.line(thisWeek: 50 * 60, lastWeek: 100 * 60, hasEarlierData: true)
        XCTAssertEqual(down.text, "\u{2212}50% vs last week (1h 40m)")
        XCTAssertTrue(down.spoken.hasPrefix("Down 50%"))
        XCTAssertTrue(StatsWeekComparison.line(thisWeek: 102 * 60, lastWeek: 100 * 60, hasEarlierData: true)
            .text.hasPrefix("About the same"))
        XCTAssertEqual(StatsWeekComparison.line(thisWeek: 60, lastWeek: 0, hasEarlierData: true).text, "No listening last week")
        XCTAssertEqual(StatsWeekComparison.line(thisWeek: 60, lastWeek: 0, hasEarlierData: false).text, "First week with data logged")
    }

    // MARK: - Hero line and pace

    func testHeroLinePrefersPaceThenSessions() {
        XCTAssertEqual(StatsHeroLine.choose(pace: "At this pace…", sessionSummary: "42m average session"), .pace("At this pace…"))
        XCTAssertEqual(StatsHeroLine.choose(pace: nil, sessionSummary: "42m average session"), .sessions("42m average session"))
        XCTAssertEqual(StatsHeroLine.choose(pace: "", sessionSummary: nil), .none)
    }

    func testPaceDaysToFinish() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DayKey.makeFormatter(timeZone: cal.timeZone)
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let days = [f.string(from: today): 3600.0, f.string(from: yesterday): 1800.0]
        // Average 45 min/day over the two active days; 5 h left → 6.67 → 7 days.
        XCTAssertEqual(StatsPace.daysToFinish(remainingSeconds: 5 * 3600, days: days, today: today,
                                              calendar: cal, keyFormatter: f), 7)
        // Essentially finished, or no recent listening → no pace.
        XCTAssertNil(StatsPace.daysToFinish(remainingSeconds: 300, days: days, today: today, calendar: cal, keyFormatter: f))
        XCTAssertNil(StatsPace.daysToFinish(remainingSeconds: 5 * 3600, days: [:], today: today, calendar: cal, keyFormatter: f))
        let old = cal.date(byAdding: .day, value: -10, to: today)!
        XCTAssertNil(StatsPace.daysToFinish(remainingSeconds: 5 * 3600, days: [f.string(from: old): 3600],
                                            today: today, calendar: cal, keyFormatter: f))
    }

    func testPaceSentence() {
        XCTAssertEqual(StatsPace.sentence(title: "Dune", days: 6),
                       "At this pace you\u{2019}ll finish \u{201C}Dune\u{201D} in about 6 days.")
        XCTAssertTrue(StatsPace.sentence(title: "Dune", days: 1).hasSuffix("about 1 day."))
    }

    // MARK: - Heatmap legend and contrast

    func testHeatmapLegendStatesTheLevelThresholds() {
        XCTAssertEqual(ListeningHeatmap.legendLabels, ["None", "Under 15", "15\u{2013}30", "30\u{2013}60", "60+"])
        XCTAssertEqual(ListeningHeatmap.legendLabels.count, 5) // one per level 0...4
        // The legend's boundaries are the ones `level(minutes:)` uses.
        for (index, threshold) in ListeningHeatmap.thresholds.enumerated() {
            XCTAssertEqual(ListeningHeatmap.level(minutes: threshold - 0.5), index + 1)
            XCTAssertEqual(ListeningHeatmap.level(minutes: threshold), index + 2)
        }
        XCTAssertTrue(ListeningHeatmap.legendSpoken.contains("under 15"))
    }

    func testHeatmapLevelOneClearsThreeToOneAgainstEmptyForEveryAccentAndAppearance() {
        for accent in AppTheme.accentOptions {
            for dark in [false, true] {
                let fills = ListeningHeatmap.levelFillHexes(accentHex: accent.hex, dark: dark)
                XCTAssertEqual(fills.count, 5)
                let ratio = HeatmapColor.contrast(fills[1], fills[0])
                XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(accent.name) \(dark ? "Dark" : "Light"): level 1 vs empty \(ratio)")
                // Each level stands further from empty than the one before it.
                let ratios = fills.dropFirst().map { HeatmapColor.contrast($0, fills[0]) }
                XCTAssertEqual(ratios, ratios.sorted(), "\(accent.name) \(dark ? "Dark" : "Light") ramp is monotonic")
            }
        }
    }

    func testHeatmapDarkTopLevelIsTheRawAccent() {
        // In Dark the accent already clears the target, so the top step is the accent itself.
        XCTAssertEqual(ListeningHeatmap.levelFillHexes(accentHex: "E8A838", dark: true)[4], "E8A838")
    }
}
