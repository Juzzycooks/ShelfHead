import XCTest
import Intents
import UIKit
@testable import ShelfHead

/// PL-14: the app's half of the `INPlayMediaIntent` hand-off from the `ShelfHeadIntents` extension.
final class PlayMediaRequestTests: XCTestCase {
    func testMediaNameIsReadAndTrimmed() {
        XCTAssertEqual(PlayMediaRequest.mediaName(from: ["mediaName": "  Emma \n"]), "Emma")
    }

    func testBlankOrMissingNameMeansResume() {
        XCTAssertNil(PlayMediaRequest.mediaName(from: ["mediaName": "   "]))
        XCTAssertNil(PlayMediaRequest.mediaName(from: [:]))
        XCTAssertNil(PlayMediaRequest.mediaName(from: nil))
        XCTAssertNil(PlayMediaRequest.mediaName(from: ["mediaName": 42]))
    }

    func testSpokenNameFromTheIntentIsTrimmed() {
        XCTAssertEqual(PlayMediaRequest.mediaName(" Emma "), "Emma")
        XCTAssertNil(PlayMediaRequest.mediaName("  "))
        XCTAssertNil(PlayMediaRequest.mediaName(nil))
    }

    /// Batch 362: `.handleInApp` reaches the app through `application(_:handlerFor:)`, which
    /// Siri only calls for intents the app lists in `INIntentsSupported`.
    func testAppDeclaresAndHandlesPlayMediaIntent() {
        let supported = Bundle.main.object(forInfoDictionaryKey: "INIntentsSupported") as? [String]
        XCTAssertTrue(supported?.contains("INPlayMediaIntent") == true)
        let handler = AppDelegate().application(UIApplication.shared, handlerFor: INPlayMediaIntent())
        XCTAssertTrue(handler is INPlayMediaIntentHandling)
    }

    func testActivityTypeMatchesTheRegisteredUserActivityType() throws {
        // The app must list the type in Info.plist `NSUserActivityTypes` or the system won't deliver it.
        let types = Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        XCTAssertTrue(types?.contains(PlayMediaRequest.activityType) == true)
    }
}
