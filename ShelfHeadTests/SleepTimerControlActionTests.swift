import XCTest
@testable import ShelfHead

/// `PlaybackCoordinator.sleepTimerControlAction(_:_:_:_:)` is the pure decision half of
/// `setSleepTimerFromWidget(enabled:)` — the Control Center sleep timer toggle. Same
/// precedent as `SetPlayStateActionTests`: only a live session (a book loaded and not
/// merely awaiting a cold resume) can have a timer armed or disarmed; the toggle never
/// starts or restores playback.
final class SleepTimerControlActionTests: XCTestCase {
    func testLiveOnArmsDefaultMinutes() {
        let action = PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: true, hasBook: true, isAwaitingResume: false, defaultMinutes: 30)
        XCTAssertEqual(action, .arm(minutes: 30))
    }

    func testLiveOnWithZeroDefaultArmsOneMinute() {
        let action = PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: true, hasBook: true, isAwaitingResume: false, defaultMinutes: 0)
        XCTAssertEqual(action, .arm(minutes: 1))
    }

    func testLiveOffDisarms() {
        let action = PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: false, hasBook: true, isAwaitingResume: false, defaultMinutes: 30)
        XCTAssertEqual(action, .disarm)
    }

    func testNothingLoadedIsNone() {
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: true, hasBook: false, isAwaitingResume: false, defaultMinutes: 30), .none)
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: false, hasBook: false, isAwaitingResume: false, defaultMinutes: 30), .none)
    }

    func testAwaitingResumeIsNone() {
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: true, hasBook: true, isAwaitingResume: true, defaultMinutes: 30), .none)
        XCTAssertEqual(PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: false, hasBook: true, isAwaitingResume: true, defaultMinutes: 30), .none)
    }

    func testSnapshotWithoutSleepTimerKeysDecodesToNil() throws {
        let json = """
        {"itemId":"1","title":"T","author":"A","currentTime":0,"duration":100,\
        "isPlaying":false,"updatedAt":719528400}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(SharedPlayback.Snapshot.self, from: json)
        XCTAssertNil(snapshot.sleepTimerActive)
        XCTAssertNil(snapshot.sleepTimerDefaultMinutes)
    }

    func testSleepTimerFieldsRoundTrip() throws {
        let original = SharedPlayback.Snapshot(
            itemId: "1", title: "T", author: "A", currentTime: 0, duration: 100,
            isPlaying: false, updatedAt: Date(), sleepTimerActive: true, sleepTimerDefaultMinutes: 15)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedPlayback.Snapshot.self, from: data)
        XCTAssertEqual(decoded.sleepTimerActive, true)
        XCTAssertEqual(decoded.sleepTimerDefaultMinutes, 15)
    }
}
