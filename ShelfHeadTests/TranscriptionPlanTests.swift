import XCTest
@testable import ShelfHead

/// Phase 1, Batch 422: resume / restart / append decisions for a partial transcript.
final class TranscriptionPlanTests: XCTestCase {
    private func transcript(trackCount: Int = 3, completed: [Int] = [], partial: PartialProgress? = nil,
                            segments: [TranscriptSegment] = [], locale: String = "en-US") -> Transcript {
        Transcript(itemId: "li_1", localeIdentifier: locale, trackCount: trackCount, audioSignature: "10.0|20.0|30.0",
                   completedTracks: completed, partial: partial, segments: segments)
    }

    private func seg(_ start: Double, _ end: Double, _ text: String = "x") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    // MARK: resumePoint

    func testResumeFromStart() {
        XCTAssertEqual(TranscriptionPlan.resumePoint(for: transcript()), PartialProgress(trackIndex: 0, secondsInTrack: 0))
    }

    func testResumeAfterCompletedTracks() {
        XCTAssertEqual(TranscriptionPlan.resumePoint(for: transcript(completed: [0, 1])),
                       PartialProgress(trackIndex: 2, secondsInTrack: 0))
    }

    func testResumeSkipsGapInCompletedTracks() {
        XCTAssertEqual(TranscriptionPlan.resumePoint(for: transcript(completed: [0, 2])),
                       PartialProgress(trackIndex: 1, secondsInTrack: 0))
    }

    func testResumeRespectsPartialOnThatTrack() {
        let partial = PartialProgress(trackIndex: 1, secondsInTrack: 321.5)
        XCTAssertEqual(TranscriptionPlan.resumePoint(for: transcript(completed: [0], partial: partial)), partial)
    }

    func testResumeIgnoresPartialForOtherTrack() {
        let partial = PartialProgress(trackIndex: 2, secondsInTrack: 99)
        XCTAssertEqual(TranscriptionPlan.resumePoint(for: transcript(completed: [0], partial: partial)),
                       PartialProgress(trackIndex: 1, secondsInTrack: 0))
    }

    func testResumeNilWhenComplete() {
        XCTAssertNil(TranscriptionPlan.resumePoint(for: transcript(completed: [0, 1, 2])))
        XCTAssertNil(TranscriptionPlan.resumePoint(for: transcript(trackCount: 0)))
    }

    // MARK: mustRestart

    func testMustRestartFalseWhenEverythingMatches() {
        XCTAssertFalse(TranscriptionPlan.mustRestart(transcript(), audioSignature: "10.0|20.0|30.0", trackCount: 3, localeIdentifier: "en-US"))
    }

    func testMustRestartOnEachMismatch() {
        let t = transcript()
        XCTAssertTrue(TranscriptionPlan.mustRestart(t, audioSignature: "other", trackCount: 3, localeIdentifier: "en-US"))
        XCTAssertTrue(TranscriptionPlan.mustRestart(t, audioSignature: "10.0|20.0|30.0", trackCount: 4, localeIdentifier: "en-US"))
        XCTAssertTrue(TranscriptionPlan.mustRestart(t, audioSignature: "10.0|20.0|30.0", trackCount: 3, localeIdentifier: "fr-FR"))
        var old = t
        old.version = Transcript.currentVersion - 1
        XCTAssertTrue(TranscriptionPlan.mustRestart(old, audioSignature: "10.0|20.0|30.0", trackCount: 3, localeIdentifier: "en-US"))
    }

    func testMustRestartIgnoresLocaleSeparatorAndCase() {
        XCTAssertFalse(TranscriptionPlan.mustRestart(transcript(), audioSignature: "10.0|20.0|30.0", trackCount: 3, localeIdentifier: "en_us"))
    }

    // MARK: appending

    func testAppendToEmpty() {
        let result = TranscriptionPlan.appending([seg(0, 1), seg(1, 2)], to: transcript())
        XCTAssertEqual(result.segments.map(\.start), [0, 1])
    }

    func testAppendAfterExistingKeepsEverything() {
        let result = TranscriptionPlan.appending([seg(20, 21)], to: transcript(segments: [seg(0, 5), seg(5, 10)]))
        XCTAssertEqual(result.segments.map(\.start), [0, 5, 20])
    }

    func testAppendDropsOverlappingTail() {
        let existing = transcript(segments: [seg(0, 5), seg(5, 10, "old"), seg(10, 15, "old")])
        let result = TranscriptionPlan.appending([seg(8, 12, "new"), seg(12, 16, "new")], to: existing)
        XCTAssertEqual(result.segments.map(\.start), [0, 5, 8, 12])
        XCTAssertEqual(result.segments.map(\.text), ["x", "old", "new", "new"])
    }

    func testAppendDropsExistingSegmentStartingExactlyAtFirstNewStart() {
        let existing = transcript(segments: [seg(0, 5), seg(5, 10, "old")])
        let result = TranscriptionPlan.appending([seg(5, 9, "new")], to: existing)
        XCTAssertEqual(result.segments.map(\.text), ["x", "new"])
    }

    func testAppendEmptyChangesNothing() {
        let existing = transcript(segments: [seg(0, 5)])
        XCTAssertEqual(TranscriptionPlan.appending([], to: existing), existing)
    }

    func testAppendPreservesOtherFields() {
        let existing = transcript(completed: [0], partial: PartialProgress(trackIndex: 1, secondsInTrack: 4))
        let result = TranscriptionPlan.appending([seg(0, 1)], to: existing)
        XCTAssertEqual(result.completedTracks, [0])
        XCTAssertEqual(result.partial, existing.partial)
        XCTAssertEqual(result.itemId, existing.itemId)
    }
}
