import Foundation
import MediaPlayer

/// Single owner of `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` for the whole
/// Watch app — added 9 September 2026 for the review's HIGH "both modes register
/// remote-command handlers at launch."
///
/// **What was broken:** `WatchConnectivityStore.init` and `StandaloneAudioEngine.init`
/// each called their own `configureRemoteCommands()`, and both singletons are built at
/// launch (`WatchStore.init` constructs the engine; the app's `@State` holds the
/// connectivity store). `MPRemoteCommandCenter.shared()` is process-wide and
/// `addTarget` *appends* a handler, so both were live simultaneously: one Control
/// Center play tap ran the companion relay's `togglePlayPause()` **and** the local
/// engine's, and both types wrote `MPNowPlayingInfoCenter.default().nowPlayingInfo`
/// from their own state, so the Now Playing glance flipped between the phone's book
/// and the Watch's depending on which one updated last.
///
/// **Ownership rule (the one this file exists to state):**
/// 1. `MPRemoteCommandCenter` targets are registered exactly once per process, here,
///    by `activate()` — called from `WatchAppDelegate.applicationDidFinishLaunching()`.
///    Neither `WatchConnectivityStore` nor `StandaloneAudioEngine` may call
///    `addTarget`/`removeTarget` any more.
/// 2. Which engine a command reaches is decided **at invocation time** from
///    `WatchStore.shared.mode`, not at registration time. That's deliberate: mode can
///    change between launch and the tap, and re-registering targets on every mode
///    transition (the other option the review offered) means the correctness of
///    Control Center depends on never missing a transition. Reading the mode when the
///    command actually fires cannot go stale.
/// 3. Only the mode that owns playback may write `MPNowPlayingInfoCenter`. Both
///    `WatchConnectivityStore.updateNowPlayingInfo()` and
///    `StandaloneAudioEngine.updateNowPlayingInfo()` now publish through
///    `publish(_:as:)` below, which drops a write from the inactive mode instead of
///    letting it overwrite the active one. Clearing counts as a write, so a
///    standalone teardown can no longer blank the companion glance either.
/// 4. `modeDidChange(to:)` (called from `WatchStore.resolveMode()`) clears the
///    outgoing mode's info and asks the incoming one to republish, so the glance
///    switches once, cleanly, instead of drifting.
///
/// **[device check]**: written without a watchOS device/simulator available. The
/// symptom this fixes (one Control Center tap acting twice) and its fix are both
/// only observable on real hardware's Now Playing glance.
@MainActor
final class WatchRemoteCommandRouter {
    static let shared = WatchRemoteCommandRouter()

    /// Who is allowed to drive playback and the Now Playing glance right now.
    enum Owner: Equatable {
        case companion
        case standalone
    }

    /// The five commands this app actually registers. An enum rather than five
    /// near-identical closures so `dispatch(_:)` holds the whole mode-vs-command
    /// matrix in one readable place.
    private enum Command {
        case play, pause, toggle, skipForward, skipBackward
    }

    private var isActive = false

    private init() {}

    /// Pure mapping from mode to Now Playing/command owner. `nonisolated static` so
    /// it can be pinned by the Watch test target without standing up either engine —
    /// same convention as `StandaloneAudioEngine.resumePosition(...)`.
    nonisolated static func owner(for mode: WatchStore.Mode) -> Owner {
        switch mode {
        case .companion: return .companion
        case .standalone: return .standalone
        }
    }

    var currentOwner: Owner { Self.owner(for: WatchStore.shared.mode) }

    // MARK: - Registration

    /// Idempotent: called once from the app delegate, but safe if a future call site
    /// (a test, a re-activation) runs it again — the guard is what makes "registered
    /// exactly once per process" true rather than merely intended.
    func activate() {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.dispatch(.play) ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatch(.pause) ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatch(.toggle) ?? .commandFailed
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.dispatch(.skipForward) ?? .commandFailed
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.dispatch(.skipBackward) ?? .commandFailed
        }
        applyPreferredIntervals(for: WatchStore.shared.mode)
    }

    /// `preferredIntervals` is the one piece of remote-command configuration that
    /// genuinely differs per mode (companion mirrors the phone's own synced
    /// intervals; standalone uses the engine's own constants), so it's re-applied on
    /// every transition rather than fixed at registration.
    private func applyPreferredIntervals(for mode: WatchStore.Mode) {
        let center = MPRemoteCommandCenter.shared()
        let forward: Double
        let backward: Double
        switch Self.owner(for: mode) {
        case .companion:
            let state = WatchConnectivityStore.shared.playbackState
            forward = state?.skipForwardInterval ?? 30
            backward = state?.skipBackwardInterval ?? 15
        case .standalone:
            forward = StandaloneAudioEngine.skipForwardSeconds
            backward = StandaloneAudioEngine.skipBackwardSeconds
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
    }

    // MARK: - Dispatch

    private func dispatch(_ command: Command) -> MPRemoteCommandHandlerStatus {
        switch currentOwner {
        case .companion:
            let store = WatchConnectivityStore.shared
            // `.commandFailed`, not `.noActionableNowPlayingItem`: that case is
            // declared `MP_API(ios(9.1), macos(10.12.2))` with no watchOS clause in
            // this SDK's `MPRemoteCommand.h`, and `.commandFailed` is exactly what
            // both stores' own handlers returned here before this router existed —
            // no behaviour change on top of the ownership fix.
            guard let state = store.playbackState else { return .commandFailed }
            switch command {
            case .play:
                if !state.isPlaying { store.togglePlayPause() }
            case .pause:
                if state.isPlaying { store.togglePlayPause() }
            case .toggle:
                store.togglePlayPause()
            case .skipForward:
                store.forward()
            case .skipBackward:
                store.rewind()
            }
            return .success
        case .standalone:
            let engine = WatchStore.shared.standalone
            // `isLoaded`, not `currentItemId`: the latter deliberately survives a
            // `stop()` (it backs the Continue Listening row), so it isn't a usable
            // "is there something to command" test.
            guard engine.isLoaded else { return .commandFailed }
            switch command {
            case .play:
                if !engine.isPlaying { engine.togglePlayPause() }
            case .pause:
                if engine.isPlaying { engine.togglePlayPause() }
            case .toggle:
                engine.togglePlayPause()
            case .skipForward:
                engine.skipForward()
            case .skipBackward:
                engine.skipBackward()
            }
            return .success
        }
    }

    // MARK: - Now Playing ownership

    /// The only place in the Watch app that assigns `nowPlayingInfo`. A write from
    /// the mode that isn't active is dropped rather than applied — including a `nil`
    /// (clearing) write, which is how a standalone teardown used to blank the
    /// companion glance.
    func publish(_ info: [String: Any]?, as owner: Owner) {
        guard currentOwner == owner else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Called from `WatchStore.resolveMode()` when `mode` actually changed. Clears
    /// whatever the outgoing mode left behind (bypassing `publish(_:as:)` on purpose
    /// — by this point the new mode is already the owner, so an owner-gated clear
    /// would be attributed to the wrong side) and lets the incoming mode republish
    /// from its own state.
    func modeDidChange(to mode: WatchStore.Mode) {
        applyPreferredIntervals(for: mode)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        switch Self.owner(for: mode) {
        case .companion:
            WatchConnectivityStore.shared.refreshNowPlayingInfo()
        case .standalone:
            WatchStore.shared.standalone.refreshNowPlayingInfo()
        }
    }
}
