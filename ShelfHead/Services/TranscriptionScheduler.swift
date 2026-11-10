import BackgroundTasks
import Foundation
import UIKit

/// Phase 1 Section A: background execution for transcription.
///
/// Two triggers, both feeding `TranscriptionCenter.runJob`:
/// - **Transcribe now** (iOS 26 `BGContinuedProcessingTask`): submitted from the tap, shows a
///   system Live Activity with progress and a cancel button, keeps running after the app is
///   backgrounded. No GPU resources are requested (CPU + Neural Engine only). If submission
///   fails, the work runs in-process for as long as the app stays alive.
/// - **Overnight** (`BGProcessingTask`, external power): scheduled when the app backgrounds
///   while downloaded books still lack a transcript.
///
/// Registration: `registerHandlers()` must run before launch finishes (`ShelfHeadApp.init`) and
/// registers the overnight id. A continued task is registered differently: its handler goes in
/// at submit time under the task's own unique identifier (`submitUserInitiated`). Batch 424:
/// registering the `.*` wildcard itself is refused ("not advertised in the application's
/// Info.plist"), and submitting a request with no handler for its identifier is an uncaught
/// `NSInternalInconsistencyException`; that crashed Transcribe on the iPhone (Batch 422 build).
/// Only these NEW identifiers are registered here. The refresh id
/// `com.justin.ShelfHead.refresh` is registered by SwiftUI's `.backgroundTask` and must never
/// be registered a second time (it crashes).
enum TranscriptionScheduler {
    /// Wildcard form, as listed in `BGTaskSchedulerPermittedIdentifiers`. A continued task's
    /// actual identifier is `<prefix><unique suffix>` (see `BGContinuedProcessingTaskRequest`).
    nonisolated static let continuedWildcardIdentifier = "com.justin.ShelfHead.transcribe.*"
    nonisolated static let continuedPrefix = "com.justin.ShelfHead.transcribe."
    nonisolated static let overnightIdentifier = "com.justin.ShelfHead.transcribe-overnight"

    private struct PendingJob { let itemId: String; let title: String }
    /// Submitted continued-task requests waiting for their launch handler, by identifier.
    private static var pending: [String: PendingJob] = [:]
    private static var overnightRunner: Task<Void, Never>?

    // MARK: - Registration

