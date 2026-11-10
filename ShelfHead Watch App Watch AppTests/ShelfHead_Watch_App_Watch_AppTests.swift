//
//  ShelfHead_Watch_App_Watch_AppTests.swift
//  ShelfHead Watch App Watch AppTests
//
//  Created by Juzzycooks on 28/7/2026.
//

// XCTest, not Swift Testing: every other test file in this project is
// `XCTest`/`XCTestCase` (see `CLAUDE.md`'s Testing section), and this file was
// still the untouched `import Testing` template Xcode generates. The template's
// `@testable import ShelfHead_Watch_App_Watch_App` was also stale — the Watch app
// target has since been renamed to `ShelfHead Watch`, so its module is
// `ShelfHead_Watch` (target name → `PRODUCT_NAME = $(TARGET_NAME)` → module name
// with the space underscored; no `PRODUCT_MODULE_NAME` override in the project).
import XCTest
@testable import ShelfHead_Watch

/// Pins `StandaloneAudioEngine.resumePosition(...)`, the pure decision behind the
/// 9 September 2026 review's CRITICAL finding: standalone playback started every
/// book at 0:00 and then pushed ~30s over the top of the listener's real position
/// 30 seconds later. Following this project's stated testing precedent (pin the
/// pure decision function; don't try to drive the stateful `AVQueuePlayer` path).
final class StandaloneResumePositionTests: XCTestCase {

    private func resume(server: Double? = nil, serverMs: Double? = nil,
                        local: Double? = nil, localMs: Double? = nil,
                        duration: Double = 3600) -> Double {
        StandaloneAudioEngine.resumePosition(
            serverTime: server, serverLastUpdateMs: serverMs,
            localTime: local, localLastUpdateMs: localMs,
            duration: duration)
    }

    // MARK: - Only one side exists

    func testServerOnlyIsUsed() {
        XCTAssertEqual(resume(server: 1234, serverMs: 1_000), 1234)
    }

    func testLocalOnlyIsUsed() {
        // The offline local-download case: no session, so no server candidate.
        XCTAssertEqual(resume(local: 987, localMs: 1_000), 987)
    }

    func testNeitherSideKnownStartsAtZero() {
        XCTAssertEqual(resume(), 0)
    }

    // MARK: - Newer wins

    func testNewerLocalWinsOverOlderServer() {
        XCTAssertEqual(resume(server: 100, serverMs: 1_000, local: 900, localMs: 2_000), 900)
    }

    func testNewerServerWinsOverOlderLocal() {
        // The phone listened on past this Watch's last known position.
        XCTAssertEqual(resume(server: 2_400, serverMs: 5_000, local: 900, localMs: 2_000), 2_400)
    }

    func testNewerServerWinsEvenWhenItsPositionIsEarlier() {
        // A deliberate re-listen from an earlier point on another device is newer,
        // and newer wins — the whole point of comparing clocks rather than positions.
        XCTAssertEqual(resume(server: 120, serverMs: 9_000, local: 3_000, localMs: 2_000), 120)
    }

    // MARK: - Clocks that can't be compared fall back to the further-ahead position

    func testEqualTimestampsPrefersFurtherAhead() {
        XCTAssertEqual(resume(server: 100, serverMs: 4_000, local: 800, localMs: 4_000), 800)
        XCTAssertEqual(resume(server: 900, serverMs: 4_000, local: 800, localMs: 4_000), 900)
    }

    func testMissingServerTimestampPrefersFurtherAhead() {
        // A server that doesn't echo `userMediaProgress` back on the play response
        // gives a position with no clock — resuming behind a known position is what
        // destroys it, so the further-ahead one wins.
        XCTAssertEqual(resume(server: 1_500, serverMs: nil, local: 300, localMs: 2_000), 1_500)
    }

    func testMissingLocalTimestampPrefersFurtherAhead() {
        XCTAssertEqual(resume(server: 300, serverMs: 2_000, local: 1_500, localMs: nil), 1_500)
    }

    // MARK: - Clamping into [0, duration)

    func testPositionAtDurationRestartsFromZero() {
        // A finished book's server `currentTime` is typically exactly its duration.
        XCTAssertEqual(resume(server: 3_600, serverMs: 1_000, duration: 3_600), 0)
    }

    func testPositionPastDurationRestartsFromZero() {
        XCTAssertEqual(resume(server: 4_000, serverMs: 1_000, duration: 3_600), 0)
    }

    func testNegativePositionIsFloored() {
        XCTAssertEqual(resume(server: -30, serverMs: 1_000), 0)
    }

    func testZeroPositionStaysZero() {
        XCTAssertEqual(resume(server: 0, serverMs: 1_000, local: 0, localMs: 2_000), 0)
    }

    func testUnknownDurationSkipsTheClampRatherThanDiscardingThePosition() {
        XCTAssertEqual(resume(server: 4_000, serverMs: 1_000, duration: 0), 4_000)
    }

    func testNotANumberIsTreatedAsNoPosition() {
        XCTAssertEqual(resume(server: .nan, serverMs: 1_000), 0)
    }
}
