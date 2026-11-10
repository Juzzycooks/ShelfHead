import AVFoundation
import CoreMedia
import Foundation
import Speech
import UIKit

// MARK: - Center (main actor, what the UI and the schedulers talk to)

/// Phase 1 Section A: owns transcription state for the whole app. UI reads `state(for:)`,
/// `availability` and `storageBytes`; user and background triggers call `transcribeNow` /
/// `runJob`. The Speech work lives in `TranscriptionEngine` (iOS 26+), one instance per job.
///
/// Below iOS 26 every call is inert: `isSupportedOS` is false, `availability` is
/// `.unsupportedOS`, `supportedLocales()` is `[]`.
@MainActor
@Observable
final class TranscriptionCenter {
    static let shared = TranscriptionCenter()

    enum ItemState: Equatable {
        case notStarted
        case queued
        case running(fraction: Double)
        case paused(fraction: Double)
        case complete
        case failed(message: String)
    }

    enum Availability: Equatable {
        case unsupportedOS, checking, deviceUnsupported, languageUnsupported, needsModelDownload, ready
    }

    enum JobOutcome: Equatable { case completed, cancelled, failed, alreadyRunning }

    private(set) var availability: Availability = .checking
    private(set) var storageBytes: Int64 = 0

    /// Runtime states (queued/running/failed and results of finished jobs). Observed.
    private var states: [String: ItemState] = [:]
    /// Disk-derived states, cached so `state(for:)` can be called from a view body without
    /// writing observed state. Dropped whenever a job, delete or override changes the item.
    @ObservationIgnored private var diskStates: [String: ItemState] = [:]
    @ObservationIgnored private var jobs: [String: Task<JobOutcome, Never>] = [:]
    /// Review 2 Medium 8 (30 October 2026): items deleted (or language-changed) while a job was
    /// running. The engine checkpoints on cancel, which would bring the transcript back, so
    /// `runJob` deletes again once the task has really ended.
    @ObservationIgnored private var discardOnFinish: Set<String> = []
    /// Review 3 Low (transcribe after delete): a Transcribe tap while a deleted job tears down, keyed to its title.
    @ObservationIgnored private var restartAfterDiscard: [String: (title: String, scopeKey: String)] = [:]
    @ObservationIgnored private var transcriptCache: [String: Transcript] = [:]
    @ObservationIgnored private var lastHighWaterWrite: [String: Double] = [:]

