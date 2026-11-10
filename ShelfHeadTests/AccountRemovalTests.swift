import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • AccountRemovalTests
// =============================================================================
//
// T1 (REVIEW_2026-09-04_UI.md): swiping to delete the *currently active* account in
// Settings > Account & Security > Servers dropped its Keychain password and its
// entry in the saved-account list, but left the live session (tokens, `serverURL`/
// `username`, playback) untouched — "Current Account" kept showing the just-removed
// account until the user backgrounded the app or tapped Sign Out. The fix ends the
// live session whenever the removed account is the current one (`logout()`'s full
// wipe until Critique 2026-10-06; now that server's session only, through Sign Out's
// tail `finishEndingLiveSession`), decided by the pure `AuthViewModel.removalAlsoSignsOut(removedId:
// currentId:)`. This pins that decision function, since `removeAccount` itself talks
// to the real Keychain/AccountStore and isn't unit-testable directly — same
// "extract the decision, test the decision" precedent as `CarPlayStateTests.swift`
// and `DownloadManager.shouldReclaimOrphanDirectory`.
final class AccountRemovalTests: XCTestCase {

    func testRemovingTheCurrentAccountAlsoSignsOut() {
        XCTAssertTrue(AuthViewModel.removalAlsoSignsOut(removedId: "acct-1", currentId: "acct-1"))
    }

    func testRemovingADifferentAccountDoesNotSignOut() {
        XCTAssertFalse(AuthViewModel.removalAlsoSignsOut(removedId: "acct-2", currentId: "acct-1"))
    }

    func testRemovingAnAccountWithNoCurrentAccountDoesNotSignOut() {
        XCTAssertFalse(AuthViewModel.removalAlsoSignsOut(removedId: "acct-1", currentId: nil))
    }
}

// =============================================================================
// Fix 5 (REVIEW-2026-09-09.md) — one account-lifecycle cleanup routine
// =============================================================================
//
// Sign-out, account switch and account removal now share
// `AuthViewModel.tearDownAccountScopedState(reason:)`. The routine itself talks to the
// real Keychain, filesystem, Spotlight index and App Group container, so what's pinned
// here is the same thing `AccountRemovalTests` above pins: the pure decisions the
// routine and its callers make. Three of them:
//
//  1. `DownloadManager.scopedDefaultsKeys(scope:)` — the purge list that account
//     deletion walks. The bug was a purge with hand-written literals drifting behind
//     the key builders, so the test asserts the builders and the list can't disagree.
//  2. `AuthViewModel.reauthenticationMethod(for:storedPassword:)` — SSO vs. password
//     routing, which is what stops a switch from tearing down a live session for a
//     login that could only fail.
//  3. `DownloadManager.shouldReclaimScopeDirectory(_:knownScopeKeys:currentScopeKey:)`
//     — the guard on the orphaned-scope sweep, i.e. the one piece of this fix that
//     deletes downloaded audio.
/// `@MainActor`: matches `DownloadManagerScopeTests` — the `DownloadManager` members
/// exercised here are main-actor-isolated even where the functions themselves are pure.
@MainActor
final class AccountLifecycleCleanupTests: XCTestCase {

    // MARK: - Scoped UserDefaults keys

    /// Computed rather than stored: `XCTestCase` instances are created by the ObjC
    /// runtime, so a `@MainActor` test class is better off without stored-property
    /// initializers that run inside that init.
    private var scope: String {
        DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1")
    }

    func testEveryScopedKeyBuilderAppearsInThePurgeList() {
        let keys = DownloadManager.scopedDefaultsKeys(scope: scope)
        // Each builder used anywhere in `DownloadManager` for per-scope state.
        for built in [DownloadManager.downloadedItemsKey(scope: scope),
                      DownloadManager.pausedItemsKey(scope: scope),
                      DownloadManager.failedDownloadsKey(scope: scope),
                      DownloadManager.applicationSupportMigrationKey(scope: scope)] {
            XCTAssertTrue(keys.contains(built),
                          "\(built) is written per scope but wouldn't be purged on account removal.")
        }
    }

