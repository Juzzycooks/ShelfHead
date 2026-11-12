import SwiftUI
import AVFoundation
import UIKit
import CarPlay
import Intents
import AppIntents
import TipKit
import os

/// REVIEW G1: the iPhone app is portrait-only except while Driving Mode is on screen. The
/// Info.plist still lists Portrait + both Landscapes (the app delegate's mask is intersected
/// with it, so it can only narrow, never widen); `AppDelegate` answers with `mask`, and
/// Driving Mode flips it through `OrientationLock.setDrivingMode`.
enum OrientationPolicy {
    /// Pure decision: Driving Mode on allows everything but upside-down, otherwise portrait.
    static func mask(drivingModeActive: Bool) -> UIInterfaceOrientationMask {
        drivingModeActive ? .allButUpsideDown : .portrait
    }
}

@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = OrientationPolicy.mask(drivingModeActive: false)

    /// Driving Mode appeared (`true`) or went away (`false`).
    static func setDrivingMode(_ active: Bool) {
        mask = OrientationPolicy.mask(drivingModeActive: active)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        // Tell the root and whatever is presented on it (Driving Mode is a full-screen cover).
        var vc = scene.keyWindow?.rootViewController
        while let current = vc {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = current.presentedViewController
        }
        if !active {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }
}

/// Handles background URLSession completion events for downloads.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
        DownloadManager.shared.ensureSessionReady()
    }

    /// Item 3 (REVIEW-2026-09-09-REMAINING.md): a play session pre-warmed for the next
    /// Up Next book is a real open row on the server; every in-app drop path now closes it
    /// (`PlayerViewModel.resolvePrefetchedSession`), and this is the termination half.
    /// Best-effort by nature — the close is a single fire-and-forget POST, and iOS gives
    /// a terminating process only a few seconds — but it's the only chance that row gets.
    /// Deliberately *not* hooked to `.background`: audio keeps playing there and the warm
    /// session is about to be handed off, not abandoned.
    func applicationWillTerminate(_ application: UIApplication) {
        PlaybackCoordinator.shared.playerViewModel?.discardPrefetchedSession()
    }

    /// Batch 362 (PL-14 follow-up, user report: CarPlay's Siri row answered "not implemented
    /// yet"). `ShelfHeadIntents` answers `INPlayMediaIntent` with `.handleInApp`, which per
    /// Apple's docs launches the app in the background and asks the app delegate for a
    /// handler (`application(_:handlerFor:)`, iOS 14.0; only called for apps that support
    /// multiple scenes, which this one does for CarPlay). It does not deliver an
    /// `NSUserActivity` continuation — that's `.continueInApp` — so with no handler here Siri
    /// had nothing to hand the request to. The app's Info.plist lists the intent under
    /// `INIntentsSupported`, which this method requires.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaIntentHandler() : nil
    }

    /// REVIEW G1: portrait unless Driving Mode is up (see `OrientationLock`).
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }

    /// Batch 453: the app window gets `HouseholdSceneDelegate` so a tapped household invite
    /// reaches `windowScene(_:userDidAcceptCloudKitShareWith:)`. The configuration is loaded
    /// by name from the Info.plist manifest, so CarPlay keeps its own delegate class.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: connectingSceneSession.configuration.name,
                                          sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            config.delegateClass = HouseholdSceneDelegate.self
        }
        return config
    }
}

/// Plays what Siri heard ("play Emma") or, for a bare "play", the most recent unfinished book.
/// Not gated on App Lock, same as Siri's "Resume Listening": it starts audio and shows nothing.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let name = PlayMediaRequest.mediaName(intent.mediaSearch?.mediaName)
        await PlaybackCoordinator.shared.playRequestedInBackground(mediaName: name)
        return INPlayMediaIntentResponse(code: .success, userActivity: nil)
    }
}

