import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • YearInReviewPagesTests
// =============================================================================
//
// Pins the pure `YearInReviewView.buildCards(...)` — the card list/order/placement/
// copy behind the Year in Review grid — since the grid itself (a live view reading
// network-fetched state) isn't unit-testable directly. Same "extract the decision,
// test the decision" precedent as `sessionsAreIncomplete` in the same view file and
// `DownloadManager.shouldReclaimOrphanDirectory`.
//
// History: Batch 318 (P-12, REVIEW_2026-09-14_DESIGN.md) turned this screen into a
// full-bleed `TabView(.page)` pager, and these tests pinned `buildPages(...)`/
// `YearInReviewPage`. The pager was reverted on 15 September 2026 by user decision
// after seeing it on device, so the symbols are now `buildCards(...)`/
// `YearInReviewCard` and the pinned order is *display* order for a grid — four tiles,
// then the full-width cards. Two P-12 outcomes are still pinned here because they
// were kept across the revert: no all-time "Books Finished" card at all, and the
// lifetime Best Streak caveat living in `caveat` (the ⓘ popover) rather than in
// `incompleteNote` (inline body copy).
//
// Critique 2026-10-06 (shape → bolder): the grid became a hero figure, a figure list and
// the chart panel (`Placement.hero/.figure/.chart`), the figure order follows the design
// (Books Played, Longest Session, Most-Listened Author, Best Streak), and "Books Touched"
// is "Books Played".
final class YearInReviewPagesTests: XCTestCase {

    private func makeCards(
        distinctBooks: Int = 3,
        topAuthor: (name: String, seconds: Double)? = ("Jane Doe", 3600),
        sessionsMayBeIncomplete: Bool = false
    ) -> [YearInReviewCard] {
        YearInReviewView.buildCards(
            year: 2026,
            totalSeconds: 3600 * 10,
            distinctBooks: distinctBooks,
            topAuthor: topAuthor,
            longestSessionSeconds: 3600 * 2,
            bestStreakDays: 14,
            monthlyBars: [Bar(label: "Jan", minutes: 60)],
            sessionsMayBeIncomplete: sessionsMayBeIncomplete,
            incompleteSessionsNote: "note"
        )
    }

    // MARK: - Card presence / order

    func testIncludesTopAuthorCardWhenAuthorDataExists() {
        let cards = makeCards()
        XCTAssertEqual(cards.map(\.kind), [
            .totalListened, .booksListened, .longestSession, .topAuthor, .bestStreak, .monthlyChart
        ])
    }

    func testOmitsTopAuthorCardWhenNoAuthorData() {
        let cards = makeCards(topAuthor: nil)
        XCTAssertEqual(cards.map(\.kind), [
            .totalListened, .booksListened, .longestSession, .bestStreak, .monthlyChart
        ])
        XCTAssertFalse(cards.contains { $0.kind == .topAuthor })
    }

    func testNoAllTimeBooksFinishedCardExists() {
        // P-12's one removal that survived the revert: the server has no
        // completion-date source, so there is no honest year-scoped version of it.
        XCTAssertEqual(Set(YearInReviewCard.Kind.allCases), [
            .totalListened, .booksListened, .topAuthor, .longestSession, .monthlyChart, .bestStreak
        ])
    }

    // MARK: - Placement drives the layout

    func testHeroIsTotalListenedFiguresAreTheRestAndChartIsAlone() {
        let cards = makeCards()
        XCTAssertEqual(cards.filter { $0.placement == .hero }.map(\.kind), [.totalListened])
        XCTAssertEqual(cards.filter { $0.placement == .figure }.map(\.kind), [
            .booksListened, .longestSession, .topAuthor, .bestStreak
        ])
        XCTAssertEqual(cards.filter { $0.placement == .chart }.map(\.kind), [.monthlyChart])
    }

