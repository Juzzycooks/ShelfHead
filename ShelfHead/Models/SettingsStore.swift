import Foundation
import UIKit

/// Keys + defaults for user playback preferences. `SettingsView` writes these via
/// `@AppStorage`; `AudioPlayerService` / `PlayerViewModel` read them here so the
/// settings actually take effect.
enum SettingsKeys {
    static let defaultPlaybackSpeed = "settings_defaultPlaybackSpeed"
    static let skipForwardInterval = "settings_skipForwardInterval"
    static let skipBackwardInterval = "settings_skipBackwardInterval"
    static let perBookSpeed = "settings_perBookSpeed"
    static let autoDownloadContinueListening = "settings_autoDownloadContinueListening"
    static let wifiOnlyDownloads = "settings_wifiOnlyDownloads"
    static let smartRewind = "settings_smartRewind"
    static let sleepFadeOut = "settings_sleepFadeOut"
    static let autoDeleteFinished = "settings_autoDeleteFinished"
    static let keepScreenAwake = "settings_keepScreenAwake"
    static let allowCellularStreaming = "settings_allowCellularStreaming"
    static let hapticsEnabled = "settings_hapticsEnabled"
    /// Batch 422 (transcription foundation). Master switch for on-device book transcripts.
    static let transcriptsEnabled = "settings_transcriptsEnabled"
    /// Overnight transcription runs only on power (see `TranscriptionScheduleDecision`).
    static let transcribeWhileCharging = "settings_transcribeWhileCharging"
    /// Locale identifier to transcribe in; empty = "Match the book".
    static let transcriptDefaultLanguage = "settings_transcriptDefaultLanguage"
    /// Batch 433: the narrator "Previously On…" montage adds short spoken lines between the
    /// narrator's clips. Off by default (narrator only).
    static let recapSpokenLinks = "settings_recapSpokenLinks"
    /// Batch 433: resuming a book after a few days away plays its prepared recap first, then
    /// the book. Off by default.
    static let recapAutoPlay = "settings_recapAutoPlay"
    static let autoplayNext = "settings_autoplayNext"
    static let autoContinueSeries = "settings_autoContinueSeries"
    static let downloadWhileCharging = "settings_downloadWhileCharging"
    static let seriesAutoDownload = "settings_seriesAutoDownload"   // [seriesName: Bool]
    static let spotlightIndexing = "settings_spotlightIndexing"
    /// Batch 406. Same string as `LiveActivityController.enabledDefaultsKey`, which reads it.
    static let liveActivities = "settings_liveActivitiesEnabled"
    static let streamWithURLToken = "settings_streamWithURLToken"
    static let storePassword = "settings_storePassword"
    static let appearance = "settings_appearance"                  // system | light | dark
    static let accentColor = "settings_accentColor"                // hex string
    static let hiddenHomeSections = "settings_hiddenHomeSections"  // [String] of section keys
    static let homeSectionOrder = "settings_homeSectionOrder"      // [String] of section keys, user-chosen order
    /// D2 follow-up (structural cap, 14 Aug 2026): every BROWSE-tier Home section key
    /// `reconcileNewHomeBrowseSections` has ever made a visibility decision about for
    /// this account — see that function for why this exists (unlike
    /// `SettingsMigrator`'s step-1 one-time fixed list, this makes the cap apply to
    /// shelf types introduced after this shipped, not just the ones known when it did).
    static let seenHomeBrowseSections = "settings_seenHomeBrowseSections"  // [String] of section keys
    /// One-time bootstrap marker for `reconcileNewHomeBrowseSections`: grandfathers in
    /// whatever an existing account's BROWSE zone already looks like the first time this
    /// runs, so accounts that customised Home before this fix shipped don't have their
    /// current sections silently re-hidden.
    static let homeBrowseSeenMigrated = "settings_homeBrowseSeenMigrated"
    /// N-6 (REVIEW_2026-09-14_DESIGN.md): schema version for the Home *shelf seeds*
    /// that ship after `SettingsMigrator`'s own steps 1 and 2 — see
    /// `SettingsStore.runHomeShelfSeedsIfNeeded()`. A separate counter from
    /// `SettingsMigrator`'s `settings_schemaVersion` rather than a fourth step there:
    /// these seeds have to run before `HomeView` reads `hiddenHomeSections`/
    /// `homeSectionOrder` into its `@State`, and they only ever touch those two Home
    /// keys, so they version independently of the general settings schema.
    static let homeShelfSeedVersion = "settings_homeShelfSeedVersion"   // Int
    static let chapterHaptics = "settings_chapterHaptics"          // haptic tick on chapter change
    static let libraryLayout = "settings_libraryLayout"            // grid | list
    /// Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §4.1c): "comfortable" | "compact" —
    /// iPhone-only (see `LibraryView.columns`'s idiom check); iPad always uses
    /// "comfortable"'s density curve regardless of this value.
    static let libraryGridDensity = "settings_libraryGridDensity"
    static let dailyReminder = "settings_dailyReminder"            // daily listening reminder on/off
    static let dailyReminderHour = "settings_dailyReminderHour"    // 0-23
    static let dailyReminderMinute = "settings_dailyReminderMinute"
    static let notifyDownloadComplete = "settings_notifyDownloadComplete"
    static let selectedLibraryId = "settings_selectedLibraryId"    // shared with CarPlay
    static let shakeAction = "settings_shakeAction"                // off | reset | extend
    static let smartSleepTimer = "settings_smartSleepTimer"        // snap to chapter end near the target (F2)
    static let librarySortOption = "settings_librarySortOption"    // LibrarySort.rawValue
    static let librarySortDescending = "settings_librarySortDescending"
    static let libraryProgressFilter = "settings_libraryProgressFilter"  // LibraryProgressFilter.rawValue
    // `settings_libraryDownloadedOnly` was retired in G6 (REVIEW_2026-09-04_UI.md): the
    // Downloaded filter is per-session view state now. Any value left on disk from
    // earlier builds is simply never read.
    static let dailyListeningGoalMinutes = "settings_dailyListeningGoalMinutes"  // 0 = off
    static let autoSkipIntroOutro = "settings_autoSkipIntroOutro"
    // Batch 399: timed chapter skip (seconds trimmed off every chapter's start/end).
    // 0 = off. Per-book overrides are a [itemId: [start, end]] map. See `ChapterSkip`.
    static let chapterSkipStart = "settings_chapterSkipStart"
    static let chapterSkipEnd = "settings_chapterSkipEnd"
    static let perBookChapterSkip = "settings_perBookChapterSkip"
    // Scheduled ("bedtime window") sleep timer — distinct from the manually-invoked
    // countdown/chapter timers in the player. See SettingsStore.scheduledSleepTimer*.
    static let scheduledSleepTimerEnabled = "settings_scheduledSleepTimerEnabled"
    static let scheduledSleepTimerStartHour = "settings_scheduledSleepTimerStartHour"
    static let scheduledSleepTimerStartMinute = "settings_scheduledSleepTimerStartMinute"
    static let scheduledSleepTimerEndHour = "settings_scheduledSleepTimerEndHour"
    static let scheduledSleepTimerEndMinute = "settings_scheduledSleepTimerEndMinute"
    static let scheduledSleepTimerSuppressedUntil = "settings_scheduledSleepTimerSuppressedUntil"
    static let scheduledSleepTimerDurationMinutes = "settings_scheduledSleepTimerDurationMinutes"
    // The length the Control Center Sleep Timer toggle arms.
    static let defaultSleepTimerMinutes = "settings_defaultSleepTimerMinutes"
    static let volumeBoostDB = "settings_volumeBoostDB"
    static let bassBoostDB = "settings_bassBoostDB"
    static let trebleBoostDB = "settings_trebleBoostDB"
    static let appLockEnabled = "settings_appLockEnabled"          // Face ID/Touch ID/passcode gate on foreground
    // D1 (design brief 2026-08-12): full player cover defaults to the plain square
    // artwork; the cassette is now an opt-in flip the user reaches by tapping the
    // cover. Persisted so the choice survives relaunch instead of resetting every time.
    static let playerShowsCassette = "settings_playerShowsCassette"
    /// Batch 425: the full player shows live captions in place of the cover.
    static let playerShowsCaptions = "settings_playerShowsCaptions"
    /// Batch 425: language identifier captions are translated into; empty = off.
    static let captionTranslationLanguage = "settings_captionTranslationLanguage"
    /// Opt-in `NSUbiquitousKeyValueStore` fallback for last-known playback position —
    /// see `CloudPositionStore`. Default off: the iCloud Key-Value Storage capability
    /// has to be added to the app target before it does anything useful.
    static let cloudPositionSync = "settings_cloudPositionSync"
    /// Batch 327: opt into the pre-iOS 27 `MPNowPlayingInfoCenter`/
    /// `MPRemoteCommandCenter` now-playing path on a device that could use iOS 27's
    /// `NowPlaying.MediaSession` instead. Read exactly once per launch, by
    /// `NowPlayingSessionBridge.backend` — see that property for why switching backends
    /// mid-launch is not allowed. Ignored below iOS 27, where classic is the only path.
    static let classicNowPlaying = "settings_classicNowPlaying"
}

