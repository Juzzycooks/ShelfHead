import XCTest
@testable import ShelfHead

/// Pins the exact bugs `TrackTimeline` was extracted to fix (ARCH-1, ARCH-9 in
/// REVIEW_2026-08-12.md): the old hand-rolled track-selection loops in
/// `AudioPlayerService` used an exclusive upper bound that matched no track at all
/// when a time landed exactly on (or past) the book's total duration.
final class TrackTimelineTests: XCTestCase {

    private func track(index: Int, start: Double?, duration: Double?) -> AudioTrack {
        AudioTrack(index: index, startOffset: start, duration: duration, title: nil,
                   contentUrl: "file:///track\(index).m4b", mimeType: nil, codec: nil)
    }

    // MARK: - Basic round trip

    func testResolvesMidTrackOffsetCorrectly() {
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 100, duration: 100),
            track(index: 2, start: 200, duration: 100),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])

        XCTAssertEqual(timeline.position(atAbsoluteTime: 0), .init(trackIndex: 0, offsetInTrack: 0))
        XCTAssertEqual(timeline.position(atAbsoluteTime: 50), .init(trackIndex: 0, offsetInTrack: 50))
        XCTAssertEqual(timeline.position(atAbsoluteTime: 150), .init(trackIndex: 1, offsetInTrack: 50))
        XCTAssertEqual(timeline.position(atAbsoluteTime: 250), .init(trackIndex: 2, offsetInTrack: 50))
    }

    func testExactInternalBoundaryResolvesToTheNextTrack() {
        // time == 100 is track 0's end AND track 1's start — must resolve to track 1
        // (matching the original loop's behavior for internal boundaries; only the
        // *last* track's upper bound changes).
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 100, duration: 100),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        XCTAssertEqual(timeline.position(atAbsoluteTime: 100), .init(trackIndex: 1, offsetInTrack: 0))
    }

    // MARK: - ARCH-1: time == duration on the last track

    func testTimeEqualToTotalDurationResolvesToEndOfLastTrackNotNoMatch() {
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 100, duration: 100),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        // Old behavior: no track satisfied `time < trackStart + trackDuration` for
        // time == 200, so the loop fell out having matched nothing at all.
        let position = timeline.position(atAbsoluteTime: 200)
        XCTAssertEqual(position.trackIndex, 1)
        XCTAssertEqual(position.offsetInTrack, 100, accuracy: 0.001)
    }

    func testTimeWellPastTotalDurationClampsToTheLastTracksOwnDuration() {
        // A wildly out-of-range time (e.g. corrupt/rounded session data) shouldn't
        // hand back an offset past the last track's own known duration.
        let tracks = [track(index: 0, start: 0, duration: 100)]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        let position = timeline.position(atAbsoluteTime: 9_999)
        XCTAssertEqual(position.trackIndex, 0)
        XCTAssertEqual(position.offsetInTrack, 100, accuracy: 0.001)
    }

    func testNegativeTimeClampsToTheStart() {
        let tracks = [track(index: 0, start: 0, duration: 100)]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        XCTAssertEqual(timeline.position(atAbsoluteTime: -50), .init(trackIndex: 0, offsetInTrack: 0))
    }

    // MARK: - Nil-duration tracks

    func testNilDurationMidTrackFallsBackToNextTracksStartAsItsBound() {
        // Track 1 has no reported duration — it should still be selected for times up
        // to (not including) track 2's start, rather than never matching anything past
        // its own start (the original behavior: `trackDuration = 0`, so the window
        // from start to start-plus-zero is empty).
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 100, duration: nil),
            track(index: 2, start: 180, duration: 100),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        XCTAssertEqual(timeline.position(atAbsoluteTime: 150), .init(trackIndex: 1, offsetInTrack: 50))
        XCTAssertEqual(timeline.position(atAbsoluteTime: 179), .init(trackIndex: 1, offsetInTrack: 79))
        XCTAssertEqual(timeline.position(atAbsoluteTime: 180), .init(trackIndex: 2, offsetInTrack: 0))
    }

    func testNilDurationLastTrackIsUnboundedOnItsHighSide() {
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 100, duration: nil),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        XCTAssertEqual(timeline.position(atAbsoluteTime: 500), .init(trackIndex: 1, offsetInTrack: 400))
    }

    // MARK: - startOffset falls back to accumulated duration when absent

    func testMissingStartOffsetAccumulatesFromPriorTrackDurations() {
        let tracks = [
            track(index: 0, start: nil, duration: 60),
            track(index: 1, start: nil, duration: 60),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        XCTAssertEqual(timeline.position(atAbsoluteTime: 90), .init(trackIndex: 1, offsetInTrack: 30))
    }

    // MARK: - Chapter lookup

    func testChapterLookupAtExactBoundaries() {
        let chapters = [
            Chapter.testFixture(id: 0, start: 0, end: 100, title: "One"),
            Chapter.testFixture(id: 1, start: 100, end: 200, title: "Two"),
        ]
        let timeline = TrackTimeline(tracks: [], chapters: chapters)
        XCTAssertEqual(timeline.chapter(at: 0)?.title, "One")
        XCTAssertEqual(timeline.chapter(at: 99.999)?.title, "One")
        // The boundary belongs to the chapter that starts there, not the one ending there.
        XCTAssertEqual(timeline.chapter(at: 100)?.title, "Two")
        XCTAssertNil(timeline.chapter(at: 200))
    }

    func testEmptyTracksResolvesToTrackZeroWithoutCrashing() {
        let timeline = TrackTimeline(tracks: [], chapters: [])
        XCTAssertEqual(timeline.position(atAbsoluteTime: 42), .init(trackIndex: 0, offsetInTrack: 0))
    }

    // MARK: - P3-11 (third-pass review, 14 Aug 2026): a real gap between two tracks'
    // independently-reported boundaries

    func testGapBetweenTracksCapsOffsetAtTheEarlierTracksOwnDuration() {
        // Track 0 ends at 100 by its own reported duration, but track 1 doesn't start
        // until 200 — a genuine 100s gap in the server's own numbers. Before this fix,
        // `position(atAbsoluteTime: 150)` matched track 0's range (bounded by track 1's
        // start, per NEW-10) with NO cap against track 0's own 100s duration, handing
        // back offset 150 on a 100s file — AVPlayer would clamp that seek, report the
        // asset finished, and `moveToNextTrack()` would fire immediately, landing at
        // 200 instead of the intended 150.
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 200, duration: 100),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        let position = timeline.position(atAbsoluteTime: 150)
        XCTAssertEqual(position.trackIndex, 0)
        XCTAssertEqual(position.offsetInTrack, 100, accuracy: 0.001)
    }

    func testNonMonotonicNextStartFallsBackToOwnDurationInsteadOfAnInvalidRange() {
        // Track 1's reported start (0) doesn't come after track 0's own start (0) at
        // all — a non-monotonic/flat pair (bad or hostile server data). Trusting it
        // as-is would make `trackEnd(at: 0)` return 0, an empty (zero-width) range
        // that could never match anything, even a time that plainly belongs to track
        // 0. `trackEnd` must fall back to track 0's own start+duration instead.
        let tracks = [
            track(index: 0, start: 0, duration: 100),
            track(index: 1, start: 0, duration: 100),
        ]
        let timeline = TrackTimeline(tracks: tracks, chapters: [])
        let position = timeline.position(atAbsoluteTime: 80)
        XCTAssertEqual(position.trackIndex, 0)
        XCTAssertEqual(position.offsetInTrack, 80, accuracy: 0.001)
    }
}

private extension Chapter {
    /// `Chapter`'s memberwise fields are all `let` with a custom `Codable` initializer
    /// (to tolerate a missing title) and no public memberwise initializer — this
    /// round-trips through JSON instead of needing one added just for tests.
    static func testFixture(id: Int, start: Double, end: Double, title: String) -> Chapter {
        let json = """
        {"id": \(id), "start": \(start), "end": \(end), "title": "\(title)"}
        """
        return try! JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
    }
}
