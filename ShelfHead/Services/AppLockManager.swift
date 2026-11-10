import Foundation
import LocalAuthentication
import Observation

/// S1 (REVIEW_2026-08-20_UI_SECURITY.md): a deep link, Handoff/Spotlight continuation, or
/// already-resolved book open that arrived while the app was locked. Queuing it here (see
/// `AppLockManager.pendingAction`) instead of executing it immediately is what closes the
/// App Lock bypass — previously `handleDeepLink`, both `onContinueUserActivity` handlers,
/// and the `deepLinkedItem` sheet in `ContentView.swift` never checked `isLocked` at all,
/// so a Spotlight tap or `shelfhead://` link could present a book's detail sheet over the
/// lock overlay or start playback while the app was supposed to be locked.
///
/// This type only carries data — `MainTabView` (`ContentView.swift`) is what actually
/// replays a queued action, via `.onChange(of: appLock.isLocked)` firing when
/// `authenticate()` below flips it back to `false`. `AppLockManager` is a plain service
/// singleton with no reference to the view-owned state (`deepLinkedItem`, `selectedTab`,
/// `playerViewModel`) a replay needs, so the actual dispatch has to live where that state
/// does; this enum is just the mailbox between the two.
///
/// **Deliberately NOT covered by this queue**, by explicit product decision recorded in
/// S1's "Fix direction" — a future reviewer should treat these as intentional, not
/// re-report them:
/// - CarPlay (`CarPlayCoordinator.swift`) — system media controls are OS-owned, and
///   Apple's own guidance discourages biometric gates while driving.
/// - Lock-screen transport controls (`MPRemoteCommandCenter` in `AudioPlayerService.swift`)
///   — same reasoning, an OS-owned surface.
/// - App Intents / Siri (`PlaybackIntents.swift`) — "Hey Siri, resume" is expected to work
///   regardless of app-lock state, consistent with how Siri interacts with other locked
///   apps' media.
/// - The Watch app (`WatchConnectivityStore.swift`) and the Home Screen widget
///   (`ShelfHeadWidgets/`) — left exactly as they behave today.
/// - Spotlight's own indexing (`SpotlightIndexer.swift`) — this queue covers *opening* a
///   Spotlight result, not whether title/author/narrator/series get indexed in the first
///   place; stripping the index when lock is enabled is a bigger, more disruptive product
///   change than this pass makes unilaterally.
enum PendingUnlockAction {
    /// A `shelfhead://…` URL that arrived via `.onOpenURL`.
    case deepLink(URL)
    /// A Handoff (`AudioPlayerService.playbackActivityType`) or Spotlight
    /// (`CSSearchableItemActionType`) continuation from `.onContinueUserActivity`. Carries
    /// the raw activity so replay can re-dispatch on `activityType` exactly like the two
    /// live handlers in `ContentView.swift` do.
    case continueUserActivity(NSUserActivity)
    /// A book already fetched from the server, about to be opened — either started
    /// playing (`playAt` non-nil, the Handoff path) or shown in the `deepLinkedItem`
    /// detail sheet (`playAt == nil`). Carries the already-resolved `LibraryItem` rather
    /// than just an id so replay doesn't re-fetch it after the user unlocks.
    case openBookItem(item: LibraryItem, playAt: Double?)
}

/// Optional Face ID/Touch ID/passcode gate, shown over the whole app on return to the
/// foreground when `SettingsStore.appLockEnabled` is on (Settings > Account & Security).
/// `ContentView` owns wiring this to `scenePhase`: it calls `lockIfNeeded()` on going to
/// `.background` and presents `AppLockView` (which calls `authenticate()`) while
/// `isLocked` is true.
// CRIT-3 step 2 (REVIEW_2026-08-12.md): de-facto main-actor state (read/written
// exclusively from SwiftUI views). Making this class `@MainActor` also fixes the
// isolation inconsistency the review flagged in `authenticate()` below — see the
// comment there.
//
// Real build errors, corrected after two wrong rounds — see `FavoritesStore.swift`/
// `ThemeStore.swift` for the full account: `@Observable` transforms every `var`
// property into a main-actor-isolated computed accessor, so a `nonisolated init()`
// can never assign one, regardless of in-line defaults. Since every real caller of
// `.shared` here is already main-actor (SwiftUI views), the fix is to not mark
// `shared`/`init()` `nonisolated` at all.
@MainActor
@Observable
final class AppLockManager {
    static let shared = AppLockManager()

    /// True while content should stay hidden behind the lock screen.
    var isLocked = false

    /// SEC-3: true once we've discovered the device has no passcode/Face ID/Touch ID
    /// enrolled at all — meaning App Lock, if turned on, silently protects nothing
    /// (`authenticate()` below opens right back up since there's nothing to gate
    /// behind). Settings reads this to show an explicit warning next to the toggle
    /// instead of letting it look like it's doing something it isn't.
    var deviceHasNoProtection: Bool = false

    /// HIG audit 2026-09-17 M11: which biometry (if any) this device actually has, so
    /// `AppLockView` can show the matching glyph/copy instead of hardcoding Face ID.
    /// `LAContext.biometryType` only reports a real value once `canEvaluatePolicy` has
    /// been called on that same context — reading it off a bare, never-evaluated
    /// `LAContext()` always returns `.none` — so this is refreshed alongside
    /// `deviceHasNoProtection`, from the same evaluated context, rather than read fresh
    /// on demand.
    var biometryType: LABiometryType = .none

