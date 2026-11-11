import XCTest
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 O1, O4, O5, O6, F8): the pure decisions behind the sign-in
/// and session quick wins. `@MainActor` for `ReachabilityStore.ConnectionTestResult`, which is
/// nested in a `@MainActor` class (same reason as `LoginAddServerMergeTests`).
@MainActor
final class QuickWinsSignInTests: XCTestCase {

    // MARK: - O1 session-ended pill

    func testSessionEndedPillShowsOnlyWhenSessionNeedsSignInAndNothingCoversIt() {
        XCTAssertTrue(ConnectivityCopy.showsSessionEndedPill(sessionNeedsSignIn: true, isPromptPresented: false,
                                                             isLocked: false, status: .ok))
        XCTAssertTrue(ConnectivityCopy.showsSessionEndedPill(sessionNeedsSignIn: true, isPromptPresented: false,
                                                             isLocked: false, status: .serverUnreachable))
        XCTAssertFalse(ConnectivityCopy.showsSessionEndedPill(sessionNeedsSignIn: false, isPromptPresented: false,
                                                              isLocked: false, status: .ok))
        // The sheet itself is up.
        XCTAssertFalse(ConnectivityCopy.showsSessionEndedPill(sessionNeedsSignIn: true, isPromptPresented: true,
                                                              isLocked: false, status: .ok))
        // Never over App Lock.
        XCTAssertFalse(ConnectivityCopy.showsSessionEndedPill(sessionNeedsSignIn: true, isPromptPresented: false,
                                                              isLocked: true, status: .ok))
        // Offline outranks it.
        XCTAssertFalse(ConnectivityCopy.showsSessionEndedPill(sessionNeedsSignIn: true, isPromptPresented: false,
                                                              isLocked: false, status: .offline))
    }

    func testSessionEndedMessageNamesTheHost() {
        XCTAssertEqual(ConnectivityCopy.sessionEndedMessage(host: "abs.example.com"), "Signed out of abs.example.com")
        XCTAssertEqual(ConnectivityCopy.sessionEndedMessage(host: nil), "Signed out of your server")
        XCTAssertEqual(ConnectivityCopy.sessionEndedMessage(host: ""), "Signed out of your server")
    }

    func testReopenSessionExpiredPromptGuard() {
        XCTAssertTrue(AuthViewModel.canReopenSessionExpiredPrompt(sessionNeedsSignIn: true, isAuthenticated: true,
                                                                  isPresented: false, isSigningIn: false))
        XCTAssertFalse(AuthViewModel.canReopenSessionExpiredPrompt(sessionNeedsSignIn: false, isAuthenticated: true,
                                                                   isPresented: false, isSigningIn: false))
        XCTAssertFalse(AuthViewModel.canReopenSessionExpiredPrompt(sessionNeedsSignIn: true, isAuthenticated: false,
                                                                   isPresented: false, isSigningIn: false))
        XCTAssertFalse(AuthViewModel.canReopenSessionExpiredPrompt(sessionNeedsSignIn: true, isAuthenticated: true,
                                                                   isPresented: true, isSigningIn: false))
        XCTAssertFalse(AuthViewModel.canReopenSessionExpiredPrompt(sessionNeedsSignIn: true, isAuthenticated: true,
                                                                   isPresented: false, isSigningIn: true))
    }

    // MARK: - O4 redirect URI not allowed

    func testInitiationFailureMapsOnlyTheRedirectURIRefusal() {
        // Audiobookshelf's own answer (Auth.js / OidcAuthStrategy.getAuthorizationUrl).
        let refusal = Data("Invalid redirect_uri".utf8)
        guard case .redirectURINotAllowed = OIDCAuthService.initiationFailure(statusCode: 400, body: refusal) else {
            return XCTFail("400 Invalid redirect_uri should map to redirectURINotAllowed")
        }
        // Other 400s from the same endpoint stay generic.
        for body in ["Invalid response_type, only code supported",
                     "code_challenge required for mobile flow (PKCE)",
                     "Only S256 code_challenge_method method supported",
                     #"{"error":"Invalid callback URL - must be same-origin"}"#] {
            guard case .noAuthorizationRedirect = OIDCAuthService.initiationFailure(statusCode: 400, body: Data(body.utf8)) else {
                return XCTFail("\(body) should stay noAuthorizationRedirect")
            }
        }
        // The same words with another status (a proxy page, a 500) stay generic too.
        guard case .noAuthorizationRedirect = OIDCAuthService.initiationFailure(statusCode: 500, body: refusal),
              case .noAuthorizationRedirect = OIDCAuthService.initiationFailure(statusCode: 200, body: refusal),
              case .noAuthorizationRedirect = OIDCAuthService.initiationFailure(statusCode: nil, body: refusal),
              case .noAuthorizationRedirect = OIDCAuthService.initiationFailure(statusCode: 400, body: Data()) else {
            return XCTFail("Only a 400 with the redirect_uri body maps to redirectURINotAllowed")
        }
    }

