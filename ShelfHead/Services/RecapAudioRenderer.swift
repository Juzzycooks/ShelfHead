import Foundation
import AVFoundation

/// Batch 433: renders a `RecapProgram` (narrator clips + optional spoken links) into ONE audio
/// file so "Previously On…" plays like a real track (Lock Screen, CarPlay, headphones, speed).
///
/// Speech items are synthesised with `AVSpeechSynthesizer.write(_:toBufferCallback:)` into temporary
/// files; clips are cut from the downloaded files (or, for the book loaded in the player, the
/// streaming URLs the controller supplies). Clips and speech sit on separate composition tracks
/// (different formats), with short gaps between items and a quick fade on each clip, then export
/// as .m4a. The result and its `recap-audio.json` manifest are cached beside the book's notes.

// MARK: - Pure helpers

/// Layout of a rendered montage: where each item starts, given how long each one is.
nonisolated enum RecapTimeline {
    /// Silence between items.
    nonisolated static let gap: Double = 0.6
    /// Fade in / out on each narrator clip.
    nonisolated static let fade: Double = 0.25

    nonisolated struct Slot: Equatable, Sendable {
        var offset: Double
        var duration: Double
    }

    /// Items back to back with `gap` between them. Negative / non-finite durations count as 0.
    nonisolated static func layout(durations: [Double], gap: Double = RecapTimeline.gap)
        -> (slots: [Slot], total: Double) {
        var cursor = 0.0
        var slots: [Slot] = []
        for (index, raw) in durations.enumerated() {
            let duration = raw.isFinite ? max(raw, 0) : 0
            if index > 0 { cursor += gap }
            slots.append(Slot(offset: cursor, duration: duration))
            cursor += duration
        }
        return (slots, cursor)
    }

    /// Marks for the manifest: one per rendered item, in play order. `items` and `slots` must match.
    nonisolated static func marks(items: [RecapProgramItem], slots: [Slot]) -> [RecapAudioManifest.Mark] {
        zip(items, slots).map { item, slot in RecapAudioManifest.Mark(offset: slot.offset, duration: slot.duration, item: item) }
    }

    nonisolated struct FadeRamps: Equatable, Sendable {
        var inStart: Double
        var inDuration: Double
        var outStart: Double
        var outDuration: Double
    }

    /// Fade-in at the clip's start, fade-out ending at its end. Each is `fade` long, or half the clip
    /// if the clip is shorter than two fades, so the two never overlap.
    nonisolated static func fadeRamps(offset: Double, duration: Double, fade: Double = RecapTimeline.fade) -> FadeRamps {
        let length = max(0, min(fade, duration / 2))
        return FadeRamps(inStart: offset, inDuration: length,
                         outStart: offset + duration - length, outDuration: length)
    }

    /// Where playback should go for a skip: next mark's offset, or for "previous" the current mark's
    /// start when more than `restartThreshold` seconds in, else the previous mark's. `nil` for next
    /// past the last mark (the caller finishes the recap).
    nonisolated static func skipTarget(forward: Bool, elapsed: Double, marks: [RecapAudioManifest.Mark],
                                       restartThreshold: Double = 3) -> Double? {
        guard !marks.isEmpty else { return nil }
        let current = currentMarkIndex(at: elapsed, marks: marks) ?? 0
        if forward {
            let next = current + 1
            return next < marks.count ? marks[next].offset : nil
        }
        if elapsed - marks[current].offset > restartThreshold { return marks[current].offset }
        return current > 0 ? marks[current - 1].offset : 0
    }

    /// The mark playing at `elapsed`: the last one starting at or before it; nil before the first.
    nonisolated static func currentMarkIndex(at elapsed: Double, marks: [RecapAudioManifest.Mark]) -> Int? {
        var found: Int?
        for (index, mark) in marks.enumerated() where mark.offset <= elapsed + 0.001 {
            found = index
        }
        return found
    }
}

/// Where one slice of a clip's audio comes from.
nonisolated enum RecapClipSource: Equatable, Sendable {
    case local, stream, none

    /// Downloaded file first (offline, fast), then the streaming asset, else the clip can't be cut.
    nonisolated static func choose(hasLocalFile: Bool, hasStream: Bool) -> RecapClipSource {
        if hasLocalFile { return .local }
        return hasStream ? .stream : .none
    }
}

