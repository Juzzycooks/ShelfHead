import XCTest
import Security
@testable import ShelfHead

/// Pins the two pure decision functions extracted from `KeychainService` for items 4 and 5
/// (REVIEW-2026-09-09-REMAINING.md).
///
/// Deliberately *only* the pure logic: the simulator test host has no Keychain entitlement
/// of its own, so exercising `SecItemAdd`/`SecItemUpdate`/`SecItemDelete` here would be
/// testing the host's provisioning rather than this app's behaviour. Following the
/// project's existing precedent (`DownloadManager.shouldReclaimOrphanDirectory`), the
/// decision is separated from the I/O and the decision is what gets tested.
final class KeychainServiceDecisionTests: XCTestCase {

    // MARK: - Item 4: update-first write ordering

    /// A successful `SecItemUpdate` is the whole write. Nothing else may run — in
    /// particular no `SecItemDelete`.
    func testWriteRecoveryForSuccessIsDone() {
        XCTAssertEqual(KeychainService.writeRecovery(forUpdateStatus: errSecSuccess), .done)
    }

    /// The regression this fix exists for: "item isn't there" must take the plain add
    /// path, never the delete-then-add path. `errSecItemNotFound` is by far the most
    /// common non-success status here (every first write of every key hits it), so
    /// mapping it to `.deleteThenAdd` would put essentially every write back on the
    /// lossy path.
    func testWriteRecoveryForItemNotFoundIsAddNotDeleteThenAdd() {
        let recovery = KeychainService.writeRecovery(forUpdateStatus: errSecItemNotFound)
        XCTAssertEqual(recovery, .add)
        XCTAssertNotEqual(recovery, .deleteThenAdd)
    }

