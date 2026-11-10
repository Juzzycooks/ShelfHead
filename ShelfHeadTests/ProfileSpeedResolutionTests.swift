import XCTest
@testable import ShelfHead

/// Review Medium 12 (30 October 2026): an active profile's speed wins over a remembered per-book speed.
final class ProfileSpeedResolutionTests: XCTestCase {
    func testProfileSpeedBeatsRememberedAndDefault() {
        XCTAssertEqual(SettingsStore.resolveSpeed(profile: 0.75, remembered: 1.5, globalDefault: 1.0), 0.75)
    }

    func testRememberedSpeedUsedWithoutProfile() {
        XCTAssertEqual(SettingsStore.resolveSpeed(profile: nil, remembered: 1.5, globalDefault: 1.0), 1.5)
    }

    func testGlobalDefaultWhenNothingElse() {
        XCTAssertEqual(SettingsStore.resolveSpeed(profile: nil, remembered: nil, globalDefault: 1.25), 1.25)
    }

    func testOffProfileHasNoSpeedOverride() {
        XCTAssertNil(ListeningProfile.off.overrides.playbackSpeed)
    }
}
