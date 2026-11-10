import XCTest
@testable import ShelfHead

/// Polish pass (J3-8, J3-11): pins the small pure pieces of the core-listening fixes.
final class PolishPlayerTests: XCTestCase {

    /// J3-8: VoiceOver hears the speed as a number of times, trimmed of trailing zeros.
    func testSpokenSpeedFormatsWholeAndFractionalRates() {
        XCTAssertTrue(SpeedSheet.spokenSpeed(1).contains("1"))
        XCTAssertFalse(SpeedSheet.spokenSpeed(1).contains("1.0"))
        XCTAssertTrue(SpeedSheet.spokenSpeed(1.25).contains("1.25"))
        XCTAssertTrue(SpeedSheet.spokenSpeed(1.5).contains("1.5"))
        XCTAssertFalse(SpeedSheet.spokenSpeed(1.5).contains("1.50"))
    }

    /// J3-8: hold-to-repeat waits longer than one repeat interval, so a tap never repeats.
    func testHoldToRepeatTimingIsSane() {
        XCTAssertGreaterThan(SpeedSheet.holdDelay, SpeedSheet.repeatInterval)
    }

    /// J3-11: cover retries are bounded and spaced out (no hammering a struggling server).
    func testCoverRetryDelaysAreBoundedAndIncreasing() {
        let delays = CachedCover.retryDelays
        XCTAssertFalse(delays.isEmpty)
        XCTAssertLessThanOrEqual(delays.count, 4)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertGreaterThanOrEqual(delays.first ?? 0, 3)
    }
}
