import SwiftUI
import UniformTypeIdentifiers

/// Settings root menu — deep-links into the category pages and the inline About section.
///
/// Critique 2026-10-06 (distill): nine category rows in three groups (Account & Storage,
/// Listening, App); "Playback & Appearance" became Playback, Sleep Timer, Sound,
/// Appearance and System & Privacy. Routing goes through `SettingsDestinationView`
/// (`PlaybackAppearanceSettingsView.swift`). The history below predates that split.
///
/// UI-12 (REVIEW_2026-08-12.md, "Split SettingsView.swift into Views/Settings/"): this
/// file used to be 1547 lines containing the root menu plus all 4 category pages plus
/// `ServerDiagnosticsView`/`DownloadHealthView` as extra top-level structs. It's now
/// trimmed to just the root menu — every category page moved to its own file:
///   - `AccountSecuritySettingsView.swift`
///   - `PlaybackAppearanceSettingsView.swift` (+ `PlaybackSettingsSection.swift`,
///     `SleepTimerSettingsSection.swift`, `AudioSettingsSection.swift`,
///     `AppearanceSettingsSection.swift`)
///   - `DownloadsView.swift` (`DownloadsSettingsView` — merged in Batch 266 from
///     this file and the former `DownloadsNotificationsSettingsView.swift`, now
///     deleted, since the two read as accidental duplicates on the root menu)
///   - `DiagnosticsSettingsView.swift`
///   - `Views/Diagnostics/ServerDiagnosticsView.swift`, `DownloadHealthView.swift`
/// Shared row builders (`menuRow`/`settingRow`) moved to `SettingsComponents.swift`;
/// the search index moved to `SettingsSearchIndex.swift`. Navigation structure (which
/// screen is reached from where) is unchanged — every `NavigationLink` here still goes
/// to the exact same content, just now split across files instead of one.
struct SettingsView: View {
    /// Measured mini-player + tab-bar height, passed from ContentView.
    var bottomInset: CGFloat = 0
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Root-menu search — with settings spread across 4 pages, this is the fastest way
    /// back to a specific toggle without remembering which page it lives on. Matches
    /// against `SettingsSearchIndex` (a small static keyword list per entry) rather
    /// than reflecting over `@AppStorage` properties, since several settings are known
    /// by more than one name (e.g. "EQ" for the bass/treble sliders).
    @State private var searchText = ""

    /// "2.2 (5)" read from the bundle rather than hardcoded.
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    // Computed once (in `.task`), not inline in `body` — `ShareLink(item:)` evaluates
    // its `item` argument on every render of the containing view, so calling
    // `ShelfLog.exportDiagnostics()` there directly re-assembled and re-redacted the
    // whole report (including scanning the in-memory log buffer) every time ANY
    // `@AppStorage` toggle anywhere in Settings changed, not just when the user
    // actually taps Export.
    /// Batch 493 (N3): the report being shared; built when the row is tapped.
    @State private var diagnosticsShare: DiagnosticsShare?
    @State private var isBuildingDiagnostics = false

    /// Critique 2026-10-06 (clarify): filtered by live state — "Remove All Servers from
    /// This Device" is only offered when that row is shown (more than one saved server).
    /// Batch 490 (REVIEW 2026-11-11 N3): also hides Upload, Library Doctor, the Household
    /// sharing toggle and the transcript rows when the page they'd open doesn't show them.
    private var searchResults: [SettingsSearchEntry] {
        let user = authViewModel.currentUser
        let state = SettingsSearchEntry.LiveState(
            savedServerCount: authViewModel.accounts.count,
            canUpload: user?.canUpload == true,
            canUpdateLibrary: user?.canUpdateLibrary == true,
            isAdmin: user?.isAdmin == true,
            isInHousehold: HouseholdStore.shared.isInHousehold,
            transcriptsSupported: TranscriptionCenter.shared.isSupportedOS)
        return SettingsSearchIndex.results(for: searchText, state: state)
    }

