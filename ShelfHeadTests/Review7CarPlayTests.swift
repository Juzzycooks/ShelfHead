import XCTest
@testable import ShelfHead

// Batch 478 review 7: CarPlay row guards, filtered page size, Release Radar scope guard.
final class Review7CarPlayTests: XCTestCase {
    func testShouldSeekOnlyForSameBook() {
        XCTAssertTrue(CarPlayCoordinator.shouldSeek(builtFor: "a", current: "a"))
        XCTAssertFalse(CarPlayCoordinator.shouldSeek(builtFor: "a", current: "b"))
        XCTAssertFalse(CarPlayCoordinator.shouldSeek(builtFor: "a", current: nil))
    }

    func testFilteredPageSizeReservesShowMoreSlot() {
        XCTAssertEqual(CarPlayCoordinator.filteredPageSize(cap: 24), 23)
        XCTAssertEqual(CarPlayCoordinator.filteredPageSize(cap: 12), 11)
        XCTAssertEqual(CarPlayCoordinator.filteredPageSize(cap: 1), 1)
        XCTAssertEqual(CarPlayCoordinator.filteredPageSize(cap: 0), 1)
    }

    func testCancellationIsNotAFailure() {
        XCTAssertTrue(CarPlayCoordinator.isCancellation(CancellationError()))
        XCTAssertFalse(CarPlayCoordinator.isCancellation(URLError(.notConnectedToInternet)))
    }

    func testRadarRefreshGuardIsScopeAware() {
        XCTAssertTrue(ReleaseRadarViewModel.mayStartRefresh(runningScope: nil, requested: "a"))
        XCTAssertFalse(ReleaseRadarViewModel.mayStartRefresh(runningScope: "a", requested: "a"))
        XCTAssertTrue(ReleaseRadarViewModel.mayStartRefresh(runningScope: "a", requested: "b"))
    }
}
