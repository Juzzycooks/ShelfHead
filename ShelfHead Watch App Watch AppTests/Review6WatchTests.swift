import XCTest
@testable import ShelfHead_Watch

final class Review6WatchTests: XCTestCase {
    func testStaleFilenamesClearedWithoutManifest() {
        let names = ["track-0.audio", "track-1.audio", "pending.json", "cover.jpg", "manifest.json"]
        XCTAssertEqual(Set(WatchLocalDownloadManager.staleFilenames(hasManifest: false, directoryContents: names)),
                       ["track-0.audio", "track-1.audio", "pending.json"])
    }

    func testStaleFilenamesNeverTouchCompletedDownload() {
        XCTAssertTrue(WatchLocalDownloadManager.staleFilenames(hasManifest: true,
                                                               directoryContents: ["track-0.audio", "manifest.json"]).isEmpty)
    }

    func testHandoffSwitchesAccountOnlyForDifferentServer() {
        XCTAssertFalse(WatchStore.handoffSwitchesAccount(existingServerURL: nil, incomingServerURL: "https://a.com"))
        XCTAssertFalse(WatchStore.handoffSwitchesAccount(existingServerURL: "https://ABS.com/", incomingServerURL: "https://abs.com"))
        XCTAssertTrue(WatchStore.handoffSwitchesAccount(existingServerURL: "https://a.com", incomingServerURL: "https://b.com"))
    }

    func testMatchesSentDetectsReplacement() {
        let sent = WatchPendingBookmarkQueue.Entry(itemId: "i", title: "A", time: 10.2)
        var same = sent; same.ambiguousFailures = 1
        XCTAssertTrue(WatchPendingBookmarkQueue.matchesSent(same, sent))
        var replaced = WatchPendingBookmarkQueue.Entry(itemId: "i", title: "B", time: 10.7)
        replaced.id = sent.id
        XCTAssertFalse(WatchPendingBookmarkQueue.matchesSent(replaced, sent))
    }
}
