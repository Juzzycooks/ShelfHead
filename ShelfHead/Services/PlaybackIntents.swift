import Foundation
import AppIntents
import CoreSpotlight

/// Bridges Siri / Shortcuts "resume" into the running app's player.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()
    weak var playerViewModel: PlayerViewModel?
    private init() {}

    /// On a cold launch via Siri/Shortcuts, `perform()` can run before `ContentView`
    /// has assigned `playerViewModel`. Since these intents use `openAppWhenRun`, the app
    /// IS launching — briefly wait for the view model rather than silently no-op.
    private func awaitPlayerViewModel(timeout: TimeInterval = 3) async -> PlayerViewModel? {
        if let vm = playerViewModel { return vm }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)   // 0.1s
            if let vm = playerViewModel { return vm }
        }
        return playerViewModel
    }

    /// Resume the most recently played, unfinished book.
    func resumeMostRecent() async {
        await ensureConfigured()
        let downloadsFirst = Self.shouldTryDownloadsFirst(status: ReachabilityStore.shared.trustedStatus, deviceIsOnline: NetworkMonitor.shared.isConnected)
        // Review 7 Low (slow server): race the server against ~3 s; nil = threw/timed out,
        // [] = the server answered with nothing in progress.
        var serverList: [LibraryItem]?
        if !downloadsFirst {
            // Only bound the wait when there is a downloaded book to fall back to.
            serverList = await Self.serverRace(seconds: DownloadManager.shared.downloadedItems.isEmpty ? 30 : 3) {
                try await AudiobookshelfAPI.shared.getItemsInProgress()
            }
            if let item = serverList?.first {
                await awaitPlayerViewModel()?.startPlayback(for: item)
                return
            }
        }
        // Review 7 Low (empty list): an empty answer means nothing in progress; only fall back locally when the call failed.
        if let serverList, serverList.isEmpty { return }
        // Review 6 Low (bare play offline): resume the most recently played downloaded book.
        let dm = DownloadManager.shared
        if let local = Self.mostRecentStarted(in: dm.downloadedItems.compactMap { dm.manifest(for: $0) },
                                              lastPlayed: { $0.lastUpdate }, position: { $0.currentTime }, duration: { $0.duration }),
           let item = dm.downloadedLibraryItems().first(where: { $0.id == local.id }) {
            await awaitPlayerViewModel()?.startPlayback(for: item)
        } else if downloadsFirst, let item = await Self.serverRace({ try await AudiobookshelfAPI.shared.getItemsInProgress() })?.first {
            await awaitPlayerViewModel()?.startPlayback(for: item)   // flag may be stale; try the server
        }
    }

    /// Review 7 Low (slow server): runs `body`, giving up after `seconds`. Nil on throw or timeout.
    static func serverRace<T: Sendable>(seconds: TimeInterval = 3, _ body: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Review 6 Medium 6: true when the server is known unreachable or the phone is offline, so
    /// a downloaded copy should be tried before waiting out the server request timeout.
    nonisolated static func shouldTryDownloadsFirst(status: ReachabilityStore.Status, deviceIsOnline: Bool) -> Bool {
        !deviceIsOnline || status != .ok
    }

    /// Most recently played book that was actually started (position > 0) and not finished.
    /// Never returns an unstarted book: bare "play" means resume.
    nonisolated static func mostRecentStarted<T>(in items: [T], lastPlayed: (T) -> Double?,
                                                 position: (T) -> Double, duration: (T) -> Double) -> T? {
        items.filter { position($0) > 0 && !(duration($0) > 0 && position($0) >= duration($0) - 1) }
            .max { (lastPlayed($0) ?? 0) < (lastPlayed($1) ?? 0) }
    }

    /// Siri "Resume Listening" (Batch 332): `playFromWidget()` bounded to `timeout`
    /// seconds. The work task is deliberately NOT cancelled when the deadline wins —
    /// only the wrapper awaiting it is — so a slow cold start still finishes in the
    /// background after Siri has been answered.
    func resumeInBackground(timeout: TimeInterval = 8) async {
        await runBounded(timeout: timeout) { await self.playFromWidget() }
    }

    /// Batch 362: the CarPlay/Siri `INPlayMediaIntent` handler's call, bounded the same way as
    /// `resumeInBackground` so Siri gets its response before it gives up on the app.
    func playRequestedInBackground(mediaName: String?, timeout: TimeInterval = 8) async {
        await runBounded(timeout: timeout) { await self.playRequested(mediaName: mediaName) }
    }

    /// Runs `body` and returns once it finishes (true) or `timeout` passes (false), whichever
    /// comes first. The work task is never cancelled.
    ///
    /// Batch 495 (REVIEW 2026-11-11 Y2): this used to race `work.value` inside a task group,
    /// but a task group waits for every child before it returns and awaiting an unstructured
    /// task's `value` doesn't respond to cancellation, so the "bound" only ended when the work
    /// did. A continuation resumed by whichever side finishes first returns at the deadline.
    @discardableResult
    private func runBounded(timeout: TimeInterval, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        let work = Task { @MainActor in await body() }
        let gate = BoundedRunGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                await work.value
                if gate.claim() { continuation.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                if gate.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // MARK: - Bounded background play of one book (Batch 495, REVIEW 2026-11-11 Y2/Y5)

    /// Siri "Play ‹book›" and the pinned widget's Play disc: start `itemId` without opening
    /// the app, bounded to `timeout` seconds, and report what actually happened. If the
    /// deadline passes before the book has begun starting (the server lookup is still
    /// out), the attempt is abandoned so a late server answer can't start sound after the
    /// listener was told it failed. A start already under way is left to finish.
    func playInBackground(itemId: String, timeout: TimeInterval = 8) async -> BackgroundPlayOutcome {
        let attempt = BackgroundPlayAttempt()
        let finished = await runBounded(timeout: timeout) {
            await self.play(itemId: itemId, openPlayer: false, attempt: attempt)
        }
        if !finished && !attempt.startBegun { attempt.abandoned = true }
        let service = AudioPlayerService.shared
        return BackgroundPlayOutcome.decide(requestedItemId: itemId,
                                            liveItemId: service.currentItemId,
                                            isPlaying: service.isPlaying,
                                            workFinished: finished,
                                            startBegun: attempt.startBegun)
    }

    /// Y5: the pinned widget's Play disc. `PlayPinnedBookIntent` (WidgetPlaybackIntents.swift)
    /// leaves the book id in the App Group and posts `PinnedPlayRequest.darwinName`; this
    /// takes the request, plays it through the same bounded path as Siri, and writes the
    /// outcome back so the intent can stop waiting.
    func playPinnedFromWidget() async {
        guard let request = PinnedPlayRequest.takePending(now: Date()) else { return }
        let outcome = await playInBackground(itemId: request.itemId)
        PinnedPlayRequest.writeOutcome(outcome == .playing ? .playing : .failed, token: request.token)
    }

    /// PL-14: the app half of the CarPlay/Siri `INPlayMediaIntent`. A bare play (no name)
    /// resumes the most recent book. A named title plays the best server match, else the best
    /// downloaded match (offline); a named title that matches nothing starts nothing.
    // Review 5 Low (named title, no match): no longer falls back to resuming.
    func playRequested(mediaName: String?) async {
        guard let name = Self.requestedTitle(mediaName) else {
            await resumeMostRecent()
            return
        }
        await ensureConfigured()
        // Review 6 Medium 6: known-unreachable server / offline phone: downloaded copy first.
        if Self.shouldTryDownloadsFirst(status: ReachabilityStore.shared.trustedStatus, deviceIsOnline: NetworkMonitor.shared.isConnected),
           let local = Self.bestDownloadedMatch(for: name, in: DownloadManager.shared.downloadedLibraryItems(), title: { $0.title }) {
            await awaitPlayerViewModel()?.startPlayback(for: local)
            return
        }
        // Review 7 Low (slow server): bound the search; on timeout fall to the downloaded copy below.
        let hasLocal = Self.bestDownloadedMatch(for: name, in: DownloadManager.shared.downloadedLibraryItems(), title: { $0.title }) != nil
        let serverMatch = await Self.serverRace(seconds: hasLocal ? 3 : 30) { try await AudiobookQuery().entities(matching: name).first }
        if let match = serverMatch ?? nil {
            await play(itemId: match.id)
        } else if let local = Self.bestDownloadedMatch(for: name, in: DownloadManager.shared.downloadedLibraryItems(), title: { $0.title }) {
            // Review 5 Low (offline play by title)
            await awaitPlayerViewModel()?.startPlayback(for: local)
        }
    }

    /// The trimmed spoken title, or nil for a bare play.
    nonisolated static func requestedTitle(_ raw: String?) -> String? {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Best downloaded book for a spoken title: exact (case/diacritic-insensitive) first, then
    /// the shortest title containing the phrase. Nil when nothing matches.
    nonisolated static func bestDownloadedMatch<T>(for name: String, in items: [T], title: (T) -> String = { _ in "" }) -> T? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let exact = items.first(where: { title($0).compare(q, options: opts) == .orderedSame }) { return exact }
        return items.filter { title($0).range(of: q, options: opts) != nil }
            .min { title($0).count < title($1).count }
    }

    /// Start playback for a book already resolved to a specific server item id —
    /// `PlayAudiobookIntent`'s path once `AudiobookQuery` has resolved a specific
    /// `AudiobookEntity`, rather than re-searching by title on every invocation.
    func play(itemId: String, openPlayer: Bool = true, attempt: BackgroundPlayAttempt? = nil) async {
        await ensureConfigured()
        // Batch 495 (REVIEW 2026-11-11 Y2): the book is already loaded here. Playing: nothing
        // to do. Paused live session: resume it rather than restarting the session.
        if let vm = playerViewModel, vm.currentBook?.id == itemId, !vm.isAwaitingResume {
            if !vm.isPlaying { vm.togglePlayPause() }
            return
        }
        // Review 7 Low (slow server): bounded; downloaded copy is the fallback.
        let hasLocal = DownloadManager.shared.downloadedLibraryItems().contains { $0.id == itemId }
        let resolved: LibraryItem?
        if let item = await Self.serverRace(seconds: hasLocal ? 3 : 30, { try await AudiobookshelfAPI.shared.getItem(itemId: itemId) }) {
            resolved = item
        } else {
            // Review 5 Low (offline play by title): server unreachable, play the downloaded copy.
            resolved = DownloadManager.shared.downloadedLibraryItems().first(where: { $0.id == itemId })
        }
        guard let item = resolved else { return }
        let vm = await awaitPlayerViewModel()
        // Batch 495 (Y2): a background caller that already answered "couldn't start" must
        // not start the book late.
        if attempt?.abandoned == true { return }
        attempt?.startBegun = true
        await vm?.startPlayback(for: item, openPlayer: openPlayer)
    }

    // MARK: - Find in audiobook (Batch 424)

    /// Siri "Find in Audiobook": searches the on-device transcript of `itemId` (or the loaded /
    /// last-played book) for `text` and jumps to the best match the listener has already heard.
    /// Never jumps past the spoiler frontier (`TranscriptionCenter.frontier(for:)`).
    func find(text: String, itemId: String?) async -> FindInAudiobookOutcome {
        await ensureConfigured()
        guard let vm = await awaitPlayerViewModel() else { return .noBook }
        // Resolve the book: explicit id, else the loaded book, else the restored last session.
        var targetId = itemId ?? vm.currentBook?.id
        if targetId == nil {
            vm.adoptActiveSessionIfNeeded()
            vm.restoreLastSession()
            targetId = vm.currentBook?.id
        }
        guard let id = targetId else { return .noBook }

        let center = TranscriptionCenter.shared
        let transcript = center.transcript(for: id)
        var best: TranscriptSearchHit?
        var anywhere: TranscriptSearchHit?
        if let transcript {
            // Index build is a linear pass over the segments; done inline (MainActor) since the
            // intent is already foreground (`openAppWhenRun`).
            let index = TranscriptSearchIndex(transcript: transcript)
            best = TranscriptSearch.bestMatch(text, in: index, before: center.frontier(for: id))
            if best == nil { anywhere = TranscriptSearch.bestMatch(text, in: index, before: nil) }
        }
        let outcome = FindInAudiobookOutcome.decide(hasTranscript: transcript != nil,
                                                    bestBeforeFrontier: best,
                                                    bestAnywhere: anywhere)
        guard case .jump(let time) = outcome else { return outcome }

        if vm.currentBook?.id == id && !vm.isAwaitingResume {
            vm.seek(to: time, reason: .search)
            if !vm.isPlaying { vm.togglePlayPause() }
        } else {
            guard let item = try? await AudiobookshelfAPI.shared.getItem(itemId: id) else { return .couldNotPlay }
            await vm.startPlayback(for: item)
            guard BookDetailView.shouldSeekAfterStart(loadedBookId: vm.currentBook?.id,
                                                      itemId: id,
                                                      isAwaitingResume: vm.isAwaitingResume) else {
                return .couldNotPlay
            }
            vm.seek(to: time, reason: .search)
        }
        return outcome
    }

    /// On a cold launch via Siri the session may not be restored yet — seed it from the Keychain.
    private func ensureConfigured() async {
        await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
    }

    // MARK: - Widget playback control

    /// The widget's play/pause/skip buttons post a Darwin notification that
    /// `AudioPlayerService.setupWidgetControlBridge()` listens for and used to act on
    /// directly (`AudioPlayerService.shared.togglePlayPause()` / `skipForward()` /
    /// `skipBackward()`). That's correct while the app is alive with something already
    /// loaded, but if the app had been fully terminated, a freshly-launched
    /// `AudioPlayerService.shared` has no session loaded at all — `play()` on an empty
    /// player is a silent no-op, which is exactly the "play button doesn't resume
    /// after closing the app" bug this fixes. These route through the view model
    /// instead so a cold start restores the last-played book (same snapshot the
    /// mini-player itself restores from) before acting, mirroring `resumeMostRecent()`
    /// above but from the *local* snapshot rather than a fresh server query — it should
    /// resume exactly where the widget was already showing the user it had left off.
    private func ensureSomethingLoaded() async -> PlayerViewModel? {
        await ensureConfigured()
        guard let vm = await awaitPlayerViewModel() else { return nil }
        if vm.currentBook == nil {
            // Adopts a session already playing in this process (e.g. started from
            // CarPlay moments earlier) if there is one — sets `currentBook`
            // asynchronously, but in that case `currentSession` is already non-nil so
            // `toggleFromWidget()`'s live-session branch handles it regardless.
            // Otherwise, restores the last-known snapshot from the App Group, which
            // sets `currentBook` synchronously — that's the path a genuine cold start
            // (nothing loaded anywhere) relies on.
            vm.adoptActiveSessionIfNeeded()
            vm.restoreLastSession()
        }
        return vm
    }

    func toggleFromWidget() async {
        guard let vm = await ensureSomethingLoaded() else { return }
        if vm.currentBook == nil {
            // No local snapshot to restore from (fresh install, signed out, or the
            // account was switched/cleared since anything last played) — falling
            // through to togglePlayPause() here would hit AudioPlayerService.play()
            // with nothing loaded. That's now guarded against there too, but it would
            // still just silently do nothing. Fall back to a real server query for the
            // most recent in-progress book instead, same as the Siri "Resume Listening"
            // path — gives the widget tap a real chance of doing something useful.
            await resumeMostRecent()
            return
        }
        vm.togglePlayPause()
    }

    /// Review 2 Medium 3 (30 October 2026): what a skip request should do, given what is loaded.
    nonisolated enum SkipAction: Equatable {
        case skip
        /// Widget path only: start playback from the restored snapshot instead of skipping.
        case coldStart
        /// Siri path: a restored book must not start sound the listener didn't ask for.
        case needsPlayFirst
        case nothingPlaying
    }

    /// Review 3 Medium 4: `hasLiveSession` (the audio service has a session) skips even when
    /// `currentBook` is still nil, as after CarPlay/background starts whose adoption is async.
    nonisolated static func skipAction(hasBook: Bool, isAwaitingResume: Bool, allowColdStart: Bool,
                                       hasLiveSession: Bool = false) -> SkipAction {
        if hasLiveSession { return .skip }
        guard hasBook else { return .nothingPlaying }
        guard isAwaitingResume else { return .skip }
        return allowColdStart ? .coldStart : .needsPlayFirst
    }

    /// Review 2 Medium 3: whether a cold start actually took hold (a live session exists or audio is playing).
    nonisolated static func coldStartTookHold(hasBook: Bool, isAwaitingResume: Bool, isPlaying: Bool) -> Bool {
        hasBook && (isPlaying || !isAwaitingResume)
    }

    private func performSkip(forward: Bool, allowColdStart: Bool) async -> SkipAction {
        guard let vm = await ensureSomethingLoaded() else { return .nothingPlaying }
        let action = PlaybackCoordinator.skipAction(hasBook: vm.currentBook != nil,
                                                    isAwaitingResume: vm.isAwaitingResume,
                                                    allowColdStart: allowColdStart,
                                                    hasLiveSession: AudioPlayerService.shared.currentSession != nil)
        switch action {
        case .skip:
            // Review 3 Medium 4: act on the service directly (what the view model forwards to anyway).
            let service = AudioPlayerService.shared
            if forward { service.skipForward() } else { service.skipBackward() }
        case .coldStart:
            // Cold start: just resume rather than racing a skip against the seek to
            // the resume position that `startPlayback` performs asynchronously once
            // the AVPlayerItem becomes ready. Calling skipForward() right after would
            // either get silently clobbered when that seek lands moments later, or —
            // if the skip target crosses a chapter/track boundary — reload the item a
            // second time and leave playback stuck paused. Tapping skip again once
            // playback has actually started applies the skip safely.
            if let book = vm.currentBook {
                await vm.startPlayback(for: book, openPlayer: false)
            }
            // Review 2 Medium 3: don't claim success if the start didn't take hold.
            if !PlaybackCoordinator.coldStartTookHold(hasBook: vm.currentBook != nil,
                                                      isAwaitingResume: vm.isAwaitingResume,
                                                      isPlaying: vm.isPlaying) {
                return .nothingPlaying
            }
        case .needsPlayFirst, .nothingPlaying:
            break
        }
        return action
    }

    /// Widget bridge: keeps the cold-start-resumes behaviour. Returns whether it did something.
    @discardableResult
    func skipForwardFromWidget() async -> Bool {
        let r = await performSkip(forward: true, allowColdStart: true)
        return r == .skip || r == .coldStart
    }

    @discardableResult
    func skipBackwardFromWidget() async -> Bool {
        let r = await performSkip(forward: false, allowColdStart: true)
        return r == .skip || r == .coldStart
    }

    /// Review 2 Medium 3: Siri/Shortcuts skip. Never starts playback; throws a spoken error instead.
    func skipFromIntent(forward: Bool) async throws {
        switch await performSkip(forward: forward, allowColdStart: false) {
        case .skip, .coldStart: return
        case .needsPlayFirst: throw PlaybackIntentError.pressPlayFirstToSkip
        case .nothingPlaying: throw PlaybackIntentError.nothingPlaying
        }
    }

    /// The large widget's chapter skip buttons. Same cold-start race as
    /// `skipForwardFromWidget()`/`skipBackwardFromWidget()`, so it shares the same guard —
    /// jumping to a chapter boundary right after a cold start would race the resume seek
    /// `startPlayback` performs asynchronously. Calls the view model's `nextChapter()`/
    /// `previousChapter()` (not `AudioPlayerService` directly) so the same layer that owns
    /// `skipForward()`/`skipBackward()` above also owns this.
    func nextChapterFromWidget() async {
        guard let vm = await ensureSomethingLoaded() else { return }
        if vm.isAwaitingResume {
            if let book = vm.currentBook {
                await vm.startPlayback(for: book, openPlayer: false)
            }
            return
        }
        vm.nextChapter()
    }

    func previousChapterFromWidget() async {
        guard let vm = await ensureSomethingLoaded() else { return }
        if vm.isAwaitingResume {
            if let book = vm.currentBook {
                await vm.startPlayback(for: book, openPlayer: false)
            }
            return
        }
        vm.previousChapter()
    }

    // MARK: - Control Center "set play state"

    /// The pure decision half of `playFromWidget()`/`pauseFromWidget()`, extracted so it
    /// can be unit-tested without driving `AppIntents`, `AudioPlayerService` or a real
    /// `PlayerViewModel` — same precedent as `StartSleepTimerIntent
    /// .validatedSleepTimerMinutes(_:)` above. `PlaybackControlToggleIntent`
    /// (ShelfHeadWidgets/ShelfHeadPlaybackControl.swift) now posts a real "set" Darwin
    /// notification (`com.shelfhead.setPlaying`/`com.shelfhead.setPaused`) instead of
    /// inferring a flip from the tile's last-known state, so these two methods need to
    /// turn "the person asked for play/pause" plus the three bits of state
    /// `ensureSomethingLoaded()` can observe into exactly one action — never more than
    /// one, and critically, never an action that starts or restores playback when a
    /// pause was requested (a Control Center pause tapped moments after a force-quit
    /// must stay a no-op, not silently resume the last book just because loading its
    /// identity was needed to answer "is it playing").
    enum SetPlayStateAction: Equatable {
        /// Nothing loaded anywhere (fresh install, signed out, or cleared account) —
        /// only reachable when `requestedPlaying` is true; a play request falls back to
        /// a real server query, mirroring `toggleFromWidget()`.
        case resumeMostRecent
        /// A book identity was restored from the local snapshot but never actually
        /// started (`isAwaitingResume`) — load and play it, mirroring
        /// `skipForwardFromWidget()`'s cold-start handling.
        case startFromColdSnapshot
        /// A live, paused session — resume it.
        case play
        /// A live, playing session — pause it.
        case pause
        /// Already in (or can't safely be moved to) the requested state: already
        /// playing, already paused, or a pause requested with nothing actually playing
        /// (including the cold-snapshot case, where "pause" must not become "start then
        /// immediately pause").
        case none
    }

    /// - Parameters:
    ///   - requestedPlaying: `true` for `playFromWidget()`, `false` for
    ///     `pauseFromWidget()` — what Control Center's `SetValueIntent` asked for.
    ///   - hasBook: `vm.currentBook != nil` after `ensureSomethingLoaded()` has had a
    ///     chance to restore the last snapshot.
    ///   - isAwaitingResume: `vm.isAwaitingResume` — a book identity is known but no
    ///     live session has been started yet.
    ///   - isPlaying: `vm.isPlaying`.
    nonisolated static func setPlayStateAction(
        requestedPlaying: Bool,
        hasBook: Bool,
        isAwaitingResume: Bool,
        isPlaying: Bool
    ) -> SetPlayStateAction {
        guard requestedPlaying else {
            // Pause: only ever pause a session that is actually, live, playing right
            // now. Nothing loaded, or a cold-snapshot identity with no live session yet
            // (isAwaitingResume), or an already-paused session all resolve to `.none` —
            // none of them may start or restore anything.
            return (hasBook && !isAwaitingResume && isPlaying) ? .pause : .none
        }
        guard hasBook else { return .resumeMostRecent }
        if isAwaitingResume { return .startFromColdSnapshot }
        return isPlaying ? .none : .play
    }

    /// Control Center asked for "playing". Mirrors `toggleFromWidget()`'s cold-start
    /// fallback and `skipForwardFromWidget()`'s `isAwaitingResume` handling, but never
    /// toggles blindly — `togglePlayPause()` is only reached in the `.play` case, where
    /// `setPlayStateAction` has already established the session is loaded, live, and
    /// currently paused, so toggling it is unambiguously "start playing".
    func playFromWidget() async {
        guard let vm = await ensureSomethingLoaded() else { return }
        let action = PlaybackCoordinator.setPlayStateAction(
            requestedPlaying: true,
            hasBook: vm.currentBook != nil,
            isAwaitingResume: vm.isAwaitingResume,
            isPlaying: vm.isPlaying
        )
        switch action {
        case .resumeMostRecent:
            await resumeMostRecent()
        case .startFromColdSnapshot:
            if let book = vm.currentBook {
                await vm.startPlayback(for: book, openPlayer: false)
            }
        case .play:
            vm.togglePlayPause()
        case .pause, .none:
            break
        }
    }

    /// Control Center asked for "paused". `PlayerViewModel` exposes no direct `pause()`
    /// — only `togglePlayPause()` — so this only ever calls it from the `.pause` case,
    /// where `setPlayStateAction` has already confirmed a live session is actually
    /// playing (never `isAwaitingResume`, so `togglePlayPause()` can't take its
    /// load-and-start branch here); every other case is a no-op, so a pause request can
    /// never start or restore playback, even moments after a cold relaunch.
    func pauseFromWidget() async {
        guard let vm = await ensureSomethingLoaded() else { return }
        let action = PlaybackCoordinator.setPlayStateAction(
            requestedPlaying: false,
            hasBook: vm.currentBook != nil,
            isAwaitingResume: vm.isAwaitingResume,
            isPlaying: vm.isPlaying
        )
        if action == .pause {
            vm.togglePlayPause()
        }
    }

    // MARK: - Control Center sleep timer

    enum SleepTimerControlAction: Equatable {
        case arm(minutes: Int)
        case disarm
        case none
    }

    /// Pure decision half of `setSleepTimerFromWidget(enabled:)`. Only a live session (a
    /// book loaded AND not merely awaiting a cold resume) can have a timer armed or
    /// disarmed; the toggle never starts or restores playback, so a cold snapshot or
    /// nothing-loaded resolves to `.none` either way.
    nonisolated static func sleepTimerControlAction(
        requestedOn: Bool,
        hasBook: Bool,
        isAwaitingResume: Bool,
        defaultMinutes: Int,
        hasLiveSession: Bool = false
    ) -> SleepTimerControlAction {
        // Review 3 Medium 4: a live service session counts even before `currentBook` is adopted.
        let isLive = (hasBook && !isAwaitingResume) || hasLiveSession
        guard isLive else { return .none }
        return requestedOn ? .arm(minutes: max(1, defaultMinutes)) : .disarm
    }

    /// Review Medium 24 (30 October 2026): Siri/Shortcuts "Set Sleep Timer". Loads the last book first (the old
    /// intent called `AudioPlayerService.shared` directly, which is empty after a kill), arms only on a live
    /// session, and returns whether the timer was armed so the intent can say so honestly.
    /// Review 2 Low (Siri): a loaded-but-restored book throws `pressPlayFirstForSleepTimer`, not "start a book".
    func setSleepTimerFromIntent(minutes: Int) async throws {
        guard let vm = await ensureSomethingLoaded() else { throw PlaybackIntentError.noSleepTimerTarget }
        guard case .arm(let armed) = PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: true,
            hasBook: vm.currentBook != nil,
            isAwaitingResume: vm.isAwaitingResume,
            defaultMinutes: minutes,
            hasLiveSession: AudioPlayerService.shared.currentSession != nil
        ) else {
            throw PlaybackIntentError.sleepTimerError(hasBook: vm.currentBook != nil)
        }
        // Batch 495 (REVIEW 2026-11-11 Y3): called from `StartSleepTimerIntent.perform()`, a
        // `LiveActivityIntent`, so the countdown activity may start with the app in the background.
        LiveActivityController.shared.allowingIntentStart {
            applySleepTimer(.minutes(armed), via: vm)
        }
    }

    /// Review 3 Medium 4: the timer lives on the audio service; the view model only adds profile/undo
    /// bookkeeping, so with no adopted book yet go straight to the service.
    private func applySleepTimer(_ option: SleepTimerOption, via vm: PlayerViewModel) {
        if vm.currentBook != nil { vm.setSleepTimer(option) } else {
            // Review 4 Low (Sleep profile): same bookkeeping as `PlayerViewModel.setSleepTimer`.
            ListeningProfileManager.shared.profileSleepTimerReplaced()
            AudioPlayerService.shared.setSleepTimer(option)
        }
    }

    /// Control Center's Sleep Timer toggle posts `com.shelfhead.setSleepTimerOn`/
    /// `com.shelfhead.setSleepTimerOff` — see `AudioPlayerService.setupWidgetControlBridge()`.
    func setSleepTimerFromWidget(enabled: Bool) async {
        guard let vm = await ensureSomethingLoaded() else { return }
        switch PlaybackCoordinator.sleepTimerControlAction(
            requestedOn: enabled,
            hasBook: vm.currentBook != nil,
            isAwaitingResume: vm.isAwaitingResume,
            defaultMinutes: SettingsStore.defaultSleepTimerMinutes,
            hasLiveSession: AudioPlayerService.shared.currentSession != nil
        ) {
        case .arm(let minutes):
            // Batch 495 (REVIEW 2026-11-11 Y3): only `SleepTimerControlToggleIntent` (a
            // `LiveActivityIntent`) posts the "on" channel, and its `perform()` is still
            // waiting while this runs, so the countdown activity may start from here.
            LiveActivityController.shared.allowingIntentStart {
                applySleepTimer(.minutes(minutes), via: vm)
            }
        case .disarm: applySleepTimer(.off, via: vm)
        case .none: break
        }
    }
}

/// Batch 495 (REVIEW 2026-11-11 Y2): one-shot latch for `PlaybackCoordinator.runBounded`, so
/// exactly one of "work finished" and "deadline passed" resumes its continuation.
@MainActor
final class BoundedRunGate {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Batch 495 (Y2): shared between `playInBackground` and the `play(itemId:)` it bounds.
/// `startBegun` is set just before the player starts loading the book; `abandoned` is set by
/// the caller when the deadline passed first, and stops a late start.
@MainActor
final class BackgroundPlayAttempt {
    var startBegun = false
    var abandoned = false
}

/// Batch 495 (REVIEW 2026-11-11 Y2/Y5): what a bounded background play of one book achieved.
enum BackgroundPlayOutcome: Equatable {
    /// The requested book is the live session and playing.
    case playing
    /// The book began loading but wasn't playing by the deadline. It may still start.
    case stillStarting
    /// Nothing started: the book couldn't be found or loaded, the start failed, or the
    /// deadline passed before loading began (the attempt was abandoned).
    case couldNotStart

    nonisolated static func decide(requestedItemId: String, liveItemId: String?, isPlaying: Bool,
                                   workFinished: Bool, startBegun: Bool) -> BackgroundPlayOutcome {
        if liveItemId == requestedItemId && isPlaying { return .playing }
        if !workFinished && startBegun { return .stillStarting }
        return .couldNotStart
    }
}

/// Batch 495 (Y2): Siri's answer when "Play ‹book›" can't confirm the book is playing. Thrown,
/// so Siri presents it as a failure rather than a success.
enum PlayBookIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case stillStarting(title: String)
    case couldNotStart(title: String)

    /// Nil for `.playing`: the intent answers with a dialog instead of throwing.
    nonisolated static func forOutcome(_ outcome: BackgroundPlayOutcome, title: String) -> PlayBookIntentError? {
        switch outcome {
        case .playing: return nil
        case .stillStarting: return .stillStarting(title: title)
        case .couldNotStart: return .couldNotStart(title: title)
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .stillStarting(let title):
            return "“\(title)” is still loading. If it doesn’t start, open ShelfHead."
        case .couldNotStart(let title):
            return "Couldn’t start “\(title)”. Check that your server is reachable, then try again."
        }
    }
}

/// "Hey Siri, play ShelfHead" resumes in the background without bringing the app to
/// the screen (Batch 332). History: Batch 68 made this an `AudioPlaybackIntent` and Siri
/// spun then gave up, so Batch 70 reverted to `AppIntent` + `openAppWhenRun`. That
/// attempt ran `resumeMostRecent()` — a server round-trip from cold with no bound.
/// This one differs in both respects: it takes the widget's proven cold-start path
/// (`playFromWidget()` — local snapshot first, server query only when nothing was ever
/// loaded) and is time-boxed by `resumeInBackground()`, so Siri always gets an answer.
/// Once AVPlayer has started, the audio session keeps the process alive on its own.
/// **[device check]** the Batch 70 regression was only ever observed on hardware.
struct ResumePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Listening"
    static var description = IntentDescription("Resume your most recent audiobook.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackCoordinator.shared.resumeInBackground()
        return .result()
    }
}

