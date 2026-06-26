import Foundation
import Observation

/// Delegate for the background download session. Forwards events to `DownloadManager`
/// and trusts the user's (possibly self-signed) server certificate.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private func itemId(from task: URLSessionTask) -> (id: String, track: Int)? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|")
        guard parts.count == 2, let track = Int(parts[1]) else { return nil }
        return (String(parts[0]), track)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = itemId(from: downloadTask) else { return }
        DownloadManager.shared.trackProgress(itemId: info.id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let info = itemId(from: downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            DownloadManager.shared.trackFailed(itemId: info.id, message: "Server returned HTTP \(http.statusCode).")
            return
        }
        // Must move the temp file synchronously while `location` is still valid.
        DownloadManager.shared.storeFinishedTrack(from: location, itemId: info.id, trackIndex: info.track)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = itemId(from: task) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let ns = error as NSError
        // A dropped connection usually provides resume data — continue from where we
        // left off rather than failing/restarting.
        let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let detail = "\(error.localizedDescription) (code \(ns.code))"
        #if DEBUG
        print("[Download] track \(info.id)|\(info.track) error code \(ns.code): \(error.localizedDescription)")
        #endif
        DownloadManager.shared.retryOrFail(itemId: info.id, trackIndex: info.track,
                                           resumeData: resumeData, message: detail)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            DownloadManager.shared.backgroundCompletionHandler?()
            DownloadManager.shared.backgroundCompletionHandler = nil
        }
    }
}

