import XCTest
@testable import ShelfHead

final class LoadedPlayerSyncTests: XCTestCase {
    func testOtherBookUntouched() {
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "b", isFinished: true, currentTime: 5), .none)
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: nil, itemId: "b", isFinished: false, currentTime: 5), .none)
    }
    func testLoadedFinishedClosesOut() {
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: true, currentTime: 100), .markFinished)
    }
    func testLoadedResetSeeksToStart() {
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: false, currentTime: 0), .seek(0))
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: false, currentTime: -3), .seek(0))
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: false, currentTime: 42), .seek(42))
    }
}