@main
struct ShelfHeadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var authViewModel = AuthViewModel()
    /// Batch 329: declared WITHOUT a default and assigned in `init()` via
    /// `State(initialValue:)`. Under Xcode 27's `@State` macro (TN3211), reading a `@State`
    /// property's value inside `init()` — before the `State` is installed on a view — no
    /// longer returns the stored initial instance; it logs "Accessing State<…>'s value
    /// without being installed on a View. This will create a new … instance each time" and
    /// hands back a throwaway. `init()` below reads both of these to wire
    /// `PlaybackCoordinator` and `WatchSessionManager`, so on every iOS 27 build since
    /// 5.6 (1) those two were attached to orphan view models (the coordinator self-healed
    /// in `ContentView.task`; the Watch bridge did not). Same pattern as
    /// `AddServerView`'s `_serverURL = State(initialValue:)`; the rule TN3211 warns about
    /// (init value discarded) only bites when a declaration-site default ALSO exists.
    @State private var playerViewModel: PlayerViewModel
    @State private var libraryViewModel: LibraryViewModel
    /// Appearance + accent, in one observable object instead of duplicated `@AppStorage`
    /// reads (see ThemeStore.swift). Reading `themeStore.accentHex` here re-renders the
    /// whole tree when it changes, so `Color.shelfAmber` (and the global tint) update live.
    @State private var themeStore = ThemeStore.shared

    init() {
        // Polish pass (J2-17): launch timing baseline (signpost interval + milestone; see `LaunchTrace`).
        LaunchTrace.prime()
        let appInitState = LaunchTrace.signposter.beginInterval("AppInit")
        defer {
            LaunchTrace.signposter.endInterval("AppInit", appInitState)
            LaunchTrace.mark("appInitEnd")
        }
        // Phase 1: register the transcription BGTask handlers (new ids only) before launch finishes.
        TranscriptionScheduler.registerHandlers()
        // Batch 329: build the two view models as locals and hand the SAME instances to
        // `State` and to the two singletons below — see the property declarations.
        let player = PlayerViewModel()
        let library = LibraryViewModel()
        _playerViewModel = State(initialValue: player)
        _libraryViewModel = State(initialValue: library)
        NSSetUncaughtExceptionHandler { exception in
            // S3 (REVIEW_2026-08-20_UI_SECURITY.md): this was the one logging path in the
            // app that bypassed `ShelfLog.redact()` (`Services/ShelfLog.swift`) — `NSLog`
            // also writes to the unified system log without `os.Logger`'s `%{private}`
            // treatment. An `NSException` surfacing from Foundation/AVFoundation/
            // URLSession internals can carry a failing URL in `reason` or `userInfo`, and
            // when the opt-in `streamWithURLToken` setting is on (Settings > Streaming,
            // default off) that URL carries `?token=`. Fix: route `name`/`reason` through
            // `ShelfLog.redact` before logging, and drop `userInfo` entirely rather than
            // redact it — `name` + `reason` are what's actually diagnostic, and `userInfo`
            // is the part most likely to carry a raw request/URL.
            NSLog("🛑 UNCAUGHT EXCEPTION name=%@ reason=%@",
                  ShelfLog.redact(exception.name.rawValue),
                  ShelfLog.redact(exception.reason ?? "nil"))
        }
        SettingsStore.registerDefaults()
        // Every one-time settings migration, in order, exactly once. Must run before any
        // view reads the settings its steps seed — `HomeView`'s `@State` captures
        // `hiddenHomeSections`/`homeSectionOrder` at initialization, so running this any
        // later (e.g. from `HomeView.task`) risks a cold launch capturing the
        // pre-migration values if `HomeView` mounts before that task's first await point
        // resumes. This was three separate calls whose required ordering lived only in
        // this comment; `SettingsMigrator` now owns it.
        SettingsMigrator.runIfNeeded()
        // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10): must run once, before any
        // `.popoverTip(...)` in the view tree could possibly evaluate its rules —
        // TipKit itself (not any one tip) needs this configure call to be ready.
        AppTips.configure()
        configureAudioSession()
        configureAppearance()
        // Wire this up here — unconditionally, at process init — rather than relying
        // solely on ContentView's `.task` (which only runs once a Scene actually
        // renders a view). Widget/Siri intents conforming to `AudioPlaybackIntent` can
        // launch this app in the background purely to run `perform()`, and it's not
        // guaranteed that SwiftUI ever instantiates/renders `ContentView`'s body in
        // that kind of headless launch — if it doesn't, `ContentView.task` never runs,
        // `PlaybackCoordinator.shared.playerViewModel` stays nil forever, and every
        // widget/Siri playback action silently no-ops waiting on a view model that
        // will never arrive. Assign the local built at the top of this `init()` (NOT the
        // `@State` property — see its declaration for the Xcode 27 macro trap) so the
        // coordinator holds the very instance the view tree will get, guaranteed on every
        // launch regardless of whether any UI ever appears.
        // (ContentView's `.task` still does this too; harmless, redundant safety net.)
        PlaybackCoordinator.shared.playerViewModel = player
        // Apple Watch companion bridge (see Services/WatchSessionManager.swift). Purely
        // additive: activation is a no-op without a paired Watch, and nothing else in
        // the app depends on it existing.
        WatchSessionManager.shared.activate()
        WatchSessionManager.shared.attach(playerViewModel: player, libraryViewModel: library)
        // Batch 406: live progress from the server (socket.io). Idles until an account exists
        // and restarts itself on `.shelfheadAccountChanged`; locals, not the `@State`s (see above).
        ServerEventSocket.shared.start(player: player, library: library)
        // Review 2 Low (Sync) (30 October 2026): created at launch so its init warms the
        // cross-device scope cache and starts observing account switches before the first
        // offline play needs an iCloud position.
        _ = CloudPositionStore.shared
        // Recreate the background download session so it reconnects to any
        // in-flight downloads from a previous launch.
        DownloadManager.shared.ensureSessionReady()
        // Needed so the "download only while charging" policy can read battery state.
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Force App Shortcut (Siri phrase) registration now rather than waiting for the
        // system's periodic refresh, so "Hey Siri, Play ShelfHead" runs the intent
        // instead of offering to create a shortcut.
        ShelfHeadShortcuts.updateAppShortcutParameters()
        // Trim the disk cover cache (F3) if it's grown past its cap. Cheap directory
        // walk, but off-main and low-priority since it's not needed for anything on
        // the critical launch path.
        Task.detached(priority: .utility) { DiskCoverCache.evictIfNeeded() }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authViewModel)
                .environment(playerViewModel)
                .environment(libraryViewModel)
                .environment(themeStore)
                // CO-1 (docs/visual-design-review.md, Round V1): the root tint feeds
                // system controls (tab selection, confirmationDialog buttons, pickers,
                // links) that render it as *text*, and the raw accent measures ~1.9:1 on
                // Light. `shelfAmberText` is identical to the accent in Dark and darkened
                // to ≥4.5:1 in Light; it stays live because it reads the `@Observable`
                // `ThemeStore.cachedAccentTextColor`, which is recomputed whenever
                // `accentHex` changes.
                //
                // CO-8 (Batch 353): Toggle, Picker and DatePicker rows inherit this tint
                // rather than setting `.tint(Color.shelfAmber)` themselves, so in Light they
                // get the darker token too. Don't re-add a per-row override on them. The 13
                // `.tint(Color.shelfAmber)` sites that remain are genuine fills (swipe
                // actions, sliders, a progress bar, a prominent button, glass tints).
                .tint(Color.shelfAmberText)
                .preferredColorScheme(themeStore.appearance.colorScheme)
        }
        // Batch 406: background app refresh flushes queued progress and runs the existing
        // auto-download rules while the app is closed. The modifier registers the handler
        // itself, so there's no `BGTaskScheduler.register` anywhere (a second registration
        // for the same identifier crashes). `perform()` reschedules in a `defer`.
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.identifier)) {
            await BackgroundRefreshScheduler.perform()
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist the listening position when leaving the foreground — the
            // 15s sync timer stops once suspended, so this guards against losing
            // position on backgrounding, force-quit, or a crash. Also retries any
            // queued offline progress when we come back to the foreground.
            switch phase {
            case .inactive, .background:
                AudioPlayerService.shared.flushProgress()
                // The connectivity banner (F10) is only ever visible in the foreground,
                // but the app itself stays alive for the full duration of background
                // audio playback — a long audiobook session could otherwise mean
                // hundreds of pings to the user's server for a banner nobody can see,
                // waking the network/radio for no visible benefit. `startPolling()` is
                // safe to call again on the next `.active` (it cancels any previous
                // poll first).
                ReachabilityPollGate.stop()
                if phase == .background {
                    BackgroundRefreshScheduler.schedule()
                    // Phase 1: queue the overnight transcription pass if books still need one.
                    TranscriptionScheduler.scheduleOvernightIfNeeded()
                }
            case .active:
                AudioPlayerService.shared.flushPendingProgress()
                // Bookmarks made offline (or from CarPlay / the lock screen with no usable
                // connection) replay here as well as on the connectivity-restored hook —
                // coming back to the app is the other natural moment for it, and covers a
                // launch where the network never actually transitioned.
                Task { await BookmarkSyncService.shared.flush() }
                // Reflect anything started from CarPlay/Siri while the phone UI was closed.
                playerViewModel.adoptActiveSessionIfNeeded()
                // Polish pass (J2-12): `ContentView`'s `.task` also starts polling on a cold
                // launch; `ReachabilityPollGate` lets only the first of the two through.
                ReachabilityPollGate.start()
            @unknown default:
                break
            }
        }
    }

    private func configureAudioSession() {
        // Set the category at launch; activation happens when playback starts
        // (see AudioPlayerService.play) so we don't interrupt other audio early.
        let session = AVAudioSession.sharedInstance()
        do {
            // Batch 329: no options, on purpose. The iOS 27 SDK header is explicit that for
            // output-only categories like `.playback` "AllowBluetoothA2DP is always
            // implicitly true and cannot be changed", and that `.allowAirPlay` is "only
            // valid with PlayAndRecord" — and iOS 27 now enforces it: the old
            // `[.allowBluetoothA2DP, .allowAirPlay]` failed with `paramErr` (-50) on a real
            // iPhone 17 (user's console, 15 Sep 2026), so the catch below fell back to
            // plain `.playback` and the app ran WITHOUT `.spokenAudio` mode. AirPods /
            // AirPlay routing is unaffected by dropping the options: it's the category's
            // default behaviour. The fallback stays as belt and braces.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            // Bug investigation (26 August 2026): user's console showed "Failed to
            // configure audio session: Error Domain=NSOSStatusErrorDomain Code=-50" —
            // this exact catch block (previously a bare `#if DEBUG print`, invisible
            // in Release and not in the Settings > Diagnostics export). Code -50
            // (`paramErr`) from this exact category/mode/options combination is a
            // known false failure specifically on the iOS Simulator's simulated
            // audio hardware — the combination is valid per Apple's documented
            // category/option compatibility table and works on a real device — but
            // rather than assume "just the simulator" and leave the app with no
            // configured category at all if this genuinely fails on a real device
            // (e.g. some third-party accessory conflicting with A2DP), retry once
            // with a minimal, near-certain-to-succeed category instead. Losing the
            // Bluetooth/AirPlay auto-routing this once is a much smaller failure than
            // silently breaking all playback because no category was ever set.
            ShelfLog.error(.playback, "Audio session setCategory(.playback, mode: .spokenAudio) failed: \(error.localizedDescription) — retrying with a minimal category")
            do {
                try session.setCategory(.playback)
            } catch {
                ShelfLog.error(.playback, "Audio session fallback setCategory(.playback) also failed: \(error.localizedDescription)")
            }
        }
    }

    private func configureAppearance() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Color.shelfBackground)
        // Adaptive title color (cream on dark, espresso on light) via the dynamic shelfCream.
        let titleColor = UIColor(Color.shelfCream)
        navAppearance.titleTextAttributes = [.foregroundColor: titleColor]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: titleColor]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        // Code review fix (26 August 2026): this comment was stale — true only on the
        // legacy path (`ContentView.legacyTabs`, iOS 17–25), which does use the custom
        // `RetroTabBar`. Since D5 (Batch 163), `ContentView.modernTabs` (iOS 26+) uses a
        // real system `TabView`/`Tab`, which does have its own `UITabBarAppearance`.
        // This method still only themes the nav bar; no equivalent tab bar styling is
        // applied on the modern path. **[device check]**: whether the nav bar (forced
        // opaque `shelfBackground`) and the untouched system tab bar visually agree on
        // iOS 26+ hasn't been confirmed on a real device/simulator.
    }
}
