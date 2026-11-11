import XCTest
import SwiftUI
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11): pins the pure decisions behind the player quick wins —
/// bookmark default titles, the idle-timer owner, the compact-height scrolling column, the
/// mini player's chapter line at speed, the speed sheet's transcribe hint, the queue footer,
/// the chapter list's played/time-left state, and the sleep timer's custom length,
/// "+1 chapter" and "Jump back" offer.
@MainActor
final class QuickWinsPlayerTests: XCTestCase {

    // MARK: V8 — BookmarkDefaultTitle

    func testBookmarkDefaultTitleWithChapter() {
        XCTAssertEqual(BookmarkDefaultTitle.make(chapterTitle: "Chapter 7", time: 3723),
                       "Chapter 7 · \(3723.0.formattedTime)")
    }

    func testBookmarkDefaultTitleWithoutChapterIsTimeAlone() {
        XCTAssertEqual(BookmarkDefaultTitle.make(chapterTitle: nil, time: 352), 352.0.formattedTime)
    }

    func testBookmarkDefaultTitleBlankChapterIsTimeAlone() {
        XCTAssertEqual(BookmarkDefaultTitle.make(chapterTitle: "   ", time: 90), 90.0.formattedTime)
        XCTAssertEqual(BookmarkDefaultTitle.make(chapterTitle: "", time: 90), 90.0.formattedTime)
    }

    func testBookmarkDefaultTitleTrimsChapter() {
        XCTAssertEqual(BookmarkDefaultTitle.make(chapterTitle: " Prologue \n", time: 5),
                       "Prologue · \(5.0.formattedTime)")
    }

    // MARK: P2 — one idle-timer decision

    func testIdleTimerFollowsSettingWhilePlaying() {
        XCTAssertTrue(AudioPlayerService.idleTimerDisabled(playing: true, keepScreenAwakeSetting: true, drivingModeOnScreen: false))
        XCTAssertFalse(AudioPlayerService.idleTimerDisabled(playing: true, keepScreenAwakeSetting: false, drivingModeOnScreen: false))
        XCTAssertFalse(AudioPlayerService.idleTimerDisabled(playing: false, keepScreenAwakeSetting: true, drivingModeOnScreen: false))
    }

    func testDrivingModeKeepsScreenAwakeRegardless() {
        XCTAssertTrue(AudioPlayerService.idleTimerDisabled(playing: false, keepScreenAwakeSetting: false, drivingModeOnScreen: true))
        XCTAssertTrue(AudioPlayerService.idleTimerDisabled(playing: true, keepScreenAwakeSetting: false, drivingModeOnScreen: true))
    }

    // MARK: G1 — compact height scrolls

    func testScrollingColumnAtAccessibilitySizesOrCompactHeight() {
        XCTAssertTrue(PlayerView.usesScrollingColumn(isAccessibilitySize: true, verticalSizeClass: .regular))
        XCTAssertTrue(PlayerView.usesScrollingColumn(isAccessibilitySize: false, verticalSizeClass: .compact))
        XCTAssertFalse(PlayerView.usesScrollingColumn(isAccessibilitySize: false, verticalSizeClass: .regular))
        XCTAssertFalse(PlayerView.usesScrollingColumn(isAccessibilitySize: false, verticalSizeClass: nil))
    }

    // MARK: P6 — mini player chapter line is wall-clock

    func testMiniPlayerChapterLineDividesByRate() {
        let line = MiniPlayerStatus.line(isStalled: false, isStreaming: false, sleepOption: .off,
                                         sleepRemaining: 0, chapterRemaining: 900, author: "A",
                                         playbackRate: 1.5)
        XCTAssertEqual(line.kind, .chapter)
        XCTAssertTrue(line.full.hasPrefix(600.0.formattedTime), line.full)
        XCTAssertTrue(line.short.hasPrefix(600.0.formattedTime), line.short)
    }

    func testMiniPlayerChapterLineAtOneTimesIsUnchanged() {
        let line = MiniPlayerStatus.line(isStalled: false, isStreaming: false, sleepOption: .off,
                                         sleepRemaining: 0, chapterRemaining: 764, author: "A")
        XCTAssertTrue(line.full.hasPrefix(764.0.formattedTime), line.full)
    }

    // MARK: P7 — speed sheet's transcribe hint

    func testTranscribeHintOnlyWhenTranscriptionIsPossible() {
        XCTAssertTrue(SpeedSheet.showsTranscribeHint(hasNarratorPace: false, canTranscribe: true,
                                                     transcriptsEnabled: true, isPodcast: false, isDownloaded: true))
        XCTAssertFalse(SpeedSheet.showsTranscribeHint(hasNarratorPace: true, canTranscribe: true,
                                                      transcriptsEnabled: true, isPodcast: false, isDownloaded: true))
        XCTAssertFalse(SpeedSheet.showsTranscribeHint(hasNarratorPace: false, canTranscribe: false,
                                                      transcriptsEnabled: true, isPodcast: false, isDownloaded: true))
        XCTAssertFalse(SpeedSheet.showsTranscribeHint(hasNarratorPace: false, canTranscribe: true,
                                                      transcriptsEnabled: false, isPodcast: false, isDownloaded: true))
        XCTAssertFalse(SpeedSheet.showsTranscribeHint(hasNarratorPace: false, canTranscribe: true,
                                                      transcriptsEnabled: true, isPodcast: true, isDownloaded: true))
        XCTAssertFalse(SpeedSheet.showsTranscribeHint(hasNarratorPace: false, canTranscribe: true,
                                                      transcriptsEnabled: true, isPodcast: false, isDownloaded: false))
    }

