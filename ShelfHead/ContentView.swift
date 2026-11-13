import SwiftUI
import os
import CoreSpotlight
import Combine
import Intents
// HIG audit 2026-09-17 M1(b): needed for `UIResponder.keyboardWill{Show,Hide}Notification`
// — there's no SwiftUI-native way to observe "is the software keyboard visible right now"
// app-wide (short of threading `@FocusState` through every text field), so this is the
// unavoidable exception CLAUDE.md carves out for "no SwiftUI equivalent" UIKit imports.
import UIKit

struct ContentView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCheckingSession = true
    @State private var appLock = AppLockManager.shared
    /// Batch 490 (REVIEW 2026-11-11 E1): links that arrive before the main tabs exist (splash,
    /// sign-in, the launch profile picker) wait here instead of being dropped; `MainTabView`
    /// takes them once it's on screen.
    @State private var linkInbox = IncomingLinkInbox.shared
    /// SEC-3: separate from `appLock.isLocked`, which only flips on `.background` (by
    /// design — flipping on `.inactive` would flash the lock screen for transient
    /// interruptions like the volume HUD). The cost of that deliberate `.background`
    /// choice is that iOS captures the app-switcher snapshot during the
    /// `.inactive`→`.background` transition, before `AppLockView` is composited — so
    /// with App Lock on, the current book/position/library were still visible in the
    /// multitasking switcher. This flips as soon as the scene leaves `.active` (not
    /// waiting for `.background`) purely to blank the snapshot, independent of the
    /// interactive lock's own timing.
    @State private var obscureForSnapshot = false
    /// Batch 457: the launch profile picker shows once per process, only when turned on in Settings › Household › Kids.
    @State private var profilePickerDone = false
    // HIG audit 2026-09-17 M6 (lowest priority — transient splash, kept tiny): these were
    // fixed `.system(size:)` literals that never grew with Dynamic Type.
    @ScaledMetric private var splashGlyphSize: CGFloat = 48
    @ScaledMetric private var splashTitleSize: CGFloat = 22

    var body: some View {
        ZStack {
            Group {
                if isCheckingSession {
                    // Splash / loading state — prevents login screen flash. LS-3 (docs/
                    // design-review.md, Round 3): this now only covers the Keychain
                    // restore in `checkExistingSession()` — the server round-trip that
                    // verifies the restored session moved to a background task, so this
                    // is brief even offline. It can still occasionally take over a second
                    // on a slow Keychain, hence the delayed spinner below.
                    ZStack {
                        Color.shelfBackground.ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "headphones.circle.fill")
                                .font(.system(size: splashGlyphSize))
                                .foregroundStyle(Color.shelfAmberText)
                            Text("ShelfHead")
                                .font(.system(size: splashTitleSize, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.shelfAmberText)
                            // LS-3: the placeholder (`EmptyView`) and the `ProgressView`
                            // are both mounted from the first frame — only their opacity
                            // crossfades after `delay` — so this slot is already sized to
                            // the spinner and nothing shifts when it fades in at ~1 s.
                            DelayedProgressView(delay: .seconds(1)) {
                                ProgressView()
                                    .shelfSpinner()   // LS-15: shared brand-spinner tint
                                    .accessibilityLabel("Loading")
                            }
                        }
                    }
                } else if authViewModel.isAuthenticated {
                    if SettingsStore.showProfilePickerAtLaunch && !profilePickerDone {
                        ProfilePickerView { profilePickerDone = true }
                    } else {
                        MainTabView()
                    }
                } else {
                    LoginView()
                }
            }

            // Optional Face ID/Touch ID/passcode gate (Settings > Account & Security).
            // Only relevant once signed in — the login screen itself has nothing to
            // protect. Sits above everything at a high zIndex so it fully covers the
            // mini-player/full-player/banners too.
            if authViewModel.isAuthenticated, appLock.isLocked || obscureForSnapshot {
                // `showsPrompt: false` for the snapshot-only case: no Face ID prompt
                // should fire just because the app is momentarily inactive (a
                // notification center pull-down, a system sheet), only a blank cover.
                AppLockView(showsPrompt: appLock.isLocked) { Task { await appLock.authenticate() } }
                    .zIndex(1000)
                    .transition(.opacity)
            }
        }
        // UI-12: routed through `shelfAnimation` (rather than `.animation`) so Reduce
        // Motion suppresses these transitions too — previously only 4 of 16 animation
        // sites in the app respected it.
        .shelfAnimation(.easeInOut(duration: 0.3), value: authViewModel.isAuthenticated)
        .shelfAnimation(.easeInOut(duration: 0.2), value: isCheckingSession)
        .shelfAnimation(.easeInOut(duration: 0.2), value: appLock.isLocked)
        .shelfAnimation(.easeInOut(duration: 0.15), value: obscureForSnapshot)
        // Polish pass (J1-1): "Sign In Again" over the running app, never over the App Lock
        // screen. The `!appLock.isLocked` check in `set` stops a lock from counting as
        // "Not Now", so the sheet comes back after unlock.
        .sheet(item: Binding(
            get: { appLock.isLocked ? nil : authViewModel.sessionExpiredPrompt },
            set: { if $0 == nil, !appLock.isLocked { authViewModel.dismissSessionExpiredPrompt() } }
        )) { prompt in
            SessionExpiredSheet(prompt: prompt)
        }
        .task {
            // Polish pass (J2-17): the splash is up from first render until `isCheckingSession` flips below.
            let splashState = LaunchTrace.signposter.beginInterval("SplashShown")
            defer {
                LaunchTrace.signposter.endInterval("SplashShown", splashState)
                LaunchTrace.mark("splashDismissed")
            }
            PlaybackCoordinator.shared.playerViewModel = playerViewModel
            // LS-3: `checkExistingSession()` now only awaits the Keychain restore — it
            // kicks the server verification off in a background task and returns as soon
            // as `isAuthenticated`/`serverURL` are set, so everything below (and
            // `isCheckingSession = false` at the end) no longer waits on a network
            // round-trip. None of it needs `currentUser`/the server-verified `username`
            // that verification fetches: `reloadForActiveScope()` and
            // `restoreLastSession()`/`adoptActiveSessionIfNeeded()` key off
            // `AuthStore`'s serverURL and `AccountStore.currentAccountId` (both already
            // set by the Keychain restore above), and `lockIfNeeded()` only reads
            // `SettingsStore.appLockEnabled`. If a restored session turns out to be
            // rejected, `verifyRestoredSession(generation:)` signs it out from whatever
            // screen is showing by then, the same way an expired session is discovered
            // any other time the app is already running.
            await authViewModel.checkExistingSession()
            // Restore the last-played book into the mini-player (paused, ready to resume)
            // so a relaunch after iOS reclaimed the app picks up where you left off.
            if authViewModel.isAuthenticated {
                // Batch 457: a child's account with Bedtime Story ticked gets that profile from launch.
                KidProfileCoordinator.applyProfile(forAccountId: AccountStore.currentAccountId)
                // Load the active account's downloads (and run the one-time legacy migration)
                // now that the server/user are known.
                //
                // Polish pass (J2-5/J2-6): `ShelfHeadApp.init` already ran
                // `DownloadManager.bootstrapIfNeeded()` (via `ensureSessionReady()`) for the
                // remembered scope, so a full second reload here repeated the same manifest
                // reads, migrations and orphan sweep before the splash could lift. The reload now
                // only runs when the scope the Keychain restore resolved differs from the one
                // already loaded (`reloadIfScopeChanged()` — what a first sign-in after an update
                // or a headless-launch seed needs). Nothing below depends on the reload: they
                // read the scope key, which is already resolved.
                let scopeState = LaunchTrace.signposter.beginInterval("DownloadScopeLoad")
                DownloadManager.shared.reloadIfScopeChanged()
                LaunchTrace.signposter.endInterval("DownloadScopeLoad", scopeState)
                // Adopt a session already playing (e.g. started from CarPlay) before
                // falling back to restoring the last-played snapshot.
                playerViewModel.adoptActiveSessionIfNeeded()
                playerViewModel.restoreLastSession()
                if playerViewModel.currentBook != nil { LaunchTrace.mark("firstPlayable") }
                // A cold launch is already "returning to the foreground" as far as the
                // lock is concerned — otherwise turning the setting on wouldn't take
                // effect until the *second* time the app is opened. Must still happen
                // before `isCheckingSession = false` below reveals `MainTabView` — this
                // sets `appLock.isLocked` synchronously (no `await` in between), so the
                // `AppLockView` cover in the `ZStack` above is already showing by the
                // same render pass that shows `MainTabView` underneath it.
                appLock.lockIfNeeded()
            }
            isCheckingSession = false
        }
        // Review 4 Medium 2: the picker replaces `MainTabView`, whose receiver does the account-change reset, so a
        // switch made at the picker skipped it. Only acts while the picker is up (MainTabView's receiver otherwise).
        // Libraries aren't loaded here: Home loads them on appear when empty.
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
            guard authViewModel.isAuthenticated, !isCheckingSession,
                  SettingsStore.showProfilePickerAtLaunch, !profilePickerDone else { return }
            Self.resetAccountScopedState(libraryViewModel: libraryViewModel, playerViewModel: playerViewModel,
                                         downloadManager: DownloadManager.shared)
        }
        // Batch 490 (REVIEW 2026-11-11 E1): moved up from `MainTabView` so a link that arrives
        // while it isn't mounted yet is held, not lost. `MainTabView` consumes the inbox and
        // still routes everything through `handleDeepLink` (and so behind App Lock).
        .onOpenURL { url in linkInbox.hold(url) }
        // Batch 497 (REVIEW 2026-11-11 Spotlight): "Search in App" from Spotlight arrives as a
        // CSQueryContinuationActionType activity (needs Info.plist `CoreSpotlightContinuation` = true;
        // harmless without it). Turned into the `shelfhead://search` link and held like any other, so
        // sign-in, the profile picker and App Lock gate it.
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            if let url = SpotlightSearchContinuation.url(activityType: activity.activityType,
                                                         userInfo: activity.userInfo) {
                linkInbox.hold(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // SEC-3: blank the switcher snapshot for any non-`.active` phase — covers
            // the `.inactive` transition the OS actually snapshots during, ahead of
            // `appLock.lockIfNeeded()` below still only firing on `.background`.
            obscureForSnapshot = SettingsStore.appLockEnabled && phase != .active
            if phase == .background {
                appLock.lockIfNeeded()
            } else if phase == .active, appLock.isLocked {
                Task { await appLock.authenticate() }
            }
        }
        // Batch 406 (user report: CarPlay's "Ask Siri" still said the app doesn't support it
        // after Batch 362). Apple's "Requesting Authorization to Use Siri": "Siri can't
        // interact with your app or app extension until the user grants permission", and
        // the app must ask, even when an Intents extension handles the intent. It never did.
        // Asked the first time a book plays in the foreground, so the prompt is in context
        // (not on launch, and never over CarPlay or the lock screen); the system remembers
        // the answer, so later calls are no-ops.
        // Polish pass (J2-17): first moment a book is loaded (restored paused, or adopted/started).
        .onChange(of: playerViewModel.currentBook?.id) { _, id in
            if id != nil { LaunchTrace.mark("firstPlayable") }
        }
        .onChange(of: playerViewModel.isPlaying) { _, playing in
            guard playing, scenePhase == .active, !appLock.isLocked,
                  INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
            INPreferences.requestSiriAuthorization { status in
                ShelfLog.info(.intents, "Siri authorization: \(status.rawValue)")
            }
        }
    }

    /// Review 4 Medium 2: the non-view-state part of the account-change reset, shared by `MainTabView`'s receiver
    /// and `ContentView`'s (while the launch profile picker is showing).
    static func resetAccountScopedState(libraryViewModel: LibraryViewModel, playerViewModel: PlayerViewModel,
                                        downloadManager: DownloadManager) {
        libraryViewModel.resetForAccountChange()
        MixtapePlayer.shared.stop()
        // Batch 457: Bedtime Story on for a child who has it, back to Off when leaving a child.
        KidProfileCoordinator.applyProfile(forAccountId: AccountStore.currentAccountId)
        playerViewModel.currentBook = nil
        playerViewModel.retireUndoOffersForAccountChange()
        // Stop the previous account's downloads and load the new account's scope.
        downloadManager.cancelAllActiveDownloads()
        downloadManager.reloadForActiveScope()
    }
}

/// Polish pass (J2-12): `ReachabilityStore.startPolling()` cancels and restarts its poll, and so
/// fires a `/ping` straight away, every time it's called. A cold launch reached it from both
/// `ContentView.task` and the scenePhase `.active` handler. Both go through here instead, and
/// the background transition (`stop()`) re-arms it for the next foreground.
@MainActor
enum ReachabilityPollGate {
    private static var isPolling = false

    static func start(_ store: ReachabilityStore = .shared) {
        guard !isPolling else { return }
        isPolling = true
        store.startPolling()
    }

    static func stop(_ store: ReachabilityStore = .shared) {
        isPolling = false
        store.stopPolling()
    }
}

/// Critique 2026-10-06 (distill): which tab's navigation stack a screen sits in. Set on each
/// tab's `NavigationStack` (both shells) and inherited by pushed screens, so Book Detail can
/// say which tab it's hiding the mini player in (`MiniPlayerSuppression`). Nil outside a tab.
private struct ShelfTabIndexKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var shelfTabIndex: Int? {
        get { self[ShelfTabIndexKey.self] }
        set { self[ShelfTabIndexKey.self] = newValue }
    }
}

