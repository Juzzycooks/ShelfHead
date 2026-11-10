import XCTest
@testable import ShelfHead

/// Item 33: the Siri/Shortcuts "Set Sleep Timer" intent (`StartSleepTimerIntent`) used to
/// accept any `Int` minutes value, including 0 or negative, and hand it straight to
/// `AudioPlayerService.setSleepTimer(.minutes(_:))` — which (per its own countdown logic)
/// fires on the very next tick, so "Hey Siri, set a 0 minute sleep timer" paused playback
/// about a second after it started, with nothing telling the user why.
///
/// `StartSleepTimerIntent.validatedSleepTimerMinutes(_:)` is the pure decision half of the
/// fix: reject anything below 1 minute outright, and cap anything above the in-app maximum
/// (60 — the largest fixed `.minutes(_:)` value in `SleepTimerOption.presets`,
/// Models/PlayerState.swift) down to that maximum rather than rejecting it. `perform()`
/// itself (which throws `$minutes.needsValueError(...)` for the reject case) isn't
/// exercised here — that requires driving the `AppIntents` runtime, not something this
/// suite reaches into.
final class SleepTimerValidationTests: XCTestCase {

    func testZeroIsRejected() {
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(0), .tooLow)
    }

    func testNegativeIsRejected() {
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(-5), .tooLow)
    }

    func testOneMinuteIsValid() {
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(1), .valid(1))
    }

    func testMaximumIsValidAsRequested() {
        let max = StartSleepTimerIntent.maxSleepTimerMinutes
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(max), .valid(max))
    }

    func testAboveMaximumIsCappedToMaximum() {
        let max = StartSleepTimerIntent.maxSleepTimerMinutes
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(max + 1), .capped(max))
    }

    /// A more extreme over-request still caps to exactly the maximum, not to something
    /// scaled or clamped differently.
    func testWayAboveMaximumIsCappedToMaximum() {
        let max = StartSleepTimerIntent.maxSleepTimerMinutes
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(500), .capped(max))
    }
}