    func testPurgeListIncludesTheFailedDownloadsKey() {
        // The specific miss this fix is named for: `shelfhead_failedDownloads.<scope>`
        // retained a removed account's failed-download records, book titles included.
        XCTAssertTrue(DownloadManager.scopedDefaultsKeys(scope: scope)
            .contains { $0.hasPrefix("shelfhead_failedDownloads.") })
    }

    func testPurgeListHasNoDuplicatesAndIsAllScopeSuffixed() {
        let keys = DownloadManager.scopedDefaultsKeys(scope: scope)
        XCTAssertEqual(Set(keys).count, keys.count, "A key listed twice means a builder was aliased.")
        for key in keys {
            XCTAssertTrue(key.hasSuffix("." + scope), "\(key) isn't scope-suffixed, so it isn't per-account.")
        }
    }

    func testScopedKeysOfTwoAccountsNeverOverlap() {
        let other = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "user-2")
        let mine = Set(DownloadManager.scopedDefaultsKeys(scope: scope))
        let theirs = Set(DownloadManager.scopedDefaultsKeys(scope: other))
        XCTAssertTrue(mine.isDisjoint(with: theirs),
                      "Purging one account's keys must not remove another account's state.")
    }

    // MARK: - SSO vs. password routing

    private func account(sso: Bool?) -> ServerAccount {
        ServerAccount(id: "acct-1", serverURL: "https://abs.example.com", username: "justin",
                      usesSingleSignOn: sso)
    }

    func testAccountMarkedSSORoutesToSingleSignOnEvenWithAStoredPassword() {
        // The flag wins: an SSO account that also has a stale password entry from a
        // previous password login must not be re-authenticated with it.
        XCTAssertEqual(AuthViewModel.reauthenticationMethod(for: account(sso: true), storedPassword: "hunter2"),
                       .singleSignOn)
    }

    func testEmptyStoredPasswordIsReadAsSingleSignOn() {
        // `loginWithOIDC` saves `""`, so this is what every SSO account saved before
        // `ServerAccount.usesSingleSignOn` existed looks like on disk. Reading it as a
        // real credential is what used to tear down the session for an impossible login.
        XCTAssertEqual(AuthViewModel.reauthenticationMethod(for: account(sso: nil), storedPassword: ""),
                       .singleSignOn)
    }

    func testRealStoredPasswordRoutesToThePasswordLogin() {
        XCTAssertEqual(AuthViewModel.reauthenticationMethod(for: account(sso: false), storedPassword: "hunter2"),
                       .password("hunter2"))
    }

    func testMissingPasswordEntryIsUnavailableRatherThanSSO() {
        // "Stay signed in" off deletes the entry entirely. That's a prompt-the-user case,
        // not an SSO one — and, crucially, `switchAccount` returns before any teardown.
        XCTAssertEqual(AuthViewModel.reauthenticationMethod(for: account(sso: nil), storedPassword: nil),
                       .unavailable)
    }

    func testSSOMarkedAccountWithNoPasswordEntryStillRoutesToSingleSignOn() {
        XCTAssertEqual(AuthViewModel.reauthenticationMethod(for: account(sso: true), storedPassword: nil),
                       .singleSignOn)
    }

    // MARK: - Orphaned download-scope sweep

    func testOrphanedScopeIsReclaimable() {
        XCTAssertTrue(DownloadManager.shouldReclaimScopeDirectory(
            "scope-gone", knownScopeKeys: ["scope-a", "scope-b"], currentScopeKey: "scope-a"))
    }

    func testKnownAndCurrentScopesAreNeverReclaimed() {
        XCTAssertFalse(DownloadManager.shouldReclaimScopeDirectory(
            "scope-b", knownScopeKeys: ["scope-a", "scope-b"], currentScopeKey: "scope-a"))
        XCTAssertFalse(DownloadManager.shouldReclaimScopeDirectory(
            "scope-a", knownScopeKeys: ["scope-a", "scope-b"], currentScopeKey: "scope-a"))
    }

    func testNothingIsReclaimedWhenTheKnownListDoesNotContainTheActiveScope() {
        // The failure mode that matters: `AccountStore.accounts()` returns `[]` on any
        // Keychain read/decode failure, and reading that as "every scope on disk is an
        // orphan" would delete every download on the device.
        XCTAssertFalse(DownloadManager.shouldReclaimScopeDirectory(
            "scope-gone", knownScopeKeys: [], currentScopeKey: "scope-a"))
        XCTAssertFalse(DownloadManager.shouldReclaimScopeDirectory(
            "scope-gone", knownScopeKeys: ["scope-b"], currentScopeKey: "scope-a"))
    }

    func testPlaceholderAndHiddenDirectoriesAreNeverReclaimed() {
        XCTAssertFalse(DownloadManager.shouldReclaimScopeDirectory(
            "unscoped", knownScopeKeys: ["scope-a"], currentScopeKey: "scope-a"))
        XCTAssertFalse(DownloadManager.shouldReclaimScopeDirectory(
            ".paused", knownScopeKeys: ["scope-a"], currentScopeKey: "scope-a"))
    }

    // MARK: - Loader staleness

    func testLoadIsStaleAfterTheAccountGenerationBumps() {
        XCTAssertTrue(LibraryViewModel.isStaleLoad(
            startedAccountGeneration: 1, currentAccountGeneration: 2,
            startedLibraryId: "lib-1", currentLibraryId: "lib-1"))
    }

    func testLoadIsStaleWhenTheSelectedLibraryChanged() {
        XCTAssertTrue(LibraryViewModel.isStaleLoad(
            startedAccountGeneration: 1, currentAccountGeneration: 1,
            startedLibraryId: "lib-1", currentLibraryId: "lib-2"))
        // Including "a library was selected, now none is" — an account switch clears it.
        XCTAssertTrue(LibraryViewModel.isStaleLoad(
            startedAccountGeneration: 1, currentAccountGeneration: 1,
            startedLibraryId: "lib-1", currentLibraryId: nil))
    }

    func testUnchangedAccountAndLibraryIsNotStale() {
        XCTAssertFalse(LibraryViewModel.isStaleLoad(
            startedAccountGeneration: 3, currentAccountGeneration: 3,
            startedLibraryId: "lib-1", currentLibraryId: "lib-1"))
    }

    func testLibrarylessLoaderIsJudgedOnTheAccountGenerationAlone() {
        // `loadUserProgress()` reads `/api/me`, which isn't library-scoped, so it passes
        // `nil` for both ids.
        XCTAssertFalse(LibraryViewModel.isStaleLoad(
            startedAccountGeneration: 7, currentAccountGeneration: 7,
            startedLibraryId: nil, currentLibraryId: nil))
        XCTAssertTrue(LibraryViewModel.isStaleLoad(
            startedAccountGeneration: 7, currentAccountGeneration: 8,
            startedLibraryId: nil, currentLibraryId: nil))
    }
}
// =============================================================================
// Item 12 (REVIEW-2026-09-09-REMAINING.md) — removal step ordering
// =============================================================================
//
// Removing the account you are signed in as used to delete
// `Downloads/accounts/<scope>` — including every book's `manifest.json`, the only
// local progress store — and only *then* call `logout()`, whose teardown is what
// awaits `AudioPlayerService.stopAndFlush()`. The playing book's final position was
// therefore flushed after its local manifest was already gone.
//
// The fix makes the flush the first step, and specifically ahead of
// `AccountStore.remove`: that call clears the current-account id, and both
// `DownloadManager.currentScopeKey()` and `AudioPlayerService.currentProgressScope()`
// read it, so a flush after it would write the manifest into a different
// (nonexistent) `…|unknown` scope and file the queued fallback entry under that scope
// too. `removeAccount(_:)` is a loop over `AuthViewModel.removalSteps(isCurrent:)`,
// so the ordering is a pure value and this is a real pin on the shipped sequence
// rather than a restatement of it — same "extract the decision, test the decision"
// precedent as `AccountLifecycleCleanupTests` above.
/// `@MainActor`: `AccountRemovalStep`/`AccountTeardownReason` are nested in the
/// `@MainActor` `AuthViewModel`, matching `AccountLifecycleCleanupTests`.
@MainActor
final class AccountRemovalOrderingTests: XCTestCase {

