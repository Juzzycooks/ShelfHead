import XCTest
@testable import ShelfHead

/// Tests for streak math and the UserDefaults-backed settings accessors.
/// The settings tests touch `UserDefaults.standard`; each cleans up the keys it uses.
final class StatsSettingsTests: XCTestCase {

    // MARK: - Date key helper (mirrors ListeningStats' formatter)

    private func dayKey(_ offset: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        return f.string(from: d)
    }

    // MARK: - ListeningStats.currentStreak

    func testCurrentStreakCountsConsecutiveDays() {
        let stats = ListeningStats(totalTime: nil, today: nil,
                                   days: [dayKey(0): 100, dayKey(-1): 100, dayKey(-2): 100])
        XCTAssertEqual(stats.currentStreak, 3)
    }

    func testCurrentStreakStartsYesterdayWhenTodayEmpty() {
        // No listening today yet → the streak counts from yesterday, not lost.
        let stats = ListeningStats(totalTime: nil, today: nil,
                                   days: [dayKey(-1): 100, dayKey(-2): 100])
        XCTAssertEqual(stats.currentStreak, 2)
    }

    func testCurrentStreakBreaksOnGap() {
        let stats = ListeningStats(totalTime: nil, today: nil,
                                   days: [dayKey(0): 100, dayKey(-1): 0, dayKey(-2): 100])
        XCTAssertEqual(stats.currentStreak, 1)
    }

    func testCurrentStreakZeroWhenNoDays() {
        XCTAssertEqual(ListeningStats(totalTime: nil, today: nil, days: nil).currentStreak, 0)
        XCTAssertEqual(ListeningStats(totalTime: nil, today: nil, days: [:]).currentStreak, 0)
    }

    // MARK: - ListeningStats.bestStreak

    func testBestStreakFindsLongestRun() {
        // A 2-day run and a 4-day run (with gaps between) → best is 4.
        let stats = ListeningStats(totalTime: nil, today: nil, days: [
            dayKey(-1): 5, dayKey(-2): 5,                                   // run of 2
            dayKey(-5): 5, dayKey(-6): 5, dayKey(-7): 5, dayKey(-8): 5      // run of 4
        ])
        XCTAssertEqual(stats.bestStreak, 4)
    }

    func testBestStreakIgnoresZeroDays() {
        let stats = ListeningStats(totalTime: nil, today: nil,
                                   days: [dayKey(-1): 0, dayKey(-2): 0])
        XCTAssertEqual(stats.bestStreak, 0)
    }

    // MARK: - SettingsStore.smartRewindAmount

