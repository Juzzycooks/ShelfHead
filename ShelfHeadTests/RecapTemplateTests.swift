import XCTest
@testable import ShelfHead

/// Pins the pure, deterministic pieces of `RecapGenerator` — the "Where you left off"
/// card's instant template, before any on-device model upgrade lands.
final class RecapTemplateTests: XCTestCase {

    func testRemainingLabelUnderAMinute() {
        XCTAssertEqual(RecapGenerator.remainingLabel(seconds: 30), "under a minute")
    }

    func testRemainingLabelMinutesOnly() {
        XCTAssertEqual(RecapGenerator.remainingLabel(seconds: 90), "1 m")
    }

    func testRemainingLabelHoursAndMinutes() {
        XCTAssertEqual(RecapGenerator.remainingLabel(seconds: 3661), "1 h 1 m")
    }

    func testTemplateRecapIncludesPercentChapterAndLeft() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lastListened = now.addingTimeInterval(-3 * 24 * 3600)
        let facts = RecapFacts(
            title: "The Fellowship of the Ring",
            author: "J.R.R. Tolkien",
            seriesLine: nil,
            chapterTitle: "A Knife in the Dark",
            chapterNumber: 7,
            chapterCount: 22,
            progress: 0.42,
            remainingSeconds: 6 * 3600 + 10 * 60,
            lastListened: lastListened,
            descriptionExcerpt: "Spoiler-laden plot summary that must never appear."
        )

        let recap = RecapGenerator.templateRecap(facts, now: now)

        XCTAssertTrue(recap.contains("42%"))
        XCTAssertTrue(recap.contains("chapter 7 of 22"))
        XCTAssertTrue(recap.contains("A Knife in the Dark"))
        XCTAssertTrue(recap.contains("left"))
        XCTAssertFalse(recap.contains("Spoiler-laden"))
    }

    func testTemplateRecapOmitsChapterPhraseWhenNoChapterData() {
        let facts = RecapFacts(
            title: "Some Book",
            author: "Some Author",
            seriesLine: nil,
            chapterTitle: nil,
            chapterNumber: nil,
            chapterCount: nil,
            progress: 0.1,
            remainingSeconds: 120,
            lastListened: nil,
            descriptionExcerpt: nil
        )

        let recap = RecapGenerator.templateRecap(facts)

        XCTAssertFalse(recap.contains("chapter"))
    }
}
