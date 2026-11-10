import Foundation
import BackgroundTasks

/// Batch 406: background app refresh. Auto-download of Continue Listening, per-series
/// auto-download and the offline progress/bookmark queue flush used to run only while the
/// app was open; this lets iOS wake the app now and then to do the same.
///
/// Wiring (see `ShelfHeadApp`): the SwiftUI `Scene.backgroundTask(.appRefresh(identifier))`
/// modifier (iOS 16.0) runs `perform()`; `schedule()` is called when the scene goes to
/// `.background` and again at the end of every run, because a refresh request is one-shot
/// and iOS keeps at most one pending refresh request (a new `submit` replaces it).
/// `.backgroundTask` registers its own handler with the system, so there is no
/// `BGTaskScheduler.register` call here — registering the same identifier twice crashes.
///
/// Budget: the system gives a refresh task roughly 30 seconds. When it runs out it cancels
/// the task that runs the modifier's action, so every step checks `Task.isCancelled` and
/// the awaits underneath (URLSession async) throw on cancellation. Downloads started here
/// are background `URLSession` transfers and continue on their own after the task ends.
enum BackgroundRefreshScheduler {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let identifier = "com.justin.ShelfHead.refresh"

    private static let idleKey = "backgroundRefresh_lastRunWasIdle"

    // MARK: - Pure decisions

    enum Decision: Equatable {
        case run
        case skipSignedOut
        case skipOffline
        case skipCancelled
    }

    /// Whether a refresh should do any work. Signed-out beats offline so the log says
    /// the more fundamental reason.
    nonisolated static func shouldRun(signedIn: Bool, hasNetwork: Bool, isCancelled: Bool = false) -> Decision {
        if isCancelled { return .skipCancelled }
        if !signedIn { return .skipSignedOut }
        if !hasNetwork { return .skipOffline }
        return .run
    }

    /// Earliest-begin delay for the next request. iOS decides the real time from usage
    /// patterns and battery; this is only the floor. 2 h while there was something to do,
    /// 4 h backing off once a run found nothing, and 6 h when signed out (nothing to
    /// refresh until the user returns to the app, which reschedules on its own).
    nonisolated static func refreshInterval(lastRunWasIdle: Bool, signedIn: Bool = true) -> TimeInterval {
        if !signedIn { return 6 * 3600 }
        return lastRunWasIdle ? 4 * 3600 : 2 * 3600
    }

    nonisolated static func nextEarliestBeginDate(
        now: Date, lastRunWasIdle: Bool, signedIn: Bool = true
    ) -> Date {
        now.addingTimeInterval(refreshInterval(lastRunWasIdle: lastRunWasIdle, signedIn: signedIn))
    }

    // MARK: - Scheduling

    /// Submits the next refresh request. Safe to call repeatedly: per Apple, submitting a
    /// request for an unexecuted task already in the queue replaces it.
    /// `AudiobookshelfAPI` is an actor, so the signed-in read hops to it in a Task; callers
    /// (the scene-phase hook, `perform()`'s `defer`) stay synchronous.
    @MainActor
    static func schedule() {
        Task { @MainActor in
            submit(signedIn: await AudiobookshelfAPI.shared.isConfigured)
        }
    }

    @MainActor
    private static func submit(signedIn: Bool) {
        let idle = UserDefaults.standard.bool(forKey: idleKey)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = nextEarliestBeginDate(
            now: Date(), lastRunWasIdle: idle, signedIn: signedIn)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // `.unavailable` is normal (Background App Refresh off, Simulator); not worth an alarm.
            ShelfLog.info(.sync, "Background refresh not scheduled: \(error.localizedDescription)")
        }
    }

    // MARK: - The refresh

    /// Runs in the `.backgroundTask` action. Always reschedules before returning, whether
    /// it did work, skipped, or was cancelled mid-way.
    @MainActor
    static func perform() async {
        defer { schedule() }

        // Cold background launch: the app's session may not be restored yet. Same Keychain
        // seed CarPlay and Siri use (`PlaybackCoordinator.ensureConfigured`).
        await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
        // High 2 (30 Oct 2026): downloads may have bootstrapped before that seed.
        DownloadManager.shared.reloadIfScopeChanged()

        let signedIn = await AudiobookshelfAPI.shared.isConfigured
        let decision = shouldRun(
            signedIn: signedIn,
            hasNetwork: NetworkMonitor.shared.isConnected,
            isCancelled: Task.isCancelled)
        guard decision == .run else {
            ShelfLog.info(.sync, "Background refresh skipped: \(decision)")
            return
        }
        ShelfLog.info(.sync, "Background refresh started")

        // 1. Offline queues. `awaitPendingWrites` drains PendingProgressQueue (conflict
        //    hold-back included) and waits for it; BookmarkSyncService.flush guards itself.
        await AudioPlayerService.shared.awaitPendingWrites()
        guard !Task.isCancelled else { return }
        await BookmarkSyncService.shared.flush()
        guard !Task.isCancelled else { return }

        // 2. Auto-downloads. `DownloadManager.autoDownloadIfEnabled` and
        //    `autoDownloadIfAllowed` both check `autoDownloadPolicyAllows` (Wi-Fi only and
        //    charging only) and skip books already downloaded or downloading, so the
        //    background path inherits the same gates as the foreground one.
        var startedSomething = false
        do {
            let inProgress = try await AudiobookshelfAPI.shared.getItemsInProgress(limit: 10)
            guard !Task.isCancelled else { return }
            DownloadManager.shared.ensureSessionReady()

            let before = DownloadManager.shared.activeDownloads.count
            DownloadManager.shared.autoDownloadIfEnabled(inProgress)

            // Per-series: the foreground path (`PlayerViewModel.maybeAutoDownloadNextInSeries`)
            // keys off the current book; here every in-progress book's series stands in.
            var seenSeries = Set<String>()
            for book in inProgress {
                guard !Task.isCancelled else { break }
                guard let series = book.seriesName, let libraryId = book.libraryId,
                      SettingsStore.seriesAutoDownloadEnabled(series),
                      seenSeries.insert("\(libraryId)|\(series)").inserted,
                      let match = try? await AudiobookshelfAPI.shared.findSeries(libraryId: libraryId, matching: series),
                      let books = match.books,
                      let next = books.nextUnfinishedInSeries(after: book, seriesName: series) else { continue }
                DownloadManager.shared.autoDownloadIfAllowed(next)
            }
            startedSomething = DownloadManager.shared.activeDownloads.count > before

            // 3. Widget data: same publish `LibraryViewModel` does, progress merged from /api/me.
            if !inProgress.isEmpty, !Task.isCancelled {
                let progress = (try? await AudiobookshelfAPI.shared.getCurrentUser())?.mediaProgress ?? []
                let byItem = Dictionary(progress.map { ($0.libraryItemId, $0) }, uniquingKeysWith: { a, _ in a })
                WidgetLibraryPublisher.publishContinueListening(inProgress) { byItem[$0] }
            }
        } catch {
            ShelfLog.error(.sync, "Background refresh fetch failed: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(!startedSomething, forKey: idleKey)
        ShelfLog.info(.sync, "Background refresh finished (startedDownloads: \(startedSomething))")
    }
}
