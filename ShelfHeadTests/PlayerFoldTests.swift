import XCTest
@testable import ShelfHead

/// iPhone Duo (Batch 418): the full player's fold split. `PlayerFold(divisionFrame:)` and
/// `panes(in:)` are pure, so the axis rule and the pane arithmetic are pinned here without a
/// folding device (`PlayerFold.current(in:)` needs a live GeometryProxy).
final class PlayerFoldTests: XCTestCase {

    func testTallDivisionRunsVertically() {
        let fold = PlayerFold(divisionFrame: CGRect(x: 380, y: 0, width: 40, height: 900))
        XCTAssertTrue(fold.runsVertically)
    }

    func testWideDivisionRunsHorizontally() {
        let fold = PlayerFold(divisionFrame: CGRect(x: 0, y: 430, width: 800, height: 40))
        XCTAssertFalse(fold.runsVertically)
    }

    func testBookPanesSplitWidthAroundTheFold() {
        let fold = PlayerFold(divisionFrame: CGRect(x: 380, y: 0, width: 40, height: 900))
        let panes = fold.panes(in: CGSize(width: 800, height: 900))
        XCTAssertEqual(panes.first, 380)
        XCTAssertEqual(panes.gap, 40)
        XCTAssertEqual(panes.second, 380)
    }

    func testLaptopPanesSplitHeightAroundTheFold() {
        let fold = PlayerFold(divisionFrame: CGRect(x: 0, y: 430, width: 800, height: 40))
        let panes = fold.panes(in: CGSize(width: 800, height: 1000))
        XCTAssertEqual(panes.first, 430)
        XCTAssertEqual(panes.gap, 40)
        XCTAssertEqual(panes.second, 530)
    }

    func testPanesClampWhenTheDivisionOverhangsTheView() {
        // A region overlapping only part of the view can start at negative coordinates or
        // run past its size (Apple docs, ReservedRegion); the three parts still sum to the side.
        let fold = PlayerFold(divisionFrame: CGRect(x: -20, y: 0, width: 60, height: 900))
        let panes = fold.panes(in: CGSize(width: 800, height: 900))
        XCTAssertEqual(panes.first, 0)
        XCTAssertEqual(panes.gap, 40)
        XCTAssertEqual(panes.second, 760)
        XCTAssertEqual(panes.first + panes.gap + panes.second, 800)
    }
}
