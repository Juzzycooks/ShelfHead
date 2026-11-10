import XCTest
@testable import ShelfHead

/// N-6 (REVIEW_2026-09-14_DESIGN.md): cover for the two pure pieces behind giving the
/// eight client-side `SmartFilter`s a first-class Home shelf —
/// `SettingsStore`'s one-time seed decisions, and the deep link that lands on one.
///
/// Both are here for the same reason `SettingsMigratorTests` exists: a settings seed that
/// gets its decision wrong surfaces as "the app rearranged/hid my Home screen", which is
/// blamed on almost anything before a one-time migration, and the shelf's own rendering
/// can't be exercised without a running app. The stateful halves —
/// `runHomeShelfSeedsIfNeeded()`'s `UserDefaults` round trip, `HomeView`'s shelf, and
/// `MainTabView.openLibrary(applying:)`'s tab/navigation mutation — are deliberately not
/// tested here, matching this project's precedent of pinning the decision function and
/// leaving the I/O and view state to a device check.
final class SmartFilterShelfTests: XCTestCase {

    private let key = HomeView.smartFiltersKey
    private let anchors = HomeView.smartFiltersOrderAnchors

    // MARK: - The seed's default-visibility decision

    /// Step 1's "show" decision: "visible" in this model means "absent from the hidden
    /// set" — so for an account that has never seen the key, showing must not write it
    /// anywhere. (Step 2 then hides it by default — see the `hiding:` tests below.)
    func testShowDecisionLeavesAnUntouchedHiddenSetAlone() {
        let hidden: Set<String> = ["LabelDiscover", "LabelListenAgain"]
        XCTAssertEqual(SettingsStore.seededHomeVisibility(hidden: hidden, showing: key), hidden)
        XCTAssertFalse(SettingsStore.seededHomeVisibility(hidden: hidden, showing: key).contains(key),
                       "Showing a shelf must not add it to the hidden set")
    }

    func testShowDecisionOnAnEmptyHiddenSetStaysEmpty() {
        XCTAssertTrue(SettingsStore.seededHomeVisibility(hidden: [], showing: key).isEmpty)
    }

    /// Showing removes only the named key and leaves every other shelf's choice alone.
    func testShowDecisionUnhidesOnlyTheNamedKey() {
        let hidden: Set<String> = [key, "LabelDiscover", HomeView.narratorShelfKey]
        let seeded = SettingsStore.seededHomeVisibility(hidden: hidden, showing: key)
        XCTAssertFalse(seeded.contains(key))
        XCTAssertEqual(seeded, ["LabelDiscover", HomeView.narratorShelfKey],
                       "Seeding one shelf visible must not disturb any other shelf's choice")
    }

    /// The show decision only ever *removes*.
    func testShowDecisionNeverHidesAnything() {
        let hidden: Set<String> = ["LabelDiscover"]
        let seeded = SettingsStore.seededHomeVisibility(hidden: hidden, showing: key)
        XCTAssertTrue(seeded.isSubset(of: hidden))
    }

    // MARK: - Step 2: hidden by default (Batch 320, user decision on device)

    /// The shelf ships hidden: step 2 adds the key to the hidden set on a fresh install
    /// (which has just run step 1 and has an empty hidden set).
    func testHideDecisionHidesTheShelfOnAFreshInstall() {
        let seeded = SettingsStore.seededHomeVisibility(hidden: [], hiding: key)
        XCTAssertEqual(seeded, [key])
    }

    /// …and on a device that already ran step 1 with other shelves hidden, it adds only
    /// the Smart Filters key and disturbs nothing else.
    func testHideDecisionAddsOnlyTheNamedKey() {
        let hidden: Set<String> = ["LabelDiscover", HomeView.narratorShelfKey]
        let seeded = SettingsStore.seededHomeVisibility(hidden: hidden, hiding: key)
        XCTAssertEqual(seeded, hidden.union([key]))
    }

    /// Idempotent: re-running the hide on an already-hidden key is a no-op.
    func testHideDecisionIsIdempotent() {
        let hidden: Set<String> = [key, "LabelDiscover"]
        XCTAssertEqual(SettingsStore.seededHomeVisibility(hidden: hidden, hiding: key), hidden)
    }

    /// The structural cap must not re-show it: the key is deliberately absent from
    /// `HomeView.defaultVisibleBrowseKeys` (Batch 320).
    func testSmartFiltersIsNotOnTheAlwaysVisibleAllowlist() {
        XCTAssertFalse(HomeView.defaultVisibleBrowseKeys.contains(key))
    }

    // MARK: - The seed's placement decision

    /// The order every account that has never dragged its own comes in with — what
    /// `SettingsMigrator`'s step 2 seeds. Smart Filters lands directly after Next in
    /// Series, ahead of B-Side / Recently Added / Downloaded (placement is independent of
    /// visibility — the shelf is placed by step 1 and hidden by step 2).
    func testSeedPlacesTheShelfAfterTheDefaultContinueSeriesAnchor() {
        let saved = ["LabelContinueSeries", HomeView.bSideKey,
                     "LabelRecentlyAdded", HomeView.downloadedShelfKey]
        XCTAssertEqual(
            SettingsStore.seededHomeOrder(saved: saved, inserting: key, after: anchors),
            ["LabelContinueSeries", key, HomeView.bSideKey,
             "LabelRecentlyAdded", HomeView.downloadedShelfKey]
        )
    }