    nonisolated static func registerHandlers() {
        guard #available(iOS 26.0, *) else { return }
        let scheduler = BGTaskScheduler.shared
        let okOvernight = scheduler.register(forTaskWithIdentifier: overnightIdentifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await runOvernight(processing) }
        }
        if !okOvernight {
            ShelfLog.error(.playback, "Overnight transcription task registration refused; check BGTaskSchedulerPermittedIdentifiers")
        }
    }

    // MARK: - Transcribe now

    /// Called from `TranscriptionCenter.transcribeNow` (a user tap, app in the foreground).
    static func submitUserInitiated(itemId: String, title: String) {
        guard #available(iOS 26.0, *) else { return }
        let identifier = continuedPrefix + uniqueSuffix(for: itemId)
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title,
            subtitle: String(localized: "Preparing transcript…", comment: "Subtitle of the system progress activity while transcribing a book"))
        // Default `.queue` strategy: `.fail` would cancel the task right after launch when the system is
        // busy, which the handler can't tell apart from the user cancelling.
        pending[identifier] = PendingJob(itemId: itemId, title: title)
        // Register this request's own identifier (it matches the `.*` entry in Info.plist), as
        // Apple's "Performing long-running tasks on iOS and iPadOS" does: register, then submit.
        // Each identifier is unique (`uniqueSuffix`), so this never registers one twice. Never
        // submit when registration failed: a request without a handler is an uncaught exception.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await runContinued(continued) }
        }
        do {
            guard registered else { throw ContinuedTaskError.registrationRefused }
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Unsupported, too many tasks, or the strategy refused: keep going while foreground.
            ShelfLog.info(.playback, "Continued transcription task not accepted (\(error.localizedDescription)); running in-process")
            pending[identifier] = nil
            Task { @MainActor in
                _ = await TranscriptionCenter.shared.runJob(itemId: itemId, title: title)
            }
        }
    }

    /// Drops a queued-but-not-started request for the book.
    static func forgetPending(itemId: String) {
        for (identifier, job) in pending where job.itemId == itemId {
            pending[identifier] = nil
            if #available(iOS 26.0, *) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
        }
    }

    private enum ContinuedTaskError: LocalizedError {
        case registrationRefused
        var errorDescription: String? { "launch handler registration refused" }
    }

    /// Unique per submission, not just per second: the identifier is also registered, and a
    /// second registration of the same identifier kills the app (two taps within a second).
    private static func uniqueSuffix(for itemId: String) -> String {
        let hash = String(UInt(bitPattern: itemId.hashValue), radix: 36)
        let nonce = UUID().uuidString.prefix(8).lowercased()
        return "\(hash).\(nonce)"
    }

    @available(iOS 26.0, *)
    @MainActor
    private static func runContinued(_ task: BGContinuedProcessingTask) async {
        guard let job = pending.removeValue(forKey: task.identifier) else {
            task.setTaskCompleted(success: false)
            return
        }
        let center = TranscriptionCenter.shared
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = 0
        var finished = false
        task.expirationHandler = {
            // The system or the user (via the Live Activity) ended it: checkpoint and stop.
            Task { @MainActor in center.cancel(itemId: job.itemId) }
        }
        let title = job.title
        let outcome = await center.runJob(itemId: job.itemId, title: job.title) { fraction in
            task.progress.completedUnitCount = Int64(fraction * 1000)
            let percent = Int((fraction * 100).rounded())
            task.updateTitle(title, subtitle: String(
                localized: "\(percent)% transcribed",
                comment: "Subtitle of the system progress activity; %lld is a percentage"))
        }
        if !finished {
            finished = true
            task.setTaskCompleted(success: outcome == .completed)
        }
    }

    // MARK: - Overnight

    /// Schedules (or cancels) the overnight processing request. Called when the app moves to
    /// the background. Safe to call repeatedly; a new submit replaces the unexecuted one.
    @MainActor
    static func scheduleOvernightIfNeeded() {
        guard #available(iOS 26.0, *) else { return }
        guard TranscriptionCenter.shared.canTranscribe,
              SettingsStore.transcriptsEnabled, SettingsStore.transcribeWhileCharging,
              !pendingOvernightItemIds().isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: overnightIdentifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: overnightIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            ShelfLog.info(.playback, "Overnight transcription not scheduled: \(error.localizedDescription)")
        }
    }

    /// Downloaded books with no finished transcript, in-progress books first (most recently
    /// played first), finished books last. Books that failed in the last day are skipped.
    @MainActor
    static func pendingOvernightItemIds() -> [String] {
        let downloads = DownloadManager.shared
        let now = Date()
        struct Candidate { let id: String; let rank: Int; let lastUpdate: Double }
        var candidates: [Candidate] = []
        for id in downloads.downloadedItems {
            let meta = TranscriptStore.meta(itemId: id)
            if meta.isComplete { continue }
            if let failed = meta.lastFailure, now.timeIntervalSince(failed) < 24 * 3600 { continue }
            guard let manifest = downloads.manifest(for: id) else { continue }
            let started = manifest.currentTime > 0
            let finished = manifest.duration > 0 && manifest.currentTime >= manifest.duration - 30
            let rank = finished ? 2 : (started ? 0 : 1)
            candidates.append(Candidate(id: id, rank: rank, lastUpdate: manifest.lastUpdate ?? 0))
        }
        return candidates.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.lastUpdate > $1.lastUpdate
        }.map(\.id)
    }

    /// The book to warm notes for: the one loaded in the player, else the most recently
    /// updated download.
    @MainActor
    private static func recentBookId() -> String? {
        if let current = AudioPlayerService.shared.currentItemId { return current }
        let downloads = DownloadManager.shared
        return downloads.downloadedItems
            .compactMap { id in downloads.manifest(for: id).map { (id, $0.lastUpdate ?? 0) } }
            .max { $0.1 < $1.1 }?.0
    }

    @available(iOS 26.0, *)
    @MainActor
    private static func runOvernight(_ task: BGProcessingTask) async {
        scheduleOvernightIfNeeded()   // one-shot request: queue the next night first
        let device = UIDevice.current
        let charging = device.batteryState == .charging || device.batteryState == .full
        let ids = pendingOvernightItemIds()
        let decision = TranscriptionScheduleDecision.overnight(
            enabled: SettingsStore.transcriptsEnabled && SettingsStore.transcribeWhileCharging,
            isCharging: charging,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            pendingCount: ids.count)
        guard decision == .run else {
            ShelfLog.info(.playback, "Overnight transcription skipped: \(decision)")
            task.setTaskCompleted(success: true)
            return
        }

        let center = TranscriptionCenter.shared
        let runner = Task { @MainActor in
            for id in ids {
                if Task.isCancelled { break }
                let title = DownloadManager.shared.manifest(for: id)?.title ?? id
                let outcome = await center.runJob(itemId: id, title: title)
                if outcome == .cancelled { break }
            }
        }
        overnightRunner = runner
        task.expirationHandler = {
            // Cancelling the runner cancels the running job, which checkpoints before returning.
            Task { @MainActor in overnightRunner?.cancel() }
        }
        await runner.value
        overnightRunner = nil
        // Batch 428: with the transcripts done, warm the recap notes for the book being listened
        // to (short, and skipped in Low Power Mode). Its own task so expiry can still cancel it.
        if !runner.isCancelled, let warmId = recentBookId() {
            let warm = Task { @MainActor in
                await BookIntelligence.shared.warmNotes(itemIds: [warmId], deadline: Date().addingTimeInterval(10 * 60))
            }
            overnightRunner = warm
            await warm.value
            overnightRunner = nil
            // Batch 433: with "Play Recap When Resuming" on, prepare that book's narrator montage now,
            // so resuming after a few days away can play it at once (it never waits for rendering).
            if !warm.isCancelled, SettingsStore.recapAutoPlay {
                let book = DownloadManager.shared.manifest(for: warmId)
                let prerender = Task { @MainActor in
                    await RecapPlaybackController.shared.prerender(itemId: warmId, title: book?.title ?? "",
                                                                  author: book?.author ?? "")
                }
                overnightRunner = prerender
                await prerender.value
                overnightRunner = nil
            }
        }
        task.setTaskCompleted(success: !runner.isCancelled)
    }
}
