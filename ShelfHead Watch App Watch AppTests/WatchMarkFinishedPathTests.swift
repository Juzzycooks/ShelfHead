import XCTest
@testable import ShelfHead_Watch

/// Batch 413/414: who writes Book Details' Mark as Finished (`WatchMarkFinishedPath`).
final class WatchMarkFinishedPathTests: XCTestCase {
    private func decide(isFinished: Bool = false, session: Bool = false,
                        reachable: Bool = false) -> WatchMarkFinishedPath {
        WatchMarkFinishedPath.decide(itemId: "a", isFinished: isFinished, hasWatchSession: session,
                                     phoneIsReachable: reachable)
    }

    func testFinishedBookShowsNothing() {
        XCTAssertEqual(decide(isFinished: true, session: true), .hidden)
        XCTAssertEqual(decide(isFinished: true, reachable: true), .hidden)
    }

    func testWatchSessionWritesItselfWithOrWithoutThePhone() {
        XCTAssertEqual(decide(session: true, reachable: false), .server)
        XCTAssertEqual(decide(session: true, reachable: true), .server)
    }

    func testWithoutASessionThePhoneWritesAnyBook() {
        XCTAssertEqual(decide(reachable: true), .phone)
        XCTAssertEqual(decide(reachable: false), .needsPhone)
    }
}