    /// Batch 490 (REVIEW 2026-11-11 N3): public pages for the About section.
    private static let privacyPolicyURL = URL(string: "https://github.com/Juzzycooks/ShelfHead/blob/main/ShelfHead/AppStore/PRIVACY.md")!
    private static let issuesURL = URL(string: "https://github.com/Juzzycooks/ShelfHead/issues/new")!
    private static let licenceURL = URL(string: "https://github.com/Juzzycooks/ShelfHead/blob/main/LICENSE")!
    @State private var showsWhatsNew = false

    /// Batch 493 (N3): the server's version from `/status`, or nil when it can't be reached.
    private static func fetchServerVersion(rawURL: String) async -> String? {
        guard !rawURL.isEmpty else { return nil }
        let result = await ReachabilityStore.testConnection(rawURL: rawURL)
        return result.serverStatus?.serverVersion
    }

    /// One About row: muted glyph, cream title, optional muted subtitle (IC-3).
    private func aboutRow(_ icon: String, _ title: LocalizedStringResource,
                          subtitle: LocalizedStringResource? = nil) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Color.shelfMuted)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.shelfCream)
                if let subtitle {
                    Typo.supporting(Text(subtitle))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// D5 (design brief 2026-08-12): on iOS 26+, `ContentView`'s `modernTabs` puts
    /// a real `TabView` + `.tabViewBottomAccessory` in charge of the bottom of the
    /// screen, so the collision this originally forced `.navigationBarDrawer`
    /// to avoid (see the comment on `.searchable` below) no longer applies there —
    /// `.automatic` lets iOS 26's floating search field render as intended. Below
    /// iOS 26 (`legacyTabs`, the custom bar), the forced placement is unchanged.
    private var searchPlacement: SearchFieldPlacement {
        if #available(iOS 26.0, *) {
            return .automatic
        }
        return .navigationBarDrawer(displayMode: .always)
    }

    /// Critique 2026-10-06 (distill): one router (`SettingsDestinationView`) for the root
    /// menu and search, so a page can't be reached two different ways.
    private func destination(for page: SettingsPage, focusRow: String? = nil) -> some View {
        SettingsDestinationView(page: page, bottomInset: bottomInset, focusRow: focusRow)
    }

    private func categoryLink(_ page: SettingsPage, icon: String, subtitle: LocalizedStringResource?) -> some View {
        NavigationLink { destination(for: page) } label: {
            menuRow(icon, LocalizedStringResource(stringLiteral: page.title), subtitle: subtitle)
        }
    }

    // MARK: - Root groups (Batch 492, REVIEW 2026-11-11 N2)

    struct RootGroup: Identifiable, Equatable {
        let title: LocalizedStringResource
        let pages: [SettingsPage]
        var id: String { String(localized: title) }
        static func == (lhs: RootGroup, rhs: RootGroup) -> Bool { lhs.pages == rhs.pages && lhs.id == rhs.id }
    }

    /// The Settings root, as data so a test can pin it. No group has more than four rows. Server
    /// Tools is left out for an account that has none of the permissions its rows need.
    static func rootGroups(showsServerTools: Bool) -> [RootGroup] {
        [
            RootGroup(title: "Server",
                      pages: [.account, .downloads] + (showsServerTools ? [.serverTools] : []) + [.kids]),
            RootGroup(title: "Listening", pages: [.playback, .sleepTimer, .sound, .transcripts]),
            RootGroup(title: "Sharing & Services", pages: [.household, .readingSites, .releaseRadar]),
            RootGroup(title: "App", pages: [.appearance, .systemPrivacy, .recentChanges, .diagnostics]),
        ]
    }

    private var showsServerTools: Bool {
        let user = authViewModel.currentUser
        return ServerToolsSettingsSection.isAvailable(canUpdateLibrary: user?.canUpdateLibrary == true,
                                                      canUpload: user?.canUpload == true)
    }

    @ViewBuilder
    private func rootRow(_ page: SettingsPage) -> some View {
        switch page {
        case .account:
            categoryLink(.account, icon: "person.crop.circle.fill",
                         subtitle: LocalizedStringResource(stringLiteral: authViewModel.username))  // user data, shown verbatim
        case .downloads:
            // Batch 266: one Downloads row (was two look-alike rows). Critique 2026-10-06
            // (distill): preferences and storage; the books themselves are on the Downloads
            // page, linked from there.
            categoryLink(.downloads, icon: "arrow.down.circle.fill", subtitle: "Preferences and storage")
        case .serverTools:
            categoryLink(.serverTools, icon: "wrench.and.screwdriver.fill",
                         subtitle: "Backups, Library Doctor, Upload")
        case .kids:
            categoryLink(.kids, icon: "figure.and.child.holdinghands",
                         subtitle: "Child accounts and the profile picker")
        case .playback:
            categoryLink(.playback, icon: "play.circle.fill", subtitle: "Speed, skips, Up Next")
        case .sleepTimer:
            categoryLink(.sleepTimer, icon: "moon.zzz.fill", subtitle: "Fade, bedtime window, shake")
        case .sound:
            categoryLink(.sound, icon: "speaker.wave.2.fill", subtitle: "Volume boost, bass, treble")
        case .transcripts:
            categoryLink(.transcripts, icon: "text.quote", subtitle: "On-device, search and captions")
        case .household:
            categoryLink(.household, icon: "person.2.fill", subtitle: "Recommendations and book clubs")
        case .readingSites:
            categoryLink(.readingSites, icon: "books.vertical.fill", subtitle: "Hardcover, Goodreads, StoryGraph")
        case .releaseRadar:
            categoryLink(.releaseRadar, icon: "calendar.badge.clock", subtitle: "Upcoming books in your series")
        case .appearance:
            categoryLink(.appearance, icon: "circle.lefthalf.filled", subtitle: "Theme, accent colour")
        case .systemPrivacy:
            categoryLink(.systemPrivacy, icon: "lock.shield", subtitle: "Spotlight, iCloud, reminders")
        case .recentChanges:
            categoryLink(.recentChanges, icon: "arrow.uturn.backward.circle", subtitle: "Undo a position change")
        case .diagnostics:
            categoryLink(.diagnostics, icon: "stethoscope", subtitle: "Server and download health")
        case .featuresTips:
            // Not a root row: reached from the About section below.
            EmptyView()
        }
    }

    /// Height reserved so the last row clears the floating mini-player + tab bar.
    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    // MARK: - Root menu

    // Code review fix (26 August 2026): this used to supply its own `NavigationStack`
    // here — the only tab root that did. `HomeView`/`LibraryView` both explicitly
    // document the opposite convention ("NavigationStack is provided by the caller"),
    // and the legacy tab path (`ContentView.legacyTabs`) already respects that,
    // mounting this view bare. But `ContentView.modernTabs` (iOS 26+) wraps it in
    // `NavigationStack(path: $settingsPath) { SettingsView() }` regardless — so on
    // iOS 26 there were two nested stacks. Every `NavigationLink` in this file pushed
    // onto the INNER one (this file's own, now removed), leaving `settingsPath` (the
    // outer one) permanently empty — which meant re-tapping the Settings tab while
    // several pages deep did nothing on iOS 26, unlike every other tab. Removed;
    // `ContentView.modernTabs`'s `NavigationStack(path: $settingsPath)` is now the
    // only stack, on both tab paths.
    var body: some View {
            ZStack {
                Color.shelfBackground
                    .ignoresSafeArea()

                List {
                    // While searching, show only matches (each deep-links straight into
                    // the page that setting lives on) instead of the normal category
                    // menu — searching and browsing are different intents, and mixing
                    // both in one scroll view just makes search results harder to scan.
                    // Critique 2026-10-06 (clarify): a query of only spaces isn't a search.
                    if SettingsSearchIndex.isSearching(searchText) {
                        Section {
                            if searchResults.isEmpty {
                                Text("No settings found for \u{201C}\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.shelfMuted)
                            } else {
                                // Critique 2026-10-06 (clarify): each result opens its page
                                // scrolled to the row it names, highlighted for a moment.
                                ForEach(searchResults) { entry in
                                    NavigationLink(destination: destination(for: entry.page, focusRow: entry.row)) {
                                        // Critique 2026-10-06 (clarify): the page the
                                        // result opens, as its subtitle.
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.title)
                                                .foregroundStyle(Color.shelfCream)
                                            Typo.supporting(Text(entry.page.title))
                                                .foregroundStyle(Color.shelfMuted)
                                        }
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                            }
                        } header: {
                            RetroSectionHeader(title: "Search Results")
                        }
                        .listRowBackground(Color.shelfCard)
                    } else {
                    // Batch 492 (REVIEW 2026-11-11 N2): four groups of at most four rows, by what
                    // the user is deciding (`rootGroups`): the server and who uses it, how books
                    // play, what is shared or looked up elsewhere, and how the app itself behaves.
                    // Earlier history: Critique 2026-10-06 (distill) split "Playback & Appearance"
                    // into five pages; P-7 (REVIEW_2026-09-14_DESIGN.md) → the tiles carry no amber
                    // `tint`, `menuRow`'s quiet tile is the default (DESIGN.md, One Light Rule).
                    ForEach(Self.rootGroups(showsServerTools: showsServerTools)) { group in
                        Section {
                            ForEach(group.pages, id: \.self) { page in
                                rootRow(page)
                            }
                        } header: {
                            RetroSectionHeader(title: group.title)
                        }
                        .listRowBackground(Color.shelfCard)
                    }

                    aboutSection
                    }
                }
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: bottomClearance)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Batch 482: lets the app push a page by value (an accepted household invite opens Household).
            .navigationDestination(for: SettingsPage.self) { destination(for: $0) }
            // iOS 26 changed the default `.searchable` placement to a floating field
            // near the bottom of the screen (its own new "unified search" pattern,
            // e.g. Maps/Photos). Below iOS 26, this app's custom floating mini-player
            // + tab pill (anchored via a `safeAreaInset` one level up in
            // `MainTabView`'s `legacyTabs`) has no way to coordinate with that — the
            // two floating bottom elements collided, with the search field ending up
            // rendered underneath/behind the custom bar instead of reachable, hence
            // `searchPlacement` forcing `.navigationBarDrawer(displayMode: .always)`
            // there (the classic top-of-nav-bar position, matching every other search
            // field in this app — Library, narrator browse). On iOS 26+, `MainTabView`
            // now uses a real `TabView` + `.tabViewBottomAccessory` (`modernTabs`,
            // D5), which the system DOES know how to coordinate with, so
            // `searchPlacement` reverts to `.automatic` there instead.
            .searchable(text: $searchText, placement: searchPlacement, prompt: "Search Settings")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Critique 2026-10-06 (typeset): was a bare system(size: 18); nearest
                    // existing role is `cardTitle` (17 semibold rounded, .headline-relative).
                    Typo.cardTitle(Text("Settings"))
                        .foregroundStyle(Color.shelfCream)
                }
            }
            .task {
                await authViewModel.loadAccounts()
            }
            .reexpandsTabBarOnAppear()
    }

    // MARK: - About (inline on the root menu)

    private var aboutSection: some View {
        Section {
            // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10, §7c): the "cheap half" of
            // this app's discoverability answer — see `FeaturesTipsView`'s own doc
            // comment.
            NavigationLink { destination(for: .featuresTips) } label: {
                HStack {
                    // IC-3 (docs/visual-design-review.md, Round V1): every About row is
                    // `shelfMuted`, so none reads as an unexplained "active" icon.
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 24)
                    Text("Features & Tips")
                        .foregroundStyle(Color.shelfCream)
                }
            }

            // Redacted diagnostics (app/OS/server versions + recent redacted
            // log lines). Never contains tokens, passwords, or audio.
            // Batch 490 (REVIEW 2026-11-11 N3): this release's notes, on demand.
            Button {
                showsWhatsNew = true
            } label: {
                aboutRow("gift", "What’s New")
            }
            .sheet(isPresented: $showsWhatsNew) {
                WhatsNewSheet()
            }

            // Batch 493 (N3): the short, redacted `FeedbackDiagnostics` report, not the raw log.
            // Built on tap, so the one `/status` request for the server version is made only
            // when the listener asks to share, not every time Settings opens.
            Button {
                guard !isBuildingDiagnostics else { return }
                isBuildingDiagnostics = true
                Task {
                    let serverURL = authViewModel.serverURL
                    let serverVersion = await Self.fetchServerVersion(rawURL: serverURL)
                    diagnosticsShare = DiagnosticsShare(text: FeedbackDiagnostics.report(serverVersion: serverVersion,
                                                                                        serverURL: serverURL))
                    isBuildingDiagnostics = false
                }
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 24)
                    Text("Share Diagnostics")
                        .foregroundStyle(Color.shelfCream)
                    Spacer()
                    if isBuildingDiagnostics { ProgressView() }
                }
            }
            .accessibilityLabel("Share diagnostics")
            .sheet(item: $diagnosticsShare) { share in
                ActivityView(items: [share.text])
            }

            // Batch 490 (REVIEW 2026-11-11 N3): where to report a problem, the privacy
            // policy the App Store links to, and the licence. All open in Safari.
            Link(destination: Self.issuesURL) {
                HStack {
                    aboutRow("exclamationmark.bubble", "Send Feedback",
                             subtitle: "Opens a GitHub issue. Share Diagnostics first if you want to paste a report; it leaves out your server address.")
                    Image(systemName: "arrow.up.right")
                        .scaledFont(13, relativeTo: .footnote)
                        .foregroundStyle(Color.shelfMuted)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint("Opens in Safari")
            Link(destination: Self.privacyPolicyURL) {
                aboutRow("hand.raised", "Privacy Policy")
            }
            .accessibilityHint("Opens in Safari")
            Link(destination: Self.licenceURL) {
                aboutRow("doc.text", "Licence", subtitle: "Open source under the MIT Licence")
            }
            .accessibilityHint("Opens in Safari")

            // ASO pass (AppStoreListing.md, 14 Sep 2026): only rendered once
            // `ReviewPromptManager.appStoreID` is filled in from App Store Connect —
            // `writeReviewURL` returns `nil` for the placeholder `nil` ID, so a
            // dead/placeholder link can never ship.
            if let url = ReviewPromptManager.writeReviewURL(appStoreID: ReviewPromptManager.appStoreID) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "star")
                            .foregroundStyle(Color.shelfMuted)
                            .frame(width: 24)
                        Text("Rate ShelfHead")
                            .foregroundStyle(Color.shelfCream)
                        Spacer()
                    }
                }
                .accessibilityLabel("Rate ShelfHead on the App Store")
            }
        } header: {
            RetroSectionHeader(title: "About")
        } footer: {
            // Critique 2026-10-06 (distill): the Version and "ShelfHead for
            // Audiobookshelf" rows were two non-interactive rows (one with a decorative
            // amber glyph); one footer line says both.
            Typo.supporting(Text("ShelfHead for Audiobookshelf \u{00B7} Version \(Self.appVersion)"))
                .foregroundStyle(Color.shelfMuted)
                .textSelection(.enabled)
        }
        .listRowBackground(Color.shelfCard)
    }
}

