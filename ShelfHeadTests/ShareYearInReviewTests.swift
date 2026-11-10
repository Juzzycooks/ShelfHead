import XCTest
@testable import ShelfHead

// Critique 2026-10-06 (shape → bolder): pins the pure pieces of the new `.yearInReview`
// share card and the composer's merged Remix — which themes/contents a Year in Review
// context gets (and that a book context never gets the year card), the card's copy
// ("MY 2026", "best streak · all-time"), every privacy flag it honours, and the Remix
// theme cycle that keeps Collage/Kinetic reachable now "Try another style" is gone.
final class ShareYearInReviewTests: XCTestCase {

    private func bookContext() -> ShareCardContext {
        ShareCardContext(itemId: "li_1", title: "Alpha", author: "Jane Doe",
                         progress: ProgressShareData(progress: 0.4, listened: "2h", remaining: "3h", speed: "1.0×", chapters: 10))
    }

    private func review(booksPlayed: Int? = 14, topAuthor: String? = "Jane Doe", streak: Int? = 38) -> YearReviewShareData {
        YearReviewShareData(year: 2026, hoursValue: "212", hoursUnit: "hours",
                            booksPlayed: booksPlayed, topAuthor: topAuthor, bestStreakDays: streak)
    }

    private func yearContext() -> ShareCardContext {
        var context = bookContext()
        context.yearReview = review()
        return context
    }

    // MARK: - Content / theme selection

    func testYearContextGetsOnlyTheYearCard() {
        XCTAssertEqual(ShareCardContent.available(for: yearContext()), [.yearInReview])
        XCTAssertEqual(ShareCardTheme.available(for: yearContext()), [.yearInReview])
    }

    func testBookContextNeverGetsTheYearCard() {
        XCTAssertFalse(ShareCardContent.available(for: bookContext()).contains(.yearInReview))
        XCTAssertFalse(ShareCardTheme.available(for: bookContext()).contains(.yearInReview))
        // The book flow is unchanged: progress and the cover-led themes are still there.
        XCTAssertTrue(ShareCardContent.available(for: bookContext()).contains(.progress))
        XCTAssertTrue(ShareCardTheme.available(for: bookContext()).contains(.spotlight))
    }

    func testYearPresetIsOfferedOnlyForAYearContext() {
        XCTAssertTrue(SharePreset.isAvailable(.yearInReview, availableThemes: ShareCardTheme.available(for: yearContext())))
        XCTAssertFalse(SharePreset.isAvailable(.yearInReview, availableThemes: ShareCardTheme.available(for: bookContext())))
        XCTAssertEqual(SharePreset.resolvedContent(for: .yearInReview, available: [.yearInReview]), .yearInReview)
    }

    // MARK: - Copy

    func testKickerNamesTheYearWithoutGrouping() {
        XCTAssertEqual(YearReviewShareData.kicker(year: 2026), "MY 2026")
    }

    func testHeadlineIsHoursListened() {
        XCTAssertEqual(review().headline(privacy: SharePrivacyOptions()),
                       ShareStatCell(value: "212", caption: "hours listened"))
    }

    func testCellsAreBooksPlayedTopAuthorAndAllTimeStreak() {
        XCTAssertEqual(review().cells(privacy: SharePrivacyOptions()), [
            ShareStatCell(value: "14", caption: "books played"),
            ShareStatCell(value: "Jane Doe", caption: "top author"),
            ShareStatCell(value: "38 days", caption: "best streak \u{00B7} all-time")
        ])
    }

    func testStreakIsNeverCaptionedAsAPlainDayStreak() {
        let captions = review(streak: 1).cells(privacy: SharePrivacyOptions()).map(\.caption)
        XCTAssertFalse(captions.contains("day streak"))
        XCTAssertEqual(review(streak: 1).cells(privacy: SharePrivacyOptions()).last?.value, "1 day")
    }

    func testSingularBookPlayed() {
        XCTAssertEqual(review(booksPlayed: 1).cells(privacy: SharePrivacyOptions()).first,
                       ShareStatCell(value: "1", caption: "book played"))
    }

    func testMissingFiguresAreOmittedNotZero() {
        // Sessions unavailable → nil books/author; no streak → nothing.
        XCTAssertTrue(review(booksPlayed: nil, topAuthor: nil, streak: 0).cells(privacy: SharePrivacyOptions()).isEmpty)
    }

    // MARK: - Privacy

    func testHidingListeningTotalsHidesHoursAndBooks() {
        var privacy = SharePrivacyOptions()
        privacy.showListeningTotals = false
        XCTAssertNil(review().headline(privacy: privacy))
        XCTAssertFalse(review().cells(privacy: privacy).contains { $0.caption == "books played" })
        XCTAssertFalse(SharePrivacyOptions.headlineIsVisible(content: .yearInReview, privacy: privacy))
    }

    func testStreakAndAuthorFlagsAreHonoured() {
        var privacy = SharePrivacyOptions()
        privacy.showStreak = false
        privacy.showAuthor = false
        XCTAssertEqual(review().cells(privacy: privacy).map(\.caption), ["books played"])
    }

    func testCoverOnlyStyleOptionsLeaveNoFigures() {
        var privacy = SharePrivacyOptions()
        privacy.showListeningTotals = false
        privacy.showStreak = false
        privacy.showAuthor = false
        XCTAssertNil(review().headline(privacy: privacy))
        XCTAssertTrue(review().cells(privacy: privacy).isEmpty)
    }

    func testListeningTotalsDefaultOn() {
        XCTAssertTrue(SharePrivacyOptions().showListeningTotals)
    }

    // MARK: - Remix

    func testRemixCyclesSpotlightsFamilyAndAlwaysRollsTheSeed() {
        var theme = ShareCardTheme.spotlight
        var shuffle = 0
        var seen: [ShareCardTheme] = []
        for _ in 0..<3 {
            (theme, shuffle) = SharePreset.remix(theme: theme, shuffle: shuffle)
            seen.append(theme)
        }
        XCTAssertEqual(seen, [.collage, .kineticType, .spotlight])
        XCTAssertEqual(shuffle, 3)
    }

    func testRemixKeepsOtherPresetsOnTheirOwnTheme() {
        for preset in SharePreset.allCases where preset != .spotlight {
            let next = SharePreset.remix(theme: preset.theme, shuffle: 7)
            XCTAssertEqual(next.theme, preset.theme, "\(preset)")
            XCTAssertEqual(next.shuffle, 8)
        }
    }

    func testCollageAndKineticBelongToSpotlight() {
        XCTAssertEqual(SharePreset.preset(for: .collage), .spotlight)
        XCTAssertEqual(SharePreset.preset(for: .kineticType), .spotlight)
        XCTAssertEqual(SharePreset.preset(for: .yearInReview), .yearInReview)
        // Every theme is reachable from some preset.
        for theme in ShareCardTheme.allCases {
            XCTAssertNotNil(SharePreset.preset(for: theme), "\(theme)")
        }
    }
}
