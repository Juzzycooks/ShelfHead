import XCTest
@testable import ShelfHead

/// HL-4 (docs/visual-design-review.md, V4): axis labels at accessibility sizes.
final class ChartAxisLabelsTests: XCTestCase {
    private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    func testThinnedKeepsEverythingWhenItFits() {
        XCTAssertEqual(ChartAxisLabels.thinned(["a", "b", "c"], limit: 4), ["a", "b", "c"])
    }

    func testYearThinnedToQuarters() {
        XCTAssertEqual(ChartAxisLabels.thinned(months, limit: 4), ["Jan", "Apr", "Jul", "Oct"])
    }

    func testMonthThinnedToThreeStartsAtFirst() {
        let days = (1...30).map(String.init)
        let ticks = ChartAxisLabels.thinned(days, limit: 3)
        XCTAssertEqual(ticks, ["1", "11", "21"])
    }

    func testDrawnNarrowUsesFirstLetterOnly() {
        XCTAssertEqual(ChartAxisLabels.drawn("Tue", narrow: true), "T")
        XCTAssertEqual(ChartAxisLabels.drawn("Tue", narrow: false), "Tue")
        // Batch 400: Chinese short weekdays all start with "周", so narrow uses the
        // locale's very short symbol instead of the first character.
        let zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(ChartAxisLabels.drawn("周二", narrow: true, locale: zh), "二")
        XCTAssertEqual(ChartAxisLabels.drawn("Tue", narrow: true, locale: Locale(identifier: "en_US")), "T")
    }

    func testNonPositiveLimitReturnsAll() {
        XCTAssertEqual(ChartAxisLabels.thinned(months, limit: 0), months)
    }
}