/// A book the "Play Audiobook" intent can resolve to. A shadow model over `LibraryItem`
/// — mirrors the widget target's `PinnedBookEntity` (see `WidgetContentIntent.swift`) —
/// exposing only what Siri/Shortcuts need to name and disambiguate a book, not the full
/// media/chapters/progress graph `LibraryItem` carries.
struct AudiobookEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = AudiobookQuery()

    let id: String

    @Property(title: "Title") var title: String
    @Property(title: "Author") var author: String
    @Property(title: "Narrator") var narrator: String?
    @Property(title: "Series") var series: String?

    init(from item: LibraryItem) {
        self.init(id: item.id, fields: AudiobookEntityFields(item))
    }

    init(id: String, fields: AudiobookEntityFields) {
        self.id = id
        self.title = fields.title
        self.author = fields.author
        self.narrator = fields.narrator
        self.series = fields.series
    }

    var fields: AudiobookEntityFields {
        AudiobookEntityFields(title: title, authorName: author, narratorName: narrator, seriesName: series)
    }

    /// Subtitle carries the narrator too, so Siri / Spotlight can tell two editions of the
    /// same title apart. No cover image: resolving one needs the network, and
    /// `displayRepresentation` must stay synchronous and offline-safe (Batch 406).
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(fields.contentDescription)",
                              image: DisplayRepresentation.Image(systemName: "headphones"))
    }

    /// `shelfhead://book/<id>`, the route `ContentView.handleDeepLink` already owns (App
    /// Lock gating included). Pure so it's pinned by `IndexedEntityTests`.
    static func deepLinkURL(forID id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shelfhead"
        components.host = "book"
        components.path = "/" + id
        return components.url
    }
}

