import XCTest
@testable import ShelfHead_Watch

/// Batch 495 (REVIEW 2026-11-11 W7): standalone playback follows the iPhone's playback
/// settings — the payload's compatibility, skip intervals, per-book speed precedence and
/// smart rewind.
final class Batch495WatchPlaybackPreferencesTests: XCTestCase {

    // MARK: Payload compatibility

    func testOldPhonePayloadDecodesWithNewFieldsMissing() throws {
        // What a phone before Batch 495 sends: chapter skip only.
        let json = #"{"defaultEnd":8,"defaultStart":5,"overrides":{"li_1":[20,30]}}"#
        let decoded = try JSONDecoder().decode(WatchChapterSkipSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.defaultStart, 5)
        XCTAssertEqual(decoded.defaultEnd, 8)
        XCTAssertEqual(decoded.overrides["li_1"], [20, 30])
        XCTAssertNil(decoded.skipBackwardInterval)
        XCTAssertNil(decoded.skipForwardInterval)
        XCTAssertNil(decoded.smartRewind)
        XCTAssertNil(decoded.defaultSpeed)
        XCTAssertNil(decoded.perBookSpeeds)
    }

    func testMalformedNewFieldDoesNotLoseChapterSkip() throws {
        let json = #"{"defaultEnd":0,"defaultStart":7,"overrides":{},"perBookSpeeds":"oops","smartRewind":"yes","skipForwardInterval":45}"#
        let decoded = try JSONDecoder().decode(WatchChapterSkipSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.defaultStart, 7)
        XCTAssertNil(decoded.perBookSpeeds)
        XCTAssertNil(decoded.smartRewind)
        XCTAssertEqual(decoded.skipForwardInterval, 45)
    }

    /// An old Watch app decodes with the synthesized `Codable` of the three original
    /// fields. Its shape is mirrored here so the new keys are proven ignorable.
    private struct OldWatchChapterSkipSettings: Codable, Equatable {
        var defaultStart: Int
        var defaultEnd: Int
        var overrides: [String: [Int]]
    }

    func testNewPhonePayloadStillDecodesOnAnOldWatch() throws {
        let settings = WatchChapterSkipSettings(defaultStart: 5, defaultEnd: 8, overrides: ["li_1": [20, 30]],
                                                skipBackwardInterval: 10, skipForwardInterval: 45,
                                                smartRewind: false, defaultSpeed: 1.25,
                                                perBookSpeeds: ["li_1": 1.5])
        let data = try JSONEncoder().encode(settings)
        let old = try JSONDecoder().decode(OldWatchChapterSkipSettings.self, from: data)
        XCTAssertEqual(old, OldWatchChapterSkipSettings(defaultStart: 5, defaultEnd: 8, overrides: ["li_1": [20, 30]]))
        XCTAssertEqual(try JSONDecoder().decode(WatchChapterSkipSettings.self, from: data), settings, "round trip")
    }