    private func steps(current: Bool) -> [AuthViewModel.AccountRemovalStep] {
        AuthViewModel.removalSteps(isCurrent: current)
    }

    private func index(_ step: AuthViewModel.AccountRemovalStep, current: Bool) -> Int? {
        steps(current: current).firstIndex(of: step)
    }

    // MARK: - Current-account removal

    func testCurrentAccountRemovalIsTheFullFourStepSequence() {
        XCTAssertEqual(steps(current: true),
                       [.stopAndFlushPlayback, .removeCredentials,
                        .deleteAccountScopedState, .signOutSession])
    }

    func testFlushHappensBeforeTheDownloadTreeIsDeleted() {
        // The bug itself: the final position was written after `manifest.json` was gone.
        let flush = index(.stopAndFlushPlayback, current: true)
        let deleteTree = index(.deleteAccountScopedState, current: true)
        XCTAssertNotNil(flush)
        XCTAssertNotNil(deleteTree)
        XCTAssertLessThan(flush ?? .max, deleteTree ?? .min)
    }

    func testFlushHappensBeforeTheCredentialsAndCurrentAccountIdAreRemoved() {
        // Not merely "before the delete": `AccountStore.remove` calls `clearCurrent()`,
        // and the local manifest write resolves its directory through the current
        // account id. Flushing after it would still lose the local write.
        let flush = index(.stopAndFlushPlayback, current: true)
        let remove = index(.removeCredentials, current: true)
        XCTAssertLessThan(flush ?? .max, remove ?? .min)
    }

