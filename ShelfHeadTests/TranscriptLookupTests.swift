import XCTest
@testable import ShelfHead

/// Phase 1, Batch 422: the pure lookups over a transcript's sorted segments.
final class TranscriptLookupTests: XCTestCase {
    private let segments = [
        TranscriptSegment(start: 10, end: 14, text: "First."),
        TranscriptSegment(start: 14, end: 18, text: "Second."),
        TranscriptSegment(start: 30, end: 33, text: "Third."),
    ]

    // MARK: segmentIndex

    func testSegmentIndexInsideSegment() {
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 11), 0)
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 15), 1)
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 31), 2)
    }

    func testSegmentIndexAtBoundaryPicksLaterSegment() {
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 14), 1)
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 10), 0)
    }

    func testSegmentIndexBeforeFirstIsNil() {
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: 9.9))
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: 0))
    }

    func testSegmentIndexShortGapKeepsPreviousCaption() {
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 19), 1)
    }

    func testSegmentIndexLongGapIsNil() {
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: 25))
    }

    func testSegmentIndexCustomGapTolerance() {
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: 19, gapTolerance: 0.5))
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 25, gapTolerance: 10), 1)
    }

    func testSegmentIndexPastEndWithinToleranceThenNil() {
        XCTAssertEqual(TranscriptLookup.segmentIndex(in: segments, at: 34), 2)
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: 40))
    }

    func testSegmentIndexEmptyAndNonFinite() {
        XCTAssertNil(TranscriptLookup.segmentIndex(in: [], at: 5))
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: .nan))
        XCTAssertNil(TranscriptLookup.segmentIndex(in: segments, at: .infinity))
    }

    // MARK: wordIndex

    private let timed = TranscriptSegment(
        start: 100, end: 103, text: "Hello brave world.",
        wordStarts: [0, 1, 2], wordOffsets: [0, 6, 12])

    func testWordIndexPicksLastWordStartedAtOrBefore() {
        XCTAssertEqual(TranscriptLookup.wordIndex(in: timed, at: 100), 0)
        XCTAssertEqual(TranscriptLookup.wordIndex(in: timed, at: 100.9), 0)
        XCTAssertEqual(TranscriptLookup.wordIndex(in: timed, at: 101), 1)
        XCTAssertEqual(TranscriptLookup.wordIndex(in: timed, at: 102.5), 2)
        XCTAssertEqual(TranscriptLookup.wordIndex(in: timed, at: 200), 2)
    }

    func testWordIndexBeforeFirstWordIsNil() {
        XCTAssertNil(TranscriptLookup.wordIndex(in: timed, at: 99))
    }

    func testWordIndexWithoutTimingIsNil() {
        XCTAssertNil(TranscriptLookup.wordIndex(in: TranscriptSegment(start: 0, end: 1, text: "x"), at: 0.5))
    }

    // MARK: wordRange

    func testWordRangeTrimsTrailingSpace() {
        XCTAssertEqual(TranscriptLookup.wordRange(in: timed, wordIndex: 0), NSRange(location: 0, length: 5))
        XCTAssertEqual(TranscriptLookup.wordRange(in: timed, wordIndex: 1), NSRange(location: 6, length: 5))
    }

    func testWordRangeLastWordRunsToEndOfText() {
        XCTAssertEqual(TranscriptLookup.wordRange(in: timed, wordIndex: 2), NSRange(location: 12, length: 6))
    }

    func testWordRangeOutOfRangeIsNil() {
        XCTAssertNil(TranscriptLookup.wordRange(in: timed, wordIndex: -1))
        XCTAssertNil(TranscriptLookup.wordRange(in: timed, wordIndex: 3))
    }

    func testWordRangeCJKWithoutSpaces() {
        let segment = TranscriptSegment(
            start: 0, end: 2, text: "你好世界。",
            wordStarts: [0, 0.5, 1], wordOffsets: [0, 2, 4])
        XCTAssertEqual(TranscriptLookup.wordRange(in: segment, wordIndex: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(TranscriptLookup.wordRange(in: segment, wordIndex: 1), NSRange(location: 2, length: 2))
        XCTAssertEqual(TranscriptLookup.wordRange(in: segment, wordIndex: 2), NSRange(location: 4, length: 1))
    }

    func testWordRangeBadOffsetsAreNil() {
        let segment = TranscriptSegment(start: 0, end: 1, text: "abc", wordStarts: [0], wordOffsets: [10])
        XCTAssertNil(TranscriptLookup.wordRange(in: segment, wordIndex: 0))
    }

    // MARK: segmentIndices

    func testSegmentIndicesOverlap() {
        XCTAssertEqual(TranscriptLookup.segmentIndices(in: segments, from: 12, to: 16), 0..<2)
        XCTAssertEqual(TranscriptLookup.segmentIndices(in: segments, from: 0, to: 100), 0..<3)
        XCTAssertEqual(TranscriptLookup.segmentIndices(in: segments, from: 29, to: 31), 2..<3)
    }

    func testSegmentIndicesNoOverlapAndBadInput() {
        XCTAssertTrue(TranscriptLookup.segmentIndices(in: segments, from: 20, to: 25).isEmpty)
        XCTAssertTrue(TranscriptLookup.segmentIndices(in: segments, from: 50, to: 60).isEmpty)
        XCTAssertTrue(TranscriptLookup.segmentIndices(in: segments, from: 5, to: 1).isEmpty)
        XCTAssertTrue(TranscriptLookup.segmentIndices(in: [], from: 0, to: 10).isEmpty)
    }
}
