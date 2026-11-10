import XCTest
@testable import ShelfHead

/// Phase 1, Batch 422: turning word-level transcriber runs into sentence segments.
final class SegmentBuilderTests: XCTestCase {
    private func run(_ text: String, _ start: Double, _ end: Double) -> TimedRun {
        TimedRun(text: text, start: start, end: end)
    }

    private func build(_ runs: [TimedRun], offset: Double = 0, spaceless: Bool = false,
                       pause: Double = 1.2, maxDuration: Double = 25) -> [TranscriptSegment] {
        SegmentBuilder.segments(from: runs, trackOffset: offset, spaceless: spaceless,
                                pauseSplit: pause, maxDuration: maxDuration)
    }

    func testEmptyInput() {
        XCTAssertTrue(build([]).isEmpty)
    }

    func testSingleSentenceWithTimingAndOffsets() {
        let segments = build([run("Hello", 1, 1.4), run("brave", 1.5, 1.9), run("world.", 2, 2.5)])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello brave world.")
        XCTAssertEqual(segments[0].start, 1)
        XCTAssertEqual(segments[0].end, 2.5)
        XCTAssertEqual(segments[0].wordStarts, [0, 0.5, 1])
        XCTAssertEqual(segments[0].wordOffsets, [0, 6, 12])
    }

    func testLeadingSpacesAreTrimmedAndEmptyRunsSkipped() {
        let segments = build([run(" Hello", 0, 0.4), run("   ", 0.4, 0.5), run("", 0.5, 0.6), run(" world. ", 0.6, 1)])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello world.")
        XCTAssertEqual(segments[0].wordOffsets, [0, 6])
    }

    func testSplitsAtSentenceTerminators() {
        let segments = build([
            run("One.", 0, 0.5), run("Two!", 0.6, 1), run("Three?", 1.1, 1.5),
            run("Four…", 1.6, 2), run("Five", 2.1, 2.5),
        ])
        XCTAssertEqual(segments.map(\.text), ["One.", "Two!", "Three?", "Four…", "Five"])
    }

    func testPunctuationOnlyRunAttachesToPreviousWord() {
        let segments = build([run("Well", 0, 0.3), run(",", 0.3, 0.3), run("then", 0.4, 0.7), run(".", 0.7, 0.7)])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Well, then.")
        XCTAssertEqual(segments[0].wordStarts.count, 2)
        XCTAssertEqual(segments[0].wordOffsets, [0, 6])
    }

    func testClosingQuoteAfterTerminatorStaysInSentence() {
        let segments = build([run("\u{201C}Go.", 0, 0.5), run("\u{201D}", 0.5, 0.5), run("He", 0.6, 0.8), run("left.", 0.9, 1.2)])
        XCTAssertEqual(segments.map(\.text), ["\u{201C}Go.\u{201D}", "He left."])
        XCTAssertEqual(segments[0].wordOffsets, [0])
    }

    func testQuoteGluedToTerminatorSplits() {
        let segments = build([run("Go.\u{201D}", 0, 0.5), run("Next", 0.6, 0.9)])
        XCTAssertEqual(segments.map(\.text), ["Go.\u{201D}", "Next"])
    }

    func testPauseSplit() {
        let segments = build([run("alpha", 0, 0.5), run("beta", 3, 3.5)], pause: 1.2)
        XCTAssertEqual(segments.map(\.text), ["alpha", "beta"])
        XCTAssertEqual(segments[1].start, 3)
        XCTAssertEqual(segments[1].wordStarts, [0])
    }

    func testShortPauseDoesNotSplit() {
        let segments = build([run("alpha", 0, 0.5), run("beta", 1.5, 2)], pause: 1.2)
        XCTAssertEqual(segments.map(\.text), ["alpha beta"])
    }

