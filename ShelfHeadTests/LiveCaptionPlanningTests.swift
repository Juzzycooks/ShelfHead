import XCTest
@testable import ShelfHead

/// Batch 425: pure planning for live captions and translation. Segment i spans
/// [i*10, i*10+8], so a 2 s gap follows each line and times double as indices.
final class LiveCaptionPlanningTests: XCTestCase {
    private func segs(_ n: Int) -> [TranscriptSegment] {
        (0..<n).map { TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 8, text: "Line \($0)") }
    }

    private func window(_ s: [TranscriptSegment], _ t: Double, complete: Bool = true,
                        before: Int = 2, after: Int = 2) -> LiveCaptionWindow {
        LiveCaptionPlanner.window(segments: s, time: t, isComplete: complete, before: before, after: after)
    }

    // MARK: Window

    func testEmptyTranscript() {
        let w = window([], 5)
        XCTAssertNil(w.anchor)
        XCTAssertEqual(w.lines, [])
        XCTAssertFalse(w.anchorIsLive)
        XCTAssertFalse(w.beyondTranscript)
    }

    func testEmptyIncompleteIsBeyond() {
        XCTAssertTrue(window([], 5, complete: false).beyondTranscript)
    }

    func testBeforeFirstLineShowsUpcoming() {
        let s = segs(6).map { var x = $0; x.start += 5; x.end += 5; return x }
        let w = window(s, 1)
        XCTAssertNil(w.anchor)
        XCTAssertEqual(w.lines, [0, 1, 2])
        XCTAssertFalse(w.anchorIsLive)
    }

    func testBeforeFirstLineWithFewSegments() {
        let s = segs(2).map { var x = $0; x.start += 5; x.end += 5; return x }
        XCTAssertEqual(window(s, 0).lines, [0, 1])
    }

    func testLiveLine() {
        let w = window(segs(10), 52)
        XCTAssertEqual(w.anchor, 5)
        XCTAssertTrue(w.anchorIsLive)
        XCTAssertEqual(w.lines, [3, 4, 5, 6, 7])
    }

    func testShortGapStillLive() {
        // 1 s after line 2 ended (28): within the 1.5 s tolerance.
        let w = window(segs(10), 29)
        XCTAssertEqual(w.anchor, 2)
        XCTAssertTrue(w.anchorIsLive)
    }

    func testLongGapHoldsLastLine() {
        var s = segs(4)
        s[3].start = 100; s[3].end = 108
        let w = window(s, 60)
        XCTAssertEqual(w.anchor, 2)
        XCTAssertFalse(w.anchorIsLive)
        XCTAssertEqual(w.lines, [0, 1, 2, 3])
    }

    func testFirstLineEdgeClampsBefore() {
        let w = window(segs(10), 3)
        XCTAssertEqual(w.anchor, 0)
        XCTAssertEqual(w.lines, [0, 1, 2])
    }

    func testLastLineEdgeClampsAfter() {
        let w = window(segs(10), 93)
        XCTAssertEqual(w.anchor, 9)
        XCTAssertEqual(w.lines, [7, 8, 9])
    }

    func testBeforeAfterOne() {
        XCTAssertEqual(window(segs(10), 52, before: 1, after: 1).lines, [4, 5, 6])
    }

    func testBeforeAfterZero() {
        XCTAssertEqual(window(segs(10), 52, before: 0, after: 0).lines, [5])
    }

    func testBeyondTranscriptOnlyWhenIncomplete() {
        let s = segs(3) // covered until 28
        XCTAssertTrue(window(s, 200, complete: false).beyondTranscript)
        XCTAssertFalse(window(s, 200, complete: true).beyondTranscript)
        XCTAssertFalse(window(s, 20, complete: false).beyondTranscript)
    }

    func testBeyondTranscriptKeepsLastLine() {
        let w = window(segs(3), 200, complete: false)
        XCTAssertEqual(w.anchor, 2)
        XCTAssertFalse(w.anchorIsLive)
    }

    // MARK: Highlight

    private func wordSegment() -> TranscriptSegment {
        // "one two three": words start at 0, 1, 2 s after 10.
        TranscriptSegment(start: 10, end: 13, text: "one two three",
                          wordStarts: [0, 1, 2], wordOffsets: [0, 4, 8])
    }

    func testHighlightPicksCurrentWord() {
        XCTAssertEqual(LiveCaptionPlanner.highlightRange(in: wordSegment(), at: 11.4), NSRange(location: 4, length: 3))
        XCTAssertEqual(LiveCaptionPlanner.highlightRange(in: wordSegment(), at: 12.5), NSRange(location: 8, length: 5))
    }

    func testHighlightNilWithoutWordTiming() {
        let s = TranscriptSegment(start: 0, end: 5, text: "no timing")
        XCTAssertNil(LiveCaptionPlanner.highlightRange(in: s, at: 2))
    }

    func testHighlightNilBeforeFirstWord() {
        var s = wordSegment()
        s.wordStarts = [0.5, 1, 2]
        XCTAssertNil(LiveCaptionPlanner.highlightRange(in: s, at: 10.2))
    }

    func testHighlightTailAfterEnd() {
        XCTAssertNotNil(LiveCaptionPlanner.highlightRange(in: wordSegment(), at: 13.2))
        XCTAssertNil(LiveCaptionPlanner.highlightRange(in: wordSegment(), at: 13.4))
    }

    // MARK: Interpolation

    func testInterpolationAdvancesWithRate() {
        let t0 = Date()
        let r = LiveCaptionPlanner.interpolatedTime(lastTime: 100, lastTickDate: t0, now: t0.addingTimeInterval(0.4),
                                                    isPlaying: true, rate: 1.5)
        XCTAssertEqual(r, 100.6, accuracy: 0.0001)
    }

    func testInterpolationClampsToMax() {
        let t0 = Date()
        let r = LiveCaptionPlanner.interpolatedTime(lastTime: 100, lastTickDate: t0, now: t0.addingTimeInterval(5),
                                                    isPlaying: true, rate: 2)
        XCTAssertEqual(r, 101, accuracy: 0.0001)
    }

    func testInterpolationPausedReturnsLastTime() {
        let t0 = Date()
        let r = LiveCaptionPlanner.interpolatedTime(lastTime: 100, lastTickDate: t0, now: t0.addingTimeInterval(0.4),
                                                    isPlaying: false, rate: 1)
        XCTAssertEqual(r, 100)
    }

    func testInterpolationNeverGoesBackwards() {
        let t0 = Date()
        let r = LiveCaptionPlanner.interpolatedTime(lastTime: 100, lastTickDate: t0, now: t0.addingTimeInterval(-3),
                                                    isPlaying: true, rate: 1)
        XCTAssertEqual(r, 100)
    }

    // MARK: Translation batch

    func testBatchStartsAtAnchorAndCoversLookAhead() {
        // time 52 -> anchor 5; lookAhead 30 -> horizon 82 -> segments up to start 80 (index 8).
        let b = LiveCaptionPlanner.translationBatch(segments: segs(30), time: 52, done: [], inFlight: [],
                                                    lookAhead: 30)
        XCTAssertEqual(b, [5, 6, 7, 8])
    }

    func testBatchSkipsDoneAndInFlight() {
        let b = LiveCaptionPlanner.translationBatch(segments: segs(30), time: 52, done: [5, 7], inFlight: [6],
                                                    lookAhead: 30)
        XCTAssertEqual(b, [8])
    }

    func testBatchCapsAtMaxCount() {
        let b = LiveCaptionPlanner.translationBatch(segments: segs(100), time: 0, done: [], inFlight: [],
                                                    lookAhead: 1000, maxCount: 3)
        XCTAssertEqual(b, [0, 1, 2])
    }

    func testBatchEmptyWhenAllDone() {
        let b = LiveCaptionPlanner.translationBatch(segments: segs(30), time: 52, done: Set(0..<30), inFlight: [])
        XCTAssertEqual(b, [])
    }

    func testBatchBeforeFirstLineStartsAtZero() {
        let s = segs(5).map { var x = $0; x.start += 20; x.end += 20; return x }
        XCTAssertEqual(LiveCaptionPlanner.translationBatch(segments: s, time: 0, done: [], inFlight: [],
                                                           lookAhead: 35), [0, 1])
    }

    func testBatchEmptySegments() {
        XCTAssertEqual(LiveCaptionPlanner.translationBatch(segments: [], time: 0, done: [], inFlight: []), [])
    }

    func testBatchEndsAtLastSegment() {
        XCTAssertEqual(LiveCaptionPlanner.translationBatch(segments: segs(3), time: 25, done: [], inFlight: []), [2])
    }

    // MARK: Languages

    func testSameLanguageIsNotTranslation() {
        XCTAssertFalse(CaptionTranslationLanguage.isTranslation(source: "en-US", target: "en"))
        XCTAssertFalse(CaptionTranslationLanguage.isTranslation(source: "en-GB", target: "en-US"))
    }

    func testDifferentLanguageIsTranslation() {
        XCTAssertTrue(CaptionTranslationLanguage.isTranslation(source: "en-US", target: "fr"))
        XCTAssertTrue(CaptionTranslationLanguage.isTranslation(source: "zh-CN", target: "en"))
    }

    func testChineseScriptsDiffer() {
        XCTAssertTrue(CaptionTranslationLanguage.isTranslation(source: "zh-CN", target: "zh-Hant"))
        XCTAssertTrue(CaptionTranslationLanguage.isTranslation(source: "zh-TW", target: "zh-Hans"))
        XCTAssertFalse(CaptionTranslationLanguage.isTranslation(source: "zh-CN", target: "zh-Hans"))
        XCTAssertFalse(CaptionTranslationLanguage.isTranslation(source: "zh-TW", target: "zh-Hant"))
    }

    func testEmptyTargetIsNotTranslation() {
        XCTAssertFalse(CaptionTranslationLanguage.isTranslation(source: "en-US", target: ""))
    }

    func testSuggestedTargetSkipsSourceLanguage() {
        XCTAssertEqual(CaptionTranslationLanguage.suggestedTarget(source: "en-US",
                                                                   preferredLanguages: ["en-AU", "fr-FR"]), "fr")
    }

    func testSuggestedTargetKeepsChineseScript() {
        XCTAssertEqual(CaptionTranslationLanguage.suggestedTarget(source: "en-US",
                                                                   preferredLanguages: ["zh-Hans-AU", "en-AU"]), "zh-Hans")
        XCTAssertEqual(CaptionTranslationLanguage.suggestedTarget(source: "en-US",
                                                                   preferredLanguages: ["zh-TW"]), "zh-Hant")
    }

    func testSuggestedTargetNilWhenNothingDiffers() {
        XCTAssertNil(CaptionTranslationLanguage.suggestedTarget(source: "en-US", preferredLanguages: ["en-AU", "en-GB"]))
        XCTAssertNil(CaptionTranslationLanguage.suggestedTarget(source: "en-US", preferredLanguages: []))
    }
}
