import XCTest
@testable import ShelfHead

/// Batch 445: pins the mood search rule parser, the hard filters and the ranking.
final class MoodSearchTests: XCTestCase {
    private let genres = ["Mystery", "Fantasy", "Science Fiction", "Fiction", "Romance"]

    private func parse(_ text: String) -> MoodQuery {
        MoodRuleParser.parse(text, knownGenres: genres)
    }

    // MARK: Parser

    func testUnderHours() {
        XCTAssertEqual(parse("under 8 hours").maxHours, 8)
        XCTAssertEqual(parse("less than 10.5 hrs").maxHours, 10.5)
        XCTAssertEqual(parse("a book under 5h").maxHours, 5)
    }

    func testOverHours() {
        XCTAssertEqual(parse("over 12 hours").minHours, 12)
        XCTAssertEqual(parse("more than 20 hours").minHours, 20)
    }

    func testBetweenHours() {
        let q = parse("between 4 and 7 hours")
        XCTAssertEqual(q.minHours, 4)
        XCTAssertEqual(q.maxHours, 7)
    }

    func testShortAndLong() {
        XCTAssertEqual(parse("a short one").maxHours, MoodRuleParser.shortHours)
        XCTAssertEqual(parse("something long").minHours, MoodRuleParser.longHours)
    }

    func testExplicitHoursBeatShort() {
        XCTAssertEqual(parse("short, under 3 hours").maxHours, 3)
    }

    func testUnplayed() {
        XCTAssertTrue(parse("an unplayed mystery").unplayedOnly)
        XCTAssertTrue(parse("something new to me").unplayedOnly)
        XCTAssertTrue(parse("books I haven't listened to").unplayedOnly)
        XCTAssertFalse(parse("a mystery").unplayedOnly)
    }

    func testParseStarredNarratorAndAuthor() {
        XCTAssertTrue(parse("by a narrator I've starred").starredNarrator)
        XCTAssertTrue(parse("my favourite narrator").starredNarrator)
        XCTAssertTrue(parse("starred narrators").starredNarrator)
        XCTAssertTrue(parse("an author I starred").starredAuthor)
        XCTAssertFalse(parse("an author I starred").starredNarrator)
    }

    func testGenreDetectionUsesLibraryGenresAndPlurals() {
        XCTAssertEqual(parse("a short unplayed mystery").genres, ["Mystery"])
        XCTAssertEqual(parse("mysteries please").genres, ["Mystery"])
        XCTAssertEqual(parse("some science fiction").genres, ["Science Fiction"])
        XCTAssertEqual(parse("a western").genres, [])
    }

    func testToneWordsAreTheRest() {
        let q = parse("something cosy under 8 hours by a narrator I've starred")
        XCTAssertEqual(q.toneWords, ["cosy"])
        XCTAssertEqual(q.maxHours, 8)
        XCTAssertTrue(q.starredNarrator)
        XCTAssertTrue(q.genres.isEmpty)
    }

    func testLanguage() {
        XCTAssertEqual(parse("a romance in spanish").language, "Spanish")
    }

    func testNothingUnderstoodIsEmpty() {
        XCTAssertTrue(parse("   ").isEmpty)
        XCTAssertTrue(parse("something").isEmpty)
    }

    func testModelMergeKeepsRulesAndOnlyKnownGenres() {
        let rules = parse("under 8 hours")
        let model = MoodQuery(genres: ["mysteries", "Cooking"], toneWords: ["Cosy"], minHours: 2, maxHours: 20,
                              starredNarrator: true)
        let merged = rules.merged(withModel: model, knownGenres: genres)
        XCTAssertEqual(merged.maxHours, 8)
        XCTAssertEqual(merged.minHours, 2)
        XCTAssertEqual(merged.genres, ["Mystery"])
        XCTAssertEqual(merged.toneWords, ["cosy"])
        XCTAssertTrue(merged.starredNarrator)
    }

    // MARK: Filter and rank

    private func book(_ id: String, title: String? = nil, hours: Double = 5, genres: [String] = [],
                      narrator: String? = nil, author: String? = nil, description: String? = nil,
                      language: String? = nil, played: Double? = nil, finished: Bool = false,
                      addedAt: Int? = nil, podcast: Bool = false) -> ShelfHead.LibraryItem {
        let metadata = MediaMetadata(
            title: title ?? id, subtitle: nil, authorName: author, narratorName: narrator,
            seriesName: nil, description: description, publishedYear: nil, publisher: nil,
            language: language, genres: genres, isbn: nil, asin: nil, series: nil)
        let media = Media(metadata: metadata, coverPath: nil, duration: hours * 3600, chapters: nil,
                          audioFiles: nil, numChapters: nil, numAudioFiles: nil, episodes: nil, ebookFile: nil)
        let progress = played.map {
            MediaProgress(id: id, libraryItemId: id, episodeId: nil, duration: hours * 3600, progress: $0,
                          currentTime: $0 * hours * 3600, isFinished: finished, lastUpdate: nil,
                          startedAt: nil, finishedAt: nil)
        }
        return ShelfHead.LibraryItem(id: id, ino: nil, libraryId: nil, mediaType: podcast ? "podcast" : "book",
                                     media: media, numFiles: nil, size: nil, addedAt: addedAt, updatedAt: nil,
                                     mediaProgress: progress)
    }

