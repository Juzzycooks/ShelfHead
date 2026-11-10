import XCTest
@testable import ShelfHead

/// Pins Home's NOW-zone hero source, the load-failure vs empty classification, the
/// BROWSE header rule and the hero's composite VoiceOver label (critique 2026-10-05).
final class HomeStateTests: XCTestCase {
    private typealias C = HomeState.DownloadCandidate

    // Critique 2026-10-05 (Home, 2nd): the loaded unfinished book leads even with a server shelf.
    func testLoadedUnfinishedBookLeadsOverServerShelf() {
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: true, currentBookID: "a", currentBookProgress: 0.2,
                                            downloads: [C(id: "d", progress: 0.5, lastUpdate: 9)]), .currentBook)
    }

    func testServerShelfUsedWhenNoCurrentBookOrItIsFinished() {
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: true, currentBookID: nil, currentBookProgress: nil,
                                            downloads: []), .server)
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: true, currentBookID: "a", currentBookProgress: 0.995,
                                            downloads: []), .server)
    }

    func testRestoredCurrentBookIsHeroWhenShelfAbsent() {
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: false, currentBookID: "a", currentBookProgress: nil,
                                            downloads: []), .currentBook)
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: false, currentBookID: "a", currentBookProgress: 0.4,
                                            downloads: [C(id: "d", progress: 0.5, lastUpdate: 9)]), .currentBook)
    }

    func testFinishedCurrentBookFallsThroughToDownloads() {
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: false, currentBookID: "a", currentBookProgress: 0.995,
                                            downloads: [C(id: "d", progress: 0.5, lastUpdate: 9)]), .downloaded(id: "d"))
    }

    func testMostRecentStartedUnfinishedDownloadIsChosen() {
        let downloads = [
            C(id: "old", progress: 0.3, lastUpdate: 100),
            C(id: "new", progress: 0.1, lastUpdate: 500),
            C(id: "fresh", progress: 0, lastUpdate: 900),      // never started
            C(id: "done", progress: 1.0, lastUpdate: 999),     // finished
        ]
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: false, currentBookID: nil, currentBookProgress: nil,
                                            downloads: downloads), .downloaded(id: "new"))
    }

    func testNoSourcesMeansNoHero() {
        XCTAssertEqual(HomeState.heroChoice(serverHasItems: false, currentBookID: nil, currentBookProgress: nil,
                                            downloads: [C(id: "x", progress: 0, lastUpdate: nil)]), .none)
    }

    func testEmptyKindDistinguishesFailureFromEmpty() {
        typealias K = HomeState.EmptyKind
        func kind(_ r: ReachabilityStore.Status, failed: Bool = false, libs: Bool = true, selected: Bool = true) -> K {
            HomeState.emptyKind(reachability: r, loadFailed: failed, hasLibraries: libs, hasSelectedLibrary: selected)
        }
        XCTAssertEqual(kind(.offline), .offline)
        XCTAssertEqual(kind(.serverUnreachable), .serverUnreachable)
        XCTAssertEqual(kind(.ok, failed: true), .loadFailed)
        XCTAssertEqual(kind(.ok, failed: true, libs: false, selected: false), .loadFailed)
        XCTAssertEqual(kind(.ok, libs: false, selected: false), .noLibraries)
        XCTAssertEqual(kind(.ok, libs: true, selected: false), .loadFailed)
        XCTAssertEqual(kind(.ok), .genuinelyEmpty)
    }

    func testCompactLoadFailureOnlyForRetryableFailuresWithoutShelves() {
        XCTAssertTrue(HomeState.showsCompactLoadFailure(kind: .loadFailed, hasServerShelves: false))
        XCTAssertTrue(HomeState.showsCompactLoadFailure(kind: .serverUnreachable, hasServerShelves: false))
        XCTAssertFalse(HomeState.showsCompactLoadFailure(kind: .loadFailed, hasServerShelves: true))
        XCTAssertFalse(HomeState.showsCompactLoadFailure(kind: .offline, hasServerShelves: false))
        XCTAssertFalse(HomeState.showsCompactLoadFailure(kind: .noLibraries, hasServerShelves: false))
        XCTAssertFalse(HomeState.showsCompactLoadFailure(kind: .genuinelyEmpty, hasServerShelves: false))
    }

    func testPlayControlLabelsAndGlyphs() {
        XCTAssertEqual(HomeState.playVerb(isCurrent: true, isPlaying: true), "Pause")
        XCTAssertEqual(HomeState.playVerb(isCurrent: true, isPlaying: false), "Resume")
        XCTAssertEqual(HomeState.playVerb(isCurrent: false, isPlaying: true), "Play")
        XCTAssertEqual(HomeState.playGlyph(isCurrent: true, isPlaying: true), "pause.fill")
        XCTAssertEqual(HomeState.playGlyph(isCurrent: true, isPlaying: false), "play.fill")
        XCTAssertEqual(HomeState.playGlyph(isCurrent: false, isPlaying: true), "play.fill")
        XCTAssertEqual(HomeState.playButtonLabel(title: "Dune", isCurrent: false, isPlaying: true, anotherLoaded: true), "Play Dune instead")
        XCTAssertEqual(HomeState.playButtonLabel(title: "Dune", isCurrent: false, isPlaying: false, anotherLoaded: false), "Play Dune")
        XCTAssertEqual(HomeState.playButtonLabel(title: "Dune", isCurrent: true, isPlaying: false, anotherLoaded: true), "Resume Dune")
        XCTAssertEqual(HomeState.playButtonLabel(title: "Dune", isCurrent: true, isPlaying: true, anotherLoaded: true), "Pause Dune")
    }

    func testBrowseHeaderOnlyBeforeHeaderlessShelf() {
        XCTAssertTrue(HomeState.browseNeedsOwnHeader(firstKey: HomeView.bSideKey))
        XCTAssertFalse(HomeState.browseNeedsOwnHeader(firstKey: "LabelRecentlyAdded"))
        XCTAssertFalse(HomeState.browseNeedsOwnHeader(firstKey: HomeView.downloadedShelfKey))
    }

    func testHeroAccessibilityLabelIsComposite() {
        XCTAssertEqual(
            HomeState.heroAccessibilityLabel(title: "Dune", author: "Frank Herbert", progress: 0.13,
                                             remainingSeconds: 3600 * 12 + 60 * 30, playback: .paused),
            "Dune, Frank Herbert, 13 percent through, 12 hours 30 minutes left, paused")
        XCTAssertEqual(
            HomeState.heroAccessibilityLabel(title: "Dune", author: "Frank Herbert", progress: 0,
                                             remainingSeconds: nil, playback: .none),
            "Dune, Frank Herbert, not started")
        XCTAssertTrue(HomeState.heroAccessibilityLabel(title: "A", author: "B", progress: 0.5,
                                                       remainingSeconds: 60, playback: .playing).hasSuffix("1 minute left, now playing"))
    }
}