struct MainTabView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Library bulk select is on (`LibrarySelectingPreferenceKey`): the legacy tab bar hides.
    /// The mini player stays (plan §3.2 doesn't hide it).
    @State private var librarySelecting = false
    /// HIG audit 2026-09-17 M1(b): tracks whether the software keyboard is on screen, so
    /// the shake handler below can step aside — shake is the system's own undo/redo
    /// gesture, and a text field (e.g. the bookmark note editor) may have its own live
    /// undo manager that shake is meant to reach instead.
    @State private var keyboardVisible = false
    /// One merged stream for the flag above — `willShow`/`willHide` (not `did`) so it
    /// flips before a shake could plausibly land mid-transition.
    private var keyboardVisibility: AnyPublisher<Bool, Never> {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification).map { _ in true },
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification).map { _ in false }
        ).eraseToAnyPublisher()
    }
    @State private var selectedTab = 0
    /// Batch 444: a file opened in ShelfHead from Files/Share ("Open in") lands on Upload.
    @State private var showUploadSheet = false
    @State private var homeReset = 0
    @State private var libraryReset = 0
    /// Bumped when the Setup (Settings) tab is re-tapped while already active — forces
    /// `SettingsView`'s `.id()` below to rebuild, which recreates its internal
    /// `NavigationStack` from scratch. That pops any pushed page (Account & Security,
    /// Playback, Appearance, etc.) back to the root Settings menu, the same "tap the
    /// active tab to go home" behavior Home and Library already have.
    @State private var settingsReset = 0
    /// Code review fix (26 August 2026): index 2 (`StatsView`) has real navigation
    /// depth (`YearInReviewView`, `AllBookmarksView`) — same `onRetap`/
    /// `selectedTabBinding` wiring Home/Library/Settings already have, so re-tapping
    /// this tab while pushed deep pops back to root instead of doing nothing.
    @State private var listeningReset = 0
    /// D5 (design brief 2026-08-12): per-tab navigation state for the iOS 26
    /// `TabView` path (`modernTabs` below). The legacy path (`legacyTabs`) keeps
    /// using bare `NavigationStack { ... }` + `.id()` bumps instead — these three
    /// are unused there and stay empty for the app's whole lifetime on <iOS 26.
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    /// Code review fix (26 August 2026): companion to `listeningReset` above, for the
    /// modern (iOS 26+) tab path — same role `homePath`/`libraryPath`/`settingsPath`
    /// play for their tabs.
    @State private var listeningPath = NavigationPath()
    /// Batch 496 (REVIEW 2026-11-11 N6): the iOS 26 Search tab (value 4): its stack and its
    /// field. Unused on the legacy shell, where search stays in Library.
    @State private var searchPath = NavigationPath()
    @State private var searchTab = SearchTabModel()
    /// iPhone Duo (§3, docs/iphone-duo-readiness-2026-10-22.md): the book in Library's
    /// detail column on the inner display (`librarySplitView`). Only set at regular width,
    /// and it outlives a fold: collapsing shows it over the Library root, and Back clears it.
    @State private var libraryDetailItem: LibraryItem?
    /// iPhone Duo (§3): the split view's top column once collapsed (outer display). Follows
    /// `libraryDetailItem`, and the system writes `.sidebar` back when Back pops the book.
    @State private var libraryCompactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var downloadManager = DownloadManager.shared
    /// S1 (REVIEW_2026-08-20_UI_SECURITY.md): same singleton `ContentView` reads to decide
    /// whether to show `AppLockView`. `MainTabView` needs its own reference too — this is
    /// where `handleDeepLink`, both `onContinueUserActivity` handlers, and the
    /// `deepLinkedItem` sheet actually live, so this is where they get gated and where a
    /// queued `pendingAction` gets replayed once `isLocked` flips back to `false`.
    @State private var appLock = AppLockManager.shared
    /// Drives the F10 offline/server-unreachable banner.
    @State private var reachability = ReachabilityStore.shared
    /// Design review 2026-09-23 AN-4: the status actually shown by `ConnectivityBanner`
    /// below. Follows `reachability.status` immediately for `.offline`/`.ok` (device-
    /// offline and recovery should never be delayed), but a transition INTO
    /// `.serverUnreachable` is only adopted if the store is still unreachable 1.5s
    /// later — see the `.task(id: reachability.status)` in `body` — so a single failed
    /// ping doesn't flash the banner. `ReachabilityStore` itself is untouched; this is a
    /// view-layer debounce only.
    /// Critique 2026-10-06 (harden): the debounce moved into the shared `DisplayedReachability`
    /// so Driving Mode reads the same debounced status as the banner.
    @State private var displayedReachability = DisplayedReachability.shared
    private var displayedReachabilityStatus: ReachabilityStore.Status { displayedReachability.status }
    /// The connectivity banner's own height, so the full player can sit below it rather
    /// than under it (critique 2026-10-05). 0 while the banner is empty.
    @State private var connectivityBannerHeight: CGFloat = 0
    /// Batch 321: the value `modernTabs` hands `.tabBarMinimizeBehavior(...)`. Held as
    /// `@State` (rather than read statically at the use site) so `@Observable` tracking
    /// actually invalidates the TabView when `suspended` flips — a static read is
    /// invisible to SwiftUI, the same trap `accentHex` documents above. See
    /// `TabBarMinimizeCoordinator` in `Extensions.swift` for the whole mechanism.
    @State private var tabBarMinimize = TabBarMinimizeCoordinator.shared
    /// Batch 218 (R10.8): shared in-process tab-switch request box — see `TabRouter`'s
    /// own doc comment. Injected into both tab-shell branches below via `.environment`.
    @State private var tabRouter = TabRouter()
    /// A book opened via deep link / Spotlight / Handoff, shown in a sheet.
    @State private var deepLinkedItem: LibraryItem?
    /// Batch 458: a `shelfhead://mixtape?…` link, decoded, waiting for its import sheet.
    @State private var pendingMixtape: DecodedMixtapeLink?
    /// Batch 490 (REVIEW 2026-11-11 E1): a link that led nowhere (a removed book, a bad
    /// mixtape) says so in a toast instead of doing nothing.
    @State private var linkFailureMessage: String?
    /// Batch 490 (REVIEW 2026-11-11 E1): see `ContentView.linkInbox`.
    @State private var linkInbox = IncomingLinkInbox.shared
    /// Batch 490 (REVIEW 2026-11-11 F25): What's New after an update, once, over the tabs.
    @State private var showWhatsNew = false
    @Environment(AuthViewModel.self) private var authViewModel
    /// Measured height of the mini-player + tab bar, used as explicit bottom
    /// clearance for the ScrollView-based tabs (List-based Setup gets it for free).
    @State private var barHeight: CGFloat = 0
    /// The current accent hex, from the shared `ThemeStore` (see ThemeStore.swift) rather
    /// than a duplicated `@AppStorage` read. `Color.shelfAmber` resolves from this at
    /// render time but is a static read SwiftUI can't track, so views that aren't
    /// otherwise invalidated keep the old accent. Keying the tabs + bottom bar on it
    /// forces them to rebuild and re-read the accent the moment the user picks a new swatch.
    @Environment(ThemeStore.self) private var themeStore
    /// Fallback for `AppAppearance.system`, where the app defers to the device.
    @Environment(\.colorScheme) private var systemColorScheme

    /// N-6 (REVIEW_2026-09-14_DESIGN.md): runs the versioned Home-shelf seeds
    /// (`SettingsStore.runHomeShelfSeedsIfNeeded()`) before `HomeView` exists.
    ///
    /// They have to land before `HomeView`'s `@State` is seeded from
    /// `hiddenHomeSections`/`homeSectionOrder` — a `@State` default that has already
    /// been evaluated won't pick up a later write, which is the same ordering constraint
    /// `SettingsMigrator`'s own doc comment describes for its steps 1 and 2. This view
    /// constructs `HomeView` in its `body`, so its `init` is strictly earlier; that is
    /// the whole reason the call sits here rather than in `HomeView` itself.
    ///
    /// SwiftUI re-initializes a view value freely, so this runs more than once per
    /// launch. That's fine and intentional: after the first, it is a single
    /// `UserDefaults` integer read that fails the version guard and returns.
    init() {
        SettingsStore.runHomeShelfSeedsIfNeeded()
    }
    private var accentHex: String { themeStore.accentHex }

    // 16 September 2026: Downloads is no longer a top-level tab. The old tab's two
    // jobs already exist elsewhere — browsing downloaded books is Library's
    // `downloadedOnly` filter, and managing transfers/storage is Settings > Downloads
    // (`DownloadsSettingsView`) — so this slot goes to the listening retrospective
    // (`StatsView`: stats, streak, Year in Review, All Bookmarks) instead.
    private let tabs = [
        RetroTabItem(icon: "house.fill", label: "Home"),
        RetroTabItem(icon: "books.vertical.fill", label: "Library"),
        RetroTabItem(icon: "chart.bar.fill", label: "Stats"),
        RetroTabItem(icon: "gearshape.fill", label: "Settings")
    ]

    /// NEW-4 (follow-up review, 14 Aug 2026): `barHeight` only ever gets a real
    /// measurement from the legacy `bottomBar`'s `BottomBarHeightKey` preference —
    /// on iOS 26, `modernTabs` has nothing that writes it, so it stays 0 forever.
    /// The three `.toast(...)` calls in `body` are attached to the outer `ZStack`,
    /// a SIBLING of the TabView (not a descendant), so — unlike Settings/subpages,
    /// which get the system's automatic safe-area inset for free as genuine
    /// TabView children (see `bottomBarClearance`'s iOS 26 branch) — toasts never
    /// inherit that inset either way, and need an explicit value regardless of
    /// which tab path is active. This mirrors the legacy fallback's own intent
    /// (clear whatever's floating at the bottom) but sized for the native tab bar
    /// + `.tabViewBottomAccessory` on iOS 26, which this view has no way to
    /// measure directly from outside the TabView's own layout tree.
    /// VD-1 (docs/design-review.md): the full player's own bottom-safe-area reading,
    /// used only by the `showFullPlayer` branch of `toastBottomInset` below. Read
    /// straight off the key window rather than threaded through a
    /// `GeometryReader`/`PreferenceKey` the way `barHeight` above is — this view has no
    /// reader of its own in its layout tree, and `PlayerView.body` already measures the
    /// same physical inset locally (`geometry.safeAreaInsets.bottom`) for its own
    /// bottom padding, so this is the same number by another route.
    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first?.safeAreaInsets.bottom ?? 0
    }

    /// VD-1: approximate height of the full player's own bottom controls region, above
    /// the safe area — `PlayerView+BottomRegion.swift`'s `bottomGlassRegion`: the sleep-
    /// timer/Up Next status chip row (14pt top padding plus an ~34pt capsule when a chip
    /// is showing) followed by the five-column secondary toolbar (18pt top padding plus
    /// a `toolbarIconSlot`-tall row — 44pt by default — inside its own 10pt top/bottom
    /// padding). That comes to roughly 150pt at the default Dynamic Type size. Not
    /// measured live — doing so would need a `PreferenceKey` inside `PlayerView` itself,
    /// out of scope for this fix — so this is a deliberately generous estimate, sized
    /// for the taller "both chips showing" case, rather than an exact figure.
    ///
    /// Fourth run (critique 2026-10-05): the status chips now carry a 44 pt hit area (14 pt
    /// top padding + 44), so the region is ≈ 58 + 18 + 60 + 10 ≈ 146 pt plus label height;
    /// raised to 160 so a toast clears the tool row's labels on an iPhone SE.
    private static let fullPlayerBottomControlsHeight: CGFloat = 160
    /// VD-1: the review's own suggested "about 24pt" of breathing room above that region.
    private static let fullPlayerToastClearance: CGFloat = 24

    /// Critique 2026-10-05 (Mini player, 2nd): all toasts share one bottom slot; while the Undo
    /// toast is up the others sit above it instead of overlapping it.
    private var otherToastInset: CGFloat {
        // Critique 2026-10-06 (harden): the "Playing instead of … Undo" toast shares the slot.
        let undoShowing = playerViewModel.stopUndoMessage != nil || playerViewModel.replaceUndoMessage != nil
        return toastBottomInset + (undoShowing ? 64 : 0)
    }

    /// Critique 2026-10-06 (harden): a pushed Book Detail hosts the single-book Undo toast itself,
    /// above its pinned Play bar (this root slot only knows the tab bar's height, so the toast
    /// landed on the bar). While one is showing in the selected tab the root copy stands down.
    private var progressUndoBinding: Binding<String?> {
        Binding(
            get: {
                playerViewModel.progressToastHosts.isSuppressed(selectedTab: selectedTab)
                    ? nil : libraryViewModel.progressUndoMessage
            },
            set: { libraryViewModel.progressUndoMessage = $0 }
        )
    }

    private var toastBottomInset: CGFloat {
        // VD-1 (docs/design-review.md): with the full player open, a toast was still
        // clearing the (now hidden) mini player/tab bar underneath it — `barHeight`
        // below is a stale measurement of *that* bar, not of what's actually on screen,
        // which is the player's own sleep/Up Next chips and bottom toolbar. This branch
        // therefore has to run first and win outright, not only be consulted once
        // `barHeight` happens to be 0.
        if playerViewModel.showFullPlayer, playerViewModel.currentBook != nil {
            return bottomSafeAreaInset + Self.fullPlayerBottomControlsHeight + Self.fullPlayerToastClearance
        }
        if barHeight > 0 { return barHeight }
        // LS-2 (docs/design-review.md): `hasMiniPlayer`, not `currentBook != nil` — the
        // mini player now also mounts while a start is in flight, and the toast needs to
        // clear it then too.
        if #available(iOS 26.0, *) {
            return playerViewModel.hasMiniPlayer ? 140 : 70
        }
        // Legacy path startup race — `BottomBarHeightKey`'s first real value
        // hasn't landed yet. Same fallback `bottomBarClearance` uses, same reason.
        return playerViewModel.hasMiniPlayer ? 152 : 88
    }

    /// Critique 2026-10-06 (distill, user decision): the mini player is drawn only while no
    /// Book Detail with a pinned Play bar is showing in the selected tab, so that screen has
    /// one play control. `hasMiniPlayer` itself is untouched (Magic Tap below still keys on
    /// it). iOS 26.0 can't hide the system accessory without the blank-pill bug documented
    /// at `modernTabsWithAccessory`, so it keeps the mini player there.
    private var showsMiniPlayer: Bool {
        let suppressed = playerViewModel.miniPlayerSuppression.isSuppressed(selectedTab: selectedTab)
        let canHide: Bool
        if #available(iOS 26.1, *) {
            canHide = true
        } else if #available(iOS 26.0, *) {
            canHide = false
        } else {
            canHide = true
        }
        return MiniPlayerSuppression.showsMiniPlayer(hasMiniPlayer: playerViewModel.hasMiniPlayer,
                                                     suppressed: suppressed, canHide: canHide)
    }

    /// The floating mini-player + tab pill for the legacy (iOS 17–25) tab shell.
    /// `bottomBar` is only ever referenced from `legacyTabs`'s `.safeAreaInset` below —
    /// `modernTabs` (iOS 26+) uses the native `TabView` + `.tabViewBottomAccessory`
    /// instead (D5 / Batch 163) — so the `#available(iOS 26.0, *)` branch just below,
    /// which wraps the two glass shapes in a `GlassEffectContainer` so they'd blend/morph
    /// when close, can never actually run in the shipping app. Left in place for SwiftUI
    /// previews and in case this view is ever un-gated to run on iOS 26 too. On iOS 17–25,
    /// where this view actually renders, the `else` branch is the only one that ever runs;
    /// an iOS 26 user never reaches this view at all.
    @ViewBuilder private var bottomBar: some View {
        let content = VStack(spacing: 0) {
            // LS-2 (docs/design-review.md): `hasMiniPlayer`, not `currentBook != nil` —
            // mount for a book a start is in flight for too, not only a live session.
            // Critique 2026-10-06 (distill): `showsMiniPlayer` also steps it aside while Book
            // Detail's pinned Play bar is up; it slides like the tab bar does (Book Detail
            // animates the change, Reduce Motion aware).
            if showsMiniPlayer {
                MiniPlayerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // 16 September 2026: index 2's in-flight-download badge moved with the tab
            // it badged — Library's ambient in-flight-downloads row now carries that
            // feedback, so the legacy tab bar needs no per-render badge copy here.
            if !librarySelecting {
                RetroTabBar(selection: legacySelectedTabBinding, items: tabs) { tappedIndex in
                    switch tappedIndex {
                    case 0: homeReset += 1
                    case 1:
                        libraryReset += 1
                        // Batch 490 (REVIEW 2026-11-11 F14): the stack is bound to the path now, so a
                        // remount alone would rebuild it at the same depth.
                        libraryPath = NavigationPath()
                    case 2: listeningReset += 1
                    case 3:
                        settingsReset += 1
                        settingsPath = NavigationPath()
                    default: break
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: BottomBarHeightKey.self, value: geo.size.height)
            }
        )

        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content }
        } else {
            content
        }
    }

    /// D5 (design brief 2026-08-12): binding passed to the iOS 26 `TabView`
    /// below. A `Binding`'s `set` closure fires on every tab-bar interaction,
    /// including re-tapping the tab that's already selected — unlike
    /// `.onChange(of:)`, which only fires on an actual value transition — so
    /// this is what lets re-tapping the active tab pop that tab's
    /// `NavigationStack` back to its root, mirroring the reset-on-reselect
    /// behavior `RetroTabBar`'s `onReselect` callback gives the legacy path via
    /// `homeReset`/`libraryReset`/`settingsReset`.
    private var selectedTabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    // Batch 321: re-tapping the active tab is a "screen appeared" event
                    // as far as the tab bar is concerned — it pops to root and/or
                    // scrolls to top — but it changes no value `.onChange(of:
                    // selectedTab)` below could see, and popping an already-empty
                    // `NavigationPath` isn't a change either. Handled here so that
                    // gesture always brings a minimised bar back too.
                    tabBarMinimize.reexpand()
                    switch newValue {
                    case 0:
                        homePath = NavigationPath()
                        // D5 follow-up: also bumps `HomeView.scrollToTopSignal` (passed
                        // below) so reselecting Home scrolls back to the top, not just
                        // pops navigation depth — see that file's comment for why this
                        // was needed on top of the `NavigationPath` reset alone. Reuses
                        // `homeReset` (already `@State` here for the legacy path) rather
                        // than adding a fourth near-identical counter.
                        homeReset += 1
                    case 1:
                        libraryPath = NavigationPath()
                        // Tab-shell reconciliation (26 August 2026): bumps
                        // `LibraryView.scrollToTopSignal` (passed below) the same way
                        // `homeReset` already does for Home just above — previously
                        // this case only reset navigation depth, with nothing at all
                        // resetting scroll position on the modern tab path. See that
                        // property's own doc comment in `LibraryView.swift` for the
                        // explicit "Books mode's grid/list only" scope boundary.
                        libraryReset += 1
                        // iPhone Duo (§3): the tab's root on the inner display has no book open.
                        libraryDetailItem = nil
                    case 2: listeningPath = NavigationPath()
                    case 3: settingsPath = NavigationPath()
                    case 4: searchPath = NavigationPath()   // Batch 496 (N6)
                    default: break
                    }
                }
                // Batch 457: on a child's account, Settings needs the parent's Face ID or passcode.
                if newValue == 3, selectedTab != 3,
                   ParentGate.settingsNeedGate(activeAccountId: AccountStore.currentAccountId) {
                    Task {
                        if await ParentGate.authenticate(reason: String(localized: "Open Settings", comment: "Face ID / passcode prompt reason")) {
                            selectedTab = 3
                        }
                    }
                    return
                }
                selectedTab = newValue
            }
        )
    }

    /// Review 3 High 1 (30 October 2026): the legacy bar (iOS 17.6–25) bound straight to `selectedTab`, so the
    /// Batch 457 Settings gate above never ran there. Its reselect handling stays in `RetroTabBar.onRetap`.
    private var legacySelectedTabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == 3, selectedTab != 3,
                   ParentGate.settingsNeedGate(activeAccountId: AccountStore.currentAccountId) {
                    Task {
                        if await ParentGate.authenticate(reason: String(localized: "Open Settings", comment: "Face ID / passcode prompt reason")) {
                            selectedTab = 3
                        }
                    }
                    return
                }
                selectedTab = newValue
            }
        )
    }

    /// D5 (design brief 2026-08-12): the existing custom tab shell, completely
    /// unchanged — used on iOS 17.6–25 (the app's deployment target). Extracted
    /// verbatim out of `body` so the iOS 26 path (`modernTabs`) can live
    /// alongside it without disturbing this one at all.
    // P3-20 (third-pass review, 14 Aug 2026), reconciled (26 August 2026):
    // `legacyTabs` (below) and `modernTabs` (below that, iOS 26+) use two genuinely
    // different mechanisms for "reselecting the active tab resets it," not one
    // missing feature — `legacyTabs` re-keys each tab's `.id(...)` on
    // `homeReset`/`libraryReset`/`settingsReset` (via `RetroTabBar`'s `onReselect`),
    // which fully remounts that tab's `NavigationStack` + root view from scratch;
    // that remount already scrolls back to the top as a side effect of being a brand
    // new `ScrollView`/`List` instance, on top of resetting navigation depth. This
    // file's own prior comment claimed reselecting Home did "nothing" on the legacy
    // path — re-checked against the actual code below and that wasn't accurate; the
    // remount already covered it. `modernTabs` instead keeps each tab's `HomeView`/
    // `LibraryView` mounted continuously (so `homePath`/`libraryPath` behave as real,
    // lasting per-tab navigation state) and uses `selectedTabBinding`'s reselect
    // branch to bump `homeReset`/`libraryReset` as a lightweight *signal* into each
    // view's own `scrollToTopSignal` parameter instead of a remount. What WAS a real,
    // now-fixed gap: `selectedTabBinding` bumped `homeReset` on Home reselect but
    // never bumped `libraryReset` on Library reselect, so re-tapping Library on
    // iOS 26+ reset navigation depth but left scroll position untouched — Library
    // now gets the identical signal-based wiring Home already had (see
    // `LibraryView.scrollToTopSignal`'s own doc comment for the exact scope: Books
    // mode's grid/list only, not the other five browse modes).
    // The other named divergence — `modernTabs` never passing `LibraryView` (or
    // `HomeView`) a `bottomInset:` — is left as-is, correctly: on iOS 26+,
    // `.tabViewBottomAccessory` below already reserves that space automatically as a
    // real system safe-area inset, so an explicit `bottomInset` there would double
    // -count the clearance rather than fix a gap. Only `legacyTabs`'s custom
    // `bottomBar` (no automatic inset of its own) needs the manually-measured
    // `barHeight` passed through.
    @ViewBuilder private var legacyTabs: some View {
        // Keep all tabs mounted so each preserves its scroll / navigation state.
        ZStack {
            NavigationStack { HomeView(bottomInset: barHeight) }.environment(\.shelfTabIndex, 0).id("home-\(homeReset)-\(accentHex)")
                .opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
                // .opacity(0)/.allowsHitTesting(false) block touch but NOT VoiceOver —
                // without this, swiping through a hidden tab's content is still
                // possible, so a VoiceOver user falls straight from Home into Library,
                // Downloads, then Settings with no indication of where they are.
                .accessibilityHidden(selectedTab != 0)
            // Batch 490 (REVIEW 2026-11-11 F14): bound to `libraryPath` (as on the modern path) so
            // `shelfhead://series/<id>` and `author/<id>` can push onto it.
            NavigationStack(path: $libraryPath) { LibraryView(bottomInset: barHeight) }.environment(\.shelfTabIndex, 1).id("lib-\(libraryReset)-\(accentHex)")
                .opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
                .accessibilityHidden(selectedTab != 1)
            // 16 September 2026: slot 2 is Listening (`StatsView`) — see `tabs`' doc
            // comment above.
            NavigationStack { StatsView(bottomInset: barHeight) }.environment(\.shelfTabIndex, 2).id("listening-\(listeningReset)-\(accentHex)")
                .opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)
                .accessibilityHidden(selectedTab != 2)
            // Code review fix (26 August 2026): `SettingsView` used to supply its own
            // `NavigationStack` internally, so this mounted it bare. Now that the
            // double-nesting bug on the modern tab path is fixed by removing that
            // internal stack (see `SettingsView.body`'s own comment), the legacy path
            // needs to provide one here instead — matching every other tab in this
            // `ZStack`.
            // Batch 482: bound to `settingsPath` (as on the modern path) so an accepted invite can open Household.
            NavigationStack(path: $settingsPath) { SettingsView(bottomInset: barHeight) }.environment(\.shelfTabIndex, 3).id("settings-\(settingsReset)")
                .opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)
                .accessibilityHidden(selectedTab != 3)
        }
        // SB-2a's bottom gradient scrim (Batch 317) was REMOVED in Batch 320: on device
        // the user read it as a solid bar sitting above the mini player / tab pill
        // rather than a fade, and preferred no scrim to that. Legibility of the bottom
        // chrome is left to the bar itself (opaque-ish `bottomBar` here; the system's
        // scroll-edge effect on the iOS 26 path).
        // Reserve space for the mini-player + tab bar so content (e.g. the Sign Out
        // button) never hides behind them. safeAreaInset propagates the inset into
        // each tab's scroll view automatically.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar.id(accentHex)   // rebuild tab pill + mini-player on accent change
        }
        .onPreferenceChange(LibrarySelectingPreferenceKey.self) { selecting in
            if reduceMotion {
                librarySelecting = selecting
            } else {
                withAnimation(.easeInOut(duration: 0.25)) { librarySelecting = selecting }
            }
        }
    }

    /// D5 (design brief 2026-08-12): "Adopt TabView + tabViewBottomAccessory on
    /// iOS 26" — a real system `TabView` instead of the custom `ZStack`/
    /// `RetroTabBar` shell, gated to iOS 26+ only (`legacyTabs` above is
    /// untouched and still used below iOS 26). Spec-mandated stop-gate: state
    /// preservation across tab switches and mini-player behavior during
    /// tab-bar minimize need on-device verification — this environment can't
    /// run a simulator to capture that. See CHANGES_IMPLEMENTED.md Batch 163.
    @available(iOS 26.0, *)
    @ViewBuilder private var modernTabs: some View {
        modernTabsWithAccessory
            // Batch 321 (user decision, reversing Batch 320's remedy): minimise-on-
            // scroll is wanted on EVERY page — Settings and its sub-pages included —
            // not just on the two tabs whose content is reliably long. Batch 320 had
            // restricted it to `selectedTab <= 1` because a bar minimised by one scroll
            // stayed minimised after navigating to a screen too short to scroll back up
            // (Downloads → Download Settings → back), with iOS 26 offering no API to
            // expand the bar programmatically.
            //
            // What that batch also observed on device is the way out: *changing the
            // value* passed here re-expands a minimised bar (that's why switching to
            // Downloads/Settings, which flipped `.onScrollDown` → `.never`, restored
            // it). So the behaviour is `.onScrollDown` everywhere, and
            // `TabBarMinimizeCoordinator` flips this to `.never` for ~100ms whenever a
            // screen appears — a push, a pop back, a tab switch, an account change, a
            // deep link — which forces the expand and then immediately restores normal
            // minimise-on-scroll. See that type's doc comment in `Extensions.swift`.
            .tabBarMinimizeBehavior(tabBarMinimize.suspended ? .never : .onScrollDown)
            // Keyed on accent like the legacy bottom bar, for consistency — though
            // unlike the legacy path (which only rebuilds the tab pill + mini-player),
            // this rebuilds the whole TabView, which also resets `homePath`/
            // `libraryPath`/`settingsPath` to empty. Accepted tradeoff: an accent
            // change is rare and the legacy path's per-tab `.id()` keys already reset
            // nav state on accent change today too.
            .id(accentHex)
    }

    /// User report (real device, iOS 26): "when no book is playing, the now playing
    /// pill still exists but just blank." Root cause: `.tabViewBottomAccessory` is a
    /// *container* modifier, not a conditional one — the system reserves and paints
    /// its glass accessory slot as soon as the modifier is attached, whether or not
    /// the `@ViewBuilder` closure resolves to anything. The closure below has always
    /// been guarded on `currentBook != nil` (and `MiniPlayerView`'s own body guards
    /// again), so with nothing playing the closure produced an empty view — and the
    /// system happily rendered an empty pill around it. The legacy path never had
    /// this bug because it composes `bottomBar` by hand, so omitting `MiniPlayerView`
    /// there genuinely removes the bar.
    ///
    /// iOS 26.1 added a `tabViewBottomAccessory(isEnabled:content:)` overload that
    /// suppresses the container itself, which is exactly the fix; iOS 26.0 only has
    /// the single-argument form. Two viable shapes for the 26.0 hole:
    /// (a) leave 26.0 on the old modifier (blank pill persists there), or
    /// (b) attach the modifier conditionally, i.e. `if hasBook { core.tabViewBottom
    ///     Accessory { ... } } else { core }`.
    /// (b) is rejected: the two branches are different view types, so SwiftUI
    /// discards and rebuilds the whole `TabView` every time playback starts or
    /// stops — which would blow away `homePath`/`libraryPath`/`listeningPath`/
    /// `settingsPath` mid-session (start a book from Library while three levels
    /// deep and you'd get bounced to the root). A blank pill on one point release
    /// is much cheaper than losing navigation state on every play/stop, so (a) it
    /// is. Note the `if #available` below is *not* the same hazard: the OS version
    /// can't change while the process is alive, so that branch is chosen once and
    /// never flips, leaving a single stable `TabView` identity either way.
    @available(iOS 26.0, *)
    @ViewBuilder private var modernTabsWithAccessory: some View {
        if #available(iOS 26.1, *) {
            modernTabCore
                // LS-2 (docs/design-review.md): `hasMiniPlayer`, not `currentBook != nil`
                // — enable the accessory for a book a start is in flight for too.
                // Critique 2026-10-06 (distill): `showsMiniPlayer` also disables it while
                // Book Detail's pinned Play bar is showing (Apple docs
                // `View/tabViewBottomAccessory(isEnabled:content:)`, iOS 26.1: "Use this
                // modifier to dynamically show and hide the accessory view").
                .tabViewBottomAccessory(isEnabled: showsMiniPlayer) {
                    systemAccessoryMiniPlayer
                }
        } else {
            // Critique 2026-10-06 (distill): iOS 26.0 keeps the mini player on Book Detail.
            // `tabViewBottomAccessory(content:)` (iOS 26.0) has no `isEnabled:`, so emptying
            // the content would bring back the blank glass pill described above, and attaching
            // the modifier conditionally would rebuild the TabView. `showsMiniPlayer` reports
            // it visible here so nothing else assumes it's gone.
            modernTabCore
                .tabViewBottomAccessory { systemAccessoryMiniPlayer }
        }
    }

    /// The mini-player as hosted by the iOS 26 system tab accessory. Still guarded on
    /// `hasMiniPlayer` so the 26.0 branch above (no `isEnabled:`) can't render a
    /// half-built bar, and so the 26.1+ branch degrades safely if `isEnabled` and the
    /// closure ever disagree for a frame.
    @available(iOS 26.0, *)
    @ViewBuilder private var systemAccessoryMiniPlayer: some View {
        // LS-2: `hasMiniPlayer`, not `currentBook != nil` — see `modernTabsWithAccessory`.
        if playerViewModel.hasMiniPlayer {
            // D5 follow-up (design brief 2026-08-12): user feedback that this bar
            // looked "too small and cutoff" and "like a window inside a window" —
            // `MiniPlayerView`'s own `.glassPill` card + outer margin (designed for
            // the legacy floating bar) double up with the system accessory's own
            // glass container. `embeddedInSystemAccessory: true` drops that extra
            // chrome so the system's own container is the only one. See
            // `MiniPlayerView`'s doc comment on that parameter.
            MiniPlayerView(embeddedInSystemAccessory: true)
                // The system hosts this accessory outside the hierarchy that
                // `ShelfHeadApp`'s `.preferredColorScheme(...)` applies to, so adaptive
                // colours inside it resolve against a DARK trait collection whatever
                // the app's appearance is. Measured on device: with the app in Light,
                // `Color.shelfCream` (adaptive `2A211A` light / `F4E9D6` dark) came out
                // as the cream dark-variant and the title rendered nearly invisible on
                // the light glass; `shelfMuted`'s dark variant is a mid-brown that
                // stayed legible, which is why only the title looked broken. Same class
                // of bug WATCH-5 documented for the widget. Forcing the scheme here
                // makes every adaptive colour in the accessory resolve the way the rest
                // of the app already does.
                .environment(\.colorScheme, themeStore.appearance.colorScheme ?? systemColorScheme)
        }
    }

    /// The bare `TabView` shared by both branches of `modernTabsWithAccessory` above.
    /// Extracted so the accessory modifier is the *only* difference between them —
    /// see that property's doc comment for why that matters for view identity.
    @available(iOS 26.0, *)
    @ViewBuilder private var modernTabCore: some View {
        TabView(selection: selectedTabBinding) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                NavigationStack(path: $homePath) { HomeView(scrollToTopSignal: homeReset) }
                    .environment(\.shelfTabIndex, 0)
            }
            Tab("Library", systemImage: "books.vertical.fill", value: 1) {
                librarySplitView
                    .environment(\.shelfTabIndex, 1)
            }
            // 16 September 2026: slot 2 is Listening — see `tabs`' own doc comment
            // above for the full reasoning.
            // Code review fix (26 August 2026): was a bare `NavigationStack { StatsView() }`
            // with no `path:` binding — nothing for `selectedTabBinding`'s reselect
            // branch to clear, so re-tapping this tab while pushed deep did nothing
            // on the modern path either. `listeningPath` mirrors `homePath`/
            // `libraryPath` the same way.
            Tab("Stats", systemImage: "chart.bar.fill", value: 2) {
                NavigationStack(path: $listeningPath) { StatsView() }
                    .environment(\.shelfTabIndex, 2)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: 3) {
                NavigationStack(path: $settingsPath) { SettingsView() }
                    .environment(\.shelfTabIndex, 3)
            }
            // Batch 496 (REVIEW 2026-11-11 N6): HIG Searching, "In apps that use tab bars ...
            // search is a dedicated tab". `TabRole.search` (iOS 18) supplies the title and
            // magnifying glass and sits apart at the trailing edge; the four tabs stay as they are.
            Tab(value: 4, role: .search) {
                NavigationStack(path: $searchPath) { LibrarySearchTabView(model: searchTab) }
                    .environment(\.shelfTabIndex, 4)
            }
        }
        .librarySearchTab(searchTab, libraryViewModel: libraryViewModel)
    }

    /// iPhone Duo (§3, docs/iphone-duo-readiness-2026-10-22.md; user decision "Split view,
    /// Library only"): Library in a two-column `NavigationSplitView` (iOS 16). At regular
    /// width (the inner display) a book tap fills the detail column through
    /// `libraryDetailItem`. At compact width the split view collapses to one stack (Apple,
    /// `NavigationSplitView`: "with narrow sizes like on iPhone ... collapses all of its
    /// columns into a stack"), whose root is the same `NavigationStack(path: $libraryPath)`
    /// as before, and `LibraryView` gets no `detailSelection`, so its book links push exactly
    /// as they always have. One hierarchy for both widths, so a fold or unfold keeps
    /// `LibraryView`'s state (scope, search, select mode) and the open book. Series,
    /// Authors, Downloads and the other pushes from Library stay in the sidebar column's
    /// own stack ("Activating a link in the same column adds a view to the stack").
    @ViewBuilder private var librarySplitView: some View {
        NavigationSplitView(columnVisibility: .constant(.all), preferredCompactColumn: $libraryCompactColumn) {
            NavigationStack(path: $libraryPath) {
                LibraryView(scrollToTopSignal: libraryReset,
                            detailSelection: horizontalSizeClass == .regular ? $libraryDetailItem : nil)
                    // Both columns always show; the toggle would only hide the Library.
                    .toolbar(removing: .sidebarToggle)
            }
            // Screens pushed in this column (Series, Authors, Collections, Downloads) open
            // their books in the detail column too, through `BookLink`.
            .environment(\.libraryDetailSelection, horizontalSizeClass == .regular ? $libraryDetailItem : nil)
            .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 480)
        } detail: {
            NavigationStack {
                if let item = libraryDetailItem {
                    BookDetailView(item: item)
                } else {
                    EmptyStateView(icon: "books.vertical",
                                   title: LocalizedStringResource("No Book Selected", comment: "Title of the empty detail column next to the Library on a wide display"),
                                   subtitle: LocalizedStringResource("Choose a book from your library to see it here.", comment: "Subtitle of the empty detail column next to the Library on a wide display"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.shelfBackground)
                }
            }
            // A new book starts a fresh detail stack (pops anything pushed from the last one).
            .id(libraryDetailItem?.id)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: libraryDetailItem?.id) { _, id in
            libraryCompactColumn = id == nil ? .sidebar : .detail
        }
        .onChange(of: libraryCompactColumn) { _, column in
            // Back from the book while collapsed: the system shows the sidebar again, so the
            // book is closed rather than reappearing on the next unfold.
            if column == .sidebar && horizontalSizeClass != .regular { libraryDetailItem = nil }
        }
    }

    var body: some View {
        @Bindable var playerViewModel = playerViewModel
        @Bindable var downloadManager = downloadManager
        @Bindable var libraryViewModel = libraryViewModel
        return ZStack {
            Color.shelfBackground.ignoresSafeArea()

            // UI-6: the tabs + full player share this inner ZStack, which is the full
            // extent of the full player's `.isModal` accessibility scope below — so that
            // trait only suppresses VoiceOver access to *these* siblings (the tabs/mini-
            // player behind the modal, as intended) and not the connectivity banner,
            // which is declared in the outer ZStack instead and must stay reachable
            // regardless of whether the full player is up.
            ZStack {
                // D5 (design brief 2026-08-12): real `TabView` on iOS 26+, the
                // existing custom shell otherwise. See `modernTabs`/`legacyTabs` above.
                Group {
                    if #available(iOS 26.0, *) {
                        modernTabs
                    } else {
                        legacyTabs
                    }
                }
                // Critique 2026-10-06 (adapt): the banner floats over the tabs (outer
                // ZStack, zIndex 20) and covered navigation-bar buttons. Same measured top
                // inset the full player gets below, so both tab shells lay out beneath it;
                // 0 whenever the banner is empty.
                .safeAreaPadding(.top, connectivityBannerHeight)
                .shelfAnimation(.easeInOut(duration: 0.25), value: connectivityBannerHeight)

                // Full player presented as an overlay (not a sheet). It slides up from
                // the bottom, fully opaque (no cross-fade), so it reads as the player
                // rising from the mini-player rather than a translucent "ghost". The
                // custom drag-to-dismiss slides it back down.
                if playerViewModel.showFullPlayer, playerViewModel.currentBook != nil {
                    PlayerView()
                        // Critique 2026-10-05 (clarify): the connectivity / "N positions
                        // waiting to sync" banner floats above the player (it lives in the
                        // outer ZStack, see below) and was drawn over the drag handle and
                        // its close target. Pushing the player's safe area down by the
                        // banner's measured height lays the strip out beneath it instead;
                        // 0 whenever the banner is empty, so nothing moves otherwise.
                        .safeAreaPadding(.top, connectivityBannerHeight)
                        // ...and eases the change, so a banner appearing mid-listen slides the
                        // player down instead of snapping the cover to a new size. Reduce
                        // Motion turns it off (`shelfAnimation`).
                        .shelfAnimation(.easeInOut(duration: 0.25), value: connectivityBannerHeight)
                        // Critique 2026-10-05 (Mini player, 2nd): Magic Tap moved to the app
                        // root (see `.accessibilityAction(.magicTap)` on `body`) so it also
                        // works with the player collapsed. Not repeated here: the nearest
                        // handler wins, so one here would just shadow the root's identical one.
                        // The full player follows the app's Light/Dark appearance. Its chrome
                        // uses the adaptive shelf palette; only the skeuomorphic hardware (the
                        // cassette deck and the LCD tape counter) stays dark in both themes,
                        // pinned locally in RetroComponents.
                        .transition(.move(edge: .bottom))
                        .zIndex(10)
                        // VoiceOver: treat the full player as modal so focus can't wander into
                        // the tabs/mini-player behind it (its siblings in *this* inner
                        // ZStack only — see the comment above on why the banner lives
                        // outside it).
                        .accessibilityAddTraits(.isModal)
                }
            }
            // Design review 2026-09-23 AN-2: single source of truth for the full
            // player's entrance/exit motion — previously only the call sites that
            // happened to wrap `showFullPlayer = true` in `withAnimation` animated,
            // so "play and open", podcast episodes and bookmark jumps popped in
            // instantly. Scoped to this inner ZStack (tabs + full player only, not the
            // outer ZStack's connectivity banner) so it can't newly animate unrelated
            // state — the banner's own `displayedReachabilityStatus` animation above is
            // a sibling, outside this modifier's subtree. Direction-aware: an implicit
            // `.animation(_:value:)` overrides the explicit `withAnimation` curve of every
            // dismiss path (`dismissFullPlayer()`, the title → Book Detail button), which
            // all use a quick `.easeOut(duration: 0.25)` — so closing keeps that curve.
            .shelfAnimation(
                playerViewModel.showFullPlayer
                    ? .spring(response: 0.42, dampingFraction: 0.85)
                    : .easeOut(duration: 0.25),
                value: playerViewModel.showFullPlayer
            )

            // F10: persistent "offline" vs "server unreachable" banner — floats above
            // everything (including the full player) since connectivity matters
            // regardless of which screen is up. UI-6: `.accessibilitySortPriority(100)`
            // makes VoiceOver announce it before whatever screen happens to be showing
            // (declaration order otherwise puts it dead last), and living in this outer
            // ZStack — rather than as a sibling of the full player above — keeps it
            // reachable even while the player's `.isModal` trait is active.
            // Design review (14 Aug 2026), item 2: `pendingSyncCount` reads
            // `AudioPlayerService.shared.pendingProgressCount` directly — `@Observable`
            // tracks this dependency the same way it would through `@Environment`, so
            // the banner still updates live without needing the singleton injected.
            // Design review 2026-09-23 AN-4: animate on the debounced
            // `displayedReachabilityStatus` (not the raw store status) so the slide-in/
            // out transition and the debounce agree on when the banner actually changes.
            ConnectivityBanner(status: displayedReachabilityStatus,
                               pendingSyncCount: AudioPlayerService.shared.pendingProgressCount,
                               // Critique 2026-10-06 (clarify): say the download keeps playing.
                               hasBook: playerViewModel.currentBook != nil,
                               isLocal: !playerViewModel.isStreamingCurrentBook,
                               isPlaying: playerViewModel.isPlaying)
                // Measured before the full-height frame below, so this is the banner's
                // own content height (0 when it shows nothing). Feeds the full player's
                // top inset above. `onGeometryChange` is iOS 16.0 (Apple docs).
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { connectivityBannerHeight = $0 }
                .shelfAnimation(.easeInOut(duration: 0.25), value: displayedReachabilityStatus)
                .shelfAnimation(.easeInOut(duration: 0.25), value: AudioPlayerService.shared.pendingProgressCount)
                .zIndex(20)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilitySortPriority(100)
                // AX-11 (docs/design-review.md, follow-up): the banner's text now scales
                // with Dynamic Type. This ZStack doesn't `.ignoresSafeArea()`, so the
                // `.top`-aligned frame above already keeps it below the status bar/Dynamic
                // Island — but at the largest accessibility sizes the warning can wrap to
                // 2-3 lines and, since it's a fixed-position overlay rather than part of
                // the scrollable content, would grow down far enough to sit over an inline
                // navigation bar's leading/trailing buttons on whichever tab is showing.
                // Capping at `.accessibility3` (rather than letting it reach `.accessibility5`)
                // keeps the text meaningfully larger than the default while staying clear
                // of those controls — the same capping pattern already used for fixed-
                // layout rows elsewhere in this app (e.g. `HomeView.swift:1514`,
                // `SeriesBrowseView.swift:134`, both `...DynamicTypeSize.accessibility1`).
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        // Batch 218 (R10.8): makes `tabRouter` reachable from both tab-shell
        // branches above (`legacyTabs`/`modernTabs` both contain `HomeView`).
        .environment(tabRouter)
        // ASO pass (AppStoreListing.md, 14 Sep 2026): fires the native review prompt at
        // the moments `ReviewPromptManager` decides are eligible — see
        // `ReviewPromptRequester` in `ReviewPromptManager.swift`.
        .reviewPromptRequester()
        .task {
            ReachabilityPollGate.start(reachability)   // Polish pass (J2-12): one start per foreground
            // Batch 453: touches CloudKit only if this device already belongs to a household.
            HouseholdStore.shared.resumeIfJoined()
            HouseholdShareAcceptance.acceptPendingIfUnlocked()
            // Batch 456: waits for SharePlay sessions for the life of the app.
            ListenTogetherController.shared.start()
            // Batch 454: publishes nothing unless "Share what I'm listening to" is on.
            HouseholdNowListeningPublisher.shared.start(player: playerViewModel)
        }
        // Design review 2026-09-23 AN-4: the report's suggested 1-2s debounce before
        // showing "server unreachable" — a single failed ping shouldn't flash the
        // banner. Re-runs (cancelling any prior sleep) on every `reachability.status`
        // change: `.offline`/`.ok` are adopted immediately, `.serverUnreachable` only
        // after 1.5s if the store is still unreachable by then.
        .task(id: reachability.status) {
            await displayedReachability.follow(reachability)
        }
        .onPreferenceChange(BottomBarHeightKey.self) { barHeight = $0 }
        .onChange(of: selectedTab) { _, _ in
            Haptics.selection()
            // Batch 321: covers every tab change, including the programmatic ones that
            // bypass `selectedTabBinding` entirely (`handleDeepLink`, `openLibrary`).
            // The binding's own call above is only for the reselect case, which changes
            // no value and so never reaches here — the two never double-fire.
            tabBarMinimize.reexpand()
        }
        // Batch 321: navigation depth changing within a tab is the other half of "a
        // screen appeared". Every pushed screen also carries `reexpandsTabBarOnAppear()`
        // itself, so these are belt-and-braces for the modern tab path's own state —
        // and they cover the programmatic pops (deep link, account change) that clear a
        // path without any new screen appearing at all.
        .onChange(of: homePath) { _, _ in tabBarMinimize.reexpand() }
        .onChange(of: libraryPath) { _, _ in tabBarMinimize.reexpand() }
        .onChange(of: listeningPath) { _, _ in tabBarMinimize.reexpand() }
        .onChange(of: settingsPath) { _, _ in tabBarMinimize.reexpand() }
        .onChange(of: searchPath) { _, _ in tabBarMinimize.reexpand() }
        // Batch 218 (R10.8): consumes a tab-switch request from a descendant (e.g.
        // `HomeView`'s empty-state CTA) — reuses `selectedTabBinding`'s own
        // reset-on-reselect logic rather than just assigning `selectedTab` directly,
        // so requesting the tab you're already on behaves the same as tapping it
        // again in the tab bar.
        .onChange(of: tabRouter.requestedTab) { _, newValue in
            guard let tab = newValue else { return }
            selectedTabBinding.wrappedValue = tab
            tabRouter.requestedTab = nil
        }
        // N-6 (REVIEW_2026-09-14_DESIGN.md): the same consume-and-clear shape as
        // `requestedTab` above, for Home's Smart Filters shelf — see `TabRouter`'s
        // `requestedSmartFilter` for why it's a separate box rather than a tab request
        // plus a filter call at the shelf.
        .onChange(of: tabRouter.requestedSmartFilter) { _, newValue in
            guard let filter = newValue else { return }
            tabRouter.requestedSmartFilter = nil
            openLibrary(applying: filter)
        }
        // Batch 490 (REVIEW 2026-11-11 N7): a descendant asks for a Settings page (Home's "Use a
        // Different Server", Other Servers' empty state). Same consume-and-clear shape as above.
        .onChange(of: tabRouter.requestedSettingsPage) { _, newValue in
            guard let page = newValue else { return }
            tabRouter.requestedSettingsPage = nil
            openSettings(page: page)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadOpenHousehold)) { _ in
            openSettings(page: .household)
        }
        // Batch 490 (REVIEW 2026-11-11 E1/F13): links (and Home Screen quick actions) held by
        // `IncomingLinkInbox`, including any that arrived before this view was on screen.
        .onChange(of: linkInbox.pending, initial: true) { _, _ in
            deliverPendingLink()
        }
        // Batch 490 (REVIEW 2026-11-11 F25): What's New, once per update, after the tabs are up.
        // A short wait lets a cold launch settle (and App Lock cover the app first if it's on).
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            presentWhatsNewIfDue()
        }
        .onChange(of: playerViewModel.showFullPlayer) { _, isShown in
            if !isShown { presentWhatsNewIfDue() }
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: { WhatsNew.markPresented() }) {
            WhatsNewSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
            // Account switched — drop the previous account's data and reload fresh.
            // Review 4 Medium 2: the non-view part lives in one shared helper (also used at ContentView level).
            ContentView.resetAccountScopedState(libraryViewModel: libraryViewModel, playerViewModel: playerViewModel,
                                                downloadManager: downloadManager)
            // Fix 5 (REVIEW-2026-09-09.md): reset navigation too. Nothing here touched the
            // four `NavigationPath`s or `deepLinkedItem`, so a book detail, an author page
            // or the deep-link sheet for an item that may not even exist on the new server
            // stayed on screen over freshly-cleared state — with working-looking buttons
            // (download, add to Up Next) pointed at a foreign item id.
            //
            // Both tab shells need their own mechanism: the iOS 26 `TabView` path keeps
            // each tab mounted and drives depth through these paths, while the legacy
            // shell pops to root by re-keying each tab's `.id(...)` on its reset counter
            // (which remounts the tab's `NavigationStack` from scratch). Bumping the
            // counters is inert on the modern path — there they're only scroll-to-top
            // signals — so doing both is correct rather than redundant.
            homePath = NavigationPath()
            libraryPath = NavigationPath()
            listeningPath = NavigationPath()
            settingsPath = NavigationPath()
            // Batch 496 (N6): the Search tab's stack and query belonged to the old account.
            searchPath = NavigationPath()
            searchTab.reset()
            deepLinkedItem = nil
            // iPhone Duo (§3): and the inner display's detail column (a book from the old server).
            libraryDetailItem = nil
            homeReset += 1
            libraryReset += 1
            listeningReset += 1
            settingsReset += 1
            // Review 3 High 2 (30 October 2026): the gate only fires on a move into Settings, so a switch to a
            // child's account while Settings is open must leave it.
            selectedTab = ParentGate.tabAfterAccountChange(current: selectedTab, activeAccountId: AccountStore.currentAccountId)
            // Batch 321: an account switch resets every tab to its root, which is as
            // much a "new screen appeared" as a pop — don't leave the bar minimised
            // over freshly-reset content.
            tabBarMinimize.reexpand()
            Task { await libraryViewModel.loadLibraries() }
        }
        .onShake {
            // Shake gesture (only while a sleep timer is armed); action is configurable.
            // HIG audit 2026-09-17 M1(b): shake is the system's own gesture for undo/redo
            // (HIG Gestures, Undo and redo) — while the software keyboard is up, a live
            // text field (e.g. the bookmark note editor) may want that shake for its own
            // undo manager, so step aside rather than fight it.
            guard !keyboardVisible else { return }
            guard playerViewModel.isSleepTimerActive else { return }
            switch SettingsStore.shakeAction {
            case .off:
                break
            case .reset:
                playerViewModel.resetSleepTimer(); Haptics.success()
            case .extend:
                playerViewModel.extendSleepTimer(by: 15 * 60); Haptics.success()
            }
        }
        .onReceive(keyboardVisibility) { keyboardVisible = $0 }
        // Critique 2026-10-05 (Mini player, 2nd): VoiceOver's two-finger double-tap plays or
        // pauses from anywhere in the app (HIG Playing audio), including with only the mini
        // player showing. Driving Mode's full-screen cover keeps its own handler (it is
        // presented outside this hierarchy), so there is no double toggle.
        .accessibilityAction(.magicTap) {
            if playerViewModel.hasMiniPlayer { playerViewModel.togglePlayPause() }
        }
        .toast(message: $playerViewModel.errorMessage, bottomInset: otherToastInset)
        .toast(message: $downloadManager.downloadError, duration: 6, bottomInset: otherToastInset)
        // D1 (REVIEW 2026-11-11): "Will download on Wi-Fi." when a manual download is accepted and waits.
        .toast(message: $downloadManager.downloadInfo, style: .info, duration: 4, bottomInset: otherToastInset)
        // Batch 495 (REVIEW 2026-11-11 D6): Auto-delete finished says so, and the files only go
        // once this toast does, so Undo keeps them.
        .toast(message: $downloadManager.autoDeleteUndoMessage, style: .info, duration: AutoDeletePlan.undoWindow,
               bottomInset: otherToastInset,
               action: ToastAction(label: "Undo") { downloadManager.undoPendingAutoDelete() })
        .toast(message: $playerViewModel.infoMessage, style: .success, duration: 2, bottomInset: otherToastInset)
        // Library contract: a failed background refresh is a non-blocking toast; the
        // blocking `errorAlert` below stays for `errorMessage` (a failed first load).
        .toast(message: $libraryViewModel.refreshFailureMessage, duration: 4, bottomInset: otherToastInset)
        // Batch 490 (REVIEW 2026-11-11 E1): a deep link that couldn't be opened.
        .toast(message: $linkFailureMessage, style: .info, duration: 4, bottomInset: otherToastInset)
        // Critique 2026-10-06 (harden): single-book Mark Finished / Reset is undoable for 6 s,
        // from Book Detail's menu, the long-press menu and Library's list swipe alike.
        .toast(message: progressUndoBinding, style: .success, duration: 6, bottomInset: otherToastInset,
               action: ToastAction(label: "Undo") { libraryViewModel.undoLastProgressChange() })
        // Critique 2026-10-05 (Mini player): Stop (long-press menu / VoiceOver) is undoable for 6 s.
        .toast(message: $playerViewModel.stopUndoMessage, style: .info, duration: 6, bottomInset: toastBottomInset,
               action: ToastAction(label: "Undo") { playerViewModel.undoStop() })
        // Critique 2026-10-06 (harden): B-side, Play Instead and episode taps that replaced the
        // loaded book are undoable for 6 s; Undo puts the previous book back at its position.
        .toast(message: $playerViewModel.replaceUndoMessage, style: .info, duration: 6, bottomInset: toastBottomInset,
               action: ToastAction(label: "Undo") { playerViewModel.undoReplace() })
        // Critique 2026-10-05 (second run): a failed playback start is an alert with Retry,
        // not a toast — it blocks what the listener just asked for, and an alert is announced
        // by VoiceOver and waits to be read. Offline/cellular guard messages stay toasts.
        // Batch 495 (REVIEW 2026-11-11 P4): the same alert carries the lost-stream notice, titled for it.
        .errorAlert(title: playerViewModel.failureIsLostStream ? "Playback Stopped" : "Can't Start Playback", message: Binding(
            // Stands down while Driving Mode's full-screen cover is up: an alert can't
            // present under it, and a failed presentation clears the message (UX-4), so
            // Driving Mode shows the failure itself with its own Try Again (fourth run).
            get: { playerViewModel.isDrivingModePresented ? nil : playerViewModel.startFailureMessage },
            set: { playerViewModel.startFailureMessage = $0 }
        )) {
            playerViewModel.retryFailedStart()
        }
        // The single stall clock (see `PlayerViewModel.transportWaitingChanged`). Driven from
        // here because this view is always mounted, whichever screen is up.
        .onChange(of: playerViewModel.isTransportWaiting, initial: true) { _, waiting in
            playerViewModel.transportWaitingChanged(waiting)
        }
        // UX-4 audit (Batch 355): the library's load/refresh error alert has one owner, here.
        // Home and Library each used to bind `libraryViewModel.errorMessage` themselves, and
        // both tabs stay mounted in the `TabView`, so one error raised two presentations of the
        // same shared state: the UX-4 pattern (a failed presentation's `set(false)` clears the
        // message the other one is showing). Retry is Home's version, the superset: load the
        // libraries if there are none yet, otherwise refresh.
        .errorAlert(message: $libraryViewModel.errorMessage) {
            Task {
                if libraryViewModel.libraries.isEmpty {
                    await libraryViewModel.loadLibraries()
                } else {
                    await libraryViewModel.refresh()
                }
            }
        }
        // Surfaced regardless of which tab is active — reconciliation runs from
        // `LibraryViewModel.loadUserProgress()` on any library load/refresh, not from
        // one particular screen. See `DownloadManager.reconcile(serverProgress:)`.
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        // Batch 443: the optional "rate on Hardcover" sheet after a book finishes.
        .readingRatingPrompt()
        .sheet(isPresented: $showUploadSheet) {
            UploadSheet(onOpenLibrary: { _ in selectedTab = 1 })
        }
        .alert("Progress Doesn't Match", isPresented: Binding(
            get: { downloadManager.pendingProgressConflict != nil },
            set: { if !$0 { downloadManager.pendingProgressConflict = nil } }
        ), presenting: downloadManager.pendingProgressConflict) { conflict in
            // Fix 2.1 (REVIEW-2026-09-09.md): both buttons hand the `conflict` value they
            // were built with straight to the resolver. The `isPresented` setter above
            // nils `pendingProgressConflict` synchronously as the alert dismisses, which
            // is *before* either `Task` below runs — so the old parameterless resolver
            // (which re-read that property and bailed when it was nil) discarded the
            // user's choice every time, and the prompt came back on the next reconcile.
            // HIG audit 2026-09-17 L2: titles used to carry interpolated timestamps
            // ("Keep This Device (12:34:56)"); the message below already states both
            // times once, clearly, so the buttons stay succinct per HIG Alerts.
            Button("Keep This Device") {
                Task { await downloadManager.resolveProgressConflict(conflict, keepLocal: true) }
            }
            Button("Use Server") {
                Task { await downloadManager.resolveProgressConflict(conflict, keepLocal: false) }
            }
            // Polish pass (DL-6): "Ask Me Later" snoozes this exact disagreement, so the
            // prompt comes back only once either side's position or timestamp changes.
            Button("Ask Me Later", role: .cancel) {
                downloadManager.snoozeConflict(itemId: conflict.itemId)
            }
        } message: { conflict in
            let when = ProgressConflict.lastPlayedSummary(localLastUpdate: conflict.localLastUpdate,
                                                          serverLastUpdate: conflict.serverLastUpdate)
            Text("\u{201C}\(conflict.title)\u{201D} has different progress here than on the server \u{2014} this device is at \(conflict.localTime.formattedTime), the server is at \(conflict.serverTime.formattedTime). Which one should win?")
                + Text(when.map { "\n\n" + $0 } ?? "")
        }
        .systemChromeTint()
        // S1 (REVIEW_2026-08-20_UI_SECURITY.md): `handleDeepLink` itself is the gate (see its
        // doc comment), since it's also the entry point `replayPendingAction` re-enters after
        // unlock. Batch 490 (REVIEW 2026-11-11 E1): `.onOpenURL` lives on `ContentView` now and
        // hands URLs over through `IncomingLinkInbox` (`deliverPendingLink`).
        // Handoff: resume the book (at the exact position) handed off from another
        // device. S1: gated — while locked, the activity is queued instead of acting on
        // it, so a Handoff continuation can't start playback over the lock screen.
        .onContinueUserActivity(AudioPlayerService.playbackActivityType) { activity in
            guard !appLock.isLocked else {
                appLock.pendingAction = .continueUserActivity(activity)
                return
            }
            handleHandoffActivity(activity)
        }
        // PL-14: Siri's "play …" from CarPlay's assistant cell (or "Hey Siri, play …" in
        // ShelfHead). `ShelfHeadIntents` answers `.handleInApp` and Siri launches the app with
        // this activity; the search term rides in `userInfo`. Gated like the other
        // continuations so it can't start playback over the lock screen.
        .onContinueUserActivity(PlayMediaRequest.activityType) { activity in
            guard !appLock.isLocked else {
                appLock.pendingAction = .continueUserActivity(activity)
                return
            }
            handlePlayMediaActivity(activity)
        }
        // Spotlight: tapping an indexed book opens its detail page. S1: gated the same
        // way as Handoff above — Spotlight indexing itself (the text content, not this
        // open-on-tap path) is deliberately left alone; see `PendingUnlockAction`'s doc
        // comment.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard !appLock.isLocked else {
                appLock.pendingAction = .continueUserActivity(activity)
                return
            }
            handleSpotlightActivity(activity)
        }
        // S1: the sheet modifier itself has nothing to gate — `deepLinkedItem` is only
        // ever set by `finishOpeningBook(item:playAt:)`, which re-checks `appLock.isLocked`
        // immediately before setting it (closing the TOCTOU window where the app gets
        // locked *during* the async `getItemDetail` fetch above it) and queues a
        // `.openBookItem` pending action instead. So by the time this sheet could present,
        // the app is guaranteed unlocked.
        .sheet(item: $deepLinkedItem) { item in
            // Inherits the app's appearance setting (no forced dark scheme).
            // UI-10 (REVIEW_2026-08-12.md): the Spotlight/`shelfhead://book/<id>`
            // deep-link path presents this as a sheet, above the full player's
            // ZStack-overlay layer — `isPresentedModally: true` tells the detail view
            // to dismiss itself before triggering the full player, so a bookmark tap
            // from in here doesn't make the player materialize invisibly behind this
            // sheet. See `BookDetailView.isPresentedModally`'s doc comment.
            NavigationStack { BookDetailView(item: item, isPresentedModally: true) }
        }
        .sheet(item: $pendingMixtape) { MixtapeImportView(link: $0) }
        .listenTogetherNotices()
        // G1 (REVIEW_2026-09-04_UI.md): `shelfhead://nowplaying`, `shelfhead://resume`,
        // Siri "Resume Listening", Handoff and the widget's play intent all end in
        // `showFullPlayer = true` — some via `openFullPlayer()` here, some inside
        // `PlayerViewModel`/`PlaybackCoordinator`. The player is a ZStack overlay under
        // any presented sheet, so with the Book Detail sheet up it opened behind it and
        // nothing visibly happened (confirmed rendered, both themes). UI-10 handled the
        // inverse — a tap *inside* the sheet dismissing itself first — but not a request
        // arriving from outside. Watching the flag at the root catches every path.
        .onChange(of: playerViewModel.showFullPlayer) { _, isShown in
            if isShown { deepLinkedItem = nil }
        }
        // S1: replay a queued action the instant `authenticate()` succeeds (the `false`
        // arm of this transition). `wasLocked` guards against firing on the very first
        // render (where `isLocked` starts `false` and there's nothing to replay) and
        // against `lockIfNeeded()` transitions (`false` → `true`, the wrong direction).
        .onChange(of: appLock.isLocked) { wasLocked, isLocked in
            // Batch 453: a household invite opened while locked waits here, like a deep link.
            HouseholdShareAcceptance.acceptPendingIfUnlocked()
            // Batch 490 (REVIEW 2026-11-11 F25): held back while locked; offered once unlocked.
            if wasLocked, !isLocked { presentWhatsNewIfDue() }
            guard wasLocked, !isLocked, let action = appLock.pendingAction else { return }
            appLock.pendingAction = nil
            replayPendingAction(action)
        }
    }

    // MARK: - Deep links / routing

    /// S1 (REVIEW_2026-08-20_UI_SECURITY.md): gated at the top rather than per-`case` —
    /// every case here either mutates playback state (`resume`) or navigates within the
    /// locked app (`nowplaying`/`downloads`/`library`/`book`), and this is also the exact
    /// function `replayPendingAction` re-enters once unlocked, so gating once at entry
    /// keeps the "act now" and "act after unlock" paths identical rather than duplicating
    /// the switch.
    private func handleDeepLink(_ url: URL) {
        guard !appLock.isLocked else {
            appLock.pendingAction = .deepLink(url)
            return
        }
        // Batch 444: "Open in ShelfHead" hands over a file URL. Queued behind App Lock by the
        // guard above like any other open; replay re-enters here.
        if url.isFileURL {
            guard UploadInbox.isUploadable(url) else { return }
            UploadInbox.shared.receive([url])
            showUploadSheet = true
            return
        }
        // Batch 321: every case below either switches tab, pops to a root, or brings up
        // the full player — all of them land the user somewhere new, so the tab bar
        // should not still be minimised from wherever they were. Done once here rather
        // than per-case, the same way the lock gate above is.
        tabBarMinimize.reexpand()
        switch url.host {
        case "nowplaying":
            openFullPlayer()
            // Polish pass (WG-3): with no book to show, the link used to leave the app on
            // whichever tab was last selected. Land on Home (tab 0), where Resume lives.
            if playerViewModel.currentBook == nil { selectedTab = 0 }
        case "resume":
            Task { await PlaybackCoordinator.shared.resumeMostRecent() }
        case "downloads":
            // 16 September 2026: Downloads has no tab of its own again — this deep
            // link (offline banner, widget, Shortcut) lands on Library with the
            // downloaded-only filter on, same as it did before Downloads briefly had
            // a top-level slot. Explicitly resets `libraryPath`/bumps `libraryReset`
            // rather than routing through `selectedTabBinding`, so it always lands on
            // Library's root regardless of where that tab was left.
            libraryPath = NavigationPath()
            libraryReset += 1
            libraryDetailItem = nil  // iPhone Duo (§3): the root, as at compact width.
            libraryViewModel.showDownloads()
            selectedTab = 1
        case "library":
            // N-6 (REVIEW_2026-09-14_DESIGN.md): `shelfhead://library?smartFilter=<raw>`
            // lands on Library with that smart filter applied. A plain
            // `shelfhead://library` is deliberately left exactly as it was — it selects
            // the tab and nothing else, preserving whatever depth that tab was left at,
            // which is the behaviour the offline banner and Shortcuts already rely on.
            if let filter = DeepLinkParser.smartFilter(in: url) {
                openLibrary(applying: filter)
            } else {
                selectedTab = 1
            }
        case "mixtape":
            // Batch 458: shelfhead://mixtape?v=1&d=… opens the import sheet.
            // Batch 490 (REVIEW 2026-11-11 E1): a link that doesn't decode says so.
            if let decoded = try? MixtapeLink.decode(url) {
                pendingMixtape = decoded
            } else {
                linkFailureMessage = String(localized: "That mixtape link couldn\u{2019}t be read. Ask for it to be shared again.")
            }
        case "book":
            // shelfhead://book/<id>, and (Batch 490, REVIEW 2026-11-11 F14) `?t=<seconds>` to
            // start there. Only a valid, non-negative number counts; anything else just opens it.
            if let id = DeepLinkParser.bookID(in: url) {
                // Batch 495 (REVIEW 2026-11-11 Y1): `?play=1` (a notification's Play action) plays it
                // from where it was left; `t` wins when both are present.
                let playAt = DeepLinkParser.startTime(in: url)
                openBook(id: id, playAt: playAt,
                         playLink: playAt == nil && DeepLinkParser.wantsPlay(in: url) ? url : nil)
            }
        case "household":
            // Batch 495 (REVIEW 2026-11-11 Y1): a recommendation for a book on another server.
            openSettings(page: .household)
        case "series":
            // Batch 490 (REVIEW 2026-11-11 F14): shelfhead://series/<id> → that series in Library.
            if let id = DeepLinkParser.seriesID(in: url) {
                openSeries(id: id, link: url)
            } else if let name = DeepLinkParser.seriesName(in: url) {
                // Batch 497 (Y1): shelfhead://series?name=<name> (a Release Radar reminder).
                openSeries(named: name, link: url)
            }
        case "author":
            // Batch 490 (REVIEW 2026-11-11 F14): shelfhead://author/<id> → that author's books.
            if let id = DeepLinkParser.authorID(in: url) { openAuthor(id: id, link: url) }
        case "search":
            // Batch 490 (REVIEW 2026-11-11 F14/F13): shelfhead://search[?q=…] (and the Search quick
            // action) lands on Library's Books root, with `q` (if any) in the search field.
            // Batch 496 (REVIEW 2026-11-11 N6): on iOS 26 it lands on the Search tab instead.
            if case .searchTab(let query)? = SearchRequestRoute.route(for: url, hasSearchTab: SearchRequestRoute.systemHasSearchTab) {
                searchPath = NavigationPath()
                searchTab.receive(query: query)
                selectedTab = 4
                return
            }
            libraryPath = NavigationPath()
            libraryDetailItem = nil
            libraryViewModel.requestedBrowseMode = .books
            // The text, when the link carries one, goes through the Library's request seam.
            libraryViewModel.requestedSearchText = DeepLinkParser.searchQuery(in: url)
            selectedTab = 1
        case "driving":
            // Batch 490 (REVIEW 2026-11-11 F14): Driving Mode over the loaded (or last) book. It
            // only presents the screen; it never starts playback. With no book, like `nowplaying`.
            openFullPlayer()
            if playerViewModel.currentBook != nil {
                playerViewModel.pendingDrivingModeRequest = true
            } else {
                selectedTab = 0
            }
        default:
            break
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 E1): hands a held link to `handleDeepLink` (which still gates
    /// on App Lock) if it's still fresh — a link tapped long ago, at a sign-in screen, is dropped
    /// rather than acted on out of the blue (`PendingLinkRule`).
    private func deliverPendingLink() {
        guard let link = linkInbox.take() else { return }
        guard PendingLinkRule.isFresh(receivedAt: link.receivedAt, now: Date()) else { return }
        handleDeepLink(link.url)
    }

    /// Batch 490 (REVIEW 2026-11-11 F25): shows What's New once per update — never over App Lock
    /// (`MainTabView` only exists after sign-in) and never while another root sheet, alert or
    /// the full player is up. Dismissing it marks it seen (`.sheet(onDismiss:)`).
    private func presentWhatsNewIfDue() {
        guard !showWhatsNew, WhatsNew.shouldPresentAfterUpdate,
              !appLock.isLocked,
              authViewModel.sessionExpiredPrompt == nil,
              deepLinkedItem == nil, pendingMixtape == nil, !showUploadSheet,
              downloadManager.pendingProgressConflict == nil,
              !playerViewModel.showFullPlayer else { return }
        showWhatsNew = true
    }

    /// Batch 490 (REVIEW 2026-11-11 F14): pushes a Library screen from a link, on Library's root.
    private func showLibraryRoute(_ route: LibraryRoute) {
        tabBarMinimize.reexpand()
        libraryDetailItem = nil
        libraryPath = NavigationPath([route])
        selectedTab = 1
    }

    /// Batch 490 (REVIEW 2026-11-11 F14): `shelfhead://series/<id>`. The series page needs the
    /// full series (with its books), which only the series list carries, so it's found there:
    /// the copy Library already loaded, else the server's list a page at a time.
    private func openSeries(id: String, link: URL) {
        Task {
            guard let series = await resolveSeries(id: id) else {
                linkFailureMessage = Self.linkTargetFailureMessage
                return
            }
            // Re-checked after the await, as `finishOpeningBook` does.
            guard !appLock.isLocked else { appLock.pendingAction = .deepLink(link); return }
            showLibraryRoute(.series(series))
        }
    }

    /// Batch 497 (REVIEW 2026-11-11 Y1): `shelfhead://series?name=<name>`. Matches the name exactly
    /// (case/diacritic-insensitive) in the loaded series list, then the server's list; with no
    /// match, no library or no server, it falls back to the search link (`SeriesNameRoute`).
    private func openSeries(named name: String, link: URL) {
        Task { @MainActor in
            var candidates: [Series]? = libraryViewModel.seriesLoaded ? libraryViewModel.seriesList : []
            var outcome = SeriesNameRoute.decide(name: name, candidateNames: candidates?.map { Self.names(of: $0) })
            if case .search = outcome {
                candidates = await fetchAllSeries()
                outcome = SeriesNameRoute.decide(name: name, candidateNames: candidates?.map { Self.names(of: $0) })
            }
            // Re-checked after the awaits, as `openSeries(id:)` does.
            guard !appLock.isLocked else { appLock.pendingAction = .deepLink(link); return }
            switch outcome {
            case .open(let index):
                if let series = candidates?[index] { showLibraryRoute(.series(series)) }
            case .search(let searchURL):
                if let searchURL { handleDeepLink(searchURL) }
            }
        }
    }

    private static func names(of series: Series) -> [String] {
        [series.name, series.displayName].compactMap { $0 }
    }

    /// Every series of the current library, a page at a time; nil when there is no library yet or
    /// the server can't be reached.
    private func fetchAllSeries() async -> [Series]? {
        guard let libraryId = await currentLibraryId() else { return nil }
        var all: [Series] = []
        let pageSize = 100
        for page in 0..<20 {
            guard let response = try? await AudiobookshelfAPI.shared.getSeries(libraryId: libraryId, limit: pageSize, page: page)
            else { return nil }
            all += response.results
            if response.results.count < pageSize { break }
        }
        return all
    }

    /// Batch 490 (REVIEW 2026-11-11 F14): `shelfhead://author/<id>`.
    private func openAuthor(id: String, link: URL) {
        Task {
            guard let author = await resolveAuthor(id: id) else {
                linkFailureMessage = Self.linkTargetFailureMessage
                return
            }
            guard !appLock.isLocked else { appLock.pendingAction = .deepLink(link); return }
            showLibraryRoute(.author(author))
        }
    }

    private static var linkTargetFailureMessage: String {
        String(localized: "Couldn\u{2019}t open that link. It may have been removed, or your server can\u{2019}t be reached.")
    }

    /// The library a link resolves against. On a cold launch Home is still loading it, so
    /// this waits a little (up to about five seconds) rather than failing straight away.
    private func currentLibraryId() async -> String? {
        for _ in 0..<10 {
            if let id = libraryViewModel.selectedLibrary?.id { return id }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return libraryViewModel.selectedLibrary?.id
    }

    private func resolveSeries(id: String) async -> Series? {
        if let known = libraryViewModel.seriesList.first(where: { $0.id == id }) { return known }
        guard let libraryId = await currentLibraryId() else { return nil }
        let pageSize = 100
        for page in 0..<20 {
            guard let response = try? await AudiobookshelfAPI.shared.getSeries(libraryId: libraryId, limit: pageSize, page: page)
            else { return nil }
            if let match = response.results.first(where: { $0.id == id }) { return match }
            if response.results.count < pageSize { break }
        }
        return nil
    }

    private func resolveAuthor(id: String) async -> NamedEntity? {
        if let known = libraryViewModel.filterData?.authors?.first(where: { $0.id == id }) { return known }
        guard let libraryId = await currentLibraryId(),
              let data = try? await AudiobookshelfAPI.shared.getFilterData(libraryId: libraryId) else { return nil }
        return data.authors?.first(where: { $0.id == id })
    }

    /// N-6 (REVIEW_2026-09-14_DESIGN.md): the single "open Library showing this smart
    /// filter" route, shared by Home's Smart Filters shelf (in-process, via `TabRouter`)
    /// and by `shelfhead://library?smartFilter=<rawValue>` (external, via
    /// `handleDeepLink`) — the same one-implementation-per-action rule
    /// `finishOpeningBook` follows for the book-opening paths.
    ///
    /// Unlike the plain `shelfhead://library` case, this one always lands on the Library
    /// root: applying a filter and leaving the user three pages deep in an author's page
    /// would show them none of it. Pops depth explicitly rather than going through
    /// `selectedTabBinding` (which only pops when *re*-selecting an already-active tab),
    /// the same reasoning the `downloads` case gives.
    ///
    /// App Lock: the deep-link entry is already gated at `handleDeepLink`'s top. The
    /// in-process entry can't realistically fire while locked (`AppLockView` covers the
    /// whole app), but it's gated here anyway and queued as the equivalent URL, so both
    /// entries queue and replay through exactly one path instead of one of them being
    /// safe by circumstance.
    private func openLibrary(applying filter: SmartFilter) {
        guard !appLock.isLocked else {
            if let url = DeepLinkParser.libraryURL(smartFilter: filter) {
                appLock.pendingAction = .deepLink(url)
            }
            return
        }
        // Batch 321: reachable from Home's Smart Filters shelf (in-process, via
        // `TabRouter`) as well as from `handleDeepLink`, which already re-expands at its
        // own entry — so this covers the in-process caller, and the case where Library
        // was already the selected tab and nothing below changes value.
        tabBarMinimize.reexpand()
        libraryPath = NavigationPath()
        libraryDetailItem = nil  // iPhone Duo (§3): the root, as at compact width.
        // Legacy tab shell only: re-keys Library's `.id(...)`, remounting it — which is
        // also what resets its `browseMode` back to Books. On the iOS 26 path this is
        // just a scroll-to-top signal and the tab stays mounted, so the scope reset
        // there comes from `LibraryViewModel.requestedBrowseMode` instead (set by
        // `presentSmartFilter`).
        libraryReset += 1
        selectedTab = 1
        Task { await libraryViewModel.presentSmartFilter(filter) }
    }

    /// Batch 482: an accepted household invite lands on Settings › Household, where the outcome shows. On a
    /// child's account Settings needs the parent's Face ID or passcode first, as from the tab bar.
    /// Batch 490 (REVIEW 2026-11-11 N7): any Settings page (Home and Other Servers ask for Account).
    private func openSettings(page: SettingsPage) {
        tabBarMinimize.reexpand()
        let open = {
            settingsPath = NavigationPath([page])
            selectedTab = 3
        }
        if selectedTab != 3, ParentGate.settingsNeedGate(activeAccountId: AccountStore.currentAccountId) {
            Task {
                if await ParentGate.authenticate(reason: String(localized: "Open Settings", comment: "Face ID / passcode prompt reason")) {
                    open()
                }
            }
            return
        }
        open()
    }

    private func openFullPlayer() {
        if playerViewModel.currentBook == nil { playerViewModel.restoreLastSession() }
        if playerViewModel.currentBook != nil {
            // G1 (REVIEW_2026-09-04_UI.md): the full player is a ZStack overlay; a
            // presented sheet sits above it. If the `deepLinkedItem` sheet is up, the
            // player would otherwise materialise invisibly behind it and this deep link
            // would appear to do nothing. The `onChange(of: showFullPlayer)` below covers
            // every other path that opens the player; this handles the case where it's
            // already open and the sheet was presented on top of it.
            deepLinkedItem = nil
            // Design review 2026-09-23 AN-2: was a local `withAnimation` wrapper around
            // just this flip, with the identical spring curve the host now applies via
            // `.shelfAnimation(value: showFullPlayer)` on the tabs/full-player ZStack
            // above — removed as redundant.
            playerViewModel.showFullPlayer = true
        }
    }

    /// Fetch a book by id and present it; optionally start playback at `playAt` (Handoff).
    /// Batch 490 (REVIEW 2026-11-11 E1): falls back to the downloaded copy (offline, or the server
    /// is down), and says so when neither has it instead of doing nothing.
    private func openBook(id: String, playAt: Double? = nil, playLink: URL? = nil) {
        Task {
            let fetched = await libraryViewModel.getItemDetail(itemId: id)
            guard let item = DeepLinkParser.resolvedBook(fetched: fetched,
                                                         downloaded: DownloadManager.shared.libraryItem(for: id)) else {
                linkFailureMessage = String(localized: "Couldn\u{2019}t open that book. It may have been removed, or your server can\u{2019}t be reached.")
                return
            }
            await finishOpeningBook(item: item, playAt: playAt, playLink: playLink)
        }
    }

    /// S1 (REVIEW_2026-08-20_UI_SECURITY.md): the actual "present a book" step, factored
    /// out of `openBook` so the normal (unlocked) path and a replayed `.openBookItem`
    /// pending action call the exact same code rather than duplicating the branch between
    /// starting playback and presenting the `deepLinkedItem` sheet. Re-checks
    /// `appLock.isLocked` here — not just at the outer `handleDeepLink`/
    /// `onContinueUserActivity` call sites — because `getItemDetail` in `openBook` above is
    /// async: the app can be locked *during* that fetch, after the outer guard already
    /// passed. Queues the already-resolved `item` (no re-fetch needed on replay) instead of
    /// starting playback or presenting the sheet over the lock.
    private func finishOpeningBook(item: LibraryItem, playAt: Double?, playLink: URL? = nil) async {
        guard !appLock.isLocked else {
            // Batch 495 (Y1): `.openBookItem` has no "play" flag, so a Play link re-queues as itself.
            if let playLink {
                appLock.pendingAction = .deepLink(playLink)
            } else {
                appLock.pendingAction = .openBookItem(item: item, playAt: playAt)
            }
            return
        }
        if playLink != nil {
            // Batch 495 (REVIEW 2026-11-11 Y1): the download-complete notification's Play action.
            // Only ever reached from that explicit tap.
            if playerViewModel.currentBook?.id != item.id {
                await playerViewModel.startPlayback(for: item)
            } else if !playerViewModel.isPlaying {
                playerViewModel.togglePlayPause()
            }
            openFullPlayer()
        } else if let playAt {
            if playerViewModel.currentBook?.id != item.id {
                await playerViewModel.startPlayback(for: item)
            }
            playerViewModel.seek(to: playAt)
            openFullPlayer()
        } else if horizontalSizeClass == .regular, #available(iOS 26.0, *) {
            // iPhone Duo (§3): on the inner display the book opens in Library's detail
            // column (the iOS 26+ shell's split view) rather than as a sheet over it.
            selectedTab = 1
            libraryDetailItem = item
        } else {
            deepLinkedItem = item
        }
    }

    /// Handoff continuation handler, extracted so `replayPendingAction` can call the exact
    /// same code a live `onContinueUserActivity(AudioPlayerService.playbackActivityType)`
    /// event uses (S1, REVIEW_2026-08-20_UI_SECURITY.md).
    private func handleHandoffActivity(_ activity: NSUserActivity) {
        guard let info = activity.userInfo,
              let itemId = info["itemId"] as? String else { return }
        let time = info["currentTime"] as? Double
        openBook(id: itemId, playAt: time)
    }

    /// `INPlayMediaIntent` continuation (PL-14): a spoken title plays that book; a bare "play"
    /// resumes the most recent unfinished one.
    private func handlePlayMediaActivity(_ activity: NSUserActivity) {
        let name = PlayMediaRequest.mediaName(from: activity.userInfo)
        Task { await PlaybackCoordinator.shared.playRequested(mediaName: name) }
    }

    /// Spotlight continuation handler, extracted for the same reason as
    /// `handleHandoffActivity` above (S1, REVIEW_2026-08-20_UI_SECURITY.md).
    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
            openBook(id: id)
        }
    }

    /// S1 (REVIEW_2026-08-20_UI_SECURITY.md): replays a `PendingUnlockAction` queued while
    /// locked, immediately after `authenticate()` succeeds (see the `.onChange(of:
    /// appLock.isLocked)` above in `body`). Each case re-enters the exact function its live
    /// counterpart uses — `handleDeepLink`, `handleHandoffActivity`/`handleSpotlightActivity`
    /// (re-dispatched on `activityType` since a queued activity doesn't know which live
    /// handler it came from), and `finishOpeningBook` — so there is exactly one code path
    /// for each action, not a duplicated "replay" version.
    private func replayPendingAction(_ action: PendingUnlockAction) {
        switch action {
        case .deepLink(let url):
            handleDeepLink(url)
        case .continueUserActivity(let activity):
            if activity.activityType == AudioPlayerService.playbackActivityType {
                handleHandoffActivity(activity)
            } else if activity.activityType == CSSearchableItemActionType {
                handleSpotlightActivity(activity)
            } else if activity.activityType == PlayMediaRequest.activityType {
                handlePlayMediaActivity(activity)
            }
        case .openBookItem(let item, let playAt):
            Task { await finishOpeningBook(item: item, playAt: playAt) }
        }
    }
}

