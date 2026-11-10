import XCTest
@testable import ShelfHead

final class Review3HomeTests: XCTestCase {
    func testFreshRefreshIsNotStale() {
        XCTAssertFalse(OtherServersStore.isStaleRefresh(startAccountId: "a", currentAccountId: "a",
                                                        startGeneration: 3, currentGeneration: 3, isKidNow: false))
    }

    func testAccountChangeIsStale() {
        XCTAssertTrue(OtherServersStore.isStaleRefresh(startAccountId: "a", currentAccountId: "b",
                                                       startGeneration: 3, currentGeneration: 3, isKidNow: false))
    }

    func testNewerGenerationIsStale() {
        XCTAssertTrue(OtherServersStore.isStaleRefresh(startAccountId: "a", currentAccountId: "a",
                                                       startGeneration: 3, currentGeneration: 4, isKidNow: false))
    }

    func testKidNowIsStale() {
        XCTAssertTrue(OtherServersStore.isStaleRefresh(startAccountId: "a", currentAccountId: "a",
                                                       startGeneration: 3, currentGeneration: 3, isKidNow: true))
    }
}
