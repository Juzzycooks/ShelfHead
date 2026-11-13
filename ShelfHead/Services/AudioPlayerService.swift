import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import WidgetKit
import GroupActivities

@MainActor
@Observable
final class AudioPlayerService {
    // CRIT-3 step 3 (REVIEW_2026-08-12.md): mirrors `DownloadManager.shared`'s exact
    // reasoning (see that type's own `static let shared`/`init()` comments). Without
    // `nonisolated` here, a `static let` on a `@MainActor` class is a main-actor-isolated
    // singleton being lazily constructed — but Swift's static-stored-property
    // initialization runs via a thread-safe one-time-execution mechanism that isn't
    // itself provably on the main actor, so constructing `AudioPlayerService()` from
    // that context was calling this type's (implicitly `@MainActor`-isolated) `init()`
    // from a context the compiler can't prove is isolated — a hard error once
    // `SWIFT_STRICT_CONCURRENCY` moves past `minimal`. `init()` and the three setup
    // functions it calls are marked `nonisolated` below for the same reason; none of
    // them touch this instance's main-actor state synchronously (every touch is already
    // wrapped in `Task { @MainActor in ... }`), so nothing about their behavior changes.
    nonisolated static let shared = AudioPlayerService()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var syncTimer: Timer?
    private var sleepTimer: Timer?

    // Playback state
    var isPlaying = false {
        // Batch 439: ambient beds follow the book's play state (every path that sets this,
        // including end of book and interruptions). The recap montage never sets it.
        didSet { if oldValue != isPlaying { AmbientBedEngine.shared.setPlaying(isPlaying) } }
    }
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0

    /// True while playback is *intended* (`isPlaying`) but AVPlayer is waiting on data
    /// rather than actually rendering audio — i.e. `timeControlStatus ==
    /// .waitingToPlayAtSpecifiedRate`.
    ///
    /// Fix 6.E (REVIEW-2026-09-09.md): published now so `isPlaying` can stay a pure
    /// statement of intent while a stall is still visible somewhere. LS-1
    /// (docs/design-review.md): now wired into the UI via
    /// `PlayerViewModel.isTransportWaiting` — the mini player and full player transport
    /// both show a rotating ring around the play button after ~300ms of continuous
    /// buffering, with the play/pause glyph staying in place and tappable underneath.
    var isBuffering = false

    /// Design review (14 Aug 2026), item 2 — "nothing tells the user whether their
    /// position is saved." Mirrors `PendingProgressQueue.shared.count(forScope:)` for
    /// the currently active scope; refreshed at every point this file already touches
    /// the queue (`record`/`clear`/`drain`) so it stays current without polling. Read by
    /// the connectivity banner and the Diagnostics settings row — see
    /// `refreshPendingProgressCount()` below for why a slightly-stale count is fine here.
    var pendingProgressCount: Int = 0

    /// Batch 433: something (the "Previously On…" montage) that temporarily owns the transport
    /// controls and Now Playing. Deliberately a tracked property (not `@ObservationIgnored`): the
    /// iOS 27 session model reads it inside `content` / `playbackSnapshot` / `commands`, so setting
    /// or clearing it re-publishes those. Only `RecapPlaybackController` sets it, on the main actor.
    var transientOverride: (any TransientPlaybackOverride)?

    // Session
    var currentSession: PlaybackSession?
    var currentItemId: String?
    var currentTrackIndex: Int = 0
    private var timeListenedSinceSync: Double = 0
    private var pausedAt: Date?   // for smart rewind on resume
    /// Whether an audio-session interruption caught us playing; only then may its end resume.
    private var resumeAfterInterruption = false
    private var statusObservation: NSKeyValueObservation?  // waits for item readiness before seeking
    private var hasReachedResumePosition = true            // gates sync until we've seeked to the resume point

    /// The seek-and-then-maybe-play work a freshly-loaded `AVPlayerItem` still owes,
    /// once it actually reaches `.readyToPlay`. Non-nil for exactly the window between
    /// `loadAndPlayTrack` creating an item and `applyPendingItemStart()` finishing with
    /// it (which for an already-ready item is the same turn of the run loop).
    ///
    /// Fixes 6.A and 6.B (REVIEW-2026-09-09.md) both come down to this being state
    /// rather than values captured in a closure at load time:
    ///
    /// - **6.B**: `startWhenReady` used to close over the resume offset it was created
    ///   with, so any seek the user made while the item was still loading (scrubber,
    ///   skip, chapter tap, lock-screen scrub, CarPlay) was silently rewound back to
    ///   the resume point the moment the item became ready. `seek(to:)`'s same-track
    ///   branch now *retargets* `seekOffsetInTrack` and `applyPendingItemStart()`
    ///   re-reads it at fire time, so the last requested position is the one that
    ///   lands.
    /// - **6.A**: the same for the play/don't-play decision. It used to be baked in as
    ///   `loadAndPlayTrack`'s `autoPlay:` argument, derived from `isPlaying` at the
    ///   moment of the call — so a smart rewind that crossed back into the *previous*
    ///   file (`play()` seeked before setting `isPlaying`) reloaded with
    ///   `autoPlay: false` and came up paused while `isPlaying`, Now Playing, the
    ///   widget and the Watch all said playing. `play()`/`pause()` now flip
    ///   `autoPlay` on the pending start instead, so whichever intent is current when
    ///   the item becomes ready is the one honoured.
    private struct PendingItemStart {
        /// Offset *within the loading track* to seek to before playing, or nil for
        /// "start at the top of this track, no seek owed".
        var seekOffsetInTrack: Double?
        /// Whether playback should begin once the seek (if any) has landed.
        var autoPlay: Bool
        /// Bumped by every `loadAndPlayTrack` call so a seek completion that arrives
        /// after a *different* item started loading (or after `stop()`) can recognise
        /// itself as stale and do nothing, rather than clearing the newer load's
        /// pending state — or, after a stop, republishing Now Playing for a session
        /// that no longer exists.
        let generation: Int
    }
    private var pendingItemStart: PendingItemStart?
    private var pendingStartGeneration = 0
    /// Guards the retarget loop in `applyPendingItemStart()` from spinning if a seek
    /// target somehow never converges (it can only be moved by an external `seek(to:)`,
    /// so this is belt-and-braces rather than an expected path).
    private var pendingStartSeekAttempts = 0
    /// KVO on the *player* (not the item) — see `observeTimeControlStatus()`.
    private var timeControlObservation: NSKeyValueObservation?
    /// Debounced "did the player stop underneath us?" check — see
    /// `scheduleUnexpectedPauseCheck()` for why this can't act immediately.
    private var unexpectedPauseCheck: Task<Void, Never>?
    private var streamRecoveryAttempts = 0                 // guards the stream-failure reload (e.g. expired token)
    private var lastStreamRecoveryAt: Date?
    /// Batch 495 (REVIEW 2026-11-11 P4): a `handleStreamFailure` reload is waiting on its
    /// token refresh, so a pause seen meanwhile isn't the stream dying for good.
    @ObservationIgnored private var streamRecoveryInFlight = false
    /// Batch 495 (REVIEW 2026-11-11 P4): true while the "lost the connection" notice is up.
    /// Changes are reported through `onStreamLostChanged`; play/stop/a new start clear it.
    @ObservationIgnored private var streamLostNoticeShown = false {
        didSet { if streamLostNoticeShown != oldValue { onStreamLostChanged?(streamLostNoticeShown) } }
    }
    /// Batch 495 (REVIEW 2026-11-11 P4): `PlayerViewModel` shows the notice through its
    /// failed-start path (root alert, Driving Mode's status line) when this reports true.
    @ObservationIgnored var onStreamLostChanged: ((Bool) -> Void)?
    private var isAdvancingTrack = false                  // guards against double-firing the end-of-track advance
    /// Live-updated by `refreshAudioProcessing()` when volume boost/tone-control
    /// settings change mid-playback; nil when no processing is attached to the current
    /// track (see `AudioProcessingChain`).
    private var audioTapContext: AudioTapContext?

    // Skip intervals (seconds), seeded from user settings.
    private var skipForwardInterval: Double = SettingsStore.skipForwardInterval
    private var skipBackwardInterval: Double = SettingsStore.skipBackwardInterval

    // Sleep timer
    var sleepTimerOption: SleepTimerOption = .off
    var sleepTimerRemaining: TimeInterval = 0
    /// Absolute book time at which a chapter-based sleep timer should pause.
    /// `private(set)` (Batch 406) so `LiveActivityController` can tell a book-time target
    /// (which runs `playbackRate` times faster than the clock) from a wall-clock countdown.
    private(set) var sleepTargetTime: Double?
    /// When true, playback stops (without auto-advancing) when the current book ends.
    private var sleepAtEndOfBook = false

    /// Handoff: the activity type other devices continue to resume the same book.
    static let playbackActivityType = "com.justin.ShelfHead.playback"
    private var playbackActivity: NSUserActivity?