    var isSupportedOS: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// The OS has the API *and* this device has a speech model (the simulator and some older
    /// devices don't). Gates the Book Detail row, Transcribe now and overnight scheduling.
    var canTranscribe: Bool {
        if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    private init() {
        if !isSupportedOS { availability = .unsupportedOS }
        // Review 6 Low (account switch): drop per-account state.
        // Review 7 Medium 6: also cancel running jobs (discarded on finish) so they can't report into the new account.
        NotificationCenter.default.addObserver(forName: .shelfheadAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, task) in self.jobs { self.discardOnFinish.insert(id); task.cancel() }
                self.restartAfterDiscard.removeAll()
                self.lastHighWaterWrite.removeAll()
                self.states = [:]
                self.diskStates = [:]
                self.transcriptCache = [:]
            }
        }
    }

    // MARK: State

    func state(for itemId: String) -> ItemState {
        if let live = states[itemId] { return live }
        if let cached = diskStates[itemId] { return cached }
        let meta = TranscriptStore.meta(itemId: itemId)
        let resolved: ItemState
        if meta.isComplete {
            resolved = .complete
        } else if meta.fraction > 0 {
            resolved = .paused(fraction: meta.fraction)
        } else {
            resolved = .notStarted
        }
        diskStates[itemId] = resolved
        return resolved
    }

    /// True while a job (foreground or background) is actually running for the book.
    func isRunning(_ itemId: String) -> Bool { jobs[itemId] != nil }

    private func setState(_ state: ItemState, for itemId: String) {
        states[itemId] = state
    }

    /// Forgets runtime and cached state so the next read comes from disk.
    private func resetState(for itemId: String) {
        states[itemId] = nil
        diskStates[itemId] = nil
        transcriptCache[itemId] = nil
    }

    func transcript(for itemId: String) -> Transcript? {
        if let cached = transcriptCache[itemId] { return cached }
        guard let loaded = TranscriptStore.load(itemId: itemId) else { return nil }
        transcriptCache[itemId] = loaded
        return loaded
    }

    // MARK: Availability

    /// Checks device, language and model state. `localeIdentifier` nil means the user's default
    /// transcript language, else the app's preferred locale.
    func refreshAvailability(localeIdentifier: String?) async {
        guard #available(iOS 26.0, *) else { availability = .unsupportedOS; return }
        availability = .checking
        guard SpeechTranscriber.isAvailable else { availability = .deviceUnsupported; return }
        let appLocale = Self.appLocale()
        let request = localeIdentifier ?? SettingsStore.transcriptDefaultLanguage
        let candidate = TranscriptLocaleResolver.candidateLocale(forBookLanguage: request, fallback: appLocale)
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = TranscriptLocaleResolver.bestSupported(
            candidate, among: supported, preferredRegion: appLocale.region?.identifier) else {
            availability = supported.isEmpty ? .deviceUnsupported : .languageUnsupported
            return
        }
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [probe]) {
        case .installed: availability = .ready
        case .unsupported: availability = .languageUnsupported
        default: availability = .needsModelDownload
        }
    }

    func supportedLocales() async -> [Locale] {
        guard #available(iOS 26.0, *) else { return [] }
        return await SpeechTranscriber.supportedLocales
    }

    nonisolated static func appLocale() -> Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }

    // MARK: Triggers

    /// User tapped "Transcribe". Needs the book downloaded. Hands off to the scheduler, which
    /// runs it as a continued background task (or in-process as a fallback).
    func transcribeNow(itemId: String, title: String) {
        guard canTranscribe, SettingsStore.transcriptsEnabled else { return }
        if jobs[itemId] != nil {
            // Review 3 Low (transcribe after delete): supersede a discarding job; start once its teardown ends.
            if discardOnFinish.contains(itemId) {
                restartAfterDiscard[itemId] = (title, TranscriptStore.currentScopeKey())
                setState(.queued, for: itemId)
            }
            return
        }
        if case .queued = state(for: itemId) { return }
        guard DownloadManager.shared.manifest(for: itemId) != nil else {
            setState(.failed(message: String(
                localized: "Download the book first. Transcripts are made from the downloaded audio.",
                comment: "Transcript error: the book isn't downloaded")), for: itemId)
            return
        }
        setState(.queued, for: itemId)
        TranscriptionScheduler.submitUserInitiated(itemId: itemId, title: title)
    }

    func cancel(itemId: String) {
        // Review 4 Medium 5: a cancel withdraws a pending restart; stop showing "queued".
        if restartAfterDiscard.removeValue(forKey: itemId) != nil { resetState(for: itemId) }
        jobs[itemId]?.cancel()
        if jobs[itemId] == nil {
            // Queued but not started (e.g. waiting on the system): drop it.
            TranscriptionScheduler.forgetPending(itemId: itemId)
            resetState(for: itemId)
        }
    }

    func deleteTranscript(itemId: String) {
        restartAfterDiscard[itemId] = nil   // Review 4 Medium 5
        if jobs[itemId] != nil { discardOnFinish.insert(itemId) }
        jobs[itemId]?.cancel()
        TranscriptStore.deleteTranscriptKeepingMeta(itemId: itemId)
        resetState(for: itemId)
        refreshStorage()
    }

    func deleteAllTranscripts() {
        restartAfterDiscard.removeAll()   // Review 4 Medium 5
        for (id, task) in jobs { discardOnFinish.insert(id); task.cancel() }
        TranscriptStore.deleteAll()
        states.removeAll()
        diskStates.removeAll()
        transcriptCache.removeAll()
        refreshStorage()
    }

    func refreshStorage() {
        Task.detached(priority: .utility) {
            let bytes = TranscriptStore.totalStorageBytes()
            await MainActor.run { TranscriptionCenter.shared.storageBytes = bytes }
        }
    }

    // MARK: Language and listening frontier

    func languageOverride(for itemId: String) -> String? {
        TranscriptStore.languageOverride(itemId: itemId)
    }

    /// Changing the language invalidates the transcript (it is made again in the new language).
    func setLanguageOverride(_ identifier: String?, for itemId: String) {
        let old = TranscriptStore.languageOverride(itemId: itemId)
        guard old != identifier else { return }
        restartAfterDiscard[itemId] = nil   // Review 4 Medium 5
        TranscriptStore.setLanguageOverride(identifier, itemId: itemId)
        if jobs[itemId] != nil { discardOnFinish.insert(itemId) }
        jobs[itemId]?.cancel()
        TranscriptStore.deleteTranscriptKeepingMeta(itemId: itemId)
        resetState(for: itemId)
        refreshStorage()
    }

    /// Records the book's ABS `metadata.language` for a downloaded book, which the download
    /// manifest doesn't keep, so overnight runs can pick the right locale. Downloads record it
    /// themselves since Batch 422; this backfills books downloaded before that, from Book
    /// Detail. Not-downloaded books are skipped: they can't be transcribed, and writing their
    /// meta would leave an empty transcript folder behind for every book viewed.
    func noteBookLanguage(_ language: String?, for itemId: String) {
        guard let language, !language.isEmpty,
              DownloadManager.shared.isDownloaded(itemId: itemId) else { return }
        TranscriptStore.updateMeta(itemId: itemId) { $0.bookLanguage = language }
    }

    /// Raises the stored high-water mark from a live position. Cheap: writes only when the
    /// position has advanced by at least 10 s since the last write.
    func noteListeningPosition(itemId: String, time: Double) {
        guard time.isFinite, time - (lastHighWaterWrite[itemId] ?? 0) >= 10 else { return }
        lastHighWaterWrite[itemId] = time
        TranscriptStore.raiseHighWater(time, itemId: itemId)
    }

    func frontier(for itemId: String) -> Double {
        let player = AudioPlayerService.shared
        let live: Double? = player.currentItemId == itemId ? player.currentTime : nil
        let progress = DownloadManager.shared.manifest(for: itemId)?.currentTime
        return ListeningFrontier.frontier(
            storedHighWater: TranscriptStore.highWater(itemId: itemId),
            progressTime: progress, currentTime: live)
    }

    // MARK: Job execution (used by the foreground fallback and both background schedulers)

    /// Runs one book's transcription to completion, cancellation or failure and publishes
    /// state along the way. `onFraction` is the hook the schedulers use for task progress.
    func runJob(itemId: String, title: String,
                onFraction: (@MainActor @Sendable (Double) -> Void)? = nil) async -> JobOutcome {
        guard isSupportedOS, SettingsStore.transcriptsEnabled else {
            resetState(for: itemId)
            return .failed
        }
        guard jobs[itemId] == nil else { return .alreadyRunning }
        guard #available(iOS 26.0, *) else { return .failed }

        guard let input = makeInput(itemId: itemId) else {
            setState(.failed(message: String(
                localized: "The downloaded audio for this book couldn't be found. Download it again to transcribe.",
                comment: "Transcript error: local audio files missing")), for: itemId)
            TranscriptStore.updateMeta(itemId: itemId) { $0.lastFailure = Date(); $0.lastFailureMessage = "missing audio" }
            return .failed
        }

        let engine = TranscriptionEngine(input: input)
        let task = Task<JobOutcome, Never> { [weak self] in
            do {
                try await engine.run { fraction in
                    Task { @MainActor in
                        self?.reportProgress(itemId: itemId, fraction: fraction, scopeKey: input.scopeKey)
                        onFraction?(fraction)
                    }
                }
                return .completed
            } catch is CancellationError {
                return .cancelled
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ShelfLog.error(.playback, "Transcription failed: \(message)")
                self?.recordFailure(itemId: itemId, message: message, scopeKey: input.scopeKey)
                return .failed
            }
        }
        jobs[itemId] = task
        setState(.running(fraction: TranscriptStore.meta(itemId: itemId).fraction), for: itemId)
        TranscriptionScheduler.forgetPending(itemId: itemId)
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        jobs[itemId] = nil
        transcriptCache[itemId] = nil
        diskStates[itemId] = nil
        if discardOnFinish.remove(itemId) != nil {
            // Review 2 Medium 8: the user deleted this transcript mid-run; drop whatever the
            // engine checkpointed (or completed) after the delete.
            TranscriptStore.deleteTranscriptKeepingMeta(itemId: itemId, scopeKey: input.scopeKey)
            transcriptCache[itemId] = nil
            resetState(for: itemId)
            refreshStorage()
            if let pending = restartAfterDiscard.removeValue(forKey: itemId) {
                // Review 4 Low (account switch / background restart): drop it if the account changed
                // or the app isn't foreground (the continued task needs a foreground submit).
                if Self.shouldAutoRestart(pendingScope: pending.scopeKey,
                                          currentScope: TranscriptStore.currentScopeKey(),
                                          isActive: UIApplication.shared.applicationState == .active) {
                    transcribeNow(itemId: itemId, title: pending.title)
                }
            }
            return outcome
        }
        restartAfterDiscard[itemId] = nil
        // Review 7 Medium 6: a job from another account must not publish into this one.
        guard Self.shouldApplyJobUpdate(jobScope: input.scopeKey, currentScope: TranscriptStore.currentScopeKey()) else {
            refreshStorage()
            return outcome
        }
        switch outcome {
        case .completed: setState(.complete, for: itemId)
        case .cancelled: resetState(for: itemId)   // reads back as .paused from the checkpoint
        case .failed, .alreadyRunning: break       // recordFailure published .failed
        }
        refreshStorage()
        return outcome
    }

    nonisolated static func shouldAutoRestart(pendingScope: String, currentScope: String, isActive: Bool) -> Bool {
        isActive && pendingScope == currentScope
    }

    nonisolated static func shouldApplyJobUpdate(jobScope: String, currentScope: String) -> Bool {
        jobScope == currentScope
    }

    private func reportProgress(itemId: String, fraction: Double, scopeKey: String) {
        guard Self.shouldApplyJobUpdate(jobScope: scopeKey, currentScope: TranscriptStore.currentScopeKey()) else { return }
        // Review 4 Low (queued flips to running): ignore late callbacks from a discarded job.
        guard jobs[itemId] != nil, !discardOnFinish.contains(itemId) else { return }
        setState(.running(fraction: min(1, max(0, fraction))), for: itemId)
    }

    private func recordFailure(itemId: String, message: String, scopeKey: String) {
        TranscriptStore.updateMeta(itemId: itemId, scopeKey: scopeKey) { $0.lastFailure = Date(); $0.lastFailureMessage = message }
        guard Self.shouldApplyJobUpdate(jobScope: scopeKey, currentScope: TranscriptStore.currentScopeKey()) else { return }
        setState(.failed(message: message), for: itemId)
    }

    /// Resolves the book's downloaded tracks into plain values for the engine, so the engine
    /// never touches main-actor state.
    private func makeInput(itemId: String) -> TranscriptionJobInput? {
        let downloads = DownloadManager.shared
        guard let manifest = downloads.manifest(for: itemId), !manifest.tracks.isEmpty else { return nil }
        let sorted = manifest.tracks.sorted { $0.index < $1.index }
        var tracks: [TranscriptionJobInput.Track] = []
        for track in sorted {
            guard let url = downloads.localFileURL(itemId: itemId, trackIndex: track.index) else { return nil }
            tracks.append(.init(index: track.index, startOffset: track.startOffset,
                                duration: track.duration, url: url))
        }
        let meta = TranscriptStore.meta(itemId: itemId)
        // Per-book override, else the default language, else what ABS says the book is in.
        let request = meta.languageOverride ?? SettingsStore.transcriptDefaultLanguage ?? meta.bookLanguage
        return TranscriptionJobInput(itemId: itemId, scopeKey: TranscriptStore.currentScopeKey(),
                                     totalDuration: manifest.duration > 0 ? manifest.duration
                                         : sorted.reduce(0) { $0 + $1.duration },
                                     tracks: tracks, languageRequest: request)
    }
}