    func testMaxDurationSplit() {
        let runs = (0..<10).map { run("w\($0)", Double($0), Double($0) + 0.9) }
        let segments = build(runs, maxDuration: 4)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), runs.map(\.text).joined(separator: " "))
        for segment in segments { XCTAssertLessThanOrEqual(segment.duration, 4.0 + 1e-9) }
    }

    func testTrackOffsetIsApplied() {
        let segments = build([run("Hi", 2, 2.5), run("there.", 2.6, 3)], offset: 3600)
        XCTAssertEqual(segments[0].start, 3602)
        XCTAssertEqual(segments[0].end, 3603)
        XCTAssertEqual(segments[0].wordStarts, [0, 0.6])
    }

    func testCJKJoinsWithoutSpacesAndSplitsAtIdeographicFullStop() {
        let segments = build([
            run("你好", 0, 0.4), run("世界", 0.4, 0.8), run("。", 0.8, 0.8),
            run("再见", 1, 1.4), run("！", 1.4, 1.4),
        ], spaceless: true)
        XCTAssertEqual(segments.map(\.text), ["你好世界。", "再见！"])
        XCTAssertEqual(segments[0].wordOffsets, [0, 2])
        XCTAssertEqual(segments[1].wordOffsets, [0])
    }

    func testWordOffsetsAreUTF16() {
        // "😀" is two UTF-16 code units; "é" one.
        let segments = build([run("😀", 0, 0.2), run("café", 0.3, 0.6), run("ok.", 0.7, 1)])
        XCTAssertEqual(segments[0].text, "😀 café ok.")
        XCTAssertEqual(segments[0].wordOffsets, [0, 3, 8])
        let ns = segments[0].text as NSString
        XCTAssertEqual(ns.substring(from: 3), "café ok.")
        XCTAssertEqual(TranscriptLookup.wordRange(in: segments[0], wordIndex: 1), NSRange(location: 3, length: 4))
    }

    func testIsSpaceless() {
        for id in ["zh-CN", "zh_TW", "zh-Hans", "ja-JP", "th-TH", "lo", "km-KH", "my-MM"] {
            XCTAssertTrue(SegmentBuilder.isSpaceless(localeIdentifier: id), id)
        }
        for id in ["en-US", "fr-FR", "de", "ko-KR", ""] {
            XCTAssertFalse(SegmentBuilder.isSpaceless(localeIdentifier: id), id)
        }
    }

    // MARK: - Abbreviations, initials and numbers don't end a sentence

    private func words(_ text: String) -> [TimedRun] {
        text.split(separator: " ").enumerated().map { i, w in run(String(w), Double(i) * 0.4, Double(i) * 0.4 + 0.3) }
    }

    func testTitleAbbreviationDoesNotSplit() {
        XCTAssertEqual(build(words("Mr. Smith opened the door. Dr. Watson waited.")).map(\.text),
                       ["Mr. Smith opened the door.", "Dr. Watson waited."])
    }

    func testInitialsDoNotSplit() {
        XCTAssertEqual(build(words("It was written by J. R. R. Tolkien. He was a professor.")).map(\.text),
                       ["It was written by J. R. R. Tolkien.", "He was a professor."])
    }

    func testPlaceAbbreviationDoesNotSplit() {
        XCTAssertEqual(build(words("They sailed to St. Ives at dawn. The sea was calm.")).map(\.text),
                       ["They sailed to St. Ives at dawn.", "The sea was calm."])
    }

    func testPeriodBeforeLowercaseOrDigitDoesNotSplit() {
        XCTAssertEqual(build(words("It was approx. three miles. Then vol. 2 began.")).map(\.text),
                       ["It was approx. three miles.", "Then vol. 2 began."])
    }

    func testDecimalInOneRunStaysInSentence() {
        XCTAssertEqual(build(words("They walked 3.5 miles. It rained.")).map(\.text),
                       ["They walked 3.5 miles.", "It rained."])
    }

    func testPendingPeriodAtEndOfInputStillFlushes() {
        XCTAssertEqual(build(words("The end.")).map(\.text), ["The end."])
    }

    func testSentenceBreakDecision() {
        XCTAssertFalse(SegmentBuilder.isSentenceBreak(after: "Hello Mr.", next: "Smith"))
        XCTAssertFalse(SegmentBuilder.isSentenceBreak(after: "by J.", next: "R."))
        XCTAssertTrue(SegmentBuilder.isSentenceBreak(after: "She left the room.", next: "Then"))
        XCTAssertTrue(SegmentBuilder.isSentenceBreak(after: "He said \u{201C}stop.\u{201D}", next: "Nobody"))
    }
}