    func testSmartRewindDisabledReturnsZero() {
        let original = UserDefaults.standard.object(forKey: SettingsKeys.smartRewind)
        defer { UserDefaults.standard.set(original, forKey: SettingsKeys.smartRewind) }

        UserDefaults.standard.set(false, forKey: SettingsKeys.smartRewind)
        XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: 3600), 0)
    }

    func testSmartRewindScalesWithPause() {
        let original = UserDefaults.standard.object(forKey: SettingsKeys.smartRewind)
        defer { UserDefaults.standard.set(original, forKey: SettingsKeys.smartRewind) }

        UserDefaults.standard.set(true, forKey: SettingsKeys.smartRewind)
        XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: 5), 0)      // < 10s
        XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: 30), 3)     // < 60s
        XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: 300), 5)    // < 10m
        XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: 1800), 10)  // < 1h
        XCTAssertEqual(SettingsStore.smartRewindAmount(pausedFor: 7200), 20)  // >= 1h
    }

    // MARK: - SettingsStore per-book speed

    func testPerBookSpeedRoundTrips() {
        defer { SettingsStore.clearPerBookSpeeds() }

        SettingsStore.setSpeed(1.5, forItem: "book_A")
        XCTAssertEqual(SettingsStore.speed(forItem: "book_A"), 1.5)
        XCTAssertEqual(SettingsStore.resolvedSpeed(forItem: "book_A"), 1.5)
    }

    func testResolvedSpeedFallsBackToDefault() {
        let original = UserDefaults.standard.object(forKey: SettingsKeys.defaultPlaybackSpeed)
        defer {
            UserDefaults.standard.set(original, forKey: SettingsKeys.defaultPlaybackSpeed)
            SettingsStore.clearPerBookSpeeds()
        }

        UserDefaults.standard.removeObject(forKey: SettingsKeys.defaultPlaybackSpeed)
        SettingsStore.clearPerBookSpeeds()
        // No per-book value and no global override → 1.0.
        XCTAssertEqual(SettingsStore.resolvedSpeed(forItem: "never_set"), 1.0)
    }

    func testClearPerBookSpeeds() {
        SettingsStore.setSpeed(2.0, forItem: "book_B")
        SettingsStore.clearPerBookSpeeds()
        XCTAssertNil(SettingsStore.speed(forItem: "book_B"))
    }

    func testPerBookSpeedKeepsLatestUnderCap() {
        defer { SettingsStore.clearPerBookSpeeds() }

        // Insert well beyond the internal cap; the most-recently-set entry must survive.
        for i in 0..<600 { SettingsStore.setSpeed(1.25, forItem: "cap_\(i)") }
        SettingsStore.setSpeed(1.75, forItem: "cap_final")
        XCTAssertEqual(SettingsStore.speed(forItem: "cap_final"), 1.75)
    }

    // MARK: - SettingsStore home-section hiding

    func testHomeSectionHideShow() {
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.hiddenHomeSections) }

        XCTAssertFalse(SettingsStore.isHomeSectionHidden("LabelRecentlyAdded"))
        SettingsStore.setHomeSection("LabelRecentlyAdded", hidden: true)
        XCTAssertTrue(SettingsStore.isHomeSectionHidden("LabelRecentlyAdded"))
        XCTAssertTrue(SettingsStore.hiddenHomeSections.contains("LabelRecentlyAdded"))
        SettingsStore.setHomeSection("LabelRecentlyAdded", hidden: false)
        XCTAssertFalse(SettingsStore.isHomeSectionHidden("LabelRecentlyAdded"))
    }

    // MARK: - SettingsStore home-section ordering

    func testHomeSectionOrderPersists() {
        let original = SettingsStore.homeSectionOrder
        defer { SettingsStore.setHomeSectionOrder(original) }

        // Deliberately no "starts empty" assertion. `TEST_HOST` is the app, so
        // `ShelfHeadApp.init()` runs before any test does, and its one-time settings
        // migration seeds a default order (`SettingsMigrator` step 2 — previously
        // `applyHomeDefaultOrderV3IfNeeded()`, which seeded identically) on every fresh
        // simulator clone. This test is about round-tripping a written order, which is
        // what it now checks; asserting the starting value only pinned whether the host
        // app had run its migrations yet.
        SettingsStore.setHomeSectionOrder(["yourWeek", "downloadedOffline", "LabelContinueListening"])
        XCTAssertEqual(SettingsStore.homeSectionOrder, ["yourWeek", "downloadedOffline", "LabelContinueListening"])
    }

    func testMergedHomeSectionOrderKeepsSavedOrderForAvailableKeys() {
        let saved = ["c", "a", "b"]
        let available = ["a", "b", "c"]
        XCTAssertEqual(SettingsStore.mergedHomeSectionOrder(saved: saved, available: available), ["c", "a", "b"])
    }

    func testMergedHomeSectionOrderDropsUnavailableSavedKeys() {
        // "d" was saved (e.g. a shelf that existed at the time) but the server no
        // longer returns it — it must not appear, and must not leave a gap.
        let saved = ["d", "a", "b"]
        let available = ["a", "b"]
        XCTAssertEqual(SettingsStore.mergedHomeSectionOrder(saved: saved, available: available), ["a", "b"])
    }

    func testMergedHomeSectionOrderAppendsNewlyAvailableKeys() {
        // "c" is newly available (e.g. the first-ever download) and has no saved
        // position — it should land at the end, in its own natural order, rather than
        // being silently dropped or inserted somewhere surprising.
        let saved = ["b", "a"]
        let available = ["a", "b", "c"]
        XCTAssertEqual(SettingsStore.mergedHomeSectionOrder(saved: saved, available: available), ["b", "a", "c"])
    }

    func testMergedHomeSectionOrderWithNoSavedOrderUsesAvailableOrder() {
        XCTAssertEqual(SettingsStore.mergedHomeSectionOrder(saved: [], available: ["x", "y", "z"]), ["x", "y", "z"])
    }

    // MARK: - SettingsStore per-series auto-download

    func testSeriesAutoDownloadToggle() {
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.seriesAutoDownload) }

        XCTAssertFalse(SettingsStore.seriesAutoDownloadEnabled("Wheel of Time"))
        SettingsStore.setSeriesAutoDownload(true, for: "Wheel of Time")
        XCTAssertTrue(SettingsStore.seriesAutoDownloadEnabled("Wheel of Time"))
        SettingsStore.setSeriesAutoDownload(false, for: "Wheel of Time")
        XCTAssertFalse(SettingsStore.seriesAutoDownloadEnabled("Wheel of Time"))
    }
}
