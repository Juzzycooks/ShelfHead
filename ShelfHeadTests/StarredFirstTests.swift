import XCTest
@testable import ShelfHead

final class StarredFirstTests: XCTestCase {
    private func split(_ names: [String], starred: Set<String>) -> (starred: [String], rest: [String]) {
        FavoritesStore.starredFirst(names, name: { $0 }, isStarred: { starred.contains($0) })
    }

    func testEmptyInput() {
        let r = split([], starred: ["a"])
        XCTAssertTrue(r.starred.isEmpty)
        XCTAssertTrue(r.rest.isEmpty)
    }

    func testNoneStarred() {
        let r = split(["Ann", "Bob"], starred: [])
        XCTAssertTrue(r.starred.isEmpty)
        XCTAssertEqual(r.rest, ["Ann", "Bob"])
    }

    func testCaseInsensitiveMatching() {
        let r = split(["Brandon SANDERSON", "Other"], starred: ["brandon sanderson"])
        XCTAssertEqual(r.starred, ["Brandon SANDERSON"])
        XCTAssertEqual(r.rest, ["Other"])
    }

    func testOrderKeptAndStarredNotRepeatedInRest() {
        let r = split(["D", "a", "C", "b", "E"], starred: ["a", "b", "c"])
        XCTAssertEqual(r.starred, ["a", "C", "b"])
        XCTAssertEqual(r.rest, ["D", "E"])
    }

    func testDuplicatesArePreserved() {
        let r = split(["Ann", "ann", "Bob", "Ann"], starred: ["ann"])
        XCTAssertEqual(r.starred, ["Ann", "ann", "Ann"])
        XCTAssertEqual(r.rest, ["Bob"])
    }

    func testEmptyNameNeverStarred() {
        let r = split([""], starred: [""])
        XCTAssertTrue(r.starred.isEmpty)
        XCTAssertEqual(r.rest, [""])
    }
}
