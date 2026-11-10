import XCTest
@testable import ShelfHead

final class Review4TranscriptionTests: XCTestCase {
    func testAutoRestartOnlyWhenActiveAndSameScope() {
        XCTAssertTrue(TranscriptionCenter.shouldAutoRestart(pendingScope: "a", currentScope: "a", isActive: true))
        XCTAssertFalse(TranscriptionCenter.shouldAutoRestart(pendingScope: "a", currentScope: "b", isActive: true))
        XCTAssertFalse(TranscriptionCenter.shouldAutoRestart(pendingScope: "a", currentScope: "a", isActive: false))
    }
}
