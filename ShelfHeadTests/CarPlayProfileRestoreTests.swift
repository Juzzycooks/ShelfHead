import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • CarPlayProfileRestoreTests
// =============================================================================
//
// Restore-semantics fix (follow-up to P-14, REVIEW_2026-09-14_DESIGN.md — CarPlay
// half): Batch 318 made CarPlay auto-apply the Driving listening profile on connect
// and restore the pre-connect profile on disconnect, but documented a KNOWN
// SIMPLIFICATION — a manual switch away from Driving while still connected was
// clobbered by disconnect's restore. This pins
// `CarPlayCoordinator.profileToRestoreOnDisconnect(preConnect:autoApplied:activeNow:
// userChangedSinceAutoApply:)`, the pure decision function `
// restoreProfileAfterCarPlayIfNeeded()` now defers to, so the fix is verifiable
// without a live CarPlay session — same extract-a-pure-function precedent as
// `CarPlayListWindowingTests`. The function is `nonisolated static` on a `@MainActor`
// type, so it's callable directly here with no `await`.
final class CarPlayProfileRestoreTests: XCTestCase {

    // MARK: - Original behaviour: no manual change since the auto-switch

    func testRestoresPreConnectProfileWhenStillExactlyWhatCarPlayApplied() {
        // The bread-and-butter case this feature exists for: connect (was Off) → auto
        // Driving → disconnect with nothing touched in between → restore Off.
        let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
            preConnect: .off, autoApplied: .driving, activeNow: .driving,
            userChangedSinceAutoApply: false)
        XCTAssertEqual(restore, .off)
    }

    func testRestoresNonOffPreConnectProfileToo() {
        // Pre-connect profile was Work (not Off) — disconnect must restore Work, not
        // silently fall back to Off.
        let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
            preConnect: .work, autoApplied: .driving, activeNow: .driving,
            userChangedSinceAutoApply: false)
        XCTAssertEqual(restore, .work)
    }

    // MARK: - The fix: a manual switch since the auto-switch is honoured

    func testLeavesManuallyChosenProfileAloneRatherThanRestoringPreConnect() {
        // The exact scenario the KNOWN SIMPLIFICATION documented as broken: connect →
        // auto Driving → driver manually switches to Sleep (Setup row, player menu, or
        // Settings — any source) → disconnect must keep Sleep, not revert to whatever
        // was active before connecting.
        let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
            preConnect: .off, autoApplied: .driving, activeNow: .sleep,
            userChangedSinceAutoApply: true)
        XCTAssertNil(restore, "a deliberate manual switch since the auto-apply must not be reverted")
    }

    func testLeavesManualChoiceAloneEvenWhenItHappensToMatchAutoApplied() {
        // Edge case called out in the decision function's doc comment: the driver
        // re-picks Driving deliberately (e.g. via the CarPlay Setup row) after the
        // auto-switch already applied it. `activeNow == autoApplied` alone must not be
        // read as "nothing happened" — `userChangedSinceAutoApply` is the deciding
        // signal, not equality with `autoApplied`.
        let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
            preConnect: .work, autoApplied: .driving, activeNow: .driving,
            userChangedSinceAutoApply: true)
        XCTAssertNil(restore, "a deliberate re-pick of the same profile is still a deliberate pick, not the untouched auto-switch")
    }

    func testLeavesAloneWhenActiveProfileDiffersFromAutoAppliedEvenIfNotFlaggedAsUserChanged() {
        // Defensive case: `activeNow != autoApplied` despite `userChangedSinceAutoApply
        // == false` should never happen in practice (every `activate(_:)` call site is
        // tracked), but this must not restore over an unexplained state it doesn't
        // understand.
        let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
            preConnect: .off, autoApplied: .driving, activeNow: .work,
            userChangedSinceAutoApply: false)
        XCTAssertNil(restore)
    }

    // MARK: - preConnect == autoApplied (Driving was already active pre-connect)

    func testRestoringToTheSameProfileCarPlayAppliedIsStillCorrect() {
        // Degenerate but valid: pre-connect profile already was Driving (shouldn't
        // normally reach this function at all, since `offerOrApplyDrivingProfileIfNeeded`
        // guards on `activeProfile != .driving`, but the pure function itself must
        // still behave sanely if ever called this way).
        let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
            preConnect: .driving, autoApplied: .driving, activeNow: .driving,
            userChangedSinceAutoApply: false)
        XCTAssertEqual(restore, .driving)
    }

    // MARK: - Every ListeningProfile as the pre-connect value

    func testEveryProfileRoundTripsAsThePreConnectValueWhenUntouched() {
        for profile in ListeningProfile.allCases {
            let restore = CarPlayCoordinator.profileToRestoreOnDisconnect(
                preConnect: profile, autoApplied: .driving, activeNow: .driving,
                userChangedSinceAutoApply: false)
            XCTAssertEqual(restore, profile, "pre-connect profile \(profile) must round-trip when nothing changed it")
        }
    }
}
