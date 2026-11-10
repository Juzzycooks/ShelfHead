import XCTest
@testable import ShelfHead

/// Pins the player copy decisions from the critique's clarify pass (2026-10-05): the
/// drag-handle status word, the "finishes …" clause, and playback-start error messages.
final class PlayerClarityTests: XCTestCase {

    // MARK: - Header status

    func testHeaderSaysNowPlayingOrPaused() {
        XCTAssertEqual(PlayerView.headerStatus(isPlaying: true, isWaiting: false, stalled: false, isStreaming: true), .nowPlaying)
        XCTAssertEqual(PlayerView.headerStatus(isPlaying: false, isWaiting: false, stalled: false, isStreaming: true), .paused)
        XCTAssertFalse(PlayerView.HeaderStatus.paused.isLive)
    }

    func testOnlyAStalledStreamBlamesTheServer() {
        XCTAssertEqual(PlayerView.headerStatus(isPlaying: false, isWaiting: true, stalled: false, isStreaming: true), .loading)
        XCTAssertEqual(PlayerView.headerStatus(isPlaying: false, isWaiting: true, stalled: true, isStreaming: true), .waitingForServer)
        XCTAssertEqual(PlayerView.headerStatus(isPlaying: false, isWaiting: true, stalled: true, isStreaming: false), .loading)
    }

    // MARK: - Finish clock

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testSameDayFinishShowsJustTheTime() throws {
        let phrase = try XCTUnwrap(PlayerView.finishClockPhrase(finish: date(5, 21, 40), now: date(5, 20), sleepTimer: .off, calendar: calendar))
        XCTAssertFalse(phrase.hasPrefix("tomorrow"))
    }

    func testFinishAfterMidnightSaysTomorrow() throws {
        let phrase = try XCTUnwrap(PlayerView.finishClockPhrase(finish: date(6, 1, 10), now: date(5, 22), sleepTimer: .off, calendar: calendar))
        XCTAssertTrue(phrase.hasPrefix("tomorrow "), phrase)
    }

    func testFinishMoreThanTwelveHoursAwayIsLeftOff() {
        // The critique's case: 15h 46m left at 2:25 pm read "finishes 6:11 am".
        XCTAssertNil(PlayerView.finishClockPhrase(finish: date(6, 6, 11), now: date(5, 14, 25), sleepTimer: .off, calendar: calendar))
    }

    func testASleepTimerThatStopsFirstHidesTheFinish() {
        XCTAssertNil(PlayerView.finishClockPhrase(finish: date(5, 21), now: date(5, 20), sleepTimer: .minutes(30), calendar: calendar))
        XCTAssertNil(PlayerView.finishClockPhrase(finish: date(5, 21), now: date(5, 20), sleepTimer: .endOfChapter, calendar: calendar))
        XCTAssertNotNil(PlayerView.finishClockPhrase(finish: date(5, 21), now: date(5, 20), sleepTimer: .endOfBook, calendar: calendar))
    }

    // MARK: - Error copy

    func testErrorsNeverShowRawCodes() {
        let errors: [Error] = [APIError.serverError(502), APIError.httpError(418), APIError.invalidResponse,
                               APIError.decodingError(URLError(.cannotDecodeContentData)), URLError(.badServerResponse)]
        for error in errors {
            let message = PlayerViewModel.playbackStartFailureMessage(for: error, isEpisode: false)
            XCTAssertFalse(message.contains("502") || message.contains("418") || message.contains("HTTP") || message.contains("parse"), message)
            XCTAssertTrue(message.hasSuffix("."), message)
        }
    }

    func testUnreachableServerSaysSo() {
        let message = PlayerViewModel.playbackStartFailureMessage(for: URLError(.timedOut), isEpisode: false)
        XCTAssertTrue(message.contains("reach your server"), message)
    }

    func testEpisodeWordingNamesTheEpisode() {
        let message = PlayerViewModel.playbackStartFailureMessage(for: APIError.notFound, isEpisode: true)
        XCTAssertTrue(message.contains("this episode"), message)
    }