    /// AX-12 (docs/design-review.md, follow-up): single source of truth for the SF
    /// Symbol matching `biometryType`, so `AppLockView`'s big glyph and its Unlock
    /// button can't disagree about how the app unlocks (previously the view hardcoded
    /// its own switch for the glyph only, while the button title used a second, separate
    /// switch). `.opticid`'s availability is confirmed from iOS 17.0 — below this app's
    /// 17.6 floor — via `scripts/appledoc.sh
    /// https://developer.apple.com/documentation/localauthentication/labiometrytype/opticid`.
    /// `.faceid` (iOS 13.0), `.touchid` (iOS 14.0) and `.lock.fill` (iOS 13.0) are all
    /// confirmed available as SF Symbols via `name_availability.plist`
    /// (`plutil -convert json -o -
    /// /System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/
    /// CoreGlyphs.bundle/Contents/Resources/name_availability.plist`, per CLAUDE.md's
    /// documented technique). `.none` (no biometrics enrolled — passcode-only fallback,
    /// see `authenticate()` below) and any future case this switch doesn't know about
    /// yet both default to the passcode glyph rather than lying about which biometry
    /// is in use.
    var biometrySymbolName: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    /// AX-12: paired with `biometrySymbolName` so the Unlock button's title, its glyph
    /// and the lock screen's big glyph all read from the same switch and can't drift
    /// from one another.
    var biometryDisplayName: String {
        switch biometryType {
        case .faceID: return String(localized: "Face ID", comment: "Biometry name")
        case .touchID: return String(localized: "Touch ID", comment: "Biometry name")
        case .opticID: return String(localized: "Optic ID", comment: "Biometry name")
        default: return String(localized: "Passcode", comment: "Device passcode as the unlock method")
        }
    }

    /// AX-13: whether any biometry is enrolled, from the same switch as the two helpers
    /// above, so wording that differs for passcode-only devices doesn't have to compare
    /// display strings.
    var hasBiometrics: Bool {
        switch biometryType {
        case .faceID, .touchID, .opticID: return true
        default: return false
        }
    }

    /// S1 (REVIEW_2026-08-20_UI_SECURITY.md): a deep link / Handoff / Spotlight / book-open
    /// action that arrived while `isLocked` was true, queued instead of dropped. Set by
    /// `MainTabView`'s gated call sites in `ContentView.swift`; consumed by the same view's
    /// `.onChange(of: appLock.isLocked)`, which fires the moment `authenticate()` below
    /// flips this back to `false`. See `PendingUnlockAction`'s doc comment for what is and
    /// isn't covered by this queue.
    var pendingAction: PendingUnlockAction?

    // Inlines `refreshDeviceProtectionStatus()`'s body directly rather than calling it,
    // just to keep `init()` self-contained — now that `init()` is plain `@MainActor`
    // (not `nonisolated`), calling that method from here would actually be fine too.
    private init() {
        var error: NSError?
        let context = LAContext()
        deviceHasNoProtection = !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        // HIG audit 2026-09-17 M11: same evaluated context, so `biometryType` reflects
        // the just-run `canEvaluatePolicy` call above rather than a stale/default value.
        biometryType = context.biometryType
    }

    /// Checks (without prompting — `canEvaluatePolicy` never shows system UI) whether
    /// the device currently has any device-owner authentication enrolled, updating
    /// `deviceHasNoProtection`. Safe to call anytime, e.g. when the Account & Security
    /// settings page appears, since enrollment can change while the app is open.
    func refreshDeviceProtectionStatus() {
        var error: NSError?
        let context = LAContext()
        deviceHasNoProtection = !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        // HIG audit 2026-09-17 M11: refreshed alongside `deviceHasNoProtection` — see
        // `biometryType`'s doc comment for why it can't just be read off a fresh context.
        biometryType = context.biometryType
    }

    /// Called when the app leaves the foreground. Locking on `.background` (not
    /// `.inactive`, which also fires for a momentary interruption like the system
    /// volume HUD or a permission prompt) avoids flashing the lock screen for
    /// something that isn't really "the app left."
    func lockIfNeeded() {
        guard SettingsStore.appLockEnabled else { return }
        isLocked = true
    }

    /// Prompts Face ID/Touch ID, falling back to the device passcode
    /// (`.deviceOwnerAuthentication`, not `.deviceOwnerAuthenticationWithBiometrics`) —
    /// a passcode-only fallback means someone who hasn't enrolled Face ID, or whose
    /// biometrics momentarily fail, still has a way back into their own downloaded
    /// audiobooks instead of being locked out entirely. Returns `true` (and clears
    /// `isLocked`) if the device has no biometrics/passcode configured at all, since
    /// there's nothing to actually gate behind in that case.
    @discardableResult
    func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            deviceHasNoProtection = true
            // S1: this `isLocked = false` (and the one below on a successful prompt) is
            // what `MainTabView`'s `.onChange(of: appLock.isLocked)` watches for to replay
            // `pendingAction`, if one was queued while locked — see `PendingUnlockAction`.
            isLocked = false
            return true
        }
        // `LAContext.evaluatePolicy` is completion-handler-based (no native async/await
        // overload in LocalAuthentication) and calls back on an arbitrary queue, not
        // necessarily the main thread — bridge it explicitly with `withCheckedContinuation`.
        // Resuming the continuation from that arbitrary queue is fine in itself (it just
        // resumes the suspended `async` call); it's the code *after* the `await` below
        // that needs to be back on the main actor before touching `isLocked`, which it is,
        // since `authenticate()` is `@MainActor`-isolated as a method of this class.
        let success: Bool = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock ShelfHead", comment: "Reason shown in the system Face ID / Touch ID prompt")) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        // `authenticate()` is itself main-actor-isolated now that the class is
        // `@MainActor` (it's still `async` because of the `withCheckedContinuation`
        // bridge above, not because of this assignment), so a direct assignment here is
        // already back on the main actor — the explicit `MainActor.run` hop the review
        // flagged as inconsistent is no longer needed.
        if success {
            isLocked = false
        }
        return success
    }
}
