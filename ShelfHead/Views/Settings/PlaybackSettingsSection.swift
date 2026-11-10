import SwiftUI
import Intents

/// The Playback page's sections: Listening Profile, Playback, Up Next, While Playing.
/// Split out of `SettingsView`'s single giant `playbackAppearancePage` List (UI-12,
/// REVIEW_2026-08-12.md, "Split SettingsView.swift into Views/Settings/") — the
/// Listening Profile picker stays paired with the raw playback toggles/pickers it's a
/// preset shortcut for, rather than becoming its own page.
///
/// Critique 2026-10-06 (distill): this used to be one 14-control "Playback" group that
/// also held Spotlight, Classic Lock Screen and iCloud sync. Those three moved to
/// `SystemPrivacySettingsSection` (below); what's left is grouped by the decision it
/// governs, and "Stream on cellular" moved in from Settings > Downloads. Every binding,
/// key and side effect is unchanged.
struct PlaybackSettingsSection: View {
    @State private var listeningProfileManager = ListeningProfileManager.shared

    @AppStorage(SettingsKeys.defaultPlaybackSpeed) private var defaultPlaybackSpeed: Double = 1.0
    @AppStorage(SettingsKeys.skipForwardInterval) private var skipForwardInterval: Double = 30
    @AppStorage(SettingsKeys.skipBackwardInterval) private var skipBackwardInterval: Double = 15
    @AppStorage(SettingsKeys.smartRewind) private var smartRewind = true
    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(SettingsKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(SettingsKeys.chapterHaptics) private var chapterHaptics = true
    @AppStorage(SettingsKeys.autoplayNext) private var autoplayNext = true
    @AppStorage(SettingsKeys.autoContinueSeries) private var autoContinueSeries = false
    @AppStorage(SettingsKeys.autoSkipIntroOutro) private var autoSkipIntroOutro = false
    @AppStorage(SettingsKeys.chapterSkipStart) private var chapterSkipStart = 0
    @AppStorage(SettingsKeys.chapterSkipEnd) private var chapterSkipEnd = 0
    /// Critique 2026-10-06 (distill): moved from Settings > Downloads — it governs
    /// streaming playback, not downloads. Same key and default as before.
    @AppStorage(SettingsKeys.allowCellularStreaming) private var allowCellularStreaming = true

    private let skipOptions: [Double] = [10, 15, 30, 45, 60]

    var body: some View {
        Group {
            Section {
                ForEach(ListeningProfile.allCases) { profile in
                    Button {
                        Haptics.selection()
                        listeningProfileManager.activate(profile)
                    } label: {
                        HStack {
                            settingRow(profile.icon, .verbatim(profile.label))
                            Spacer()
                            if listeningProfileManager.activeProfile == profile {
                                Image(systemName: "checkmark").foregroundStyle(Color.shelfAmberText)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(listeningProfileManager.activeProfile == profile ? .isSelected : [])
                    .settingsRowAnchor(ifPresent: profile == ListeningProfile.allCases.first ? SettingsRow.listeningProfile : nil)
                }
            } header: {
                RetroSectionHeader(title: "Listening Profile")
            } footer: {
                // Critique 2026-10-06 (distill): one line; the restore note only while a
                // profile is on, where it applies.
                Typo.supporting(Text(listeningProfileManager.activeProfile == .off
                    ? listeningProfileManager.activeProfile.subtitle
                    : String(localized: "\(listeningProfileManager.activeProfile.subtitle). Pick \u{201C}Off\u{201D} to restore your own settings.", comment: "Listening profile footer. %@ is the active profile’s one-line description.")))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)

            Section {
                // P-7/P-8 (REVIEW_2026-09-14_DESIGN.md): `SettingsControlRow` couples
                // icon+title into one `settingRow` label and moves the Picker below it at
                // accessibility sizes; the Picker keeps a real (hidden) label of its own
                // for VoiceOver.
                SettingsControlRow(icon: "gauge.with.needle", title: "Default Speed") {
                    Picker("Default Speed", selection: $defaultPlaybackSpeed) {
                        ForEach(PlaybackSpeed.allCases, id: \.rawValue) { speed in
                            Text(speed.label).tag(speed.rawValue)
                        }
                    }
                    .labelsHidden()
                }
                .settingsRowAnchor(SettingsRow.defaultSpeed)

                SettingsControlRow(icon: "gobackward", title: "Skip Back") {
                    Picker("Skip Back", selection: $skipBackwardInterval) {
                        ForEach(skipOptions, id: \.self) { secs in
                            Text("\(Int(secs)) seconds").tag(secs)
                        }
                    }
                    .labelsHidden()
                }
                .settingsRowAnchor(SettingsRow.skipIntervals)

                SettingsControlRow(icon: "goforward", title: "Skip Forward") {
                    Picker("Skip Forward", selection: $skipForwardInterval) {
                        ForEach(skipOptions, id: \.self) { secs in
                            Text("\(Int(secs)) seconds").tag(secs)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $smartRewind) {
                        settingRow("gobackward", "Smart rewind on resume")
                    }
                    SettingsCaption(text: "Replays a few seconds when you come back.",
                                    topic: "Smart rewind",
                                    detail: "The longer playback was paused, the further back it starts, so you pick up the thread.")
                }
                .settingsRowAnchor(SettingsRow.smartRewind)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $autoSkipIntroOutro) {
                        settingRow("forward.end.fill", "Auto-skip intro & outro")
                    }
                    SettingsCaption(text: chapterSkipStart > 0 || chapterSkipEnd > 0
                                        ? "Not used while chapter trims are set."
                                        : "Skips chapters titled like credits.",
                                    topic: "Auto-skip intro & outro",
                                    detail: chapterSkipStart > 0 || chapterSkipEnd > 0
                                        ? "Title matching isn\u{2019}t used for any book while Skip at Chapter Start or End is set. Turn both back to Off to use it again."
                                        : "Skips chapters that look like publisher intros and outros, such as \u{201C}Opening Credits\u{201D}, \u{201C}Also by this author\u{201D} or copyright pages. Title matching isn\u{2019}t perfect, so check it on a few of your books before leaving it on.")
                }
                .settingsRowAnchor(SettingsRow.autoSkipIntroOutro)

                VStack(alignment: .leading, spacing: 4) {
                    SettingsControlRow(icon: "arrow.right.to.line", title: "Skip at Chapter Start") {
                        Picker("Skip at Chapter Start", selection: $chapterSkipStart) {
                            ForEach(ChapterSkip.options, id: \.self) { secs in
                                Text(ChapterSkip.label(secs)).tag(secs)
                            }
                        }
                        .labelsHidden()
                    }
                    SettingsControlRow(icon: "arrow.right.to.line.compact", title: "Skip at Chapter End") {
                        Picker("Skip at Chapter End", selection: $chapterSkipEnd) {
                            ForEach(ChapterSkip.options, id: \.self) { secs in
                                Text(ChapterSkip.label(secs)).tag(secs)
                            }
                        }
                        .labelsHidden()
                    }
                    SettingsCaption(text: "Trims every chapter. Books can override this from the player\u{2019}s \u{22EF} menu.",
                                    topic: "Chapter trims",
                                    detail: "Jumps forward this many seconds when a chapter starts, and moves on to the next chapter this many seconds before one ends. When either is set it replaces title matching for every book. Choosing a chapter, scrubbing or using next and previous chapter never triggers it.")
                }
                .settingsRowAnchor(SettingsRow.chapterSkip)

                Toggle(isOn: $allowCellularStreaming) {
                    settingRow("antenna.radiowaves.left.and.right", "Stream on cellular")
                }
                .settingsRowAnchor(SettingsRow.cellularStreaming)
            } header: {
                RetroSectionHeader(title: "Playback")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                Toggle(isOn: $autoplayNext) {
                    settingRow("text.line.first.and.arrowtriangle.forward", "Autoplay next in queue")
                }
                .settingsRowAnchor(SettingsRow.autoplayNext)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $autoContinueSeries) {
                        settingRow("books.vertical", "Auto-continue series")
                    }
                    SettingsCaption(text: "Adds the next book in the series.",
                                    topic: "Auto-continue series",
                                    detail: "When Up Next is empty as a book finishes, ShelfHead adds the next unfinished book in that series. It never skips past that one book.")
                }
                .settingsRowAnchor(SettingsRow.autoContinueSeries)
            } header: {
                RetroSectionHeader(title: "Up Next")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                Toggle(isOn: $keepScreenAwake) {
                    settingRow("sun.max.fill", "Keep screen awake while playing")
                }
                .settingsRowAnchor(SettingsRow.keepScreenAwake)

                Toggle(isOn: $hapticsEnabled) {
                    settingRow("hand.tap.fill", "Haptic feedback")
                }
                .settingsRowAnchor(SettingsRow.haptics)

                Toggle(isOn: $chapterHaptics) {
                    settingRow("book.pages", "Haptic tick on chapter change")
                }
            } header: {
                RetroSectionHeader(title: "While Playing")
            }
            .listRowBackground(Color.shelfCard)
        }
        // Moved here from the container page's `.onChange` calls — this is the only
        // section that owns the skip-interval `@AppStorage` keys, so refreshing
        // `AudioPlayerService`'s cached intervals belongs with them, not on a container
        // view that no longer needs to know these keys exist.
        .onChange(of: skipForwardInterval) { _, _ in
            AudioPlayerService.shared.refreshSkipIntervals()
        }
        .onChange(of: skipBackwardInterval) { _, _ in
            AudioPlayerService.shared.refreshSkipIntervals()
        }
    }
}

/// Critique 2026-10-06 (distill): the "System & Privacy" page — what ShelfHead shares
/// with the rest of the system. Spotlight, Classic Lock Screen and iCloud position sync
/// moved here out of the Playback group; the daily listening reminder moved in from
/// Settings > Downloads. App Lock and the stream-token setting stay on Account &
/// Security (that page is owned elsewhere), linked from here rather than moved.
/// Bindings, keys and side effects are unchanged from their old homes.
struct SystemPrivacySettingsSection: View {
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @AppStorage(SettingsKeys.spotlightIndexing) private var spotlightIndexing = true
    @AppStorage(SettingsKeys.liveActivities) private var liveActivities = true
    /// Batch 327. The default comes from `NowPlayingSessionRules.defaultPrefersClassic`
    /// rather than a literal so this and `SettingsStore.registerDefaults()` can't
    /// disagree about the shipping default — that constant is the one place it lives.
    @AppStorage(SettingsKeys.classicNowPlaying) private var classicNowPlaying = NowPlayingSessionRules.defaultPrefersClassic
    @AppStorage(SettingsKeys.cloudPositionSync) private var cloudPositionSync = false
    @AppStorage(SettingsKeys.dailyReminder) private var dailyReminder = false
    @AppStorage(SettingsKeys.dailyReminderHour) private var reminderHour = 19
    @AppStorage(SettingsKeys.dailyReminderMinute) private var reminderMinute = 0

