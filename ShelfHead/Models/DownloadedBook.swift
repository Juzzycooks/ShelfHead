import Foundation

/// On-disk manifest saved alongside downloaded audio so a book can be listed,
/// titled, and played fully offline without contacting the server.
struct DownloadedBook: Codable, Identifiable {
    let id: String
    let title: String
    let author: String
    let narrator: String?
    let duration: Double
    let chapters: [Chapter]
    let tracks: [DownloadedTrack]
    /// Last known playback position (seconds). Updated locally during playback
    /// and used as the resume point when starting offline.
    var currentTime: Double
    /// Epoch milliseconds of the last local progress update, for last-write-wins
    /// reconciliation against the server's `MediaProgress.lastUpdate`.
    var lastUpdate: Double?

    struct DownloadedTrack: Codable {
        let index: Int
        let startOffset: Double
        let duration: Double
        let filename: String
    }

    /// A `LibraryItem` reconstructed from the manifest, with the last-known progress
    /// cached in, so downloaded books can be listed/opened/played fully offline.
    func asLibraryItem() -> LibraryItem {
        let pct = duration > 0 ? min(currentTime / duration, 1) : 0
        let progress = MediaProgress(
            id: id, libraryItemId: id, duration: duration, progress: pct,
            currentTime: currentTime, isFinished: pct >= 0.99,
            lastUpdate: lastUpdate.map { Int($0) }, startedAt: nil, finishedAt: nil
        )
        return LibraryItem(
            id: id,
            ino: nil,
            libraryId: nil,
            mediaType: "book",
            media: Media(
                metadata: MediaMetadata(
                    title: title, subtitle: nil, authorName: author, narratorName: narrator,
                    seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
                    language: nil, genres: nil, isbn: nil, asin: nil
                ),
                coverPath: nil,
                duration: duration,
                chapters: chapters,
                audioFiles: nil,
                numChapters: chapters.count,
                numAudioFiles: tracks.count
            ),
            numFiles: tracks.count,
            size: nil,
            addedAt: nil,
            updatedAt: nil,
            mediaProgress: progress
        )
    }

    /// Builds a `PlaybackSession` equivalent from the manifest + local files so
    /// `AudioPlayerService` can play it with no network.
    func localSession(localURLProvider: (Int) -> URL?) -> PlaybackSession {
        let audioTracks: [AudioTrack] = tracks.map { track in
            AudioTrack(
                index: track.index,
                startOffset: track.startOffset,
                duration: track.duration,
                title: track.filename,
                contentUrl: localURLProvider(track.index)?.absoluteString,
                mimeType: nil,
                codec: nil
            )
        }

        let item = asLibraryItem()

        return PlaybackSession(
            id: "offline-\(id)",
            libraryItemId: id,
            mediaType: "book",
            duration: duration,
            playMethod: 0,
            audioTracks: audioTracks,
            currentTime: currentTime,
            startTime: currentTime,
            chapters: chapters,
            libraryItem: item
        )
    }
}