    // MARK: P9 — queue footer

    func testQueueFooterFollowsAutoplay() {
        XCTAssertEqual(QueueSheet.footerText(autoplayNext: true), "Plays when this book ends")
        XCTAssertEqual(QueueSheet.footerText(autoplayNext: false), "Autoplay is off. Tap a book to start it.")
    }

    // MARK: F23 — chapter list

    func testChapterPlayedBeforeCurrentChapter() {
        XCTAssertTrue(ChapterListSheet.isPlayed(chapterEnd: 600, currentChapterStart: 600))
        XCTAssertTrue(ChapterListSheet.isPlayed(chapterEnd: 300, currentChapterStart: 600))
        XCTAssertFalse(ChapterListSheet.isPlayed(chapterEnd: 900, currentChapterStart: 600))
        XCTAssertFalse(ChapterListSheet.isPlayed(chapterEnd: 300, currentChapterStart: nil))
    }

    func testChapterTimeLeftIsWallClock() {
        XCTAssertTrue(ChapterListSheet.timeLeftText(chapterEnd: 1000, currentTime: 100, rate: 1.5)
            .hasPrefix(600.0.formattedTime))
        XCTAssertTrue(ChapterListSheet.timeLeftText(chapterEnd: 1000, currentTime: 1200, rate: 1)
            .hasPrefix(0.0.formattedTime))
    }

    // MARK: F20 — sleep timer

    func testCustomMinutesClamp() {
        XCTAssertEqual(SleepTimerOption.clampedCustomMinutes(0), 1)
        XCTAssertEqual(SleepTimerOption.clampedCustomMinutes(20), 20)
        XCTAssertEqual(SleepTimerOption.clampedCustomMinutes(500), 180)
    }

    func testAddChapterOption() {
        XCTAssertEqual(AudioPlayerService.optionAfterAddingChapter(.endOfChapter), .chapters(1))
        XCTAssertEqual(AudioPlayerService.optionAfterAddingChapter(.chapters(2)), .chapters(3))
        XCTAssertNil(AudioPlayerService.optionAfterAddingChapter(.minutes(15)))
        XCTAssertNil(AudioPlayerService.optionAfterAddingChapter(.endOfBook))
        XCTAssertNil(AudioPlayerService.optionAfterAddingChapter(.off))
    }

    func testNextChapterSleepTargetCountsFromCurrentTarget() {
        let chapters = [Chapter(id: 0, start: 0, end: 600, title: "One"),
                        Chapter(id: 1, start: 600, end: 1200, title: "Two"),
                        Chapter(id: 2, start: 1200, end: 1800, title: "Three")]
        XCTAssertEqual(AudioPlayerService.nextChapterSleepTarget(chapters: chapters, currentTarget: 600), 1200)
        XCTAssertEqual(AudioPlayerService.nextChapterSleepTarget(chapters: chapters, currentTarget: 1200), 1800)
        XCTAssertNil(AudioPlayerService.nextChapterSleepTarget(chapters: chapters, currentTarget: 1800))
        XCTAssertNil(AudioPlayerService.nextChapterSleepTarget(chapters: [], currentTarget: 0))
    }

    func testSleepJumpBackOfferedOnlyWellPastTheArmedPositionInTheSameBook() {
        XCTAssertEqual(AudioPlayerService.sleepJumpBackTarget(armedAt: 1000, armedItemId: "a",
                                                              resumeAt: 1000 + 1800, currentItemId: "a"), 1000)
        XCTAssertEqual(AudioPlayerService.sleepJumpBackTarget(armedAt: 1000, armedItemId: "a",
                                                              resumeAt: 1000 + AudioPlayerService.sleepJumpBackMinimum,
                                                              currentItemId: "a"), 1000)
        XCTAssertNil(AudioPlayerService.sleepJumpBackTarget(armedAt: 1000, armedItemId: "a",
                                                            resumeAt: 1100, currentItemId: "a"))
        XCTAssertNil(AudioPlayerService.sleepJumpBackTarget(armedAt: 1000, armedItemId: "a",
                                                            resumeAt: 5000, currentItemId: "b"))
        XCTAssertNil(AudioPlayerService.sleepJumpBackTarget(armedAt: 1000, armedItemId: "a",
                                                            resumeAt: 5000, currentItemId: nil))
    }

    // MARK: P11 — Pocket Cassette

    func testWalkmanSkinKeepsRawValueButNotTheTrademark() {
        XCTAssertEqual(DeckSkin.walkman.rawValue, "walkman")
        XCTAssertEqual(String(localized: DeckSkin.walkman.displayName), "Pocket Cassette")
    }
}
