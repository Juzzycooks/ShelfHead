import XCTest
@testable import ShelfHead

/// Targeted tests for the pure, extractable parts of the OIDC/SSO sign-in flow
/// (`OIDCAuthService`) and the response shape it shares with the native `/login`
/// endpoint (`LoginResponse`). The flow's actual network legs (the `/auth/openid`
/// initiation request, the `ASWebAuthenticationSession` browser hop, and the
/// `/auth/openid/callback` token exchange) aren't exercised here — those need a real
/// server and remain manual/TestFlight-verified, per the existing test target's scope.
/// What's tested is exactly the logic that was wrong in the first version of this file
/// and wouldn't have been caught without these: the PKCE challenge derivation, the
/// state-mismatch rejection, the same-host-vs-external redirect decision, and decoding
/// both response shapes Audiobookshelf can return a token in.
final class OIDCAuthServiceTests: XCTestCase {

    // MARK: - PKCE code_challenge (RFC 7636 Appendix B test vector)

    func testCodeChallengeMatchesRFC7636AppendixBVector() {
        // https://datatracker.ietf.org/doc/html/rfc7636#appendix-B — the canonical
        // worked example for S256: a fixed verifier and its known-correct challenge.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(OIDCAuthService.codeChallenge(for: verifier), expectedChallenge)
    }