#Preview {
    SettingsView()
        .environment(AuthViewModel())
        .environment(PlayerViewModel())
}

// MARK: - Feedback diagnostics (Batch 493, REVIEW 2026-11-11 N3)

/// The plain-text report behind About › Share Diagnostics. It is short on purpose: the app and
/// iOS versions, the device model, the server version and a handful of setting states. It has no
/// log lines, no account or server details beyond the version, and every value is passed through
/// `ShelfLog.redact` and has any host replaced by "your server", so it is safe to paste into a
/// public GitHub issue. Pure and parameterised, so a test can pin it.
enum FeedbackDiagnostics {
    /// The setting states included, as (label, defaults key). Booleans print On/Off, a missing
    /// value prints "default".
    static let settingKeys: [(String, String)] = [
        ("Wi-Fi only downloads", SettingsKeys.wifiOnlyDownloads),
        ("Download while charging", SettingsKeys.downloadWhileCharging),
        ("Auto-download Continue Listening", SettingsKeys.autoDownloadContinueListening),
        ("Auto-delete finished", SettingsKeys.autoDeleteFinished),
        ("Stream on cellular", SettingsKeys.allowCellularStreaming),
        ("Token in stream URL", SettingsKeys.streamWithURLToken),
        ("Stay signed in (password stored)", SettingsKeys.storePassword),
        ("Smart rewind", SettingsKeys.smartRewind),
        ("Autoplay next", SettingsKeys.autoplayNext),
        ("Auto-continue series", SettingsKeys.autoContinueSeries),
        ("Transcripts", SettingsKeys.transcriptsEnabled),
        ("Live Activities", SettingsKeys.liveActivities),
        ("Spotlight indexing", SettingsKeys.spotlightIndexing),
        ("Default speed", SettingsKeys.defaultPlaybackSpeed),
    ]

