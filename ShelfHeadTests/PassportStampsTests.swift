import XCTest
@testable import ShelfHead

final class PassportStampsTests: XCTestCase {
    private func date(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }

    private func book(_ id: String, day: Int, genres: [String] = [], narrators: [String] = [],
                      year: Int? = nil, narratorName: String? = nil) -> FinishedBook {
        FinishedBook(id: id, title: "T\(id)", author: "A", narratorName: narratorName, narrators: narrators,
                     genres: genres, publishedYear: year, finishedAt: date(day), duration: 0, coverPath: nil)
    }

    func testGenreNormalisationAndDedupe() {
        let books = [book("1", day: 1, genres: ["Fantasy", " fantasy ", "Sci  Fi"]),
                     book("2", day: 2, genres: ["FANTASY"])]
        let genres = PassportStamps.stamps(.genre, in: PassportStamps.stamps(from: books))
        XCTAssertEqual(genres.count, 2)
        let fantasy = genres.first { $0.key == "fantasy" }
        XCTAssertEqual(fantasy?.count, 2)
        XCTAssertEqual(fantasy?.name, "Fantasy")
        XCTAssertEqual(genres.first { $0.key == "sci fi" }?.name, "Sci Fi")
    }

    func testNarratorStampsAndFallbackSplit() {
        let books = [book("1", day: 1, narrators: ["Jim Dale"]),
                     book("2", day: 2, narratorName: "Jim Dale, Stephen Fry")]
        let n = PassportStamps.stamps(.narrator, in: PassportStamps.stamps(from: books))
        XCTAssertEqual(Set(n.map(\.name)), ["Jim Dale", "Stephen Fry"])
        XCTAssertEqual(n.first { $0.name == "Jim Dale" }?.count, 2)
    }

    func testDecadeBucketing() {
        let books = [book("1", day: 1, year: 1899), book("2", day: 2, year: 1990), book("3", day: 3, year: 1999),
                     book("4", day: 4, year: nil)]
        let d = PassportStamps.stamps(.decade, in: PassportStamps.stamps(from: books))
        XCTAssertEqual(Set(d.map(\.name)), ["1890s", "1990s"])
        XCTAssertEqual(d.first { $0.name == "1990s" }?.count, 2)
    }

    func testEarnedAtIsEarliestRegardlessOfInputOrder() {
        let books = [book("late", day: 9, genres: ["Horror"]), book("early", day: 3, genres: ["Horror"])]
        let s = PassportStamps.stamps(.genre, in: PassportStamps.stamps(from: books))[0]
        XCTAssertEqual(s.earnedAt, date(3))
        XCTAssertEqual(s.earnedByBookID, "early")
        XCTAssertEqual(s.latestAt, date(9))
    }

    func testNewestEarnedFirstWithinKind() {
        let books = [book("1", day: 1, genres: ["A"]), book("2", day: 5, genres: ["B"])]
        let g = PassportStamps.stamps(.genre, in: PassportStamps.stamps(from: books))
        XCTAssertEqual(g.map(\.name), ["B", "A"])
    }

    func testMilestoneThresholds() {
        XCTAssertTrue(PassportStamps.stamps(from: []).isEmpty)
        let four = (1...4).map { book("\($0)", day: $0) }
        XCTAssertEqual(PassportStamps.stamps(.milestone, in: PassportStamps.stamps(from: four)).map(\.key), ["1"])
        let ten = (1...10).map { book("\($0)", day: $0) }
        let m = PassportStamps.stamps(.milestone, in: PassportStamps.stamps(from: ten))
        XCTAssertEqual(Set(m.map(\.key)), ["1", "5", "10"])
        XCTAssertEqual(m.first { $0.key == "5" }?.earnedAt, date(5))
        XCTAssertEqual(m.first { $0.key == "10" }?.earnedByBookID, "10")
    }

    func testSummaryMostBooksWins() {
        let books = [book("1", day: 1, genres: ["A"], narrators: ["X"]),
                     book("2", day: 2, genres: ["B"], narrators: ["Y"]),
                     book("3", day: 3, genres: ["B"], narrators: ["Y"])]
        let s = PassportStamps.summary(books)
        XCTAssertEqual(s.topGenre, "B")
        XCTAssertEqual(s.favouriteNarrator, "Y")
    }

    func testSummaryTieGoesToMostRecent() {
        let books = [book("1", day: 1, genres: ["A"], narrators: ["X"]),
                     book("2", day: 8, genres: ["B"], narrators: ["Y"])]
        let s = PassportStamps.summary(books)
        XCTAssertEqual(s.topGenre, "B")
        XCTAssertEqual(s.favouriteNarrator, "Y")
        XCTAssertEqual(PassportStamps.summary([]), PassportSummary())
    }
}
