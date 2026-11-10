import XCTest
import LocalAuthentication
@testable import ShelfHead

/// Batch 472 review fixes (Medium 38, Medium 24, Low Release Radar, Low Hardcover).
final class Batch472ReviewFixTests: XCTestCase {
    func testParentGatePassesOnlyWhenNoPasscodeIsSet() {
        XCTAssertTrue(ParentGate.passesWhenUnavailable(errorCode: LAError.passcodeNotSet.rawValue))
        XCTAssertFalse(ParentGate.passesWhenUnavailable(errorCode: LAError.biometryNotAvailable.rawValue))
        XCTAssertFalse(ParentGate.passesWhenUnavailable(errorCode: LAError.notInteractive.rawValue))
        XCTAssertFalse(ParentGate.passesWhenUnavailable(errorCode: nil))
    }

    func testSleepTimerIntentArmsOnlyOnLiveSession() {
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: true, hasBook: true,
                                                                   isAwaitingResume: false, defaultMinutes: 20),
                       .arm(minutes: 20))
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: true, hasBook: false,
                                                                   isAwaitingResume: false, defaultMinutes: 20), .none)
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(requestedOn: true, hasBook: true,
                                                                   isAwaitingResume: true, defaultMinutes: 20), .none)
    }

    func testReleaseRadarStopsOnThrottleAndServerErrorsOnly() {
        typealias E = AudibleCatalogAPI.CatalogError
        XCTAssertTrue(ReleaseRadarViewModel.shouldStopRun(after: E.badResponse(429)))
        XCTAssertTrue(ReleaseRadarViewModel.shouldStopRun(after: E.badResponse(503)))
        XCTAssertTrue(ReleaseRadarViewModel.shouldStopRun(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(ReleaseRadarViewModel.shouldStopRun(after: E.badResponse(404)))
        XCTAssertFalse(ReleaseRadarViewModel.shouldStopRun(after: E.badURL))
    }

    func testHardcoverMutationErrorFieldThrows() {
        XCTAssertThrowsError(try HardcoverAPI.throwIfMutationFailed(
            ["update_user_book": ["id": 1, "error": "Not allowed"]], key: "update_user_book"))
        XCTAssertNoThrow(try HardcoverAPI.throwIfMutationFailed(
            ["update_user_book": ["id": 1, "error": NSNull()]], key: "update_user_book"))
        XCTAssertNoThrow(try HardcoverAPI.throwIfMutationFailed([:], key: "update_user_book"))
    }
}