    /// Replaces any `http(s)://host[:port]` and the given server's bare host with "your server".
    static func scrubHosts(_ input: String, serverURL: String) -> String {
        var result = input
        if let regex = try? NSRegularExpression(pattern: #"https?://[^/\s"']+"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "your server")
        }
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let url = URL(string: candidate), let host = url.host, !host.isEmpty {
            if let port = url.port {
                result = result.replacingOccurrences(of: "\(host):\(port)", with: "your server")
            }
            result = result.replacingOccurrences(of: host, with: "your server")
        }
        return result
    }

    /// "iPhone16,2" style identifier; the simulator reports its host model, which is fine.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func stateText(_ value: Any?) -> String {
        switch value {
        case let number as NSNumber:
            // UserDefaults hands booleans back as NSNumber; 1.0 must not read as "On".
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "On" : "Off" }
            return number.stringValue
        case let text as String: return text
        default: return "default"
        }
    }

    /// Builds the report. `settings` is (label, value text) pairs; pass `currentSettings()` live.
    static func report(appVersion: String, build: String, osVersion: String, deviceModel: String,
                       serverVersion: String?, serverURL: String, settings: [(String, String)],
                       now: Date = Date()) -> String {
        var lines = [
            "ShelfHead feedback diagnostics",
            "App: \(appVersion) (\(build))",
            "iOS: \(osVersion)",
            "Device: \(deviceModel)",
            "Audiobookshelf server: \(serverVersion ?? "unknown")",
            "Generated: \(ISO8601DateFormatter().string(from: now))",
            "",
            "Settings:",
        ]
        lines += settings.map { "\($0.0): \($0.1)" }
        lines += ["", "Left out on purpose: your server address, account, tokens and passwords, and the app log."]
        return scrubHosts(ShelfLog.redact(lines.joined(separator: "\n")), serverURL: serverURL)
    }

    static func currentSettings(_ defaults: UserDefaults = .standard) -> [(String, String)] {
        settingKeys.map { ($0.0, stateText(defaults.object(forKey: $0.1))) }
    }

    /// The live report for this device.
    static func report(serverVersion: String?, serverURL: String) -> String {
        let info = Bundle.main.infoDictionary
        return report(appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
                      build: info?["CFBundleVersion"] as? String ?? "?",
                      osVersion: UIDevice.current.systemVersion,
                      deviceModel: deviceModel,
                      serverVersion: serverVersion, serverURL: serverURL,
                      settings: currentSettings())
    }
}

/// Batch 493 (N3): a built diagnostics report waiting for the share sheet.
struct DiagnosticsShare: Identifiable {
    let id = UUID()
    let text: String
}
