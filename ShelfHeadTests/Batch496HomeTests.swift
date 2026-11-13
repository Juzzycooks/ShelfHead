import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 N4, N5): Home's shelf caps, which shelves get See all, and
/// when the profile button shows.
final class Batch496HomeTests: XCTestCase {

    // MARK: - N4 caps

    func testAlsoInProgressShowsAtMostThreeRows() {
        XCTAssertEqual(HomeState.alsoInProgressRowCap, 3)
        let nine = (1...9).map { "book\($0)" }
        XCTAssertEqual(HomeState.capped(nine, to: HomeState.alsoInProgressRowCap), ["book1", "book2", "book3"])
        XCTAssertEqual(HomeState.capped(["a", "b"], to: HomeState.alsoInProgressRowCap), ["a", "b"])
    }

    func testAlsoInProgressSeeAllOnlyWhenSomethingIsHidden() {
        XCTAssertFalse(HomeState.alsoInProgressHasSeeAll(otherCount: 0))
        XCTAssertFalse(HomeState.alsoInProgressHasSeeAll(otherCount: 3))
        XCTAssertTrue(HomeState.alsoInProgressHasSeeAll(otherCount: 4))
        XCTAssertTrue(HomeState.alsoInProgressHasSeeAll(otherCount: 9))
    }

    func testDownloadedShelfCappedAtADozen() {
        XCTAssertEqual(HomeState.downloadedTileCap, 12)
        let forty = Array(0..<40)
        XCTAssertEqual(HomeState.capped(forty, to: HomeState.downloadedTileCap), Array(0..<12))
        XCTAssertEqual(HomeState.capped(Array(0..<5), to: HomeState.downloadedTileCap).count, 5)
    }

    func testCappedHandlesEdgeCases() {
        XCTAssertEqual(HomeState.capped([Int](), to: 3), [])
        XCTAssertEqual(HomeState.capped([1, 2], to: 0), [])
        XCTAssertEqual(HomeState.capped([1, 2], to: -1), [])
    }

    // MARK: - N4 See all

    func testSeeAllDestinations() {
        XCTAssertEqual(HomeState.seeAllDestination(forSectionKey: "LabelRecentlyAdded"), .recentlyAdded)
        XCTAssertEqual(HomeState.seeAllDestination(forSectionKey: "LabelContinueSeries"), .series)
        XCTAssertEqual(HomeState.seeAllDestination(forSectionKey: HomeView.downloadedShelfKey), .downloads)
    }

    func testShelvesWithoutACheapFullListGetNoSeeAll() {
        // Batch 497 (N4): Listen Again and the narrator shelf now have one (Batch497HomeTests).
        for key in ["LabelContinueListening", "LabelDiscover", "SomeServerLabel",
                    HomeView.weekStatsKey, HomeView.bSideKey,
                    HomeView.otherServersKey, HomeView.releaseRadarKey, HomeView.householdKey,
                    HomeView.smartFiltersKey] {
            XCTAssertNil(HomeState.seeAllDestination(forSectionKey: key), key)
        }
    }

    func testSeeAllLabelsNameTheShelf() {
        let destinations: [HomeState.SeeAllDestination] = [.recentlyAdded, .series, .downloads, .alsoInProgress]
        let labels = destinations.map(HomeState.seeAllAccessibilityLabel)
        XCTAssertEqual(Set(labels).count, destinations.count)
        for label in labels {
            XCTAssertNotEqual(label, "See all")
            XCTAssertTrue(label.hasPrefix("See all "), label)
        }
        XCTAssertEqual(HomeState.seeAllAccessibilityLabel(.recentlyAdded), "See all recently added")
    }

    func testRecentlyAddedPaging() {
        XCTAssertTrue(HomeState.recentlyAddedHasMore(loaded: 50, total: 120, lastPageCount: 50))
        XCTAssertFalse(HomeState.recentlyAddedHasMore(loaded: 120, total: 120, lastPageCount: 20))
        // A server that over-reports its total can't make the page fetch forever.
        XCTAssertFalse(HomeState.recentlyAddedHasMore(loaded: 100, total: 500, lastPageCount: 0))
    }

    // MARK: - N5 profile button

    func testProfileButtonNeedsSomeoneToSwitchTo() {
        XCTAssertFalse(HomeState.showsProfileButton(savedAccountCount: 0, hasAnyKid: false, isAppLocked: false))
        XCTAssertFalse(HomeState.showsProfileButton(savedAccountCount: 1, hasAnyKid: false, isAppLocked: false))
        XCTAssertTrue(HomeState.showsProfileButton(savedAccountCount: 2, hasAnyKid: false, isAppLocked: false))
        XCTAssertTrue(HomeState.showsProfileButton(savedAccountCount: 1, hasAnyKid: true, isAppLocked: false))
    }

    func testProfileButtonNeverShownWhileLocked() {
        for count in 0...3 {
            for kid in [false, true] {
                XCTAssertFalse(HomeState.showsProfileButton(savedAccountCount: count, hasAnyKid: kid, isAppLocked: true))
            }
        }
    }
}
