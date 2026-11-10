import XCTest
@testable import ShelfHead

final class NarratorPaceTests: XCTestCase {
    private func seg(_ start: Double, _ end: Double, words: Int) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: Array(repeating: "word", count: words).joined(separator: " "))
    }

    func testPaceCountsSpeechTimeNotGaps() {
        // 10 segments of 40 s each (400 s speech), 100 words each, separated by 20 s gaps.
        let segments = (0..<10).map { seg(Double($0) * 60, Double($0) * 60 + 40, words: 100) }
        let wpm = NarratorPace.wordsPerMinute(segments: segments)
        XCTAssertEqual(wpm!, 1000.0 / (400.0 / 60), accuracy: 0.01)
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(NarratorPace.wordsPerMinute(segments: [seg(0, 100, words: 300)]))
        XCTAssertNil(NarratorPace.wordsPerMinute(segments: []))
    }

    func testWordStartsPreferredOverText() {
        var s = seg(0, 300, words: 1)
        s.wordStarts = Array(repeating: 0, count: 600)
        XCTAssertEqual(NarratorPace.wordsPerMinute(segments: [s])!, 120, accuracy: 0.01)
    }

    func testCJKCountsCharactersOverOnePointFive() {
        let s = TranscriptSegment(start: 0, end: 300, text: String(repeating: "你", count: 150))
        XCTAssertEqual(NarratorPace.wordCount(of: s), 100, accuracy: 0.001)
        XCTAssertEqual(NarratorPace.wordsPerMinute(segments: [s])!, 20, accuracy: 0.01)
    }

    func testRateClampsAndRounds() {
        XCTAssertEqual(NarratorPace.rate(targetWPM: 170, paceWPM: 170), 1.0, accuracy: 1e-9)
        XCTAssertEqual(NarratorPace.rate(targetWPM: 230, paceWPM: 170), 1.35, accuracy: 1e-9)
        XCTAssertEqual(NarratorPace.rate(targetWPM: 300, paceWPM: 50), 3.0, accuracy: 1e-9)
        XCTAssertEqual(NarratorPace.rate(targetWPM: 120, paceWPM: 400), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NarratorPace.rate(targetWPM: 200, paceWPM: 150), 1.35, accuracy: 1e-9)
        XCTAssertEqual(NarratorPace.rate(targetWPM: 170, paceWPM: 0), 1.0, accuracy: 1e-9)
    }
}
