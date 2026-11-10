// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and every sibling file in
// this target.
//
// Critique 2026-10-06 (harden, then shape → onboard): pins the pure decisions behind the
// Watch's run journey (`WatchRunJourney.swift`) — which server reading a download resumes
// from, which side wins, the conflict baseline, the hero's label, the setup prompt, the
// audio-route decision after activation, the transport width per case size, the
// accessibility header, the bookmark outcome copy, Jump back, and the empty-state and
// detail copy. The stateful halves (AVAudioSession, the pager, the network) aren't
// driven here.
import XCTest
@testable import ShelfHead_Watch

final class WatchServerProgressTests: XCTestCase {

    private func reading(_ time: Double, _ ms: Double?) -> WatchServerProgress {
        WatchServerProgress(currentTime: time, lastUpdateMs: ms)
    }

    func testNewestKnownClockWins() {
        let picked = WatchServerProgressPicker.newest([reading(100, 1_000), reading(500, 9_000), reading(300, 5_000)])
        XCTAssertEqual(picked, reading(500, 9_000))
    }

    func testKnownClockBeatsUnknown() {
        XCTAssertEqual(WatchServerProgressPicker.newest([reading(900, nil), reading(100, 1)]), reading(100, 1))
    }

    func testTieGoesToTheFirstListedSource() {
        // Callers list the fresh fetch first, then the iPhone, then the manifest.
        XCTAssertEqual(WatchServerProgressPicker.newest([reading(10, 5), reading(20, 5)]), reading(10, 5))
        XCTAssertEqual(WatchServerProgressPicker.newest([reading(10, nil), reading(20, nil)]), reading(10, nil))
    }

    func testNilAndUnusableReadingsAreIgnored() {
        XCTAssertNil(WatchServerProgressPicker.newest([nil, nil]))
        XCTAssertNil(WatchServerProgressPicker.newest([reading(.nan, 5), reading(-1, 9)]))
        XCTAssertEqual(WatchServerProgressPicker.newest([nil, reading(.nan, 99), reading(42, 1)]), reading(42, 1))
    }

    // MARK: - The reported bug

