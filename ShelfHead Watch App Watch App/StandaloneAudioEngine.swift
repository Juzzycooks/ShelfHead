import Foundation
import AVFoundation
import MediaPlayer

// MARK: - Standalone playback engine (Stage 3 proof-of-concept)

/// The Watch's own audio engine — no phone, no `WatchConnectivityStore` relay. See
/// `WATCH_STANDALONE_PROPOSAL_2026-08-28-ADDENDUM.md` §10 for the design this
/// implements and why.
///
/// **Originally, deliberately did not sync or close its playback session (§10.1).**
/// `ProgressReconciler.reconcile` (main app, `ShelfHead/Services/ProgressReconciler.swift`)
/// flags a conflict on raw position divergence alone, before it ever checks which side's
/// `lastUpdate` is actually newer — so any standalone session run long enough to prove
/// out background audio (which the whole point of this stage is to do) would trip a
/// misleading "conflict" prompt on the phone the next time it's opened, framed as a
/// two-sided dispute when the Watch's progress is actually just newer. Position did not
/// survive a relaunch of this app — a real, named limitation of this stage, not a
/// silent one.
///
/// **Superseding note (Stage 6, 28 August 2026):** the above was this stage's own
/// stated follow-up, not a permanent decision — `startPlaybackSession` is still called
/// (needed for a valid, licensed stream URL), and now `syncSession`/`closeSession` are
/// too, roughly every 30s of listening and on `stop()` (see `checkInProgress()`), via
/// `WatchProgressSyncCoordinator` (`WatchProgressSync.swift`), which owns its own
/// conflict heuristic specifically so this Watch's writes don't compound
/// `ProgressReconciler.reconcile`'s pre-existing gap. That gap itself is unchanged and
/// unfixed — it's a phone-side issue, out of this stage's scope. The
/// permanently-open-session risk described above is otherwise unchanged: it's the same
/// shape as what already happens today whenever the phone's own app is force-quit or
/// killed mid-playback (`AudioPlayerService.closeSession()`,
/// `ShelfHead/Services/AudioPlayerService.swift:1244`, is only ever called from
/// `stop()`, with no termination/background hook anywhere in that file).
///
/// **Superseding note (9 September 2026 review, CRITICAL + HIGH):** the "position
/// did not survive a relaunch of this app" limitation stated above was worse than
/// stated — playback started at 0:00 *every* time, saved position or not, and the
/// periodic tick then pushed ~30s over the top of the listener's real position.
/// `play(...)` now resolves a resume position from the server's own session
/// `currentTime` and this device's last recorded position (`resumePosition(...)`,
/// pure and unit-tested) and seeks to it before any audio plays, with every
/// progress write suppressed until that seek actually lands
/// (`hasReachedResumePosition`). Switching books also records and closes the
/// outgoing book's session first (`captureOutgoingProgress()` +
/// `writeOutProgress(...)`) instead of tearing it down silently.
///
/// **Audio session: `.longFormAudio` policy, not the phone's category+options model.**
/// The phone (`AudioPlayerService.swift:139–169`) uses plain `.playback`/`.spokenAudio`
/// with `[.allowBluetoothA2DP, .allowAirPlay]` options. watchOS has its own, different
/// sanctioned mechanism for a long-running background-audio app: `AVAudioSession`'s
/// `policy: .longFormAudio` parameter on `setCategory`, activated via
/// `activate(options:completionHandler:)` rather than `setActive(_:options:)`. Per
/// multiple developer reports (no single authoritative Apple page found stating this as
/// plainly as the class docs state the policy's existence), a `.longFormAudio` session
/// is incompatible with non-empty `options` — so this does not attempt
/// `.allowBluetoothA2DP`/`.allowAirPlay` at all; Bluetooth headphone routing is left to
/// whatever default route watchOS already applies for a `.playback`-category app.
/// `[device check]`: this whole mechanism is new to this project and unverified on real
/// hardware.
///
/// **AirPlay:** genuinely unconfirmed whether it's reachable from a third-party watchOS
/// app's audio session at all — per the addendum, not built around either answer.
/// `[device check]`.
///
/// **No-headphones state is explicit, not a silent speaker fallback.** Critique
/// 2026-10-06 (harden): the route is read only *after* the session is activated. The
/// old gate read `currentRoute.outputs` before activation and refused to play without an
/// external route, but per Apple's `activate(options:completionHandler:)` page it's the
/// long-form activation itself that "selects a reachable route automatically" (AirPods
/// attached to the iPhone included), routes to the built-in speaker where supported, or
/// "presents the route picker" — so the old check could see no headphones that the
/// system was about to connect. Now: activate, let the system route or show its picker,
/// then decide (`StandaloneRouteDecision`). Only a session that ended on the Watch
/// speaker asks first (`routeIssue == .speakerOnly`); a dismissed picker says so
/// (`.noOutputChosen`); a mid-book disconnect pauses, as the phone does
/// (`AudioPlayerService`'s `.oldDeviceUnavailable` handling), and says so
/// (`.headphonesDisconnected`).
@MainActor
@Observable
final class StandaloneAudioEngine {
    enum PlaybackError: Error, LocalizedError {
        case activationFailed
        case noPlayableTrack
        case streamFailed

        var errorDescription: String? {
            switch self {
            case .activationFailed: return String(localized: "Couldn\u{2019}t start audio on this Watch. Try again.")
            case .noPlayableTrack: return String(localized: "This title has no playable audio track.")
            case .streamFailed: return String(localized: "Streaming stopped. Check your connection and try again.")
            }
        }
    }

    private let api: WatchAudiobookshelfAPI
    /// Stage 6: where this engine hands off progress for actual server writes — see
    /// that type's own doc comment for the push/queue/conflict logic. Passed in
    /// (`WatchStore`'s own init, not a reach-back through `WatchStore.shared`) so
    /// this engine stays a plain, independently-constructible type with an explicit
    /// dependency list, matching how `api` itself is already injected rather than
    /// read from a singleton inline.
    private let progressSync: WatchProgressSyncCoordinator
    private var player: AVQueuePlayer?
    private var tracks: [WatchAudioTrack] = []
    private var timeObserverToken: Any?
    private var routeChangeObserver: NSObjectProtocol?
    /// Polish pass Phase 2a #7 (WA-1): audio-session interruptions (a call, Siri, an alarm).
    private var interruptionObserver: NSObjectProtocol?
    /// Whether an interruption caught the book playing; only then may its end resume it.
    /// A listener's own play or pause clears it, as on the phone.
    private var resumeAfterInterruption = false
    private var endOfQueueObserver: NSObjectProtocol?
    private var itemFailureObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    /// 30 Oct 2026 review (High 8): when the last streamed-item recovery was attempted, and
    /// whether one is still in flight. See `streamFailureAction(...)`.
    private var lastStreamRecoveryAt: Date?
    private var isRecoveringStream = false
    private var currentItemObservation: NSKeyValueObservation?

    /// Set once per `play(...)` call, never mutated afterward — used to compute
    /// absolute position (`track.startOffset + player.currentTime()`) across track
    /// boundaries without re-deriving it from `player.items()` each tick.
    private var trackStartOffsets: [String: Double] = [:]

    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Stage 4: needed so the root screen's "Continue Listening" card
    /// (now the Shelf's current sleeve, `WatchShelfView`) can
    /// navigate back into `StandaloneNowPlayingView` for whatever's currently
    /// loaded — not read anywhere in Stage 3, where the only way to reach this
    /// screen at all was already carrying the item id in hand from the tapped row.
    private(set) var currentItemId: String?
    /// PL-4: the loaded book's chapters, from the playback session. Empty for a downloaded book
    /// played offline (that path makes no session call) and for books without chapter data.
    private(set) var chapters: [WatchChapter] = []
    /// PL-4: the running sleep timer, if any. See `StandaloneSleepTimer`.
    private(set) var sleepTimer: StandaloneSleepTimer?
    private(set) var itemTitle: String = ""
    private(set) var itemAuthor: String = ""
    private(set) var errorMessage: String?
    /// Critique 2026-10-06 (harden): true during the short (≤ `freshProgressTimeout`)
    /// server check before a download plays, so Now Playing can say "Checking your
    /// place…" instead of showing a bare spinner.
    private(set) var isCheckingPlace = false

    /// Critique 2026-10-06 (harden): what Now Playing should say about the audio route,
    /// set only from what activation actually produced (see the type doc comment and
    /// `StandaloneRouteDecision`). Cleared when playback starts or headphones connect.
    private(set) var routeIssue: StandaloneRouteIssue?
    /// The listener chose "Play on Speaker" for the loaded book, so a later resume on the
    /// speaker doesn't ask again. Reset when headphones connect or another book loads.
    private var speakerAccepted = false

    /// Critique 2026-10-06 (adapt): standalone had no speed control at all, so a run
    /// without the phone was stuck at 1×. The rate the player uses whenever it plays
    /// (`AVPlayer.defaultRate`, watchOS 9.0+: "A default rate at which to begin
    /// playback"; `play()` starts at it). Remembered across launches.
    private(set) var playbackRate: Double = UserDefaults.standard.object(forKey: StandaloneAudioEngine.playbackRateDefaultsKey) as? Double ?? 1.0
    nonisolated static let playbackRateDefaultsKey = "standalone.playbackRate"

