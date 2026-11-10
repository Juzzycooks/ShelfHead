import XCTest
import Security
@testable import ShelfHead

/// Polish pass (J1-1, J1-2, J1-5, J1-6, CR-4, ST-12): pins the pure decisions behind the
/// sign-in / session-expired fixes. The stateful paths (the refresh actor, the Keychain,
/// the sheet) are device-checked; these pin what they decide (see `CLAUDE.md` > Testing).
final class PolishAuthTests: XCTestCase {

    // MARK: J1-1 — when the API signals "session expired"

    func testSignalsOnlyForARejectedRefreshOfTheCurrentPersistedSession() {
        XCTAssertTrue(AudiobookshelfAPI.shouldSignalSessionExpired(
            outcome: .rejected, persistsCredentials: true, isConfigured: true,
            refreshGeneration: 3, currentGeneration: 3))
    }

    func testNoSignalForANetworkFailureOrASuccessfulRefresh() {
        for outcome in [RefreshOutcome.couldNotComplete, .refreshed] {
            XCTAssertFalse(AudiobookshelfAPI.shouldSignalSessionExpired(
                outcome: outcome, persistsCredentials: true, isConfigured: true,
                refreshGeneration: 1, currentGeneration: 1), "\(outcome)")
        }
    }

    func testNoSignalForAStaleGenerationAnUnconfiguredStoreOrATransientClient() {
        // The session moved on (login, switch, sign-out) while the refresh ran.
        XCTAssertFalse(AudiobookshelfAPI.shouldSignalSessionExpired(
            outcome: .rejected, persistsCredentials: true, isConfigured: true,
            refreshGeneration: 2, currentGeneration: 3))
        // Signed out: nothing to sign back into.
        XCTAssertFalse(AudiobookshelfAPI.shouldSignalSessionExpired(
            outcome: .rejected, persistsCredentials: true, isConfigured: false,
            refreshGeneration: 1, currentGeneration: 1))
        // A throwaway client (e.g. Other Servers) isn't the app's session.
        XCTAssertFalse(AudiobookshelfAPI.shouldSignalSessionExpired(
            outcome: .rejected, persistsCredentials: false, isConfigured: true,
            refreshGeneration: 1, currentGeneration: 1))
    }

    // MARK: J1-1 — when the view model raises the sheet

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func present(isAuthenticated: Bool = true, isSigningIn: Bool = false,
                         verifying: Bool = false, isPresented: Bool = false,
                         dismissedAt: Date? = nil) -> Bool {
        AuthViewModel.shouldPresentSessionExpired(
            isAuthenticated: isAuthenticated, isSigningIn: isSigningIn,
            isVerifyingRestoredSession: verifying, isPresented: isPresented,
            dismissedAt: dismissedAt, now: now)
    }

    func testPresentsForASignedInIdleSession() {
        XCTAssertTrue(present())
    }

    func testDoesNotPresentWhenSignedOutSigningInOrVerifyingAtLaunch() {
        XCTAssertFalse(present(isAuthenticated: false))
        XCTAssertFalse(present(isSigningIn: true))
        XCTAssertFalse(present(verifying: true))
    }

    func testABurstOfRefusalsRaisesTheSheetOnce() {
        XCTAssertFalse(present(isPresented: true))
    }

    func testNotNowSnoozesForTenMinutes() {
        XCTAssertEqual(AuthViewModel.sessionExpiredSnooze, 600)
        XCTAssertFalse(present(dismissedAt: now.addingTimeInterval(-60)))
        XCTAssertFalse(present(dismissedAt: now.addingTimeInterval(-599)))
        XCTAssertTrue(present(dismissedAt: now.addingTimeInterval(-600)))
    }

    // MARK: J1-1 — signing in again must be the same account

    func testSameAccountComparesServerUserIdWhenKnown() {
        XCTAssertTrue(AuthViewModel.isSameAccount(expectedUserId: "u1", expectedUsername: "justin",
                                                  signedInUserId: "u1", signedInUsername: "renamed"))
        XCTAssertFalse(AuthViewModel.isSameAccount(expectedUserId: "u1", expectedUsername: "justin",
                                                   signedInUserId: "u2", signedInUsername: "justin"))
    }

    func testSameAccountFallsBackToCaseInsensitiveUsername() {
        XCTAssertTrue(AuthViewModel.isSameAccount(expectedUserId: nil, expectedUsername: "Justin",
                                                  signedInUserId: "u9", signedInUsername: "justin "))
        XCTAssertTrue(AuthViewModel.isSameAccount(expectedUserId: "", expectedUsername: "justin",
                                                  signedInUserId: "u9", signedInUsername: "JUSTIN"))
        XCTAssertFalse(AuthViewModel.isSameAccount(expectedUserId: nil, expectedUsername: "justin",
                                                   signedInUserId: "u9", signedInUsername: "kid"))
    }

    // MARK: J1-5 / ST-12 — sign-in error copy

    private func message(_ error: Error, online: Bool = true) -> String {
        AuthViewModel.signInErrorMessage(for: error, serverURL: "https://abs.example.com", deviceIsOnline: online)
    }

    func testRealUnauthorizedStaysIncorrectUsernameOrPassword() {
        XCTAssertEqual(message(APIError.unauthorized), String(localized: "Incorrect username or password."))
    }

