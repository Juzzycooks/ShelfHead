import XCTest
@testable import ShelfHead

/// S4 (REVIEW_2026-09-04_UI.md): "Clear" used to wipe the whole Up Next queue with no
/// confirmation. The fix adds a `.confirmationDialog`; the only part of it checkable
/// without a live queue/UI is the destructive button's copy, which is why the singular
/// vs. plural title was split into a pure `QueueSheet.clearQueueButtonTitle(count:)`.
final class UpNextClearCopyTests: XCTestCase {

    func testSingularBook() {
        XCTAssertEqual(QueueSheet.clearQueueButtonTitle(count: 1), "Clear 1 Book")
    }

    func testPluralBooks() {
        XCTAssertEqual(QueueSheet.clearQueueButtonTitle(count: 3), "Clear 3 Books")
    }
}
