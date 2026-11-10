import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • YearInReviewTruncationTests
// =============================================================================
//
// Y7 (REVIEW_2026-09-04_UI.md): `YearInReviewView.loadSessions(forYear:)` pages
// newest-first and stops as soon as a page's oldest session predates the target
// year — but it's also bounded to a page cap, and a heavy listener whose year
// didn't fit inside that cap would otherwise see silently undercounted "Books
// Listened To" / "Most-Listened Author" / "Longest Session" figures with no
// indication anything was cut off. Pins the pure predicate the view uses to detect
// that case, since `loadSessions(forYear:)` itself talks to the real network API
// and isn't unit-testable directly — same "extract the decision, test the
// decision" precedent as `AccountRemovalTests.swift` and
// `DownloadManager.shouldReclaimOrphanDirectory`.
final class YearInReviewTruncationTests: XCTestCase {

    func testCapHitBeforeReachingYearStartIsIncomplete() {
        XCTAssertTrue(
            YearInReviewView.sessionsAreIncomplete(pagesFetched: 20, maxPages: 20, reachedYearStart: false)
        )
    }

    func testCapHitButYearStartWasReachedIsComplete() {
        XCTAssertFalse(
            YearInReviewView.sessionsAreIncomplete(pagesFetched: 20, maxPages: 20, reachedYearStart: true)
        )
    }

    func testFewerPagesThanCapIsComplete() {
        XCTAssertFalse(
            YearInReviewView.sessionsAreIncomplete(pagesFetched: 5, maxPages: 20, reachedYearStart: false)
        )
    }
}
