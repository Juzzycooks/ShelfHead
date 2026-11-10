import XCTest
@testable import ShelfHead

/// Item 3 (REVIEW-2026-09-09-REMAINING.md, "unclosed prefetch sessions"): pins the rule
/// that decides what happens to a playback session `PlayerViewModel.prefetchNext()`
/// warmed for the next book in Up Next.
///
/// Why this is the thing worth testing: a warmed session is a *server* row —
/// `POST /api/items/<id>/play` opens a listening session before a single sample plays.
/// Only the auto-advance hand-off ever consumed one; every other outcome (stop, a queue
/// edit, a different book started by hand, sign-out, a cancelled prefetch task) dropped
/// the reference and left a zero-time open session behind, visible in the server's
/// Listening Sessions and skewing that book's stats. The fix routes every one of those
/// paths through a single decision — "given what's held and what just happened, keep,
/// hand off, or close" — so that decision is what gets pinned here, per this project's
/// convention of testing the pure function a fix rests on rather than the stateful I/O
/// around it (see `ProgressReconcilerTests`, `CurrentChapterResolutionTests`).
///
/// What this cannot cover: that each call site actually calls it, and that the close
/// request reaches the server. Both need a real server — see the device-check note in the
/// batch entry.
///
/// `@MainActor` because `PlayerViewModel` is, and `PrefetchEvent`/
/// `PrefetchedSessionDisposition` are nested in it — the same reason
/// `CurrentChapterResolutionTests` is.
@MainActor
final class PrefetchedSessionLifetimeTests: XCTestCase {

    private typealias Disposition = PlayerViewModel.PrefetchedSessionDisposition
    private typealias Event = PlayerViewModel.PrefetchEvent

    private func disposition(held: String?, _ event: Event) -> Disposition {
        PlayerViewModel.prefetchedSessionDisposition(heldItemId: held, event: event)
    }

    /// Every event, for the "nothing was warmed" case — used to assert the exhaustive
    /// nil-held rule and to make sure a new event can't silently skip it.
    private var allEvents: [Event] {
        [
            .startingPlayback(itemId: "book-a"),
            .prefetching(itemId: "book-a"),
            .queueHeadChanged(newHeadItemId: "book-a"),
            .queueHeadChanged(newHeadItemId: nil),
            .prefetchCancelled,
            .discarded
        ]
    }

    // MARK: - Nothing held

    func testNothingHeldIsAlwaysKeep() {
        for event in allEvents {
            XCTAssertEqual(disposition(held: nil, event), .keep,
                           "No warmed session means there is nothing to close or hand off (\(event))")
        }
    }

    // MARK: - Hand-off

    func testStartingTheWarmedBookHandsTheSessionOff() {
        XCTAssertEqual(disposition(held: "book-a", .startingPlayback(itemId: "book-a")), .handOff)
    }

    func testStartingADifferentBookClosesTheWarmedSession() {
        // The user tapped another book (or auto-advance skipped a finished title). The
        // warmed session will never be played, so it has to be closed rather than dropped.
        XCTAssertEqual(disposition(held: "book-a", .startingPlayback(itemId: "book-b")), .close)
    }

    func testHandOffIsTheOnlyOutcomeThatEverSurrendersTheSession() {
        // Guards against a future event accidentally being treated as a hand-off: only an
        // exact item match on `.startingPlayback` may return `.handOff`.
        for event in allEvents where event != .startingPlayback(itemId: "book-a") {
            XCTAssertNotEqual(disposition(held: "book-a", event), .handOff,
                              "\(event) must not hand a session to the player")
        }
    }

    // MARK: - Replacement by a new prefetch

    func testPrefetchingTheSameBookKeepsTheExistingSession() {
        // `prefetchNext()` re-runs for the same head (a re-entrant `onNearEnd`, a queue
        // edit that leaves the head alone): the session already in hand is the right one,
        // and closing-and-reopening it would churn a server row for nothing.
        XCTAssertEqual(disposition(held: "book-a", .prefetching(itemId: "book-a")), .keep)
    }

    func testPrefetchingADifferentBookClosesTheOldSession() {
        // This is the "a new prefetch overwrites the old session" leak: the queue head
        // moved, so the old warm session is replaced — and must be closed as it goes.
        XCTAssertEqual(disposition(held: "book-a", .prefetching(itemId: "book-b")), .close)
    }

    // MARK: - Queue mutations

    func testQueueHeadUnchangedKeepsTheSession() {
        // A reorder/removal further down Up Next leaves the next book alone.
        XCTAssertEqual(disposition(held: "book-a", .queueHeadChanged(newHeadItemId: "book-a")), .keep)
    }

    func testQueueReorderedAwayFromTheWarmedBookClosesTheSession() {
        XCTAssertEqual(disposition(held: "book-a", .queueHeadChanged(newHeadItemId: "book-b")), .close)
    }

    func testQueueClearedClosesTheSession() {
        // `clearQueue()` — the Up Next editor's "Clear", and every account teardown
        // (sign out, account switch, account removal) via
        // `AuthViewModel.tearDownAccountScopedState`.
        XCTAssertEqual(disposition(held: "book-a", .queueHeadChanged(newHeadItemId: nil)), .close)
    }

    // MARK: - Cancellation and outright abandonment

    func testCancelledPrefetchClosesTheSessionItOpened() {
        // The POST had already reached the server by the time the task was cancelled, so
        // "return early" is precisely what left the row open.
        XCTAssertEqual(disposition(held: "book-a", .prefetchCancelled), .close)
    }

    func testDiscardClosesTheSession() {
        // `stop()`, autoplay-off, a podcast episode started, auto-advance declining to
        // advance because the next book is streamed and the device is offline.
        XCTAssertEqual(disposition(held: "book-a", .discarded), .close)
    }

    // MARK: - Shape of the decision

    func testDecisionDependsOnlyOnTheHeldItemIdAndTheEvent() {
        // Purity check in the only form a unit test can make it: same inputs, same answer,
        // repeatedly, with unrelated ids in between.
        for _ in 0..<3 {
            XCTAssertEqual(disposition(held: "book-a", .startingPlayback(itemId: "book-a")), .handOff)
            XCTAssertEqual(disposition(held: "book-z", .startingPlayback(itemId: "book-a")), .close)
            XCTAssertEqual(disposition(held: nil, .startingPlayback(itemId: "book-a")), .keep)
        }
    }

    func testItemIdComparisonIsExactNotPrefixed() {
        // Audiobookshelf item ids are opaque strings; "li_abc" must not match "li_abcd".
        XCTAssertEqual(disposition(held: "li_abc", .startingPlayback(itemId: "li_abcd")), .close)
        XCTAssertEqual(disposition(held: "li_abc", .prefetching(itemId: "li_abcd")), .close)
        XCTAssertEqual(disposition(held: "li_abc", .queueHeadChanged(newHeadItemId: "li_abcd")), .close)
    }
}
