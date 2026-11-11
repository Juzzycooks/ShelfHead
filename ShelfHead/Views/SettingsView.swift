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
    @State private var diagnosticsReport = ""

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
            isInHousehold: HouseholdStore.shared.isInHousehold,
            transcriptsSupported: TranscriptionCenter.shared.isSupportedOS)
        return SettingsSearchIndex.results(for: searchText, state: state)
    }

    /// Batch 490 (REVIEW 2026-11-11 N3): public pages for the About section.
    private static let privacyPolicyURL = URL(string: "https://github.com/Juzzycooks/ShelfHead/blob/main/ShelfHead/AppStore/PRIVACY.md")!
    private static let issuesURL = URL(string: "https://github.com/Juzzycooks/ShelfHead/issues")!
    private static let licenceURL = URL(string: "https://github.com/Juzzycooks/ShelfHead/blob/main/LICENSE")!
    @State private var showsWhatsNew = false

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
                    // Critique 2026-10-06 (distill): "Playback & Appearance" (~30 controls)
                    // is split into five pages, and the root regrouped into three short
                    // groups by what the user is deciding: where the books come from and
                    // live, how they play, and how the app itself behaves. Recent Changes
                    // (an undo log, not a diagnostic) moved here from Diagnostics.
                    //
                    // P-7 (REVIEW_2026-09-14_DESIGN.md) → Critique 2026-10-06 (distill):
                    // the tiles no longer pass an amber `tint`; `menuRow`'s quiet tile is
                    // the default for every row (DESIGN.md, One Light Rule).
                    Section {
                        categoryLink(.account, icon: "person.crop.circle.fill",
                                     subtitle: LocalizedStringResource(stringLiteral: authViewModel.username))  // user data, shown verbatim
                        // Batch 266: one Downloads row (was two look-alike rows). Critique
                        // 2026-10-06 (distill): preferences and storage; the books
                        // themselves are on the Downloads page, linked from there.
                        categoryLink(.downloads, icon: "arrow.down.circle.fill",
                                     subtitle: "Preferences and storage")
                    } header: {
                        RetroSectionHeader(title: "Account & Storage")
                    }
                    .listRowBackground(Color.shelfCard)

                    Section {
                        categoryLink(.playback, icon: "play.circle.fill",
                                     subtitle: "Speed, skips, Up Next")
                        categoryLink(.sleepTimer, icon: "moon.zzz.fill",
                                     subtitle: "Fade, bedtime window, shake")
                        categoryLink(.sound, icon: "speaker.wave.2.fill",
                                     subtitle: "Volume boost, bass, treble")
                        categoryLink(.transcripts, icon: "text.quote",
                                     subtitle: "On-device, search and captions")
                        categoryLink(.readingSites, icon: "books.vertical.fill",
                                     subtitle: "Hardcover, Goodreads, StoryGraph")
                        categoryLink(.household, icon: "person.2.fill",
                                     subtitle: "Recommendations and book clubs")
                        categoryLink(.recentChanges, icon: "arrow.uturn.backward.circle",
                                     subtitle: "Undo a position change")
                    } header: {
                        RetroSectionHeader(title: "Listening")
                    }
                    .listRowBackground(Color.shelfCard)

                    Section {
                        categoryLink(.appearance, icon: "circle.lefthalf.filled",
                                     subtitle: "Theme, accent colour")
                        categoryLink(.systemPrivacy, icon: "lock.shield",
                                     subtitle: "Spotlight, iCloud, reminders")
                        categoryLink(.diagnostics, icon: "stethoscope",
                                     subtitle: "Server and download health")
                        // 16 September 2026: Listening (`StatsView`) is a top-level tab
                        // again, so its Settings-root shortcut row is gone.
                    } header: {
                        RetroSectionHeader(title: "App")
                    }
                    .listRowBackground(Color.shelfCard)

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
                diagnosticsReport = ShelfLog.exportDiagnostics()
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

            ShareLink(item: diagnosticsReport) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 24)
                    Text("Export Diagnostics")
                        .foregroundStyle(Color.shelfCream)
                    Spacer()
                }
            }
            .accessibilityLabel("Export diagnostics")

            // Batch 490 (REVIEW 2026-11-11 N3): where to report a problem, the privacy
            // policy the App Store links to, and the licence. All open in Safari.
            Link(destination: Self.issuesURL) {
                aboutRow("exclamationmark.bubble", "Report a Problem",
                         subtitle: "On GitHub. You can attach the exported diagnostics; they’re redacted.")
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