    /// L3 (REVIEW_2026-08-20_UI_SECURITY.md): a denied notification permission used to
    /// snap the reminder toggle back off with no explanation. Moved here with the toggle.
    @State private var showNotificationsDeniedAlert = false

    /// Bridges the stored hour/minute to a DatePicker Date, rescheduling on change.
    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: reminderHour, minute: reminderMinute, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                reminderHour = c.hour ?? 19
                reminderMinute = c.minute ?? 0
                if dailyReminder {
                    NotificationManager.scheduleDailyReminder(hour: reminderHour, minute: reminderMinute)
                }
            }
        )
    }

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $spotlightIndexing) {
                        settingRow("magnifyingglass", "Show books in Spotlight")
                    }
                    .onChange(of: spotlightIndexing) { _, on in
                        // Turning off removes indexed books immediately; turning on lets
                        // the next library load re-index (indexing is gated by this flag).
                        if !on { SpotlightIndexer.removeAll() }
                    }
                    SettingsCaption(text: "Titles and authors only.",
                                    topic: "Spotlight",
                                    detail: "Lets you find a book from iPhone search without opening ShelfHead first. Only titles and authors are indexed, never listening history or account details.")
                }
                .settingsRowAnchor(SettingsRow.spotlight)

                SiriStatusRow()
                    .settingsRowAnchor(SettingsRow.siri)

                // Batch 406: HIG "Live Activities" — let people turn them off in the app.
                // Off ends a running sleep-timer or downloads activity straight away.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $liveActivities) {
                        settingRow("platter.filled.top.iphone", "Live Activities")
                    }
                    .onChange(of: liveActivities) { _, _ in
                        LiveActivityController.shared.refresh()
                    }
                    SettingsCaption(text: "Sleep timer and downloads on the Lock Screen.",
                                    topic: "Live Activities",
                                    detail: "Shows the sleep timer counting down and download progress on the Lock Screen and in the Dynamic Island.")
                }
                .settingsRowAnchor(SettingsRow.liveActivities)

                // Batch 327: iOS 27 only, because below it there is no choice to make —
                // the classic `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` path is
                // the only one that exists, and a toggle that can't change anything is
                // worse than no toggle. Deliberately not wired to anything live: the two
                // backends are mutually exclusive for the whole launch (see
                // `NowPlayingSessionBridge.backend`), so this only takes effect on the
                // next cold start, which the caption says outright.
                if #available(iOS 27, *) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $classicNowPlaying) {
                            settingRow("lock.rectangle", "Classic Lock Screen controls")
                        }
                        SettingsCaption(text: "Takes effect next time ShelfHead opens.",
                                        topic: "Classic Lock Screen controls",
                                        detail: "Uses the pre\u{2011}iOS 27 Now Playing system for the Lock Screen, Control Centre and CarPlay.")
                    }
                    .settingsRowAnchor(SettingsRow.classicNowPlaying)
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Critique 2026-10-06 (harden): no availability gate — the obvious
                    // check, `FileManager.ubiquityIdentityToken`, reports the iCloud Drive
                    // Documents identity (Apple docs), which key-value storage doesn't need,
                    // so it would disable this for users who only turned iCloud Drive off.
                    Toggle(isOn: $cloudPositionSync) {
                        settingRow("icloud", "Sync positions with iCloud")
                    }
                    SettingsCaption(text: "A backup for when your server is down.",
                                    topic: "iCloud position sync",
                                    detail: "Keeps your last position for each book in iCloud, so you can pick up where you left off when your server can\u{2019}t be reached.")
                }
                .settingsRowAnchor(SettingsRow.iCloudPositions)
            } header: {
                RetroSectionHeader(title: "System")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                Toggle(isOn: $dailyReminder) {
                    settingRow("bell.badge.fill", "Daily listening reminder")
                }
                .onChange(of: dailyReminder) { _, on in
                    if on {
                        Task {
                            if await NotificationManager.requestAuthorization() {
                                NotificationManager.scheduleDailyReminder(hour: reminderHour, minute: reminderMinute)
                            } else {
                                // L3: was a silent revert — explained now via the alert
                                // below instead of the toggle just snapping back off.
                                dailyReminder = false
                                showNotificationsDeniedAlert = true
                            }
                        }
                    } else {
                        NotificationManager.cancelDailyReminder()
                    }
                }
                .settingsRowAnchor(SettingsRow.dailyReminder)

                if dailyReminder {
                    DatePicker(selection: reminderTimeBinding, displayedComponents: .hourAndMinute) {
                        settingRow("clock", "Reminder time")
                    }
                }
            } header: {
                RetroSectionHeader(title: "Notifications")
            }
            .listRowBackground(Color.shelfCard)
            .shelfAnimation(.default, value: dailyReminder)
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .alert("Notifications Are Off", isPresented: $showNotificationsDeniedAlert) {
                Button("Open Settings") {
                    // HIG audit 2026-09-17 L4: land directly on the app's Notifications page.
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Notifications are off for ShelfHead. Turn them on in Settings to use this.")
            }
            .systemChromeTint()

            Section {
                // Critique 2026-10-06 (distill): App Lock and the stream-token setting live
                // on Account & Security; a link here so someone looking under privacy
                // finds them, without two copies of the same toggles.
                NavigationLink {
                    AccountSecuritySettingsView(bottomInset: bottomInset)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        settingRow("lock.shield", "App Lock & sign-in security")
                        Typo.supporting(Text("In Account & Security"))
                            .foregroundStyle(Color.shelfMuted)
                            .padding(.leading, 32)
                    }
                    .accessibilityElement(children: .combine)
                }
                .settingsRowAnchor(SettingsRow.securityLink)
            } header: {
                RetroSectionHeader(title: "Privacy")
            }
            .listRowBackground(Color.shelfCard)

            // Batch 442: the one feature that asks an outside service (Audible's catalog).
            ReleaseRadarSettingsSection(libraryItems: libraryViewModel.items)
                .settingsRowAnchor(SettingsRow.releaseRadar)
                .listRowBackground(Color.shelfCard)
        }
    }
}