    func testCodeVerifierIsURLSafeAndRightLength() throws {
        // RFC 7636 §4.1: 43–128 characters, unreserved URL-safe alphabet only.
        // `makeCodeVerifier()` throws only on a CSPRNG failure (finding #7, "fail closed"
        // rather than silently produce a predictable verifier) — not reachable in a test
        // environment, so `try` (not `try!`) here just lets XCTest report it as a failure
        // rather than a crash if it somehow ever did happen.
        let verifier = try OIDCAuthService.makeCodeVerifier()
        XCTAssertEqual(verifier.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testCodeVerifiersAreNotReused() throws {
        // Not a proof of randomness, but catches a regression to a fixed/zeroed value.
        let a = try OIDCAuthService.makeCodeVerifier()
        let b = try OIDCAuthService.makeCodeVerifier()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Callback validation (state mismatch / missing code)

    func testExtractAuthorizationCodeSucceedsWhenStateMatches() throws {
        let callbackURL = URL(string: "shelfhead-oidc://oauth?state=abc123&code=the-auth-code")!
        let code = try OIDCAuthService.extractAuthorizationCode(from: callbackURL, expectedState: "abc123")
        XCTAssertEqual(code, "the-auth-code")
    }

    func testExtractAuthorizationCodeRejectsStateMismatch() {
        let callbackURL = URL(string: "shelfhead-oidc://oauth?state=wrong-state&code=the-auth-code")!
        XCTAssertThrowsError(
            try OIDCAuthService.extractAuthorizationCode(from: callbackURL, expectedState: "abc123")
        ) { error in
            guard case OIDCAuthService.OIDCError.stateMismatch = error else {
                return XCTFail("Expected .stateMismatch, got \(error)")
            }
        }
    }

    func testExtractAuthorizationCodeRejectsMissingCode() {
        let callbackURL = URL(string: "shelfhead-oidc://oauth?state=abc123")!
        XCTAssertThrowsError(
            try OIDCAuthService.extractAuthorizationCode(from: callbackURL, expectedState: "abc123")
        ) { error in
            guard case OIDCAuthService.OIDCError.noCodeInCallback = error else {
                return XCTFail("Expected .noCodeInCallback, got \(error)")
            }
        }
    }

    func testExtractAuthorizationCodeRejectsMissingState() {
        // No `state` param at all (as opposed to a wrong one) must also be rejected —
        // a missing state is not "matches by absence."
        let callbackURL = URL(string: "shelfhead-oidc://oauth?code=the-auth-code")!
        XCTAssertThrowsError(
            try OIDCAuthService.extractAuthorizationCode(from: callbackURL, expectedState: "abc123")
        ) { error in
            guard case OIDCAuthService.OIDCError.stateMismatch = error else {
                return XCTFail("Expected .stateMismatch, got \(error)")
            }
        }
    }

    // MARK: - Same-host vs. external redirect decision

    func testSameHostRedirectIsNotExternal() {
        // A reverse proxy upgrading http to https on the same host — must be followed
        // on our own cookie-carrying session, not handed to the browser.
        let redirect = URL(string: "https://abs.example.com/auth/openid")!
        XCTAssertFalse(OIDCAuthService.isExternalRedirect(redirect, relativeToServerHost: "abs.example.com"))
    }

    func testDifferentHostRedirectIsExternal() {
        // The actual identity-provider hop — must be handed to ASWebAuthenticationSession.
        let redirect = URL(string: "https://accounts.google.com/o/oauth2/auth")!
        XCTAssertTrue(OIDCAuthService.isExternalRedirect(redirect, relativeToServerHost: "abs.example.com"))
    }

    func testSubdomainRedirectIsExternal() {
        // A subdomain is a different host string, and must not be conflated with the
        // server's own host even though it "looks related."
        let redirect = URL(string: "https://auth.abs.example.com/login")!
        XCTAssertTrue(OIDCAuthService.isExternalRedirect(redirect, relativeToServerHost: "abs.example.com"))
    }

    func testNilServerHostIsTreatedAsExternal() {
        // Defensive default — shouldn't be reachable in practice (signIn validates the
        // server URL has a host first), but a nil comparison base must fail safe (open
        // in the browser) rather than silently treating everything as same-host.
        let redirect = URL(string: "https://abs.example.com/auth/openid")!
        XCTAssertTrue(OIDCAuthService.isExternalRedirect(redirect, relativeToServerHost: nil))
    }

    // MARK: - HTTPS→HTTP downgrade rejection (SEC-2)

    func testHTTPSToHTTPIsADowngrade() {
        // The exact exploit: a server reached over HTTPS redirects to plain HTTP,
        // same host or not — must be rejected before it's replayed with custom
        // headers/cookies attached.
        XCTAssertTrue(OIDCAuthService.isSchemeDowngrade(from: "https", to: "http"))
    }

    func testHTTPToHTTPSIsNotADowngrade() {
        // The documented, legitimate reverse-proxy case: must stay allowed.
        XCTAssertFalse(OIDCAuthService.isSchemeDowngrade(from: "http", to: "https"))
    }

    func testHTTPSToHTTPSIsNotADowngrade() {
        XCTAssertFalse(OIDCAuthService.isSchemeDowngrade(from: "https", to: "https"))
    }

    func testHTTPToHTTPIsNotADowngrade() {
        // A legitimately plain-HTTP self-hosted server (already gated elsewhere by
        // AuthViewModel.requiresInsecureConnectionConfirmation) staying on HTTP
        // throughout is not itself a downgrade.
        XCTAssertFalse(OIDCAuthService.isSchemeDowngrade(from: "http", to: "http"))
    }

    func testSchemeDowngradeComparisonIsCaseInsensitive() {
        XCTAssertTrue(OIDCAuthService.isSchemeDowngrade(from: "HTTPS", to: "HTTP"))
        XCTAssertFalse(OIDCAuthService.isSchemeDowngrade(from: "HTTPS", to: "HTTPS"))
    }

    // MARK: - LoginResponse decoding (both token shapes the callback exchange can return)

    func testLoginResponseDecodesLegacyTokenShape() throws {
        // Older Audiobookshelf servers return only the permanent `token` field.
        let json = """
        {"user": {"id": "u1", "username": "justin", "token": "legacy-token-value"}}
        """
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.user.effectiveAccessToken, "legacy-token-value")
        XCTAssertNil(decoded.user.refreshToken)
    }

    func testLoginResponseDecodesModernAccessTokenShape() throws {
        // v2.26+ servers return a short-lived accessToken plus a refreshToken.
        let json = """
        {"user": {"id": "u1", "username": "justin", "accessToken": "access-value", "refreshToken": "refresh-value"}}
        """
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.user.effectiveAccessToken, "access-value")
        XCTAssertEqual(decoded.user.refreshToken, "refresh-value")
    }

    func testLoginResponsePrefersAccessTokenWhenBothPresent() throws {
        let json = """
        {"user": {"id": "u1", "username": "justin", "token": "legacy-token-value", "accessToken": "access-value"}}
        """
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.user.effectiveAccessToken, "access-value")
    }
}