    func testSignOutIsTheLastStep() {
        // The sign-out step (`finishEndingLiveSession` since the 2026-10-06 critique; was
        // `logout()`) clears `AuthStore` and posts `.shelfheadAccountChanged`; anything
        // that still needs the outgoing account's credentials has to have run already.
        XCTAssertEqual(steps(current: true).last, .signOutSession)
    }

    func testTheDownloadTreeIsOnlyDeletedAfterTheAccountIsActuallyRemoved() {
        // Both orders: the tree must never be deleted for an account still in the
        // saved-account list (the `guard removed else { return }` case).
        for current in [true, false] {
            let remove = index(.removeCredentials, current: current)
            let deleteTree = index(.deleteAccountScopedState, current: current)
            XCTAssertLessThan(remove ?? .max, deleteTree ?? .min,
                              "isCurrent: \(current)")
        }
    }

    func testEveryStepAppearsAtMostOnce() {
        for current in [true, false] {
            let all = steps(current: current)
            XCTAssertEqual(Set(all).count, all.count,
                           "A repeated step means a second stop, flush or teardown pass.")
        }
    }

    // MARK: - Non-current removal is untouched

    func testNonCurrentRemovalNeitherStopsPlaybackNorSignsOut() {
        XCTAssertEqual(steps(current: false), [.removeCredentials, .deleteAccountScopedState])
        XCTAssertFalse(steps(current: false).contains(.stopAndFlushPlayback),
                       "Deleting some other saved account must not interrupt playback.")
        XCTAssertFalse(steps(current: false).contains(.signOutSession))
    }

    // MARK: - Exactly one stop, exactly one flush

