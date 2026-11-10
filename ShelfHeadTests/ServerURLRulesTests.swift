import XCTest
@testable import ShelfHead

/// Item 22 (REVIEW-2026-09-09-REMAINING.md, Batch 314): the server-address rules used to
/// live in `AuthViewModel` with a byte-for-byte copy in the Watch target. They are now one
/// shared `ServerURLRules` compiled into both targets, and `AuthViewModel` forwards to it.
/// `AuthViewModelURLTests` still pins the behaviour through the forwarders; this file pins
/// that the forwarders really are forwarders (same answer for the same input), so a future
/// "quick fix" in one place can't silently reintroduce two implementations.
@MainActor
final class ServerURLRulesTests: XCTestCase {

    private let rawInputs = [
        "", "   ", "books.example.com", "HTTP://Books.Example.com/Base/", "https://example.com/?token=x",
        "ftp://books.example.com", "192.168.1.10:13378", "https://user:pass@example.com",
    ]

    func testAuthViewModelForwardsNormalisation() {
        for raw in rawInputs {
            XCTAssertEqual(AuthViewModel.normalizedServerURL(raw), ServerURLRules.normalizedServerURL(raw), raw)
        }
    }

    func testAuthViewModelForwardsPrivateHostDecision() {
        for host in ["localhost", "shelf.local", "10.1.2.3", "172.31.0.1", "172.32.0.1", "fe80::1", "8.8.8.8", "books.example.com"] {
            XCTAssertEqual(AuthViewModel.isLocalOrPrivateHost(host), ServerURLRules.isLocalOrPrivateHost(host), host)
        }
    }

    func testAuthViewModelForwardsInsecureConfirmationDecision() {
        for url in ["https://books.example.com", "http://192.168.1.10:13378", "http://shelf.local", "http://books.example.com"] {
            XCTAssertEqual(AuthViewModel.requiresInsecureConnectionConfirmation(for: url),
                           ServerURLRules.requiresInsecureConnectionConfirmation(for: url), url)
        }
    }

    func testSharedRulesRejectWhatTheWatchCopyUsedToReject() {
        // The Watch's former copy pinned exactly these; keeping them here means the shared
        // definition is now pinned from both bundles.
        XCTAssertNil(ServerURLRules.normalizedServerURL("ftp://books.example.com"))
        XCTAssertNil(ServerURLRules.normalizedServerURL("https://user:pass@example.com"))
        XCTAssertNil(ServerURLRules.normalizedServerURL("https://example.com/#/library"))
        XCTAssertEqual(ServerURLRules.normalizedServerURL("https://ABS.EXAMPLE.COM"), "https://abs.example.com")
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://books.example.com"))
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://192.168.1.10:13378"))
    }

    // MARK: - UX-4 follow-up: Tailscale is exempt (Batch 355)

    func testTailscaleRangeLowerAndUpperEdgesAreExempt() {
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.64.0.1"))
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.127.255.254:13378"))
    }

    func testAddressesJustOutsideTheTailscaleRangeStillAlert() {
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.63.255.255"))
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.128.0.1"))
    }

    func testMagicDNSNameIsExempt() {
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://nas.tailnet-1234.ts.net:13378"))
    }

    func testLookalikeAndBareHostnamesStillAlert() {
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://evil-ts.net"))
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://nas"))
    }

    func testAuthViewModelForwardsTheTailscaleDecision() {
        for host in ["100.64.0.1", "100.127.255.254", "100.63.255.255", "100.128.0.1", "nas.tailnet-1234.ts.net"] {
            XCTAssertEqual(AuthViewModel.isLocalOrPrivateHost(host), ServerURLRules.isLocalOrPrivateHost(host), host)
        }
    }
}
