import XCTest
@testable import ShelfHead

/// SB-1 (REVIEW_2026-09-14_DESIGN.md): the first-run `LoginView` and the Settings
/// `AddServerView` are now one view (`ServerConnectionView`), so the form decisions both
/// screens depend on live in one place. These pin that shared decision math — the
/// project's standing preference over trying to drive the stateful view itself (see
/// `CLAUDE.md` > Testing).
///
/// Batch 319 (device feedback, 14 Sep 2026) added the progressive-disclosure rules —
/// step 2 hidden until the connection test passes, the header editor and SSO behind
/// collapsed disclosures, the "Sign in anyway" bypass, and the two-PAGE flow that
/// replaced the single scrolling form — and they're pinned here alongside the SB-1 set.
///
/// `@MainActor`: `ReachabilityStore.ConnectionTestResult` is nested in the `@MainActor`
/// `ReachabilityStore` and inherits its isolation, so both constructing one and calling
/// the two rules that take one need the main actor. Same reason `AccountRemovalTests`
/// is a `@MainActor` class. The older rules below are all nonisolated and unaffected.
@MainActor
final class LoginAddServerMergeTests: XCTestCase {

    private func result(_ outcome: ReachabilityStore.ConnectionTestResult.Outcome,
                        resolved: String? = "https://a.example")
    -> ReachabilityStore.ConnectionTestResult {
        ReachabilityStore.ConnectionTestResult(outcome: outcome, resolvedURL: resolved)
    }

    // MARK: - Header rows → dictionary

    func testBlankNamedRowsAreDropped() {
        // A freshly-added, not-yet-filled-in row must not be sent as an empty header name.
        let pairs = [
            EditableHeaderPair(key: "CF-Access-Client-Id", value: "abc"),
            EditableHeaderPair(key: "", value: "orphan"),
            EditableHeaderPair(key: "   ", value: "also orphan")
        ]
        XCTAssertEqual(ServerConnectionRules.customHeaders(from: pairs),
                       ["CF-Access-Client-Id": "abc"])
    }

    func testHeaderNameIsTrimmedButValueIsNot() {
        // A stray space either side of a pasted header NAME is a typo; a space inside a
        // header VALUE is a legal byte and must survive verbatim.
        let pairs = [EditableHeaderPair(key: "  X-Gate  ", value: " token ")]
        XCTAssertEqual(ServerConnectionRules.customHeaders(from: pairs), ["X-Gate": " token "])
    }

    func testEmptyRowsProduceEmptyDictionary() {
        XCTAssertTrue(ServerConnectionRules.customHeaders(from: []).isEmpty)
        XCTAssertTrue(ServerConnectionRules.customHeaders(from: [EditableHeaderPair()]).isEmpty)
    }

    // MARK: - Advisory header warnings

    func testBlankHeaderNameIsNotFlagged() {
        // Incomplete, not wrong — the row was just added.
        XCTAssertTrue(ServerConnectionRules.headerNameIsUsable(""))
        XCTAssertTrue(ServerConnectionRules.headerNameIsUsable("   "))
    }

    func testReservedHeaderNameIsFlagged() {
        // The case the warning exists for: `AuthStore.sanitizedCustomHeaders` strips this
        // so it can't replace the real bearer token, and the user needs to know why.
        XCTAssertFalse(ServerConnectionRules.headerNameIsUsable("Authorization"))
        XCTAssertFalse(ServerConnectionRules.headerNameIsUsable("authorization"))
    }

    func testMalformedHeaderNameIsFlagged() {
        XCTAssertFalse(ServerConnectionRules.headerNameIsUsable("X Gate"))
        XCTAssertFalse(ServerConnectionRules.headerNameIsUsable("X-Gate: extra"))
    }

    func testOrdinaryHeaderNameIsNotFlagged() {
        XCTAssertTrue(ServerConnectionRules.headerNameIsUsable("CF-Access-Client-Secret"))
        XCTAssertTrue(ServerConnectionRules.headerNameIsUsable("  X-Gate  "))
    }

