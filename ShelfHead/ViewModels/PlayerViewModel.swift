import Foundation

@Observable
final class PlayerViewModel {
    private let playerService = AudioPlayerService.shared

    var currentBook: LibraryItem?
    var showFullPlayer = false
    var isLoadingSession = false
    var errorMessage: String?
    var isResuming = false // true when continuing a previously started book

    // Restored-but-not-yet-loaded state: after the app is relaunched we show the last
    // book in the mini-player at its saved position, ready to resume on play.
    private var restoredCurrentTime: Double = 0
    private var restoredDuration: Double = 0

    /// True when a book is shown (e.g. restored on launch) but no live session exists yet.
    var isAwaitingResume: Bool { currentBook != nil && playerService.currentSession == nil }

    // Playback state (proxied from service, falling back to the restored snapshot).
    var isPlaying: Bool { playerService.isPlaying }
    var currentTime: Double { playerService.currentSession != nil ? playerService.currentTime : restoredCurrentTime }
    var duration: Double { playerService.currentSession != nil ? playerService.duration : restoredDuration }
    var playbackRate: Float { playerService.playbackRate }
    var currentChapter: Chapter? { playerService.currentChapter }
    var chapters: [Chapter] { playerService.chapters }
    var sleepTimerOption: SleepTimerOption { playerService.sleepTimerOption }
    var sleepTimerRemaining: TimeInterval { playerService.sleepTimerRemaining }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    /// Restores the last-played book into the mini-player on launch (paused, ready to
    /// resume), reading the snapshot persisted in the App Group. Skips books that look
    /// finished so a completed title doesn't reappear.
    func restoreLastSession() {
        guard currentBook == nil, playerService.currentSession == nil,
              let snap = SharedPlayback.read(), !snap.itemId.isEmpty,
              snap.progress < 0.985 else { return }

        restoredCurrentTime = snap.currentTime
        restoredDuration = snap.duration
        currentBook = LibraryItem(
            id: snap.itemId, ino: nil, libraryId: nil, mediaType: "book",
            media: Media(
                metadata: MediaMetadata(
                    title: snap.title, subtitle: nil, authorName: snap.author, narratorName: nil,
                    seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
                    language: nil, genres: nil, isbn: nil, asin: nil
                ),
                coverPath: nil, duration: snap.duration, chapters: [],
                audioFiles: nil, numChapters: 0, numAudioFiles: 0
            ),
            numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: nil
        )
    }

    var remainingTime: Double {
        max(0, duration - currentTime)
    }

    // MARK: - Playback Actions

    func startPlayback(for item: LibraryItem) async {
        errorMessage = nil

        // Respect the cellular-streaming preference (downloaded books always allowed).
        if !DownloadManager.shared.isDownloaded(itemId: item.id),
           !SettingsStore.allowCellularStreaming,
           NetworkMonitor.shared.isConnected, !NetworkMonitor.shared.isOnWiFi {
            errorMessage = "Streaming on cellular is off. Download this book or connect to Wi-Fi."
            return
        }

        isLoadingSession = true

        // Detect if this is a resume (item has existing progress)
        isResuming = item.progressPercent > 0 && !item.isFinished

        // Keep the access token fresh for streamed playback — the token is embedded in
        // the AVPlayer asset URL and expires ~hourly. Skipped for downloads/offline.
        if !DownloadManager.shared.isDownloaded(itemId: item.id), NetworkMonitor.shared.isConnected {
            await AudiobookshelfAPI.shared.ensureFreshAccessToken()
        }

        do {
            let session = try await AudiobookshelfAPI.shared.startPlaybackSession(itemId: item.id)
            currentBook = item
            playerService.startPlayback(session: session, startTime: resolvedStartTime(for: item, session: session))
            applyDefaultSpeed()
            showFullPlayer = true
        } catch {
            // No server session — if the book is downloaded, play it fully offline.
            if let offlineSession = DownloadManager.shared.localSession(for: item.id) {
                currentBook = item
                playerService.startPlayback(session: offlineSession, startTime: offlineSession.currentTime)
                applyDefaultSpeed()
                showFullPlayer = true
            } else {
                errorMessage = "Failed to start playback: \(error.localizedDescription)"
            }
        }

        isLoadingSession = false
    }

    /// Chooses the resume position, preferring locally-saved offline progress when
    /// it is newer than the server's (last-write-wins by `lastUpdate`).
    private func resolvedStartTime(for item: LibraryItem, session: PlaybackSession) -> Double {
        let serverTime = session.currentTime ?? 0
        guard let book = DownloadManager.shared.manifest(for: item.id),
              let localMs = book.lastUpdate else {
            return serverTime
        }
        let serverMs = Double(item.mediaProgress?.lastUpdate ?? 0)
        return localMs > serverMs ? book.currentTime : serverTime
    }

    /// Apply the remembered speed for this book (falling back to the global default).
    private func applyDefaultSpeed() {
        guard let id = currentBook?.id else { return }
        let speed = SettingsStore.resolvedSpeed(forItem: id)
        playerService.setPlaybackRate(Float(speed))
    }

    func resumePlayback(for item: LibraryItem) async {
        await startPlayback(for: item)
    }

    func togglePlayPause() {
        // If this is a book restored on launch (no live session yet), load + resume it.
        if isAwaitingResume, let book = currentBook {
            Task { await startPlayback(for: book) }
            return
        }
        playerService.togglePlayPause()
    }

    func skipForward() {
        playerService.skipForward()
    }

    func skipBackward() {
        playerService.skipBackward()
    }

    func seek(to time: Double) {
        playerService.seek(to: time)
    }

    func seekToChapter(_ chapter: Chapter) {
        playerService.seek(to: chapter.start)
    }

    // MARK: - Bookmarks

    var bookmarks: [AudioBookmark] = []

    func loadBookmarks() async {
        guard let id = currentBook?.id else { bookmarks = []; return }
        bookmarks = (try? await AudiobookshelfAPI.shared.getBookmarks(itemId: id)) ?? []
    }

    func addBookmarkAtCurrentTime() async {
        guard let id = currentBook?.id else { return }
        let title = currentChapter?.title ?? currentTime.formattedTime
        try? await AudiobookshelfAPI.shared.addBookmark(itemId: id, time: currentTime, title: title)
        await loadBookmarks()
    }

    func deleteBookmark(_ bookmark: AudioBookmark) async {
        try? await AudiobookshelfAPI.shared.deleteBookmark(itemId: bookmark.libraryItemId, time: bookmark.time)
        await loadBookmarks()
    }

    func seekToBookmark(_ bookmark: AudioBookmark) {
        playerService.seek(to: bookmark.time)
    }

    func nextChapter() {
        playerService.skipToNextChapter()
    }

    func previousChapter() {
        playerService.skipToPreviousChapter()
    }

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        playerService.setPlaybackRate(Float(speed.rawValue))
        // Remember this speed for the current book.
        if let id = currentBook?.id {
            SettingsStore.setSpeed(speed.rawValue, forItem: id)
        }
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        playerService.setSleepTimer(option)
    }

    func stop() {
        playerService.stop()
        currentBook = nil
        showFullPlayer = false
    }
}
