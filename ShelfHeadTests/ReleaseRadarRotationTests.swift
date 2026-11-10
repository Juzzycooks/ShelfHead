import XCTest
@testable import ShelfHead

final class ReleaseRadarRotationTests: XCTestCase {
    func testFullRunUsesPlannedNext() {
        XCTAssertEqual(ReleaseRadarViewModel.rotationAfterRun(rotation: 0, checked: 5, planned: 5, total: 12, plannedNext: 5), 5)
    }

    func testEarlyStopAdvancesOnlyPastChecked() {
        XCTAssertEqual(ReleaseRadarViewModel.rotationAfterRun(rotation: 5, checked: 2, planned: 5, total: 12, plannedNext: 10), 7)
    }

    func testEarlyStopWrapsAndZeroCheckedKeepsStart() {
        XCTAssertEqual(ReleaseRadarViewModel.rotationAfterRun(rotation: 11, checked: 3, planned: 5, total: 12, plannedNext: 4), 2)
        XCTAssertEqual(ReleaseRadarViewModel.rotationAfterRun(rotation: 14, checked: 0, planned: 5, total: 12, plannedNext: 7), 2)
    }
}
