import Foundation
// CRIT-3 follow-up (this pass, 15 Aug 2026): `@preconcurrency` — the compiler's own
// suggested fix for the `WCSession` capture errors below (`activationDidCompleteWith`,
// `sessionReachabilityDidChange`). WatchConnectivity's own types (like `WCSession`)
// predate Swift's concurrency checking and aren't marked `Sendable` in this SDK;
// `@preconcurrency` tells the checker to trust this module's types as it did before
// `SWIFT_STRICT_CONCURRENCY` was enabled, rather than treating every reference to one
// of its types as a fresh Sendable violation.
@preconcurrency import WatchConnectivity
import Observation
import WatchKit
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Watch-side half of the ShelfHead <-> iPhone bridge. Owns all state the Watch UI
/// observes and is the single place that talks to `WCSession` on this side.
///
/// SYNC BOUNDARY (iPhone -> Watch): `session(_:didReceiveApplicationContext:)` and
/// `session(_:didReceiveMessage:)` are the only inbound entry points. Both hop to the
/// main actor before touching any of the `@Observable` state below, since WatchKit/
/// WatchConnectivity callbacks aren't guaranteed to land on the main thread.
///
/// SYNC BOUNDARY (Watch -> iPhone): every command sent up (`send(_:)`) is optimistic —
/// the UI updates immediately for responsiveness, but is rolled back if the phone
/// replies with a failure (stale/cross-account/no active item), or if no reply arrives
/// within a short timeout (phone unreachable). This file never treats "I sent a command"
/// as "the phone applied it."
///
/// **Credential awareness (Stage 2, standalone Watch app, 28 August 2026):** this file
/// otherwise still doesn't know or care about `AuthStore`/`KeychainService`/tokens —
/// the credential handoff itself is a separate `sendMessage`/reply exchange driven
/// entirely by `WatchStore.requestHandoffFromPhone()`, never touching this class. The
/// one exception is `apply(context:)`'s `"wipeCredentials"` branch: when the phone
/// signals a sign-out or account switch, something on the Watch side has to notice and
/// act, and this is the one place every inbound phone->Watch payload already lands —
/// adding a second, parallel inbound-message pathway just to keep this file
/// credential-agnostic would be more indirection for no real benefit. The action itself
/// (clearing the Watch's own Keychain) is still delegated out, to
/// `WatchStore.wipeCredentials()` — this file recognizes the signal, it doesn't
/// implement the wipe.
@MainActor
@Observable
final class WatchConnectivityStore: NSObject {
    static let shared = WatchConnectivityStore()

    // MARK: - Observed state

    private(set) var playbackState: WatchPlaybackState? {
        didSet {
            // L14: companion mode feeds the complication too (the phone owns playback).
            guard playbackState != oldValue else { return }
            // Review Low (complication, 30 October 2026): while this Watch is playing on its
            // own, the standalone engine owns the complication; the phone's state must not overwrite it.
            guard !WatchStore.shared.standalone.isLoaded else { return }
            if let state = playbackState, state.hasActiveItem {
                WatchComplicationStore.publish(WatchComplicationSnapshot(
                    title: state.title, author: state.author,
                    progress: WatchComplicationSnapshot.progress(currentTime: state.currentTime, duration: state.duration),
                    isPlaying: state.isPlaying, updatedAt: Date()))
            } else {
                WatchComplicationStore.publish(nil)
            }
        }
    }
    private(set) var chapters: [WatchChapterSummary] = []
    private(set) var bookmarks: [WatchBookmarkSummary] = []
    private(set) var downloads: [WatchDownloadSummary] = []
    private(set) var recentlyAdded: [WatchBookSummary] = []
    private(set) var collections: [WatchCollectionSummary] = []

    /// True once `WCSession` has completed activation on this device.
    private(set) var isActivated = false
    /// True if the paired iPhone is currently reachable for immediate (message-based)
    /// commands. Background/context-based state sync still works even when this is
    /// false; only immediate command delivery needs reachability.
    private(set) var isReachable = false
    /// True if we've never received a snapshot at all (fresh install / first launch
    /// before the phone has pushed anything) — distinct from "stale," which means we
    /// HAVE a snapshot but it's too old to trust.
    var hasReceivedAnySnapshot: Bool { playbackState != nil }

