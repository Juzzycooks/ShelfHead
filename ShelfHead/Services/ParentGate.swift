import Foundation
import LocalAuthentication

/// Batch 457: the parent's check before a child's session can reach Settings or an adult account. Device owner
/// authentication (Face ID, Touch ID or the passcode), the same policy `AppLockManager` uses.
enum ParentGate {
    /// True when the parent passed. Review Medium 38 (30 October 2026): this used to return true whenever
    /// `canEvaluatePolicy` failed for ANY reason, so a transient or unexpected LocalAuthentication error let a
    /// child through. Now it passes only on `LAError.passcodeNotSet` (a device with no passcode has nothing to
    /// check against; `AppLockManager.authenticate()` documents the same fallback) and fails closed otherwise.
    /// Product note: on a device with no passcode the gate cannot protect anything.
    @MainActor
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return passesWhenUnavailable(errorCode: error?.code)
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Pure: whether the gate passes when the device-owner policy can't be evaluated. Only "no passcode set".
    nonisolated static func passesWhenUnavailable(errorCode: Int?) -> Bool {
        errorCode == LAError.passcodeNotSet.rawValue
    }

    /// Pure: a gate is needed to open Settings while a child's account is active.
    nonisolated static func settingsNeedGate(activeAccountId: String?, store: KidProfileStore = .standard) -> Bool {
        store.isKid(activeAccountId)
    }

    /// Pure: Review 3 High 2. After an account switch, a child's account can't stay on the Settings tab (3); it
    /// goes to Home.
    nonisolated static func tabAfterAccountChange(current: Int, activeAccountId: String?,
                                                  store: KidProfileStore = .standard) -> Int {
        current == 3 && settingsNeedGate(activeAccountId: activeAccountId, store: store) ? 0 : current
    }

    /// Pure: a gate is needed to switch to `targetAccountId` when any child account is saved and the target is an
    /// adult one, so a child can't walk out of the picker into a parent's library.
    nonisolated static func switchNeedsGate(to targetAccountId: String, store: KidProfileStore = .standard) -> Bool {
        store.hasAnyKid && !store.isKid(targetAccountId)
    }

    /// Pure: Review 2 High 1 (30 October 2026). The profile picker asks for any grown-up tile whenever a child
    /// profile is saved, including the already-active account (same as `switchNeedsGate(to:)`).
    nonisolated static func pickerNeedsGate(target targetAccountId: String, store: KidProfileStore = .standard) -> Bool {
        switchNeedsGate(to: targetAccountId, store: store)
    }

    /// Pure: Batch 497 (REVIEW 2026-11-11 N5). The gate for one tap on a picker tile. A child tile, or no child
    /// profile saved: never. Home's picker (`openedInSession`) tapping the account already signed in: never, since
    /// the person is already in that account and nothing changes. Every other grown-up tile: always. The launch
    /// picker keeps gating the active grown-up tile (Review 2 High 1): there the restored session wasn't chosen
    /// by whoever is holding the phone, so that tap is what grants access.
    nonisolated static func pickerTapNeedsGate(currentAccountId: String?, tappedAccountId: String,
                                               tappedIsKid: Bool, anyKidSaved: Bool, openedInSession: Bool) -> Bool {
        guard anyKidSaved, !tappedIsKid else { return false }
        if openedInSession, let currentAccountId, currentAccountId == tappedAccountId { return false }
        return true
    }

    /// Pure: the gate for `AuthViewModel.switchAccount`, which every route (picker, Other Servers, Add Server,
    /// insecure-connection retry) goes through. Needed when the active account is a child's and the target is an
    /// adult one. With no active account (signed out) it falls back to `switchNeedsGate(to:)`, so a child can't use
    /// the sign-in screen's saved servers to reach a parent's library. Adult to anything, same account, and
    /// kid to kid never prompt.
    nonisolated static func switchNeedsGate(from activeAccountId: String?, to targetAccountId: String,
                                            store: KidProfileStore = .standard) -> Bool {
        guard let activeAccountId else { return switchNeedsGate(to: targetAccountId, store: store) }
        return activeAccountId != targetAccountId && store.isKid(activeAccountId) && !store.isKid(targetAccountId)
    }
}

/// Batch 457: what to do to the listening profile after an account switch (and at launch).
enum KidProfileCoordinator {
    /// Pure decision: the profile to activate, or nil to leave it alone.
    nonisolated static func profileAfterSwitch(to accountId: String?, current: ListeningProfile,
                                               store: KidProfileStore = .standard) -> ListeningProfile? {
        if let kid = store.profile(for: accountId) {
            return kid.usesBedtimeStory && current != .bedtimeStory ? .bedtimeStory : nil
        }
        // Left a child's account: don't leave their profile active on a parent's.
        return current == .bedtimeStory ? .off : nil
    }

    /// Call after a successful `switchAccount` and once at launch with `AccountStore.currentAccountId`.
    @MainActor
    static func applyProfile(forAccountId accountId: String?) {
        let manager = ListeningProfileManager.shared
        if let next = profileAfterSwitch(to: accountId, current: manager.activeProfile) {
            manager.activate(next)
        }
    }
}
