import XCTest
@testable import ShelfHead

/// Batch 429: pure planning for X-Ray and Ask the Book.
final class BookKnowledgePlanningTests: XCTestCase {
    private func seg(_ start: Double, _ text: String, length: Double = 3) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + length, text: text)
    }

    private func ent(_ name: String, _ kind: NoteEntityKind = .person, _ note: String = "n") -> NoteEntity {
        NoteEntity(name: name, kind: kind, note: note)
    }

    private func notes(_ index: Int, _ start: Double, _ end: Double, _ entities: [NoteEntity] = [],
                       summary: String = "S") -> ChunkNotes {
        ChunkNotes(chunkIndex: index, start: start, end: end, sourceHash: "h", summary: summary, entities: entities)
    }

    // MARK: Key

    func testKeyFoldsCaseAndDiacritics() {
        XCTAssertEqual(EntityMerger.key("  Café   Noir "), "cafe noir")
        XCTAssertEqual(EntityMerger.key("HOLDEN"), "holden")
    }

    func testKeyStripsLeadingArticle() {
        XCTAssertEqual(EntityMerger.key("The Rocinante"), "rocinante")
        XCTAssertEqual(EntityMerger.key("A Dog"), "dog")
        XCTAssertEqual(EntityMerger.key("An Ocean"), "ocean")
        XCTAssertEqual(EntityMerger.key("Another"), "another")
        XCTAssertEqual(EntityMerger.key("The"), "the")
    }

    func testKeyStripsPossessive() {
        XCTAssertEqual(EntityMerger.key("Holden's"), "holden")
        XCTAssertEqual(EntityMerger.key("Holden\u{2019}s"), "holden")
        XCTAssertEqual(EntityMerger.key("The King's"), "king")
    }

    func testKeyCJKOnlyTrimmed() {
        XCTAssertEqual(EntityMerger.key(" 北京 "), "北京")
    }

    // MARK: Merger

    func testMergeCaseDiacriticArticle() {
        let n = [notes(0, 0, 10, [ent("The Café", .place), ent("Holden")]),
                 notes(1, 10, 20, [ent("cafe", .place), ent("HOLDEN's")])]
        let r = EntityMerger.merge(n, frontier: 100)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.first { $0.id == "cafe" }?.mentionCount, 2)
        XCTAssertEqual(r.first { $0.id == "holden" }?.mentionCount, 2)
    }

    func testMergeDisplayNameMostFrequentSpelling() {
        let n = [notes(0, 0, 10, [ent("Holden")]), notes(1, 10, 20, [ent("holden")]), notes(2, 20, 30, [ent("holden")])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100).first?.name, "holden")
    }

    func testMergeDisplayNameTieGoesToLongest() {
        let n = [notes(0, 0, 10, [ent("Holden")]), notes(1, 10, 20, [ent("Holden's")])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100).first?.name, "Holden's")
    }

    func testMergeSingleWordIntoLastWord() {
        let n = [notes(0, 0, 10, [ent("James Holden")]), notes(1, 10, 20, [ent("Holden")])]
        let r = EntityMerger.merge(n, frontier: 100)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].name, "James Holden")
        XCTAssertEqual(r[0].mentionCount, 2)
    }

    func testMergeSingleWordIntoFirstWord() {
        let n = [notes(0, 0, 10, [ent("James Holden")]), notes(1, 10, 20, [ent("James")])]
        let r = EntityMerger.merge(n, frontier: 100)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].id, "james holden")
    }

    func testMergeAmbiguousSingleWordStaysSeparate() {
        let n = [notes(0, 0, 10, [ent("James Holden"), ent("James Bond")]), notes(1, 10, 20, [ent("James")])]
        let r = EntityMerger.merge(n, frontier: 100)
        XCTAssertEqual(r.count, 3)
        XCTAssertNotNil(r.first { $0.id == "james" })
    }

    func testMergeSameChunkNamingBothCountsOnce() {
        let n = [notes(0, 0, 10, [ent("James Holden"), ent("Holden")])]
        let r = EntityMerger.merge(n, frontier: 100)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].mentionCount, 1)
    }

    func testMergeFrontierFiltersNotes() {
        let n = [notes(0, 0, 10, [ent("Amos")]), notes(1, 10, 20, [ent("Naomi")])]
        let r = EntityMerger.merge(n, frontier: 15)
        XCTAssertEqual(r.map(\.id), ["amos"])
        XCTAssertEqual(EntityMerger.merge(n, frontier: 20).count, 2)
    }

    func testMergeNotesLimitAndDistinctOldestFirst() {
        var n: [ChunkNotes] = []
        for i in 0..<6 { n.append(notes(i, Double(i) * 10, Double(i) * 10 + 10, [ent("Amos", .person, "note \(i)")])) }
        n.append(notes(6, 60, 70, [ent("Amos", .person, "NOTE 0")]))
        let r = EntityMerger.merge(Array(n.reversed()), frontier: 1_000)
        XCTAssertEqual(r[0].notes, ["note 0", "note 1", "note 2", "note 3"])
        XCTAssertEqual(r[0].mentionCount, 7)
    }

    func testMergeDistinctNotesDedupes() {
        let n = [notes(0, 0, 10, [ent("Amos", .person, "Big")]), notes(1, 10, 20, [ent("Amos", .person, "big")])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100)[0].notes, ["Big"])
    }

    func testMergeSkipsEmptyNotes() {
        let n = [notes(0, 0, 10, [ent("Amos", .person, "  ")])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100)[0].notes, [])
    }

    func testMergeFirstMention() {
        let n = [notes(1, 10, 20, [ent("Amos")]), notes(0, 0, 10, [ent("Amos")])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100)[0].firstMention, 0)
        let m = [notes(0, 0, 10), notes(1, 10, 20, [ent("Amos")])]
        XCTAssertEqual(EntityMerger.merge(m, frontier: 100)[0].firstMention, 10)
    }

    func testMergeMajorityKind() {
        let n = [notes(0, 0, 10, [ent("Eros", .place)]), notes(1, 10, 20, [ent("Eros", .person)]),
                 notes(2, 20, 30, [ent("Eros", .place)])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100)[0].kind, .place)
    }

    func testMergeKindTiePrefersPersonThenPlace() {
        let a = [notes(0, 0, 10, [ent("X", .term)]), notes(1, 10, 20, [ent("X", .person)])]
        XCTAssertEqual(EntityMerger.merge(a, frontier: 100)[0].kind, .person)
        let b = [notes(0, 0, 10, [ent("X", .term)]), notes(1, 10, 20, [ent("X", .place)])]
        XCTAssertEqual(EntityMerger.merge(b, frontier: 100)[0].kind, .place)
    }

    func testMergeSortOrder() {
        let n = [notes(0, 0, 10, [ent("Zed", .term), ent("Bea", .person), ent("Ann", .person), ent("Mars", .place)]),
                 notes(1, 10, 20, [ent("Bea", .person), ent("Mars", .place)])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100).map(\.name), ["Bea", "Ann", "Mars", "Zed"])
    }

    func testMergeEmptyNamesIgnored() {
        let n = [notes(0, 0, 10, [ent("  "), ent("Amos")])]
        XCTAssertEqual(EntityMerger.merge(n, frontier: 100).map(\.id), ["amos"])
    }

    // MARK: Passages

    func testPassagesGroupToTarget() {
        // 40 characters = 10 tokens each; target 25 fits two per passage.
        let segs = (0..<5).map { seg(Double($0) * 3, String(repeating: "abcd", count: 10)) }
        let p = PassageBuilder.passages(segments: segs, frontier: 100, spaceless: false, targetTokens: 25)
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0].start, 0)
        XCTAssertEqual(p[0].end, 6)
        XCTAssertEqual(p[2].text, String(repeating: "abcd", count: 10))
    }

    func testPassagesNeverSplitOversizedSegment() {
        let big = String(repeating: "abcd", count: 50)
        let p = PassageBuilder.passages(segments: [seg(0, "hi"), seg(3, big), seg(6, "yo")], frontier: 100,
                                        spaceless: false, targetTokens: 10)
        XCTAssertEqual(p.map(\.text), ["hi", big, "yo"])
    }

    func testPassagesFrontierExcludesLaterSegments() {
        let segs = [seg(0, "one"), seg(3, "two"), seg(6, "three")]
        let p = PassageBuilder.passages(segments: segs, frontier: 6, spaceless: false)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].text, "one two")
        XCTAssertEqual(p[0].end, 6)
    }

    func testPassagesSpacelessJoinsWithoutSeparator() {
        let p = PassageBuilder.passages(segments: [seg(0, "你好"), seg(3, "世界")], frontier: 100, spaceless: true)
        XCTAssertEqual(p.map(\.text), ["你好世界"])
    }

    func testPassagesEmptyAndBlank() {
        XCTAssertTrue(PassageBuilder.passages(segments: [], frontier: 100, spaceless: false).isEmpty)
        XCTAssertTrue(PassageBuilder.passages(segments: [seg(0, "  ")], frontier: 100, spaceless: false).isEmpty)
    }

    // MARK: BM25 tokens

    func testTokensLatinFoldsAndSplits() {
        XCTAssertEqual(BM25.tokens("Café Noir, Holden!"), ["cafe", "noir", "holden"])
    }

    func testTokensDropStopwords() {
        XCTAssertEqual(BM25.tokens("The ship of the captain"), ["ship", "captain"])
    }

    func testTokensApostropheSplitsAndDropsSingleLetters() {
        XCTAssertEqual(BM25.tokens("Holden's ship"), ["holden", "ship"])
    }

    func testTokensKeepNumbers() {
        XCTAssertEqual(BM25.tokens("chapter 7"), ["chapter", "7"])
    }

    func testTokensCJKBigrams() {
        XCTAssertEqual(BM25.tokens("你好世界"), ["你好", "好世", "世界"])
    }

    func testTokensCJKSingleCharacterRun() {
        XCTAssertEqual(BM25.tokens("他 ship"), ["他", "ship"])
    }

    func testTokensEmpty() {
        XCTAssertEqual(BM25.tokens(""), [])
        XCTAssertEqual(BM25.tokens("the of a"), [])
    }

    // MARK: BM25 rank

    func testRankExactTermBeatsUnrelated() {
        let docs = ["Amos fixed the engine", "A quiet walk in the park", "Holden spoke to the captain"]
        XCTAssertEqual(BM25.rank(query: "Who is Holden?", documents: docs, k: 5), [2])
    }

    func testRankOrdersByRelevance() {
        let docs = ["engine", "engine engine broken", "nothing here", "engine fixed by Amos"]
        let r = BM25.rank(query: "engine", documents: docs, k: 5)
        XCTAssertEqual(Set(r), [0, 1, 3])
        XCTAssertEqual(r.first, 0)
    }

    func testRankLimitK() {
        let docs = ["ship one", "ship two", "ship three"]
        XCTAssertEqual(BM25.rank(query: "ship", documents: docs, k: 2).count, 2)
        XCTAssertTrue(BM25.rank(query: "ship", documents: docs, k: 0).isEmpty)
    }

    func testRankTiesByIndex() {
        XCTAssertEqual(BM25.rank(query: "ship", documents: ["ship", "ship"], k: 5), [0, 1])
    }

    func testRankEmptyQueryOrDocuments() {
        XCTAssertTrue(BM25.rank(query: "", documents: ["a b"], k: 3).isEmpty)
        XCTAssertTrue(BM25.rank(query: "the of", documents: ["the of"], k: 3).isEmpty)
        XCTAssertTrue(BM25.rank(query: "ship", documents: [], k: 3).isEmpty)
    }

    func testRankRareTermWeighsMore() {
        let docs = ["ship ship ship", "ship captain", "ship"]
        XCTAssertEqual(BM25.rank(query: "captain ship", documents: docs, k: 3).first, 1)
    }

    func testRankCJK() {
        let docs = ["今天天气很好", "他去了北京旅行", "没有关系"]
        XCTAssertEqual(BM25.rank(query: "北京", documents: docs, k: 3), [1])
    }

    // MARK: Ask context

    private func passage(_ start: Double, _ text: String) -> Passage {
        Passage(start: start, end: start + 10, text: text)
    }

    func testContextBookOrderNotRankOrder() {
        let ps = [passage(0, "ship captain ship"), passage(10, "unrelated"), passage(20, "captain")]
        let c = AskPlanner.context(question: "captain", passages: ps, notes: [], spaceless: false)
        XCTAssertEqual(c.map(\.start), [0, 20])
    }

    func testContextBudgetKeepsBestSkipsTooBig() {
        let best = passage(0, "captain " + String(repeating: "abcd", count: 5))   // 7 tokens
        let big = passage(10, "captain " + String(repeating: "abcd", count: 40))  // too big
        let small = passage(20, "captain")                                         // 2 tokens
        let c = AskPlanner.context(question: "captain", passages: [big, small, best], notes: [], spaceless: false,
                                   budgetTokens: 10)
        XCTAssertFalse(c.contains(big))
        XCTAssertTrue(c.contains(best))
        XCTAssertTrue(c.contains(small))
    }

    func testContextTotalWithinBudget() {
        let ps = (0..<20).map { passage(Double($0) * 10, "captain " + String(repeating: "abcd", count: 10)) }
        let c = AskPlanner.context(question: "captain", passages: ps, notes: [], spaceless: false, budgetTokens: 60)
        let total = c.reduce(0) { $0 + TokenEstimate.tokens($1.text, spaceless: false) }
        XCTAssertLessThanOrEqual(total, 60)
        XCTAssertFalse(c.isEmpty)
    }

    func testContextEmptyWhenNothingMatches() {
        XCTAssertTrue(AskPlanner.context(question: "dragon", passages: [passage(0, "ship")], notes: [],
                                         spaceless: false).isEmpty)
    }

    func testContextAddsAtMostTwoOverlappingNoteSummaries() {
        let ps = [passage(100, "captain Holden")]
        let ns = [notes(0, 0, 90, summary: "far"), notes(1, 95, 105, summary: "first"),
                  notes(2, 105, 115, summary: "second"), notes(3, 108, 120, summary: "third")]
        let c = AskPlanner.context(question: "captain", passages: ps, notes: ns, spaceless: false)
        XCTAssertEqual(c.map(\.text), ["first", "captain Holden", "second"])
        XCTAssertEqual(c[0].start, 95)
        XCTAssertEqual(c[0].end, 105)
    }

    func testContextNoteSummariesCountInBudget() {
        let ps = [passage(0, "captain")]   // 2 tokens
        let ns = [notes(0, 0, 10, summary: String(repeating: "abcd", count: 20))]
        let c = AskPlanner.context(question: "captain", passages: ps, notes: ns, spaceless: false, budgetTokens: 10)
        XCTAssertEqual(c.map(\.text), ["captain"])
    }

    // MARK: Prompt

    func testPromptFormat() {
        let ctx = [Passage(start: 65, end: 70, text: "First."), Passage(start: 3725, end: 3730, text: "Second.")]
        let p = AskPlanner.prompt(title: "Leviathan Wakes", author: "James S. A. Corey", question: "Who?", context: ctx)
        XCTAssertEqual(p, """
        Book: Leviathan Wakes
        Author: James S. A. Corey

        [1] (1:05) First.
        [2] (1:02:05) Second.

        Question: Who?
        """)
    }

    func testPromptOmitsBlankAuthor() {
        let p = AskPlanner.prompt(title: "T", author: "  ", question: "Q", context: [])
        XCTAssertEqual(p, "Book: T\n\n\nQuestion: Q")
    }

    // MARK: Citations

    func testCitationsSingleAndList() {
        XCTAssertEqual(AskPlanner.citations(in: "He did it [3]. Also [1, 4].", passageCount: 5), [2, 0, 3])
    }

    func testCitationsOutOfRangeDropped() {
        XCTAssertEqual(AskPlanner.citations(in: "A [0] B [2] C [9]", passageCount: 3), [1])
    }

    func testCitationsDeduped() {
        XCTAssertEqual(AskPlanner.citations(in: "[2] and [2], [1, 2]", passageCount: 3), [1, 0])
    }

    func testCitationsNone() {
        XCTAssertEqual(AskPlanner.citations(in: "No markers (1) here, [a]", passageCount: 3), [])
    }

    // MARK: Display text

    func testDisplayTextRemovesMarkers() {
        XCTAssertEqual(AskPlanner.displayText("He did it [3]. Also [1, 4]."), "He did it. Also.")
    }

    func testDisplayTextMidSentenceAndLeading() {
        XCTAssertEqual(AskPlanner.displayText("[1] Start of it [2] and end"), "Start of it and end")
    }

    func testDisplayTextKeepsNonCitationBrackets() {
        XCTAssertEqual(AskPlanner.displayText("See [a] and (2)"), "See [a] and (2)")
    }

    // MARK: Batch 432: aliases, mentions, profile planning

    private func entry(_ name: String = "James Holden", aliases: [String]? = nil, notes: [String] = ["A captain"]) -> XRayEntry {
        XRayEntry(id: EntityMerger.key(name), name: name, kind: .person, notes: Array(notes.prefix(4)),
                  firstMention: 0, mentionCount: 1, aliases: aliases ?? [name], allNotes: notes)
    }

    func testMergeFillsAliasesByFrequency() {
        let n = [notes(0, 0, 10, [ent("James Holden")]), notes(1, 10, 20, [ent("Holden")]),
                 notes(2, 20, 30, [ent("Holden")]), notes(3, 30, 40, [ent("Jim Holden")])]
        let r = EntityMerger.merge(n, frontier: 100)
        // "Holden" folds into the single multi-word match only when unambiguous; here two multi-word entries
        // share the surname, so it stays separate.
        XCTAssertEqual(r.first { $0.id == "james holden" }?.aliases, ["James Holden"])
        let m = EntityMerger.merge([notes(0, 0, 10, [ent("James Holden")]), notes(1, 10, 20, [ent("Holden")]),
                                    notes(2, 20, 30, [ent("Holden")])], frontier: 100)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(Set(m[0].aliases), ["James Holden", "Holden"])
        XCTAssertEqual(m[0].aliases.first, "Holden")   // 2 mentions beat 1
    }

    func testMergeAllNotesUncappedButNotesCapped() {
        let n = (0..<6).map { notes($0, Double($0) * 10, Double($0) * 10 + 10, [ent("Ann", .person, "note \($0)")]) }
        let r = EntityMerger.merge(n, frontier: 1_000)[0]
        XCTAssertEqual(r.notes.count, 4)
        XCTAssertEqual(r.allNotes.count, 6)
        XCTAssertEqual(Array(r.allNotes.prefix(4)), r.notes)
    }

    func testMentionsUnionInBookOrder() {
        let segs = [seg(0, "Holden walked in."), seg(10, "Nothing here at all."), seg(20, "Jim Holden spoke."),
                    seg(30, "Then Jim left.")]
        let index = TranscriptSearchIndex(itemId: "x", segments: segs)
        let e = entry(aliases: ["James Holden", "Jim", "Holden"])
        let m = XRayMentionFinder.mentions(for: e, in: index, frontier: 1_000)
        XCTAssertEqual(m.map(\.segmentIndex), [0, 2, 3])
        XCTAssertEqual(m.map(\.time), [0, 20, 30])
    }

    func testMentionsNeverPastFrontier() {
        let segs = [seg(0, "Holden here."), seg(100, "Holden there."), seg(200, "Holden again.")]
        let index = TranscriptSearchIndex(itemId: "x", segments: segs)
        let m = XRayMentionFinder.mentions(for: entry("Holden"), in: index, frontier: 100)
        XCTAssertEqual(m.map(\.segmentIndex), [0, 1])
    }

    func testMentionsEmptyWithoutMatches() {
        let index = TranscriptSearchIndex(itemId: "x", segments: [seg(0, "Quiet.")])
        XCTAssertTrue(XRayMentionFinder.mentions(for: entry("Holden"), in: index, frontier: 100).isEmpty)
    }

    func testSampleIndicesKeepsHeadAndTail() {
        let idx = XRayProfilePlanner.sampleIndices(total: 100, count: 10)
        XCTAssertEqual(idx.count, 10)
        XCTAssertEqual(Array(idx.prefix(3)), [0, 1, 2])
        XCTAssertEqual(Array(idx.suffix(3)), [97, 98, 99])
        XCTAssertEqual(idx, idx.sorted())
        XCTAssertEqual(Set(idx).count, 10)
    }

    func testSampleIndicesAllWhenCountCoversTotal() {
        XCTAssertEqual(XRayProfilePlanner.sampleIndices(total: 4, count: 10), [0, 1, 2, 3])
        XCTAssertEqual(XRayProfilePlanner.sampleIndices(total: 0, count: 3), [])
    }

    func testSampleIndicesMiddleIsStrictlyBetweenAndDistinct() {
        let idx = XRayProfilePlanner.sampleIndices(total: 12, count: 11)
        XCTAssertEqual(idx.count, 11)
        XCTAssertEqual(Set(idx).count, 11)
    }

    private func manyMentions(_ n: Int, length: Int = 200) -> [XRayMention] {
        (0..<n).map { XRayMention(segmentIndex: $0, time: Double($0) * 10,
                                  snippet: "m\($0) " + String(repeating: "x", count: length)) }
    }

    func testPromptFitsBudgetAndKeepsFirstAndRecent() {
        let mentions = manyMentions(300)
        let prompt = XRayProfilePlanner.prompt(entry: entry(), mentions: mentions, spaceless: false)
        XCTAssertLessThanOrEqual(prompt.count, XRayProfilePlanner.spacedBudgetChars)
        XCTAssertTrue(prompt.contains("m0 "))
        XCTAssertTrue(prompt.contains("m299 "))
        XCTAssertTrue(prompt.contains("Name: James Holden"))
        XCTAssertTrue(prompt.contains("Kind: person"))
    }

    func testPromptCJKBudgetIsSmaller() {
        let mentions = manyMentions(300, length: 100)
        let spaced = XRayProfilePlanner.prompt(entry: entry(), mentions: mentions, spaceless: false)
        let cjk = XRayProfilePlanner.prompt(entry: entry(), mentions: mentions, spaceless: true)
        XCTAssertLessThanOrEqual(cjk.count, XRayProfilePlanner.spacelessBudgetChars)
        XCTAssertLessThan(cjk.count, spaced.count)
        XCTAssertTrue(cjk.contains("m0 "))
        XCTAssertTrue(cjk.contains("m299 "))
    }

    func testPromptIncludesAllNotesWithinBudget() {
        let e = entry(notes: (0..<10).map { "distinct note \($0)" })
        let prompt = XRayProfilePlanner.prompt(entry: e, mentions: [], spaceless: false)
        XCTAssertTrue(prompt.contains("distinct note 9"))
        XCTAssertFalse(prompt.contains("Passages"))
    }

    func testInputHashStableAndChangesWithInput() {
        let a = XRayProfilePlanner.prompt(entry: entry(), mentions: manyMentions(5), spaceless: false)
        let a2 = XRayProfilePlanner.prompt(entry: entry(), mentions: manyMentions(5), spaceless: false)
        let b = XRayProfilePlanner.prompt(entry: entry(), mentions: manyMentions(6), spaceless: false)
        XCTAssertEqual(XRayProfilePlanner.inputHash(a), XRayProfilePlanner.inputHash(a2))
        XCTAssertNotEqual(XRayProfilePlanner.inputHash(a), XRayProfilePlanner.inputHash(b))
    }

    func testProfileCacheHitMissAndCap() {
        var c = XRayProfileCache.empty(itemId: "i", localeIdentifier: "en-US")
        c.store(id: "a", hash: "h1", text: "One")
        XCTAssertEqual(c.profile(for: "a", hash: "h1"), "One")
        XCTAssertNil(c.profile(for: "a", hash: "h2"))
        c.store(id: "a", hash: "h2", text: "Two")
        XCTAssertEqual(c.records.count, 1)
        XCTAssertEqual(c.profile(for: "a", hash: "h2"), "Two")
        for i in 0..<(XRayProfileCache.capacity + 20) { c.store(id: "e\(i)", hash: "h", text: "t") }
        XCTAssertEqual(c.records.count, XRayProfileCache.capacity)
        XCTAssertNil(c.profile(for: "a", hash: "h2"))
    }
}
