import XCTest
@testable import ShelfHead

final class Review7SettingsTests: XCTestCase {
    func testSanitizedClampsNumbers() {
        XCTAssertEqual(SettingsExport.sanitized(.double(99), forKey: SettingsKeys.volumeBoostDB), .double(12))
        XCTAssertEqual(SettingsExport.sanitized(.int(-50), forKey: SettingsKeys.bassBoostDB), .double(-6))
        XCTAssertEqual(SettingsExport.sanitized(.double(9), forKey: SettingsKeys.defaultPlaybackSpeed), .double(3.0))
        XCTAssertEqual(SettingsExport.sanitized(.int(0), forKey: SettingsKeys.skipForwardInterval), .double(10))
        XCTAssertEqual(SettingsExport.sanitized(.int(500), forKey: SettingsKeys.chapterSkipStart), .int(120))
        XCTAssertEqual(SettingsExport.sanitized(.int(30), forKey: SettingsKeys.dailyReminderHour), .int(23))
    }

    func testSanitizedRejectsWrongTypesAndPassesUnruledKeys() {
        XCTAssertNil(SettingsExport.sanitized(.string("loud"), forKey: SettingsKeys.volumeBoostDB))
        XCTAssertNil(SettingsExport.sanitized(.int(1), forKey: SettingsKeys.dailyReminder))
        XCTAssertNil(SettingsExport.sanitized(.double(.infinity), forKey: SettingsKeys.defaultPlaybackSpeed))
        XCTAssertEqual(SettingsExport.sanitized(.string("dark"), forKey: SettingsKeys.appearance), .string("dark"))
    }

    func testApplySkipsRejectedValues() {
        let d = UserDefaults(suiteName: "Review7SettingsTests")!
        d.removePersistentDomain(forName: "Review7SettingsTests")
        let file = SettingsExportFile(version: 1, exportedAt: Date(), appVersion: "x", settings: [
            SettingsKeys.volumeBoostDB: .double(40), SettingsKeys.dailyReminder: .string("yes")])
        XCTAssertEqual(SettingsExport.apply(file, to: d), 1)
        XCTAssertEqual(d.double(forKey: SettingsKeys.volumeBoostDB), 12)
        XCTAssertNil(d.object(forKey: SettingsKeys.dailyReminder))
        d.removePersistentDomain(forName: "Review7SettingsTests")
    }

    func testProfileKeysAreExcludedNotExported() {
        for key in ["settings_activeListeningProfile", "settings_carPlayAutoDrivingPreference"] {
            XCTAssertTrue(SettingsExport.excludedKeys.contains(key))
            XCTAssertFalse(SettingsExport.exportedKeys.contains(key))
        }
    }

    func testSnapshotExportsBaselineWhileProfileActive() {
        let d = UserDefaults(suiteName: "Review7SettingsTests2")!
        d.removePersistentDomain(forName: "Review7SettingsTests2")
        d.set("driving", forKey: "settings_activeListeningProfile")
        d.set(6.0, forKey: SettingsKeys.volumeBoostDB)
        let json = #"{"playbackSpeed":1.0,"volumeBoostDB":2.0,"keepScreenAwake":false,"chapterHaptics":true,"wifiOnlyDownloads":false,"sleepFadeOut":true}"#
        d.set(Data(json.utf8), forKey: "settings_listeningProfileBaseline")
        let file = SettingsExport.snapshot(defaults: d, appVersion: "x")
        XCTAssertEqual(file.settings[SettingsKeys.volumeBoostDB], .double(2.0))
        d.removePersistentDomain(forName: "Review7SettingsTests2")
    }
}