/// Batch 218 (R10.8): `HomeView`'s "Browse Library" empty-state action used to switch
/// tabs by round-tripping through `UIApplication.shared.open("shelfhead://library")`
/// — the app's own URL scheme, handed to the OS and back to this same process just to
/// flip `selectedTab`, which `MainTabView` (the actual owner of that state) could just
/// do directly. That round trip works today, but only because the OS hands the URL
/// back to this exact app instance; it's a needless indirection for something
/// entirely in-process, and would behave oddly on iPad if a second window happened to
/// receive the callback instead. This tiny `@Observable` box is injected via
/// `.environment` so a descendant like `HomeView` can request a tab switch without a
/// `Binding<Int>` threaded down through every intermediate view — `MainTabView` owns
/// the instance, observes it, and clears it after acting. The URL scheme itself is
/// untouched: `handleDeepLink` below still sets `selectedTab` directly for Spotlight/
/// Shortcuts/external entry points, which genuinely arrive via the system URL handler
/// and have no in-process caller to bind to instead.
@Observable
final class TabRouter {
    /// Non-nil for one render cycle: set by a descendant that wants to switch tabs;
    /// `MainTabView` consumes it and resets it to `nil`.
    var requestedTab: Int?

    /// N-6 (REVIEW_2026-09-14_DESIGN.md): non-nil for one render cycle — set by Home's
    /// Smart Filters shelf to open Library *with that filter applied*, consumed and
    /// reset by `MainTabView`.
    ///
    /// Its own box rather than "set `requestedTab` and also apply the filter" at the
    /// call site: those are one indivisible request (a tab switch that lands somewhere
    /// specific), and splitting them across two observable writes would let a render
    /// land between them — Library visibly appearing unfiltered, then re-filtering.
    /// `MainTabView.openLibrary(applying:)` performs both, in order, in one pass.
    var requestedSmartFilter: SmartFilter?

