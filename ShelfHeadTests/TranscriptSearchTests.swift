import XCTest
@testable import ShelfHead

/// Batch 424: the pure "search inside the audio" engine. Segments sit 10 s apart
/// (segment i starts at i * 10), so times double as indices in the assertions.
final class TranscriptSearchTests: XCTestCase {
    private func makeIndex(_ texts: [String]) -> TranscriptSearchIndex {
        let segments = texts.enumerated().map { pair in
            TranscriptSegment(start: Double(pair.offset) * 10, end: Double(pair.offset) * 10 + 9, text: pair.element)
        }
        return TranscriptSearchIndex(itemId: "book", segments: segments)
    }

    private func run(_ query: String, _ index: TranscriptSearchIndex, frontier: Double? = nil,
                     includeAhead: Bool = true, limit: Int = 200) -> TranscriptSearchResults {
        TranscriptSearch.search(query, in: index, frontier: frontier, includeAhead: includeAhead, limit: limit)
    }

    private func highlighted(_ hit: TranscriptSearchHit) -> [String] {
        hit.highlights.map { (hit.snippet as NSString).substring(with: $0) }
    }

    private func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Folding

    func testCaseInsensitive() {
        let r = run("LIGHTHOUSE", makeIndex(["The Lighthouse stood alone."]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["Lighthouse"])
    }

    func testDiacriticsFoldBothWays() {
        XCTAssertEqual(run("cafe", makeIndex(["We met at the café."])).hits.count, 1)
        XCTAssertEqual(run("café", makeIndex(["We met at the cafe."])).hits.count, 1)
    }

    func testFullWidthLatinFolds() {
        let r = run("ｈｅｌｌｏ", makeIndex(["well hello there"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["hello"])
    }

    func testSharpSFoldsAndHighlightCoversOriginal() {
        // Folding changes length here (ß -> ss); the highlight must still cover the original word.
        let r = run("strasse", makeIndex(["Die Straße ist lang"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["Straße"])
    }

    func testDecomposedAccentHighlightCoversCombiningMark() {
        let r = run("cafe", makeIndex(["Cafe\u{301} au lait"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["Cafe\u{301}"])
    }

    func testApostrophesAndQuotesAreEqual() {
        XCTAssertEqual(run("don’t", makeIndex(["I don't know"])).hits.count, 1)
        XCTAssertEqual(run("don't", makeIndex(["I don’t know"])).hits.count, 1)
        XCTAssertEqual(run("dont", makeIndex(["I don’t know"])).hits.count, 1)
    }

    func testPunctuationIsIgnoredBetweenWords() {
        let r = run("wait what", makeIndex(["Wait, what? No!"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertGreaterThanOrEqual(r.hits[0].score, 100, "contiguous phrase tier")
    }

    // MARK: Spaced matching

    func testLastWordMatchesAsPrefix() {
        let r = run("lightho", makeIndex(["The lighthouse keeper"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["lightho"])
    }

    func testMidWordIsNotAMatch() {
        XCTAssertTrue(run("house", makeIndex(["The lighthouse keeper"])).hits.isEmpty)
    }

    func testAllWordsAnywhereMatch() {
        XCTAssertEqual(run("lighthouse keeper", makeIndex(["keeper of the lighthouse"])).hits.count, 1)
    }

    func testMissingWordMeansNoMatch() {
        XCTAssertTrue(run("lighthouse dragon", makeIndex(["the lighthouse keeper"])).hits.isEmpty)
    }

    func testPhraseOutranksOrderedScatter() {
        let index = makeIndex(["the old lighthouse keeper waved",
                               "the old man climbed all the way up the lighthouse"])
        let r = run("old lighthouse", index)
        XCTAssertEqual(r.hits.map(\.segmentIndex), [0, 1], "book order, not score order")
        XCTAssertGreaterThan(r.hits[0].score, r.hits[1].score)
    }

    func testOrderedNearbyOutranksAnyOrder() {
        let index = makeIndex(["the lighthouse was very old", "the old man and the lighthouse"])
        let r = run("old lighthouse", index)
        XCTAssertEqual(r.hits.count, 2)
        XCTAssertGreaterThan(r.hits[1].score, r.hits[0].score)
    }

    func testPhraseAcrossSegmentBoundary() {
        let index = makeIndex(["He walked up to the old", "lighthouse and knocked."])
        let r = run("old lighthouse", index)
        XCTAssertEqual(r.hits.count, 1)
        let hit = r.hits[0]
        XCTAssertEqual(hit.segmentIndex, 0)
        XCTAssertEqual(hit.time, 0)
        XCTAssertEqual(hit.snippet, "He walked up to the old lighthouse and knocked.")
        XCTAssertEqual(highlighted(hit), ["old", "lighthouse"])
    }

    func testBoundaryMatchNeedsAdjacentWords() {
        let index = makeIndex(["He walked up to the old", "stone lighthouse"])
        XCTAssertTrue(run("old lighthouse", index).hits.isEmpty)
    }

    // MARK: Spaceless matching

    func testCJKSubstring() {
        let r = run("灯塔", makeIndex(["他走进了灯塔，看见了老人。", "没有关系"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["灯塔"])
    }

    func testCJKIgnoresWhitespaceOnBothSides() {
        let index = makeIndex(["灯 塔 在海边"])
        XCTAssertEqual(run("灯塔", index).hits.count, 1)
        let r = run("灯 塔", index)
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(highlighted(r.hits[0]), ["灯 塔"])
    }

    func testCJKAcrossSegmentBoundary() {
        let r = run("灯塔", makeIndex(["他走进了灯", "塔看见了老人"]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(r.hits[0].segmentIndex, 0)
        XCTAssertEqual(r.hits[0].snippet, "他走进了灯塔看见了老人")
        XCTAssertEqual(highlighted(r.hits[0]), ["灯塔"])
    }

    func testMixedQuery() {
        let r = run("第4章 Harry", makeIndex(["第4章 Harry arrives", "第5章 Ron arrives"]))
        XCTAssertEqual(r.hits.map(\.segmentIndex), [0])
        XCTAssertEqual(highlighted(r.hits[0]), ["第4章 Harry"])
    }

    // MARK: Frontier, limit, order

    func testFrontierHidesAheadMatchesAndCountsThem() {
        let index = makeIndex(["a lighthouse", "the lighthouse again", "another lighthouse"])
        let hidden = run("lighthouse", index, frontier: 10, includeAhead: false)
        XCTAssertEqual(hidden.hits.map(\.segmentIndex), [0, 1], "start == frontier is not ahead")
        XCTAssertEqual(hidden.hiddenAheadCount, 1)

        let shown = run("lighthouse", index, frontier: 10, includeAhead: true)
        XCTAssertEqual(shown.hits.count, 3)
        XCTAssertEqual(shown.hiddenAheadCount, 0)

        let unlimited = run("lighthouse", index, frontier: nil, includeAhead: false)
        XCTAssertEqual(unlimited.hits.count, 3)
        XCTAssertEqual(unlimited.hiddenAheadCount, 0)
    }

    func testHiddenCountIgnoresLimit() {
        let index = makeIndex(Array(repeating: "the lighthouse", count: 6))
        let r = run("lighthouse", index, frontier: 20, includeAhead: false, limit: 2)
        XCTAssertEqual(r.hits.count, 2)
        XCTAssertTrue(r.isTruncated)
        XCTAssertEqual(r.hiddenAheadCount, 3)
    }

    func testLimitAndTruncation() {
        let index = makeIndex(Array(repeating: "the lighthouse", count: 5))
        let capped = run("lighthouse", index, limit: 3)
        XCTAssertEqual(capped.hits.map(\.segmentIndex), [0, 1, 2])
        XCTAssertTrue(capped.isTruncated)
        let exact = run("lighthouse", index, limit: 5)
        XCTAssertEqual(exact.hits.count, 5)
        XCTAssertFalse(exact.isTruncated)
    }

    func testHitsComeBackInBookOrder() {
        let texts = ["old lighthouse", "lighthouse and the old sea", "the old lighthouse keeper", "old lighthouse"]
        let r = run("old lighthouse", makeIndex(texts))
        XCTAssertEqual(r.hits.map(\.segmentIndex), [0, 1, 2, 3])
        XCTAssertEqual(r.hits.map(\.time), r.hits.map(\.time).sorted())
    }

    // MARK: Snippets and highlights

    func testShortSegmentGetsPreviousSegmentAsContext() {
        let r = run("lighthouse", makeIndex(["Previous line here.", "The lighthouse."]))
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(r.hits[0].snippet, "Previous line here. The lighthouse.")
        XCTAssertEqual(highlighted(r.hits[0]), ["lighthouse"])
    }

    func testFirstSegmentHasNoContextToPrepend() {
        let r = run("lighthouse", makeIndex(["The lighthouse.", "Next line."]))
        XCTAssertEqual(r.hits[0].snippet, "The lighthouse.")
    }

    func testHighlightAfterEmojiUsesUTF16Offsets() {
        let r = run("lighthouse", makeIndex(["🎧 Listening to the lighthouse"]))
        XCTAssertEqual(highlighted(r.hits[0]), ["lighthouse"])
    }

    func testLongSegmentIsTrimmedWithEllipsesAroundTheMatch() {
        let filler = String(repeating: "alpha beta gamma delta ", count: 12)
        let text = filler + "lighthouse " + filler
        let r = run("lighthouse", makeIndex([text]))
        let hit = r.hits[0]
        XCTAssertTrue(hit.snippet.hasPrefix("…"))
        XCTAssertTrue(hit.snippet.hasSuffix("…"))
        XCTAssertLessThanOrEqual((hit.snippet as NSString).length, 162)
        XCTAssertEqual(highlighted(hit), ["lighthouse"])
        // Cut at word boundaries: no clipped fragment like "lph" next to the ellipsis.
        let body = hit.snippet.dropFirst().dropLast()
        let words = Set(["alpha", "beta", "gamma", "delta", "lighthouse"])
        XCTAssertTrue(body.split(separator: " ").allSatisfy { words.contains(String($0)) })
    }

    func testMatchNearStartOnlyGetsTrailingEllipsis() {
        let text = "lighthouse " + String(repeating: "alpha beta gamma delta ", count: 12)
        let hit = run("lighthouse", makeIndex([text])).hits[0]
        XCTAssertFalse(hit.snippet.hasPrefix("…"))
        XCTAssertTrue(hit.snippet.hasSuffix("…"))
        XCTAssertEqual(highlighted(hit), ["lighthouse"])
    }

    func testLongCJKSegmentTrimsAnywhere() {
        let text = String(repeating: "他走进了房间", count: 40) + "灯塔" + String(repeating: "看见了老人", count: 40)
        let hit = run("灯塔", makeIndex([text])).hits[0]
        XCTAssertTrue(hit.snippet.hasPrefix("…"))
        XCTAssertTrue(hit.snippet.hasSuffix("…"))
        XCTAssertLessThanOrEqual((hit.snippet as NSString).length, 162)
        XCTAssertEqual(highlighted(hit), ["灯塔"])
    }

    func testHighlightsAreValidAndCoverQueryWords() {
        let filler = String(repeating: "alpha beta gamma delta ", count: 12)
        let texts = ["The OLD Lighthouse keeper", "Old men and old lighthouses", filler + "old " + filler + "lighthouse " + filler,
                     "an old café near the lighthouse"]
        let r = run("old lighthouse", makeIndex(texts))
        XCTAssertEqual(r.hits.count, 4)
        for hit in r.hits {
            let length = (hit.snippet as NSString).length
            XCTAssertFalse(hit.highlights.isEmpty)
            for range in hit.highlights {
                XCTAssertGreaterThanOrEqual(range.location, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(range), length)
                let word = fold((hit.snippet as NSString).substring(with: range))
                XCTAssertTrue("old".hasPrefix(word) || "lighthouse".hasPrefix(word) || word.hasPrefix("old") || word.hasPrefix("lighthouse"),
                              "unexpected highlight \(word)")
            }
        }
    }

    // MARK: bestMatch

    func testBestMatchTieGoesToLatestAndRespectsBefore() {
        let index = makeIndex(["lighthouse keeper", "old lighthouse", "old lighthouse"])
        XCTAssertEqual(TranscriptSearch.bestMatch("old lighthouse", in: index, before: nil)?.segmentIndex, 2)
        XCTAssertEqual(TranscriptSearch.bestMatch("old lighthouse", in: index, before: 10)?.segmentIndex, 1,
                       "start == before is allowed")
        XCTAssertEqual(TranscriptSearch.bestMatch("old lighthouse", in: index, before: 19.9)?.segmentIndex, 1)
        XCTAssertNil(TranscriptSearch.bestMatch("old lighthouse", in: index, before: 5))
    }

    func testBestMatchPrefersHigherScoreOverLater() {
        let index = makeIndex(["old lighthouse", "the lighthouse was old"])
        let best = TranscriptSearch.bestMatch("old lighthouse", in: index, before: nil)
        XCTAssertEqual(best?.segmentIndex, 0)
    }

    func testBestMatchIgnoresLimitCap() {
        var texts = Array(repeating: "the lighthouse", count: 300)
        texts.append("lighthouse")  // shorter segment scores slightly higher, and it is past the 200 cap
        let best = TranscriptSearch.bestMatch("lighthouse", in: makeIndex(texts), before: nil)
        XCTAssertEqual(best?.segmentIndex, 300)
    }

    // MARK: isSearchable and empties

    func testIsSearchableEdges() {
        XCTAssertFalse(TranscriptSearch.isSearchable(""))
        XCTAssertFalse(TranscriptSearch.isSearchable("   "))
        XCTAssertFalse(TranscriptSearch.isSearchable("a"))
        XCTAssertFalse(TranscriptSearch.isSearchable(" a "))
        XCTAssertFalse(TranscriptSearch.isSearchable("1"))
        XCTAssertTrue(TranscriptSearch.isSearchable("ab"))
        XCTAssertTrue(TranscriptSearch.isSearchable("a b"))
        XCTAssertTrue(TranscriptSearch.isSearchable("12"))
        XCTAssertTrue(TranscriptSearch.isSearchable("灯"))
        XCTAssertTrue(TranscriptSearch.isSearchable("あ"))
        XCTAssertTrue(TranscriptSearch.isSearchable("ア"))
        XCTAssertTrue(TranscriptSearch.isSearchable("한"))
    }

    func testEmptyTranscriptAndEmptyQueryReturnEmpty() {
        XCTAssertEqual(run("lighthouse", makeIndex([])), .empty)
        XCTAssertEqual(run("", makeIndex(["the lighthouse"])), .empty)
        XCTAssertEqual(run("l", makeIndex(["the lighthouse"])), .empty)
        XCTAssertEqual(run("lighthouse", makeIndex(["nothing here"])), .empty)
        XCTAssertNil(TranscriptSearch.bestMatch("lighthouse", in: makeIndex([]), before: nil))
    }

    func testIndexBuildsFromTranscript() {
        let transcript = Transcript(itemId: "li_1", localeIdentifier: "en-US", trackCount: 1, audioSignature: "x",
                                    segments: [TranscriptSegment(start: 3, end: 5, text: "The lighthouse.")])
        let index = TranscriptSearchIndex(transcript: transcript)
        XCTAssertEqual(index.itemId, "li_1")
        XCTAssertEqual(index.segmentCount, 1)
        XCTAssertEqual(run("lighthouse", index).hits.first?.time, 3)
    }
}