    func testTopAuthorCarriesTheCoverOfTheirMostPlayedBook() {
        let cards = YearInReviewView.buildCards(
            year: 2026, totalSeconds: 3600, distinctBooks: 1, topAuthor: ("Jane Doe", 3600),
            longestSessionSeconds: 60, bestStreakDays: 1, monthlyBars: [],
            sessionsMayBeIncomplete: false, incompleteSessionsNote: "note",
            topAuthorCoverItemId: "li_1")
        XCTAssertEqual(cards.first { $0.kind == .topAuthor }?.coverItemId, "li_1")
        XCTAssertTrue(cards.filter { $0.kind != .topAuthor }.allSatisfy { $0.coverItemId == nil })
    }

    func testOnlyTheChartCardHasAnEmptyHeadlineValue() {
        let cards = makeCards()
        for card in cards where card.kind != .monthlyChart {
            XCTAssertFalse(card.value.isEmpty, "\(card.kind) should carry a headline figure")
        }
        XCTAssertEqual(cards.first { $0.kind == .monthlyChart }?.value, "")
    }

    // MARK: - Lifetime caveat lives behind the popover, not inline

    func testBestStreakCaveatIsPopoverOnlyNotInlineNote() {
        let streakCard = makeCards().first { $0.kind == .bestStreak }
        XCTAssertNotNil(streakCard?.caveat)
        XCTAssertNil(streakCard?.incompleteNote)
        XCTAssertEqual(streakCard?.value, "14 days")
    }

    func testBestStreakLabelSaysAllTime() {
        // The caveat is behind the ⓘ, so the label itself has to carry enough for
        // someone who never taps it.
        XCTAssertEqual(makeCards().first { $0.kind == .bestStreak }?.label, "Best Streak (all-time)")
    }

    func testOnlyBestStreakCardCarriesACaveat() {
        let cards = makeCards()
        for card in cards where card.kind != .bestStreak {
            XCTAssertNil(card.caveat, "\(card.kind) should not carry a lifetime-figure caveat")
        }
    }

    // MARK: - Y7 undercount note only applies to session-derived cards

    func testIncompleteNoteAppliesOnlyToSessionDerivedCards() {
        let cards = makeCards(sessionsMayBeIncomplete: true)
        let notedKinds = Set(cards.filter { $0.incompleteNote != nil }.map(\.kind))
        XCTAssertEqual(notedKinds, [.booksListened, .topAuthor, .longestSession])
    }

    func testNoIncompleteNoteWhenSessionsAreComplete() {
        let cards = makeCards(sessionsMayBeIncomplete: false)
        XCTAssertTrue(cards.allSatisfy { $0.incompleteNote == nil })
    }

    // MARK: - Copy

    func testBooksPlayedLabelIsSingularForOneBook() {
        let card = makeCards(distinctBooks: 1).first { $0.kind == .booksListened }
        XCTAssertEqual(card?.label, "Book Played")
    }

    func testBooksPlayedLabelIsPluralOtherwise() {
        let card = makeCards(distinctBooks: 2).first { $0.kind == .booksListened }
        XCTAssertEqual(card?.label, "Books Played")
    }

    func testNoCardSaysTouched() {
        // "Books Touched" was jargon (critique 2026-10-06, Jordan persona).
        for distinct in [0, 1, 2] {
            XCTAssertFalse(makeCards(distinctBooks: distinct).contains { $0.label.contains("Touched") })
        }
    }

    func testTotalListenedLabelNamesTheSelectedYear() {
        XCTAssertEqual(makeCards().first { $0.kind == .totalListened }?.label, "Listened in 2026")
    }

    func testTopAuthorCardShowsTheAuthorNameWithAYearScopedDetailLine() {
        let card = makeCards().first { $0.kind == .topAuthor }
        XCTAssertEqual(card?.value, "Jane Doe")
        XCTAssertEqual(card?.label, "Most-Listened Author")
        XCTAssertEqual(card?.detail, "1h 0m this year")
    }

    // MARK: - Hour formatting

    func testFormatHoursOmitsHoursWhenUnderAnHour() {
        XCTAssertEqual(YearInReviewView.formatHours(59 * 60), "59m")
    }

    func testFormatHoursIncludesHoursAndMinutes() {
        XCTAssertEqual(YearInReviewView.formatHours(3600 * 2 + 60 * 5), "2h 5m")
    }
}
