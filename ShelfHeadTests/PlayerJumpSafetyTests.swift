import XCTest
@testable import ShelfHead

/// Pins the pure decisions behind the player's "never lose your place" hardening
/// (critique 2026-10-05): where ⏮/⏭ land, when a jump offers "Jump back", how the
/// transport row's tiers are toned, and that the Sleep profile arms a timer.
///
/// Same precedent as `PlayerAccessibilityLayoutTests`: the decision functions are tested
/// directly; the on-screen chip and the hit targets need a device pass.
final class PlayerJumpSafetyTests: XCTestCase {

    /// `Chapter` has no memberwise init (only `Decodable`); same JSON-fixture approach as
    /// `NowPlayingSessionRulesTests`.
    private func chapters(_ triples: [(Int, Double, Double)]) throws -> [Chapter] {
        let objects = triples.map { #"{"id": \#($0.0), "start": \#($0.1), "end": \#($0.2), "title": "Chapter \#($0.0)"}"# }
        let json = "[\(objects.joined(separator: ","))]"
        return try JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
    }

    private func threeChapters() throws -> [Chapter] {
        try chapters([(0, 0, 600), (1, 600, 1800), (2, 1800, 3000)])
    }

    // MARK: - Next chapter

    func testNextChapterGoesToTheFollowingChapterStart() throws {
        XCTAssertEqual(AudioPlayerService.nextChapterTarget(chapters: try threeChapters(), currentTime: 700, duration: 3000), 1800)
    }

    func testNextChapterJustBeforeABoundaryStillSkipsPastIt() throws {
        // Within 0.5s of the next start counts as "already there", so it goes one further.
        XCTAssertEqual(AudioPlayerService.nextChapterTarget(chapters: try threeChapters(), currentTime: 1799.8, duration: 3000), 3000)
    }

    func testNextChapterInTheLastChapterRunsToTheEndOfTheBook() throws {
        XCTAssertEqual(AudioPlayerService.nextChapterTarget(chapters: try threeChapters(), currentTime: 2000, duration: 3200), 3200)
    }

    func testNextChapterWithUnknownDurationUsesTheLastChapterEnd() throws {
        // Fix 6.C: never seek(to: 0) because duration is 0.
        XCTAssertEqual(AudioPlayerService.nextChapterTarget(chapters: try threeChapters(), currentTime: 2000, duration: 0), 3000)
    }

    func testNextChapterAtTheVeryEndHasNowhereToGo() throws {
        XCTAssertNil(AudioPlayerService.nextChapterTarget(chapters: try threeChapters(), currentTime: 3000, duration: 3000))
    }

    func testNextChapterWithNoChaptersIsNil() {
        XCTAssertNil(AudioPlayerService.nextChapterTarget(chapters: [], currentTime: 10, duration: 3000))
    }

    // MARK: - Previous chapter

    func testPreviousChapterMoreThanThreeSecondsInRestartsTheChapter() throws {
        XCTAssertEqual(AudioPlayerService.previousChapterTarget(chapters: try threeChapters(), currentTime: 1500), 600)
    }

    func testPreviousChapterNearTheStartGoesToThePreviousChapter() throws {
        XCTAssertEqual(AudioPlayerService.previousChapterTarget(chapters: try threeChapters(), currentTime: 602), 0)
    }

    func testPreviousChapterInTheFirstChapterGoesToZero() throws {
        XCTAssertEqual(AudioPlayerService.previousChapterTarget(chapters: try threeChapters(), currentTime: 2), 0)
    }

    // MARK: - Jump back threshold

    func testChapterRestartOffersJumpBack() throws {
        // The critique's headline case: ⏮ 15 minutes into a chapter is a big jump and must
        // be undoable.
        let target = AudioPlayerService.previousChapterTarget(chapters: try threeChapters(), currentTime: 1500)
        XCTAssertTrue(PlayerViewModel.offersSeekUndo(from: 1500, to: target))
    }

    func testSmallSeeksDoNotOfferJumpBack() {
        XCTAssertFalse(PlayerViewModel.offersSeekUndo(from: 100, to: 110))
        XCTAssertFalse(PlayerViewModel.offersSeekUndo(from: 100, to: 85.5))
    }

    func testFifteenSecondsInEitherDirectionOffersJumpBack() {
        XCTAssertTrue(PlayerViewModel.offersSeekUndo(from: 100, to: 115))
        XCTAssertTrue(PlayerViewModel.offersSeekUndo(from: 100, to: 85))
    }

    // MARK: - Transport tiers

    func testChapterButtonsAreAQuieterTierThanSkips() {
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .skip, enabled: true), 0.7, accuracy: 0.0001)
        XCTAssertEqual(PlayerView.transportGlyphOpacity(role: .chapter, enabled: true), 0.55, accuracy: 0.0001)
        XCTAssertLessThan(PlayerView.transportGlyphOpacity(role: .chapter, enabled: true),
                          PlayerView.transportGlyphOpacity(role: .skip, enabled: true))
        XCTAssertLessThan(PlayerView.transportGlyphOpacity(role: .chapter, enabled: false),
                          PlayerView.transportGlyphOpacity(role: .chapter, enabled: true))
    }

    // MARK: - Sleep profile

    func testOnlyTheSleepProfileArmsATimer() {
        for profile in ListeningProfile.allCases {
            XCTAssertEqual(profile.overrides.armsSleepTimer == true, profile == .sleep, "\(profile)")
        }
    }
}
