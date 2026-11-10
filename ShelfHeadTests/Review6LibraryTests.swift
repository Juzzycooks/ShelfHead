import XCTest
@testable import ShelfHead

final class Review6LibraryTests: XCTestCase {
    func testSeekAtEndOfUnfinishedBookIsIgnored() {
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: false, currentTime: 1000, duration: 1000), .none)
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: false, currentTime: 500, duration: 1000), .seek(500))
        XCTAssertEqual(LibraryViewModel.loadedPlayerSync(loadedItemId: "a", itemId: "a", isFinished: true, currentTime: 1000, duration: 1000), .markFinished)
    }

    func testLoadedBookUsesPlayerPositionWhenUnfinishing() {
        let snaps = [
            LibraryProgressSnapshot(itemId: "a", title: "A", currentTime: 1000, progress: 1, isFinished: false, duration: 1000),
            LibraryProgressSnapshot(itemId: "b", title: "B", currentTime: 1000, progress: 1, isFinished: false, duration: 1000),
        ]
        let out = LibraryViewModel.snapshotsForLoadedPlayer(snaps, loadedItemId: "a", playerTime: 250)
        XCTAssertEqual(out[0].currentTime, 250)
        XCTAssertEqual(out[0].progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(out[1], snaps[1])
        XCTAssertEqual(LibraryViewModel.snapshotsForLoadedPlayer(snaps, loadedItemId: "a", playerTime: 0), snaps)
    }

    func testRollbackSkippedWhenListenerMovedOrPlaying() {
        XCTAssertTrue(LibraryViewModel.shouldRollbackPlayer(movedTo: 100, currentTime: 100.2, isPlaying: false))
        XCTAssertFalse(LibraryViewModel.shouldRollbackPlayer(movedTo: 100, currentTime: 130, isPlaying: false))
        XCTAssertFalse(LibraryViewModel.shouldRollbackPlayer(movedTo: 100, currentTime: 100, isPlaying: true))
    }

    func testFavoritesNormalizedTrims() {
        XCTAssertEqual(FavoritesStore.normalized("  Ray Porter \n"), "ray porter")
    }
}
