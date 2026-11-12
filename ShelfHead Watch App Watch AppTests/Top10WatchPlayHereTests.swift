// XCTest, as every sibling file. REVIEW 2026-11-11 W3: pins the decisions behind
// "Play on This Watch" on companion Now Playing and the out-of-range handling.
import XCTest
@testable import ShelfHead_Watch

final class Top10WatchPlayHereTests: XCTestCase {

    func testCanPlayOnWatchWhenDownloadedOrSignedIn() {
        XCTAssertTrue(WatchPhoneLinkDecision.canPlayOnWatch(isDownloaded: true, hasWatchSession: false))
        XCTAssertTrue(WatchPhoneLinkDecision.canPlayOnWatch(isDownloaded: false, hasWatchSession: true))
        XCTAssertFalse(WatchPhoneLinkDecision.canPlayOnWatch(isDownloaded: false, hasWatchSession: false))
    }

    func testOutOfRangeNeedsUnreachableAndStale() {
        XCTAssertTrue(WatchPhoneLinkDecision.isOutOfRange(isReachable: false, isStateStale: true))
        XCTAssertFalse(WatchPhoneLinkDecision.isOutOfRange(isReachable: false, isStateStale: false), "just dropped")
        XCTAssertFalse(WatchPhoneLinkDecision.isOutOfRange(isReachable: true, isStateStale: true), "paused phone, only syncing")
    }

    func testSyncingBannerYieldsToOutOfRange() {
        XCTAssertTrue(WatchPhoneLinkDecision.showsSyncingBanner(isStateStale: true, isOutOfRange: false))
        XCTAssertFalse(WatchPhoneLinkDecision.showsSyncingBanner(isStateStale: true, isOutOfRange: true))
        XCTAssertFalse(WatchPhoneLinkDecision.showsSyncingBanner(isStateStale: false, isOutOfRange: false))
    }

    func testNoticeIsPersistentOutOfRangeWithButtonOnlyWhenPlayable() {
        XCTAssertEqual(WatchPhoneLinkDecision.notice(isOutOfRange: true, failedCommandNotice: false, canPlayOnWatch: true),
                       .init(isOutOfRange: true, offersPlayOnWatch: true))
        XCTAssertEqual(WatchPhoneLinkDecision.notice(isOutOfRange: true, failedCommandNotice: false, canPlayOnWatch: false),
                       .init(isOutOfRange: true, offersPlayOnWatch: false))
        XCTAssertEqual(WatchPhoneLinkDecision.notice(isOutOfRange: false, failedCommandNotice: true, canPlayOnWatch: true),
                       .init(isOutOfRange: false, offersPlayOnWatch: true))
        XCTAssertNil(WatchPhoneLinkDecision.notice(isOutOfRange: false, failedCommandNotice: false, canPlayOnWatch: true))
    }

    func testExtrapolationFreezesWhenStale() {
        let last = Date(timeIntervalSince1970: 1_000)
        let now = last.addingTimeInterval(300)
        XCTAssertEqual(WatchPhoneLinkDecision.extrapolationDate(now: now, lastUpdated: last, isStateStale: true), last)
        XCTAssertEqual(WatchPhoneLinkDecision.extrapolationDate(now: now, lastUpdated: last, isStateStale: false), now)
        // Clock skew: a snapshot "from the future" never pushes the estimate past now.
        XCTAssertEqual(WatchPhoneLinkDecision.extrapolationDate(now: last, lastUpdated: now, isStateStale: true), last)
    }
}
