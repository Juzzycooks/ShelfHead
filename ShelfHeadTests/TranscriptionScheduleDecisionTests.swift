import XCTest
@testable import ShelfHead

/// Phase 1, Batch 422: whether the overnight transcription task should run.
final class TranscriptionScheduleDecisionTests: XCTestCase {
    private func decide(enabled: Bool = true, charging: Bool = true, lowPower: Bool = false,
                        thermal: ProcessInfo.ThermalState = .nominal, pending: Int = 2) -> TranscriptionScheduleDecision {
        TranscriptionScheduleDecision.overnight(enabled: enabled, isCharging: charging, lowPowerMode: lowPower,
                                                thermalState: thermal, pendingCount: pending)
    }

    func testRunsWhenEverythingIsFavourable() {
        XCTAssertEqual(decide(), .run)
        XCTAssertEqual(decide(thermal: .fair), .run)
    }

    func testEachGate() {
        XCTAssertEqual(decide(enabled: false), .skipDisabled)
        XCTAssertEqual(decide(pending: 0), .skipNothingToDo)
        XCTAssertEqual(decide(charging: false), .skipNotCharging)
        XCTAssertEqual(decide(lowPower: true), .skipLowPower)
        XCTAssertEqual(decide(thermal: .serious), .skipThermal)
        XCTAssertEqual(decide(thermal: .critical), .skipThermal)
    }

    func testPrecedence() {
        XCTAssertEqual(decide(enabled: false, charging: false, lowPower: true, thermal: .critical, pending: 0), .skipDisabled)
        XCTAssertEqual(decide(charging: false, lowPower: true, thermal: .critical, pending: 0), .skipNothingToDo)
        XCTAssertEqual(decide(charging: false, lowPower: true, thermal: .critical), .skipNotCharging)
        XCTAssertEqual(decide(lowPower: true, thermal: .critical), .skipLowPower)
    }
}
