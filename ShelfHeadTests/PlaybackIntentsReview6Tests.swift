import XCTest
@testable import ShelfHead

final class PlaybackIntentsReview6Tests: XCTestCase {
    func testDownloadsFirstWhenOfflineOrServerDown() {
        XCTAssertTrue(PlaybackCoordinator.shouldTryDownloadsFirst(status: .serverUnreachable, deviceIsOnline: true))
        XCTAssertTrue(PlaybackCoordinator.shouldTryDownloadsFirst(status: .ok, deviceIsOnline: false))
        XCTAssertTrue(PlaybackCoordinator.shouldTryDownloadsFirst(status: .offline, deviceIsOnline: true))
        XCTAssertFalse(PlaybackCoordinator.shouldTryDownloadsFirst(status: .ok, deviceIsOnline: true))
    }

    func testMostRecentStartedPicksLatestStartedUnfinished() {
        typealias B = (id: String, last: Double?, pos: Double, dur: Double)
        let books: [B] = [("a", 100, 50, 1000), ("b", 300, 0, 1000), ("c", 200, 999.5, 1000), ("d", 150, 10, 1000)]
        let r = PlaybackCoordinator.mostRecentStarted(in: books, lastPlayed: { $0.last }, position: { $0.pos }, duration: { $0.dur })
        XCTAssertEqual(r?.id, "d")
    }

    func testMostRecentStartedNilWhenNothingStarted() {
        let books: [(last: Double?, pos: Double, dur: Double)] = [(5, 0, 100)]
        XCTAssertNil(PlaybackCoordinator.mostRecentStarted(in: books, lastPlayed: { $0.last }, position: { $0.pos }, duration: { $0.dur }))
    }
}
