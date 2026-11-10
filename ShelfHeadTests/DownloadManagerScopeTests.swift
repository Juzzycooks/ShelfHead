import XCTest
@testable import ShelfHead

/// Targeted tests for the riskiest *pure* logic in `DownloadManager`'s account/server
/// scoping — the part responsible for keeping one account's downloads, paused state,
/// and UserDefaults keys from leaking into another's. The scoping itself is exercised
/// here directly (no AVPlayer/URLSession involved); the actual disk I/O and background
/// session behavior are out of scope for a unit test and remain covered by manual/
/// TestFlight verification, per the existing test target's scope.
/// `@MainActor`: the `DownloadManager` members exercised here are main-actor-isolated.
/// This test target predates that annotation and had never been rebuilt against it.
@MainActor
final class DownloadManagerScopeTests: XCTestCase {

    // MARK: - scopeKey

    func testScopeKeyIsDeterministic() {
        let a = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1")
        let b = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1")
        XCTAssertEqual(a, b)
    }

    func testScopeKeyDiffersByAccount() {
        let a = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1")
        let b = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-2")
        XCTAssertNotEqual(a, b, "Two different accounts on the same server must not share a scope key.")
    }

    func testScopeKeyDiffersByServer() {
        let a = DownloadManager.scopeKey(serverURL: "https://one.example.com", accountId: "user-1")
        let b = DownloadManager.scopeKey(serverURL: "https://two.example.com", accountId: "user-1")
        XCTAssertNotEqual(a, b, "The same account id on two different servers must not share a scope key.")
    }

    func testScopeKeyIsFilesystemAndUserDefaultsSafe() {
        // Base64 can contain '/', '+', '=' — all of which are meaningful in a path
        // component or awkward in a UserDefaults key. scopeKey() must strip them.
        let key = DownloadManager.scopeKey(serverURL: "https://abs.example.com/sub?x=1&y=2", accountId: "weird/id+here=")
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("+"))
        XCTAssertFalse(key.contains("="))
    }

    // MARK: - purgeScopedDefaults (M7: fix unbounded UserDefaults growth on account removal)

    func testPurgeScopedDefaultsRemovesOnlyThatAccountsKeys() {
        let server = "https://abs.example.com"
        let keptScope = DownloadManager.scopeKey(serverURL: server, accountId: "keep-me")
        let removedScope = DownloadManager.scopeKey(serverURL: server, accountId: "remove-me")
        let keptKey = "shelfhead_downloadedItems.\(keptScope)"
        let removedKey = "shelfhead_downloadedItems.\(removedScope)"

        let defaults = UserDefaults.standard
        defaults.set(Data(), forKey: keptKey)
        defaults.set(Data(), forKey: removedKey)
        defer { defaults.removeObject(forKey: keptKey); defaults.removeObject(forKey: removedKey) }

        DownloadManager.purgeScopedDefaults(serverURL: server, accountId: "remove-me")

        XCTAssertNil(defaults.data(forKey: removedKey), "Removed account's scoped key should be gone.")
        XCTAssertNotNil(defaults.data(forKey: keptKey), "A different account's scoped key must survive.")
    }

    // MARK: - parseTaskKey (background URLSession task descriptions → (itemId, track))

    func testParseTaskKeyScopedForm() {
        let parsed = DownloadManager.parseTaskKey("someScope123|item-abc|2")
        XCTAssertEqual(parsed?.id, "item-abc")
        XCTAssertEqual(parsed?.track, 2)
    }

    func testParseTaskKeyLegacyForm() {
        // Pre-3.1 task descriptions had no scope prefix — must still parse.
        let parsed = DownloadManager.parseTaskKey("item-abc|2")
        XCTAssertEqual(parsed?.id, "item-abc")
        XCTAssertEqual(parsed?.track, 2)
    }

    func testParseTaskKeyRejectsGarbage() {
        XCTAssertNil(DownloadManager.parseTaskKey(nil))
        XCTAssertNil(DownloadManager.parseTaskKey(""))
        XCTAssertNil(DownloadManager.parseTaskKey("not-a-valid-key"))
        XCTAssertNil(DownloadManager.parseTaskKey("scope|item|not-a-number"))
    }

    // MARK: - parseScopedTaskKey (CRIT-2: in-flight task adoption at bootstrap)

    func testParseScopedTaskKeyScopedForm() {
        let parsed = DownloadManager.parseScopedTaskKey("someScope123|item-abc|2")
        XCTAssertEqual(parsed?.scope, "someScope123")
        XCTAssertEqual(parsed?.id, "item-abc")
        XCTAssertEqual(parsed?.track, 2)
    }

    func testParseScopedTaskKeyLegacyFormHasEmptyScope() {
        // A legacy (pre-3.1, no-scope) task description must parse with an empty
        // scope rather than nil/failing — `adoptInFlightDownloads` treats an empty
        // scope as "adopt regardless," matching `DownloadSessionDelegate.isForeignScope`'s
        // existing legacy-task handling.
        let parsed = DownloadManager.parseScopedTaskKey("item-abc|2")
        XCTAssertEqual(parsed?.scope, "")
        XCTAssertEqual(parsed?.id, "item-abc")
        XCTAssertEqual(parsed?.track, 2)
    }

    func testParseScopedTaskKeyRejectsGarbage() {
        XCTAssertNil(DownloadManager.parseScopedTaskKey(nil))
        XCTAssertNil(DownloadManager.parseScopedTaskKey(""))
        XCTAssertNil(DownloadManager.parseScopedTaskKey("not-a-valid-key"))
        XCTAssertNil(DownloadManager.parseScopedTaskKey("scope|item|not-a-number"))
    }

    // MARK: - DownloadFailure (ARCH-5: failed downloads must survive a relaunch)

    func testDownloadFailureRoundTripsThroughJSON() throws {
        let original = DownloadManager.DownloadFailure(
            itemId: "item-1", title: "Test Book", message: "The connection kept dropping."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DownloadManager.DownloadFailure.self, from: data)
        XCTAssertEqual(decoded.itemId, original.itemId)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.message, original.message)
        XCTAssertEqual(decoded.id, "item-1")
    }

    func testDownloadFailureDictionaryRoundTripsThroughJSON() throws {
        // This is the actual shape persisted (`[String: DownloadFailure]`), not a bare
        // array — confirms the dictionary itself, not just the element, round-trips.
        let original = [
            "item-1": DownloadManager.DownloadFailure(itemId: "item-1", title: "A", message: "m1"),
            "item-2": DownloadManager.DownloadFailure(itemId: "item-2", title: "B", message: "m2"),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: DownloadManager.DownloadFailure].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded["item-1"]?.title, "A")
        XCTAssertEqual(decoded["item-2"]?.message, "m2")
    }
}
