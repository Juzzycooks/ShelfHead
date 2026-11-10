import Foundation
import Observation

/// A named bundle of playback-related settings that can be applied in one tap —
/// switching context (about to drive, about to fall asleep, listening while working)
/// without hunting through several separate Settings toggles each time.
///
/// This is a manual, in-app switcher rather than a true iOS Focus Filter — a real
/// Focus Filter (the thing that lets iOS itself flip a setting automatically when you
/// enter a system Focus like Driving or Sleep) requires declaring a
/// `SetFocusFilterIntent`-conforming App Intent and enabling it in the app's Xcode
/// target capabilities; that's a project-configuration step this static-review-only
/// pass can't safely make blind (no Xcode/compiler available to verify the intent
/// registers correctly). The manual switcher here is fully functional standalone and
/// gives the same practical benefit — it's just triggered from Settings/Now Playing
/// instead of automatically by the system Focus.
enum ListeningProfile: String, CaseIterable, Identifiable, Codable {
    case off
    case driving
    case sleep
    case work
    /// Batch 457: the kid accounts' profile. Opt-in per child (`KidProfile.usesBedtimeStory`).
    case bedtimeStory

    var id: String { rawValue }

    var label: String {
        switch self {
        // T2 (REVIEW_2026-09-04_UI.md): renamed from "Driving" — it shared a name and
        // icon with the unrelated big-button "Driving Mode" player UI, which sent
        // Settings search for "driving" to the wrong destination. The `case driving`
        // rawValue is unchanged since it's persisted.
        case .off:     return String(localized: "Off", comment: "Listening profile name: no profile active")
        case .driving: return String(localized: "Commute", comment: "Listening profile name")
        case .sleep:   return String(localized: "Sleep", comment: "Listening profile name")
        case .work:    return String(localized: "Work", comment: "Listening profile name")
        case .bedtimeStory: return String(localized: "Bedtime Story", comment: "Listening profile name, for a child's account")
        }
    }

    var icon: String {
        switch self {
        case .off:     return "slider.horizontal.3"
        case .driving: return "car.side.fill"
        case .sleep:   return "moon.stars.fill"
        case .work:    return "briefcase.fill"
        case .bedtimeStory: return "book.closed.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .off:     return String(localized: "Your normal settings, unchanged")
        case .driving: return String(localized: "For the road: 1\u{00d7} speed, boosted volume for road noise, screen stays awake")
        case .sleep:   return String(localized: "0.75\u{00d7} speed, a \(SettingsStore.scheduledSleepTimerDurationMinutes)-minute sleep timer with fade-out, screen can sleep", comment: "Listening profile description. %lld is minutes")
        case .work:    return String(localized: "1.25\u{00d7} speed, quieter haptics, Wi-Fi-only downloads")
        case .bedtimeStory: return String(localized: "1\u{00d7} speed, stops at the end of the chapter, no automatic next book", comment: "Listening profile description for a child's account")
        }
    }

    /// The overrides this profile applies. `nil` in a field means "leave whatever it
    /// currently is" — `.off` has every field nil since deactivating just restores the
    /// snapshot `ListeningProfileManager` took before the first profile was applied.
    struct Overrides: Codable, Equatable {
        var playbackSpeed: Double?
        var volumeBoostDB: Double?
        var keepScreenAwake: Bool?
        var chapterHaptics: Bool?
        var wifiOnlyDownloads: Bool?
        var sleepFadeOut: Bool?
        /// Start a countdown sleep timer of the bedtime-window length when the profile is
        /// turned on (critique 2026-10-05, user decision). Not a setting, so it isn't part
        /// of the baseline; `ListeningProfileManager` cancels only a timer it started.
        var armsSleepTimer: Bool?
        /// Batch 439: ambient bed mixed under the narration, and its level (0...1). Optional so
        /// stored or hand-written JSON without them still decodes.
        var ambientBed: AmbientBed?
        var ambientLevel: Double?
        /// Batch 457: stop at the end of the current chapter when the profile is turned on.
        var armsEndOfChapterTimer: Bool?
        /// Batch 457: whether the next queued book plays by itself, and whether a series
        /// continues into its next book. Only ever set to false by a profile.
        var autoplayNext: Bool?
        var autoContinueSeries: Bool?
    }