/// What a device shake does while a sleep timer is running.
enum ShakeAction: String, CaseIterable, Identifiable, Equatable {
    case off, reset, extend
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:    return String(localized: "Off", comment: "Shake action: do nothing")
        case .reset:  return String(localized: "Reset sleep timer", comment: "Shake action")
        case .extend: return String(localized: "Extend +15 min", comment: "Shake action: add 15 minutes to the sleep timer")
        }
    }
}

enum SettingsStore {
    static var defaultPlaybackSpeed: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.defaultPlaybackSpeed)
        return v > 0 ? v : 1.0
    }

    static var skipForwardInterval: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.skipForwardInterval)
        return v > 0 ? v : 30
    }

    static var skipBackwardInterval: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.skipBackwardInterval)
        return v > 0 ? v : 15
    }

    static var autoDownloadContinueListening: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.autoDownloadContinueListening)
    }

    static var wifiOnlyDownloads: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.wifiOnlyDownloads)
    }

    static var smartRewind: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.smartRewind) }
    static var sleepFadeOut: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.sleepFadeOut) }
    static var autoDeleteFinished: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoDeleteFinished) }
    static var keepScreenAwake: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.keepScreenAwake) }
    static var allowCellularStreaming: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.allowCellularStreaming) }
    static var hapticsEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.hapticsEnabled) }
    static var transcriptsEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.transcriptsEnabled) }
    static var transcribeWhileCharging: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.transcribeWhileCharging) }
    static var recapSpokenLinks: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.recapSpokenLinks) }
    static var recapAutoPlay: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.recapAutoPlay) }
    /// Nil when the user left it on "Match the book" (empty string).
    static var transcriptDefaultLanguage: String? {
        let value = UserDefaults.standard.string(forKey: SettingsKeys.transcriptDefaultLanguage) ?? ""
        return value.isEmpty ? nil : value
    }
    /// Gates the app behind Face ID/Touch ID/passcode on every return to the
    /// foreground — see `AppLockManager`. Default off: most people aren't sharing a
    /// device where a self-hosted audiobook app's contents need gating, and this only
    /// protects listening history/downloads, not payment or health-grade data.
    static var appLockEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.appLockEnabled) }

    /// D1: whether the full player defaults to showing the cassette instead of the
    /// plain cover. `PlayerView` itself reads/writes this via `@AppStorage`; this
    /// accessor exists for parity with every other setting here and for any future
    /// non-view reader (none yet).
    static var playerShowsCassette: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.playerShowsCassette) }
    static var playerShowsCaptions: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.playerShowsCaptions) }
    /// Nil when caption translation is off (empty string).
    static var captionTranslationLanguage: String? {
        let value = UserDefaults.standard.string(forKey: SettingsKeys.captionTranslationLanguage) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Batch 327: whether to keep using the classic (`MPNowPlayingInfoCenter` +
    /// `MPRemoteCommandCenter`) Lock Screen / Control Center / CarPlay integration on a
    /// device that supports iOS 27's `NowPlaying.MediaSession`.
    ///
    /// The shipping default is `NowPlayingSessionRules.defaultPrefersClassic`, registered
    /// in `registerDefaults()` below rather than hardcoded here — that constant is the
    /// single place the default lives, so a plain `bool(forKey:)` read stays correct even
    /// if it is flipped to `true`.
    static var classicNowPlaying: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.classicNowPlaying) }

    /// Whether the queue auto-advances to the next book when one finishes.
    static var autoplayNext: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoplayNext) }
    /// When the Up Next queue runs dry right as a book finishes, automatically add the
    /// next unfinished book in that series (if any) rather than leaving the queue empty.
    /// Default on — this only ever adds one book, never auto-*plays* past a series
    /// boundary into an unrelated book, so it stays a convenience rather than a surprise.
    static var autoContinueSeries: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoContinueSeries) }
    /// Only run auto-downloads while the device is charging.
    static var downloadWhileChargingOnly: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.downloadWhileCharging) }
    /// Whether the library is indexed into Spotlight (default on).
    static var spotlightIndexingEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.spotlightIndexing) }
    /// Whether stream URLs carry `?token=` (AVPlayer range-request compatibility). Default
    /// OFF as of the security review — header-only auth is attempted first; this is a
    /// per-server opt-in fallback for a proxy/AVPlayer combination that needs the token
    /// in the URL. A URL-embedded token routinely ends up in access logs, WAF/CDN logs,
    /// and crash reports, so it stays off unless a server specifically needs it.
    static var streamWithURLToken: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.streamWithURLToken) }
    /// Whether the account password is kept (in the Keychain) for silent re-login when a
    /// refresh token is rejected. Default OFF as of the security review — the refresh
    /// token already covers normal re-auth; storing the password too is opt-in exposure
    /// the user can turn on if they'd rather not re-type it when a session lapses.
    static var storePassword: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.storePassword) }
    /// Light haptic when the chapter changes during playback (default on).
    static var chapterHapticsEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.chapterHaptics) }
    /// Notify when a download finishes (default off).
    static var notifyDownloadCompleteEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.notifyDownloadComplete) }
    /// What a shake does while a sleep timer runs.
    ///
    /// HIG audit 2026-09-17 M1: was `?? .reset`. Shake is the system's own gesture for
    /// undo/redo (HIG Gestures, Undo and redo), so repurposing it should be opt-in, not
    /// on by default. This only changes the *fallback* for installs that have never
    /// written a value — it's deliberately not a retroactive migration for anyone who
    /// already chose (or silently kept) Reset, since that would override a real, if
    /// unconfirmed, choice.
    static var shakeAction: ShakeAction {
        ShakeAction(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.shakeAction) ?? "") ?? .off
    }
    /// When a duration-based sleep timer (e.g. "30 min") would land within a few minutes
    /// of a chapter boundary, snap to that boundary instead of cutting off mid-sentence
    /// (default on, via `registerDefaults()`). Only affects `.minutes` timers on books
    /// with chapter data — the dedicated "End of chapter" / "+N chapters" options are
    /// unaffected.
    static var smartSleepTimer: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.smartSleepTimer) }
    /// Whether `CloudPositionStore` may read/write iCloud fallback positions (default off).
    static var cloudPositionSync: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.cloudPositionSync) }

    // MARK: - Library browse: sort / filter (persisted so a relaunch doesn't
    // silently reset the user's choice back to Title/All — `libraryLayout`
    // (grid/list) was already persisted via `@AppStorage`; these weren't.)

    static var librarySortOption: LibrarySort {
        get { LibrarySort(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.librarySortOption) ?? "") ?? .title }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.librarySortOption) }
    }
    static var librarySortDescending: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.librarySortDescending) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.librarySortDescending) }
    }
    static var libraryProgressFilter: LibraryProgressFilter {
        get { LibraryProgressFilter(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.libraryProgressFilter) ?? "") ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.libraryProgressFilter) }
    }

    // MARK: - Daily listening goal

    /// Minutes/day the user is aiming for; 0 means the goal ring is turned off.
    /// Defaults to 30 (via `registerDefaults`) so the ring shows up out of the box
    /// rather than requiring a trip to settings first.
    static var dailyListeningGoalMinutes: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.dailyListeningGoalMinutes) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.dailyListeningGoalMinutes) }
    }

    // MARK: - Auto-skip intro/outro

    /// Default OFF (unlike most playback toggles here) — auto-skipping content based on
    /// a title-pattern match carries real risk of skipping wanted content on a
    /// false-positive match, so this is opt-in rather than a default every listener
    /// gets without asking.
    static var autoSkipIntroOutroEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.autoSkipIntroOutro)
    }

    // MARK: - Timed chapter skip (Batch 399)

    /// The global default trims, applied to every book without its own override.
    static var defaultChapterSkip: ChapterSkip {
        get {
            ChapterSkip(start: UserDefaults.standard.integer(forKey: SettingsKeys.chapterSkipStart),
                        end: UserDefaults.standard.integer(forKey: SettingsKeys.chapterSkipEnd))
        }
        set {
            UserDefaults.standard.set(newValue.start, forKey: SettingsKeys.chapterSkipStart)
            UserDefaults.standard.set(newValue.end, forKey: SettingsKeys.chapterSkipEnd)
        }
    }

    /// This book's own trims, or nil when it follows the global default. An override of
    /// `.off` is meaningful: "no timed skip for this book", which also hands it back to
    /// title-matched intro/outro skip if that's on.
    static func chapterSkipOverride(forItem itemId: String) -> ChapterSkip? {
        let map = UserDefaults.standard.dictionary(forKey: SettingsKeys.perBookChapterSkip) as? [String: [Int]]
        guard let pair = map?[itemId], pair.count == 2 else { return nil }
        return ChapterSkip(start: pair[0], end: pair[1])
    }

    /// Sets (or, with nil, removes) a book's override. Bounded like `setSpeed`.
    static func setChapterSkipOverride(_ skip: ChapterSkip?, forItem itemId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: SettingsKeys.perBookChapterSkip) as? [String: [Int]]) ?? [:]
        map[itemId] = skip.map { [$0.start, $0.end] }
        if map.count > perBookSpeedCap {
            for key in map.keys where key != itemId {
                map.removeValue(forKey: key)
                if map.count <= perBookSpeedCap { break }
            }
        }
        UserDefaults.standard.set(map, forKey: SettingsKeys.perBookChapterSkip)
    }

    /// What playback of this book actually uses: its override, else the global default.
    static func resolvedChapterSkip(forItem itemId: String) -> ChapterSkip {
        chapterSkipOverride(forItem: itemId) ?? defaultChapterSkip
    }

    /// Drop all per-book chapter-skip overrides (on sign-out, alongside per-book speeds).
    static func clearPerBookChapterSkips() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.perBookChapterSkip)
    }

    // MARK: - Scheduled ("bedtime window") sleep timer

    /// Distinct from the manually-invoked countdown/end-of-chapter timers in the
    /// player (see `SleepTimerOption`): when enabled, starting a fresh playback session
    /// during the configured window automatically arms a countdown sleep timer, so
    /// nightly bedtime listening doesn't rely on remembering to set one by hand. See
    /// `AudioPlayerService.applyScheduledSleepTimerIfNeeded()`.
    static var scheduledSleepTimerEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.scheduledSleepTimerEnabled)
    }

    /// Window start, as hour/minute of day. The window can wrap past midnight (e.g.
    /// 22:00–07:00) — `isWithinScheduledSleepWindow(hour:minute:)` below handles that.
    static var scheduledSleepTimerStartHour: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.scheduledSleepTimerStartHour) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.scheduledSleepTimerStartHour) }
    }
    static var scheduledSleepTimerStartMinute: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.scheduledSleepTimerStartMinute) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.scheduledSleepTimerStartMinute) }
    }
    static var scheduledSleepTimerEndHour: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.scheduledSleepTimerEndHour) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.scheduledSleepTimerEndHour) }
    }
    static var scheduledSleepTimerEndMinute: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.scheduledSleepTimerEndMinute) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.scheduledSleepTimerEndMinute) }
    }
    static var scheduledSleepTimerDurationMinutes: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.scheduledSleepTimerDurationMinutes) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.scheduledSleepTimerDurationMinutes) }
    }

    /// The length (minutes) armed when the Control Center Sleep Timer toggle is turned on.
    static var defaultSleepTimerMinutes: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.defaultSleepTimerMinutes) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.defaultSleepTimerMinutes) }
    }

    /// Whether `hour:minute` falls inside the configured window, handling the common
    /// overnight case where the end time is numerically earlier than the start time
    /// (e.g. 22:00 → 07:00 spans midnight).
    static func isWithinScheduledSleepWindow(hour: Int, minute: Int) -> Bool {
        let nowMinutes = hour * 60 + minute
        let startMinutes = scheduledSleepTimerStartHour * 60 + scheduledSleepTimerStartMinute
        let endMinutes = scheduledSleepTimerEndHour * 60 + scheduledSleepTimerEndMinute
        if startMinutes == endMinutes { return false } // zero-width window — treat as never
        if startMinutes < endMinutes {
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        } else {
            // Wraps past midnight, e.g. 22:00–07:00.
            return nowMinutes >= startMinutes || nowMinutes < endMinutes
        }
    }

    /// "Skip tonight" — lets the scheduled sleep timer stay enabled as a standing
    /// preference without forcing a trip to Settings (to turn it off, then remember to
    /// turn it back on tomorrow) every time the user wants one longer session. Stored
    /// as a `Date` rather than a `Bool`, so it clears itself automatically rather than
    /// needing to be remembered to be turned back off.
    static var scheduledSleepTimerSuppressedUntil: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: SettingsKeys.scheduledSleepTimerSuppressedUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: SettingsKeys.scheduledSleepTimerSuppressedUntil)
        }
    }

    /// Suppresses auto-arming until the configured window's end time next occurs —
    /// i.e. "not tonight," rather than a fixed arbitrary duration that might expire
    /// mid-listen or linger long past when it's needed.
    static func suppressScheduledSleepTimerForTonight() {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = scheduledSleepTimerEndHour
        components.minute = scheduledSleepTimerEndMinute
        guard var candidate = calendar.date(from: components) else {
            // Shouldn't happen with valid stored hour/minute values, but fall back to a
            // reasonable fixed duration rather than leaving suppression unset.
            scheduledSleepTimerSuppressedUntil = now.addingTimeInterval(12 * 3600)
            return
        }
        if candidate <= now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        scheduledSleepTimerSuppressedUntil = candidate
    }

    /// Clears an active "skip tonight" suppression early — used when the user
    /// re-enables the scheduled timer manually rather than waiting for it to expire.
    static func clearScheduledSleepTimerSuppression() {
        scheduledSleepTimerSuppressedUntil = nil
    }

    // MARK: - Volume boost / tone control

    /// Extra gain in dB above the source's own level (0 = off). See
    /// `AudioProcessingChain` for how this is actually applied — a plain `AVPlayer`
    /// caps `volume` at 1.0 (no boost above unity), so this needs a real-time audio tap.
    static var volumeBoostDB: Double {
        get { UserDefaults.standard.double(forKey: SettingsKeys.volumeBoostDB) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.volumeBoostDB) }
    }
    /// Bass tone control, in dB-equivalent (0 = off). Simple one-pole low-shelf, not a
    /// precise parametric shelf — see `AudioProcessingChain`'s doc comment for why.
    static var bassBoostDB: Double {
        get { UserDefaults.standard.double(forKey: SettingsKeys.bassBoostDB) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.bassBoostDB) }
    }
    /// Treble tone control, in dB-equivalent (0 = off).
    static var trebleBoostDB: Double {
        get { UserDefaults.standard.double(forKey: SettingsKeys.trebleBoostDB) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.trebleBoostDB) }
    }

    // MARK: - Selected library (shared between the app UI and CarPlay)

    static var selectedLibraryId: String? {
        get { UserDefaults.standard.string(forKey: SettingsKeys.selectedLibraryId) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.selectedLibraryId) }
    }

    // MARK: - Home screen customisation

    /// Section keys the user has chosen to hide on the Home screen.
    static var hiddenHomeSections: Set<String> {
        Set((UserDefaults.standard.array(forKey: SettingsKeys.hiddenHomeSections) as? [String]) ?? [])
    }
    static func isHomeSectionHidden(_ key: String) -> Bool {
        hiddenHomeSections.contains(key)
    }
    static func setHomeSection(_ key: String, hidden: Bool) {
        var set = hiddenHomeSections
        if hidden { set.insert(key) } else { set.remove(key) }
        UserDefaults.standard.set(Array(set), forKey: SettingsKeys.hiddenHomeSections)
    }

    /// The user's chosen Home section order, as last saved from the reorder UI in
    /// `HomeCustomizeSheet`. May be stale relative to what's actually available right
    /// now (a shelf that's since emptied out, a newly-appeared one) — always pass this
    /// through `orderedHomeSectionKeys(from:)` rather than using it directly.
    static var homeSectionOrder: [String] {
        (UserDefaults.standard.array(forKey: SettingsKeys.homeSectionOrder) as? [String]) ?? []
    }
    static func setHomeSectionOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: SettingsKeys.homeSectionOrder)
    }
    /// Merges the saved order with the sections actually available right now: keeps the
    /// saved relative order for keys still present, appends any key that's newly
    /// available (a shelf the server just started returning, a first-ever download,
    /// etc.) after everything else in `availableKeys`' own order, and silently drops any
    /// saved key that's no longer available (e.g. Downloaded emptied out, a shelf
    /// disappeared) rather than leaving a gap or a stale entry.
    static func orderedHomeSectionKeys(from availableKeys: [String]) -> [String] {
        mergedHomeSectionOrder(saved: homeSectionOrder, available: availableKeys)
    }
    /// Pure merge, split out from `orderedHomeSectionKeys(from:)` so callers that keep
    /// their own live copy of the saved order (e.g. `HomeView`'s `@State`, mirroring how
    /// `hiddenSections` already works) can recompute the merge locally without a round
    /// trip through `UserDefaults` on every render.
    static func mergedHomeSectionOrder(saved: [String], available: [String]) -> [String] {
        var ordered = saved.filter { available.contains($0) }
        for key in available where !ordered.contains(key) {
            ordered.append(key)
        }
        return ordered
    }

    // MARK: - Home shelf seeds (versioned, one-time)

    /// N-6 (REVIEW_2026-09-14_DESIGN.md): bump when appending a case to
    /// `applyHomeShelfSeed(step:)`.
    static let currentHomeShelfSeedVersion = 2

    /// Runs every Home-shelf seed this install hasn't seen, in order, persisting after
    /// each one so an interrupted launch resumes rather than restarting — the same shape
    /// `SettingsMigrator.runIfNeeded()` uses, on its own version counter (see
    /// `SettingsKeys.homeShelfSeedVersion` for why it isn't a fourth step over there).
    ///
    /// Must be called before anything reads `hiddenHomeSections`/`homeSectionOrder`,
    /// which in practice means before `HomeView` is first initialized — those two are
    /// what its `@State` is seeded from, and a `@State` default that has already been
    /// evaluated won't pick up a later write. `MainTabView.init()` is the call site.
    ///
    /// Returns true when it actually applied a step, so a caller can tell a first run
    /// from a no-op; every later launch is a single `UserDefaults` integer read.
    @discardableResult
    static func runHomeShelfSeedsIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        // `integer(forKey:)` returns 0 for a missing key, which is exactly right: an
        // install that predates this counter has run none of the steps. Clamped for the
        // same reason `SettingsMigrator.startingVersion` clamps — a value written by a
        // newer build must not re-run this build's steps, and a corrupt negative must
        // not index a step that doesn't exist.
        var version = min(max(defaults.integer(forKey: SettingsKeys.homeShelfSeedVersion), 0),
                          currentHomeShelfSeedVersion)
        guard version < currentHomeShelfSeedVersion else { return false }
        while version < currentHomeShelfSeedVersion {
            version += 1
            applyHomeShelfSeed(step: version)
            defaults.set(version, forKey: SettingsKeys.homeShelfSeedVersion)
        }
        return true
    }

    private static func applyHomeShelfSeed(step: Int) {
        switch step {
        case 1: seedSmartFiltersShelf()
        case 2: seedSmartFiltersShelfHiddenByDefault()
        default: break
        }
    }

    /// Step 1 — the Smart Filters shelf (N-6, REVIEW_2026-09-14_DESIGN.md).
    ///
    /// The eight client-side `SmartFilter`s were only reachable from a tab inside
    /// Library's filter sheet, so the app's strongest differentiator was two taps and a
    /// segmented control deep. Step 1 made the shelf visible and placed it directly
    /// under the continue-listening shelves; **step 2 (below) then hides it by default** —
    /// the user's call after seeing it on device — so the net effect for every install is
    /// "placed, hidden, one tap away in Customize Home". Both halves are pure functions
    /// below so the decision can be pinned by a test rather than only observed on a device.
    ///
    /// Visibility is also enforced going forward by
    /// `HomeView.defaultVisibleBrowseKeys` — `reconcileNewHomeBrowseSections` defaults
    /// any BROWSE key it has never decided about to *hidden*, and this key being on that
    /// allowlist is what stops the cap from immediately undoing this seed. This step is
    /// what additionally places it, which the allowlist can't do.
    private static func seedSmartFiltersShelf() {
        let key = HomeView.smartFiltersKey

        let currentlyHidden = hiddenHomeSections
        let hidden = seededHomeVisibility(hidden: currentlyHidden, showing: key)
        if hidden != currentlyHidden {
            UserDefaults.standard.set(Array(hidden), forKey: SettingsKeys.hiddenHomeSections)
        }

        // Only an account that already has a saved order needs placing: with no saved
        // order, `mergedHomeSectionOrder(saved:available:)` falls through to
        // `HomeView.availableSectionKeys`' own order, which inserts this key after the
        // same anchors (via the same function) — writing a one-element order here would
        // instead pin Smart Filters above every other browse shelf.
        let saved = homeSectionOrder
        guard !saved.isEmpty else { return }
        setHomeSectionOrder(seededHomeOrder(saved: saved, inserting: key,
                                            after: HomeView.smartFiltersOrderAnchors))
    }

    /// Step 2 — Smart Filters ships HIDDEN by default (user decision on device, 14
    /// September 2026, Batch 320). Step 1 had made it visible; the user found the extra
    /// shelf on Home unwanted out of the box. It stays fully available in Customize Home
    /// and is still placed after the continue-listening shelves by step 1, so turning it
    /// on lands it in the right spot. Going forward `HomeView.defaultVisibleBrowseKeys`
    /// no longer lists the key either, so the structural cap also defaults it to hidden
    /// for an account where it appears for the first time.
    ///
    /// Runs exactly once, immediately after step 1 on a fresh install or on the next
    /// launch for a device that already ran step 1 — in both cases before the user has
    /// had a Customize Home session that could have expressed a preference the other
    /// way, which is what makes an unconditional hide safe here.
    private static func seedSmartFiltersShelfHiddenByDefault() {
        let key = HomeView.smartFiltersKey
        let currentlyHidden = hiddenHomeSections
        let hidden = seededHomeVisibility(hidden: currentlyHidden, hiding: key)
        if hidden != currentlyHidden {
            UserDefaults.standard.set(Array(hidden), forKey: SettingsKeys.hiddenHomeSections)
        }
    }

    /// The inverse decision for a shelf that ships hidden: adding the key to the hidden
    /// set, touching nothing else. Pure, pinned by `SmartFilterShelfTests`.
    static func seededHomeVisibility(hidden: Set<String>, hiding key: String) -> Set<String> {
        var out = hidden
        out.insert(key)
        return out
    }

    /// The seed's default-visibility decision, pure so it can be pinned by a test: a
    /// Home shelf that ships visible is simply one that is *absent* from the hidden set,
    /// so seeding it removes the key if some earlier state had put it there and is
    /// otherwise a no-op. Deliberately not the inverse operation — nothing here can
    /// re-hide a shelf, so re-entering this (a restored backup, a clamped version) can
    /// never override a choice the user has since made in Customize Home.
    static func seededHomeVisibility(hidden: Set<String>, showing key: String) -> Set<String> {
        var out = hidden
        out.remove(key)
        return out
    }

    /// The seed's placement decision, pure for the same reason: returns `saved` with
    /// `key` inserted directly after the last of `anchors` that appears in it.
    ///
    /// - A `key` already present is left exactly where it is (so the seed is idempotent,
    ///   and so `HomeView.availableSectionKeys` can call this unconditionally on every
    ///   recompute without the key drifting).
    /// - No anchor present means the shelves it was meant to follow aren't in this
    ///   order at all, so it goes to the front rather than the back — being first in
    ///   BROWSE is the intent's nearest neighbour, being last is not.
    /// - Anchors are matched in `anchors`' own order against `saved`, taking the
    ///   *latest* position found, so a user who dragged Next in Series above Continue
    ///   Listening still gets the shelf below both of them.
    static func seededHomeOrder(saved: [String], inserting key: String, after anchors: [String]) -> [String] {
        guard !saved.contains(key) else { return saved }
        var insertAt = 0
        for anchor in anchors {
            guard let index = saved.firstIndex(of: anchor) else { continue }
            insertAt = max(insertAt, index + 1)
        }
        var out = saved
        out.insert(key, at: min(insertAt, out.count))
        return out
    }

    /// One-time settings migrations that used to live here — the Home visibility seed,
    /// the Home order seed, and the alternate-app-icon revert — now run as ordered steps
    /// in `SettingsMigrator`, which replaced their three independent `Bool` flags with a
    /// single schema version. `reconcileNewHomeBrowseSections` below deliberately stayed:
    /// it is ongoing reconciliation, not a one-time migration.

    /// D2 follow-up (structural cap, follow-up review 14 Aug 2026): `SettingsMigrator`'s
    /// step 1 only ever runs once, against a fixed list of BROWSE-tier key names known at
    /// the time it shipped — a shelf type Audiobookshelf (or a later app version) adds
    /// afterward was never on that list, so it defaulted to *visible*, and the "capped to
    /// a handful of shelves" browse zone the design brief asked for could grow without
    /// bound as new shelf types appear. This is called every time Home recomputes what's
    /// actually available, so the cap is enforced going forward too, not just at first
    /// install: any BROWSE-tier key this account has never been decided about before
    /// (tracked in `seenHomeBrowseSections`, independent of the mutable `hiddenHomeSections`/
    /// `homeSectionOrder` state so a later explicit unhide via Customize Home is never
    /// undone by this running again) defaults to hidden unless it's on the small
    /// `alwaysVisible` allowlist — the same three sections `SettingsMigrator`'s step 1
    /// already leaves visible for a fresh install.
    ///
    /// The very first call ever grandfathers in whatever's already available without
    /// hiding anything, so an account that customised Home before this fix shipped
    /// doesn't have its current, already-decided browse zone silently re-hidden — only
    /// shelf types that show up for the first time *after* that get the new default.
    ///
    /// Returns the keys newly hidden by this call, so a caller keeping its own live
    /// `@State` mirror of `hiddenHomeSections` (same pattern `HomeView` already uses)
    /// can fold them in without an extra `UserDefaults` round trip.
    @discardableResult
    static func reconcileNewHomeBrowseSections(browseKeys: [String], alwaysVisible: Set<String>) -> Set<String> {
        guard !browseKeys.isEmpty else { return [] }
        var seen = Set((UserDefaults.standard.array(forKey: SettingsKeys.seenHomeBrowseSections) as? [String]) ?? [])

        guard UserDefaults.standard.bool(forKey: SettingsKeys.homeBrowseSeenMigrated) else {
            UserDefaults.standard.set(true, forKey: SettingsKeys.homeBrowseSeenMigrated)
            seen.formUnion(browseKeys)
            UserDefaults.standard.set(Array(seen), forKey: SettingsKeys.seenHomeBrowseSections)
            return []
        }

        let unseen = browseKeys.filter { !seen.contains($0) }
        guard !unseen.isEmpty else { return [] }
        seen.formUnion(unseen)
        UserDefaults.standard.set(Array(seen), forKey: SettingsKeys.seenHomeBrowseSections)

        let toHide = Set(unseen.filter { !alwaysVisible.contains($0) })
        guard !toHide.isEmpty else { return [] }
        var hidden = hiddenHomeSections
        hidden.formUnion(toHide)
        UserDefaults.standard.set(Array(hidden), forKey: SettingsKeys.hiddenHomeSections)
        return toHide
    }

    // MARK: - Per-series auto-download

    static func seriesAutoDownloadEnabled(_ series: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.seriesAutoDownload) as? [String: Bool])?[series] ?? false
    }
    static func setSeriesAutoDownload(_ enabled: Bool, for series: String) {
        var map = (UserDefaults.standard.dictionary(forKey: SettingsKeys.seriesAutoDownload) as? [String: Bool]) ?? [:]
        if enabled { map[series] = true } else { map.removeValue(forKey: series) }
        UserDefaults.standard.set(map, forKey: SettingsKeys.seriesAutoDownload)
    }

    /// Seconds to rewind on resume, scaled by how long playback was paused.
    static func smartRewindAmount(pausedFor seconds: TimeInterval) -> Double {
        guard smartRewind else { return 0 }
        switch seconds {
        case ..<10: return 0
        case ..<60: return 3
        case ..<600: return 5
        case ..<3600: return 10
        default: return 20
        }
    }

    // MARK: - Per-book speed memory

    /// The remembered speed for a specific book, if the user set one.
    static func speed(forItem itemId: String) -> Double? {
        let map = UserDefaults.standard.dictionary(forKey: SettingsKeys.perBookSpeed) as? [String: Double]
        return map?[itemId]
    }

    /// The speed to use when starting a book: its remembered speed, else the global default.
    static func resolvedSpeed(forItem itemId: String) -> Double {
        // Review Medium 12 (30 October 2026): an active profile's speed beats the book's remembered one.
        resolveSpeed(profile: ListeningProfileManager.shared.activeProfile.overrides.playbackSpeed,
                     remembered: speed(forItem: itemId), globalDefault: defaultPlaybackSpeed)
    }

    /// Pure decision behind `resolvedSpeed(forItem:)`: profile speed, else remembered, else default.
    nonisolated static func resolveSpeed(profile: Double?, remembered: Double?, globalDefault: Double) -> Double {
        profile ?? remembered ?? globalDefault
    }

    /// Upper bound on remembered per-book speeds so the dictionary can't grow forever.
    private static let perBookSpeedCap = 500

    static func setSpeed(_ speed: Double, forItem itemId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: SettingsKeys.perBookSpeed) as? [String: Double]) ?? [:]
        map[itemId] = speed
        // Keep the map bounded. Without recency data we can only trim arbitrarily, but
        // the entry we just set is always preserved.
        if map.count > perBookSpeedCap {
            for key in map.keys where key != itemId {
                map.removeValue(forKey: key)
                if map.count <= perBookSpeedCap { break }
            }
        }
        UserDefaults.standard.set(map, forKey: SettingsKeys.perBookSpeed)
    }

    /// Drop all remembered per-book speeds (e.g. on logout / account removal).
    static func clearPerBookSpeeds() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.perBookSpeed)
    }

    /// Register defaults once at launch so first reads are correct everywhere.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.defaultPlaybackSpeed: 1.0,
            SettingsKeys.skipForwardInterval: 30.0,
            SettingsKeys.skipBackwardInterval: 15.0,
            SettingsKeys.autoDownloadContinueListening: false,
            SettingsKeys.wifiOnlyDownloads: true,
            SettingsKeys.smartRewind: true,
            SettingsKeys.sleepFadeOut: true,
            SettingsKeys.autoDeleteFinished: false,
            SettingsKeys.keepScreenAwake: false,
            SettingsKeys.allowCellularStreaming: true,
            SettingsKeys.hapticsEnabled: true,
            SettingsKeys.transcriptsEnabled: true,
            SettingsKeys.transcribeWhileCharging: true,
            SettingsKeys.transcriptDefaultLanguage: "",
            SettingsKeys.autoplayNext: true,
            // Off by default (28 Oct 2026, user rule): nothing starts playing that the
            // listener didn't choose. Turning it on in Settings › Playback opts in.
            SettingsKeys.autoContinueSeries: false,
            SettingsKeys.downloadWhileCharging: false,
            SettingsKeys.spotlightIndexing: true,
            SettingsKeys.liveActivities: true,
            SettingsKeys.chapterHaptics: true,
            // Default OFF (security review, finding #2): a query-string token is a live
            // credential that routinely ends up in reverse-proxy/CDN/WAF access logs,
            // crash reports, and copied diagnostic output — far more exposure than a
            // request header gets. Header-only auth is attempted first now; this only
            // needs to be turned on as a per-server compatibility fallback if a
            // particular AVPlayer/proxy combination won't do range requests without the
            // token in the URL. See `AudioPlayerService`'s streaming-URL construction.
            SettingsKeys.streamWithURLToken: false,
            // Default OFF (security review, finding #4): the app already has a refresh
            // token for silent re-authentication; keeping the original account password
            // too is usually unnecessary exposure, and it's easy for a password reused
            // elsewhere to matter more than this app's own session ever would. Recovery
            // order is now: refresh token → ask the user to sign in again → only store
            // the password if they explicitly opt back in from Settings.
            SettingsKeys.storePassword: false,
            SettingsKeys.smartSleepTimer: true,
            SettingsKeys.dailyListeningGoalMinutes: 30,
            // Scheduled sleep timer defaults to a plausible 10pm-7am bedtime window,
            // 30-minute countdown — but stays OFF until the user opts in.
            SettingsKeys.scheduledSleepTimerEnabled: false,
            SettingsKeys.scheduledSleepTimerStartHour: 22,
            SettingsKeys.scheduledSleepTimerStartMinute: 0,
            SettingsKeys.scheduledSleepTimerEndHour: 7,
            SettingsKeys.scheduledSleepTimerEndMinute: 0,
            SettingsKeys.scheduledSleepTimerDurationMinutes: 30,
            SettingsKeys.defaultSleepTimerMinutes: 30,
            SettingsKeys.playerShowsCassette: false,
            SettingsKeys.playerShowsCaptions: false,
            SettingsKeys.captionTranslationLanguage: "",
            SettingsKeys.cloudPositionSync: false,
            // Batch 327: deliberately registered from the constant rather than a literal
            // — `NowPlayingSessionRules.defaultPrefersClassic` is the one place the
            // iOS 27 now-playing backend default is decided (see its doc comment).
            SettingsKeys.classicNowPlaying: NowPlayingSessionRules.defaultPrefersClassic
        ])
    }
}