/// Batch 406: the pure LibraryItem -> entity/Spotlight field mapping, split out of
/// `AudiobookEntity` so it is unit-testable without a `LibraryItem` graph or App Intents.
/// Narrator/series are nil when absent or blank; `keywords` and `contentDescription`
/// reproduce exactly what `SpotlightIndexer` has always written for a book.
struct AudiobookEntityFields: Equatable {
    let title: String
    let author: String
    let narrator: String?
    let series: String?

    init(title: String, authorName: String, narratorName: String?, seriesName: String?) {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        self.title = title
        self.author = authorName
        self.narrator = clean(narratorName)
        self.series = clean(seriesName)
    }

    init(_ item: LibraryItem) {
        self.init(title: item.title, authorName: item.authorName,
                  narratorName: item.narratorName, seriesName: item.seriesName)
    }

    var keywords: [String] {
        [author] + [narrator, series].compactMap { $0 }
    }

    var contentDescription: String {
        let narrated = narrator.map {
            String(localized: "narrated by \($0)", comment: "Spotlight result description. %@ is the narrator name.")
        }
        return [author, narrated].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Batch 406: lets the system index and reason about books as App Intents entities
/// (`IndexedEntity`: iOS 18.0). Gated because the deployment target is 17.6.
/// `attributeSet` is overridden (not the `@Property(indexingKey:)` route, which would
/// need iOS 18 on the stored properties) so the entity and the hand-built
/// `CSSearchableItem` carry identical text; see `SpotlightIndexer.attributeSet(for:)`.
@available(iOS 18.0, *)
extension AudiobookEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        SpotlightIndexer.attributeSet(for: fields)
    }
}

