import Foundation

/// Which Settings page a search entry deep-links into. `SettingsView`'s search box
/// matches against `SettingsSearchIndex.entries` and routes the tapped result straight
/// to the page it lives on, without the user needing to know (or remember, across this
/// screen's 6+ past reorganizations) which page a given toggle ended up on.
///
/// Critique 2026-10-06 (distill): "Playback & Appearance" (~30 controls on one page) is
/// split into Playback, Sleep Timer, Sound, Appearance and System & Privacy, each its own
/// page from the Settings root. Recent Changes moved out of Diagnostics to the root.
enum SettingsPage: Hashable, CaseIterable {
    // T7 (REVIEW_2026-09-04_UI.md): `downloadsNotifications` and `downloadsStorage` used
    // to be two distinct pages; Batch 266 merged them into one `DownloadsSettingsView`.
    case account, playback, sleepTimer, sound, appearance, systemPrivacy, downloads, diagnostics
    /// The undo log (`PlaybackHistoryView`). Lands on the page; it has no anchored rows.
    case recentChanges
    /// Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §7d, §10): the destination for
    /// features that don't live on a Settings page at all (Driving Mode, cassette
    /// view, B-Side all live in the Player/Home/Library) — `FeaturesTipsView`
    /// explains each of them in plain language, so a search for one of these
    /// deep-links there instead of to a toggle that doesn't exist.
    case featuresTips
    /// Batch 422: on-device book transcripts (`TranscriptsSettingsView`).
    case transcripts
    /// Batch 443: Hardcover sync and Goodreads/StoryGraph CSV (`ReadingSitesView`).
    case readingSites
    /// Batch 453: a CloudKit-shared household for recommendations and book clubs (`HouseholdSettingsView`).
    case household

    /// Critique 2026-10-06 (clarify): the destination page's own navigation title, shown as
    /// each search result's subtitle so a result says where it leads before it's tapped.
    var title: String {
        switch self {
        case .account: return String(localized: "Account & Security")
        case .playback: return String(localized: "Playback")
        case .sleepTimer: return String(localized: "Sleep Timer")
        case .sound: return String(localized: "Sound")
        case .appearance: return String(localized: "Appearance")
        case .systemPrivacy: return String(localized: "System & Privacy")
        case .downloads: return String(localized: "Downloads")
        case .diagnostics: return String(localized: "Diagnostics")
        case .recentChanges: return String(localized: "Recent Changes")
        case .featuresTips: return String(localized: "Features & Tips")
        case .transcripts: return String(localized: "Transcripts", comment: "Settings page title: on-device speech-to-text transcripts of audiobooks")
        case .readingSites: return String(localized: "Reading Sites", comment: "Settings page title: Hardcover sync and Goodreads/StoryGraph import and export")
        case .household: return String(localized: "Household", comment: "Settings page title: family or friends sharing recommendations and book clubs over iCloud")
        }
    }

    /// Whether ShelfHead's own Settings code can scroll this page to a row. Recent
    /// Changes is owned elsewhere: a result there lands on the page.
    var supportsRowAnchors: Bool {
        switch self {
        case .recentChanges: return false
        default: return true
        }
    }
}

/// Critique 2026-10-06 (clarify): stable row ids shared by the search index and the
/// pages' `.settingsRowAnchor(_:)` calls, so a search result scrolls to the row it names
/// rather than landing at the top of the page. One constant per anchored row, so the two
/// sides can't drift apart through a typo.
enum SettingsRow {
    // Account & Security
    static let servers = "account.servers"
    static let customHeaders = "account.customHeaders"
    static let staySignedIn = "account.staySignedIn"
    static let streamToken = "account.streamToken"
    static let importExport = "account.importExport"
    static let signOut = "account.signOut"
    static let removeAllServers = "account.removeAllServers"
    static let appLock = "account.appLock"
    static let activeSessions = "account.activeSessions"

    // Playback
    static let listeningProfile = "playback.listeningProfile"
    static let defaultSpeed = "playback.defaultSpeed"
    static let skipIntervals = "playback.skipIntervals"
    static let smartRewind = "playback.smartRewind"
    static let autoSkipIntroOutro = "playback.autoSkipIntroOutro"
    static let chapterSkip = "playback.chapterSkip"
    static let cellularStreaming = "playback.cellularStreaming"
    static let autoplayNext = "playback.autoplayNext"
    static let autoContinueSeries = "playback.autoContinueSeries"
    static let keepScreenAwake = "playback.keepScreenAwake"
    static let haptics = "playback.haptics"

