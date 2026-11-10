import XCTest
@testable import ShelfHead

/// Batch 406: the pure decisions behind background app refresh.
final class BackgroundRefreshSchedulerTests: XCTestCase {
    func testRunsWhenSignedInAndOnline() {
        XCTAssertEqual(BackgroundRefreshScheduler.shouldRun(signedIn: true, hasNetwork: true), .run)
    }

    func testSkipsWhenSignedOut() {
        XCTAssertEqual(BackgroundRefreshScheduler.shouldRun(signedIn: false, hasNetwork: true), .skipSignedOut)
    }

    func testSkipsWhenOffline() {
        XCTAssertEqual(BackgroundRefreshScheduler.shouldRun(signedIn: true, hasNetwork: false), .skipOffline)
    }

    func testSignedOutOutranksOffline() {
        XCTAssertEqual(BackgroundRefreshScheduler.shouldRun(signedIn: false, hasNetwork: false), .skipSignedOut)
    }

    func testCancellationWinsOverEverything() {
        XCTAssertEqual(
            BackgroundRefreshScheduler.shouldRun(signedIn: true, hasNetwork: true, isCancelled: true),
            .skipCancelled)
    }

    func testIntervals() {
        XCTAssertEqual(BackgroundRefreshScheduler.refreshInterval(lastRunWasIdle: false), 2 * 3600)
        XCTAssertEqual(BackgroundRefreshScheduler.refreshInterval(lastRunWasIdle: true), 4 * 3600)
        XCTAssertEqual(BackgroundRefreshScheduler.refreshInterval(lastRunWasIdle: false, signedIn: false), 6 * 3600)
    }

    func testIntervalStaysWithinOneToSixHours() {
        for idle in [true, false] {
            for signedIn in [true, false] {
                let i = BackgroundRefreshScheduler.refreshInterval(lastRunWasIdle: idle, signedIn: signedIn)
                XCTAssertGreaterThanOrEqual(i, 3600)
                XCTAssertLessThanOrEqual(i, 6 * 3600)
            }
        }
    }

    func testNextEarliestBeginDateIsNowPlusInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            BackgroundRefreshScheduler.nextEarliestBeginDate(now: now, lastRunWasIdle: false),
            now.addingTimeInterval(2 * 3600))
    }

    func testIdentifierMatchesInfoPlist() {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        XCTAssertEqual(ids?.contains(BackgroundRefreshScheduler.identifier), true)
    }
}
