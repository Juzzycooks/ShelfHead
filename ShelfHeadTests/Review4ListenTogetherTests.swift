import XCTest
@testable import ShelfHead

/// Review 4: Listen Together reducer and join decisions.
final class Review4ListenTogetherTests: XCTestCase {
    func testForeignOfferDoesNotClobberActiveOrWaiting() {
        let active = ListenTogetherState.active(participants: 2, title: "A")
        XCTAssertEqual(ListenTogetherLogic.reduce(active, .sessionOffered(matchesMyServer: false, title: "B")), active)
        XCTAssertEqual(ListenTogetherLogic.reduce(.waiting, .sessionOffered(matchesMyServer: false, title: "B")), .waiting)
        XCTAssertEqual(ListenTogetherLogic.reduce(.idle, .sessionOffered(matchesMyServer: false, title: "B")), .notOnYourServer(title: "B"))
    }

    func testWaitTimeoutOnlyResetsWaiting() {
        XCTAssertEqual(ListenTogetherLogic.reduce(.waiting, .waitTimedOut), .idle)
        let active = ListenTogetherState.active(participants: 2, title: "A")
        XCTAssertEqual(ListenTogetherLogic.reduce(active, .waitTimedOut), active)
        XCTAssertEqual(ListenTogetherLogic.reduce(.unavailable, .waitTimedOut), .unavailable)
    }

    func testShouldJoinOnlyWhenSharedBookLoaded() {
        XCTAssertTrue(ListenTogetherLogic.shouldJoin(loadedItemId: "x", sharedItemId: "x"))
        XCTAssertFalse(ListenTogetherLogic.shouldJoin(loadedItemId: "y", sharedItemId: "x"))
        XCTAssertFalse(ListenTogetherLogic.shouldJoin(loadedItemId: nil, sharedItemId: "x"))
    }
}