    /// WATCH-4 (REVIEW_2026-08-12.md): every one of the ten Watch->phone convenience
    /// senders below discarded `send(...)`'s completion handler entirely. For the two
    /// with optimistic UI (`togglePlayPause`, `cyclePlaybackSpeed`) a failure just
    /// silently snapped the control back with no explanation; for the other eight
    /// (bookmark add/seek, chapter seek, sleep timer, `playItem`, `markFinished`, plain
    /// seek) NOTHING visibly happened at all — including after confirming the
    /// destructive "Mark as Finished" confirmation dialog. This is set centrally in
    /// `sendCommand` (every sender funnels through it) rather than duplicated across
    /// ten call sites, so every command gets the same failure surface for free. A view
    /// keys a toast/alert off this (see `WatchRootView`'s `.alert`); `nil` means
    /// "nothing to show." Cleared on the next successful command.
    private(set) var lastCommandFailed: String?

    /// Polish pass (WA-6): set (for `phoneNoticeDuration`) when a command failed only because
    /// the iPhone couldn't be reached. Now Playing shows it inline ("iPhone not reachable")
    /// instead of the full-screen "Command Failed" alert, which stays for real errors.
    private(set) var phoneUnreachableNotice = false
    private var phoneNoticeTask: Task<Void, Never>?
    nonisolated static let phoneNoticeDuration: Double = 4

    /// WATCH-4: the Watch target had ZERO haptics anywhere before this fix, despite the
    /// rest of the app (per the review) being generous with them. `WKInterfaceDevice`
    /// haptics are the standard watchOS acknowledgment for "something happened" without
    /// requiring the user to be looking at the screen — appropriate here since most of
    /// these commands are issued from a glance-and-tap interaction.
    private func playHaptic(success: Bool) {
        WKInterfaceDevice.current().play(success ? .success : .failure)
    }

    private var localTickTimer: Timer?

    private override init() {
        super.init()
    }

    /// Republishes the companion Now Playing glance from current state — the hook
    /// `WatchRemoteCommandRouter.modeDidChange(to:)` calls when companion mode becomes
    /// the active owner, so the glance switches over immediately instead of waiting
    /// for the next snapshot or command.
    func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    /// Companion counterpart to `StandaloneAudioEngine.updateNowPlayingInfo()` —
    /// same shape, sourced from the phone's pushed `playbackState` snapshot (plus
    /// the local `WatchProgressEstimator` extrapolation for elapsed time) instead of
    /// a locally-owned `AVQueuePlayer`. Called after every point `playbackState`
    /// materially changes: the optimistic apply inside `sendCommand` (immediate
    /// Control Center feedback on a local tap) and every real snapshot applied in
    /// `apply(context:)`.
    ///
    /// **9 September 2026 (review HIGH):** publishes through
    /// `WatchRemoteCommandRouter`, which drops the write when standalone mode owns
    /// playback. This file used to assign `MPNowPlayingInfoCenter.default()
    /// .nowPlayingInfo` directly while `StandaloneAudioEngine` did the same from its
    /// own state, so the system glance flipped between the phone's book and the
    /// Watch's depending on which one wrote last. The clearing branch below goes
    /// through the same gate for the same reason — clearing is a write.
    ///
    /// `MPRemoteCommandCenter` registration also used to live here (added 31 August
    /// 2026 so companion mode had Control Center play/pause at all). It has moved,
    /// unchanged in behaviour, into `WatchRemoteCommandRouter`, which routes those
    /// same commands to `togglePlayPause()`/`rewind()`/`forward()` on this type when
    /// companion mode is active — the "one owner" half of the same fix.
    private func updateNowPlayingInfo() {
        guard let state = playbackState, state.hasActiveItem else {
            WatchRemoteCommandRouter.shared.publish(nil, as: .companion)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.author,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: estimatedCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        #if canImport(UIKit)
        if let coverData = state.coverData, let image = UIImage(data: coverData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #endif
        WatchRemoteCommandRouter.shared.publish(info, as: .companion)
    }

    // MARK: - Lifecycle

    /// Call from the Watch app's root view `.task`/`init`. Activating twice is safe —
    /// `WCSession` no-ops if already activated.
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        startLocalTicker()
    }

    /// Call on scenePhase -> active (app foreground) to force a fresh snapshot rather
    /// than trusting whatever `updateApplicationContext` happened to last deliver —
    /// context delivery is "eventually," and a user opening the Watch app wants
    /// up-to-date state now.
    func requestFreshSnapshotOnForeground() {
        send(WatchCommandKind.requestSnapshot, itemId: nil, completion: { _ in })
    }

    /// Drives the ~1s local countdown/progress tick between real snapshots, using
    /// `WatchProgressEstimator` — never mutates `playbackState.currentTime` itself
    /// (that would drift from the phone's truth); views read the estimate directly.
    private func startLocalTicker() {
        localTickTimer?.invalidate()
        localTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // `[weak self]` on BOTH closures — see the matching comment in
            // `WatchSessionManager.startPolling()` for why (Swift 6.4 #ImplicitStrongCapture).
            Task { @MainActor [weak self] in self?.objectWillChangeTick() }
        }
    }

