import XCTest
@testable import ShelfHead

/// Batch 433: pure planning for the narrator "Previously On…" montage.
final class RecapProgramPlanningTests: XCTestCase {
    private func seg(_ start: Double, _ text: String, length: Double = 4) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + length, text: text)
    }

    private func note(_ index: Int, _ start: Double, _ end: Double, summary: String = "S",
                      hash: String = "h", entities: [String] = []) -> ChunkNotes {
        ChunkNotes(chunkIndex: index, start: start, end: end, sourceHash: hash + "\(index)", summary: summary,
                   entities: entities.map { NoteEntity(name: $0, kind: .person, note: "") })
    }

    private func cand(_ id: Int, chunk: Int = 0, start: Double = 0, end: Double = 4, text: String = "Some words here.",
                      rank: Int = 0, chunkEnd: Double = 100) -> RecapMomentCandidate {
        RecapMomentCandidate(id: id, chunkIndex: chunk, start: start, end: end, text: text, rank: rank,
                             chunkEnd: chunkEnd)
    }

    private let sentenceA = "Holden found the letter hidden under the old floorboard"
    private let sentenceB = "The rain kept falling on the quiet empty street outside"
    private let sentenceC = "Naomi quietly decided to leave the ship before the morning"

    // MARK: Candidates

    func testCandidatesStayInsideTheirChunkAndRankMatchesFirst() {
        let segs = [seg(0, sentenceB), seg(4, sentenceA), seg(8, sentenceC),
                    seg(12, sentenceB), seg(16, sentenceA)]
        let n = note(0, 0, 12, summary: "Holden found a letter under the floorboard.", entities: ["Holden"])
        let c = RecapProgramPlanner.candidates(notes: [n], segments: segs, spaceless: false, perChunk: 1)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].start, 4)
        XCTAssertEqual(c[0].id, 1)
        XCTAssertEqual(c[0].rank, 0)
        XCTAssertEqual(c[0].chunkEnd, 12)
        XCTAssertTrue(c.allSatisfy { $0.start >= 0 && $0.end <= 12 })
    }

    func testCandidatesIdsAreInBookOrderAcrossChunks() {
        let segs = [seg(0, sentenceA), seg(4, sentenceB), seg(8, sentenceA), seg(12, sentenceC)]
        let notes = [note(0, 0, 8, summary: "Holden letter"), note(1, 8, 16, summary: "Naomi ship")]
        let c = RecapProgramPlanner.candidates(notes: notes, segments: segs, spaceless: false, perChunk: 2)
        XCTAssertEqual(c.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(c.map(\.chunkIndex), [0, 0, 1, 1])
        XCTAssertEqual(c.map(\.start), c.map(\.start).sorted())
    }

    func testHeadingAndShortSegmentsAreSkipped() {
        let segs = [seg(0, "Chapter 3."), seg(4, "Chapter three: the long road home"), seg(8, "Yes."),
                    seg(12, sentenceA)]
        let n = note(0, 0, 16, summary: "Holden letter")
        let c = RecapProgramPlanner.candidates(notes: [n], segments: segs, spaceless: false)
        XCTAssertEqual(c.map(\.start), [12])
    }

    func testCJKScoringAndLengthRules() {
        let match = "霍尔登在地板下面发现了一封被藏起来的旧信件"
        let other = "窗外的雨一直下个不停街道上空无一人"
        let segs = [seg(0, "第三章"), seg(4, "好的。"), seg(8, other), seg(12, match)]
        let n = note(0, 0, 16, summary: "霍尔登发现了一封旧信件。")
        let c = RecapProgramPlanner.candidates(notes: [n], segments: segs, spaceless: true, perChunk: 1)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].start, 12)
    }

    func testHeadingDetection() {
        XCTAssertTrue(RecapProgramPlanner.isHeading("Chapter 3.", spaceless: false))
        XCTAssertTrue(RecapProgramPlanner.isHeading("Prologue", spaceless: false))
        XCTAssertTrue(RecapProgramPlanner.isHeading("第三章", spaceless: true))
        XCTAssertFalse(RecapProgramPlanner.isHeading(sentenceA, spaceless: false))
    }

    // MARK: Clip range

    func testClipRangeExtendsToMinimumWithoutExceedingMax() {
        let segs = (0..<8).map { seg(Double($0) * 3, sentenceA, length: 3) }
        let c = cand(1, start: 0, end: 3, chunkEnd: 24)
        let r = RecapProgramPlanner.clipRange(for: c, segments: segs, minLength: 6, maxLength: 20)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 6)
        let capped = RecapProgramPlanner.clipRange(for: c, segments: segs, minLength: 30, maxLength: 10)
        XCTAssertLessThanOrEqual(capped.duration, 10)
        XCTAssertGreaterThanOrEqual(capped.duration, 9)
    }

    func testClipRangeDoesNotCrossChunkEnd() {
        let segs = (0..<8).map { seg(Double($0) * 3, sentenceA, length: 3) }
        let c = cand(1, start: 3, end: 6, chunkEnd: 9)
        let r = RecapProgramPlanner.clipRange(for: c, segments: segs, minLength: 12, maxLength: 20)
        XCTAssertEqual(r.start, 3)
        XCTAssertEqual(r.end, 9)
    }

    func testClipRangeLongSingleSegmentStaysAsIs() {
        let segs = [seg(0, sentenceA, length: 30), seg(30, sentenceB, length: 5)]
        let r = RecapProgramPlanner.clipRange(for: cand(1, start: 0, end: 30, chunkEnd: 40), segments: segs)
        XCTAssertEqual(r, ClipRange(start: 0, end: 30))
    }

    // MARK: Prompt

    func testPromptListsSummariesAndMoments() {
        let prompt = RecapProgramPlanner.scriptPrompt(
            title: "T", author: "A", notes: [note(0, 0, 60, summary: "First part.")],
            candidates: [cand(1, start: 5, text: "Hello there my friend again."), cand(2, start: 65)])
        XCTAssertTrue(prompt.hasPrefix("Book: T\nAuthor: A"))
        XCTAssertTrue(prompt.contains("Part 1 (0:00–1:00): First part."))
        XCTAssertTrue(prompt.contains("Moments:"))
        XCTAssertTrue(prompt.contains("[1] (0:05) Hello there my friend again."))
    }

    func testPromptWithinBudgetDropsLowestRankedCandidatesFirst() {
        let long = String(repeating: "abcd ", count: 60)
        let cands = (1...6).map { cand($0, start: Double($0), text: long, rank: $0 == 4 ? 5 : 0) }
        let notes = [note(0, 0, 60, summary: "Old."), note(1, 60, 120, summary: "New.")]
        let budget = 320
        let fitted = RecapProgramPlanner.fit(title: "T", author: "", notes: notes, candidates: cands,
                                             budgetTokens: budget)
        XCTAssertLessThan(fitted.candidates.count, 6)
        XCTAssertFalse(fitted.candidates.contains { $0.id == 4 })
        let prompt = RecapProgramPlanner.scriptPrompt(title: "T", author: "", notes: notes, candidates: cands,
                                                      budgetTokens: budget)
        XCTAssertLessThanOrEqual(TokenEstimate.tokens(prompt, spaceless: false), budget)
    }

    func testPromptDropsOldestSummariesOnlyAfterCandidates() {
        let long = String(repeating: "abcd ", count: 80)
        let cands = [cand(1, text: long), cand(2, text: long)]
        let notes = [note(0, 0, 60, summary: String(repeating: "word ", count: 100)),
                     note(1, 60, 120, summary: "Newest.")]
        let fitted = RecapProgramPlanner.fit(title: "T", author: "", notes: notes, candidates: cands,
                                             budgetTokens: 150)
        XCTAssertEqual(fitted.candidates.count, 2)
        XCTAssertEqual(fitted.notes.map(\.chunkIndex), [1])
    }

    // MARK: Beats

    func testBeatsDropBadAndDuplicateNumbersAndSortByTime() {
        let cands = [cand(1, start: 10), cand(2, start: 20), cand(3, start: 30)]
        let beats = RecapProgramPlanner.beats(
            fromModel: [("c", 3), ("x", 9), ("a", 1), ("dup", 3), ("zero", 0)], candidates: cands)
        XCTAssertEqual(beats.map(\.candidate.id), [1, 3])
        XCTAssertEqual(beats.map(\.line), ["a", "c"])
    }

    func testBeatsCapAtMax() {
        let cands = (1...8).map { cand($0, start: Double($0)) }
        let beats = RecapProgramPlanner.beats(fromModel: (1...8).map { ("l", $0) }, candidates: cands, maxBeats: 4)
        XCTAssertEqual(beats.count, 4)
    }

    func testFallbackPicksMostRecentChunksBestCandidate() {
        let notes = (0..<4).map { note($0, Double($0) * 10, Double($0) * 10 + 10, summary: "Part \($0) happened. Then more.") }
        let cands = [cand(1, chunk: 0, start: 1), cand(2, chunk: 1, start: 11, rank: 1),
                     cand(3, chunk: 1, start: 12, rank: 0), cand(4, chunk: 2, start: 21), cand(5, chunk: 3, start: 31)]
        let beats = RecapProgramPlanner.fallbackBeats(notes: notes, candidates: cands, maxBeats: 3)
        XCTAssertEqual(beats.map(\.candidate.id), [3, 4, 5])
        XCTAssertEqual(beats[0].line, "Part 1 happened.")
    }

    // MARK: Program

    func testProgramInterleavesSpeechOnlyWithSpokenLinks() {
        let segs = [seg(0, sentenceA, length: 7), seg(10, sentenceB, length: 7)]
        let beats = [("Earlier, a letter.", cand(1, start: 0, end: 7, text: sentenceA, chunkEnd: 20)),
                     ("Then the rain.", cand(2, start: 10, end: 17, text: sentenceB, chunkEnd: 20))]
        let with = RecapProgramPlanner.program(itemId: "i", summary: "S", beats: beats, segments: segs,
                                               spokenLinks: true, madeThrough: 20, inputHash: "h")
        XCTAssertEqual(with.items.count, 4)
        XCTAssertEqual(with.items[0], .speech("Earlier, a letter."))
        XCTAssertEqual(with.items[1], .clip(start: 0, end: 7, text: sentenceA))
        let without = RecapProgramPlanner.program(itemId: "i", summary: "S", beats: beats, segments: segs,
                                                  spokenLinks: false, madeThrough: 20, inputHash: "h")
        XCTAssertEqual(without.items.count, 2)
        XCTAssertFalse(without.spokenLinks)
        XCTAssertEqual(without.madeThrough, 20)
        XCTAssertEqual(without.version, RecapProgram.currentVersion)
    }

    func testProgramClipsNeverOverlapTheNextChosenMoment() {
        // Simulator, Batch 433: a short first moment stretched to the 6 s minimum ran into the second
        // chosen moment, so its sentence played twice.
        let segs = [seg(11, sentenceB, length: 5), seg(16, sentenceA, length: 6), seg(22, sentenceC, length: 7)]
        let beats = [("", cand(0, start: 11, end: 16)), ("", cand(1, start: 16, end: 22)),
                     ("", cand(2, start: 16, end: 22)), ("", cand(3, start: 22, end: 29))]
        let p = RecapProgramPlanner.program(itemId: "i", summary: "S", beats: beats, segments: segs,
                                            spokenLinks: false, madeThrough: 29, inputHash: "h")
        let ranges: [(Double, Double)] = p.items.compactMap {
            if case let .clip(start, end, _) = $0 { return (start, end) } else { return nil }
        }
        XCTAssertEqual(ranges.map(\.0), [11, 16, 22])
        XCTAssertEqual(ranges.map(\.1), [16, 22, 29])
    }

    func testProgramWithNoBeatsIsTheSpokenSummary() {
        let p = RecapProgramPlanner.program(itemId: "i", summary: "The story so far.", beats: [], segments: [],
                                            spokenLinks: false, madeThrough: 5, inputHash: "h")
        XCTAssertEqual(p.items, [.speech("The story so far.")])
    }

    // MARK: Input hash

    func testInputHashChangesWithLinksAndNotes() {
        let a = [note(0, 0, 10), note(1, 10, 20)]
        let base = RecapProgramPlanner.inputHash(notes: a, spokenLinks: false)
        XCTAssertEqual(base, RecapProgramPlanner.inputHash(notes: a, spokenLinks: false))
        XCTAssertNotEqual(base, RecapProgramPlanner.inputHash(notes: a, spokenLinks: true))
        XCTAssertNotEqual(base, RecapProgramPlanner.inputHash(notes: [note(0, 0, 10), note(1, 10, 20, hash: "z")],
                                                              spokenLinks: false))
        XCTAssertNotEqual(base, RecapProgramPlanner.inputHash(notes: [note(1, 10, 20)], spokenLinks: false))
    }
}
