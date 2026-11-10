// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and the sibling test
// files in this same target.
//
// Everything pinned here is a `nonisolated static` pure decision function, following
// this project's precedent (`WatchStore.shouldDeferModeChange`, `.resolvedMode`,
// `.signInGate`): pin the decision, don't try to drive the stateful credential path.
import XCTest
@testable import ShelfHead_Watch

// MARK: - Session kinds

/// Pins `WatchSessionKind`'s two derived properties and its raw values.
///
/// The raw values are a WatchConnectivity wire contract with the phone's
/// `WatchHandoffSessionKind` (`ShelfHead/Services/WatchSessionManager.swift`), which
/// this target can't import — `ShelfHeadTests/WatchHandoffCredentialPlanTests.swift`
/// pins the identical literals on the other side.
final class WatchSessionKindTests: XCTestCase {

    func testRawValuesAreTheWireContract() {
        XCTAssertEqual(WatchSessionKind.dedicated.rawValue, "dedicated")
        XCTAssertEqual(WatchSessionKind.durable.rawValue, "durable")
        XCTAssertEqual(WatchSessionKind.shared.rawValue, "shared")
    }

    func testOnlyABorrowedTokenNeedsThePhone() {
        XCTAssertTrue(WatchSessionKind.dedicated.survivesWithoutThePhone)
        XCTAssertTrue(WatchSessionKind.durable.survivesWithoutThePhone)
        XCTAssertFalse(WatchSessionKind.shared.survivesWithoutThePhone)
    }

    /// The gate on `POST /logout`. A `.durable` credential is Audiobookshelf's
    /// permanent user token — the phone is very likely authenticating with the same
    /// string — and `.shared` is literally a copy of the phone's access token, so
    /// closing either server-side could sign the *phone* out.
    func testOnlyADedicatedSessionMayBeClosedServerSide() {
        XCTAssertTrue(WatchSessionKind.dedicated.ownedExclusivelyByThisWatch)
        XCTAssertFalse(WatchSessionKind.durable.ownedExclusivelyByThisWatch)
        XCTAssertFalse(WatchSessionKind.shared.ownedExclusivelyByThisWatch)
    }
}

// MARK: - Which credential a handoff reply carried

/// Pins `WatchStore.handoffSessionKind(fromReply:refreshToken:)`, including its
/// backwards-compatible reading of a reply from a phone build that predates item 10
/// (no `sessionKind` key at all).
final class WatchHandoffSessionKindDecodingTests: XCTestCase {

    func testExplicitKindIsUsed() {
        XCTAssertEqual(
            WatchStore.handoffSessionKind(fromReply: ["sessionKind": "dedicated"], refreshToken: "r"),
            .dedicated)
        XCTAssertEqual(
            WatchStore.handoffSessionKind(fromReply: ["sessionKind": "durable"], refreshToken: nil),
            .durable)
        XCTAssertEqual(
            WatchStore.handoffSessionKind(fromReply: ["sessionKind": "shared"], refreshToken: nil),
            .shared)
    }

    /// An explicit `durable` wins over the refresh-token inference — that's the whole
    /// reason the key exists.
    func testExplicitKindOutranksTheRefreshTokenInference() {
        XCTAssertEqual(
            WatchStore.handoffSessionKind(fromReply: ["sessionKind": "shared"], refreshToken: "r"),
            .shared)
    }

    func testUnknownKindFallsBackToTheInference() {
        XCTAssertEqual(
            WatchStore.handoffSessionKind(fromReply: ["sessionKind": "quantum"], refreshToken: "r"),
            .dedicated)
        XCTAssertEqual(
            WatchStore.handoffSessionKind(fromReply: ["sessionKind": "quantum"], refreshToken: nil),
            .shared)
    }

    /// An older phone build sends no `sessionKind`. What it did send was its own pair,
    /// so a refresh token means "this Watch holds a pair it can rotate" — the exact
    /// behaviour this Watch had before item 10, which is the right thing to preserve
    /// for a mixed-version pairing.
    func testOlderPhoneWithARefreshTokenReadsAsDedicated() {
        XCTAssertEqual(WatchStore.handoffSessionKind(fromReply: ["ok": true], refreshToken: "r"), .dedicated)
    }

