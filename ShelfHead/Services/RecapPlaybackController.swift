import Foundation
import AVFoundation

/// Batch 433: plays the rendered "Previously On…" montage like a real track.
///
/// The montage is one audio file played by its own `AVPlayer` at the book's playback speed. While it
/// plays, this controller is `AudioPlayerService.transientOverride`: remote play/pause/skip (Lock
/// Screen, Control Center, CarPlay, headphones, the iOS 27 session backend) reach it instead of the
/// book, and Now Playing shows "Previously On…" with the book's cover. The book is paused first and,
/// when `resumesBookAfter` is set, resumed at the end. Asking the book itself to play (in-app play
/// button, widget, Siri) ends the recap without resuming it (`overrideYieldToBook`).
@MainActor
@Observable
final class RecapPlaybackController: TransientPlaybackOverride {
    static let shared = RecapPlaybackController()

    enum Phase: Equatable {
        case idle
        /// Getting the program and rendering it, 0...1.
        case preparing(Double)
        case playing
        case paused
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var itemId: String?
    private(set) var manifest: RecapAudioManifest?
    private(set) var currentMarkIndex: Int?
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var resumesBookAfter = false

    /// Shown as the Now Playing subtitle.
    private(set) var bookTitle = ""

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var prepareTask: Task<(url: URL, manifest: RecapAudioManifest), Error>?
    /// True while `finish()` hands playback back to the book, so its `play()` can't be intercepted.
    @ObservationIgnored private var isResumingBook = false
    /// The session `interceptResumeIfNeeded` last looked at: it decides once per loaded book, so a
    /// later resume in the same session (an hour's pause) never replays a recap.
    @ObservationIgnored private var evaluatedSessionId: String?

    private init() {}

    // MARK: - Transient override (what the Now Playing surfaces read)

    var overrideTitle: String {
        String(localized: "Previously On…", comment: "Now Playing title while the narrator's recap montage plays")
    }
    var overrideSubtitle: String { bookTitle }
    var overrideElapsed: Double { elapsed }
    var overrideDuration: Double { duration }
    var overrideIsPlaying: Bool { phase == .playing }

    /// Active = something is playing or paused (not still preparing).
    var isActive: Bool { phase == .playing || phase == .paused }

    func overridePlay() {
        guard phase == .paused, let player else { return }
        activateSessionIfNeeded()
        player.playImmediately(atRate: AudioPlayerService.shared.playbackRate)
        phase = .playing
        AudioPlayerService.shared.refreshNowPlaying()
    }

    func overridePause() {
        guard phase == .playing, let player else { return }
        player.pause()
        phase = .paused
        AudioPlayerService.shared.refreshNowPlaying()
    }

    func overrideTogglePlayPause() {
        if phase == .playing { overridePause() } else { overridePlay() }
    }

    func overrideSkip(forward: Bool) {
        guard isActive, let manifest else { return }
        if let target = RecapTimeline.skipTarget(forward: forward, elapsed: elapsed, marks: manifest.marks) {
            seek(to: target)
        } else if forward {
            finish()
        }
    }

    func overrideYieldToBook() {
        resumesBookAfter = false
        teardown(clearOverride: true)
        phase = .idle
    }

    // MARK: - Start / stop

