import XCTest
@testable import ShelfHead

// Batch 495 (REVIEW 2026-11-11 C5): the CarPlay Speed list's decisions.
final class Batch495CarPlaySpeedTests: XCTestCase {

    func testStandardRatesAreThreeQuartersToTwoInQuarterSteps() {
        let options = CarPlayCoordinator.speedListOptions(current: 1.0)
        XCTAssertEqual(options.map(\.rate), [0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
    }

    func testExactlyTheCurrentRateIsMarked() {
        let options = CarPlayCoordinator.speedListOptions(current: 1.5)
        XCTAssertEqual(options.filter(\.isCurrent).map(\.rate), [1.5])
    }

    func testOffGridCurrentIsInsertedInOrderAndMarked() {
        let options = CarPlayCoordinator.speedListOptions(current: 1.05)
        XCTAssertEqual(options.map(\.rate), [0.75, 1.0, 1.05, 1.25, 1.5, 1.75, 2.0])
        XCTAssertEqual(options.filter(\.isCurrent).map(\.rate), [1.05])
    }

    func testCurrentAboveTwoIsAppendedAndBelowThreeQuartersIsPrepended() {
        XCTAssertEqual(CarPlayCoordinator.speedListOptions(current: 2.5).last?.rate, 2.5)
        XCTAssertTrue(CarPlayCoordinator.speedListOptions(current: 2.5).last?.isCurrent ?? false)
        XCTAssertEqual(CarPlayCoordinator.speedListOptions(current: 0.5).first?.rate, 0.5)
        XCTAssertTrue(CarPlayCoordinator.speedListOptions(current: 0.5).first?.isCurrent ?? false)
    }

    func testFloatNoiseDoesNotDuplicateAStandardRate() {
        let options = CarPlayCoordinator.speedListOptions(current: 1.2500001)
        XCTAssertEqual(options.count, 6)
        XCTAssertEqual(options.filter(\.isCurrent).count, 1)
    }

    func testSpeedListOnlyPushedWhileThereIsDepthRoom() {
        XCTAssertTrue(CarPlayCoordinator.canPushSpeedList(templateCount: 2))
        XCTAssertTrue(CarPlayCoordinator.canPushSpeedList(templateCount: 4))
        XCTAssertFalse(CarPlayCoordinator.canPushSpeedList(templateCount: 5))
    }
}