    func testOlderPhoneWithoutARefreshTokenReadsAsShared() {
        XCTAssertEqual(WatchStore.handoffSessionKind(fromReply: ["ok": true], refreshToken: nil), .shared)
        XCTAssertEqual(WatchStore.handoffSessionKind(fromReply: ["ok": true], refreshToken: ""), .shared)
    }
}

// MARK: - Whether an arriving handoff replaces what's here

/// Pins `WatchStore.applyHandoff(existing:incoming:)` — item 10's rule that a working
/// session of this Watch's own is never traded away for a borrowed access token.
final class WatchApplyHandoffTests: XCTestCase {

    private let server = "https://abs.example.com"

    private func existing(_ kind: WatchSessionKind, usable: Bool = true,
                          server: String? = nil) -> WatchStore.ExistingWatchSession {
        WatchStore.ExistingWatchSession(kind: kind, isUsable: usable, serverURL: server ?? self.server)
    }

    private func incoming(_ kind: WatchSessionKind, server: String? = nil) -> WatchStore.IncomingHandoff {
        WatchStore.IncomingHandoff(kind: kind, serverURL: server ?? self.server)
    }

    func testNoExistingSessionAlwaysAdopts() {
        XCTAssertEqual(WatchStore.applyHandoff(existing: nil, incoming: incoming(.shared)), .adopt)
        XCTAssertEqual(WatchStore.applyHandoff(existing: nil, incoming: incoming(.dedicated)), .adopt)
    }

    /// The case the whole function exists for: a dedicated session that still works
    /// must not be replaced by a token that expires within the hour and can't be
    /// renewed away from the phone.
    func testAWorkingDedicatedSessionIsNotTradedForABorrowedToken() {
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.dedicated), incoming: incoming(.shared)),
                       .keepExisting)
    }

    func testAWorkingDurableSessionIsNotTradedForABorrowedToken() {
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.durable), incoming: incoming(.shared)),
                       .keepExisting)
    }

    /// A dedicated session the server has already rejected is worth less than a fresh
    /// borrowed token — and this branch is what lets the automatic re-handoff in
    /// `signalSessionExpired()` recover anything at all.
    func testARejectedDedicatedSessionIsReplacedByABorrowedToken() {
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.dedicated, usable: false),
                                               incoming: incoming(.shared)),
                       .adopt)
    }

    func testABorrowedSessionIsAlwaysReplaced() {
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.shared), incoming: incoming(.shared)), .adopt)
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.shared), incoming: incoming(.dedicated)), .adopt)
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.shared), incoming: incoming(.durable)), .adopt)
    }

    func testAnUpgradeIsAlwaysAdopted() {
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.durable), incoming: incoming(.dedicated)), .adopt)
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.dedicated), incoming: incoming(.dedicated)), .adopt)
        XCTAssertEqual(WatchStore.applyHandoff(existing: existing(.dedicated), incoming: incoming(.durable)), .adopt)
    }

    /// The phone switched account or server — following it is the point of a handoff,
    /// so even a perfectly good dedicated session for the *old* server is replaced.
    func testADifferentServerAlwaysAdopts() {
        XCTAssertEqual(
            WatchStore.applyHandoff(existing: existing(.dedicated),
                                    incoming: incoming(.shared, server: "https://other.example.com")),
            .adopt)
    }

    /// …but a trailing slash or a difference in case is not a different server, and
    /// must not be allowed to discard a good session on every handoff.
    func testTrailingSlashAndCaseAreNotAServerChange() {
        XCTAssertEqual(
            WatchStore.applyHandoff(existing: existing(.dedicated, server: "https://abs.example.com"),
                                    incoming: incoming(.shared, server: "https://ABS.example.com/")),
            .keepExisting)
    }

    func testComparableServerURLNormalisesSlashesCaseAndWhitespace() {
        XCTAssertEqual(WatchStore.comparableServerURL("  https://ABS.Example.com/// "),
                       "https://abs.example.com")
        XCTAssertEqual(WatchStore.comparableServerURL("https://abs.example.com"),
                       "https://abs.example.com")
    }
}

// MARK: - What to do about an expired session