    var overrides: Overrides {
        switch self {
        case .off:
            return Overrides()
        case .driving:
            // 1.0x (not sped up — safer to follow while attention is split), a real
            // volume lift for road/engine noise, and the screen kept awake so a glance
            // at the lock screen for Now Playing controls doesn't need an unlock first.
            return Overrides(playbackSpeed: 1.0, volumeBoostDB: 6, keepScreenAwake: true, chapterHaptics: true)
        case .sleep:
            // Slower and gentler, with the existing fade-out-before-sleep-timer-ends
            // setting turned on; screen doesn't need to stay awake in bed. No ambient bed: nothing
            // plays in the background unless the listener picks it themselves.
            return Overrides(playbackSpeed: 0.75, keepScreenAwake: false, sleepFadeOut: true, armsSleepTimer: true)
        case .work:
            // Faster for efficient half-attention listening, quieter (no chapter
            // haptics buzzing during a meeting), and Wi-Fi-only downloads so background
            // downloads don't eat a work network's data plan.
            return Overrides(playbackSpeed: 1.25, chapterHaptics: false, wifiOnlyDownloads: true)
        case .bedtimeStory:
            // Batch 457: one story, then quiet. Normal speed, no boost, end-of-chapter timer, nothing
            // that plays on by itself, and no ambient bed (nothing starts sound the listener didn't pick).
            return Overrides(playbackSpeed: 1.0, volumeBoostDB: 0, keepScreenAwake: false, sleepFadeOut: true,
                             armsEndOfChapterTimer: true, autoplayNext: false, autoContinueSeries: false)
        }
    }
}

/// P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half): whether CarPlay should
/// silently switch to the Driving profile on connect. Owned here (a UserDefaults key
/// alongside `activeKey`/`baselineKey`) rather than in `SettingsKeys`/`SettingsStore`
/// — those belong to a different file this pass doesn't touch —
/// `CarPlayCoordinator` reads/writes it via `ListeningProfileManager.shared` but the
/// answer itself, and the one-time nature of the prompt, live here so any other
/// surface (a future Watch/CarPlay-adjacent feature) can consult the same answer.
enum CarPlayAutoDrivingPreference: String {
    /// Never asked yet — `CarPlayCoordinator` should present its one-time
    /// `CPAlertTemplate` prompt on the next connect.
    case notAsked
    /// Driver answered "Always" — auto-apply Driving on every future CarPlay
    /// connect, no prompt.
    case always
    /// Driver answered "Not now" — the prompt is only ever shown once (see its call
    /// site's doc comment), so this means "don't auto-apply, and don't ask again."
    case declined
}

/// Where a profile activation came from — distinguishes a deliberate pick (Settings'
/// `PlaybackSettingsSection`, `PlayerView`'s "…" menu picker, or `CarPlayCoordinator`'s
/// own CarPlay Setup "Listening Profile" row — all of which call `activate(_:)` with
/// the default `.user` origin) from `CarPlayCoordinator`'s own silent bookkeeping
/// (auto-applying Driving on CarPlay connect, or restoring the pre-connect profile on
/// disconnect — both pass `origin: .carPlay` explicitly).
///
/// Restore-semantics fix (follow-up to P-14, REVIEW_2026-09-14_DESIGN.md — CarPlay
/// half): `CarPlayCoordinator.restoreProfileAfterCarPlayIfNeeded()` reads
/// `lastActivationOrigin` to tell whether the driver (or any other surface) changed
/// profiles after CarPlay's auto-switch, so a deliberate manual choice isn't reverted
/// out from under them on disconnect. See
/// `CarPlayCoordinator.profileToRestoreOnDisconnect(preConnect:autoApplied:activeNow:
/// userChangedSinceAutoApply:)` for the full decision table.
enum ActivationOrigin {
    /// A real pick — Settings, the player menu, or the CarPlay Setup row's own
    /// profile picker. The default for `activate(_:)` so every pre-existing call site
    /// keeps this meaning without being touched.
    case user
    /// `CarPlayCoordinator` changing the profile on the driver's behalf as part of its
    /// own connect/disconnect bookkeeping, not a deliberate pick.
    case carPlay
}

