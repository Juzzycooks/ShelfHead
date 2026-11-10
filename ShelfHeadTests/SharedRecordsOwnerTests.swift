import XCTest
@testable import ShelfHead

/// 28 Oct 2026: the unscoped App Group records (playback snapshot, widget library, Up Next)
/// are cleared on sign-in unless the incoming account already owns them.
final class SharedRecordsOwnerTests: XCTestCase {
    func testSameAccountKeepsRecords() {
        XCTAssertFalse(SharedPlayback.recordsNeedClearing(owner: "a", incoming: "a"))
    }

    func testDifferentAccountClearsRecords() {
        XCTAssertTrue(SharedPlayback.recordsNeedClearing(owner: "a", incoming: "b"))
    }

    func testUnknownOwnerClearsRecords() {
        XCTAssertTrue(SharedPlayback.recordsNeedClearing(owner: nil, incoming: "b"))
    }

    func testNoIncomingAccountClearsRecords() {
        XCTAssertTrue(SharedPlayback.recordsNeedClearing(owner: "a", incoming: nil))
    }
}
