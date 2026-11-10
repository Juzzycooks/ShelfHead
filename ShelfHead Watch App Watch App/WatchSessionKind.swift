import Foundation

/// What kind of server session this Watch is holding — the Watch's copy of the
/// phone's `WatchHandoffSessionKind` (`ShelfHead/Services/WatchSessionManager.swift`).
///
/// **The raw strings are the WatchConnectivity wire contract** for the handoff
/// reply's additive `sessionKind` key. They're duplicated rather than shared for the
/// same reason the Watch used to duplicate the phone's URL rules (now shared as `ServerURLRules`): the phone-side file
/// imports `UIKit` and the whole phone service graph, and the two targets compile
/// with different `SWIFT_DEFAULT_ACTOR_ISOLATION` defaults. Change them in both
/// places or not at all.
///
/// Added 10 September 2026 (item 10 — "shared rotating refresh token between phone
/// and Watch"). Before it, every handoff gave the Watch the phone's own access *and*
/// refresh token; because Audiobookshelf's refresh tokens rotate and are single-use,
/// whichever device refreshed first silently invalidated the other. The phone
/// recovered by re-logging in with the stored password; the Watch, which deliberately
/// never receives the password, just died with "Your session has expired." Knowing
/// *which kind* of credential this Watch holds is what lets it tell the three cases
/// apart: renew on its own, keep working forever, or ask the phone for a new one.
///
/// **Explicitly `nonisolated`.** The Watch target's default isolation is `MainActor`,
/// so an unannotated enum here would pick that up and couldn't be used from the
/// `nonisolated static` pure decision functions on `WatchStore` (or from their tests)
/// — the trap `HANDOFF.md`'s "Gotchas learned today" describes for every type shared
/// across the isolation boundary.
nonisolated enum WatchSessionKind: String, Equatable, Sendable, CaseIterable {
    /// A second, independent server session minted for this Watch alone (the phone
    /// performed a fresh `POST /login` and handed over *that* session's pair), or one
    /// this Watch created itself by signing in manually. It has its own rotating
    /// refresh token, so this Watch renews without the phone and without disturbing
    /// the phone's chain.
    case dedicated
    /// A credential that neither rotates nor expires — Audiobookshelf's legacy
    /// permanent `User.token`. Not exclusive to this Watch, but nothing either device
    /// does can invalidate it, so it needs no refresh token and no reconnect warning.
    case durable
    /// The phone's current access token, handed over **without** its refresh token so
    /// this Watch can never break the phone's rotation chain. Works until that access
    /// token expires (roughly hourly), after which this Watch must ask the phone for a
    /// fresh handoff.
    case shared

    /// True when this credential keeps working without the phone: either it renews
    /// itself (`.dedicated`) or it never needs renewing (`.durable`).
    ///
    /// This is the property that matters for both Watch-side decisions: whether an
    /// incoming access-token-only handoff is allowed to replace what's already here
    /// (`WatchStore.applyHandoff(existing:incoming:)`), and whether the user needs to
    /// be told anything about bringing their iPhone nearby.
    var survivesWithoutThePhone: Bool { self != .shared }

    /// True only for a session no other device is using, which is the precondition for
    /// closing it server-side (`POST /logout`) when this Watch signs out. A `.durable`
    /// token is the *user's* permanent token — the phone is very likely authenticating
    /// with the same string — so logging it out is never attempted.
    var ownedExclusivelyByThisWatch: Bool { self == .dedicated }
}

/// Where the current session's kind is remembered across launches.
///
/// `UserDefaults`, not the Keychain, deliberately: this is a one-word classification
/// of a credential, not a credential — it reveals nothing an attacker with the
/// Keychain contents wouldn't already have, and `KeychainService`'s key list is fixed
/// and shared with the phone target. It's written next to every credential write in
/// `WatchAudiobookshelfAPI` so the two can't drift, and cleared by `wipeCredentials()`.
///
/// A missing value means "a session stored by a build that predates this" — treated
/// as `.shared` at the one read site that has to decide, which is the conservative
/// answer (it never claims durability this Watch might not have).
nonisolated enum WatchSessionKindStore {
    static let defaultsKey = "watchStore.sessionKind"

    static var current: WatchSessionKind? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return WatchSessionKind(rawValue: raw)
    }

    static func set(_ kind: WatchSessionKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
