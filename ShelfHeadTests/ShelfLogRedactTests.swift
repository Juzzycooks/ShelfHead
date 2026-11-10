import XCTest
@testable import ShelfHead

/// Review test gap: pins what `ShelfLog.redact` actually does today. It strips the value of
/// `token`/`access_token`/`refresh_token`/`password`/`api_key` query pairs, a `?code=`/`&code=`
/// OAuth code, and `Bearer <value>` headers. It does not touch hosts (that is the private
/// `redactHosts`, applied only in `exportDiagnostics`), and it has no JWT-shape rule: a bare
/// JWT is only redacted when it sits behind one of the keys above.
final class ShelfLogRedactTests: XCTestCase {
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.c2lnbmF0dXJl"

    func testTokenQueryValueIsRedactedAndKeyKept() {
        let out = ShelfLog.redact("GET https://abs.example/s/item/1/a.m4b?token=abc123 failed")
        XCTAssertEqual(out, "GET https://abs.example/s/item/1/a.m4b?token=••• failed")
    }

    func testEachSecretKeyIsRedacted() {
        for key in ["token", "access_token", "access-token", "refresh_token", "refresh-token", "password", "api_key", "api-key", "apikey"] {
            let out = ShelfLog.redact("https://h/x?\(key)=SECRET&other=1")
            XCTAssertFalse(out.contains("SECRET"), key)
            XCTAssertEqual(out, "https://h/x?\(key)=•••&other=1", key)
        }
    }

    func testKeyMatchIsCaseInsensitive() {
        XCTAssertEqual(ShelfLog.redact("Token=abc&PASSWORD=def"), "Token=•••&PASSWORD=•••")
    }

    func testOnlyTheSecretParamIsRedactedWhenSeveralArePresent() {
        let out = ShelfLog.redact("https://h/x?a=1&token=SECRET&b=2")
        XCTAssertEqual(out, "https://h/x?a=1&token=•••&b=2")
    }

    func testValueStopsAtQuoteOrWhitespace() {
        let out = ShelfLog.redact(#"failingURL="https://h/x?token=SECRET" retry"#)
        XCTAssertEqual(out, #"failingURL="https://h/x?token=•••" retry"#)
    }

    func testBearerHeaderValueIsRedacted() {
        XCTAssertEqual(ShelfLog.redact("Authorization: Bearer \(jwt)"), "Authorization: Bearer •••")
        XCTAssertEqual(ShelfLog.redact("bearer abc.def-ghi_jkl"), "bearer •••")
    }

    func testJWTBehindATokenKeyIsRedactedInFull() {
        let out = ShelfLog.redact("?token=\(jwt)")
        XCTAssertFalse(out.contains("eyJ"))
        XCTAssertEqual(out, "?token=•••")
    }

    func testOAuthCodeRedactedOnlyAsAQueryParameter() {
        XCTAssertEqual(ShelfLog.redact("https://h/cb?code=AUTHCODE&state=s"), "https://h/cb?code=•••&state=s")
        XCTAssertEqual(ShelfLog.redact("https://h/cb?state=s&code=AUTHCODE"), "https://h/cb?state=s&code=•••")
        // NSError's own "Code=-1009" must survive.
        let err = "Error Domain=NSURLErrorDomain Code=-1009 \"offline\""
        XCTAssertEqual(ShelfLog.redact(err), err)
    }

    func testAlreadyCleanStringIsUnchanged() {
        for s in ["", "Playback started for Dune", "https://abs.example/api/items/abc/cover?width=300",
                  "Chapter 3 of 12 at 00:41:07"] {
            XCTAssertEqual(ShelfLog.redact(s), s)
        }
    }

    func testRedactionIsIdempotent() {
        let once = ShelfLog.redact("a?token=x&password=y Bearer z")
        XCTAssertEqual(ShelfLog.redact(once), once)
    }

    func testRedactDoesNotStripHosts() {
        // Pins current behaviour: hosts are only scrubbed by the export path.
        XCTAssertEqual(ShelfLog.redact("Connecting to https://books.example.com:13378/api"),
                       "Connecting to https://books.example.com:13378/api")
    }
}
