import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import WidgetKit

@Observable
final class AudioPlayerService {
    static let shared = AudioPlayerService()

    private var player: AVPlayer?
    private var playerItems: [AVPlayerItem] = []
    private var timeObserver: Any?
    private var syncTimer: Timer?
    private var sleepTimer: Timer?

    // Playback state
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var bufferedTime: Double = 0
    var playbackRate: Float = 1.0

    // Session
    var currentSession: PlaybackSession?
    var currentItemId: String?
    var currentTrackIndex: Int = 0
    private var lastSyncTime: Double = 0
    private var timeListenedSinceSync: Double = 0
    private var pausedAt: Date?   // for smart rewind on resume
    private var statusObservation: NSKeyValueObservation?  // waits for item readiness before seeking
    private var hasReachedResumePosition = true            // gates sync until we've seeked to the resume point
    private var streamRecoveryAttempts = 0                 // guards the stream-failure reload (e.g. expired token)
    private var lastStreamRecoveryAt: Date?

    // Skip intervals (seconds), seeded from user settings.
    private var skipForwardInterval: Double = SettingsStore.skipForwardInterval
    private var skipBackwardInterval: Double = SettingsStore.skipBackwardInterval

    // Sleep timer
    var sleepTimerOption: SleepTimerOption = .off
    var sleepTimerRemaining: TimeInterval = 0

    private init() {
        setupRemoteTransportControls()
        setupNotifications()
        setupWidgetControlBridge()
    }

