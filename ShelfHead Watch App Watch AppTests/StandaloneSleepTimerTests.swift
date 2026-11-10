import XCTest
@testable import ShelfHead_Watch

/// PL-4 (docs/design-review.md): the pure half of standalone Watch chapters and sleep timer.
final class StandaloneSleepTimerTests: XCTestCase {
    private func chapters() throws -> [WatchChapter] {
        let json = #"[{"id":0,"start":0,"end":100,"title":"One"},{"id":1,"start":100,"end":250,"title":"Two"},{"id":2,"start":250,"end":400,"title":"Three"}]"#
        return try JSONDecoder().decode([WatchChapter].self, from: Data(json.utf8))
    }

    func testChapterLookupUsesHalfOpenRanges() throws {
        let c = try chapters()
        XCTAssertEqual(StandaloneSleepTimer.chapter(in: c, at: 0)?.id, 0)
        XCTAssertEqual(StandaloneSleepTimer.chapter(in: c, at: 99.9)?.id, 0)
        XCTAssertEqual(StandaloneSleepTimer.chapter(in: c, at: 100)?.id, 1)
        XCTAssertEqual(StandaloneSleepTimer.chapter(in: c, at: 400)?.id, 2, "the last chapter owns its end point")
        XCTAssertNil(StandaloneSleepTimer.chapter(in: c, at: 401))
        XCTAssertNil(StandaloneSleepTimer.chapter(in: [], at: 5))
    }

    func testMinutesTimerCountsPlayingSecondsOnly() throws {
        var timer = try XCTUnwrap(StandaloneSleepTimer.minutes(1))
        XCTAssertEqual(timer.secondsLeft(currentTime: 0), 60)
        timer.tick(seconds: 1)
        timer.tick(seconds: 1)
        XCTAssertEqual(timer.secondsLeft(currentTime: 1234), 58, "book position doesn't matter to a minutes timer")
        XCTAssertFalse(timer.isExpired(currentTime: 0))
        for _ in 0..<58 { timer.tick(seconds: 1) }
        XCTAssertTrue(timer.isExpired(currentTime: 0))
        timer.tick(seconds: 5)
        XCTAssertEqual(timer.secondsLeft(currentTime: 0), 0, "never goes negative")
    }

    func testNonPositiveMinutesIsNoTimer() {
        XCTAssertNil(StandaloneSleepTimer.minutes(0))
        XCTAssertNil(StandaloneSleepTimer.minutes(-5))
    }

    func testEndOfChapterTracksThePosition() throws {
        let c = try chapters()
        let timer = try XCTUnwrap(StandaloneSleepTimer.endOfChapter(chapters: c, at: 120))
        XCTAssertEqual(timer.option, .endOfChapter)
        XCTAssertEqual(timer.secondsLeft(currentTime: 120), 130)
        XCTAssertEqual(timer.secondsLeft(currentTime: 240), 10)
        XCTAssertTrue(timer.isExpired(currentTime: 250))
        var ticked = timer
        ticked.tick(seconds: 1)
        XCTAssertEqual(ticked.secondsLeft(currentTime: 120), 130, "ticking doesn't move a chapter timer")
    }

    func testEndOfChapterNeedsChapters() {
        XCTAssertNil(StandaloneSleepTimer.endOfChapter(chapters: [], at: 10))
    }

    func testFadeRampsOverTheLastTenSeconds() throws {
        var timer = try XCTUnwrap(StandaloneSleepTimer.minutes(1))
        XCTAssertEqual(timer.fadeVolume(currentTime: 0), 1)
        for _ in 0..<55 { timer.tick(seconds: 1) }   // 5 s left
        XCTAssertEqual(timer.fadeVolume(currentTime: 0), 0.5, accuracy: 0.001)
        for _ in 0..<5 { timer.tick(seconds: 1) }
        XCTAssertEqual(timer.fadeVolume(currentTime: 0), 0, accuracy: 0.001)
    }

    func testRemainingLabel() throws {
        var timer = try XCTUnwrap(StandaloneSleepTimer.minutes(15))
        XCTAssertEqual(timer.remainingLabel(currentTime: 0), "15m left")
        timer.tick(seconds: 30)
        XCTAssertEqual(timer.remainingLabel(currentTime: 0), "15m left", "14.5 minutes rounds up")
        for _ in 0..<(14 * 60 + 15) { timer.tick(seconds: 1) }
        XCTAssertEqual(timer.remainingLabel(currentTime: 0), "15s left")
    }
}