    /// Call from the Watch app's `.onChange(of: scenePhase)` so the 1s ticker doesn't
    /// keep firing (and forcing a view recompute every second) once the scene isn't
    /// visible. watchOS typically suspends the app in the background anyway, but an
    /// explicit stop/start here avoids relying on that for correctness, and also
    /// avoids ticking during transitional (inactive) states where nothing is on
    /// screen to update. Safe to call redundantly — `startLocalTicker()` invalidates
    /// any existing timer first, and invalidating an already-nil timer is a no-op.
    func setSceneActive(_ active: Bool) {
        if active {
            startLocalTicker()
        } else {
            localTickTimer?.invalidate()
            localTickTimer = nil
        }
    }

    /// `@Observable` only invalidates views on property writes it can see, but nothing
    /// about the *displayed* elapsed time is itself a stored property (it's computed
    /// from `playbackState` + wall clock) — so views showing the estimate should read
    /// through this tick counter to know when to recompute. Kept as a tiny observed
    /// counter rather than restructuring the estimator to be timer-driven itself.
    private(set) var tick: Int = 0
    private func objectWillChangeTick() { tick &+= 1 }

    /// Best-effort local scope, derived from the last snapshot received — the Watch has
    /// no independent notion of "signed in account," it only knows what the phone last
    /// told it.
    var currentScope: WatchAccountScope? {
        playbackState?.scope
    }

    var isStateStale: Bool {
        guard let playbackState else { return true }
        // P3-9 (third-pass review, 14 Aug 2026): reads `lastConfirmedUpdate`, not
        // `lastUpdated` — the latter gets rebased to "now" by `togglePlayPause()`'s
        // optimistic apply (correct for the position estimator, wrong for staleness),
        // so using it here made an unconfirmed local toggle report the snapshot as
        // fresh before the phone ever confirmed anything. `lastConfirmedUpdate` is only
        // ever written by a real snapshot from the phone.
        return WatchStaleness.isStale(lastUpdated: playbackState.lastConfirmedUpdate)
    }

    var estimatedCurrentTime: Double {
        guard let playbackState else { return 0 }
        _ = tick   // establish an observation dependency so this recomputes each tick
        return WatchProgressEstimator.estimatedCurrentTime(state: playbackState)
    }

    var estimatedProgress: Double {
        guard let playbackState else { return 0 }
        _ = tick
        return WatchProgressEstimator.progressFraction(state: playbackState)
    }

    // MARK: - Sending commands (optimistic with rollback)

    /// Sends a command to the phone. `optimisticApply` mutates local state immediately
    /// for a snappy UI; if the phone reports failure (or is unreachable and times out),
    /// `rollback` restores the prior value. Both closures are optional — some commands
    /// (bookmarks, sleep timer) don't have a meaningful optimistic local representation
    /// and just wait for the next real snapshot.
    func send(
        _ kind: WatchCommandKind,
        itemId: String?,
        optimisticApply: (() -> Void)? = nil,
        rollback: (() -> Void)? = nil,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard let scope = currentScope else {
            // No idea what account we belong to yet (first launch, reinstall, or after
            // clearing state) — refuse to guess for anything that would actually mutate
            // playback. `.requestSnapshot` is the one exception: it's exactly the
            // command that's supposed to recover from this situation, so refusing to
            // send it here would leave a fresh Watch install permanently stuck with
            // nothing to show and no way to ask the phone for a first snapshot. It
            // carries a nil scope and is validated without a scope check on the phone
            // (see `WatchCommandValidator.validate`).
            guard case .requestSnapshot = kind else {
                reportOutcome(ok: false, reason: String(localized: "Not synced with iPhone yet"))
                completion(false)
                return
            }
            sendCommand(WatchPlaybackCommand(scope: nil, itemId: itemId, kind: kind),
                        optimisticApply: optimisticApply, rollback: rollback, completion: completion)
            return
        }
        sendCommand(WatchPlaybackCommand(scope: scope, itemId: itemId, kind: kind),
                    optimisticApply: optimisticApply, rollback: rollback, completion: completion)
    }

