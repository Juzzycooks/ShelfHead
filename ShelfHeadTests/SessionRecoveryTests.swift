import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • SessionRecoveryTests
// =============================================================================
//
// Item 2 (REVIEW-2026-09-09 remaining): "no recovery when a playback session goes
// invalid server-side."
//
// Root cause, confirmed in `AudioPlayerService.syncProgress()`: every `syncSession`
// failure was treated identically to being offline — log it, re-queue the position,
// carry the listened time forward, try again in 30 seconds. That's right for a dropped
// connection and wrong for an Audiobookshelf restart, which drops every in-memory
// playback session: from then on *every* sync for the current listen 404s, forever.
// The position keeps reaching the server anyway (`/api/me/progress`, via the pending
// queue), so nothing looks broken — but `timeListened`, the only input to the server's
// listening stats, streaks and daily goal, is never delivered, and `closeSession()` is
// a `try?` against an id the server has never heard of.
//
// Only the decisions are pinned here. The reopen itself (`startPlaybackSession`, swapping
// the id into `currentSession`) is live network + `@MainActor` player state, the same
// line `NowPlayingChapterRepublishTests` and `DownloadManager.shouldReclaimOrphan
// Directory` already draw around their own I/O.
final class SessionRecoveryTests: XCTestCase {

    private let liveSession = "sess-abc123"

    // MARK: - shouldReopenSession(after:sessionId:)

    func testA404MeansTheSessionIsGoneAndShouldBeReopened() {
        // Audiobookshelf's answer for an unknown session id — the restart case.
        XCTAssertTrue(AudioPlayerService.shouldReopenSession(
            after: APIError.notFound, sessionId: liveSession))
    }

    func testA400IsAlsoTreatedAsAnInvalidSessionId() {
        XCTAssertTrue(AudioPlayerService.shouldReopenSession(
            after: APIError.httpError(400), sessionId: liveSession))
    }

    func testOtherHTTPStatusesDoNotReopen() {
        // 429 is a proxy rate-limiting us, not a missing session; retrying the same
        // session later is the right move.
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: APIError.httpError(429), sessionId: liveSession))
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: APIError.httpError(418), sessionId: liveSession))
    }

    func testServerErrorsDoNotReopen() {
        // A 502 from a proxy while the server restarts is transient; the session may well
        // still exist once it comes back.
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: APIError.serverError(502), sessionId: liveSession))
    }

    func testAuthAndTransportFailuresDoNotReopen() {
        // A 401 has already been refreshed-and-retried once inside `AudiobookshelfAPI.send`
        // by the time it surfaces here, and a URLError is simply "no network".
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: APIError.unauthorized, sessionId: liveSession))
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: APIError.forbidden, sessionId: liveSession))
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: URLError(.notConnectedToInternet), sessionId: liveSession))
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: URLError(.timedOut), sessionId: liveSession))
    }

    func testAnOfflineSessionIsNeverReopened() {
        // `offline-` sessions are synthesized from a download manifest
        // (`DownloadedBook.localSession`) and have no server counterpart at all.
        XCTAssertFalse(AudioPlayerService.shouldReopenSession(
            after: APIError.notFound, sessionId: "offline-item-42"))
    }

    // MARK: - shouldAttemptSessionReopen(now:lastAttemptAt:minInterval:)

    func testTheFirstReopenAttemptIsAlwaysAllowed() {
        XCTAssertTrue(AudioPlayerService.shouldAttemptSessionReopen(
            now: Date(), lastAttemptAt: nil))
    }

    func testASecondAttemptWithinTheWindowIsRefused() {
        // The loop guard: a server that 404s the *freshly created* session too (a deleted
        // item, a proxy swallowing `/play`) would otherwise get one `/play` request per
        // failed sync, forever.
        let now = Date()
        XCTAssertFalse(AudioPlayerService.shouldAttemptSessionReopen(
            now: now, lastAttemptAt: now.addingTimeInterval(-59)))
    }

    func testAnAttemptIsAllowedAgainOnceTheWindowHasPassed() {
        let now = Date()
        XCTAssertTrue(AudioPlayerService.shouldAttemptSessionReopen(
            now: now, lastAttemptAt: now.addingTimeInterval(-60)))
        XCTAssertTrue(AudioPlayerService.shouldAttemptSessionReopen(
            now: now, lastAttemptAt: now.addingTimeInterval(-600)))
    }

    func testTheWindowIsAtLeastAsLongAsTwoPeriodicSyncs() {
        // The periodic sync runs every 30s (`startPeriodicSync`), so a default under 30
        // would let every single failing sync spawn a reopen.
        let now = Date()
        XCTAssertFalse(AudioPlayerService.shouldAttemptSessionReopen(
            now: now, lastAttemptAt: now.addingTimeInterval(-30)))
    }

    // MARK: - carryForwardTimeListened(pending:failed:)

    func testAFailedSyncsListenedTimeRollsIntoTheNextOne() {
        // `syncProgress()` zeroes `timeListenedSinceSync` in its synchronous prologue, so
        // a failure has to put it back or that window of listening is lost outright.
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: 12, failed: 30), 42)
    }

    func testCarryForwardAccumulatesAcrossRepeatedFailures() {
        // The invalid-session case: sync after sync fails, and this accumulator is the
        // only thing carrying the whole listen forward to whichever session finally
        // accepts it.
        var total: Double = 0
        for _ in 0..<10 {
            total = AudioPlayerService.carryForwardTimeListened(pending: total, failed: 30)
        }
        XCTAssertEqual(total, 300)
    }

    func testNonFiniteInputsAreDroppedRatherThanPropagated() {
        // The running total is incremented from an AVPlayer time observer; one NaN would
        // otherwise poison every later sync's `timeListened` (and the server's stats with
        // it) until the book changed.
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: .nan, failed: 30), 30)
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: 30, failed: .nan), 30)
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: .infinity, failed: 5), 5)
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: .nan, failed: .nan), 0)
    }

    func testNegativeInputsAreDropped() {
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: -100, failed: 30), 30)
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: 30, failed: -100), 30)
    }

    func testZeroIsAValidResult() {
        XCTAssertEqual(AudioPlayerService.carryForwardTimeListened(pending: 0, failed: 0), 0)
    }
}