@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    var activeDownloads: [String: DownloadTask] = [:]
    var downloadedItems: Set<String> = []
    /// Surfaced to the UI (as a toast) when a download fails, so failures aren't silent.
    var downloadError: String?

    private let fileManager = FileManager.default
    /// In-memory cache of manifests, keyed by item id.
    private var manifests: [String: DownloadedBook] = [:]

    /// Stored by the app delegate so we can tell the system we're done after a
    /// background download completes while the app was suspended.
    var backgroundCompletionHandler: (() -> Void)?

    /// Background session: downloads continue when the app is suspended or closed, and
    /// the system manages connectivity/retries. Safe here because the server uses a
    /// trusted (Let's Encrypt) certificate, so the daemon validates TLS normally.
    /// Dropped connections are additionally resumed via resume-data retry (see retryOrFail).
    /// The identifier must stay stable so the session reconnects to in-flight tasks on relaunch.
    @ObservationIgnored private lazy var sessionDelegate = DownloadSessionDelegate()
    @ObservationIgnored private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.shelfhead.download")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false                  // run now, don't defer for power/Wi-Fi
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 6        // download multi-file books in parallel
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()
    /// Resume-retry attempts keyed by "itemId|trackIndex".
    @ObservationIgnored private var retryCounts: [String: Int] = [:]
    /// Original download URL per "itemId|trackIndex", so a track can be restarted
    /// from scratch when the failure provides no resume data (e.g. a TLS reset).
    @ObservationIgnored private var trackURLs: [String: URL] = [:]
    private let maxRetries = 6

    private init() {
        loadDownloadedItems()
    }

    /// Touch the session so it's recreated (and reconnects to outstanding tasks)
    /// on launch and when the system delivers background events.
    func ensureSessionReady() { _ = downloadSession }

    // MARK: - Public API

    func downloadBook(_ item: LibraryItem) {
        guard activeDownloads[item.id] == nil, !isDownloaded(itemId: item.id) else { return }
        activeDownloads[item.id] = DownloadTask(itemId: item.id, title: item.title)
        Task { await enqueueDownload(item) }
    }

    /// Auto-downloads the given items if the setting is enabled (and Wi-Fi if required).
    func autoDownloadIfEnabled(_ items: [LibraryItem]) {
        guard SettingsStore.autoDownloadContinueListening else { return }
        if SettingsStore.wifiOnlyDownloads && !NetworkMonitor.shared.isOnWiFi { return }
        for item in items where !isDownloaded(itemId: item.id) && !isDownloading(itemId: item.id) {
            downloadBook(item)
        }
    }

    func cancelDownload(itemId: String) {
        downloadSession.getAllTasks { tasks in
            for task in tasks where (task.taskDescription?.hasPrefix("\(itemId)|") ?? false) {
                task.cancel()
            }
        }
        activeDownloads[itemId]?.isCancelled = true
        activeDownloads.removeValue(forKey: itemId)
        try? fileManager.removeItem(at: downloadDirectory(for: itemId))
    }

    func removeDownload(itemId: String) {
        let itemDir = downloadDirectory(for: itemId)
        try? fileManager.removeItem(at: itemDir)
        downloadedItems.remove(itemId)
        manifests.removeValue(forKey: itemId)
        saveDownloadedItems()
    }

    func removeAllDownloads() {
        for itemId in downloadedItems {
            try? fileManager.removeItem(at: downloadDirectory(for: itemId))
        }
        downloadedItems.removeAll()
        manifests.removeAll()
        saveDownloadedItems()
    }

    /// Total bytes used by all downloaded audio files + manifests.
    func totalStorageUsed() -> Int64 {
        let root = downloadsRoot()
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func formattedStorageUsed() -> String {
        ByteCountFormatter.string(fromByteCount: totalStorageUsed(), countStyle: .file)
    }

    func isDownloaded(itemId: String) -> Bool {
        downloadedItems.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        activeDownloads[itemId] != nil
    }

    func progress(for itemId: String) -> Double {
        activeDownloads[itemId]?.progress ?? 0
    }

    /// The real container extension for a track (from the manifest's original
    /// filename), e.g. "m4b"/"mp3". AVFoundation needs a recognizable extension to
    /// identify a *local* file's format — a generic ".audio" name fails to play.
    private func trackExtension(itemId: String, trackIndex: Int) -> String {
        let name = manifest(for: itemId)?.tracks.first(where: { $0.index == trackIndex })?.filename ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "m4b" : ext
    }

    /// Destination file for a downloaded track, named with its real extension.
    private func trackFileURL(itemId: String, trackIndex: Int) -> URL {
        downloadDirectory(for: itemId)
            .appendingPathComponent("track_\(trackIndex).\(trackExtension(itemId: itemId, trackIndex: trackIndex))")
    }

    func localFileURL(itemId: String, trackIndex: Int) -> URL? {
        let target = trackFileURL(itemId: itemId, trackIndex: trackIndex)
        if fileManager.fileExists(atPath: target.path) { return target }
        // Migrate a legacy ".audio" file (which AVPlayer can't identify) to the real
        // extension so it becomes playable without a re-download.
        let legacy = downloadDirectory(for: itemId).appendingPathComponent("track_\(trackIndex).audio")
        if fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: target)
            return fileManager.fileExists(atPath: target.path) ? target : legacy
        }
        return nil
    }

    /// A locally-cached cover file (saved at download time) so downloaded books
    /// show their artwork with no network. Nil if not cached.
    func localCoverURL(itemId: String) -> URL? {
        // Fast path: only downloaded items can have a cached cover. This avoids a
        // filesystem stat for every non-downloaded cell during fast grid scrolling
        // (shelfCoverURL calls this for every cover).
        guard downloadedItems.contains(itemId) else { return nil }
        let cover = downloadDirectory(for: itemId).appendingPathComponent("cover.jpg")
        return fileManager.fileExists(atPath: cover.path) ? cover : nil
    }

    /// The saved manifest for a downloaded book (title, chapters, tracks, progress).
    func manifest(for itemId: String) -> DownloadedBook? {
        if let cached = manifests[itemId] { return cached }
        let url = downloadDirectory(for: itemId).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode(DownloadedBook.self, from: data) else {
            return nil
        }
        manifests[itemId] = book
        return book
    }

    /// A LibraryItem (with cached progress) for a downloaded book — for listing it
    /// in the Library/Downloads and opening it offline.
    func libraryItem(for itemId: String) -> LibraryItem? {
        manifest(for: itemId)?.asLibraryItem()
    }

    /// All downloaded books as LibraryItems, title-sorted.
    func downloadedLibraryItems() -> [LibraryItem] {
        downloadedItems
            .compactMap { manifest(for: $0)?.asLibraryItem() }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Builds a fully-offline playback session from local files.
    func localSession(for itemId: String) -> PlaybackSession? {
        guard let book = manifest(for: itemId) else { return nil }
        return book.localSession { [weak self] index in
            self?.localFileURL(itemId: itemId, trackIndex: index)
        }
    }

    /// Persist the last playback position so an offline resume is accurate.
    func updateLocalProgress(itemId: String, currentTime: Double) {
        guard var book = manifest(for: itemId) else { return }
        book.currentTime = currentTime
        book.lastUpdate = Date().timeIntervalSince1970 * 1000
        manifests[itemId] = book
        writeManifest(book, for: itemId)
    }

    private func writeManifest(_ book: DownloadedBook, for itemId: String) {
        let url = downloadDirectory(for: itemId).appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(book) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Last-write-wins reconciliation between local (offline) progress and the
    /// server's progress. Pushes newer local progress up; pulls newer server
    /// progress down into the manifest.
    func reconcile(serverProgress: [String: MediaProgress]) async {
        // Snapshot ids so we don't mutate the set while iterating (auto-delete below).
        for itemId in Array(downloadedItems) {
            guard var book = manifest(for: itemId) else { continue }
            let server = serverProgress[itemId]
            let serverMs = Double(server?.lastUpdate ?? 0)
            let localMs = book.lastUpdate ?? 0

            if localMs > serverMs, book.currentTime > 0, book.duration > 0 {
                // Local is newer — push it to the server.
                let progress = min(book.currentTime / book.duration, 1.0)
                try? await AudiobookshelfAPI.shared.updateProgress(
                    libraryItemId: itemId,
                    progress: progress,
                    currentTime: book.currentTime,
                    duration: book.duration,
                    isFinished: server?.isFinished ?? false
                )
            } else if serverMs > localMs, let server {
                // Server is newer — update the local manifest.
                book.currentTime = server.currentTime ?? book.currentTime
                book.lastUpdate = serverMs
                manifests[itemId] = book
                writeManifest(book, for: itemId)
            }
        }

        // Auto-delete finished downloads (not the one currently playing).
        if SettingsStore.autoDeleteFinished {
            let playingId = AudioPlayerService.shared.currentItemId
            let finished = Array(downloadedItems).filter {
                serverProgress[$0]?.isFinished == true && $0 != playingId
            }
            if !finished.isEmpty {
                await MainActor.run {
                    for itemId in finished { removeDownload(itemId: itemId) }
                }
            }
        }
    }

    // MARK: - Download Logic (background URLSession)

    /// Fetches the item, writes the manifest up front, then enqueues a background
    /// download task per audio file. Completion is handled by the session delegate
    /// (so it survives app suspension/relaunch).
    private func enqueueDownload(_ item: LibraryItem) async {
        guard AuthStore.shared.isConfigured else {
            await MainActor.run { _ = activeDownloads.removeValue(forKey: item.id); downloadError = "You're not signed in." }
            return
        }
        let serverURL = AuthStore.shared.serverURL
        let token = AuthStore.shared.accessToken

        do {
            let detail = try await AudiobookshelfAPI.shared.getItem(itemId: item.id)
            guard let audioFiles = detail.media?.audioFiles, !audioFiles.isEmpty else {
                await MainActor.run {
                    _ = activeDownloads.removeValue(forKey: item.id)
                    downloadError = "No audio files were returned for “\(item.title)”."
                }
                return
            }
            let ordered = audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            let itemDir = downloadDirectory(for: item.id)
            try? fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)

            // Build + persist the manifest immediately so completion checks work even
            // if the app is relaunched in the background mid-download.
            var tracks: [DownloadedBook.DownloadedTrack] = []
            var offset: Double = 0
            for (index, file) in ordered.enumerated() {
                let dur = file.duration ?? 0
                tracks.append(.init(index: index, startOffset: offset, duration: dur,
                                    filename: file.metadata?.filename ?? "track_\(index)"))
                offset += dur
            }
            let manifest = DownloadedBook(
                id: item.id, title: detail.title, author: detail.authorName,
                narrator: detail.narratorName, duration: detail.duration,
                chapters: detail.chapters, tracks: tracks,
                currentTime: detail.currentTime,
                lastUpdate: detail.mediaProgress?.lastUpdate.map(Double.init)
            )
            writeManifest(manifest, for: item.id)
            await MainActor.run { manifests[item.id] = manifest }

            // Cache the cover art for offline display (best-effort; build the remote
            // URL directly so we don't pick up a not-yet-written local file).
            if let coverURL = URL(string: "\(serverURL)/api/items/\(item.id)/cover?width=600&token=\(token)"),
               let (coverData, _) = try? await URLSession.shared.data(from: coverURL), !coverData.isEmpty {
                try? coverData.write(to: itemDir.appendingPathComponent("cover.jpg"), options: .atomic)
            }

            // Enqueue a background task per missing track.
            for (index, file) in ordered.enumerated() {
                let dest = trackFileURL(itemId: item.id, trackIndex: index)
                if fileManager.fileExists(atPath: dest.path) { continue }
                guard let ino = file.ino,
                      let url = URL(string: "\(serverURL)/api/items/\(item.id)/file/\(ino)/download") else { continue }
                let key = "\(item.id)|\(index)"
                trackURLs[key] = url
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let task = downloadSession.downloadTask(with: request)
                task.taskDescription = key
                task.resume()
            }

            // If everything was already on disk, finalize now.
            await MainActor.run { finalizeIfComplete(itemId: item.id) }
        } catch {
            await MainActor.run {
                _ = activeDownloads.removeValue(forKey: item.id)
                downloadError = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Delegate callbacks (called from the background session delegate)

    func trackProgress(itemId: String, written: Int64, expected: Int64) {
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        DispatchQueue.main.async {
            guard let manifest = self.manifest(for: itemId) else { return }
            let total = max(manifest.tracks.count, 1)
            let done = self.completedTrackCount(itemId: itemId)
            self.activeDownloads[itemId]?.progress = min(1.0, (Double(done) + fraction) / Double(total))
        }
    }

    /// Move the finished temp file into place. Called synchronously on the delegate
    /// queue while `location` is still valid.
    func storeFinishedTrack(from location: URL, itemId: String, trackIndex: Int) {
        let dir = downloadDirectory(for: itemId)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = trackFileURL(itemId: itemId, trackIndex: trackIndex)
        if fileManager.fileExists(atPath: dest.path) { try? fileManager.removeItem(at: dest) }
        try? fileManager.moveItem(at: location, to: dest)
        DispatchQueue.main.async {
            let key = "\(itemId)|\(trackIndex)"
            self.retryCounts[key] = nil
            self.trackURLs[key] = nil
            self.finalizeIfComplete(itemId: itemId)
        }
    }

    func trackFailed(itemId: String, message: String) {
        DispatchQueue.main.async {
            let total = self.manifest(for: itemId)?.tracks.count ?? 0
            guard self.completedTrackCount(itemId: itemId) < total else { return } // already done
            self.activeDownloads.removeValue(forKey: itemId)
            self.downloadError = "Couldn't download. \(message)"
        }
    }

    /// On a dropped connection, resume from where we stopped (up to `maxRetries`),
    /// otherwise surface the failure.
    func retryOrFail(itemId: String, trackIndex: Int, resumeData: Data?, message: String) {
        DispatchQueue.main.async {
            let key = "\(itemId)|\(trackIndex)"
            // Don't retry if this track already finished, or the whole download was cancelled.
            guard self.activeDownloads[itemId] != nil else { return }
            let attempts = self.retryCounts[key] ?? 0

            if attempts < self.maxRetries {
                self.retryCounts[key] = attempts + 1
                let task: URLSessionDownloadTask
                if let resumeData {
                    // Continue from where it dropped.
                    task = self.downloadSession.downloadTask(withResumeData: resumeData)
                } else if let url = self.trackURLs[key] {
                    // No resume data (e.g. a TLS reset) — restart the track from scratch.
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(AuthStore.shared.accessToken)", forHTTPHeaderField: "Authorization")
                    task = self.downloadSession.downloadTask(with: request)
                } else {
                    self.failPermanently(itemId: itemId, message: message)
                    return
                }
                task.taskDescription = key
                // Resume immediately — a delayed retry can't fire while the app is
                // suspended, and the background session already paces connectivity.
                task.resume()
                return
            }
            self.failPermanently(itemId: itemId, message: message)
        }
    }

    private func failPermanently(itemId: String, message: String) {
        retryCounts = retryCounts.filter { !$0.key.hasPrefix("\(itemId)|") }
        let total = manifest(for: itemId)?.tracks.count ?? 0
        guard completedTrackCount(itemId: itemId) < total else { return }
        activeDownloads.removeValue(forKey: itemId)
        downloadError = "Couldn't download (connection kept dropping). \(message)"
    }

    private func completedTrackCount(itemId: String) -> Int {
        guard let manifest = manifest(for: itemId) else { return 0 }
        let dir = downloadDirectory(for: itemId)
        return manifest.tracks.indices.filter { idx in
            fileManager.fileExists(atPath: trackFileURL(itemId: itemId, trackIndex: idx).path)
                || fileManager.fileExists(atPath: dir.appendingPathComponent("track_\(idx).audio").path)
        }.count
    }

    private func finalizeIfComplete(itemId: String) {
        guard let manifest = manifest(for: itemId) else { return }
        let total = manifest.tracks.count
        let done = completedTrackCount(itemId: itemId)
        activeDownloads[itemId]?.progress = total > 0 ? Double(done) / Double(total) : 0
        if total > 0 && done == total {
            activeDownloads.removeValue(forKey: itemId)
            downloadedItems.insert(itemId)
            saveDownloadedItems()
        }
    }

    // MARK: - Storage

    private func downloadsRoot() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ShelfHead/Downloads")
    }

    private func downloadDirectory(for itemId: String) -> URL {
        downloadsRoot().appendingPathComponent(itemId)
    }

    private func loadDownloadedItems() {
        if let data = UserDefaults.standard.data(forKey: "shelfhead_downloadedItems"),
           let items = try? JSONDecoder().decode(Set<String>.self, from: data) {
            downloadedItems = items
        }
    }

    private func saveDownloadedItems() {
        if let data = try? JSONEncoder().encode(downloadedItems) {
            UserDefaults.standard.set(data, forKey: "shelfhead_downloadedItems")
        }
    }
}

// MARK: - Download Task

@Observable
final class DownloadTask: Identifiable {
    let id: String
    let title: String
    var progress: Double = 0
    var isCancelled = false

    init(itemId: String, title: String) {
        self.id = itemId
        self.title = title
    }
}
