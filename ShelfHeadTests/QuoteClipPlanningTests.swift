import XCTest
@testable import ShelfHead

/// Batch 426: pure planning for quote clips. Segment i spans [i*10, i*10+8] (a 2 s gap follows each
/// line), so times double as indices.
final class QuoteClipPlanningTests: XCTestCase {
    private func segs(_ n: Int) -> [TranscriptSegment] {
        (0..<n).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 8, text: "Line \($0).") }
    }

    private func range(_ s: Double, _ e: Double) -> ClipRange { ClipRange(start: s, end: e) }

    private let tracks: [(index: Int, startOffset: Double, duration: Double)] = [
        (0, 0, 100), (1, 100, 100), (2, 200, 100)
    ]

    // MARK: Default range

    func testDefaultRangeMidBookNoSegments() {
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 100, bookDuration: 1000, segments: []),
                       range(70, 100))
    }

    func testDefaultRangeNearStartIsShort() {
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 10, bookDuration: 1000, segments: []),
                       range(0, 10))
    }

    func testDefaultRangePlayheadUnderMinLengthIsFirst30() {
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 2, bookDuration: 1000, segments: []),
                       range(0, 30))
    }

    func testDefaultRangePlayheadUnderMinLengthShortBook() {
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 2, bookDuration: 20, segments: []),
                       range(0, 20))
    }

    func testDefaultRangePlayheadPastEndIsClamped() {
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 1005, bookDuration: 1000, segments: []),
                       range(970, 1000))
    }

    func testDefaultRangeSnapsToSentences() {
        // 75 is inside line 7 (70-78); 105 is inside line 10 (100-108).
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 105, bookDuration: 1000, segments: segs(20)),
                       range(70, 108))
    }

    func testDefaultRangeEndExactlyAtSentenceStartSnapsBack() {
        // The playhead sits on the first word of line 10; the clip ends with line 9 instead.
        XCTAssertEqual(ClipRangeSnapper.defaultRange(playhead: 100, bookDuration: 1000, segments: segs(20)),
                       range(70, 98))
    }

    // MARK: Snapping

    func testSnapContainingSentences() {
        XCTAssertEqual(ClipRangeSnapper.snapped(range(73, 95), bookDuration: 1000, segments: segs(20)),
                       range(70, 98))
    }

    func testSnapStartInGapGoesToNextSentence() {
        // 79 is in the gap after line 7; line 8 starts at 80 (1 s away). End 95 is inside line 9.
        XCTAssertEqual(ClipRangeSnapper.snapped(range(79, 95), bookDuration: 1000, segments: segs(20)),
                       range(80, 98))
    }

    func testSnapEndInGapGoesToPreviousSentence() {
        XCTAssertEqual(ClipRangeSnapper.snapped(range(50, 79), bookDuration: 1000, segments: segs(20)),
                       range(50, 78))
    }

    func testSnapGapTooFarLeavesBoundariesAlone() {
        let s = [TranscriptSegment(start: 0, end: 8, text: "A."),
                 TranscriptSegment(start: 20, end: 28, text: "B.")]
        XCTAssertEqual(ClipRangeSnapper.snapped(range(12, 15), bookDuration: 100, segments: s), range(12, 15))
    }

    func testSnapNeverGoesBelowMinLength() {
        let s = [TranscriptSegment(start: 0, end: 8, text: "A."),
                 TranscriptSegment(start: 9.5, end: 10.5, text: "B."),
                 TranscriptSegment(start: 12, end: 20, text: "C.")]
        // Both ends would snap into the tiny middle line (1 s long); neither is allowed to.
        XCTAssertEqual(ClipRangeSnapper.snapped(range(8.5, 11.6), bookDuration: 100, segments: s),
                       range(8.5, 11.6))
    }

    func testSnapNeverExceedsMaxLength() {
        let s = [TranscriptSegment(start: 0, end: 100, text: "Long one."),
                 TranscriptSegment(start: 100, end: 200, text: "Long two.")]
        XCTAssertEqual(ClipRangeSnapper.snapped(range(50, 150), bookDuration: 1000, segments: s),
                       range(50, 150))
    }

    func testSnapKeepsOneEndWhenOnlyOtherWouldOverflow() {
        let s = [TranscriptSegment(start: 0, end: 100, text: "Long one."),
                 TranscriptSegment(start: 100, end: 200, text: "Long two.")]
        // Start snaps to 0 (length 100 fits); the end at 100 is the first line's own end, so it stays.
        XCTAssertEqual(ClipRangeSnapper.snapped(range(60, 100), bookDuration: 1000, segments: s),
                       range(0, 100))
    }

    func testSnapNoSegmentsClampsOnly() {
        XCTAssertEqual(ClipRangeSnapper.snapped(range(-5, 120), bookDuration: 100, segments: []),
                       range(0, 100))
    }

    func testSnapClampsToBookDuration() {
        // Line 9 ends at 98, past the 95 s book.
        XCTAssertEqual(ClipRangeSnapper.snapped(range(70, 93), bookDuration: 95, segments: segs(20)),
                       range(70, 95))
    }

    // MARK: Sentence nudges

    func testNudgeEndLaterBySentence() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: true, delta: 1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(70, 108))
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: true, delta: 2,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(70, 118))
    }

    func testNudgeEndEarlierBySentence() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: true, delta: -1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(70, 88))
    }

    func testNudgeStartEarlierBySentence() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: false, delta: -1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(60, 98))
    }

    func testNudgeStartLaterBySentence() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: false, delta: 1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(80, 98))
    }

    func testNudgeStartLaterFallsBackToLargestFittingStep() {
        // +5 sentences would pass the end; +2 (start 90) is the most that fits.
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: false, delta: 5,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(90, 98))
    }

    func testNudgeCannotShrinkBelowMinLength() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(90, 98), end: false, delta: 1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(90, 98))
    }

    func testNudgeEndStopsAtBookEnd() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: true, delta: 1,
                                                         bookDuration: 100, segments: segs(20)),
                       range(70, 98))
    }

    func testNudgeStartStopsAtBookStart() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(0, 28), end: false, delta: -1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(0, 28))
    }

    func testNudgeEndStopsAtMaxLength() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(0, 118), end: true, delta: 1,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(0, 118))
    }

    func testNudgeBySentenceWithoutSegmentsMovesSeconds() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: true, delta: 1,
                                                         bookDuration: 1000, segments: []),
                       range(70, 99))
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: false, delta: -2,
                                                         bookDuration: 1000, segments: []),
                       range(68, 98))
    }

    func testNudgeBySentenceZeroDeltaIsNoOp() {
        XCTAssertEqual(ClipRangeSnapper.nudgedBySentence(range(70, 98), end: true, delta: 0,
                                                         bookDuration: 1000, segments: segs(20)),
                       range(70, 98))
    }

    // MARK: Second nudges

    func testNudgeBySeconds() {
        XCTAssertEqual(ClipRangeSnapper.nudged(range(70, 100), end: true, by: 1, bookDuration: 1000),
                       range(70, 101))
        XCTAssertEqual(ClipRangeSnapper.nudged(range(70, 100), end: false, by: -1, bookDuration: 1000),
                       range(69, 100))
    }

    func testNudgeBySecondsClampsToMinMaxAndBook() {
        XCTAssertEqual(ClipRangeSnapper.nudged(range(70, 100), end: false, by: 40, bookDuration: 1000),
                       range(97, 100))
        XCTAssertEqual(ClipRangeSnapper.nudged(range(70, 100), end: true, by: -40, bookDuration: 1000),
                       range(70, 73))
        XCTAssertEqual(ClipRangeSnapper.nudged(range(70, 100), end: true, by: 500, bookDuration: 1000),
                       range(70, 190))
        XCTAssertEqual(ClipRangeSnapper.nudged(range(70, 100), end: true, by: 5, bookDuration: 102),
                       range(70, 102))
        XCTAssertEqual(ClipRangeSnapper.nudged(range(2, 30), end: false, by: -10, bookDuration: 1000),
                       range(0, 30))
    }

    // MARK: Track pieces

    func testPiecesSingleTrack() {
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(20, 50), tracks: tracks),
                       [ClipTrackPiece(trackIndex: 0, start: 20, duration: 30)])
    }

    func testPiecesAcrossBoundary() {
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(90, 110), tracks: tracks),
                       [ClipTrackPiece(trackIndex: 0, start: 90, duration: 10),
                        ClipTrackPiece(trackIndex: 1, start: 0, duration: 10)])
    }

    func testPiecesAcrossThreeTracks() {
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(50, 250), tracks: tracks),
                       [ClipTrackPiece(trackIndex: 0, start: 50, duration: 50),
                        ClipTrackPiece(trackIndex: 1, start: 0, duration: 100),
                        ClipTrackPiece(trackIndex: 2, start: 0, duration: 50)])
    }

    func testPiecesUnsortedTracks() {
        let shuffled = [tracks[2], tracks[0], tracks[1]]
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(90, 110), tracks: shuffled),
                       [ClipTrackPiece(trackIndex: 0, start: 90, duration: 10),
                        ClipTrackPiece(trackIndex: 1, start: 0, duration: 10)])
    }

    func testPiecesOutsideOrEmpty() {
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(500, 520), tracks: tracks), [])
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(10, 20), tracks: []), [])
    }

    func testPiecesDropSliver() {
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(99.995, 150), tracks: tracks),
                       [ClipTrackPiece(trackIndex: 1, start: 0, duration: 50)])
    }

    func testPiecesRangeStartingOnBoundary() {
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(100, 150), tracks: tracks),
                       [ClipTrackPiece(trackIndex: 1, start: 0, duration: 50)])
    }

    func testPiecesNonZeroTrackOffsets() {
        let t: [(index: Int, startOffset: Double, duration: Double)] = [(3, 1000.5, 60)]
        XCTAssertEqual(ClipTrackPlanner.pieces(for: range(1010.5, 1030.5), tracks: t),
                       [ClipTrackPiece(trackIndex: 3, start: 10, duration: 20)])
    }

    // MARK: Clip text

    private var sentences: [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 8, text: "Hello there."),
         TranscriptSegment(start: 10, end: 18, text: "How are you?"),
         TranscriptSegment(start: 20, end: 28, text: "Fine, thanks.")]
    }

    func testTextJoinsOverlappingSegments() {
        XCTAssertEqual(ClipText.text(for: range(0, 28), segments: sentences, spaceless: false),
                       "Hello there. How are you? Fine, thanks.")
    }

    func testTextIncludesSegmentOverlappedByExactlyHalf() {
        // Line 0 overlaps [4, 8] = half; line 1 overlaps 5 of 8.
        XCTAssertEqual(ClipText.text(for: range(4, 15), segments: sentences, spaceless: false),
                       "Hello there. How are you?")
    }

    func testTextExcludesEdgeSlivers() {
        // Line 0 overlaps only 3 of 8 s; line 2 not at all.
        XCTAssertEqual(ClipText.text(for: range(5, 15), segments: sentences, spaceless: false),
                       "How are you?")
    }

    func testTextEmptyWhenNothingOverlaps() {
        XCTAssertEqual(ClipText.text(for: range(40, 60), segments: sentences, spaceless: false), "")
        XCTAssertEqual(ClipText.text(for: range(0, 10), segments: [], spaceless: false), "")
    }

    func testTextSpacelessJoin() {
        let s = [TranscriptSegment(start: 0, end: 5, text: "你好。"),
                 TranscriptSegment(start: 5, end: 10, text: "再见。")]
        XCTAssertEqual(ClipText.text(for: range(0, 10), segments: s, spaceless: true), "你好。再见。")
    }

    func testTextTrimsWhitespace() {
        let s = [TranscriptSegment(start: 0, end: 5, text: "  Padded.\n")]
        XCTAssertEqual(ClipText.text(for: range(0, 5), segments: s, spaceless: false), "Padded.")
    }

    func testIsSpaceless() {
        XCTAssertTrue(ClipText.isSpaceless(localeIdentifier: "zh-CN"))
        XCTAssertTrue(ClipText.isSpaceless(localeIdentifier: "zh_TW"))
        XCTAssertTrue(ClipText.isSpaceless(localeIdentifier: "ja-JP"))
        XCTAssertTrue(ClipText.isSpaceless(localeIdentifier: "ZH-Hans"))
        XCTAssertFalse(ClipText.isSpaceless(localeIdentifier: "en-US"))
        XCTAssertFalse(ClipText.isSpaceless(localeIdentifier: "jv-ID"))
        XCTAssertFalse(ClipText.isSpaceless(localeIdentifier: ""))
    }

    // MARK: Bookmark note

    func testBookmarkNoteShortTextUnchanged() {
        XCTAssertEqual(ClipText.bookmarkNote("  A short line. ", spaceless: false), "A short line.")
    }

    func testBookmarkNoteExactlyLimitNotCut() {
        let text = String(repeating: "a", count: 200)
        XCTAssertEqual(ClipText.bookmarkNote(text, spaceless: false), text)
    }

    func testBookmarkNoteCutsAtWordBoundary() {
        XCTAssertEqual(ClipText.bookmarkNote("alpha beta gamma delta epsilon", limit: 20, spaceless: false),
                       "alpha beta gamma…")
    }

    func testBookmarkNoteKeepsWholeWordEndingAtLimit() {
        XCTAssertEqual(ClipText.bookmarkNote("alpha beta gamma dd epsilon", limit: 19, spaceless: false),
                       "alpha beta gamma dd…")
    }

    func testBookmarkNoteSingleLongWordCutsMidWord() {
        XCTAssertEqual(ClipText.bookmarkNote("supercalifragilistic", limit: 10, spaceless: false),
                       "supercalif…")
    }

    func testBookmarkNoteSpacelessCutsAtCharacter() {
        let text = String(repeating: "你", count: 300)
        let note = ClipText.bookmarkNote(text, spaceless: true)
        XCTAssertEqual(note, String(repeating: "你", count: 200) + "…")
    }

    func testBookmarkNoteDefaultLimitOnLongProse() {
        let text = Array(repeating: "word", count: 100).joined(separator: " ")
        let note = ClipText.bookmarkNote(text, spaceless: false)
        XCTAssertTrue(note.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(note.count, 201)
    }

    // MARK: File name

    func testFileNameFormat() {
        XCTAssertEqual(ClipText.fileName(title: "Dune", start: 65), "Dune – 1m05s.m4a")
        XCTAssertEqual(ClipText.fileName(title: "Dune", start: 0), "Dune – 0m00s.m4a")
        XCTAssertEqual(ClipText.fileName(title: "Dune", start: 59.9), "Dune – 0m59s.m4a")
    }

    func testFileNameHoursFormat() {
        XCTAssertEqual(ClipText.fileName(title: "Dune", start: 3725), "Dune – 1h02m05s.m4a")
    }

    func testFileNameStripsIllegalCharacters() {
        XCTAssertEqual(ClipText.fileName(title: "My Book: Part/1 \\ \"Q\"? <a>|*", start: 65),
                       "My Book Part1 Q a – 1m05s.m4a")
    }

    func testFileNameTruncatesTitleTo60() {
        let name = ClipText.fileName(title: String(repeating: "a", count: 100), start: 5)
        XCTAssertEqual(name, String(repeating: "a", count: 60) + " – 0m05s.m4a")
    }

    func testFileNameEmptyTitleFallsBackToClip() {
        XCTAssertEqual(ClipText.fileName(title: "", start: 5), "Clip – 0m05s.m4a")
        XCTAssertEqual(ClipText.fileName(title: " ?:/ ", start: 5), "Clip – 0m05s.m4a")
    }

    func testFileNameNegativeStartIsZero() {
        XCTAssertEqual(ClipText.fileName(title: "Dune", start: -4), "Dune – 0m00s.m4a")
    }
}
