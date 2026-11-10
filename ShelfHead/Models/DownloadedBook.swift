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
    /// How many of this book's chapters the server sent in a shape the client couldn't
    /// use, and which were therefore left out of `chapters` when this manifest was
    /// written (Item 11, `REVIEW-2026-09-09-REMAINING.md`). Carried so the "some
    /// chapters couldn't be read" note under the chapter list still appears offline,
    /// where there is no server payload left to re-derive it from.
    ///
    /// Declared last, with a default, so `DownloadManager`'s memberwise construction of
    /// a manifest keeps working, and decoded with `decodeIfPresent` below so every
    /// manifest already on disk — none of which has this key — still decodes.
    var droppedChapterCount: Int = 0
    /// The server `updatedAt` (epoch ms) the currently-saved `cover.jpg` was fetched
    /// for — `nil` for a manifest written before cover versioning existed. Compared
    /// against the item's live `updatedAt` (via `CoverVersions`) by
    /// `DownloadManager.shouldRefreshLocalCover(manifestVersion:serverVersion:)` to
    /// decide whether a downloaded book's local cover needs re-fetching after the user
    /// replaces the artwork on the server.
    ///
    /// Declared last, with a default, for the same reason `droppedChapterCount` is
    /// (Item 11, `REVIEW-2026-09-09-REMAINING.md`): `DownloadManager`'s memberwise
    /// construction of a manifest keeps working unchanged wherever it doesn't pass this,
    /// and every manifest already on disk — none of which has this key — still decodes.
    var coverUpdatedAt: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, author, narrator, duration, chapters, tracks
        case currentTime, lastUpdate, droppedChapterCount, coverUpdatedAt
    }

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
            id: id, libraryItemId: id, episodeId: nil, duration: duration, progress: pct,
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
                    language: nil, genres: nil, isbn: nil, asin: nil, series: nil
                ),
                coverPath: nil,
                duration: duration,
                chapters: chapters,
                audioFiles: nil,
                numChapters: chapters.count,
                numAudioFiles: tracks.count,
                episodes: nil,
                ebookFile: nil,
                // Item 11: so `BookDetailView`'s chapter list shows the same note
                // offline that it showed when the book was still being read from the
                // server.
                droppedChapterCount: droppedChapterCount
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
            libraryItem: item,
            // Item 11: the player reads the *session's* chapter list once playback
            // starts, so the note in `PlayerView.ChapterListSheet` needs the count here
            // too, not only on the library item above.
            droppedChapterCount: droppedChapterCount
        )
    }
}

extension DownloadedBook {

    /// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): written by hand for one reason —
    /// Swift's *synthesized* `Decodable` ignores a property's default value and throws
    /// `keyNotFound` for a missing key, so adding `droppedChapterCount` to this struct
    /// would have made every manifest already on disk undecodable, and every downloaded
    /// book would have vanished from the app. `decodeIfPresent ?? 0` is what keeps old
    /// manifests readable; everything else decodes exactly as the synthesized
    /// initializer did.
    ///
    /// `chapters` goes through `LossyArray` rather than a strict `[Chapter]`. Note this
    /// is *not* needed for compatibility: every chapter in an existing manifest was
    /// written from a `Chapter` that had already decoded, with numeric `id`/`start`/
    /// `end`, and `Chapter.init(from:)`'s new rules only reject missing/null/non-numeric/
    /// non-finite values — a zero-length, inverted or negative-start chapter an older
    /// build wrote is still accepted, so no existing manifest can newly fail. It is here
    /// because the failure mode if one ever *did* fail is the worst in the app: a
    /// corrupted manifest takes the whole downloaded book offline, files and all.
    /// Dropping the unreadable chapter and counting it degrades instead.
    ///
    /// In an extension so the memberwise initializer `DownloadManager` builds a manifest
    /// with is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decode(String.self, forKey: .author)
        narrator = try c.decodeIfPresent(String.self, forKey: .narrator)
        duration = try c.decode(Double.self, forKey: .duration)
        tracks = try c.decode([DownloadedTrack].self, forKey: .tracks)
        currentTime = try c.decode(Double.self, forKey: .currentTime)
        lastUpdate = try c.decodeIfPresent(Double.self, forKey: .lastUpdate)

        let lossyChapters = try c.decode(LossyArray<Chapter>.self, forKey: .chapters)
        chapters = lossyChapters.elements
        for skip in lossyChapters.skipped {
            ShelfLog.error(.downloads, "Manifest \(id): dropped chapters[\(skip.index)]: \(skip.reason)")
        }
        // The count already recorded when the manifest was written, plus anything this
        // read of it had to drop. Absent in every manifest written before Item 11.
        let persistedCount = try c.decodeIfPresent(Int.self, forKey: .droppedChapterCount) ?? 0
        droppedChapterCount = max(max(0, persistedCount), lossyChapters.skipped.count)

        // Absent in every manifest written before cover versioning existed —
        // `shouldRefreshLocalCover` treats that nil as "refresh once, to be safe."
        coverUpdatedAt = try c.decodeIfPresent(Int.self, forKey: .coverUpdatedAt)
    }
}
