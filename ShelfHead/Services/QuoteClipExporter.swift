import AVFoundation
import Foundation

/// Batch 426: cuts a range of a downloaded book into a short .m4a for sharing.
/// Local files only (no network); streamed books share the card without audio.
enum QuoteClipError: LocalizedError {
    case notDownloaded
    case nothingToExport
    case exportFailed(String?)

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            return String(localized: "This book isn't downloaded, so the audio can't be clipped.", comment: "Clip export error: the book has no local audio files")
        case .nothingToExport:
            return String(localized: "There's no audio in that range to clip.", comment: "Clip export error: the selected range doesn't overlap any downloaded audio")
        case .exportFailed(let detail):
            if let detail, !detail.isEmpty {
                return String(localized: "The clip couldn't be exported: \(detail)", comment: "Clip export error; %@ is the system's reason")
            }
            return String(localized: "The clip couldn't be exported.", comment: "Clip export error with no further detail")
        }
    }
}

enum QuoteClipExporter {
    /// The book has a manifest and its first track file is on disk. (Every piece's file is
    /// re-checked at export time.)
    static func hasLocalAudio(itemId: String) -> Bool {
        guard DownloadManager.shared.manifest(for: itemId) != nil else { return false }
        return DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: 0) != nil
    }

    private static var clipsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Clips", isDirectory: true)
    }

    /// Exports `range` of the downloaded book to a temporary .m4a and returns its URL.
    static func export(itemId: String, range: ClipRange, title: String) async throws -> URL {
        guard let manifest = DownloadManager.shared.manifest(for: itemId) else {
            throw QuoteClipError.notDownloaded
        }
        let tracks = manifest.tracks.map { (index: $0.index, startOffset: $0.startOffset, duration: $0.duration) }
        let pieces = ClipTrackPlanner.pieces(for: range, tracks: tracks)
        guard !pieces.isEmpty else { throw QuoteClipError.nothingToExport }

        // Older exports are only useful until the share sheet closes.
        try? FileManager.default.removeItem(at: clipsDirectory)
        let folder = clipsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = folder.appendingPathComponent(ClipText.fileName(title: title, start: range.start))

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw QuoteClipError.exportFailed(nil)
        }
        var cursor = CMTime.zero
        for piece in pieces {
            guard let fileURL = DownloadManager.shared.localFileURL(itemId: itemId, trackIndex: piece.trackIndex) else {
                throw QuoteClipError.notDownloaded
            }
            let asset = AVURLAsset(url: fileURL)
            do {
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw QuoteClipError.exportFailed(nil)
                }
                let timeRange = CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 600),
                                            duration: CMTime(seconds: piece.duration, preferredTimescale: 600))
                try compositionTrack.insertTimeRange(timeRange, of: source, at: cursor)
                cursor = CMTimeAdd(cursor, timeRange.duration)
            } catch let error as QuoteClipError {
                throw error
            } catch {
                throw QuoteClipError.exportFailed(error.localizedDescription)
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw QuoteClipError.exportFailed(nil)
        }
        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw QuoteClipError.exportFailed(error.localizedDescription)
        }
        return outputURL
    }
}
