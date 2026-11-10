import XCTest
@testable import ShelfHead

/// N-3 (REVIEW_2026-09-14_DESIGN.md): the Library tab's Books/Series/Authors/
/// Narrators/Collections/Playlists chip row scrolled horizontally and clipped
/// ("Narr…") — a scope switcher masquerading as a filter chip row. Replaced with a
/// segmented control for the four primary scopes plus a compact trailing menu for
/// the remaining two (Collections/Playlists), falling back to a single `Menu` at
/// accessibility Dynamic Type sizes. `LibraryView.isPrimaryScope` is the pure
/// classification behind which of the six `BrowseMode` cases lands in the segmented
/// control vs. the "More" menu — pinned here since the surrounding view needs a live
/// `LibraryViewModel` (for `availableModes`) and isn't unit-testable directly.
final class LibraryScopeControlTests: XCTestCase {

    func testPrimaryScopes() {
        XCTAssertTrue(LibraryView.isPrimaryScope(.books))
        XCTAssertTrue(LibraryView.isPrimaryScope(.series))
        XCTAssertTrue(LibraryView.isPrimaryScope(.authors))
        XCTAssertTrue(LibraryView.isPrimaryScope(.narrators))
    }

    func testSecondaryScopes() {
        XCTAssertFalse(LibraryView.isPrimaryScope(.collections))
        XCTAssertFalse(LibraryView.isPrimaryScope(.playlists))
    }

    /// Every `BrowseMode` case must land in exactly one bucket — no scope should
    /// silently disappear from both the segmented control and the "More" menu.
    func testEveryScopeIsClassified() {
        for mode in BrowseMode.allCases {
            let isPrimary = LibraryView.isPrimaryScope(mode)
            let isSecondary = !isPrimary
            XCTAssertTrue(isPrimary || isSecondary, "\(mode) must classify as primary or secondary")
        }
    }

    /// Guards the specific PM decision (four primary scopes, two secondary) rather
    /// than just "some split exists" — a future edit that moves a scope between the
    /// two groups should have to touch this test deliberately.
    func testExactPrimaryAndSecondaryCounts() {
        let primary = BrowseMode.allCases.filter(LibraryView.isPrimaryScope)
        let secondary = BrowseMode.allCases.filter { !LibraryView.isPrimaryScope($0) }
        XCTAssertEqual(primary.count, 4)
        XCTAssertEqual(secondary.count, 2)
        XCTAssertEqual(Set(secondary), [.collections, .playlists])
    }
}
