import XCTest
@testable import ShelfHead

/// Batch 428: pure planning for book intelligence. Copy tests run in English.
final class BookIntelligencePlanningTests: XCTestCase {
    private func seg(_ start: Double, _ text: String, length: Double = 3) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + length, text: text)
    }

    /// A segment whose text costs exactly `tokens` tokens (4 characters each, latin).
    private func segTokens(_ start: Double, _ tokens: Int) -> TranscriptSegment {
        seg(start, String(repeating: "abcd", count: tokens))
    }

    private func notes(_ index: Int, _ start: Double, _ end: Double, _ summary: String = "S") -> ChunkNotes {
        ChunkNotes(chunkIndex: index, start: start, end: end, sourceHash: "h", summary: summary, entities: [])
    }

    private func chunk(_ index: Int, _ text: String, _ start: Double = 0, _ end: Double = 10) -> TranscriptChunk {
        TranscriptChunk(index: index, start: start, end: end, segmentRange: index..<(index + 1), text: text)
    }

    // MARK: Tokens

    func testTokensLatinCeil() {
        XCTAssertEqual(TokenEstimate.tokens("abcd", spaceless: false), 1)
        XCTAssertEqual(TokenEstimate.tokens("abcde", spaceless: false), 2)
        XCTAssertEqual(TokenEstimate.tokens("a", spaceless: false), 1)
        XCTAssertEqual(TokenEstimate.tokens(String(repeating: "x", count: 400), spaceless: false), 100)
    }

    func testTokensEmpty() {
        XCTAssertEqual(TokenEstimate.tokens("", spaceless: false), 0)
        XCTAssertEqual(TokenEstimate.tokens("", spaceless: true), 0)
    }

    func testTokensSpacelessOnePerCharacter() {
        XCTAssertEqual(TokenEstimate.tokens("你好世界", spaceless: true), 4)
        XCTAssertEqual(TokenEstimate.tokens("你好世界", spaceless: false), 1)
    }

    // MARK: Chunker

    func testChunkerEmpty() {
        let r = TranscriptChunker.chunks(segments: [], spaceless: false, transcriptComplete: true)
        XCTAssertTrue(r.chunks.isEmpty)
        XCTAssertTrue(r.lastIsClosed)
        XCTAssertFalse(TranscriptChunker.chunks(segments: [], spaceless: false, transcriptComplete: false).lastIsClosed)
    }

    func testChunkerSingleChunkUnderBudget() {
        let segs = [seg(0, "Hello there."), seg(3, "General Kenobi.")]
        let r = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        XCTAssertEqual(r.chunks.count, 1)
        XCTAssertEqual(r.chunks[0].segmentRange, 0..<2)
        XCTAssertEqual(r.chunks[0].text, "Hello there. General Kenobi.")
        XCTAssertEqual(r.chunks[0].start, 0)
        XCTAssertEqual(r.chunks[0].end, 6)
        XCTAssertEqual(r.chunks[0].index, 0)
    }

    func testChunkerSplitsAtBudget() {
        // 1,000 + 1,000 = 2,000 fits; the next 1 token spills into chunk 1.
        let segs = [segTokens(0, 1000), segTokens(3, 1000), segTokens(6, 1)]
        let r = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        XCTAssertEqual(r.chunks.map(\.segmentRange), [0..<2, 2..<3])
        XCTAssertEqual(r.chunks.map(\.index), [0, 1])
    }

    func testChunkerExactBudgetStaysTogether() {
        let segs = [segTokens(0, 1500), segTokens(3, 500)]
        let r = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        XCTAssertEqual(r.chunks.count, 1)
    }

    func testChunkerOverBudgetSingleSegmentIsOwnChunk() {
        let segs = [seg(0, "Hi."), segTokens(3, 5000), seg(6, "Bye.")]
        let r = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        XCTAssertEqual(r.chunks.map(\.segmentRange), [0..<1, 1..<2, 2..<3])
    }

    func testChunkerOverBudgetFirstSegmentAlone() {
        let segs = [segTokens(0, 5000)]
        let r = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        XCTAssertEqual(r.chunks.count, 1)
        XCTAssertEqual(r.chunks[0].segmentRange, 0..<1)
    }

    func testChunkerEarlierChunksStableWhenAppended() {
        var segs = (0..<10).map { segTokens(Double($0) * 3, 700) }
        let before = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: false).chunks
        segs += (10..<16).map { segTokens(Double($0) * 3, 700) }
        let after = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: false).chunks
        XCTAssertGreaterThan(after.count, before.count)
        // Every chunk but the previously-last one is unchanged.
        XCTAssertEqual(Array(before.dropLast()), Array(after.prefix(before.count - 1)))
    }

    func testChunkerDeterministic() {
        let segs = (0..<20).map { segTokens(Double($0) * 3, 300) }
        let a = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        let b = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true)
        XCTAssertEqual(a.chunks, b.chunks)
    }

    func testChunkerLastIsClosedFollowsCompleteFlag() {
        let segs = [seg(0, "One.")]
        XCTAssertTrue(TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true).lastIsClosed)
        XCTAssertFalse(TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: false).lastIsClosed)
    }

    func testChunkerSpacelessJoinAndBudget() {
        let segs = [seg(0, "你好"), seg(3, "世界")]
        let r = TranscriptChunker.chunks(segments: segs, spaceless: true, transcriptComplete: true)
        XCTAssertEqual(r.chunks[0].text, "你好世界")
        // 1 token per character: two 1,500-character segments exceed 2,000.
        let long = [seg(0, String(repeating: "字", count: 1500)), seg(3, String(repeating: "字", count: 1500))]
        XCTAssertEqual(TranscriptChunker.chunks(segments: long, spaceless: true, transcriptComplete: true).chunks.count, 2)
        XCTAssertEqual(TranscriptChunker.chunks(segments: long, spaceless: false, transcriptComplete: true).chunks.count, 1)
    }

    func testChunkerCoversEverySegmentOnce() {
        let segs = (0..<37).map { segTokens(Double($0), 400) }
        let chunks = TranscriptChunker.chunks(segments: segs, spaceless: false, transcriptComplete: true).chunks
        XCTAssertEqual(chunks.first?.segmentRange.lowerBound, 0)
        XCTAssertEqual(chunks.last?.segmentRange.upperBound, 37)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.segmentRange.upperBound, b.segmentRange.lowerBound)
        }
    }

    // MARK: Heard

    func testHeardFiltersByEnd() {
        let chunks = [chunk(0, "a", 0, 100), chunk(1, "b", 100, 200), chunk(2, "c", 200, 300)]
        XCTAssertEqual(TranscriptChunker.heard(chunks, frontier: 200).map(\.index), [0, 1])
        XCTAssertEqual(TranscriptChunker.heard(chunks, frontier: 199).map(\.index), [0])
        XCTAssertEqual(TranscriptChunker.heard(chunks, frontier: 50).map(\.index), [])
        XCTAssertEqual(TranscriptChunker.heard(chunks, frontier: 1000).map(\.index), [0, 1, 2])
    }

    // MARK: Chunk Codable

    func testChunkCodableRoundTripAndShape() throws {
        let c = TranscriptChunk(index: 2, start: 1.5, end: 9, segmentRange: 4..<9, text: "hi")
        let data = try JSONEncoder().encode(c)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["lower"] as? Int, 4)
        XCTAssertEqual(json["upper"] as? Int, 9)
        XCTAssertNil(json["segmentRange"])
        XCTAssertEqual(try JSONDecoder().decode(TranscriptChunk.self, from: data), c)
    }

    // MARK: Hash

    func testHashStableAndShape() {
        XCTAssertEqual(NotesCache.hash(""), "cbf29ce484222325")
        XCTAssertEqual(NotesCache.hash("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(NotesCache.hash("hello"), NotesCache.hash("hello"))
        XCTAssertNotEqual(NotesCache.hash("hello"), NotesCache.hash("hellp"))
        let h = NotesCache.hash("some text 你好")
        XCTAssertEqual(h.count, 16)
        XCTAssertEqual(h, h.lowercased())
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    // MARK: Cache validity

    private func cache(version: Int = NotesCache.currentVersion, _ notes: [ChunkNotes]) -> NotesCache {
        NotesCache(version: version, itemId: "li_1", localeIdentifier: "en-US", notes: notes)
    }

    private func noted(_ chunk: TranscriptChunk, hash: String? = nil) -> ChunkNotes {
        ChunkNotes(chunkIndex: chunk.index, start: chunk.start, end: chunk.end,
                   sourceHash: hash ?? NotesCache.hash(chunk.text), summary: "S", entities: [])
    }

    func testCacheValidMatchesIndexAndHash() {
        let chunks = [chunk(0, "alpha"), chunk(1, "beta")]
        let valid = cache([noted(chunks[0]), noted(chunks[1])]).valid(for: chunks)
        XCTAssertEqual(Set(valid.keys), [0, 1])
    }

    func testCacheChangedTextInvalidates() {
        let chunks = [chunk(0, "alpha"), chunk(1, "beta")]
        let stale = cache([noted(chunks[0]), noted(chunks[1])])
        let changed = [chunks[0], chunk(1, "beta changed")]
        XCTAssertEqual(Set(stale.valid(for: changed).keys), [0])
    }

    func testCacheVersionMismatchIsEmpty() {
        let chunks = [chunk(0, "alpha")]
        XCTAssertTrue(cache(version: NotesCache.currentVersion + 1, [noted(chunks[0])]).valid(for: chunks).isEmpty)
        XCTAssertTrue(cache(version: 0, [noted(chunks[0])]).valid(for: chunks).isEmpty)
    }

    func testCacheIgnoresNotesForMissingChunks() {
        let chunks = [chunk(0, "alpha")]
        let extra = noted(chunk(5, "zzz"))
        XCTAssertEqual(Set(cache([noted(chunks[0]), extra]).valid(for: chunks).keys), [0])
        XCTAssertTrue(cache([]).valid(for: chunks).isEmpty)
    }

    func testCacheCodableRoundTrip() throws {
        let c = cache([ChunkNotes(chunkIndex: 0, start: 0, end: 10, sourceHash: "x", summary: "Sum",
                                  entities: [NoteEntity(name: "Ann", kind: .person, note: "the heroine")])])
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(NotesCache.self, from: data), c)
    }

    // MARK: Recap offer

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testOfferWhenAllConditionsMet() {
        let last = now.addingTimeInterval(-4 * 86_400)
        XCTAssertTrue(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 3600, lastOfferedAt: nil))
    }

    func testOfferNeedsLastListened() {
        XCTAssertFalse(RecapPlanner.shouldOffer(lastListened: nil, now: now, frontier: 3600, lastOfferedAt: nil))
    }

    func testOfferBoundaryExactlyThreeDays() {
        let exactly = now.addingTimeInterval(-3 * 86_400)
        let justUnder = now.addingTimeInterval(-3 * 86_400 + 1)
        XCTAssertTrue(RecapPlanner.shouldOffer(lastListened: exactly, now: now, frontier: 3600, lastOfferedAt: nil))
        XCTAssertFalse(RecapPlanner.shouldOffer(lastListened: justUnder, now: now, frontier: 3600, lastOfferedAt: nil))
    }

    func testOfferFrontierBoundary() {
        let last = now.addingTimeInterval(-5 * 86_400)
        XCTAssertFalse(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 600, lastOfferedAt: nil))
        XCTAssertTrue(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 601, lastOfferedAt: nil))
        XCTAssertFalse(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 0, lastOfferedAt: nil))
    }

    func testOfferNotRepeatedSinceLastListen() {
        let last = now.addingTimeInterval(-5 * 86_400)
        // Offered after the last listen, or at the same instant: no.
        XCTAssertFalse(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 3600,
                                                lastOfferedAt: last.addingTimeInterval(60)))
        XCTAssertFalse(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 3600, lastOfferedAt: last))
        // Offered before the last listen (a previous absence): yes.
        XCTAssertTrue(RecapPlanner.shouldOffer(lastListened: last, now: now, frontier: 3600,
                                               lastOfferedAt: last.addingTimeInterval(-86_400)))
    }

    // MARK: recapNotes

    func testRecapNotesEmpty() {
        XCTAssertTrue(RecapPlanner.recapNotes([], frontier: 1000, spaceless: false).isEmpty)
    }

    func testRecapNotesFrontierExcludesUnheard() {
        let all = [notes(0, 0, 100), notes(1, 100, 200), notes(2, 200, 300)]
        XCTAssertEqual(RecapPlanner.recapNotes(all, frontier: 200, spaceless: false).map(\.chunkIndex), [0, 1])
        XCTAssertTrue(RecapPlanner.recapNotes(all, frontier: 50, spaceless: false).isEmpty)
    }

    func testRecapNotesOldestFirstEvenIfInputShuffled() {
        let all = [notes(2, 200, 300), notes(0, 0, 100), notes(1, 100, 200)]
        XCTAssertEqual(RecapPlanner.recapNotes(all, frontier: 300, spaceless: false).map(\.chunkIndex), [0, 1, 2])
    }

    func testRecapNotesBudgetKeepsNewest() {
        let summary = String(repeating: "abcd", count: 100)   // 100 tokens each
        let all = (0..<5).map { notes($0, Double($0) * 100, Double($0 + 1) * 100, summary) }
        let picked = RecapPlanner.recapNotes(all, frontier: 500, spaceless: false, budgetTokens: 250)
        XCTAssertEqual(picked.map(\.chunkIndex), [3, 4])
        let all5 = RecapPlanner.recapNotes(all, frontier: 500, spaceless: false, budgetTokens: 500)
        XCTAssertEqual(all5.map(\.chunkIndex), [0, 1, 2, 3, 4])
    }

    func testRecapNotesSpacelessCountsCharacters() {
        let summary = String(repeating: "字", count: 100)
        let all = (0..<3).map { notes($0, Double($0) * 10, Double($0 + 1) * 10, summary) }
        XCTAssertEqual(RecapPlanner.recapNotes(all, frontier: 30, spaceless: true, budgetTokens: 250).count, 2)
        XCTAssertEqual(RecapPlanner.recapNotes(all, frontier: 30, spaceless: false, budgetTokens: 250).count, 3)
    }

    // MARK: recapPrompt

    func testRecapPromptFormat() {
        let n = [notes(0, 0, 754, "Ann meets Bo."), notes(1, 754, 3725, "They flee.")]
        let prompt = RecapPlanner.recapPrompt(title: "The Book", author: "A. Writer", notes: n)
        XCTAssertEqual(prompt, """
        Book: The Book
        Author: A. Writer

        Part 1 (0:00–12:34): Ann meets Bo.
        Part 2 (12:34–1:02:05): They flee.
        """)
    }

    func testRecapPromptOmitsEmptyAuthor() {
        let prompt = RecapPlanner.recapPrompt(title: "T", author: "  ", notes: [notes(0, 0, 60, "X")])
        XCTAssertFalse(prompt.contains("Author:"))
        XCTAssertTrue(prompt.hasPrefix("Book: T\n\nPart 1"))
    }

    func testTimestampFormats() {
        XCTAssertEqual(RecapPlanner.timestamp(0), "0:00")
        XCTAssertEqual(RecapPlanner.timestamp(59.9), "0:59")
        XCTAssertEqual(RecapPlanner.timestamp(3599), "59:59")
        XCTAssertEqual(RecapPlanner.timestamp(3600), "1:00:00")
        XCTAssertEqual(RecapPlanner.timestamp(-5), "0:00")
    }

    // MARK: Zoned out

    func testZonedOutWindowSelectsOverlap() {
        let segs = [seg(0, "far"), seg(100, "in"), seg(290, "mid"), seg(500, "now"), seg(900, "later")]
        let p = ZonedOutPlanner.passage(segments: segs, time: 600, spaceless: false)
        // Window is [300, 600]: "mid" ends at 293 (out), "now" starts 500 (in), "later" starts 900 (out).
        XCTAssertEqual(p?.text, "now")
        XCTAssertEqual(p?.start, 500)
        XCTAssertEqual(p?.end, 503)
    }

    func testZonedOutIncludesSegmentStraddlingWindowStart() {
        let segs = [seg(298, "straddle"), seg(310, "inside")]
        let p = ZonedOutPlanner.passage(segments: segs, time: 600, spaceless: false)
        XCTAssertEqual(p?.start, 298)
        XCTAssertEqual(p?.text, "straddle inside")
    }

    func testZonedOutEmpty() {
        XCTAssertNil(ZonedOutPlanner.passage(segments: [], time: 100, spaceless: false))
        XCTAssertNil(ZonedOutPlanner.passage(segments: [seg(1000, "x")], time: 100, spaceless: false))
        XCTAssertNil(ZonedOutPlanner.passage(segments: [seg(0, "x")], time: 1000, spaceless: false))
    }

    func testZonedOutTrimsFromFront() {
        let segs = (0..<10).map { segTokens(Double($0) * 10, 100) }   // 1,000 tokens
        let p = ZonedOutPlanner.passage(segments: segs, time: 100, spaceless: false, budgetTokens: 350)
        // Keeps the last three (300 tokens): starts at segment 7.
        XCTAssertEqual(p?.start, 70)
        XCTAssertEqual(p?.end, 93)
        XCTAssertLessThanOrEqual(TokenEstimate.tokens(p?.text ?? "", spaceless: false), 350)
    }

    func testZonedOutKeepsLastSegmentEvenIfOverBudget() {
        let segs = [seg(0, "small"), segTokens(10, 5000)]
        let p = ZonedOutPlanner.passage(segments: segs, time: 20, spaceless: false, budgetTokens: 100)
        XCTAssertEqual(p?.start, 10)
        XCTAssertEqual(p?.end, 13)
    }

    func testZonedOutSpacelessJoin() {
        let segs = [seg(0, "你好"), seg(3, "世界")]
        XCTAssertEqual(ZonedOutPlanner.passage(segments: segs, time: 10, spaceless: true)?.text, "你好世界")
    }

    func testZonedOutSegmentStartingAtTimeExcluded() {
        let segs = [seg(0, "before"), seg(100, "at")]
        XCTAssertEqual(ZonedOutPlanner.passage(segments: segs, time: 100, spaceless: false)?.text, "before")
    }

    // MARK: Unavailable

    private let allReasons: [IntelligenceUnavailable] = [
        .osTooOld, .deviceNotEligible, .appleIntelligenceOff, .modelNotReady, .noTranscript, .notHeardYet,
        .rateLimited, .unsupportedLanguage, .refused, .contextTooLarge, .timedOut, .failed
    ]

    func testMessagesNonEmptyUniqueSingleLine() {
        let messages = allReasons.map(\.message)
        for m in messages {
            XCTAssertFalse(m.isEmpty)
            XCTAssertEqual(m, m.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(m.contains("\n"))
        }
        XCTAssertEqual(Set(messages).count, allReasons.count)
    }

    func testMessageCopy() {
        XCTAssertEqual(IntelligenceUnavailable.appleIntelligenceOff.message,
                       "Turn on Apple Intelligence in Settings to use this.")
        XCTAssertEqual(IntelligenceUnavailable.noTranscript.message, "Transcribe this book first.")
        XCTAssertEqual(IntelligenceUnavailable.notHeardYet.message, "Listen a little further first.")
    }

    func testRetryableSet() {
        let retryable = allReasons.filter(\.isRetryable)
        XCTAssertEqual(Set(retryable.map(\.message)),
                       Set([IntelligenceUnavailable.rateLimited, .timedOut, .failed, .modelNotReady].map(\.message)))
        XCTAssertEqual(retryable.count, 4)
    }
}
