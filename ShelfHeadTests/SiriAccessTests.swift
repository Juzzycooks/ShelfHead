import XCTest
import Intents
@testable import ShelfHead

/// Batch 406: the Settings > System & Privacy Siri row. Pins which action each
/// authorization status offers, so a denied user always has a way back.
final class SiriAccessTests: XCTestCase {
    func testNotDeterminedOffersTheRequest() {
        let access = SiriAccess(.notDetermined)
        XCTAssertEqual(access.action, .request)
        XCTAssertEqual(access.status.key, "Not set up")
    }

    func testDeniedOffersSettings() {
        let access = SiriAccess(.denied)
        XCTAssertEqual(access.action, .openSettings)
        XCTAssertEqual(access.status.key, "Off")
    }

    func testAuthorizedShowsOnWithNoAction() {
        let access = SiriAccess(.authorized)
        XCTAssertEqual(access.action, .none)
        XCTAssertEqual(access.status.key, "On")
    }

    func testRestrictedHasNoActionTheUserCannotTake() {
        let access = SiriAccess(.restricted)
        XCTAssertEqual(access.action, .none)
        XCTAssertEqual(access.status.key, "Restricted")
    }
}
