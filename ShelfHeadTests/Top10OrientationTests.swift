import XCTest
import UIKit
@testable import ShelfHead

final class Top10OrientationTests: XCTestCase {
    func testPortraitWhenDrivingModeIsOff() {
        XCTAssertEqual(OrientationPolicy.mask(drivingModeActive: false), .portrait)
    }

    func testLandscapeAllowedWhenDrivingModeIsOn() {
        let mask = OrientationPolicy.mask(drivingModeActive: true)
        XCTAssertEqual(mask, .allButUpsideDown)
        XCTAssertTrue(mask.contains(.landscapeLeft))
        XCTAssertTrue(mask.contains(.landscapeRight))
        XCTAssertFalse(mask.contains(.portraitUpsideDown))
    }
}
