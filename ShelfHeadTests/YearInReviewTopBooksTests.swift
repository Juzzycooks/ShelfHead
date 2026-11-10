import XCTest
@testable import ShelfHead

// Critique 2026-10-06 (shape → bolder): pins the pure pieces behind Year in Review's new
// hero and top-covers row — the most-played ranking built from the year's sessions, the
// hero figure's split ("212" + "hours"), and the cover tile's VoiceOver label.
final class YearInReviewTopBooksTests: XCTestCase {

    private func session(_ id: String = UUID().uuidString, item: String?, title: String? = nil,
                         author: String? = nil, listened: Double, duration: Double? = nil) -> ListeningSession {
        ListeningSession(id: id, libraryItemId: item, displayTitle: title, displayAuthor: author,
                         duration: duration, timeListening: listened, currentTime: nil,
                         startedAt: nil, updatedAt: 1_780_000_000_000)
    }

    // MARK: - Ranking

    func testRanksBooksByTotalListeningAcrossSessions() {
        let ranked = YearInReviewView.rankedBooks(from: [
            session(item: "a", title: "Alpha", listened: 3600),
            session(item: "b", title: "Bravo", listened: 5000),
            session(item: "a", title: "Alpha", listened: 3600),   // a = 7200 total
            session(item: "c", title: "Charlie", listened: 100)
        ])
        XCTAssertEqual(ranked.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ranked.first?.seconds, 7200)
    }

    func testClampsASessionToTheBookDuration() {
        // A corrupted 10-hour session on a 1-hour book counts as 1 hour.
        let ranked = YearInReviewView.rankedBooks(from: [
            session(item: "a", title: "Short", listened: 36_000, duration: 3600),
            session(item: "b", title: "Long", listened: 5000)
        ])
        XCTAssertEqual(ranked.map(\.id), ["b", "a"])
        XCTAssertEqual(ranked.last?.seconds, 3600)
    }

    func testSkipsSessionsWithNoItemIdAndBooksWithNoListening() {
        let ranked = YearInReviewView.rankedBooks(from: [
            session(item: nil, title: "Orphan", listened: 9999),
            session(item: "", title: "Empty id", listened: 9999),
            session(item: "z", title: "Opened only", listened: 0),
            session(item: "a", title: "Alpha", listened: 60)
        ])
        XCTAssertEqual(ranked.map(\.id), ["a"])
    }

    func testTiesBreakByTitleThenId() {
        let ranked = YearInReviewView.rankedBooks(from: [
            session(item: "2", title: "Same", listened: 600),
            session(item: "x", title: "Beta", listened: 600),
            session(item: "1", title: "Same", listened: 600),
            session(item: "y", title: "Alpha", listened: 600)
        ])
        XCTAssertEqual(ranked.map(\.id), ["y", "x", "1", "2"])
    }

    func testFillsTitleAndAuthorFromAnySessionOfTheBook() {
        let ranked = YearInReviewView.rankedBooks(from: [
            session(item: "a", title: nil, author: "  ", listened: 60),
            session(item: "a", title: "Alpha", author: "Jane Doe", listened: 60)
        ])
        XCTAssertEqual(ranked.first?.title, "Alpha")
        XCTAssertEqual(ranked.first?.author, "Jane Doe")
    }

    func testEmptySessionsRankNothing() {
        XCTAssertTrue(YearInReviewView.rankedBooks(from: []).isEmpty)
    }

    // MARK: - Hero figure

    func testHeroFigureIsWholeHours() {
        let figure = YearInReviewView.heroFigure(totalSeconds: 212 * 3600 + 40 * 60)
        XCTAssertEqual(figure.value, "212")
        XCTAssertEqual(figure.unit, "hours")
    }

    func testHeroFigureSingularHour() {
        let figure = YearInReviewView.heroFigure(totalSeconds: 3600 + 59 * 60)
        XCTAssertEqual(figure.value, "1")
        XCTAssertEqual(figure.unit, "hour")
    }

    func testHeroFigureFallsBackToMinutesUnderAnHour() {
        let figure = YearInReviewView.heroFigure(totalSeconds: 45 * 60)
        XCTAssertEqual(figure.value, "45")
        XCTAssertEqual(figure.unit, "minutes")
        XCTAssertEqual(YearInReviewView.heroFigure(totalSeconds: 60).unit, "minute")
    }

    func testHeroFigureNeverGoesNegativeOrGroupsDigits() {
        XCTAssertEqual(YearInReviewView.heroFigure(totalSeconds: -5).value, "0")
        XCTAssertEqual(YearInReviewView.heroFigure(totalSeconds: 1234 * 3600).value, "1234")
    }

    // MARK: - VoiceOver

    func testTopBookAccessibilityLabelNamesRankTitleAuthorAndTime() {
        let book = YearInReviewTopBook(id: "a", title: "Alpha", author: "Jane Doe", seconds: 3600 * 12 + 300)
        XCTAssertEqual(YearInReviewView.topBookAccessibilityLabel(book, rank: 1),
                       "Number 1: Alpha, by Jane Doe. 12h 5m this year.")
        let anonymous = YearInReviewTopBook(id: "b", title: "", author: nil, seconds: 120)
        XCTAssertEqual(YearInReviewView.topBookAccessibilityLabel(anonymous, rank: 2),
                       "Number 2: Untitled. 2m this year.")
    }
}
