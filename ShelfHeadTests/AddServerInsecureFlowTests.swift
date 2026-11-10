import XCTest
@testable import ShelfHead

/// UX-4 (docs/design-review.md, Batch 355): Add Server with a plain-HTTP, non-local address
/// closed the sheet silently. `AccountSecuritySettingsView` bound its own account-switch
/// Insecure Connection alert to the same `AuthViewModel.pendingInsecureConnection` that the
/// Add Server sheet raises; that alert tried to present under the open sheet, the sheet came
/// down, and its binding cleared the pending state, so `connect()` read "no error, nothing
/// pending" as success. These pin the two pure rules the fix rests on. The view and the
/// view model themselves aren't driven here (see `CLAUDE.md` > Testing).
@MainActor
final class AddServerInsecureFlowTests: XCTestCase {

    // MARK: - The http:// gate itself (the input to both rules)

    func testPlainHTTPToPublicHostIsGated() {
        XCTAssertTrue(AuthViewModel.requiresInsecureConnectionConfirmation(for: "http://example.com"))
    }

    func testPlainHTTPToTheLocalTestServerIsNotGated() {
        XCTAssertFalse(AuthViewModel.requiresInsecureConnectionConfirmation(for: "http://localhost:13378"))
    }

    // MARK: - Which screen owns the Insecure Connection alert

    func testAccountSecurityAlertIgnoresAnAddServerSignIn() {
        // The Add Server sheet raised the pending connection; no switch is in progress here.
        XCTAssertFalse(AccountSecuritySettingsView.showsAccountSwitchInsecureAlert(
            isSwitching: false, hasPendingInsecureConnection: true))
    }

    func testAccountSecurityAlertShowsForItsOwnSwitch() {
        XCTAssertTrue(AccountSecuritySettingsView.showsAccountSwitchInsecureAlert(
            isSwitching: true, hasPendingInsecureConnection: true))
    }

    func testAccountSecurityAlertStaysHiddenWithNothingPending() {
        XCTAssertFalse(AccountSecuritySettingsView.showsAccountSwitchInsecureAlert(
            isSwitching: true, hasPendingInsecureConnection: false))
    }

    // MARK: - What the form does after login() returns

    func testPendingInsecureConnectionKeepsTheForm() {
        XCTAssertEqual(ServerConnectionRules.signInOutcome(succeeded: false,
                                                           pendingInsecureConnection: true,
                                                           errorMessage: nil),
                       .awaitingInsecureConfirmation)
    }

    func testOnlyARealSuccessDismisses() {
        XCTAssertEqual(ServerConnectionRules.signInOutcome(succeeded: true,
                                                           pendingInsecureConnection: false,
                                                           errorMessage: nil),
                       .succeeded)
    }

    func testTheRegressionCaseShowsAnErrorInsteadOfDismissing() {
        // Not signed in, no error, nothing pending: the exact state the old code dismissed on.
        XCTAssertEqual(ServerConnectionRules.signInOutcome(succeeded: false,
                                                           pendingInsecureConnection: false,
                                                           errorMessage: nil),
                       .failed(ServerConnectionRules.genericSignInFailure))
    }

    func testAnEmptyErrorMessageFallsBackToTheGenericCopy() {
        XCTAssertEqual(ServerConnectionRules.signInOutcome(succeeded: false,
                                                           pendingInsecureConnection: false,
                                                           errorMessage: ""),
                       .failed(ServerConnectionRules.genericSignInFailure))
    }

    func testTheViewModelsErrorIsShownAsIs() {
        XCTAssertEqual(ServerConnectionRules.signInOutcome(succeeded: false,
                                                           pendingInsecureConnection: false,
                                                           errorMessage: "Connection failed. Please check the server URL and try again."),
                       .failed("Connection failed. Please check the server URL and try again."))
    }

    func testPendingWinsEvenIfAStaleErrorIsSet() {
        XCTAssertEqual(ServerConnectionRules.signInOutcome(succeeded: false,
                                                           pendingInsecureConnection: true,
                                                           errorMessage: "old"),
                       .awaitingInsecureConfirmation)
    }
}
