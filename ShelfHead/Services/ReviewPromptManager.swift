import SwiftUI
import StoreKit

/// Decides when to fire the system's native "Rate ShelfHead" prompt
/// (`RequestReviewAction`, i.e. `AppStore.requestReview`/`SKStoreReviewController`) and
/// builds the App Store review-write URL for the "Rate ShelfHead" row in Settings >
/// About.
///
/// ASO pass (`ShelfHead/AppStore/AppStoreListing.md`, 14 Sep 2026): "after finishing a
/// book or a 7-day streak; never at launch/onboarding/errors". This class owns *when
/// it's eligible* (pure, unit-tested `decision(...)`); `ReviewPromptRequester` below
/// owns *actually calling StoreKit*, since only a view has the `requestReview`
/// environment action and can check the app is actually in the foreground and unlocked.
///
/// State lives in its own `review_*` `UserDefaults.standard` keys, deliberately not
/// folded into `SettingsStore` — this is prompt-eligibility bookkeeping (an install-age
/// clock and a cooldown timestamp), not a user-facing setting.
///
/// Privacy note: `requestReview`/`SKStoreReviewController` is not a "required reason"
/// API under Apple's privacy manifest rules (it doesn't touch disk timestamps, boot
/// time, active keyboard, file timestamps, or system boot time APIs), so nothing needs
/// to change in `PrivacyInfo.xcprivacy` for this feature.
@Observable
@MainActor
final class ReviewPromptManager {
    static let shared = ReviewPromptManager()

    private enum Keys {
        static let booksFinished = "review_booksFinishedSinceInstall"
        static let lastPromptedAt = "review_lastPromptedAt"
        static let firstSeenAt = "review_firstSeenAt"
    }

    /// Flipped to `true` the instant a trigger becomes eligible. `ReviewPromptRequester`
    /// (installed once at the app root, in `ContentView.swift`) observes this, waits for
    /// a safe moment, and actually invokes StoreKit. Not persisted — it only matters
    /// within the current process launch; if the app is killed before the requester
    /// acts on it, the next eligible trigger will set it again.
    var promptRequested = false

    private let defaults: UserDefaults

    private(set) var booksFinishedSinceInstall: Int {
        didSet { defaults.set(booksFinishedSinceInstall, forKey: Keys.booksFinished) }
    }

    private(set) var lastPromptedAt: Date? {
        didSet { defaults.set(lastPromptedAt, forKey: Keys.lastPromptedAt) }
    }