    private nonisolated init() {
        // Follow-up review (14 Aug 2026): `setupRemoteTransportControls()` mutates
        // `MPRemoteCommandCenter.shared()` directly (adding command targets,
        // setting `preferredIntervals`) — real configuration work, not just
        // registering the already-actor-hopping callback closures inside it.
        // `MPRemoteCommandCenter` isn't documented as thread-safe for that
        // configuration, and this `init()` is itself `nonisolated`, so calling it
        // here synchronously ran that mutation on whatever thread first touches
        // `AudioPlayerService.shared` — not guaranteed to be the main thread.
        // Deferred to the main actor instead: it's fire-and-forget wiring done
        // once at singleton construction, and nothing else in this initializer
        // depends on it having completed synchronously. Same `Task { @MainActor
        // [weak self] in ... }` pattern already used a few lines below for the
        // connectivity-restored observer, which confirms capturing `self` weakly
        // like this from inside `init()` is safe here — the closure only ever
        // runs after `init()` has fully returned.
        //
        // Batch 327: which of the two now-playing backends gets wired up here is the
        // whole of the either/or decision — `NowPlayingSessionBridge.backend` is a
        // per-launch `static let`, so exactly one of these two branches ever runs and
        // the classic `MPRemoteCommandCenter` targets are simply never registered on a
        // session-backend launch (a skip handler registered on both paths would skip
        // twice per tap).
        Task { @MainActor [weak self] in
            if #available(iOS 27, *), NowPlayingSessionBridge.backend == .session {
                NowPlayingSessionBridge.shared.activate()
            } else {
                self?.setupRemoteTransportControls()
            }
        }
        setupNotifications()
        setupWidgetControlBridge()
        // Push any progress recorded while offline once the network returns.
        // ARCH-2: `addConnectivityRestoredObserver` now requires `@Sendable`, which a
        // main-actor-isolated capture of `self` doesn't satisfy directly — wrap the hop
        // explicitly instead of letting the closure silently inherit `@MainActor` from
        // this initializer and run on NetworkMonitor's background queue anyway (which is
        // what happened before this fix; `flushPendingProgress()` is `@MainActor` and
        // was executing its synchronous prologue off the main actor every time
        // connectivity was restored).
        // Real build error: `self` from the outer `[weak self]` capture is an implicit
        // local `var` (a weak reference is inherently mutable), and referencing that
        // outer var from inside the nested `Task { @MainActor in ... }` closure — itself
        // a separate concurrently-executing closure — without its own capture list means
        // Swift 6 has to treat it as a captured-var-across-concurrency-domains access,
        // which it rejects. Re-declaring `[weak self]` on the `Task` closure itself
        // creates an independent weak capture taken directly from the outer `self`
        // (still main-actor-isolated at the point the notification fires, and safely
        // weak either way), rather than closing over the outer closure's own local var.
        NetworkMonitor.shared.addConnectivityRestoredObserver { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushPendingProgress()
            }
        }
    }

    /// Listens for the widget's play/pause/skip buttons AND the Control Center toggle's
    /// real "set play state" channel (Darwin notifications posted by
    /// ShelfHeadWidgets/WidgetPlaybackIntents.swift and ShelfHeadPlaybackControl.swift)
    /// and routes them through PlaybackCoordinator rather than calling this service
    /// directly. Delivered while the app is alive in the background — but critically,
    /// this can also be the very first code to run after a fully-terminated app is
    /// relaunched to service the notification, in which case `AudioPlayerService.shared`
    /// has nothing loaded yet. Calling `togglePlayPause()` / `skipForward()` /
    /// `skipBackward()` directly in that state was a silent no-op (the "play button
    /// doesn't resume after closing the app" bug) — PlaybackCoordinator's
    /// `...FromWidget()` methods restore the last-played book from the shared snapshot
    /// first when needed.
    ///
    /// `com.shelfhead.setPlaying`/`com.shelfhead.setPaused` are the Control Center
    /// toggle's dedicated "set" channel (`PlaybackControlToggleIntent` in
    /// ShelfHeadPlaybackControl.swift posts one or the other unconditionally, matching
    /// what `SetValueIntent` asks of it), as opposed to `togglePlayback`'s flip-only
    /// semantics — `playFromWidget()`/`pauseFromWidget()` never infer the requested
    /// state from what's currently playing the way the old toggle-based Control Center
    /// intent had to.
    ///
    /// `com.shelfhead.setSleepTimerOn`/`com.shelfhead.setSleepTimerOff` are the same
    /// "set" pattern for the Control Center sleep timer toggle
    /// (`SleepTimerControlToggleIntent`, in ShelfHeadWidgets/WidgetPlaybackIntents.swift):
    /// they route through `PlaybackCoordinator.setSleepTimerFromWidget(enabled:)` rather
    /// than calling `setSleepTimer(_:)` here directly, for the same cold-start reason as
    /// the play/pause channel above.
    ///
    /// `com.shelfhead.nextChapter`/`com.shelfhead.previousChapter` are the large widget's
    /// chapter skip buttons (`NextChapterIntent`/`PreviousChapterIntent`,
    /// WidgetPlaybackIntents.swift) — same cold-start-relaunch reasoning, routed through
    /// `PlaybackCoordinator.nextChapterFromWidget()`/`previousChapterFromWidget()`.
    private nonisolated func setupWidgetControlBridge() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.toggleFromWidget() }
            },
            "com.shelfhead.togglePlayback" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.skipForwardFromWidget() }
            },
            "com.shelfhead.skipForward" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.skipBackwardFromWidget() }
            },
            "com.shelfhead.skipBackward" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.playFromWidget() }
            },
            "com.shelfhead.setPlaying" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.pauseFromWidget() }
            },
            "com.shelfhead.setPaused" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.setSleepTimerFromWidget(enabled: true) }
            },
            "com.shelfhead.setSleepTimerOn" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.setSleepTimerFromWidget(enabled: false) }
            },
            "com.shelfhead.setSleepTimerOff" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.nextChapterFromWidget() }
            },
            "com.shelfhead.nextChapter" as CFString, nil, .deliverImmediately
        )
        // Sleep timer Live Activity "+15 min" (`SleepTimerExtendIntent`). Calls the same
        // `extendSleepTimer(by:)` the player's own "+15m" uses, then republishes the shared
        // snapshot so `postDarwinAndAwaitHandling`'s `updatedAt` poll sees the ack (a bare
        // extend doesn't write the snapshot itself).
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    let service = AudioPlayerService.shared
                    service.extendSleepTimer(by: 15 * 60)
                    service.republishSharedSnapshot()
                }
            },
            "com.shelfhead.extendSleepTimer15" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.previousChapterFromWidget() }
            },
            "com.shelfhead.previousChapter" as CFString, nil, .deliverImmediately
        )
        // Batch 495 (REVIEW 2026-11-11 Y5): the pinned widget's Play disc (`PlayPinnedBookIntent`).
        // The book id waits in the App Group (`PinnedPlayRequest`); the coordinator plays it.
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in await PlaybackCoordinator.shared.playPinnedFromWidget() }
            },
            PinnedPlayRequest.darwinName as CFString, nil, .deliverImmediately
        )
        // Batch 490 (REVIEW 2026-11-11 F17): Control Centre "Add Bookmark" (`AddBookmarkControlIntent`).
        // Same guards, default title and `BookmarkSyncService.create` call as the lock screen
        // bookmark command (`setupRemoteCommands`); does nothing when no book is loaded and
        // never starts playback. Republishes the snapshot so the intent's `updatedAt` wait ends.
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    let service = AudioPlayerService.shared
                    guard service.transientOverride == nil,
                          let itemId = service.currentItemId, service.currentTime > 0 else { return }
                    let time = service.currentTime
                    let title = BookmarkDefaultTitle.make(chapterTitle: service.currentChapter?.title, time: time)
                    service.republishSharedSnapshot()
                    await BookmarkSyncService.shared.create(itemId: itemId, time: time, title: title)
                }
            },
            "com.shelfhead.addBookmark" as CFString, nil, .deliverImmediately
        )
    }

    /// Writes the shared snapshot so a widget/Live Activity intent waiting on its
    /// `updatedAt` (see `postDarwinAndAwaitHandling`) gets its acknowledgement.
    fileprivate func republishSharedSnapshot() {
        publishControlState()
    }

    // MARK: - Playback Control

    /// Batch 427 (Section E): the server's own chapters (and how many it sent unreadably) for
    /// the loaded session, kept so `reloadChapterOverride()` can re-resolve after the listener
    /// saves or resets chapters made on this device. `currentSession.chapters` holds whatever
    /// is in effect (the override's, when one applies).
    private(set) var serverChapters: [Chapter]?
    private(set) var serverDroppedChapterCount = 0

    /// The one place chapters made on this device replace the server's: a copy of `session`
    /// whose chapters are `ChapterOverrideStore`'s resolution of the server ones (and no
    /// "couldn't read N chapters" note, which described the list that's been replaced).
    /// Returns `session` untouched when nothing differs.
    private func sessionResolvingChapterOverride(_ session: PlaybackSession, itemId: String?) -> PlaybackSession {
        let server = serverChapters ?? []
        let wanted: [Chapter]?
        let dropped: Int
        if ChapterOverrideStore.isApplied(itemId: itemId, server: server) {
            wanted = ChapterOverrideStore.resolvedChapters(itemId: itemId, server: server)
            dropped = 0
        } else {
            wanted = serverChapters
            dropped = serverDroppedChapterCount
        }
        let same = Self.sameChapters(wanted, session.chapters)
        if same && dropped == session.droppedChapterCount { return session }
        return PlaybackSession(
            id: session.id,
            libraryItemId: session.libraryItemId,
            mediaType: session.mediaType,
            duration: session.duration,
            playMethod: session.playMethod,
            audioTracks: session.audioTracks,
            currentTime: session.currentTime,
            startTime: session.startTime,
            chapters: wanted,
            libraryItem: session.libraryItem,
            droppedChapterCount: dropped
        )
    }

    nonisolated private static func sameChapters(_ a: [Chapter]?, _ b: [Chapter]?) -> Bool {
        let a = a ?? [], b = b ?? []
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.id == $1.id && $0.start == $1.start && $0.end == $1.end && $0.title == $1.title }
    }

    /// Re-resolves the live session's chapters after chapters made on this device were saved
    /// or removed (`.shelfheadChapterOverrideChanged`), and refreshes everything that was
    /// derived from the old list: Now Playing (chapter title/number/count and the
    /// chapter-relative elapsed/duration, via `updateNowPlaying()`, which also rewrites the
    /// shared widget/Watch snapshot), plus the per-chapter bookkeeping the time observer keeps.
    func reloadChapterOverride() {
        guard let session = currentSession else { return }
        let resolved = sessionResolvingChapterOverride(session, itemId: currentItemId)
        guard resolved.droppedChapterCount != session.droppedChapterCount
                || !Self.sameChapters(resolved.chapters, session.chapters) else { return }
        currentSession = resolved
        lastHapticChapterId = nil
        lastAutoSkippedChapterId = nil
        chapterSkipLastTickTime = currentTime
        lastPublishedChapterId = nil
        updateNowPlaying()
    }

    /// Review Medium 9 (30 October 2026): whether starting `new` should first sync and close
    /// the session that is loaded now. True only when a session is loaded, it is for a
    /// different book, and it isn't literally the same server session (a prefetched session
    /// handed over for gapless auto-advance is a *new* session id for the *next* book, so
    /// it still closes the finished one; re-handing the live session closes nothing).
    ///
    /// Review 2 Low (Playback) (30 October 2026): the book comparison is gone. A podcast
    /// episode switch (same `libraryItemId`) and a fresh session for the same book also
    /// leave the old session open; any differing session id closes it.
    nonisolated static func shouldCloseOutPreviousSession(
        loadedSessionId: String?, loadedItemId: String?, newSessionId: String, newItemId: String?
    ) -> Bool {
        guard let loadedSessionId else { return false }
        return loadedSessionId != newSessionId
    }

    /// Review 2 High 2 (30 October 2026): while a mixtape plays clips, no position may be
    /// written as a book's saved position (iCloud, server, session close). Pure, for tests.
    nonisolated static func shouldRecordPosition(suppressed: Bool) -> Bool { !suppressed }

    /// Review 2 High 2 (30 October 2026): called by `MixtapePlayer` just before it turns
    /// suppression on. Saves the loaded book's real position and closes its session, so the
    /// clips that follow can't leave it open or overwrite it. The session is closed, so the
    /// caller must start a fresh one if it keeps using this book.
    func flushAndCloseForMixtape() {
        // Review 4 Low (second close): from the stale post-mixtape state (suppressed, not driving)
        // the previous clip session stays open: closing sends `currentTime`, which is a clip
        // position, and the API can't omit it. The server expires idle sessions; left as is.
        guard currentSession != nil, !suppressProgressSync else { return }
        if let itemId = currentItemId {
            CloudPositionStore.shared.record(itemId: itemId, currentTime: currentTime, duration: duration, force: true)
        }
        syncProgress()
        closeSession()
    }

    /// Returns false (and changes nothing) when the session has no audio tracks, so the
    /// caller can surface its failure alert. Review Medium 10 (30 October 2026): this used
    /// to replace `currentSession` first and bail afterwards, leaving the old audio playing
    /// under the new title with the periodic sync writing its position onto the new book.
    @discardableResult
    func startPlayback(session rawSession: PlaybackSession, startTime: Double? = nil) -> Bool {
        guard let tracks = rawSession.audioTracks, !tracks.isEmpty else {
            ShelfLog.error(.playback, "Playback session has no audio tracks; not switching")
            return false
        }
        let newItemId = rawSession.libraryItemId ?? rawSession.libraryItem?.id
        // Review Medium 9 (30 October 2026): switching books never saved or closed the
        // previous one (up to 30 s of position and listening time lost, old server session
        // left open). Same order as `stop()`: `syncProgress()` reports and zeroes the
        // accumulated listening time before `closeSession()` reads it. Both capture their
        // values synchronously and write in tracked tasks, so this doesn't delay the start.
        if Self.shouldCloseOutPreviousSession(
            loadedSessionId: currentSession?.id, loadedItemId: currentItemId,
            newSessionId: rawSession.id, newItemId: newItemId) {
            // Review 2 High 2 (30 October 2026): not while a mixtape is playing clips.
            if let itemId = currentItemId, Self.shouldRecordPosition(suppressed: suppressProgressSync),
               !Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync) {   // Review 7 Medium 1
                CloudPositionStore.shared.record(itemId: itemId, currentTime: currentTime, duration: duration, force: true)
            }
            syncProgress()
            closeSession()
        }
        // Review 7 Medium 2: a chapter / end-of-book sleep timer doesn't follow the listener to another book.
        if Self.shouldCancelSleepOnItemChange(option: sleepTimerOption, oldItemId: currentItemId, newItemId: newItemId),
           currentSession != nil {
            cancelSleepTimer()
        }
        serverChapters = rawSession.chapters
        serverDroppedChapterCount = rawSession.droppedChapterCount
        let session = sessionResolvingChapterOverride(rawSession, itemId: newItemId)
        currentSession = session
        currentItemId = session.libraryItemId ?? session.libraryItem?.id
        if !mixtapeDriving { resumedFromMixtapeClip = false }   // Review 4 Low (quick play-pause): a fresh load isn't at a clip position
        // Review 3 High 3: a new session loaded by anything but the mixtape ends the post-mixtape
        // suppression (the previous clip session was closed out above, still suppressed).
        suppressProgressSync = Self.suppressionAfterExplicitAction(mixtapeDriving: mixtapeDriving, suppressed: suppressProgressSync)

        var rawStartOffset = startTime ?? session.currentTime ?? 0
        // Fallback: when the server can't be reached, adopt a further-along iCloud
        // position over the (possibly stale) one just resolved above. Never overrides
        // a reachable server's answer — see `CloudPositionStore.shouldAdoptCloudPosition`.
        if let cloudItemId = currentItemId,
           let cloud = CloudPositionStore.shared.position(forItemId: cloudItemId) {
            let serverReachable = ReachabilityStore.shared.status == .ok
            let localUpdatedAt = session.libraryItem?.mediaProgress?.lastUpdate
                .map { Date(timeIntervalSince1970: Double($0) / 1000) }
            if CloudPositionStore.shouldAdoptCloudPosition(
                cloud: cloud, localCurrentTime: rawStartOffset, localUpdatedAt: localUpdatedAt,
                serverReachable: serverReachable
            ) {
                rawStartOffset = cloud.currentTime
                ShelfLog.info(.playback, "Adopted iCloud position for \(cloudItemId)")
            }
        }
        duration = session.duration ?? 0
        // ARCH-9: clamp a finished-or-past-the-end saved position a hair before the
        // very end rather than resuming literally at the last sample — a genuinely
        // finished book (currentTime >= duration, from a manifest rounding past
        // duration, a Handoff resume, or reopening a completed book from the library)
        // would otherwise sit exactly at the boundary `moveToNextTrack`'s
        // didPlayToEndTime notification fires on, risking an immediate re-trigger of
        // natural-completion handling. `TrackTimeline.position` below already resolves
        // an at-or-past-duration offset to "end of the last track" rather than
        // silently matching no track at all (the actual root cause — see
        // TrackTimeline.swift) — this clamp is an additional safety margin on top.
        //
        // NEW-9 (follow-up review, 14 Aug 2026): the original `min(rawStartOffset,
        // max(0, duration - 1))` silently discarded the resume position whenever
        // `duration` was 0 or unknown (`session.duration` nil, or a manifest whose
        // duration the server never reported) — `max(0, 0 - 1) == 0`, so
        // `startOffset` collapsed to 0 regardless of `rawStartOffset`, and the next
        // `syncProgress()` call then wrote that 0 back to the server, permanently
        // losing the real position. This reintroduced ARCH-9 for exactly the input
        // class it exists to fix (offline sessions built from a manifest,
        // `DownloadedBook.localSession`; podcast-episode sessions,
        // `PlayerViewModel.swift`). Only clamp against `duration - 1` when there's
        // an actual duration to clamp against; otherwise trust the saved position
        // as-is (still floored at 0, in case of a corrupt negative value).
        let startOffset = duration > 0 ? min(rawStartOffset, duration - 1) : max(0, rawStartOffset)

        let timeline = TrackTimeline(tracks: tracks, chapters: session.chapters ?? [])
        let position = timeline.position(atAbsoluteTime: startOffset)
        let targetTrackIndex = position.trackIndex
        let trackSeekTime = position.offsetInTrack

        currentTrackIndex = targetTrackIndex
        // Reflect the resume position immediately so the lock screen / widget / sync
        // never momentarily report 0 (which previously wiped server progress).
        currentTime = startOffset
        hasReachedResumePosition = false
        streamRecoveryAttempts = 0
        streamLostNoticeShown = false   // Batch 495 (P4): a new start replaces the notice
        // Reset the per-session listen counter so time listened on the previous book
        // isn't attributed to this one on the first sync.
        timeListenedSinceSync = 0
        hasFiredNearEnd = false
        lastHapticChapterId = nil
        lastAutoSkippedChapterId = nil
        // A fresh start at the top of the book counts as "entering" the first chapter, so
        // its start trim applies; resuming anywhere else is not a boundary crossing.
        if let first = session.chapters?.first, abs(startOffset - first.start) < 0.5 {
            chapterSkipLastTickTime = first.start - 0.01
        } else {
            chapterSkipLastTickTime = startOffset
        }
        // Cleared before `loadAndPlayTrack` — which ends in `updateNowPlaying()` — so
        // the new book's opening chapter is published once there and the very first
        // periodic tick then finds the ids already in agreement. Not clearing it would
        // leave the previous book's chapter id here, which for a book whose resume
        // point happens to land in the same-numbered chapter would suppress that first
        // publish; clearing it and NOT publishing in `loadAndPlayTrack` would instead
        // cost one redundant publish on the first tick.
        lastPublishedChapterId = nil
        applyScheduledSleepTimerIfNeeded()
        loadAndPlayTrack(at: targetTrackIndex, seekTo: trackSeekTime)

        // Batch 327: the one place the iOS 27 `MediaSession` asks to own the
        // now-playing surfaces. The classic path has no equivalent step
        // (`MPNowPlayingInfoCenter` is implicitly whoever wrote to it last), and this is
        // per-session rather than per-resume on purpose — see
        // `NowPlayingSessionBridge.playbackDidStart()`.
        if #available(iOS 27, *), NowPlayingSessionBridge.backend == .session {
            NowPlayingSessionBridge.shared.playbackDidStart()
        }

        // Load cover art for lock screen / Dynamic Island
        if let itemId = session.libraryItemId {
            loadNowPlayingArtwork(for: itemId)
        } else if let itemId = session.libraryItem?.id {
            loadNowPlayingArtwork(for: itemId)
        }
        return true
    }

    private func loadAndPlayTrack(at index: Int, seekTo time: Double = 0, autoPlay: Bool = true) {
        guard let tracks = currentSession?.audioTracks, index < tracks.count else { return }
        // A new track is now loading; clear the end-of-track advance guard.
        isAdvancingTrack = false

        guard let resolved = assetURL(forTrackAt: index) else { return }

        let asset: AVURLAsset
        if let headers = resolved.headers {
            asset = AVURLAsset(url: resolved.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: resolved.url)
        }
        let playerItem = AVPlayerItem(asset: asset)
        // Batch 440: opt-in Spatial Audio (see SpatialAudioStatus.swift).
        playerItem.allowedAudioSpatializationFormats = SpatialAudioStatus.formats(forEnabled: SettingsStore.spatialAudioEnabled)

        // Audio tap (see AudioProcessingChain.swift): attached only when some processing is on
        // (volume boost, bass/treble, Clearer voices, Even volume). Merely having a tap pulls
        // AVFoundation off its hardware-assisted path for the whole track, so tracks with
        // everything neutral get none (Batch 4x battery fix). Batch 438 factored the attach
        // into `attachAudioProcessing` so `refreshAudioProcessing()` can use it mid-track.
        attachAudioProcessing(to: playerItem, asset: asset, trackIndex: index)

        // Batch 456: name this item for SharePlay *before* it becomes current, because the
        // coordinator's delegate asks for the identifier as soon as the item is set.
        registerCoordinationIdentifier(for: playerItem, trackIndex: index)

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
            // Attached once per AVPlayer instance rather than per item, because
            // `timeControlStatus` lives on the player and survives
            // `replaceCurrentItem` (fix 6.E).
            observeTimeControlStatus()
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        // Batch 456: a new AVPlayer (first load, or after `reloadCurrentTrack`) has a fresh
        // playbackCoordinator, so a live SharePlay session is re-attached here.
        applyPlaybackCoordination()
        if let itemId = currentItemId { onTrackLoaded?(itemId, index) }

        statusObservation?.invalidate()
        statusObservation = nil
        // A new item is loading: whatever the previous one still owed is void, and any
        // in-flight "did the player stop underneath us?" check would now be looking at
        // a pause that IS ours (this reload). Both reset before `pendingItemStart` is
        // re-armed below.
        cancelUnexpectedPauseCheck()
        pendingStartSeekAttempts = 0
        pendingStartGeneration += 1
        pendingItemStart = PendingItemStart(seekOffsetInTrack: time > 0 ? time : nil,
                                            autoPlay: autoPlay,
                                            generation: pendingStartGeneration)

        let trackStart = tracks[index].startOffset ?? 0
        currentTime = trackStart + time
        hasReachedResumePosition = (time <= 0)
        setupTimeObserver()

        // Seek to the resume point (if any) and begin playback ONLY once the item is
        // ready. Calling play()/seek before `.readyToPlay` is unreliable and can leave
        // the player paused or stuck at 0 — the cause of "won't play, just sits there".
        // The work itself lives in `applyPendingItemStart()` (fixes 6.A/6.B — it reads
        // the seek target and the play/don't-play intent out of `pendingItemStart` at
        // fire time instead of closing over the values this call was made with).
        // Polish pass (PB-5): the observation now lives for the item's whole lifetime
        // (it used to be removed at `.readyToPlay`), so a `.failed` that arrives after the
        // item was ready — a stream that dies mid-book — is seen here too, not only through
        // `failedToPlayToEndTimeNotification`. It is replaced/invalidated wherever the item
        // is (`loadAndPlayTrack`, `stop`, the media-services rebuild).
        let alreadyReady = playerItem.status == .readyToPlay
        do {
            statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                // KVO callbacks aren't guaranteed on the main thread; hop before touching
                // any observable/player state (including invalidating the observation).
                let status = item.status
                // Captured unconditionally (not just #if DEBUG) so a real failure is visible
                // in "Export Diagnostics" too, not only in a debug console — but routed
                // through `ShelfLog.error`, never a raw `print`, because AVFoundation/
                // URLSession error descriptions often embed the *full failing URL*
                // (`NSURLErrorFailingURLStringErrorKey`) including its query string. If
                // `streamWithURLToken` is enabled (see `assetURL`), that URL can contain
                // `?token=<access token>` — `ShelfLog.error` runs this through
                // `ShelfLog.redact` before it touches the log or the diagnostics buffer, so
                // the token never reaches either even in that mode. A bare `print` would have
                // bypassed that redaction entirely.
                let errorDescription = item.error?.localizedDescription
                // CRIT-3 follow-up: same fix as the seek-completion handler above —
                // unwrap the weak capture here, before creating the `Task`, rather
                // than referencing the captured-var `self` from inside it.
                guard let self else { return }
                Task { @MainActor in
                    switch status {
                    case .readyToPlay:
                        self.applyPendingItemStart()
                    case .failed:
                        self.statusObservation?.invalidate()
                        self.statusObservation = nil
                        // Polish pass (PB-5): a failure after the item had already become
                        // ready is a mid-playback stream failure — hand it to the same
                        // recovery `failedToPlayToEndTimeNotification` uses (token refresh +
                        // reload, capped; no-op for local files). A failure before ready
                        // keeps the original handling below.
                        let failedAfterReady = self.pendingItemStart == nil && self.hasReachedResumePosition
                        self.hasReachedResumePosition = true
                        // Nothing is ever going to become ready for this item, so the
                        // owed start work can't be honoured — drop it rather than
                        // leaving `pendingItemStart` non-nil forever, which would
                        // permanently suppress the unexpected-pause reconciliation
                        // (fix 6.E treats a pending item load as "our" pause).
                        self.pendingItemStart = nil
                        self.isBuffering = false
                        ShelfLog.error(.playback, "Player item failed: \(errorDescription ?? "unknown")")
                        // An item that will never become ready can't be playing, so
                        // don't leave every surface claiming it is. No new
                        // `timeControlStatus` change is coming (the player was already
                        // `.paused`), so the reconciliation has to be asked for here.
                        self.scheduleUnexpectedPauseCheck()
                        if failedAfterReady { self.handleStreamFailure() }
                    default:
                        break
                    }
                }
            }
        }
        if alreadyReady { applyPendingItemStart() }

        updateNowPlaying()
    }

    /// Applies whatever start work the current (now `.readyToPlay`) item still owes:
    /// the resume seek — or, if the user moved somewhere else while it was loading,
    /// *their* seek — and then playback, if playback is still what's intended.
    ///
    /// This replaces the old `startWhenReady` closure, which captured both the seek
    /// offset and the `autoPlay` flag at track-load time. Every value it needs is now
    /// re-read from `pendingItemStart` at fire time (see that type's doc comment for
    /// the two bugs that fixes, 6.A and 6.B), and the seek completion re-checks the
    /// target once more in case a seek landed while the first one was in flight.
    ///
    /// CRIT-3 (15 Aug 2026), still applies: with `SWIFT_STRICT_CONCURRENCY = targeted`
    /// a plain `DispatchQueue.main.async` hop doesn't carry actor-isolation
    /// information to the concurrency checker the way `Task { @MainActor in ... }`
    /// does, so referencing this (`@MainActor`-isolated) instance's `self` inside one,
    /// from a closure the compiler already treats as `@Sendable` (AVPlayer's seek
    /// completion runs on a not-provably-main-actor thread), was flagged as an unsafe
    /// cross-isolation reference. Hence the `Task { @MainActor in ... }` below, with
    /// the weak capture resolved to a plain `let` *before* the `Task` is created —
    /// reading a captured var from a nested concurrently-executing closure is what
    /// Swift 6 actually rejects.
    private func applyPendingItemStart() {
        guard let pending = pendingItemStart else { return }

        guard let offset = pending.seekOffsetInTrack, offset > 0 else {
            pendingItemStart = nil
            pendingStartSeekAttempts = 0
            hasReachedResumePosition = true
            if pending.autoPlay { play() }
            updateNowPlaying()
            return
        }

        let generation = pending.generation
        let target = CMTime(seconds: offset, preferredTimescale: 600)
        let tol = CMTime(seconds: 1, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Stale completion: a different item started loading, or `stop()`
                // happened, while this seek was in flight. Nothing here is ours to
                // finish — and in the stop case, `updateNowPlaying()` below would
                // republish a session that has already been torn down.
                guard let current = self.pendingItemStart, current.generation == generation else { return }
                // Fix 6.B: if a `seek(to:)` retargeted us while this seek was in
                // flight, honour the newer target instead of declaring the resume
                // point reached. AVPlayer cancels a pending seek when a new one is
                // issued (this completion then fires with `finished: false`), so
                // without this the user's position could still be lost — it just
                // wouldn't be rewound by us. The 1s comparison window matches the
                // tolerance the seek itself was issued with, so a seek that landed
                // where we asked never counts as a retarget.
                if Self.shouldRetargetPendingSeek(
                    seekedOffset: offset,
                    desiredOffset: current.seekOffsetInTrack,
                    attempts: self.pendingStartSeekAttempts
                ) {
                    self.pendingStartSeekAttempts += 1
                    self.applyPendingItemStart()
                    return
                }
                let shouldPlay = current.autoPlay
                self.pendingItemStart = nil
                self.pendingStartSeekAttempts = 0
                self.hasReachedResumePosition = true
                if shouldPlay { self.play() }
                self.updateNowPlaying()
            }
        }
    }

    /// Whether a just-completed pending-start seek should be re-issued because the
    /// target moved while it was in flight (fix 6.B).
    ///
    /// `desiredOffset` is `pendingItemStart?.seekOffsetInTrack` read *after* the seek
    /// completed: nil means nothing is owed any more (the pending start was consumed or
    /// cleared), in which case there's nothing to retarget. The 1-second window matches
    /// the tolerance the seek was issued with, so a seek that landed where it was asked
    /// to never counts as a retarget and this can't loop on rounding. The attempt cap is
    /// belt-and-braces: only an external `seek(to:)` can move the target, so in practice
    /// this fires at most once per user seek.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live `AVPlayer`.
    nonisolated static func shouldRetargetPendingSeek(
        seekedOffset: Double, desiredOffset: Double?, attempts: Int
    ) -> Bool {
        guard let desiredOffset, attempts < 4 else { return false }
        return abs(desiredOffset - seekedOffset) > 1
    }

    /// Resolves the playable URL for a track, preferring a local download (offline
    /// playback / bandwidth saving) and falling back to streaming with an auth header.
    private func assetURL(forTrackAt index: Int) -> (url: URL, headers: [String: String]?)? {
        guard let tracks = currentSession?.audioTracks, index < tracks.count else { return nil }

        // 1) Local downloaded file, if present.
        if let itemId = currentItemId,
           let localURL = DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: index) {
            return (localURL, nil)
        }

        guard let contentUrl = tracks[index].contentUrl else { return nil }

        // 2) An absolute file URL (offline session built from a manifest).
        if contentUrl.hasPrefix("file://"), let url = URL(string: contentUrl) {
            return (url, nil)
        }

        // 3) Stream from the server. Header-only auth (`Authorization: Bearer …`, applied
        // via AVURLAssetHTTPHeaderFieldsKey below) is the default and preferred path: the
        // access token never appears in the URL at all, so it can't leak into reverse-proxy
        // access logs, browser/CDN history, or — see `ShelfLog.redact` — an AVFoundation
        // error's `NSURLErrorFailingURLStringErrorKey`-embedded failing URL. Some proxy/
        // AVPlayer combinations, however, drop the custom Authorization header specifically
        // on the byte-range/redirect follow-up requests AVPlayer issues mid-stream (the
        // initial request succeeds, then subsequent range requests 401 and the stream
        // aborts) — for those setups, `streamWithURLToken` (Settings → Streaming, OFF by
        // default) is the escape hatch: it duplicates the token into the URL's query string
        // as well, so it rides along on every request regardless of which headers survive
        // AVPlayer's internals. This is opt-in fallback behaviour, not the default; the
        // header is attached unconditionally either way (see `headers` below), so turning
        // the setting on only ever adds a second, redundant place the token appears — it
        // never removes the header path.
        //
        // We deliberately don't attempt to detect a range-request auth failure at runtime
        // and retry with the URL-token path automatically: AVPlayer's `.failed` status and
        // `failedToPlayToEndTimeNotification` don't reliably distinguish "401 on a range
        // request" from any other network/decoding failure (see `handleStreamFailure`,
        // which already owns the one auth-shaped recovery we *can* detect: an expired
        // access token, refreshed and retried). Inventing a fragile "was that a range-auth
        // failure?" heuristic we can't verify against a real device/proxy is worse than
        // asking the small number of affected users to flip one Settings toggle.
        let serverURL = AuthStore.shared.serverURL
        let token = AuthStore.shared.accessToken
        let urlString: String
        if SettingsStore.streamWithURLToken {
            let separator = contentUrl.contains("?") ? "&" : "?"
            urlString = "\(serverURL)\(contentUrl)\(separator)token=\(token)"
        } else {
            urlString = "\(serverURL)\(contentUrl)"
        }
        guard let url = URL(string: urlString) else { return nil }
        // Merge in any reverse-proxy headers configured for this server (Cloudflare
        // Access, Authelia, etc.) — `AuthStore.shared.customHeaders` wins on key
        // collision, though a proxy header named "Authorization" would be unusual.
        var headers = AuthStore.shared.customHeaders
        headers["Authorization"] = "Bearer \(token)"
        return (url, headers)
    }

    func play() {
        // Review 3 High 3: an explicit play (not the mixtape's own) ends post-mixtape suppression.
        if suppressProgressSync && !mixtapeDriving {
            resumedFromMixtapeClip = true   // Review 4 Low (quick play-pause)
            timeListenedSinceSync = 0       // Review 5 Medium 2: the guard counts listening since this play
        }
        suppressProgressSync = Self.suppressionAfterExplicitAction(mixtapeDriving: mixtapeDriving, suppressed: suppressProgressSync)
        resumeAfterInterruption = false   // Review 2 Low (Playback) (30 October 2026): explicit play
        // Batch 433: the book itself was asked to play while the recap montage owns the controls
        // (in-app play button, widget, Siri). The recap steps aside without resuming the book,
        // and the book carries on below.
        if let override = transientOverride {
            override.overrideYieldToBook()
        } else if RecapPlaybackController.shared.interceptResumeIfNeeded() {
            // "Play Recap When Resuming": the recap plays first and calls `play()` again when it
            // ends. `interceptResumeIfNeeded` decides once per loaded session and records the
            // offer, so that second call can't be intercepted again.
            return
        }
        // Without a loaded player/session, playImmediately(atRate:) on a nil `player`
        // is a no-op — but everything below it isn't: it would still activate the audio
        // session (interrupting whatever else is playing), flip isPlaying to true with
        // no audio behind it, publish phantom Now Playing info, and write a widget
        // snapshot claiming something is playing when nothing is. Reachable via the
        // widget's toggle button on a fresh install / after Sign Out, where there's no
        // last-played book to restore. Bail before any of that happens.
        guard player != nil, currentSession != nil else { return }
        // Batch 495 (REVIEW 2026-11-11 P4): an explicit play replaces the lost-stream
        // notice. If the item itself has failed, playing it would do nothing while every
        // surface said playing, so reload it at the current position instead; the
        // listener asked for sound, so the reload starts it.
        streamLostNoticeShown = false
        if player?.currentItem?.status == .failed {
            reloadCurrentTrackAfterStreamLoss()
            return
        }
        activateAudioSession()

        // Fix 6.A (REVIEW-2026-09-09.md): the intent is declared BEFORE the
        // smart-rewind seek, not after it. `seek(to:)`'s different-track branch derives
        // its `autoPlay:` argument from `isPlaying`, so with `isPlaying` still false
        // here a rewind that crossed back into the *previous* audio file reloaded the
        // item with `autoPlay: false` — the reload seeked and then sat there paused,
        // while `isPlaying`, Now Playing, the widget and the Watch (all set a few lines
        // further down) said playing. One-file-per-chapter books make "paused for an
        // hour, resume a few seconds into a file" an ordinary thing to do, not an edge
        // case. Nothing else observes `isPlaying` synchronously between here and the
        // end of this function, so moving it up is otherwise inert.
        isPlaying = true
        // Whatever the reconciler may have been about to check, this play() supersedes.
        cancelUnexpectedPauseCheck()

        // Smart rewind: nudge back a few seconds based on how long we were paused.
        // `pausedAt` is cleared *before* the seek so the re-entrant `play()` that
        // `applyPendingItemStart()` performs — when the rewind does cross a file
        // boundary — can't apply a second rewind on top of this one.
        let pausedSince = pausedAt
        pausedAt = nil
        if let pausedSince {
            let rewind = SettingsStore.smartRewindAmount(pausedFor: Date().timeIntervalSince(pausedSince))
            if rewind > 0 { seek(to: max(0, currentTime - rewind)) }
        }
        // Batch 490 (REVIEW 2026-11-11 F20): offered once, then forgotten either way.
        if let offer = sleepResumeOffer {
            sleepResumeOffer = nil
            if let target = Self.sleepJumpBackTarget(armedAt: offer.time, armedItemId: offer.itemId,
                                                     resumeAt: currentTime, currentItemId: currentItemId) {
                onSleepResumeOffer?(offer.itemId, target)
            }
        }

        player?.volume = 1   // restore in case a sleep fade lowered it
        AmbientBedEngine.shared.setFadeFactor(1)
        if pendingItemStart != nil {
            // An item is still loading: either the smart rewind above crossed a file
            // boundary, or a resume/track-change seek hasn't landed yet. Calling
            // `playImmediately(atRate:)` at a not-yet-ready item is exactly the
            // "starts paused / sits at 0" unreliability the readiness gate exists to
            // avoid, so record the intent instead and let `applyPendingItemStart()`
            // start playback the moment the seek completes. This also covers a user
            // (or the widget/lock screen) hitting play *during* a load that was started
            // with `autoPlay: false`, which used to be silently dropped.
            pendingItemStart?.autoPlay = true
        } else {
            player?.playImmediately(atRate: playbackRate)
        }
        setKeepAwake(true)
        startPeriodicSync()   // run the 30s progress sync only while actually playing
        updateNowPlaying()
    }

    /// Batch 440: applies the Spatial Audio setting to the item that is playing right now
    /// (new items pick it up where they are created). Sets the session's multichannel
    /// flag to match. `allowedAudioSpatializationFormats` isn't key-value observable, so
    /// the property is simply re-set; the session options stay `[]` (Batch 329).
    func refreshSpatialAudio() {
        let enabled = SettingsStore.spatialAudioEnabled
        try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(enabled)
        player?.currentItem?.allowedAudioSpatializationFormats = SpatialAudioStatus.formats(forEnabled: enabled)
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Batch 440: tell the system whether we supply multichannel-capable content (off by default).
        try? session.setSupportsMultichannelContent(SettingsStore.spatialAudioEnabled)
        // Batch 329: Xcode 27's runtime-issue pane flags the synchronous `setActive(true)`
        // on the main thread as a hang risk ("Consider using the asynchronous
        // activate/deactivate API") — activation can block on the audio server. iOS 27
        // adds `activate(options:completionHandler:)`; it returns immediately and
        // `AVPlayer` activates the session itself on `play` anyway, so playback below does
        // not wait on it. Pre-27 keeps the synchronous call.
        if #available(iOS 27, *) {
            session.activate(options: []) { activated, error in
                if let error, !activated {
                    ShelfLog.debug(.playback, "Audio session activation failed: \(error.localizedDescription)")
                }
            }
        } else {
            try? session.setActive(true)
        }
    }

    func pause() {
        resumeAfterInterruption = false   // Review 2 Low (Playback) (30 October 2026): a listener pause wins over a pending interruption resume
        player?.pause()
        isPlaying = false
        // The mirror image of `play()`'s handling (fix 6.A): a pause that arrives while
        // an item is still loading has to cancel that load's pending playback, or the
        // item would start playing by itself the moment it became ready.
        pendingItemStart?.autoPlay = false
        isBuffering = false
        cancelUnexpectedPauseCheck()
        pausedAt = Date()
        setKeepAwake(false)
        // Review 4 Low (quick play-pause): play then an immediate pause after a mixtape would write the clip position.
        let skipRecord = skipPositionWriteOnPause
            || Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync)
        if !skipRecord { resumedFromMixtapeClip = false }
        // Review 2 High 2 (30 October 2026): a mixtape clip position is not the book's position.
        if !skipRecord, let itemId = currentItemId, Self.shouldRecordPosition(suppressed: suppressProgressSync) {
            CloudPositionStore.shared.record(itemId: itemId, currentTime: currentTime, duration: duration, force: true)
        }
        if !skipRecord { syncProgress() }   // one final sync of the current position
        stopPeriodicSync()      // then stop waking every 30s so the app can suspend (saves battery)
        updateNowPlaying()
    }

    /// An interruption's end resumes playback only when the system allows it
    /// (`.shouldResume`) *and* it interrupted something that was playing — the listener's
    /// own pause stays a pause. Pure, for tests.
    nonisolated static func shouldResumeAfterInterruption(wasPlaying: Bool, systemSaysResume: Bool) -> Bool {
        wasPlaying && systemSaysResume
    }

    private func setKeepAwake(_ on: Bool) {
        // Batch 490 (REVIEW 2026-11-11 P2): this service is the one owner of
        // `isIdleTimerDisabled`; Driving Mode's hold is folded in by `applyIdleTimer()`
        // rather than written from the view, so a pause can't let the screen sleep
        // under Driving Mode and closing Driving Mode can't undo the playback setting.
        keepAwakeWhilePlaying = on
        applyIdleTimer()
    }

    /// Batch 490 (REVIEW 2026-11-11 P2): whether playback has asked for the screen to
    /// stay on (`play()` sets it, `pause()`/stop clear it); the setting is read at apply time.
    @ObservationIgnored private var keepAwakeWhilePlaying = false

    /// Batch 490 (REVIEW 2026-11-11 P2): true while Driving Mode is on screen. Driving
    /// Mode is a glanceable dashboard, so it keeps the screen on whatever the "Keep screen
    /// awake" setting says and whether or not audio is playing.
    func setDrivingModeHoldsScreenAwake(_ on: Bool) {
        guard holdsScreenAwakeForDrivingMode != on else { return }
        holdsScreenAwakeForDrivingMode = on
        applyIdleTimer()
    }
    @ObservationIgnored private var holdsScreenAwakeForDrivingMode = false

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = Self.idleTimerDisabled(
            playing: keepAwakeWhilePlaying,
            keepScreenAwakeSetting: SettingsStore.keepScreenAwake,
            drivingModeOnScreen: holdsScreenAwakeForDrivingMode)
    }

    /// Batch 490 (REVIEW 2026-11-11 P2): the one idle-timer decision. Pure, for tests.
    nonisolated static func idleTimerDisabled(playing: Bool, keepScreenAwakeSetting: Bool,
                                              drivingModeOnScreen: Bool) -> Bool {
        drivingModeOnScreen || (playing && keepScreenAwakeSetting)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: Double) {
        guard let session = currentSession,
              let tracks = session.audioTracks, !tracks.isEmpty else { return }

        // ARCH-1: `TrackTimeline.position` always resolves to a track for a non-empty
        // list — including `time == duration` on the last track, which the previous
        // hand-rolled loop's exclusive upper bound (`time < trackStart +
        // trackDuration`) matched to *nothing*, silently no-op'ing the whole function.
        // That's what made skip-forward, "next chapter" (whose fallback is exactly
        // `seek(to: duration)`), and the lock-screen/CarPlay/AirPods equivalents go
        // dead once the user was within one skip interval of the end of a book.
        let timeline = TrackTimeline(tracks: tracks, chapters: session.chapters ?? [])
        let position = timeline.position(atAbsoluteTime: time)
        chapterSkipLastTickTime = time

        if position.trackIndex != currentTrackIndex {
            currentTrackIndex = position.trackIndex
            loadAndPlayTrack(at: position.trackIndex, seekTo: position.offsetInTrack, autoPlay: isPlaying)
        } else {
            // Fix 6.B (REVIEW-2026-09-09.md): if the current item is still loading, the
            // seek below is unreliable (that's why the readiness gate exists) *and*
            // `applyPendingItemStart()` is about to seek to the resume point the track
            // was loaded with — which silently threw away any seek made in this window
            // (scrubber, skip, chapter tap, lock-screen scrub, CarPlay, or the widget's
            // skip buttons). Retargeting the pending start here makes the last position
            // the user asked for the one that actually lands; the raw seek is still
            // issued as well, since it's free and does take effect if the item happens
            // to be ready with only the seek completion outstanding.
            if pendingItemStart != nil {
                pendingItemStart?.seekOffsetInTrack = position.offsetInTrack
                hasReachedResumePosition = false
            }
            let cmTime = CMTime(seconds: position.offsetInTrack, preferredTimescale: 1000)
            // Polish pass (PB-7): frame-accurate seeks are cheap on a local file but force
            // HLS/transcoded streams to fetch and decode from the previous keyframe, so
            // streamed items get the same 1 s tolerance the resume seek uses.
            let isLocalFile = (player?.currentItem?.asset as? AVURLAsset)?.url.isFileURL ?? false
            let tol = CMTime(seconds: Self.seekTolerance(isLocalFile: isLocalFile), preferredTimescale: 600)
            // Forward-only: landing even slightly *before* a chapter boundary would show the
            // previous chapter and make the next ⏭ jump back to the same boundary.
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: tol)
            currentTime = time
            // Without this, the lock screen/Control Centre/CarPlay/AirPods and
            // the widget all keep showing the pre-seek position — they
            // extrapolate from the last-published ElapsedPlaybackTime, which
            // this same-track seek path never used to refresh.
            updateNowPlaying()
        }
    }

    /// Polish pass (PB-7): seek tolerance in seconds. Zero for local files (cheap, and
    /// chapter skips want to land on the boundary); 1 s for streams, matching the resume
    /// seek in `applyPendingItemStart()`. Pure for tests.
    nonisolated static func seekTolerance(isLocalFile: Bool) -> Double { isLocalFile ? 0 : 1 }

    /// Where a skip of `delta` seconds from `current` should land, given a book
    /// duration that may not be known.
    ///
    /// Fix 6.C (REVIEW-2026-09-09.md): `skipForward` used to be a bare
    /// `min(currentTime + amount, duration)`. `duration` is legitimately 0 for a
    /// manifest-built offline session (`DownloadedBook.localSession`) and for a
    /// podcast episode whose duration the server never reported — so a skip-forward
    /// there resolved to `min(anything, 0)` = **0**, seeking the listener back to
    /// 0:00. That position then went straight to the server on the next
    /// `syncProgress()`, so a single tap of the +30s button (or the lock-screen /
    /// CarPlay / AirPods equivalent) destroyed the real position. Same shape as the
    /// `startOffset` fix in `startPlayback` (NEW-9): only clamp against `duration`
    /// when there is a duration to clamp against, and otherwise let
    /// `TrackTimeline.position` and AVPlayer bound the seek — both of which already
    /// cap an over-long offset to the track's own length.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live `AVPlayer` — same
    /// precedent as `shouldRepublishNowPlaying` above.
    nonisolated static func clampedSeekTarget(current: Double, delta: Double, duration: Double) -> Double {
        let raw = current + delta
        if raw <= 0 { return 0 }
        guard duration > 0 else { return raw }
        return min(raw, duration)
    }

    func skipForward(_ seconds: Double? = nil) {
        let amount = seconds ?? skipForwardInterval
        seek(to: Self.clampedSeekTarget(current: currentTime, delta: amount, duration: duration))
    }

    func skipBackward(_ seconds: Double? = nil) {
        let amount = seconds ?? skipBackwardInterval
        seek(to: Self.clampedSeekTarget(current: currentTime, delta: -amount, duration: duration))
    }

    /// Re-read skip intervals from settings and update the lock-screen controls.
    func refreshSkipIntervals() {
        skipForwardInterval = SettingsStore.skipForwardInterval
        skipBackwardInterval = SettingsStore.skipBackwardInterval
        // Batch 327: harmless either way (nothing is listening to these commands on a
        // session-backend launch), but gated to keep the either/or clean — on iOS 27
        // the intervals reach the system through `NowPlayingSessionModel.commands`,
        // which re-reads `SettingsStore` every time the framework recomputes them.
        guard NowPlayingSessionBridge.backend == .classic else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
    }

    // MARK: - Chapter Navigation

    func skipToNextChapter() {
        guard let chapters = currentSession?.chapters, !chapters.isEmpty else {
            skipForward()
            return
        }
        // Review Medium 14 (30 October 2026): on the last chapter the lock screen's ⏭ used to
        // run to the end of the book, which can mark it finished and start Up Next.
        guard PlayerViewModel.hasNextChapter(chapters: chapters, currentTime: currentTime) else { return }
        if let target = Self.nextChapterTarget(chapters: chapters, currentTime: currentTime, duration: duration) {
            seek(to: target)
        }
    }

    func skipToPreviousChapter() {
        guard let chapters = currentSession?.chapters, !chapters.isEmpty else {
            skipBackward()
            return
        }
        seek(to: Self.previousChapterTarget(chapters: chapters, currentTime: currentTime))
    }

    /// Where "next chapter" lands from `currentTime`: the next chapter's start, else the end
    /// of the book, else `nil` (nowhere ahead to go). Pure so the lock-screen path above and
    /// `PlayerViewModel.nextChapter()` (which needs the target up front to offer "Jump back")
    /// agree by construction. Pinned by `ChapterSkipTargetTests`.
    ///
    /// Fix 6.C: `seek(to: duration)` — "there's no next chapter, so run to the end of the
    /// book" — is `seek(to: 0)` when `duration` is unknown (an offline manifest session, a
    /// podcast episode), throwing the listener back to the very start and syncing that. The
    /// last chapter's own `end` is the best available stand-in for the end of the book in
    /// that case; if even that isn't ahead of where we already are, there is nowhere to skip
    /// to and doing nothing is the honest answer.
    nonisolated static func nextChapterTarget(chapters: [Chapter], currentTime: Double, duration: Double) -> Double? {
        guard !chapters.isEmpty else { return nil }
        if let next = chapters.first(where: { $0.start > currentTime + 0.5 }) {
            return next.start
        }
        let endOfBook = duration > 0 ? duration : (chapters.last?.end ?? 0)
        return endOfBook > currentTime ? endOfBook : nil
    }

    /// Where "previous chapter" lands from `currentTime`: more than 3s into a chapter
    /// restarts it, otherwise the previous chapter's start, otherwise 0. Pure for the same
    /// reason as `nextChapterTarget`. Callers handle an empty chapter list themselves.
    nonisolated static func previousChapterTarget(chapters: [Chapter], currentTime: Double) -> Double {
        let currentStart = chapters.last(where: { $0.start <= currentTime })?.start ?? 0
        if currentTime - currentStart > 3 {
            return currentStart
        } else if let prev = chapters.last(where: { $0.start < currentStart - 0.5 }) {
            return prev.start
        } else {
            return 0
        }
    }

    /// Batch 399: where a timed chapter skip (`ChapterSkip`) should jump on this tick, or
    /// nil for "carry on". Pure so it's testable without a live player; pinned by
    /// `ChapterSkipDecisionTests`.
    ///
    /// Only ordinary playback triggers it: `previousTime` is the last tick's position (or,
    /// after any `seek(to:)`, the seek target), and the step to `currentTime` must be a
    /// short forward one. So a chapter-list tap, a scrub, "previous chapter" or the
    /// jump-back pill landing inside a trimmed region is left alone — those are the
    /// listener choosing to be there.
    /// - Start: playback has just crossed into a chapter and is still inside its first
    ///   `skip.start` seconds → jump to `start + skip.start`.
    /// - End: playback has just crossed `skip.end` seconds before a chapter's end → jump to
    ///   the next chapter, landing past its own start trim. Never on the last chapter, so
    ///   this can't run a book to its end and mark it finished early.
    /// A chapter too short to keep `minimumKept` seconds after both trims isn't trimmed.
    nonisolated static func chapterSkipTarget(
        chapters: [Chapter], previousTime: Double?, currentTime: Double,
        skip: ChapterSkip, maxStep: Double = 2.0, minimumKept: Double = 10
    ) -> Double? {
        guard skip.isActive, let previousTime,
              currentTime >= previousTime, currentTime - previousTime <= maxStep,
              let index = chapters.firstIndex(where: { currentTime >= $0.start && currentTime < $0.end })
        else { return nil }

        let startTrim = Double(skip.start), endTrim = Double(skip.end)
        func trimmable(_ chapter: Chapter) -> Bool {
            chapter.end - chapter.start >= startTrim + endTrim + minimumKept
        }
        let chapter = chapters[index]
        guard trimmable(chapter) else { return nil }

        if startTrim > 0, previousTime < chapter.start, currentTime < chapter.start + startTrim {
            return chapter.start + startTrim
        }

        let threshold = chapter.end - endTrim
        if endTrim > 0, index + 1 < chapters.count,
           previousTime < threshold, currentTime >= threshold {
            let next = chapters[index + 1]
            // A hair past the boundary when not trimming, as the title skip does, so
            // observer slop can't resolve the landing back into this chapter.
            return next.start + (startTrim > 0 && trimmable(next) ? startTrim : 0.05)
        }
        return nil
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
        updateNowPlaying()
    }

    func stop() {
        // Order matters: `syncProgress()` reports (and zeroes) whatever listening time
        // has accumulated since the last sync, so `closeSession()` — called
        // immediately after — correctly has nothing left to add. Do NOT "fix" this by
        // reordering or having both report the same non-zero value: the two calls hit
        // different server endpoints (session sync vs. session close), and if both are
        // additive server-side, reporting the same increment twice would double-count
        // the user's listening time.
        // Review 2 High 2 (30 October 2026): same guard as `pause()`.
        // Review 7 Medium 1: nor within 5 s of a post-mixtape play (syncProgress/closeSession carry the same guard).
        if let itemId = currentItemId, Self.shouldRecordPosition(suppressed: suppressProgressSync),
           !Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync) {
            CloudPositionStore.shared.record(itemId: itemId, currentTime: currentTime, duration: duration, force: true)
        }
        syncProgress()
        closeSession()
        streamLostNoticeShown = false   // Batch 495 (P4)
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()
        stopPeriodicSync()
        cancelSleepTimer()
        sleepArmAnchor = nil       // Batch 490 (REVIEW 2026-11-11 F20)
        sleepResumeOffer = nil
        setKeepAwake(false)
        statusObservation?.invalidate()
        statusObservation = nil
        // `timeControlObservation` deliberately survives: it's attached to the AVPlayer
        // (which this function keeps, emptied, for the next book) rather than to an
        // item, and re-attaching it per session would leak one observation per stop.
        cancelUnexpectedPauseCheck()
        pendingItemStart = nil
        pendingStartSeekAttempts = 0
        isBuffering = false
        hasReachedResumePosition = true
        pausedAt = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSession = nil
        currentItemId = nil
        nowPlayingArtwork = nil
        nowPlayingCoverData = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Nothing is published any more, so the "last published chapter" record has to
        // go with it — otherwise a stale id survives a stop and the next session's
        // first boundary check could compare against a chapter from the old book.
        lastPublishedChapterId = nil
        SharedPlayback.write(nil)
        SharedPlayback.writeCover(nil)
        WidgetCenter.shared.reloadAllTimelines()
        lastPublishedControlState = nil
        reloadControlCenterControls()
        playbackActivity?.invalidate()
        playbackActivity = nil
        // Batch 329: asynchronous on iOS 27 for the same main-thread reason as
        // `activateAudioSession()`; the option keeps its meaning (`AVAudioSession
        // .DeactivationOptions.notifyOthersOnDeactivation`).
        if #available(iOS 27, *) {
            AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Sleep Timer

    /// `allowSnap` exists so `extendSleepTimer` (the "+15m" action) can convert a
    /// chapter-based timer to a concrete minutes timer without immediately re-snapping
    /// it — with short chapters there's almost always another boundary within the
    /// window, so "+15m" could otherwise land anywhere in the snap window of the
    /// intended extension, occasionally landing very close to where it already was and
    /// making the button look broken.
    func setSleepTimer(_ option: SleepTimerOption, allowSnap: Bool = true) {
        // Batch 490 (REVIEW 2026-11-11 F20): where the listener was when they armed a
        // timer. Kept through extend / reset / "+1 chapter" (the timer was never off);
        // re-taken when arming from off or on another book; dropped when it ends up off.
        let wasOff = sleepTimerOption == .off
        cancelSleepTimer()
        defer {
            if sleepTimerOption == .off {
                sleepArmAnchor = nil
            } else if wasOff || sleepArmAnchor?.itemId != currentItemId, let itemId = currentItemId {
                sleepArmAnchor = (itemId, currentTime)
            }
        }
        defer { publishControlState() }
        // Batch 406: the one Live Activity hook. Every arm path (manual, smart snap,
        // "+15" on a chapter timer, shake-to-reset, Undo, bedtime auto-arm, Control
        // Center) comes through here; the controller observes the rest from this
        // service's own state (ticks, extend, pause, speed, the timer firing, `stop()`).
        defer { LiveActivityController.shared.observeSleepTimer(of: self) }
        sleepTimerOption = option

        switch option {
        case .off:
            sleepTimerRemaining = 0
        case .minutes(let mins):
            // F2 "smart" sleep timer: if the raw target would land within a few minutes
            // of a chapter boundary, snap to that boundary instead of cutting off
            // mid-sentence. Reuses the same absolute-time-target mechanism as
            // .endOfChapter/.chapters (driven by the time observer, see
            // `updateCurrentTime`), rather than the ticking countdown `Timer` below.
            let rawTarget = currentTime + Double(mins * 60)
            // The window is proportional (20% of the requested duration), capped at
            // `smartSleepSnapWindow`. A flat 3-minute window is reasonable for a
            // 30-minute timer but not for the short presets (5/10 min) — a "5 min"
            // timer landing 2:10 into the window would be 43% shorter than requested
            // with nothing in the UI explaining why, and non-fiction chapters in the
            // 4-6 minute range make that the common case, not the edge case.
            let snapWindow = min(Self.smartSleepSnapWindow, Double(mins * 60) * 0.20)
            if allowSnap, SettingsStore.smartSleepTimer,
               let snapped = nearbyChapterEnd(near: rawTarget, window: snapWindow) {
                sleepTargetTime = snapped
                sleepTimerRemaining = max(snapped - currentTime, 0)
            } else {
                sleepTargetTime = nil
                sleepTimerRemaining = TimeInterval(mins * 60)
                sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.isPlaying else { return }   // don't tick down or fade while paused
                        self.sleepTimerRemaining -= 1
                        self.applySleepFade()
                        if self.sleepTimerRemaining <= 0 {
                            self.pause()
                            self.noteSleepTimerFired()
                            self.cancelSleepTimer()
                            self.publishControlState()
                        }
                    }
                }
            }
        case .endOfChapter:
            // Pause at the end of the current chapter (handled in the time observer).
            guard armChapterSleepTimer(additional: 0) else { return }
        case .chapters(let n):
            // Pause after the current chapter plus n more.
            guard armChapterSleepTimer(additional: n) else { return }
        case .endOfBook:
            // Fires when the book finishes (handled in moveToNextTrack); no countdown.
            sleepAtEndOfBook = true
            sleepTimerRemaining = -1
        }
    }

    /// Re-arms the active sleep timer from the current moment ("shake to reset").
    /// Minutes restart their full countdown; chapter timers recompute from here.
    func resetSleepTimer() {
        guard sleepTimerOption != .off else { return }
        setSleepTimer(sleepTimerOption)
    }

    /// Arms a chapter-based sleep timer (`.endOfChapter` / `.chapters(n)`) against the
    /// current position. Returns false — leaving the timer **off** rather than armed —
    /// when there's no chapter boundary ahead to stop at.
    ///
    /// Fix 6.F (REVIEW-2026-09-09.md): the target used to come from a
    /// `firstIndex(where:) ?? 0` fallback, so whenever `currentTime` fell outside every
    /// chapter's `[start, end)` range — a gap between chapters, or anywhere past the
    /// last chapter's end, which for a book whose chapter list doesn't quite cover its
    /// runtime is the ordinary state at the end of a listen — it armed against chapter
    /// **0's** end. That target is in the past, so `updateCurrentTime`'s
    /// `sleepTimerRemaining <= 0.5` check fired on the very next tick and playback
    /// paused within half a second of the user choosing "End of chapter". Reporting
    /// "couldn't arm" is strictly better than a timer that stops the book immediately.
    private func armChapterSleepTimer(additional: Int) -> Bool {
        guard let target = Self.chapterSleepTarget(
            chapters: currentSession?.chapters ?? [], currentTime: currentTime,
            extraChapters: additional
        ) else {
            // `setSleepTimer` has already called `cancelSleepTimer()` and set
            // `sleepTimerOption`, so undo just that: everything else is already clear.
            sleepTimerOption = .off
            sleepTimerRemaining = 0
            sleepTargetTime = nil
            ShelfLog.info(.playback, "Chapter sleep timer not armed: no chapter boundary ahead")
            return false
        }
        sleepTargetTime = target
        sleepTimerRemaining = max(target - currentTime, 0)
        return true
    }

    /// End time of the chapter `extraChapters` chapters after the one containing
    /// `currentTime` (clamped to the last chapter). Nil when there's nothing ahead to
    /// stop at — no chapter data at all, or a position at/past the last chapter's end.
    ///
    /// When `currentTime` falls in a gap *between* chapters (or before the first one)
    /// this counts from the next chapter that still ends ahead of us, so "end of
    /// chapter" chosen from inside a gap stops at the end of the chapter the listener
    /// is about to hear rather than refusing to arm.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live session — same
    /// precedent as `shouldRepublishNowPlaying` / `clampedSeekTarget` above.
    nonisolated static func chapterSleepTarget(
        chapters: [Chapter], currentTime: Double, extraChapters: Int
    ) -> Double? {
        guard !chapters.isEmpty else { return nil }
        let extra = max(extraChapters, 0)
        let baseIndex: Int
        if let containing = chapters.firstIndex(where: { currentTime >= $0.start && currentTime < $0.end }) {
            baseIndex = containing
        } else if let next = chapters.indices.first(where: { chapters[$0].end > currentTime }) {
            baseIndex = next
        } else {
            return nil   // past the end of the last chapter: nothing ahead to stop at
        }
        let targetIndex = min(baseIndex + extra, chapters.count - 1)
        let end = chapters[targetIndex].end
        // A non-monotonic/overlapping chapter list could still hand back an end that
        // isn't actually ahead of us; treat that as "can't arm" rather than as a target
        // in the past, which is the whole point of this function.
        return end > currentTime ? end : nil
    }

    /// Upper bound on how close a raw sleep-timer target has to land to a chapter
    /// boundary for the "smart" timer to snap to it (F2) — the actual window used is
    /// `min(this, 20% of the requested duration)`, see `setSleepTimer`. 3 minutes is
    /// the right ceiling for a 30-minute-or-longer timer: close enough to be clearly
    /// "meant" for that boundary, not so wide that it effectively becomes a 27- or
    /// 33-minute timer.
    private static let smartSleepSnapWindow: TimeInterval = 3 * 60

    /// Item 26 (REVIEW-2026-09-09-REMAINING.md): boundaries within this many seconds of
    /// "now" are treated as already passed rather than nearby. Without this, a chapter
    /// end exactly at (or a hair past, from tick/rounding timing) `currentTime` could be
    /// picked as the "nearest" snap target and then read as already-elapsed on the very
    /// next tick — the same class of bug fix 6.F fixed for `chapterSleepTarget` above
    /// (`end > currentTime`, not `>=`). Matches the `<= 0.5` "has the timer arrived"
    /// threshold `updateCurrentTime` already uses to decide a sleep timer has reached its
    /// target, so both places agree on how close counts as "there".
    // `nonisolated`: read as the default argument of the `nonisolated static`
    // `nearestUpcomingChapterEnd` below; without it the compiler warns (error in Swift 6)
    // about a main-actor-isolated static being referenced from a nonisolated context.
    private nonisolated static let chapterBoundaryEpsilon: TimeInterval = 0.5

    /// The chapter end closest to `target`, if one falls within `window` and isn't
    /// already in the past (or near enough to it to count as passed — see
    /// `chapterBoundaryEpsilon`). Nil if there's no chapter data or nothing nearby.
    private func nearbyChapterEnd(near target: Double, window: TimeInterval) -> Double? {
        guard let chapters = currentSession?.chapters, !chapters.isEmpty else { return nil }
        return Self.nearestUpcomingChapterEnd(
            chapterEnds: chapters.map(\.end), currentTime: currentTime, target: target, window: window)
    }

    /// Pure half of `nearbyChapterEnd(near:window:)` — no session/instance state, so it's
    /// unit-testable without a live player. Same precedent as `chapterSleepTarget`/
    /// `shouldRepublishNowPlaying` above.
    nonisolated static func nearestUpcomingChapterEnd(
        chapterEnds: [Double], currentTime: Double, target: Double, window: TimeInterval,
        epsilon: TimeInterval = AudioPlayerService.chapterBoundaryEpsilon
    ) -> Double? {
        let candidates = chapterEnds.filter { $0 > currentTime + epsilon }
        guard let best = candidates.min(by: { abs($0 - target) < abs($1 - target) }) else { return nil }
        return abs(best - target) <= window ? best : nil
    }

    /// Adds time to a running countdown timer (the "+15m" action). No-op for
    /// end-of-chapter or when no timer is active. Restores full volume in case a
    /// fade-out had already begun.
    func extendSleepTimer(by seconds: TimeInterval) {
        guard sleepTimerRemaining > 0 else { return }
        if sleepTargetTime != nil {
            // Chapter-based timer has no ticking countdown, so convert it to a concrete
            // minutes timer (otherwise "+15m" did nothing and it still stopped at the
            // chapter boundary). `allowSnap: false` so this doesn't immediately re-snap
            // to a nearby chapter boundary — with short chapters there's almost always
            // one within the window, which could otherwise land the extension anywhere
            // in that range, occasionally right back near where it already was.
            setSleepTimer(.minutes(max(1, Int(((sleepTimerRemaining + seconds) / 60).rounded()))), allowSnap: false)
        } else {
            sleepTimerRemaining += seconds
            sleepTimerOption = .minutes(Int((sleepTimerRemaining / 60).rounded()))
            player?.volume = 1
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 F20): the chip's "+1 chapter" for an end-of-chapter or
    /// +N chapters timer — moves the stop one chapter boundary further on, counted from the
    /// boundary it was already heading for (re-arming `.chapters(n + 1)` from "now" would
    /// overshoot once playback has crossed into a later chapter). Restores full volume in
    /// case the fade had begun. No-op when there's no later boundary.
    func extendSleepTimerByOneChapter() {
        guard let current = sleepTargetTime,
              let option = Self.optionAfterAddingChapter(sleepTimerOption),
              let next = Self.nextChapterSleepTarget(chapters: currentSession?.chapters ?? [],
                                                     currentTarget: current) else { return }
        sleepTargetTime = next
        sleepTimerRemaining = max(next - currentTime, 0)
        sleepTimerOption = option
        player?.volume = 1
        AmbientBedEngine.shared.setFadeFactor(1)
        publishControlState()
    }

    /// The end of the first chapter that ends after `currentTarget`, or nil. Pure.
    nonisolated static func nextChapterSleepTarget(chapters: [Chapter], currentTarget: Double) -> Double? {
        chapters.map { $0.end }.filter { $0 > currentTarget + 0.5 }.min()
    }

    /// `.endOfChapter` → `.chapters(1)`, `.chapters(n)` → `.chapters(n + 1)`; nil for the
    /// timers "+1 chapter" doesn't apply to. Pure.
    nonisolated static func optionAfterAddingChapter(_ option: SleepTimerOption) -> SleepTimerOption? {
        switch option {
        case .endOfChapter: return .chapters(1)
        case .chapters(let n): return .chapters(n + 1)
        default: return nil
        }
    }

    /// Puts back a timer the listener just turned off from the player's sleep chip (the
    /// "Undo" offer, `PlayerViewModel.undoSleepTimerOff()`). A countdown resumes with its
    /// exact remaining seconds as a plain countdown (`allowSnap: false`, so it doesn't jump
    /// to a different chapter boundary than the one it was heading for); chapter and
    /// end-of-book timers re-arm from the current position, which a moment after cancelling
    /// is the same target they had.
    func restoreSleepTimer(_ option: SleepTimerOption, remaining: TimeInterval) {
        switch option {
        case .off:
            return
        case .minutes:
            setSleepTimer(option, allowSnap: false)
            if remaining > 0 {
                sleepTimerRemaining = remaining
                publishControlState()
            }
        default:
            setSleepTimer(option)
        }
    }

    /// Call after changing any audio-processing setting (volume boost, bass/treble, Clearer voices,
    /// Even volume, or a Listening Profile applying them). Takes effect on the playing track at once:
    /// an attached tap just re-reads the settings; if none is attached yet, one is attached to the
    /// current item by setting its `audioMix`; if nothing needs processing any more, the mix is
    /// removed so the track returns to the efficient path.
    ///
    /// Batch 438, Apple docs checked with `scripts/appledoc.sh`: `AVPlayerItem.audioMix` is a
    /// settable property ("The audio mix parameters to be applied during playback"); its page says
    /// only that a mix works with file-based media, not HTTP Live Streaming, and says nothing that
    /// forbids assigning it while the item plays. That is what this relies on (ABS serves direct
    /// files, not HLS). The tap itself is created before the mix is assigned. Not yet confirmed
    /// on a device that a mid-playback assignment is gapless: [device check].
    func refreshAudioProcessing() {
        if SettingsStore.audioProcessingNeeded {
            if let context = audioTapContext {
                context.refreshFromSettings()
            } else if let item = player?.currentItem {
                attachAudioProcessing(to: item, asset: item.asset, trackIndex: nil)
            }
        } else if audioTapContext != nil {
            audioTapContext = nil
            player?.currentItem?.audioMix = nil
        }
    }

    /// Creates the tap context for `item` and attaches the mix shortly after (track loading is
    /// async). Does nothing, and clears any stale context, when no processing is needed.
    private func attachAudioProcessing(to item: AVPlayerItem, asset: AVAsset, trackIndex: Int?) {
        guard SettingsStore.audioProcessingNeeded else {
            audioTapContext = nil
            return
        }
        let context = AudioTapContext()
        context.refreshFromSettings()
        audioTapContext = context
        seedLoudness(for: context, trackIndex: trackIndex)
        Task { @MainActor [weak self] in
            guard let mix = await AudioProcessingChain.makeAudioMix(for: asset, context: context) else { return }
            guard self?.audioTapContext === context, self?.player?.currentItem === item else { return }
            item.audioMix = mix
        }
    }

    /// Batch 438: starts the leveller from the book's cached loudness; if the book is downloaded and
    /// not measured yet, measures its first minutes in the background for next time.
    private func seedLoudness(for context: AudioTapContext, trackIndex: Int?) {
        guard SettingsStore.matchLoudness, let itemId = currentItemId else { return }
        if let cached = LoudnessCache.shared.loudness(forItem: itemId) {
            context.seedLoudness(cached)
            return
        }
        let index = trackIndex ?? currentTrackIndex
        if let file = DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: index) {
            Task.detached(priority: .utility) {
                await LoudnessCache.shared.ensureMeasured(itemId: itemId, fileURL: file)
            }
        }
    }

    /// Auto-arms a countdown sleep timer when a fresh playback session starts inside the
    /// user's configured "bedtime window" (see `SettingsStore.scheduledSleepTimer*`) —
    /// distinct from the countdown/end-of-chapter timers set manually from the player.
    /// Called once per fresh `startPlayback`, not on every resume/tick, so it never
    /// overrides a timer the user set (or cleared) themselves mid-session, and never
    /// re-arms itself repeatedly while already running.
    private func applyScheduledSleepTimerIfNeeded() {
        guard SettingsStore.scheduledSleepTimerEnabled, sleepTimerOption == .off else { return }
        if let suppressedUntil = SettingsStore.scheduledSleepTimerSuppressedUntil {
            guard suppressedUntil <= Date() else { return }   // still within a "skip tonight" window
            SettingsStore.clearScheduledSleepTimerSuppression()   // expired — clear so it doesn't linger
        }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let hour = now.hour, let minute = now.minute,
              SettingsStore.isWithinScheduledSleepWindow(hour: hour, minute: minute) else { return }
        setSleepTimer(.minutes(SettingsStore.scheduledSleepTimerDurationMinutes))
    }

    /// "Skip tonight" — lets the scheduled sleep timer stay on as a standing preference
    /// without a trip to Settings every time a longer session is wanted once. See
    /// `SettingsStore.suppressScheduledSleepTimerForTonight`.
    func skipScheduledSleepTimerTonight() {
        SettingsStore.suppressScheduledSleepTimerForTonight()
    }

    // MARK: Batch 490 (REVIEW 2026-11-11 F20): "Jump back" to where the timer was set

    /// Item and position when the current sleep timer was armed (see `setSleepTimer`).
    @ObservationIgnored private var sleepArmAnchor: (itemId: String, time: Double)?
    /// Set when a timer fires; offered once, at the next resume of the same book.
    @ObservationIgnored private var sleepResumeOffer: (itemId: String, time: Double)?
    /// Called by `play()` with (item id, armed position) when the listener resumes a book
    /// whose sleep timer stopped it and they're well past where they set it. The player
    /// offers a "Jump back" chip; nothing here ever seeks.
    @ObservationIgnored var onSleepResumeOffer: ((String, Double) -> Void)?

    /// A sleep timer has just stopped playback: remember where it was armed. End-of-book
    /// timers don't call this — finishing the book is not a place to jump back from.
    private func noteSleepTimerFired() {
        sleepResumeOffer = sleepArmAnchor
        sleepArmAnchor = nil
    }

    /// Played past the armed position by at least this much before the offer is worth
    /// making; under it, smart rewind and the skip buttons already cover the gap.
    nonisolated static let sleepJumpBackMinimum: TimeInterval = 180

    /// Pure, for tests: the position to offer, or nil.
    nonisolated static func sleepJumpBackTarget(armedAt: Double, armedItemId: String,
                                                resumeAt: Double, currentItemId: String?) -> Double? {
        guard armedItemId == currentItemId, resumeAt - armedAt >= sleepJumpBackMinimum else { return nil }
        return armedAt
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerOption = .off
        sleepTimerRemaining = 0
        sleepTargetTime = nil
        sleepAtEndOfBook = false
        player?.volume = 1   // undo any sleep fade
        AmbientBedEngine.shared.setFadeFactor(1)
    }

    /// Gradually lowers volume in the final seconds before the sleep timer fires.
    private func applySleepFade() {
        guard SettingsStore.sleepFadeOut else {
            AmbientBedEngine.shared.setFadeFactor(1)
            return
        }
        let window: TimeInterval = 20
        if sleepTimerRemaining > 0 && sleepTimerRemaining <= window {
            player?.volume = Float(sleepTimerRemaining / window)
            AmbientBedEngine.shared.setFadeFactor(Float(sleepTimerRemaining / window))   // Batch 439
        } else {
            player?.volume = 1
            AmbientBedEngine.shared.setFadeFactor(1)
        }
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        // `addPeriodicTimeObserver`'s closure type isn't proven main-actor-isolated by
        // the compiler even though we pass `queue: .main` — Swift 6 can't see through
        // `DispatchQueue` scheduling the way it can `Task { @MainActor in }`.
        //
        // Bug fix (17 Aug 2026): this used to hop via `Task { @MainActor in ... }`,
        // which — unlike a plain main-queue dispatch — doesn't run synchronously; it
        // enqueues onto the cooperative executor and runs on a *later* run-loop turn.
        // This fires every 0.5s of book time (so every 0.25s of wall-clock time at 2x
        // speed), and the scrubber's displayed position is driven straight off
        // `currentTime`, so that extra scheduling hop showed up as visible stutter/lag
        // in the scrubber — the "glitchy" feel reported after CRIT-3. `queue: .main`
        // already *guarantees* AVFoundation calls this closure synchronously on the
        // main thread, so `MainActor.assumeIsolated` (assert-and-run-synchronously,
        // rather than Task's enqueue-and-run-later) is the correct tool here: it
        // satisfies the same Swift 6 concurrency check without reintroducing the hop.
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.updateCurrentTime(time)
            }
        }
    }

    private func updateCurrentTime(_ cmTime: CMTime) {
        guard let tracks = currentSession?.audioTracks,
              currentTrackIndex < tracks.count else { return }

        // While resuming, ignore the player's pre-seek position (0) so we don't flash
        // back to the start before the seek to the resume point has landed.
        guard hasReachedResumePosition else { return }

        let trackTime = cmTime.seconds
        let trackStart = tracks[currentTrackIndex].startOffset ?? 0
        currentTime = trackStart + trackTime
        // `addPeriodicTimeObserver(forInterval:)`'s interval is on the player's media
        // timeline, not wall-clock time — at 2x speed the observer fires every 0.5s of
        // *book* time, which is only ~0.25s of real elapsed time. Audiobookshelf's
        // "time listened" stat (streaks, year-in-review) is wall-clock listening time,
        // so dividing by rate (not multiplying) is what makes this correct at every
        // speed: 0.5s of book time took 0.5/rate seconds of the user's actual time.
        // Review 5 Medium 2: clip listening isn't the book's listening time.
        if !suppressProgressSync { timeListenedSinceSync += 0.5 / Double(playbackRate) }
        // Review 7 Medium 1: real listening since the post-mixtape play ends the clip-position guard
        // (periodic syncs zero the counter, so it must clear before they can).
        if Self.shouldClearMixtapeResume(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync) {
            resumedFromMixtapeClip = false
        }
        // Batch 422: how far the listener has actually heard (spoiler bound for transcript
        // features). Only while playing, so a scrub ahead doesn't count; writes every 10 s.
        if isPlaying, let itemId = currentItemId {
            TranscriptionCenter.shared.noteListeningPosition(itemId: itemId, time: currentTime)
        }

        // Keep the App Group snapshot's `updatedAt` fresh during long uninterrupted
        // playback (no seeks/pauses to otherwise trigger a write). The widget uses
        // staleness here to detect "the app that would be updating this was closed" —
        // without this periodic touch, a snapshot written once at track-start would
        // look just as stale during totally normal, still-playing 20-minute chapters
        // as it does after the app was actually force-quit, and the widget couldn't
        // tell the difference. Deliberately NOT calling reloadWidgetsThrottled() here:
        // the widget's own pre-generated timeline entries already extrapolate progress
        // forward without needing a reload (see M1); this is only about keeping the
        // freshness timestamp honest.
        if isPlaying, Date().timeIntervalSince(lastSharedPlaybackTouchAt) >= 20 {
            lastSharedPlaybackTouchAt = Date()
            writeSharedPlaybackSnapshot()
        }

        // Sustained playback clears the stream-recovery counter so a later token
        // expiry can recover again (without allowing a tight fail/reload loop).
        if streamRecoveryAttempts > 0, let last = lastStreamRecoveryAt,
           Date().timeIntervalSince(last) > 60 {
            streamRecoveryAttempts = 0
        }

        // Fire the near-end hook once so the next queued book can be prefetched.
        // Review 6 Low (near end): a mixtape clip's end isn't the book's end.
        if !suppressProgressSync, !hasFiredNearEnd, duration > 0, (duration - currentTime) <= 20 {
            hasFiredNearEnd = true
            onNearEnd?()
        }

        // Light haptic when the chapter boundary is crossed during playback. Only on a
        // real transition (not the first chapter of a book), and gated by the setting.
        if isPlaying, SettingsStore.chapterHapticsEnabled {
            let chapterId = currentChapter?.id
            if let chapterId, let last = lastHapticChapterId, chapterId != last {
                Haptics.impact(.light)
            }
            lastHapticChapterId = chapterId
        }

        // Auto-skip publisher intro/outro chapters ("Opening Credits", "Also by this
        // author", etc. — see `Chapter.looksLikeIntroOrOutro`). Off by default (see
        // `SettingsStore.autoSkipIntroOutroEnabled`). Guarded by `lastAutoSkippedChapterId`
        // so this only fires once per chapter per playthrough — without it, seeking
        // backward into an already-skipped chapter (e.g. from the chapter list, or the
        // jump-back pill) would immediately bounce forward again.
        //
        // Batch 399: a book with timed chapter trims (`ChapterSkip`, its own or the
        // global default) uses those *instead* of title matching — the two would
        // otherwise fight over the same boundaries.
        let chapterSkip = currentItemId.map { SettingsStore.resolvedChapterSkip(forItem: $0) } ?? .off
        let previousSkipTickTime = chapterSkipLastTickTime
        chapterSkipLastTickTime = currentTime
        if isPlaying, chapterSkip.isActive,
           let target = Self.chapterSkipTarget(chapters: chapters, previousTime: previousSkipTickTime,
                                               currentTime: currentTime, skip: chapterSkip) {
            // An "end of chapter" sleep timer means the end the listener actually
            // hears: stop here rather than jump into the next chapter and then pause.
            if let sleepTarget = sleepTargetTime, sleepTarget <= (currentChapter?.end ?? 0) + 0.5,
               target > sleepTarget {
                pause()
                noteSleepTimerFired()
                cancelSleepTimer()
                publishControlState()
                return
            }
            seek(to: target)
        } else if isPlaying, !chapterSkip.isActive, SettingsStore.autoSkipIntroOutroEnabled,
           let chapter = currentChapter, chapter.looksLikeIntroOrOutro,
           chapter.id != lastAutoSkippedChapterId {
            lastAutoSkippedChapterId = chapter.id
            // A hair past the boundary rather than exactly on it, so this doesn't land
            // back on the same chapter due to floating-point/observer-interval slop.
            seek(to: chapter.end + 0.05)
        }

        // Republish Now Playing when playback has simply crossed a chapter boundary —
        // the fix for "CarPlay/lock screen sticks at 0:00 remaining with a full bar
        // until I stop/start or skip" (see `shouldRepublishNowPlaying`). Placed AFTER
        // the auto-skip block on purpose: that block's `seek(to:)` already republishes
        // for the chapter it lands in, so by the time we get here there's nothing owed
        // and we don't write MPNowPlayingInfoCenter twice in the same tick.
        //
        // Cheap on the tick: an `Int?` comparison against the last published id, so
        // this is a no-op on all but the single tick that crosses a boundary — it is
        // NOT gated on `isPlaying` or on any setting, because the staleness is just as
        // visible if a boundary is crossed by something other than ordinary playback.
        //
        // `updateNowPlaying()` also fires `writeSharedPlaybackSnapshot()`,
        // `reloadWidgetsThrottled()` and `updateHandoffActivity()`. All three are fine
        // to run here: a chapter boundary is a genuinely meaningful moment for all of
        // them (the widget/Handoff position really did move on), it happens once per
        // chapter rather than per tick, and the widget reload is coalesced to at most
        // once every 5s by `reloadWidgetsThrottled()` regardless.
        if Self.shouldRepublishNowPlaying(
            lastPublishedChapterId: lastPublishedChapterId,
            currentChapterId: currentChapter?.id
        ) {
            updateNowPlaying()
        }

        // Chapter-based sleep timer (end of chapter, or +N chapters): pause when we
        // reach the precomputed target time.
        if let target = sleepTargetTime {
            sleepTimerRemaining = target - currentTime
            applySleepFade()
            if sleepTimerRemaining <= 0.5 {
                pause()
                noteSleepTimerFired()
                cancelSleepTimer()
                publishControlState()
            }
        }

        // Safety net only: the real advance happens on AVPlayerItem.didPlayToEndTime (see
        // setupNotifications), so we never cut a track short. This fallback catches the rare
        // case where that notification doesn't arrive — it uses no early margin (>= duration)
        // so it can't clip, and the isAdvancingTrack guard prevents a double advance/skip.
        if !isAdvancingTrack,
           let trackDuration = tracks[currentTrackIndex].duration,
           trackDuration > 0, trackTime >= trackDuration {
            isAdvancingTrack = true
            DispatchQueue.main.async { [weak self] in self?.moveToNextTrack() }
        }
    }

    private func moveToNextTrack() {
        guard let tracks = currentSession?.audioTracks else { return }
        let nextIndex = currentTrackIndex + 1

        if nextIndex < tracks.count {
            let wasPlaying = isPlaying
            currentTrackIndex = nextIndex
            loadAndPlayTrack(at: nextIndex, autoPlay: wasPlaying)
        } else {
            // Finished all tracks
            // Review 5 Medium 3: a mixtape clip ending at the book's end isn't the listener finishing it.
            if Self.shouldTreatEndAsBookFinished(suppressed: suppressProgressSync) == false {
                isAdvancingTrack = false   // Review 6 High 1: don't leave the advance guard stuck
                pause()
                return
            }
            pause()
            syncProgress()
            // Deterministically mark the book finished rather than relying on the
            // server's completion threshold.
            recordFinishedProgress()
            // Don't offer this book for resume on next launch — it's complete.
            SharedPlayback.write(nil)
            if sleepAtEndOfBook {
                // "End of book" sleep timer: stop here, do NOT roll into Up Next.
                cancelSleepTimer()
                publishControlState()
            } else {
                // Let the queue (if any) advance to the next book.
                onPlaybackFinished?()
            }
        }
    }

    /// Where an explicit, out-of-band "mark finished" call originated. Distinct from
    /// natural end-of-book completion (`moveToNextTrack`, above), which has its own
    /// long-standing autoplay decision (`sleepAtEndOfBook` / `onPlaybackFinished`) and
    /// doesn't go through `markCurrentBookFinished(source:)` at all — this enum exists
    /// only to label the sources that close out a book *without* having actually played
    /// it to the end.
    enum FinishSource: String {
        case watch
        case carPlay
        case siri
        case library   // Review 5 Medium 6: Book Detail / Library mark on the loaded book
    }

    /// Explicitly closes out the current book as finished from an out-of-band trigger —
    /// today only the Watch's "Mark as Finished" (see `WatchSessionManager.handle`), with
    /// `.carPlay`/`.siri` reserved for future equivalents.
    ///
    /// This replaces an earlier approach where the Watch handler faked completion by
    /// calling `pause()` then `seek(to: player.duration)`, hoping to trigger the exact
    /// same code path `moveToNextTrack()` uses on natural completion. That trick was
    /// fragile in a way that was never actually exercised end-to-end: `seek(to:)` only
    /// acts when it finds a track whose window satisfies `time < trackStart +
    /// trackDuration` — for `time == duration` on the last track that comparison is
    /// false by construction (duration IS that track's end), so the seek silently
    /// matched no track and did nothing. It was depending entirely on
    /// `updateCurrentTime`'s safety-net check (`trackTime >= trackDuration`) to notice a
    /// position the player was never actually moved to, and that check only runs from
    /// the periodic time observer — which stops firing the moment `pause()` (called
    /// first) takes effect. In practice the "mark finished" button could easily do
    /// nothing at all.
    ///
    /// Performs the same closing-out steps `moveToNextTrack()` takes on natural
    /// completion: stop playback, sync/record the finished progress (server + local
    /// manifest), stop offering the book for resume, and refresh every Now Playing
    /// surface (lock screen/widget/CarPlay/Watch) via `updateNowPlaying()`. Deliberately
    /// does **not** call `onPlaybackFinished` (the Up Next autoplay hook — wired only
    /// from `moveToNextTrack`'s natural-completion branch): a user tapping "Mark as
    /// Finished" on the Watch is explicitly closing out *this* book, not asking
    /// ShelfHead to start playing the next queued one on their behalf. Autoplay firing
    /// as a side effect of an explicit "I'm done with this" action — especially one
    /// confirmed via a destructive-styled confirmation dialog — would be surprising and
    /// working against what the user just told the app they wanted.
    func markCurrentBookFinished(source: FinishSource) {
        guard currentSession != nil, currentItemId != nil else { return }
        // Order matches moveToNextTrack(): stop the audio and flush whatever position
        // was actually reached before overwriting it with the finished state below.
        // Review 6 Low (finish race): the library's finished PATCH already succeeded; position syncs
        // with the old position (pause's final sync, or ours) would race it.
        skipPositionWriteOnPause = source == .library
        pause()
        skipPositionWriteOnPause = false
        if source != .library { syncProgress() }
        recordFinishedProgress()
        // Don't offer this book for resume on next launch — it's complete.
        SharedPlayback.write(nil)
        // Refresh lock screen / widget / CarPlay / Watch snapshot to reflect playback
        // having stopped — mirrors what pause()/moveToNextTrack already trigger, so the
        // Watch-initiated completion looks identical everywhere else to a natural one.
        updateNowPlaying()
        ShelfLog.info(.playback, "Marked book finished (source: \(source.rawValue))")
    }

    /// Sends an explicit `isFinished: true` progress update for the current book. For
    /// offline sessions it queues the finished state (flushed when back online) and
    /// updates the local manifest. Shared by natural completion (`moveToNextTrack`) and
    /// explicit out-of-band completion (`markCurrentBookFinished(source:)`).
    private func recordFinishedProgress() {
        guard let itemId = currentItemId else { return }
        let dur = duration > 0 ? duration : currentTime
        guard dur > 0 else { return }
        // Batch 428: a finished book counts as heard to the end, so transcript features
        // (recap, search) aren't held back by a frontier left short of the last segment.
        TranscriptStore.raiseHighWater(dur, itemId: itemId)
        // Captured synchronously, on the main actor, before any `await` — this is what
        // pins the queued entry to whichever account was actually active when the book
        // was finished (ARCH-3; see `PendingProgressQueue`'s doc comment for the bug this
        // closes if the scope were instead read later, inside the suspended `Task`).
        let scope = Self.currentProgressScope()
        let entry = PendingProgressQueue.Entry(
            scope: scope, itemId: itemId, currentTime: dur, duration: dur,
            updatedAt: Date().timeIntervalSince1970)
        if let session = currentSession, session.id.hasPrefix("offline-") {
            trackWrite(Task { [weak self] in
                await PendingProgressQueue.shared.record(entry)
                self?.refreshPendingProgressCount()
            })
            DownloadManager.shared.updateLocalProgress(itemId: itemId, currentTime: dur)
        } else {
            // Queue it as pending too, so if the network drops right at the end the
            // finished state is retried by flushPendingProgress rather than lost.
            trackWrite(Task { [weak self] in
                // Published only on failure, like `syncProgress`'s write-ahead copy.
                await PendingProgressQueue.shared.record(entry)
                do {
                    try await AudiobookshelfAPI.shared.updateProgress(
                        libraryItemId: itemId, progress: 1.0,
                        currentTime: dur, duration: dur, isFinished: true,
                        expectedScope: scope)   // Review 4 Low (finished scope)
                    await PendingProgressQueue.shared.clear(
                        itemId: itemId, scope: scope, ifNotNewerThan: entry.updatedAt)
                    self?.refreshPendingProgressCount()
                } catch {
                    // Leave it queued; flushPendingProgress will mark it finished later.
                    self?.refreshPendingProgressCount()
                }
            })
        }
    }

    /// The scope key a progress entry should be queued under, computed the same way as
    /// `DownloadManager.currentScopeKey()` (deliberately kept in sync with it — the two
    /// queues describe the same "which server+account was this for" concept) so a queued
    /// position never gets attributed to the wrong account after a switch. Must always be
    /// called synchronously, before any `await`, by whichever function is capturing a
    /// position to queue — never from inside an already-suspended `Task`.
    static func currentProgressScope() -> String {
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty else { return "unscoped" }
        return DownloadManager.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
    }

    /// Called when the current book finishes all tracks. PlayerViewModel uses this
    /// to auto-advance the Up Next queue.
    var onPlaybackFinished: (() -> Void)?

    /// Fired once, ~20s before the current book ends, so PlayerViewModel can prefetch
    /// the next queued book's session + artwork for a gapless hand-off.
    var onNearEnd: (() -> Void)?

    /// Batch 443: fired on each progress sync with the synced position, so PlayerViewModel can
    /// pass it to reading-site sync (which throttles itself).
    var onProgressSynced: ((_ itemId: String, _ currentTime: Double, _ duration: Double) -> Void)?
    private var hasFiredNearEnd = false
    /// Last chapter id we fired a haptic for, so we tick only on real transitions.
    private var lastHapticChapterId: Int?
    /// Last intro/outro chapter id we already auto-skipped, so seeking back into it
    /// manually (e.g. from the chapter list) doesn't get immediately re-skipped.
    private var lastAutoSkippedChapterId: Int?
    /// Batch 399: the position the timed chapter skip last saw — the previous tick, or the
    /// target of the latest `seek(to:)`, so a deliberate seek never reads as playback
    /// crossing a boundary. See `chapterSkipTarget`.
    private var chapterSkipLastTickTime: Double?
    /// The chapter id whose values were last written to `MPNowPlayingInfoCenter`.
    ///
    /// Deliberately NOT reusing `lastHapticChapterId` above: that one only advances
    /// inside `if isPlaying, SettingsStore.chapterHapticsEnabled`, so with chapter
    /// haptics off (or while paused) it stops tracking reality entirely — it can't
    /// double as the record of what Now Playing has actually seen.
    ///
    /// Written in exactly one place — `updateNowPlaying()` itself — so the periodic
    /// tick and the play/pause/seek/track-change call sites can never disagree about
    /// what was last published. See `shouldRepublishNowPlaying(...)`.
    private var lastPublishedChapterId: Int?

    /// Polish pass (PB-3): the rate Now Playing should claim. Zero unless audio is
    /// actually expected to be rendering. Pure for tests.
    nonisolated static func nowPlayingRate(isPlaying: Bool, isBuffering: Bool, playbackRate: Float) -> Double {
        (isPlaying && !isBuffering) ? Double(playbackRate) : 0.0
    }

    /// Whether a Now Playing republish is owed because the chapter changed under us.
    ///
    /// The bug this pins (user report, real device — CarPlay + lock screen): the
    /// values `updateNowPlaying()` publishes are chapter-RELATIVE
    /// (`MPNowPlayingInfoPropertyElapsedPlaybackTime` = `currentTime - chapter.start`,
    /// `MPMediaItemPropertyPlaybackDuration` = the chapter's length), and the system
    /// extrapolates elapsed time forward from the last published pair using the
    /// playback rate rather than asking us again. `updateNowPlaying()` was called on
    /// play/pause/seek/rate/track-change but NOT when playback simply crossed a
    /// chapter boundary, so the extrapolation ran to the published chapter duration
    /// and CLAMPED there — 0:00 remaining, a full progress bar, and a stale chapter
    /// title — until a stop/start or a skip happened to republish. `CPNowPlayingTemplate`
    /// reads the same `MPNowPlayingInfoCenter`, which is why one fix covers CarPlay,
    /// the lock screen, Control Centre and AirPods announcements together.
    ///
    /// `nil` is treated as a real, distinct value on both sides rather than "unknown":
    /// - `nil -> id` republishes, which is what makes a chapterless-to-chaptered
    ///   transition (and the very first publish of a session, if one somehow hadn't
    ///   happened yet) land.
    /// - `id -> nil` republishes too, so running off the end of the last chapter, or
    ///   into a gap between chapters, falls back to whole-book values instead of
    ///   leaving the previous chapter's bar pinned full.
    /// - `nil -> nil` does not, so a book with no chapter data never republishes on
    ///   the tick at all.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live `AVPlayer` — same
    /// precedent as `DownloadManager.shouldReclaimOrphanDirectory` and
    /// `CarPlayCoordinator.chapterWindow`.
    nonisolated static func shouldRepublishNowPlaying(
        lastPublishedChapterId: Int?, currentChapterId: Int?
    ) -> Bool {
        lastPublishedChapterId != currentChapterId
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    // MARK: - Progress Sync

    private func startPeriodicSync() {
        stopPeriodicSync()
        // 30s rather than the original 15s — halves how often this wakes the network
        // radio to push progress to a self-hosted server during a long uninterrupted
        // listen, at the cost of a slightly larger worst-case progress-loss window if
        // the app were killed outright. That trade-off is reasonable because the
        // immediate syncs on pause/stop/backgrounding/seek/session-close (see call
        // sites of `syncProgress()`/`flushProgress()`) already cover the common cases
        // where losing more than a few seconds of progress would actually matter.
        // `Timer`'s closure isn't proven main-actor-isolated by the compiler either
        // (same reasoning as the time observer above), even though `Timer.scheduledTimer`
        // always fires on the run loop it was scheduled from (main, here).
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncProgress()
            }
        }
    }

    private func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Listen Together (Batch 456)

    /// Batch 456: true while a SharePlay session drives this player. Rate, pause and seek are then
    /// the group's (the coordinator propagates them), so `PlayerViewModel` must not persist a
    /// speed change as this book's saved speed while this is true.
    private(set) var isCoordinatingPlayback = false

    /// Called on the main actor each time a track's item is loaded (item id, track index). The
    /// `ListenTogetherController` uses it to tell the group when the initiator moves to another
    /// file of a multi-file book: the coordinator syncs time within an item but does not manage
    /// which item is current (docs: "doesn't manage the playback queue").
    @ObservationIgnored var onTrackLoaded: ((String, Int) -> Void)?

    @ObservationIgnored private var coordinationAttach: ((AVPlayerPlaybackCoordinator) -> Void)?
    @ObservationIgnored private let coordinationIdentifiers = ListenTogetherItemIdentifiers()

    /// Joins `session`'s playback coordination to the current AVPlayer (now, or when it exists).
    /// Generic so this file doesn't depend on the activity type.
    func attachGroupSession<A: GroupActivity>(_ session: GroupSession<A>) {
        coordinationAttach = { $0.coordinateWithSession(session) }
        isCoordinatingPlayback = true
        applyPlaybackCoordination()
    }

    /// Ends coordination bookkeeping. The session's own `leave()`/`end()` is what actually stops
    /// the coordinator following the group; the delegate is dropped so identifiers are default.
    func detachGroupSession() {
        coordinationAttach = nil
        isCoordinatingPlayback = false
        player?.playbackCoordinator.delegate = nil
    }

    /// Group-driven move to another file of the current book (no-op when already there).
    func coordinatedMoveToTrack(_ index: Int) {
        guard isCoordinatingPlayback, index != currentTrackIndex,
              let tracks = currentSession?.audioTracks, index >= 0, index < tracks.count else { return }
        currentTrackIndex = index
        loadAndPlayTrack(at: index, autoPlay: isPlaying)
    }

    private func applyPlaybackCoordination() {
        guard let attach = coordinationAttach, let player else { return }
        let coordinator = player.playbackCoordinator
        coordinator.delegate = coordinationIdentifiers
        attach(coordinator)
    }

    private func registerCoordinationIdentifier(for item: AVPlayerItem, trackIndex: Int) {
        guard let itemId = currentItemId else { return }
        coordinationIdentifiers.set(ListenTogetherIdentifier.encode(itemId: itemId, trackIndex: trackIndex), for: item)
    }

    /// Batch 458: true while a mixtape plays clips. A clip jumps into the middle of a book
    /// the listener may be partway through (or hasn't started), so those positions must not
    /// become the book's progress on the server, in iCloud or in the download manifest.
    var suppressProgressSync = false
    /// Review 3 High 3: true only while `MixtapePlayer` is sequencing. After it stops or finishes,
    /// `suppressProgressSync` stays on (the player still holds the last clip's book at the clip
    /// position) until the listener's next play or a new load, so no flush writes the clip position.
    var mixtapeDriving = false
    /// Review 4 Low (quick play-pause): set when a play ends post-mixtape suppression, so the
    /// player is still at the clip position until real listening happens.
    private var resumedFromMixtapeClip = false
    private var skipPositionWriteOnPause = false   // Review 6 Low (finish race)
    nonisolated static let mixtapeResumeListenThreshold = 5.0

    /// Review 5 Medium 3: the last track ending while suppressed (a mixtape clip) just pauses.
    nonisolated static func shouldTreatEndAsBookFinished(suppressed: Bool) -> Bool { !suppressed }

    /// Review 5 Low (resumedFromMixtapeClip): a new mixtape or a stop starts clean.
    func clearResumedFromMixtapeClip() { resumedFromMixtapeClip = false }

    /// Review 4 Low (quick play-pause): a pause shortly after resuming from a mixtape clip must
    /// not force-record/sync the clip position. Pure, for tests.
    nonisolated static func shouldSkipPauseRecord(resumedFromMixtapeClip: Bool, listened: Double) -> Bool {
        resumedFromMixtapeClip && listened < mixtapeResumeListenThreshold
    }

    /// Review 7 Medium 1: once this much real listening has happened the player is no longer at the clip
    /// position, so the flag clears. Pure, for tests.
    nonisolated static func shouldClearMixtapeResume(resumedFromMixtapeClip: Bool, listened: Double) -> Bool {
        resumedFromMixtapeClip && listened >= mixtapeResumeListenThreshold
    }

    /// Review 7 Medium 2: a target-based sleep timer (chapter / end of book) belongs to the book it
    /// was armed in; a plain countdown carries over. Pure, for tests.
    nonisolated static func shouldCancelSleepOnItemChange(option: SleepTimerOption, oldItemId: String?, newItemId: String?) -> Bool {
        guard oldItemId != newItemId else { return false }
        switch option {
        case .endOfChapter, .chapters, .endOfBook: return true
        case .off, .minutes: return false
        }
    }

    /// Review 7 Low (clip smart rewind): a mixtape clip seek isn't a resume, so no smart rewind.
    func clearPausedAtForClipSeek() { pausedAt = nil }

    /// Review 3 High 3: the suppression flag after a play or a session load. Only the mixtape
    /// itself keeps it; any other action clears it. Pure, for tests.
    nonisolated static func suppressionAfterExplicitAction(mixtapeDriving: Bool, suppressed: Bool) -> Bool {
        mixtapeDriving ? suppressed : false
    }

    /// Polish pass (PB-10): whether the termination save should write. Same guards as
    /// `syncProgress()` (no bogus position before the resume seek lands, nothing for a
    /// suppressed mixtape clip) plus "is a book loaded". Pure for tests.
    nonisolated static func shouldSaveLocalProgressOnTerminate(
        hasItem: Bool, isDownloaded: Bool, suppressed: Bool,
        hasReachedResumePosition: Bool, currentTime: Double
    ) -> Bool {
        hasItem && isDownloaded && !suppressed && hasReachedResumePosition && currentTime > 1
    }

    /// Synchronous and local only: the download manifest (`updateLocalProgress` is
    /// `nonisolated`, in-memory cache under a lock plus an atomic file write). No network
    /// and no actor hops — `PendingProgressQueue` is an actor, so it can't be written
    /// synchronously here. Streamed books keep their last queued/synced position.
    private func saveLocalProgressForTermination() {
        guard let itemId = currentItemId else { return }
        guard Self.shouldSaveLocalProgressOnTerminate(
            hasItem: true,
            isDownloaded: DownloadManager.shared.isDownloaded(itemId: itemId),
            suppressed: suppressProgressSync
                || Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync),
            hasReachedResumePosition: hasReachedResumePosition,
            currentTime: currentTime) else { return }
        DownloadManager.shared.updateLocalProgress(itemId: itemId, currentTime: currentTime)
    }

    private func syncProgress() {
        guard let session = currentSession else { return }
        guard !suppressProgressSync else { return }
        // Review 7 Medium 1: the player is still at the clip position for the first seconds after a post-mixtape play.
        guard !Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync) else { return }

        // Don't sync a bogus position: before the resume seek has landed, or a
        // near-zero time while a real position exists. This was wiping server progress.
        guard hasReachedResumePosition, currentTime > 1 else { return }

        let listened = timeListenedSinceSync
        timeListenedSinceSync = 0

        // Capture values now so the async task doesn't race the main-thread state.
        let ct = currentTime
        let dur = duration
        let itemId = currentItemId
        // Captured here too, alongside `ct`/`dur`/`itemId`, and not a moment later —
        // see `currentProgressScope()`'s doc comment for why that timing matters.
        let scope = Self.currentProgressScope()

        if let itemId {
            CloudPositionStore.shared.record(itemId: itemId, currentTime: ct, duration: dur)
            onProgressSynced?(itemId, ct, dur)
        }

        // Always keep local resume position current (works offline).
        if let itemId, DownloadManager.shared.isDownloaded(itemId: itemId) {
            DownloadManager.shared.updateLocalProgress(itemId: itemId, currentTime: ct)
        }

        // Offline sessions have no server session to sync to — but the position still
        // has to reach the server eventually.
        //
        // Fix 2.4 (REVIEW-2026-09-09.md): this used to be a bare early return, so a
        // whole offline listen was recorded *only* into the download manifest. The
        // manifest is the right resume source (it's what plays offline, and
        // `updateLocalProgress` above keeps it current), but it is not a sync channel:
        // nothing drains it to the server. The only thing that got the position back up
        // was `DownloadManager.reconcile`'s push branch on the next library refresh, and
        // that same batch of fixes found *that* push silently swallowed its own failures
        // (fix 2.2) and, before fix 2.3, usually didn't run at all because the offline
        // listening was misread as a conflict. Recording into `PendingProgressQueue` here
        // gives an offline listen the same durable, retried path a failed online sync has
        // always had, independent of reconcile.
        //
        // No double-recording when online: this branch returns, and the online path below
        // records its own entry exactly once inside the `Task`. Both use the same
        // `scope`, captured synchronously above (see `currentProgressScope()`), and the
        // same `dur > 0` gate as the online copy (NEW-9). Re-recording the same item
        // every 30s is by design — the queue is keyed by `"scope|itemId"`, so a newer
        // position replaces the older one rather than piling up.
        if session.id.hasPrefix("offline-") {
            guard let itemId, dur > 0 else { return }
            let entry = PendingProgressQueue.Entry(
                scope: scope, itemId: itemId, currentTime: ct, duration: dur,
                updatedAt: Date().timeIntervalSince1970)
            trackWrite(Task { [weak self] in
                await PendingProgressQueue.shared.record(entry)
                self?.refreshPendingProgressCount()
            })
            return
        }

        trackWrite(Task { [weak self] in
            // Queue the position BEFORE the network write, so a suspend/termination that
            // kills this task mid-flight can't lose the final position. Cleared on success
            // — but only if nothing newer raced in while the write was in flight (the
            // `ifNotNewerThan` guard); otherwise flushPendingProgress reconciles it later.
            var entry: PendingProgressQueue.Entry?
            // NEW-9 (follow-up review, 14 Aug 2026): don't queue an offline-retry
            // entry with `duration <= 0` — an unknown duration gives any later
            // consumer of this queued entry (e.g. a future resume path that clamps
            // against it) nothing reliable to clamp against, which is exactly the
            // class of bug the `startOffset` fix above addresses for the live
            // resume path. The live server sync call just below is unaffected and
            // still runs either way; this only skips the *offline fallback copy*.
            if let itemId, dur > 0 {
                let e = PendingProgressQueue.Entry(
                    scope: scope, itemId: itemId, currentTime: ct, duration: dur,
                    updatedAt: Date().timeIntervalSince1970)
                await PendingProgressQueue.shared.record(e)
                entry = e
                // Not published here: this write-ahead copy is cleared a moment later on
                // success, and publishing it flashed the "waiting to sync" pill (and
                // shifted every tab down by its height) on each pause. The count is
                // published below once the entry is known to be left behind.
            }
            do {
                try await AudiobookshelfAPI.shared.syncSession(
                    sessionId: session.id,
                    currentTime: ct,
                    timeListened: listened,
                    duration: dur
                )
                if let itemId, let entry {
                    await PendingProgressQueue.shared.clear(
                        itemId: itemId, scope: scope, ifNotNewerThan: entry.updatedAt)
                    self?.refreshPendingProgressCount()
                }
            } catch {
                ShelfLog.error(.sync, "Progress sync failed; queued for retry: \(error.localizedDescription)")
                self?.refreshPendingProgressCount()
                // Decided here, synchronously, while the `error` value is still in hand —
                // an `Error` existential isn't `Sendable`, so what crosses into the hop
                // below is a plain `Bool`, not the error itself.
                let reopen = Self.shouldReopenSession(after: error, sessionId: session.id)
                // The position is retried via the pending-progress queue, but
                // `timeListenedSinceSync` was already zeroed above — without this,
                // this window's listened time would just be discarded outright
                // instead of rolling into the next successful sync.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.timeListenedSinceSync = Self.carryForwardTimeListened(
                        pending: self.timeListenedSinceSync, failed: listened)
                    if reopen { self.reopenPlaybackSession(replacing: session.id) }
                }
            }
        })
    }

    // MARK: - Session recovery (REVIEW-2026-09-09 remaining, item 2)

    /// When the last session reopen was attempted, so a server that answers 404 to
    /// everything can't turn every failed sync into a new `/play` request.
    private var lastSessionReopenAt: Date?

    /// Whether a failed `syncSession` means the session itself is gone server-side (as
    /// opposed to the network being down), and so should be reopened.
    ///
    /// The bug this addresses: an Audiobookshelf restart drops every in-memory playback
    /// session. From then on **every** sync for the current listen 404s, `closeSession()`
    /// is a `try?` that also 404s, and `timeListened` — the only thing that feeds the
    /// server's listening stats, streaks and daily goal — is never delivered at all, while
    /// the position keeps syncing perfectly well through `/api/me/progress`. Nothing in
    /// the UI is wrong, so nothing prompts anyone to restart playback; the listening time
    /// is simply never recorded.
    ///
    /// Only a definite server-side "this session doesn't exist" qualifies. Audiobookshelf
    /// answers 404 for an unknown session id; 400 is included because a malformed/expired
    /// session id is rejected there by some versions. Everything else — a timeout, a DNS
    /// failure, a 5xx, a 401 (which `AudiobookshelfAPI.send` has already refreshed and
    /// retried once by the time it surfaces) — is a transient failure where the existing
    /// queue-and-retry behaviour is right and reopening would be noise.
    ///
    /// `offline-` sessions are excluded belt-and-braces: `syncProgress()` returns before
    /// the network call for those, so this can't be reached with one, and an offline
    /// session has no server counterpart to reopen in any case.
    nonisolated static func shouldReopenSession(after error: Error, sessionId: String) -> Bool {
        guard !sessionId.hasPrefix("offline-") else { return false }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .notFound:
            return true
        case .httpError(let code):
            return code == 400
        case .invalidURL, .invalidResponse, .unauthorized, .forbidden,
             .serverError, .decodingError:
            return false
        }
    }

    /// Rate-limits the reopen so a server that 404s a freshly created session too (an item
    /// deleted server-side, a proxy swallowing `/play`) can't produce one `/play` request
    /// per failed sync forever. The periodic sync runs every 30s, so a 60s floor means at
    /// most one attempt every other sync, and a burst of syncs triggered by
    /// pause/seek/background can only ever produce one.
    nonisolated static func shouldAttemptSessionReopen(
        now: Date, lastAttemptAt: Date?, minInterval: TimeInterval = 60
    ) -> Bool {
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= minInterval
    }

    /// The `timeListened` that must roll into the next sync after one failed.
    ///
    /// `syncProgress()` zeroes `timeListenedSinceSync` in its synchronous prologue (so a
    /// successful sync can't double-count time that accrued while it was in flight), which
    /// means a failure has to put it back or the window is lost outright. With a session
    /// that has gone invalid server-side this is no longer a one-off: every sync fails, so
    /// this accumulator is the *only* thing carrying the whole listen forward to whatever
    /// session finally accepts it.
    ///
    /// Non-finite and negative inputs are dropped rather than propagated — the running
    /// total is incremented from an `AVPlayer` time observer, and a single NaN would
    /// poison every subsequent sync's `timeListened` (and, through it, the server's stats)
    /// with no way back short of a book change.
    nonisolated static func carryForwardTimeListened(pending: Double, failed: Double) -> Double {
        let safePending = (pending.isFinite && pending > 0) ? pending : 0
        let safeFailed = (failed.isFinite && failed > 0) ? failed : 0
        return safePending + safeFailed
    }

    /// Asks the server for a fresh playback session for the book that's already playing,
    /// and adopts its id for syncing/closing. Does **not** touch the audio: nothing about
    /// the current `AVPlayer`, its item, or the resume position changes.
    private func reopenPlaybackSession(replacing failedSessionId: String) {
        // The book may have changed (or stopped) between the failed sync and this hop.
        guard let session = currentSession, session.id == failedSessionId,
              let itemId = currentItemId else { return }
        // A podcast episode's session comes from a different endpoint
        // (`startPlaybackSession(itemId:episodeId:)`) and `PlaybackSession` carries no
        // episode id to rebuild it from, so reopening one would silently create a session
        // for the wrong thing. Fall back to the existing behaviour for podcasts.
        guard session.mediaType != "podcast" else { return }
        guard Self.shouldAttemptSessionReopen(now: Date(), lastAttemptAt: lastSessionReopenAt) else { return }
        lastSessionReopenAt = Date()

        trackWrite(Task { [weak self] in
            guard let fresh = try? await AudiobookshelfAPI.shared.startPlaybackSession(itemId: itemId) else {
                ShelfLog.error(.sync, "Couldn't reopen the playback session for \(ShelfLog.redact(itemId)); progress still syncs, listening time for this stretch won't be recorded")
                return
            }
            self?.adoptReopenedSession(fresh, replacing: failedSessionId)
        })
    }

    /// Swaps in the reopened session's **id** while keeping every other field of the
    /// session that's actually playing.
    ///
    /// Deliberately not `currentSession = fresh`: the live session's `audioTracks`,
    /// `chapters` and `duration` are what `assetURL(forTrackAt:)`, `TrackTimeline`, the
    /// chapter list and the scrubber are all built against right now. A server that
    /// re-transcodes, re-orders or re-derives any of those between the two `/play` calls
    /// would otherwise change the shape of the book underneath a playing `AVPlayer`. The
    /// id is the only part that was actually stale, so the id is the only part replaced.
    ///
    /// Everything downstream reads the id off `currentSession` — `closeSession()`, the
    /// `offline-` checks in `syncProgress`/`recordFinishedProgress`/`handleStreamFailure`,
    /// and `WatchSessionManager.buildPlaybackState`'s `sessionId` — so this one assignment
    /// is what makes the new session the one they all use.
    private func adoptReopenedSession(_ fresh: PlaybackSession, replacing failedSessionId: String) {
        guard let current = currentSession, current.id == failedSessionId else { return }
        currentSession = PlaybackSession(
            id: fresh.id,
            libraryItemId: current.libraryItemId,
            mediaType: current.mediaType,
            duration: current.duration,
            playMethod: current.playMethod,
            audioTracks: current.audioTracks,
            currentTime: current.currentTime,
            startTime: current.startTime,
            chapters: current.chapters,
            libraryItem: current.libraryItem,
            // Item 11: carried across with the chapter list it describes, so the note
            // under the player's chapter list doesn't disappear when a session is
            // reopened mid-listen.
            droppedChapterCount: current.droppedChapterCount
        )
        ShelfLog.info(.sync, "Reopened the playback session after the server dropped it; listening time resumes on the next sync")
    }

    /// Force an immediate progress write. Called from the app's scenePhase hook
    /// on background/inactive and on termination so we don't rely solely on the
    /// 15s timer (which stops the moment the app is suspended). Wrapped in a
    /// background task so the async write can finish while the app suspends.
    ///
    /// Fix 9.3 (REVIEW-2026-09-09.md): this used to release the background-task
    /// assertion from a fixed `DispatchQueue.main.asyncAfter(deadline: .now() + 5)`,
    /// with no relationship at all to whether the writes had finished — a slow server
    /// or a flaky connection got the app suspended out from under an in-flight sync, and
    /// the identifier was mutated from both the expiration handler and that delayed
    /// block. It now waits on the writes themselves (`drainInFlightWrites()`), and the
    /// identifier lives in a main-actor property with exactly two writers — the
    /// expiration handler and the completion below — both funnelled through
    /// `endProgressFlushBackgroundTask()`, which is idempotent.
    ///
    /// The upper bound is still the expiration handler: the OS gives us a bounded window
    /// and calls it when that runs out, which is the only limit that means anything here.
    func flushProgress() {
        if progressFlushTaskID == .invalid {
            progressFlushTaskID = UIApplication.shared.beginBackgroundTask(withName: "ShelfHeadProgressFlush") { [weak self] in
                // UIKit calls the expiration handler on the main thread, but hop
                // explicitly so that's a fact the compiler checks rather than one this
                // file assumes — and so this and the completion below are serialized
                // against each other on the main actor. `[weak self]` on BOTH closures:
                // Swift 6.4 (#ImplicitStrongCapture) flags a weak inner capture whose
                // outer closure holds `self` strongly by implication — same shape as
                // `startPeriodicSync()`'s timer.
                Task { @MainActor [weak self] in self?.endProgressFlushBackgroundTask() }
            }
        }
        // Both writes are *started* synchronously, exactly as before this fix — only the
        // waiting moved. That matters: `syncProgress()`'s prologue reads the live
        // position and zeroes `timeListenedSinceSync` before it suspends, and this is
        // called from `willTerminate`, where there may be no later main-actor turn in
        // which a deferred prologue could run at all.
        startPendingWrites()
        // Item 24 (REVIEW-2026-09-09-REMAINING.md): `writeSharedPlaybackSnapshot()` now
        // hands its encode+write to a coalesced background queue rather than doing it
        // inline, so the widget's App Group record could otherwise still be in flight
        // when the process is suspended right after this call returns. This is the one
        // caller that actually needs the record durable before that can happen — a brief
        // block here (at most one pending JSON encode + `UserDefaults.set`) is the
        // accepted cost, same trade `syncProgress()`/`flushPendingProgress()` already
        // make on this exact path.
        SharedPlayback.flush()
        // Counted, not a bool: `.inactive` and `.background` arrive back-to-back on a
        // real backgrounding, so two flushes overlap routinely. The first begins the
        // assertion, the last one to finish ends it — otherwise the earlier flush's
        // completion would drop the assertion while the later flush was still writing.
        progressFlushesInFlight += 1
        Task { @MainActor [weak self] in
            await self?.drainInFlightWrites()
            self?.finishProgressFlush()
        }
    }

    /// The assertion `flushProgress()` is holding, or `.invalid` when none. Main-actor
    /// state, so the expiration handler and the flush completion can't both end it.
    private var progressFlushTaskID: UIBackgroundTaskIdentifier = .invalid
    private var progressFlushesInFlight = 0

    private func finishProgressFlush() {
        progressFlushesInFlight = max(0, progressFlushesInFlight - 1)
        guard progressFlushesInFlight == 0 else { return }
        endProgressFlushBackgroundTask()
    }

    /// Idempotent — the whole point of routing both writers through here.
    private func endProgressFlushBackgroundTask() {
        guard progressFlushTaskID != .invalid else { return }
        let id = progressFlushTaskID
        progressFlushTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    // MARK: - Awaitable writes (fix 9.3)

    /// Progress/session writes that have been started but haven't finished yet.
    ///
    /// Every position write in this file is deliberately unstructured: `syncProgress()`
    /// is called from a `Timer`, from `pause()`, from `stop()` and from the remote
    /// command centre, none of which can `await`. That's fine right up until the caller
    /// is about to destroy the thing the write depends on — an account switch or
    /// sign-out clears the token and re-scopes the download tree immediately after
    /// `stop()`, and the OS suspends the process immediately after the scenePhase hook.
    /// Keeping a handle to each in-flight write is what lets `awaitPendingWrites()` (and
    /// therefore `stopAndFlush()`) turn "started" into "finished" for those callers.
    ///
    /// Keyed rather than an array so each write can remove *itself* on completion, which
    /// keeps this from growing for the life of the process.
    private var inFlightWrites: [Int: Task<Void, Never>] = [:]
    private var nextWriteID = 0

    /// Registers one of those writes. Wrapped around the existing `Task { ... }` at each
    /// progress/session write site in this file rather than replacing it, so the write
    /// bodies — and their captures, isolation and `[weak self]` handling — are untouched.
    ///
    /// Registration always wins the race against the write finishing: the argument's
    /// `Task` is main-actor-isolated by inheritance and we are holding the main actor, so
    /// it cannot have started before this returns.
    @discardableResult
    private func trackWrite(_ task: Task<Void, Never>) -> Task<Void, Never> {
        let id = nextWriteID
        nextWriteID += 1
        inFlightWrites[id] = task
        // Reaper, so a long-lived app doesn't accumulate finished handles. Not itself
        // tracked — `drainInFlightWrites()` waits on the real write, not on this.
        Task { @MainActor [weak self] in
            await task.value
            self?.inFlightWrites[id] = nil
        }
        return task
    }

    /// Writes the current position, drains the offline queue, and does not return until
    /// every write either of those started has actually finished.
    ///
    /// This is the awaitable counterpart to `flushProgress()`, for callers that *can*
    /// await — `stopAndFlush()`, and the account-lifecycle paths through it.
    func awaitPendingWrites() async {
        startPendingWrites()
        await drainInFlightWrites()
    }

    /// The synchronous half of a flush: start both writes, capturing the live position
    /// and scope now rather than on some later turn of the main actor. Callers differ
    /// only in whether they then wait for the result.
    private func startPendingWrites() {
        // Review 6 Low (flush): a clip position isn't written within 5 s of a post-mixtape play.
        if !Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync) {
            syncProgress()
        }
        flushPendingProgress()
    }

    /// Waits for every tracked write, in waves — finishing one write can start another
    /// (a failed sync re-queues its listened time; a queue drain records before it
    /// pushes). Capped because "loop until the set is empty" would be unbounded if
    /// writes kept begetting writes; in practice one or two waves is all this takes.
    ///
    /// Tracks what it has already awaited rather than removing entries or waiting for
    /// `trackWrite`'s reaper: the reaper is a separate task, so there is no guarantee it
    /// has run by the time the group below returns, and re-awaiting the same finished
    /// task would otherwise burn a wave and eat into the cap.
    private func drainInFlightWrites(maxWaves: Int = 5) async {
        var awaited = Set<Int>()
        for _ in 0..<maxWaves {
            let wave = inFlightWrites.filter { !awaited.contains($0.key) }
            guard !wave.isEmpty else { return }
            awaited.formUnion(wave.keys)
            await withTaskGroup(of: Void.self) { group in
                for task in wave.values {
                    group.addTask { await task.value }
                }
            }
        }
    }

    /// `stop()`, plus a wait for the writes `stop()` starts.
    ///
    /// `stop()` fires `syncProgress()` and `closeSession()` fire-and-forget and then
    /// synchronously tears the session down, so the account-lifecycle callers — an
    /// account switch, a sign-out — can (and do) clear the token and re-scope downloads
    /// while the final position is still in flight, dropping it. Those callers should
    /// `await stopAndFlush()` instead. Every existing `stop()` caller is unchanged; this
    /// is purely additive, so adopting it is a separate, reviewable change.
    func stopAndFlush() async {
        stop()
        await awaitPendingWrites()
    }

    // MARK: - Deferred (offline) progress queue

    /// Design review (14 Aug 2026), item 2: re-reads the queue's count for the current
    /// scope and publishes it. Called after every `record`/`clear`/`drain` call site
    /// below rather than on a timer — this number only needs to be "roughly right, and
    /// right immediately after something that would change it," not continuously live.
    private func refreshPendingProgressCount() {
        let scope = Self.currentProgressScope()
        Task { [weak self] in
            guard let self else { return }
            self.pendingProgressCount = await PendingProgressQueue.shared.count(forScope: scope)
        }
    }

    /// Pushes any queued offline/failed-sync positions to the server. Safe to call often;
    /// entries are removed only on a successful write (or when superseded) — see
    /// `PendingProgressQueue`. Triggered on connectivity restore and on foreground/flush.
    ///
    /// Guards against clobbering progress set on another device while this one was
    /// offline. It fetches the server's `lastUpdate` **and** `currentTime` per item, and
    /// `PendingProgressQueue.drain` then either drops a queued entry the server has
    /// already written past, or *holds it back* when pushing it would drag the book more
    /// than `DownloadManager.conflictThreshold` backwards — the case the "Progress Doesn't
    /// Match" prompt exists to ask about, which the flush must not answer first.
    func flushPendingProgress() {
        let scope = Self.currentProgressScope()
        // Read synchronously on the main actor, alongside `scope`, rather than from inside
        // the task below — it's the same constant `DownloadManager.reconcile` measures a
        // conflict with, and the two must not be able to disagree.
        let conflictThreshold = DownloadManager.conflictThreshold
        // Review Medium 15: only downloaded books are held for the conflict prompt.
        let downloaded = DownloadManager.shared.downloadedItems
        trackWrite(Task { [weak self] in
            // Review Low (Sync) (30 October 2026): if /api/me can't be fetched, keep every
            // entry queued and retry later rather than sending them with no stale or
            // conflict check (an empty map used to mean "push unconditionally").
            guard let fetched = await Self.fetchServerProgress() else { return }
            // Review 2 Medium 4 (30 October 2026): the account may have switched during the
            // /api/me fetch; entries stay queued for their own account's next flush.
            guard BookmarkSyncService.scopeIsUnchanged(captured: scope, current: Self.currentProgressScope()) else { return }
            let serverProgress = fetched.positions   // itemId -> position + lastUpdate
            let serverFinishedIds = fetched.finishedIds
            // `drain` both returns this scope's queued entries and evicts dead weight
            // (stale-by-age, or superseded by a newer server position) across *every*
            // scope while it has the queue open — see its doc comment for why that
            // eviction can't just be scoped to `scope` the way the returned entries are.
            //
            // Fix (REVIEW-2026-09-09 remaining, item 1): it also *holds back* — neither
            // pushes nor drops — any entry sitting more than `conflictThreshold` behind
            // the server's own `currentTime`. That is the exact shape
            // `DownloadManager.reconcile` refuses to auto-resolve and raises the "Progress
            // Doesn't Match" prompt for; before this, the flush would happily push it
            // first and answer the question on the user's behalf, wiping the server
            // position the prompt was about to offer them.
            let pending = await PendingProgressQueue.shared.drain(
                activeScope: scope, serverProgress: serverProgress,
                conflictThreshold: conflictThreshold,
                downloadedItemIds: downloaded)
            self?.refreshPendingProgressCount()
            guard !pending.isEmpty else { return }
            for entry in pending {
                // Review 2 Medium 4 (30 October 2026): re-check before every send; the account
                // can switch between iterations. Nothing is cleared.
                guard BookmarkSyncService.scopeIsUnchanged(captured: scope, current: Self.currentProgressScope()) else { break }
                // Ebook follow-up (P-15): an entry queued by `EbookReaderView` on a
                // failed/offline `updateEbookProgress` call carries a page location, not
                // a listening position — route it to that same API instead of treating
                // `currentTime`/`duration` (both 0 for these entries, see `Entry.ebook`)
                // as an audio position. `drain(...)` already kept these out of the
                // audio conflict-hold path entirely; this is the other half, at the
                // network call itself.
                if entry.isEbook, let location = entry.ebookLocation {
                    do {
                        try await AudiobookshelfAPI.shared.updateEbookProgress(
                            itemId: entry.itemId, location: location, progress: entry.ebookProgress ?? 0,
                            expectedScope: scope)   // Review 3 Low (progress scope)
                        await PendingProgressQueue.shared.clear(
                            itemId: entry.itemId, scope: scope, isEbook: true, ifNotNewerThan: entry.updatedAt)
                    } catch {
                        // Keep it queued for the next attempt.
                    }
                    continue
                }
                let progress = entry.duration > 0 ? min(entry.currentTime / entry.duration, 1) : 0
                // Review Medium 19 (30 October 2026): keep the server's finished flag, so a
                // re-listen's queued position doesn't un-finish the book.
                let finished = Self.queuedEntryIsFinished(
                    currentTime: entry.currentTime, duration: entry.duration,
                    serverFinished: serverFinishedIds.contains(entry.itemId))
                do {
                    try await AudiobookshelfAPI.shared.updateProgress(
                        libraryItemId: entry.itemId, progress: progress,
                        currentTime: entry.currentTime, duration: entry.duration, isFinished: finished,
                        expectedScope: scope)   // Review 3 Low (progress scope): AccountChangedError leaves it queued
                    // `ifNotNewerThan` is the guard the old code lacked: if a fresher
                    // `record` landed for this item while the write above was in flight,
                    // this no-ops instead of deleting the newer position out from under it.
                    await PendingProgressQueue.shared.clear(
                        itemId: entry.itemId, scope: scope, ifNotNewerThan: entry.updatedAt)
                } catch {
                    // Keep it queued for the next attempt.
                }
            }
            // Design review (14 Aug 2026), item 2: one more refresh once every clear in
            // the loop above has landed (or failed and stayed queued) — the count after
            // `drain` only reflects eviction, not the successful pushes this loop just did.
            self?.refreshPendingProgressCount()
        })
    }

    /// Map of libraryItemId → the server's `lastUpdate` (in seconds) **and** `currentTime`
    /// from the current user's media progress. Nil if the user can't be fetched (offline) — the
    /// flush then keeps everything queued (see the Low (Sync) note below).
    ///
    /// Carries `currentTime` as well as the timestamp (it used to be timestamps alone)
    /// because `PendingProgressQueue.drain` now has two questions to answer, not one:
    /// "has the server written since we captured this?" (drop) and "would pushing this
    /// drag the book backwards past the conflict threshold?" (hold). Only the second one
    /// needs a position.
    ///
    /// An entry whose `lastUpdate` is missing is no longer skipped outright: a nil
    /// timestamp can't make anything look stale (the drop test is `if let`), but its
    /// `currentTime` is still a real position worth measuring the gap against.
    ///
    /// Review Low (Sync) (30 October 2026): now returns nil when the user can't be fetched
    /// (the caller keeps everything queued), and also reports which audiobooks the server
    /// has marked finished (Medium 19). Forces a fresh read: the cached user could be up to
    /// the cache TTL old, which defeats a stale/conflict check.
    private static func fetchServerProgress() async
        -> (positions: [String: PendingProgressQueue.ServerPosition], finishedIds: Set<String>)? {
        guard let user = try? await AudiobookshelfAPI.shared.getCurrentUser(forceRefresh: true) else { return nil }
        let list = user.mediaProgress ?? []
        var map: [String: PendingProgressQueue.ServerPosition] = [:]
        var finishedIds: Set<String> = []
        for mp in list {
            if mp.isFinished == true, mp.episodeId == nil { finishedIds.insert(mp.libraryItemId) }
            // `lastUpdate` is epoch milliseconds; normalise to seconds.
            let seconds = mp.lastUpdate.map { Double($0) / 1000.0 }
            // A podcast reports one `MediaProgress` per *episode* under a single
            // `libraryItemId`, so several records can collide on one key. Keep the most
            // recently written one — and, unlike the old `max()` over timestamps alone,
            // keep its `currentTime` with it rather than pairing the newest timestamp
            // with some other episode's position.
            if let existing = map[mp.libraryItemId], (existing.lastUpdate ?? 0) >= (seconds ?? 0) { continue }
            map[mp.libraryItemId] = PendingProgressQueue.ServerPosition(
                lastUpdate: seconds, currentTime: mp.currentTime)
        }
        return (map, finishedIds)
    }

    /// Review Medium 19 (30 October 2026): the `isFinished` flag to send with a queued
    /// position. Finished when the position is within 1% of the end, **or** when the server
    /// already has the book finished (a re-listen from partway must not un-finish it).
    /// Explicit un-finishing goes through its own reset call, not this queue.
    nonisolated static func queuedEntryIsFinished(currentTime: Double, duration: Double, serverFinished: Bool) -> Bool {
        guard duration > 0 else { return serverFinished }
        return (currentTime / duration) >= 0.99 || serverFinished
    }

    private func closeSession() {
        // Review 2 High 2 (30 October 2026): the close body carries `currentTime`, which would
        // be a clip position, and the API can't close without one. Skip it during a mixtape
        // (the server expires idle sessions; `MixtapePlayer` closed the real one up front).
        guard Self.shouldRecordPosition(suppressed: suppressProgressSync) else { return }
        guard !Self.shouldSkipPauseRecord(resumedFromMixtapeClip: resumedFromMixtapeClip, listened: timeListenedSinceSync) else { return }   // Review 6 Low (flush)
        guard let session = currentSession, !session.id.hasPrefix("offline-"),
              hasReachedResumePosition, currentTime > 1 else { return }
        // Capture values now: stop() calls this and then synchronously zeroes
        // currentTime/duration, so the async Task must not read them off self
        // (that closed the session at position 0 and wiped server progress).
        let ct = currentTime
        let listened = timeListenedSinceSync
        let dur = duration
        trackWrite(Task {
            try? await AudiobookshelfAPI.shared.closeSession(
                sessionId: session.id,
                currentTime: ct,
                timeListened: listened,
                duration: dur
            )
        })
    }

    // MARK: - Now Playing Info

    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingCoverData: Data?  // small JPEG shared with the widget

    private nonisolated func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remote-command callbacks aren't a guaranteed main-thread boundary, but they
        // mutate player/observable/Now-Playing/widget state — hop to the main actor.
        // Batch 433: while a `transientOverride` (the recap montage) is set, play/pause/toggle/skip/
        // next/previous go to it instead of the book; scrubbing, rate changes keep their meaning
        // (rate is picked up by the recap's own player), and bookmarking is ignored.
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overridePlay() } else { self?.play() }
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overridePause() } else { self?.pause() }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overrideTogglePlayPause() } else { self?.togglePlayPause() }
            }
            return .success
        }

        // CRIT-3: reads `SettingsStore.skipForwardInterval`/`skipBackwardInterval`
        // directly rather than `self.skipForwardInterval`/`skipBackwardInterval` (the
        // main-actor-isolated instance properties those are seeded from) — this
        // function is `nonisolated` (see `init()`'s doc comment) and, since the
        // follow-up review's thread-safety fix, called once from a `Task {
        // @MainActor in ... }` scheduled at the very end of singleton construction,
        // before anything realistically could have changed the instance properties
        // from their `SettingsStore`-seeded initial values. The two are identical
        // at that point either way, so this is not a behavior change.
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: SettingsStore.skipForwardInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overrideSkip(forward: true) } else { self?.skipForward() }
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: SettingsStore.skipBackwardInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overrideSkip(forward: false) } else { self?.skipBackward() }
            }
            return .success
        }

        // HIG audit 2026-09-17 L1: the classic backend (this function only runs when
        // `NowPlayingSessionBridge.backend == .classic`, per the `init()` gate above)
        // never registered a playback-rate remote command, so Siri/CarPlay/headphones
        // couldn't change speed on iOS 17–26. Mirrors the iOS 27 session backend's
        // `.changePlaybackRate(supported:)` target (`NowPlayingSessionBridge.swift:372`),
        // sharing the same speed ladder (`NowPlayingSessionRules.supportedRates()`) and
        // the same `setPlaybackRate(_:)` setter.
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates =
            NowPlayingSessionRules.supportedRates().map { NSNumber(value: $0) }
        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            // Pull the Float out before hopping actors — the event itself isn't Sendable
            // (same shape as `changePlaybackPositionCommand` below with `positionTime`).
            let rate = event.playbackRate
            Task { @MainActor [weak self] in self?.setPlaybackRate(rate) }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Batch 433: the recap montage has no scrubbing (its marks are the unit); don't
                // let a scrub seek the paused book underneath it.
                if self.transientOverride != nil { return }
                // `position` arrives in whatever coordinate space `updateNowPlaying()`
                // published as the scrubber's 0...duration range — since that's now
                // chapter-relative whenever a chapter is playing, convert back to
                // absolute book time (`seek(to:)`'s coordinate space) by adding the
                // current chapter's start offset. Chapterless books publish absolute
                // book time already, so `currentChapter == nil` needs no adjustment.
                let absolute = (self.currentChapter?.start ?? 0) + position
                self.seek(to: absolute)
            }
            return .success
        }

        // Next/previous track controls map to chapter navigation.
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overrideSkip(forward: true) } else { self?.skipToNextChapter() }
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if let override = self?.transientOverride { override.overrideSkip(forward: false) } else { self?.skipToPreviousChapter() }
            }
            return .success
        }

        // Bookmark the current moment from the lock screen / headphones (parity with
        // CarPlay's bookmark button). MPFeedbackCommand shows a bookmark affordance.
        commandCenter.bookmarkCommand.isEnabled = true
        commandCenter.bookmarkCommand.localizedShortTitle = String(localized: "Bookmark", comment: "Lock screen / headphones command title for adding a bookmark")
        commandCenter.bookmarkCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.transientOverride == nil,
                      let itemId = self.currentItemId, self.currentTime > 0 else { return }
                let time = self.currentTime
                // Queued if the write fails — the lock screen and headphone remote have no
                // way to report an error, so this used to be the most silent of the eight
                // bookmark call sites.
                // Batch 490 (REVIEW 2026-11-11 V8): same default title as the player's.
                await BookmarkSyncService.shared.create(
                    itemId: itemId, time: time,
                    title: BookmarkDefaultTitle.make(chapterTitle: self.currentChapter?.title, time: time))
            }
            return .success
        }
    }

    /// Batch 433: lets `RecapPlaybackController` republish Now Playing (classic backend; the session
    /// backend re-reads its model on its own) after its state changes.
    func refreshNowPlaying() {
        updateNowPlaying()
    }

    /// Batch 433: streaming sources for cutting narrator clips out of the book that is loaded in
    /// the player when it isn't downloaded. Built from the same URLs + auth headers playback uses
    /// (`assetURL(forTrackAt:)`); nil for any other book. `tracks` use array positions as indices,
    /// matching `DownloadManager.localFileURL(itemId:trackIndex:)`.
    func recapStreamSource(forItemId itemId: String)
        -> (asset: (Int) -> AVURLAsset?, tracks: [(index: Int, startOffset: Double, duration: Double)])? {
        guard currentItemId == itemId, let tracks = currentSession?.audioTracks, !tracks.isEmpty else { return nil }
        var assets: [Int: AVURLAsset] = [:]
        var layout: [(index: Int, startOffset: Double, duration: Double)] = []
        var cursor = 0.0
        for index in tracks.indices {
            let start = tracks[index].startOffset ?? cursor
            let length = tracks[index].duration ?? 0
            layout.append((index, start, length))
            cursor = start + length
            guard let resolved = assetURL(forTrackAt: index) else { continue }
            if let headers = resolved.headers {
                assets[index] = AVURLAsset(url: resolved.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            } else {
                assets[index] = AVURLAsset(url: resolved.url)
            }
        }
        return ({ assets[$0] }, layout)
    }

    private func updateNowPlaying() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentSession?.libraryItem?.title ?? String(localized: "Unknown", comment: "Fallback now-playing title when the book has no title")
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentSession?.libraryItem?.authorName ?? ""
        // Chapter title as the album line whenever one exists, so surfaces that show a
        // third line of text (lock screen, CarPlay) can indicate which chapter the
        // now-chapter-relative progress below belongs to, without displacing the author.
        if let chapter = currentChapter, !chapter.title.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = chapter.title
        }
        // HIG audit 2026-09-17 M8: MPNowPlayingInfoCenter's own docs ask for "as many
        // information properties as you can" — chapter number/count were missing next to
        // the chapter-title write above. Number is zero-based per Apple's documentation.
        if let chapter = currentChapter, let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
            nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = index
            nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        // Elapsed/duration are chapter-relative whenever a chapter is playing (`start`/
        // `end` are absolute book-time offsets, same coordinate space as `currentTime`),
        // falling back to whole-book values for chapterless books. This is a shared,
        // system-wide change — MPNowPlayingInfoCenter has no way to publish different
        // values to CarPlay vs. the lock screen/Control Center/AirPods, so all of them
        // now show chapter progress rather than book progress. The scrubber-drag path
        // (`changePlaybackPositionCommand` above) converts back to absolute time using
        // `currentChapter?.start`, matching this same coordinate space.
        if let chapter = currentChapter {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime - chapter.start
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = chapter.end - chapter.start
        } else {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // Polish pass (PB-3): rate 0 while the player is waiting for data, so the system
        // doesn't extrapolate elapsed time through a stall. MPNowPlayingInfoPropertyElapsedPlaybackTime
        // is "automatically calculated, by the system, from the previously provided elapsed
        // time and the playback rate" (developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyelapsedplaybacktime),
        // so a nonzero rate before audio actually renders makes it run ahead. Republished
        // on `.waiting` → `.playing` in `handleTimeControlStatus`.
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = Self.nowPlayingRate(isPlaying: isPlaying, isBuffering: isBuffering, playbackRate: playbackRate)
        // Without this, the system's elapsed-time extrapolation between updates is
        // subtly wrong at non-1x speeds (it needs to know the rate to project forward
        // from ElapsedPlaybackTime even while paused/scrubbing).
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate

        // Batch 433: while the recap montage owns Now Playing, publish its title/subtitle/position
        // instead of the book's (the book's cover stays). It runs at the book's playback speed.
        if let override = transientOverride {
            nowPlayingInfo[MPMediaItemPropertyTitle] = override.overrideTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = override.overrideSubtitle
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = nil
            nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = nil
            nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = nil
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = override.overrideElapsed
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = override.overrideDuration
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = override.overrideIsPlaying ? playbackRate : 0.0
        }

        // Set artwork if we have it
        if let artwork = nowPlayingArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        // Batch 327: the ONE line the session backend must not execute. Everything else
        // in this method — `lastPublishedChapterId`, the shared App Group snapshot, the
        // widget reload, the Handoff activity — feeds the widgets and the Watch, which
        // have nothing to do with which now-playing API the phone uses, so all of it
        // stays unconditional. The dictionary above is still built either way; that
        // costs a few allocations per publish and keeps this gate to a single line.
        if NowPlayingSessionBridge.backend == .classic {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
        // Recorded here rather than at the (one) periodic-tick call site so every path
        // that publishes — play/pause, seek, rate change, track change, artwork
        // arrival — keeps this in step. In particular a seek that lands in a different
        // chapter updates it as a side effect, so `updateCurrentTime`'s boundary check
        // then correctly finds nothing owed instead of publishing a second time.
        lastPublishedChapterId = currentChapter?.id

        writeSharedPlaybackSnapshot()
        publishControlState(writeSnapshot: false)
        reloadWidgetsThrottled()

        // Publish a Handoff activity so another device can pick up this book + position.
        updateHandoffActivity()
    }

    /// Share the current playback state with the Home/Lock-Screen widget via the App
    /// Group. Split out from `updateNowPlaying()` so the periodic "keep this fresh"
    /// touch below can call it WITHOUT also triggering `reloadWidgetsThrottled()` —
    /// the widget's pre-generated timeline entries already extrapolate progress
    /// forward on their own (see M1), so a reload isn't needed just to keep
    /// `updatedAt` current; forcing one every ~20s during long uninterrupted
    /// playback would burn through WidgetKit's reload budget for no visual benefit.
    private func writeSharedPlaybackSnapshot() {
        SharedPlayback.write(.init(
            itemId: currentItemId ?? "",
            title: currentSession?.libraryItem?.title ?? "",
            author: currentSession?.libraryItem?.authorName ?? "",
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            updatedAt: Date(),
            rate: Double(playbackRate),
            // WATCH-3: so the widget's skip buttons can show the real configured
            // interval instead of a hardcoded 15/30.
            skipBackwardInterval: SettingsStore.skipBackwardInterval,
            skipForwardInterval: SettingsStore.skipForwardInterval,
            sleepTimerActive: sleepTimerOption != .off,
            sleepTimerDefaultMinutes: SettingsStore.defaultSleepTimerMinutes,
            // So the large widget's chapter row can show a title next to its skip
            // buttons; nil for a chapterless book/episode.
            chapterTitle: currentChapter?.title
        ))
    }

    private struct ControlState: Equatable { var isPlaying: Bool; var sleepTimerActive: Bool }
    private var lastPublishedControlState: ControlState?

    /// Writes the shared snapshot (when a session is loaded) and asks Control Center to
    /// re-read the two stateful controls, but only when the state they show has actually
    /// changed — control reloads are budgeted like widget reloads.
    private func publishControlState(writeSnapshot: Bool = true) {
        if writeSnapshot, currentSession != nil { writeSharedPlaybackSnapshot() }
        let state = ControlState(isPlaying: isPlaying, sleepTimerActive: sleepTimerOption != .off)
        guard state != lastPublishedControlState else { return }
        lastPublishedControlState = state
        reloadControlCenterControls()
    }

    private func reloadControlCenterControls() {
        guard #available(iOS 18.0, *) else { return }
        SharedPlayback.flush()   // same reason as reloadWidgetsThrottled(): the provider must read the value we just queued
        ControlCenter.shared.reloadControls(ofKind: SharedPlayback.playbackControlKind)
        ControlCenter.shared.reloadControls(ofKind: SharedPlayback.sleepTimerControlKind)
    }

    /// Last time `updateCurrentTime`'s periodic freshness touch ran (see there).
    private var lastSharedPlaybackTouchAt = Date.distantPast
    private var lastWidgetReloadAt = Date.distantPast
    private var widgetReloadScheduled = false

    /// `updateNowPlaying()` now runs on every seek (not just play/pause/track change),
    /// so scrubbing the progress slider could fire a widget-timeline reload per seek.
    /// WidgetKit budgets reloads and starts silently dropping them if you're too
    /// chatty — coalesce to at most once every few seconds, with a trailing call so
    /// the final position still lands.
    /// Polish pass (WG-2): whether a reload may skip the throttle. A play/pause flip is
    /// the one change the widget must show immediately; everything else (seeks, chapter
    /// changes, artwork) stays coalesced. Pure for tests.
    nonisolated static func shouldReloadWidgetsNow(
        elapsedSinceLastReload: TimeInterval, minInterval: TimeInterval,
        lastPublishedIsPlaying: Bool?, isPlaying: Bool
    ) -> Bool {
        if elapsedSinceLastReload >= minInterval { return true }
        if let last = lastPublishedIsPlaying, last != isPlaying { return true }
        return false
    }

    private var lastWidgetReloadIsPlaying: Bool?

    private func reloadWidgetsThrottled() {
        let minInterval: TimeInterval = 5
        let elapsed = Date().timeIntervalSince(lastWidgetReloadAt)
        let shouldNow = Self.shouldReloadWidgetsNow(
            elapsedSinceLastReload: elapsed, minInterval: minInterval,
            lastPublishedIsPlaying: lastWidgetReloadIsPlaying, isPlaying: isPlaying)
        // Recorded on every call, including the trailing-reload path below, so the
        // flip detection compares against the state the widget was last asked to show.
        defer { if shouldNow { lastWidgetReloadIsPlaying = isPlaying } }
        if shouldNow {
            lastWidgetReloadAt = Date()
            // Item 24: `SharedPlayback.write(_:)` (called just above, in
            // `updateNowPlaying()`) now hands its encode+write to a coalesced background
            // queue instead of writing inline, so the freshest snapshot isn't guaranteed
            // to have landed in the App Group `UserDefaults` yet. `flush()` blocks only
            // until that queue is caught up — cheap, and only paid here, at most once
            // per `minInterval` — so the widget's timeline provider reads the value this
            // call actually meant to publish rather than whatever was there before it.
            SharedPlayback.flush()
            WidgetCenter.shared.reloadAllTimelines()
        } else if !widgetReloadScheduled {
            widgetReloadScheduled = true
            let delay = minInterval - elapsed
            // @MainActor to match how this is entered everywhere else — without it,
            // this delayed continuation resumes on the concurrency thread pool and
            // mutates `widgetReloadScheduled`/`lastWidgetReloadAt` off the main thread
            // while every other call path touches them from the main thread.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard let self else { return }
                self.widgetReloadScheduled = false
                self.lastWidgetReloadAt = Date()
                self.lastWidgetReloadIsPlaying = self.isPlaying
                SharedPlayback.flush()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func updateHandoffActivity() {
        guard let itemId = currentItemId, currentSession != nil else {
            playbackActivity?.invalidate()
            playbackActivity = nil
            return
        }
        let activity = playbackActivity ?? NSUserActivity(activityType: Self.playbackActivityType)
        activity.title = currentSession?.libraryItem?.title ?? String(localized: "Audiobook", comment: "Fallback Handoff activity title")
        activity.isEligibleForHandoff = true
        activity.userInfo = ["itemId": itemId, "currentTime": currentTime]
        activity.becomeCurrent()
        playbackActivity = activity
    }

    /// Bumped by every `loadNowPlayingArtwork(for:)` call, so a decode that finishes
    /// after a newer one started can recognise itself as stale. The `currentItemId`
    /// check alone isn't enough: `loadNowPlayingArtwork` is called again for the *same*
    /// item on a session re-open (a stream recovery, a Watch-initiated resume), and two
    /// in-flight fetches for one id could otherwise land out of order — the older,
    /// lower-quality-cover decode winning because it happened to finish last. Same
    /// generation-token shape as `PendingItemStart.generation`.
    private var nowPlayingArtworkGeneration = 0

    /// Whether a finished artwork decode is still the one that should be shown.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live network fetch — same
    /// precedent as `shouldRepublishNowPlaying`/`shouldRetargetPendingSeek` above.
    nonisolated static func shouldApplyFetchedArtwork(
        fetchedItemId: String, currentItemId: String?,
        fetchGeneration: Int, currentGeneration: Int
    ) -> Bool {
        currentItemId == fetchedItemId && fetchGeneration == currentGeneration
    }

    /// Fetches the cover image from the server and sets it as Now Playing artwork.
    ///
    /// Fix 9.2 (REVIEW-2026-09-09.md): the decode, the 240×240 thumbnail and the JPEG
    /// encode all used to run on the main actor. The `await MainActor.run` at the end
    /// says the code believed otherwise, but with `SWIFT_APPROACHABLE_CONCURRENCY`
    /// (`NonisolatedNonsendingByDefault`) a bare `Task {}` created in a `@MainActor`
    /// method *inherits* main isolation — so a full-size cover decode plus two
    /// re-encodes happened on the main thread at every track change, which is exactly
    /// when the player UI is also being rebuilt. The image work now happens inside
    /// `Task.detached`, matching `CoverImageCache.prefetch`'s shape; only the property
    /// assignments, the App Group cover write and `updateNowPlaying()` stay on main.
    func loadNowPlayingArtwork(for itemId: String) {
        // Design review 2026-09-23 PL-2: this used to always hand-build a server cover
        // URL, so a downloaded book playing offline never showed Lock Screen/CarPlay
        // artwork for the whole session. `shelfCoverURL` prefers the local `file://`
        // cover for a downloaded book (falling back to the server URL otherwise), and
        // `authorizedData(for:)` below already has a dedicated branch for `file://`.
        guard let url = shelfCoverURL(itemId: itemId, width: 600) else { return }
        nowPlayingArtworkGeneration += 1
        let generation = nowPlayingArtworkGeneration

        Task { [weak self] in
            do {
                // Item 6d (REVIEW-2026-09-09 remaining): this used to build its own
                // `AuthStore.authorizedRequest(url:)` and hand it straight to
                // `URLSession.shared.data(for:)`. That fixed the older
                // missing-custom-headers bug but left the *other* half of the known
                // "bypasses the API type" pattern (CLAUDE.md; the Watch-covers and
                // `CarPlayImageLoader` bugs) in place: no refresh-and-retry-once on a 401.
                // Behind a reverse proxy issuing short-lived tokens, the first artwork
                // fetch after a token expiry simply 401'd and the lock screen kept the
                // previous book's cover — or none at all — until the next track change
                // happened to land inside a fresh token's window.
                //
                // `authorizedData(for:)` builds the request through the very same
                // `AuthStore.authorizedRequest(url:)` (bearer token + per-account custom
                // headers), so the request on the wire is unchanged; what's added is the
                // single refresh-and-retry and the `APIError` mapping for non-2xx, which
                // the `catch` below already treats the same way as any other failure.
                let data = try await AudiobookshelfAPI.shared.authorizedData(for: url)
                // Decode + thumbnail + JPEG encode, all off the main actor. `.value`
                // keeps the ordering semantics the old code had: nothing is applied
                // until this returns, and the staleness check below then runs on main
                // against the *current* state rather than the state at fetch time.
                let prepared = await Task.detached(priority: .userInitiated) { () -> (image: UIImage, coverData: Data?)? in
                    guard let image = UIImage(data: data) else { return nil }
                    // Downscale for the widget snapshot (keep App Group storage small).
                    let widgetImage = image.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? image
                    return (image, widgetImage.jpegData(compressionQuality: 0.7))
                }.value
                guard let prepared, let self else { return }
                // Guard against a slow fetch landing after the user switched books,
                // which would show the previous title's cover — and against a slow
                // decode for *this* book losing a race with a newer one (see
                // `nowPlayingArtworkGeneration`).
                guard Self.shouldApplyFetchedArtwork(
                    fetchedItemId: itemId, currentItemId: self.currentItemId,
                    fetchGeneration: generation,
                    currentGeneration: self.nowPlayingArtworkGeneration) else { return }
                let image = prepared.image
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.nowPlayingCoverData = prepared.coverData
                // Written once per track change (not per playback tick, unlike the
                // old embedded-in-Snapshot approach) — the widget reads this file
                // directly at render time instead of carrying it on every entry.
                //
                // Deliberately still on main, unlike the image work above: `stop()`
                // calls `SharedPlayback.writeCover(nil)` synchronously on the main
                // actor, and moving this write off-actor would let a cover land *after*
                // that clear and resurrect the previous book's artwork in the widget.
                SharedPlayback.writeCover(prepared.coverData)
                self.updateNowPlaying()
            } catch {
                // Non-critical — lock screen just won't show artwork
            }
        }
    }

    // MARK: - Notifications

    private nonisolated func setupNotifications() {
        // `NotificationCenter.addObserver(forName:object:queue:using:)`'s closure isn't
        // proven main-actor-isolated by the compiler despite `queue: .main` (same gap as
        // `addPeriodicTimeObserver`/`Timer` above) — hop explicitly in every block below
        // rather than touching `self`'s main-actor state directly from the closure.

        // Advance to the next track exactly when the current one finishes. Using the
        // end-of-item notification (instead of an early time-observer cutoff) means
        // multi-track books don't clip the last moment of each track at the stitch point.
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only react to the item we're actually playing, and only once per boundary.
                guard let item, item === self.player?.currentItem, !self.isAdvancingTrack else { return }
                self.isAdvancingTrack = true
                self.moveToNextTrack()
            }
        }

        // Polish pass (PB-10): best-effort local save on termination. The scenePhase
        // `flushProgress()` already covers a foreground quit; this covers the app being
        // terminated while playing in the background. Not delivered when a suspended app is
        // killed, nor on a crash/jetsam, so the 30 s sync loss window remains for those.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; assume isolation rather than a `Task` hop, which
            // may never get a turn once the process is exiting.
            MainActor.assumeIsolated { self?.saveLocalProgressForTermination() }
        }

        // A streamed item that fails mid-playback is most often an expired access token
        // (the token is baked into the asset URL). Refresh and reload from the current
        // position. Guarded/capped so non-auth failures can't loop.
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStreamFailure()
            }
        }

        // Fix 6.D (REVIEW-2026-09-09.md): the media server can be reset out from under
        // us (its daemon crashing or being restarted under memory pressure — most
        // often noticed around a phone call, a Siri interaction, or CarPlay
        // connecting). Everything AVFoundation handed us before that point is dead
        // afterwards, so nothing recovered on its own: playback stopped for good while
        // `isPlaying`, Now Playing, the widget and the Watch all still said playing.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    // Batch 433: with the recap montage playing it is the thing interrupted.
                    // Batch 471 (review 30 Oct 2026, High 4): remember whether anything was
                    // actually playing. `.shouldResume` only says resuming is appropriate; it
                    // said so for a book the listener had paused too, and the old handler then
                    // started it. Nothing paused means nothing to pause (a second `pause()`
                    // also re-stamped `pausedAt`, shrinking the next smart rewind).
                    let wasPlaying = self.transientOverride?.overrideIsPlaying ?? self.isPlaying
                    // Review 2 Low (Playback) (30 October 2026): a second `.began` (already
                    // paused by the first) must not erase the first one's "was playing".
                    // Explicit play()/pause() by the listener clears the flag.
                    let resumeAfter = self.resumeAfterInterruption || wasPlaying
                    if wasPlaying {
                        if let override = self.transientOverride { override.overridePause() } else { self.pause() }
                    }
                    // Set after the pause: `pause()`/`play()` clear the flag for listener actions.
                    self.resumeAfterInterruption = resumeAfter
                case .ended:
                    let resume = Self.shouldResumeAfterInterruption(
                        wasPlaying: self.resumeAfterInterruption,
                        systemSaysResume: options?.contains(.shouldResume) == true)
                    self.resumeAfterInterruption = false
                    if resume {
                        if let override = self.transientOverride { override.overridePlay() } else { self.play() }
                    }
                @unknown default:
                    break
                }
            }
        }

        // Pause when headphones / AirPods are disconnected (route becomes unavailable),
        // rather than abruptly continuing on the speaker.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            Task { @MainActor [weak self] in
                if reason == .oldDeviceUnavailable, self?.isPlaying == true {
                    self?.pause()
                } else if reason == .oldDeviceUnavailable, self?.resumeAfterInterruption == true {
                    // Review 7 Low (AirPods during call): the route is gone, so the call's end mustn't resume on the speaker.
                    self?.resumeAfterInterruption = false
                } else if reason == .oldDeviceUnavailable, let override = self?.transientOverride, override.overrideIsPlaying {
                    override.overridePause()   // Batch 433: headphones unplugged during the recap
                }
            }
        }
    }

    /// Recovers a streamed item that failed mid-playback (typically an expired access
    /// token in the asset URL): refresh the token and reload the current track at the
    /// current position. No-op for downloaded/offline books and capped to avoid loops.
    private func handleStreamFailure() {
        guard let itemId = currentItemId,
              currentSession?.id.hasPrefix("offline-") == false,
              // Only streamed playback is affected; a local file isn't a token problem.
              DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: currentTrackIndex) == nil,
              let tracks = currentSession?.audioTracks, currentTrackIndex < tracks.count,
              streamRecoveryAttempts < 3 else { return }
        // Polish pass (PB-5): the item's `.failed` status and `failedToPlayToEndTime` can
        // both report one failure; the second must not start a second reload.
        if let last = lastStreamRecoveryAt, Date().timeIntervalSince(last) < 2 { return }

        streamRecoveryAttempts += 1
        lastStreamRecoveryAt = Date()
        let trackStart = tracks[currentTrackIndex].startOffset ?? 0
        let resumeAt = max(0, currentTime - trackStart)
        let wasPlaying = isPlaying
        let index = currentTrackIndex
        streamRecoveryInFlight = true   // Batch 495 (P4)

        Task {
            await AudiobookshelfAPI.shared.ensureFreshAccessToken(force: true)
            await MainActor.run {
                self.streamRecoveryInFlight = false
                // Batch 495 (P4): a pause (listener, sleep timer, interruption) during the
                // token refresh wins over the intent captured at the failure.
                self.loadAndPlayTrack(at: index, seekTo: resumeAt, autoPlay: wasPlaying && self.isPlaying)
            }
        }
    }

    /// Batch 495 (REVIEW 2026-11-11 P4): whether a pause nobody asked for should be
    /// explained as a lost connection. Only for a streamed track the listener was playing,
    /// with no interruption waiting to resume it and no recovery reload still on its way.
    /// A deliberate pause, a sleep timer stop and an interruption all clear
    /// `listenerWasPlaying` before the check runs; a downloaded track isn't `isStreamed`.
    nonisolated static func shouldShowStreamLostNotice(isStreamed: Bool,
                                                       listenerWasPlaying: Bool,
                                                       interruptionPending: Bool,
                                                       recoveryInFlight: Bool) -> Bool {
        isStreamed && listenerWasPlaying && !interruptionPending && !recoveryInFlight
    }

    /// Batch 495 (P4): the current track plays from the server rather than a local file.
    private var isCurrentTrackStreamed: Bool {
        guard let itemId = currentItemId, let session = currentSession,
              !session.id.hasPrefix("offline-") else { return false }
        return DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: currentTrackIndex) == nil
    }

    /// Batch 495 (REVIEW 2026-11-11 P4): the lost-stream notice's Retry, and an explicit
    /// play on a failed item. Reloads the current track at the current position with a
    /// fresh recovery budget and starts it. Only ever called from a listener's action, so
    /// it never starts sound on its own.
    func retryAfterStreamLoss() {
        guard currentSession != nil else { return }
        streamLostNoticeShown = false
        reloadCurrentTrackAfterStreamLoss()
    }

    private func reloadCurrentTrackAfterStreamLoss() {
        guard let tracks = currentSession?.audioTracks, currentTrackIndex < tracks.count else { return }
        streamRecoveryAttempts = 0
        lastStreamRecoveryAt = nil
        let index = currentTrackIndex
        let resumeAt = max(0, currentTime - (tracks[index].startOffset ?? 0))
        streamRecoveryInFlight = true
        let requestedAt = Date()
        Task {
            await AudiobookshelfAPI.shared.ensureFreshAccessToken()
            await MainActor.run {
                self.streamRecoveryInFlight = false
                // The session may have been stopped or replaced while the token refreshed.
                guard self.currentTrackIndex == index, self.currentSession != nil else { return }
                // A pause after the tap (lock screen, sleep timer) cancels the start.
                let pausedSinceTap = self.pausedAt.map { $0 > requestedAt } ?? false
                self.loadAndPlayTrack(at: index, seekTo: resumeAt, autoPlay: !pausedSinceTap)
            }
        }
    }

    // MARK: - Player State Reconciliation (fix 6.E)

    /// Observes the *player's* `timeControlStatus` so `isPlaying` — which is a statement
    /// of what the app intends — can be reconciled against what AVPlayer is actually
    /// doing, and so a stall is at least recorded (`isBuffering`).
    ///
    /// Before this, nothing in the app ever compared the two. A stream that died
    /// mid-playback without producing `failedToPlayToEndTimeNotification` (a Wi-Fi
    /// dropout, a reverse proxy closing the connection, a server restart) left
    /// `isPlaying == true` forever: the player UI, the mini player, Now Playing, the
    /// widget, CarPlay and the Watch all showed playing, the idle timer stayed
    /// disabled, and a countdown sleep timer kept ticking down against silence.
    ///
    /// Attached to the player rather than the item (see `loadAndPlayTrack`), and
    /// deliberately *asymmetric*: a `.paused` player while we think we're playing is
    /// reconciled (after the debounce below), but a `.playing` player while we think
    /// we're paused is only used to clear `isBuffering` — never to flip `isPlaying`
    /// back on. Every route into playback in this app goes through `play()`, which
    /// activates the audio session, starts the periodic sync and republishes every
    /// surface; inferring "we must be playing" here would set the flag without any of
    /// that, and the one thing that *can* resume the player behind our back — an audio
    /// session interruption ending with `.shouldResume` — already calls `play()`.
    private func observeTimeControlStatus() {
        timeControlObservation?.invalidate()
        guard let player else { return }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            // KVO gives no main-thread guarantee. Read the two values off the player
            // here (both are Sendable value types, unlike `AVPlayer.WaitingReason`'s
            // optional wrapper, which is why the reason is reduced to a Bool) and hop
            // before touching any of this instance's state — same shape as the item
            // status observation in `loadAndPlayTrack`, including resolving the weak
            // capture to a plain `let` before the `Task` is created.
            let status = observed.timeControlStatus
            let waitingForData = observed.reasonForWaitingToPlay == .toMinimizeStalls
                || observed.reasonForWaitingToPlay == .evaluatingBufferingRate
            guard let self else { return }
            Task { @MainActor in
                self.handleTimeControlStatus(status, waitingForData: waitingForData)
            }
        }
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus, waitingForData: Bool) {
        switch status {
        case .playing:
            let wasBuffering = isBuffering
            isBuffering = false
            cancelUnexpectedPauseCheck()
            // Polish pass (PB-3): audio is really rendering now — restart the system's
            // elapsed-time extrapolation from the true position.
            if wasBuffering { updateNowPlaying() }
        case .waitingToPlayAtSpecifiedRate:
            // Only "buffering" if playback is what we're trying to do — the player also
            // sits in this state briefly around a seek while paused.
            let wasBuffering = isBuffering
            isBuffering = isPlaying && waitingForData
            // Polish pass (PB-3): freeze the extrapolation while stalled.
            if isBuffering != wasBuffering { updateNowPlaying() }
        case .paused:
            isBuffering = false
            scheduleUnexpectedPauseCheck()
        @unknown default:
            break
        }
    }

    /// Schedules the "did the player stop underneath us?" check.
    ///
    /// This CANNOT act immediately, and that's the whole subtlety of fix 6.E. AVPlayer
    /// goes `.paused` at the end of every audio file, and the end-of-track handoff
    /// (`didPlayToEndTimeNotification` → `moveToNextTrack()` → `loadAndPlayTrack`) is
    /// itself delivered through a main-queue notification plus a `Task { @MainActor }`
    /// hop, so there is no ordering guarantee between the two. Reconciling on the spot
    /// would race that handoff and, when it won, pause a multi-file book at every
    /// single file boundary — a far worse bug than the one being fixed. Waiting a beat
    /// and then re-checking lets the ordinary transitions claim the pause first, since
    /// each of them leaves a marker this check looks for.
    ///
    /// **States treated as "our" pause** (checked at fire time, not now):
    /// - `isPlaying == false` — we asked for this pause (`pause()`, `stop()`, the sleep
    ///   timer, an interruption we handled, end of book).
    /// - `pendingItemStart != nil` — an item is loading and will start itself:
    ///   `startPlayback`, a track advance, a smart rewind across a file boundary,
    ///   `handleStreamFailure`'s reload, or the media-services rebuild.
    /// - `isAdvancingTrack == true` — between the end-of-track notification and the
    ///   next item being loaded.
    /// - `hasReachedResumePosition == false` — a resume/retargeted seek hasn't landed.
    /// - the current item is sitting at (or within half a second of) its own end — the
    ///   end-of-track handoff is in flight even if it hasn't set a marker yet.
    /// - the player has since gone back to `.playing`/`.waitingToPlayAtSpecifiedRate`
    ///   on its own (a brief buffering blip).
    ///
    /// Anything else is a pause nobody in this app asked for, and the honest thing to
    /// do is stop claiming to be playing. `pause()` is reused verbatim so every surface
    /// is republished the same way a user-initiated pause would republish it, and so
    /// `pausedAt` is stamped — which means the eventual resume gets the usual smart
    /// rewind, exactly the right behaviour after audio died mid-sentence.
    private func scheduleUnexpectedPauseCheck() {
        guard isPlaying else { return }
        cancelUnexpectedPauseCheck()
        unexpectedPauseCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reconcileUnexpectedPauseIfNeeded()
        }
    }

    private func cancelUnexpectedPauseCheck() {
        unexpectedPauseCheck?.cancel()
        unexpectedPauseCheck = nil
    }

    private func reconcileUnexpectedPauseIfNeeded() {
        unexpectedPauseCheck = nil
        guard isPlaying, let player, player.timeControlStatus == .paused,
              pendingItemStart == nil, !isAdvancingTrack, hasReachedResumePosition else { return }
        // End-of-file handoff still in flight (see this function's doc comment).
        if let item = player.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0,
               item.currentTime().seconds >= itemDuration - 0.5 { return }
        }
        // Batch 495 (REVIEW 2026-11-11 P4): a recovery reload is waiting on its token
        // refresh and will load a new item (which cancels this check). Look again shortly
        // rather than pausing, so the reload keeps the listener's intent to play.
        if streamRecoveryInFlight {
            scheduleUnexpectedPauseCheck()
            return
        }
        ShelfLog.error(.playback, "Player stopped unexpectedly (stall or lost stream) — reconciling to paused")
        // Batch 495 (REVIEW 2026-11-11 P4): decided before `pause()`, which clears the flags.
        let showNotice = Self.shouldShowStreamLostNotice(isStreamed: isCurrentTrackStreamed,
                                                         listenerWasPlaying: isPlaying,
                                                         interruptionPending: resumeAfterInterruption,
                                                         recoveryInFlight: streamRecoveryInFlight)
        pause()
        if showNotice { streamLostNoticeShown = true }
    }

    /// Rebuilds the audio stack after the system's media server has been reset (fix
    /// 6.D). Every `AVPlayer`, `AVPlayerItem` and audio-session configuration created
    /// before the reset is invalid afterwards, which is why this discards the player
    /// entirely rather than trying to nudge it back to life; Apple's guidance for this
    /// notification is exactly "recreate your objects".
    ///
    /// Rare but real: it happens when the media services daemon crashes or is restarted
    /// under memory pressure, and users hit it most often around a phone call, a Siri
    /// interaction, or a CarPlay connect/disconnect. Without this, playback simply died
    /// while every surface still reported playing — the same class of lie fix 6.E
    /// addresses, except the player itself is unrecoverable, so reconciling `isPlaying`
    /// to false wouldn't be good enough on its own.
    ///
    /// Conservative by design: with nothing loaded it only re-applies the audio session
    /// category (there's nothing to rebuild), and it never starts playback that wasn't
    /// already running.
    private func handleMediaServicesReset() {
        ShelfLog.error(.playback, "Media services were reset — rebuilding the player")
        reconfigureAudioSessionCategory()

        guard let tracks = currentSession?.audioTracks, currentTrackIndex < tracks.count else {
            // Nothing loaded: re-applying the category above is the whole job.
            isBuffering = false
            return
        }

        let wasPlaying = isPlaying
        let index = currentTrackIndex
        let trackStart = tracks[index].startOffset ?? 0
        let resumeAt = max(0, currentTime - trackStart)

        // Tear down explicitly. `loadAndPlayTrack` would otherwise reuse the dead
        // player via `replaceCurrentItem`, and its `timeControlStatus` observation
        // would still be attached to that dead object.
        cancelUnexpectedPauseCheck()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        removeTimeObserver()
        pendingItemStart = nil
        pendingStartSeekAttempts = 0
        isBuffering = false
        isAdvancingTrack = false
        audioTapContext = nil
        player?.replaceCurrentItem(with: nil)
        player = nil

        if wasPlaying { activateAudioSession() }
        // `autoPlay: wasPlaying` is honest here in a way it wasn't in the smart-rewind
        // path (fix 6.A): `isPlaying` was never changed above, so if it was true it
        // still is, and `applyPendingItemStart()` will call `play()` once the rebuilt
        // item is ready. `play()`'s smart rewind doesn't apply — `pausedAt` is nil
        // while playing — so this resumes at the position, not a few seconds behind it.
        loadAndPlayTrack(at: index, seekTo: resumeAt, autoPlay: wasPlaying)
    }

    /// Re-applies the playback audio-session category after a media-services reset.
    ///
    /// Deliberately a (small) duplicate of `ShelfHeadApp.configureAudioSession()`,
    /// which owns this at launch and is `private` to that type: the category has to be
    /// set again after a reset, and the alternative — exposing the app-level function
    /// or moving audio-session ownership into this service — is a bigger refactor than
    /// this fix warrants. Keep the two in step; the fallback exists for the same reason
    /// it does there (see that function's comment about `paramErr` on the simulator).
    private func reconfigureAudioSessionCategory() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Batch 329: `options: []` — see `ShelfHeadApp.configureAudioSession()`; the
            // old A2DP/AirPlay options are invalid for `.playback` and fail on iOS 27.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            ShelfLog.error(.playback, "Audio session category could not be restored after a media services reset: \(error.localizedDescription) — retrying with a minimal category")
            try? session.setCategory(.playback)
        }
    }

    // MARK: - Chapter Info

    var currentChapter: Chapter? {
        currentSession?.chapters?.first { currentTime >= $0.start && currentTime < $0.end }
    }

    var chapters: [Chapter] {
        currentSession?.chapters ?? []
    }
}