nonisolated enum RecapRenderError: LocalizedError {
    case nothingToPlay
    case speechFailed
    case exportFailed(String?)

    var errorDescription: String? {
        switch self {
        case .nothingToPlay:
            return String(localized: "There's nothing to play for this recap yet.",
                          comment: "Previously On… montage error: the program had no usable audio or text")
        case .speechFailed:
            return String(localized: "The recap's voice couldn't be prepared.",
                          comment: "Previously On… montage error: speech synthesis produced no audio")
        case .exportFailed(let detail):
            if let detail, !detail.isEmpty {
                return String(localized: "The recap couldn't be prepared: \(detail)",
                              comment: "Previously On… montage error; %@ is the system's reason")
            }
            return String(localized: "The recap couldn't be prepared.",
                          comment: "Previously On… montage error with no further detail")
        }
    }
}

// MARK: - Speech capture

/// Collects `AVSpeechSynthesizer.write` buffers into an audio file. The callback arrives on an
/// arbitrary queue, so state is guarded by a lock; the continuation resumes exactly once.
private final class TimeoutTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    func set(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { task.cancel() } else { self.task = task }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

private final class SpeechCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var sampleRate: Double = 0
    private var frames: AVAudioFramePosition = 0
    private var continuation: CheckedContinuation<Double, Error>?

    init(url: URL) { self.url = url }

    func install(_ continuation: CheckedContinuation<Double, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil else { return }
        if pcm.frameLength == 0 {
            finishLocked(timedOut: false)
            return
        }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
                sampleRate = pcm.format.sampleRate
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch {
            file = nil
            let pending = continuation
            continuation = nil
            pending?.resume(throwing: RecapRenderError.speechFailed)
        }
    }

    /// Task cancelled: resume with `CancellationError` so the render stops instead of waiting.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        file = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    func timeout() {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil else { return }
        finishLocked(timedOut: true)
    }

    /// Closes the file (flushing it) and resumes with its duration. Caller holds the lock.
    private func finishLocked(timedOut: Bool) {
        file = nil   // AVAudioFile finalises on release
        let pending = continuation
        continuation = nil
        let seconds = sampleRate > 0 ? Double(frames) / sampleRate : 0
        if seconds > 0.05 {
            pending?.resume(returning: seconds)
        } else {
            pending?.resume(throwing: RecapRenderError.speechFailed)
        }
    }
}

// MARK: - Renderer

enum RecapAudioRenderer {
    static let audioFileName = "recap-audio.m4a"
    static let manifestFileName = "recap-audio.json"

    // MARK: Cache

