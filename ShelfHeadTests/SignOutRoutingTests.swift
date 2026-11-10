import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden, second run): Sign Out is this server only. Pins where it
/// goes next (`AuthViewModel.nextAccountAfterSignOut`), when it signs in there by itself
/// (`switchesAutomaticallyAfterSignOut`), which teardown it runs (`signOutTeardownReason`)
/// and the message left when that sign-in fails.
@MainActor
final class SignOutRoutingTests: XCTestCase {

    private let a = ServerAccount(id: "A", serverURL: "https://a.example.com", username: "demo")
    private let b = ServerAccount(id: "B", serverURL: "https://b.example.com", username: "demo")
    private let c = ServerAccount(id: "C", serverURL: "http://192.168.1.50:13378", username: "demo")

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testNoOtherServerMeansTheSignInScreen() {
        XCTAssertNil(AuthViewModel.nextAccountAfterSignOut(signingOutId: "A", accounts: [a], lastUsed: [:]))
        XCTAssertNil(AuthViewModel.nextAccountAfterSignOut(signingOutId: nil, accounts: [], lastUsed: [:]))
    }

    func testPicksTheMostRecentlyUsedOtherServer() {
        let next = AuthViewModel.nextAccountAfterSignOut(
            signingOutId: "A", accounts: [a, b, c],
            lastUsed: ["A": date(300), "B": date(100), "C": date(200)])
        XCTAssertEqual(next?.id, "C")
    }

    func testNeverPicksTheServerBeingSignedOutOf() {
        let next = AuthViewModel.nextAccountAfterSignOut(
            signingOutId: "A", accounts: [a, b], lastUsed: ["A": date(999), "B": date(1)])
        XCTAssertEqual(next?.id, "B")
    }

    func testServersWithNoRecordFallBackToTheMostRecentlyAdded() {
        let next = AuthViewModel.nextAccountAfterSignOut(signingOutId: "A", accounts: [a, b, c], lastUsed: [:])
        XCTAssertEqual(next?.id, "C")
        // A recorded use beats no record at all.
        let recorded = AuthViewModel.nextAccountAfterSignOut(signingOutId: "A", accounts: [a, b, c],
                                                             lastUsed: ["B": date(1)])
        XCTAssertEqual(recorded?.id, "B")
    }

    func testOnlyAStoredPasswordSignsInAutomatically() {
        XCTAssertTrue(AuthViewModel.switchesAutomaticallyAfterSignOut(.password("pw")))
        XCTAssertFalse(AuthViewModel.switchesAutomaticallyAfterSignOut(.singleSignOn))
        XCTAssertFalse(AuthViewModel.switchesAutomaticallyAfterSignOut(.unavailable))
    }

    func testTeardownKeepsPerServerPreferencesWhileOtherServersRemain() {
        XCTAssertEqual(AuthViewModel.signOutTeardownReason(remainingSavedServers: 2, playbackAlreadyStopped: false),
                       .accountSwitch)
        XCTAssertEqual(AuthViewModel.signOutTeardownReason(remainingSavedServers: 0, playbackAlreadyStopped: false),
                       .signOut(playbackAlreadyStopped: false))
    }

    func testTeardownNeverStopsPlaybackTwice() {
        // Removing the current account has already stopped and flushed.
        for remaining in [0, 3] {
            let reason = AuthViewModel.signOutTeardownReason(remainingSavedServers: remaining,
                                                             playbackAlreadyStopped: true)
            XCTAssertFalse(reason.stopsPlayback, "remaining: \(remaining)")
        }
        XCTAssertTrue(AuthViewModel.signOutTeardownReason(remainingSavedServers: 2,
                                                          playbackAlreadyStopped: false).stopsPlayback)
    }

    func testAFailedAutomaticSignInSaysWhatHappened() {
        XCTAssertEqual(AuthViewModel.signOutSwitchFailedMessage(nextHost: "b.example.com",
                                                                reason: "Incorrect username or password."),
                       "Signed out. Couldn\u{2019}t sign in to b.example.com: Incorrect username or password.")
        XCTAssertEqual(AuthViewModel.signOutSwitchFailedMessage(nextHost: "b.example.com", reason: nil),
                       "Signed out. Couldn\u{2019}t sign in to b.example.com. Tap it under Saved servers to try again.")
    }
}