    /// Batch 490 (REVIEW 2026-11-11 N7): non-nil for one render cycle — a Settings page to open
    /// (Settings tab, that page pushed, behind the parent gate on a child's account). Consumed
    /// and reset by `MainTabView.openSettings(page:)`.
    var requestedSettingsPage: SettingsPage?
}

/// Batch 490 (REVIEW 2026-11-11 E1/F13): one held incoming link. `.onOpenURL` (on `ContentView`)
/// and the Home Screen quick actions (`HouseholdSceneDelegate`) put it here; `MainTabView` takes it
/// once it's on screen. Only the newest is kept: a second link replaces an unread first one.
struct IncomingLink: Equatable {
    let url: URL
    let receivedAt: Date
}

@MainActor
@Observable
final class IncomingLinkInbox {
    static let shared = IncomingLinkInbox()

    private(set) var pending: IncomingLink?

    func hold(_ url: URL, now: Date = Date()) {
        pending = IncomingLink(url: url, receivedAt: now)
    }

    /// The held link, cleared, or nil.
    func take() -> IncomingLink? {
        defer { pending = nil }
        return pending
    }
}

/// Batch 490 (REVIEW 2026-11-11 E1): whether a held link is still worth acting on. A link waits
/// while the app is on the splash, sign-in or profile picker; if that takes more than ten minutes
/// it's dropped rather than suddenly opening a book or starting a route long after the tap. A
/// receipt time in the future (the clock moved) counts as fresh. Pinned by `QuickWinsShellTests`.
nonisolated enum PendingLinkRule {
    static let maxAge: TimeInterval = 10 * 60

    static func isFresh(receivedAt: Date, now: Date, maxAge: TimeInterval = maxAge) -> Bool {
        now.timeIntervalSince(receivedAt) <= maxAge
    }
}

