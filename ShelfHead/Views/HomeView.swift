import SwiftUI

struct HomeView: View {
    /// Clearance for the mini-player + tab bar, measured by ContentView.
    var bottomInset: CGFloat = 0
    /// D5 follow-up (design brief 2026-08-12): bumped by `ContentView`'s
    /// `modernTabs` (the iOS 26 `TabView` path) when Home's tab icon is
    /// re-tapped while already selected — scrolls back to the top of this
    /// screen. Unused by the legacy path, which already gets this for free
    /// (its `homeReset`-driven `.id()` bump fully remounts the view). Defaults
    /// to 0 so omitting it (as the legacy path does) is harmless.
    var scrollToTopSignal: Int = 0
    /// Stable anchor for the scroll-to-top above — sits at the very top of the
    /// scrollable content (see `headerView`'s `.id()` below).
    private static let topAnchorID = "home-top"
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Batch 218 (R10.8): lets `nowZoneEmptyState`'s "Browse Library" action switch
    /// tabs in-process instead of round-tripping through the `shelfhead://library`
    /// URL scheme — see `TabRouter`'s own doc comment in `ContentView.swift`.
    @Environment(TabRouter.self) private var tabRouter
    /// Multi-server "Other Servers" shelf: needs the signed-in account's id to exclude
    /// it from the other-accounts fetch and to detect a successful `switchAccount`.
    @Environment(AuthViewModel.self) private var authViewModel
    // NEW-15 (follow-up review, 14 Aug 2026): the scroll-to-top `withAnimation`
    // below was the only unguarded `withAnimation` call in the whole Views
    // directory — every other animated transition in the app routes through
    // either `reduceMotion ? nil : ...` or the custom `shelfAnimation(_:value:)`
    // wrapper specifically so Reduce Motion suppresses it too.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Critique 2026-10-05 (Home): "Show Downloads" in the load-failure state routes through
    /// the existing `shelfhead://downloads` deep link (handled by `MainTabView`).
    @Environment(\.openURL) private var openURL
    @State private var downloadManager = DownloadManager.shared
    @State private var otherServersStore = OtherServersStore.shared
    // Review 3 Low (Home kid hide): observe the kid-profile key so marking the account as a kid re-renders.
    @AppStorage(KidProfileStore.storageKey) private var kidProfilesData = Data()
    private var isKidAccount: Bool {
        _ = kidProfilesData
        return KidProfileStore.standard.isKid(AccountStore.currentAccountId)
    }
    @State private var hiddenSections: Set<String> = SettingsStore.hiddenHomeSections
    @State private var sectionOrder: [String] = SettingsStore.homeSectionOrder
    @State private var showCustomize = false
    @State private var weekStats: ListeningStatistics?
    @State private var isLoadingWeekStats = false
    @State private var loadingWeekScope: String?
    /// P3-2 (third-pass review, 14 Aug 2026): guards `reconcileBrowseSectionsIfNeeded()`
    /// below — see that function's doc comment for the ordering bug this closes.
    @State private var hasCompletedInitialLoad = false
    /// Polish pass (J3-1): whether the loaded book's live position is past the finished
    /// threshold; nil while the player has no duration. Written only by `NowZoneFinishedProbe`.
    @State private var playerReachedFinish: Bool?
    /// N-6 (REVIEW_2026-09-14_DESIGN.md): per-filter match counts for the Smart Filters
    /// shelf, or empty when they aren't free — see
    /// `LibraryViewModel.cachedSmartFilterCounts()` for the rule (they are read off the
    /// bulk snapshot only if one is already in memory; this screen never triggers the
    /// whole-library fetch that would build one). Held in `@State` and recomputed only
    /// when something relevant changed, because that call is O(filters × library) and
    /// must not sit on a `body` path.
    @State private var smartFilterCounts: [SmartFilter: Int] = [:]
    /// Batch 490 (REVIEW 2026-11-11 E4): observed, not read once from `SettingsStore`, so turning
    /// Release Radar on in Settings mounts the shelf as soon as the first check finds something.
    @AppStorage(SettingsKeys.releaseRadarEnabled) private var releaseRadarEnabled = false
    /// Batch 490 (REVIEW 2026-11-11 E5): the empty-library state's Upload Books.
    @State private var showUploadSheet = false
    /// Batch 490 (REVIEW 2026-11-11 V6): hosts Release Radar's Undo toast (see `.toast` in `body`).
    @State private var releaseRadar = ReleaseRadarViewModel.shared
    /// Batch 496 (REVIEW 2026-11-11 N5): the profile picker, mid-session, as a full-screen cover.
    @State private var showProfilePicker = false
    /// Batch 496 (N5): the picker is never shown over App Lock (see `.fullScreenCover` in `body`).
    @State private var appLock = AppLockManager.shared
    @Environment(\.scenePhase) private var scenePhase
    private var hasAnyKidProfile: Bool {
        _ = kidProfilesData
        return KidProfileStore.standard.hasAnyKid
    }
    private var showsProfileButton: Bool {
        HomeState.showsProfileButton(savedAccountCount: authViewModel.accounts.count,
                                     hasAnyKid: hasAnyKidProfile,
                                     isAppLocked: appLock.isLocked)
    }

    /// Stable identity for a shelf so hide/show survives relaunches.
    private func shelfKey(_ shelf: PersonalizedView) -> String {
        shelf.labelStringKey
    }

    /// Calmer, audiobook-native section titles; falls back to the server label.
    private func shelfTitle(_ shelf: PersonalizedView) -> String {
        switch shelf.labelStringKey {
        case "LabelContinueListening": return String(localized: "Continue Listening", comment: "Home shelf title")
        case "LabelContinueSeries":    return String(localized: "Next in Series", comment: "Home shelf title")
        case "LabelRecentlyAdded":     return String(localized: "Recently Added", comment: "Home shelf title")
        case "LabelDiscover":          return String(localized: "Discover", comment: "Home shelf title")
        case "LabelListenAgain":       return String(localized: "Listen Again", comment: "Home shelf title")
        default:                       return shelf.label // server-supplied label, shown verbatim
        }
    }

    /// Stable key for the narrator-favourites shelf — not server-driven (unlike the
    /// personalized shelves below), so it needs its own fixed key rather than one
    /// derived from a `PersonalizedView`. Not `private`: `SettingsStore
    /// `SettingsMigrator` step 1 (D2, design brief 2026-08-12) references this
    /// directly so its default-hidden list can't silently drift out of sync with the
    /// literal string this file actually uses.
    static let narratorShelfKey = "narratorFavorites"

    /// Stable key for the downloaded/offline shelf — also not server-driven.
    static let downloadedShelfKey = "downloadedOffline"

    /// Stable key for the "Your Week" stats card — also not server-driven, and
    /// previously had no key at all (so it couldn't be hidden or reordered).
    static let weekStatsKey = "yourWeek"

    /// Stable key for the "On Other Servers" shelf — also not server-driven; backed by
    /// `OtherServersStore`, not `libraryViewModel.personalizedShelves`.
    static let otherServersKey = "otherServers"

    /// Batch 442: "Release Radar" — later books in your series from Audible's public catalog.
    /// Opt-in (Settings), so it's on the default-visible allowlist: turning it on should show it.
    static let releaseRadarKey = "releaseRadar"
    /// Batch 454: household members' listening and recommendations. Offered only while in a household.
    static let householdKey = "household"

    /// Design review (14 Aug 2026), item 3: a real, labelled home for "B-side" — also
    /// not server-driven. Previously only reachable via an unlabelled `shuffle` glyph
    /// in `LibraryView`'s nav bar, which most people would read as "shuffle the list
    /// order," not "play a random unstarted book." Given a row here too, alongside the
    /// matching button added to `LibraryView`'s empty state.
    static let bSideKey = "bSideShuffle"

    /// N-6 (REVIEW_2026-09-14_DESIGN.md): stable key for the Smart Filters shelf — also
    /// not server-driven. Referenced directly by `SettingsStore`'s Home-shelf seed
    /// (step 1) for the same reason `narratorShelfKey` is referenced by
    /// `SettingsMigrator`'s step 1: the seed's list can't silently drift out of sync
    /// with the literal string this file actually renders against.
    static let smartFiltersKey = "smartFilters"

    /// N-6: the shelf keys the Smart Filters shelf is seeded to sit *after* — the two
    /// "carry on with what you were doing" shelves. Ordered least- to most-preferred
    /// anchor; `SettingsStore.seededHomeOrder(saved:inserting:after:)` takes the latest
    /// position any of them occupies, so a user who has dragged Next in Series above
    /// Continue Listening still ends up with this shelf below both.
    ///
    /// Used twice, deliberately through the same function: once by the one-time seed
    /// (which places the key in an account's *saved* order) and once by
    /// `availableSectionKeys` below (which places it in the app's *default* order, for
    /// an account that has no saved order to merge against).
    static let smartFiltersOrderAnchors = ["LabelContinueListening", "LabelContinueSeries"]

    /// Design review (14 Aug 2026), item 3: whether there's anything for B-side to pick
    /// from — same check as `LibraryView.hasUnstartedBooks`, against the full library.
    private var hasUnstartedBooks: Bool {
        libraryViewModel.items.contains { libraryViewModel.progressFor(itemId: $0.id) == nil }
    }

    /// D2 (design brief 2026-08-12): Home is explicitly two zones now — NOW (the
    /// Continue Listening hero + Up Next, always first, never below the fold) and
    /// BROWSE (everything else, capped to a handful of shelves by default — see
    /// `SettingsMigrator`'s step 1). This purely affects rendering
    /// (grouping + the "Browse" divider below); it doesn't change what's hideable or
    /// reorderable — `HomeCustomizeSheet` still works exactly as it did.
    private enum SectionTier { case now, browse }
    private func tier(for key: String) -> SectionTier {
        switch key {
        case "LabelContinueListening": return .now
        default: return .browse
        }
    }

    /// D2 follow-up (structural cap, 14 Aug 2026): the small set of BROWSE-tier keys
    /// that stay visible by default whenever this account (or a future shelf type) has
    /// never been decided about before — see `SettingsStore.reconcileNewHomeBrowseSections`.
    /// Matches the three sections `SettingsMigrator`'s step 1 already leaves visible
    /// for a brand-new install.
    /// Design review (14 Aug 2026), item 3: `bSideKey` added to this allowlist too —
    /// without it, the D2 structural-cap fix (Batch 180) would treat B-side as just
    /// another newly-appeared BROWSE key and default it to hidden the first time it
    /// shows up for an existing account, silently undoing the point of giving it a
    /// real home here.
    /// N-6 (REVIEW_2026-09-14_DESIGN.md) then Batch 320: `smartFiltersKey` was briefly on
    /// this allowlist so the structural cap wouldn't hide the shelf the seed had just
    /// shown. The user decided on device that Smart Filters should ship HIDDEN, so the
    /// key is deliberately NOT listed here — the cap's hidden-by-default behaviour is now
    /// the wanted one, and `SettingsStore`'s seed step 2 hides it for installs that had
    /// already run step 1. It stays available in Customize Home.
    /// `otherServersKey` added for the same reason `bSideKey` is on this list: without
    /// it, `SettingsStore.reconcileNewHomeBrowseSections` would treat it as just another
    /// newly-appeared BROWSE key on every existing install (this key has never existed
    /// before) and silently default it to hidden the first time it has anything to show.
    static let defaultVisibleBrowseKeys: Set<String> = ["LabelContinueSeries", "LabelRecentlyAdded", downloadedShelfKey, bSideKey, otherServersKey, releaseRadarKey, householdKey]

    /// Critique 2026-10-05 (Home): the key of the pinned NOW-zone shelf. It is no longer
    /// hideable (it was pinned first anyway, and hiding it produced a false "Nothing in
    /// progress" state), so it is filtered out of Customise Home and any persisted hidden
    /// value for it is ignored and cleared.
    private static let continueListeningKey = "LabelContinueListening"

    /// Critique 2026-10-05 (Home): downloaded books as candidates for the offline hero.
    private var downloadHeroCandidates: [HomeState.DownloadCandidate] {
        downloadManager.downloadedLibraryItems().map {
            HomeState.DownloadCandidate(id: $0.id,
                                        progress: $0.mediaProgress?.progress ?? 0,
                                        lastUpdate: $0.mediaProgress?.lastUpdate)
        }
    }

    /// Critique 2026-10-05 (Home): the books the NOW zone renders. Normally the server's
    /// Continue Listening shelf; when that is absent (it is not persisted, so an offline
    /// or unreachable cold launch never has it) falls back to the restored/last-played
    /// book the mini player is already showing, else the most recently played download.
    private var nowZoneItems: [LibraryItem] {
        let serverItems: [LibraryItem] = libraryViewModel.personalizedShelves
            .first(where: { shelfKey($0) == Self.continueListeningKey })?.entities ?? []
        let current = playerViewModel.currentBook
        // Polish pass (J3-1): this used to read `playerViewModel.currentTime` (and `duration`)
        // here, and it's evaluated three times in `body`, so the whole of Home invalidated at
        // the playback tick (~2 Hz). `heroChoice` only asks "is it past the finished
        // threshold?", so `NowZoneFinishedProbe` (a tiny child view that does the per-tick read)
        // writes that one flag into `playerReachedFinish` and Home re-renders only when it flips.
        var currentProgress: Double?
        if current != nil {
            if let reachedFinish = playerReachedFinish {
                currentProgress = reachedFinish ? 1 : 0
            } else if let id = current?.id {
                currentProgress = libraryViewModel.progressFor(itemId: id)?.progress
            }
        }
        switch HomeState.heroChoice(serverHasItems: !serverItems.isEmpty,
                                    currentBookID: current?.id,
                                    currentBookProgress: currentProgress,
                                    downloads: downloadHeroCandidates) {
        case .server: return serverItems
        case .currentBook:
            // Critique 2026-10-05 (Home, 2nd): the loaded, unfinished book leads even when
            // the server shelf is non-empty (it may have been started elsewhere since the
            // shelf last loaded). Prefer the shelf's copy of it (it carries server
            // progress); the rest of the shelf follows without duplicating it.
            guard let current else { return serverItems }
            let lead = serverItems.first(where: { $0.id == current.id }) ?? current
            return [lead] + serverItems.filter { $0.id != lead.id }
        case .downloaded(let id): return downloadManager.downloadedLibraryItems().filter { $0.id == id }
        case .none: return []
        }
    }