    // Sleep Timer
    static let sleepFadeOut = "sleep.fadeOut"
    static let smartSleepTimer = "sleep.smart"
    static let scheduledSleepTimer = "sleep.scheduled"
    static let controlCenterTimer = "sleep.controlCenter"
    static let shakeGesture = "sleep.shake"

    // Sound
    static let volumeBoost = "sound.volumeBoost"
    // Phase 2 (Batches 436–442)
    static let ambientSound = "sound.ambient"
    static let releaseRadar = "system.releaseRadar"
    static let libraryDoctor = "account.libraryDoctor"
    static let dialogue = "sound.dialogue"
    static let upload = "account.upload"
    static let spatialAudio = "sound.spatial"
    static let readingSites = "readingSites.hardcover"

    // Transcripts
    static let transcriptsEnabled = "transcripts.enabled"
    static let transcribeWhileCharging = "transcripts.charging"
    static let transcriptLanguage = "transcripts.language"
    static let transcriptStorage = "transcripts.storage"
    // Batch 433
    static let recapSpokenLinks = "transcripts.recapLinks"
    static let recapAutoPlay = "transcripts.recapAutoPlay"

    // Appearance
    static let theme = "appearance.theme"
    static let deckSkin = "appearance.deckSkin"
    static let household = "household.root"
    static let householdSharing = "household.sharing"
    static let kids = "household.kids"
    static let accentColour = "appearance.accent"

    // System & Privacy
    static let spotlight = "system.spotlight"
    static let siri = "system.siri"
    static let liveActivities = "system.liveActivities"
    static let classicNowPlaying = "system.classicNowPlaying"
    static let iCloudPositions = "system.iCloudPositions"
    static let dailyReminder = "system.dailyReminder"
    static let securityLink = "system.securityLink"

    // Downloads (Settings > Downloads)
    static let downloadedBooksLink = "downloads.downloadedBooks"
    static let autoDownload = "downloads.autoDownload"
    static let wifiOnly = "downloads.wifiOnly"
    static let autoDeleteFinished = "downloads.autoDelete"
    static let imageCache = "downloads.imageCache"
    static let notifyDownloadComplete = "downloads.notifyComplete"
    static let storage = "downloads.storage"

    // Diagnostics
    static let syncStatus = "diagnostics.sync"
    static let serverDiagnostics = "diagnostics.server"
    static let serverBackups = "account.backups"
    static let downloadHealth = "diagnostics.downloadHealth"

    // Features & Tips
    static let featureBSide = "features.bSide"
    static let featureCassette = "features.cassette"
    static let featureFineScrub = "features.fineScrub"
    static let featureDrivingMode = "features.drivingMode"
    static let featureSleepShake = "features.sleepShake"
    static let featureWidget = "features.widget"
    static let featureWatch = "features.watch"
}

/// One row per setting a user might search for, across all pages. Deliberately flat
/// and hand-maintained rather than generated — the value of search here is mapping the
/// words a person actually thinks in ("EQ", "sleep", "wifi") onto wherever the setting
/// actually landed, not reflecting over `@AppStorage` property names (several settings
/// are known by more than one name).
struct SettingsSearchEntry: Equatable, Identifiable {
    /// Critique 2026-10-06 (clarify): when a row is only on screen in some states, the
    /// index leaves it out in the others rather than offering a result that leads nowhere.
    enum Condition: Equatable {
        case always
        /// "Remove All Servers from This Device" only shows with more than one saved
        /// server (`AccountSecuritySettingsView`).
        case multipleSavedServers
    }

    let title: String
    let keywords: [String]
    /// Localized synonyms (parsed from one comma-separated, translatable string), matched
    /// in addition to `keywords` so a user typing in their own language finds the row.
    let localizedKeywords: [String]
    let page: SettingsPage
    /// The anchored row on `page` (a `SettingsRow` constant), or nil to land on the page.
    var row: String? = nil
    var condition: Condition = .always

    init(title: String, keywords: [String], localizedKeywords: String = "", page: SettingsPage,
         row: String? = nil, condition: Condition = .always) {
        self.title = title
        self.keywords = keywords
        self.localizedKeywords = Self.parseKeywordList(localizedKeywords)
        self.page = page
        self.row = row
        self.condition = condition
    }