    func testSignInFailurePointsToSettings() {
        let message = PlayerViewModel.playbackStartFailureMessage(for: APIError.unauthorized, isEpisode: false)
        XCTAssertTrue(message.contains("Settings"), message)
    }
}

/// Second-critique pass (2026-10-05): one time scheme, chapter titles, Driving Mode status.
final class PlayerTimeSchemeTests: XCTestCase {
    private func chapters(_ triples: [(Int, Double, Double)]) throws -> [Chapter] {
        let objects = triples.map { #"{"id": \#($0.0), "start": \#($0.1), "end": \#($0.2), "title": "\#(String(format: "%03d", $0.0 + 1))"}"# }
        return try JSONDecoder().decode([Chapter].self, from: Data("[\(objects.joined(separator: ","))]".utf8))
    }

    func testJumpBackWithinTheChapterUsesChapterTime() throws {
        let list = try chapters([(0, 0, 600), (1, 600, 1800)])
        XCTAssertEqual(PlayerView.jumpBackLabel(undoTime: 690, chapters: list, currentChapterId: 1), "Jump back to \(90.0.formattedTime)")
    }

    func testJumpBackToAnotherChapterNamesIt() throws {
        let list = try chapters([(0, 0, 600), (1, 600, 1800)])
        // Named by the chapter's own (displayed) title, not its array position.
        XCTAssertEqual(PlayerView.jumpBackLabel(undoTime: 86, chapters: list, currentChapterId: 1), "Jump back to Chapter 1 · \(86.0.formattedTime)")
        XCTAssertEqual(PlayerView.jumpBackLabel(undoTime: 86, chapters: list, currentChapterId: 1, verb: "Return to"), "Return to Chapter 1 · \(86.0.formattedTime)")
    }

    func testJumpBackWithoutChaptersUsesBookTime() {
        XCTAssertEqual(PlayerView.jumpBackLabel(undoTime: 4000, chapters: [], currentChapterId: nil), "Jump back to \(4000.0.formattedTime)")
    }

    func testNumericChapterTitlesReadAsChapters() {
        XCTAssertEqual(PlayerView.displayChapterTitle("002"), "Chapter 2")
        XCTAssertEqual(PlayerView.displayChapterTitle(" 12 "), "Chapter 12")
        XCTAssertEqual(PlayerView.displayChapterTitle("Chapter 3: The Ring"), "Chapter 3: The Ring")
        XCTAssertEqual(PlayerView.displayChapterTitle("1984"), "Chapter 1984") // a known, accepted edge
    }

    func testDrivingStatusOnlySpeaksUpWhenThereIsNews() {
        XCTAssertNil(PlayerView.drivingStatusLine(reachability: .ok, header: .nowPlaying, isStreaming: true))
        XCTAssertNil(PlayerView.drivingStatusLine(reachability: .ok, header: .paused, isStreaming: true))
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .ok, header: .waitingForServer, isStreaming: true), "Waiting for your server")
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .serverUnreachable, header: .nowPlaying, isStreaming: false),
                       "Can't reach your server \u{00B7} using your download")
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .offline, header: .nowPlaying, isStreaming: true), "You're offline")
    }

    func testHeaderSpokenTextIsSentenceCase() {
        XCTAssertEqual(PlayerView.HeaderStatus.waitingForServer.spokenText, "Waiting for your server")
        XCTAssertEqual(PlayerView.HeaderStatus.paused.spokenText, "Paused")
    }
}

/// Third-critique pass (2026-10-05): Jump back expiry and Driving Mode status precedence.
final class JumpBackOfferTests: XCTestCase {
    func testOfferStaysWhileListeningNearTheJump() {
        XCTAssertTrue(PlayerViewModel.seekUndoStillOffered(target: 1000, currentTime: 1060, targetChapterId: 3, currentChapterId: 3))
    }

    func testOfferRetiresAfterTwoMinutesOfListening() {
        XCTAssertFalse(PlayerViewModel.seekUndoStillOffered(target: 1000, currentTime: 1121, targetChapterId: 3, currentChapterId: 3))
    }