    /// Every section key currently available to show, in the app's own default order
    /// (server shelf order, Continue Listening included, then Downloaded, Narrators,
    /// Your Week) — this is the *default* order before the user's saved customisation
    /// is merged in, and also the full set `orderedSectionKeys` filters/reorders from.
    private var availableSectionKeys: [String] {
        var out: [String] = []
        for shelf in libraryViewModel.personalizedShelves {
            guard shelf.isBookShelf, let entities = shelf.entities, !entities.isEmpty else { continue }
            let key = shelfKey(shelf)
            if !out.contains(key) { out.append(key) }
        }
        if !downloadManager.downloadedItems.isEmpty {
            out.append(Self.downloadedShelfKey)
        }
        if !libraryViewModel.favoriteNarratorItems.isEmpty {
            out.append(Self.narratorShelfKey)
        }
        if weekStats?.hasEnough == true {
            out.append(Self.weekStatsKey)
        }
        if hasUnstartedBooks {
            out.append(Self.bSideKey)
        }
        if !isKidAccount,   // Review 2 Medium 11
           !otherServersStore.mergedItems.isEmpty || otherServersStore.shelves.contains(where: { $0.state == .needsSignIn }) {
            out.append(Self.otherServersKey)
        }
        if releaseRadarEnabled && !ReleaseRadarViewModel.shared.entries.isEmpty {
            out.append(Self.releaseRadarKey)
        }
        if HouseholdStore.shared.isSocialAvailable {   // Batch 482: not on a kid profile
            out.append(Self.householdKey)
        }
        // N-6 (REVIEW_2026-09-14_DESIGN.md): available whenever there's a library to
        // filter — the eight smart filters are client-side and don't depend on any
        // particular shelf having loaded. Placed through the same pure function the
        // one-time seed uses (see `smartFiltersOrderAnchors`) rather than appended like
        // the four above, because `mergedHomeSectionOrder` appends *newly available*
        // keys at the end: for an account with no saved order at all, this default order
        // is the only thing deciding where the shelf sits, and the end of BROWSE is not
        // where it belongs.
        if libraryViewModel.selectedLibrary != nil {
            out = SettingsStore.seededHomeOrder(saved: out, inserting: Self.smartFiltersKey,
                                                after: Self.smartFiltersOrderAnchors)
        }
        return out
    }

    /// P3-2 (third-pass review, 14 Aug 2026): the actual reconcile call, split out of
    /// `.onChange(of: availableSectionKeys)` so `body`'s `.task` can also call it once,
    /// directly, after every startup load has landed — see both call sites' own
    /// comments. `SettingsStore.reconcileNewHomeBrowseSections`'s one-time migration
    /// branch (the part that grandfathers in an existing account's current state
    /// without hiding anything) only gets ONE real chance to run correctly: whichever
    /// call happens to be first after this account's `homeBrowseSeenMigrated` flag is
    /// still unset. Calling it against a partial `availableKeys` — which is exactly
    /// what happened when this ran from `.onChange` after each of `loadLibraries()` /
    /// `loadFavoriteNarratorItems()` / `loadWeekStats()` individually, since each
    /// completion changes the computed property and re-fires `.onChange` on its own —
    /// meant the migration used whatever had loaded *first* as "everything," and every
    /// shelf that loaded afterward looked new and got silently, permanently hidden.
    private func reconcileBrowseSectionsIfNeeded(availableKeys: [String]) {
        let browseKeys = availableKeys.filter { tier(for: $0) == .browse }
        let newlyHidden = SettingsStore.reconcileNewHomeBrowseSections(
            browseKeys: browseKeys, alwaysVisible: Self.defaultVisibleBrowseKeys
        )
        if !newlyHidden.isEmpty {
            hiddenSections.formUnion(newlyHidden)
        }
    }

    /// `availableSectionKeys`, reordered per the user's saved drag-to-reorder choice
    /// (see `HomeCustomizeSheet`) — this is what `body` actually iterates over. Uses the
    /// local `sectionOrder` `@State` (kept in sync with the sheet's edits) rather than
    /// re-reading `UserDefaults` on every render, same pattern as `hiddenSections`.
    private var orderedSectionKeys: [String] {
        SettingsStore.mergedHomeSectionOrder(saved: sectionOrder, available: availableSectionKeys)
    }

    /// Display title for any section key, server-driven or fixed.
    private func sectionTitle(for key: String) -> String {
        switch key {
        case Self.downloadedShelfKey: return String(localized: "Downloaded", comment: "Home shelf title: books saved on this device")
        case Self.narratorShelfKey: return String(localized: "From Narrators You Follow", comment: "Home shelf title")
        case Self.weekStatsKey: return String(localized: "Your Week", comment: "Home shelf title: this week's listening stats")
        case Self.bSideKey: return String(localized: "B-Side", comment: "Home shelf title: random unstarted book shuffle")
        case Self.otherServersKey: return String(localized: "On Other Servers", comment: "Home shelf title: books on the user's other saved servers")
        case Self.releaseRadarKey: return String(localized: "Release Radar", comment: "Home shelf title: upcoming books in the user's series")
        case Self.householdKey: return String(localized: "Household", comment: "Home shelf title: what household members are listening to and recommend")
        case Self.smartFiltersKey: return String(localized: "Smart Filters", comment: "Home shelf title")
        default:
            if let shelf = libraryViewModel.personalizedShelves.first(where: { shelfKey($0) == key }) {
                return shelfTitle(shelf)
            }
            return key
        }
    }

    /// The sections the user can toggle/reorder in `HomeCustomizeSheet`, already in
    /// their current display order.
    private var customizableSections: [(key: String, title: String)] {
        // Critique 2026-10-05 (Home): Continue Listening is pinned, not customisable.
        orderedSectionKeys.filter { $0 != Self.continueListeningKey }.map { ($0, sectionTitle(for: $0)) }
    }

    /// Renders whichever section `key` refers to, or nothing if that section's backing
    /// content has since disappeared (e.g. the last download was deleted) — callers
    /// don't need to re-check presence themselves.
    @ViewBuilder
    private func sectionView(for key: String) -> some View {
        if key == Self.downloadedShelfKey {
            if !downloadManager.downloadedItems.isEmpty {
                // Batch 496 (REVIEW 2026-11-11 N4): capped at a dozen tiles; See all opens Downloads.
                CompactShelfRow(title: String(localized: "Downloaded", comment: "Home shelf title: books saved on this device"),
                                items: HomeState.capped(downloadManager.downloadedLibraryItems(), to: HomeState.downloadedTileCap),
                                seeAll: HomeState.seeAllDestination(forSectionKey: key),
                                bottomInset: bottomInset)
            }
        } else if key == Self.narratorShelfKey {
            if !libraryViewModel.favoriteNarratorItems.isEmpty {
                // Batch 497 (N4): See all opens the Narrators list (starred first).
                CompactShelfRow(title: String(localized: "From Narrators You Follow", comment: "Home shelf title"), items: libraryViewModel.favoriteNarratorItems,
                                seeAll: HomeState.seeAllDestination(forSectionKey: key),
                                bottomInset: bottomInset)
            }
        } else if key == Self.smartFiltersKey {
            if libraryViewModel.selectedLibrary != nil {
                SmartFiltersShelf(counts: smartFilterCounts)
            }
        } else if key == Self.bSideKey {
            if hasUnstartedBooks {
                HomeBSideCard()
                    .padding(.horizontal, Space.pageH)
            }
        } else if key == Self.householdKey {
            HouseholdShelf()
        } else if key == Self.releaseRadarKey {
            if releaseRadarEnabled && !ReleaseRadarViewModel.shared.entries.isEmpty {
                ReleaseRadarShelf(libraryItems: libraryViewModel.items)
            }
        } else if key == Self.otherServersKey {
            if !isKidAccount,   // Review 2 Medium 11
               !otherServersStore.mergedItems.isEmpty || otherServersStore.shelves.contains(where: { $0.state == .needsSignIn }) {
                OtherServersShelf()
            }
        } else if key == Self.weekStatsKey {
            // Compact weekly stats glance — full breakdown stays in Settings > Stats;
            // this is only a teaser, per design direction.
            if let weekStats, weekStats.hasEnough {
                HomeWeekStatsCard(stats: weekStats)
                    // UI-4: this file's page margin was already 20pt everywhere (unlike
                    // `LibraryView`/`BookDetailView`, which use 16pt — the review's
                    // "adjacent tabs, 4pt mismatch" finding). Routed through
                    // `Space.pageH` throughout this file so that value is now a named
                    // standard other files can adopt, instead of nine independent 20s.
                    .padding(.horizontal, Space.pageH)
            }
        } else if let shelf = libraryViewModel.personalizedShelves.first(where: { shelfKey($0) == key }),
                  shelf.isBookShelf,
                  let entities = shelf.entities, !entities.isEmpty {
            // Defensive-consistency fix (26 August 2026): `orderedSectionKeys`
            // (above) and `CarPlayCoordinator`'s equivalent lookup both already
            // guard on `shelf.isBookShelf` before treating a shelf's `entities` as
            // real `LibraryItem`s — this render path was the one place that same
            // guard was missing, so a "series"/"authors"/"episode"-typed personalized
            // shelf could in principle reach `CompactShelfRow`/`ContinueListeningSection`
            // with entities that don't actually have the book/podcast shape those
            // expect. Not confirmed to be the cause of the reported blank-title bug
            // (that fix is `LibraryItem.title`'s new empty-string guard, in
            // `AudiobookshelfModels.swift`) — added here anyway since it's a cheap,
            // clearly-correct consistency fix regardless.
            // Critique 2026-10-05 (Home, 2nd): the Continue Listening branch that used to
            // sit here was unreachable (the NOW zone is rendered separately by
            // `nowZoneItems`, and BROWSE filters out `.now` keys); removed.
            // Batch 496 (N4): Recently Added and Next in Series get a See all (HomeState).
            CompactShelfRow(title: shelfTitle(shelf), items: entities,
                            seeAll: HomeState.seeAllDestination(forSectionKey: key),
                            bottomInset: bottomInset)
        }
    }

    /// Identifies the currently active server+account, so an in-flight load can tell
    /// whether the account switched underneath it before it lands.
    private func activeStatsScope() -> String {
        "\(AuthStore.shared.serverURL)|\(AccountStore.currentAccountId ?? "")"
    }

    /// Loads the compact "Your Week" summary from the same stats sources the Share
    /// feature already uses (`ListeningStatistics.from`) — no separate stats pipeline.
    /// Captures the active account/server scope before the async calls and re-checks it
    /// before assigning, so a load started just before an account switch can't land the
    /// previous account's numbers into the new account's Home (the `.shelfheadAccountChanged`
    /// handler below clears `weekStats` and starts a fresh load, but doesn't cancel an
    /// already-in-flight one).
    private func loadWeekStats() async {
        let scope = activeStatsScope()
        // Review 6 Low (Your Week): an in-flight load for the *previous* account must not block the new one.
        guard !isLoadingWeekStats || loadingWeekScope != scope else { return }
        loadingWeekScope = scope
        isLoadingWeekStats = true
        defer { if loadingWeekScope == scope { isLoadingWeekStats = false; loadingWeekScope = nil } }
        // Polish pass (J2-4): `loadPersonalizedView()` fetched `/api/me/listening-stats` moments ago
        // at launch; reuse that result (or its in-flight request) instead of asking twice.
        async let statsTask = libraryViewModel.listeningStats(maxAge: 60)
        async let sessionsTask = (try? await AudiobookshelfAPI.shared.getListeningSessions(itemsPerPage: 25)) ?? []
        let stats = await statsTask
        let sessions = await sessionsTask
        guard scope == activeStatsScope() else { return }
        weekStats = ListeningStatistics.from(
            stats: stats, sessions: sessions,
            finishedBooks: libraryViewModel.finishedBooksCount,
            streak: libraryViewModel.listeningStreak
        )
    }

    /// Batch 442: at most once a day, and only when the user opted in.
    private func refreshReleaseRadarIfEnabled() async {
        guard releaseRadarEnabled else { return }
        await ReleaseRadarViewModel.shared.refreshIfNeeded(items: libraryViewModel.items)
    }