// MARK: - Engine inputs

/// Everything the engine needs, resolved on the main actor.
nonisolated struct TranscriptionJobInput: Sendable {
    struct Track: Sendable {
        let index: Int
        /// Book time the track starts, seconds.
        let startOffset: Double
        let duration: Double
        let url: URL
    }
    let itemId: String
    let scopeKey: String
    let totalDuration: Double
    let tracks: [Track]
    /// Override / default / ABS language string, resolved by `TranscriptLocaleResolver`.
    let languageRequest: String?
}

// MARK: - Engine (iOS 26+)

/// One transcription job (one book). Feeds the downloaded audio to `SpeechAnalyzer` ourselves,
/// in pulled chunks, so a long single-file m4b can resume mid-file and memory stays flat.
///
/// Time base: audio is fed from `secondsInTrack` without a `bufferStartTime`, so result
/// `audioTimeRange`s are relative to the first fed sample; the resume offset is added back
/// here. (If a build-time check shows ranges are already track time, drop `resume` in `collect`.)
@available(iOS 26.0, *)
actor TranscriptionEngine {
    nonisolated enum Failure: LocalizedError {
        case deviceUnsupported
        case languageUnsupported
        case modelUnavailable
        case audioUnreadable

        var errorDescription: String? {
            switch self {
            case .deviceUnsupported:
                return String(localized: "This device doesn't support on-device transcription.",
                              comment: "Transcript error")
            case .languageUnsupported:
                return String(localized: "On-device transcription isn't available for this book's language.",
                              comment: "Transcript error")
            case .modelUnavailable:
                return String(localized: "The speech model couldn't be downloaded. Check your connection and try again.",
                              comment: "Transcript error")
            case .audioUnreadable:
                return String(localized: "The downloaded audio couldn't be read.",
                              comment: "Transcript error")
            }
        }
    }

    private let input: TranscriptionJobInput
    private var transcript: Transcript?
    /// Audio seconds already transcribed in finished tracks (for progress).
    private var secondsBeforeTrack: Double = 0
    private nonisolated static let checkpointInterval: Double = 300

    init(input: TranscriptionJobInput) {
        self.input = input
    }

    /// Runs to completion; throws `CancellationError` (after checkpointing) when cancelled.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw Failure.deviceUnsupported }
        let appLocale = TranscriptionCenter.appLocale()
        let candidate = TranscriptLocaleResolver.candidateLocale(
            forBookLanguage: input.languageRequest, fallback: appLocale)
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = TranscriptLocaleResolver.bestSupported(
            candidate, among: supported, preferredRegion: appLocale.region?.identifier) else {
            throw Failure.languageUnsupported
        }
        let localeId = locale.identifier(.bcp47)

        // Model assets (shared by the system across apps; no-op when installed).
        do {
            let probe = Self.makeTranscriber(locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            ShelfLog.error(.playback, "Transcription model install failed: \(error.localizedDescription)")
            throw Failure.modelUnavailable
        }

        // Existing transcript: resume it unless it can't be trusted.
        let signature = Transcript.audioSignature(trackDurations: input.tracks.map(\.duration))
        if let existing = TranscriptStore.load(itemId: input.itemId, scopeKey: input.scopeKey),
           !TranscriptionPlan.mustRestart(existing, audioSignature: signature,
                                          trackCount: input.tracks.count, localeIdentifier: localeId) {
            transcript = existing
        } else {
            TranscriptStore.deleteTranscriptKeepingMeta(itemId: input.itemId, scopeKey: input.scopeKey)
            transcript = Transcript(itemId: input.itemId, localeIdentifier: localeId,
                                    trackCount: input.tracks.count, audioSignature: signature)
        }

        while let current = transcript, let point = TranscriptionPlan.resumePoint(for: current) {
            try Task.checkCancellation()
            guard input.tracks.indices.contains(point.trackIndex) else { throw Failure.audioUnreadable }
            secondsBeforeTrack = input.tracks.enumerated()
                .filter { current.completedTracks.contains($0.offset) }
                .reduce(0) { $0 + $1.element.duration }
            try await transcribeTrack(position: point.trackIndex, start: point.secondsInTrack,
                                      locale: locale, progress: progress)
        }
        progress(1)
    }

    // MARK: Per-track work

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        // Final results only (no volatile/fast), with per-run audio time ranges.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    private func transcribeTrack(position: Int, start: Double, locale: Locale,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let track = input.tracks[position]
        let transcriber = Self.makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.modelUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let spaceless = SegmentBuilder.isSpaceless(localeIdentifier: locale.identifier(.bcp47))
        let offset = track.startOffset
        let before = secondsBeforeTrack
        let total = max(input.totalDuration, 1)

        let collector = Task.detached { [transcriber] () -> CollectResult in
            await Self.collect(
                transcriber: transcriber, resume: start, trackOffset: offset, spaceless: spaceless,
                checkpoint: { [weak self] segments, secondsInTrack in
                    await self?.applyCheckpoint(segments, position: position, secondsInTrack: secondsInTrack)
                },
                progress: { trackSeconds in progress(min(1, (before + trackSeconds) / total)) })
        }

        var failure: Error?
        var last: CMTime?
        do {
            let audio = TrackAudioSequence(url: track.url, startSeconds: start,
                                           format: UncheckedBox(format))
            last = try await analyzer.analyzeSequence(audio)
        } catch {
            failure = error
        }
        do {
            if let last { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }
        } catch {
            if failure == nil { failure = error }
            // The result stream only ends once the analyzer is finished; make sure of it.
            await analyzer.cancelAndFinishNow()
        }
        let collected = await collector.value
        if failure == nil { failure = collected.error }

        if let failure {
            // Keep what we have (everything but the last, possibly unfinished, sentence).
            let segments = SegmentBuilder.segments(from: collected.runs, trackOffset: offset, spaceless: spaceless)
            if segments.count >= 2 {
                applyCheckpoint(Array(segments.dropLast()), position: position,
                                secondsInTrack: segments[segments.count - 1].start - offset)
            }
            if Task.isCancelled || failure is CancellationError { throw CancellationError() }
            throw failure
        }
        if Task.isCancelled {
            // Cancelled right at the end: checkpoint like above rather than claim completion.
            let segments = SegmentBuilder.segments(from: collected.runs, trackOffset: offset, spaceless: spaceless)
            if segments.count >= 2 {
                applyCheckpoint(Array(segments.dropLast()), position: position,
                                secondsInTrack: segments[segments.count - 1].start - offset)
            }
            throw CancellationError()
        }

        // Track finished: commit the tail and mark it complete.
        let tail = SegmentBuilder.segments(from: collected.runs, trackOffset: offset, spaceless: spaceless)
        guard var updated = transcript else { return }
        if !tail.isEmpty { updated = TranscriptionPlan.appending(tail, to: updated) }
        if !updated.completedTracks.contains(position) { updated.completedTracks.append(position) }
        updated.completedTracks.sort()
        updated.partial = nil
        updated.updatedAt = Date()
        transcript = updated
        TranscriptStore.save(updated, totalDuration: input.totalDuration, scopeKey: input.scopeKey)
    }

    /// Persists segments committed mid-track and moves the resume point to `secondsInTrack`.
    private func applyCheckpoint(_ segments: [TranscriptSegment], position: Int, secondsInTrack: Double) {
        guard var updated = transcript, !segments.isEmpty else { return }
        updated = TranscriptionPlan.appending(segments, to: updated)
        updated.partial = PartialProgress(trackIndex: position, secondsInTrack: max(0, secondsInTrack))
        updated.updatedAt = Date()
        transcript = updated
        TranscriptStore.save(updated, totalDuration: input.totalDuration, scopeKey: input.scopeKey)
    }

    // MARK: Result collection

    private nonisolated struct CollectResult: Sendable {
        /// Runs not yet committed to a checkpoint (track time, resume offset applied).
        var runs: [TimedRun]
        var error: Error?
    }

    /// Reads final results until the analyzer finishes. Checkpoints roughly every five minutes
    /// of audio: segments are built from the buffered runs, all but the last (possibly
    /// unfinished) sentence are committed, and the resume point becomes that sentence's start.
    /// Never throws; the error travels in the result so the caller can still checkpoint.
    private nonisolated static func collect(
        transcriber: SpeechTranscriber, resume: Double, trackOffset: Double, spaceless: Bool,
        checkpoint: @Sendable ([TranscriptSegment], Double) async -> Void,
        progress: @Sendable (Double) -> Void
    ) async -> CollectResult {
        var runs: [TimedRun] = []
        var lastCheckpointAt = resume
        var lastProgressEmit = Date.distantPast
        do {
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = result.text
                for run in text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(text[run.range].characters)
                    runs.append(TimedRun(text: piece, start: resume + range.start.seconds,
                                         end: resume + range.end.seconds))
                }
                guard let end = runs.last?.end else { continue }
                let now = Date()
                if now.timeIntervalSince(lastProgressEmit) >= 0.5 {   // ~2 updates/s
                    lastProgressEmit = now
                    progress(end)
                }
                if end - lastCheckpointAt >= checkpointInterval {
                    let segments = SegmentBuilder.segments(from: runs, trackOffset: trackOffset, spaceless: spaceless)
                    if segments.count >= 2, let last = segments.last {
                        await checkpoint(Array(segments.dropLast()), last.start - trackOffset)
                        runs.removeAll { trackOffset + $0.start < last.start - 0.0005 }
                        lastCheckpointAt = end
                    }
                }
            }
            return CollectResult(runs: runs, error: nil)
        } catch {
            return CollectResult(runs: runs, error: error)
        }
    }
}