    /// The critique's case: the iPhone took the book to 40%, the Watch last played it at
    /// 10 minutes a week earlier. The download must resume at the iPhone's position.
    func testDownloadResumesWhereTheIPhoneLeftOff() {
        let duration: Double = 36_000
        let manifest = reading(14_400, 2_000_000)          // 40%, recorded at download time
        let watchLocal = (time: 600.0, ms: 1_000_000.0)    // older, on the Watch
        let server = WatchServerProgressPicker.newest([nil, nil, manifest])
        let position = StandaloneAudioEngine.resumePosition(
            serverTime: server?.currentTime, serverLastUpdateMs: server?.lastUpdateMs,
            localTime: watchLocal.time, localLastUpdateMs: watchLocal.ms, duration: duration)
        XCTAssertEqual(position, 14_400)
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: server?.currentTime, serverLastUpdateMs: server?.lastUpdateMs,
                                                localTime: watchLocal.time, localLastUpdateMs: watchLocal.ms), .server)
    }

    func testAFresherWatchPositionStillWins() {
        // A run yesterday on the Watch, nothing on the iPhone since: the Watch is newer.
        let server = reading(14_400, 2_000_000)
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: server.currentTime, serverLastUpdateMs: server.lastUpdateMs,
                                                localTime: 16_200, localLastUpdateMs: 3_000_000), .local)
    }

    func testWinnerMatchesResumePositionRules() {
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: nil, serverLastUpdateMs: nil, localTime: nil, localLastUpdateMs: nil), .none)
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: 5, serverLastUpdateMs: nil, localTime: nil, localLastUpdateMs: nil), .server)
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: nil, serverLastUpdateMs: nil, localTime: 5, localLastUpdateMs: nil), .local)
        // Clocks can't be compared: further ahead wins, as in `resumePosition`.
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: 10, serverLastUpdateMs: nil, localTime: 20, localLastUpdateMs: 1), .local)
        XCTAssertEqual(WatchResumeWinner.decide(serverTime: 30, serverLastUpdateMs: 7, localTime: 20, localLastUpdateMs: 7), .server)
    }

    // MARK: - Companion snapshot

    func testCompanionReadingOnlyForTheSameBookOnTheSameServer() {
        let confirmed = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(WatchServerProgress.fromCompanion(snapshotItemId: "a", requestedItemId: "b", sameServer: true,
                                                       estimatedTime: 50, isPlaying: false, lastConfirmedUpdate: confirmed))
        XCTAssertNil(WatchServerProgress.fromCompanion(snapshotItemId: "a", requestedItemId: "a", sameServer: false,
                                                       estimatedTime: 50, isPlaying: false, lastConfirmedUpdate: confirmed))
        XCTAssertNil(WatchServerProgress.fromCompanion(snapshotItemId: "", requestedItemId: "", sameServer: true,
                                                       estimatedTime: 50, isPlaying: false, lastConfirmedUpdate: confirmed))
        XCTAssertNil(WatchServerProgress.fromCompanion(snapshotItemId: "a", requestedItemId: "a", sameServer: true,
                                                       estimatedTime: 0, isPlaying: false, lastConfirmedUpdate: confirmed))
    }

    func testCompanionReadingIsTimestampedByPlayState() {
        let confirmed = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        let paused = WatchServerProgress.fromCompanion(snapshotItemId: "a", requestedItemId: "a", sameServer: true,
                                                       estimatedTime: 50, isPlaying: false,
                                                       lastConfirmedUpdate: confirmed, now: now)
        XCTAssertEqual(paused, WatchServerProgress(currentTime: 50, lastUpdateMs: 1_000_000))
        let playing = WatchServerProgress.fromCompanion(snapshotItemId: "a", requestedItemId: "a", sameServer: true,
                                                        estimatedTime: 50, isPlaying: true,
                                                        lastConfirmedUpdate: confirmed, now: now)
        XCTAssertEqual(playing?.lastUpdateMs, 2_000_000)
    }

    // MARK: - Hero resume point

    func testHeroResumePointUsesTheNewerSide() {
        let point = WatchResumePoint.resolve(server: WatchServerProgress(currentTime: 14_400, lastUpdateMs: 2_000),
                                             localTime: 600, localUpdatedAtMs: 1_000, duration: 36_000)
        XCTAssertEqual(point.position, 14_400)
        XCTAssertEqual(point.updatedAtMs, 2_000)
    }

    func testHeroResumePointWithNothingKnown() {
        let point = WatchResumePoint.resolve(server: nil, localTime: nil, localUpdatedAtMs: nil, duration: 100)
        XCTAssertNil(point.position)
        XCTAssertNil(point.updatedAtMs)
    }

    func testABookStartedOnTheIPhoneIsNoLongerOfferedAsStart() throws {
        let point = WatchResumePoint.resolve(server: WatchServerProgress(currentTime: 14_400, lastUpdateMs: 2_000),
                                             localTime: nil, localUpdatedAtMs: nil, duration: 36_000)
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [
            WatchResumeInput(itemId: "book", title: "Book", author: "A", duration: 36_000,
                             downloadedAt: Date(timeIntervalSince1970: 0),
                             lastPosition: point.position, lastPlayedAt: point.updatedAtMs)
        ]))
        XCTAssertEqual(pick.kind, .resume)
        XCTAssertEqual(pick.progress, 0.4, accuracy: 0.0001)
        XCTAssertEqual(pick.actionLabel, "Resume \u{00B7} 6h left")
    }

    func testStartLabelForAnUnstartedDownload() throws {
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [
            WatchResumeInput(itemId: "new", title: "New", author: "A", duration: 3_600,
                             downloadedAt: Date(timeIntervalSince1970: 0), lastPosition: nil, lastPlayedAt: nil)
        ]))
        XCTAssertEqual(pick.actionLabel, "Start")
    }

    func testResumeLabelWithoutADuration() {
        let candidate = WatchResumeCandidate(itemId: "x", title: "X", author: "A", progress: 0, kind: .resume)
        XCTAssertEqual(candidate.actionLabel, "Resume")
    }

    func testShortDurationText() {
        XCTAssertEqual(WatchShortDuration.text(15_120), "4h 12m")
        XCTAssertEqual(WatchShortDuration.text(7_200), "2h")
        XCTAssertEqual(WatchShortDuration.text(720), "12m")
        XCTAssertEqual(WatchShortDuration.text(20), "1m", "the last partial minute never reads 0m")
        XCTAssertEqual(WatchShortDuration.text(0), "0m")
        XCTAssertEqual(WatchShortDuration.text(.nan), "0m")
    }

    // MARK: - Conflict baseline

    func testServerUnchangedByClock() {
        XCTAssertTrue(WatchProgressBaseline.serverUnchanged(serverTime: 5_000, serverLastUpdateMs: 100,
                                                            baselinePosition: 1_000, baselineTimeMs: 100))
    }

    /// A baseline adopted from the iPhone's snapshot carries the phone's clock, so the
    /// server's own `lastUpdate` for the same position can be a little later.
    func testServerUnchangedByPositionWhenClocksDiffer() {
        XCTAssertTrue(WatchProgressBaseline.serverUnchanged(serverTime: 14_430, serverLastUpdateMs: 2_500,
                                                            baselinePosition: 14_400, baselineTimeMs: 2_000))
    }

    func testRealMoveOnTheServerIsStillAConflictCandidate() {
        XCTAssertFalse(WatchProgressBaseline.serverUnchanged(serverTime: 20_000, serverLastUpdateMs: 9_000,
                                                             baselinePosition: 14_400, baselineTimeMs: 2_000))
        XCTAssertFalse(WatchProgressBaseline.serverUnchanged(serverTime: nil, serverLastUpdateMs: 9_000,
                                                             baselinePosition: 14_400, baselineTimeMs: 2_000))
    }
}

