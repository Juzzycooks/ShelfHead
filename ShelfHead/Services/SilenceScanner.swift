import Accelerate
import AVFoundation
import Foundation

/// Batch 427 (Section E): why a scan for quiet stretches couldn't run.
enum SilenceScanError: LocalizedError {
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            return String(localized: "This book isn't downloaded, so its audio can't be scanned for pauses.", comment: "Chapter suggestions error: the book has no local audio files to scan")
        }
    }
}

/// Reads a downloaded book's audio files and returns its long pauses (in book time) for the
/// chapter suggester. Local files only; nothing is decoded to disk. Pure maths lives in
/// `SilenceGapFinder`; this type only does the file reading.
enum SilenceScanner {
    /// Level window: 0.1 s of channel 0 per RMS value.
    nonisolated private static let windowSeconds = 0.1
    /// Windows per read, so each read is about one second of audio.
    nonisolated private static let windowsPerRead = 10

    /// Scans every track of `itemId`. `progress` receives 0...1 (seconds scanned over the
    /// book's total) after each ~1 s buffer, from whatever thread the scan runs on. Throws
    /// `CancellationError` when the task is cancelled between buffers and
    /// `SilenceScanError.notDownloaded` when there is no manifest or no file on disk.
    ///
    /// Batch 436: `minGap` is the shortest pause reported (default 1.5 s, what the chapter
    /// suggester wants; Smart Speed passes ~0.35 s).
    @concurrent nonisolated static func scan(itemId: String,
                                             minGap: Double = 1.5,
                                             progress: @Sendable (Double) -> Void) async throws -> [SilenceGap] {
        guard let manifest = DownloadManager.shared.manifest(for: itemId), !manifest.tracks.isEmpty else {
            throw SilenceScanError.notDownloaded
        }
        let total = max(manifest.tracks.reduce(0) { $0 + max(0, $1.duration) }, 1)
        var scannedBefore = 0.0
        var gaps: [SilenceGap] = []
        var scannedAnyFile = false
        var lastReported = 0.0

        for track in manifest.tracks.sorted(by: { $0.startOffset < $1.startOffset }) {
            try Task.checkCancellation()
            guard let url = DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: track.index) else {
                scannedBefore += max(0, track.duration)
                continue
            }
            let file = try AVAudioFile(forReading: url)
            scannedAnyFile = true
            let format = file.processingFormat
            let windowFrames = max(1, Int((format.sampleRate * windowSeconds).rounded()))
            let actualWindow = Double(windowFrames) / format.sampleRate
            let capacity = AVAudioFrameCount(windowFrames * windowsPerRead)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }

            var levels: [Float] = []
            levels.reserveCapacity(Int(Double(max(file.length, 0)) / Double(windowFrames)) + 1)

            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: capacity)
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }
                if let channel = buffer.floatChannelData?[0] {
                    var index = 0
                    while index < frames {
                        let count = min(windowFrames, frames - index)
                        // vDSP: a 20 h book is ~720,000 windows; a scalar loop is slow in Debug.
                        var rms: Float = 0
                        vDSP_rmsqv(channel + index, 1, &rms, vDSP_Length(count))
                        levels.append(rms > 0 ? 20 * log10(rms) : -Float.infinity)
                        index += count
                    }
                } else {
                    // No float data (shouldn't happen for the processing format): count as loud.
                    levels.append(contentsOf: Array(repeating: Float(0), count: (frames + windowFrames - 1) / windowFrames))
                }
                let scannedInTrack = Double(file.framePosition) / format.sampleRate
                let fraction = min(1, (scannedBefore + scannedInTrack) / total)
                // Every half percent, not every buffer (one call per second of audio otherwise).
                if fraction - lastReported >= 0.005 {
                    lastReported = fraction
                    progress(fraction)
                }
            }

            gaps.append(contentsOf: SilenceGapFinder.gaps(
                levels: levels, windowSeconds: actualWindow, offset: track.startOffset, minGap: minGap))
            scannedBefore += max(0, track.duration)
            progress(min(1, scannedBefore / total))
        }

        guard scannedAnyFile else { throw SilenceScanError.notDownloaded }
        return SilenceGapFinder.merged(gaps)
    }
}