// MARK: - Audio feeding

/// Wraps a non-`Sendable` value the engine hands between tasks that never use it concurrently.
private nonisolated struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Pull-based `AnalyzerInput` sequence over one track file, starting at `startSeconds`.
/// The analyzer pulls chunks (about 30 s of audio) as it needs them, so a 10-hour file never
/// sits in memory, and cancelling the task ends the sequence.
@available(iOS 26.0, *)
private nonisolated struct TrackAudioSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    let url: URL
    let startSeconds: Double
    let format: UncheckedBox<AVAudioFormat>

    func makeAsyncIterator() -> Iterator {
        Iterator(url: url, startSeconds: startSeconds, target: format.value)
    }

    nonisolated struct Iterator: AsyncIteratorProtocol {
        let url: URL
        let startSeconds: Double
        let target: AVAudioFormat
        private var file: AVAudioFile?
        private var converter: AVAudioConverter?
        private var opened = false
        private var finished = false

        init(url: URL, startSeconds: Double, target: AVAudioFormat) {
            self.url = url
            self.startSeconds = startSeconds
            self.target = target
        }

        mutating func next() async throws -> AnalyzerInput? {
            if finished || Task.isCancelled { return nil }
            if !opened {
                opened = true
                let audioFile = try AVAudioFile(forReading: url)
                let rate = audioFile.processingFormat.sampleRate
                audioFile.framePosition = Swift.min(audioFile.length, Swift.max(0, AVAudioFramePosition(startSeconds * rate)))
                file = audioFile
                converter = AVAudioConverter(from: audioFile.processingFormat, to: target)
            }
            guard let file, let converter else { finished = true; return nil }

            while !finished {
                let inFormat = file.processingFormat
                if file.framePosition >= file.length {
                    // End of file: flush the converter's tail once.
                    finished = true
                    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { return nil }
                    var error: NSError?
                    _ = converter.convert(to: out, error: &error) { _, status in
                        status.pointee = .endOfStream
                        return nil
                    }
                    return out.frameLength > 0 ? AnalyzerInput(buffer: out) : nil
                }
                let chunk = AVAudioFrameCount(Swift.min(Int64(inFormat.sampleRate * 30), file.length - file.framePosition))
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { return nil }
                try file.read(into: inBuffer, frameCount: chunk)
                guard inBuffer.frameLength > 0 else { finished = true; return nil }

                let ratio = target.sampleRate / inFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 4096
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .error { throw error ?? TranscriptionEngine.Failure.audioUnreadable }
                if out.frameLength > 0 { return AnalyzerInput(buffer: out) }
                // Converter buffered everything (rate conversion warm-up): read the next chunk.
            }
            return nil
        }
    }
}