    var body: some View {
        // NavigationStack is provided by ContentView so the mini-player/tab-bar
        // safe-area inset propagates into this scroll view correctly.
        return ZStack {
            // NB: no .ignoresSafeArea() here — inside a ZStack it would zero the
            // ScrollView's bottom safe-area inset and let the mini-player overlap.
            // The full-bleed fill is the `.background(...)` on this ZStack instead —
            // see that comment for why an ancestor's fill wasn't enough on iOS 26.
            Color.shelfBackground

                // Home has content worth showing even when the server's personalized
                // shelves haven't loaded (or failed to) — downloaded books, followed
                // narrators, and the weekly stats teaser are all local/independent of
                // that request. The empty state should only show when literally none of
                // Home's sections have anything, not just when shelves are empty —
                // otherwise offline-first users with only downloads see "Nothing here
                // yet" despite having books ready to play.
                let hasServerShelves = !libraryViewModel.personalizedShelves.isEmpty
                let hasDownloads = !downloadManager.downloadedItems.isEmpty
                let hasNarratorItems = !libraryViewModel.favoriteNarratorItems.isEmpty
                let hasStats = weekStats?.hasEnough == true
                // Critique 2026-10-05 (Home): a restored/last-played book or a downloaded
                // one is content too (the offline hero), even with no server shelves.
                let hasHeroFallback = !nowZoneItems.isEmpty

                // AN-3 (docs/design-review.md, Round 3): computed once so the branch
                // condition below and the `.shelfAnimation(value:)` key on the Group
                // that wraps this if/else-if/else can't drift apart.
                let showsSkeleton = (libraryViewModel.isLoadingPersonalized || libraryViewModel.isLoadingLibraries) && !hasServerShelves
                    && !hasDownloads && !hasNarratorItems && !hasStats && !hasHeroFallback

                // Scoped to a Group around just the if/else-if/else, not the outer
                // ZStack — the ZStack also carries `.toolbar`/`.navigationBarTitleDisplayMode`
                // below, and the trailing toolbar's library-switcher Menu can appear at
                // the same moment the first page of shelves lands, which would otherwise
                // get swept into this same animated transaction.
                Group {
                if showsSkeleton {
                    // Skeleton shelves instead of a centered spinner — gives cold
                    // launch a sense of the content's shape while it loads.
                    ScrollView { SkeletonHomeContent() }
                        .scrollDisabled(true)
                        .transition(.opacity)
                } else if !hasServerShelves && !hasDownloads && !hasNarratorItems && !hasStats && !hasHeroFallback {
                    // Critique 2026-10-05 (Home): inside a ScrollView so pull-to-refresh
                    // (the `.refreshable` below) works from the empty/error state, and
                    // split into "couldn't load" vs "genuinely empty".
                    ScrollView { homeEmptyOrErrorState }
                        .scrollIndicators(.hidden)
                        .transition(.opacity)
                } else {
                    ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Reverted per user feedback (26 August 2026): Stage 2 had
                            // removed this greeting from the NOW zone entirely (keeping
                            // it only in the empty state) to make room for the bigger
                            // hero cover below. The user preferred the greeting back
                            // even with a book in progress, so `headerView` (greeting
                            // only — the streak capsule stays retired to the Listening
                            // tab, see Stage 3) is back to rendering unconditionally.
                            headerView(showsSubtitle: !nowZoneItems.isEmpty)
                                .id(Self.topAnchorID)

                            // D2 (design brief 2026-08-12): Home is explicitly two zones,
                            // not a flat list of eight equally-weighted shelves. NOW is
                            // never optional — Resume must be reachable in one tap without
                            // scrolling whenever there's an in-progress book, so this
                            // renders an explicit empty state rather than just omitting the
                            // zone when there's nothing in progress yet (a silent blank gap
                            // reads as broken, not "nothing to show").
                            // Critique 2026-10-05 (Home): the hero no longer depends on the
                            // user's hidden-sections set (Continue Listening isn't hideable
                            // any more) or only on the server shelf (see `nowZoneItems`).
                            let nowItems = nowZoneItems
                            if !nowItems.isEmpty {
                                ContinueListeningSection(items: nowItems, bottomInset: bottomInset)
                            } else {
                                nowZoneEmptyState
                            }

                            // Critique 2026-10-05 (Home, 2nd): compact failure card directly
                            // under the hero (book first), only when shelves failed to load.
                            homeLoadFailureCard

                            // BROWSE — everything else, in the user's own saved order
                            // (defaulting to a capped set of shelves for anyone who's never
                            // customised Home — see `SettingsStore
                            // `SettingsMigrator` step 1). See `HomeCustomizeSheet` for
                            // the drag-to-reorder/show-hide UI and `orderedSectionKeys` for
                            // how the saved order is merged with what's actually available.
                            // The divider only renders when there's actually a browse
                            // section beneath it — an orphaned "BROWSE" label above nothing
                            // is worse than no label at all.
                            let browseKeys = orderedSectionKeys.filter {
                                tier(for: $0) == .browse && !hiddenSections.contains($0)
                            }
                            if !browseKeys.isEmpty {
                                // Critique 2026-10-05 (Home), JUDGMENT CALL: BROWSE used to
                                // stack its caps label directly over the first shelf's own
                                // caps label (two headers in a row). The user adjusted the
                                // spacing before but never rejected removing it, so the
                                // separate BROWSE header only renders when the first shelf
                                // has none of its own (the bare B-Side row); otherwise that
                                // shelf's header does the job. Easy to restore: always
                                // render the header.
                                let showsBrowseHeader = HomeState.browseNeedsOwnHeader(firstKey: browseKeys.first)
                                // Fixed after user testing ("the browse bar makes it look
                                // like there should be things under it"): the outer VStack's
                                // uniform 24pt spacing put just as much air between "BROWSE"
                                // and the first shelf beneath it as between that shelf and
                                // the next one — so the divider read as an empty peer
                                // section (its own header with nothing attached) rather than
                                // a label introducing the group below it. Nesting the
                                // divider and the shelves in their own VStack with a much
                                // tighter 10pt gap right after "BROWSE" — while keeping the
                                // normal 24pt rhythm *between* the shelves themselves via a
                                // second nested VStack — pulls the first shelf visually
                                // under the label instead of floating it at arm's length,
                                // without inventing a new header treatment (still the same
                                // `RetroSectionHeader` the brief asks for).
                                VStack(alignment: .leading, spacing: 10) {
                                    if showsBrowseHeader {
                                        RetroSectionHeader(title: LocalizedStringResource("Browse", comment: "Home section header above the browse shelves"))
                                            .padding(.horizontal, Space.pageH)
                                    }
                                    VStack(alignment: .leading, spacing: 24) {
                                        ForEach(browseKeys, id: \.self) { key in
                                            sectionView(for: key)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 16 + bottomInset)
                    }
                    .scrollIndicators(.hidden)
                    // Pass 3 item 3 (REVIEW_2026-09-04_UI.md) added a hard bottom scroll
                    // edge here (Batch 290) to stop cover art bleeding through the tab bar.
                    // Reverted on user report (4 Sep 2026): the solid band was "buggy when it
                    // regrows" as the edge effect animates, and the see-through bottom is
                    // preferred. The system's default soft edge is what renders now.
                    // D5 follow-up: re-tapping the already-selected Home tab (iOS 26
                    // `modernTabs` path) bumps `scrollToTopSignal` from `ContentView`;
                    // scroll back to the very top rather than doing nothing, which is
                    // what happened before this — reselect only reset `homePath`
                    // (irrelevant here, since Home has no pushed navigation depth in
                    // the common case of just being scrolled down).
                    .onChange(of: scrollToTopSignal) { _, _ in
                        // NEW-15 (follow-up review, 14 Aug 2026): guarded — this was
                        // the one unguarded `withAnimation` in the Views directory.
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                    }
                    }
                    .transition(.opacity)
                }
                }
                .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
            }
            // Black bar behind the bottom pills (user report, real device, iOS 26; Batch 307).
            // The note on the fill above used to read "ContentView already paints a
            // full-bleed shelfBackground behind this" — true only on the legacy tab
            // path, where that fill is a genuine ZStack sibling of the whole tab shell.
            // On `modernTabs` the system `TabView`/`NavigationStack` host paints its own
            // opaque `systemBackground` over ContentView's fill, so nothing of ours shows
            // through it. Measured in a standalone iOS 26.5 harness (pixel scans, not
            // eyeballed): with a floating tab bar plus `.tabViewBottomAccessory`, the tab
            // root's bottom safe-area inset is 139pt, and a bare `Color` child of a
            // ZStack stops dead at that edge. The ScrollView's *content* does scroll
            // under the pills (that's the see-through look), but wherever it isn't
            // opaque — row gaps, past the end of the content, or the whole strip in a
            // `List` with `.scrollContentBackground(.hidden)` — the host's
            // `systemBackground` shows straight through: rgb(0,0,0) with a dark trait
            // collection, white/grey with a light one. The host resolves that against
            // the device's style, not the app's `.preferredColorScheme` (the accessory's
            // own colours escape the same way — see `ContentView.systemAccessoryMiniPlayer`),
            // which is why a device in system Dark shows it black even with the app in
            // Light. Listening and Settings never had this because their fill is
            // `.ignoresSafeArea()`. Painting our own background full-bleed made this
            // structure pixel-identical to theirs in both schemes (0 differing pixels).
            // Deliberately a `.background` and not `.ignoresSafeArea()` on the fill
            // above: background content doesn't participate in this ZStack's layout, so
            // the ScrollView keeps the bottom safe-area inset that note is about.
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // HIG audit 2026-09-17 M3 — deliberate departure, user decision (same day):
                // Apple's Toolbars page says "don't title windows with your app name", and
                // Batch 335 briefly replaced this wordmark with a plain "Home" title. The
                // user asked for the wordmark back; it's the brand mark of the retro
                // design language, so it stays. The one M3 change kept is the VoiceOver
                // grouping on `wordmark` itself.
                // G8: `sharedBackgroundVisibility(.hidden)` keeps the non-interactive mark
                // out of iOS 26's automatic glass capsule so it reads as a title, not a
                // button; below 26 there's no capsule to remove.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { wordmark }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { wordmark }
                }
                // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Group {
                        // Batch 496 (REVIEW 2026-11-11 N5): the profile picker without quitting the
                        // app. Titled Label (VoiceOver, iPhone Duo overflow); the parent gate lives
                        // in the picker's tiles, as at launch.
                        if showsProfileButton {
                            Button {
                                guard !appLock.isLocked else { return }
                                Haptics.selection()
                                showProfilePicker = true
                            } label: {
                                Label("Switch Profile", systemImage: "person.crop.circle")
                            }
                            .accessibilityHint("Choose who’s listening")
                        }
                        if libraryViewModel.libraries.count > 1 {
                            Menu {
                                ForEach(libraryViewModel.libraries) { library in
                                    Button {
                                        Task { await libraryViewModel.selectLibrary(library) }
                                    } label: {
                                        HStack {
                                            Text(library.name)
                                            if library.id == libraryViewModel.selectedLibrary?.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                // iPhone Duo (§2): titled Label so the item can sit in the side bar.
                                Label("Switch library", systemImage: "square.stack.fill")
                            }
                        }
                        Button {
                            showCustomize = true
                        } label: {
                            // F4 (REVIEW_2026-09-04_UI.md): was `slider.horizontal.3` — the
                            // exact glyph the Settings *tab* uses (`ContentView.swift`), and
                            // both are on screen at once here, so the same icon pointed at
                            // two unrelated destinations from opposite corners of Home. This
                            // is the inverse of the Batch 218 (R10.7) fix, which unified two
                            // glyphs that shared one action; `slider.horizontal.3` belongs to
                            // Settings, and what this button actually does is rearrange the
                            // shelves, so it takes a compositional glyph instead.
                            Label("Customise Home", systemImage: "rectangle.3.group")
                        }
                        .accessibilityHint("Show, hide and reorder the shelves on Home")
                    }
                    .monochromeToolbarItem()
                }
            }
            .refreshable {
                // Detach the reload so ending the pull gesture (which cancels the
                // .refreshable task) can't cancel the network requests mid-flight —
                // that cancellation was blanking the shelves.
                await Task {
                    await libraryViewModel.refresh()
                    await libraryViewModel.loadFavoriteNarratorItems()
                    await loadWeekStats()
                }.value
            }
            // `HomeView` stays mounted across account switches (see `MainTabView`'s
            // persistent-tab `ZStack`), so `.task` alone won't re-fire — drop the stale
            // account's stats explicitly and reload for the newly active one.
            .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
                weekStats = nil
                // N-6: counts belong to the previous account's library. Cleared here for
                // the same reason `weekStats` is — this screen stays mounted across an
                // account switch, so nothing else would drop them.
                smartFilterCounts = [:]
                // Review 6 Medium 10: the iOS 26 shell doesn't remount Home, so reload this shelf too.
                Task { await libraryViewModel.loadFavoriteNarratorItems() }
                Task { await loadWeekStats() }
                Task { await authViewModel.loadAccounts() }   // Batch 496 (N5): an added server
            }
            // Review 7 Medium 3: the handler above runs before the new account's library is
            // selected (and before its progress loads), so reload both once it is.
            .onChange(of: libraryViewModel.selectedLibrary?.id) { _, newId in
                guard hasCompletedInitialLoad, newId != nil else { return }
                Task { await libraryViewModel.loadFavoriteNarratorItems() }
                Task { await loadWeekStats() }
            }
            // D2 follow-up (structural cap, 14 Aug 2026): re-run the BROWSE-tier
            // visibility reconciliation any time what's actually available changes —
            // covers a shelf type that's new to this account, not just the ones fixed
            // at first install (see `SettingsStore.reconcileNewHomeBrowseSections`).
            //
            // P3-2 (third-pass review, 14 Aug 2026): guarded by `hasCompletedInitialLoad`
            // — see `reconcileBrowseSectionsIfNeeded()`'s doc comment for why calling
            // this on every intermediate change during the `.task` below's three
            // sequential loads corrupted the one-time migration.
            .onChange(of: availableSectionKeys) { _, newValue in
                guard hasCompletedInitialLoad else { return }
                reconcileBrowseSectionsIfNeeded(availableKeys: newValue)
            }
            // N-6 (REVIEW_2026-09-14_DESIGN.md): the Smart Filters shelf's counts are
            // recomputed only when the snapshot they're read from appears or goes stale
            // — not on every render, and never by fetching. `hasSmartFilterSnapshot`
            // flips false→true the first time a smart filter is opened anywhere in the
            // app, and true→false when a library switch or refresh invalidates it, so
            // this covers both "counts just became available" and "counts just stopped
            // being true". `smartFilter` is watched as well because re-selecting a
            // filter after a refresh re-fetches the snapshot in place, with no
            // transition on the flag above to observe.
            .onChange(of: libraryViewModel.hasSmartFilterSnapshot) { _, _ in
                smartFilterCounts = libraryViewModel.cachedSmartFilterCounts()
            }
            .onChange(of: libraryViewModel.smartFilter) { _, _ in
                smartFilterCounts = libraryViewModel.cachedSmartFilterCounts()
            }
            .background { NowZoneFinishedProbe(reachedFinish: $playerReachedFinish) }
            // Polish pass (J2-17): first time Home has server shelves to draw (cached or fresh).
            .onChange(of: !libraryViewModel.personalizedShelves.isEmpty, initial: true) { _, hasShelves in
                if hasShelves { LaunchTrace.mark("homeFirstShelves") }
            }
            .task {
                // Critique 2026-10-05 (Home): Continue Listening used to be hideable; clear
                // any persisted hidden value so it can't suppress the hero.
                if hiddenSections.contains(Self.continueListeningKey) {
                    hiddenSections.remove(Self.continueListeningKey)
                    SettingsStore.setHomeSection(Self.continueListeningKey, hidden: false)
                }
                // Batch 496 (N5): the saved-account count decides the profile button.
                Task { await authViewModel.loadAccounts() }
                if libraryViewModel.libraries.isEmpty {
                    await libraryViewModel.loadLibraries()
                }
                // Polish pass (J2-3): the three loads are independent of each other, so they run
                // together and are all awaited before `hasCompletedInitialLoad` flips below
                // (the P3-2 reconcile still sees the full set). Release Radar reads
                // `libraryViewModel.items`, which `loadLibraries()` above has already filled.
                async let narrators: Void = libraryViewModel.loadFavoriteNarratorItems()
                async let week: Void = loadWeekStats()
                async let radar: Void = refreshReleaseRadarIfEnabled()
                _ = await (narrators, week, radar)
                // Multi-server: fetch every other saved account's in-progress books for
                // the "On Other Servers" shelf. Detached from the sequential loads above
                // rather than awaited inline — it's a nice-to-have shelf, not something
                // the rest of Home's startup should wait on.
                Task { await otherServersStore.refresh(currentAccountId: authViewModel.currentAccountId) }
                // P3-2: only now — after every load this screen waits on at startup
                // has actually landed — does `availableSectionKeys` reflect the FULL
                // set this account can show. Reconciling (including the one-time
                // migration branch) against anything earlier than this point means
                // treating a shelf that simply hasn't loaded YET the same as one that
                // doesn't exist, which is exactly the bug: the old code ran this
                // reconcile from `.onChange` after each of the three loads above
                // individually, so `loadLibraries()` landing first set the one-time
                // migration flag using only the server shelves it had at that instant
                // — narrator favourites and Your Week hadn't loaded yet, so by the time
                // they did, they looked "new to this account" and got silently,
                // permanently hidden, overwriting anyone who'd deliberately unhidden them.
                hasCompletedInitialLoad = true
                reconcileBrowseSectionsIfNeeded(availableKeys: availableSectionKeys)
                // N-6: pick up a snapshot that already existed before this screen
                // appeared (Home stays mounted, so this `.task` doesn't re-run on every
                // return to the tab — but a cold launch straight into Home can still
                // find one left by CarPlay or a restored session).
                smartFilterCounts = libraryViewModel.cachedSmartFilterCounts()
            }
            // UX-4 audit (Batch 355): the library error alert moved to `MainTabView`, its one
            // owner; this tab and Library both used to present it.
            .sheet(isPresented: $showCustomize) {
                HomeCustomizeSheet(availableSections: customizableSections, hidden: $hiddenSections, order: $sectionOrder,
                                   moreShelves: HomeMoreShelves.rows(releaseRadarEnabled: releaseRadarEnabled,
                                                                     releaseRadarHasEntries: !ReleaseRadarViewModel.shared.entries.isEmpty,
                                                                     isInHousehold: HouseholdStore.shared.isInHousehold,
                                                                     isKidProfile: KidProfileStore.standard.isKid(AccountStore.currentAccountId)),
                                   openSettings: { page in
                                       showCustomize = false
                                       tabRouter.requestedSettingsPage = page
                                   })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // Batch 490 (REVIEW 2026-11-11 E5): same sheet and library hand-off as Library's "+".
            .sheet(isPresented: $showUploadSheet) {
                UploadSheet(onOpenLibrary: { id in
                    guard let library = libraryViewModel.libraries.first(where: { $0.id == id }) else { return }
                    Task { await libraryViewModel.selectLibrary(library) }
                })
            }
            // Batch 490 (REVIEW 2026-11-11 V6): Release Radar's "Not Interested" Undo. Hosted here, not
            // on the shelf, because hiding the last entry unmounts the shelf (and its toast with it).
            // Batch 496 (REVIEW 2026-11-11 N5): the picker mid-session. Switching runs through the
            // picker's own `ServerSwitchFlow` (password, insecure-connection and failure follow-ups),
            // and `MainTabView`'s `.shelfheadAccountChanged` receiver resets account state as for any
            // switch. A full-screen cover sits above ContentView's App Lock overlay, so it closes
            // when the app locks and is blanked while the scene is inactive (the switcher snapshot).
            .fullScreenCover(isPresented: $showProfilePicker) {
                ProfilePickerView(onFinish: { showProfilePicker = false },
                                  onCancel: { showProfilePicker = false })
                    .overlay {
                        if SettingsStore.appLockEnabled && (scenePhase != .active || appLock.isLocked) {
                            Color.shelfBackground.ignoresSafeArea()
                        }
                    }
            }
            .onChange(of: appLock.isLocked) { _, locked in
                if locked { showProfilePicker = false }
            }
            .toast(message: $releaseRadar.notInterestedToast,
                   style: .info, duration: 4, bottomInset: bottomInset,
                   action: ToastAction(label: LocalizedStringResource("Undo")) {
                       releaseRadar.undoLastNotInterested()
                   })
            .reexpandsTabBarOnAppear()
    }

