import XCTest
@testable import ShelfHead

/// Batch 424: pins the pure decision behind Siri's "Find in Audiobook", especially the spoiler
/// rule (a match only past the frontier is `.onlyAhead`, never a jump).
final class FindInAudiobookTests: XCTestCase {
    private func hit(_ time: Double) -> TranscriptSearchHit {
        TranscriptSearchHit(segmentIndex: 0, time: time, score: 1, snippet: "x", highlights: [])
    }

    func testNoTranscriptWinsOverEverything() {
        XCTAssertEqual(FindInAudiobookOutcome.decide(hasTranscript: false, bestBeforeFrontier: hit(5), bestAnywhere: hit(5)),
                       .noTranscript)
    }

    func testJumpsToHitBeforeFrontier() {
        XCTAssertEqual(FindInAudiobookOutcome.decide(hasTranscript: true, bestBeforeFrontier: hit(120.5), bestAnywhere: nil),
                       .jump(time: 120.5))
    }

    func testBeforeFrontierPreferredOverAnywhere() {
        XCTAssertEqual(FindInAudiobookOutcome.decide(hasTranscript: true, bestBeforeFrontier: hit(10), bestAnywhere: hit(900)),
                       .jump(time: 10))
    }

    func testOnlyAheadWhenMatchExistsButNotHeard() {
        XCTAssertEqual(FindInAudiobookOutcome.decide(hasTranscript: true, bestBeforeFrontier: nil, bestAnywhere: hit(900)),
                       .onlyAhead)
    }

    func testNotFoundWhenNoMatchAnywhere() {
        XCTAssertEqual(FindInAudiobookOutcome.decide(hasTranscript: true, bestBeforeFrontier: nil, bestAnywhere: nil),
                       .notFound)
    }

    func testOnlyAheadAndNotFoundAreDistinct() {
        XCTAssertNotEqual(FindInAudiobookOutcome.onlyAhead, FindInAudiobookOutcome.notFound)
    }

    /// A hit exactly at time 0 is still a jump (not mistaken for "no hit").
    func testJumpToStartOfBook() {
        XCTAssertEqual(FindInAudiobookOutcome.decide(hasTranscript: true, bestBeforeFrontier: hit(0), bestAnywhere: hit(0)),
                       .jump(time: 0))
    }

    func testOutcomesHaveDistinctNonEmptyDialogs() {
        let outcomes: [FindInAudiobookOutcome] = [.jump(time: 1), .noBook, .noTranscript, .notFound, .onlyAhead]
        let texts = outcomes.map { String(describing: $0.dialog) }
        XCTAssertEqual(Set(texts).count, outcomes.count)
    }
}
