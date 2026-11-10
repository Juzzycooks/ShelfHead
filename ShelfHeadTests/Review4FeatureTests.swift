import XCTest
@testable import ShelfHead

/// Review 4 Low fixes in the feature services.
final class Review4FeatureTests: XCTestCase {
    func testMutationErrorOn200IsThrown() {
        let failed: [String: Any] = ["update_user_book_read": ["id": NSNull(), "error": "not allowed"]]
        XCTAssertThrowsError(try HardcoverAPI.throwIfMutationFailed(failed, key: "update_user_book_read"))
        let ok: [String: Any] = ["update_user_book": ["id": 3, "error": NSNull()]]
        XCTAssertNoThrow(try HardcoverAPI.throwIfMutationFailed(ok, key: "update_user_book"))
    }

    @MainActor
    func testFinishedCatalogResetsOnAccountChange() {
        let catalog = FinishedBookCatalog()
        let exp = expectation(description: "reset")
        NotificationCenter.default.post(name: .shelfheadAccountChanged, object: nil)
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(catalog.hasLoaded)
        XCTAssertTrue(catalog.books.isEmpty)
    }
}
