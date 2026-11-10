import XCTest
@testable import ShelfHead

/// P-4 (REVIEW_2026-09-14_DESIGN.md): pins `BookDetailView.shouldShowDescription(_:)`,
/// the pure predicate behind whether Book Detail's About section renders at all.
/// Stricter than the general-purpose `MediaMetadata.isMeaningfulDescription` (a flat
/// 20-character floor, still used elsewhere in the model layer) — real servers were
/// seen putting a bare chapter heading into the description field (e.g. "Chapter 84"),
/// and this screen wants that gone even on the rare case it clears the lower floor.
final class BookDetailDescriptionTests: XCTestCase {

    func testNilDescriptionIsHidden() {
        XCTAssertFalse(BookDetailView.shouldShowDescription(nil))
    }

    func testEmptyDescriptionIsHidden() {
        XCTAssertFalse(BookDetailView.shouldShowDescription(""))
    }

    func testWhitespaceOnlyDescriptionIsHidden() {
        XCTAssertFalse(BookDetailView.shouldShowDescription("   \n\t  "))
    }

    func testShortDescriptionUnderFortyCharactersIsHidden() {
        // 24 characters trimmed — under the 40-character floor.
        XCTAssertFalse(BookDetailView.shouldShowDescription("A short teaser, not much."))
    }

    func testDescriptionExactlyAtFortyCharactersIsShown() {
        let text = String(repeating: "a", count: 40)
        XCTAssertEqual(text.count, 40)
        XCTAssertTrue(BookDetailView.shouldShowDescription(text))
    }

    func testDescriptionOneCharacterUnderFortyIsHidden() {
        let text = String(repeating: "a", count: 39)
        XCTAssertFalse(BookDetailView.shouldShowDescription(text))
    }

    func testLeadingAndTrailingWhitespaceIsTrimmedBeforeCounting() {
        // 40 'a's padded with whitespace that shouldn't count toward the floor.
        let text = "   " + String(repeating: "a", count: 40) + "   "
        XCTAssertTrue(BookDetailView.shouldShowDescription(text))
    }

    func testBareChapterHeadingIsHidden() {
        // The real-world junk this fix targets — short enough to already fail the
        // length floor, but exercised explicitly since it's the named case.
        XCTAssertFalse(BookDetailView.shouldShowDescription("Chapter 84"))
        XCTAssertFalse(BookDetailView.shouldShowDescription("chapter 12"))
        XCTAssertFalse(BookDetailView.shouldShowDescription("CHAPTER 1"))
    }

    func testBareChapterHeadingIsHiddenEvenWhenPaddedPastTheLengthFloor() {
        // A chapter heading whose number alone pushes it past 40 characters must still
        // be caught by the `^chapter \d+$` pattern, not slip through on length.
        let text = "Chapter " + String(repeating: "9", count: 40)
        XCTAssertGreaterThanOrEqual(text.count, 40)
        XCTAssertFalse(BookDetailView.shouldShowDescription(text))
    }

    func testChapterHeadingWithExtraTextIsShown() {
        // Only a bare "Chapter N" is junk; a real chapter-derived title with more
        // content is a legitimate (if unusual) description once it clears the floor.
        let text = "Chapter 84: The Long Road Home and What Came After"
        XCTAssertTrue(BookDetailView.shouldShowDescription(text))
    }

    func testOrdinaryLongDescriptionIsShown() {
        let text = "A gripping tale of adventure, loss, and redemption across three continents."
        XCTAssertTrue(BookDetailView.shouldShowDescription(text))
    }
}