    /// Splits a translated keyword string on ",", full-width "，" and "、", trimming
    /// whitespace, lowercasing and dropping empties.
    static func parseKeywordList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Stable list identity: the row id where there is one, else the title (titles are
    /// unique — pinned by `SettingsSearchIndexTests.testNoDuplicateTitles`).
    var id: String { row.map { "\($0)#\(title)" } ?? "title#\(title)" }

    /// Whether this entry's row is on screen for the given live state.
    func isVisible(savedServerCount: Int) -> Bool {
        switch condition {
        case .always: return true
        case .multipleSavedServers: return savedServerCount > 1
        }
    }
}

/// UI-12 (REVIEW_2026-08-12.md, "Split SettingsView.swift into Views/Settings/"):
/// extracted out of `SettingsView`, where this was private nested state, so this pure
/// title/keyword-matching logic can be unit tested directly (see
/// `SettingsSearchIndexTests.swift`) independent of the view hierarchy it used to live
/// inside of.
enum SettingsSearchIndex {
    /// Every entry for the running system, before live-state filtering. Critique
    /// 2026-10-06 (clarify): "Classic Lock Screen controls" is only listed on iOS 27,
    /// where its row exists (`SystemPrivacySettingsSection` gates it with
    /// `#available(iOS 27, *)`).
    static var entries: [SettingsSearchEntry] {
        entries(includesClassicLockScreen: isClassicLockScreenAvailable)
    }

    private static var isClassicLockScreenAvailable: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// Pure, for tests: the index with or without the iOS 27-only row.
    static func entries(includesClassicLockScreen: Bool) -> [SettingsSearchEntry] {
        includesClassicLockScreen ? allEntries : allEntries.filter { $0.title != classicLockScreenTitle }
    }

    /// Critique 2026-10-06 (clarify): the index filtered by live state, so a row that
    /// isn't on screen (Remove All Servers with one saved server) isn't offered.
    static func entries(includesClassicLockScreen: Bool, savedServerCount: Int) -> [SettingsSearchEntry] {
        entries(includesClassicLockScreen: includesClassicLockScreen)
            .filter { $0.isVisible(savedServerCount: savedServerCount) }
    }

    static let classicLockScreenTitle = String(localized: "Classic Lock Screen controls")