/// Opens an audiobook's detail page (Siri / Spotlight / Shortcuts "open"). Forwards to the
/// existing `shelfhead://book/<id>` deep link via `OpenURLIntent` so App Lock gating and
/// `finishOpeningBook` stay the single code path. **[device check]**
@available(iOS 18.0, *)
struct OpenAudiobookIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Audiobook"
    static var description = IntentDescription("Open an audiobook's page in ShelfHead.")

    @Parameter(title: "Book")
    var target: AudiobookEntity

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        // `.result()` can't satisfy `OpensIntent`, so the (unreachable in practice) failure
        // case falls back to the Library tab rather than throwing.
        let url = AudiobookEntity.deepLinkURL(forID: target.id) ?? URL(string: "shelfhead://library")!
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// Resolves `AudiobookEntity` values for `PlayAudiobookIntent`. `EntityStringQuery`
/// rather than the widget's `EnumerableEntityQuery` — the widget's pinned-book set is
/// capped and local, but the library here is unbounded and only searchable through the
/// server, so entities are resolved on demand rather than enumerated up front.
struct AudiobookQuery: EntityStringQuery {
    /// Seeds the session from the Keychain first, same as `PlaybackCoordinator
    /// .ensureConfigured()` — Siri can invoke this on a cold launch before the app's own
    /// session-restore has run. Capped so Siri's disambiguation list stays short.
    ///
    /// Searches EVERY library and aggregates, rather than returning from the first one
    /// that yields any hits. The inherited `playByTitle` behaviour (kept when this query
    /// was first written) stopped at the first library with results, which on a
    /// multi-library account meant a title held only in a later library could never be
    /// found — and the picker made that visible in a way the old play-the-single-best-
    /// match path had hidden. Libraries are searched in order and their hits concatenated,
    /// so a book is reachable wherever it lives; ids are deduped defensively in case the
    /// same item is ever reported by two libraries, and the cap is applied once at the end
    /// rather than per library so one big library can't crowd out the others entirely.
    ///
    /// Deliberately serial rather than a `TaskGroup`: accounts here have a handful of
    /// libraries at most, `search` is one request each, and a serial loop keeps this free
    /// of the `Sendable` questions a group over `LibraryItem` would raise under this
    /// project's `targeted` strict-concurrency setting. **[device check]** the added
    /// latency on a multi-library account hasn't been measured against Siri's own budget.
    func entities(matching string: String) async throws -> [AudiobookEntity] {
        await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let libraries = try? await AudiobookshelfAPI.shared.getLibraries() else { return [] }
        var seen = Set<String>()
        var aggregated: [AudiobookEntity] = []
        for library in libraries {
            guard let results = try? await AudiobookshelfAPI.shared.search(libraryId: library.id, query: trimmed) else { continue }
            for item in results where seen.insert(item.id).inserted {
                aggregated.append(AudiobookEntity(from: item))
            }
        }
        return Array(aggregated.prefix(10))
    }