// MARK: - Listen Together helpers (Batch 456)

/// Batch 456: the logical identity of a playable item across SharePlay participants. Each device
/// plays its own URL (streaming, downloaded, different token), so the coordinator matches items by
/// this string instead: `"<libraryItemId>#<trackIndex>"`.
nonisolated enum ListenTogetherIdentifier {
    static func encode(itemId: String, trackIndex: Int) -> String { "\(itemId)#\(max(0, trackIndex))" }

    /// Splits on the LAST `#` so an item id is never mis-parsed; nil for anything malformed.
    static func parse(_ identifier: String) -> (itemId: String, trackIndex: Int)? {
        guard let hash = identifier.lastIndex(of: "#") else { return nil }
        let id = String(identifier[..<hash])
        guard !id.isEmpty, let index = Int(identifier[identifier.index(after: hash)...]), index >= 0 else { return nil }
        return (id, index)
    }
}

/// Batch 456: the `AVPlayerPlaybackCoordinatorDelegate` that names player items. The coordinator may
/// call it off the main thread, so the map is lock-guarded and never touches player state; an item
/// that was never registered gets a unique id (it can never match another participant's).
nonisolated final class ListenTogetherItemIdentifiers: NSObject, AVPlayerPlaybackCoordinatorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let table = NSMapTable<AVPlayerItem, NSString>.weakToStrongObjects()

    func set(_ identifier: String, for item: AVPlayerItem) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(identifier as NSString, forKey: item)
    }

    func playbackCoordinator(_ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem) -> String {
        lock.lock(); defer { lock.unlock() }
        return (table.object(forKey: playerItem) as String?) ?? UUID().uuidString
    }
}