final class WatchRunSetupTests: XCTestCase {

    func testPromptShowsOnlyOnANeverSetUpWatch() {
        XCTAssertTrue(WatchRunSetupPrompt.shouldShow(hasNoSession: true, wasDismissed: false, wasCompleted: false))
        XCTAssertFalse(WatchRunSetupPrompt.shouldShow(hasNoSession: false, wasDismissed: false, wasCompleted: false),
                       "signed in, checking, or expired")
        XCTAssertFalse(WatchRunSetupPrompt.shouldShow(hasNoSession: true, wasDismissed: true, wasCompleted: false),
                       "Not Now is final")
        XCTAssertFalse(WatchRunSetupPrompt.shouldShow(hasNoSession: true, wasDismissed: false, wasCompleted: true),
                       "set up once, never again, even after a sign-out")
    }

    func testHandoffButtonCopy() {
        XCTAssertEqual(WatchAccountCopy.handoffTitle(hasNoSession: true), "Set Up via iPhone")
        XCTAssertEqual(WatchAccountCopy.handoffTitle(hasNoSession: false), "Reconnect via iPhone")
    }

    /// Critique 2026-10-06 (polish): the "iPhone Downloads" row read "1 books".
    func testIPhoneDownloadsRowCount() {
        XCTAssertNil(StandaloneDownloadsView.iPhoneDownloadsCount(0))
        XCTAssertEqual(StandaloneDownloadsView.iPhoneDownloadsCount(1), "1 book")
        XCTAssertEqual(StandaloneDownloadsView.iPhoneDownloadsCount(3), "3 books")
    }
}

final class StandaloneRouteDecisionTests: XCTestCase {

    func testHeadphonesPlay() {
        XCTAssertEqual(StandaloneRouteDecision.afterActivation(activated: true, hasExternalOutput: true, speakerAccepted: false), .play)
    }

    func testSpeakerAsksFirst() {
        XCTAssertEqual(StandaloneRouteDecision.afterActivation(activated: true, hasExternalOutput: false, speakerAccepted: false), .askAboutSpeaker)
    }

    func testAcceptedSpeakerPlays() {
        XCTAssertEqual(StandaloneRouteDecision.afterActivation(activated: true, hasExternalOutput: false, speakerAccepted: true), .play)
    }

    /// Apple: a dismissed route picker calls the completion handler with `false`.
    func testDismissedPickerIsNoRoute() {
        XCTAssertEqual(StandaloneRouteDecision.afterActivation(activated: false, hasExternalOutput: true, speakerAccepted: true), .noRoute)
    }

    func testRouteCopyIsPlainAndActionable() {
        XCTAssertEqual(StandaloneRouteIssue.speakerOnly.actionTitle, "Play on Speaker")
        XCTAssertEqual(StandaloneRouteIssue.noOutputChosen.actionTitle, "Try Again")
        XCTAssertNil(StandaloneRouteIssue.headphonesDisconnected.actionTitle, "Play on the transport is the next step")
        for issue in [StandaloneRouteIssue.speakerOnly, .noOutputChosen, .headphonesDisconnected] {
            XCTAssertFalse(issue.message.contains("—"), "plain sentences")
            XCTAssertTrue(issue.message.hasSuffix("."))
        }
    }
}

final class WatchTransportLayoutTests: XCTestCase {

    /// 40 mm, 41 mm, 44 mm, 45 mm, 49 mm screen widths.
    private let widths: [CGFloat] = [162, 176, 184, 198, 205]

    func testRowFitsEveryCaseSize() {
        for width in widths {
            let layout = WatchTransportLayout.forScreenWidth(width)
            XCTAssertLessThanOrEqual(layout.totalWidth, width - WatchTransportLayout.reservedWidth, "\(width) pt")
        }
    }

    func testTargetsNeverDropBelow44() {
        for width in widths {
            let layout = WatchTransportLayout.forScreenWidth(width)
            XCTAssertEqual(layout.skip, 44, "\(width) pt")
            XCTAssertGreaterThanOrEqual(layout.play, 44, "\(width) pt")
            XCTAssertGreaterThanOrEqual(layout.spacing, WatchTransportLayout.minimumSpacing, "\(width) pt")
        }
    }

    func testFortyMillimetreShrinksGapsThenPlay() {
        let layout = WatchTransportLayout.forScreenWidth(162)
        XCTAssertEqual(layout.spacing, WatchTransportLayout.minimumSpacing)
        XCTAssertLessThan(layout.play, WatchTransportLayout.preferredPlay)
        XCTAssertEqual(layout.play, 50)
    }

