import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • NowPlayingArtworkStalenessTests
// =============================================================================
//
// Pins `AudioPlayerService.shouldApplyFetchedArtwork(fetchedItemId:currentItemId:
// fetchGeneration:currentGeneration:)`, the guard that keeps fix 9.2
// (REVIEW-2026-09-09.md) from trading a main-thread hitch for a wrong cover.
//
// That fix moved the Now Playing cover decode, the 240×240 thumbnail and the JPEG
// encode into `Task.detached` — they had been running on the main actor, because a
// bare `Task {}` in a `@MainActor` method inherits main isolation under
// `SWIFT_APPROACHABLE_CONCURRENCY`. Moving the work off-actor widens the window
// between "cover bytes arrived" and "cover applied", so what lands has to be
// re-checked against the session that is current *now*: the old code checked the
// item id only, which misses two same-id fetches finishing out of order (a stream
// recovery or a Watch-initiated resume re-opens the session for the same book).
//
// Only the decision is tested — the fetch, the decode and the
// `MPNowPlayingInfoCenter`/App Group writes around it need a live server and device,
// the same line `NowPlayingChapterRepublishTests` draws around the actual publish.
final class NowPlayingArtworkStalenessTests: XCTestCase {

    private func shouldApply(
        fetched: String, current: String?, generation: Int, currentGeneration: Int
    ) -> Bool {
        AudioPlayerService.shouldApplyFetchedArtwork(
            fetchedItemId: fetched, currentItemId: current,
            fetchGeneration: generation, currentGeneration: currentGeneration)
    }

    /// The ordinary case: one fetch, still the current book, still the newest request.
    func testTheOnlyInFlightFetchForTheCurrentBookApplies() {
        XCTAssertTrue(shouldApply(fetched: "book1", current: "book1", generation: 7, currentGeneration: 7))
    }

    /// The case the original `currentItemId` check was written for — a slow fetch
    /// landing after the user started a different book.
    func testArtworkForAPreviousBookIsRejected() {
        XCTAssertFalse(shouldApply(fetched: "book1", current: "book2", generation: 3, currentGeneration: 4),
                       "A cover for the book we just left must never replace the current one.")
    }

    /// After `stop()` there is no current item, and nothing should be published — the
    /// player has already cleared `MPNowPlayingInfoCenter` and the App Group cover.
    func testArtworkArrivingAfterStopIsRejected() {
        XCTAssertFalse(shouldApply(fetched: "book1", current: nil, generation: 3, currentGeneration: 3),
                       "A stop clears Now Playing; a late decode must not republish artwork.")
    }

    /// The case the item-id check alone cannot catch, and the reason the generation
    /// token exists: two fetches for the *same* book (a session re-open after a stream
    /// recovery, or a Watch-initiated resume) finishing out of order. Only the newest
    /// request may apply, whichever one happens to finish last.
    func testAnOlderFetchForTheSameBookIsRejected() {
        XCTAssertFalse(shouldApply(fetched: "book1", current: "book1", generation: 4, currentGeneration: 5),
                       "An overtaken fetch for the same book must lose, not win by finishing last.")
        XCTAssertTrue(shouldApply(fetched: "book1", current: "book1", generation: 5, currentGeneration: 5),
                      "The newest request for the current book is the one that applies.")
    }

    /// Both conditions have to hold, so a generation that happens to match while the
    /// book has changed (counters are per-service, not per-item) still fails.
    func testMatchingGenerationDoesNotOverrideAChangedItem() {
        XCTAssertFalse(shouldApply(fetched: "book1", current: "book2", generation: 9, currentGeneration: 9))
    }
}