    /// Listens for the widget's play/pause button (a Darwin notification posted by
    /// TogglePlaybackIntent) and toggles playback. Delivered while the app is alive
    /// in the background.
    private func setupWidgetControlBridge() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { AudioPlayerService.shared.togglePlayPause() }
            },
            "com.shelfhead.togglePlayback" as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { AudioPlayerService.shared.skipForward() }
            },
            "com.shelfhead.skipForward" as CFString, nil, .deliverImmediately
        )
    }

    // MARK: - Playback Control

    func startPlayback(session: PlaybackSession, startTime: Double? = nil) {
        currentSession = session
        currentItemId = session.libraryItemId ?? session.libraryItem?.id
        guard let tracks = session.audioTracks, !tracks.isEmpty else { return }

        let startOffset = startTime ?? session.currentTime ?? 0
        duration = session.duration ?? 0

        // Find the correct track based on startOffset
        var accumulatedTime: Double = 0
        var targetTrackIndex = 0
        var trackSeekTime: Double = 0

        for (index, track) in tracks.enumerated() {
            let trackStart = track.startOffset ?? accumulatedTime
            let trackDuration = track.duration ?? 0

            if startOffset >= trackStart && startOffset < trackStart + trackDuration {
                targetTrackIndex = index
                trackSeekTime = startOffset - trackStart
                break
            }
            accumulatedTime += trackDuration
        }

        currentTrackIndex = targetTrackIndex
        // Reflect the resume position immediately so the lock screen / widget / sync
        // never momentarily report 0 (which previously wiped server progress).
        currentTime = startOffset
        hasReachedResumePosition = false
        streamRecoveryAttempts = 0
        loadAndPlayTrack(at: targetTrackIndex, seekTo: trackSeekTime)

        // Load cover art for lock screen / Dynamic Island
        if let itemId = session.libraryItemId {
            loadNowPlayingArtwork(for: itemId)
        } else if let itemId = session.libraryItem?.id {
            loadNowPlayingArtwork(for: itemId)
        }
    }

    private func loadAndPlayTrack(at index: Int, seekTo time: Double = 0, autoPlay: Bool = true) {
        guard let tracks = currentSession?.audioTracks, index < tracks.count else { return }

        guard let resolved = assetURL(forTrackAt: index) else { return }

        let asset: AVURLAsset
        if let headers = resolved.headers {
            asset = AVURLAsset(url: resolved.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: resolved.url)
        }
        let playerItem = AVPlayerItem(asset: asset)

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        statusObservation?.invalidate()
        statusObservation = nil

        let trackStart = tracks[index].startOffset ?? 0
        currentTime = trackStart + time
        hasReachedResumePosition = (time <= 0)
        setupTimeObserver()

        // Seek to the resume point (if any) and begin playback ONLY once the item is
        // ready. Calling play()/seek before `.readyToPlay` is unreliable and can leave
        // the player paused or stuck at 0 — the cause of "won't play, just sits there".
        let startWhenReady: () -> Void = { [weak self] in
            guard let self else { return }
            if time > 0 {
                let target = CMTime(seconds: time, preferredTimescale: 600)
                let tol = CMTime(seconds: 1, preferredTimescale: 600)
                self.player?.seek(to: target, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.hasReachedResumePosition = true
                        if autoPlay { self.play() }
                        self.updateNowPlaying()
                    }
                }
            } else {
                if autoPlay { self.play() }
                self.updateNowPlaying()
            }
        }

        if playerItem.status == .readyToPlay {
            startWhenReady()
        } else {
            statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    DispatchQueue.main.async { startWhenReady() }
                case .failed:
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    DispatchQueue.main.async {
                        self.hasReachedResumePosition = true
                        #if DEBUG
                        print("[Player] item failed: \(item.error?.localizedDescription ?? "unknown")")
                        #endif
                    }
                default:
                    break
                }
            }
        }

        updateNowPlaying()
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

        // 3) Stream from the server. Put the token in the query string (ABS accepts
        // ?token=) so it rides along on every byte-range request — AVPlayer often drops
        // a custom Authorization header on its range/redirect follow-ups, which the
        // server then rejects (401 → aborted connection). Keep the header too.
        let serverURL = AuthStore.shared.serverURL
        let token = AuthStore.shared.accessToken
        let separator = contentUrl.contains("?") ? "&" : "?"
        let urlString = "\(serverURL)\(contentUrl)\(separator)token=\(token)"
        guard let url = URL(string: urlString) else { return nil }
        let headers = ["Authorization": "Bearer \(token)"]
        return (url, headers)
    }

    func play() {
        activateAudioSession()
        // Smart rewind: nudge back a few seconds based on how long we were paused.
        if let pausedAt {
            let rewind = SettingsStore.smartRewindAmount(pausedFor: Date().timeIntervalSince(pausedAt))
            if rewind > 0 { seek(to: max(0, currentTime - rewind)) }
        }
        pausedAt = nil
        player?.volume = 1   // restore in case a sleep fade lowered it
        player?.playImmediately(atRate: playbackRate)
        isPlaying = true
        setKeepAwake(true)
        startPeriodicSync()   // run the 15s progress sync only while actually playing
        updateNowPlaying()
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        pausedAt = Date()
        setKeepAwake(false)
        syncProgress()          // one final sync of the current position
        stopPeriodicSync()      // then stop waking every 15s so the app can suspend (saves battery)
        updateNowPlaying()
    }

    private func setKeepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on && SettingsStore.keepScreenAwake
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
              let tracks = session.audioTracks else { return }

        // Find the correct track
        var accumulatedTime: Double = 0
        for (index, track) in tracks.enumerated() {
            let trackStart = track.startOffset ?? accumulatedTime
            let trackDuration = track.duration ?? 0

            if time >= trackStart && time < trackStart + trackDuration {
                let trackSeekTime = time - trackStart

                if index != currentTrackIndex {
                    currentTrackIndex = index
                    loadAndPlayTrack(at: index, seekTo: trackSeekTime, autoPlay: isPlaying)
                } else {
                    let cmTime = CMTime(seconds: trackSeekTime, preferredTimescale: 1000)
                    player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    currentTime = time
                }
                return
            }
            accumulatedTime += trackDuration
        }
    }

    func skipForward(_ seconds: Double? = nil) {
        let amount = seconds ?? skipForwardInterval
        let newTime = min(currentTime + amount, duration)
        seek(to: newTime)
    }

    func skipBackward(_ seconds: Double? = nil) {
        let amount = seconds ?? skipBackwardInterval
        let newTime = max(currentTime - amount, 0)
        seek(to: newTime)
    }

    /// Re-read skip intervals from settings and update the lock-screen controls.
    func refreshSkipIntervals() {
        skipForwardInterval = SettingsStore.skipForwardInterval
        skipBackwardInterval = SettingsStore.skipBackwardInterval
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
        if let next = chapters.first(where: { $0.start > currentTime + 0.5 }) {
            seek(to: next.start)
        } else {
            seek(to: duration)
        }
    }

    func skipToPreviousChapter() {
        guard let chapters = currentSession?.chapters, !chapters.isEmpty else {
            skipBackward()
            return
        }
        // If we're more than 3s into the current chapter, restart it; otherwise go to the previous one.
        let currentStart = chapters.last(where: { $0.start <= currentTime })?.start ?? 0
        if currentTime - currentStart > 3 {
            seek(to: currentStart)
        } else if let prev = chapters.last(where: { $0.start < currentStart - 0.5 }) {
            seek(to: prev.start)
        } else {
            seek(to: 0)
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
        updateNowPlaying()
    }

    func stop() {
        syncProgress()
        closeSession()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()
        stopPeriodicSync()
        cancelSleepTimer()
        setKeepAwake(false)
        statusObservation?.invalidate()
        statusObservation = nil
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
        SharedPlayback.write(nil)
        WidgetCenter.shared.reloadAllTimelines()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Sleep Timer

    func setSleepTimer(_ option: SleepTimerOption) {
        cancelSleepTimer()
        sleepTimerOption = option

        switch option {
        case .off:
            sleepTimerRemaining = 0
        case .minutes(let mins):
            sleepTimerRemaining = TimeInterval(mins * 60)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isPlaying else { return }   // don't tick down or fade while paused
                    self.sleepTimerRemaining -= 1
                    self.applySleepFade()
                    if self.sleepTimerRemaining <= 0 {
                        self.pause()
                        self.cancelSleepTimer()
                    }
                }
            }
        case .endOfChapter:
            // Will be handled in time observer
            sleepTimerRemaining = -1
            break
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerOption = .off
        sleepTimerRemaining = 0
        player?.volume = 1   // undo any sleep fade
    }

    /// Gradually lowers volume in the final seconds before the sleep timer fires.
    private func applySleepFade() {
        guard SettingsStore.sleepFadeOut else { return }
        let window: TimeInterval = 20
        if sleepTimerRemaining > 0 && sleepTimerRemaining <= window {
            player?.volume = Float(sleepTimerRemaining / window)
        } else {
            player?.volume = 1
        }
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.updateCurrentTime(time)
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
        // Count actual content listened, which scales with playback rate (the observer
        // fires every 0.5s of wall time; at 2x that's ~1.0s of book per tick).
        timeListenedSinceSync += 0.5 * Double(playbackRate)

        // Sustained playback clears the stream-recovery counter so a later token
        // expiry can recover again (without allowing a tight fail/reload loop).
        if streamRecoveryAttempts > 0, let last = lastStreamRecoveryAt,
           Date().timeIntervalSince(last) > 60 {
            streamRecoveryAttempts = 0
        }

        // Check for end of chapter sleep timer
        if sleepTimerOption == .endOfChapter {
            if let chapters = currentSession?.chapters,
               let currentChapter = chapters.first(where: { currentTime >= $0.start && currentTime < $0.end }) {
                sleepTimerRemaining = currentChapter.end - currentTime
                applySleepFade()
                if sleepTimerRemaining <= 0.5 {
                    pause()
                    cancelSleepTimer()
                }
            }
        }

        // Check if current track ended, move to next. Defer to the next run-loop pass so
        // we don't call replaceCurrentItem from inside this item's own time-observer
        // callback (which can assert/deadlock on some iOS versions).
        if let trackDuration = tracks[currentTrackIndex].duration,
           trackTime >= trackDuration - 0.5 {
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
            pause()
            syncProgress()
            // Don't offer this book for resume on next launch — it's complete.
            SharedPlayback.write(nil)
        }
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
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.syncProgress()
        }
    }

    private func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func syncProgress() {
        guard let session = currentSession else { return }

        // Don't sync a bogus position: before the resume seek has landed, or a
        // near-zero time while a real position exists. This was wiping server progress.
        guard hasReachedResumePosition, currentTime > 1 else { return }

        let listened = timeListenedSinceSync
        timeListenedSinceSync = 0

        // Always keep local resume position current (works offline).
        if let itemId = currentItemId, DownloadManager.shared.isDownloaded(itemId: itemId) {
            DownloadManager.shared.updateLocalProgress(itemId: itemId, currentTime: currentTime)
        }

        // Offline sessions have no server session to sync to.
        guard !session.id.hasPrefix("offline-") else { return }

        Task {
            try? await AudiobookshelfAPI.shared.syncSession(
                sessionId: session.id,
                currentTime: currentTime,
                timeListened: listened,
                duration: duration
            )
        }
    }

    private func closeSession() {
        guard let session = currentSession, !session.id.hasPrefix("offline-"),
              hasReachedResumePosition, currentTime > 1 else { return }
        Task {
            try? await AudiobookshelfAPI.shared.closeSession(
                sessionId: session.id,
                currentTime: currentTime,
                timeListened: timeListenedSinceSync,
                duration: duration
            )
        }
    }

    // MARK: - Now Playing Info

    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingCoverData: Data?  // small JPEG shared with the widget

    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }

        // Next/previous track controls map to chapter navigation.
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipToNextChapter()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipToPreviousChapter()
            return .success
        }
    }

    private func updateNowPlaying() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentSession?.libraryItem?.title ?? "Unknown"
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentSession?.libraryItem?.authorName ?? ""
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        // Set artwork if we have it
        if let artwork = nowPlayingArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // Share the snapshot with the Home/Lock-Screen widget (no-op until an App Group is configured).
        SharedPlayback.write(.init(
            itemId: currentItemId ?? "",
            title: currentSession?.libraryItem?.title ?? "",
            author: currentSession?.libraryItem?.authorName ?? "",
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            updatedAt: Date(),
            coverData: nowPlayingCoverData
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Fetches the cover image from the server and sets it as Now Playing artwork
    func loadNowPlayingArtwork(for itemId: String) {
        let serverURL = AuthStore.shared.serverURL
        let token = AuthStore.shared.accessToken
        guard let url = URL(string: "\(serverURL)/api/items/\(itemId)/cover?width=600&token=\(token)") else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { return }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                // Downscale for the widget snapshot (keep App Group storage small).
                let widgetImage = image.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? image
                let coverData = widgetImage.jpegData(compressionQuality: 0.7)

                await MainActor.run {
                    // Guard against a slow fetch landing after the user switched books,
                    // which would show the previous title's cover.
                    guard self.currentItemId == itemId else { return }
                    self.nowPlayingArtwork = artwork
                    self.nowPlayingCoverData = coverData
                    self.updateNowPlaying()
                }
            } catch {
                // Non-critical — lock screen just won't show artwork
            }
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        // A streamed item that fails mid-playback is most often an expired access token
        // (the token is baked into the asset URL). Refresh and reload from the current
        // position. Guarded/capped so non-auth failures can't loop.
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleStreamFailure()
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                self?.pause()
            case .ended:
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self?.play()
                    }
                }
            @unknown default:
                break
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
            if reason == .oldDeviceUnavailable, self?.isPlaying == true {
                self?.pause()
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

        streamRecoveryAttempts += 1
        lastStreamRecoveryAt = Date()
        let trackStart = tracks[currentTrackIndex].startOffset ?? 0
        let resumeAt = max(0, currentTime - trackStart)
        let wasPlaying = isPlaying
        let index = currentTrackIndex

        Task {
            await AudiobookshelfAPI.shared.ensureFreshAccessToken(force: true)
            await MainActor.run {
                self.loadAndPlayTrack(at: index, seekTo: resumeAt, autoPlay: wasPlaying)
            }
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