    func testRedirectURIErrorNamesTheSettingAndTheAddress() {
        XCTAssertEqual(OIDCAuthService.redirectURI, "shelfhead-oidc://oauth")
        let message = OIDCAuthService.OIDCError.redirectURINotAllowed.errorDescription ?? ""
        XCTAssertTrue(message.contains("Allowed Mobile Redirect URIs"))
        XCTAssertTrue(message.contains("shelfhead-oidc://oauth"))
        XCTAssertTrue(message.contains(OIDCAuthService.redirectURISetupInstruction))
        // The sign-in error path shows it unchanged, and the form offers Copy for it only.
        XCTAssertEqual(AuthViewModel.signInErrorMessage(for: OIDCAuthService.OIDCError.redirectURINotAllowed,
                                                        serverURL: "https://abs.example.com", deviceIsOnline: true),
                       message)
        XCTAssertTrue(ServerConnectionRules.errorOffersRedirectURICopy(message))
        XCTAssertFalse(ServerConnectionRules.errorOffersRedirectURICopy(
            OIDCAuthService.OIDCError.noAuthorizationRedirect.errorDescription))
        XCTAssertFalse(ServerConnectionRules.errorOffersRedirectURICopy(nil))
    }

    // MARK: - O5 profile picker

    func testProfilePickerFinishesOnlyOnTheChosenAccount() {
        XCTAssertTrue(ProfilePickerView.switchLanded(targetId: "a", currentAccountId: "a", isAuthenticated: true))
        XCTAssertFalse(ProfilePickerView.switchLanded(targetId: "a", currentAccountId: "b", isAuthenticated: true))
        XCTAssertFalse(ProfilePickerView.switchLanded(targetId: "a", currentAccountId: "a", isAuthenticated: false))
        XCTAssertFalse(ProfilePickerView.switchLanded(targetId: "a", currentAccountId: nil, isAuthenticated: true))
    }

    // MARK: - O6 one spinner per attempt

    func testStatusRowSpinnerOnlyWhenNoButtonIsSpinning() {
        typealias Rules = ServerConnectionRules
        XCTAssertFalse(Rules.statusRowShowsSpinner(connecting: nil, page: .signIn, ssoOptionsExpanded: true))
        XCTAssertFalse(Rules.statusRowShowsSpinner(connecting: .password, page: .signIn, ssoOptionsExpanded: false))
        XCTAssertFalse(Rules.statusRowShowsSpinner(connecting: .singleSignOn, page: .signIn, ssoOptionsExpanded: true))
        XCTAssertTrue(Rules.statusRowShowsSpinner(connecting: .singleSignOn, page: .signIn, ssoOptionsExpanded: false))
        XCTAssertTrue(Rules.statusRowShowsSpinner(connecting: .password, page: .server, ssoOptionsExpanded: false))
    }

    // MARK: - F8 /status

    private func status(_ json: String) -> ServerStatusInfo? {
        ReachabilityStore.parseServerStatus(from: Data(json.utf8))
    }