    private nonisolated static func directory(itemId: String, scopeKey: String) -> URL {
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey)
    }

    /// Review 6 Low (loose recap files): a no-directory render hands back `recap-<uuid>.m4a` in the
    /// temp folder; whoever plays it never deletes it, so older ones are swept on the next render.
    nonisolated static func shouldSweepLooseFile(name: String, age: TimeInterval) -> Bool {
        name.hasPrefix("recap-") && name.hasSuffix(".m4a") && name != audioFileName && age > 3600
    }

    // Review 7 Low (recap sweep): the most recent loose file handed out is exempt, since the player may still hold it.
    private nonisolated(unsafe) static var lastLooseURL: URL?
    private static let lastLooseLock = NSLock()

    private nonisolated static func sweepLooseFiles() {
        let protected = lastLooseLock.withLock { lastLooseURL?.lastPathComponent }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names {
            if name == protected { continue }
            let url = tmp.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            if shouldSweepLooseFile(name: name, age: Date().timeIntervalSince(modified)) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// The rendered file and manifest for exactly this program + voice, if both are on disk.
    nonisolated static func cached(itemId: String, programHash: String,
                                   voiceIdentifier: String?,
                                   scopeKey: String = TranscriptStore.currentScopeKey()) -> (url: URL, manifest: RecapAudioManifest)? {
        let dir = directory(itemId: itemId, scopeKey: scopeKey)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestFileName)),
              let manifest = try? JSONDecoder().decode(RecapAudioManifest.self, from: data),
              manifest.version == RecapAudioManifest.currentVersion,
              manifest.itemId == itemId,
              manifest.programHash == programHash,
              manifest.voiceIdentifier == voiceIdentifier else { return nil }
        let url = dir.appendingPathComponent(manifest.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, manifest)
    }

    // MARK: Render

    private struct ClipSlice {
        var asset: AVURLAsset
        var sourceTrack: AVAssetTrack
        var start: Double
        var duration: Double
    }

    private enum Entry {
        case speech(item: RecapProgramItem, url: URL, duration: Double)
        case clip(item: RecapProgramItem, slices: [ClipSlice], duration: Double)

        var item: RecapProgramItem {
            switch self {
            case .speech(let item, _, _), .clip(let item, _, _): return item
            }
        }
        var duration: Double {
            switch self {
            case .speech(_, _, let duration), .clip(_, _, let duration): return duration
            }
        }
        var isClip: Bool { if case .clip = self { return true } else { return false } }
    }

    /// Renders `program` to one .m4a, caches it (when the book's item directory exists) and returns
    /// it with its manifest. `streamAsset` / `streamTracks` let the book loaded in the player be cut
    /// from its streaming URLs when it isn't downloaded. With no cuttable clip the program's
    /// `summary` is rendered as speech only (`hasNarratorAudio == false`).
    static func render(program: RecapProgram, itemId: String, voiceIdentifier: String?,
                       streamAsset: ((Int) -> AVURLAsset?)?,
                       streamTracks: [(index: Int, startOffset: Double, duration: Double)]? = nil) async throws
        -> (url: URL, manifest: RecapAudioManifest) {
        // Review 6 Low (scope): captured before the long render so an account switch can't redirect the cache.
        let scopeKey = TranscriptStore.currentScopeKey()
        sweepLooseFiles()
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapRender", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        let localTracks = DownloadManager.shared.manifest(for: itemId)?.tracks
            .map { (index: $0.index, startOffset: $0.startOffset, duration: $0.duration) }
        let tracks = localTracks ?? streamTracks ?? []

        // 1. Gather every item that can actually be played.
        var entries: [Entry] = []
        for (position, item) in program.items.enumerated() {
            try Task.checkCancellation()
            switch item {
            case .speech(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                do {
                    let (url, seconds) = try await synthesize(trimmed, voice: voice,
                                                              into: work.appendingPathComponent("speech-\(position).caf"))
                    entries.append(.speech(item: item, url: url, duration: seconds))
                } catch {
                    if error is CancellationError { throw error }   // Review 2 Low (Recap renderer)
                    ShelfLog.error(.storage, "Recap speech skipped: \(error.localizedDescription)")
                }
            case .clip(let start, let end, _):
                let pieces = ClipTrackPlanner.pieces(for: ClipRange(start: start, end: end), tracks: tracks)
                guard !pieces.isEmpty else { continue }
                if let slices = await loadSlices(pieces: pieces, itemId: itemId, streamAsset: streamAsset) {
                    entries.append(.clip(item: item, slices: slices, duration: slices.reduce(0) { $0 + $1.duration }))
                } else {
                    ShelfLog.info(.storage, "Recap clip \(Int(start))s skipped: no audio source")
                }
            }
        }

        // 2. No narrator audio at all: the written summary, spoken.
        var hasNarratorAudio = entries.contains { $0.isClip }
        if !hasNarratorAudio {
            let summary = program.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw RecapRenderError.nothingToPlay }
            let (url, seconds) = try await synthesize(summary, voice: voice,
                                                      into: work.appendingPathComponent("speech-summary.caf"))
            entries = [.speech(item: .speech(summary), url: url, duration: seconds)]
            hasNarratorAudio = false
        }

        // 3. Compose.
        let layout = RecapTimeline.layout(durations: entries.map(\.duration))
        let composition = AVMutableComposition()
        var clipTrack: AVMutableCompositionTrack?
        var speechTrack: AVMutableCompositionTrack?
        var rampParameters: AVMutableAudioMixInputParameters?

        for (entry, slot) in zip(entries, layout.slots) {
            try Task.checkCancellation()
            let at = CMTime(seconds: slot.offset, preferredTimescale: 600)
            switch entry {
            case .speech(_, let url, _):
                if speechTrack == nil {
                    speechTrack = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                guard let speechTrack else { throw RecapRenderError.exportFailed(nil) }
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw RecapRenderError.speechFailed
                }
                let range = CMTimeRange(start: .zero, duration: CMTime(seconds: slot.duration, preferredTimescale: 600))
                try speechTrack.insertTimeRange(range, of: source, at: at)
            case .clip(_, let slices, _):
                if clipTrack == nil {
                    clipTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid)
                    if let clipTrack { rampParameters = AVMutableAudioMixInputParameters(track: clipTrack) }
                }
                guard let clipTrack else { throw RecapRenderError.exportFailed(nil) }
                var cursor = at
                for slice in slices {
                    let range = CMTimeRange(start: CMTime(seconds: slice.start, preferredTimescale: 600),
                                            duration: CMTime(seconds: slice.duration, preferredTimescale: 600))
                    try clipTrack.insertTimeRange(range, of: slice.sourceTrack, at: cursor)
                    cursor = CMTimeAdd(cursor, range.duration)
                }
                if let rampParameters {
                    let ramps = RecapTimeline.fadeRamps(offset: slot.offset, duration: slot.duration)
                    rampParameters.setVolumeRamp(
                        fromStartVolume: 0, toEndVolume: 1,
                        timeRange: CMTimeRange(start: CMTime(seconds: ramps.inStart, preferredTimescale: 600),
                                               duration: CMTime(seconds: ramps.inDuration, preferredTimescale: 600)))
                    rampParameters.setVolumeRamp(
                        fromStartVolume: 1, toEndVolume: 0,
                        timeRange: CMTimeRange(start: CMTime(seconds: ramps.outStart, preferredTimescale: 600),
                                               duration: CMTime(seconds: ramps.outDuration, preferredTimescale: 600)))
                }
            }
        }

        // 4. Export.
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecapRenderError.exportFailed(nil)
        }
        if let rampParameters {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [rampParameters]
            session.audioMix = mix
        }
        let exported = work.appendingPathComponent("export.m4a")
        do {
            try await session.export(to: exported, as: .m4a)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RecapRenderError.exportFailed(error.localizedDescription)
        }

        // 5. Cache beside the notes (or hand back a temporary file when the directory doesn't exist).
        let manifest = RecapAudioManifest(
            version: RecapAudioManifest.currentVersion, itemId: itemId, programHash: program.inputHash,
            voiceIdentifier: voiceIdentifier, fileName: audioFileName, duration: layout.total,
            marks: RecapTimeline.marks(items: entries.map(\.item), slots: layout.slots),
            hasNarratorAudio: hasNarratorAudio)
        let dir = directory(itemId: itemId, scopeKey: scopeKey)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            // Outlives `defer` above: move out of the work folder.
            let loose = FileManager.default.temporaryDirectory.appendingPathComponent("recap-\(UUID().uuidString).m4a")
            try FileManager.default.moveItem(at: exported, to: loose)
            lastLooseLock.withLock { lastLooseURL = loose }
            return (loose, manifest)
        }
        let destination = dir.appendingPathComponent(audioFileName)
        // Manifest first goes away so a half-replaced file is never described by a stale manifest.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(manifestFileName))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: exported, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: dir.appendingPathComponent(manifestFileName),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            ShelfLog.error(.storage, "Recap manifest save failed: \(error.localizedDescription)")
        }
        return (destination, manifest)
    }

    /// Opens every piece's source, or `nil` when any piece has none (a clip with a hole in it would
    /// be worse than skipping it).
    private static func loadSlices(pieces: [ClipTrackPiece], itemId: String,
                                   streamAsset: ((Int) -> AVURLAsset?)?) async -> [ClipSlice]? {
        var slices: [ClipSlice] = []
        for piece in pieces {
            let local = DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: piece.trackIndex)
            let stream = streamAsset?(piece.trackIndex)
            let asset: AVURLAsset
            switch RecapClipSource.choose(hasLocalFile: local != nil, hasStream: stream != nil) {
            case .local: asset = AVURLAsset(url: local!)
            case .stream: asset = stream!
            case .none: return nil
            }
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
            slices.append(ClipSlice(asset: asset, sourceTrack: track, start: piece.start, duration: piece.duration))
        }
        return slices.isEmpty ? nil : slices
    }

    /// Speaks `text` into `url` with `voice` (nil = the system default for the device's language).
    private static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice?, into url: URL) async throws
        -> (url: URL, seconds: Double) {
        // Batch 435: the same cleaned, paced utterance as Read It to Me (`SpeechScript`).
        let utterance = SpeechScript.utterance(for: text, voice: voice)
        let synthesizer = AVSpeechSynthesizer()
        let capture = SpeechCapture(url: url)
        // Review 2 Low (Recap renderer, 30 October 2026): the timeout task is cancelled once the capture
        // ends, and Cancel stops speech mid-item (AVSpeechSynthesizer.stopSpeaking(at: .immediate)).
        nonisolated(unsafe) let speaker = synthesizer
        let timeoutBox = TimeoutTaskBox()
        let seconds: Double
        do {
            seconds = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                    capture.install(continuation)
                    // Review 3 Low (recap cancel): a cancel that landed before install was lost; don't start speech.
                    if Task.isCancelled { capture.cancel(); return }
                    synthesizer.write(utterance) { buffer in capture.handle(buffer) }
                    // Some voices never send the closing empty buffer; whatever was captured by then stands.
                    timeoutBox.set(Task.detached {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        if !Task.isCancelled { capture.timeout() }
                    })
                }
            } onCancel: {
                _ = speaker.stopSpeaking(at: .immediate)
                capture.cancel()
            }
        } catch {
            timeoutBox.cancel()
            throw error
        }
        timeoutBox.cancel()
        withExtendedLifetime(synthesizer) {}
        return (url, seconds)
    }
}
