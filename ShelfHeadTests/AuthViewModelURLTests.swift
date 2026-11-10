import XCTest
@testable import ShelfHead

/// Housekeeping batch (REVIEW_2026-08-12.md): `AuthViewModel.normalizedServerURL` and
/// `isLocalOrPrivateHost` had zero test coverage despite gating whether a plain-HTTP
/// connection is allowed without an explicit "I understand the risk" confirmation —
/// exactly the kind of security-relevant string/parsing logic that's cheap to pin down
/// with tests and easy to silently regress without them. `AuthViewModel` is
/// `@MainActor`, and `normalizedServerURL`/`requiresInsecureConnectionConfirmation`
/// aren't `nonisolated` (only `isLocalOrPrivateHost` is), so this whole test class is
/// marked `@MainActor` to allow calling all three synchronously without threading
/// `async`/`await` through every test method.
@MainActor
final class AuthViewModelURLTests: XCTestCase {

    // MARK: - normalizedServerURL

    func testEmptyOrWhitespaceOnlyReturnsNil() {
        XCTAssertNil(AuthViewModel.normalizedServerURL(""))
        XCTAssertNil(AuthViewModel.normalizedServerURL("   "))
        XCTAssertNil(AuthViewModel.normalizedServerURL("\n\t "))
    }

    func testBareHostDefaultsToHTTPS() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("books.example.com"), "https://books.example.com")
    }

    func testExplicitHTTPSchemeIsPreserved() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("http://books.example.com"), "http://books.example.com")
    }

    func testExplicitHTTPSSchemeIsPreserved() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("https://books.example.com"), "https://books.example.com")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("HTTPS://books.example.com"), "https://books.example.com")
        XCTAssertEqual(AuthViewModel.normalizedServerURL("HTTP://books.example.com"), "http://books.example.com")
    }

    func testLeadingAndTrailingWhitespaceIsTrimmedBeforeParsing() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("  https://books.example.com  "), "https://books.example.com")
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertNil(AuthViewModel.normalizedServerURL("ftp://books.example.com"))
        XCTAssertNil(AuthViewModel.normalizedServerURL("ws://books.example.com"))
    }

    func testMissingHostIsRejected() {
        XCTAssertNil(AuthViewModel.normalizedServerURL("https://"))
        XCTAssertNil(AuthViewModel.normalizedServerURL("https:///path"))
    }

    func testTrailingSlashesAreStripped() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("https://books.example.com/"), "https://books.example.com")
        XCTAssertEqual(AuthViewModel.normalizedServerURL("https://books.example.com///"), "https://books.example.com")
    }

    func testNonRootPathIsPreservedMinusTrailingSlash() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("https://books.example.com/audiobookshelf/"),
                       "https://books.example.com/audiobookshelf")
    }

    func testPortIsPreserved() {
        XCTAssertEqual(AuthViewModel.normalizedServerURL("https://books.example.com:13378"),
                       "https://books.example.com:13378")
        XCTAssertEqual(AuthViewModel.normalizedServerURL("192.168.1.50:13378"), "https://192.168.1.50:13378")
    }

    func testUserinfoIsRejected() {
        // A server *base* address containing embedded credentials almost certainly means
        // the user pasted something other than a plain server root.
        XCTAssertNil(AuthViewModel.normalizedServerURL("https://user:pass@books.example.com"))
    }

    func testQueryStringIsRejected() {
        XCTAssertNil(AuthViewModel.normalizedServerURL("https://books.example.com?token=abc123"))
    }

    func testFragmentIsRejected() {
        XCTAssertNil(AuthViewModel.normalizedServerURL("https://books.example.com#somewhere"))
    }

    func testHostIsLowercased() {
        // `URLComponents.host` itself lowercases the host, so this pins that behavior
        // rather than a bespoke lowercasing step in `normalizedServerURL`.
        XCTAssertEqual(AuthViewModel.normalizedServerURL("https://BOOKS.EXAMPLE.COM"), "https://books.example.com")
    }

    // MARK: - isLocalOrPrivateHost

    func testLocalhostAndDotLocalAreLocal() {
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("localhost"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("LOCALHOST"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("mymac.local"))
    }

    func testRFC1918IPv4RangesAreLocal() {
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("10.0.0.1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("10.255.255.255"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("172.16.0.1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("172.31.255.255"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("192.168.1.1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("192.168.0.50"))
    }

    func test172RangeBoundariesAreExact() {
        // 172.16.0.0/12 is 172.16.x.x through 172.31.x.x — 172.15 and 172.32 are public.
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("172.15.255.255"))
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("172.32.0.1"))
    }

    func testLoopbackAndLinkLocalIPv4AreLocal() {
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("127.0.0.1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("127.53.1.2"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("169.254.1.1"))
    }

    func testPublicIPv4HostsAreNotLocal() {
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("8.8.8.8"))
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("1.1.1.1"))
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("93.184.216.34"))
    }

    func testPublicHostnamesAreNotLocal() {
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("books.example.com"))
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("audiobookshelf.example.org"))
    }

    func testIPv6LoopbackAndLinkLocalAndUniqueLocalAreLocal() {
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("::1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("fe80::1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("fc00::1"))
        XCTAssertTrue(AuthViewModel.isLocalOrPrivateHost("fd12:3456:789a::1"))
    }

    func testPublicIPv6HostIsNotLocal() {
        XCTAssertFalse(AuthViewModel.isLocalOrPrivateHost("2001:4860:4860::8888"))
    }

    // MARK: - requiresInsecureConnectionConfirmation
    //
    // Built directly on the two functions above; a couple of integration-style cases
    // pin the actual security-relevant behavior they exist to support, not just the
    // string plumbing in isolation.

    func testPlainHTTPToPublicHostRequiresConfirmation() {
        XCTAssertTrue(AuthViewModel.requiresInsecureConnectionConfirmation(for: "http://books.example.com"))
    }

    func testPlainHTTPToLocalOrPrivateHostDoesNotRequireConfirmation() {
        XCTAssertFalse(AuthViewModel.requiresInsecureConnectionConfirmation(for: "http://192.168.1.50"))
        XCTAssertFalse(AuthViewModel.requiresInsecureConnectionConfirmation(for: "http://localhost:13378"))
    }

    func testHTTPSNeverRequiresConfirmationRegardlessOfHost() {
        XCTAssertFalse(AuthViewModel.requiresInsecureConnectionConfirmation(for: "https://books.example.com"))
    }
}
