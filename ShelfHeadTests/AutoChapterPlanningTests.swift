import XCTest
@testable import ShelfHead

/// Batch 427: pure planning for auto-chapters. Generated titles are localised; tests run in English.
final class AutoChapterPlanningTests: XCTestCase {
    private func ch(_ id: Int, _ s: Double, _ e: Double, _ t: String = "T") -> Chapter {
        Chapter(id: id, start: s, end: e, title: t)
    }

    private func seg(_ start: Double, _ text: String, length: Double = 3) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + length, text: text)
    }

    private func cueTitles(_ texts: [String]) -> [String] {
        // Each line sits 100 s after the last, with a 2 s pause before it.
        let segs = texts.enumerated().map { seg(Double($0.offset) * 100 + 2, $0.element) }
        return ChapterCueDetector.cues(in: segs).map(\.title)
    }

    // MARK: Health

    func testHealthIssues() {
        XCTAssertEqual(ChapterHealth.issues(chapters: [], droppedCount: 0, bookDuration: 7200), [.none])
        XCTAssertEqual(ChapterHealth.issues(chapters: [ch(0, 0, 7200)], droppedCount: 0, bookDuration: 7200), [.single])
        XCTAssertEqual(ChapterHealth.issues(chapters: [ch(0, 0, 20000), ch(1, 20000, 21000)], droppedCount: 0, bookDuration: 21000), [.overlong])
        XCTAssertEqual(ChapterHealth.issues(chapters: [ch(0, 0, 3600), ch(1, 3600, 7200)], droppedCount: 2, bookDuration: 7200), [.dropped])
        XCTAssertEqual(ChapterHealth.issues(chapters: [ch(0, 0, 40000)], droppedCount: 1, bookDuration: 40000), [.single, .overlong, .dropped])
    }

    func testHealthyAndShortBooks() {
        XCTAssertEqual(ChapterHealth.issues(chapters: [ch(0, 0, 3600), ch(1, 3600, 7200)], droppedCount: 0, bookDuration: 7200), [])
        XCTAssertEqual(ChapterHealth.issues(chapters: [ch(0, 0, 600)], droppedCount: 0, bookDuration: 600), [])
        XCTAssertEqual(ChapterHealth.issues(chapters: [], droppedCount: 3, bookDuration: 1100), [])
    }

    // MARK: Threshold

    func testThresholdPercentile() {
        let levels = (0..<11).map { Float(-70 + $0 * 5) }   // -70 ... -20
        XCTAssertEqual(SilenceGapFinder.threshold(levels: levels), -55)
    }

    func testThresholdClamps() {
        XCTAssertEqual(SilenceGapFinder.threshold(levels: Array(repeating: -20, count: 10)), -30)
        XCTAssertEqual(SilenceGapFinder.threshold(levels: Array(repeating: -90, count: 10)), -60)
    }

    func testThresholdEmptyAndInfinite() {
        XCTAssertEqual(SilenceGapFinder.threshold(levels: []), -50)
        XCTAssertEqual(SilenceGapFinder.threshold(levels: [-.infinity, -.infinity]), -50)
    }

    // MARK: Gaps

    private func levels(loud a: Int, quiet q: Int, loud b: Int) -> [Float] {
        Array(repeating: -20, count: a) + Array(repeating: -80, count: q) + Array(repeating: -20, count: b)
    }

    func testGapFoundWithOffset() {
        let gaps = SilenceGapFinder.gaps(levels: levels(loud: 5, quiet: 20, loud: 5), windowSeconds: 0.1, offset: 100)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 100.5, accuracy: 1e-6)
        XCTAssertEqual(gaps[0].end, 102.5, accuracy: 1e-6)
        XCTAssertEqual(gaps[0].duration, 2.0, accuracy: 1e-6)
    }

    func testGapShorterThanMinIgnored() {
        XCTAssertTrue(SilenceGapFinder.gaps(levels: levels(loud: 5, quiet: 10, loud: 5), windowSeconds: 0.1, offset: 0).isEmpty)
        XCTAssertEqual(SilenceGapFinder.gaps(levels: levels(loud: 5, quiet: 10, loud: 5), windowSeconds: 0.1, offset: 0, minGap: 1.0).count, 1)
    }

    func testTrailingRunCounts() {
        let gaps = SilenceGapFinder.gaps(levels: levels(loud: 5, quiet: 20, loud: 0), windowSeconds: 0.1, offset: 0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].end, 2.5, accuracy: 1e-6)
    }

    func testNegativeInfinityIsQuiet() {
        let l = Array(repeating: Float(-20), count: 10) + Array(repeating: -Float.infinity, count: 20)
        let gaps = SilenceGapFinder.gaps(levels: l, windowSeconds: 0.1, offset: 0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 1.0, accuracy: 1e-6)
    }

    func testMergeJoinsTouchingAndOverlapping() {
        let merged = SilenceGapFinder.merged([
            SilenceGap(start: 50, end: 52), SilenceGap(start: 10, end: 12),
            SilenceGap(start: 12.04, end: 13), SilenceGap(start: 12.5, end: 15)
        ])
        XCTAssertEqual(merged, [SilenceGap(start: 10, end: 15), SilenceGap(start: 50, end: 52)])
        XCTAssertEqual(SilenceGapFinder.merged([SilenceGap(start: 0, end: 1), SilenceGap(start: 1.2, end: 2)]).count, 2)
    }

    // MARK: Cues

    func testEnglishForms() {
        XCTAssertEqual(cueTitles(["Chapter 4", "chapter four.", "Part Two", "Book III", "CHAPTER TWENTY-ONE", "Chapter twenty one"]),
                       ["Chapter 4", "Chapter Four", "Part Two", "Book III", "Chapter Twenty-One", "Chapter Twenty One"])
    }

    func testStandaloneWords() {
        XCTAssertEqual(cueTitles(["Prologue", "epilogue", "Introduction.", "Foreword", "Preface", "Afterword", "Interlude",
                                  "Acknowledgments", "Acknowledgements", "Author's Note"]),
                       ["Prologue", "Epilogue", "Introduction", "Foreword", "Preface", "Afterword", "Interlude",
                        "Acknowledgments", "Acknowledgements", "Author's Note"])
    }

    func testRomanNumeralsUppercased() {
        XCTAssertEqual(cueTitles(["Chapter XII", "Chapter XL"]), ["Chapter XII", "Chapter XL"])
        XCTAssertEqual(cueTitles(["Chapter IIII"]), [])
        XCTAssertEqual(cueTitles(["Part I think so"]), [])
    }

    func testChineseForms() {
        XCTAssertEqual(cueTitles(["第四章 风雨欲来", "第十二回", "第3节", "序章", "尾声", "第一部"]),
                       ["第四章", "第十二回", "第3节", "序章", "尾声", "第一部"])
        XCTAssertEqual(cueTitles(["第章"]), [])
    }

    func testMidSentenceRejected() {
        XCTAssertEqual(cueTitles(["As I said in chapter four, things changed.", "Chapters are short."]), [])
    }

    func testLongSegmentNeedsPause() {
        let long = "Chapter four was the worst of all of them he thought later"
        let noPause = [seg(0, "He left the room."), seg(3.2, long)]
        XCTAssertTrue(ChapterCueDetector.cues(in: noPause).isEmpty)
        let paused = [seg(0, "He left the room."), seg(5, long)]
        XCTAssertEqual(ChapterCueDetector.cues(in: paused).map(\.title), ["Chapter Four"])
        // The first segment counts as preceded by a pause.
        XCTAssertEqual(ChapterCueDetector.cues(in: [seg(0, long)]).count, 1)
    }

    func testShortSegmentAcceptedWithoutPause() {
        let segs = [seg(0, "He left."), seg(3, "Chapter five, the storm")]
        XCTAssertEqual(ChapterCueDetector.cues(in: segs), [ChapterCue(time: 3, title: "Chapter Five")])
    }

    func testCuesWithin60sDropped() {
        let segs = [seg(10, "Chapter one"), seg(40, "Chapter One"), seg(71, "Chapter two")]
        XCTAssertEqual(ChapterCueDetector.cues(in: segs).map(\.time), [10, 71])
    }

    func testCaseAndDiacritics() {
        XCTAssertEqual(cueTitles(["PRÓLOGUE", "  “Chapter Seven”"]), ["Prólogue", "Chapter Seven"])
    }

    // MARK: Builder

    private func build(duration: Double, server: [Chapter] = [], cues: [ChapterCue] = [], trackStarts: [Double] = [],
                       trackTitles: [String] = [], gaps: [SilenceGap] = []) -> [ChapterSuggestion] {
        ChapterProposalBuilder.suggestions(bookDuration: duration, serverChapters: server, cues: cues,
                                           trackStarts: trackStarts, trackTitles: trackTitles, gaps: gaps)
    }

    func testCueOnlyBook() {
        let s = build(duration: 10800, cues: [ChapterCue(time: 600, title: "Chapter 1"), ChapterCue(time: 4000, title: "Chapter 2"),
                                              ChapterCue(time: 8000, title: "Chapter 3")])
        XCTAssertEqual(s.map(\.start), [0, 600, 4000, 8000])
        XCTAssertEqual(s.map(\.title), ["Opening", "Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(s.map(\.source), [.start, .cue, .cue, .cue])
        XCTAssertEqual(s.map(\.id), [0, 1, 2, 3])
        XCTAssertTrue(s.allSatisfy(\.isIncluded))
    }

    func testFirstCueNearZeroTitlesOpening() {
        let s = build(duration: 10800, cues: [ChapterCue(time: 30, title: "Prologue"), ChapterCue(time: 4000, title: "Chapter 1"),
                                              ChapterCue(time: 8000, title: "Chapter 2")])
        XCTAssertEqual(s.map(\.start), [0, 4000, 8000])
        XCTAssertEqual(s[0].title, "Prologue")
        XCTAssertEqual(s[0].source, .start)
    }

    func testNoAnnouncementsIsOpening() {
        let s = build(duration: 5000)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].title, "Opening")
        XCTAssertEqual(s[0].start, 0)
    }

    func testServerAndCueMerge() {
        let server = [ch(0, 0, 1000, "One"), ch(1, 1000, 2000, "Two"), ch(2, 2000, 3600, "Three")]
        let s = build(duration: 3600, server: server,
                      cues: [ChapterCue(time: 1010, title: "Chapter 2"), ChapterCue(time: 3000, title: "Chapter 3")])
        XCTAssertEqual(s.map(\.start), [0, 1000, 2000, 3000])
        XCTAssertEqual(s.map(\.title), ["One", "Two", "Three", "Chapter 3"])
        XCTAssertEqual(s.map(\.source), [.start, .server, .server, .cue])
    }

    func testSingleAndOverlongServerChaptersIgnored() {
        XCTAssertEqual(build(duration: 7200, server: [ch(0, 0, 7200, "Whole")]).count, 1)
        let server = [ch(0, 0, 50000, "Huge"), ch(1, 50000, 52000, "Small")]
        let s = build(duration: 52000, server: server)
        XCTAssertEqual(s.map(\.start), [0, 50000])
        XCTAssertEqual(s[0].title, "Opening")
    }

    func testSilenceOnlySpacingNearTarget() {
        func gap(endingAt t: Double, _ len: Double) -> SilenceGap { SilenceGap(start: t - len, end: t) }
        var gaps = [gap(endingAt: 1000, 2.0), gap(endingAt: 2700, 6), gap(endingAt: 5400, 6), gap(endingAt: 8100, 6)]
        gaps.append(gap(endingAt: 2900, 3))
        let s = build(duration: 9000, gaps: gaps)
        XCTAssertEqual(s.map(\.start), [0, 2699.5, 5399.5, 8099.5])
        XCTAssertEqual(s.map(\.title), ["Opening", "Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(s.dropFirst().map(\.source), [.silence, .silence, .silence])
    }

    func testSilenceOnlyHonoursMinSpacing() {
        let gaps = stride(from: 100.0, to: 9000, by: 100).map { SilenceGap(start: $0 - 3, end: $0) }
        let s = build(duration: 9000, gaps: gaps)
        for (a, b) in zip(s, s.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.start - a.start, ChapterProposalBuilder.minSpacing)
        }
        XCTAssertGreaterThan(s.count, 2)
    }

    func testTrackTitlesAndGeneratedNames() {
        let s = build(duration: 12000, trackStarts: [0, 4000, 8000], trackTitles: ["Intro.mp3", "The Storm", "Track 3"])
        XCTAssertEqual(s.map(\.start), [0, 4000, 8000])
        XCTAssertEqual(s.map(\.title), ["Opening", "The Storm", "Chapter 1"])
        XCTAssertEqual(s.dropFirst().map(\.source), [.track, .track])
    }

    func testMinSpacingPriority() {
        // A track start 100 s from a cue loses to it; a silence 100 s from a track loses to it.
        let s = build(duration: 12000,
                      cues: [ChapterCue(time: 1100, title: "Chapter 1"), ChapterCue(time: 6000, title: "Chapter 2")],
                      trackStarts: [0, 1000, 9000, 9100], trackTitles: [])
        XCTAssertEqual(s.map(\.start), [0, 1100, 6000, 9000])
        XCTAssertEqual(s.map(\.source), [.start, .cue, .cue, .track])
    }

    func testCueSnapsToPrecedingGap() {
        let s = build(duration: 10000,
                      cues: [ChapterCue(time: 2003, title: "Chapter 1"), ChapterCue(time: 6000, title: "Chapter 2")],
                      gaps: [SilenceGap(start: 1990, end: 1999)])
        XCTAssertEqual(s[1].start, 1998.5, accuracy: 1e-9)
        XCTAssertEqual(s[2].start, 6000)
    }

    func testCueFarFromGapUnchanged() {
        let s = build(duration: 10000, cues: [ChapterCue(time: 2100, title: "Chapter 1"), ChapterCue(time: 6000, title: "Chapter 2")],
                      gaps: [SilenceGap(start: 1990, end: 1999)])
        XCTAssertEqual(s[1].start, 2100)
    }

    // MARK: chapters(from:)

    private func sug(_ id: Int, _ start: Double, _ title: String, included: Bool = true) -> ChapterSuggestion {
        ChapterSuggestion(id: id, start: start, title: title, source: .cue, isIncluded: included)
    }

    func testChaptersFromSuggestions() {
        let result = ChapterProposalBuilder.chapters(from: [
            sug(0, 0, "A"), sug(1, 100, "B"), sug(2, 100.5, "B2"), sug(3, 500, "X", included: false), sug(4, 900, "C")
        ], bookDuration: 1000)
        XCTAssertEqual(result.map(\.start), [0, 100, 900])
        XCTAssertEqual(result.map(\.end), [100, 900, 1000])
        XCTAssertEqual(result.map(\.id), [0, 1, 2])
        XCTAssertEqual(result.map(\.title), ["A", "B", "C"])
    }

    func testEmptyTitleBecomesChapterN() {
        let result = ChapterProposalBuilder.chapters(from: [sug(0, 0, ""), sug(1, 100, "  ")], bookDuration: 1000)
        XCTAssertEqual(result.map(\.title), ["Chapter 1", "Chapter 2"])
    }

    func testFirstChapterAlwaysStartsAtZero() {
        let result = ChapterProposalBuilder.chapters(from: [sug(0, 40, "A"), sug(1, 500, "B")], bookDuration: 1000)
        XCTAssertEqual(result.first?.start, 0)
        XCTAssertTrue(ChapterProposalBuilder.chapters(from: [sug(0, 0, "A", included: false)], bookDuration: 1000).isEmpty)
    }

    // MARK: Nudge

    func testNudgeClamps() {
        let base = [sug(0, 0, "A"), sug(1, 100, "B"), sug(2, 200, "C")]
        XCTAssertEqual(ChapterProposalBuilder.nudged(base, id: 1, by: 5, bookDuration: 1000)[1].start, 105)
        XCTAssertEqual(ChapterProposalBuilder.nudged(base, id: 1, by: -500, bookDuration: 1000)[1].start, 1)
        XCTAssertEqual(ChapterProposalBuilder.nudged(base, id: 1, by: 500, bookDuration: 1000)[1].start, 199)
        XCTAssertEqual(ChapterProposalBuilder.nudged(base, id: 2, by: 5000, bookDuration: 1000)[2].start, 999)
        XCTAssertEqual(ChapterProposalBuilder.nudged(base, id: 0, by: 5, bookDuration: 1000), base)
    }

    // MARK: Override resolver

    private let server = [Chapter(id: 0, start: 0, end: 1000, title: "S1"), Chapter(id: 1, start: 1000, end: 2000, title: "S2")]

    private func override(version: Int = ChapterOverride.currentVersion, chapters: [Chapter]? = nil,
                          signature: String? = nil) -> ChapterOverride {
        ChapterOverride(version: version, itemId: "x",
                        chapters: chapters ?? [Chapter(id: 0, start: 0, end: 2000, title: "Mine")],
                        serverSignature: signature ?? ChapterOverrideResolver.serverSignature(server),
                        savedAt: Date(timeIntervalSince1970: 0))
    }

    func testSignature() {
        XCTAssertEqual(ChapterOverrideResolver.serverSignature(server), "2|2000|2000")
        XCTAssertEqual(ChapterOverrideResolver.serverSignature([]), "0|0|0")
    }

    func testResolveAppliedOverride() {
        let o = override()
        XCTAssertTrue(ChapterOverrideResolver.isApplied(server: server, override: o))
        XCTAssertEqual(ChapterOverrideResolver.resolve(server: server, override: o).map(\.title), ["Mine"])
    }

    func testServerChangeRetiresOverride() {
        let o = override()
        let changed = [Chapter(id: 0, start: 0, end: 2000, title: "S")]
        XCTAssertFalse(ChapterOverrideResolver.isApplied(server: changed, override: o))
        XCTAssertEqual(ChapterOverrideResolver.resolve(server: changed, override: o), changed)
    }

    func testNilEmptyAndOldVersionFallBack() {
        XCTAssertEqual(ChapterOverrideResolver.resolve(server: server, override: nil), server)
        XCTAssertEqual(ChapterOverrideResolver.resolve(server: server, override: override(chapters: [])), server)
        XCTAssertFalse(ChapterOverrideResolver.isApplied(server: server, override: override(version: 0)))
        XCTAssertEqual(ChapterOverrideResolver.resolve(server: server, override: override(version: 0)), server)
    }

    func testOverrideRoundTripsThroughJSON() throws {
        let o = override()
        let data = try JSONEncoder().encode(o)
        XCTAssertEqual(try JSONDecoder().decode(ChapterOverride.self, from: data), o)
    }
}
