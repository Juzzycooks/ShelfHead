import XCTest
@testable import ShelfHead

final class PlayRequestedTests: XCTestCase {
    func testRequestedTitleBlankIsNil() {
        XCTAssertNil(PlaybackCoordinator.requestedTitle(nil))
        XCTAssertNil(PlaybackCoordinator.requestedTitle("  \n"))
        XCTAssertEqual(PlaybackCoordinator.requestedTitle(" Dune "), "Dune")
    }

    func testDownloadedMatchPrefersExactThenShortestContaining() {
        let titles = ["Dune Messiah", "Dune", "Children of Dune"]
        XCTAssertEqual(PlaybackCoordinator.bestDownloadedMatch(for: "dune", in: titles, title: { $0 }), "Dune")
        XCTAssertEqual(PlaybackCoordinator.bestDownloadedMatch(for: "messi", in: titles, title: { $0 }), "Dune Messiah")
        XCTAssertNil(PlaybackCoordinator.bestDownloadedMatch(for: "Emma", in: titles, title: { $0 }))
    }
}