    /// The teardown reason each step hands to `tearDownAccountScopedState`, so the test
    /// can count playback stops across the whole removal rather than just within one
    /// function. Mirrors `removeAccount(_:)`'s switch.
    private func reason(for step: AuthViewModel.AccountRemovalStep)
        -> AuthViewModel.AccountTeardownReason? {
        switch step {
        case .stopAndFlushPlayback: return nil          // direct `stopPlaybackAndTransfers()`
        case .removeCredentials: return nil
        case .deleteAccountScopedState: return .accountRemoval(scopeKey: "scope-a", wasActiveScope: true)
        // Via `AuthViewModel.signOutTeardownReason(remainingSavedServers:playbackAlreadyStopped: true)`,
        // which is this for any number of remaining servers.
        case .signOutSession: return .signOut(playbackAlreadyStopped: true)
        }
    }

    func testCurrentAccountRemovalStopsPlaybackExactlyOnce() {
        var stops = 0
        for step in steps(current: true) {
            if step == .stopAndFlushPlayback { stops += 1 }
            if reason(for: step)?.stopsPlayback == true { stops += 1 }
        }
        XCTAssertEqual(stops, 1, "A second stop would race the awaited flush.")
    }

    func testNonCurrentAccountRemovalStopsPlaybackNever() {
        var stops = 0
        for step in steps(current: false) {
            if step == .stopAndFlushPlayback { stops += 1 }
            if reason(for: step)?.stopsPlayback == true { stops += 1 }
        }
        XCTAssertEqual(stops, 0)
    }

    // MARK: - The teardown reason's own flag

    func testSignOutStopsPlaybackUnlessTheCallerAlreadyDid() {
        XCTAssertTrue(AuthViewModel.AccountTeardownReason
            .signOut(playbackAlreadyStopped: false).stopsPlayback)
        XCTAssertFalse(AuthViewModel.AccountTeardownReason
            .signOut(playbackAlreadyStopped: true).stopsPlayback)
    }

    func testAccountSwitchStillStopsPlaybackAndRemovalNeverDoes() {
        XCTAssertTrue(AuthViewModel.AccountTeardownReason.accountSwitch.stopsPlayback)
        XCTAssertFalse(AuthViewModel.AccountTeardownReason
            .accountRemoval(scopeKey: "scope-a", wasActiveScope: true).stopsPlayback)
    }

    func testIsSignOutIgnoresThePayload() {
        // The sign-out-only tail (per-book speeds, cover caches) must still run when the
        // sign-out arrives from a current-account removal.
        XCTAssertTrue(AuthViewModel.AccountTeardownReason
            .signOut(playbackAlreadyStopped: true).isSignOut)
        XCTAssertTrue(AuthViewModel.AccountTeardownReason
            .signOut(playbackAlreadyStopped: false).isSignOut)
        XCTAssertFalse(AuthViewModel.AccountTeardownReason.accountSwitch.isSignOut)
        XCTAssertFalse(AuthViewModel.AccountTeardownReason
            .accountRemoval(scopeKey: "scope-a", wasActiveScope: true).isSignOut)
    }
}
// =============================================================================
// Item 12 follow-up — deleting the *active* scope's tree clears the live caches
// =============================================================================
//
// `DownloadManager.deleteDownloads(forScopeKey:)` decided whether a deletion was
// "the account you're signed in as" by comparing against `currentScopeKey()` — but
// `AuthViewModel.removeAccount(_:)` only reaches it after `AccountStore.remove` has
// called `clearCurrent()`, so the comparison always failed and the removal took the
// bare-`removeItem` path. `downloadedItems`, `manifests`, `failedDownloads`,
// `itemsWithLocalCover` and the completed-track cache were left describing books whose
// files had just been deleted, so every "is this downloaded?" surface kept saying yes.
// The caller now passes the answer in, and this pins the branch decision.
@MainActor
final class ScopeDeletionDecisionTests: XCTestCase {

