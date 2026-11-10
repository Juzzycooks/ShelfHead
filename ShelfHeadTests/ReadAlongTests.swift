import XCTest
@testable import ShelfHead

/// Pins the pure read-along pieces (Batch 431): block extraction, tokenizing, alignment,
/// the transcript-to-ebook map and its lookups. The reader's JavaScript can't run here, so
/// its block rule is pinned against the Swift one by comparing the selector text.
final class ReadAlongTests: XCTestCase {

    // MARK: - Helpers

    private func xhtml(_ body: String, head: String = "<head><title>T</title></head>") -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">\(head)<body>\(body)</body></html>
        """.utf8)
    }

    private func blocks(_ body: String) -> [String] {
        EPUBTextExtractor.blocks(fromXHTML: xhtml(body))
    }

    private func keys(_ text: String) -> [String] {
        ReadAlongTokenizer.tokens(in: text).map(\.key)
    }

    private func seg(_ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, text: text)
    }

    // MARK: - Extractor

    func testExtractorFindsParagraphsInOrder() {
        XCTAssertEqual(blocks("<h1>Title</h1><p>One.</p><p>Two.</p>"), ["Title", "One.", "Two."])
    }

    func testExtractorKeepsOnlyLeafBlocks() {
        let out = blocks("<blockquote><p>Inner one</p><p>Inner two</p></blockquote><ul><li>A</li><li>B<ul><li>C</li></ul></li></ul>")
        XCTAssertEqual(out, ["Inner one", "Inner two", "A", "C"])
    }

    func testExtractorJoinsInlineMarkup() {
        XCTAssertEqual(blocks("<p>Hello <em>big</em> <a href=\"x\">world</a>!<br/>Bye</p>"), ["Hello big world!Bye"])
    }

    func testExtractorIgnoresHeadAndNonBlockText() {
        let data = xhtml("<div>loose text</div><p>Kept</p>", head: "<head><title>Ignore</title><style>p{}</style></head>")
        XCTAssertEqual(EPUBTextExtractor.blocks(fromXHTML: data), ["Kept"])
    }

    func testExtractorMatchesPrefixedAndUppercaseNames() {
        let data = Data("""
        <x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:body><x:P>Hi</x:P><x:li>there</x:li></x:body></x:html>
        """.utf8)
        XCTAssertEqual(EPUBTextExtractor.blocks(fromXHTML: data), ["Hi", "there"])
    }

    func testExtractorDecodesHTMLEntities() {
        let out = blocks("<p>a&nbsp;b &mdash; c&hellip; &amp; &eacute;&lt;</p>")
        XCTAssertEqual(out, ["a\u{A0}b \u{2014} c\u{2026} & \u{E9}<"])
    }

    func testExtractorIncludesCDATA() {
        XCTAssertEqual(blocks("<p>a<![CDATA[<b>]]>c</p>"), ["a<b>c"])
    }

    func testExtractorUTF16LengthsWithEmojiAndCurlyQuotes() {
        let out = blocks("<p>\u{201C}Hi\u{201D} \u{1F600}!</p>")
        XCTAssertEqual(out, ["\u{201C}Hi\u{201D} \u{1F600}!"])
        XCTAssertEqual(out[0].utf16.count, 8)
    }

    func testExtractorReturnsBlocksBeforeParseError() {
        let data = Data("<html><body><p>Good</p><p>Also good</p><p>Broken <b></p></body></html>".utf8)
        XCTAssertEqual(EPUBTextExtractor.blocks(fromXHTML: data), ["Good", "Also good"])
    }

    func testExtractorHandlesGarbageAndEmpty() {
        XCTAssertEqual(EPUBTextExtractor.blocks(fromXHTML: Data()), [])
        XCTAssertEqual(EPUBTextExtractor.blocks(fromXHTML: Data("not xml at all".utf8)), [])
    }

    func testExtractorHandlesBOMAndLatin1Declaration() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><html><body><p>caf\u{E9}</p></body></html>".utf8))
        XCTAssertEqual(EPUBTextExtractor.blocks(fromXHTML: data), ["caf\u{E9}"])
    }

    // MARK: - Tokenizer

    func testTokenizerBasicWordsAndRanges() {
        let toks = ReadAlongTokenizer.tokens(in: "Hello, world! 1984")
        XCTAssertEqual(toks.map(\.key), ["hello", "world", "1984"])
        XCTAssertEqual(toks.map(\.range), [0..<5, 7..<12, 14..<18])
    }

    func testTokenizerKeepsInnerApostrophes() {
        let toks = ReadAlongTokenizer.tokens(in: "don't keeper\u{2019}s 'quoted' rock'n'roll")
        XCTAssertEqual(toks.map(\.key), ["dont", "keepers", "quoted", "rocknroll"])
        XCTAssertEqual(toks[0].range, 0..<5)
        XCTAssertEqual(toks[2].range, 16..<22)
    }

    func testTokenizerFoldsCaseDiacriticsAndWidth() {
        XCTAssertEqual(keys("Caf\u{E9} NA\u{CF}VE \u{FF21}\u{FF22}\u{FF23}"), ["cafe", "naive", "abc"])
        // Decomposed form folds the same as precomposed.
        XCTAssertEqual(keys("cafe\u{301}"), ["cafe"])
        XCTAssertEqual(ReadAlongTokenizer.tokens(in: "cafe\u{301}")[0].range, 0..<5)
    }

    func testTokenizerCJKOneTokenPerCharacter() {
        let toks = ReadAlongTokenizer.tokens(in: "\u{4F60}\u{597D}, ab \u{3053}\u{3093}\u{D55C}")
        XCTAssertEqual(toks.map(\.key), ["\u{4F60}", "\u{597D}", "ab", "\u{3053}", "\u{3093}", "\u{D55C}"])
        XCTAssertEqual(toks[2].range, 4..<6)
    }

    func testTokenizerRangesCountSurrogatePairs() {
        let toks = ReadAlongTokenizer.tokens(in: "\u{1F600} hi \u{20000}x")
        XCTAssertEqual(toks.map(\.key), ["hi", "\u{20000}", "x"])
        XCTAssertEqual(toks[0].range, 3..<5)
        XCTAssertEqual(toks[1].range, 6..<8)
        XCTAssertEqual(toks[2].range, 8..<9)
    }

    func testTokenizerEmptyAndPunctuationOnly() {
        XCTAssertTrue(ReadAlongTokenizer.tokens(in: "").isEmpty)
        XCTAssertTrue(ReadAlongTokenizer.tokens(in: " ... --- ").isEmpty)
    }

    // MARK: - Aligner

    private func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    private func assertMonotonic(_ m: [Int?], file: StaticString = #filePath, line: UInt = #line) {
        var last = -1
        for case let v? in m {
            XCTAssertGreaterThan(v, last, file: file, line: line)
            last = v
        }
    }

    func testAlignIdentical() {
        let a = words("the quick brown fox jumps over the lazy dog")
        XCTAssertEqual(TextAligner.align(a, a), Array(0..<a.count).map { Optional($0) })
    }

    func testAlignEmptyInputs() {
        XCTAssertEqual(TextAligner.align([], ["a"]), [])
        XCTAssertEqual(TextAligner.align(["a", "b"], []), [nil, nil])
    }

    func testAlignHandlesInsertionsAndDeletions() {
        let a = words("one two three four five six seven")
        let b = words("one two XX three four five YY ZZ seven")
        // Insertions in the book.
        XCTAssertEqual(TextAligner.align(a, b), [0, 1, 3, 4, 5, nil, 8])
        // Deletion from the book.
        let m = TextAligner.align(words("a b c d e"), words("a b d e"))
        XCTAssertEqual(m, [0, 1, nil, 2, 3])
    }

    func testAlignSubstitution() {
        let m = TextAligner.align(words("a b c d e"), words("a b X d e"))
        XCTAssertEqual(m, [0, 1, nil, 3, 4])
    }

    func testAlignAudioIntroAbsentFromBook() {
        let intro = words("this is audible dot com presents")
        let body = (0..<40).map { "w\($0)" }
        let m = TextAligner.align(intro + body, body)
        for i in 0..<intro.count { XCTAssertNil(m[i]) }
        for i in 0..<body.count { XCTAssertEqual(m[intro.count + i], i) }
    }

    func testAlignBookFrontMatterAbsentFromAudio() {
        let front = (0..<50).map { "front\($0)" }
        let body = (0..<40).map { "w\($0)" }
        let m = TextAligner.align(body, front + body)
        for i in 0..<body.count { XCTAssertEqual(m[i], front.count + i) }
    }

    func testAlignPartialTranscriptCoversStartOfBook() {
        let book = (0..<500).map { "w\($0 % 97)x\($0)" }
        let a = Array(book[0..<100])
        let m = TextAligner.align(a, book)
        XCTAssertEqual(m, Array(0..<100).map { Optional($0) })
    }

    func testAlignWithRepeatedCommonWordsStaysOnTrack() {
        var book: [String] = []
        for i in 0..<60 { book += ["the", "cat\(i)", "and", "the", "dog\(i)", "of", "the", "rat\(i)"] }
        var a = book
        a.remove(at: 100)
        a.remove(at: 40)
        a.insert("zzz", at: 200)
        let m = TextAligner.align(a, book)
        assertMonotonic(m)
        // Every unique word (catN, dogN, ratN) still present in `a` lands on itself.
        var unique = 0
        for (i, key) in a.enumerated() where key.hasPrefix("cat") || key.hasPrefix("dog") || key.hasPrefix("rat") {
            XCTAssertEqual(m[i].map { book[$0] }, key)
            unique += 1
        }
        XCTAssertGreaterThan(unique, 150)
    }

    func testAlignUsesLCSInGapsWithoutUniqueAnchors() {
        // No unique-in-both words anywhere: only the LCS fallback can match.
        let a = words("x y x y x")
        let b = words("x y y x")
        let m = TextAligner.align(a, b)
        assertMonotonic(m)
        XCTAssertEqual(m.compactMap { $0 }.count, 4)
    }

    func testAlignIsMonotonicOnShuffledNoise() {
        var rng = SystemRandomNumberGenerator()
        let vocab = (0..<30).map { "v\($0)" }
        let a = (0..<300).map { _ in vocab.randomElement(using: &rng)! }
        let b = (0..<320).map { _ in vocab.randomElement(using: &rng)! }
        let m = TextAligner.align(a, b)
        assertMonotonic(m)
        for case let v? in m { XCTAssertTrue((0..<b.count).contains(v)) }
        for (i, v) in m.enumerated() { if let v { XCTAssertEqual(a[i], b[v]) } }
    }

    func testAlignLargeInputIsFast() {
        // 150k tokens each: mostly unique words, ~2% edits, plus a common-word sprinkle.
        let n = 150_000
        var a: [String] = []
        var b: [String] = []
        a.reserveCapacity(n)
        b.reserveCapacity(n + 4000)
        for i in 0..<n {
            let w = i % 7 == 0 ? "the" : "w\(i)"
            if i % 50 != 13 { a.append(w) }
            b.append(w)
            if i % 61 == 5 { b.append("extra\(i)") }
        }
        let start = Date()
        let m = TextAligner.align(a, b)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 20, "alignment of 150k tokens took \(elapsed)s")
        assertMonotonic(m)
        let matched = m.compactMap { $0 }.count
        XCTAssertGreaterThan(matched, a.count * 9 / 10)
        for (i, v) in m.enumerated() where i % 997 == 0 { if let v { XCTAssertEqual(a[i], b[v]) } }
    }

    // MARK: - Builder

    func testBuilderLocatesSegmentsInBlocks() {
        let spine = [
            ["Chapter One", "It was a bright cold day in April.", "The clocks were striking thirteen."],
            ["Winston Smith slipped quickly through the glass doors."],
        ]
        let segments = [
            seg(0, "It was a bright cold day in April."),
            seg(3, "The clocks were striking thirteen."),
            seg(6, "Winston Smith slipped quickly through the glass doors."),
        ]
        let map = ReadAlongMapBuilder.build(segments: segments, spineBlocks: spine, key: "k")
        XCTAssertEqual(map.key, "k")
        XCTAssertEqual(map.locations[0], ReadAlongLocation(spineIndex: 0, startBlock: 1, startOffset: 0, endBlock: 1, endOffset: 34))  // through the full stop
        XCTAssertEqual(map.locations[1], ReadAlongLocation(spineIndex: 0, startBlock: 2, startOffset: 0, endBlock: 2, endOffset: 34))
        XCTAssertEqual(map.locations[2]?.spineIndex, 1)
        XCTAssertEqual(map.blockLengths, [[11, 34, 34], [54]])
        XCTAssertEqual(map.matchedFraction, 1, accuracy: 0.0001)
    }

    func testBuilderSegmentCanSpanBlocks() {
        let spine = [["The old man looked at", "the sea and sighed deeply."]]
        let segments = [seg(0, "The old man looked at the sea and sighed deeply.")]
        let map = ReadAlongMapBuilder.build(segments: segments, spineBlocks: spine, key: "")
        let loc = map.locations[0]
        XCTAssertEqual(loc?.startBlock, 0)
        XCTAssertEqual(loc?.startOffset, 0)
        XCTAssertEqual(loc?.endBlock, 1)
        XCTAssertEqual(loc?.endOffset, 26)  // through the full stop
    }

    func testBuilderUnmatchedSegmentsAreNil() {
        let spine = [["Alpha beta gamma delta epsilon.", "Zeta eta theta iota kappa."]]
        let segments = [
            seg(0, "Alpha beta gamma delta epsilon."),
            seg(3, "Completely different words appear here instead."),
            seg(6, "Zeta eta theta iota kappa."),
        ]
        let map = ReadAlongMapBuilder.build(segments: segments, spineBlocks: spine, key: "")
        XCTAssertNotNil(map.locations[0])
        XCTAssertNotNil(map.locations[2])
        XCTAssertNil(map.locations[1])
        XCTAssertEqual(map.matchedFraction, 10.0 / 16.0, accuracy: 0.0001)
    }

    func testBuilderRejectsSegmentsWithTooFewMatches() {
        // Only one of ten words matches: below 25%.
        let spine = [["alpha one two three four five six seven eight nine ten. beta gamma delta"]]
        let segments = [seg(0, "alpha q1 q2 q3 q4 q5 q6 q7 q8 q9")]
        let map = ReadAlongMapBuilder.build(segments: segments, spineBlocks: spine, key: "")
        XCTAssertNil(map.locations[0])
    }

    func testBuilderDropsFarOutlierMatch() {
        // A segment of 4 words whose first word also appears far earlier in the book.
        var filler = (0..<200).map { "fill\($0)" }.joined(separator: " ")
        filler += " "
        let block = "zebra " + filler + "mango river stone cloud"
        let segments = [seg(0, "zebra mango river stone")]
        // Alignment is monotonic, so "zebra" at the start and the rest at the end both match;
        // the cluster rule keeps the larger group (the last three).
        let map = ReadAlongMapBuilder.build(segments: segments, spineBlocks: [[block]], key: "")
        let loc = map.locations[0]
        XCTAssertNotNil(loc)
        XCTAssertGreaterThan(loc?.startOffset ?? 0, 100)
    }

    func testBuilderEmptyInputs() {
        let map = ReadAlongMapBuilder.build(segments: [], spineBlocks: [["x"]], key: "e")
        XCTAssertEqual(map.locations.count, 0)
        XCTAssertEqual(map.matchedFraction, 0)
        let none = ReadAlongMapBuilder.build(segments: [seg(0, "hello there")], spineBlocks: [], key: "")
        XCTAssertEqual(none.locations.count, 1)
        XCTAssertNil(none.locations[0])
        XCTAssertEqual(none.matchedFraction, 0)
    }

    func testBuilderIntroAndFrontMatterTolerated() {
        let spine = [["Copyright page nobody reads", "Contents of this book listed here"],
                     ["First sentence of the story begins here.", "Second sentence follows right after it."]]
        let segments = [
            seg(0, "Welcome to this audiobook production."),
            seg(3, "First sentence of the story begins here."),
            seg(6, "Second sentence follows right after it."),
        ]
        let map = ReadAlongMapBuilder.build(segments: segments, spineBlocks: spine, key: "")
        XCTAssertEqual(map.locations[1]?.spineIndex, 1)
        XCTAssertEqual(map.locations[1]?.startBlock, 0)
        XCTAssertEqual(map.locations[2]?.startBlock, 1)
    }

    // MARK: - Map lookups

    private func lookupMap() -> ReadAlongMap {
        ReadAlongMap(
            version: 1, key: "k",
            locations: [
                ReadAlongLocation(spineIndex: 0, startBlock: 0, startOffset: 0, endBlock: 0, endOffset: 10),
                nil,
                ReadAlongLocation(spineIndex: 0, startBlock: 1, startOffset: 5, endBlock: 2, endOffset: 4),
                ReadAlongLocation(spineIndex: 1, startBlock: 0, startOffset: 0, endBlock: 0, endOffset: 20),
            ],
            blockLengths: [[10, 30, 30], [20]], matchedFraction: 0.9)
    }

    func testSegmentIndexContains() {
        let m = lookupMap()
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 0, offset: 0), 0)
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 0, offset: 9), 0)
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 1, offset: 5), 2)
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 2, offset: 3), 2)
        XCTAssertEqual(m.segmentIndex(spineIndex: 1, block: 0, offset: 19), 3)
    }

    func testSegmentIndexPicksNextWhenBetween() {
        let m = lookupMap()
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 0, offset: 10), 2)
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 1, offset: 1), 2)
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 2, offset: 4), 3)
    }

    func testSegmentIndexPicksLastWhenAfterEverything() {
        let m = lookupMap()
        XCTAssertEqual(m.segmentIndex(spineIndex: 1, block: 0, offset: 20), 3)
        XCTAssertEqual(m.segmentIndex(spineIndex: 5, block: 0, offset: 0), 3)
    }

    func testSegmentIndexBeforeEverythingPicksFirst() {
        var m = lookupMap()
        m.locations[0] = nil
        XCTAssertEqual(m.segmentIndex(spineIndex: 0, block: 0, offset: 0), 2)
    }

    func testSegmentIndexNilWithoutLocations() {
        let m = ReadAlongMap(version: 1, key: "", locations: [nil, nil], blockLengths: [], matchedFraction: 0)
        XCTAssertNil(m.segmentIndex(spineIndex: 0, block: 0, offset: 0))
        let e = ReadAlongMap(version: 1, key: "", locations: [], blockLengths: [], matchedFraction: 0)
        XCTAssertNil(e.segmentIndex(spineIndex: 0, block: 0, offset: 0))
    }

    func testLocationForSegmentFallsBackToEarlier() {
        let m = lookupMap()
        XCTAssertEqual(m.location(forSegment: 0), m.locations[0])
        XCTAssertEqual(m.location(forSegment: 1), m.locations[0])
        XCTAssertEqual(m.location(forSegment: 3), m.locations[3])
        XCTAssertEqual(m.location(forSegment: 99), m.locations[3])
        XCTAssertNil(m.location(forSegment: -1))
        var lead = lookupMap()
        lead.locations[0] = nil
        XCTAssertNil(lead.location(forSegment: 1))
    }

    // MARK: - Codable, fingerprint, scripts

    func testMapCodableRoundTrip() throws {
        let m = lookupMap()
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(ReadAlongMap.self, from: data), m)
    }

    func testFingerprintChangesWithEachInput() {
        var t = Transcript(itemId: "i", localeIdentifier: "en-US", trackCount: 1, audioSignature: "s",
                           segments: [seg(0, "a"), seg(2, "b")], createdAt: Date(timeIntervalSince1970: 100),
                           updatedAt: Date(timeIntervalSince1970: 1000))
        let base = ReadAlongMapBuilder.fingerprint(transcript: t, ebookByteCount: 500)
        XCTAssertEqual(base, ReadAlongMapBuilder.fingerprint(transcript: t, ebookByteCount: 500))
        XCTAssertNotEqual(base, ReadAlongMapBuilder.fingerprint(transcript: t, ebookByteCount: 501))
        var more = t
        more.segments.append(seg(4, "c"))
        XCTAssertNotEqual(base, ReadAlongMapBuilder.fingerprint(transcript: more, ebookByteCount: 500))
        var covered = t
        covered.segments[1].end = 60
        XCTAssertNotEqual(base, ReadAlongMapBuilder.fingerprint(transcript: covered, ebookByteCount: 500))
        t.updatedAt = Date(timeIntervalSince1970: 2000)
        XCTAssertNotEqual(base, ReadAlongMapBuilder.fingerprint(transcript: t, ebookByteCount: 500))
    }

    func testScriptsAreNonEmptyAndShareTheBlockRule() throws {
        for script in [ReadAlongScript.highlight, ReadAlongScript.clear, ReadAlongScript.locate] {
            XCTAssertFalse(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(script.contains("return"))
        }
        let expected = EPUBTextExtractor.blockTags.joined(separator: ",")
        for script in [ReadAlongScript.highlight, ReadAlongScript.locate] {
            let regex = try NSRegularExpression(pattern: "const SEL = '([^']*)';")
            let range = NSRange(script.startIndex..., in: script)
            let match = try XCTUnwrap(regex.firstMatch(in: script, range: range))
            let tags = (script as NSString).substring(with: match.range(at: 1))
            XCTAssertEqual(tags, expected)
        }
        XCTAssertTrue(ReadAlongScript.highlight.contains("shelfhead-readalong"))
        XCTAssertTrue(ReadAlongScript.clear.contains("shelfhead-readalong"))
    }

    func testEndOffsetTakesInClosingPunctuation() {
        let text = "He said \u{201C}stay.\u{201D} Then left"
        // "stay" ends at UTF-16 offset 13; the full stop and closing quote follow.
        XCTAssertEqual(ReadAlongMapBuilder.extendingOverClosingPunctuation(13, in: text), 15)
        XCTAssertEqual(ReadAlongMapBuilder.extendingOverClosingPunctuation(4, in: "Then left"), 4)
        XCTAssertEqual(ReadAlongMapBuilder.extendingOverClosingPunctuation(3, in: "end"), 3)
        XCTAssertEqual(ReadAlongMapBuilder.extendingOverClosingPunctuation(2, in: "\u{4F60}\u{597D}\u{3002}"), 3)
    }
}
