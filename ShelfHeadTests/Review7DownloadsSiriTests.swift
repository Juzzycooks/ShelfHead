import XCTest
@testable import ShelfHead

// Review 7 (Batch 478): stale reachability and the bounded server race.
final class Review7DownloadsSiriTests: XCTestCase {
    func testTrustedStatusIgnoresStaleOrMissingProbe() {
        let now = Date()
        XCTAssertEqual(ReachabilityStore.trustedStatus(.serverUnreachable, lastCheckedAt: nil, now: now), .ok)
        XCTAssertEqual(ReachabilityStore.trustedStatus(.offline, lastCheckedAt: now.addingTimeInterval(-300), now: now), .ok)
        XCTAssertEqual(ReachabilityStore.trustedStatus(.serverUnreachable, lastCheckedAt: now.addingTimeInterval(-30), now: now), .serverUnreachable)
    }

    func testServerRaceReturnsNilOnTimeoutAndThrow() async {
        let slow: Int? = await PlaybackCoordinator.serverRace(seconds: 0.1) {
            try await Task.sleep(nanoseconds: 2_000_000_000); return 1
        }
        XCTAssertNil(slow)
        struct E: Error {}
        let thrown: Int? = await PlaybackCoordinator.serverRace(seconds: 1) { throw E() }
        XCTAssertNil(thrown)
        let ok: Int? = await PlaybackCoordinator.serverRace(seconds: 1) { 7 }
        XCTAssertEqual(ok, 7)
    }
}
