import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (clarify + harden): the quiet-pill vs solid-alarm decision.
final class ConnectivityBannerStateTests: XCTestCase {
    private func state(_ status: ReachabilityStore.Status, hasBook: Bool, isLocal: Bool,
                       isPlaying: Bool, pending: Int = 0) -> ConnectivityBannerState? {
        ConnectivityCopy.bannerState(status: status, hasBook: hasBook, isLocal: isLocal,
                                     isPlaying: isPlaying, pendingCount: pending)
    }

    func testOkShowsNothingForEveryPlaybackCombination() {
        for hasBook in [false, true] {
            for isLocal in [false, true] {
                for isPlaying in [false, true] {
                    XCTAssertNil(state(.ok, hasBook: hasBook, isLocal: isLocal, isPlaying: isPlaying, pending: 50))
                }
            }
        }
    }

    func testLocalBookIsQuietWhetherPlayingOrPaused() {
        for status in [ReachabilityStore.Status.offline, .serverUnreachable] {
            for isPlaying in [false, true] {
                let s = state(status, hasBook: true, isLocal: true, isPlaying: isPlaying, pending: 3)
                XCTAssertEqual(s?.style, .quiet)
                XCTAssertTrue(s?.message.hasSuffix("using your download") ?? false)
            }
        }
        XCTAssertEqual(state(.offline, hasBook: true, isLocal: true, isPlaying: true)?.message,
                       "Offline \u{00B7} using your download")
    }

    func testStreamingBookIsAlarmOnlyWhilePlaying() {
        for status in [ReachabilityStore.Status.offline, .serverUnreachable] {
            XCTAssertEqual(state(status, hasBook: true, isLocal: false, isPlaying: true)?.style, .alarm)
            XCTAssertEqual(state(status, hasBook: true, isLocal: false, isPlaying: false)?.style, .quiet)
        }
    }

    func testNothingLoadedIsAlarm() {
        for status in [ReachabilityStore.Status.offline, .serverUnreachable] {
            for isPlaying in [false, true] {
                // isLocal is meaningless without a book (isStreamingCurrentBook is false then).
                for isLocal in [false, true] {
                    let s = state(status, hasBook: false, isLocal: isLocal, isPlaying: isPlaying)
                    XCTAssertEqual(s?.style, .alarm)
                    XCTAssertFalse(s?.message.contains("download") ?? true)
                }
            }
        }
    }

    func testLongQueueDoesNotEscalateAndCountIsNotInBannerMessage() {
        // Critique 2026-10-06: queued positions are safe on the phone, so a long queue with a
        // download playing stays quiet, and the count lives only in the pending pill.
        for n in [1, 9, 10, 12, 50] {
            let s = state(.serverUnreachable, hasBook: true, isLocal: true, isPlaying: true, pending: n)
            XCTAssertEqual(s?.style, .quiet)
            XCTAssertEqual(s?.message, "Can't reach your server \u{00B7} using your download")
            XCTAssertFalse(s?.message.contains("\(n)") ?? true)
        }
        XCTAssertEqual(state(.offline, hasBook: true, isLocal: true, isPlaying: false, pending: 12)?.style, .quiet)
        // Streaming and playing is still the alarm, with no count either.
        let streaming = state(.offline, hasBook: true, isLocal: false, isPlaying: true, pending: 12)
        XCTAssertEqual(streaming?.style, .alarm)
        XCTAssertEqual(streaming?.message, "You're offline")
    }

    func testPendingMessageCopy() {
        XCTAssertEqual(ConnectivityCopy.pendingMessage(count: 1), "1 listening position waiting to sync")
        XCTAssertEqual(ConnectivityCopy.pendingMessage(count: 12), "12 listening positions waiting to sync")
    }

    func testSyncNowHiddenOnlyWhileOffline() {
        XCTAssertFalse(ConnectivityCopy.showsSyncNow(status: .offline))
        XCTAssertTrue(ConnectivityCopy.showsSyncNow(status: .serverUnreachable))
        XCTAssertTrue(ConnectivityCopy.showsSyncNow(status: .ok))
    }

    func testRetryOnlyWhenServerUnreachable() {
        for hasBook in [false, true] {
            for isLocal in [false, true] {
                for isPlaying in [false, true] {
                    XCTAssertEqual(state(.serverUnreachable, hasBook: hasBook, isLocal: isLocal, isPlaying: isPlaying)?.action, .retry)
                    XCTAssertNil(state(.offline, hasBook: hasBook, isLocal: isLocal, isPlaying: isPlaying)?.action)
                }
            }
        }
    }

    func testPendingPillDismissalReturnsOnlyWhenCountGrows() {
        XCTAssertFalse(ConnectivityCopy.pendingPillVisible(count: 0, dismissedAt: nil))
        XCTAssertTrue(ConnectivityCopy.pendingPillVisible(count: 2, dismissedAt: nil))
        XCTAssertFalse(ConnectivityCopy.pendingPillVisible(count: 2, dismissedAt: 2))
        XCTAssertFalse(ConnectivityCopy.pendingPillVisible(count: 1, dismissedAt: 2))
        XCTAssertTrue(ConnectivityCopy.pendingPillVisible(count: 3, dismissedAt: 2))
    }

    func testSyncOutcomeMessages() {
        XCTAssertEqual(ConnectivityCopy.syncOutcomeMessage(before: 3, after: 0), "All synced")
        XCTAssertEqual(ConnectivityCopy.syncOutcomeMessage(before: 5, after: 2), "2 still waiting to sync")
        XCTAssertEqual(ConnectivityCopy.syncOutcomeMessage(before: 3, after: 3), "Couldn't sync \u{00B7} will keep trying")
    }

    func testDrivingStatusSharesBannerWordingAndQuietRule() {
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .offline, header: .paused, isStreaming: false),
                       ConnectivityCopy.message(for: .offline, usingDownload: true))
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .serverUnreachable, header: .paused, isStreaming: true),
                       ConnectivityCopy.message(for: .serverUnreachable, usingDownload: false))
        XCTAssertTrue(PlayerView.drivingStatusIsQuiet(reachability: .offline, isStreaming: false))
        XCTAssertFalse(PlayerView.drivingStatusIsQuiet(reachability: .offline, isStreaming: true))
        XCTAssertFalse(PlayerView.drivingStatusIsQuiet(reachability: .offline, isStreaming: false, startFailure: "x"))
        XCTAssertFalse(PlayerView.drivingStatusIsQuiet(reachability: .ok, isStreaming: false))
    }
}
