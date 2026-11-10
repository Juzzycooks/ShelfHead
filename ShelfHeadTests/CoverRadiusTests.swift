import XCTest
@testable import ShelfHead

/// V3 / IC-1 (docs/visual-design-review.md): a cover's corner radius follows its size.
final class CoverRadiusTests: XCTestCase {
    func testThumbnailsUseThumbRadius() {
        for side: CGFloat in [38, 40, 44, 48] {
            XCTAssertEqual(Radius.cover(side: side), Radius.thumb, "side \(side)")
        }
    }

    func testRowCoversUseChipRadius() {
        for side: CGFloat in [49, 52, 56, 64, 80] {
            XCTAssertEqual(Radius.cover(side: side), Radius.chip, "side \(side)")
        }
    }

    func testLargeCoversUseCardRadius() {
        for side: CGFloat in [81, 130, 160] {
            XCTAssertEqual(Radius.cover(side: side), Radius.card, "side \(side)")
        }
    }

    func testThumbIsSixPoints() {
        XCTAssertEqual(Radius.thumb, 6)
    }
}
