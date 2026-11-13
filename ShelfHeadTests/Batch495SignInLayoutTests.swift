import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 O3): the sign-in page is driven by the server's `authMethods`.
final class Batch495SignInLayoutTests: XCTestCase {
    typealias Rules = ServerConnectionRules

    func testMissingAuthMethodsKeepsTodaysLayout() {
        XCTAssertEqual(Rules.signInLayout(authMethods: nil), .passwordWithSSODisclosure)
    }

    func testLocalOnlyKeepsTodaysLayout() {
        XCTAssertEqual(Rules.signInLayout(authMethods: ["local"]), .passwordWithSSODisclosure)
    }

    func testEmptyOrUnrecognisedMethodsKeepTodaysLayout() {
        XCTAssertEqual(Rules.signInLayout(authMethods: []), .passwordWithSSODisclosure)
        XCTAssertEqual(Rules.signInLayout(authMethods: ["saml"]), .passwordWithSSODisclosure)
    }

    func testOpenIDOnlyIsSingleSignOnOnly() {
        XCTAssertEqual(Rules.signInLayout(authMethods: ["openid"]), .singleSignOnOnly)
        XCTAssertEqual(Rules.signInLayout(authMethods: ["OpenID"]), .singleSignOnOnly)
    }

    func testBothMethodsGivePasswordAndSSOInEitherOrder() {
        XCTAssertEqual(Rules.signInLayout(authMethods: ["local", "openid"]), .passwordAndSSO)
        XCTAssertEqual(Rules.signInLayout(authMethods: ["openid", "local"]), .passwordAndSSO)
    }

    func testLayoutFlags() {
        XCTAssertTrue(Rules.SignInLayout.passwordWithSSODisclosure.showsPasswordFields)
        XCTAssertFalse(Rules.SignInLayout.passwordWithSSODisclosure.showsSSOButtonInline)
        XCTAssertTrue(Rules.SignInLayout.passwordAndSSO.showsPasswordFields)
        XCTAssertTrue(Rules.SignInLayout.passwordAndSSO.showsSSOButtonInline)
        XCTAssertFalse(Rules.SignInLayout.singleSignOnOnly.showsPasswordFields)
        XCTAssertTrue(Rules.SignInLayout.singleSignOnOnly.showsSSOButtonInline)
    }

    func testSSOButtonVisibilityFeedsTheSpinnerRule() {
        XCTAssertFalse(Rules.ssoButtonVisible(layout: .passwordWithSSODisclosure, disclosureExpanded: false))
        XCTAssertTrue(Rules.ssoButtonVisible(layout: .passwordWithSSODisclosure, disclosureExpanded: true))
        XCTAssertTrue(Rules.ssoButtonVisible(layout: .singleSignOnOnly, disclosureExpanded: false))
        XCTAssertTrue(Rules.ssoButtonVisible(layout: .passwordAndSSO, disclosureExpanded: false))
        // O6: with the SSO button always on the page, its own spinner covers the attempt.
        XCTAssertFalse(Rules.statusRowShowsSpinner(connecting: .singleSignOn, page: .signIn,
                                                   ssoOptionsExpanded: Rules.ssoButtonVisible(layout: .passwordAndSSO, disclosureExpanded: false)))
    }

    func testServerStatusButtonTextFlowsToTheTitle() {
        let info = ServerStatusInfo(authMethods: ["openid"], openIDButtonText: "Sign in with Authentik")
        XCTAssertEqual(Rules.singleSignOnButtonTitle(serverText: info.openIDButtonText), "Sign in with Authentik")
    }
}
