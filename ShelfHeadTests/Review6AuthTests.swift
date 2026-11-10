import XCTest
@testable import ShelfHead

/// Review 6 Medium 1: the stored-credentials re-login is tri-state.
final class Review6AuthTests: XCTestCase {
    private func classify(keychainFailed: Bool = false, has: Bool = true, ok: Bool = false, error: Error? = nil) -> RefreshOutcome {
        AudiobookshelfAPI.classifyReauthResult(keychainReadFailed: keychainFailed, hasStoredCredentials: has,
                                               loginSucceeded: ok, loginError: error)
    }

    func testKeychainReadErrorCouldNotComplete() {
        XCTAssertEqual(classify(keychainFailed: true, has: false), .couldNotComplete)
    }

    func testNoStoredCredentialsRejected() {
        XCTAssertEqual(classify(has: false), .rejected)
    }

    func testLoginSuccessRefreshed() {
        XCTAssertEqual(classify(ok: true), .refreshed)
    }

    func testLogin401And403Rejected() {
        XCTAssertEqual(classify(error: APIError.unauthorized), .rejected)
        XCTAssertEqual(classify(error: APIError.forbidden), .rejected)
    }

    func testTransientLoginFailuresCouldNotComplete() {
        XCTAssertEqual(classify(error: URLError(.timedOut)), .couldNotComplete)
        XCTAssertEqual(classify(error: APIError.serverError(503)), .couldNotComplete)
        XCTAssertEqual(classify(error: APIError.invalidResponse), .couldNotComplete)
        XCTAssertEqual(classify(error: AccountChangedError()), .couldNotComplete)
    }
}
