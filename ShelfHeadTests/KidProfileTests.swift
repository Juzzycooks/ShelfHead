import XCTest
@testable import ShelfHead

/// Batch 457: kids' profiles. The create-user body, permission decoding, the Bedtime Story profile and the
/// per-account kid flag store.
final class KidProfileTests: XCTestCase {

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChildBodyShape() throws {
        let body = ABSUserBody.child(username: "Mia", password: "pw", libraryIds: ["lib1"], tags: ["kids"], allowDownloads: true)
        let obj = try json(try body.encoded())
        XCTAssertEqual(obj["username"] as? String, "Mia")
        XCTAssertEqual(obj["type"] as? String, "user")
        XCTAssertEqual(obj["isActive"] as? Bool, true)
        XCTAssertEqual(obj["librariesAccessible"] as? [String], ["lib1"])
        XCTAssertEqual(obj["itemTagsSelected"] as? [String], ["kids"])
        let perms = try XCTUnwrap(obj["permissions"] as? [String: Bool])
        XCTAssertEqual(perms["accessExplicitContent"], false)
        XCTAssertEqual(perms["accessAllLibraries"], false)
        XCTAssertEqual(perms["accessAllTags"], false)
        XCTAssertEqual(perms["download"], true)
        for key in ["update", "delete", "upload", "createEreader", "selectedTagsNotAccessible"] {
            XCTAssertEqual(perms[key], false, key)
        }
    }

    func testNoTagsMeansAllTagsAndDownloadsCanBeOff() throws {
        let body = ABSUserBody.child(username: "Sam", password: nil, libraryIds: ["a", "b"], tags: [], allowDownloads: false)
        let obj = try json(try body.encoded())
        let perms = try XCTUnwrap(obj["permissions"] as? [String: Bool])
        XCTAssertEqual(perms["accessAllTags"], true)
        XCTAssertEqual(perms["download"], false)
        XCTAssertNil(obj["password"])
    }

    func testGeneratedPasswordIsReadable() {
        let password = KidPasswordGenerator.make(length: 14)
        XCTAssertEqual(password.count, 14)
        XCTAssertTrue(password.allSatisfy { KidPasswordGenerator.alphabet.contains($0) })
        XCTAssertFalse(password.contains("0") || password.contains("O") || password.contains("l"))
    }