    func testTransportFailuresReuseTheConnectionTestCopy() {
        for code in [URLError.Code.timedOut, .serverCertificateUntrusted, .cannotFindHost, .cannotConnectToHost] {
            let failure = ServerConnectionFailure.classify(code, deviceIsOnline: true)
            let advice = ServerConnectionRules.failureAdvice(failure: failure, resolvedURL: "https://abs.example.com",
                                                            triedPlainHTTP: false)
            XCTAssertEqual(message(URLError(code)), "\(advice.message) \(advice.nextStep)", "\(code)")
        }
    }

    func testDistinctTransportFailuresGetDistinctCopy() {
        let lines = Set([URLError.Code.timedOut, .serverCertificateUntrusted, .cannotFindHost].map { message(URLError($0)) })
        XCTAssertEqual(lines.count, 3)
    }

    func testOfflineSaysOfflineOnlyWhenTheDeviceIsOffline() {
        let offline = message(URLError(.notConnectedToInternet), online: false)
        XCTAssertTrue(offline.hasPrefix("You\u{2019}re offline"), offline)
        let online = message(URLError(.notConnectedToInternet), online: true)
        XCTAssertFalse(online.hasPrefix("You\u{2019}re offline"), online)
    }

    func testNonAudiobookshelfRepliesSaySo() {
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "HTML"))
        XCTAssertEqual(message(decoding), AuthViewModel.notAudiobookshelfMessage)
        XCTAssertEqual(message(APIError.decodingError(decoding)), AuthViewModel.notAudiobookshelfMessage)
        XCTAssertEqual(message(APIError.httpError(418)), AuthViewModel.notAudiobookshelfMessage)
        XCTAssertNotEqual(message(APIError.serverError(502)), AuthViewModel.notAudiobookshelfMessage)
    }

    func testOIDCConnectionFailureIsClassifiedLikeAnyOtherTransportError() {
        XCTAssertEqual(message(OIDCAuthService.OIDCError.connectionFailed(URLError(.timedOut))),
                       message(URLError(.timedOut)))
    }

    func testNoSignInMessageLeaksTechnicalDetail() {
        let errors: [Error] = [APIError.serverError(500), APIError.httpError(404), APIError.invalidResponse,
                               URLError(.timedOut), URLError(.badServerResponse), NSError(domain: "x", code: 42)]
        for error in errors {
            let line = message(error)
            XCTAssertFalse(line.contains("500") || line.contains("404") || line.contains("42") || line.contains("NSURLError"), line)
        }
    }

    // MARK: ST-5 — APIError descriptions

    func testAPIErrorDescriptionsCarryNoStatusCodes() {
        XCTAssertFalse(APIError.serverError(503).errorDescription?.contains("503") ?? true)
        XCTAssertFalse(APIError.httpError(409).errorDescription?.contains("409") ?? true)
        let decoding = APIError.decodingError(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "keyNotFound")))
        XCTAssertFalse(decoding.errorDescription?.contains("keyNotFound") ?? true)
    }

    // MARK: J1-6 — usernames are trimmed, passwords aren't

    func testNormalizedUsernameTrimsSpacesAndNewlines() {
        XCTAssertEqual(AuthViewModel.normalizedUsername("  justin \n"), "justin")
        XCTAssertEqual(AuthViewModel.normalizedUsername("jus tin"), "jus tin")
    }

    func testWhitespaceOnlyUsernameCannotSubmit() {
        XCTAssertFalse(ServerConnectionRules.canSubmitPassword(serverURL: "https://abs.example.com",
                                                               username: " \n", password: "pw"))
        // A password made of spaces is still a password.
        XCTAssertTrue(ServerConnectionRules.canSubmitPassword(serverURL: "https://abs.example.com",
                                                              username: "justin", password: "   "))
    }

    // MARK: CR-4 — a locked Keychain is not "signed out"

    func testLockedKeychainKeepsWaiting() {
        XCTAssertEqual(AuthViewModel.keychainReadRetryDelay(afterAttempt: 1, status: errSecInteractionNotAllowed), 2)
        XCTAssertEqual(AuthViewModel.keychainReadRetryDelay(afterAttempt: 149, status: errSecInteractionNotAllowed), 2)
        XCTAssertNil(AuthViewModel.keychainReadRetryDelay(afterAttempt: 150, status: errSecInteractionNotAllowed))
    }

    func testOtherKeychainErrorsRetryBriefly() {
        XCTAssertEqual(AuthViewModel.keychainReadRetryDelay(afterAttempt: 1, status: errSecInternalError), 0.5)
        XCTAssertEqual(AuthViewModel.keychainReadRetryDelay(afterAttempt: 2, status: errSecInternalError), 0.5)
        XCTAssertNil(AuthViewModel.keychainReadRetryDelay(afterAttempt: 3, status: errSecInternalError))
    }

    // MARK: J1-3 / J1-4 — sign-in timeouts

    func testSignInAndRefreshTimeoutsAreShorterThanSend() {
        XCTAssertEqual(AudiobookshelfAPI.signInTimeout, 20)
        XCTAssertEqual(AudiobookshelfAPI.refreshTimeout, 15)
    }

    // MARK: J1-2 — cold-launch prefill copy

    func testSessionEndedPrefillNamesTheHost() {
        let prefill = AuthViewModel.SessionEndedPrefill(serverURL: "https://abs.example.com", username: "justin",
                                                        customHeaders: [:])
        XCTAssertTrue(prefill.message.contains("abs.example.com"), prefill.message)
    }
}
