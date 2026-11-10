import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): custom header values are proxy secrets. Account &
/// Security's editor no longer writes the Keychain on every keystroke, and Add Server's
/// Advanced section opens for the proxy refusals its advice points at.
@MainActor
final class HeaderSecretsTests: XCTestCase {

    // MARK: - Save only when something changed

    func testUnchangedHeadersAreNotSavedAgain() {
        XCTAssertFalse(ServerConnectionRules.headerSaveIsNeeded(["X-Token": "s"], lastSaved: ["X-Token": "s"],
                                                                lastSaveFailed: false))
        XCTAssertFalse(ServerConnectionRules.headerSaveIsNeeded([:], lastSaved: [:], lastSaveFailed: false))
    }

    func testChangedHeadersAreSaved() {
        XCTAssertTrue(ServerConnectionRules.headerSaveIsNeeded(["X-Token": "s2"], lastSaved: ["X-Token": "s"],
                                                               lastSaveFailed: false))
        XCTAssertTrue(ServerConnectionRules.headerSaveIsNeeded([:], lastSaved: ["X-Token": "s"],
                                                               lastSaveFailed: false))
        XCTAssertTrue(ServerConnectionRules.headerSaveIsNeeded(["X-Token": "s"], lastSaved: nil,
                                                               lastSaveFailed: false))
    }

    func testAFailedSaveIsRetriedEvenIfNothingChanged() {
        XCTAssertTrue(ServerConnectionRules.headerSaveIsNeeded(["X-Token": "s"], lastSaved: ["X-Token": "s"],
                                                               lastSaveFailed: true))
    }

    // MARK: - Advanced opens on a proxy refusal

    private func unreachable(_ failure: ServerConnectionFailure) -> ReachabilityStore.ConnectionTestResult {
        ReachabilityStore.ConnectionTestResult(outcome: .unreachable, resolvedURL: "https://abs.example.org",
                                               failure: failure)
    }

    func testAdvancedOpensOnHTTP401And403() {
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: unreachable(.httpStatus(401)),
                                                                            hasHeaders: false))
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: unreachable(.httpStatus(403)),
                                                                            hasHeaders: false))
    }

    func testAdvancedStaysShutForOtherFailures() {
        XCTAssertFalse(ServerConnectionRules.headersDisclosureStartsExpanded(result: unreachable(.httpStatus(500)),
                                                                             hasHeaders: false))
        XCTAssertFalse(ServerConnectionRules.headersDisclosureStartsExpanded(result: unreachable(.timedOut),
                                                                             hasHeaders: false))
    }

    func testExistingBehaviourIsKept() {
        let gate = ReachabilityStore.ConnectionTestResult(outcome: .notAudiobookshelf, resolvedURL: "https://x")
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: gate, hasHeaders: false))
        XCTAssertTrue(ServerConnectionRules.headersDisclosureStartsExpanded(result: nil, hasHeaders: true))
        XCTAssertFalse(ServerConnectionRules.headersDisclosureStartsExpanded(result: nil, hasHeaders: false))
    }
}