/// Batch 399 (App Store review request): seconds trimmed off the start and end of every
/// chapter, for books where each chapter opens with a jingle or a spoken "Chapter Seven"
/// that title-matched intro/outro skip (`Chapter.looksLikeIntroOrOutro`) can't see.
/// While a book's resolved value is active it replaces title matching for that book.
/// The decision itself is `AudioPlayerService.chapterSkipTarget`.
struct ChapterSkip: Equatable {
    var start: Int
    var end: Int

    static let off = ChapterSkip(start: 0, end: 0)

    var isActive: Bool { start > 0 || end > 0 }

    /// Picker choices, in seconds; 0 is "Off".
    static let options: [Int] = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]

    /// "Off", "15 s", "1 min 30 s" — shared by Settings and the player sheet.
    static func label(_ seconds: Int) -> String {
        guard seconds > 0 else { return String(localized: "Off", comment: "Chapter skip option: disabled") }
        if seconds < 60 { return String(localized: "\(seconds) s", comment: "Chapter skip length in seconds. %lld is seconds") }
        let s = seconds % 60
        return s == 0
            ? String(localized: "\(seconds / 60) min", comment: "Chapter skip length in whole minutes. %lld is minutes")
            : String(localized: "\(seconds / 60) min \(s) s", comment: "Chapter skip length. First %lld is minutes, second is seconds")
    }
}