    // MARK: - Empty / load-failure state (Critique 2026-10-05, Home)

    /// Whether the first personalized load failed, the account has no libraries, or Home
    /// is genuinely empty. Critique 2026-10-05 (Home, 2nd): driven by
    /// `LibraryViewModel.personalizedLoadFailed` rather than inferred from reachability
    /// and whether a library was ever resolved — see `HomeState.emptyKind`.
    private var homeEmptyKind: HomeState.EmptyKind {
        HomeState.emptyKind(reachability: ReachabilityStore.shared.status,
                            loadFailed: libraryViewModel.personalizedLoadFailed,
                            hasLibraries: !libraryViewModel.libraries.isEmpty,
                            hasSelectedLibrary: libraryViewModel.selectedLibrary != nil)
    }

    private func retryHomeLoad() {
        Haptics.selection()
        Task {
            if libraryViewModel.libraries.isEmpty {
                await libraryViewModel.loadLibraries()
            } else {
                await libraryViewModel.refresh()
            }
        }
    }

    /// Full-page state, reached only when Home has nothing at all to show (so no
    /// downloads: with downloads the hero leads and `homeLoadFailureCard` sits below it).
    @ViewBuilder
    private var homeEmptyOrErrorState: some View {
        let kind = homeEmptyKind
        VStack(spacing: 4) {
            switch kind {
            case .genuinelyEmpty:
                // Batch 490 (REVIEW 2026-11-11 E5): a library with no books. "Shelves will appear once
                // you start listening" promised something that can't happen without books; say
                // where to add them, check again after, and offer Upload when the account may.
                EmptyStateView(
                    icon: "books.vertical",
                    title: LocalizedStringResource("This library is empty"),
                    subtitle: LocalizedStringResource("Add books on your server, then check again."),
                    actionTitle: LocalizedStringResource("Check Again")
                ) {
                    retryHomeLoad()
                }
                if authViewModel.currentUser?.canUpload == true {
                    Button {
                        Haptics.selection()
                        showUploadSheet = true
                    } label: {
                        Text("Upload Books")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            case .noLibraries:
                // Critique 2026-10-06 (clarify): the primary used to be "Open Settings", but
                // nothing in this app's Settings adds a library. Check Again is primary (after
                // adding one on the server); switching servers stays a quiet secondary.
                EmptyStateView(
                    icon: "books.vertical",
                    title: .verbatim(HomeState.noLibrariesTitle),
                    subtitle: .verbatim(HomeState.noLibrariesMessage),
                    actionTitle: .verbatim(HomeState.noLibrariesAction)
                ) {
                    retryHomeLoad()
                }
                Button {
                    Haptics.selection()
                    // Batch 490 (REVIEW 2026-11-11 N7): straight to Settings › Account (where
                    // servers are switched and added), not the Settings root.
                    tabRouter.requestedSettingsPage = .account
                } label: {
                    Text("Use a Different Server")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            case .serverUnreachable, .offline, .loadFailed:
                EmptyStateView(
                    icon: kind == .offline ? "wifi.slash" : "exclamationmark.icloud",
                    title: kind == .offline ? LocalizedStringResource("You're offline")
                        : (kind == .loadFailed ? LocalizedStringResource("Couldn't load your shelves") : LocalizedStringResource("Can't reach your server")),
                    subtitle: LocalizedStringResource("Check your connection and try again."),
                    actionTitle: LocalizedStringResource("Retry", comment: "Button: try loading again")
                ) {
                    retryHomeLoad()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Critique 2026-10-05 (Home, 2nd): when the shelves failed to load but there is still
    /// something to play (downloads or a restored book), the book keeps leading and the
    /// failure is a compact card below the hero. This is where "Show Downloads" /
    /// "Your downloads still play." now actually render (the full-page state could never
    /// have them: it required no downloads).
    @ViewBuilder
    private var homeLoadFailureCard: some View {
        let kind = homeEmptyKind
        if HomeState.showsCompactLoadFailure(kind: kind, hasServerShelves: !libraryViewModel.personalizedShelves.isEmpty) {
            let hasDownloads = !downloadManager.downloadedItems.isEmpty
            VStack(alignment: .leading, spacing: 8) {
                // Batch 490 (REVIEW 2026-11-11, session ended): when the server signed this account
                // out, "check your connection" is the wrong advice — say what actually happened.
                if authViewModel.sessionNeedsSignIn {
                    Typo.rowTitle(Text("Your session on this server ended."))
                        .foregroundStyle(Color.shelfCream)
                    Typo.metadata(Text("Sign in again to refresh your shelves."))
                        .foregroundStyle(Color.shelfMuted)
                } else {
                    Typo.rowTitle(kind == .loadFailed ? Text("Couldn't refresh your shelves") : Text("Can't reach your server"))
                        .foregroundStyle(Color.shelfCream)
                    Typo.metadata(hasDownloads ? Text("Your downloads still play.") : Text("Check your connection and try again."))
                        .foregroundStyle(Color.shelfMuted)
                }
                HStack(spacing: 16) {
                    Button {
                        retryHomeLoad()
                    } label: {
                        Text("Retry")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(minHeight: 44)
                    }
                    if hasDownloads {
                        Button {
                            Haptics.selection()
                            if let url = URL(string: "shelfhead://downloads") { openURL(url) }
                        } label: {
                            Text("Show Downloads")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.shelfAmberText)
                                .frame(minHeight: 44)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.shelfCard)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .padding(.horizontal, Space.pageH)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - NOW zone empty state (D2, design brief 2026-08-12)

    /// Shown in place of the hero card when there's no in-progress book, so the NOW
    /// zone is never a silent blank gap — reuses the same `EmptyStateView` every other
    /// empty state in the app already uses, with a CTA into Library.
    ///
    /// Batch 218 (R10.8): this used to open the `shelfhead://library` deep link and
    /// let the system URL handler route it back to `ContentView.handleDeepLink`,
    /// purely because Home had no direct binding to `MainTabView`'s own
    /// `selectedTab`. `TabRouter` (see its doc comment) is that binding now, so this
    /// switches tabs directly in-process instead of round-tripping through the OS.
    /// The URL scheme itself still works exactly as before for Spotlight/Shortcuts.
    private var nowZoneEmptyState: some View {
        EmptyStateView(
            icon: "play.circle",
            title: LocalizedStringResource("Nothing in progress"),
            subtitle: LocalizedStringResource("Start a book and it'll show up here, ready to resume in one tap."),
            actionTitle: LocalizedStringResource("Browse Library")
        ) {
            Haptics.selection()
            tabRouter.requestedTab = 1
        }
        .padding(.horizontal, Space.pageH)
    }

    // MARK: - Header

    /// Reverted per user feedback (26 August 2026) — Stage 2 had removed this
    /// unconditional greeting row in favor of showing it only in the empty state, to
    /// free space for the bigger hero cover. Restored to render every time, book in
    /// progress or not. The streak capsule that used to sit in this same row stays
    /// retired to the Listening tab (Stage 3) — not reinstated here since that wasn't
    /// part of the feedback; say if you'd like it back too.
    private func headerView(showsSubtitle: Bool) -> some View {
        // Code review fix (26 August 2026): the wrapping `HStack { ... Spacer() }`
        // was vestigial — it existed to hold this leading text block alongside the
        // streak capsule that used to share this row, which moved to the Listening
        // tab back in Stage 3. With nothing left to push away from, the `Spacer()`
        // did nothing; the `VStack` alone lays out the same way on its own.
        VStack(alignment: .leading, spacing: 2) {
            Typo.pageTitle(Text(greetingText))
                .foregroundStyle(Color.shelfCream)

            // Critique 2026-10-05 (Home, 2nd): "Pick up where you left off" above a
            // "Nothing in progress" card contradicted it; only shown with a book to resume.
            if showsSubtitle {
                Typo.metadata(Text("Pick up where you left off"))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .padding(.horizontal, Space.pageH)
        .padding(.top, 8)
    }

    /// The nav-bar wordmark. Kept out of the toolbar's glass capsule on iOS 26 (see G8
    /// at the call site). Restored after Batch 335's M3 by user request — see the
    /// call site. HIG audit M3 (VoiceOver part): the decorative glyph and the text are
    /// one element now, so VoiceOver reads "ShelfHead" once instead of a symbol name
    /// followed by the word.
    @ScaledMetric(relativeTo: .headline) private var wordmarkSize: CGFloat = 18
    private var cappedWordmarkSize: CGFloat { min(wordmarkSize, 18 * 1.3) }

    // Critique 2026-10-05 (Home, 2nd): the two `.font(.system(size:))` calls below are the
    // brand-mark exception, not body text: the amber wordmark is a logo lock-up (rounded
    // bold, glyph + text sized together). It still scales with Dynamic Type through the
    // `@ScaledMetric` above, capped at 1.3x so the nav bar holds.
    private var wordmark: some View {
        HStack(spacing: 6) {
            Image(systemName: "headphones.circle.fill")
                // Critique 2026-10-05 (Home): was fixed 18pt; scaled (capped at 1.3x so
                // the nav bar doesn't blow out) with the wordmark text beside it.
                .font(.system(size: cappedWordmarkSize))
                .foregroundStyle(Color.shelfAmberText)
            Text("ShelfHead")
                .font(.system(size: cappedWordmarkSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.shelfAmberText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ShelfHead")
    }

    private var greetingText: String {
        HomeState.greeting(hour: Calendar.current.component(.hour, from: Date()))
    }
}

// MARK: - Continue Listening (Hero Card + Compact Queue)

/// Redesigned per the "UI/product notes" from the external review: the single most
/// recent in-progress book leads as a large hero card, with everything else that's
/// in progress collapsed into a compact "Also in Progress" list underneath instead of an
/// equally-weighted horizontal scroll. `items` is already server-ordered by recency
/// (Audiobookshelf's "Continue Listening" shelf), so `items.first` is simply the
/// most recently played book.
struct ContinueListeningSection: View {
    let items: [LibraryItem]
    /// Batch 496 (N4): clearance for the pushed "Also in Progress" page on the legacy tab bar.
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        // Stage 2 (REDESIGN_PROPOSAL_2026-08-26.md, §3.1b): the "Continue Listening"
        // section header used to sit directly above a card that is unmistakably that
        // section's one piece of content — the only `RetroSectionHeader` in the app
        // introducing a group of one. Removed; "Also in Progress" below still gets its header
        // since it genuinely introduces a list.
        VStack(alignment: .leading, spacing: 14) {
            if let hero = items.first {
                ContinueListeningHeroCard(
                    item: hero,
                    serverProgress: libraryViewModel.progressFor(itemId: hero.id)
                )
                .padding(.horizontal, Space.pageH)
            }

            if items.count > 1 {
                ContinueListeningQueue(items: Array(items.dropFirst()), bottomInset: bottomInset)
            }
        }
    }
}

/// The large, single-book card for the most recent in-progress title — bigger cover,
/// bigger type, and a labelled "Resume" pill instead of the small circular play button
/// the compact queue rows below use, so it reads as the clear primary action on Home.
struct ContinueListeningHeroCard: View {
    let item: LibraryItem
    let serverProgress: MediaProgress?
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Critique 2026-10-05 (Home): when this is the active book and the server has no
    /// progress record for it (the offline / restored-session case: the item is rebuilt
    /// from the App Group snapshot with no `mediaProgress`), the player's own position
    /// is the best local figure available.
    private var livePlayerProgress: (time: Double, duration: Double)? {
        guard isNowPlaying, serverProgress == nil, playerViewModel.duration > 0 else { return nil }
        return (playerViewModel.currentTime, playerViewModel.duration)
    }

    private var progressValue: Double {
        // Batch 497 (L12): reading only for a book with no audio (`LibraryItem.shownProgress`).
        if let serverProgress { return item.shownProgress(serverProgress) }
        if let live = livePlayerProgress, item.progressPercent == 0 { return live.time / live.duration }
        return item.shownProgress(nil)
    }

    private var currentTimeValue: Double {
        if let serverProgress { return serverProgress.currentTime ?? item.currentTime }
        if let live = livePlayerProgress, item.currentTime == 0 { return live.time }
        return item.currentTime
    }

    private var durationValue: Double {
        if let serverProgress { return serverProgress.duration ?? item.duration }
        if let live = livePlayerProgress, item.duration == 0 { return live.duration }
        return item.duration
    }

    private var isNowPlaying: Bool { playerViewModel.currentBook?.id == item.id }

    private var playLabel: String {
        HomeState.playVerb(isCurrent: isNowPlaying, isPlaying: playerViewModel.isPlaying)
    }

    /// Critique 2026-10-06 (harden + clarify, decision): when the hero is the loaded book, the
    /// mini player under it already carries play/pause for the same book, so the hero's
    /// button opens the player instead of being a second transport. Chosen over hiding the
    /// mini player while the hero is on screen: Home scrolls, so the bar would come and go
    /// with the scroll position (and iOS 26.0 can't hide the accessory at all). The card's
    /// VoiceOver actions still offer Pause/Resume. Pinned by `HomeAlsoInProgressTests`.
    private var heroButton: HomeState.HeroButton {
        HomeState.heroButton(isCurrent: isNowPlaying)
    }

    private func performHeroButton() {
        if heroButton == .openPlayer {
            Haptics.impact(.medium)
            playerViewModel.showFullPlayer = true
        } else {
            performPlay()
        }
    }

    private func performPlay() {
        Haptics.impact(.medium)
        // Real bug fix (29 August 2026): this always called
        // `startPlayback(for:)`, even when `item` was already the active,
        // currently-playing book — which re-fetched a brand-new playback
        // session and rebuilt the AVPlayer from scratch on every tap,
        // instead of just pausing it. `togglePlayPause()` already handles the one
        // case that still needs `startPlayback` itself (a book restored on launch
        // with no live session yet, via `isAwaitingResume`).
        if isNowPlaying {
            playerViewModel.togglePlayPause()
        } else {
            Task { await playerViewModel.startPlayback(for: item) }
        }
    }

    /// Critique 2026-10-05 (Home): one composite VoiceOver label for the card (title,
    /// author, percent through, time left, now playing / paused) instead of fragments
    /// ending in an orphaned "13%".
    private var compositeA11yLabel: String {
        HomeState.heroAccessibilityLabel(
            title: item.title, author: item.authorName,
            progress: progressValue,
            remainingSeconds: durationValue > 0 ? durationValue - currentTimeValue : nil,
            playback: isNowPlaying ? (playerViewModel.isPlaying ? .playing : .paused) : .none
        )
    }

    var body: some View {
        // Critique 2026-10-05 (Home): the Resume button used to be nested inside the
        // card's NavigationLink. It is now a sibling below the link so VoiceOver gets two
        // clear stops (the card, which opens Book Detail, and the play button) and the
        // card also offers the play action as a custom action.
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(destination: BookDetailView(item: item)) {
                VStack(alignment: .leading, spacing: 14) {
                    // Critique 2026-10-05 (Home): stacks vertically at accessibility sizes.
                    let rowLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    rowLayout {
                        // Design-direction pass (17 Aug 2026), point 3 / Stage 2: this is
                        // the one cover on all of Home meant to visually dominate (130pt,
                        // trade settled in the 26 August code review).
                        // V3 / IC-1: `CoverImageView` picks `Radius.card` for a cover this
                        // size (and draws the edge), so no second clip here.
                        //
                        // Critique 2026-10-05 (Home): the full scrim + centred amber disc
                        // + equalizer are gone (three now-playing markers on one screen,
                        // and DESIGN.md keeps covers clean). One small corner badge, and
                        // only while audio is actually moving, like the tiles' reel band.
                        CoverImageView(itemId: item.id, width: 130, height: 130)
                            .overlay(alignment: .bottomTrailing) {
                                if isNowPlaying && playerViewModel.isPlaying {
                                    EqualizerBadge(animating: true, color: Color.onAccent)
                                        .frame(width: 16, height: 14)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 5)
                                        .background(Color.shelfAmber, in: Capsule())
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                            }

                        VStack(alignment: .leading, spacing: 6) {
                            Typo.heroTitle(Text(item.title))
                                .foregroundStyle(Color.shelfCream)
                                // G10 (REVIEW_2026-09-04_UI.md): a third line only at
                                // accessibility sizes; default stays 2 (HL-6, settled).
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                .multilineTextAlignment(.leading)
                                // Ask for the height two lines actually need rather than
                                // depending on a sibling to supply it (F5).
                                .fixedSize(horizontal: false, vertical: true)

                            Typo.metadata(Text(item.authorName))
                                .foregroundStyle(Color.shelfMuted)
                                .lineLimit(1)

                            // F5: the metadata lines stay together; the `.top` alignment
                            // lets leftover height fall below them.
                            if durationValue > 0 {
                                let remaining = durationValue - currentTimeValue
                                // Point 8: amber means action/current-state; "time left"
                                // is descriptive metadata, so muted.
                                Text("\(remaining.formattedDuration) left")
                                    .scaledFont(12, weight: .semibold, relativeTo: .caption)
                                    .foregroundStyle(Color.shelfMuted)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Critique 2026-10-05 (Home): one element, one composite label; the play
            // action is also reachable from this element's actions rotor.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(compositeA11yLabel)
            .accessibilityHint("Opens book details")
            // Critique 2026-10-05 (Home, 2nd): `.isLink` removed; a NavigationLink already
            // carries the button trait, so VoiceOver announced it twice.
            .accessibilityAction(named: Text(playLabel)) { performPlay() }

            // Batch 434 (user: make it less in your face, like Book Detail): progress on the left and
            // a compact capsule on the right, in one row, instead of a full-width slab under the
            // progress bar. Stacks at accessibility sizes. Still a sibling of the link (not nested),
            // so VoiceOver keeps its two stops.
            let footerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            footerLayout {
                // Progress bar + percentage — amber stays here deliberately (point 8
                // allows amber for "progress"); this is real playback state.
                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.shelfMuted.opacity(0.3))
                                .frame(height: 6)
                            Capsule()
                                .fill(Color.shelfAmber)
                                .frame(width: geo.size.width * min(progressValue, 1.0), height: 6)
                        }
                    }
                    .frame(height: 6)

                    Text("\(Int(progressValue * 100))%")
                        // HIG audit 2026-09-17 M6: `minWidth` lets it grow with Dynamic Type.
                        .scaledFont(12, weight: .bold, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(minWidth: 38, alignment: .trailing)
                }
                // Batch 434: decorative here; the card's composite label already says the percent.
                .accessibilityHidden(true)

                Button {
                    performHeroButton()
                } label: {
                    // Critique 2026-10-06: "Open Player" for the loaded book (the mini player
                    // is its transport), "Play" for any other.
                    HStack(spacing: 6) {
                        Image(systemName: heroButton.glyph)
                        Text(heroButton.title)
                    }
                    .shelfCompactButtonStyle()
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityLabel(HomeState.heroButtonAccessibilityLabel(heroButton, title: item.title,
                                                                           anotherLoaded: playerViewModel.currentBook != nil))
                // Batch 490 (REVIEW 2026-11-11 A1): Play starts audio, so VoiceOver keeps quiet over
                // it; Open Player only shows the player.
                .accessibilityAddTraits(heroButton == .play ? .startsMediaSession : [])
            }
        }
        .padding(16)
        .background(Color.shelfCard)
        // UI-4: this hero card's 18pt radius is `Radius.hero`'s namesake.
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero))
        // Design-direction pass, points 1 & 2: theme-aware elevation instead of an
        // amber outline, so Resume is the strongest amber element on the card.
        .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.hero))
        // L4 (REVIEW_2026-08-20_UI_SECURITY.md): the hero gets the same context menu as
        // every lesser tile.
        .bookContextMenu(item)
    }
}

/// Compact "Also in Progress" list for every other in-progress book — a simple vertical stack
/// of slim rows rather than another horizontal scroll, so it visually reads as a
/// queue underneath the hero card rather than a second, equally-weighted shelf.
struct ContinueListeningQueue: View {
    let items: [LibraryItem]
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        // Batch 496 (REVIEW 2026-11-11 N4): at most three rows under the hero; the rest are
        // one See all away, so a heavy listener reaches the first shelf without scrolling.
        let shown = HomeState.capped(items, to: HomeState.alsoInProgressRowCap)
        VStack(alignment: .leading, spacing: 8) {
            // UI-4: was a bare hand-rolled `Text`, its own third visual language for a
            // section header alongside `RetroSectionHeader` (used two sections above by
            // "Continue Listening") and the plain `.font(.headline)` rows elsewhere in
            // the app — three different-looking headers doing the identical job on
            // adjacent screens. `RetroSectionHeader` is the one every other Home section
            // already uses, so this queue's own label now matches them instead of
            // introducing its own.
            // Critique 2026-10-06 (clarify): was "Up Next", which everywhere else in the app
            // is the play queue. These are the other books in progress, not a queue.
            Group {
                if HomeState.alsoInProgressHasSeeAll(otherCount: items.count) {
                    RetroSectionHeader(title: .verbatim(HomeState.alsoInProgressTitle),
                                       seeAllLabel: HomeState.seeAllAccessibilityLabel(.alsoInProgress)) {
                        HomeAlsoInProgressPage(items: items, bottomInset: bottomInset)
                    }
                } else {
                    RetroSectionHeader(title: .verbatim(HomeState.alsoInProgressTitle))
                }
            }
            .padding(.horizontal, Space.pageH)

            VStack(spacing: 8) {
                ForEach(shown) { item in
                    ContinueListeningQueueRow(
                        item: item,
                        serverProgress: libraryViewModel.progressFor(itemId: item.id)
                    )
                }
            }
            .padding(.horizontal, Space.pageH)
        }
    }
}

struct ContinueListeningQueueRow: View {
    let item: LibraryItem
    let serverProgress: MediaProgress?
    @Environment(PlayerViewModel.self) private var playerViewModel

    private var progressValue: Double {
        item.shownProgress(serverProgress)  // Batch 497 (L12)
    }

    // Code review fix (26 August 2026): this row had no `accessibilityElement`/
    // `accessibilityLabel` at all, unlike every sibling row in the app
    // (`CassetteTile`, `SearchResultRow`, `LibraryListRow`, `HomeWeekStatsCard`) that
    // builds one composite label under UI-7's pattern. VoiceOver split this one into
    // separate stops — title, then a bare "47%" with nothing saying what it measured.
    private var isCurrent: Bool { playerViewModel.currentBook?.id == item.id }

    /// Critique 2026-10-05 (Home, 2nd): same three-state play logic as the hero card
    /// (playing -> pause, loaded+paused -> resume, else start), so tapping the row's
    /// button on the book that is already loaded no longer rebuilds its session.
    private func performPlay() {
        Haptics.impact(.medium)   // Batch 495 (V7): play/pause class
        if isCurrent {
            playerViewModel.togglePlayPause()
        } else {
            Task { await playerViewModel.startPlayback(for: item) }
        }
    }

    private var rowA11yLabel: String {
        var parts = [item.title, item.authorName]
        if playerViewModel.currentBook?.id == item.id {
            parts.append(playerViewModel.isPlaying ? String(localized: "now playing", comment: "VoiceOver status") : String(localized: "paused", comment: "VoiceOver status"))
        }
        if progressValue >= 0.01 { parts.append(String(localized: "\(Int(progressValue * 100)) percent through", comment: "VoiceOver: book progress; %lld is a percentage")) }
        else if progressValue > 0 { parts.append(String(localized: "just started", comment: "VoiceOver: book progress")) }
        else { parts.append(String(localized: "not started", comment: "VoiceOver: book progress")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        NavigationLink(destination: BookDetailView(item: item)) {
            HStack(spacing: 10) {
                CoverImageView(itemId: item.id, width: 44, height: 44)
                    // Critique 2026-10-05 (Home, 2nd): was a black 0.3 scrim + static equalizer
                    // whenever the book was merely loaded (even paused). Now the hero's
                    // corner badge, only while audio is actually playing.
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent && playerViewModel.isPlaying {
                            EqualizerBadge(animating: true, color: Color.onAccent)
                                .frame(width: 11, height: 10)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                                .background(Color.shelfAmber, in: Capsule())
                                .padding(3)
                                .allowsHitTesting(false)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    // UI-4: was its own 13pt spelling of "book title in a row" — one of
                    // five the review found across the app. `Typo.rowTitle` is the
                    // shared 14pt version every migrated call site now renders at.
                    Typo.rowTitle(Text(item.title))
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(1)

                    // G9 (REVIEW_2026-09-04_UI.md): a queued book nobody has started drew
                    // an empty bar and a bare "0%". Keyed to the *displayed* percentage,
                    // not `> 0` — the first rendered check showed a book with a few
                    // seconds of server-side progress still drawing "0%" — so anything
                    // that would round to 0% gets words instead. `rowA11yLabel` above
                    // uses the same thresholds.
                    if progressValue >= 0.01 {
                        HStack(spacing: 6) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.shelfMuted.opacity(0.3))
                                        .frame(height: 3)
                                    Capsule()
                                        .fill(Color.shelfAmber)
                                        .frame(width: geo.size.width * min(progressValue, 1.0), height: 3)
                                }
                            }
                            .frame(height: 3)

                            // Critique 2026-10-05 (Home): was a fixed-ish 9pt base; now the
                            // `Typo.figure` fine role (caption2, monospaced digits).
                            Typo.figure(Text("\(Int(progressValue * 100))%"), fine: true, weight: .bold)
                                .foregroundStyle(Color.shelfMuted)
                        }
                    } else {
                        Typo.fine(progressValue > 0 ? Text("Just started") : Text("Not started"), weight: .medium)
                            .foregroundStyle(Color.shelfMuted)
                            // Pass 3 (REVIEW_2026-09-04_UI.md), regression from G9: the
                            // `GeometryReader` bar this replaces was also what stretched the
                            // text column — and so the whole card — to full width. Without
                            // it the row hugged its content and rendered visibly narrower
                            // than its siblings (seen in build 23's own verification crop,
                            // not recognised until Pass 3). Reclaim the width explicitly.
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button {
                    performPlay()
                } label: {
                    Image(systemName: HomeState.playGlyph(isCurrent: isCurrent, isPlaying: playerViewModel.isPlaying))
                        // Deliberately NOT `scaledFont` here (unlike the readable-text
                        // sites this pass fixes): this is a decorative glyph inside a
                        // fixed 26x26 circular button, and `.frame`'s fixed size doesn't
                        // grow with it — scaling the font would just clip the icon
                        // against the circle at large Dynamic Type sizes instead of
                        // making anything more legible. The button's real accessibility
                        // fix is the ≥44pt tap target below, which is unaffected by icon
                        // size, plus the `accessibilityLabel` VoiceOver actually reads.
                        .font(.system(size: 11))
                        .foregroundStyle(Color.onAccent)
                        .frame(width: 26, height: 26)
                        .background(Color.shelfAmber)
                        .clipShape(Circle())
                        // ≥44pt hit target without enlarging the visible disc.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(HomeState.playButtonLabel(
                    title: item.title, isCurrent: isCurrent, isPlaying: playerViewModel.isPlaying,
                    anotherLoaded: playerViewModel.currentBook != nil))
            }
            .padding(8)
            // Critique 2026-10-05 (Home, 2nd): was `shelfCard.opacity(0.6)`; in Dark the
            // `shelfElevation` shadow showed through the translucent fill and muddied the
            // row's content. Opaque now (the elevation still separates it in Light).
            .background(Color.shelfCard)
            // Code review fix (26 August 2026): raw `10` → `Radius.card` (see the hero
            // cover above for the same fix and rationale).
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            // Critique 2026-10-05 (Home): in Light the 0.6-opacity card fill nearly
            // vanished into the page; elevation gives it the hairline (shadow in Dark).
            .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .bookContextMenu(item)
        // `.combine` rather than `.ignore` (unlike `LibraryListRow`'s equivalent) —
        // this row has its own nested Play button, which needs to keep its own
        // action reachable rather than being absorbed into one opaque element.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowA11yLabel)
    }
}

// MARK: - Compact Shelf Row (for other sections)

struct CompactShelfRow: View {
    let title: String
    let items: [LibraryItem]
    /// Batch 496 (REVIEW 2026-11-11 N4): where the header's See all goes, or nil for none.
    var seeAll: HomeState.SeeAllDestination? = nil
    var bottomInset: CGFloat = 0
    @State private var downloadManager = DownloadManager.shared
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let seeAll {
                    RetroSectionHeader(title: .verbatim(title),
                                       seeAllLabel: HomeState.seeAllAccessibilityLabel(seeAll)) {
                        HomeSeeAllPage(destination: seeAll, bottomInset: bottomInset)
                    }
                } else {
                    RetroSectionHeader(title: .verbatim(title))
                }
            }
            .padding(.horizontal, Space.pageH)

            if items.count == 1, let item = items.first {
                // A single-item shelf (common for "Next in Series") uses a wide
                // horizontal card so it reads as intentional rather than a lone
                // tile stranded in empty space.
                NavigationLink(destination: BookDetailView(item: item)) {
                    HStack(spacing: 14) {
                        CoverImageView(itemId: item.id, width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            // UI-4: this exact 14pt/semibold/rounded spelling is what
                            // `Typo.rowTitle` unifies the app's other "book title in a
                            // row" variants toward.
                            Typo.rowTitle(Text(item.title))
                                .foregroundStyle(Color.shelfCream)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Typo.rowSubtitle(Text(item.authorName))
                                .foregroundStyle(Color.shelfMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            // VD-7 (docs/design-review.md, Round 4): trailing disclosure chevron
                            // next to `Typo.rowTitle`/`rowSubtitle` text — scale it like the
                            // app's other row chevrons (see `BookDetailView.chaptersRow`).
                            .scaledFont(13, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Color.shelfMuted)
                    }
                    .padding(12)
                    .background(Color.shelfCard)
                    // Code review fix (26 August 2026): raw `14` was byte-identical to
                    // `Radius.panel` — the token Batch 228 introduced for exactly this
                    // "padded content panel" role and migrated 10 sites in
                    // `StatsView`/`YearInReviewView` onto, missed here.
                    .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
                    // Critique 2026-10-05 (Home): Light-theme separation (hairline).
                    .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.panel))
                }
                .buttonStyle(.plain)
                .bookContextMenu(item)
                .padding(.horizontal, Space.pageH)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { item in
                            NavigationLink(destination: BookDetailView(item: item)) {
                                CassetteTile(
                                    coverURL: shelfCoverURL(itemId: item.id),
                                    title: item.title,
                                    subtitle: item.authorName,
                                    // Critique 2026-10-05 (Home): in-progress / finished
                                    // books show it on the tile like Library's grid does.
                                    progress: item.shownProgress(libraryViewModel.progressFor(itemId: item.id)),  // Batch 497 (L12)
                                    isFinished: libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished,
                                    downloaded: downloadManager.isDownloaded(itemId: item.id),
                                    downloadProgress: downloadManager.isDownloading(itemId: item.id)
                                        ? downloadManager.progress(for: item.id) : nil,
                                    isNowPlaying: playerViewModel.currentBook?.id == item.id,
                                    isPlaying: playerViewModel.isPlaying
                                )
                                .frame(width: 128)
                            }
                            .buttonStyle(.plain)
                            .bookContextMenu(item)
                        }
                    }
                    .padding(.horizontal, Space.pageH)
                }
                // Critique 2026-10-05 (Home): the shelf is one VoiceOver container named
                // for its title, so the tiles read as members of "<title>" rather than
                // an undifferentiated run of buttons.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
            }
        }
    }
}

// MARK: - See all destinations (Batch 496, REVIEW 2026-11-11 N4)

/// Where a Home shelf's See all goes. Pushed inside Home's own navigation stack (as the
/// Other Servers shelf's See all is), built from Library's existing pages and tiles.
struct HomeSeeAllPage: View {
    let destination: HomeState.SeeAllDestination
    var bottomInset: CGFloat = 0

    var body: some View {
        switch destination {
        case .recentlyAdded: HomeRecentlyAddedPage(bottomInset: bottomInset)
        case .series: HomeSeriesPage(bottomInset: bottomInset)
        case .downloads: DownloadsView(bottomInset: bottomInset)
        // Reached from `ContinueListeningQueue` with its items, not through this switch.
        case .alsoInProgress: EmptyView()
        case .listenAgain: HomeRecentlyAddedPage(shelf: .listenAgain, bottomInset: bottomInset)   // Batch 497 (N4)
        case .narrators: HomeNarratorsPage()   // Batch 497 (N4)
        }
    }
}

/// Batch 497 (REVIEW 2026-11-11 N4): Library's Narrators list (starred first), pushed from
/// From Narrators You Follow. It loads the narrator list itself if Library hasn't yet.
struct HomeNarratorsPage: View {
    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            NarratorsBrowseView()
        }
        .navigationTitle(String(localized: "Narrators"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every other in-progress book, as the same rows Home shows under the hero.
struct HomeAlsoInProgressPage: View {
    let items: [LibraryItem]
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        ContinueListeningQueueRow(item: item,
                                                  serverProgress: libraryViewModel.progressFor(itemId: item.id))
                    }
                }
                .padding(.horizontal, Space.pageH)
                .padding(.top, Space.l)
                .padding(.bottom, 16 + bottomInset)
            }
        }
        .navigationTitle(HomeState.alsoInProgressTitle)
        .navigationBarTitleDisplayMode(.inline)
        .reexpandsTabBarOnAppear()
    }
}

/// Library's Series grid, pushed from Next in Series. Loads the series list if Library
/// hasn't yet (Home can be the first screen to need it).
struct HomeSeriesPage: View {
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            SeriesBrowseView(bottomInset: bottomInset)
        }
        .navigationTitle(String(localized: "Series"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !libraryViewModel.seriesLoaded && !libraryViewModel.isLoadingSeries {
                await libraryViewModel.loadSeries()
            }
        }
        .reexpandsTabBarOnAppear()
    }
}

/// The library, newest first: Recently Added's full list. Its own page (paged 50 at a time
/// from `/api/libraries/<id>/items?sort=addedAt&desc=1`) rather than a switch to the Library
/// tab, so Library's own sort choice is left alone.
/// Batch 497 (N4): also Listen Again's page (`shelf: .listenAgain`), every finished book with
/// the latest finish first; the query comes from `HomeState.pagedQuery(for:)`.
struct HomeRecentlyAddedPage: View {
    var shelf: HomeState.SeeAllDestination = .recentlyAdded
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var books: [LibraryItem] = []
    @State private var total = 0
    @State private var nextPage = 0
    @State private var lastPageCount = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadFailed = false

    private static let pageSize = 50
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading && books.isEmpty {
                ScrollView {
                    SkeletonGrid(padding: EdgeInsets(top: Space.l, leading: Space.pageH, bottom: Space.l, trailing: Space.pageH))
                }
                .scrollDisabled(true)
                .accessibilityElement()
                .accessibilityLabel("Loading…")
                .transition(.opacity)
            } else if loadFailed && books.isEmpty {
                LoadFailedStateView { Task { await reload() } }
            } else if books.isEmpty {
                if shelf == .listenAgain {
                    EmptyStateView(icon: "checkmark.circle",
                                   title: LocalizedStringResource("No finished books yet"),
                                   subtitle: LocalizedStringResource("Books you finish will appear here."))
                } else {
                    EmptyStateView(icon: "books.vertical",
                                   title: LocalizedStringResource("This library is empty"),
                                   subtitle: LocalizedStringResource("Add books on your server, then check again."))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(books) { item in
                            BookLink(item) {
                                BookGridTile(item: item)
                            }
                            .buttonStyle(.plain)
                            .bookContextMenu(item)
                            .onAppear {
                                if item.id == books.last?.id { Task { await loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, Space.pageH)
                    .padding(.vertical, Space.l)
                    if isLoadingMore {
                        ProgressView()
                            .shelfSpinner()
                            .accessibilityLabel("Loading…")
                            .padding(.bottom, Space.l)
                    }
                    Color.clear.frame(height: bottomInset)
                }
                .transition(.opacity)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: isLoading)
        .navigationTitle(shelf == .listenAgain
                         ? String(localized: "Listen Again", comment: "Home shelf title")
                         : String(localized: "Recently Added", comment: "Home shelf title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .reexpandsTabBarOnAppear()
    }

    /// One page, or nil on failure. `stale` when the account or library changed meanwhile.
    private func fetch(page: Int) async -> (response: LibraryItemsResponse?, stale: Bool) {
        guard let libraryId = libraryViewModel.selectedLibrary?.id,
              let query = HomeState.pagedQuery(for: shelf) else { return (nil, false) }
        let accountId = AccountStore.currentAccountId
        let response = try? await AudiobookshelfAPI.shared.getLibraryItems(
            libraryId: libraryId, limit: Self.pageSize, page: page, filter: query.filter,
            sort: query.sort, desc: query.desc)
        let stale = libraryViewModel.selectedLibrary?.id != libraryId || AccountStore.currentAccountId != accountId
        return (response, stale)
    }

    private func reload() async {
        isLoading = true
        loadFailed = false
        let result = await fetch(page: 0)
        guard !result.stale else { return }
        if let response = result.response {
            books = response.results
            total = response.total
            lastPageCount = response.results.count
            nextPage = 1
        } else if libraryViewModel.selectedLibrary != nil {
            loadFailed = true
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore,
              HomeState.recentlyAddedHasMore(loaded: books.count, total: total, lastPageCount: lastPageCount) else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let result = await fetch(page: nextPage)
        guard !result.stale, let response = result.response else { return }
        let known = Set(books.map(\.id))
        books += response.results.filter { !known.contains($0.id) }
        total = response.total
        lastPageCount = response.results.count
        nextPage += 1
    }
}

// MARK: - Smart Filters shelf

/// N-6 (REVIEW_2026-09-14_DESIGN.md): a first-class Home surface for the eight
/// client-side `SmartFilter`s.
///
/// They were the app's strongest differentiator and lived two taps deep — the Library
/// toolbar's filter sheet, then its Filters tab. This is the discovery surface; the
/// sheet stays exactly as it is as the *editing* surface (tapping the active filter
/// there still clears it, which is a thing you only want next to the results).
/// Tapping a card here always applies, never toggles: from Home there is no visible
/// result set to toggle against, so a tap that silently cleared a filter and left you
/// on Library showing everything would read as the navigation having failed.
///
/// Deliberately a horizontal scroller of small cards rather than a grid: this is a
/// shelf among shelves, and eight full-width rows would dominate the BROWSE zone the
/// D2 cap exists to keep small.
struct SmartFiltersShelf: View {
    /// Per-filter match counts, or empty when they aren't known — see
    /// `LibraryViewModel.cachedSmartFilterCounts()`. A missing count renders the
    /// filter's own subtitle instead of a placeholder number: "—" or "0" would both be
    /// read as "nothing matches", which is a different (and possibly false) claim from
    /// "not counted yet".
    var counts: [SmartFilter: Int] = [:]

    @Environment(TabRouter.self) private var tabRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Cards get wider (not taller-and-truncated) at accessibility sizes, matching how
    /// `LibraryView`'s own smart-filter chips drop to a single column there.
    private var cardWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 240 : 156
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RetroSectionHeader(title: LocalizedStringResource("Smart Filters", comment: "Home shelf title"))
                .padding(.horizontal, Space.pageH)

            ScrollView(.horizontal, showsIndicators: false) {
                // A plain `HStack`, unlike the `LazyHStack` every book shelf in this
                // file uses: there are exactly eight cards, all cheap and none loading
                // an image, so laziness buys nothing — and a lazy stack sizes its
                // cross-axis from whichever children happen to be realized, which is
                // precisely what would break the equal-height cards below as you scroll.
                HStack(alignment: .top, spacing: 12) {
                    ForEach(SmartFilter.allCases) { filter in
                        SmartFilterCard(filter: filter, count: counts[filter], width: cardWidth) {
                            Haptics.selection()
                            tabRouter.requestedSmartFilter = filter
                        }
                    }
                }
                .padding(.horizontal, Space.pageH)
            }
            // Critique 2026-10-05 (Home): grouped as one named container (see CompactShelfRow).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Smart Filters")
        }
    }
}

/// One smart filter as a tappable card. Mirrors `LibraryView.smartFilterChip`'s
/// content (icon + label, subtitle as the accessibility hint) so the two surfaces read
/// as the same feature, in the card shape Home's shelves use rather than that sheet's
/// grid chip.
private struct SmartFilterCard: View {
    let filter: SmartFilter
    let count: Int?
    let width: CGFloat
    let action: () -> Void

    private var countLabel: String? {
        guard let count else { return nil }
        return count == 1 ? String(localized: "1 book") : String(localized: "\(count) books")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: filter.icon)
                    // VD-7 (docs/design-review.md, Round 4): sits directly above
                    // `Typo.rowTitle`'s text in this same card stack, so it scales with it
                    // instead of shrinking relative to the title at AX sizes.
                    .scaledFont(16, weight: .semibold, relativeTo: .subheadline)
                    // Amber discipline (design-direction pass, point 8): this glyph is
                    // the tappable action's own mark, not decoration on a row that has
                    // one elsewhere — the same role the B-side shuffle glyph plays.
                    .foregroundStyle(Color.shelfAmberText)

                Typo.rowTitle(Text(filter.label))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(countLabel ?? filter.subtitle)
                    .scaledFont(12, relativeTo: .caption)
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(Space.m)
            .frame(width: width, alignment: .topLeading)
            // Equal-height cards: each one asks for the whole row's height, which the
            // `HStack` has already sized to the tallest card. Without this a card with a
            // one-line title next to one with a two-line title would have a visibly
            // shorter fill, and the shelf would read as ragged rather than as a set.
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card))
            // Critique 2026-10-05 (Home): hairline in Light / shadow in Dark so the card
            // separates from the page.
            .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        // VoiceOver reads the filter and its match count as one label, then what the
        // filter actually means as the hint — same split `LibraryView`'s chip uses.
        .accessibilityLabel(countLabel.map { String(localized: "\(filter.label), \($0)", comment: "VoiceOver: %1$@ is a smart filter name, %2$@ is a count such as 3 books") } ?? filter.label)
        .accessibilityHint(filter.subtitle)
    }
}

// MARK: - Your Week (compact stats teaser)

/// Design review (14 Aug 2026), item 3: "B-side" — play a random book you've never
/// started, like flipping a cassette over — used to be reachable only via an
/// unlabelled `shuffle` glyph in `LibraryView`'s nav bar. Given a real, labelled home
/// here (and a matching button in `LibraryView`'s own empty state) instead.
struct HomeBSideCard: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var isShuffling = false
    @State private var toastMessage: String?

    // VD-7 (docs/design-review.md, Round 4): the shuffle glyph shares its fixed 20x20
    // swap slot with the `ProgressView` shown while shuffling, so it can't grow freely
    // without misaligning that pairing — capped like `AppLockView`'s glyph
    // (`min(scaled, base * factor)`) rather than left fixed, since it sits directly
    // beside `Typo.rowTitle`'s "Flip to a B-side" text.
    @ScaledMetric(relativeTo: .subheadline) private var shuffleIconSize: CGFloat = 15
    private var cappedShuffleIconSize: CGFloat { min(shuffleIconSize, 15 * 1.3) }

    var body: some View {
        // Design-direction pass (17 Aug 2026), points 1 & 2: this used to be a full
        // `Color.shelfCard` + bordered box — the exact same visual weight as a shelf
        // card, so it read as another peer competing with the book being listened to
        // instead of what it actually is, a small utility. Flattened to a plain row
        // sitting directly on the background (no card fill, no border, no icon
        // "badge" circle) — a labelled feature (per the review's own note that B-side
        // should stay labelled, not an ambiguous icon), just a quiet one.
        Button {
            shuffle()
        } label: {
            HStack(spacing: 12) {
                if isShuffling {
                    ProgressView().tint(Color.shelfAmberText)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "shuffle")
                        .font(.system(size: cappedShuffleIconSize, weight: .semibold))
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 1) {
                    // Batch 218 (R9): was its own 14pt/.medium spelling of "book
                    // title in a row" — a near-miss of `Typo.rowTitle`'s identical
                    // 14pt but `.semibold` weight. Routed through the token so the
                    // weight matches every other row title in the app.
                    Typo.rowTitle(Text("Flip to a B-side"))
                        .foregroundStyle(Color.shelfCream)
                    Text("Play a random book you haven't started")
                        .scaledFont(12, relativeTo: .caption)
                        .foregroundStyle(Color.shelfMuted)
                    // Critique 2026-10-06 (harden): say, visibly, that this replaces the
                    // loaded book (only VoiceOver used to hear it).
                    if let note = playsInstead {
                        Text(note)
                            .scaledFont(12, relativeTo: .caption)
                            .foregroundStyle(Color.shelfMuted)
                            .lineLimit(1)
                    }
                }
                // Critique 2026-10-06 (harden): the navigation chevron is gone. This row
                // starts playback; it doesn't open a screen.
                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isShuffling)
        .accessibilityLabel("Flip to a B-side")
        // Critique 2026-10-06 (harden): the hint names the book it replaces, like the row.
        .accessibilityHint(HomeBSideCard.accessibilityHint(playsInstead: playsInstead))
        .toast(message: $toastMessage, style: .info)
    }

    /// "Plays instead of <title>" while a book is loaded.
    private var playsInstead: String? {
        PlayerViewModel.playsInsteadSubtitle(loadedTitle: playerViewModel.displayedBook?.title)
    }

    /// Shared with Library's B-side button.
    static func accessibilityHint(playsInstead: String?) -> String {
        let base = String(localized: "Plays a random book you haven't started yet.")
        guard let playsInstead else { return base }
        return String(localized: "\(base) \(playsInstead).", comment: "Accessibility hint: %1$@ is the sentence 'Plays a random book you haven't started yet.', %2$@ is a phrase naming the book that will be replaced")
    }

    /// Mirrors `LibraryView.shuffleBSide()` — kept as its own small copy rather than a
    /// shared helper, since the two call sites differ slightly in how they report "no
    /// unstarted books left" (a toast here vs. `LibraryView`'s own toast binding) and
    /// this is the only bit of logic involved.
    private func shuffle() {
        let unstarted = libraryViewModel.items.filter {
            libraryViewModel.progressFor(itemId: $0.id) == nil
        }
        guard let pick = unstarted.randomElement() else {
            Haptics.warning()   // Batch 495 (V7): nothing to shuffle
            toastMessage = String(localized: "Every book in this library has already been started.")
            return
        }
        Haptics.selection()
        isShuffling = true
        Task {
            // Critique 2026-10-06 (harden): "Playing instead of … Undo" when it replaced a book.
            await playerViewModel.startPlaybackOfferingUndo(for: pick)
            isShuffling = false
        }
    }
}

/// Compact "Your Week" glance for Home. Deliberately minimal — the full breakdown
/// lives in Settings > Stats (`StatsView`); this card only ever consumes the shared
/// `ListeningStatistics` adapter (`ShareCard.swift`), never recomputes its own numbers.
///
/// Review 2026-08-19: this doc comment had been split across an earlier edit — its
/// first two lines were sitting above `HomeBSideCard` ~70 lines below (fused mid-
/// sentence onto that struct's own comment), leaving only the trailing clause here.
/// Rejoined; no behavior change.
struct HomeWeekStatsCard: View {
    let stats: ListeningStatistics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var minutesLabel: String? {
        guard let minutes = stats.minutesThisWeek else { return nil }
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? String(localized: "\(hours)h \(mins)m", comment: "Compact duration: hours and minutes") : String(localized: "\(mins)m", comment: "Compact duration: minutes")
    }

    var body: some View {
        // Design-direction pass (17 Aug 2026), points 1 & 2: same flattening as
        // `HomeBSideCard` — this was a full bordered card the same weight as a shelf
        // or the hero, when it's meant to be a quiet teaser. No card fill/border now;
        // the numbers themselves (amber — real stat values, a defensible "small
        // highlight" per point 8) still stand out against a plain background.
        NavigationLink(destination: StatsView()) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // Critique 2026-10-05 (Home, 2nd): `.combine` below merged this heading's
                    // trait into the link; stripped so the row reads as one link, not a
                    // heading that is also a link.
                    RetroSectionHeader(title: LocalizedStringResource("Your Week", comment: "Home shelf title: this week's listening stats"))
                        .accessibilityRemoveTraits(.isHeader)
                    Spacer()
                    Image(systemName: "chevron.right")
                        // VD-7 (docs/design-review.md, Round 4): matches
                        // `RetroSectionHeader`'s own `Typo.sectionTitle` (relativeTo:
                        // .caption) it sits beside in this row.
                        .scaledFont(12, weight: .semibold, relativeTo: .caption)
                        // Review 2026-08-19: was `.opacity(0.6)` — 2.50:1 against Light
                        // theme's paper and 3.00:1 against Dark's espresso, i.e. at or
                        // under WCAG 1.4.11's 3:1 floor for non-text UI. It's the only
                        // affordance signalling this whole row is tappable, so full
                        // `shelfMuted` (5.60:1 / 6.24:1) it is; it still reads as quiet
                        // next to the cream title beside it.
                        .foregroundStyle(Color.shelfMuted)
                }

                // Review 2026-08-19: with all four columns present this row already
                // overflowed at the DEFAULT text size — 3×20pt of spacing inside a
                // 20pt-margin page leaves roughly 69pt per column on a 375pt-wide
                // phone, and "Longest Session" alone wants ~85pt at 11pt, so the two
                // rightmost labels were being compressed on the most common device
                // width. Three changes rather than one: `.top` alignment so wrapped
                // labels hang off a shared baseline instead of re-centering their
                // column against the taller neighbour, tighter 14pt gaps to buy back
                // 18pt, and (in `statColumn`) two-line wrapping so a long label
                // resolves by going taller rather than by truncating. Dynamic Type is
                // clamped the same way `CassetteTile` clamps its own grid-critical
                // text — the row still scales, it just can't shatter a four-column
                // layout at the largest accessibility sizes.
                // Critique 2026-10-05 (Home): the AX1 clamp is gone. At accessibility sizes
                // the four columns stack vertically instead (labels beside values would
                // not fit a row), so text can scale fully rather than being capped.
                let columnsLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                columnsLayout {
                    if let minutesLabel {
                        statColumn(value: minutesLabel, label: "Listened")
                    }
                    if stats.streakDays > 0 {
                        statColumn(value: "\(stats.streakDays)", label: "Day Streak")
                    }
                    if let longest = stats.longestSessionMinutes {
                        statColumn(value: String(localized: "\(longest)m", comment: "Compact duration: minutes"), label: "Longest Session")
                    }
                    if let timeOfDay = stats.timeOfDay {
                        statColumn(value: Self.timeOfDayLabel(timeOfDay), label: "Usually Listens")
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Your week: \(accessibilitySummary). View full stats."))
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let minutesLabel { parts.append(String(localized: "\(minutesLabel) listened", comment: "VoiceOver: %@ is a duration like 2h 5m")) }
        if stats.streakDays > 0 { parts.append(String(localized: "\(stats.streakDays) day streak", comment: "VoiceOver: listening streak in days")) }
        if let longest = stats.longestSessionMinutes { parts.append(String(localized: "longest session \(longest) minutes", comment: "VoiceOver: longest listening session")) }
        if let timeOfDay = stats.timeOfDay { parts.append(Self.timeOfDaySpoken(timeOfDay)) }
        return parts.joined(separator: ", ")
    }

    /// Batch 400: `ListeningStatistics.timeOfDay` is one of four English words from
    /// `ShareCard` (deliberately not localised there), so Home maps it to its own strings.
    static func timeOfDayLabel(_ value: String) -> String {
        switch value {
        case "Morning": return String(localized: "Morning", comment: "Home Your Week: the part of the day you usually listen")
        case "Afternoon": return String(localized: "Afternoon", comment: "Home Your Week: the part of the day you usually listen")
        case "Evening": return String(localized: "Evening", comment: "Home Your Week: the part of the day you usually listen")
        case "Night": return String(localized: "Night", comment: "Home Your Week: the part of the day you usually listen")
        default: return value
        }
    }

    /// The VoiceOver form, one whole phrase per value so word order can change.
    static func timeOfDaySpoken(_ value: String) -> String {
        switch value {
        case "Morning": return String(localized: "usually listens in the morning", comment: "VoiceOver, Home Your Week summary fragment")
        case "Afternoon": return String(localized: "usually listens in the afternoon", comment: "VoiceOver, Home Your Week summary fragment")
        case "Evening": return String(localized: "usually listens in the evening", comment: "VoiceOver, Home Your Week summary fragment")
        case "Night": return String(localized: "usually listens at night", comment: "VoiceOver, Home Your Week summary fragment")
        default: return value
        }
    }

    private func statColumn(value: String, label: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Review 2026-08-19: the value was fixed `.font(.system(size: 17))` while
            // the label directly beneath it was already `scaledFont` — so at large
            // Dynamic Type sizes the caption grew and the number it captions did not,
            // inverting the pair's hierarchy inside a single component. 17/`.title3` is
            // exactly `Typo.heroTitle`'s spec, which is the role this number plays here
            // (the prominent figure in its column), so it routes through that token
            // rather than adding a fourth independent spelling of the same size.
            // Critique 2026-10-05 (Home): cream, not amber: these figures are descriptive
            // stats, not an action or live state.
            Typo.heroTitle(Text(value))
                .foregroundStyle(Color.shelfCream)
            Text(label)
                .scaledFont(11, relativeTo: .caption)
                .foregroundStyle(Color.shelfMuted)
                // See the row's own comment: a long label ("Longest Session", "Usually
                // Listens") resolves by wrapping to a second line rather than
                // truncating mid-word. `fixedSize(vertical:)` is what actually lets it
                // claim that second line inside an `HStack`, which would otherwise hold
                // every column to one line's height.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Home Customisation Sheet

struct HomeCustomizeSheet: View {
    /// The sections available right now, already in the current display order
    /// (`HomeView.customizableSections`, which is `orderedSectionKeys` mapped to
    /// titles). Seeds `rows` on appear; `rows` then owns the live drag-reorder state
    /// so `.onMove` has something mutable to reorder without fighting the parent's
    /// own recomputation of `availableSections` on every render.
    let availableSections: [(key: String, title: String)]
    @Binding var hidden: Set<String>
    @Binding var order: [String]
    /// N1 (REVIEW 2026-11-11): the opt-in shelves, which `availableSections` leaves out while they have no content.
    var moreShelves: [HomeMoreShelves.Row] = []
    /// Dismisses the sheet and opens that Settings page.
    var openSettings: (SettingsPage) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(key: String, title: String)] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                List {
                    Section {
                        ForEach(rows, id: \.key) { section in
                            Toggle(isOn: Binding(
                                get: { !hidden.contains(section.key) },
                                set: { show in
                                    if show { hidden.remove(section.key) }
                                    else { hidden.insert(section.key) }
                                    SettingsStore.setHomeSection(section.key, hidden: !show)
                                    Haptics.selection()
                                }
                            )) {
                                Text(section.title).foregroundStyle(Color.shelfCream)
                            }
                        }
                        .onMove(perform: move)
                    } header: {
                        RetroSectionHeader(title: LocalizedStringResource("Show & Reorder", comment: "Section header in the Customize Home sheet"))
                    } footer: {
                        Text("Hidden shelves stay on your server — this only changes what appears here. Drag the handles to reorder.")
                            .foregroundStyle(Color.shelfMuted)
                    }
                    .listRowBackground(Color.shelfCard)
                    if !moreShelves.isEmpty {
                        Section {
                            ForEach(moreShelves) { shelf in
                                Button {
                                    Haptics.selection()
                                    openSettings(shelf.settingsPage)
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Typo.rowTitle(Text(shelf.title)).foregroundStyle(Color.shelfCream)
                                            Typo.supporting(Text(shelf.stateText)).foregroundStyle(Color.shelfMuted)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(Color.shelfMuted)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(shelf.hint)
                            }
                        } header: {
                            RetroSectionHeader(title: LocalizedStringResource("More Shelves", comment: "Section header in the Customize Home sheet: opt-in shelves that only appear once switched on"))
                        } footer: {
                            Text("These shelves are off until you set them up. Release Radar asks Audible\u{2019}s public catalogue about series names in your library.")
                                .foregroundStyle(Color.shelfMuted)
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                }
                .scrollContentBackground(.hidden)
                // Reorder handles only render while a List is in edit mode; there's no
                // separate delete/insert affordance here (no swipe-to-delete row action
                // is configured), so keeping edit mode permanently on just shows the
                // drag handle — no Edit/Done toggle needed alongside the Toggle rows.
                .environment(\.editMode, .constant(.active))
            }
            .navigationTitle("Customise Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }.monochromeToolbarItem()
                }
            }
        }
        .onAppear {
            // Finding 22 (code review, 26 August 2026): was `if rows.isEmpty`, which
            // only seeded once — reopening this sheet after a new section finished
            // loading (e.g. "Your Week") kept showing the stale list until the app
            // relaunched, since `rows` was never empty on the second open. Reseeding
            // unconditionally on every appear is safe: `rows` only exists to give
            // `.onMove` something mutable to drag-reorder, not to preserve
            // in-progress edits across sheet dismissals.
            rows = availableSections
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
        let newOrder = rows.map { $0.key }
        order = newOrder
        SettingsStore.setHomeSectionOrder(newOrder)
        Haptics.selection()
    }
}

// MARK: - More Shelves (N1, REVIEW 2026-11-11)

/// The opt-in Home shelves that Customise Home's main list can't show while they are empty, and
/// where each is switched on. Pure so `Top10HomeShelvesTests` can pin it. Release Radar needs more
/// than a switch (it runs a check against Audible), and Household needs an iCloud group, so each
/// row opens its Settings page rather than carrying a bare toggle.
enum HomeMoreShelves {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case releaseRadar, household }
        let kind: Kind
        let stateText: String
        var id: Kind { kind }
        var settingsPage: SettingsPage { kind == .releaseRadar ? .releaseRadar : .household }
        var title: String {
            switch kind {
            case .releaseRadar: return String(localized: "Release Radar", comment: "Home shelf title: upcoming books in the user's series")
            case .household: return String(localized: "Household", comment: "Home shelf title: what household members are listening to and recommend")
            }
        }
        var hint: String {
            switch kind {
            case .releaseRadar: return String(localized: "Opens Release Radar settings", comment: "VoiceOver hint on a Customise Home row")
            case .household: return String(localized: "Opens Household settings", comment: "VoiceOver hint on a Customise Home row")
            }
        }
    }

    /// Release Radar is always listed (Off, On with nothing yet, or On and shown above). Household is
    /// listed only while there is no household to show (once in one it is in the main list), and never
    /// on a kid profile, where the shelf is unavailable.
    static func rows(releaseRadarEnabled: Bool, releaseRadarHasEntries: Bool,
                     isInHousehold: Bool, isKidProfile: Bool) -> [Row] {
        var out: [Row] = []
        let radarState: String
        if !releaseRadarEnabled {
            radarState = String(localized: "Off \u{00B7} Set up in Settings", comment: "Customise Home: Release Radar is off")
        } else if releaseRadarHasEntries {
            radarState = String(localized: "On \u{00B7} Shown above", comment: "Customise Home: Release Radar is on and has a shelf")
        } else {
            radarState = String(localized: "On \u{00B7} Nothing to show yet", comment: "Customise Home: Release Radar is on but found nothing")
        }
        out.append(Row(kind: .releaseRadar, stateText: radarState))
        if !isInHousehold && !isKidProfile {
            out.append(Row(kind: .household,
                           stateText: String(localized: "Join or create a household in Settings", comment: "Customise Home: Household shelf needs a household")))
        }
        return out
    }
}

#Preview {
    HomeView()
        .environment(LibraryViewModel())
        .environment(PlayerViewModel())
        .environment(TabRouter())
}

// MARK: - Pure Home decisions (Critique 2026-10-05, Home)

/// Pure decisions behind Home's NOW zone, first-load failure state and BROWSE header,
/// split out of `HomeView` so they can be pinned by `HomeStateTests`.
enum HomeState {
    /// Progress at or above this counts as finished (matches `DownloadedBook.asLibraryItem`).
    static let finishedThreshold = 0.99

