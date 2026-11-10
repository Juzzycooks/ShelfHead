import XCTest
@testable import ShelfHead

/// Batch 327: pins every pure decision behind the iOS 27 `NowPlaying` adoption.
///
/// `NowPlayingSessionRules` is deliberately the only unit-testable half of that work —
/// `MediaSession`, `BookContent` and the artwork provider are framework objects whose
/// behaviour can only be observed on a real Lock Screen / Control Center / CarPlay
/// surface, which is this project's established line for what gets a test (same
/// reasoning as `DownloadManager.shouldReclaimOrphanDirectory` vs. the disk-scanning
/// sweep that calls it, and `CarPlayCoordinator.nextPlaybackRate(after:)` vs. the
/// template it drives).
///
/// No `@MainActor` and no availability gate needed: every function under test is
/// `nonisolated` and compiles on any OS, which is the reason the rules were split out of
/// the `@available(iOS 27, *)` types in the first place.
final class NowPlayingSessionRulesTests: XCTestCase {

    /// `Chapter` has no memberwise init (only `Decodable`) — same JSON-fixture approach
    /// `CurrentChapterResolutionTests` and `BookmarkMomentLabelTests` use.
    private func chapters(_ triples: [(Int, Double, Double)]) throws -> [Chapter] {
        let objects = triples.map { #"{"id": \#($0.0), "start": \#($0.1), "end": \#($0.2), "title": "Chapter \#($0.0)"}"# }
        let json = "[\(objects.joined(separator: ","))]"
        return try JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
    }

    // MARK: - `resolveBackend`

    func testBackendResolutionMatrix() {
        // The only combination that yields the new framework: available AND not opted out.
        XCTAssertEqual(
            NowPlayingSessionRules.resolveBackend(sessionAvailable: true, prefersClassic: false),
            .session)
        XCTAssertEqual(
            NowPlayingSessionRules.resolveBackend(sessionAvailable: true, prefersClassic: true),
            .classic)
        // Below iOS 27 the preference is irrelevant — classic is the only path there.
        XCTAssertEqual(
            NowPlayingSessionRules.resolveBackend(sessionAvailable: false, prefersClassic: false),
            .classic)
        XCTAssertEqual(
            NowPlayingSessionRules.resolveBackend(sessionAvailable: false, prefersClassic: true),
            .classic)
    }

    /// Not an assertion about which default is *right* — that's a simulator lock-screen
    /// decision. It pins that the constant is what `SettingsStore` registers, so the two
    /// can't silently disagree about the shipping default.
    func testSettingsStoreDefaultTracksTheOneConstant() {
        SettingsStore.registerDefaults()
        XCTAssertEqual(SettingsStore.classicNowPlaying, NowPlayingSessionRules.defaultPrefersClassic)
    }

    // MARK: - `chapterPosition`

    func testChapterPositionIsNilWithoutChapters() {
        XCTAssertNil(NowPlayingSessionRules.chapterPosition(currentTime: 42, chapters: []))
    }

    func testChapterPositionIsOneBased() throws {
        let list = try chapters([(0, 0, 100), (1, 100, 250), (2, 250, 400)])
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 0, chapters: list)?.current, 1)
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 99.9, chapters: list)?.current, 1)
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 175, chapters: list)?.current, 2)
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 399.9, chapters: list)?.current, 3)
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 175, chapters: list)?.total, 3)
    }

    func testChapterBoundaryBelongsToTheNextChapter() throws {
        // Half-open `start ..< end`, matching `AudioPlayerService.currentChapter` and
        // `PlayerViewModel.chapterIndex(in:at:)` — a position exactly on a boundary must
        // resolve the same way everywhere or the lock screen and the player disagree by
        // one chapter at every transition.
        let list = try chapters([(0, 0, 100), (1, 100, 250)])
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 100, chapters: list)?.current, 2)
    }

    func testChapterPositionBeforeTheFirstChapterClampsToOne() throws {
        // A book whose first chapter doesn't start at 0 (some Audiobookshelf imports
        // put a lead-in before chapter 1).
        let list = try chapters([(0, 30, 100), (1, 100, 250)])
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 0, chapters: list)?.current, 1)
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 29.9, chapters: list)?.current, 1)
    }

    func testChapterPositionPastTheLastChapterClampsToTotal() throws {
        let list = try chapters([(0, 0, 100), (1, 100, 250), (2, 250, 400)])
        // `end` of the last chapter is itself outside every half-open range.
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 400, chapters: list)?.current, 3)
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 9_999, chapters: list)?.current, 3)
    }

    func testChapterPositionInAGapResolvesToThePrecedingChapter() throws {
        // Not a case the framework defines, but reachable from real chapter data. The
        // chapter the listener most recently left is a better answer than either 1 or
        // the last chapter.
        let list = try chapters([(0, 0, 100), (1, 200, 300)])
        XCTAssertEqual(NowPlayingSessionRules.chapterPosition(currentTime: 150, chapters: list)?.current, 1)
    }

    // MARK: - `playbackState`

    func testNoItemIsAlwaysStopped() {
        // `isPlaying` can briefly be true with nothing loaded during teardown — the
        // guard has to win over both other arguments.
        XCTAssertEqual(
            NowPlayingSessionRules.playbackState(hasItem: false, isPlaying: true, rate: 1.5),
            .stopped)
        XCTAssertEqual(
            NowPlayingSessionRules.playbackState(hasItem: false, isPlaying: false, rate: 1.0),
            .stopped)
    }

    func testPlayingCarriesTheRate() {
        XCTAssertEqual(
            NowPlayingSessionRules.playbackState(hasItem: true, isPlaying: true, rate: 1.75),
            .playing(rate: 1.75))
        // A different rate is a different state — the system extrapolates position from
        // it, so `.playing(rate:)` must not collapse to a bare "playing".
        XCTAssertNotEqual(
            NowPlayingSessionRules.playbackState(hasItem: true, isPlaying: true, rate: 1.75),
            .playing(rate: 1.0))
    }

    func testPausedIgnoresTheRate() {
        XCTAssertEqual(
            NowPlayingSessionRules.playbackState(hasItem: true, isPlaying: false, rate: 2.5),
            .paused)
    }

    // MARK: - `supportedRates`

    func testSupportedRatesMatchTheAppsLadder() {
        let rates = NowPlayingSessionRules.supportedRates()
        XCTAssertEqual(rates.first, 0.5)
        XCTAssertEqual(rates.last, 3.0)
        XCTAssertTrue(rates.contains(1.0))
        XCTAssertEqual(rates, rates.sorted(), "The rate picker shows these in order.")
        XCTAssertEqual(Set(rates).count, rates.count, "A duplicated rate would show twice.")
        // 0.5 ... 3.0 in 0.25 steps.
        XCTAssertEqual(rates.count, 11)
        // Exact, not float-drifted — see `supportedRates()`' note on integer quarters.
        XCTAssertEqual(rates, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0])
    }

    func testEverySupportedRateIsInsideTheAppsClampedRange() {
        // `PlayerViewModel.setPlaybackRate` clamps to 0.5–3.0; offering the system a
        // rate the app would then clamp away would make the picker lie.
        for rate in NowPlayingSessionRules.supportedRates() {
            XCTAssertGreaterThanOrEqual(rate, 0.5)
            XCTAssertLessThanOrEqual(rate, 3.0)
        }
    }

    // MARK: - `clampedSeekTarget`

    func testSeekTargetClampsToZeroAndDuration() {
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(-10, duration: 600), 0)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(0, duration: 600), 0)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(300, duration: 600), 300)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(600, duration: 600), 600)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(9_999, duration: 600), 600)
    }

    func testSeekTargetRejectsNonFiniteRequests() {
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(.nan, duration: 600), 0)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(.infinity, duration: 600), 0)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(-.infinity, duration: 600), 0)
    }

    func testUnknownDurationIsTrustedRatherThanUsedToClamp() {
        // Same contract as `AudioPlayerService.clampedSeekTarget(current:delta:duration:)`
        // — an offline-manifest or podcast session can legitimately not know a duration,
        // and clamping against 0 there would throw the listener back to the start (the
        // NEW-9 bug class in `startPlayback`).
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(300, duration: 0), 300)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(300, duration: -1), 300)
        XCTAssertEqual(NowPlayingSessionRules.clampedSeekTarget(300, duration: .nan), 300)
    }

    // MARK: - Batch 328: Lock Screen lines, chapter-relative scrubber, star toggle

    func testSubtitleIsAuthorDashChapterLikeTheClassicAlbumLine() {
        XCTAssertEqual(NowPlayingSessionRules.subtitle(author: "Aesop", chapterTitle: "002 - The Two Crabs"),
                       "Aesop — 002 - The Two Crabs")
        XCTAssertEqual(NowPlayingSessionRules.subtitle(author: "Aesop", chapterTitle: nil), "Aesop")
        XCTAssertEqual(NowPlayingSessionRules.subtitle(author: "Aesop", chapterTitle: "   "), "Aesop")
        XCTAssertEqual(NowPlayingSessionRules.subtitle(author: "", chapterTitle: "Prologue"), "Prologue")
    }

    func testScrubberTimingIsChapterRelativeInsideAChapter() {
        let timing = NowPlayingSessionRules.scrubberTiming(currentTime: 1320, chapterStart: 1299, chapterEnd: 1420, bookDuration: 1590)
        XCTAssertEqual(timing.elapsed, 21, accuracy: 0.001)
        XCTAssertEqual(timing.duration ?? -1, 121, accuracy: 0.001)
    }

    func testScrubberTimingClampsAtChapterEdges() {
        let before = NowPlayingSessionRules.scrubberTiming(currentTime: 1290, chapterStart: 1299, chapterEnd: 1420, bookDuration: 1590)
        XCTAssertEqual(before.elapsed, 0)
        let after = NowPlayingSessionRules.scrubberTiming(currentTime: 1500, chapterStart: 1299, chapterEnd: 1420, bookDuration: 1590)
        XCTAssertEqual(after.elapsed, 121, accuracy: 0.001)
    }

    func testScrubberTimingFallsBackToWholeBookWithoutAChapter() {
        let timing = NowPlayingSessionRules.scrubberTiming(currentTime: 60, chapterStart: nil, chapterEnd: nil, bookDuration: 1590)
        XCTAssertEqual(timing.elapsed, 60)
        XCTAssertEqual(timing.duration, 1590)
        // An inverted or degenerate chapter is treated as no chapter.
        let inverted = NowPlayingSessionRules.scrubberTiming(currentTime: 60, chapterStart: 900, chapterEnd: 300, bookDuration: 1590)
        XCTAssertEqual(inverted.duration, 1590)
        // Unknown book duration stays unknown (nil), never 0.
        XCTAssertNil(NowPlayingSessionRules.scrubberTiming(currentTime: 60, chapterStart: nil, chapterEnd: nil, bookDuration: 0).duration)
    }

    func testAbsoluteSeekTargetAddsTheChapterOffsetBack() {
        XCTAssertEqual(NowPlayingSessionRules.absoluteSeekTarget(21, chapterStart: 1299, bookDuration: 1590), 1320)
        XCTAssertEqual(NowPlayingSessionRules.absoluteSeekTarget(21, chapterStart: nil, bookDuration: 1590), 21)
        // Still clamped to the book, and a garbage request lands at the chapter start.
        XCTAssertEqual(NowPlayingSessionRules.absoluteSeekTarget(9_999, chapterStart: 1299, bookDuration: 1590), 1590)
        XCTAssertEqual(NowPlayingSessionRules.absoluteSeekTarget(.nan, chapterStart: 1299, bookDuration: 1590), 1299)
        XCTAssertEqual(NowPlayingSessionRules.absoluteSeekTarget(-5, chapterStart: nil, bookDuration: 1590), 0)
    }

    func testNearbyBookmarkPicksTheClosestWithinTolerance() {
        XCTAssertEqual(NowPlayingSessionRules.nearbyBookmark(times: [100, 118, 130], currentTime: 120), 118)
        XCTAssertNil(NowPlayingSessionRules.nearbyBookmark(times: [100, 131], currentTime: 120))
        XCTAssertNil(NowPlayingSessionRules.nearbyBookmark(times: [], currentTime: 120))
        XCTAssertNil(NowPlayingSessionRules.nearbyBookmark(times: [120], currentTime: .nan))
    }

    func testStarIsAToggleAndThumbsDownDoesNothing() {
        // First tap: no bookmark here yet → create one.
        XCTAssertEqual(NowPlayingSessionRules.feedbackAction(.positive, nearbyBookmark: nil), .createBookmark)
        // A second "like" while one is already here must not double-bookmark.
        XCTAssertEqual(NowPlayingSessionRules.feedbackAction(.positive, nearbyBookmark: 118), .ignore)
        // Un-liking removes the one the star made.
        XCTAssertEqual(NowPlayingSessionRules.feedbackAction(.neutral, nearbyBookmark: 118), .deleteBookmark(at: 118))
        XCTAssertEqual(NowPlayingSessionRules.feedbackAction(.neutral, nearbyBookmark: nil), .ignore)
        // The daemon pairs the star with a Dislike command; that must never bookmark.
        XCTAssertEqual(NowPlayingSessionRules.feedbackAction(.negative, nearbyBookmark: nil), .ignore)
        XCTAssertEqual(NowPlayingSessionRules.feedbackAction(.negative, nearbyBookmark: 118), .ignore)
    }
}