    func testHeaderValueWarningDoesNotTrimFirst() {
        // Deliberately untrimmed: a trailing newline from a paste is exactly what this
        // warning is for, and trimming before checking would hide it.
        XCTAssertFalse(ServerConnectionRules.headerValueIsUsable("abc\n"))
        XCTAssertTrue(ServerConnectionRules.headerValueIsUsable("  abc  "))
        XCTAssertTrue(ServerConnectionRules.headerValueIsUsable(""))
    }

    // MARK: - Submit gating

    func testPasswordSubmitNeedsAllThreeFields() {
        XCTAssertTrue(ServerConnectionRules.canSubmitPassword(
            serverURL: "https://a.example", username: "jo", password: "pw"))
        XCTAssertFalse(ServerConnectionRules.canSubmitPassword(
            serverURL: "  ", username: "jo", password: "pw"))
        XCTAssertFalse(ServerConnectionRules.canSubmitPassword(
            serverURL: "https://a.example", username: "  ", password: "pw"))
        XCTAssertFalse(ServerConnectionRules.canSubmitPassword(
            serverURL: "https://a.example", username: "jo", password: ""))
    }

    func testPasswordIsNotTrimmedWhenGating() {
        // A password of only spaces is unusual but legal — it must not be gated out.
        XCTAssertTrue(ServerConnectionRules.canSubmitPassword(
            serverURL: "https://a.example", username: "jo", password: "   "))
    }

    func testSingleSignOnNeedsOnlyAServerAddress() {
        // The SB-1 fix in one assertion: SSO must be reachable with no username or
        // password typed, on first run as much as in Add Server.
        XCTAssertTrue(ServerConnectionRules.canStartSingleSignOn(serverURL: "https://a.example"))
        XCTAssertFalse(ServerConnectionRules.canStartSingleSignOn(serverURL: ""))
        XCTAssertFalse(ServerConnectionRules.canStartSingleSignOn(serverURL: "   "))
    }

    // MARK: - Advisory insecure-URL caption

    func testInsecureURLTextDetection() {
        XCTAssertTrue(ServerConnectionRules.isInsecureURLText("http://192.168.1.50:13378"))
        XCTAssertTrue(ServerConnectionRules.isInsecureURLText("  HTTP://example.com  "))
        XCTAssertFalse(ServerConnectionRules.isInsecureURLText("https://example.com"))
        // No scheme typed yet: `normalizedServerURL` defaults these to https, so the
        // caption must not fire on a bare hostname.
        XCTAssertFalse(ServerConnectionRules.isInsecureURLText("example.com"))
    }

    // MARK: - Error surfacing

    func testLocalErrorAlwaysWins() {
        XCTAssertEqual(
            ServerConnectionRules.displayedError(localError: "Incorrect username or password.",
                                                 viewModelError: "something older",
                                                 purpose: .firstRun),
            "Incorrect username or password.")
        XCTAssertEqual(
            ServerConnectionRules.displayedError(localError: "Incorrect username or password.",
                                                 viewModelError: nil,
                                                 purpose: .addAccount),
            "Incorrect username or password.")
    }

    func testFirstRunFallsBackToTheViewModelError() {
        // `AuthViewModel.logout()` sets `errorMessage` AFTER `isAuthenticated = false`,
        // specifically so a Keychain that wouldn't release an item is reported on the
        // screen the user lands on — with no sign-in attempt made there. That message has
        // to keep showing after the merge.
        XCTAssertEqual(
            ServerConnectionRules.displayedError(localError: nil,
                                                 viewModelError: "Signed out, but your saved server list couldn't be removed.",
                                                 purpose: .firstRun),
            "Signed out, but your saved server list couldn't be removed.")
    }

    func testAddServerSheetIgnoresTheViewModelError() {
        // The sheet has no producer of its own for that message, and showing a stale one
        // from elsewhere would read as "this connection failed".
        XCTAssertNil(ServerConnectionRules.displayedError(localError: nil,
                                                          viewModelError: "left over from somewhere else",
                                                          purpose: .addAccount))
    }

    func testNoErrorAtAll() {
        XCTAssertNil(ServerConnectionRules.displayedError(localError: nil, viewModelError: nil,
                                                          purpose: .firstRun))
    }

