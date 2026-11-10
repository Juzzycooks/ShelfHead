import XCTest
@testable import ShelfHead

final class SettingsExportTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SettingsExportTests")
        defaults.removePersistentDomain(forName: "SettingsExportTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SettingsExportTests")
        defaults = nil
        super.tearDown()
    }

    func testSnapshotIncludesExportableKeysAndExcludesOthers() {
        defaults.set(true, forKey: SettingsKeys.smartRewind)
        defaults.set(3, forKey: SettingsKeys.dailyReminderHour)
        defaults.set(1.25, forKey: SettingsKeys.defaultPlaybackSpeed)
        defaults.set("dark", forKey: SettingsKeys.appearance)
        defaults.set(["a", "b"], forKey: SettingsKeys.hiddenHomeSections)
        defaults.set(true, forKey: SettingsKeys.storePassword)
        defaults.set("x", forKey: SettingsKeys.selectedLibraryId)

        let file = SettingsExport.snapshot(defaults: defaults, appVersion: "1.0")

        XCTAssertEqual(file.settings[SettingsKeys.smartRewind], .bool(true))
        XCTAssertEqual(file.settings[SettingsKeys.dailyReminderHour], .int(3))
        XCTAssertEqual(file.settings[SettingsKeys.defaultPlaybackSpeed], .double(1.25))
        XCTAssertEqual(file.settings[SettingsKeys.appearance], .string("dark"))
        XCTAssertEqual(file.settings[SettingsKeys.hiddenHomeSections], .stringArray(["a", "b"]))
        XCTAssertNil(file.settings[SettingsKeys.storePassword])
        XCTAssertNil(file.settings[SettingsKeys.selectedLibraryId])
    }

    func testRoundTripEncodeDecode() throws {
        defaults.set(true, forKey: SettingsKeys.smartRewind)
        defaults.set("dark", forKey: SettingsKeys.appearance)
        let file = SettingsExport.snapshot(defaults: defaults, appVersion: "1.0")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SettingsExportFile.self, from: data)

        XCTAssertEqual(decoded.settings, file.settings)
        XCTAssertEqual(decoded.version, file.version)
    }

    func testApplyWritesSettingsAndReturnsCount() {
        defaults.set(true, forKey: SettingsKeys.smartRewind)
        defaults.set(3, forKey: SettingsKeys.dailyReminderHour)
        defaults.set(1.25, forKey: SettingsKeys.defaultPlaybackSpeed)
        defaults.set("dark", forKey: SettingsKeys.appearance)
        defaults.set(["a", "b"], forKey: SettingsKeys.hiddenHomeSections)
        let file = SettingsExport.snapshot(defaults: defaults, appVersion: "1.0")

        let target = UserDefaults(suiteName: "SettingsExportTestsTarget")!
        target.removePersistentDomain(forName: "SettingsExportTestsTarget")
        let applied = SettingsExport.apply(file, to: target)

        // A suite-based `UserDefaults` still sees the process-wide registration domain
        // (`SettingsStore.registerDefaults()`), so the snapshot legitimately carries every
        // registered preference too — pin "everything in the file was applied" and the
        // five explicit values, not an exact count.
        XCTAssertEqual(applied, file.settings.count)
        XCTAssertGreaterThanOrEqual(applied, 5)
        XCTAssertEqual(target.bool(forKey: SettingsKeys.smartRewind), true)
        XCTAssertEqual(target.integer(forKey: SettingsKeys.dailyReminderHour), 3)
        XCTAssertEqual(target.double(forKey: SettingsKeys.defaultPlaybackSpeed), 1.25)
        XCTAssertEqual(target.string(forKey: SettingsKeys.appearance), "dark")
        XCTAssertEqual(target.stringArray(forKey: SettingsKeys.hiddenHomeSections), ["a", "b"])
        target.removePersistentDomain(forName: "SettingsExportTestsTarget")
    }

    func testExcludedKeysDisjointFromExportedKeys() {
        let exported = Set(SettingsExport.exportedKeys)
        XCTAssertTrue(exported.isDisjoint(with: SettingsExport.excludedKeys))
    }
}