    func testFullPayloadPersistsAndLoads() throws {
        let suite = "Batch495WatchPlaybackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WatchChapterSkipSettings(skipBackwardInterval: 10, skipForwardInterval: 45,
                                                smartRewind: true, defaultSpeed: 1.1, perBookSpeeds: ["a": 2])
        settings.save(to: defaults)
        XCTAssertEqual(WatchChapterSkipSettings.load(from: defaults), settings)
    }

    // MARK: Skip intervals

    func testSkipIntervalsPreferThePayloadThenTheSnapshotThenFifteenThirty() {
        let none = WatchChapterSkipSettings()
        var result = WatchPlaybackPreferences.skipIntervals(settings: none, snapshotBackward: nil, snapshotForward: nil)
        XCTAssertEqual(result.backward, 15)
        XCTAssertEqual(result.forward, 30)

        result = WatchPlaybackPreferences.skipIntervals(settings: none, snapshotBackward: 10, snapshotForward: 60)
        XCTAssertEqual(result.backward, 10)
        XCTAssertEqual(result.forward, 60)

        let payload = WatchChapterSkipSettings(skipBackwardInterval: 5, skipForwardInterval: 45)
        result = WatchPlaybackPreferences.skipIntervals(settings: payload, snapshotBackward: 10, snapshotForward: 60)
        XCTAssertEqual(result.backward, 5)
        XCTAssertEqual(result.forward, 45)
    }

    func testUnusableSkipIntervalsFallThrough() {
        let payload = WatchChapterSkipSettings(skipBackwardInterval: 0, skipForwardInterval: .nan)
        let result = WatchPlaybackPreferences.skipIntervals(settings: payload, snapshotBackward: -3, snapshotForward: 20)
        XCTAssertEqual(result.backward, 15)
        XCTAssertEqual(result.forward, 20)
    }

    // MARK: Speed precedence

    func testWatchSpeedForTheBookWinsOverThePhones() {
        let settings = WatchChapterSkipSettings(defaultSpeed: 1.2, perBookSpeeds: ["a": 1.5])
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: ["a": 1.8],
                                                          settings: settings, watchLastRate: 1.0), 1.8)
    }

    func testPhoneSpeedForTheBookBeatsTheWatchsLastSpeed() {
        let settings = WatchChapterSkipSettings(defaultSpeed: 1.2, perBookSpeeds: ["a": 1.5])
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: ["b": 2.0],
                                                          settings: settings, watchLastRate: 1.0), 1.5)
    }

    func testWatchLastSpeedThenPhoneDefaultThenOne() {
        let settings = WatchChapterSkipSettings(defaultSpeed: 1.2, perBookSpeeds: [:])
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: [:],
                                                          settings: settings, watchLastRate: 1.4), 1.4)
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: [:],
                                                          settings: settings, watchLastRate: nil), 1.2)
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: [:],
                                                          settings: WatchChapterSkipSettings(), watchLastRate: nil), 1.0)
    }

    func testStartRateIsClampedAndIgnoresJunk() {
        let settings = WatchChapterSkipSettings(perBookSpeeds: ["a": 9])
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: ["a": .nan],
                                                          settings: settings, watchLastRate: nil), 3.0)
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "b", watchBookSpeeds: ["b": 0],
                                                          settings: settings, watchLastRate: 0.1), 0.5)
    }

    func testRecordingKeepsTheNewEntryAndTheCap() {
        let map = ["a": 1.0, "b": 1.1, "c": 1.2]
        let recorded = WatchPlaybackPreferences.recording(1.5, forItem: "z", in: map, cap: 2)
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded["z"], 1.5)
        XCTAssertEqual(WatchPlaybackPreferences.recording(2.0, forItem: "a", in: map)["a"], 2.0)
    }

    // MARK: Smart rewind

    func testSmartRewindScaleMatchesThePhone() {
        // `SettingsStore.smartRewindAmount(pausedFor:)`'s steps.
        let cases: [(TimeInterval, Double)] = [(0, 0), (9.9, 0), (10, 3), (59, 3), (60, 5), (599, 5),
                                               (600, 10), (3599, 10), (3600, 20), (86_400, 20)]
        for (paused, expected) in cases {
            XCTAssertEqual(WatchSmartRewind.seconds(pausedFor: paused, isEnabled: true), expected, "paused \(paused)s")
        }
        XCTAssertEqual(WatchSmartRewind.seconds(pausedFor: 3600, isEnabled: false), 0)
        XCTAssertEqual(WatchSmartRewind.seconds(pausedFor: .infinity, isEnabled: true), 0)
    }

    func testSmartRewindDefaultsOnLikeThePhone() {
        XCTAssertTrue(WatchPlaybackPreferences.smartRewindIsEnabled(settings: WatchChapterSkipSettings()))
        XCTAssertFalse(WatchPlaybackPreferences.smartRewindIsEnabled(settings: WatchChapterSkipSettings(smartRewind: false)))
    }
}
