import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): a server switch that fails, or can't start, says so where
/// it was started. Pins the pure decisions and copy behind `AuthViewModel.switchAccount`'s
/// result, `ServerSwitchFlow`, and the first-run screen's password-needed line.
@MainActor
final class ServerSwitchOutcomeTests: XCTestCase {

    private typealias Failure = AuthViewModel.AccountSwitchFailure

    // MARK: - Which question a saved-server tap asks first

    func testNoStoredPasswordAsksForItInsteadOfOfferingSwitch() {
        XCTAssertEqual(AuthViewModel.switchEntry(for: .unavailable), .askForPassword)
    }

    func testStoredPasswordAndSSOConfirmTheSwitch() {
        XCTAssertEqual(AuthViewModel.switchEntry(for: .password("pw")), .confirmSwitch)
        XCTAssertEqual(AuthViewModel.switchEntry(for: .singleSignOn), .confirmSwitch)
    }

    // MARK: - Reachability check before the teardown

    private func result(_ outcome: ReachabilityStore.ConnectionTestResult.Outcome,
                        _ failure: ServerConnectionFailure? = nil) -> ReachabilityStore.ConnectionTestResult {
        ReachabilityStore.ConnectionTestResult(outcome: outcome, resolvedURL: "https://abs.example.org",
                                               failure: failure)
    }

    func testTransportFailuresStopTheSwitchBeforeTheBookStops() {
        for failure: ServerConnectionFailure in [.secureConnection, .timedOut, .hostNotFound, .cannotConnect, .offline] {
            XCTAssertTrue(AuthViewModel.switchPreflightBlocks(result(.unreachable, failure)), "\(failure)")
        }
        XCTAssertTrue(AuthViewModel.switchPreflightBlocks(result(.invalidURL)))
    }

    func testAProxyGateDoesNotStopTheSwitch() {
        // A gate can turn `/ping` away while the sign-in works ("Sign in anyway").
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.unreachable, .httpStatus(401))))
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.unreachable, .httpStatus(503))))
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.notAudiobookshelf)))
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.unreachable, .other)))
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.unreachable, nil)))
    }

    func testAReachableServerGoesOnToSignIn() {
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.reachable)))
        XCTAssertFalse(AuthViewModel.switchPreflightBlocks(result(.reachableInsecure)))
    }

    // MARK: - What the surface does next

    func testFollowUpForEachOutcome() {
        XCTAssertEqual(ServerSwitchConfirmation.followUp(for: .switched), .none)
        XCTAssertEqual(ServerSwitchConfirmation.followUp(for: .cancelled), .none)
        XCTAssertEqual(ServerSwitchConfirmation.followUp(for: .needsPassword), .askForPassword)
        XCTAssertEqual(ServerSwitchConfirmation.followUp(for: .awaitingInsecureConfirmation), .confirmInsecureConnection)
        let failure = Failure(targetHost: "b", currentHost: "a", stoppedPlayback: false,
                              stoppedBookTitle: nil, reason: .signInFailed("x"))
        XCTAssertEqual(ServerSwitchConfirmation.followUp(for: .failed(failure)), .showFailure(failure))
    }

    // MARK: - Failure copy

    func testTitleNamesTheTarget() {
        XCTAssertEqual(ServerSwitchFailureCopy.title(host: "abs.example.org"), "Couldn\u{2019}t Switch to abs.example.org")
    }

    func testUnreachableSaysNothingChangedAndWhereYouAre() {
        let failure = Failure(targetHost: "abs.example.org", currentHost: "home.example.org",
                              stoppedPlayback: false, stoppedBookTitle: nil,
                              reason: .unreachable(failure: .timedOut, resolvedURL: "https://abs.example.org"))
        XCTAssertEqual(
            ServerSwitchFailureCopy.message(failure),
            "The server didn\u{2019}t answer in time. Check the server is running and the port is right. If you reach it over a VPN or Tailscale, make sure that\u{2019}s connected. Nothing changed. You\u{2019}re still on home.example.org.")
    }

    func testOfflineAndTLSAreWordedForASavedServer() {
        let offline = ServerSwitchFailureCopy.reason(.unreachable(failure: .offline, resolvedURL: "https://abs.example.org"))
        XCTAssertTrue(offline.hasSuffix("then try again."))
        XCTAssertFalse(offline.contains("test again"))
        let tls = ServerSwitchFailureCopy.reason(.unreachable(failure: .secureConnection, resolvedURL: "https://abs.example.org"))
        XCTAssertFalse(tls.contains("plain http"))
    }

    func testSignInFailureAfterTeardownNamesTheStoppedBook() {
        let failure = Failure(targetHost: "abs.example.org", currentHost: "home.example.org",
                              stoppedPlayback: true, stoppedBookTitle: "Dune",
                              reason: .signInFailed("Incorrect username or password."))
        XCTAssertEqual(
            ServerSwitchFailureCopy.message(failure),
            "Incorrect username or password. You\u{2019}re still on home.example.org. \u{201C}Dune\u{201D} stopped and Up Next was cleared; your place in it is saved.")
    }

    func testSignInFailureAfterTeardownWithNoBook() {
        let failure = Failure(targetHost: "b", currentHost: "a", stoppedPlayback: true,
                              stoppedBookTitle: "  ", reason: .signInFailed("Something went wrong. Please try again."))
        XCTAssertEqual(ServerSwitchFailureCopy.message(failure),
                       "Something went wrong. Please try again. You\u{2019}re still on a. Up Next was cleared.")
    }

    func testNobodySignedInGetsJustTheReason() {
        let failure = Failure(targetHost: "abs.example.org", currentHost: nil, stoppedPlayback: false,
                              stoppedBookTitle: nil, reason: .signInFailed("Incorrect username or password."))
        XCTAssertEqual(ServerSwitchFailureCopy.message(failure), "Incorrect username or password.")
        XCTAssertEqual(ServerSwitchFailureCopy.inlineMessage(failure),
                       "Couldn\u{2019}t sign in to abs.example.org. Incorrect username or password.")
    }

    // MARK: - Password-needed line

    func testPasswordNeededPromptSaysWhatsNeeded() {
        XCTAssertEqual(ServerConnectionRules.passwordNeededPrompt(username: "demo", host: "abs.example.org",
                                                                  switchesAccount: true),
                       "No password is saved for demo on abs.example.org. Enter it to switch to it.")
        XCTAssertEqual(ServerConnectionRules.passwordNeededPrompt(username: "demo", host: "abs.example.org",
                                                                  switchesAccount: false),
                       "No password is saved for demo on abs.example.org. Enter it to sign in.")
    }
}
