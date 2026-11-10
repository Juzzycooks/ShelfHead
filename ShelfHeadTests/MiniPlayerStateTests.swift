import XCTest
@testable import ShelfHead

/// Critique 2026-10-05 (Mini player): pins the pure decisions behind the bar's second line,
/// progress line and VoiceOver label.
final class MiniPlayerStateTests: XCTestCase {
    private func line(stalled: Bool = false, streaming: Bool = true, sleep: SleepTimerOption = .off,
                      sleepRemaining: TimeInterval = 0, chapter: TimeInterval? = nil,
                      author: String = "A. Author") -> MiniPlayerStatus.Line {
        MiniPlayerStatus.line(isStalled: stalled, isStreaming: streaming, sleepOption: sleep,
                              sleepRemaining: sleepRemaining, chapterRemaining: chapter, author: author)
    }

    func testStalledWhileStreamingWinsOverSleepAndChapter() {
        let l = line(stalled: true, sleep: .endOfChapter, chapter: 120)
        XCTAssertEqual(l.kind, .stalled)
        XCTAssertEqual(l.full, "Waiting for your server")
    }

    func testStalledWhileDownloadedDoesNotBlameServer() {
        XCTAssertEqual(line(stalled: true, streaming: false, chapter: 120).kind, .chapter)
    }

    func testSleepTimerBeatsChapterCountdown() {
        let l = line(sleep: .minutes(15), sleepRemaining: 724, chapter: 90)
        XCTAssertEqual(l.kind, .sleep)
        XCTAssertEqual(l.full, "Sleeps in 12:04")
    }

    func testSleepWordingForNonCountdownOptions() {
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfChapter, remaining: 0), "Sleeps at end of chapter")
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .chapters(1), remaining: 0), "Sleeps after 1 more chapter")
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .chapters(3), remaining: 0), "Sleeps after 3 more chapters")
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfBook, remaining: 0), "Sleeps at end of book")
        XCTAssertNil(MiniPlayerStatus.sleepText(option: .off, remaining: 0))
    }

    func testFallsBackToChapterThenAuthor() {
        XCTAssertEqual(line(chapter: 61).kind, .chapter)
        let a = line()
        XCTAssertEqual(a.kind, .author)
        XCTAssertEqual(a.full, "A. Author")
    }

    func testProgressFractionUsesChapterWhenPresent() {
        XCTAssertEqual(MiniPlayerStatus.progressFraction(hasChapter: true, chapterElapsed: 30, chapterLength: 120, bookProgress: 0.9), 0.25, accuracy: 0.0001)
        XCTAssertEqual(MiniPlayerStatus.progressFraction(hasChapter: false, chapterElapsed: 30, chapterLength: 120, bookProgress: 0.9), 0.9, accuracy: 0.0001)
    }

    func testProgressFractionClamps() {
        XCTAssertEqual(MiniPlayerStatus.progressFraction(hasChapter: true, chapterElapsed: 500, chapterLength: 100, bookProgress: 0), 1)
        XCTAssertEqual(MiniPlayerStatus.progressFraction(hasChapter: false, chapterElapsed: 0, chapterLength: 0, bookProgress: .nan), 0)
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(MiniPlayerStatus.accessibilityLabel(title: "Dune", isPlaying: true, isStalled: false, isStreaming: true, sleepArmed: false, author: "Frank Herbert"),
                       "Dune, playing, Frank Herbert")
        XCTAssertEqual(MiniPlayerStatus.accessibilityLabel(title: "Dune", isPlaying: false, isStalled: true, isStreaming: true, sleepArmed: true, author: "Frank Herbert"),
                       "Dune, paused, Waiting for your server")
        XCTAssertEqual(MiniPlayerStatus.accessibilityLabel(title: "Dune", isPlaying: true, isStalled: false, isStreaming: true, sleepArmed: true, author: "x"),
                       "Dune, playing, Sleep timer on")
    }

    // MARK: - Second run (2026-10-05)

    func testOfflineStallSaysOfflineNotServer() {
        let l = MiniPlayerStatus.line(isStalled: true, isStreaming: true, sleepOption: .off, sleepRemaining: 0,
                                      chapterRemaining: nil, author: "A", reachability: .offline)
        XCTAssertEqual(l.kind, .stalled)
        XCTAssertEqual(l.full, "You're offline")
        let r = MiniPlayerStatus.line(isStalled: true, isStreaming: true, sleepOption: .off, sleepRemaining: 0,
                                      chapterRemaining: nil, author: "A", reachability: .serverUnreachable)
        XCTAssertEqual(r.full, "Waiting for your server")
    }

    func testEndOfChapterSleepShowsMinutesWhenKnown() {
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfChapter, remaining: 0, chapterRemaining: 1170), "Sleeps in 19:30")
        XCTAssertEqual(MiniPlayerStatus.sleepText(option: .endOfChapter, remaining: 0, chapterRemaining: nil), "Sleeps at end of chapter")
        XCTAssertEqual(line(sleep: .endOfChapter, chapter: 1170).full, "Sleeps in 19:30")
    }

    func testAccessibilityLabelMentionsLoadingAndOffline() {
        XCTAssertEqual(MiniPlayerStatus.accessibilityLabel(title: "Dune", isPlaying: false, isStalled: false, isStreaming: true,
                                                           sleepArmed: false, author: "F", isLoading: true),
                       "Dune, paused, loading, F")
        XCTAssertEqual(MiniPlayerStatus.accessibilityLabel(title: "Dune", isPlaying: true, isStalled: true, isStreaming: true,
                                                           sleepArmed: false, author: "F", reachability: .offline),
                       "Dune, playing, You're offline")
    }

    func testStopUndoPlan() {
        let playing = PlayerViewModel.stopUndoPlan(wasPlaying: true, sleepOption: .minutes(15), sleepRemaining: 600)
        XCTAssertTrue(playing.resume)
        XCTAssertTrue(playing.rearmSleep)
        XCTAssertEqual(playing.sleepRemaining, 600)
        let paused = PlayerViewModel.stopUndoPlan(wasPlaying: false, sleepOption: .endOfBook, sleepRemaining: 0)
        XCTAssertFalse(paused.resume)
        XCTAssertFalse(paused.rearmSleep)
        let noTimer = PlayerViewModel.stopUndoPlan(wasPlaying: true, sleepOption: .off, sleepRemaining: 0)
        XCTAssertTrue(noTimer.resume)
        XCTAssertFalse(noTimer.rearmSleep)
    }
}
