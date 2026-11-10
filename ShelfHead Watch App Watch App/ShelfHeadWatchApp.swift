import SwiftUI

@main
struct ShelfHeadWatchApp: App {
    // Added 9 September 2026 (review HIGH, watchOS): `WatchLocalDownloadManager`'s
    // background session sets `sessionSendsLaunchEvents = true`, which only means
    // anything if something implements `handle(_ backgroundTasks:)` — nothing did,
    // and there was no delegate adaptor at all. See `WatchAppDelegate`. This is also
    // where the app's single `MPRemoteCommandCenter` registration now happens
    // (`WatchRemoteCommandRouter`), replacing the two competing ones the stores each
    // used to make in their own `init`.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var store = WatchConnectivityStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §8.1a): root conditionally on
            // whether something's actually playing — see `WatchRootView`'s own doc
            // comment for the decide-once reasoning.
            WatchRootView()
                .environment(store)
                // Stage 2 prototype (WATCH_STANDALONE_PROPOSAL_2026-08-28-ADDENDUM.md
                // §8.1): injected alongside `store`, not in place of it — only
                // `WatchSettingsView` reads `WatchStore` so far, the other twelve
                // screens (per §7.1's per-screen fate table) still read
                // `WatchConnectivityStore` directly until the facade's proven out.
                // `WatchStore.shared` wraps `store` (the same singleton instance)
                // internally, so both environment values observe the same underlying
                // connectivity state.
                .environment(WatchStore.shared)
                .tint(WatchTheme.accent)
                .preferredColorScheme(.dark)
                .task { store.activate() }
                // Stage 2: resolves `WatchStore.authState` from the Keychain at
                // launch, independent of whether the user ever opens Settings —
                // without this, `SettingsView`'s new "Account" row would show
                // "Checking…" indefinitely until first visited.
                .task { await WatchStore.shared.bootstrapAuth() }
                // Stage 3 (addendum §10.2/§10.5): re-decide companion-vs-standalone
                // whenever WatchConnectivity reachability actually transitions, not
                // just at launch and on foreground — `resolveMode()` itself no-ops
                // mid-playback (§2.7), so this can't yank control away from an active
                // standalone session.
                .onChange(of: store.isReachable) { _, _ in
                    WatchStore.shared.resolveMode()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Stop the 1s local progress ticker whenever the scene isn't actually
            // visible (backgrounded, or the transitional `.inactive` state) rather
            // than relying solely on watchOS suspending the process — see
            // `WatchConnectivityStore.setSceneActive(_:)`.
            store.setSceneActive(phase == .active)
            // Foregrounding the Watch app is exactly when a possibly-stale
            // `updateApplicationContext` payload is most likely to be out of date —
            // request a fresh one rather than trusting whatever last arrived.
            if phase == .active {
                store.requestFreshSnapshotOnForeground()
                // Stage 3: foregrounding is also a named natural checkpoint for the
                // companion-vs-standalone decision (§2.7) — re-check here too, not
                // just on launch and on a reachability edge.
                WatchStore.shared.resolveMode()
            }
        }
    }
}

/// The root. Batch 411: the Shelf (`WatchShelfView`) in both modes, with one
/// `NavigationStack` inside it. The "something's already playing, open on Now Playing"
/// launch rule (Stage 6, decided once per launch, fresh snapshots only) and the
/// complication deep link now push onto that stack instead of swapping in a second
/// root with its own stack.
private struct WatchRootView: View {
    @Environment(WatchConnectivityStore.self) private var store
    @Environment(WatchStore.self) private var watchStore

    var body: some View {
        WatchShelfView()
            // The "Play on Watch" hold: a book loading on this Watch's engine makes the
            // Watch the player at once, and stopping it hands back to Automatic. Here
            // because a `View` body tracks `WatchStore` (`WatchStore.nextMode(...)`).
            .onChange(of: watchStore.standalone.isLoaded) { _, _ in
                watchStore.resolveMode()
            }
            // WATCH-4 (REVIEW_2026-08-12.md): the one place that surfaces a failed
            // Watch-to-phone command, on the root so it shows over any screen.
            .alert("Command Failed", isPresented: Binding(
                get: { store.lastCommandFailed != nil },
                set: { if !$0 { store.dismissCommandFailure() } }
            )) {
                Button("OK", role: .cancel) { store.dismissCommandFailure() }
            } message: {
                Text(store.lastCommandFailed ?? "")
            }
    }
}
