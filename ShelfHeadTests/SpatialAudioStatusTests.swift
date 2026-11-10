import XCTest
import AVFoundation
@testable import ShelfHead

final class SpatialAudioStatusTests: XCTestCase {
    func testUnavailableWhenPortLacksSupport() {
        XCTAssertEqual(SpatialAudioStatus.status(portSupportsSpatial: false, settingEnabled: true), .unavailable)
        XCTAssertEqual(SpatialAudioStatus.status(portSupportsSpatial: false, settingEnabled: false), .unavailable)
    }

    func testAvailableOffAndOn() {
        XCTAssertEqual(SpatialAudioStatus.status(portSupportsSpatial: true, settingEnabled: false), .availableOff)
        XCTAssertEqual(SpatialAudioStatus.status(portSupportsSpatial: true, settingEnabled: true), .on)
    }

    func testFormatsOffIsAudioOnlyDefault() {
        XCTAssertEqual(SpatialAudioStatus.formats(forEnabled: false), .multichannel)
        XCTAssertEqual(SpatialAudioStatus.formats(forEnabled: true), .monoStereoAndMultichannel)
    }

    func testSettingDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.spatialAudioEnabled)
        XCTAssertFalse(SettingsStore.spatialAudioEnabled)
    }
}