    /// Stage 6: the open session's id for a streamed item, `nil` for a Stage 5 local
    /// download (which never calls `startPlaybackSession` at all — see `play(...)`'s
    /// own doc comment). Drives which progress-writing path the periodic tick and
    /// `stop()` use below: `syncSession`/`closeSession` when set, the durable
    /// `WatchPendingProgressQueue`-only path when not.
    private var currentSessionId: String?
    /// Wall-clock seconds actually listened since the last successful `syncSession`
    /// (or since playback started, if none has succeeded yet) — mirrors
    /// `AudioPlayerService.timeListenedSinceSync` exactly, including the
    /// roll-back-in on failure behavior (see the periodic tick below). No
    /// `/ playbackRate` division here unlike the phone's version: this engine has no
    /// speed control at all (a named limitation already recorded for Stage 3), so
    /// book time and wall time are always identical.
    private var timeListenedSinceSync: Double = 0
    /// Counts periodic ticks (the observer below fires every 1s) so a sync/queue
    /// attempt happens roughly every 30s, not every tick — matches the phone's own
    /// sync cadence rather than inventing a different one for no reason.
    private var ticksSinceLastSync: Int = 0

    /// Gates the periodic tick — both its `currentTime` update and every progress
    /// write it drives — until the resume seek for the freshly-loaded item has
    /// actually landed. Mirrors `AudioPlayerService.hasReachedResumePosition`
    /// (`ShelfHead/Services/AudioPlayerService.swift:52`, gate sites `:824`,
    /// `:1173`, `:1328`) and exists for exactly the reason the 9 September 2026
    /// review found here: before the seek completes the player's own item time is
    /// 0, so letting a tick through flashes 0:00 on screen and — 30 ticks later —
    /// pushes ~30s through `syncSession` on top of the listener's real position.
    /// `true` while nothing is loaded, so an idle engine behaves as before.
    private var hasReachedResumePosition = true
    /// The position the pending resume seek should actually use, read at fire time
    /// rather than captured when the item was loaded, so a crown scrub or a skip
    /// made while the item is still becoming ready isn't dragged back to the saved
    /// position when the seek finally runs. (The phone has that second defect
    /// still open — see the 9 September 2026 review's "A pending resume seek
    /// clobbers a user seek made while the item is still loading" — it is not
    /// repeated here.)
    private var pendingResumeTarget: Double?
    /// Whether the resume seek's completion should start playback. Cleared by any
    /// pause that happens while the seek is still pending (`togglePlayPause()`,
    /// the route-disconnect handler, `stop()`), so a user who pauses during the
    /// load isn't overridden by the seek landing a moment later.
    private var startPlaybackAfterResumeSeek = false
    /// Watches the item the resume seek will land in for `.readyToPlay`; seeking
    /// before that is unreliable (see `applyResumeSeek(on:)`).
    private var resumeSeekObservation: NSKeyValueObservation?

    /// 15/30, matching `SkipLabels`' own fallback default when no synced interval
    /// exists (companion mode's `state.skipBackwardInterval`/`skipForwardInterval`
    /// has no standalone equivalent yet — using the Watch's own synced skip-interval
    /// setting is future scope, not this stage's).
    /// `nonisolated static` since 9 September 2026: `WatchRemoteCommandRouter` needs
    /// these to set `skipForwardCommand.preferredIntervals` now that it — not this
    /// engine — owns the remote-command registration, and they were never per-instance
    /// state to begin with.
    nonisolated static let skipBackwardSeconds: Double = 15
    nonisolated static let skipForwardSeconds: Double = 30

    init(api: WatchAudiobookshelfAPI, progressSync: WatchProgressSyncCoordinator) {
        self.api = api
        self.progressSync = progressSync
        // `configureRemoteCommands()` used to run here. It has moved to
        // `WatchRemoteCommandRouter`, which registers the process's only set of
        // `MPRemoteCommandCenter` targets and dispatches to whichever mode
        // `WatchStore.mode` says is active — see that type's own doc comment for the
        // ownership rule and the double-acting-command bug it fixes.
    }

    // MARK: - Route check

