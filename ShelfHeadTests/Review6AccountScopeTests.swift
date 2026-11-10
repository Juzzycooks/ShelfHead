import XCTest
@testable import ShelfHead

final class Review6AccountScopeTests: XCTestCase {
    func testStaleGeneration() {
        XCTAssertFalse(CarPlayCoordinator.isStaleGeneration(captured: 2, current: 2))
        XCTAssertTrue(CarPlayCoordinator.isStaleGeneration(captured: 2, current: 3))
    }

    func testReleaseRadarScopeChanged() {
        XCTAssertFalse(ReleaseRadarViewModel.scopeChanged(started: "a", current: "a"))
        XCTAssertTrue(ReleaseRadarViewModel.scopeChanged(started: "a", current: "b"))
    }
}
