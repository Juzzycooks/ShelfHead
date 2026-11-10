import XCTest
@testable import ShelfHead

/// Pins `WatchSessionManager.handoffCredentialPlan(...)` — the phone-side half of
/// item 10 ("shared rotating refresh token between phone and Watch", 10 September
/// 2026).
///
/// **What was broken.** `buildCredentialHandoffReply()` handed the Watch the phone's
/// *own* access token **and** its refresh token, and the phone then kept using the
/// same pair. Audiobookshelf's refresh tokens rotate and are single-use per session,
/// so whichever device refreshed first invalidated the other's. The phone always won
/// that race in practice — a rejected refresh there falls back to
/// `reauthenticateWithStoredCredentials()`, a silent full password re-login — while
/// the Watch, which by design never receives the password, had no fallback at all and
/// simply died with "Your session has expired."
///
/// The fix is to stop sharing one session: the phone mints the Watch a session of its
/// own when it can, and otherwise hands over something that cannot break its own
/// rotation chain. This file pins that preference order and, most importantly, the
/// invariant underneath it: **no plan ever hands over the phone's refresh token.**
///
/// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section.
final class WatchHandoffCredentialPlanTests: XCTestCase {

    private let accessToken = "access-abc"
    private let refreshToken = "refresh-xyz"

    // MARK: - Preference 1: a dedicated session

    func testAStoredPasswordMintsADedicatedSession() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: true,
                                                      legacyToken: nil,
                                                      accessToken: accessToken,
                                                      refreshToken: refreshToken),
            .dedicatedLogin)
    }

    /// The password wins even when a legacy token is also available — a real, separate
    /// session beats a shared permanent credential.
    func testAStoredPasswordOutranksALegacyToken() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: true,
                                                      legacyToken: "legacy-permanent",
                                                      accessToken: accessToken,
                                                      refreshToken: refreshToken),
            .dedicatedLogin)
    }

    // MARK: - Preference 2: the legacy, non-rotating token

    func testADistinctLegacyTokenIsHandedOverWhenThereIsNoPassword() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: false,
                                                      legacyToken: "legacy-permanent",
                                                      accessToken: accessToken,
                                                      refreshToken: refreshToken),
            .legacyAPIToken("legacy-permanent"))
    }

    func testAnEmptyLegacyTokenIsNotTreatedAsACredential() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: false,
                                                      legacyToken: "",
                                                      accessToken: accessToken,
                                                      refreshToken: refreshToken),
            .sharedAccessTokenOnly(isDurable: false))
    }

    func testAMissingLegacyTokenIsNotTreatedAsACredential() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: false,
                                                      legacyToken: nil,
                                                      accessToken: accessToken,
                                                      refreshToken: refreshToken),
            .sharedAccessTokenOnly(isDurable: false))
    }

    /// A pre-2.26 server: `User.effectiveAccessToken` *is* `User.token`, so the two
    /// strings are identical and there's nothing to prefer — but that equality is also
    /// proof the credential doesn't rotate or expire, which is what `isDurable: true`
    /// records. The Watch uses it to skip the "bring your iPhone nearby" copy.
    func testALegacyTokenIdenticalToTheAccessTokenIsSharedButMarkedDurable() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: false,
                                                      legacyToken: accessToken,
                                                      accessToken: accessToken,
                                                      refreshToken: nil),
            .sharedAccessTokenOnly(isDurable: true))
    }

    // MARK: - Preference 3: the fallback, and the invariant that matters

    /// The SSO/OIDC case: no password to mint a session with, no legacy token, and a
    /// live rotating refresh token sitting right there that must not be shared.
    func testAnSSOAccountFallsBackToTheAccessTokenAlone() {
        XCTAssertEqual(
            WatchSessionManager.handoffCredentialPlan(hasStoredPassword: false,
                                                      legacyToken: nil,
                                                      accessToken: accessToken,
                                                      refreshToken: refreshToken),
            .sharedAccessTokenOnly(isDurable: false))
    }

    /// The regression guard for the whole item: whatever the inputs, the plan never
    /// carries the phone's refresh token, and never claims it does.
    func testNoPlanEverHandsOverThePhonesRefreshToken() {
        let inputs: [(Bool, String?)] = [
            (true, nil), (true, "legacy-permanent"), (true, refreshToken),
            (false, nil), (false, ""), (false, "legacy-permanent"),
            (false, accessToken), (false, refreshToken),
        ]
        for (hasPassword, legacy) in inputs {
            let plan = WatchSessionManager.handoffCredentialPlan(hasStoredPassword: hasPassword,
                                                                 legacyToken: legacy,
                                                                 accessToken: accessToken,
                                                                 refreshToken: refreshToken)
            XCTAssertFalse(plan.handsOverPhoneRefreshToken,
                           "plan \(plan) claims to hand over the phone's refresh token")
            if case .legacyAPIToken(let token) = plan {
                XCTAssertNotEqual(token, refreshToken,
                                  "the refresh token leaked out as a 'legacy' credential")
            }
        }
    }

    /// A "legacy" token that happens to equal the phone's *refresh* token is refused
    /// outright — it cannot be the non-rotating API token, and handing it over would
    /// reshare the rotating credential under a different key. The plan degrades to the
    /// plain shared case (access token only, not durable), so the Watch knows to ask
    /// the phone again when it expires. Pinned because the plan type is the only thing
    /// standing between "we deliberately share a durable credential" and "we
    /// accidentally reshare the rotating one."
    func testALegacyTokenEqualToTheRefreshTokenIsRefused() {
        let plan = WatchSessionManager.handoffCredentialPlan(hasStoredPassword: false,
                                                             legacyToken: refreshToken,
                                                             accessToken: accessToken,
                                                             refreshToken: refreshToken)
        XCTAssertEqual(plan, .sharedAccessTokenOnly(isDurable: false))
        XCTAssertFalse(plan.handsOverPhoneRefreshToken)
    }

    // MARK: - Wire contract

    /// `sessionKind`'s raw values are a WatchConnectivity wire contract with the Watch
    /// target's own `WatchSessionKind` (which this test bundle can't import — different
    /// module). Pinned as literals on both sides so a rename here fails a test rather
    /// than silently degrading every Watch to the `.shared` fallback.
    func testSessionKindRawValuesAreTheWireContract() {
        XCTAssertEqual(WatchHandoffSessionKind.dedicated.rawValue, "dedicated")
        XCTAssertEqual(WatchHandoffSessionKind.durable.rawValue, "durable")
        XCTAssertEqual(WatchHandoffSessionKind.shared.rawValue, "shared")
    }
}