/// Batch 490 (REVIEW 2026-11-11 F13): the Home Screen quick actions declared in Info.plist
/// (`UIApplicationShortcutItems`) map to the same `shelfhead://` links a widget or Shortcut uses,
/// so they take the one deep-link path (and wait behind App Lock like any other link).
nonisolated enum QuickActionRoute {
    static let resumeType = "shelfhead.quickaction.resume"
    static let downloadsType = "shelfhead.quickaction.downloads"
    static let searchType = "shelfhead.quickaction.search"

    static func url(forShortcutType type: String) -> URL? {
        switch type {
        case resumeType: return URL(string: "shelfhead://resume")
        case downloadsType: return URL(string: "shelfhead://downloads")
        case searchType: return URL(string: "shelfhead://search")
        default: return nil
        }
    }
}

/// N-6 (REVIEW_2026-09-14_DESIGN.md): pure parsing for the `shelfhead://` links
/// `MainTabView.handleDeepLink` acts on, split out of that function so it can be pinned
/// by a test — `handleDeepLink` itself mutates four pieces of view state and can't be
/// called from one.
///
/// Only the smart-filter parameter lives here so far; the other cases stay inline in
/// `handleDeepLink`, where they're a bare `switch` on `url.host` with nothing to get
/// wrong. Query parsing is the first bit of this scheme with an actual decision in it
/// (present/absent, known/unknown raw value), which is why it gets extracted.
/// Batch 496 (REVIEW 2026-11-11 N6): where a `shelfhead://search[?q=…]` link (and the Search
/// quick action, which opens that link) lands. Pinned by `Batch496SearchRoutingTests`.
nonisolated enum SearchRequestRoute: Equatable {
    /// iOS 26: the Search tab, with the query in its field (nil: focus the empty field).
    case searchTab(query: String?)
    /// iOS 17.6–25 (legacy shell, no Search tab): Library's Books root and its own field.
    case librarySearch(query: String?)

    /// Nil for any link that isn't a search link.
    static func route(for url: URL, hasSearchTab: Bool) -> SearchRequestRoute? {
        guard url.scheme == "shelfhead", url.host == "search" else { return nil }
        let query = DeepLinkParser.searchQuery(in: url)
        return hasSearchTab ? .searchTab(query: query) : .librarySearch(query: query)
    }

    /// The Search tab only exists on the iOS 26 `TabView` shell (`modernTabCore`).
    static var systemHasSearchTab: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/// Batch 497 (REVIEW 2026-11-11 Y1): what `shelfhead://series?name=` does. A series is opened
/// only on an exact name match (case, diacritics and width ignored; never "closest") that is
/// unique; everything else (no list, no match, two matches) falls back to the search link.
/// Pinned by `Batch497LinkTests`.
nonisolated enum SeriesNameRoute: Equatable {
    case open(Int)          // index into the candidates
    case search(URL?)       // `shelfhead://search?q=<name>`

    /// `candidateNames`: each series' names (nil when the library isn't loaded or the server
    /// couldn't be reached).
    static func decide(name: String, candidateNames: [[String]]?) -> SeriesNameRoute {
        let fallback = SeriesNameRoute.search(searchURL(for: name))
        guard let candidateNames else { return fallback }
        let wanted = folded(name)
        guard !wanted.isEmpty else { return fallback }
        let hits = candidateNames.indices.filter { candidateNames[$0].contains { folded($0) == wanted } }
        return hits.count == 1 ? .open(hits[0]) : fallback
    }

    static func searchURL(for name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shelfhead"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        return components.url
    }

    static func folded(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Batch 497 (REVIEW 2026-11-11 Spotlight): turns Spotlight's "Search in App" continuation into
/// the `shelfhead://search` link. Pinned by `Batch497LinkTests`.
nonisolated enum SpotlightSearchContinuation {
    /// The link for a query-continuation activity, or nil for any other activity type. A missing,
    /// non-string or blank query gives the bare `shelfhead://search` (focus the field).
    static func url(activityType type: String, userInfo: [AnyHashable: Any]?) -> URL? {
        guard type == CSQueryContinuationActionType else { return nil }
        let raw = (userInfo?[CSSearchQueryString] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return URL(string: "shelfhead://search") }
        return SeriesNameRoute.searchURL(for: raw)
    }
}

enum DeepLinkParser {

    /// The smart filter a `shelfhead://library?smartFilter=<rawValue>` link asks for, or
    /// nil for anything else — a plain `shelfhead://library`, a different host, an empty
    /// value, or a raw value no `SmartFilter` case matches.
    ///
    /// An unknown raw value deliberately degrades to "just open Library" rather than
    /// being rejected: these URLs are user-authorable (Shortcuts, a home-screen
    /// bookmark) and can outlive a renamed case, and landing on an unfiltered Library is
    /// a far better outcome than a link that silently does nothing at all.
    static func smartFilter(in url: URL) -> SmartFilter? {
        guard url.host == "library",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "smartFilter" })?.value,
              !raw.isEmpty else { return nil }
        return SmartFilter(rawValue: raw)
    }

    /// The inverse, so an in-process caller can queue itself as a `PendingUnlockAction`
    /// while the app is locked without hand-assembling the URL the replay path parses
    /// back out. `SmartFilter`'s raw values are plain camel-case identifiers, so there is
    /// nothing here to percent-encode — the `URLComponents` round trip is used anyway so
    /// that stays true by construction rather than by assumption.
    static func libraryURL(smartFilter: SmartFilter) -> URL? {
        var components = URLComponents()
        components.scheme = "shelfhead"
        components.host = "library"
        components.queryItems = [URLQueryItem(name: "smartFilter", value: smartFilter.rawValue)]
        return components.url
    }

    // MARK: Batch 490 (REVIEW 2026-11-11 F14)

    /// The first path component of a `shelfhead://<host>/<id>` link, or nil for another host or
    /// an empty id.
    static func pathID(in url: URL, host: String) -> String? {
        guard url.host == host,
              let id = url.pathComponents.first(where: { $0 != "/" }),
              !id.isEmpty else { return nil }
        return id
    }

    static func bookID(in url: URL) -> String? { pathID(in: url, host: "book") }
    static func seriesID(in url: URL) -> String? { pathID(in: url, host: "series") }
    static func authorID(in url: URL) -> String? { pathID(in: url, host: "author") }

    /// Batch 497 (REVIEW 2026-11-11 Y1): `shelfhead://series?name=<name>`, the series named rather
    /// than identified (a Release Radar entry has no Audiobookshelf id). Trimmed; nil when absent
    /// or blank, or when the link carries an id path (`series/<id>` wins).
    static func seriesName(in url: URL) -> String? {
        guard url.host == "series", seriesID(in: url) == nil,
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `shelfhead://series?name=<name>`, percent-encoded by `URLComponents`.
    static func seriesURL(named name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shelfhead"
        components.host = "series"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// `shelfhead://book/<id>?t=<seconds>`: where to start, in seconds. Only a finite,
    /// non-negative number counts; anything else (missing, empty, "abc", -5, nan, inf) is nil,
    /// so the link just opens the book.
    static func startTime(in url: URL) -> Double? {
        guard url.host == "book",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value,
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// Batch 495 (REVIEW 2026-11-11 Y1): `shelfhead://book/<id>?play=1` asks to play the book
    /// (the download-complete notification's Play action). Only the exact value "1" counts.
    static func wantsPlay(in url: URL) -> Bool {
        guard url.host == "book" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "play" })?.value == "1"
    }

    /// `shelfhead://search?q=<text>`: the search text, trimmed, or nil when absent or blank.
    static func searchQuery(in url: URL) -> String? {
        guard url.host == "search",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Batch 490 (REVIEW 2026-11-11 E1): the server's copy of a linked book when it answered,
    /// else the downloaded copy, else nil (the caller says it couldn't open it).
    static func resolvedBook<Item>(fetched: Item?, downloaded: Item?) -> Item? {
        fetched ?? downloaded
    }
}

private struct BottomBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview {
    ContentView()
        .environment(AuthViewModel())
        .environment(PlayerViewModel())
        .environment(LibraryViewModel())
}
