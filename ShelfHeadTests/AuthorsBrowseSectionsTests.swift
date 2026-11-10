import XCTest
@testable import ShelfHead

final class AuthorsBrowseSectionsTests: XCTestCase {
    func testHeaderStrings() {
        XCTAssertEqual(BrowseStarredSections.starredTitle, "Starred")
        XCTAssertEqual(BrowseStarredSections.allTitle(for: .authors), "All Authors")
        XCTAssertEqual(BrowseStarredSections.allTitle(for: .narrators), "All Narrators")
    }

    func testSectionsShowOnlyWhenSomethingIsStarred() {
        XCTAssertFalse(BrowseStarredSections.showsSections(starredCount: 0))
        XCTAssertTrue(BrowseStarredSections.showsSections(starredCount: 1))
    }

    func testDisplayedFirstPrefersStarred() {
        XCTAssertEqual(BrowseStarredSections.displayedFirst(starred: ["Zed"], rest: ["Abe"]), "Zed")
        XCTAssertEqual(BrowseStarredSections.displayedFirst(starred: [String](), rest: ["Abe"]), "Abe")
        XCTAssertNil(BrowseStarredSections.displayedFirst(starred: [String](), rest: [String]()))
    }

    func testSplitHasNoRepeatsAndIsCaseInsensitive() {
        let starredSet: Set<String> = ["zed"]
        let r = FavoritesStore.starredFirst(["Abe", "Zed", "Mo"], name: { $0 }, isStarred: { starredSet.contains($0) })
        let split = BrowseStarredSplit(starred: r.starred, rest: r.rest)
        XCTAssertEqual(split.starred, ["Zed"])
        XCTAssertEqual(split.rest, ["Abe", "Mo"])
        XCTAssertEqual(split.displayedFirst, "Zed")
    }

    func testRowAccessibilityLabelsUnchanged() {
        XCTAssertEqual(AuthorsBrowseView.rowAccessibilityLabel(name: "A", isFavorite: true), "A, Starred")
        XCTAssertEqual(NarratorsBrowseView.rowAccessibilityLabel(name: "N", isFavorite: false), "N")
    }
}