    func testParsesAFullStatusAnswer() {
        let info = status(#"""
        {"app":"audiobookshelf","serverVersion":"2.17.2","isInit":true,"language":"en-us",
         "authMethods":["local","openid"],
         "authFormData":{"authLoginCustomMessage":"<p>Welcome to <strong>the family</strong> library &amp; more</p>",
                         "authOpenIDButtonText":"Sign in with Authentik","authOpenIDAutoLaunch":false}}
        """#)
        XCTAssertEqual(info?.authMethods, ["local", "openid"])
        XCTAssertEqual(info?.serverVersion, "2.17.2")
        XCTAssertEqual(info?.isInitialized, true)
        XCTAssertEqual(info?.loginMessage, "Welcome to the family library & more")
        XCTAssertEqual(info?.openIDButtonText, "Sign in with Authentik")
        XCTAssertEqual(ServerConnectionRules.serverVersionLine(info?.serverVersion), "Audiobookshelf 2.17.2")
        XCTAssertEqual(ServerConnectionRules.singleSignOnButtonTitle(serverText: info?.openIDButtonText),
                       "Sign in with Authentik")
        XCTAssertFalse(ServerConnectionRules.serverNeedsSetup(info))
    }

    func testNotInitialisedServer() {
        let info = status(#"{"app":"audiobookshelf","serverVersion":"2.17.2","isInit":false,"authMethods":["local"],"authFormData":{"authLoginCustomMessage":null},"ConfigPath":"/config","MetadataPath":"/metadata"}"#)
        XCTAssertEqual(info?.isInitialized, false)
        XCTAssertNil(info?.loginMessage)
        XCTAssertTrue(ServerConnectionRules.serverNeedsSetup(info))
        XCTAssertEqual(ServerConnectionRules.serverNeedsSetupMessage,
                       "This server hasn\u{2019}t been set up yet. Finish setup in a browser, then try again.")
    }

    func testOlderOrOddStatusAnswersDegradeFieldByField() {
        // Older server: no authFormData, no isInit.
        let old = status(#"{"serverVersion":"2.2.0","authMethods":["local"]}"#)
        XCTAssertEqual(old?.serverVersion, "2.2.0")
        XCTAssertNil(old?.isInitialized)
        XCTAssertNil(old?.loginMessage)
        XCTAssertNil(old?.openIDButtonText)
        XCTAssertFalse(ServerConnectionRules.serverNeedsSetup(old))
        XCTAssertFalse(ServerConnectionRules.serverNeedsSetup(nil))
        // Wrong types are dropped one by one.
        let odd = status(#"{"serverVersion":217,"isInit":"yes","authMethods":"local","authFormData":{"authLoginCustomMessage":42}}"#)
        XCTAssertNotNil(odd)
        XCTAssertNil(odd?.serverVersion)
        XCTAssertNil(odd?.isInitialized)
        XCTAssertNil(odd?.authMethods)
        XCTAssertNil(odd?.loginMessage)
        // Not a JSON object at all.
        XCTAssertNil(status("not json"))
        XCTAssertNil(status(#"["local"]"#))
        XCTAssertNil(ServerConnectionRules.serverVersionLine(nil))
    }

    func testDefaultOpenIDButtonTextFallsBackToTheAppLabel() {
        let info = status(#"{"authMethods":["openid"],"authFormData":{"authOpenIDButtonText":"Login with OpenId"}}"#)
        XCTAssertNil(info?.openIDButtonText)
        XCTAssertEqual(ServerConnectionRules.singleSignOnButtonTitle(serverText: info?.openIDButtonText), "Sign in with SSO")
        XCTAssertEqual(ServerConnectionRules.singleSignOnButtonTitle(serverText: ""), "Sign in with SSO")
    }

    func testLoginMessageIsPlainCollapsedAndCapped() {
        XCTAssertNil(ServerStatusInfo.plainLoginMessage(nil))
        XCTAssertNil(ServerStatusInfo.plainLoginMessage("<p>  </p>"))
        XCTAssertEqual(ServerStatusInfo.plainLoginMessage("Line one<br>line&nbsp;two\n\n &lt;three&gt;"),
                       "Line one line two <three>")
        let long = String(repeating: "word ", count: 200)
        let capped = ServerStatusInfo.plainLoginMessage(long) ?? ""
        XCTAssertLessThanOrEqual(capped.count, ServerStatusInfo.loginMessageMaxLength)
        XCTAssertTrue(capped.hasSuffix("\u{2026}"))
    }

    func testConnectionResultCarriesStatusAuthMethods() {
        let info = ServerStatusInfo(authMethods: ["local", "openid"], serverVersion: "2.17.2")
        let result = ReachabilityStore.ConnectionTestResult(outcome: .reachable, resolvedURL: "https://abs.example.com",
                                                            serverStatus: info)
        XCTAssertEqual(result.authMethods, ["local", "openid"])
        XCTAssertEqual(result.serverStatus?.serverVersion, "2.17.2")
    }
}