    private let scope = "abs.example.com|user-1"
    private let placeholder = "abs.example.com|unknown"

    // MARK: - Which keys may name a tree at all

    func testEmptyAndPlaceholderScopeKeysAreNeverDeletable() {
        // An empty key resolves to the `accounts/` parent; `"unscoped"` is the shared
        // bucket used before any account is configured.
        XCTAssertFalse(DownloadManager.isDeletableScopeKey(""))
        XCTAssertFalse(DownloadManager.isDeletableScopeKey("unscoped"))
    }

    func testARealScopeKeyIsDeletable() {
        XCTAssertTrue(DownloadManager.isDeletableScopeKey(scope))
    }

    // MARK: - The branch that clears the in-memory caches

    func testCallerVouchingForTheActiveScopeWinsOverTheStaleComparison() {
        // The bug in one assertion: the live scope has already degraded to the
        // `…|unknown` placeholder, so only the caller's flag can get this right.
        XCTAssertTrue(DownloadManager.scopeDeletionClearsLiveState(
            scopeKey: scope, activeScopeKey: placeholder, wasActiveScope: true))
    }

    func testRemovingSomeOtherAccountLeavesTheLiveCachesAlone() {
        XCTAssertFalse(DownloadManager.scopeDeletionClearsLiveState(
            scopeKey: "abs.example.com|user-2", activeScopeKey: scope, wasActiveScope: false))
        // Even if the live comparison would have matched, an explicit `false` wins —
        // the caller knows more than the comparison does.
        XCTAssertFalse(DownloadManager.scopeDeletionClearsLiveState(
            scopeKey: scope, activeScopeKey: scope, wasActiveScope: false))
    }

    func testWithNoAnswerFromTheCallerItFallsBackToTheLiveComparison() {
        XCTAssertTrue(DownloadManager.scopeDeletionClearsLiveState(
            scopeKey: scope, activeScopeKey: scope, wasActiveScope: nil))
        XCTAssertFalse(DownloadManager.scopeDeletionClearsLiveState(
            scopeKey: scope, activeScopeKey: placeholder, wasActiveScope: nil))
    }

    // MARK: - The orphan sweep's trust gate, now explicit

    func testTheSweepRunsOnlyWhenTheSavedListVouchesForTheSignedInAccount() {
        XCTAssertTrue(DownloadManager.canRunOrphanScopeSweep(
            knownScopeKeys: [scope, "abs.example.com|user-2"], currentScopeKey: scope))
    }

    func testTheSweepIsANoOpAfterRemovingTheAccountYouWereSignedInAs() {
        // `clearCurrent()` has run, so the live scope is the placeholder and no saved
        // account can vouch for the list. Previously this was an accidental no-op that
        // fell out of every per-directory decision returning `false`.
        XCTAssertFalse(DownloadManager.canRunOrphanScopeSweep(
            knownScopeKeys: ["abs.example.com|user-2"], currentScopeKey: placeholder))
        XCTAssertFalse(DownloadManager.canRunOrphanScopeSweep(
            knownScopeKeys: [], currentScopeKey: placeholder))
    }

    func testTheTrustGateIsTheSameOneTheDirectoryDecisionUses() {
        // `shouldReclaimScopeDirectory` delegates to it, so the early return in
        // `reclaimOrphanedDownloadScopes` can never disagree with the per-directory
        // answer — which would be a sweep that walked `accounts/` and deleted something
        // the gate had already refused.
        for (known, current) in [(Set([scope]), scope), (Set<String>(), placeholder)] {
            let gate = DownloadManager.canRunOrphanScopeSweep(
                knownScopeKeys: known, currentScopeKey: current)
            let perDirectory = DownloadManager.shouldReclaimScopeDirectory(
                "scope-gone", knownScopeKeys: known, currentScopeKey: current)
            XCTAssertEqual(gate, perDirectory,
                           "known: \(known), current: \(current)")
        }
    }
}