    /// A book that no longer resolves (deleted, or removed from the library since a
    /// shortcut was saved) is omitted rather than thrown on, matching the widget's
    /// `PinnedBookQuery.entities(for:)`.
    func entities(for identifiers: [String]) async throws -> [AudiobookEntity] {
        await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
        var resolved: [AudiobookEntity] = []
        for id in identifiers {
            if let item = try? await AudiobookshelfAPI.shared.getItem(itemId: id) {
                resolved.append(AudiobookEntity(from: item))
            }
        }
        return resolved
    }

    /// Downloaded books only, not a fresh server query — local, instant, and
    /// offline-safe, the same source `CarPlayCoordinator`'s Downloads tab reads from.
    /// `@MainActor` because `DownloadManager` itself is: this hops onto it rather than
    /// making the whole query type actor-isolated.
    ///
    /// Batch 490 (REVIEW 2026-11-11 Y6): in-progress books first (most recently played first,
    /// from the App Group list the app already publishes for widgets — `SharedLibrary`, a
    /// synchronous local read), then downloaded books by title, up to ten.
    @MainActor
    func suggestedEntities() async throws -> [AudiobookEntity] {
        let downloaded = DownloadManager.shared.downloadedLibraryItems()
        let inProgress = SharedLibrary.read().books
        let ids = Self.suggestedIDs(inProgress: inProgress.map { (id: $0.id, lastPlayed: $0.updatedAt) },
                                    downloadedIDs: downloaded.map(\.id))
        let downloadedByID = Dictionary(downloaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let publishedByID = Dictionary(inProgress.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            if let item = downloadedByID[id] { return AudiobookEntity(from: item) }
            guard let book = publishedByID[id] else { return nil }
            return AudiobookEntity(id: id, fields: AudiobookEntityFields(
                title: book.title, authorName: book.author, narratorName: nil, seriesName: nil))
        }
    }

    /// The ordering decision, pure: in-progress ids newest-played first, then the downloaded ids
    /// in their given order, deduped, capped at `limit`.
    nonisolated static func suggestedIDs(inProgress: [(id: String, lastPlayed: Date)],
                                         downloadedIDs: [String], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let recent = inProgress.sorted { $0.lastPlayed > $1.lastPlayed }.map(\.id)
        for id in recent + downloadedIDs where result.count < limit {
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
    }
}

/// "Play a book in ShelfHead" — Siri asks which book (or the phrase names one), then
/// starts it by its resolved server id. (Also usable in the Shortcuts app via the book
/// picker `AudiobookQuery` backs.)
///
/// Batch 495 (REVIEW 2026-11-11 Y2): `AudioPlaybackIntent` without `openAppWhenRun`, so a
/// locked phone no longer asks for an unlock. Batch 68 tried this and Siri spun (Batch 70
/// reverted) because `perform()` waited on an unbounded server round trip. Now it goes
/// through `PlaybackCoordinator.playInBackground(itemId:)`, which answers within 8 s
/// whatever the server does, and only claims success when the book is the live session
/// and playing; otherwise it throws a spoken failure. **[device check]** like Batch 332's
/// `ResumePlaybackIntent`, the Batch 70 failure was only ever seen on hardware.
struct PlayAudiobookIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Audiobook"
    static var description = IntentDescription("Play an audiobook by title.")

    /// An `AppEntity` parameter rather than free text: it gives Shortcuts a real book
    /// picker instead of a bare text field, lets Siri disambiguate between similar
    /// titles via `AudiobookQuery`, and lets the App Shortcut phrase below name the
    /// book directly — none of which a free-text `String` parameter could do.
    @Parameter(title: "Book")
    var book: AudiobookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$book)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await PlaybackCoordinator.shared.playInBackground(itemId: book.id)
        if let error = PlayBookIntentError.forOutcome(outcome, title: book.title) { throw error }
        return .result(dialog: IntentDialog(LocalizedStringResource("Playing “\(book.title)”.")))
    }
}