    func testFortyOneMillimetreKeepsPlayAndTightensGaps() {
        let layout = WatchTransportLayout.forScreenWidth(176)
        XCTAssertEqual(layout.play, 54)
        XCTAssertEqual(layout.spacing, 9)
    }

    func testLargerCasesUseThePreferredRow() {
        for width: CGFloat in [184, 198, 205] {
            XCTAssertEqual(WatchTransportLayout.forScreenWidth(width),
                           WatchTransportLayout(skip: 44, play: 54, spacing: 12), "\(width) pt")
        }
    }

    func testAccessibilitySizesDropCoverAndSecondLine() {
        XCTAssertEqual(WatchNowPlayingHeaderLayout.forAccessibilitySize(true),
                       WatchNowPlayingHeaderLayout(showsCover: false, titleLineLimit: 1))
        XCTAssertEqual(WatchNowPlayingHeaderLayout.forAccessibilitySize(false),
                       WatchNowPlayingHeaderLayout(showsCover: true, titleLineLimit: 2))
    }
}

final class WatchFeedbackCopyTests: XCTestCase {

    func testBookmarkOutcomesSayWhatHappened() {
        XCTAssertEqual(WatchBookmarkOutcome.saved.title, "Saved")
        XCTAssertEqual(WatchBookmarkOutcome.savedOffline.title, "Will Sync")
        XCTAssertEqual(WatchBookmarkOutcome.failed.title, "Not Saved")
        XCTAssertGreaterThan(WatchBookmarkOutcome.failed.displaySeconds, WatchBookmarkOutcome.saved.displaySeconds,
                             "a failure stays long enough to read")
    }

    func testJumpBackNeedsARealJump() {
        XCTAssertNil(WatchJumpBack.make(itemId: "a", from: 100, to: 101), "under the minimum distance")
        XCTAssertNil(WatchJumpBack.make(itemId: nil, from: 100, to: 900))
        XCTAssertNil(WatchJumpBack.make(itemId: "", from: 100, to: 900))
        XCTAssertNil(WatchJumpBack.make(itemId: "a", from: .nan, to: 900))
        let jump = WatchJumpBack.make(itemId: "a", from: 3_723, to: 100)
        XCTAssertEqual(jump?.restoreTime, 3_723)
        XCTAssertEqual(jump?.label, "Jump back to 1:02:03")
    }

    func testJumpBackOnlyAppliesToTheSameBook() throws {
        let jump = try XCTUnwrap(WatchJumpBack.make(itemId: "a", from: 10, to: 900))
        XCTAssertTrue(jump.canApply(currentItemId: "a"))
        XCTAssertFalse(jump.canApply(currentItemId: "b"))
        XCTAssertFalse(jump.canApply(currentItemId: nil))
        XCTAssertEqual(WatchJumpBack.visibleSeconds, 8)
    }

    func testChaptersEmptyStateTellsTheCasesApart() {
        XCTAssertEqual(WatchChaptersEmptyState.message(hasActiveItem: false, isStale: true), "Nothing playing on iPhone")
        XCTAssertEqual(WatchChaptersEmptyState.message(hasActiveItem: true, isStale: true),
                       "Open ShelfHead on iPhone to sync chapters")
        XCTAssertEqual(WatchChaptersEmptyState.message(hasActiveItem: true, isStale: false), "This book has no chapters")
    }

    func testBookProgressText() {
        XCTAssertEqual(WatchBookProgressText.text(currentTime: nil, duration: 3_600, progress: nil, isFinished: false), "Not started")
        XCTAssertEqual(WatchBookProgressText.text(currentTime: 1_800, duration: 3_600, progress: 0.5, isFinished: false), "30m left")
        XCTAssertEqual(WatchBookProgressText.text(currentTime: nil, duration: 36_000, progress: 0.4, isFinished: false), "6h left")
        XCTAssertEqual(WatchBookProgressText.text(currentTime: nil, duration: nil, progress: 0.25, isFinished: false), "25% listened")
        XCTAssertEqual(WatchBookProgressText.text(currentTime: 10, duration: 3_600, progress: 0.1, isFinished: true), "Finished")
    }

    func testPlayTargetFollowsTheMode() {
        XCTAssertEqual(WatchBookPlayTarget.forStandaloneMode(false), .iPhone)
        XCTAssertEqual(WatchBookPlayTarget.forStandaloneMode(true), .watch)
        XCTAssertEqual(WatchBookPlayTarget.iPhone.buttonTitle, "Play on iPhone")
        XCTAssertEqual(WatchBookPlayTarget.watch.buttonTitle, "Play on Watch")
    }
}
