// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section.
//
// Pins review finding High 7 (30 October 2026): a Watch download interrupted by a
// kill/relaunch lost its in-memory state, so the redelivered track completion wrote no
// manifest. The pure decision and the persisted state's shape are pinned here; the
// disk and background-session plumbing around them is not driven.
import XCTest
@testable import ShelfHead_Watch

final class WatchPendingDownloadTests: XCTestCase {

    func testAllTracksPresentWritesManifest() {
        XCTAssertEqual(
            WatchLocalDownloadManager.pendingDownloadAction(
                expectedTrackIndices: [0, 1, 2], presentTrackIndices: [0, 1, 2], hasLiveTask: false),
            .writeManifest)
    }

    func testAllTracksPresentWritesManifestEvenWithLiveTask() {
        // A live cover task must not hold the manifest back.
        XCTAssertEqual(
            WatchLocalDownloadManager.pendingDownloadAction(
                expectedTrackIndices: [0, 1], presentTrackIndices: [0, 1, 7], hasLiveTask: true),
            .writeManifest)
    }

    func testMissingTrackWithLiveTaskKeepsWaiting() {
        XCTAssertEqual(
            WatchLocalDownloadManager.pendingDownloadAction(
                expectedTrackIndices: [0, 1, 2], presentTrackIndices: [0], hasLiveTask: true),
            .keepWaiting)
    }

    func testMissingTrackWithNoLiveTaskFails() {
        XCTAssertEqual(
            WatchLocalDownloadManager.pendingDownloadAction(
                expectedTrackIndices: [0, 1, 2], presentTrackIndices: [0, 2], hasLiveTask: false),
            .markFailed)
    }

    func testNothingPresentAndNothingLiveFails() {
        XCTAssertEqual(
            WatchLocalDownloadManager.pendingDownloadAction(
                expectedTrackIndices: [0], presentTrackIndices: [], hasLiveTask: false),
            .markFailed)
    }

    func testEmptyExpectedListNeverWritesAManifest() {
        XCTAssertEqual(
            WatchLocalDownloadManager.pendingDownloadAction(
                expectedTrackIndices: [], presentTrackIndices: [0], hasLiveTask: false),
            .markFailed)
    }

    @MainActor
    func testPendingStateRoundTrips() throws {
        let chapters = try JSONDecoder().decode(
            [WatchChapter].self,
            from: Data(#"[{"id":0,"start":0,"end":60.5,"title":"One"},{"id":1,"start":60.5,"end":120,"title":"Two"}]"#.utf8))
        let state = WatchPendingDownloadState(
            itemId: "li_abc", title: "A Book", author: "An Author", duration: 7200.25,
            tracks: [
                WatchLocalDownload.Track(index: 0, filename: "track-0.audio", duration: 3600, startOffset: 0),
                WatchLocalDownload.Track(index: 1, filename: "track-1.audio", duration: 3600.25, startOffset: 3600),
            ],
            chapters: chapters,
            serverProgress: WatchServerProgress(currentTime: 99.5, lastUpdateMs: 1_700_000_000_000))

        let decoded = try JSONDecoder().decode(WatchPendingDownloadState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.itemId, "li_abc")
        XCTAssertEqual(decoded.title, "A Book")
        XCTAssertEqual(decoded.author, "An Author")
        XCTAssertEqual(decoded.duration, 7200.25)
        XCTAssertEqual(decoded.tracks.map(\.index), [0, 1])
        XCTAssertEqual(decoded.tracks.map(\.filename), ["track-0.audio", "track-1.audio"])
        XCTAssertEqual(decoded.tracks[1].startOffset, 3600)
        XCTAssertEqual(decoded.chapters?.map(\.title), ["One", "Two"])
        XCTAssertEqual(decoded.serverProgress, state.serverProgress)
    }

    @MainActor
    func testPendingStateWithoutOptionalsRoundTrips() throws {
        let state = WatchPendingDownloadState(
            itemId: "li_x", title: "T", author: "", duration: 0, tracks: [], chapters: nil, serverProgress: nil)
        let decoded = try JSONDecoder().decode(WatchPendingDownloadState.self, from: JSONEncoder().encode(state))
        XCTAssertNil(decoded.chapters)
        XCTAssertNil(decoded.serverProgress)
    }
}