    /// Any other failing status falls back to delete-then-add — the old behaviour, now
    /// reached only after an update has actually been attempted.
    func testWriteRecoveryForOtherFailuresIsDeleteThenAdd() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDuplicateItem,
                       errSecMissingEntitlement, errSecParam, OSStatus(-99999)] {
            XCTAssertEqual(KeychainService.writeRecovery(forUpdateStatus: status),
                           .deleteThenAdd,
                           "status \(status) should fall back to delete-then-add")
        }
    }

    // MARK: - Item 5: best-effort deleteAll aggregation

    /// Every key deleted cleanly → no error at all.
    func testDeleteOutcomeAllSuccessIsNil() {
        let results = KeychainService.primaryKeys.map { (key: $0.rawValue, status: errSecSuccess) }
        XCTAssertNil(KeychainService.deleteOutcome(for: results))
    }

    /// An empty run is vacuously successful rather than an error.
    func testDeleteOutcomeEmptyIsNil() {
        XCTAssertNil(KeychainService.deleteOutcome(for: []))
    }

    /// `errSecItemNotFound` is success: the desired end state is "this key is not in the
    /// Keychain", and a key that was never written is already in that state. Treating it
    /// as a failure would make a normal sign-out report a problem on any account that
    /// never had, say, a refresh token.
    func testDeleteOutcomeNotFoundCountsAsSuccess() {
        let results: [(key: String, status: OSStatus)] = [
            ("auth_token", errSecSuccess),
            ("refresh_token", errSecItemNotFound),
            ("password", errSecSuccess)
        ]
        XCTAssertNil(KeychainService.deleteOutcome(for: results))
    }

    /// One genuine failure among successes is reported — and only that one key, so the
    /// caller's message names what actually survived rather than everything it tried.
    func testDeleteOutcomeSingleRealFailureAmongSuccesses() {
        let results: [(key: String, status: OSStatus)] = [
            ("server_url", errSecSuccess),
            ("auth_token", errSecInteractionNotAllowed),
            ("refresh_token", errSecItemNotFound),
            ("password", errSecSuccess)
        ]
        guard case .bulkDeleteFailed(let failures)? = KeychainService.deleteOutcome(for: results) else {
            return XCTFail("Expected a bulkDeleteFailed outcome")
        }
        XCTAssertEqual(failures, [KeychainDeleteFailure(key: "auth_token", status: errSecInteractionNotAllowed)])
    }

    /// The point of item 5: a failure on the *first* key must not hide the keys after it.
    /// The old `for … { try delete(key) }` threw on `server_url` and never attempted the
    /// rest, so `auth_token` and `password` stayed on the device unreported.
    func testDeleteOutcomeFailureOnFirstKeyStillReportsLaterFailures() {
        let results: [(key: String, status: OSStatus)] = [
            ("server_url", errSecInteractionNotAllowed),
            ("auth_token", errSecSuccess),
            ("password", errSecAuthFailed)
        ]
        guard case .bulkDeleteFailed(let failures)? = KeychainService.deleteOutcome(for: results) else {
            return XCTFail("Expected a bulkDeleteFailed outcome")
        }
        XCTAssertEqual(failures.map(\.key), ["server_url", "password"])
    }

    /// All keys failing reports all of them, in the order they were attempted.
    func testDeleteOutcomeAllFailuresReportsEveryKey() {
        let results = KeychainService.primaryKeys.map {
            (key: $0.rawValue, status: errSecInteractionNotAllowed)
        }
        guard case .bulkDeleteFailed(let failures)? = KeychainService.deleteOutcome(for: results) else {
            return XCTFail("Expected a bulkDeleteFailed outcome")
        }
        XCTAssertEqual(failures.count, KeychainService.primaryKeys.count)
        XCTAssertEqual(failures.map(\.key), KeychainService.primaryKeys.map(\.rawValue))
        XCTAssertTrue(failures.allSatisfy { $0.status == errSecInteractionNotAllowed })
    }

    /// The aggregate error's message has to name the keys and their statuses — that string
    /// is what reaches the log line in `AuthViewModel.logout()`, and the OSStatus is the
    /// part that distinguishes "device locked mid-sign-out" from a provisioning problem.
    func testBulkDeleteErrorDescriptionNamesKeysAndStatuses() {
        let error = KeychainError.bulkDeleteFailed([
            KeychainDeleteFailure(key: "auth_token", status: errSecInteractionNotAllowed),
            KeychainDeleteFailure(key: "password", status: errSecAuthFailed)
        ])
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("auth_token"), description)
        XCTAssertTrue(description.contains("password"), description)
        XCTAssertTrue(description.contains("\(errSecInteractionNotAllowed)"), description)
        XCTAssertTrue(description.contains("2"), description)
    }

    // MARK: - Key set / accessibility invariants

    /// `deleteAll()` clears the session keys but deliberately not `.accounts` — the saved
    /// server list is removed by `AuthViewModel.logout()` in its own step, and the Watch's
    /// sign-out calls `deleteAll()` expecting only the session keys to go.
    func testPrimaryKeysCoverSessionKeysButNotAccounts() {
        let keys = Set(KeychainService.primaryKeys)
        XCTAssertEqual(keys, [.serverURL, .authToken, .refreshToken, .username, .password, .userId, .customHeaders])
        XCTAssertFalse(keys.contains(.accounts))
    }

    /// The password's tighter accessibility class must survive the move to an
    /// update-first write path: `kSecAttrAccessible` is passed in `SecItemUpdate`'s
    /// *attributes* dictionary precisely so an item stored under the older
    /// `AfterFirstUnlock` class gets re-tightened on its next write.
    func testPasswordAccessibilityIsWhenUnlockedAndTokensAreAfterFirstUnlock() {
        // Compared as bridged `String`s: `CFString` is an imported class type and doesn't
        // carry an `Equatable` conformance for `XCTAssertEqual` to use.
        XCTAssertEqual(KeychainService.KeychainKey.password.accessibility as String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        for key in [KeychainService.KeychainKey.authToken, .refreshToken, .serverURL, .accounts] {
            XCTAssertEqual(key.accessibility as String,
                           kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                           "\(key.rawValue) should stay readable for background token refresh")
        }
    }
}