    /// Set exactly once — the first time this manager is ever constructed on a given
    /// install — and persisted from then on. Anchors the "never within 3 days of
    /// install" rule in `decision(...)` so a brand-new install can't be prompted on its
    /// first session.
    let firstSeenAt: Date

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.booksFinishedSinceInstall = defaults.integer(forKey: Keys.booksFinished)
        self.lastPromptedAt = defaults.object(forKey: Keys.lastPromptedAt) as? Date
        if let existing = defaults.object(forKey: Keys.firstSeenAt) as? Date {
            self.firstSeenAt = existing
        } else {
            let now = Date()
            self.firstSeenAt = now
            defaults.set(now, forKey: Keys.firstSeenAt)
        }
    }

    /// The two moments the ASO pass names as "good moments" to ask.
    enum Trigger {
        case bookFinished
        case streak
    }

    /// Pure eligibility rule — no I/O, no singletons — so every branch (each rule, each
    /// boundary) can be pinned with a unit test rather than exercised indirectly through
    /// `UserDefaults` state. Rules, all of which must hold:
    ///   - never within 3 days of `firstSeenAt` (don't ask on a fresh install);
    ///   - never within 120 days of a previous `lastPromptedAt` (Apple's own
    ///     `SKStoreReviewController` throttle is looser than this, but a much longer
    ///     cooldown keeps the ask rare and meaningful);
    ///   - `.bookFinished` requires `booksFinished >= 1` (the count passed in is
    ///     expected to already include the book that just finished);
    ///   - `.streak` requires `streakDays >= 7`.
    nonisolated static func decision(
        trigger: Trigger,
        booksFinished: Int,
        streakDays: Int,
        lastPromptedAt: Date?,
        firstSeenAt: Date,
        now: Date
    ) -> Bool {
        let minInstallAge: TimeInterval = 3 * 24 * 60 * 60
        guard now.timeIntervalSince(firstSeenAt) >= minInstallAge else { return false }

        if let lastPromptedAt {
            let cooldown: TimeInterval = 120 * 24 * 60 * 60
            guard now.timeIntervalSince(lastPromptedAt) >= cooldown else { return false }
        }

        switch trigger {
        case .bookFinished:
            return booksFinished >= 1
        case .streak:
            return streakDays >= 7
        }
    }

    /// Called from `PlayerViewModel`'s `onPlaybackFinished` hook, once per book
    /// completed. Increments the lifetime finished-book count first, so the count
    /// `decision(...)` sees includes this one.
    func noteBookFinished() {
        booksFinishedSinceInstall += 1
        if Self.decision(
            trigger: .bookFinished,
            booksFinished: booksFinishedSinceInstall,
            streakDays: 0,
            lastPromptedAt: lastPromptedAt,
            firstSeenAt: firstSeenAt,
            now: Date()
        ) {
            promptRequested = true
        }
    }

    /// Called from `LibraryViewModel`, each time the listening streak is refreshed.
    func noteStreak(days: Int) {
        if Self.decision(
            trigger: .streak,
            booksFinished: booksFinishedSinceInstall,
            streakDays: days,
            lastPromptedAt: lastPromptedAt,
            firstSeenAt: firstSeenAt,
            now: Date()
        ) {
            promptRequested = true
        }
    }

    /// Called by `ReviewPromptRequester` at the exact moment it actually invokes
    /// StoreKit's `requestReview` action — this is what starts the 120-day cooldown, not
    /// the moment `promptRequested` flipped `true` (which may have been seconds earlier,
    /// or dropped entirely if the app wasn't in a safe state to ask).
    func markPrompted() {
        lastPromptedAt = Date()
    }

    // MARK: - Rate ShelfHead (Settings > About)

    /// The numeric App Store Connect ID for ShelfHead — the digits in
    /// `https://apps.apple.com/app/id<ID>`. Supplied by the user from the App Store
    /// Connect record on 15 September 2026 (Batch 324). The "Rate ShelfHead" row in
    /// Settings > About renders whenever `writeReviewURL` returns non-nil, so setting
    /// this back to `nil` is the one-line way to hide the row again.
    static let appStoreID: String? = "6780096463"

    /// Pure URL builder, kept separate from `appStoreID` so both the app and
    /// `ReviewPromptTests` can exercise it without needing a real ID. Returns `nil`
    /// (rather than a URL that 404s on the App Store) whenever `appStoreID` is unset or
    /// empty, so a placeholder value can never ship a dead link.
    static func writeReviewURL(appStoreID: String?) -> URL? {
        guard let appStoreID, !appStoreID.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }
}

/// Installed once at the app root (`MainTabView` in `ContentView.swift`, alongside
/// `.environment(tabRouter)`) so the rest of the app never has to think about *how* the
/// review prompt actually fires — view models just call `noteBookFinished()`/
/// `noteStreak(days:)` on `ReviewPromptManager.shared` and this modifier does the rest.
///
/// Deliberately waits ~2s after `promptRequested` flips `true` before doing anything:
/// firing StoreKit's prompt in the same instant as the end-of-book UI (Up Next
/// auto-advance, the "up next" sheet) would collide with it. After the wait it
/// re-checks that the scene is foregrounded and App Lock isn't covering the screen —
/// if either check fails, it drops this attempt silently rather than queuing it; the
/// next eligible trigger (there's always another book, another streak) will try again.
private struct ReviewPromptRequester: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var manager = ReviewPromptManager.shared
    /// Mirrors `scenePhase` into `@State`. `@Environment` is snapshotted into the
    /// `ViewModifier` struct instance that existed when `onChange` fired; the `Task`
    /// below captures that (by-then-stale) copy of `self`, so reading `scenePhase`
    /// directly after the `sleep` would silently reuse the phase from ~2s ago instead of
    /// the current one. `@State` is reference-backed by identity, so reading it through
    /// the same captured `self` still returns the live value.
    @State private var isSceneActive = true

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                isSceneActive = (phase == .active)
            }
            .onChange(of: manager.promptRequested) { _, requested in
                guard requested else { return }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard isSceneActive, !AppLockManager.shared.isLocked else {
                        manager.promptRequested = false
                        return
                    }
                    requestReview()
                    manager.markPrompted()
                    manager.promptRequested = false
                }
            }
    }
}

extension View {
    /// One-line hook for the app root — see `ReviewPromptRequester`.
    func reviewPromptRequester() -> some View {
        modifier(ReviewPromptRequester())
    }
}