/// Applies/reverts a `ListeningProfile`'s overrides against `SettingsStore`, snapshotting
/// the user's real settings the first time any profile is activated so switching back to
/// `.off` restores them exactly — see `ListeningProfile`'s doc comment for the Focus
/// Filter framing.
@Observable
final class ListeningProfileManager {
    static let shared = ListeningProfileManager()

    private static let activeKey = "settings_activeListeningProfile"
    private static let baselineKey = "settings_listeningProfileBaseline"
    private static let carPlayAutoDrivingKey = "settings_carPlayAutoDrivingPreference"

    private(set) var activeProfile: ListeningProfile
    /// P-14: see `CarPlayAutoDrivingPreference`'s doc comment. Read by
    /// `CarPlayCoordinator` on every connect; written only via
    /// `setCarPlayAutoDrivingPreference(_:)`, mirroring `activate(_:)`'s own
    /// direct-UserDefaults-write style rather than a property observer.
    private(set) var carPlayAutoDrivingPreference: CarPlayAutoDrivingPreference
    /// See `ActivationOrigin`'s doc comment. Starts `.user` — before any profile has
    /// been activated this process lifetime there is nothing CarPlay could have
    /// auto-switched, so treating "no activation yet" as "user" is the conservative
    /// default: it can never cause a spurious restore. Intentionally in-memory only
    /// (not persisted alongside `activeKey`) — it only needs to answer "has anything
    /// changed since CarPlay's last auto-switch THIS process lifetime", which is also
    /// the lifetime a `CarPlayCoordinator`/its `profileBeforeCarPlayAutoDriving` live for.
    private(set) var lastActivationOrigin: ActivationOrigin = .user

    private init() {
        activeProfile = ListeningProfile(rawValue: UserDefaults.standard.string(forKey: Self.activeKey) ?? "") ?? .off
        carPlayAutoDrivingPreference = CarPlayAutoDrivingPreference(
            rawValue: UserDefaults.standard.string(forKey: Self.carPlayAutoDrivingKey) ?? "") ?? .notAsked
    }

