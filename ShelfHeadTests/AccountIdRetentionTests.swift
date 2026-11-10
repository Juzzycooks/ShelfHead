import XCTest
@testable import ShelfHead

/// Sign-out fix (6 Oct 2026): signing back in to the same server and username reuses the
/// account id it had before sign-out, so its download scope and queued positions come back.
final class AccountIdRetentionTests: XCTestCase {
    func testIdentityKeyIsStableAndOneWay() {
        let a = AccountStore.identityKey(serverURL: "http://192.168.1.50:13378", username: "demo")
        XCTAssertEqual(a, AccountStore.identityKey(serverURL: "http://192.168.1.50:13378", username: "demo"))
        XCTAssertEqual(a.count, 64)
        XCTAssertFalse(a.contains("192.168"))
        XCTAssertFalse(a.contains("demo"))
    }

    // MARK: Critique 2026-10-06 (harden): scheme-insensitive identity

    func testHttpAndHttpsOfTheSameServerAreOneIdentity() {
        // The http fallback sign-in followed by an https one used to mint a new id.
        let https = AccountStore.identityKey(serverURL: "https://books.example.com", username: "demo")
        XCTAssertEqual(https, AccountStore.identityKey(serverURL: "http://books.example.com", username: "demo"))
        XCTAssertEqual(AccountStore.identityKey(serverURL: "http://192.168.1.50:13378", username: "demo"),
                       AccountStore.identityKey(serverURL: "https://192.168.1.50:13378", username: "demo"))
    }

    func testIdentityIgnoresHostCaseDefaultPortsAndATrailingSlash() {
        XCTAssertEqual(AccountStore.identityAddress("https://Books.Example.com:443/abs/"), "books.example.com/abs")
        XCTAssertEqual(AccountStore.identityAddress("http://books.example.com:80"), "books.example.com")
        XCTAssertEqual(AccountStore.identityAddress("http://books.example.com:13378"), "books.example.com:13378")
    }

    func testDifferentHostPortPathOrUserAreDifferentIdentities() {
        let base = AccountStore.identityKey(serverURL: "https://books.example.com", username: "demo")
        XCTAssertNotEqual(base, AccountStore.identityKey(serverURL: "https://books.example.com", username: "other"))
        XCTAssertNotEqual(base, AccountStore.identityKey(serverURL: "https://other.example.com", username: "demo"))
        XCTAssertNotEqual(base, AccountStore.identityKey(serverURL: "https://books.example.com:8443", username: "demo"))
        XCTAssertNotEqual(base, AccountStore.identityKey(serverURL: "https://books.example.com/abs", username: "demo"))
    }

    func testBatch382IdentityStillResolvesThroughTheLegacyKey() {
        // Batch 382 hashed the exact URL; entries it retained are still read.
        let legacy = AccountStore.legacyIdentityKey(serverURL: "http://books.example.com", username: "demo")
        XCTAssertNotEqual(legacy, AccountStore.identityKey(serverURL: "http://books.example.com", username: "demo"))
        XCTAssertEqual(AccountStore.resolveNewAccountId(identity: legacy, retained: [legacy: "OLD-ID"],
                                                        makeId: { "NEW" }), "OLD-ID")
    }

    func testARetainedIdAlreadyInUseIsNotHandedOutTwice() {
        let identity = AccountStore.identityKey(serverURL: "https://books.example.com", username: "demo")
        XCTAssertEqual(AccountStore.resolveNewAccountId(identity: identity, retained: [identity: "OLD-ID"],
                                                        inUseIds: ["OLD-ID"], makeId: { "NEW" }), "NEW")
    }

    func testTheDownloadScopeKeyIsUnchanged() {
        // The identity changed; the scope key (the download directory's name) did not.
        XCTAssertNotEqual(DownloadPaths.scopeKey(serverURL: "http://books.example.com", accountId: "X"),
                          DownloadPaths.scopeKey(serverURL: "https://books.example.com", accountId: "X"))
    }

    // MARK: Downloads from signed-out servers

    func testScopeKeyBelongsToItsAccountId() {
        let scope = DownloadPaths.scopeKey(serverURL: "https://books.example.com", accountId: "ID-1")
        XCTAssertTrue(AccountStore.scopeKey(scope, belongsToAccountId: "ID-1"))
        XCTAssertFalse(AccountStore.scopeKey(scope, belongsToAccountId: "ID-2"))
        XCTAssertFalse(AccountStore.scopeKey("not base64 !!", belongsToAccountId: "ID-1"))
    }

    func testOnlySignedOutScopesAreReclaimable() {
        let reclaimable = AccountStore.reclaimableRetainedScopes(
            retained: ["old", "saved-again", "live", "unscoped", ""],
            savedScopes: ["saved-again", "live"], currentScope: "live")
        XCTAssertEqual(reclaimable, ["old"])
    }

    func testRetainedIdIsReused() {
        let identity = AccountStore.identityKey(serverURL: "https://books.example.com", username: "demo")
        let id = AccountStore.resolveNewAccountId(identity: identity, retained: [identity: "OLD-ID"],
                                                  makeId: { XCTFail("shouldn't mint"); return "NEW" })
        XCTAssertEqual(id, "OLD-ID")
    }

    func testUnknownServerGetsAFreshId() {
        let identity = AccountStore.identityKey(serverURL: "https://other.example.com", username: "demo")
        let id = AccountStore.resolveNewAccountId(identity: identity, retained: ["something-else": "OLD-ID"],
                                                  makeId: { "NEW" })
        XCTAssertEqual(id, "NEW")
    }
}

/// Critique 2026-10-06 (harden): Settings › Downloads splits "Other accounts" from the signed-out servers' row.
final class SignedOutStorageSplitTests: XCTestCase {
    func testSavedAccountsShareSubtractsSignedOut() {
        XCTAssertEqual(SignedOutStorage.savedAccountsShare(otherScopes: 500, signedOut: 200), 300)
    }

    func testSavedAccountsShareNeverGoesNegative() {
        XCTAssertEqual(SignedOutStorage.savedAccountsShare(otherScopes: 100, signedOut: 300), 0)
    }
}