    func testOfferRetiresWhenTheChapterChangesOnItsOwn() {
        XCTAssertFalse(PlayerViewModel.seekUndoStillOffered(target: 1000, currentTime: 1010, targetChapterId: 3, currentChapterId: 4))
    }

    func testPausingNeverRetiresIt() {
        // Measured in listening, not on a clock: no time-based input at all.
        XCTAssertTrue(PlayerViewModel.seekUndoStillOffered(target: 1000, currentTime: 1000, targetChapterId: nil, currentChapterId: nil))
    }

    func testWordingFollowsDirection() {
        // After ⏮ the undo moves later in the book: "Go forward to".
        XCTAssertTrue(PlayerViewModel.seekUndoGoesForward(undoTime: 900, currentTime: 600))
        XCTAssertFalse(PlayerViewModel.seekUndoGoesForward(undoTime: 600, currentTime: 900))
    }

    func testCorrectingAnOvershootBackwardsKeepsTheOffer() {
        // ⏭ overshot into chapter 4; ⟲15 back into chapter 3 while correcting. Still offered.
        XCTAssertTrue(PlayerViewModel.seekUndoStillOffered(target: 1000, currentTime: 990, targetChapterId: 4, currentChapterId: 3))
    }

    func testCompactJumpLabelIsChapterRelative() throws {
        let json = #"[{"id":0,"start":0,"end":600,"title":"001"},{"id":1,"start":600,"end":1800,"title":"002"}]"#
        let chapters = try JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
        XCTAssertEqual(PlayerView.jumpBackCompactLabel(undoTime: 629, chapters: chapters), 29.0.formattedTime)
    }

    func testDrivingStatusPutsAStartFailureFirstAndDelaysLoading() {
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .ok, header: .loading, isStreaming: true,
                                                    startFailure: "Couldn't reach your server.", showsLoading: false),
                       "Couldn't reach your server.")
        XCTAssertNil(PlayerView.drivingStatusLine(reachability: .ok, header: .loading, isStreaming: true, showsLoading: false))
        XCTAssertEqual(PlayerView.drivingStatusLine(reachability: .ok, header: .loading, isStreaming: true, showsLoading: true), "Loading")
    }
}

/// Fourth-critique pass (2026-10-05): cover floor, cover radius, toolbar label size.
final class CoverFloorTests: XCTestCase {
    func testCaptionsHideBelow72AndReturnOnlyAt120() {
        XCTAssertFalse(PlayerView.progressCaptionsHidden(currentlyHidden: false, artworkSize: 80))
        XCTAssertTrue(PlayerView.progressCaptionsHidden(currentlyHidden: false, artworkSize: 60))
        // Freeing the captions grows the cover to ~96 pt: must stay hidden (no oscillation).
        XCTAssertTrue(PlayerView.progressCaptionsHidden(currentlyHidden: true, artworkSize: 96))
        XCTAssertFalse(PlayerView.progressCaptionsHidden(currentlyHidden: true, artworkSize: 130))
    }

    func testSmallCoversUseTheCoverRadiusScale() {
        XCTAssertEqual(PlayerView.playerCoverRadius(200), Radius.panel)
        XCTAssertEqual(PlayerView.playerCoverRadius(54), Radius.cover(side: 54))
        XCTAssertLessThan(PlayerView.playerCoverRadius(40), Radius.panel)
    }

    func testToolbarLabelsShareOneSizeThatFitsTheRow() {
        XCTAssertEqual(PlayerView.toolbarLabelPointSize(scaled: 11, rowWidth: 0), 11)        // unmeasured
        XCTAssertEqual(PlayerView.toolbarLabelPointSize(scaled: 20, rowWidth: 400), 12)      // ceiling
        let se = PlayerView.toolbarLabelPointSize(scaled: 12, rowWidth: 327)                 // SE row
        XCTAssertLessThan(se * 5.4, 327 / 5 - 7.9)
    }
}