    struct DownloadCandidate: Equatable {
        let id: String
        let progress: Double
        let lastUpdate: Int?
    }

    enum HeroChoice: Equatable {
        /// The server's Continue Listening shelf has books and the loaded book (if any)
        /// is not an unfinished one that should lead.
        case server
        /// Critique 2026-10-05 (Home, 2nd): the loaded, unfinished book leads (the
        /// restored/last-played book the mini player shows); a non-empty server shelf
        /// follows it, minus that book.
        case currentBook
        /// No current book: the most recently played, unfinished download.
        case downloaded(id: String)
        case none
    }

    /// Which source the NOW-zone hero comes from. The loaded book leads whenever it is
    /// unfinished (so a book started elsewhere is not shadowed by a stale server shelf);
    /// otherwise the server shelf; otherwise the most recently played download that is
    /// started but not finished (ties keep the earlier entry).
    static func heroChoice(serverHasItems: Bool,
                           currentBookID: String?,
                           currentBookProgress: Double?,
                           downloads: [DownloadCandidate]) -> HeroChoice {
        if currentBookID != nil, (currentBookProgress ?? 0) < finishedThreshold {
            return .currentBook
        }
        if serverHasItems { return .server }
        var best: DownloadCandidate?
        for candidate in downloads where candidate.progress > 0 && candidate.progress < finishedThreshold {
            if let current = best {
                if (candidate.lastUpdate ?? 0) > (current.lastUpdate ?? 0) { best = candidate }
            } else {
                best = candidate
            }
        }
        if let best { return .downloaded(id: best.id) }
        return .none
    }