    private static let allEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(title: String(localized: "Servers & accounts"), keywords: ["server", "account", "add server", "switch account"], localizedKeywords: String(localized: "server, account, add server, switch account", comment: "Settings search keywords for 'Servers & accounts', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.servers),
        SettingsSearchEntry(title: String(localized: "Custom HTTP headers"), keywords: ["header", "proxy", "cloudflare", "authelia"], localizedKeywords: String(localized: "header, proxy, cloudflare, authelia", comment: "Settings search keywords for 'Custom HTTP headers', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.customHeaders),
        SettingsSearchEntry(title: String(localized: "Stay signed in"), keywords: ["password", "sign in", "keychain"], localizedKeywords: String(localized: "password, sign in, keychain", comment: "Settings search keywords for 'Stay signed in', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.staySignedIn),
        SettingsSearchEntry(title: String(localized: "Token in stream URL"), keywords: ["token", "stream url", "compatibility"], localizedKeywords: String(localized: "token, stream url, compatibility", comment: "Settings search keywords for 'Token in stream URL', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.streamToken),
        SettingsSearchEntry(title: String(localized: "Export / Import Connections & Settings"), keywords: ["export", "import", "backup", "settings export", "preferences"], localizedKeywords: String(localized: "export, import, backup, settings export, preferences", comment: "Settings search keywords for 'Export / Import Connections & Settings', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.importExport),
        SettingsSearchEntry(title: String(localized: "Sign Out"), keywords: ["logout", "log out", "sign out"], localizedKeywords: String(localized: "logout, log out, sign out", comment: "Settings search keywords for 'Sign Out', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.signOut),
        // Critique 2026-10-06 (harden): the full wipe Sign Out used to be, now its own row.
        // Critique 2026-10-06 (clarify): only indexed when the row is shown (> 1 server).
        SettingsSearchEntry(title: String(localized: "Remove All Servers from This Device"), keywords: ["remove all servers", "remove servers", "forget servers", "wipe", "reset"], localizedKeywords: String(localized: "remove all servers, remove servers, forget servers, wipe, reset", comment: "Settings search keywords for 'Remove All Servers from This Device', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.removeAllServers, condition: .multipleSavedServers),
        // T3 (REVIEW_2026-09-04_UI.md)
        SettingsSearchEntry(title: String(localized: "Face ID / App Lock"), keywords: ["face id", "touch id", "biometric", "app lock", "passcode", "lock"], localizedKeywords: String(localized: "face id, touch id, biometric, app lock, passcode, lock", comment: "Settings search keywords for 'Face ID / App Lock', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.appLock),
        SettingsSearchEntry(title: String(localized: "Active sessions"), keywords: ["sessions", "devices", "sign out everywhere", "logout all"], localizedKeywords: String(localized: "sessions, devices, sign out everywhere, logout all", comment: "Settings search keywords for 'Active sessions', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.activeSessions),

        // Playback
        // T2 (REVIEW_2026-09-04_UI.md): the Listening Profile picker had no search
        // entry at all, so a search for "driving" only ever surfaced the unrelated
        // Driving Mode entry below (its "Driving" preset was renamed to "Commute").
        SettingsSearchEntry(title: String(localized: "Listening Profile"), keywords: ["listening profile", "profile", "preset", "commute", "sleep profile", "work profile", "driving"], localizedKeywords: String(localized: "listening profile, profile, preset, commute, sleep profile, work profile, driving", comment: "Settings search keywords for 'Listening Profile', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.listeningProfile),
        SettingsSearchEntry(title: String(localized: "Default speed"), keywords: ["speed", "playback rate"], localizedKeywords: String(localized: "speed, playback rate", comment: "Settings search keywords for 'Default speed', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.defaultSpeed),
        SettingsSearchEntry(title: String(localized: "Skip forward / back"), keywords: ["skip", "seek"], localizedKeywords: String(localized: "skip, seek", comment: "Settings search keywords for 'Skip forward / back', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.skipIntervals),
        SettingsSearchEntry(title: String(localized: "Smart rewind"), keywords: ["rewind"], localizedKeywords: String(localized: "rewind", comment: "Settings search keywords for 'Smart rewind', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.smartRewind),
        SettingsSearchEntry(title: String(localized: "Auto-skip intro & outro"), keywords: ["intro", "outro", "skip credits"], localizedKeywords: String(localized: "intro, outro, skip credits", comment: "Settings search keywords for 'Auto-skip intro & outro', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.autoSkipIntroOutro),
        SettingsSearchEntry(title: String(localized: "Skip at chapter start & end"), keywords: ["trim", "chapter intro", "jingle", "skip seconds", "chapter skip"], localizedKeywords: String(localized: "trim, chapter intro, jingle, skip seconds, chapter skip", comment: "Settings search keywords for 'Skip at chapter start & end', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.chapterSkip),
        SettingsSearchEntry(title: String(localized: "Stream on cellular"), keywords: ["cellular", "streaming", "mobile data"], localizedKeywords: String(localized: "cellular, streaming, mobile data", comment: "Settings search keywords for 'Stream on cellular', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.cellularStreaming),
        SettingsSearchEntry(title: String(localized: "Autoplay next"), keywords: ["autoplay", "queue"], localizedKeywords: String(localized: "autoplay, queue", comment: "Settings search keywords for 'Autoplay next', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.autoplayNext),
        SettingsSearchEntry(title: String(localized: "Auto-continue series"), keywords: ["series", "auto-continue", "up next", "autoplay"], localizedKeywords: String(localized: "series, auto-continue, up next, autoplay", comment: "Settings search keywords for 'Auto-continue series', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.autoContinueSeries),
        SettingsSearchEntry(title: String(localized: "Keep screen awake"), keywords: ["screen", "awake", "wake lock"], localizedKeywords: String(localized: "screen, awake, wake lock", comment: "Settings search keywords for 'Keep screen awake', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.keepScreenAwake),
        SettingsSearchEntry(title: String(localized: "Haptics"), keywords: ["haptic", "vibration", "chapter tick"], localizedKeywords: String(localized: "haptic, vibration, chapter tick", comment: "Settings search keywords for 'Haptics', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .playback, row: SettingsRow.haptics),

        // Transcripts (Batch 422)
        SettingsSearchEntry(title: String(localized: "Book transcripts"), keywords: ["transcript", "transcripts", "captions", "speech", "speech to text", "subtitles"], localizedKeywords: String(localized: "transcript, transcripts, captions, speech, speech to text, subtitles", comment: "Settings search keywords for 'Book transcripts', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .transcripts, row: SettingsRow.transcriptsEnabled),
        SettingsSearchEntry(title: String(localized: "Transcribe while charging"), keywords: ["transcribe", "charging", "overnight", "power"], localizedKeywords: String(localized: "transcribe, charging, overnight, power", comment: "Settings search keywords for 'Transcribe while charging', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .transcripts, row: SettingsRow.transcribeWhileCharging),
        SettingsSearchEntry(title: String(localized: "Spoken Links in Recaps"), keywords: ["recap", "previously on", "spoken", "links", "narrator", "voice"], localizedKeywords: String(localized: "recap, previously on, spoken, links, narrator, voice", comment: "Settings search keywords for 'Spoken Links in Recaps', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .transcripts, row: SettingsRow.recapSpokenLinks),
        SettingsSearchEntry(title: String(localized: "Play Recap When Resuming"), keywords: ["recap", "previously on", "resume", "autoplay", "auto play", "narrator"], localizedKeywords: String(localized: "recap, previously on, resume, autoplay, auto play, narrator", comment: "Settings search keywords for 'Play Recap When Resuming', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .transcripts, row: SettingsRow.recapAutoPlay),
        SettingsSearchEntry(title: String(localized: "Transcript language"), keywords: ["transcript language", "language", "locale", "speech language"], localizedKeywords: String(localized: "transcript language, language, locale, speech language", comment: "Settings search keywords for 'Transcript language', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .transcripts, row: SettingsRow.transcriptLanguage),
        SettingsSearchEntry(title: String(localized: "Delete all transcripts"), keywords: ["delete transcripts", "transcript storage", "clear transcripts"], localizedKeywords: String(localized: "delete transcripts, transcript storage, clear transcripts", comment: "Settings search keywords for 'Delete all transcripts', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .transcripts, row: SettingsRow.transcriptStorage),

        // Sleep Timer
        SettingsSearchEntry(title: String(localized: "Sleep timer"), keywords: ["sleep", "timer", "fade"], localizedKeywords: String(localized: "sleep, timer, fade", comment: "Settings search keywords for 'Sleep timer', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sleepTimer, row: SettingsRow.sleepFadeOut),
        SettingsSearchEntry(title: String(localized: "Smart sleep timer"), keywords: ["chapter break", "snap"], localizedKeywords: String(localized: "chapter break, snap", comment: "Settings search keywords for 'Smart sleep timer', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sleepTimer, row: SettingsRow.smartSleepTimer),
        SettingsSearchEntry(title: String(localized: "Scheduled sleep timer"), keywords: ["scheduled", "bedtime", "window"], localizedKeywords: String(localized: "scheduled, bedtime, window", comment: "Settings search keywords for 'Scheduled sleep timer', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sleepTimer, row: SettingsRow.scheduledSleepTimer),
        SettingsSearchEntry(title: String(localized: "Control Centre sleep timer"), keywords: ["control center timer", "control centre"], localizedKeywords: String(localized: "control center timer, control centre", comment: "Settings search keywords for 'Control Center sleep timer', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sleepTimer, row: SettingsRow.controlCenterTimer),
        SettingsSearchEntry(title: String(localized: "Shake gesture"), keywords: ["shake"], localizedKeywords: String(localized: "shake", comment: "Settings search keywords for 'Shake gesture', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sleepTimer, row: SettingsRow.shakeGesture),

        // Sound
        SettingsSearchEntry(title: String(localized: "Volume boost / bass / treble"), keywords: ["volume", "boost", "eq", "equalizer", "bass", "treble", "sound"], localizedKeywords: String(localized: "volume, boost, eq, equalizer, bass, treble, sound", comment: "Settings search keywords for 'Volume boost / bass / treble', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sound, row: SettingsRow.volumeBoost),
        SettingsSearchEntry(title: String(localized: "Ambient Sound"), keywords: ["ambient", "rain", "fireplace", "train", "brown noise", "white noise", "background", "sleep sounds"], localizedKeywords: String(localized: "ambient, rain, fireplace, train, brown noise, white noise, background, sleep sounds", comment: "Settings search keywords for 'Ambient Sound', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sound, row: SettingsRow.ambientSound),
        SettingsSearchEntry(title: String(localized: "Spatial Audio"), keywords: ["spatial", "headphones", "airpods", "beats", "surround", "head tracking", "3d"], localizedKeywords: String(localized: "spatial, headphones, AirPods, Beats, surround, head tracking, 3D", comment: "Settings search keywords for 'Spatial Audio', comma-separated. Keep AirPods and Beats untranslated; translate the other terms and add common synonyms."), page: .sound, row: SettingsRow.spatialAudio),
        SettingsSearchEntry(title: String(localized: "Clearer voices"), keywords: ["dialogue", "voice", "clarity", "speech", "enhance", "voices"], localizedKeywords: String(localized: "dialogue, voice, clarity, speech, enhance", comment: "Settings search keywords for 'Clearer voices', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sound, row: SettingsRow.dialogue),
        SettingsSearchEntry(title: String(localized: "Even volume across books"), keywords: ["loudness", "leveller", "leveler", "normalise", "normalize", "volume", "quiet", "loud", "lufs"], localizedKeywords: String(localized: "loudness, leveller, normalise, volume, quiet, loud", comment: "Settings search keywords for 'Even volume across books', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .sound, row: SettingsRow.dialogue),
        SettingsSearchEntry(title: String(localized: "Reading Sites"), keywords: ["hardcover", "goodreads", "storygraph", "reading", "sync", "csv", "want to read", "rate", "export", "import"], localizedKeywords: String(localized: "hardcover, goodreads, storygraph, reading, sync, csv, want to read, rate, export, import", comment: "Settings search keywords for 'Reading Sites', comma-separated. Keep the site names Hardcover, Goodreads and StoryGraph untranslated; translate the other terms."), page: .readingSites, row: SettingsRow.readingSites),

        // Appearance
        SettingsSearchEntry(title: String(localized: "Theme & accent colour"), keywords: ["theme", "dark mode", "light mode", "accent", "colour", "color"], localizedKeywords: String(localized: "theme, dark mode, light mode, accent, colour, color", comment: "Settings search keywords for 'Theme & accent colour', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .appearance, row: SettingsRow.theme),
        SettingsSearchEntry(title: String(localized: "Household"), keywords: ["household", "family", "share", "invite", "recommend", "book club", "icloud"], localizedKeywords: String(localized: "household, family, share, invite, recommend, book club, icloud", comment: "Settings search keywords for 'Household', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .household, row: SettingsRow.household),
        SettingsSearchEntry(title: String(localized: "Kids"), keywords: ["child", "kids", "children", "profile", "parental", "bedtime", "picker", "family"], localizedKeywords: String(localized: "child, kids, children, profile, parental, bedtime, picker, family", comment: "Settings search keywords for 'Kids', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .household, row: SettingsRow.kids),
        SettingsSearchEntry(title: String(localized: "Share what I’m listening to"), keywords: ["household", "now listening", "share", "presence"], localizedKeywords: String(localized: "household, now listening, share, presence", comment: "Settings search keywords for 'Share what I'm listening to', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .household, row: SettingsRow.householdSharing),
        SettingsSearchEntry(title: String(localized: "Deck skin"), keywords: ["deck", "skin", "walkman", "boombox", "reel", "8-track", "cassette", "button sounds", "click"], localizedKeywords: String(localized: "deck, skin, walkman, boombox, reel, 8-track, cassette, button sounds, click", comment: "Settings search keywords for 'Deck skin', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .appearance, row: SettingsRow.deckSkin),

        // System & Privacy
        SettingsSearchEntry(title: String(localized: "Index in system search"), keywords: ["spotlight", "search index"], localizedKeywords: String(localized: "spotlight, search index", comment: "Settings search keywords for 'Index in system search', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.spotlight),
        SettingsSearchEntry(title: String(localized: "Siri"), keywords: ["siri", "voice", "carplay", "hey siri", "ask siri"], localizedKeywords: String(localized: "siri, voice, carplay, hey siri, ask siri", comment: "Settings search keywords for 'Siri', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.siri),
        SettingsSearchEntry(title: String(localized: "Live Activities"), keywords: ["live activities", "lock screen", "dynamic island", "sleep timer", "download progress"], localizedKeywords: String(localized: "live activities, lock screen, dynamic island, sleep timer, download progress", comment: "Settings search keywords for 'Live Activities', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.liveActivities),
        // Batch 327: the iOS 27 now-playing fallback toggle. The words people will
        // actually reach for here are the *surfaces* ("lock screen", "control center",
        // "dynamic island", "carplay"), not the framework name. Critique 2026-10-06
        // (clarify): left out below iOS 27, where the row doesn't exist (`entries`).
        SettingsSearchEntry(title: classicLockScreenTitle, keywords: ["lock screen", "now playing", "control center", "dynamic island", "carplay", "classic"], localizedKeywords: String(localized: "lock screen, now playing, control center, dynamic island, carplay, classic", comment: "Settings search keywords for 'Classic Lock Screen controls', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.classicNowPlaying),
        SettingsSearchEntry(title: String(localized: "Sync positions with iCloud"), keywords: ["icloud", "cloud", "position sync", "sync positions"], localizedKeywords: String(localized: "icloud, cloud, position sync, sync positions", comment: "Settings search keywords for 'Sync positions with iCloud', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.iCloudPositions),
        SettingsSearchEntry(title: String(localized: "Daily reminder"), keywords: ["reminder", "notification", "daily"], localizedKeywords: String(localized: "reminder, notification, daily", comment: "Settings search keywords for 'Daily reminder', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.dailyReminder),

        // Downloads
        SettingsSearchEntry(title: String(localized: "Auto-download"), keywords: ["auto-download", "auto download", "continue listening"], localizedKeywords: String(localized: "auto-download, auto download, continue listening", comment: "Settings search keywords for 'Auto-download', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.autoDownload),
        SettingsSearchEntry(title: String(localized: "Wi-Fi only downloads"), keywords: ["wifi", "cellular", "download on wifi"], localizedKeywords: String(localized: "wifi, cellular, download on wifi", comment: "Settings search keywords for 'Wi-Fi only downloads', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.wifiOnly),
        SettingsSearchEntry(title: String(localized: "Auto-delete finished"), keywords: ["delete", "finished", "storage"], localizedKeywords: String(localized: "delete, finished, storage", comment: "Settings search keywords for 'Auto-delete finished', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.autoDeleteFinished),
        SettingsSearchEntry(title: String(localized: "Clear image cache"), keywords: ["cache", "storage", "clear"], localizedKeywords: String(localized: "cache, storage, clear", comment: "Settings search keywords for 'Clear image cache', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.imageCache),
        SettingsSearchEntry(title: String(localized: "Download complete notification"), keywords: ["notification", "download complete"], localizedKeywords: String(localized: "notification, download complete", comment: "Settings search keywords for 'Download complete notification', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.notifyDownloadComplete),
        // Stage 3 (REDESIGN_PROPOSAL_2026-08-26.md §2.1): the management half of the
        // old Downloads tab. Critique 2026-10-06 (distill): transfers and the book list
        // live on the Downloads page now; these land on Settings > Downloads' link to it.
        SettingsSearchEntry(title: String(localized: "Active & failed downloads"), keywords: ["downloading", "failed", "retry", "in progress", "downloaded", "offline"], localizedKeywords: String(localized: "downloading, failed, retry, in progress, downloaded, offline", comment: "Settings search keywords for 'Active & failed downloads', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.downloadedBooksLink),
        SettingsSearchEntry(title: String(localized: "Storage used by downloads"), keywords: ["storage", "space", "remove all downloads", "downloaded", "offline"], localizedKeywords: String(localized: "storage, space, remove all downloads, downloaded, offline", comment: "Settings search keywords for 'Storage used by downloads', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.storage),
        // T3 (REVIEW_2026-09-04_UI.md)
        SettingsSearchEntry(title: String(localized: "Downloaded books"), keywords: ["downloaded books", "what's downloaded", "offline books", "on this device", "downloaded", "offline"], localizedKeywords: String(localized: "downloaded books, what's downloaded, offline books, on this device, downloaded, offline", comment: "Settings search keywords for 'Downloaded books', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .downloads, row: SettingsRow.downloadedBooksLink),

        // Diagnostics
        SettingsSearchEntry(title: String(localized: "Positions waiting to sync"), keywords: ["sync now", "pending", "waiting to sync", "unsynced"], localizedKeywords: String(localized: "sync now, pending, waiting to sync, unsynced", comment: "Settings search keywords for 'Positions waiting to sync', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .diagnostics, row: SettingsRow.syncStatus),
        SettingsSearchEntry(title: String(localized: "Server diagnostics"), keywords: ["diagnostics", "server health", "token expiry"], localizedKeywords: String(localized: "diagnostics, server health, token expiry", comment: "Settings search keywords for 'Server diagnostics', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .diagnostics, row: SettingsRow.serverDiagnostics),
        SettingsSearchEntry(title: String(localized: "Download health"), keywords: ["download health", "paused", "repair"], localizedKeywords: String(localized: "download health, paused, repair", comment: "Settings search keywords for 'Download health', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .diagnostics, row: SettingsRow.downloadHealth),
        SettingsSearchEntry(title: String(localized: "Server backups"), keywords: ["backup", "back up", "restore"], localizedKeywords: String(localized: "backup, back up, restore", comment: "Settings search keywords for 'Server backups', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.serverBackups),
        SettingsSearchEntry(title: String(localized: "Library Doctor"), keywords: ["doctor", "duplicates", "missing cover", "series", "chapters", "metadata", "fix"], localizedKeywords: String(localized: "doctor, duplicates, missing cover, series, chapters, metadata, fix", comment: "Settings search keywords for 'Library Doctor', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.libraryDoctor),
        SettingsSearchEntry(title: String(localized: "Upload"), keywords: ["upload", "add book", "import", "epub", "m4b", "audiobook"], localizedKeywords: String(localized: "upload, add book, import, epub, m4b, audiobook", comment: "Settings search keywords for 'Upload', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .account, row: SettingsRow.upload),
        SettingsSearchEntry(title: String(localized: "Release Radar"), keywords: ["release radar", "upcoming", "new releases", "audible", "series", "reminder"], localizedKeywords: String(localized: "release radar, upcoming, new releases, audible, series, reminder", comment: "Settings search keywords for 'Release Radar', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .systemPrivacy, row: SettingsRow.releaseRadar),

        // Critique 2026-10-06 (clarify): Recent Changes is on the Settings root now.
        SettingsSearchEntry(title: String(localized: "Recent Changes"), keywords: ["recent changes", "undo", "history", "playback history", "changed position", "mark finished"], localizedKeywords: String(localized: "recent changes, undo, history, playback history, changed position, mark finished", comment: "Settings search keywords for 'Recent Changes', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .recentChanges),

        // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §7d): these three features live
        // in the Player/Home/Library, not on any Settings page — see `SettingsPage
        // .featuresTips`'s own doc comment for why they route there instead.
        SettingsSearchEntry(title: String(localized: "Driving Mode"), keywords: ["driving", "car", "big buttons"], localizedKeywords: String(localized: "driving, car, big buttons", comment: "Settings search keywords for 'Driving Mode', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .featuresTips, row: SettingsRow.featureDrivingMode),
        SettingsSearchEntry(title: String(localized: "Cassette view"), keywords: ["cassette", "tape", "flip cover"], localizedKeywords: String(localized: "cassette, tape, flip cover", comment: "Settings search keywords for 'Cassette view', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .featuresTips, row: SettingsRow.featureCassette),
        SettingsSearchEntry(title: String(localized: "B-Side"), keywords: ["b-side", "bside", "shuffle", "random book"], localizedKeywords: String(localized: "b-side, bside, shuffle, random book", comment: "Settings search keywords for 'B-Side', comma-separated. Translate each term and add common synonyms; keep commas between terms."), page: .featuresTips, row: SettingsRow.featureBSide),
    ]

    /// Case-insensitive match against each entry's title or any of its keywords. Empty
    /// query returns no results, matching `SettingsView`'s "show search results only
    /// once the user has actually typed something" behavior.
    ///
    /// Critique 2026-10-06 (clarify): the query is trimmed first, so a trailing space from
    /// the keyboard ("sleep ") still matches, and a query of only spaces is empty. Live
    /// state filters conditional rows: pass the number of saved servers.
    static func results(for query: String, savedServerCount: Int = 1) -> [SettingsSearchEntry] {
        results(for: query, in: entries(includesClassicLockScreen: isClassicLockScreenAvailable,
                                        savedServerCount: savedServerCount))
    }

    static func results(for query: String, in entries: [SettingsSearchEntry]) -> [SettingsSearchEntry] {
        let q = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        return entries.filter { entry in
            folded(entry.title).contains(q)
                || entry.keywords.contains { folded($0).contains(q) }
                || entry.localizedKeywords.contains { folded($0).contains(q) }
        }
    }

    /// Polish pass (ST-4): titles now use curly apostrophes, so a query typed with a
    /// straight one (hardware keyboard, Smart Punctuation off) must still match.
    static func folded(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Whether the search box holds a query at all (after trimming) — `SettingsView`
    /// shows results instead of the menu only then.
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
