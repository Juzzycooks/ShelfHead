import XCTest
@testable import ShelfHead

final class Review3FeatureTests: XCTestCase {
    // Review 3 Low (Release Radar rotation)
    func testSeriesToCheckRotatesEvenWhenAllFit() {
        func book(_ s: String) -> ReleaseRadarPlanner.LibraryBook {
            .init(asin: "A\(s)", author: "X", language: "English", isStarted: true, series: [(s, 1)])
        }
        let books = [book("Alpha"), book("Beta"), book("Gamma")]
        let r = ReleaseRadarPlanner.seriesToCheck(books: books, cap: 25, rotation: 1)
        XCTAssertEqual(r.targets.map(\.name), ["Beta", "Gamma", "Alpha"])
        XCTAssertEqual(r.nextRotation, 0)
        let none = ReleaseRadarPlanner.seriesToCheck(books: books, cap: 25, rotation: 0)
        XCTAssertEqual(none.targets.map(\.name), ["Alpha", "Beta", "Gamma"])
        let wrapped = ReleaseRadarPlanner.seriesToCheck(books: books, cap: 25, rotation: 7)
        XCTAssertEqual(wrapped.targets.map(\.name), ["Beta", "Gamma", "Alpha"])
    }
}
