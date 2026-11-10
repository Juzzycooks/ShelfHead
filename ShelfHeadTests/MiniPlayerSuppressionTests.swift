import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (distill): pins the decision that hides the mini player while Book
/// Detail's pinned Play bar is showing (`MiniPlayerSuppression`).
final class MiniPlayerSuppressionTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    // MARK: registrations

    func testEmptyNeverSuppresses() {
        let s = MiniPlayerSuppression()
        for tab in 0...3 { XCTAssertFalse(s.isSuppressed(selectedTab: tab)) }
    }

    func testRegistrationSuppressesOnlyItsOwnTab() {
        var s = MiniPlayerSuppression()
        s.register(a, tab: 1)
        XCTAssertTrue(s.isSuppressed(selectedTab: 1))
        XCTAssertFalse(s.isSuppressed(selectedTab: 0), "another tab keeps its mini player")
    }

    func testUnknownTabSuppressesEverywhere() {
        var s = MiniPlayerSuppression()
        s.register(a, tab: nil)
        for tab in 0...3 { XCTAssertTrue(s.isSuppressed(selectedTab: tab)) }
    }

    func testNestedDetailsStaySuppressedUntilTheLastLeaves() {
        // Series → book A → book B → book C, then pop back out.
        var s = MiniPlayerSuppression()
        let ta = s.register(a, tab: 1)
        let tb = s.register(b, tab: 1)
        let tc = s.register(c, tab: 1)
        s.release(c, token: tc)
        XCTAssertTrue(s.isSuppressed(selectedTab: 1))
        s.release(b, token: tb)
        XCTAssertTrue(s.isSuppressed(selectedTab: 1))
        s.release(a, token: ta)
        XCTAssertFalse(s.isSuppressed(selectedTab: 1))
    }

    func testDisappearBeforeAppearOrderingStillEndsSuppressed() {
        // Push A → B where A's release lands before B registers, then B registers.
        var s = MiniPlayerSuppression()
        let ta = s.register(a, tab: 0)
        s.release(a, token: ta)
        s.register(b, tab: 0)
        XCTAssertTrue(s.isSuppressed(selectedTab: 0))
    }

    func testAppearBeforeDisappearOrderingStaysSuppressed() {
        // Pop B → A where A re-registers before B's release lands.
        var s = MiniPlayerSuppression()
        s.register(a, tab: 0)
        let tb = s.register(b, tab: 0)
        s.register(a, tab: 0)
        s.release(b, token: tb)
        XCTAssertTrue(s.isSuppressed(selectedTab: 0))
    }

    func testStaleReleaseDoesNotCancelANewerRegistration() {
        // A quick leave-and-return: the deferred release of the first appearance arrives
        // after the second appearance registered.
        var s = MiniPlayerSuppression()
        let first = s.register(a, tab: 2)
        let second = s.register(a, tab: 2)
        s.release(a, token: first)
        XCTAssertTrue(s.isSuppressed(selectedTab: 2))
        s.release(a, token: second)
        XCTAssertFalse(s.isSuppressed(selectedTab: 2))
    }

    func testRepeatedAppearIsIdempotent() {
        var s = MiniPlayerSuppression()
        s.register(a, tab: 0)
        let latest = s.register(a, tab: 0)
        XCTAssertEqual(s.registrations.count, 1)
        s.release(a, token: latest)
        XCTAssertFalse(s.isSuppressed(selectedTab: 0), "one release clears a doubled appear")
    }

    func testReleasingAnUnknownOwnerIsHarmless() {
        var s = MiniPlayerSuppression()
        s.register(a, tab: 0)
        s.release(b, token: UUID())
        XCTAssertTrue(s.isSuppressed(selectedTab: 0))
    }

    // MARK: which details suppress

    func testAudiobookAndPodcastBarsSuppress() {
        XCTAssertTrue(MiniPlayerSuppression.detailSuppresses(isPodcast: false, isEbookOnly: false, inSheet: false))
        XCTAssertTrue(MiniPlayerSuppression.detailSuppresses(isPodcast: true, isEbookOnly: false, inSheet: false))
    }

    func testEbookOnlyBarHasNoPlayControlSoDoesNotSuppress() {
        XCTAssertFalse(MiniPlayerSuppression.detailSuppresses(isPodcast: false, isEbookOnly: true, inSheet: false))
    }

    func testSheetPresentedDetailDoesNotSuppress() {
        XCTAssertFalse(MiniPlayerSuppression.detailSuppresses(isPodcast: false, isEbookOnly: false, inSheet: true))
        XCTAssertFalse(MiniPlayerSuppression.detailSuppresses(isPodcast: true, isEbookOnly: false, inSheet: true))
    }

    // MARK: what the shell draws

    func testShowsMiniPlayer() {
        XCTAssertTrue(MiniPlayerSuppression.showsMiniPlayer(hasMiniPlayer: true, suppressed: false, canHide: true))
        XCTAssertFalse(MiniPlayerSuppression.showsMiniPlayer(hasMiniPlayer: true, suppressed: true, canHide: true))
        XCTAssertFalse(MiniPlayerSuppression.showsMiniPlayer(hasMiniPlayer: false, suppressed: false, canHide: true))
    }

    func testIOS260CannotHideSoMiniPlayerStays() {
        XCTAssertTrue(MiniPlayerSuppression.showsMiniPlayer(hasMiniPlayer: true, suppressed: true, canHide: false))
    }

    // MARK: Play Instead note

    func testPodcastPlaysInsteadNoteSaysEpisode() {
        XCTAssertEqual(BookDetailView.playsInsteadNote(otherTitle: "Dune", noun: "episode"),
                       "Plays this episode instead of Dune.")
        XCTAssertEqual(BookDetailView.playsInsteadNote(otherTitle: "Dune"), "Plays this book instead of Dune.")
    }
}
