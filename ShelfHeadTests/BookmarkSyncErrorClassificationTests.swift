import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • BookmarkSyncErrorClassificationTests
// =============================================================================
//
// Pins the two pure decisions behind fix 9.1 (REVIEW-2026-09-09.md):
// `BookmarkSyncService.bookmarkSyncStatusCode(for:)` and
// `isTerminalBookmarkSyncError(statusCode:)`.
//
// The [MEDIUM] half of that fix was head-of-line blocking in `flush()`: the replay
// loop `break`ed on *any* error, so one queued operation that could never succeed —
// a `.delete` of a bookmark the server no longer has, an operation against a library
// this account lost access to — stranded every bookmark queued behind it until
// `PendingBookmarkQueue.drain`'s 30-day `maxAge` finally evicted it. The loop now
// drops a terminal failure and continues, and stops only for failures where the
// remaining entries genuinely are better off staying queued.
//
// Only the classification is tested. The flush itself needs a live
// `AudiobookshelfAPI`, `NetworkMonitor` and `AuthStore`, the same line
// `DownloadManager.shouldReclaimOrphanDirectory` draws around the disk-scanning
// sweep that calls it and `NowPlayingChapterRepublishTests` draws around the actual
// `MPNowPlayingInfoCenter` publish.
final class BookmarkSyncErrorClassificationTests: XCTestCase {

    private func status(_ error: Error) -> Int? {
        BookmarkSyncService.bookmarkSyncStatusCode(for: error)
    }

    private func isTerminal(_ error: Error) -> Bool {
        BookmarkSyncService.isTerminalBookmarkSyncError(error)
    }

    // MARK: - Status extraction

    /// `AudiobookshelfAPI.validateStatus` turns 401/403/404 into named cases that no
    /// longer carry their number, so the mapping back has to be explicit. If these
    /// drift, a `403` starts looking like a transport failure and blocks the queue again.
    func testNamedAPIErrorsMapBackToTheirStatus() {
        XCTAssertEqual(status(APIError.unauthorized), 401)
        XCTAssertEqual(status(APIError.forbidden), 403)
        XCTAssertEqual(status(APIError.notFound), 404)
    }

    /// Everything `validateStatus` doesn't name keeps its number, including the 4xx
    /// codes the classifier actually cares about (`410`, `422`) and every `5xx`.
    func testNumberedAPIErrorsKeepTheirStatus() {
        XCTAssertEqual(status(APIError.httpError(410)), 410)
        XCTAssertEqual(status(APIError.httpError(422)), 422)
        XCTAssertEqual(status(APIError.httpError(429)), 429)
        XCTAssertEqual(status(APIError.serverError(500)), 500)
        XCTAssertEqual(status(APIError.serverError(503)), 503)
    }

    /// No status at all means the request never got an HTTP answer — offline, DNS,
    /// TLS, timeout. Those are the case the flush's `break` exists for.
    func testErrorsWithoutAStatusReportNil() {
        XCTAssertNil(status(URLError(.notConnectedToInternet)))
        XCTAssertNil(status(URLError(.timedOut)))
        XCTAssertNil(status(APIError.invalidURL))
        XCTAssertNil(status(APIError.invalidResponse))
        XCTAssertNil(status(APIError.decodingError(URLError(.cannotParseResponse))))
    }

    // MARK: - Terminal vs. retryable

    /// The bug this fix closes: a queued `.delete` for a bookmark the server has
    /// already lost fails `404` forever. It has to be droppable, or nothing queued
    /// after it ever syncs.
    func testGoneAndRejectedStatusesAreTerminal() {
        for code in [400, 403, 404, 410, 422] {
            XCTAssertTrue(
                BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: code),
                "\(code) can only ever fail the same way; it must not block the queue.")
        }
    }

    /// The other half of the fix: these must NOT be treated as terminal, or a server
    /// restart or an expired session would silently discard the user's bookmarks
    /// instead of retrying them — a strictly worse bug than the one being fixed.
    func testRetryableStatusesAreNotTerminal() {
        // 401 reaching the flush means `AudiobookshelfAPI.send`'s own
        // refresh-and-retry-once already failed; the next flush runs after the user
        // has re-authenticated, so the same write may well succeed then.
        XCTAssertFalse(BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: 401))
        // Explicitly "try again later".
        XCTAssertFalse(BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: 408))
        XCTAssertFalse(BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: 429))
        // A conflict may resolve on its own; retrying is not obviously wrong.
        XCTAssertFalse(BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: 409))
        for code in [500, 502, 503, 504] {
            XCTAssertFalse(
                BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: code),
                "\(code) is the server having a bad moment, not a bookmark to throw away.")
        }
    }

    /// The convenience overload the `catch where` clause in `flush()` actually calls,
    /// end to end from an `Error`.
    func testErrorOverloadMatchesTheStatusPolicy() {
        XCTAssertTrue(isTerminal(APIError.notFound))
        XCTAssertTrue(isTerminal(APIError.forbidden))
        XCTAssertTrue(isTerminal(APIError.httpError(410)))

        XCTAssertFalse(isTerminal(APIError.unauthorized))
        XCTAssertFalse(isTerminal(APIError.serverError(503)))
        XCTAssertFalse(isTerminal(APIError.httpError(429)))
        // A statusless error is retryable by definition — this is the "the connection
        // went away again" case the loop stops on.
        XCTAssertFalse(isTerminal(URLError(.notConnectedToInternet)))
        XCTAssertFalse(isTerminal(APIError.decodingError(URLError(.cannotParseResponse))))
    }

    /// A `2xx` never reaches the classifier (it isn't an error), but the policy should
    /// still not claim success is terminal — that would read as "drop it" if the
    /// function were ever reused on a raw status.
    func testSuccessStatusesAreNotTerminal() {
        XCTAssertFalse(BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: 200))
        XCTAssertFalse(BookmarkSyncService.isTerminalBookmarkSyncError(statusCode: 204))
    }
}