    /// Prepares (program + render, or the cached file) and plays. `phase` follows along; errors end
    /// in `.failed(message)`.
    func start(itemId: String, title: String, author: String, summary: String, resumeBookAfter: Bool) async {
        teardown(clearOverride: true)
        self.itemId = itemId
        bookTitle = title
        resumesBookAfter = resumeBookAfter
        manifest = nil
        elapsed = 0
        duration = 0
        currentMarkIndex = nil
        phase = .preparing(0)

        let task = Task {
            try await self.prepare(itemId: itemId, title: title, author: author, summary: summary, progressScale: 0.7)
        }
        prepareTask = task
        let result = await task.result
        if prepareTask == task { prepareTask = nil }

        switch result {
        case .success(let rendered):
            // Superseded (stop(), or another start) while rendering.
            guard !task.isCancelled, itemId == self.itemId, case .preparing = phase else { return }
            begin(url: rendered.url, manifest: rendered.manifest)
        case .failure(let error):
            guard !(error is CancellationError), !task.isCancelled, itemId == self.itemId else {
                if case .preparing = phase { phase = .idle }
                return
            }
            if let error = error as? BookIntelligenceError {
                phase = .failed(error.reason.message)
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Ends the recap (or cancels preparing) without resuming the book.
    func stop() {
        guard phase != .idle else { return }
        resumesBookAfter = false
        teardown(clearOverride: true)
        phase = .idle
        AudioPlayerService.shared.refreshNowPlaying()
    }

    // MARK: - Preparing

    private func prepare(itemId: String, title: String, author: String, summary: String,
                         progressScale: Double) async throws -> (url: URL, manifest: RecapAudioManifest) {
        let voice = Self.voiceIdentifier(itemId: itemId)
        let program = try await BookIntelligence.shared.recapProgram(
            itemId: itemId, title: title, author: author, summary: summary,
            spokenLinks: SettingsStore.recapSpokenLinks,
            progress: { [weak self] fraction in
                guard let self, case .preparing = self.phase else { return }
                self.phase = .preparing(min(max(fraction, 0), 1) * progressScale)
            })
        return try await renderOrCached(program: program, itemId: itemId, voice: voice)
    }

    private func renderOrCached(program: RecapProgram, itemId: String,
                                voice: String?) async throws -> (url: URL, manifest: RecapAudioManifest) {
        let programHasClips = program.items.contains { if case .clip = $0 { return true } else { return false } }
        let cached = RecapAudioRenderer.cached(itemId: itemId, programHash: program.inputHash, voiceIdentifier: voice)
        if let cached, cached.manifest.hasNarratorAudio || !programHasClips { return cached }
        if case .preparing = phase { phase = .preparing(0.75) }
        // Batch 435: a streamed book that isn't loaded can be cut too (`clipStreamSource`), so a
        // speech-only fallback cached while offline is remade once the server is reachable.
        let source = programHasClips ? await clipStreamSource(itemId: itemId) : nil
        if let cached, Self.cacheIsUsable(hasNarratorAudio: cached.manifest.hasNarratorAudio,
                                          programHasClips: programHasClips,
                                          canCutNow: QuoteClipExporter.hasLocalAudio(itemId: itemId) || source != nil) {
            return cached
        }
        let rendered = try await RecapAudioRenderer.render(
            program: program, itemId: itemId, voiceIdentifier: voice,
            streamAsset: source?.asset, streamTracks: source?.tracks)
        if case .preparing = phase { phase = .preparing(1) }
        return rendered
    }

    /// Batch 435: streaming sources for cutting clips when the book isn't downloaded. The loaded book
    /// uses the player's own session URLs. Any other book asks the server for its audio files and is
    /// cut from them directly: ranged reads of `/api/items/<id>/file/<ino>` (the URL a direct-play
    /// session's tracks use; byte ranges confirmed against ABS), with the player's auth headers and
    /// its opt-in URL token. Nil offline, for a downloaded book (its local files win anyway), or when
    /// a file has no duration (clip times couldn't be mapped onto it).
    private func clipStreamSource(itemId: String) async
        -> (asset: (Int) -> AVURLAsset?, tracks: [(index: Int, startOffset: Double, duration: Double)])? {
        if let loaded = AudioPlayerService.shared.recapStreamSource(forItemId: itemId) { return loaded }
        guard !QuoteClipExporter.hasLocalAudio(itemId: itemId) else { return nil }
        guard let item = try? await AudiobookshelfAPI.shared.getItem(itemId: itemId),
              let files = item.media?.audioFiles, !files.isEmpty else { return nil }
        let ordered = files.sorted { ($0.index ?? 0) < ($1.index ?? 0) }   // DownloadManager's order
        guard let layout = Self.streamLayout(durations: ordered.map(\.duration)) else { return nil }
        let serverURL = AuthStore.shared.serverURL
        let token = AuthStore.shared.accessToken
        var headers = AuthStore.shared.customHeaders
        headers["Authorization"] = "Bearer \(token)"
        var assets: [Int: AVURLAsset] = [:]
        for (position, file) in ordered.enumerated() {
            guard let ino = file.ino else { continue }
            var path = "\(serverURL)/api/items/\(DownloadPaths.strictPathComponentEncode(itemId))"
                + "/file/\(DownloadPaths.strictPathComponentEncode(ino))"
            if SettingsStore.streamWithURLToken { path += "?token=\(token)" }
            guard let url = URL(string: path) else { continue }
            assets[position] = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        guard !assets.isEmpty else { return nil }
        return ({ assets[$0] }, layout)
    }

    /// Track layout for files played back to back, by array position: each starts where the last
    /// ended. Nil when any duration is missing or not positive.
    nonisolated static func streamLayout(durations: [Double?]) -> [(index: Int, startOffset: Double, duration: Double)]? {
        var cursor = 0.0
        var layout: [(index: Int, startOffset: Double, duration: Double)] = []
        for (index, duration) in durations.enumerated() {
            guard let duration, duration > 0 else { return nil }
            layout.append((index, cursor, duration))
            cursor += duration
        }
        return layout.isEmpty ? nil : layout
    }

    /// Whether narrator audio can be cut without the network: the book is downloaded or is the one in
    /// the player. Overnight pre-rendering only runs then.
    private func canCutClips(itemId: String) -> Bool {
        QuoteClipExporter.hasLocalAudio(itemId: itemId) || AudioPlayerService.shared.currentItemId == itemId
    }

    private static func voiceIdentifier(itemId: String) -> String? {
        SpeechReader.bestVoice(localeIdentifier: BookIntelligence.shared.transcriptLocaleIdentifier(itemId: itemId))?
            .identifier
    }

    /// Overnight warm-up: makes and renders the recap for a book without playing it. Needs narrator
    /// audio to be cuttable (downloaded, or the loaded book); otherwise it would only cache a
    /// speech-only fallback. Errors are logged, never shown.
    func prerender(itemId: String, title: String, author: String) async {
        guard canCutClips(itemId: itemId) else {
            ShelfLog.info(.storage, "Recap pre-render skipped: no narrator audio available offline")
            return
        }
        do {
            let summary = try await BookIntelligence.shared.recap(itemId: itemId, title: title, author: author)
            let program = try await BookIntelligence.shared.recapProgram(
                itemId: itemId, title: title, author: author, summary: summary,
                spokenLinks: SettingsStore.recapSpokenLinks)
            _ = try await renderOrCached(program: program, itemId: itemId, voice: Self.voiceIdentifier(itemId: itemId))
        } catch is CancellationError {
            return
        } catch {
            ShelfLog.error(.storage, "Recap pre-render failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-play on resume

    /// Auto-play only with the setting on, the usual "away long enough, not offered since" rule, and a
    /// recap that is already rendered: resuming never waits for rendering.
    nonisolated static func shouldAutoPlay(settingOn: Bool, lastListened: Date?, now: Date, frontier: Double,
                                           lastOfferedAt: Date?, hasRenderedRecap: Bool) -> Bool {
        guard settingOn, hasRenderedRecap else { return false }
        return RecapPlanner.shouldOffer(lastListened: lastListened, now: now, frontier: frontier,
                                        lastOfferedAt: lastOfferedAt)
    }

    /// A cached rendered file may be reused unless it is a speech-only fallback made when no narrator
    /// audio could be cut and the program wants clips that can be cut now.
    nonisolated static func cacheIsUsable(hasNarratorAudio: Bool, programHasClips: Bool, canCutNow: Bool) -> Bool {
        hasNarratorAudio || !programHasClips || !canCutNow
    }

    /// Called at the top of `AudioPlayerService.play()`. When the book being resumed qualifies and its
    /// recap is already cached, starts the recap (book resumes after it) and returns true so `play()`
    /// stops there. Looks at each loaded session once.
    func interceptResumeIfNeeded() -> Bool {
        guard !isResumingBook, SettingsStore.recapAutoPlay, phase == .idle else { return false }
        let service = AudioPlayerService.shared
        guard service.transientOverride == nil, let session = service.currentSession,
              let itemId = service.currentItemId else { return false }
        guard evaluatedSessionId != session.id else { return false }
        evaluatedSessionId = session.id

        // Best source for "when did they last listen": the progress the session was opened with, or
        // a downloaded book's own last-update stamp.
        let lastUpdateMs = session.libraryItem?.mediaProgress?.lastUpdate.map { Double($0) }
            ?? DownloadManager.shared.manifest(for: itemId)?.lastUpdate
        let lastListened = lastUpdateMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        let now = Date()
        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        let offeredAt = BookIntelligence.lastOfferedAt(itemId: itemId)
        // Cheap checks first; the disk reads only matter for a book that really qualifies.
        guard RecapPlanner.shouldOffer(lastListened: lastListened, now: now, frontier: frontier,
                                       lastOfferedAt: offeredAt),
              let program = BookIntelligence.cachedRecapProgram(itemId: itemId) else { return false }
        let voice = Self.voiceIdentifier(itemId: itemId)
        let rendered = RecapAudioRenderer.cached(itemId: itemId, programHash: program.inputHash, voiceIdentifier: voice)
        guard Self.shouldAutoPlay(settingOn: true, lastListened: lastListened, now: now, frontier: frontier,
                                  lastOfferedAt: offeredAt, hasRenderedRecap: rendered != nil),
              let rendered else { return false }

        BookIntelligence.markOffered(itemId: itemId)
        self.itemId = itemId
        bookTitle = session.libraryItem?.title ?? ""
        resumesBookAfter = true
        begin(url: rendered.url, manifest: rendered.manifest)
        return true
    }

    // MARK: - Playback

    private func begin(url: URL, manifest: RecapAudioManifest) {
        teardown(clearOverride: false)
        let item = AVPlayerItem(url: url)
        // The book's own player leaves `audioTimePitchAlgorithm` at its default; match it so speed
        // sounds the same here.
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        self.manifest = manifest
        duration = manifest.duration
        elapsed = 0
        currentMarkIndex = RecapTimeline.currentMarkIndex(at: 0, marks: manifest.marks)

        let service = AudioPlayerService.shared
        service.transientOverride = self
        // Pause the book after the override is set so its pause publishes the recap, not the book.
        if service.isPlaying { service.pause() }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fail() }
        }
        // Half a second: each tick republishes Now Playing through the observed `elapsed`, the same
        // cadence the book's own time updates use.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in self?.tick(seconds) }
        }

        activateSessionIfNeeded()
        player.playImmediately(atRate: service.playbackRate)
        phase = .playing
        service.refreshNowPlaying()
    }

    private func tick(_ seconds: Double) {
        guard let player, let manifest, seconds.isFinite else { return }
        elapsed = min(max(seconds, 0), duration)
        let index = RecapTimeline.currentMarkIndex(at: elapsed, marks: manifest.marks)
        if index != currentMarkIndex { currentMarkIndex = index }
        // Speed changes made while the recap plays (Siri, CarPlay, headphones) apply here.
        if phase == .playing {
            let rate = AudioPlayerService.shared.playbackRate
            if player.rate != 0, player.rate != rate { player.rate = rate }
            // Review 6 Low (recap paused externally): reflect a pause made elsewhere; never resume.
            if player.rate == 0, player.timeControlStatus == .paused { phase = .paused }
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = min(max(seconds, 0), duration)
        elapsed = target
        if let manifest { currentMarkIndex = RecapTimeline.currentMarkIndex(at: target, marks: manifest.marks) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        AudioPlayerService.shared.refreshNowPlaying()
    }

    /// The montage ended (or the last mark was skipped past): hand back to the book.
    private func finish() {
        guard isActive else { return }
        let resume = resumesBookAfter
        teardown(clearOverride: true)
        phase = .idle
        let service = AudioPlayerService.shared
        service.refreshNowPlaying()
        if resume {
            // `play()` asks `interceptResumeIfNeeded()` first; this flag (plus markOffered and the
            // once-per-session rule) keeps it from starting the recap again.
            isResumingBook = true
            service.play()
            isResumingBook = false
        }
    }

    private func fail() {
        guard isActive else { return }
        let resume = resumesBookAfter
        teardown(clearOverride: true)
        phase = .failed(String(localized: "The recap stopped unexpectedly.",
                               comment: "Previously On… montage error: playback of the rendered recap failed"))
        AudioPlayerService.shared.refreshNowPlaying()
        if resume {
            isResumingBook = true
            AudioPlayerService.shared.play()
            isResumingBook = false
        }
    }

    private func teardown(clearOverride: Bool) {
        prepareTask?.cancel()
        prepareTask = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        player?.pause()
        player = nil
        if clearOverride, AudioPlayerService.shared.transientOverride === self {
            AudioPlayerService.shared.transientOverride = nil
        }
    }

    /// The book's audio session is normally already configured and active; after a cold launch
    /// (auto-play at the very start) `AVPlayer` activates it itself on play, so nothing is needed
    /// beyond making sure the category is playback.
    private func activateSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
    }
}