    /// Anchors are matched at their *latest* position, not the first one found — a user
    /// who dragged Next in Series above Continue Listening still gets the shelf below
    /// both of them rather than wedged between them.
    func testSeedUsesTheLatestAnchorPositionNotTheFirst() {
        let saved = ["LabelContinueSeries", "LabelContinueListening", "LabelRecentlyAdded"]
        XCTAssertEqual(
            SettingsStore.seededHomeOrder(saved: saved, inserting: key, after: anchors),
            ["LabelContinueSeries", "LabelContinueListening", key, "LabelRecentlyAdded"]
        )
    }

    func testSeedPlacesTheShelfAfterContinueListeningWhenItIsTheOnlyAnchorPresent() {
        let saved = ["LabelContinueListening", "LabelRecentlyAdded", HomeView.downloadedShelfKey]
        XCTAssertEqual(
            SettingsStore.seededHomeOrder(saved: saved, inserting: key, after: anchors),
            ["LabelContinueListening", key, "LabelRecentlyAdded", HomeView.downloadedShelfKey]
        )
    }

    /// With no anchor to follow, the front is the intent's nearest neighbour: the shelf
    /// is meant to sit at the top of BROWSE, so falling back to the *end* would bury it
    /// under everything — the opposite of the finding this exists to fix.
    func testSeedPlacesTheShelfFirstWhenNoAnchorIsPresent() {
        let saved = ["LabelRecentlyAdded", HomeView.downloadedShelfKey]
        XCTAssertEqual(
            SettingsStore.seededHomeOrder(saved: saved, inserting: key, after: anchors),
            [key, "LabelRecentlyAdded", HomeView.downloadedShelfKey]
        )
    }

    /// Idempotent — `HomeView.availableSectionKeys` calls this on every recompute, so a
    /// key already in place must never be moved or duplicated.
    func testSeedIsIdempotentForAKeyAlreadyPlaced() {
        let saved = ["LabelContinueSeries", HomeView.bSideKey, key, "LabelRecentlyAdded"]
        XCTAssertEqual(SettingsStore.seededHomeOrder(saved: saved, inserting: key, after: anchors), saved,
                       "An already-placed shelf must stay exactly where the user left it")
    }

    func testSeedOnAnEmptyOrderProducesTheKeyAlone() {
        XCTAssertEqual(SettingsStore.seededHomeOrder(saved: [], inserting: key, after: anchors), [key])
    }

    /// Nothing is ever dropped: whatever the saved order held comes back, in the same
    /// relative order, with exactly one key added.
    func testSeedPreservesEveryExistingKeyAndItsRelativeOrder() {
        let saved = ["LabelContinueListening", "LabelContinueSeries", HomeView.weekStatsKey,
                     HomeView.narratorShelfKey, "LabelDiscover"]
        let seeded = SettingsStore.seededHomeOrder(saved: saved, inserting: key, after: anchors)
        XCTAssertEqual(seeded.count, saved.count + 1)
        XCTAssertEqual(seeded.filter { $0 != key }, saved)
    }

    // MARK: - Deep-link parsing

    private func parse(_ string: String) -> SmartFilter? {
        guard let url = URL(string: string) else {
            XCTFail("Not a URL: \(string)")
            return nil
        }
        return DeepLinkParser.smartFilter(in: url)
    }

    func testEverySmartFilterRoundTripsThroughItsOwnDeepLink() {
        for filter in SmartFilter.allCases {
            guard let url = DeepLinkParser.libraryURL(smartFilter: filter) else {
                XCTFail("No URL built for \(filter.rawValue)")
                continue
            }
            XCTAssertEqual(DeepLinkParser.smartFilter(in: url), filter,
                           "\(filter.rawValue) must survive the URL the lock-screen queue replays")
            XCTAssertEqual(url.host, "library",
                           "The queued URL has to re-enter handleDeepLink's `library` case")
        }
    }

    func testParsesTheSmartFilterParameter() {
        XCTAssertEqual(parse("shelfhead://library?smartFilter=nearlyFinished"), .nearlyFinished)
        XCTAssertEqual(parse("shelfhead://library?smartFilter=unplayedInStartedSeries"),
                       .unplayedInStartedSeries)
    }

    /// The existing plain link keeps its existing behaviour — nil here is what makes
    /// `handleDeepLink` fall through to "just select the tab".
    func testPlainLibraryLinkAsksForNoFilter() {
        XCTAssertNil(parse("shelfhead://library"))
        XCTAssertNil(parse("shelfhead://library?"))
    }

    /// User-authorable URLs can outlive a renamed case; degrading to an unfiltered
    /// Library beats a link that silently does nothing.
    func testUnknownOrEmptyRawValueAsksForNoFilter() {
        XCTAssertNil(parse("shelfhead://library?smartFilter=notAFilter"))
        XCTAssertNil(parse("shelfhead://library?smartFilter="))
        XCTAssertNil(parse("shelfhead://library?smartFilter=NEARLYFINISHED"),
                     "Raw values are case-sensitive; a near-miss must not resolve")
    }

    func testTheParameterIsOnlyHonouredOnTheLibraryHost() {
        XCTAssertNil(parse("shelfhead://downloads?smartFilter=nearlyFinished"))
        XCTAssertNil(parse("shelfhead://nowplaying?smartFilter=nearlyFinished"))
        XCTAssertNil(parse("shelfhead://book/abc123?smartFilter=nearlyFinished"))
    }

    func testOtherQueryParametersAreIgnored() {
        XCTAssertEqual(parse("shelfhead://library?foo=bar&smartFilter=stale&baz=1"), .stale)
        XCTAssertNil(parse("shelfhead://library?filter=stale"),
                     "Only the `smartFilter` parameter selects a filter")
    }
}
