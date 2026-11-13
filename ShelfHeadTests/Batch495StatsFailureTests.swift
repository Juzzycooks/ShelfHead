import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 E3): the failed Stats phase keeps the links that work without
/// the stats response.
final class Batch495StatsFailureTests: XCTestCase {
    func testFailedPhaseKeepsFailureBlockYearInReviewAndMore() {
        XCTAssertEqual(StatsScreenSection.sections(for: .failed), [.failureBlock, .yearInReview, .more])
    }

    func testFailedPhaseHidesEverythingFedByTheStatsResponse() {
        let failed = StatsScreenSection.sections(for: .failed)
        for hidden in [StatsScreenSection.hero, .figures, .listening, .history, .mostListened, .yourLibrary] {
            XCTAssertFalse(failed.contains(hidden), "\(hidden) needs the stats response")
        }
    }

    func testContentPhaseHasNoFailureBlockAndKeepsMore() {
        let content = StatsScreenSection.sections(for: .content)
        XCTAssertFalse(content.contains(.failureBlock))
        XCTAssertTrue(content.contains(.more))
        XCTAssertTrue(content.contains(.yearInReview))
        XCTAssertTrue(content.contains(.hero))
    }

    func testSkeletonShowsNoSections() {
        XCTAssertTrue(StatsScreenSection.sections(for: .skeleton).isEmpty)
    }

    // Batch 496: with no cached figures the failed layout is unchanged.
    func testResolveStillRoutesFailureToFailedPhase() {
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: false, loadFailed: true, hasStats: false), .failed)
    }

    // Batch 496 (E3, cache half): a failed load over cached figures keeps the cached screen.
    func testFailedWithCachedStatsHasItsOwnPhaseAndSections() {
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: false, loadFailed: true, hasStats: true, statsAreCached: true), .failedWithCache)
        XCTAssertEqual(StatsScreenSection.sections(for: .failedWithCache),
                       [.failureBlock, .hero, .figures, .yearInReview, .listening, .history, .mostListened, .yourLibrary, .more])
    }

    func testFailedWithoutCacheIsUnchangedByTheCacheFlag() {
        XCTAssertEqual(StatsScreenPhase.resolve(isLoading: false, loadFailed: true, hasStats: false, statsAreCached: false), .failed)
        XCTAssertEqual(StatsScreenSection.sections(for: .failed), [.failureBlock, .yearInReview, .more])
    }
}
