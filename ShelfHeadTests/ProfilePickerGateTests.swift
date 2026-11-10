import XCTest
@testable import ShelfHead

/// Review 2 High 1 (30 October 2026): the picker's gate decision.
final class ProfilePickerGateTests: XCTestCase {
    private func makeStore() -> KidProfileStore {
        let name = "ProfilePickerGateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return KidProfileStore(defaults: defaults)
    }

    func testPickerGatesGrownUpTilesWhenAKidIsSaved() {
        let store = makeStore()
        store.set(KidProfile(accountId: "kid"))
        XCTAssertTrue(ParentGate.pickerNeedsGate(target: "parent", store: store))
        XCTAssertFalse(ParentGate.pickerNeedsGate(target: "kid", store: store))
    }

    func testPickerDoesNotGateWithoutAKid() {
        XCTAssertFalse(ParentGate.pickerNeedsGate(target: "parent", store: makeStore()))
    }
}