    private func rank(_ q: MoodQuery, _ items: [ShelfHead.LibraryItem],
                      narrators: Set<String> = [], authors: Set<String> = []) -> [String] {
        MoodFilter.rank(query: q, items: items, progress: { $0.mediaProgress },
                        isStarredNarrator: { narrators.contains($0.lowercased()) },
                        isStarredAuthor: { authors.contains($0.lowercased()) }).map(\.id)
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertEqual(rank(MoodQuery(), [book("a")]), [])
    }

    func testHourFilters() {
        let items = [book("short", hours: 3), book("mid", hours: 8), book("long", hours: 20)]
        XCTAssertEqual(Set(rank(MoodQuery(maxHours: 8), items)), ["short", "mid"])
        XCTAssertEqual(Set(rank(MoodQuery(minHours: 8), items)), ["mid", "long"])
    }

    func testBooksWithoutDurationFailHourFilters() {
        XCTAssertEqual(rank(MoodQuery(maxHours: 8), [book("none", hours: 0)]), [])
    }

    func testUnplayedExcludesStartedAndFinished() {
        let items = [book("fresh"), book("started", played: 0.3), book("done", played: 1, finished: true)]
        XCTAssertEqual(rank(MoodQuery(unplayedOnly: true), items), ["fresh"])
    }

    func testFilterStarredNarratorAndAuthor() {
        let items = [book("a", narrator: "Ray Porter"), book("b", narrator: "Someone Else"),
                     book("c", narrator: "Ray Porter & Jane Doe", author: "Star Author")]
        XCTAssertEqual(Set(rank(MoodQuery(starredNarrator: true), items, narrators: ["ray porter"])), ["a", "c"])
        XCTAssertEqual(rank(MoodQuery(starredAuthor: true), items, authors: ["star author"]), ["c"])
    }

    func testGenreIsHardFilterAndPodcastsAreSkipped() {
        let items = [book("m", genres: ["Mystery"]), book("f", genres: ["Fantasy"]),
                     book("p", genres: ["Mystery"], podcast: true)]
        XCTAssertEqual(rank(MoodQuery(genres: ["Mystery"]), items), ["m"])
    }

    func testLanguageFilter() {
        let items = [book("en", language: "English"), book("es", language: "Spanish"), book("none")]
        XCTAssertEqual(rank(MoodQuery(language: "spanish"), items), ["es"])
    }

    func testToneWordsRankByDescriptionAndRequireAMatchWithoutGenres() {
        let items = [
            book("plain", description: "A grim war story."),
            book("cosy", description: "A cosy village tale, cosy and warm."),
            book("kinda", description: "Somewhat cosy.")
        ]
        let order = rank(MoodQuery(toneWords: ["cosy"]), items)
        XCTAssertEqual(order.first, "cosy")
        XCTAssertFalse(order.contains("plain"))
        XCTAssertEqual(order.count, 2)
    }

    func testToneWordsOnlyReorderWhenGenresArePresent() {
        let items = [
            book("a", genres: ["Mystery"], description: "Grim.", addedAt: 5),
            book("b", genres: ["Mystery"], description: "Cosy cosy cosy.", addedAt: 1)
        ]
        XCTAssertEqual(rank(MoodQuery(genres: ["Mystery"], toneWords: ["cosy"]), items), ["b", "a"])
    }

    func testHardFiltersOnlyOrderNewestFirst() {
        let items = [book("old", addedAt: 1), book("new", addedAt: 9)]
        XCTAssertEqual(rank(MoodQuery(maxHours: 8), items), ["new", "old"])
    }

    func testNothingMatchesReturnsEmptyNotJunk() {
        let items = [book("a", description: "A war story."), book("b", description: "Space opera.")]
        XCTAssertEqual(rank(MoodQuery(toneWords: ["cosy"]), items), [])
        XCTAssertEqual(rank(MoodQuery(minHours: 50), items), [])
    }

    func testReasonsDescribeTheMatch() {
        let items = [book("m", hours: 6, genres: ["Mystery"])]
        let matches = MoodFilter.rank(query: MoodQuery(genres: ["Mystery"], unplayedOnly: true), items: items,
                                      progress: { $0.mediaProgress }, isStarredNarrator: { _ in false },
                                      isStarredAuthor: { _ in false })
        XCTAssertEqual(matches.first?.reasons, [.genre("Mystery"), .duration(6 * 3600), .unplayed])
    }

    func testGenreListMostCommonFirst() {
        let items = [book("a", genres: ["Fantasy"]), book("b", genres: ["Mystery", "Fantasy"])]
        XCTAssertEqual(MoodFilter.genreList(items), ["Fantasy", "Mystery"])
    }
}
