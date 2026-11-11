import XCTest
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 P5, P8, P11): pure rules behind the player sheets' quick wins —
/// naming a moment the way the player does, the clip editor's range line, what closing the clip
/// editor does to the player, and the SharePlay banner's line.
@MainActor
final class QuickWinsPlayerSheetsTests: XCTestCase {

    // Chapter has only a Decodable init (see BookmarkMomentLabelTests).
    private func chapter(_ id: Int, _ start: Double, _ end: Double, _ title: String) throws -> Chapter {
        let json = #"{"id": \#(id), "start": \#(start), "end": \#(end), "title": "\#(title)"}"#
        return try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
    }

    private func chapters() throws -> [Chapter] {
        [try chapter(1, 0, 600, "Opening"), try chapter(2, 600, 1800, "The Road")]
    }

    // MARK: P5 BookMoment

    func testMomentLabelIsChapterRelativeWithChapters() throws {
        XCTAssertEqual(BookMoment.label(time: 764, chapters: try chapters()), "2:44 · The Road")
        XCTAssertEqual(BookMoment.time(764, chapters: try chapters()), "2:44")
    }

    func testMomentLabelIsWholeBookWithoutChapters() {
        XCTAssertEqual(BookMoment.label(time: 27_730, chapters: []), "7:42:10")
        XCTAssertEqual(BookMoment.time(27_730, chapters: []), "7:42:10")
    }

    func testMomentChapterBoundaryUsesThePlayersHalfOpenRule() throws {
        // 600 is the start of chapter 2, not the end of chapter 1.
        XCTAssertEqual(BookMoment.chapter(at: 600, in: try chapters())?.id, 2)
        // Past the last chapter's end, no chapter: plain time.
        XCTAssertNil(BookMoment.chapter(at: 1800, in: try chapters()))
        XCTAssertEqual(BookMoment.label(time: 1800, chapters: try chapters()), "30:00")
    }

    // MARK: P5 ClipRangeLabel

    func testClipRangeInOneChapterIsRelativeWithTitleOnce() throws {
        let labels = ClipRangeLabel.make(ClipRange(start: 700, end: 730), chapters: try chapters())
        XCTAssertEqual(labels, .init(from: "1:40", to: "2:10", chapterTitle: "The Road"))
    }

    func testClipRangeEndingOnItsChaptersEndStaysInThatChapter() throws {
        let labels = ClipRangeLabel.make(ClipRange(start: 570, end: 600), chapters: try chapters())
        XCTAssertEqual(labels, .init(from: "9:30", to: "10:00", chapterTitle: "Opening"))
    }

    func testClipRangeAcrossChaptersNamesEachEnd() throws {
        let labels = ClipRangeLabel.make(ClipRange(start: 590, end: 620), chapters: try chapters())
        XCTAssertEqual(labels, .init(from: "9:50 · Opening", to: "0:20 · The Road", chapterTitle: nil))
    }

    func testClipRangeWithoutChaptersIsWholeBook() {
        let labels = ClipRangeLabel.make(ClipRange(start: 27_700, end: 27_730), chapters: [])
        XCTAssertEqual(labels, .init(from: "7:41:40", to: "7:42:10", chapterTitle: nil))
    }

    // MARK: P8 ClipEditorRestore

    func testNoPreviewLeavesThePlayerAlone() {
        // The book played on while the editor was open: don't pull it back.
        let plan = ClipEditorRestore.plan(didPreview: false, isSameBook: true, openedAt: 100, wasPlaying: true,
                                          currentTime: 160, isPlaying: true)
        XCTAssertEqual(plan, .leaveAlone)
    }

    func testPreviewWhilePlayingRestoresPositionAndResumes() {
        // Preview ended and paused at the clip's end.
        let plan = ClipEditorRestore.plan(didPreview: true, isSameBook: true, openedAt: 1_000, wasPlaying: true,
                                          currentTime: 995, isPlaying: false)
        XCTAssertEqual(plan, .init(seekTo: 1_000, togglePlayPause: true, clearsJumpBack: true))
    }

    func testPreviewWhilePausedRestoresPositionAndStaysPaused() {
        // Closed mid-preview, so it is still playing: pause it again.
        let plan = ClipEditorRestore.plan(didPreview: true, isSameBook: true, openedAt: 1_000, wasPlaying: false,
                                          currentTime: 980, isPlaying: true)
        XCTAssertEqual(plan, .init(seekTo: 1_000, togglePlayPause: true, clearsJumpBack: true))
        let settled = ClipEditorRestore.plan(didPreview: true, isSameBook: true, openedAt: 1_000, wasPlaying: false,
                                             currentTime: 990, isPlaying: false)
        XCTAssertEqual(settled, .init(seekTo: 1_000, togglePlayPause: false, clearsJumpBack: true))
    }

    func testAlreadyAtTheOpeningPositionSkipsTheSeekButDropsThePreviewsOffer() {
        let plan = ClipEditorRestore.plan(didPreview: true, isSameBook: true, openedAt: 1_000, wasPlaying: true,
                                          currentTime: 1_000.3, isPlaying: true)
        XCTAssertEqual(plan, .init(seekTo: nil, togglePlayPause: false, clearsJumpBack: true))
    }

    func testAnotherBookIsNeverTouched() {
        let plan = ClipEditorRestore.plan(didPreview: true, isSameBook: false, openedAt: 1_000, wasPlaying: true,
                                          currentTime: 20, isPlaying: false)
        XCTAssertEqual(plan, .leaveAlone)
    }

    // MARK: P11 SharePlay banner

    func testSharePlayLineWaitsWhenAlone() {
        XCTAssertEqual(ListenTogetherLogic.statusLine(participants: 1), "SharePlay · Waiting for others")
        XCTAssertEqual(ListenTogetherLogic.statusLine(participants: 0), "SharePlay · Waiting for others")
    }

    func testSharePlayLineCountsPeople() {
        XCTAssertEqual(ListenTogetherLogic.statusLine(participants: 3), "SharePlay · 3 people")
    }
}
