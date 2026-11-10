import XCTest
@testable import ShelfHead

/// Review Medium 18 (30 October 2026).
final class BookmarkFlushScopeTests: XCTestCase {
    func testScopeIsUnchanged() {
        XCTAssertTrue(BookmarkSyncService.scopeIsUnchanged(captured: "a", current: "a"))
        XCTAssertFalse(BookmarkSyncService.scopeIsUnchanged(captured: "a", current: "b"))
    }
}