    private static func hasExternalAudioRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            switch output.portType {
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .airPlay:
                return true
            default:
                return false
            }
        }
    }

    /// Activates the session (see `activateAudioSession()`), then decides from the route
    /// the system actually chose. Returns whether playback may start; otherwise
    /// `routeIssue` says why. A thrown activation error lands in `errorMessage`.
    private func activateAndCheckRoute(acknowledgingSpeakerRoute: Bool) async -> Bool {
        if acknowledgingSpeakerRoute { speakerAccepted = true }
        let activated: Bool
        do {
            try configureAudioSession()
            activated = try await activateAudioSession()
        } catch {
            errorMessage = PlaybackError.activationFailed.localizedDescription
            return false
        }
        switch StandaloneRouteDecision.afterActivation(activated: activated,
                                                       hasExternalOutput: Self.hasExternalAudioRoute(),
                                                       speakerAccepted: speakerAccepted) {
        case .play:
            routeIssue = nil
            return true
        case .askAboutSpeaker:
            routeIssue = .speakerOnly
            return false
        case .noRoute:
            routeIssue = .noOutputChosen
            return false
        }
    }

    // MARK: - Resume position

    /// Picks the position a freshly-loaded item should resume from, given the
    /// server's own idea of it and this device's last locally-recorded one.
    ///
    /// Pure and `nonisolated static` on purpose: it is the whole decision behind the
    /// 9 September 2026 review's CRITICAL finding, and this project's own testing
    /// convention is to extract exactly this kind of pure decision function and pin
    /// it (see `CLAUDE.md`'s Testing section and `DownloadManager
    /// .shouldReclaimOrphanDirectory`'s precedent) rather than trying to test the
    /// stateful player path around it. Pinned by
    /// `ShelfHead Watch App Watch AppTests/ShelfHead_Watch_App_Watch_AppTests.swift`.
    ///
    /// Semantics:
    /// - both sides known and both clocks known and different → **newer wins**;
    /// - both sides known but the clocks can't be compared (either is `nil`, or
    ///   they're identical) → **the further-ahead position wins**. That's the
    ///   conservative choice, not a coin-flip: resuming *behind* a real position is
    ///   what destroys it, because the periodic tick then pushes the earlier
    ///   position back to the server;
    /// - only one side known → that one;
    /// - neither → `0`.
    ///
    /// The result is clamped into `[0, duration)`: a candidate at or past the end
    /// (a finished book, whose server `currentTime` is typically exactly `duration`)
    /// resumes from the start rather than from a dead end at the last frame.
    /// `duration <= 0` (unknown) skips the clamp rather than throwing the position
    /// away.
    nonisolated static func resumePosition(
        serverTime: Double?, serverLastUpdateMs: Double?,
        localTime: Double?, localLastUpdateMs: Double?,
        duration: Double
    ) -> Double {
        let candidate: Double?
        switch (serverTime, localTime) {
        case (let server?, let local?):
            if let serverMs = serverLastUpdateMs, let localMs = localLastUpdateMs, serverMs != localMs {
                candidate = serverMs > localMs ? server : local
            } else {
                candidate = max(server, local)
            }
        case (let server?, nil):
            candidate = server
        case (nil, let local?):
            candidate = local
        default:
            candidate = nil
        }
        // `> 0` also filters NaN, which `min`/`max` would otherwise propagate into
        // a `CMTime` and turn into an invalid seek.
        guard let candidate, candidate > 0 else { return 0 }
        guard duration > 0 else { return candidate }
        return candidate >= duration ? 0 : candidate
    }

    // MARK: - Seek planning

    /// What `seekInQueue(to:)` needs to do to land a seek at an absolute target time.
    ///
    /// `AVQueuePlayer.advanceToNextItem()` *removes* the item it leaves (see
    /// `advanceQueue(toTrackContaining:)`'s own doc comment), so once playback has
    /// moved past a track there is no way to move the existing queue backward into
    /// it — the queue has to be rebuilt from that track onward instead. Item 20 (9
    /// September 2026 review): a backward cross-track seek (crown scrub or skip-back
    /// across a file boundary on a one-file-per-chapter book) used to fall through to
    /// a plain within-item seek, which clamps to the start of whatever track the
    /// queue was still sitting on rather than reaching the earlier track at all.
    nonisolated enum SeekPlan: Equatable {
        /// The target is in the track already playing — seek within the current item.
        case withinTrack(offset: Double)
        /// The target is in a later track still present in the queue —
        /// `advanceQueue(toTrackContaining:)` can reach it, then seek within it.
        case forwardToTrack(index: Int, offset: Double)
        /// The target is in an earlier track `AVQueuePlayer` has already dropped —
        /// the queue must be rebuilt starting at `index`.
        case rebuildFromTrack(index: Int, offset: Double)
    }

    /// Pure and `nonisolated static` per this project's testing convention (see
    /// `resumePosition(...)`'s own doc comment) — pinned by
    /// `ShelfHead Watch App Watch AppTests/StandaloneAudioEngineSeekPlanTests.swift`.
    ///
    /// `trackStarts` is each track's absolute start offset, in track order (i.e.
    /// `tracks.map { trackStartOffsets[$0.id] ?? 0 }`), assumed sorted ascending and
    /// non-empty for a loaded item; `currentTrackIndex` is where playback currently
    /// sits in that same list. `targetAbsolute` is assumed already clamped to
    /// `[0, duration]` by the caller (`seekInQueue(to:)` does this).
    nonisolated static func seekPlan(targetAbsolute: Double, currentTrackIndex: Int, trackStarts: [Double]) -> SeekPlan {
        guard !trackStarts.isEmpty else { return .withinTrack(offset: max(0, targetAbsolute)) }
        // The last track whose start offset is at or before the target — exact
        // boundary hits land in the track that starts there, not the one before it.
        var targetIndex = 0
        for (index, start) in trackStarts.enumerated() where start <= targetAbsolute {
            targetIndex = index
        }
        let offset = max(0, targetAbsolute - trackStarts[targetIndex])
        if targetIndex == currentTrackIndex {
            return .withinTrack(offset: offset)
        } else if targetIndex > currentTrackIndex {
            return .forwardToTrack(index: targetIndex, offset: offset)
        } else {
            return .rebuildFromTrack(index: targetIndex, offset: offset)
        }
    }

    /// Runs the pending resume seek once the item it will land in is actually
    /// ready, then — if a pause hasn't intervened — starts playback.
    ///
    /// The wait for `.readyToPlay` is the point: a `seek` issued against an item
    /// that isn't ready yet can simply be dropped, which is precisely how this
    /// engine ended up playing from 0:00 with the saved position overwritten 30s
    /// later. Same ordering, and same reasoning, as
    /// `AudioPlayerService.loadAndPlayTrack`'s `startWhenReady`
    /// (`ShelfHead/Services/AudioPlayerService.swift:306–338`).
    ///
    /// `additionalCompletion` (Item 20, 9 September 2026 review) lets a backward
    /// cross-track seek's own queue rebuild (`rebuildQueue(...)`) reuse this exact
    /// machinery — the `hasReachedResumePosition` gate it drives is what keeps a
    /// stray progress write from firing at a stale position while the rebuild is
    /// still in flight, and `startPlaybackAfterResumeSeek` is what lets a pause
    /// issued mid-rebuild win over resuming playback once the new queue is ready.
    private func applyResumeSeek(on player: AVQueuePlayer, additionalCompletion: (@MainActor @Sendable () -> Void)? = nil) {
        // Move the queue to the item that actually contains the target *before*
        // observing readiness, so the observation watches the item the seek will
        // land in rather than the first track.
        advanceQueue(toTrackContaining: pendingResumeTarget ?? currentTime)
        guard let item = player.currentItem else {
            // Nothing to seek in — don't leave the tick suppressed forever.
            hasReachedResumePosition = true
            if startPlaybackAfterResumeSeek {
                startPlaybackAfterResumeSeek = false
                player.play()
                isPlaying = true
            }
            additionalCompletion?()
            return
        }

        // Typed `@MainActor @Sendable` for the same reason the phone's
        // `startWhenReady` is: `@MainActor` so it can touch this isolated
        // instance's state directly, `@Sendable` so it can be captured into the KVO
        // closure below, which the checker doesn't treat as main-actor-isolated.
        let seekWhenReady: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.resumeSeekObservation?.invalidate()
            self.resumeSeekObservation = nil
            // Read the target now, not when this closure was formed — a scrub made
            // during the load has retargeted it (see `pendingResumeTarget`).
            let target = self.pendingResumeTarget ?? self.currentTime
            self.pendingResumeTarget = nil
            self.seekInQueue(to: target) { [weak self] in
                guard let self else { return }
                self.hasReachedResumePosition = true
                if self.startPlaybackAfterResumeSeek {
                    self.startPlaybackAfterResumeSeek = false
                    self.player?.play()
                    self.isPlaying = true
                }
                self.updateNowPlayingInfo()
                additionalCompletion?()
            }
        }

        if item.status == .readyToPlay {
            seekWhenReady()
            return
        }
        resumeSeekObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            // KVO isn't guaranteed on the main thread. Two extractions before the
            // hop, both this file's own established patterns: resolve `self` to a
            // strong local rather than reading the captured weak var from inside
            // the nested closure, and pull the `Sendable` values (a status, a
            // message) out of the non-`Sendable` `AVPlayerItem` rather than
            // capturing the item itself — same reason the route-change handler
            // extracts `reasonValue` instead of capturing its `Notification`.
            let status = observed.status
            let failureMessage = observed.error?.localizedDescription
            guard let self else { return }
            Task { @MainActor in
                switch status {
                case .readyToPlay:
                    seekWhenReady()
                case .failed:
                    self.resumeSeekObservation?.invalidate()
                    self.resumeSeekObservation = nil
                    // Surface it rather than sitting silently paused at the resume
                    // point forever, and let the tick run again so whatever does
                    // play is at least recorded.
                    self.hasReachedResumePosition = true
                    self.startPlaybackAfterResumeSeek = false
                    self.errorMessage = failureMessage ?? PlaybackError.noPlayableTrack.localizedDescription
                    additionalCompletion?()
                default:
                    break
                }
            }
        }
    }

    // MARK: - Playback

    /// Starts playback of `itemId`. The audio session is activated first so the system
    /// can pick headphones or show its route picker; if it ends on the Watch speaker,
    /// nothing plays and `routeIssue` asks. `acknowledgingSpeakerRoute: true` is the
    /// listener's "Play on Speaker" answer.
    func play(itemId: String, title: String, author: String, acknowledgingSpeakerRoute: Bool = false) async {
        errorMessage = nil
        lastStreamRecoveryAt = nil
        // A different book starts with no speaker answer of its own.
        if itemId != currentItemId { speakerAccepted = false }
        // Critique 2026-10-06 (harden): activate first, then look at the route — see
        // the type doc comment. Before any outgoing book is touched, so a refusal here
        // leaves whatever was loaded exactly as it was.
        guard await activateAndCheckRoute(acknowledgingSpeakerRoute: acknowledgingSpeakerRoute) else { return }

        // Fix (HIGH, 9 September 2026 review — "Switching books mid-playback loses
        // the outgoing book's progress and leaks its server session"): this used to
        // fall straight through to `tearDownPlayer()` below, which drops the
        // outgoing item's un-synced window (up to 30s of listening), never records
        // its final position and never closes its server session.
        // `StandaloneNowPlayingView`'s own `.task` comment explicitly relied on that
        // teardown as "no need to stop first", which is why the view is left
        // unchanged and the ownership sits here instead. The outgoing item is now
        // written out and closed *first*, and awaited, so the old book's position is
        // on the server before the new book's session opens.
        let displacedLoadedItem = isLoaded || currentSessionId != nil
        if displacedLoadedItem {
            let outgoing = captureOutgoingProgress()
            // Silence the old item and suppress its ticks before awaiting the
            // write-out: its session is about to be closed, so nothing should sync
            // against it any more.
            player?.pause()
            isPlaying = false
            startPlaybackAfterResumeSeek = false
            hasReachedResumePosition = false
            currentSessionId = nil
            await writeOutProgress(outgoing)
        }

        do {
            let sortedTracks: [WatchAudioTrack]
            let sessionDuration: Double?
            // Fix (CRITICAL, 9 September 2026 review — "Standalone playback always
            // starts at 0:00, then overwrites the server's real position"): the
            // session response's `currentTime` used to be decoded and thrown away.
            // It's the server's own resume point for this item; it's one of the two
            // candidates `resumePosition(...)` picks between below. (Was always `nil`
            // on the local-download path; since Critique 2026-10-06 that path fills it
            // from the manifest, the iPhone's snapshot and a short online check.)
            var serverTime: Double?
            var serverLastUpdateMs: Double?
            var sessionChapters: [WatchChapter] = []

            // Stage 5: a downloaded item plays entirely from local files, with no
            // `startPlaybackSession` network call at all — the whole point of a
            // download is that it works with no connectivity, and per-play network
            // hits would defeat that even when a connection happens to be present.
            // `WatchAudioTrack.contentUrl` is overloaded to carry a `local:<filename>`
            // marker instead of a server path; `playerItem(for:itemId:)` and
            // `playerItem(matches:item:)` both branch on that prefix rather than this
            // needing a second, parallel track/model type end-to-end.
            if let localTracks = WatchLocalDownloadManager.shared.localTrackURLs(itemId: itemId) {
                sortedTracks = localTracks.map { entry in
                    WatchAudioTrack(index: entry.index, startOffset: entry.startOffset, duration: entry.duration, title: nil, contentUrl: "local:\(entry.url.lastPathComponent)", mimeType: nil)
                }
                sessionDuration = nil
                sessionChapters = WatchLocalDownloadManager.shared.localChapters(itemId: itemId)
                // Stage 6: no session for a local download — see this property's own
                // doc comment on which progress-writing path that selects.
                currentSessionId = nil
                // Critique 2026-10-06 (harden): a download used to have no server
                // reading at all, so a book the iPhone had taken to 40% started at 0:00
                // (or a stale Watch position) and the conflict prompt followed the run.
                // Three server-side readings now, newest wins: a fresh check when the
                // server answers within ~3 s, the iPhone's snapshot when it's about this
                // book, and the one saved in the manifest at download time. Offline,
                // the manifest's still counts.
                isCheckingPlace = true
                let fresh = await freshServerProgress(itemId: itemId)
                isCheckingPlace = false
                if let fresh { WatchLocalDownloadManager.shared.recordServerProgress(itemId: itemId, fresh) }
                // Polish pass (WA-3): the cached shelf's reading is an offline floor only
                // (display/resume), offered when the server didn't answer. It competes by
                // the same clock rules and is never queued or pushed.
                let cachedFloor = WatchInProgressCache.resumeCandidate(
                    fresh: fresh,
                    cached: WatchInProgressCache.cachedReading(itemId: itemId, serverURL: api.serverURL))
                let best = WatchServerProgressPicker.newest([
                    fresh, companionProgress(itemId: itemId),
                    WatchLocalDownloadManager.shared.serverProgress(itemId: itemId), cachedFloor])
                serverTime = best?.currentTime
                serverLastUpdateMs = best?.lastUpdateMs
            } else {
                // Funnelled through `WatchStandaloneCall` (9 September 2026, review
                // MEDIUM): a `.sessionExpired` here used to land in the `catch` below
                // as a plain `errorMessage`, leaving `authState` at `.active` — so
                // the app kept claiming to be signed in and offered a Play button
                // that could never work. See that type's own doc comment.
                let session = try await WatchStandaloneCall.perform {
                    try await api.startPlaybackSession(itemId: itemId)
                }
                sortedTracks = (session.audioTracks ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
                guard !sortedTracks.isEmpty else { throw PlaybackError.noPlayableTrack }
                sessionDuration = session.duration
                sessionChapters = (session.chapters ?? []).sorted { $0.start < $1.start }
                currentSessionId = session.id
                serverTime = session.currentTime
                // `POST /api/items/<id>/play` echoes the library item back with the
                // user's own progress attached (`WatchPlaybackSession.libraryItem`
                // → `userMediaProgress`), which is the only timestamp available
                // without a second request. Servers that don't include it leave
                // this `nil`, which `resumePosition(...)` treats as "can't compare
                // clocks" rather than as "not newer".
                serverLastUpdateMs = session.libraryItem?.mediaProgress?.lastUpdate.map(Double.init)
                // Critique 2026-10-06 (harden): the iPhone may be ahead of the server it
                // hasn't synced to yet; its snapshot competes on the same clock rules.
                if let phone = companionProgress(itemId: itemId),
                   let best = WatchServerProgressPicker.newest([
                       serverTime.map { WatchServerProgress(currentTime: $0, lastUpdateMs: serverLastUpdateMs) }, phone]) {
                    serverTime = best.currentTime
                    serverLastUpdateMs = best.lastUpdateMs
                }
            }
            timeListenedSinceSync = 0
            ticksSinceLastSync = 0

            // This device's own last known position for the item — the newer of
            // what's still queued in `WatchPendingProgressQueue` and what this
            // device last successfully pushed (see that method's doc comment). It's
            // the only resume candidate that exists for a local download played
            // offline, where there's no session and so no `serverTime`. Fetched
            // here, before the player exists, so no `await` sits between building
            // the queue and starting it.
            let local = await progressSync.lastKnownLocalProgress(itemId: itemId)
            // (The session was configured and activated at the top, before the route
            // check — Critique 2026-10-06.)

            tearDownPlayer()
            tracks = sortedTracks
            trackStartOffsets = [:]
            var offset: Double = 0
            var items: [AVPlayerItem] = []
            for track in sortedTracks {
                trackStartOffsets[track.id] = offset
                if let item = playerItem(for: track, itemId: itemId) {
                    items.append(item)
                }
                offset += track.duration ?? 0
            }

            let queuePlayer = AVQueuePlayer(items: items)
            player = queuePlayer
            duration = sessionDuration ?? offset
            chapters = sessionChapters
            sleepTimer = nil   // PL-4: a timer belongs to the book it was set on
            currentItemId = itemId
            chapterSkipLastTickTime = nil
            itemTitle = title
            itemAuthor = author
            isLoaded = true

            // Resume position, decided before a single frame of audio plays — see
            // `resumePosition(...)` for how the two candidates are compared.
            let resumeTarget = Self.resumePosition(
                serverTime: serverTime, serverLastUpdateMs: serverLastUpdateMs,
                localTime: local?.currentTime, localLastUpdateMs: local?.updatedAt,
                duration: duration)
            // Show the resume point immediately (the tick is suppressed until the
            // seek lands, so nothing else will set it), same as the phone does at
            // `AudioPlayerService.swift:280`.
            currentTime = resumeTarget
            pendingResumeTarget = resumeTarget
            hasReachedResumePosition = (resumeTarget <= 0)
            // Critique 2026-10-06 (harden): when the server's reading won, it becomes
            // this Watch's baseline, so the run's own progress pushes without a
            // conflict prompt (`WatchProgressSyncCoordinator.adoptServerBaseline`).
            if let serverTime,
               WatchResumeWinner.decide(serverTime: serverTime, serverLastUpdateMs: serverLastUpdateMs,
                                        localTime: local?.currentTime, localLastUpdateMs: local?.updatedAt) == .server {
                let progressSync = self.progressSync
                let adopted = WatchServerProgress(currentTime: serverTime, lastUpdateMs: serverLastUpdateMs)
                Task { await progressSync.adoptServerBaseline(itemId: itemId, progress: adopted) }
            }

            attachObservers(to: queuePlayer)
            updateNowPlayingInfo()

            if hasReachedResumePosition {
                queuePlayer.play()
                isPlaying = true
            } else {
                // Playback starts from the resume seek's completion instead of
                // here — see `applyResumeSeek(on:)` on why the seek has to wait for
                // `.readyToPlay` and why starting first would mean a second of the
                // book's opening before the jump.
                startPlaybackAfterResumeSeek = true
                applyResumeSeek(on: queuePlayer)
            }
        } catch {
            errorMessage = error.localizedDescription
            // Critique 2026-10-06: the session is now activated before the network
            // call, so a failed load with nothing else loaded releases it again.
            if !displacedLoadedItem && !isLoaded {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            if displacedLoadedItem {
                // The outgoing item's session was already closed above, so it must
                // not be left looking loaded-and-playable against a session that no
                // longer exists. `currentItemId` is deliberately left pointing at it
                // (it really was the last thing played, which is what
                // the Shelf's current sleeve reads, `WatchShelfView`).
                resetPlaybackState()
            }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        resumeAfterInterruption = false
        if isPlaying {
            player.pause()
            isPlaying = false
            // A pause during the load window wins over the resume seek: without
            // this, the seek's completion a moment later would start playback the
            // user just stopped.
            startPlaybackAfterResumeSeek = false
            // Polish pass Phase 2a #7 (WA-2): save the position now, not at the next
            // 30-second tick, so a pause followed by the app being suspended keeps it.
            checkInProgress()
        } else {
            // Critique 2026-10-06 (harden): a resume with no headphones (they
            // disconnected mid-run) goes back through activation, so the system can
            // reconnect them or show its picker, and only then asks about the speaker.
            if !Self.hasExternalAudioRoute() && !speakerAccepted {
                Task { await resume(acknowledgingSpeakerRoute: false) }
                return
            }
            routeIssue = nil
            guard hasReachedResumePosition else {
                // The resume seek hasn't landed yet — arm it instead of playing
                // from the pre-seek position (which is 0 for a fresh item, i.e.
                // exactly the bug this whole path exists to prevent).
                startPlaybackAfterResumeSeek = true
                updateNowPlayingInfo()
                return
            }
            player.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    /// Critique 2026-10-06 (harden): resumes the loaded book after activating the session
    /// and checking the route the system chose. `acknowledgingSpeakerRoute` is the
    /// "Play on Speaker" answer.
    func resume(acknowledgingSpeakerRoute: Bool) async {
        guard let player, isLoaded, !isPlaying else { return }
        resumeAfterInterruption = false   // Phase 2a #7: an explicit play wins over a pending one
        guard await activateAndCheckRoute(acknowledgingSpeakerRoute: acknowledgingSpeakerRoute) else { return }
        guard hasReachedResumePosition else {
            startPlaybackAfterResumeSeek = true
            updateNowPlayingInfo()
            return
        }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    // MARK: - Server progress (Critique 2026-10-06)

    /// How long Play waits for a fresh server reading before a download plays from what
    /// it already knows. Long enough for a nearby phone or Wi-Fi, short enough that a
    /// runner with no signal barely notices.
    nonisolated static let freshProgressTimeout: Double = 3

    /// The server's current position for `itemId`, or `nil` when there's no session, no
    /// answer within `freshProgressTimeout`, or no progress on the server.
    private func freshServerProgress(itemId: String) async -> WatchServerProgress? {
        guard api.isConfigured else { return nil }
        let api = self.api
        let timeout = Self.freshProgressTimeout
        return await withTaskGroup(of: WatchServerProgress?.self) { group in
            group.addTask { await Self.fetchServerProgress(api: api, itemId: itemId) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func fetchServerProgress(api: WatchAudiobookshelfAPI, itemId: String) async -> WatchServerProgress? {
        guard let item = try? await WatchStandaloneCall.perform({ try await api.getItem(itemId: itemId) }),
              let progress = item.mediaProgress, let time = progress.currentTime else { return nil }
        return WatchServerProgress(currentTime: time, lastUpdateMs: progress.lastUpdate.map(Double.init))
    }

    /// The iPhone's snapshot as a server-side reading, when it's about this book on this
    /// Watch's server (`WatchServerProgress.fromCompanion`).
    private func companionProgress(itemId: String) -> WatchServerProgress? {
        guard let state = WatchConnectivityStore.shared.playbackState else { return nil }
        return WatchServerProgress.fromCompanion(
            snapshotItemId: state.itemId, requestedItemId: itemId,
            sameServer: WatchStore.comparableServerURL(state.scope.serverURL) == WatchStore.comparableServerURL(api.serverURL),
            estimatedTime: WatchProgressEstimator.estimatedCurrentTime(state: state),
            isPlaying: state.isPlaying,
            lastConfirmedUpdate: state.lastConfirmedUpdate)
    }

    // MARK: - Sleep timer (PL-4)

    /// Starts, replaces or (for `.off`) cancels the sleep timer. `.endOfChapter` needs chapter
    /// data and is ignored without it.
    func setSleepTimer(_ option: WatchSleepTimerOption) {
        switch option {
        case .off:
            cancelSleepTimer()
        case .minutes(let minutes):
            sleepTimer = StandaloneSleepTimer.minutes(minutes)
        case .endOfChapter:
            sleepTimer = StandaloneSleepTimer.endOfChapter(chapters: chapters, at: currentTime)
        }
        player?.volume = 1
    }

    func cancelSleepTimer() {
        sleepTimer = nil
        player?.volume = 1
    }

    /// Called once per playback second from the time observer: counts a minutes timer down,
    /// fades the last seconds out, and pauses when it fires.
    private func evaluateSleepTimer() {
        guard var timer = sleepTimer else { return }
        // Critique 2026-10-06: the observer fires once per second of *book* time
        // (`addPeriodicTimeObserver`: "interpreted according to the timeline of the
        // current item"), so at 2× a 15-minute timer would have fired after 7.5
        // minutes. Count wall-clock listening seconds instead.
        timer.tick(seconds: 1 / max(playbackRate, 0.1))
        if timer.isExpired(currentTime: currentTime) {
            sleepTimer = nil
            if isPlaying { togglePlayPause() }
            player?.volume = 1   // restored so the next play() isn't silent
            WatchHaptics.tap()
            return
        }
        sleepTimer = timer
        player?.volume = timer.fadeVolume(currentTime: currentTime)
    }

    /// L14: keeps the Watch complication's book, play state and progress current.
    private func publishComplication() {
        guard isLoaded, !itemTitle.isEmpty else { WatchComplicationStore.publish(nil); return }
        WatchComplicationStore.publish(WatchComplicationSnapshot(
            title: itemTitle, author: itemAuthor,
            progress: WatchComplicationSnapshot.progress(currentTime: currentTime, duration: duration),
            isPlaying: isPlaying, updatedAt: Date()))
    }

    /// Critique 2026-10-06 (adapt): sets the playback rate. Applied to the live player
    /// at once when playing (setting `rate` while paused would start playback), and
    /// via `defaultRate` for every later `play()`, including a rebuilt queue
    /// (`attachObservers(to:)` stamps it on each new player).
    func setPlaybackRate(_ rate: Double) {
        let clamped = min(max(rate, 0.5), 3.0)
        playbackRate = clamped
        UserDefaults.standard.set(clamped, forKey: Self.playbackRateDefaultsKey)
        player?.defaultRate = Float(clamped)
        if isPlaying { player?.rate = Float(clamped) }
        updateNowPlayingInfo()
    }

    func skipBackward() { seek(by: -Self.skipBackwardSeconds) }
    func skipForward() { seek(by: Self.skipForwardSeconds) }

    private func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    /// UX fix (31 August 2026), direct user request ("make Now Playing more
    /// intuitive"): companion mode's `NowPlayingView` has had Digital Crown
    /// scrubbing since WATCH-4 — the platform's own expected input method for
    /// seeking on watchOS — but this engine, which backs the *other* Now Playing
    /// screen (`StandaloneNowPlayingView`), never exposed a public absolute-seek
    /// entry point for a view to drive from the crown, only the private
    /// skip-by-a-fixed-amount helper above. Public so `StandaloneNowPlayingView` can
    /// call it directly; same underlying `AVPlayerItem.seek(to:)` `skipBackward()`/
    /// `skipForward()` already used, just parameterized by absolute time instead of
    /// a delta.
    func seek(to time: Double) {
        guard player != nil else { return }
        let target = max(0, min(time, duration))
        // A seek made while the resume seek is still pending *retargets* it rather
        // than racing it: seeking now would be overwritten the moment the resume
        // seek lands. `currentTime` is updated here because the periodic tick is
        // suppressed until then, so nothing else would move the UI.
        if !hasReachedResumePosition {
            pendingResumeTarget = target
            currentTime = target
            chapterSkipLastTickTime = target
            updateNowPlayingInfo()
            return
        }
        seekInQueue(to: target)
    }

    /// The one seek implementation: consult `seekPlan(...)` and either seek within
    /// the current item, advance the queue forward to a later still-queued track, or
    /// rebuild the queue for a backward cross-track seek.
    ///
    /// Stage 3 only ever seeked inside the currently-playing item and deferred
    /// cross-track seeking to "whenever this merges into the full facade (§10.2)".
    /// The resume seek forced the issue — a saved position in a multi-file book is
    /// routinely in a later track than the one the queue starts on — so the forward
    /// half was implemented first. Item 20 (9 September 2026 review) added the
    /// backward half: `AVQueuePlayer` removes items as it consumes them, so a
    /// backward cross-track seek used to clamp to the start of whatever track the
    /// queue was still sitting on instead of reaching the earlier track at all.
    private func seekInQueue(to time: Double, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let player else {
            completion?()
            return
        }
        let target = max(0, min(time, duration))
        chapterSkipLastTickTime = target   // a deliberate seek never triggers a trim
        switch Self.seekPlan(targetAbsolute: target, currentTrackIndex: currentTrackIndex() ?? 0, trackStarts: trackStartsList()) {
        case .withinTrack, .forwardToTrack:
            advanceQueue(toTrackContaining: target)
            guard let item = player.currentItem else {
                completion?()
                return
            }
            let itemRelative = max(0, target - currentTrackStartOffset())
            let tolerance = CMTime(seconds: 1, preferredTimescale: 1000)
            item.seek(to: CMTime(seconds: itemRelative, preferredTimescale: 1000),
                      toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
                // The seek completion handler isn't main-actor-isolated; hop before
                // running the caller's (`@MainActor`) continuation, same shape as
                // `AudioPlayerService`'s own resume-seek completion.
                guard let completion else { return }
                Task { @MainActor in completion() }
            }
        case .rebuildFromTrack(let index, _):
            rebuildQueue(targetAbsolute: target, fromTrackIndex: index, completion: completion)
        }
    }

    /// The track whose cumulative start offset contains `time` — i.e. the last one
    /// starting at or before it. Reads the `trackStartOffsets` map `play(...)` built,
    /// rather than re-deriving offsets from `player.items()`.
    private func track(containing time: Double) -> WatchAudioTrack? {
        var result: WatchAudioTrack?
        var bestOffset = -Double.greatestFiniteMagnitude
        for track in tracks {
            let offset = trackStartOffsets[track.id] ?? 0
            if offset <= time, offset >= bestOffset {
                bestOffset = offset
                result = track
            }
        }
        return result ?? tracks.first
    }

    /// `tracks`' start offsets, in the same order as `tracks` itself — the shape
    /// `seekPlan(...)` needs. Rebuilt from `trackStartOffsets` on every call rather
    /// than cached, since it's only ever needed once per seek.
    private func trackStartsList() -> [Double] {
        tracks.map { trackStartOffsets[$0.id] ?? 0 }
    }

    /// The index into `tracks` of the track the queue is currently sitting on. `nil`
    /// when nothing is loaded or the current item can't be matched (both treated as
    /// index 0 by `seekInQueue(to:)`'s caller, same as an unmatched `track(containing:)`
    /// falling back to `tracks.first`).
    private func currentTrackIndex() -> Int? {
        guard let currentItem = player?.currentItem else { return nil }
        return tracks.firstIndex(where: { playerItem(matches: $0, item: currentItem) })
    }

    /// Advances the queue player forward to the track containing `time`, if it isn't
    /// already the current item.
    ///
    /// Forward only, and deliberately no-ops rather than searching when the target
    /// isn't still queued: `AVQueuePlayer.advanceToNextItem()` *removes* the item it
    /// leaves, so a loop that advanced looking for a track already behind the
    /// playhead would drain the queue and end playback outright.
    private func advanceQueue(toTrackContaining time: Double) {
        guard let player, let target = track(containing: time) else { return }
        if let current = player.currentItem, playerItem(matches: target, item: current) { return }
        guard player.items().contains(where: { playerItem(matches: target, item: $0) }) else { return }
        var remaining = player.items().count
        while remaining > 0, let current = player.currentItem, !playerItem(matches: target, item: current) {
            player.advanceToNextItem()
            remaining -= 1
        }
    }

    private func currentTrackStartOffset() -> Double {
        guard let currentItem = player?.currentItem,
              let track = tracks.first(where: { playerItem(matches: $0, item: currentItem) }) else { return 0 }
        return trackStartOffsets[track.id] ?? 0
    }

    /// Rebuilds the `AVQueuePlayer` from `fromTrackIndex` onward for a backward
    /// cross-track seek (crown scrub or skip-back across a file boundary on a
    /// one-file-per-chapter book) — `AVQueuePlayer.advanceToNextItem()` has already
    /// dropped every track before the current one, so there is no way to move the
    /// existing queue backward into an earlier track (see `seekPlan(...)`'s own doc
    /// comment).
    ///
    /// Reuses the resume-seek machinery (`applyResumeSeek(on:)` /
    /// `hasReachedResumePosition`) rather than a bespoke path: `hasReachedResumePosition
    /// = false` for the duration of the rebuild suppresses the periodic tick and
    /// `captureOutgoingProgress()`'s `shouldRecord` flag, so nothing writes progress
    /// at the stale pre-rebuild position while the new queue is still coming up
    /// (Item 20's "no progress write fires at a wrong position during the rebuild").
    /// `startPlaybackAfterResumeSeek = wasPlaying`, captured *before* the rebuild
    /// starts, means a pause issued mid-rebuild (`togglePlayPause()` clears the flag
    /// on its pause branch, exactly as it does for the initial resume seek) wins over
    /// resuming playback once the new queue's first item becomes ready — the
    /// "a pause during the rebuild wins" half of Item 20.
    ///
    /// `tracks`/`trackStartOffsets`/`isLoaded`/`currentItemId` and the rest of the
    /// loaded-item state are left untouched — only the player and its observers are
    /// torn down and rebuilt — so `updateNowPlayingInfo()` keeps publishing the same
    /// title/author/duration throughout (Item 20's "preserve … Now Playing state").
    /// "Preserve playback rate" is `attachObservers(to:)` stamping `playbackRate` on the
    /// new player as its `defaultRate` (Critique 2026-10-06), plus preserving `isPlaying`
    /// intent, which `startPlaybackAfterResumeSeek` already does; there is no
    /// standalone sleep timer wired to this engine to preserve (grepped — only
    /// companion mode's `SleepTimerView` exists), so nothing else to carry across.
    private func rebuildQueue(targetAbsolute: Double, fromTrackIndex: Int, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let itemId = currentItemId, fromTrackIndex >= 0, fromTrackIndex < tracks.count else {
            completion?()
            return
        }
        let wasPlaying = isPlaying
        player?.pause()
        isPlaying = false
        // The observer-only half of `tearDownPlayer()` — `tracks`/`trackStartOffsets`
        // stay intact so `advanceQueue(toTrackContaining:)`/`currentTrackStartOffset()`
        // keep working against the rebuilt player exactly as they did against the old
        // one.
        detachPlayerObservers()

        let items = tracks[fromTrackIndex...].compactMap { playerItem(for: $0, itemId: itemId) }
        guard !items.isEmpty else {
            player = nil
            completion?()
            return
        }
        let queuePlayer = AVQueuePlayer(items: items)
        player = queuePlayer
        attachObservers(to: queuePlayer)

        // Show the target immediately, same as `play(...)`'s own resume-seek setup —
        // the tick is suppressed until `hasReachedResumePosition` is true again, so
        // nothing else will move the UI in the meantime.
        currentTime = targetAbsolute
        pendingResumeTarget = targetAbsolute
        hasReachedResumePosition = false
        startPlaybackAfterResumeSeek = wasPlaying
        updateNowPlayingInfo()
        applyResumeSeek(on: queuePlayer, additionalCompletion: completion)
    }

    /// Stage 6: checks in with `WatchProgressSyncCoordinator` roughly every 30s of
    /// actual listening. Always records durably (the queue is the only path at all
    /// for a Stage 5 local download); additionally syncs the live session when one
    /// exists (a streamed item). On a successful `syncSession`, resets the listened
    /// counter; on failure, rolls it back in — identical shape to
    /// `AudioPlayerService.syncProgress()`'s own success/failure handling, so a
    /// dropped sync doesn't silently discard that window's listening time.
    private func checkInProgress() {
        // Belt-and-braces with the tick's own identical guard: nothing may be
        // written out before the resume seek has landed, or `currentTime` is still
        // the pre-seek position (0 for a fresh item) and this call is exactly the
        // one that used to destroy the listener's real position.
        guard hasReachedResumePosition else { return }
        guard let itemId = currentItemId, currentTime > 0 else { return }
        progressSync.recordLocalProgress(itemId: itemId, currentTime: currentTime, duration: duration)

        guard let sessionId = currentSessionId else { return }
        let ct = currentTime
        let dur = duration
        let listened = timeListenedSinceSync
        timeListenedSinceSync = 0
        // `@MainActor [weak self]` on the `Task` itself, not just an inner
        // `MainActor.run` — matches this file's own established fix for exactly
        // this shape (`attachObservers(to:)`'s `currentItemObservation`/
        // `endOfQueueObserver`/`routeChangeObserver`, all `Task { @MainActor
        // [weak self] in }`), since `self` here is a `@MainActor`-isolated
        // instance and `api` is too.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Same funnel as `play(...)`'s own session call: a periodic sync is
                // usually the *first* place a session that expired while listening
                // shows up, so it's the earliest honest moment to say so.
                try await WatchStandaloneCall.perform {
                    try await self.api.syncSession(sessionId: sessionId, currentTime: ct, timeListened: listened, duration: dur)
                }
            } catch {
                self.timeListenedSinceSync += listened
            }
        }
    }

    /// Stops local playback and tears down the engine's own state.
    ///
    /// **Stage 6 build note:** this used to deliberately never call `syncSession`/
    /// `closeSession` at all (§10.1) — the whole reason was `ProgressReconciler
    /// .reconcile`'s own conflict check firing on raw divergence before comparing
    /// which side is actually newer, which would have surfaced a misleading
    /// "conflict" on the phone the next time it opened. That risk hasn't gone away
    /// (it's a pre-existing phone-side gap this stage doesn't fix), but Stage 6 adds
    /// `WatchProgressSyncCoordinator`'s own conflict heuristic specifically so this
    /// Watch's own writes don't compound it — see that type's own doc comment. A
    /// streamed session is now closed for real; a local download (no session) only
    /// ever had the queue-based path, unaffected by this change.
    ///
    /// **9 September 2026:** the record-and-close half of this moved into
    /// `captureOutgoingProgress()` + `writeOutProgress(...)` so `play(...)` can run
    /// the identical path — awaited — before it switches to a different book, which
    /// it previously didn't do at all (that was the review's HIGH "switching books
    /// mid-playback loses the outgoing book's progress and leaks its session").
    func stop() {
        let outgoing = captureOutgoingProgress()
        // Fire-and-forget here (unlike `play(...)`, which awaits the same write-out
        // before opening the next session): `stop()` is called straight from a
        // SwiftUI `Button`, and the UI should go idle immediately rather than wait
        // on the network. `captureOutgoingProgress()` has already taken every value
        // the write-out needs, so the reset below can't race it.
        let api = self.api
        let progressSync = self.progressSync
        Task { await Self.writeOutProgress(outgoing, api: api, progressSync: progressSync) }
        resetPlaybackState()
    }

    /// Stops playback and *awaits* the outgoing item's write-out, rather than firing
    /// it off and returning immediately the way `stop()` does.
    ///
    /// Exists for one caller: `WatchStore.wipeCredentials()` (fix for the review's
    /// MEDIUM "phone-side sign-out wipes queued progress and leaves Watch playback
    /// running"). A sign-out is the one moment where the fire-and-forget shape is
    /// wrong — the access token is about to be destroyed, so a write-out that hasn't
    /// finished by the time the wipe runs can never succeed afterwards. Awaiting here
    /// gives the outgoing position its one and only chance to reach the server while
    /// the credential still works.
    func stopAndWriteOutProgress() async {
        let outgoing = captureOutgoingProgress()
        // Reset first, exactly as `stop()` does: `captureOutgoingProgress()` has
        // already taken every value the write-out needs, so tearing down here can't
        // race it, and the UI goes idle immediately instead of after the network.
        resetPlaybackState()
        await writeOutProgress(outgoing)
    }

    /// Everything the outgoing item's final write-out needs, taken synchronously so
    /// the engine's own state can be reset (or rebuilt for another book) without the
    /// write-out ever reading it afterwards — the same hazard
    /// `AudioPlayerService.closeSession()` guards against by capturing before its
    /// `Task`: read `currentTime` too late and the session closes at position 0 and
    /// wipes server progress.
    private struct OutgoingProgress {
        let itemId: String?
        let sessionId: String?
        let currentTime: Double
        let duration: Double
        let timeListened: Double
        /// False when the resume seek never landed: `currentTime` is then just the
        /// position that was already saved, so there's nothing new to record.
        let shouldRecord: Bool
    }

    private func captureOutgoingProgress() -> OutgoingProgress {
        OutgoingProgress(
            itemId: currentItemId,
            sessionId: currentSessionId,
            currentTime: currentTime,
            duration: duration,
            timeListened: timeListenedSinceSync,
            shouldRecord: hasReachedResumePosition && currentItemId != nil && currentTime > 0)
    }

    /// Records the outgoing item's final position, closes its server session if it
    /// had one, and flushes. `static`, with `api`/`progressSync` passed in, so it
    /// survives `self` being torn down or deallocated between the capture and the
    /// network write — the same reason `stop()` already extracted `let api =
    /// self.api` before forming its `Task`.
    private static func writeOutProgress(_ outgoing: OutgoingProgress, api: WatchAudiobookshelfAPI, progressSync: WatchProgressSyncCoordinator) async {
        if outgoing.shouldRecord, let itemId = outgoing.itemId {
            progressSync.recordLocalProgress(itemId: itemId, currentTime: outgoing.currentTime, duration: outgoing.duration)
        }
        if let sessionId = outgoing.sessionId {
            // Closed even when there's nothing new to record — an un-closed session
            // is the leak half of the 9 September 2026 review's HIGH finding, and
            // closing at the position that was already saved is a no-op write.
            // Funnelled like every other standalone call (9 September 2026): the
            // close is `try?` by design — there's nothing useful to do about a
            // failure at this point — but a `.sessionExpired` here is still worth
            // knowing about, and this is often the last call a dying session makes.
            try? await WatchStandaloneCall.perform {
                try await api.closeSession(sessionId: sessionId, currentTime: outgoing.currentTime,
                                          timeListened: outgoing.timeListened, duration: outgoing.duration)
            }
        }
        if outgoing.shouldRecord {
            await progressSync.flushPendingProgress()
        }
    }

    /// Instance convenience over the `static` above, for the one caller that can
    /// simply `await` it (`play(...)`, switching books).
    private func writeOutProgress(_ outgoing: OutgoingProgress) async {
        await Self.writeOutProgress(outgoing, api: api, progressSync: progressSync)
    }

    /// Returns the engine to its idle state. `currentItemId` is deliberately left
    /// alone — it's what the Shelf's current sleeve reads (`WatchShelfView`), and
    /// stopping a book doesn't stop it having been the last one played.
    private func resetPlaybackState() {
        player?.pause()
        tearDownPlayer()
        isPlaying = false
        isLoaded = false
        currentSessionId = nil
        currentTime = 0
        duration = 0
        chapters = []
        chapterSkipLastTickTime = nil
        sleepTimer = nil
        timeListenedSinceSync = 0
        ticksSinceLastSync = 0
        hasReachedResumePosition = true
        startPlaybackAfterResumeSeek = false
        pendingResumeTarget = nil
        routeIssue = nil
        speakerAccepted = false
        WatchRemoteCommandRouter.shared.publish(nil, as: .standalone)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Player item construction

    /// Mirrors `AudioPlayerService.assetURL(forTrackAt:)`'s header-based auth path
    /// exactly (`ShelfHead/Services/AudioPlayerService.swift:390–429`): the access
    /// token rides in an `Authorization: Bearer` header, never the URL's query string,
    /// so it can't leak into proxy access logs or an `NSURLErrorFailingURLStringErrorKey`
    /// -embedded failing-URL string. This stage doesn't build the phone's
    /// `streamWithURLToken` opt-in fallback for proxy setups that drop custom headers
    /// on range requests — a narrower surface is acceptable for a proof-of-concept;
    /// carrying that fallback forward is follow-up scope if it turns out to be needed.
    private func playerItem(for track: WatchAudioTrack, itemId: String) -> AVPlayerItem? {
        guard let contentUrl = track.contentUrl else { return nil }
        // Stage 5 local branch — see `play(...)`'s own doc comment on the `local:`
        // marker convention. No auth headers: it's a plain file on disk, not a
        // server request.
        if contentUrl.hasPrefix("local:") {
            guard let url = WatchLocalDownloadManager.shared.localAudioURL(itemId: itemId, trackIndex: track.index ?? -1) else { return nil }
            return AVPlayerItem(asset: AVURLAsset(url: url))
        }
        guard let url = URL(string: "\(api.serverURL)\(contentUrl)") else { return nil }
        var headers = AuthStore.shared.customHeaders
        headers["Authorization"] = "Bearer \(AuthStore.shared.accessToken)"
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func playerItem(matches track: WatchAudioTrack, item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset, let contentUrl = track.contentUrl else { return false }
        if contentUrl.hasPrefix("local:") {
            let filename = String(contentUrl.dropFirst("local:".count))
            return asset.url.lastPathComponent == filename
        }
        return asset.url.absoluteString.hasSuffix(contentUrl)
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.longFormAudio` — see type doc comment. `options: []` is intentional, not an
        // oversight: this policy is documented (by developer report, not a single
        // authoritative Apple page — `[device check]`) as rejecting non-empty options.
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    }

    /// `true` once active; `false` when the system's route picker was dismissed without a
    /// choice (Apple's `activate(options:completionHandler:)` page: "the system calls the
    /// completion handler with false"). Throws only for a real activation error.
    private func activateAudioSession() async throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            session.activate(options: []) { success, error in
                if let error, !success {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    // MARK: - Observers

    /// Batch 399 follow-up: the phone's timed chapter skip (`WatchChapterSkipSettings`,
    /// persisted from the last phone push) applied to standalone playback. Runs on each
    /// periodic tick; `chapterSkipLastTickTime` is reset to the target by every seek, so
    /// only ordinary forward playback triggers it. The decision is the pure
    /// `WatchChapterSkipRule`.
    private var chapterSkipLastTickTime: Double?

    private func applyChapterSkipIfNeeded() {
        let previous = chapterSkipLastTickTime
        chapterSkipLastTickTime = currentTime
        guard isPlaying, !chapters.isEmpty, let itemId = currentItemId else { return }
        let skip = WatchChapterSkipSettings.load().resolved(forItem: itemId)
        guard skip.start > 0 || skip.end > 0 else { return }
        let bounds = chapters.map { WatchChapterSkipRule.Bounds(start: $0.start, end: $0.end) }
        if let target = WatchChapterSkipRule.target(chapters: bounds, previousTime: previous,
                                                    currentTime: currentTime,
                                                    start: skip.start, end: skip.end) {
            seek(to: target)
        }
    }

    /// What to do when a player item fails during playback.
    nonisolated enum StreamFailureAction: Equatable {
        /// Not a streamed item (a `local:` file has no token), or a recovery is already running.
        case ignore
        /// Refresh the token and rebuild the queue at the current position; `resume` only
        /// if the listener was playing.
        case recover(resume: Bool)
        /// A recovery was already tried inside `window` — stop and tell the listener.
        case giveUp
    }

    /// 30 Oct 2026 review (High 8): streamed items carry the access token baked into their
    /// asset headers, so after a refresh they keep sending the old one and later tracks or
    /// re-issued range requests 401. Pure so the policy is pinned by tests: one recovery
    /// attempt per failure burst (`window`), never for downloaded files.
    nonisolated static func streamFailureAction(
        isStreamed: Bool, wasPlaying: Bool, recoveryInFlight: Bool,
        lastRecoveryAt: Date?, now: Date, window: TimeInterval = 30
    ) -> StreamFailureAction {
        guard isStreamed, !recoveryInFlight else { return .ignore }
        if let last = lastRecoveryAt, now.timeIntervalSince(last) < window { return .giveUp }
        return .recover(resume: wasPlaying)
    }

    /// Entry point for both failure signals (`failedToPlayToEndTime` notification and the
    /// item's `.failed` status). Only this engine's own items are considered.
    private func handleItemFailure(_ item: AVPlayerItem) {
        guard let player, item === player.currentItem || player.items().contains(item) else { return }
        let isStreamed = (item.asset as? AVURLAsset).map { !$0.url.isFileURL } ?? false
        let wasPlaying = isPlaying || startPlaybackAfterResumeSeek
        switch Self.streamFailureAction(isStreamed: isStreamed, wasPlaying: wasPlaying,
                                        recoveryInFlight: isRecoveringStream,
                                        lastRecoveryAt: lastStreamRecoveryAt, now: Date()) {
        case .ignore:
            return
        case .giveUp:
            player.pause()
            isPlaying = false
            startPlaybackAfterResumeSeek = false
            errorMessage = PlaybackError.streamFailed.localizedDescription
            updateNowPlayingInfo()
        case .recover:
            // (`rebuildQueue` derives whether to resume from `isPlaying`, so the case's
            // `resume` value isn't needed here.)
            isRecoveringStream = true
            lastStreamRecoveryAt = Date()
            // Review 2 Low (H8 recovery, 30 October 2026): remember which book this was, and
            // read the position only after the refresh, so a seek or book change made while
            // it ran isn't undone by a stale position.
            let recoveringItemId = currentItemId
            Task { @MainActor [weak self] in
                guard let self else { return }
                // `get(...)` goes through `send(...)`, whose 401 path refreshes the token and
                // updates `AuthStore`; `playerItem(for:itemId:)` reads it fresh on rebuild.
                let probe = await self.api.verifySessionStillAuthenticates()
                self.isRecoveringStream = false
                // The listener may have stopped or switched books while the refresh ran.
                guard self.currentItemId == recoveringItemId else { return }
                // Review 2 Medium 6: only a server-rejected session ends recovery. Unknown
                // (offline, refresh couldn't complete) still tries one rebuild; a second
                // failure inside the window gives up.
                if probe == .rejected {
                    self.player?.pause()
                    self.isPlaying = false
                    self.startPlaybackAfterResumeSeek = false
                    self.errorMessage = PlaybackError.streamFailed.localizedDescription
                    self.updateNowPlayingInfo()
                    WatchStore.shared.signalSessionExpired()
                    return
                }
                let target = self.currentTime
                guard self.isLoaded, self.player != nil,
                      let index = self.track(containing: target).flatMap({ t in self.tracks.firstIndex(where: { $0.id == t.id }) }) else { return }
                self.rebuildQueue(targetAbsolute: target, fromTrackIndex: index)
            }
        }
    }

    private func observeItemStatus(_ item: AVPlayerItem?) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        guard let item else { return }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            // AVPlayerItem is Sendable in the current SDK; no `nonisolated(unsafe)` copy needed.
            Task { @MainActor [weak self] in self?.handleItemFailure(item) }
        }
    }

    private func attachObservers(to player: AVQueuePlayer) {
        // Critique 2026-10-06: every new player (first load and `rebuildQueue`) starts
        // at the chosen speed.
        player.defaultRate = Float(playbackRate)
        // Build-fix (first real Xcode build, Stage 3): mirrors
        // `AudioPlayerService.setupTimeObserver()`'s own identical fix exactly
        // (`AudioPlayerService.swift:783–803`) — `addPeriodicTimeObserver`'s closure
        // type isn't proven main-actor-isolated by the compiler even with
        // `queue: .main`, so mutating `currentTime` (a `@MainActor`-isolated stored
        // property) directly inside it is rejected under Swift 6. `Task { @MainActor
        // in }` would "fix" the same error but reintroduces the exact stutter bug that
        // file's own comment documents (the Task enqueues onto a later run-loop turn
        // instead of running synchronously) — `MainActor.assumeIsolated` is the
        // correct tool: `queue: .main` already guarantees AVFoundation calls this
        // closure synchronously on the main thread, so asserting that to the
        // concurrency checker (rather than hopping via `Task`) satisfies Swift 6
        // without adding a frame of lag to the progress bar.
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Fix (CRITICAL, 9 September 2026 review): suppress the whole tick
                // until the resume seek has landed. Before it does, `time.seconds`
                // is the item's pre-seek position (0 on a fresh item), so letting
                // this through flashed 0:00 on screen, accrued listened time that
                // was never listened to, and 30 ticks later pushed ~30s over the
                // top of the real saved position. `currentTime` is already showing
                // the resume point (set in `play(...)`) while this is suppressed.
                guard self.hasReachedResumePosition else { return }
                self.currentTime = self.currentTrackStartOffset() + time.seconds
                self.applyChapterSkipIfNeeded()
                self.evaluateSleepTimer()
                self.updateNowPlayingInfo()
                // Stage 6: accumulate listened time and check in with the progress
                // writer roughly every 30 ticks (~30s), matching the phone's own
                // sync cadence. Only counts while this closure actually fires, which
                // AVFoundation only does while the player is genuinely advancing —
                // so a paused book doesn't accrue phantom listened time.
                // Critique 2026-10-06: wall-clock seconds, not book seconds (see
                // `evaluateSleepTimer`), so 2× doesn't double the listened time.
                self.timeListenedSinceSync += 1 / max(self.playbackRate, 0.1)
                self.ticksSinceLastSync += 1
                if self.ticksSinceLastSync >= 30 {
                    self.ticksSinceLastSync = 0
                    self.checkInProgress()
                }
            }
        }

        // Build-fix: referencing the outer closure's weakly-captured `self` from
        // *inside* a nested `Task { @MainActor in ... }` is a captured-var-across-
        // concurrency-domains access, which Swift 6 rejects — same root cause and fix
        // `AudioPlayerService.swift:104–113`'s own comment documents. Re-declaring
        // `[weak self]` on the `Task` closure itself, everywhere below, closes over a
        // fresh weak reference at that closure's own formation instead of reading the
        // outer closure's local var.
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.observeItemStatus(self?.player?.currentItem)
                self?.updateNowPlayingInfo()
            }
        }
        observeItemStatus(player.currentItem)
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            // AVPlayerItem is Sendable in the current SDK; no `nonisolated(unsafe)` copy needed.
            Task { @MainActor [weak self] in self?.handleItemFailure(item) }
        }

        endOfQueueObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.items().isEmpty == true else { return }
                // Review Medium 33 (30 October 2026): the end of the book used to only flip
                // `isPlaying`, leaving the final position unsaved, the server session open and
                // the engine "loaded" (so Play played silence). Pin the position to the end and
                // run the same write-out `stop()` does; it records progress, closes the session
                // and resets to idle.
                guard self.isLoaded else { self.isPlaying = false; return }
                if self.duration > 0 { self.currentTime = self.duration }
                self.hasReachedResumePosition = true
                self.stop()
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Build-fix: `Notification` isn't `Sendable`, so it can't be captured into
            // the `@Sendable` `Task` closure directly (matches
            // `AudioPlayerService.swift:1580–1586`'s own route-change handler, which
            // extracts the reason from `notification.userInfo` in this same outer,
            // not-provably-isolated closure before ever entering `Task`). Extract the
            // one `Sendable` value (`UInt`) needed out here, pass that in instead of
            // the notification itself.
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Critique 2026-10-06 (harden): headphones arriving clear any notice and
                // the speaker answer (a later disconnect asks again).
                if Self.hasExternalAudioRoute() {
                    self.routeIssue = nil
                    self.speakerAccepted = false
                }
                guard let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                // Mirrors the phone's own pause-on-disconnect behavior
                // (`AudioPlayerService.swift:1575–1588`) — arguably more important here,
                // since an unexpected speaker blast on a wrist-worn device is more
                // likely to happen somewhere public.
                // Headphones gone: a call's end mustn't resume on the speaker (as on the phone).
                if reason == .oldDeviceUnavailable { self.resumeAfterInterruption = false }
                if reason == .oldDeviceUnavailable, self.isPlaying || self.startPlaybackAfterResumeSeek {
                    let wasPlaying = self.isPlaying
                    self.player?.pause()
                    self.isPlaying = false
                    if wasPlaying { self.checkInProgress() }   // Phase 2a #7 (WA-2)
                    // Same reason as `togglePlayPause()`'s pause branch: a pending
                    // resume seek must not start playback into a route the user
                    // just unplugged.
                    self.startPlaybackAfterResumeSeek = false
                    // Say why it stopped; Play goes back through the route check.
                    if !Self.hasExternalAudioRoute() && !self.speakerAccepted {
                        self.routeIssue = .headphonesDisconnected
                    }
                    self.updateNowPlayingInfo()
                }
            }
        }

        // Polish pass Phase 2a #7 (WA-1): a call, Siri or an alarm deactivates the session.
        // Without this the engine still said "playing", the position wasn't saved, and the
        // book never came back. Same shape as the phone's handler in `AudioPlayerService`:
        // pause and save on `.began`; on `.ended`, resume only when the interruption caught
        // the book playing and the system says resuming is appropriate (`.shouldResume`,
        // https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionoptions/shouldresume).
        // The system posts this notification on the main thread
        // (https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification).
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Extract the Sendable values before entering the Task (see the route-change note above).
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    let wasPlaying = self.isPlaying || self.startPlaybackAfterResumeSeek
                    if self.isPlaying {
                        self.player?.pause()
                        self.isPlaying = false
                        self.checkInProgress()
                    }
                    self.startPlaybackAfterResumeSeek = false
                    self.resumeAfterInterruption = self.resumeAfterInterruption || wasPlaying
                    self.updateNowPlayingInfo()
                case .ended:
                    let systemSaysResume = optionsValue
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
                    let resume = self.resumeAfterInterruption && systemSaysResume
                    self.resumeAfterInterruption = false
                    // `resume` re-activates the session and re-checks the route, so a call
                    // that ends with the headphones gone asks about the speaker instead.
                    if resume { await self.resume(acknowledgingSpeakerRoute: self.speakerAccepted) }
                @unknown default:
                    break
                }
            }
        }
    }

    /// The observer-teardown half of `tearDownPlayer()`, extracted (Item 20, 9
    /// September 2026 review) so a backward cross-track seek's queue rebuild
    /// (`rebuildQueue(...)`) can retire the old `AVQueuePlayer`'s observers before
    /// installing the rebuilt one without also discarding `tracks`/
    /// `trackStartOffsets` — state the rebuilt player still needs
    /// (`advanceQueue(toTrackContaining:)`, `currentTrackStartOffset()`).
    private func detachPlayerObservers() {
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        timeObserverToken = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        resumeSeekObservation?.invalidate()
        resumeSeekObservation = nil
        if let observer = endOfQueueObserver { NotificationCenter.default.removeObserver(observer) }
        endOfQueueObserver = nil
        if let observer = routeChangeObserver { NotificationCenter.default.removeObserver(observer) }
        routeChangeObserver = nil
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        interruptionObserver = nil
        if let observer = itemFailureObserver { NotificationCenter.default.removeObserver(observer) }
        itemFailureObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player?.removeAllItems()
    }

    private func tearDownPlayer() {
        detachPlayerObservers()
        player = nil
        tracks = []
        trackStartOffsets = [:]
    }

    // MARK: - Now Playing / Remote Command Center

    /// Republishes the standalone Now Playing glance from current state — the hook
    /// `WatchRemoteCommandRouter.modeDidChange(to:)` calls when standalone mode becomes
    /// the active owner.
    ///
    /// `configureRemoteCommands()` used to live here (surfacing into watchOS's system
    /// Now Playing glance/Control Center, available to third-party watchOS apps since
    /// watchOS 5 — WWDC 2018 session 504, "Creating Audio Apps for watchOS"; the Watch
    /// has no lock screen). It moved to `WatchRemoteCommandRouter` on 9 September 2026,
    /// because registering it here *and* in `WatchConnectivityStore.init` meant both
    /// were live at once and one Control Center tap acted twice.
    func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    /// Publishes through `WatchRemoteCommandRouter` rather than assigning
    /// `MPNowPlayingInfoCenter.default().nowPlayingInfo` directly (9 September 2026,
    /// review HIGH): only the mode that owns playback may write the glance, and
    /// clearing counts as a write — a standalone teardown used to blank the companion
    /// glance out from under a phone that was still playing.
    private func updateNowPlayingInfo() {
        publishComplication()   // L14: every state change already funnels through here
        guard isLoaded else {
            WatchRemoteCommandRouter.shared.publish(nil, as: .standalone)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: itemTitle,
            MPMediaItemPropertyArtist: itemAuthor,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        WatchRemoteCommandRouter.shared.publish(info, as: .standalone)
    }
}
