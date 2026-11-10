import XCTest
@testable import ShelfHead

/// Item 28 (proactive security audit): `ReachabilityStore.testConnection(rawURL:)` used to
/// unconditionally forward the ACTIVE account's custom proxy headers (Cloudflare Access,
/// Authelia, nginx `auth_request`, ...) to whatever host the user had typed into the "Add
/// Server" screen — a credential leak to an arbitrary host whenever it differed from the
/// account currently signed in. The fix adds a `customHeaders` parameter and gates the
/// only remaining implicit fallback (to `AuthStore.shared.customHeaders`) on this pure
/// function: only forward when the host being tested is the SAME host the active account
/// is actually signed into.
///
/// Only the pure decision is pinned here — `testConnection` itself makes a real network
/// request and reads live `AuthStore`/`AuthViewModel` state, which isn't something this
/// suite reaches into.
final class ReachabilityHeaderForwardingTests: XCTestCase {

    func testSameHostForwards() {
        XCTAssertTrue(
            ReachabilityStore.shouldForwardActiveHeaders(testedHost: "audiobooks.example.com",
                                                          activeHost: "audiobooks.example.com"))
    }

    func testDifferentHostDoesNotForward() {
        XCTAssertFalse(
            ReachabilityStore.shouldForwardActiveHeaders(testedHost: "totally-different.example.net",
                                                          activeHost: "audiobooks.example.com"))
    }

    /// Hostnames aren't case-sensitive — a user retyping the same server with different
    /// casing shouldn't lose their proxy headers.
    func testCaseDifferenceStillForwards() {
        XCTAssertTrue(
            ReachabilityStore.shouldForwardActiveHeaders(testedHost: "Audiobooks.Example.COM",
                                                          activeHost: "audiobooks.example.com"))
    }

    /// Nothing is signed in yet (e.g. the very first "Add Server" screen a user ever
    /// sees) — there is no active account's headers to forward, regardless of what was
    /// typed.
    func testNilActiveHostDoesNotForward() {
        XCTAssertFalse(
            ReachabilityStore.shouldForwardActiveHeaders(testedHost: "audiobooks.example.com",
                                                          activeHost: nil))
    }

    func testNilTestedHostDoesNotForward() {
        XCTAssertFalse(
            ReachabilityStore.shouldForwardActiveHeaders(testedHost: nil,
                                                          activeHost: "audiobooks.example.com"))
    }

    func testEmptyHostsDoNotForward() {
        XCTAssertFalse(ReachabilityStore.shouldForwardActiveHeaders(testedHost: "", activeHost: ""))
    }
}