/// Batch 424: what "Find in Audiobook" should do, decided purely from the search results so the
/// spoiler rule is unit-testable. `bestBeforeFrontier` is the best hit at or before the listener's
/// frontier; `bestAnywhere` is the best hit in the whole book (only consulted when the first is nil).
enum FindInAudiobookOutcome: Equatable {
    case jump(time: Double)
    case noBook
    case noTranscript
    case notFound
    /// Matches exist, but only in a part the listener hasn't reached; don't jump (spoilers).
    case onlyAhead
    /// Found, but the book couldn't be started (offline, or the start failed), so no jump.
    case couldNotPlay

    nonisolated static func decide(hasTranscript: Bool,
                                   bestBeforeFrontier: TranscriptSearchHit?,
                                   bestAnywhere: TranscriptSearchHit?) -> FindInAudiobookOutcome {
        guard hasTranscript else { return .noTranscript }
        if let hit = bestBeforeFrontier { return .jump(time: hit.time) }
        return bestAnywhere != nil ? .onlyAhead : .notFound
    }

    /// The short spoken reply for each outcome.
    var dialog: IntentDialog {
        switch self {
        case .jump:
            return IntentDialog(LocalizedStringResource("Jumping to it."))
        case .noBook:
            return IntentDialog(LocalizedStringResource("There's no audiobook to search. Start one in ShelfHead first."))
        case .noTranscript:
            return IntentDialog(LocalizedStringResource("This book doesn't have a transcript yet. Open it in ShelfHead and tap Transcribe."))
        case .notFound:
            return IntentDialog(LocalizedStringResource("I couldn't find that in this book."))
        case .onlyAhead:
            return IntentDialog(LocalizedStringResource("That only comes up in a part you haven't heard yet."))
        case .couldNotPlay:
            return IntentDialog(LocalizedStringResource("I found it, but couldn't start the book. Try again in ShelfHead."))
        }
    }
}