    // MARK: - Remember-password caption (SB-1 gap: no opt-in at sign-in time)

    func testRememberPasswordFooterExplainsWhatOnMeans() {
        XCTAssertEqual(
            ServerConnectionRules.rememberPasswordFooter(isOn: true),
            "Your password is stored in this device's Keychain and used to sign back in automatically if your session expires or you switch back to this server.")
    }

    func testRememberPasswordFooterExplainsWhatOffMeans() {
        XCTAssertEqual(
            ServerConnectionRules.rememberPasswordFooter(isOn: false),
            "Your password won't be saved on this device. You'll be asked to re-enter it if your session expires or you switch back to this server.")
    }

    // MARK: - Step 2 gating (device feedback: hide credentials until the test passes)

    func testCredentialsStayHiddenUntilATestHasRun() {
        // A fresh form has no result at all — only step 1 should be on screen.
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: nil, insecureAccepted: false))
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: nil, insecureAccepted: true))
    }

    func testReachableRevealsCredentials() {
        XCTAssertTrue(ServerConnectionRules.showsCredentials(for: result(.reachable),
                                                             insecureAccepted: false))
    }

    func testReachableInsecureRevealsCredentialsOnlyOnceAccepted() {
        // The plain-HTTP acknowledgement is the same gate `AuthViewModel` would raise a
        // moment later; asking for it here means it's asked once, not twice.
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: result(.reachableInsecure),
                                                              insecureAccepted: false))
        XCTAssertTrue(ServerConnectionRules.showsCredentials(for: result(.reachableInsecure),
                                                             insecureAccepted: true))
    }

    func testFailingOutcomesNeverRevealCredentials() {
        // `.notAudiobookshelf` included, and deliberately: that's the proxy-gate outcome,
        // whose escape hatch is the header editor in step 1 (reachable with no passing
        // test), not showing the credential fields anyway.
        for outcome in [ReachabilityStore.ConnectionTestResult.Outcome.notAudiobookshelf,
                        .unreachable, .invalidURL] {
            XCTAssertFalse(ServerConnectionRules.showsCredentials(for: result(outcome),
                                                                   insecureAccepted: false),
                           "\(outcome) must not reveal step 2")
            // Accepting an insecure connection must not act as a bypass for a result
            // that never said the server was reachable.
            XCTAssertFalse(ServerConnectionRules.showsCredentials(for: result(outcome),
                                                                   insecureAccepted: true),
                           "\(outcome) must not reveal step 2 even once insecure HTTP is accepted")
        }
    }

    // MARK: - "Sign in anyway" bypass

    func testBypassIsOfferedOnlyOnTheTwoGateShapedFailures() {
        // Where the address is plausibly fine and the TEST is what's wrong.
        XCTAssertTrue(ServerConnectionRules.offersTestBypass(for: result(.notAudiobookshelf)))
        XCTAssertTrue(ServerConnectionRules.offersTestBypass(for: result(.unreachable)))
        // Not before a test has run — a fresh form stays just the address field.
        XCTAssertFalse(ServerConnectionRules.offersTestBypass(for: nil))
        // Not on success: an "anyway" button on a screen that is working is noise.
        XCTAssertFalse(ServerConnectionRules.offersTestBypass(for: result(.reachable)))
        XCTAssertFalse(ServerConnectionRules.offersTestBypass(for: result(.reachableInsecure)))
        // Not on `.invalidURL`: nothing was attempted, and the address really is unusable.
        XCTAssertFalse(ServerConnectionRules.offersTestBypass(for: result(.invalidURL, resolved: nil)))
    }

    func testBypassRevealsCredentialsOnBothFailingOutcomes() {
        // The insurance: a gate that blocks or rewrites `/ping` whatever headers are sent
        // must not lock a user out of a server they can otherwise sign into.
        for outcome in [ReachabilityStore.ConnectionTestResult.Outcome.notAudiobookshelf,
                        .unreachable] {
            XCTAssertFalse(ServerConnectionRules.showsCredentials(for: result(outcome),
                                                                   insecureAccepted: false),
                           "\(outcome) must still hide step 2 until the bypass is taken")
            XCTAssertTrue(ServerConnectionRules.showsCredentials(for: result(outcome),
                                                                  insecureAccepted: false,
                                                                  bypassed: true),
                          "\(outcome) must reveal step 2 once the bypass is taken")
        }
    }

    func testBypassIsIgnoredWithNoResult() {
        // Nothing offers the bypass before a test, so a stray flag must not put step 2
        // back on a fresh form — that's the clutter this whole change removes.
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: nil,
                                                               insecureAccepted: false,
                                                               bypassed: true))
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: nil,
                                                               insecureAccepted: true,
                                                               bypassed: true))
    }

    func testBypassIsIgnoredOnAnInvalidURL() {
        // `.invalidURL` never reaches the network and never offers the button; honouring
        // a bypass there would show a sign-in form for an address that can't be parsed.
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: result(.invalidURL, resolved: nil),
                                                               insecureAccepted: false,
                                                               bypassed: true))
    }

    func testBypassIsNotNeededOnSuccess() {
        // Step 2 is already revealed by the pass itself; the flag changes nothing, and
        // in particular must not paper over the missing insecure acknowledgement.
        XCTAssertTrue(ServerConnectionRules.showsCredentials(for: result(.reachable),
                                                              insecureAccepted: false,
                                                              bypassed: true))
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: result(.reachableInsecure),
                                                               insecureAccepted: false,
                                                               bypassed: true),
                       "the bypass must not substitute for accepting plain HTTP")
        XCTAssertTrue(ServerConnectionRules.showsCredentials(for: result(.reachableInsecure),
                                                              insecureAccepted: true,
                                                              bypassed: true))
    }

    func testEditingTheURLClearsTheBypass() {
        // `ServerConnectionView.serverURL`'s `onChange` sets `testResult = nil` and
        // `bypassedTest = false` together. Modelled here as the state the rule then sees:
        // no result, no bypass — step 2 gone, exactly as for the result on its own.
        XCTAssertTrue(ServerConnectionRules.showsCredentials(for: result(.unreachable),
                                                              insecureAccepted: false,
                                                              bypassed: true))
        XCTAssertFalse(ServerConnectionRules.showsCredentials(for: nil,
                                                               insecureAccepted: false,
                                                               bypassed: false))
    }

    func testDefaultedBypassMatchesTheTwoArgumentBehaviour() {
        // `bypassed` has a default so the SB-1-era call sites and tests below keep
        // compiling unchanged — pin that the default is genuinely "no bypass".
        for outcome in [ReachabilityStore.ConnectionTestResult.Outcome.reachable,
                        .reachableInsecure, .notAudiobookshelf, .unreachable, .invalidURL] {
            XCTAssertEqual(
                ServerConnectionRules.showsCredentials(for: result(outcome), insecureAccepted: false),
                ServerConnectionRules.showsCredentials(for: result(outcome), insecureAccepted: false,
                                                       bypassed: false),
                "\(outcome) must behave identically with the default and an explicit false")
        }
    }

    // MARK: - Advanced (custom header) disclosure

    func testHeadersDisclosureStartsCollapsedOnAFreshForm() {
        // The clutter half of the feedback: nothing typed, nothing tested, stay shut.
        XCTAssertFalse(ServerConnectionRules.headersDisclosureStartsExpanded(result: nil,
                                                                             hasHeaders: false))
    }

    func testHeadersDisclosureOpensWhenHeadersAlreadyExist() {
        // Prefilled/edited connection — collapsing would hide data already in the form.
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: nil,
                                                                            hasHeaders: true))
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: result(.reachable),
                                                                            hasHeaders: true))
    }

    func testHeadersDisclosureOpensOnTheProxyGateOutcome() {
        // SB-1's lesson kept: `.notAudiobookshelf` is what a Cloudflare Access / Authelia
        // block page produces, and the header editor is the only way out of it.
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: result(.notAudiobookshelf),
                                                                            hasHeaders: false))
    }

    func testHeadersDisclosureStaysShutOnOtherOutcomes() {
        for outcome in [ReachabilityStore.ConnectionTestResult.Outcome.reachable,
                        .reachableInsecure, .unreachable, .invalidURL] {
            XCTAssertFalse(ServerConnectionRules.headersDisclosureStartsExpanded(result: result(outcome),
                                                                                 hasHeaders: false),
                           "\(outcome) shouldn't force the Advanced disclosure open")
        }
    }

    // MARK: - "Other sign-in options" (SSO) disclosure

    func testSingleSignOnIsNotAdvertisedWithoutAuthMethods() {
        // `nil` covers both "no test has run yet" and a server old enough not to report
        // the field at all — neutral label, collapsed either way.
        XCTAssertFalse(ServerConnectionRules.advertisesSingleSignOn(authMethods: nil))
        XCTAssertFalse(ServerConnectionRules.otherSignInOptionsStartExpanded(authMethods: nil))
        XCTAssertEqual(ServerConnectionRules.otherSignInOptionsTitle(authMethods: nil),
                       "Other sign-in options")
    }

    func testLocalOnlyServerDoesNotAdvertiseSingleSignOn() {
        XCTAssertFalse(ServerConnectionRules.advertisesSingleSignOn(authMethods: ["local"]))
        XCTAssertFalse(ServerConnectionRules.advertisesSingleSignOn(authMethods: []))
    }

    func testOpenIDInAuthMethodsOpensAndRelabelsTheDisclosure() {
        XCTAssertTrue(ServerConnectionRules.advertisesSingleSignOn(authMethods: ["local", "openid"]))
        XCTAssertTrue(ServerConnectionRules.advertisesSingleSignOn(authMethods: ["OpenID"]))
        XCTAssertTrue(ServerConnectionRules.otherSignInOptionsStartExpanded(authMethods: ["openid"]))
        XCTAssertEqual(ServerConnectionRules.otherSignInOptionsTitle(authMethods: ["openid"]),
                       "Other sign-in options \u{2014} SSO available")
    }

    // `ReachabilityStore.testConnection` now reads `/status` after a passing `/ping` and
    // carries the result on `ConnectionTestResult.authMethods` — these pin that the
    // struct actually plumbs the value through to the rules above, on top of the
    // rules-only coverage already above.
    func testConnectionResultDefaultsAuthMethodsToNilWithTheTwoArgumentInitializer() {
        let plain = ReachabilityStore.ConnectionTestResult(outcome: .reachable, resolvedURL: "https://a.example")
        XCTAssertNil(plain.authMethods)
        XCTAssertFalse(ServerConnectionRules.otherSignInOptionsStartExpanded(authMethods: plain.authMethods))
    }

    func testConnectionResultCarryingOpenIDExpandsAndRelabelsTheDisclosure() {
        let withSSO = ReachabilityStore.ConnectionTestResult(outcome: .reachable, resolvedURL: "https://a.example",
                                                              authMethods: ["local", "openid"])
        XCTAssertTrue(ServerConnectionRules.advertisesSingleSignOn(authMethods: withSSO.authMethods))
        XCTAssertTrue(ServerConnectionRules.otherSignInOptionsStartExpanded(authMethods: withSSO.authMethods))
    }

    func testConnectionResultCarryingOnlyLocalStaysNeutral() {
        let localOnly = ReachabilityStore.ConnectionTestResult(outcome: .reachable, resolvedURL: "https://a.example",
                                                                authMethods: ["local"])
        XCTAssertFalse(ServerConnectionRules.advertisesSingleSignOn(authMethods: localOnly.authMethods))
        XCTAssertFalse(ServerConnectionRules.otherSignInOptionsStartExpanded(authMethods: localOnly.authMethods))
    }

    // MARK: - `GET /status` → `authMethods` parsing

    func testParseAuthMethodsReadsThePresentArray() {
        let json = Data(#"{"app":"audiobookshelf","authMethods":["local","openid"]}"#.utf8)
        XCTAssertEqual(ReachabilityStore.parseAuthMethods(from: json), ["local", "openid"])
    }

    func testParseAuthMethodsIsNilWhenTheKeyIsAbsent() {
        // An older Audiobookshelf server that predates the field.
        let json = Data(#"{"app":"audiobookshelf","serverVersion":"2.1.0"}"#.utf8)
        XCTAssertNil(ReachabilityStore.parseAuthMethods(from: json))
    }

    func testParseAuthMethodsReadsAnEmptyArrayAsEmptyNotNil() {
        // Distinguishes "server reported zero auth methods" from "field wasn't there".
        let json = Data(#"{"authMethods":[]}"#.utf8)
        XCTAssertEqual(ReachabilityStore.parseAuthMethods(from: json), [])
    }

    func testParseAuthMethodsFiltersNonStringElementsRatherThanFailingEntirely() {
        let json = Data(#"{"authMethods":["local", 42, null, "openid", true]}"#.utf8)
        XCTAssertEqual(ReachabilityStore.parseAuthMethods(from: json), ["local", "openid"])
    }

    func testParseAuthMethodsIsNilWhenTheFieldIsNotAnArray() {
        let json = Data(#"{"authMethods":"local"}"#.utf8)
        XCTAssertNil(ReachabilityStore.parseAuthMethods(from: json))
    }

    func testParseAuthMethodsIsNilForNonObjectJSON() {
        // A plain JSON array at the top level, and outright malformed JSON.
        XCTAssertNil(ReachabilityStore.parseAuthMethods(from: Data(#"["local","openid"]"#.utf8)))
        XCTAssertNil(ReachabilityStore.parseAuthMethods(from: Data("not json at all".utf8)))
    }

    // MARK: - Two-page flow

    func testPageStaysOnServerUntilThereIsSomethingToSignInWith() {
        // The whole point of `resolvedPage`: `showsCredentials` is the single source of
        // truth, and a `.signIn` request with nothing behind it is not honoured.
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .signIn,
                                                          showsCredentials: false), .server)
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .server,
                                                          showsCredentials: false), .server)
    }

    func testSignInPageIsHonouredOnceCredentialsAreAvailable() {
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .signIn,
                                                          showsCredentials: true), .signIn)
    }

    func testChangeServerIsAlwaysHonoured() {
        // "Change server" must work while a passing result is still in hand — going back
        // resets nothing, so `showsCredentials` is still true at that moment.
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .server,
                                                          showsCredentials: true), .server)
    }

    func testEditingTheURLCannotStrandTheUserOnTheSignInPage() {
        // The end-to-end invariant in one place: sign-in page reached off a passing
        // test, then the address is edited — `testResult` goes nil, `showsCredentials`
        // goes false, and the rendered page snaps back even though `page` still says
        // `.signIn` until its own reset lands.
        let passing = ServerConnectionRules.showsCredentials(for: result(.reachable),
                                                             insecureAccepted: false)
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .signIn,
                                                          showsCredentials: passing), .signIn)
        let afterEdit = ServerConnectionRules.showsCredentials(for: nil, insecureAccepted: false)
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .signIn,
                                                          showsCredentials: afterEdit), .server)
    }

    func testBypassAlsoOpensTheSignInPage() {
        // The bypass is one of the three ways forward, so it must reach page 2 too.
        let bypassed = ServerConnectionRules.showsCredentials(for: result(.unreachable),
                                                              insecureAccepted: false,
                                                              bypassed: true)
        XCTAssertEqual(ServerConnectionRules.resolvedPage(requested: .signIn,
                                                          showsCredentials: bypassed), .signIn)
    }

    // MARK: - Server summary row (sign-in page)

    func testSummaryStyleFollowsHowTheConnectionWasEstablished() {
        XCTAssertEqual(ServerConnectionRules.serverSummaryStyle(for: result(.reachable),
                                                                insecureAccepted: false), .verified)
        XCTAssertEqual(ServerConnectionRules.serverSummaryStyle(for: result(.reachableInsecure),
                                                                insecureAccepted: true), .insecureAccepted)
        // Reached by "Sign in anyway": the row must not show a reassuring lock.
        XCTAssertEqual(ServerConnectionRules.serverSummaryStyle(for: result(.notAudiobookshelf),
                                                                insecureAccepted: false), .unverified)
        XCTAssertEqual(ServerConnectionRules.serverSummaryStyle(for: result(.unreachable),
                                                                insecureAccepted: false), .unverified)
        // Insecure but not yet accepted can't be on this page at all; if it somehow is,
        // it must not claim to be verified.
        XCTAssertEqual(ServerConnectionRules.serverSummaryStyle(for: result(.reachableInsecure),
                                                                insecureAccepted: false), .unverified)
        XCTAssertEqual(ServerConnectionRules.serverSummaryStyle(for: nil,
                                                                insecureAccepted: true), .unverified)
    }

    func testSummaryGlyphAndCaptionMatchTheStyle() {
        XCTAssertEqual(ServerConnectionRules.serverSummaryGlyph(for: .verified), "lock.fill")
        XCTAssertEqual(ServerConnectionRules.serverSummaryGlyph(for: .insecureAccepted), "lock.open.fill")
        XCTAssertEqual(ServerConnectionRules.serverSummaryGlyph(for: .unverified), "questionmark.circle.fill")
        XCTAssertEqual(ServerConnectionRules.serverSummaryCaption(for: .verified), "Connection verified")
        XCTAssertEqual(ServerConnectionRules.serverSummaryCaption(for: .insecureAccepted),
                       "Insecure connection accepted")
        XCTAssertEqual(ServerConnectionRules.serverSummaryCaption(for: .unverified),
                       "Connection not verified")
    }

    func testSummaryHostPrefersTheResolvedAddress() {
        // What was actually contacted, not what was typed — a corrected typo should be
        // visible here rather than hidden.
        XCTAssertEqual(ServerConnectionRules.serverSummaryHost(resolvedURL: "https://library.example.com:13378",
                                                               typedURL: "library.example.com"),
                       "library.example.com")
        XCTAssertEqual(ServerConnectionRules.serverSummaryHost(resolvedURL: "http://192.168.1.50:13378",
                                                               typedURL: " 192.168.1.50 "),
                       "192.168.1.50")
    }

    func testSummaryHostFallsBackRatherThanGoingBlank() {
        // `.invalidURL` (and anything else with no resolved address) still has to render
        // something in the row.
        XCTAssertEqual(ServerConnectionRules.serverSummaryHost(resolvedURL: nil,
                                                               typedURL: "  my-nas  "),
                       "my-nas")
        XCTAssertEqual(ServerConnectionRules.serverSummaryHost(resolvedURL: "",
                                                               typedURL: "my-nas"),
                       "my-nas")
        // A resolved string with no parseable host is shown whole rather than dropped.
        XCTAssertEqual(ServerConnectionRules.serverSummaryHost(resolvedURL: "/just/a/path",
                                                               typedURL: "typed"),
                       "/just/a/path")
    }

    func testSummaryAccessibilityLabelReadsAsOneSentence() {
        XCTAssertEqual(
            ServerConnectionRules.serverSummaryAccessibilityLabel(host: "example.com", style: .verified),
            "Server example.com, connection verified")
        XCTAssertEqual(
            ServerConnectionRules.serverSummaryAccessibilityLabel(host: "example.com", style: .insecureAccepted),
            "Server example.com, insecure connection accepted")
        XCTAssertEqual(
            ServerConnectionRules.serverSummaryAccessibilityLabel(host: "example.com", style: .unverified),
            "Server example.com, connection not verified")
    }

    // MARK: - Purpose chrome

    func testPurposeChromeDiffers() {
        XCTAssertTrue(ServerConnectionPurpose.firstRun.showsBranding)
        XCTAssertFalse(ServerConnectionPurpose.firstRun.dismissesOnSuccess)
        XCTAssertTrue(ServerConnectionPurpose.firstRun.rendersViewModelError)

        XCTAssertFalse(ServerConnectionPurpose.addAccount.showsBranding)
        XCTAssertTrue(ServerConnectionPurpose.addAccount.dismissesOnSuccess)
        XCTAssertFalse(ServerConnectionPurpose.addAccount.rendersViewModelError)
    }
}