    /// Batch 490 (REVIEW 2026-11-11 V8): Home's greeting for an hour of the day (0–23). The late
    /// slot (9pm–5am) was "Night owl mode", which read as a setting rather than a greeting; it is
    /// "Good evening" now, like 5pm–9pm. Pinned by `QuickWinsShellTests`.
    static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: return String(localized: "Good morning")
        case 12..<17: return String(localized: "Good afternoon")
        default: return String(localized: "Good evening")
        }
    }

    enum EmptyKind: Equatable {
        case offline
        case serverUnreachable
        /// Reachable, but the personalized-shelf request itself failed.
        case loadFailed
        /// The load succeeded and the server returned no libraries for this account.
        case noLibraries
        case genuinelyEmpty
    }

    /// With nothing to show, was it a load failure, an account with no libraries, or a
    /// genuinely empty library? `loadFailed` is `LibraryViewModel.personalizedLoadFailed`.
    /// Reachability problems win (they have their own copy), then an explicit failure,
    /// then "no libraries" (nothing to select), then genuinely empty.
    static func emptyKind(reachability: ReachabilityStore.Status, loadFailed: Bool,
                          hasLibraries: Bool, hasSelectedLibrary: Bool) -> EmptyKind {
        switch reachability {
        case .offline: return .offline
        case .serverUnreachable: return .serverUnreachable
        case .ok:
            if loadFailed { return .loadFailed }
            if !hasLibraries { return .noLibraries }
            return hasSelectedLibrary ? .genuinelyEmpty : .loadFailed
        }
    }

    /// Whether Home should show the compact "couldn't refresh" card below the hero when
    /// there is still content to show (downloads, a restored book, narrators, stats).
    /// Offline is left to the persistent connectivity banner.
    static func showsCompactLoadFailure(kind: EmptyKind, hasServerShelves: Bool) -> Bool {
        guard !hasServerShelves else { return false }
        switch kind {
        case .serverUnreachable, .loadFailed: return true
        case .offline, .noLibraries, .genuinelyEmpty: return false
        }
    }

    // MARK: Play control (shared by the hero and Also in Progress rows)

    /// Critique 2026-10-06 (clarify): the header over the other in-progress books under the
    /// hero. Not "Up Next", which names the play queue everywhere else.
    static var alsoInProgressTitle: String { String(localized: "Also in Progress") }

    /// What the hero's labelled button does (see `ContinueListeningHeroCard.heroButton`).
    enum HeroButton: Equatable {
        /// Another book or nothing is loaded: start this one.
        case play
        /// The hero is the loaded book: the mini player is its transport, so open the player.
        case openPlayer

        var title: String { self == .openPlayer ? String(localized: "Open Player") : String(localized: "Play", comment: "Verb: button that starts playback") }
        var glyph: String { self == .openPlayer ? "chevron.up" : "play.fill" }
    }

    static func heroButton(isCurrent: Bool) -> HeroButton {
        isCurrent ? .openPlayer : .play
    }

    static func heroButtonAccessibilityLabel(_ button: HeroButton, title: String, anotherLoaded: Bool) -> String {
        switch button {
        case .openPlayer: return String(localized: "Open Player, \(title)", comment: "VoiceOver: %@ is a book title")
        case .play: return anotherLoaded ? String(localized: "Play \(title) instead", comment: "VoiceOver: %@ is a book title; another book is currently loaded") : String(localized: "Play \(title)", comment: "VoiceOver: %@ is a book title")
        }
    }

    /// Critique 2026-10-06 (clarify): the account has no libraries. The fix is on the server
    /// (add a library, or get access to one), not in this app's Settings, so the primary action
    /// is Check Again and the copy says where to look.
    static var noLibrariesTitle: String { String(localized: "No libraries on this server") }
    static var noLibrariesMessage: String { String(localized: "Add a library on your Audiobookshelf server, or ask its admin for access. Then check again.") }
    static var noLibrariesAction: String { String(localized: "Check Again") }

    /// "Pause" while this book is playing, "Resume" when it is loaded but paused, else "Play".
    static func playVerb(isCurrent: Bool, isPlaying: Bool) -> String {
        isCurrent ? (isPlaying ? String(localized: "Pause", comment: "Verb: button that pauses playback") : String(localized: "Resume", comment: "Verb: button that resumes playback")) : String(localized: "Play", comment: "Verb: button that starts playback")
    }

    static func playGlyph(isCurrent: Bool, isPlaying: Bool) -> String {
        isCurrent && isPlaying ? "pause.fill" : "play.fill"
    }

    /// VoiceOver label for a row's play button. When a different book is loaded, tapping
    /// switches books, so say so ("Play X instead").
    static func playButtonLabel(title: String, isCurrent: Bool, isPlaying: Bool, anotherLoaded: Bool) -> String {
        if isCurrent { return String(localized: "\(playVerb(isCurrent: true, isPlaying: isPlaying)) \(title)", comment: "VoiceOver: %1$@ is a verb (Pause or Resume), %2$@ is a book title") }
        return anotherLoaded ? String(localized: "Play \(title) instead", comment: "VoiceOver: %@ is a book title; another book is currently loaded") : String(localized: "Play \(title)", comment: "VoiceOver: %@ is a book title")
    }

    /// BROWSE gets its own caps header only when the first browse shelf has none of its
    /// own (the bare B-Side row); otherwise two caps labels would stack.
    static func browseNeedsOwnHeader(firstKey: String?) -> Bool {
        firstKey == HomeView.bSideKey
    }

    // MARK: Batch 496 (REVIEW 2026-11-11 N4): shelf caps and See all

    /// Rows under the hero before "Also in Progress" needs See all.
    static let alsoInProgressRowCap = 3
    /// Tiles in the Downloaded shelf; See all (Downloads) has the rest.
    static let downloadedTileCap = 12

    enum SeeAllDestination: Equatable {
        /// The library, newest first (`HomeRecentlyAddedPage`).
        case recentlyAdded
        /// Library's Series grid (`HomeSeriesPage`).
        case series
        /// The Downloads screen (`DownloadsView`).
        case downloads
        /// Every other in-progress book (`HomeAlsoInProgressPage`).
        case alsoInProgress
        /// Batch 497 (N4): every finished book, most recently finished first
        /// (`HomeRecentlyAddedPage(shelf: .listenAgain)`).
        case listenAgain
        /// Batch 497 (N4): Library's Narrators list, starred narrators first
        /// (`HomeNarratorsPage`). The shelf already shows every book it loaded; the full set
        /// would mean paging each narrator separately, so this goes to the narrators instead.
        case narrators
    }

    /// Batch 497 (N4): the server query behind a paged See all page: `/api/libraries/<id>/items`
    /// with this sort, direction and `filter`.
    struct PagedShelfQuery: Equatable {
        let sort: String
        let desc: Bool
        let filter: String?
    }

    /// Batch 497 (N4): the paged query for a See all destination, or nil when it isn't a
    /// paged page. Listen Again is the server's own shelf query (Audiobookshelf
    /// `libraryFilters.getMediaFinished`: `progress` filter `finished`), sorted by
    /// `progress.finishedAt` (`libraryItemsBookFilters.getOrder`) so the latest finish leads.
    static func pagedQuery(for destination: SeeAllDestination) -> PagedShelfQuery? {
        switch destination {
        case .recentlyAdded:
            return PagedShelfQuery(sort: LibrarySort.addedAt.rawValue, desc: true, filter: nil)
        case .listenAgain:
            return PagedShelfQuery(sort: "progress.finishedAt", desc: true,
                                   filter: LibraryProgressFilter.finished.filterValue)
        case .series, .downloads, .alsoInProgress, .narrators:
            return nil
        }
    }

    /// The first `cap` items (none for a negative cap).
    static func capped<T>(_ items: [T], to cap: Int) -> [T] {
        Array(items.prefix(max(cap, 0)))
    }

    /// Which BROWSE shelves get a See all. Discover (random by design), a server's own labels
    /// and the app's own shelves other than Downloaded and the narrator shelf get none.
    static func seeAllDestination(forSectionKey key: String) -> SeeAllDestination? {
        switch key {
        case "LabelRecentlyAdded": return .recentlyAdded
        case "LabelContinueSeries": return .series
        case HomeView.downloadedShelfKey: return .downloads
        case "LabelListenAgain": return .listenAgain        // Batch 497 (N4)
        case HomeView.narratorShelfKey: return .narrators   // Batch 497 (N4)
        default: return nil
        }
    }

    /// "Also in Progress" gets See all only when it holds more books than it shows.
    static func alsoInProgressHasSeeAll(otherCount: Int) -> Bool {
        otherCount > alsoInProgressRowCap
    }

    /// VoiceOver label for a See all link: names the shelf, not just "See all".
    static func seeAllAccessibilityLabel(_ destination: SeeAllDestination) -> String {
        switch destination {
        case .recentlyAdded: return String(localized: "See all recently added", comment: "VoiceOver: Home's Recently Added shelf link to the whole library, newest first")
        case .series: return String(localized: "See all series", comment: "VoiceOver: Home's Next in Series shelf link to the Series list")
        case .downloads: return String(localized: "See all downloaded books", comment: "VoiceOver: Home's Downloaded shelf link to the Downloads screen")
        case .alsoInProgress: return String(localized: "See all books in progress", comment: "VoiceOver: Home's Also in Progress link to every in-progress book")
        case .listenAgain: return String(localized: "See all finished books", comment: "VoiceOver: Home's Listen Again shelf link to every finished book, most recently finished first")
        case .narrators: return String(localized: "See all narrators", comment: "VoiceOver: Home's From Narrators You Follow shelf link to the Narrators list")
        }
    }

    /// Recently Added's full page: another page to fetch while fewer than `total` are
    /// loaded and the last page wasn't empty (a server that under-reports can't loop).
    static func recentlyAddedHasMore(loaded: Int, total: Int, lastPageCount: Int) -> Bool {
        lastPageCount > 0 && loaded < total
    }

    // MARK: Batch 496 (REVIEW 2026-11-11 N5): the profile button

    /// Home's profile button: shown when there is someone to switch to (more than one saved
    /// account) or a child profile exists, and never while App Lock is locked.
    static func showsProfileButton(savedAccountCount: Int, hasAnyKid: Bool, isAppLocked: Bool) -> Bool {
        guard !isAppLocked else { return false }
        return savedAccountCount > 1 || hasAnyKid
    }

    enum PlaybackState: Equatable { case none, playing, paused }

    private static func spokenDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? String(localized: "1 hour") : String(localized: "\(hours) hours")) }
        if minutes > 0 { parts.append(minutes == 1 ? String(localized: "1 minute") : String(localized: "\(minutes) minutes")) }
        return parts.isEmpty ? String(localized: "less than a minute") : parts.joined(separator: " ")
    }

    /// Composite VoiceOver label for the hero card.
    static func heroAccessibilityLabel(title: String, author: String, progress: Double,
                                       remainingSeconds: Double?, playback: PlaybackState) -> String {
        var parts = [title, author]
        let pct = Int(min(max(progress, 0), 1) * 100)
        parts.append(pct >= 1 ? String(localized: "\(pct) percent through", comment: "VoiceOver: book progress; %lld is a percentage") : (progress > 0 ? String(localized: "just started", comment: "VoiceOver: book progress") : String(localized: "not started", comment: "VoiceOver: book progress")))
        if let remainingSeconds, remainingSeconds > 0 { parts.append(String(localized: "\(spokenDuration(remainingSeconds)) left", comment: "VoiceOver: %@ is a spoken duration such as 2 hours 5 minutes")) }
        switch playback {
        case .playing: parts.append(String(localized: "now playing", comment: "VoiceOver status"))
        case .paused: parts.append(String(localized: "paused", comment: "VoiceOver status"))
        case .none: break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Polish pass (J3-1): reads the playback tick on Home's behalf so `HomeView.body` doesn't. It
/// draws nothing; its own body re-runs per tick (trivially cheap), and `reachedFinish` is only
/// written when the "past the finished threshold" answer actually changes.
private struct NowZoneFinishedProbe: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Binding var reachedFinish: Bool?

    var body: some View {
        let duration = playerViewModel.duration
        let answer: Bool? = duration > 0
            ? playerViewModel.currentTime / duration >= HomeState.finishedThreshold
            : nil
        return Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: answer, initial: true) { _, newValue in
                if reachedFinish != newValue { reachedFinish = newValue }
            }
            .accessibilityHidden(true)
    }
}