/// "Find a passage in ShelfHead": searches the book's on-device transcript and jumps back to it.
/// `openAppWhenRun`: it drives the in-app player (and may need to start a book and search a
/// transcript), which a background-only intent can't do reliably.
/// `book` is optional: nil means the current (or last played) book. **[device check]**
struct FindInAudiobookIntent: AppIntent {
    static var title: LocalizedStringResource = "Find in Audiobook"
    static var description = IntentDescription("Jump to a spoken passage in an audiobook by searching its transcript.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Book")
    var book: AudiobookEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$text) in \(\.$book)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await PlaybackCoordinator.shared.find(text: text, itemId: book?.id)
        return .result(dialog: outcome.dialog)
    }
}

/// Review Medium 24 (30 October 2026): spoken/shown to the person when a playback intent has nothing to act on,
/// instead of reporting success after doing nothing.
enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying
    case noSleepTimerTarget
    case pressPlayFirstToSkip
    case pressPlayFirstForSleepTimer

    /// Review 2 Low (Siri): pure choice of sleep-timer failure; a loaded book that can't arm needs play first.
    nonisolated static func sleepTimerError(hasBook: Bool) -> PlaybackIntentError {
        hasBook ? .pressPlayFirstForSleepTimer : .noSleepTimerTarget
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying:
            return "There's no audiobook to skip in. Start one in ShelfHead first."
        case .noSleepTimerTarget:
            return "Start an audiobook first, then set the sleep timer."
        case .pressPlayFirstToSkip:
            return "Press play first, then skip."
        case .pressPlayFirstForSleepTimer:
            return "Press play first, then set the sleep timer."
        }
    }
}

/// Skip back in the current book. `AudioPlaybackIntent` (not plain `AppIntent`) so this
/// also works from the lock screen / while the app is fully terminated, matching
/// `ResumePlaybackIntent` above — a no-op if nothing was ever loaded to skip within.
struct SkipBackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Back"
    static var description = IntentDescription("Skip back in the current audiobook.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackCoordinator.shared.skipFromIntent(forward: false)
        return .result()
    }
}

struct SkipAheadIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward in the current audiobook.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackCoordinator.shared.skipFromIntent(forward: true)
        return .result()
    }
}