    /// Persists the driver's answer to CarPlay's one-time "switch to Driving?" prompt.
    /// See `CarPlayAutoDrivingPreference`'s doc comment for why this lives here rather
    /// than in `SettingsStore`.
    func setCarPlayAutoDrivingPreference(_ preference: CarPlayAutoDrivingPreference) {
        carPlayAutoDrivingPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: Self.carPlayAutoDrivingKey)
    }

    /// The six settings any profile can touch, captured as-is so they can be restored
    /// verbatim — deliberately not reusing `ListeningProfile.Overrides` (whose fields are
    /// all optional; a baseline needs every field to actually have a value to restore).
    private struct Baseline: Codable {
        var playbackSpeed: Double
        var volumeBoostDB: Double
        var keepScreenAwake: Bool
        var chapterHaptics: Bool
        var wifiOnlyDownloads: Bool
        var sleepFadeOut: Bool
        /// Batch 439: "" = no bed. Optional so baselines saved before this field still decode;
        /// nil on restore means leave the ambient settings alone.
        var ambientBed: String?
        var ambientLevel: Double?
        /// Batch 457: optional so older baselines still decode; nil on restore leaves them alone.
        var autoplayNext: Bool?
        var autoContinueSeries: Bool?
    }

    private func snapshotCurrentAsBaseline() {
        let baseline = Baseline(
            playbackSpeed: SettingsStore.defaultPlaybackSpeed,
            volumeBoostDB: SettingsStore.volumeBoostDB,
            keepScreenAwake: SettingsStore.keepScreenAwake,
            chapterHaptics: SettingsStore.chapterHapticsEnabled,
            wifiOnlyDownloads: SettingsStore.wifiOnlyDownloads,
            sleepFadeOut: SettingsStore.sleepFadeOut,
            ambientBed: SettingsStore.ambientBed?.rawValue ?? "",
            ambientLevel: SettingsStore.ambientLevel,
            autoplayNext: SettingsStore.autoplayNext,
            autoContinueSeries: SettingsStore.autoContinueSeries
        )
        guard let data = try? JSONEncoder().encode(baseline) else { return }
        UserDefaults.standard.set(data, forKey: Self.baselineKey)
    }

    /// Review 7 Medium 10: while a profile is active, the stored baseline is what the user's
    /// settings really are. Settings export uses these values for the keys a profile overrides.
    nonisolated static func exportBaselineValues(defaults: UserDefaults = .standard) -> [String: SettingsExportValue] {
        guard let raw = defaults.string(forKey: activeKey), raw != ListeningProfile.off.rawValue,
              let data = defaults.data(forKey: baselineKey),
              let b = try? JSONDecoder().decode(Baseline.self, from: data) else { return [:] }
        var out: [String: SettingsExportValue] = [
            SettingsKeys.defaultPlaybackSpeed: .double(b.playbackSpeed),
            SettingsKeys.volumeBoostDB: .double(b.volumeBoostDB),
            SettingsKeys.keepScreenAwake: .bool(b.keepScreenAwake),
            SettingsKeys.chapterHaptics: .bool(b.chapterHaptics),
            SettingsKeys.wifiOnlyDownloads: .bool(b.wifiOnlyDownloads),
            SettingsKeys.sleepFadeOut: .bool(b.sleepFadeOut),
        ]
        if let v = b.autoplayNext { out[SettingsKeys.autoplayNext] = .bool(v) }
        if let v = b.autoContinueSeries { out[SettingsKeys.autoContinueSeries] = .bool(v) }
        return out
    }

    private func storedBaseline() -> Baseline? {
        guard let data = UserDefaults.standard.data(forKey: Self.baselineKey),
              let baseline = try? JSONDecoder().decode(Baseline.self, from: data) else { return nil }
        return baseline
    }

    /// Switches to `profile`, applying its overrides (or restoring the pre-profile
    /// baseline for `.off`). The baseline is only captured once, on the transition
    /// *out of* `.off` — switching directly between two non-off profiles (Driving →
    /// Work) re-applies overrides atop that same original baseline, not atop whatever
    /// the previous profile left in place.
    ///
    /// `origin` defaults to `.user` so every pre-existing call site (Settings,
    /// `PlayerView`'s picker, and `CarPlayCoordinator.pushListeningProfilePicker()`)
    /// keeps compiling — and keeps meaning "a deliberate pick" — unchanged.
    /// `CarPlayCoordinator`'s own auto-apply/restore bookkeeping passes `.carPlay`
    /// explicitly; see `ActivationOrigin`'s doc comment.
    @MainActor
    func activate(_ profile: ListeningProfile, origin: ActivationOrigin = .user) {
        let wasOff = activeProfile == .off
        let previousProfile = activeProfile
        activeProfile = profile
        lastActivationOrigin = origin
        UserDefaults.standard.set(profile.rawValue, forKey: Self.activeKey)
        syncProfileSleepTimer(for: profile)

        if profile == .off {
            if let baseline = storedBaseline() {
                apply(baseline)
                // Review Medium 12: leaving the profile puts the loaded book back on its own
                // remembered speed (or the restored default).
                if let id = AudioPlayerService.shared.currentSession?.libraryItemId {
                    applyProfileSpeedToLoadedBook(SettingsStore.resolvedSpeed(forItem: id))
                }
            }
            return
        }
        if wasOff {
            snapshotCurrentAsBaseline()
        } else if let baseline = storedBaseline() {
            // Review 7 Medium 9: profile to profile starts from the user's own settings, so
            // Driving's +6 dB doesn't linger in Sleep. Settings only: the ambient bed is left
            // to the existing branch below, and the loaded book's speed is only touched when
            // the new profile doesn't set one (otherwise its own override does that).
            let defaults = UserDefaults.standard
            defaults.set(baseline.playbackSpeed, forKey: SettingsKeys.defaultPlaybackSpeed)
            SettingsStore.volumeBoostDB = baseline.volumeBoostDB
            defaults.set(baseline.keepScreenAwake, forKey: SettingsKeys.keepScreenAwake)
            defaults.set(baseline.chapterHaptics, forKey: SettingsKeys.chapterHaptics)
            defaults.set(baseline.wifiOnlyDownloads, forKey: SettingsKeys.wifiOnlyDownloads)
            defaults.set(baseline.sleepFadeOut, forKey: SettingsKeys.sleepFadeOut)
            if let v = baseline.autoplayNext { defaults.set(v, forKey: SettingsKeys.autoplayNext) }
            if let v = baseline.autoContinueSeries { defaults.set(v, forKey: SettingsKeys.autoContinueSeries) }
            if profile.overrides.playbackSpeed == nil,
               let id = AudioPlayerService.shared.currentSession?.libraryItemId {
                applyProfileSpeedToLoadedBook(SettingsStore.resolvedSpeed(forItem: id))
            }
            if profile.overrides.volumeBoostDB == nil { AudioPlayerService.shared.refreshAudioProcessing() }
        }

        let overrides = profile.overrides
        let defaults = UserDefaults.standard
        if let v = overrides.playbackSpeed {
            defaults.set(v, forKey: SettingsKeys.defaultPlaybackSpeed)
            // Review Medium 12 (30 October 2026): also move the book that's already loaded.
            // Straight to the player service, so it isn't remembered as this book's own speed.
            applyProfileSpeedToLoadedBook(v)
        }
        if let v = overrides.volumeBoostDB {
            SettingsStore.volumeBoostDB = v
            // The tap only re-reads settings when asked; without this the boost applied from the
            // next track on.
            AudioPlayerService.shared.refreshAudioProcessing()
        }
        if let v = overrides.keepScreenAwake { defaults.set(v, forKey: SettingsKeys.keepScreenAwake) }
        if let v = overrides.chapterHaptics { defaults.set(v, forKey: SettingsKeys.chapterHaptics) }
        if let v = overrides.wifiOnlyDownloads { defaults.set(v, forKey: SettingsKeys.wifiOnlyDownloads) }
        if let v = overrides.sleepFadeOut { defaults.set(v, forKey: SettingsKeys.sleepFadeOut) }
        if let v = overrides.autoplayNext { defaults.set(v, forKey: SettingsKeys.autoplayNext) }
        if let v = overrides.autoContinueSeries { defaults.set(v, forKey: SettingsKeys.autoContinueSeries) }
        // Batch 439: ambient bed. A profile without one hands back the user's own choice when
        // leaving a profile that had set one (Sleep to Work), not just on Off.
        if let bed = overrides.ambientBed {
            AmbientBedEngine.shared.select(bed)
            if let level = overrides.ambientLevel { AmbientBedEngine.shared.setLevel(level) }
        } else if previousProfile.overrides.ambientBed != nil, let baseline = storedBaseline() {
            applyAmbient(baseline)
        }
    }

    /// Review Medium 12: sets the loaded book's rate (no-op with nothing loaded, or while
    /// SharePlay owns the rate or WPM mode picks it per book).
    @MainActor
    private func applyProfileSpeedToLoadedBook(_ speed: Double) {
        let player = AudioPlayerService.shared
        guard player.currentSession != nil, !player.isCoordinatingPlayback,
              !SettingsStore.speedModeIsWPM else { return }
        player.setPlaybackRate(Float(speed))
    }

    @MainActor
    private func applyAmbient(_ baseline: Baseline) {
        guard let raw = baseline.ambientBed else { return }
        AmbientBedEngine.shared.select(AmbientBed(rawValue: raw))
        if let level = baseline.ambientLevel { AmbientBedEngine.shared.setLevel(level) }
    }

    /// Whether the running sleep timer is one this manager started for the Sleep profile.
    /// In memory only: after a relaunch the timer itself is gone too.
    @ObservationIgnored private var armedProfileSleepTimer = false

    /// The player's own sleep controls call this when the listener sets or clears a timer
    /// by hand, so leaving the profile won't cancel a timer that is now theirs. Siri and
    /// Control Center timers go through the same player sleep API, so they call it too.
    func profileSleepTimerReplaced() {
        armedProfileSleepTimer = false
        pendingEndOfChapterTimer = false  // Review 5 Low (Bedtime Story)
    }

    /// Starts the Sleep profile's timer when it's turned on and nothing is armed yet, and
    /// on leaving the profile cancels that timer only if it's still the profile's own
    /// countdown (the listener hasn't replaced it from the player; see
    /// `profileSleepTimerReplaced()`).
    @MainActor
    private func syncProfileSleepTimer(for profile: ListeningProfile) {
        let player = AudioPlayerService.shared
        pendingEndOfChapterTimer = false
        if profile.overrides.armsSleepTimer == true {
            guard player.sleepTimerOption == .off else { return }
            player.setSleepTimer(.minutes(SettingsStore.scheduledSleepTimerDurationMinutes))
            armedProfileSleepTimer = player.sleepTimerOption != .off
        } else if profile.overrides.armsEndOfChapterTimer == true {
            guard player.sleepTimerOption == .off else { return }
            player.setSleepTimer(.endOfChapter)
            armedProfileSleepTimer = player.sleepTimerOption != .off
            // Review Medium 13 (30 October 2026): with no book loaded there is no chapter
            // boundary to arm against, so `setSleepTimer` leaves the timer off. Remember it
            // and arm once playback starts.
            if !armedProfileSleepTimer {
                pendingEndOfChapterTimer = true
                watchForPlaybackStart()
            }
        } else if armedProfileSleepTimer {
            armedProfileSleepTimer = false
            switch player.sleepTimerOption {
            case .minutes, .endOfChapter: player.setSleepTimer(.off)
            default: break
            }
        }
    }

    /// Review Medium 13: Bedtime Story was chosen before any book was loaded, so its
    /// end-of-chapter timer is waiting for playback to start. In memory only.
    @ObservationIgnored private var pendingEndOfChapterTimer = false

    /// Observes the player (an `@Observable`) until a book is playing, then arms the pending
    /// timer. `withObservationTracking` fires once, so it re-registers while still pending.
    @MainActor
    private func watchForPlaybackStart() {
        guard pendingEndOfChapterTimer else { return }
        withObservationTracking {
            _ = AudioPlayerService.shared.isPlaying
            _ = AudioPlayerService.shared.currentSession
        } onChange: {
            // onChange runs before the new value lands; hop to the next main-actor turn.
            // Through `shared` rather than a captured `self`: the closure is `@Sendable`.
            Task { @MainActor in
                let manager = ListeningProfileManager.shared
                guard manager.pendingEndOfChapterTimer else { return }
                let player = AudioPlayerService.shared
                guard player.isPlaying, player.currentSession != nil else {
                    manager.watchForPlaybackStart()
                    return
                }
                manager.pendingEndOfChapterTimer = false
                guard manager.activeProfile.overrides.armsEndOfChapterTimer == true,
                      player.sleepTimerOption == .off else { return }
                player.setSleepTimer(.endOfChapter)
                manager.armedProfileSleepTimer = player.sleepTimerOption != .off
            }
        }
    }

    @MainActor
    private func apply(_ baseline: Baseline) {
        let defaults = UserDefaults.standard
        defaults.set(baseline.playbackSpeed, forKey: SettingsKeys.defaultPlaybackSpeed)
        SettingsStore.volumeBoostDB = baseline.volumeBoostDB
        AudioPlayerService.shared.refreshAudioProcessing()
        defaults.set(baseline.keepScreenAwake, forKey: SettingsKeys.keepScreenAwake)
        defaults.set(baseline.chapterHaptics, forKey: SettingsKeys.chapterHaptics)
        defaults.set(baseline.wifiOnlyDownloads, forKey: SettingsKeys.wifiOnlyDownloads)
        defaults.set(baseline.sleepFadeOut, forKey: SettingsKeys.sleepFadeOut)
        if let v = baseline.autoplayNext { defaults.set(v, forKey: SettingsKeys.autoplayNext) }
        if let v = baseline.autoContinueSeries { defaults.set(v, forKey: SettingsKeys.autoContinueSeries) }
        applyAmbient(baseline)
    }
}
