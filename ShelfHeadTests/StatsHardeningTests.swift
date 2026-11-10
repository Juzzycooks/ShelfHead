import XCTest
@testable import ShelfHead

// Critique 2026-10-06 (harden): pins the Stats / Year in Review fixes that are pure logic —
// the shared POSIX day key, the stale-figures wording, the January default year, and the
// "unavailable, not 0" session-derived cards.
final class StatsHardeningTests: XCTestCase {

    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    private func gregorianDate(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: - Day key

    func testDayKeyParsesAndFormatsGregorianRegardlessOfDeviceCalendar() {
        let f = DayKey.makeFormatter(timeZone: utc)
        let parsed = f.date(from: "2026-10-06")
        XCTAssertNotNil(parsed)
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = utc
        let c = greg.dateComponents([.year, .month, .day], from: parsed!)
        XCTAssertEqual([c.year, c.month, c.day], [2026, 10, 6])
        XCTAssertEqual(f.string(from: gregorianDate(2026, 10, 6)), "2026-10-06")
        XCTAssertEqual(f.locale.identifier, "en_US_POSIX")
    }

    func testHeatmapKeysSurviveBuddhistCalendar() {
        // A Buddhist-calendar device would have written "2569-10-06" with the old,
        // calendar-adopting formatter and found no data at all.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = utc
        let today = gregorianDate(2026, 10, 6)
        let weeks = ListeningHeatmap.weeks(days: ["2026-10-06": 1800], weekCount: 2, today: today, calendar: buddhist)
        let cells = weeks.flatMap { $0 }
        XCTAssertTrue(cells.contains { $0.id == "2026-10-06" })
        XCTAssertEqual(cells.first { $0.id == "2026-10-06" }?.minutes, 30)
    }

    func testHeatmapKeysSurviveJapaneseCalendar() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = utc
        japanese.locale = Locale(identifier: "ja_JP@calendar=japanese")
        let weeks = ListeningHeatmap.weeks(days: ["2026-10-06": 600], weekCount: 1, today: gregorianDate(2026, 10, 6), calendar: japanese)
        XCTAssertEqual(weeks.flatMap { $0 }.first { $0.id == "2026-10-06" }?.minutes, 10)
    }

    // MARK: - Stale figures wording

    func testStaleMessageDistinguishesOfflineFromUnreachable() {
        let now = gregorianDate(2026, 10, 6)
        let then = now.addingTimeInterval(-5 * 60)
        let offline = StatsStaleness.message(asOf: then, now: now, status: .offline)
        let down = StatsStaleness.message(asOf: then, now: now, status: .serverUnreachable)
        XCTAssertTrue(offline.hasPrefix("Showing figures from "))
        XCTAssertTrue(offline.hasSuffix("You\u{2019}re offline."))
        XCTAssertTrue(down.hasSuffix("Can\u{2019}t reach your server."))
        XCTAssertNotEqual(offline, down)
    }

    func testStaleMessageWithoutTimestampStillReads() {
        let msg = StatsStaleness.message(asOf: nil, now: Date(), status: .serverUnreachable)
        XCTAssertEqual(msg, "Showing earlier figures. Can\u{2019}t reach your server.")
    }

    func testStaleMessageDoesNotBlameServerWhenReachabilityIsOK() {
        let now = gregorianDate(2026, 10, 6)
        let msg = StatsStaleness.message(asOf: now.addingTimeInterval(-300), now: now, status: .ok)
        XCTAssertTrue(msg.hasPrefix("Couldn\u{2019}t refresh. Showing figures from "))
        XCTAssertFalse(msg.contains("server"))
        XCTAssertEqual(StatsStaleness.message(asOf: nil, now: now, status: .ok),
                       "Couldn\u{2019}t refresh. Showing earlier figures.")
    }

    func testFirstWeekOnlyWhenNoEarlierData() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let now = gregorianDate(2026, 10, 6)
        XCTAssertFalse(StatsWeekComparison.hasDataBeforeLastWeek(days: [:], now: now, calendar: cal))
        XCTAssertFalse(StatsWeekComparison.hasDataBeforeLastWeek(days: ["2026-10-05": 600], now: now, calendar: cal))
        XCTAssertTrue(StatsWeekComparison.hasDataBeforeLastWeek(days: ["2026-08-01": 600], now: now, calendar: cal))
        XCTAssertFalse(StatsWeekComparison.hasDataBeforeLastWeek(days: ["2026-08-01": 0], now: now, calendar: cal))
    }

    func testFailureSubtitlesAreDistinct() {
        let subtitles = Set([ReachabilityStore.Status.offline, .serverUnreachable, .ok]
            .map { StatsStaleness.failureSubtitle(status: $0) })
        XCTAssertEqual(subtitles.count, 3)
        XCTAssertFalse(subtitles.contains { $0.contains("Check your connection") })
    }

    // MARK: - Default year

    func testDefaultYearInJanuaryFallsBackWhenCurrentYearEmpty() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let jan = gregorianDate(2027, 1, 3)
        XCTAssertEqual(YearInReviewView.defaultYear(now: jan, days: ["2026-12-30": 600], calendar: cal), 2026)
        XCTAssertEqual(YearInReviewView.defaultYear(now: jan, days: ["2027-01-02": 600], calendar: cal), 2027)
        XCTAssertEqual(YearInReviewView.defaultYear(now: jan, days: ["2027-01-02": 0], calendar: cal), 2026)
    }

    func testDefaultYearOutsideJanuaryIsCurrent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        XCTAssertEqual(YearInReviewView.defaultYear(now: gregorianDate(2026, 10, 6), days: [:], calendar: cal), 2026)
    }

    // MARK: - Sessions unavailable

    func testUnavailableSessionsShowDashNotZero() {
        let cards = YearInReviewView.buildCards(
            year: 2026,
            totalSeconds: 3600,
            distinctBooks: 0,
            topAuthor: nil,
            longestSessionSeconds: 0,
            bestStreakDays: 3,
            monthlyBars: [Bar(label: "Jan", minutes: 60)],
            sessionsMayBeIncomplete: false,
            incompleteSessionsNote: "note",
            sessionsUnavailable: true
        )
        let books = cards.first { $0.kind == .booksListened }
        let longest = cards.first { $0.kind == .longestSession }
        XCTAssertEqual(books?.value, YearInReviewView.unavailableValue)
        XCTAssertEqual(longest?.value, YearInReviewView.unavailableValue)
        XCTAssertNotNil(books?.incompleteNote)
        // Listening time comes from stats, not sessions, so it stays real.
        XCTAssertEqual(cards.first { $0.kind == .totalListened }?.value, "1h 0m")
    }

    func testAvailableSessionsStillShowCounts() {
        let cards = YearInReviewView.buildCards(
            year: 2026, totalSeconds: 0, distinctBooks: 0, topAuthor: nil, longestSessionSeconds: 0,
            bestStreakDays: 0, monthlyBars: [], sessionsMayBeIncomplete: false, incompleteSessionsNote: "note")
        XCTAssertEqual(cards.first { $0.kind == .booksListened }?.value, "0")
    }
}
