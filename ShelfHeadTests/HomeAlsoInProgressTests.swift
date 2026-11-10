import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden + clarify): Home's copy and hero decisions.
@MainActor
final class HomeAlsoInProgressTests: XCTestCase {
    func testOtherInProgressBooksAreNotCalledUpNext() {
        XCTAssertEqual(HomeState.alsoInProgressTitle, "Also in Progress")
        XCTAssertNotEqual(HomeState.alsoInProgressTitle, "Up Next")
    }

    /// Decision: when the hero is the loaded book, the mini player is its transport, so the
    /// hero's button opens the player rather than duplicating play/pause.
    func testHeroButtonOpensPlayerForTheLoadedBook() {
        XCTAssertEqual(HomeState.heroButton(isCurrent: true), .openPlayer)
        XCTAssertEqual(HomeState.heroButton(isCurrent: false), .play)
        XCTAssertEqual(HomeState.HeroButton.openPlayer.title, "Open Player")
        XCTAssertEqual(HomeState.HeroButton.play.title, "Play")
        XCTAssertNotEqual(HomeState.HeroButton.openPlayer.glyph, "pause.fill")
    }

    func testHeroButtonAccessibilityLabels() {
        XCTAssertEqual(HomeState.heroButtonAccessibilityLabel(.openPlayer, title: "Dune", anotherLoaded: true),
                       "Open Player, Dune")
        XCTAssertEqual(HomeState.heroButtonAccessibilityLabel(.play, title: "Dune", anotherLoaded: true),
                       "Play Dune instead")
        XCTAssertEqual(HomeState.heroButtonAccessibilityLabel(.play, title: "Dune", anotherLoaded: false),
                       "Play Dune")
    }

    /// The fix for "no libraries" is on the server, so the copy says so and the primary
    /// action is Check Again, not this app's Settings.
    func testNoLibrariesCopyPointsAtTheServer() {
        XCTAssertEqual(HomeState.noLibrariesAction, "Check Again")
        XCTAssertTrue(HomeState.noLibrariesMessage.contains("server"))
        XCTAssertFalse(HomeState.noLibrariesMessage.localizedCaseInsensitiveContains("settings"))
    }

    func testBSideHintNamesTheBookItReplaces() {
        XCTAssertEqual(HomeBSideCard.accessibilityHint(playsInstead: nil),
                       "Plays a random book you haven't started yet.")
        XCTAssertEqual(HomeBSideCard.accessibilityHint(playsInstead: "Plays instead of Dune"),
                       "Plays a random book you haven't started yet. Plays instead of Dune.")
    }
}
