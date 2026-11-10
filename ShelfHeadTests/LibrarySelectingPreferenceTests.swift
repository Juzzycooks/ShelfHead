import XCTest
@testable import ShelfHead

final class LibrarySelectingPreferenceTests: XCTestCase {
    private func combine(_ a: Bool, _ b: Bool) -> Bool {
        var v = a
        LibrarySelectingPreferenceKey.reduce(value: &v, nextValue: { b })
        return v
    }

    func testDefaultIsFalse() {
        XCTAssertFalse(LibrarySelectingPreferenceKey.defaultValue)
    }

    func testReduceIsLogicalOr() {
        XCTAssertFalse(combine(false, false))
        XCTAssertTrue(combine(false, true))
        XCTAssertTrue(combine(true, false))
        XCTAssertTrue(combine(true, true))
    }
}