/// Batch 406 (user request, after the CarPlay Siri fix): Siri only routes "play <book>" to
/// ShelfHead once the user has allowed it (Apple, "Requesting Authorization to Use Siri"),
/// and a "Don't Allow" was otherwise a dead end — the in-app ask never comes back. This
/// row shows the current answer and offers the one action that can change it: ask (not
/// yet asked) or open ShelfHead's page in the Settings app (turned off). Restricted means
/// Screen Time or device management, which the user can't fix from here, so no button.
struct SiriAccess {
    enum Action: Equatable { case request, openSettings, none }

    let status: LocalizedStringResource
    let action: Action
    let caption: LocalizedStringResource

    init(_ authorization: INSiriAuthorizationStatus) {
        switch authorization {
        case .authorized:
            status = "On"
            action = .none
            caption = "Ask Siri to play a book, including from CarPlay."
        case .denied:
            status = "Off"
            action = .openSettings
            caption = "Turn on Siri for ShelfHead in the Settings app to ask Siri to play a book."
        case .restricted:
            status = "Restricted"
            action = .none
            caption = "Siri is restricted on this iPhone by Screen Time or device management."
        case .notDetermined:
            status = "Not set up"
            action = .request
            caption = "Ask Siri to play a book, including from CarPlay."
        @unknown default:
            status = "Unknown"
            action = .openSettings
            caption = "Check Siri for ShelfHead in the Settings app."
        }
    }
}

private struct SiriStatusRow: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization = INPreferences.siriAuthorizationStatus()

    var body: some View {
        let access = SiriAccess(authorization)
        VStack(alignment: .leading, spacing: 4) {
            SettingsControlRow(icon: "mic", title: "Siri") {
                switch access.action {
                case .request:
                    Button("Turn On") {
                        INPreferences.requestSiriAuthorization { status in
                            Task { @MainActor in authorization = status }
                        }
                    }
                case .openSettings:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                case .none:
                    Text(access.status)
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            SettingsCaption(text: access.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(access.status))
        // Coming back from the Settings app is the moment the answer can have changed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization = INPreferences.siriAuthorizationStatus() }
        }
    }
}