    func testPermissionsDecodeWithNewFields() throws {
        let data = Data(#"{"download":true,"accessAllLibraries":false,"accessAllTags":false,"accessExplicitContent":false,"selectedTagsNotAccessible":true}"#.utf8)
        let perms = try JSONDecoder().decode(UserPermissions.self, from: data)
        XCTAssertEqual(perms.accessAllTags, false)
        XCTAssertEqual(perms.accessExplicitContent, false)
        XCTAssertEqual(perms.selectedTagsNotAccessible, true)
    }

    func testOldPermissionsJSONStillDecodes() throws {
        let data = Data(#"{"download":true,"update":false,"delete":false,"upload":false,"accessAllLibraries":true}"#.utf8)
        let perms = try JSONDecoder().decode(UserPermissions.self, from: data)
        XCTAssertEqual(perms.accessAllLibraries, true)
        XCTAssertNil(perms.accessAllTags)
        XCTAssertNil(perms.accessExplicitContent)
    }

    func testUserDecodesRestrictionLists() throws {
        let data = Data(#"{"id":"u","username":"mia","type":"user","librariesAccessible":["l1"],"itemTagsSelected":["kids"],"permissions":{"accessExplicitContent":false}}"#.utf8)
        let user = try JSONDecoder().decode(User.self, from: data)
        XCTAssertEqual(user.librariesAccessible, ["l1"])
        XCTAssertEqual(user.itemTagsSelected, ["kids"])
        let old = try JSONDecoder().decode(User.self, from: Data(#"{"id":"u","username":"mia"}"#.utf8))
        XCTAssertNil(old.librariesAccessible)
    }

    func testBedtimeStoryOverrides() {
        let o = ListeningProfile.bedtimeStory.overrides
        XCTAssertEqual(o.armsEndOfChapterTimer, true)
        XCTAssertEqual(o.autoplayNext, false)
        XCTAssertEqual(o.autoContinueSeries, false)
        XCTAssertEqual(o.volumeBoostDB, 0)
        XCTAssertNil(o.ambientBed)
        XCTAssertNil(o.armsSleepTimer)
    }

    private func makeStore() -> KidProfileStore {
        let name = "KidProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return KidProfileStore(defaults: defaults)
    }

    func testKidFlagIsKeyedByAccount() {
        let store = makeStore()
        XCTAssertFalse(store.hasAnyKid)
        store.set(KidProfile(accountId: "a", symbol: "star.fill", colorIndex: 2, usesBedtimeStory: false))
        XCTAssertTrue(store.isKid("a"))
        XCTAssertFalse(store.isKid("b"))
        XCTAssertFalse(store.isKid(nil))
        XCTAssertEqual(store.profile(for: "a")?.symbol, "star.fill")
        XCTAssertEqual(store.profile(for: "a")?.usesBedtimeStory, false)
        store.remove(accountId: "a")
        XCTAssertFalse(store.hasAnyKid)
    }

    func testGateDecisions() {
        let store = makeStore()
        store.set(KidProfile(accountId: "kid"))
        XCTAssertTrue(ParentGate.settingsNeedGate(activeAccountId: "kid", store: store))
        XCTAssertFalse(ParentGate.settingsNeedGate(activeAccountId: "parent", store: store))
        XCTAssertTrue(ParentGate.switchNeedsGate(to: "parent", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(to: "kid", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(to: "parent", store: makeStore()))
    }

    /// Review 3 High 2: a switch to a child's account leaves Settings; other tabs and adult accounts stay put.
    func testTabAfterAccountChange() {
        let store = makeStore()
        store.set(KidProfile(accountId: "kid"))
        XCTAssertEqual(ParentGate.tabAfterAccountChange(current: 3, activeAccountId: "kid", store: store), 0)
        XCTAssertEqual(ParentGate.tabAfterAccountChange(current: 1, activeAccountId: "kid", store: store), 1)
        XCTAssertEqual(ParentGate.tabAfterAccountChange(current: 3, activeAccountId: "parent", store: store), 3)
        XCTAssertEqual(ParentGate.tabAfterAccountChange(current: 3, activeAccountId: nil, store: store), 3)
    }

    func testSwitchGateFromActiveAccount() {
        let store = makeStore()
        store.set(KidProfile(accountId: "kid"))
        store.set(KidProfile(accountId: "kid2"))
        XCTAssertTrue(ParentGate.switchNeedsGate(from: "kid", to: "parent", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(from: "parent", to: "kid", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(from: "kid", to: "kid2", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(from: "kid", to: "kid", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(from: "parent", to: "parent2", store: store))
        // Signed out: falls back to "any child saved and the target is an adult".
        XCTAssertTrue(ParentGate.switchNeedsGate(from: nil, to: "parent", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(from: nil, to: "kid", store: store))
        XCTAssertFalse(ParentGate.switchNeedsGate(from: nil, to: "parent", store: makeStore()))
    }

    func testProfileAfterSwitch() {
        let store = makeStore()
        store.set(KidProfile(accountId: "kid"))
        store.set(KidProfile(accountId: "kid2", usesBedtimeStory: false))
        XCTAssertEqual(KidProfileCoordinator.profileAfterSwitch(to: "kid", current: .off, store: store), .bedtimeStory)
        XCTAssertNil(KidProfileCoordinator.profileAfterSwitch(to: "kid", current: .bedtimeStory, store: store))
        XCTAssertNil(KidProfileCoordinator.profileAfterSwitch(to: "kid2", current: .off, store: store))
        XCTAssertEqual(KidProfileCoordinator.profileAfterSwitch(to: "parent", current: .bedtimeStory, store: store), .off)
        XCTAssertNil(KidProfileCoordinator.profileAfterSwitch(to: "parent", current: .driving, store: store))
    }
}
