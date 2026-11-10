import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • NowPlayingChapterRepublishTests
// =============================================================================
//
// Pins `AudioPlayerService.shouldRepublishNowPlaying(lastPublishedChapterId:
// currentChapterId:)`, the decision behind a user-reported real-device bug:
//
//   "On CarPlay and the lock screen Now Playing, when the book goes to a new
//    chapter it does not transition until I stop/start or use a fwd/bkwd control.
//    It will stay at 0:00 remaining time and the bar being complete."
//
// Root cause: `updateNowPlaying()` publishes CHAPTER-RELATIVE elapsed/duration to
// `MPNowPlayingInfoCenter`, the system extrapolates elapsed forward from that pair
// on its own, and nothing republished when playback merely crossed a chapter
// boundary — so the extrapolation clamped at the published chapter duration.
//
// Only the decision is tested. The publish itself (`MPNowPlayingInfoCenter`,
// `CPNowPlayingTemplate`, WidgetKit reloads, Handoff) needs a real device, the same
// line `CarPlayListWindowingTests`/`CarPlayAlertCopyTests` already draw around live
// CarPlay templates and `DownloadManager.shouldReclaimOrphanDirectory` around the
// disk-scanning sweep that calls it.
final class NowPlayingChapterRepublishTests: XCTestCase {

    private func shouldRepublish(from last: Int?, to current: Int?) -> Bool {
        AudioPlayerService.shouldRepublishNowPlaying(
            lastPublishedChapterId: last, currentChapterId: current)
    }

    /// The actual bug: playback rolls from chapter 4 into chapter 5 with no seek, no
    /// pause and no track change. If this returns false, CarPlay and the lock screen
    /// sit at 0:00 remaining on a full bar until the user touches a transport control.
    func testCrossingAChapterBoundaryRepublishes() {
        XCTAssertTrue(shouldRepublish(from: 4, to: 5),
                      "Crossing into the next chapter must republish — this is the reported bug.")
        // Chapter ids are not guaranteed to only ever increase from here: a seek or a
        // chapter-list tap can move backwards, and that's just as much a change.
        XCTAssertTrue(shouldRepublish(from: 5, to: 4),
                      "Moving backwards into an earlier chapter is a change too.")
        XCTAssertTrue(shouldRepublish(from: 0, to: 1),
                      "The first boundary of a book (chapter 0 -> 1) is not a special case.")
    }

    /// The other half of the requirement: this runs on the 0.5s periodic time
    /// observer, so every tick that has NOT crossed a boundary must be a no-op. A
    /// republish per tick would mean an `MPNowPlayingInfoCenter` write, an App Group
    /// snapshot write and a Handoff update twice a second for the whole book.
    func testStayingInTheSameChapterDoesNotRepublish() {
        for id in [0, 1, 7, 63, 412] {
            XCTAssertFalse(shouldRepublish(from: id, to: id),
                           "Ordinary progress inside chapter \(id) must not republish on every tick.")
        }
    }

    /// A book with no chapter data at all: `currentChapter` is permanently nil, the
    /// published values are whole-book, and the tick must never republish.
    func testChapterlessBookNeverRepublishes() {
        XCTAssertFalse(shouldRepublish(from: nil, to: nil),
                       "A book with no chapters has no boundaries to cross.")
    }

    /// nil is treated as a real value on both sides, not as "unknown":
    /// - nil -> id covers the first publish of a session (and a chapterless stretch
    ///   giving way to chapter data).
    /// - id -> nil covers running off the end of the final chapter, or into a gap
    ///   between two chapters — without republishing there, the previous chapter's
    ///   bar stays pinned full rather than falling back to whole-book values.
    func testTransitionsInAndOutOfHavingAChapterRepublish() {
        XCTAssertTrue(shouldRepublish(from: nil, to: 0),
                      "Acquiring a chapter (including the session's first publish) must republish.")
        XCTAssertTrue(shouldRepublish(from: 12, to: nil),
                      "Falling out of the last chapter must republish, not leave a full bar pinned.")
    }

    /// Lifecycle guard. `startPlayback`/`stop` reset the tracked id to nil, so the
    /// state a new book starts from is (nil, whatever chapter the resume point lands
    /// in) — which must republish even when the new book's chapter number happens to
    /// match the id the previous book was left on.
    func testNewBookAfterResetRepublishesEvenAtTheSameChapterNumber() {
        let afterReset: Int? = nil
        XCTAssertTrue(shouldRepublish(from: afterReset, to: 3),
                      "A fresh session must publish its opening chapter regardless of the previous book's ids.")
    }
}