/// Start a sleep timer for the current book. Available in the Shortcuts app; the
/// minutes value is a parameter Siri will ask for.
///
/// Batch 495 (REVIEW 2026-11-11 Y3): `LiveActivityIntent`, the protocol ActivityKit documents
/// for starting a Live Activity while the app is in the background, so the countdown appears
/// on the Lock Screen when the timer is set by voice.
struct StartSleepTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Start a sleep timer for the current audiobook.")

    @Parameter(title: "Minutes", default: 30)
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set a \(\.$minutes) minute sleep timer")
    }

    /// Item 33: the largest fixed-minutes duration the in-app sleep timer exposes
    /// anywhere. `SleepTimerOption.presets` (Models/PlayerState.swift) tops out at
    /// `.minutes(60)` — every preset beyond it (`.endOfChapter`, `.chapters(_:)`,
    /// `.endOfBook`) isn't a minutes value at all, and there is no free-entry minutes
    /// field in the player UI (`PlayerView`'s sleep timer menu is presets-only). Siri
    /// had no equivalent ceiling before this fix, so "set a 500 minute sleep timer"
    /// could ask for something the app itself never offers.
    ///
    /// Batch 490 (REVIEW 2026-11-11 Y6): now follows the player's custom-length ceiling
    /// (`SleepTimerOption.customMinutesRange`, 1...180) so "set a 90 minute sleep timer"
    /// is no longer silently cut to 60.
    static let maxSleepTimerMinutes = SleepTimerOption.customMinutesRange.upperBound

    /// The decision half of Item 33's fix — pure, so it can be pinned by a test
    /// independent of `AppIntents`/`AudioPlayerService`. `0` or a negative value used to
    /// sail straight through to `AudioPlayerService.setSleepTimer`, which (per its own
    /// countdown) fires on the very next tick — "Hey Siri, set a 0 minute sleep timer"
    /// paused playback about a second after it started, with nothing telling the user
    /// why. A value above `maxSleepTimerMinutes` is capped rather than rejected: the
    /// user asked for *more* sleep than the app exposes anywhere, not for nothing.
    enum MinutesValidation: Equatable {
        /// Already within `1...maxSleepTimerMinutes` — used exactly as requested.
        case valid(Int)
        /// Above `maxSleepTimerMinutes` — silently capped down to it.
        case capped(Int)
        /// Below 1 minute — rejected outright; there's no sensible value to clamp up to.
        case tooLow
    }

    static func validatedSleepTimerMinutes(_ requested: Int) -> MinutesValidation {
        if requested < 1 { return .tooLow }
        if requested > maxSleepTimerMinutes { return .capped(maxSleepTimerMinutes) }
        return .valid(requested)
    }

    /// Batch 490 (REVIEW 2026-11-11 Y6): the confirmation names the value actually set, so a
    /// capped request says so. Pure for tests.
    nonisolated static func confirmationMinutes(for validation: MinutesValidation) -> Int? {
        switch validation {
        case .tooLow: return nil
        case .valid(let value), .capped(let value): return value
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let validation = StartSleepTimerIntent.validatedSleepTimerMinutes(minutes)
        guard let value = StartSleepTimerIntent.confirmationMinutes(for: validation) else {
            throw $minutes.needsValueError("Choose at least 1 minute")
        }
        try await PlaybackCoordinator.shared.setSleepTimerFromIntent(minutes: value)
        let dialog = value == 1
            ? IntentDialog(LocalizedStringResource("Sleep timer set for 1 minute."))
            : IntentDialog(LocalizedStringResource("Sleep timer set for \(value) minutes."))
        return .result(dialog: dialog)
    }
}

// iOS 27 `@AppIntent(schema: .audio.playAudio)` was tried here (Batch 332) and backed
// out: the metadata processor requires `audioEntity`, `playbackAttributes`,
// `queueLocation` and `warmupAudioQueueResult` parameters, i.e. the full
// search → warm-up-queue → play contract, which isn't documented offline yet. The
// phrase-based `ResumePlaybackIntent` above is the shipped "Hey Siri, play ShelfHead".

struct ShelfHeadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                // The bare "Play <app>" phrase — otherwise Siri treats "play ShelfHead"
                // as a generic media request the app doesn't implement.
                "Play \(.applicationName)",
                "Play in \(.applicationName)",
                "Resume \(.applicationName)",
                "Continue \(.applicationName)",
                "Continue my audiobook in \(.applicationName)",
                "Play my book in \(.applicationName)"
            ],
            shortTitle: "Resume Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayAudiobookIntent(),
            phrases: [
                // Now that `book` is an AppEntity parameter, a phrase can name it
                // directly. At least one phrase below still has no parameter, so the
                // intent stays reachable (Siri then asks which book) when the user
                // doesn't name one up front.
                "Play \(\.$book) in \(.applicationName)",
                "Play a book in \(.applicationName)",
                "Play an audiobook in \(.applicationName)"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: FindInAudiobookIntent(),
            phrases: [
                // Batch 424: phrases can only interpolate AppEntity/AppEnum parameters, never
                // the free-text `text`, so Siri asks for it. (`book` is optional, and an
                // optional entity in a phrase is not documented as allowed, so none name it.)
                "Find a passage in \(.applicationName)",
                "Search my audiobook in \(.applicationName)",
                "Go back to a part of my book in \(.applicationName)"
            ],
            shortTitle: "Find in Audiobook",
            systemImageName: "text.magnifyingglass"
        )
        // Review 2026-08-19: these were "gobackward.15"/"goforward.30" — the same
        // hardcoded-interval bug P3-6/WATCH-5/the widget fix each caught on their own
        // surface, on the one surface none of them covered. Unlike those, this can't be
        // routed through `SkipLabels`: `appShortcuts` is read by the system when the app
        // is *installed* to populate the Shortcuts catalog, so `systemImageName` has to
        // be a static string and would not re-render when the user later changes their
        // interval — resolving it from `SettingsStore` here would just bake in whatever
        // the value happened to be at install time, which is a subtler version of the
        // same lie. The number-free "gobackward"/"goforward" symbols (both real, and
        // already what `PlaybackSettingsSection` uses next to the interval pickers) say
        // exactly as much as is actually knowable at this point.
        AppShortcut(
            intent: SkipBackIntent(),
            phrases: ["Skip back in \(.applicationName)"],
            shortTitle: "Skip Back",
            systemImageName: "gobackward"
        )
        AppShortcut(
            intent: SkipAheadIntent(),
            phrases: ["Skip ahead in \(.applicationName)"],
            shortTitle: "Skip Forward",
            systemImageName: "goforward"
        )
        AppShortcut(
            intent: StartSleepTimerIntent(),
            phrases: [
                // `minutes` defaults to 30, so these work unspoken — Siri uses the
                // default rather than prompting for a number.
                "Set a sleep timer in \(.applicationName)",
                "Start a sleep timer in \(.applicationName)",
                "Sleep timer in \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
    }
}


/// PL-14: the pure half of the `INPlayMediaIntent` hand-off from `ShelfHeadIntents`. The
/// extension can't share code with the app (it's a separate process and target), so the two
/// agree on these strings; a test pins them against the extension's `IntentHandler`.
enum PlayMediaRequest {
    static let activityType = "INPlayMediaIntent"
    static let mediaNameKey = "mediaName"

    /// The spoken title from an activity's `userInfo`, trimmed; nil when absent or blank.
    static func mediaName(from userInfo: [AnyHashable: Any]?) -> String? {
        mediaName(userInfo?[mediaNameKey] as? String)
    }

    /// The spoken title as Siri delivered it (`INMediaSearch.mediaName`), trimmed; nil when
    /// absent or blank.
    static func mediaName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