/// Pins `WatchStore.sessionExpiryRecovery(...)`, item 10's replacement for the old
/// unconditional dead end.
///
/// Since the phone now deliberately withholds its refresh token from a `.shared`
/// handoff, "the access token expired" is a routine, expected event rather than a
/// failure — and the remedy (a fresh handoff) is free whenever the phone is nearby.
final class WatchSessionExpiryRecoveryTests: XCTestCase {

    func testAReachablePhoneIsAlwaysAskedFirst() {
        XCTAssertEqual(
            WatchStore.sessionExpiryRecovery(hasRefreshToken: false, phoneIsReachable: true,
                                             recentlyAttemptedHandoff: false),
            .requestHandoff)
        // Even with its own refresh chain: if that chain just failed, the phone can mint
        // a brand-new session, which beats sending the user to a sign-in screen.
        XCTAssertEqual(
            WatchStore.sessionExpiryRecovery(hasRefreshToken: true, phoneIsReachable: true,
                                             recentlyAttemptedHandoff: false),
            .requestHandoff)
    }

    /// The standalone dead end, with copy that names the actual remedy.
    func testABorrowedTokenWithNoPhoneAsksForThePhone() {
        XCTAssertEqual(
            WatchStore.sessionExpiryRecovery(hasRefreshToken: false, phoneIsReachable: false,
                                             recentlyAttemptedHandoff: false),
            .bringPhoneNearby)
    }

    /// This Watch had its own rotation chain and the server rejected it — a handoff
    /// isn't available, so manual sign-in is the honest answer.
    func testAnOwnRefreshChainThatFailedWithNoPhoneSaysSignInAgain() {
        XCTAssertEqual(
            WatchStore.sessionExpiryRecovery(hasRefreshToken: true, phoneIsReachable: false,
                                             recentlyAttemptedHandoff: false),
            .signInAgain)
    }

    /// The loop guard: a reachable phone that couldn't help must not be asked again on
    /// every subsequent failed request.
    func testARecentAttemptStopsTheRetryLoop() {
        XCTAssertEqual(
            WatchStore.sessionExpiryRecovery(hasRefreshToken: false, phoneIsReachable: true,
                                             recentlyAttemptedHandoff: true),
            .signInAgain)
        XCTAssertEqual(
            WatchStore.sessionExpiryRecovery(hasRefreshToken: true, phoneIsReachable: true,
                                             recentlyAttemptedHandoff: true),
            .signInAgain)
    }

    /// The invariant that keeps companion mode from ever showing standalone-only copy:
    /// `WatchAccountView`/`WatchSettingsView` render `authFailureMessage` in both
    /// modes, so "bring your iPhone nearby" has to be unreachable while the phone is
    /// reachable — by construction, not by which screen happens to show it.
    func testBringPhoneNearbyIsUnreachableWhileThePhoneIsReachable() {
        for hasRefresh in [true, false] {
            for recentlyAttempted in [true, false] {
                let outcome = WatchStore.sessionExpiryRecovery(hasRefreshToken: hasRefresh,
                                                               phoneIsReachable: true,
                                                               recentlyAttemptedHandoff: recentlyAttempted)
                XCTAssertNotEqual(outcome, .bringPhoneNearby,
                                  "hasRefresh=\(hasRefresh) recentlyAttempted=\(recentlyAttempted)")
            }
        }
    }
}

// MARK: - What the user is told about reconnecting

/// Pins `WatchStore.reconnectExpectation(for:)`. Before item 10 this was "is the
/// refresh token nil," which now conflates two very different situations: a pre-2.26
/// server's permanent token (nothing to warn about) and a deliberately borrowed access
/// token (works for about an hour away from the phone).
final class WatchReconnectExpectationTests: XCTestCase {

    func testSessionsThatSurviveAloneSayNothing() {
        XCTAssertNil(WatchStore.reconnectExpectation(for: .dedicated))
        XCTAssertNil(WatchStore.reconnectExpectation(for: .durable))
    }

    func testABorrowedSessionSetsExpectationsUpFront() {
        let copy = WatchStore.reconnectExpectation(for: .shared)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy?.contains("iPhone") == true)
    }
}