    private func sendCommand(
        _ command: WatchPlaybackCommand,
        optimisticApply: (() -> Void)?,
        rollback: (() -> Void)?,
        completion: @escaping (Bool) -> Void
    ) {
        optimisticApply?()
        updateNowPlayingInfo()

        // NEW-5 / NEW-6 (follow-up review, 14 Aug 2026): `.requestSnapshot` is a
        // background sync — fired on every foreground/activation via
        // `requestFreshSnapshotOnForeground()`, not a user-initiated action — so it
        // shouldn't drive `reportOutcome`'s haptic/`lastCommandFailed` side effects
        // like every other command does. Two concrete bugs came from routing it
        // through `reportOutcome` anyway: (1) a `.success` haptic buzzed on every
        // single app open, since a successful snapshot request looked exactly like
        // a successful user command; (2) worse, on a REAL command's validator-
        // rejection failure (staleState/itemMismatch/noActiveItem/scopeMismatch,
        // below), the order is `rollback() -> requestFreshSnapshotOnForeground() ->
        // reportOutcome(ok: false, ...)` — but that nested `.requestSnapshot`'s own
        // reply lands moments later and, unguarded, called
        // `reportOutcome(ok: true, reason: nil)`, clearing `lastCommandFailed` (and
        // the `.alert` bound to it) before the user could read why the real command
        // failed. Exempting `.requestSnapshot` here fixes both at the root, for
        // every exit of this function, not just the success path.
        let reportsOutcome = command.kind != .requestSnapshot

        guard WCSession.default.activationState == .activated else {
            rollback?()
            if reportsOutcome { reportOutcome(ok: false, reason: String(localized: "Watch isn't connected yet"), phoneUnreachable: true) }
            completion(false)
            return
        }

        guard let data = try? JSONEncoder().encode(command) else {
            rollback?()
            if reportsOutcome { reportOutcome(ok: false, reason: String(localized: "Couldn't send that command")) }
            completion(false)
            return
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["command": data], replyHandler: { reply in
                let ok = (reply["ok"] as? Bool) ?? false
                Task { @MainActor in
                    if !ok {
                        rollback?()
                        self.requestFreshSnapshotOnForeground()
                        if reportsOutcome {
                            self.reportOutcome(ok: false, reason: self.failureMessage(for: reply["reason"] as? String))
                        }
                    } else if reportsOutcome {
                        self.reportOutcome(ok: true, reason: nil)
                    }
                    completion(ok)
                }
            }, errorHandler: { _ in
                Task { @MainActor in
                    rollback?()
                    if reportsOutcome { self.reportOutcome(ok: false, reason: String(localized: "iPhone didn't respond"), phoneUnreachable: true) }
                    completion(false)
                }
            })
        } else {
            // Not reachable right now (phone locked/out of range/app backgrounded in a way
            // that suspends messaging). This used to also write the command into
            // `updateApplicationContext` under a "pendingCommand" key, on the theory that
            // it would still land once the phone reconnects — but that was misleading on
            // two counts. First, `WatchSessionManager` (the phone side) never actually
            // reads a "pendingCommand" key at all, so the write was completely inert: it
            // could never have been applied, no matter how long we waited. Second, even if
            // something *did* read it, `updateApplicationContext` replaces its entire
            // dictionary on every call and only the phone's last-received value survives —
            // it's a "latest wins" mailbox, not a queue, so relying on it to eventually
            // deliver a command would silently drop every command but the most recent one
            // sent before reconnection, with no error to show for it.
            //
            // Given neither half of that ever worked, the only honest behaviour is to fail
            // immediately: roll back the optimistic UI update and report failure right now,
            // the same as any other unreachable-phone case, so the user sees the action
            // didn't go through and can retry once reachable instead of the app quietly
            // discarding it while showing a false success.
            rollback?()
            if reportsOutcome { reportOutcome(ok: false, reason: String(localized: "iPhone unreachable"), phoneUnreachable: true) }
            completion(false)
        }
    }

    /// WATCH-4: single choke point for the haptic + `lastCommandFailed` reaction every
    /// command gets, called from every exit of `sendCommand` above. `reason` is only
    /// used when `ok` is false.
    ///
    /// Polish pass (WA-6): `phoneUnreachable` failures (out of range, no reply, not yet connected)
    /// are expected on a wrist and not worth a modal alert per tap; they raise the transient
    /// inline notice instead and leave `lastCommandFailed` alone.
    private func reportOutcome(ok: Bool, reason: String?, phoneUnreachable: Bool = false) {
        playHaptic(success: ok)
        if !ok && phoneUnreachable {
            showPhoneUnreachableNotice()
            return
        }
        if ok { clearPhoneUnreachableNotice() }
        lastCommandFailed = ok ? nil : (reason ?? String(localized: "Command failed"))
    }

    private func showPhoneUnreachableNotice() {
        phoneUnreachableNotice = true
        phoneNoticeTask?.cancel()
        phoneNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.phoneNoticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.phoneUnreachableNotice = false
        }
    }

    private func clearPhoneUnreachableNotice() {
        phoneNoticeTask?.cancel()
        phoneUnreachableNotice = false
    }

    /// Turns `WatchCommandValidator.Failure`'s `String(describing:)` reply (e.g.
    /// `"scopeMismatch"`) into a short, human-readable reason for the toast/alert —
    /// the raw case name is diagnostic, not something to show a user mid-workout.
    private func failureMessage(for rawReason: String?) -> String {
        switch rawReason {
        case "scopeMismatch": return String(localized: "Signed into a different account on iPhone")
        case "itemMismatch": return String(localized: "iPhone is playing a different book now")
        case "staleState": return String(localized: "Syncing with iPhone — try again")
        case "noActiveItem": return String(localized: "Nothing playing on iPhone")
        default: return String(localized: "Command failed")
        }
    }

    // MARK: - Convenience command senders used by the views

    func togglePlayPause() {
        guard let state = playbackState else { return }
        let wasPlaying = state.isPlaying
        // WATCH-4: rebase `currentTime`/`lastUpdated` to "now" (at the estimator's own
        // current extrapolated value, not the stale server value) at the moment of the
        // optimistic toggle. Previously this toggled `isPlaying` but left `currentTime`/
        // `lastUpdated` untouched, and `WatchProgressEstimator` only extrapolates
        // position while `isPlaying` is true — so tapping play made the displayed
        // position immediately jump FORWARD by however many seconds had elapsed since
        // the last real snapshot (extrapolation switching on with a now-stale
        // `lastUpdated`), and tapping pause made it jump BACKWARD by the same amount
        // (extrapolation switching off, snapping back to the last-known `currentTime`).
        // Snapshotting the estimator's current value into both fields before flipping
        // `isPlaying` means the toggle itself never moves the displayed position.
        let rebasedTime = estimatedCurrentTime
        send(.playPause, itemId: state.itemId,
             optimisticApply: { [weak self] in
                 self?.playbackState?.currentTime = rebasedTime
                 self?.playbackState?.lastUpdated = Date()
                 self?.playbackState?.isPlaying.toggle()
                 // LS-1 (docs/design-review.md, Round 2): this optimistic toggle is the
                 // one place the Watch itself flips `isPlaying` before the phone
                 // confirms anything — if it's pausing (`wasPlaying`), also clear
                 // `isBuffering` locally so the ring doesn't linger over a now-paused
                 // button until the next real snapshot arrives. Not needed on the
                 // play path: buffering can only start once the phone actually tries
                 // to play, and only the phone's own snapshot ever sets it true.
                 if wasPlaying {
                     self?.playbackState?.isBuffering = false
                 }
             },
             rollback: { [weak self] in
                 self?.playbackState?.isPlaying = wasPlaying
                 // Position isn't rolled back on failure — the rebase itself was
                 // correct (it reflects a real position at a real time), only the
                 // play/pause flip is undone. Re-rebasing on failure would just move
                 // the display again by whatever's elapsed since, which is worse.
             })
    }

    // WATCH-5 (REVIEW_2026-08-12.md): defaults now read the phone's REAL configured
    // skip amounts (`WatchPlaybackState.skipBackwardInterval`/`skipForwardInterval`,
    // synced by `WatchSessionManager.buildPlaybackState()`) instead of a hardcoded 15 —
    // a user who set a different skip interval on iPhone previously had the Watch
    // silently skip the wrong amount (while also showing a stale "15 Seconds" label in
    // `WatchSettingsView`). Falls back to 15/30 (the phone's own defaults, see
    // `SettingsStore`) only if no snapshot has arrived yet.
    func rewind(_ seconds: Double? = nil) {
        guard let state = playbackState else { return }
        let interval = seconds ?? state.skipBackwardInterval
        applySkip(-interval, kind: .rewind(seconds: interval), itemId: state.itemId)
    }

    func forward(_ seconds: Double? = nil) {
        guard let state = playbackState else { return }
        let interval = seconds ?? state.skipForwardInterval
        applySkip(interval, kind: .forward(seconds: interval), itemId: state.itemId)
    }

    /// PL-11 (docs/design-review.md, Round 5): shared optimistic-rebase path for both
    /// skip directions, following `togglePlayPause()`'s pattern above — previously
    /// `rewind`/`forward` sent the command with no `optimisticApply` at all, so the
    /// displayed time only moved once the phone's reply (or next snapshot) arrived,
    /// which on a slow link could be a second or more of the button appearing to do
    /// nothing beyond the haptic.
    ///
    /// Unlike `togglePlayPause()`, the position itself IS the thing being optimistically
    /// changed here (not a side effect of rebasing to avoid a jump), so a failed skip
    /// DOES roll the position back — the opposite of `togglePlayPause()`'s "position
    /// isn't rolled back" note, which applies there only because that rebase is correct
    /// regardless of outcome.
    ///
    /// Rebases from `estimatedCurrentTime` (the estimator's extrapolated position at tap
    /// time) exactly like `togglePlayPause()`, so rapid repeated taps compound correctly:
    /// `send(...)` invokes `optimisticApply` synchronously before returning
    /// (`sendCommand` calls it as its first line), so by the time a second tap in the
    /// same gesture sequence reads `estimatedCurrentTime`, it already reflects the first
    /// tap's optimistic move — three quick +30s taps land at +90s, not +30s three times.
    ///
    /// Guards against a stale rollback: if tap 1 fails after tap 2 has already applied
    /// (and possibly already succeeded), tap 1's rollback closure captures the exact
    /// post-skip value IT set (`targetTime`) and only restores `rebasedTime` if
    /// `currentTime` still equals that value — i.e. nothing newer (tap 2's optimistic
    /// apply, or a real snapshot) has landed since. Without this, tap 1's rollback could
    /// yank a since-confirmed tap 2 position back to tap 1's pre-skip time. A real
    /// snapshot from the phone (`apply(context:)`) always wins over any of this — it
    /// replaces `playbackState` wholesale, so a rollback after a fresh snapshot has
    /// arrived would target a `targetTime` that no longer matches and correctly no-ops.
    private func applySkip(_ delta: Double, kind: WatchCommandKind, itemId: String) {
        guard let duration = playbackState?.duration else { return }
        let rebasedTime = estimatedCurrentTime
        let targetTime = WatchProgressEstimator.clamp(rebasedTime + delta, duration: duration)
        send(kind, itemId: itemId,
             optimisticApply: { [weak self] in
                 self?.playbackState?.currentTime = targetTime
                 self?.playbackState?.lastUpdated = Date()
             },
             rollback: { [weak self] in
                 guard self?.playbackState?.currentTime == targetTime else { return }
                 self?.playbackState?.currentTime = rebasedTime
                 self?.playbackState?.lastUpdated = Date()
             })
    }

    func seek(to time: Double) {
        guard let state = playbackState else { return }
        send(.seek(time: time), itemId: state.itemId)
    }

    func seekToChapter(_ chapter: WatchChapterSummary) {
        guard let state = playbackState else { return }
        send(.seekToChapter(chapterId: chapter.id, startTime: chapter.start), itemId: state.itemId)
    }

    func seekToBookmark(_ bookmark: WatchBookmarkSummary) {
        guard let state = playbackState else { return }
        send(.seekToBookmark(time: bookmark.time), itemId: state.itemId)
    }

    /// Critique 2026-10-06 (harden): `completion` reports the iPhone's real answer, so
    /// Now Playing's Bookmark button can say "Saved" only when it was.
    func addBookmarkAtCurrentPosition(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let state = playbackState else {
            completion(false)
            return
        }
        send(.addBookmark, itemId: state.itemId, completion: completion)
        // UI polish pass round 2 (29 August 2026): this fired with zero tactile
        // confirmation before — see this file's own WATCH-4 comment on `playHaptic`
        // just below, which fixed relay-command acknowledgments but never covered
        // direct user actions like this one.
        WatchHaptics.tap()
    }

    func cyclePlaybackSpeed() {
        guard let state = playbackState else { return }
        setPlaybackSpeed(WatchSpeedCycler.next(after: state.playbackRate))
    }

    /// Batch 410: any rate from the Watch's Speed sheet. The phone clamps and rounds it
    /// (`PlayerViewModel.setPlaybackRate`, via `WatchSessionManager`) and saves it per book.
    func setPlaybackSpeed(_ rate: Double) {
        guard let state = playbackState else { return }
        let previous = state.playbackRate
        send(.setPlaybackSpeed(rate: rate), itemId: state.itemId,
             optimisticApply: { [weak self] in self?.playbackState?.playbackRate = rate },
             rollback: { [weak self] in self?.playbackState?.playbackRate = previous })
    }

    func setSleepTimer(_ option: WatchSleepTimerOption) {
        guard let state = playbackState else { return }
        send(.setSleepTimer(option: option), itemId: state.itemId)
    }

    /// Requires explicit confirmation before calling (see `BookProgressView`) —
    /// irreversible-feeling action that also writes server progress.
    ///
    /// Additionally requires the phone to be immediately reachable right now, unlike
    /// every other command here. `send()` no longer attempts any kind of best-effort/
    /// queued delivery when unreachable (see the comment there) — every command already
    /// fails fast in that case — but this one is destructive enough, and final enough
    /// from the user's perspective (a confirmation dialog, "isFinished" written to the
    /// server), that it's worth failing before even constructing/optimistically applying
    /// the command, rather than relying on `send()`'s generic unreachable-path handling.
    /// `isReachable` is already surfaced to the user elsewhere (`WatchSettingsView`,
    /// `StandaloneDownloadsView`'s "On iPhone" footer) so "the phone isn't reachable" isn't a surprising
    /// reason for this specific action to have visibly done nothing.
    func markFinished() {
        guard let state = playbackState, isReachable else { return }
        send(.markFinished, itemId: state.itemId)
    }

    /// Batch 414: Book Details' Mark as Finished without a Watch session. Any book, not only
    /// the one playing (`.markItemFinished`); `completion` carries the phone's real outcome.
    /// Failures surface through `reportOutcome` like every other command.
    func markFinished(itemId: String, completion: @escaping (Bool) -> Void) {
        send(.markItemFinished(itemId: itemId), itemId: itemId, completion: completion)
    }

    func playItem(itemId: String) {
        send(.playItem(itemId: itemId), itemId: nil)
    }

    /// WATCH-4: called by the root view's `.alert` once the user dismisses it — see
    /// `lastCommandFailed`.
    func dismissCommandFailure() {
        lastCommandFailed = nil
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        // CRIT-3 follow-up: read the plain `Bool` out of `session` here, synchronously,
        // rather than capturing `session` itself into the `Task` below — `WCSession`
        // isn't `Sendable` in this SDK (see the `@preconcurrency import` above), so
        // capturing it directly into a `@Sendable` closure was flagged regardless.
        let reachable = session.isReachable
        Task { @MainActor in
            self.isActivated = activationState == .activated
            self.isReachable = reachable
            if self.isActivated { self.requestFreshSnapshotOnForeground() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    // CRIT-3 follow-up: `applicationContext`/`message`/`userInfo` below are all
    // `[String: Any]` — genuinely not `Sendable` (`Any` can hold anything, including
    // non-Sendable types), unlike the `WCSession` capture above, so `@preconcurrency`
    // doesn't touch this one. `apply(context:)`'s own body only ever reads `context[key]
    // as? Data` (see its doc comment: "the dictionary shape (keyed `Data` blobs) is
    // identical either way"), so narrowing to `[String: Data]` — filtered here,
    // synchronously, before the `Task` — captures only genuinely `Sendable` values
    // instead of the raw `Any`-valued dictionary.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let dataOnly = applicationContext.compactMapValues { $0 as? Data }
        Task { @MainActor in self.apply(context: dataOnly) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let dataOnly = message.compactMapValues { $0 as? Data }
        Task { @MainActor in self.apply(context: dataOnly) }
    }

    /// WATCH-3 (REVIEW_2026-08-12.md): required now that the phone side
    /// (`WatchSessionManager`) moved downloads/recentlyAdded/collections/chapters/
    /// bookmarks off the merged `updateApplicationContext` dictionary and onto
    /// `session.transferUserInfo(_:)` instead (to stop them sharing
    /// `updateApplicationContext`'s ~256KB ceiling with `playbackState`). Without this
    /// delegate method, none of `transferUserInfo`'s payloads would ever be received at
    /// all — `didReceiveApplicationContext`/`didReceiveMessage` don't fire for it. Reuses
    /// the same `apply(context:)` parser since the dictionary shape (keyed `Data` blobs)
    /// is identical either way.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let dataOnly = userInfo.compactMapValues { $0 as? Data }
        Task { @MainActor in self.apply(context: dataOnly) }
    }

    private func apply(context: [String: Data]) {
        if let data = context["playbackState"],
           let decoded = try? JSONDecoder().decode(WatchPlaybackState.self, from: data) {
            // Cross-account/cross-book guard: if the incoming scope OR item differs from
            // whatever we were last showing, drop book-specific caches (chapters/
            // bookmarks) rather than let them appear to belong to the new book/account.
            // Previously this only checked `scope`, so switching books within the same
            // account (the common case — no account switch involved) left stale
            // chapters/bookmarks on screen until some unrelated command happened to
            // refresh them (see the matching `push(_:)` fix on the phone side, which
            // now proactively re-sends auxiliary state on an item change instead of
            // relying on that).
            if let previous = self.playbackState,
               previous.scope != decoded.scope || previous.itemId != decoded.itemId {
                self.chapters = []
                self.bookmarks = []
            }
            self.playbackState = decoded
            updateNowPlayingInfo()
        }
        if let data = context["downloads"],
           let decoded = try? JSONDecoder().decode([WatchDownloadSummary].self, from: data) {
            self.downloads = decoded
        }
        if let data = context["recentlyAdded"],
           let decoded = try? JSONDecoder().decode([WatchBookSummary].self, from: data) {
            self.recentlyAdded = decoded
        }
        if let data = context["collections"],
           let decoded = try? JSONDecoder().decode([WatchCollectionSummary].self, from: data) {
            self.collections = decoded
        }
        if let data = context["chapters"],
           let decoded = try? JSONDecoder().decode([WatchChapterSummary].self, from: data) {
            self.chapters = decoded
        }
        if let data = context["bookmarks"],
           let decoded = try? JSONDecoder().decode([WatchBookmarkSummary].self, from: data) {
            self.bookmarks = decoded
        }
        // Stage 2 (standalone Watch app, addendum §3): the one new key this method
        // recognizes that isn't book/library state — `WatchSessionManager.
        // clearWatchState()` sends this via `transferUserInfo` (not `sendMessage`;
        // see that method's own doc comment for why a wipe *instruction* wants
        // guaranteed delivery even though the credential *payload* itself
        // deliberately does not) whenever the phone signs out or switches accounts.
        // The value itself (an encoded `Date`) isn't read — only its presence
        // matters, as the trigger to clear whatever this Watch has cached locally.
        // This is the one place this file's own "doesn't know about credentials"
        // framing (see the type's doc comment above) stops being quite true — see
        // that comment's own note on the change.
        // Batch 399 follow-up: timed chapter skip settings from the phone, persisted so
        // standalone playback (`StandaloneAudioEngine`) still has them with the phone gone.
        if let data = context["chapterSkipSettings"],
           let decoded = try? JSONDecoder().decode(WatchChapterSkipSettings.self, from: data) {
            decoded.save()
        }

        if context["wipeCredentials"] != nil {
            Task { await WatchStore.shared.wipeCredentials() }
        }
    }
}
