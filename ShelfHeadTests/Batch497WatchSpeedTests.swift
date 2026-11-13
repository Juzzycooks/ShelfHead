import XCTest
@testable import ShelfHead

/// Batch 497 (REVIEW 2026-11-11 W7): the iPhone half of the Watch's per-book speed. The
/// Watch sends `WatchBookSpeedUpdate` with `transferUserInfo`; `WatchSessionManager`
/// stores what `acceptedRate` allows with `SettingsStore.setSpeed(_:forItem:)`.
final class Batch497WatchSpeedTests: XCTestCase {

    func testAPlainSpeedIsAccepted() {
        XCTAssertEqual(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 1.5, isCoordinatingPlayback: false), 1.5)
    }

    func testNeverDuringSharePlay() {
        XCTAssertNil(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 1.5, isCoordinatingPlayback: true))
    }

    func testJunkIsDropped() {
        XCTAssertNil(WatchBookSpeedUpdate.acceptedRate(itemId: "", rate: 1.5, isCoordinatingPlayback: false))
        XCTAssertNil(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 0, isCoordinatingPlayback: false))
        XCTAssertNil(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: -1, isCoordinatingPlayback: false))
        XCTAssertNil(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: .nan, isCoordinatingPlayback: false))
        XCTAssertNil(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: .infinity, isCoordinatingPlayback: false))
    }

    func testClampedAndRoundedLikeThePhonesOwnSpeedControl() {
        XCTAssertEqual(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 0.2, isCoordinatingPlayback: false), 0.5)
        XCTAssertEqual(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 4, isCoordinatingPlayback: false), 3.0)
        XCTAssertEqual(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 1.33, isCoordinatingPlayback: false)!, 1.35, accuracy: 0.0001)
        XCTAssertEqual(WatchBookSpeedUpdate.acceptedRate(itemId: "li_1", rate: 1.7499999, isCoordinatingPlayback: false)!, 1.75, accuracy: 0.0001)
    }

    func testThePayloadDecodesAndToleratesExtraKeys() throws {
        // A later Watch app may add fields; this iPhone must still read the two it knows.
        let json = #"{"itemId":"li_9","rate":1.25,"setAt":1763000000000}"#
        let decoded = try JSONDecoder().decode(WatchBookSpeedUpdate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, WatchBookSpeedUpdate(itemId: "li_9", rate: 1.25))
    }

    func testTheUserInfoKeyIsStable() {
        // The Watch and the iPhone build this from the same shared file; pinned so a rename
        // can't silently split two app versions.
        XCTAssertEqual(WatchBookSpeedUpdate.userInfoKey, "watchBookSpeed")
    }
}
