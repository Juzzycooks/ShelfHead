import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden + clarify, first-run connection flow): pins the pure pieces
/// behind the connection test's new behaviour — the scheme-less private-host candidates
/// (https, then http), the `URLError` → `ServerConnectionFailure` classification, the
/// fallback's retry/report decisions, and the per-failure copy and recovery buttons. The
/// network calls themselves aren't driven here (CLAUDE.md > Testing).
///
/// `@MainActor` for the same reason as `LoginAddServerMergeTests`: it constructs
/// `ReachabilityStore.ConnectionTestResult`, nested in a `@MainActor` type.
@MainActor
final class ServerConnectionFailureTests: XCTestCase {

    // MARK: - Candidate addresses

    func testSchemelessPrivateHostsTryHTTPSThenHTTP() {
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "192.168.1.50:13378"),
                       ["https://192.168.1.50:13378", "http://192.168.1.50:13378"])
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "nas.local:13378"),
                       ["https://nas.local:13378", "http://nas.local:13378"])
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "  10.0.0.5/abs/ "),
                       ["https://10.0.0.5/abs", "http://10.0.0.5/abs"])
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "myserver.tail1234.ts.net"),
                       ["https://myserver.tail1234.ts.net", "http://myserver.tail1234.ts.net"])
    }

    func testPublicOrBareHostsStayHTTPSOnly() {
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "books.example.com"),
                       ["https://books.example.com"])
        // A bare name isn't known to be private (see `isLocalOrPrivateHost`).
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "nas:13378"),
                       ["https://nas:13378"])
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "8.8.8.8"),
                       ["https://8.8.8.8"])
    }

    func testAnExplicitSchemeIsNeverSecondGuessed() {
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "https://192.168.1.50:13378"),
                       ["https://192.168.1.50:13378"])
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "http://192.168.1.50:13378"),
                       ["http://192.168.1.50:13378"])
    }

    func testUnparseableInputHasNoCandidates() {
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: ""), [])
        XCTAssertEqual(ServerURLRules.connectionCandidates(for: "ftp://nas.local"), [])
    }

    func testCandidatesLeaveNormalisationUnchanged() {
        // The first candidate is always exactly what `normalizedServerURL` produced before.
        for raw in ["192.168.1.50:13378", "books.example.com", "https://nas.local", "HTTP://Books.Example.com/Base/"] {
            XCTAssertEqual(ServerURLRules.connectionCandidates(for: raw).first,
                           ServerURLRules.normalizedServerURL(raw), raw)
        }
    }

    func testPlainHTTPVariantOnlyDowngradesHTTPS() {
        XCTAssertEqual(ServerURLRules.plainHTTPVariant(of: "https://books.example.com:8443/abs"),
                       "http://books.example.com:8443/abs")
        XCTAssertNil(ServerURLRules.plainHTTPVariant(of: "http://books.example.com"))
    }

    // MARK: - Classification

    func testURLErrorCodesClassify() {
        let cases: [(URLError.Code, ServerConnectionFailure)] = [
            (.secureConnectionFailed, .secureConnection),
            (.serverCertificateUntrusted, .secureConnection),
            (.serverCertificateHasUnknownRoot, .secureConnection),
            (.serverCertificateHasBadDate, .secureConnection),
            (.timedOut, .timedOut),
            (.cannotFindHost, .hostNotFound),
            (.dnsLookupFailed, .hostNotFound),
            (.cannotConnectToHost, .cannotConnect),
            (.networkConnectionLost, .cannotConnect),
            (.badURL, .other),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(ServerConnectionFailure.classify(code, deviceIsOnline: true), expected, "\(code)")
        }
    }

    func testNotConnectedIsOfflineOnlyWhenTheDeviceReallyIs() {
        XCTAssertEqual(ServerConnectionFailure.classify(.notConnectedToInternet, deviceIsOnline: false), .offline)
        // Online by the path monitor, but the request says otherwise: not "offline".
        XCTAssertEqual(ServerConnectionFailure.classify(.notConnectedToInternet, deviceIsOnline: true), .cannotConnect)
    }

    func testNonURLErrorsAreOther() {
        struct Boom: Error {}
        XCTAssertEqual(ServerConnectionFailure.classify(Boom(), deviceIsOnline: true), .other)
        XCTAssertEqual(ServerConnectionFailure.classify(URLError(.timedOut), deviceIsOnline: true), .timedOut)
    }

    func testOnlyTransportFailuresRetryOverHTTP() {
        XCTAssertTrue(ServerConnectionFailure.secureConnection.warrantsPlainHTTPRetry)
        XCTAssertTrue(ServerConnectionFailure.timedOut.warrantsPlainHTTPRetry)
        XCTAssertTrue(ServerConnectionFailure.cannotConnect.warrantsPlainHTTPRetry)
        XCTAssertFalse(ServerConnectionFailure.hostNotFound.warrantsPlainHTTPRetry)
        XCTAssertFalse(ServerConnectionFailure.offline.warrantsPlainHTTPRetry)
        XCTAssertFalse(ServerConnectionFailure.httpStatus(502).warrantsPlainHTTPRetry)
    }

    func testPreferredFailureKeepsTLSOtherwiseHTTPSide() {
        XCTAssertEqual(ServerConnectionFailure.preferredFailure(https: .secureConnection, http: .cannotConnect),
                       .secureConnection)
        XCTAssertEqual(ServerConnectionFailure.preferredFailure(https: .timedOut, http: .cannotConnect),
                       .cannotConnect)
    }

    // MARK: - Copy and recoveries

    private func advice(_ failure: ServerConnectionFailure?, _ url: String?, tried: Bool = false)
    -> ServerConnectionRules.FailureAdvice {
        ServerConnectionRules.failureAdvice(failure: failure, resolvedURL: url, triedPlainHTTP: tried)
    }

    func testTLSFailureOnHTTPSOffersPlainHTTP() {
        XCTAssertTrue(advice(.secureConnection, "https://books.example.com").offersPlainHTTP)
        XCTAssertTrue(advice(.secureConnection, "https://192.168.1.50:13378").offersPlainHTTP)
        // Already tried by the scheme-less fallback: don't offer it again.
        XCTAssertFalse(advice(.secureConnection, "https://192.168.1.50:13378", tried: true).offersPlainHTTP)
        // Not an https address: nothing to downgrade, generic copy.
        let onHTTP = advice(.secureConnection, "http://books.example.com")
        XCTAssertFalse(onHTTP.offersPlainHTTP)
        XCTAssertEqual(onHTTP.message, ServerConnectionRules.genericUnreachableMessage)
    }

    func testPublicTLSCopyMentionsEncryption() {
        XCTAssertTrue(advice(.secureConnection, "https://books.example.com").nextStep.contains("isn\u{2019}t encrypted"))
    }

    func testTimeoutOnAPrivateHostPointsAtLocalNetwork() {
        let lan = advice(.timedOut, "http://192.168.1.50:13378")
        XCTAssertTrue(lan.offersLocalNetworkSettings)
        XCTAssertEqual(lan.nextStep, ServerConnectionRules.localNetworkNextStep)
        let publicHost = advice(.timedOut, "https://books.example.com")
        XCTAssertFalse(publicHost.offersLocalNetworkSettings)
        XCTAssertFalse(publicHost.nextStep.contains("Local Network"))
    }

    func testHostNotFoundOffersLocalNetworkOnlyForMDNSNames() {
        XCTAssertTrue(advice(.hostNotFound, "https://nas.local:13378").offersLocalNetworkSettings)
        XCTAssertFalse(advice(.hostNotFound, "https://books.exmaple.com").offersLocalNetworkSettings)
    }

    func testEachFailureHasItsOwnMessage() {
        let url = "https://books.example.com"
        let messages = [
            advice(.secureConnection, url).message,
            advice(.timedOut, url).message,
            advice(.hostNotFound, url).message,
            advice(.cannotConnect, url).message,
            advice(.offline, url).message,
            advice(.httpStatus(403), url).message,
            advice(.httpStatus(502), url).message,
            advice(.httpStatus(404), url).message,
            advice(.other, url).message,
        ]
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertEqual(advice(nil, url).message, ServerConnectionRules.genericUnreachableMessage)
    }

    func testGateStatusPointsAtAdvancedHeaders() {
        XCTAssertTrue(advice(.httpStatus(401), "https://books.example.com").nextStep.contains("Advanced"))
        XCTAssertTrue(advice(.httpStatus(403), "https://books.example.com").message.contains("403"))
    }

    func testOfflineOffersNoRecoveryButtons() {
        let a = advice(.offline, "http://192.168.1.50")
        XCTAssertFalse(a.offersPlainHTTP)
        XCTAssertFalse(a.offersLocalNetworkSettings)
    }

    func testRetryAddressAndSignInAddress() {
        XCTAssertEqual(ServerConnectionRules.plainHTTPRetryAddress(resolvedURL: "https://books.example.com"),
                       "http://books.example.com")
        XCTAssertNil(ServerConnectionRules.plainHTTPRetryAddress(resolvedURL: nil))
        // The http fallback's address is what gets signed into, not the re-normalised typed text.
        XCTAssertEqual(ServerConnectionRules.signInAddress(typedURL: "192.168.1.50:13378",
                                                           resolvedURL: "http://192.168.1.50:13378"),
                       "http://192.168.1.50:13378")
        XCTAssertEqual(ServerConnectionRules.signInAddress(typedURL: "books.example.com", resolvedURL: nil),
                       "books.example.com")
    }

    func testReachableMessageNamesTheHTTPFallback() {
        XCTAssertTrue(ServerConnectionRules.reachableMessage(usedPlainHTTPFallback: true).contains("plain http"))
        XCTAssertFalse(ServerConnectionRules.reachableMessage(usedPlainHTTPFallback: false).contains("http"))
    }

    // MARK: - Result defaults (source compatibility)

    func testResultDefaultsKeepTheOldInitializerWorking() {
        let r = ReachabilityStore.ConnectionTestResult(outcome: .unreachable, resolvedURL: "https://a.example")
        XCTAssertNil(r.failure)
        XCTAssertFalse(r.usedPlainHTTPFallback)
        XCTAssertFalse(r.triedPlainHTTP)
        let fellBack = ReachabilityStore.ConnectionTestResult(outcome: .reachable, resolvedURL: "http://10.0.0.5",
                                                              usedPlainHTTPFallback: true)
        XCTAssertTrue(fellBack.triedPlainHTTP)
    }
}
