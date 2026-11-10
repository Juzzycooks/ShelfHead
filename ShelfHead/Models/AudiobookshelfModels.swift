import Foundation
import UIKit

// MARK: - Authentication

struct LoginRequest: Codable {
    let username: String
    let password: String
}

struct LoginResponse: Codable {
    let user: User
    let userDefaultLibraryId: String?
    let serverSettings: ServerSettings?

    enum CodingKeys: String, CodingKey {
        case user
        case userDefaultLibraryId
        case serverSettings
    }
}

struct User: Codable, Identifiable {
    let id: String
    let username: String
    /// Legacy permanent token. Kept by the server for backwards compatibility,
    /// but `accessToken` should be preferred on v2.26+ servers.
    let token: String?
    /// Short-lived JWT access token (ABS v2.26+). Used as the Bearer token.
    let accessToken: String?
    /// Long-lived refresh token, returned in the body only when the request
    /// sends the `x-return-tokens: true` header (mobile clients).
    let refreshToken: String?
    let type: String?
    let isActive: Bool?
    let mediaProgress: [MediaProgress]?
    let bookmarks: [AudioBookmark]?
    /// Batch 441: the server's per-user permission flags (`/api/me` and login). Nil when the
    /// server didn't send them; every flag inside is optional too.
    let permissions: UserPermissions?
    /// Batch 457: library ids a restricted account may see, and the tag allow/deny list (`itemTagsSelected`).
    /// `var` with a nil default so the memberwise initializer keeps working for existing callers.
    var librariesAccessible: [String]? = nil
    var itemTagsSelected: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, username, token, accessToken, refreshToken, type, isActive
        case mediaProgress, bookmarks, permissions, librariesAccessible, itemTagsSelected
    }

    /// The token to use for authenticated requests, preferring the new access token.
    var effectiveAccessToken: String? {
        accessToken ?? token
    }
}

extension User {

    // §Sync (REVIEW-2026-09-09.md): `mediaProgress` and `bookmarks` were plain arrays of
    // records with required fields, so ONE unexpected null/type from a different
    // Audiobookshelf version failed the whole `/api/me` decode. That single throw was
    // swallowed by `LibraryViewModel.loadUserProgress()` and took out far more than the
    // one bad row: every book showed no progress, All Bookmarks read empty,
    // `DownloadManager.reconcile` never ran, and `AudioPlayerService.serverProgressMap`
    // returned `[:]` so `flushPendingProgress` pushed queued positions over whatever the
    // server had. `LoginResponse` decodes a `User` too, so the same bad row also failed
    // sign-in outright.
    //
    // Both arrays now go through `LossyArray`, which drops only the element that doesn't
    // parse. Each drop is logged with its index and reason — indexes, item ids and titles
    // are not secrets, and `ShelfLog.redact()` strips tokens from the line regardless.
    //
    // In an extension (not the struct body) so the compiler still synthesizes the
    // memberwise initializer — the same reason `MediaMetadata` does this.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id`/`username` stay required: a payload without them isn't a user object at
        // all, and failing loudly there is correct (the caller logs and keeps its
        // last-good progress).
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? nil
        accessToken = (try? c.decodeIfPresent(String.self, forKey: .accessToken)) ?? nil
        refreshToken = (try? c.decodeIfPresent(String.self, forKey: .refreshToken)) ?? nil
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        isActive = c.lenientBool(.isActive)

        let progress = (try? c.decodeIfPresent(LossyArray<MediaProgress>.self, forKey: .mediaProgress)) ?? nil
        for skip in progress?.skipped ?? [] {
            ShelfLog.error(.sync, "Dropped /api/me mediaProgress[\(skip.index)]: \(skip.reason)")
        }
        mediaProgress = progress?.elements

        let marks = (try? c.decodeIfPresent(LossyArray<AudioBookmark>.self, forKey: .bookmarks)) ?? nil
        for skip in marks?.skipped ?? [] {
            ShelfLog.error(.sync, "Dropped /api/me bookmarks[\(skip.index)]: \(skip.reason)")
        }
        bookmarks = marks?.elements
        // Batch 441: lenient; a bad `permissions` shape never fails the whole user decode.
        permissions = (try? c.decodeIfPresent(UserPermissions.self, forKey: .permissions)) ?? nil
        librariesAccessible = (try? c.decodeIfPresent([String].self, forKey: .librariesAccessible)) ?? nil
        itemTagsSelected = (try? c.decodeIfPresent([String].self, forKey: .itemTagsSelected)) ?? nil
    }
}

/// Batch 441: the permission flags ABS sends on a user. Each flag is decoded if present and a
/// wrong-typed one reads as nil rather than failing anything.
struct UserPermissions: Codable, Equatable {
    var download: Bool?
    var update: Bool?
    var delete: Bool?
    var upload: Bool?
    var accessAllLibraries: Bool?
    /// Batch 457: the restriction flags a child's account carries. All optional; older servers omit them.
    var accessAllTags: Bool?
    var accessExplicitContent: Bool?
    var selectedTagsNotAccessible: Bool?

    enum CodingKeys: String, CodingKey {
        case download, update, delete, upload, accessAllLibraries
        case accessAllTags, accessExplicitContent, selectedTagsNotAccessible
    }

    init(download: Bool? = nil, update: Bool? = nil, delete: Bool? = nil, upload: Bool? = nil,
         accessAllLibraries: Bool? = nil, accessAllTags: Bool? = nil, accessExplicitContent: Bool? = nil,
         selectedTagsNotAccessible: Bool? = nil) {
        self.accessAllTags = accessAllTags
        self.accessExplicitContent = accessExplicitContent
        self.selectedTagsNotAccessible = selectedTagsNotAccessible
        self.download = download
        self.update = update
        self.delete = delete
        self.upload = upload
        self.accessAllLibraries = accessAllLibraries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        download = c.lenientBool(.download)
        update = c.lenientBool(.update)
        delete = c.lenientBool(.delete)
        upload = c.lenientBool(.upload)
        accessAllLibraries = c.lenientBool(.accessAllLibraries)
        accessAllTags = c.lenientBool(.accessAllTags)
        accessExplicitContent = c.lenientBool(.accessExplicitContent)
        selectedTagsNotAccessible = c.lenientBool(.selectedTagsNotAccessible)
    }
}

extension User {
    /// Batch 441: server root or admin account.
    var isAdmin: Bool { type == "root" || type == "admin" }
    /// Batch 441: may PATCH/POST item metadata, chapters and series (ABS `canUpdate`).
    var canUpdateLibrary: Bool { isAdmin || permissions?.update == true }
    /// Batch 441: may upload files, which ABS also requires for setting a cover from a URL.
    var canUpload: Bool { isAdmin || permissions?.upload == true }
}

struct AudioBookmark: Codable, Identifiable {
    let libraryItemId: String
    let title: String
    let time: Double            // seconds
    let createdAt: Int?

    enum CodingKeys: String, CodingKey { case libraryItemId, title, time, createdAt }

    // S2 (REVIEW_2026-08-20_UI_SECURITY.md): `time` is decoded straight from server JSON
    // with no finiteness/range check, and this `id` is evaluated on every render of any
    // `ForEach`/`List` over bookmarks — a plain `Int(time)` here would trap (crash) on a
    // malformed `.nan`/`.infinity`/out-of-range value the instant the list renders,
    // repeatably. `.safeSeconds` (below) clamps to a sane finite range first.
    var id: String { "\(libraryItemId)-\(time.safeSeconds)" }
}

extension AudioBookmark {

    // §Sync (REVIEW-2026-09-09.md): decoded tolerantly so one odd row can't fail the
    // whole `/api/me` payload (see `User.init(from:)`); in an extension so the
    // memberwise initializer `AudiobookshelfAPI.merging` uses still exists.
    //
    // What stays required, and why:
    // - `libraryItemId`: it is this bookmark's identity (`id`) and the path component of
    //   every bookmark endpoint. A bookmark that can't say which book it belongs to
    //   can't be listed, seeked to or deleted.
    // - `time`: a bookmark without a position is meaningless — it is the whole payload
    //   of the feature, and it is also half of the identity the delete endpoint keys on.
    // What is relaxed:
    // - `title`: the user's note. Optional in the UI already (an untitled bookmark is
    //   rendered by its timestamp), so `""` on a missing/null title loses nothing —
    //   the same call the `Chapter` decoder makes for the same reason.
    // - numbers: accepted as JSON number *or* numeric string, since ABS has shipped
    //   `time` as both across versions (`SeriesRef.sequence` already had to do this).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = try c.decode(String.self, forKey: .libraryItemId)
        guard let time = c.lenientDouble(.time) else {
            throw DecodingError.dataCorruptedError(
                forKey: .time, in: c, debugDescription: "Bookmark has no usable time")
        }
        self.time = time
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        createdAt = c.lenientInt(.createdAt)
    }
}

struct ServerSettings: Codable {
    let buildNumber: Int?
    let version: String?
}

// MARK: - Libraries

struct Library: Codable, Identifiable {
    let id: String
    let name: String
    let mediaType: String?
    let icon: String?
    let folders: [LibraryFolder]?
}

struct LibraryFolder: Codable, Identifiable {
    let id: String
    let fullPath: String?
}

struct LibraryItemsResponse: Decodable {
    let results: [LibraryItem]
    let total: Int
    let limit: Int
    let page: Int

    enum CodingKeys: String, CodingKey { case results, total, limit, page }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A single malformed item shouldn't fail the whole library screen.
        results = (try? c.decode(LossyArray<LibraryItem>.self, forKey: .results))?.elements ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? results.count
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? results.count
        page = (try? c.decode(Int.self, forKey: .page)) ?? 0
    }
}

// MARK: - Library Items

struct LibraryItem: Codable, Identifiable {
    let id: String
    let ino: String?
    let libraryId: String?
    let mediaType: String?
    let media: Media?
    let numFiles: Int?
    let size: Int?
    let addedAt: Int?
    let updatedAt: Int?
    let mediaProgress: MediaProgress?

    enum CodingKeys: String, CodingKey {
        case id, ino, libraryId, mediaType, media
        case numFiles, size, addedAt, updatedAt
        case mediaProgress = "userMediaProgress"
    }

    /// A podcast show (as opposed to a book/audiobook) — played episode-by-episode
    /// rather than as one continuous audio track. See `Media.episodes`.
    var isPodcast: Bool { mediaType == "podcast" }

    /// An item with an ebook file and no audio — Audiobookshelf also supports a book
    /// having *both* an audio version and an ebook file, but that combined case isn't
    /// handled by this pass (see `Views/EbookReaderView.swift`'s scope note); only a
    /// pure ebook-only item gets the in-app "Read" entry point.
    var isEbookOnly: Bool {
        media?.ebookFile != nil && (media?.numAudioFiles ?? 0) == 0
    }
}

extension LibraryItem {

    /// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): field-for-field what the compiler
    /// synthesized before (same keys, same `decodeIfPresent` semantics, `id` still
    /// required) — the *only* addition is the log line. `Media` records why each chapter
    /// was dropped but can't name the book: `media` is a nested container, and the item
    /// id it belongs to is a sibling key one level up, in scope only here. Writing the
    /// line here is what makes "one book's chapters look wrong" diagnosable from a log,
    /// which is the entire point of dropping the chapter quietly in the UI.
    ///
    /// Never logs a value out of the payload — the index and `LossyArray.Skip.reason`
    /// (a coding path plus type names) only, and `ShelfLog.redact()` runs over the line
    /// regardless.
    ///
    /// In an extension so the memberwise initializer used by `DownloadedBook`,
    /// `PlayerViewModel.restoreLastSession()` and the tests is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ino = try c.decodeIfPresent(String.self, forKey: .ino)
        libraryId = try c.decodeIfPresent(String.self, forKey: .libraryId)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        let decodedMedia = try c.decodeIfPresent(Media.self, forKey: .media)
        media = decodedMedia
        numFiles = try c.decodeIfPresent(Int.self, forKey: .numFiles)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        addedAt = try c.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt)
        mediaProgress = try c.decodeIfPresent(MediaProgress.self, forKey: .mediaProgress)

        for note in decodedMedia?.droppedChapterNotes ?? [] {
            ShelfLog.error(.sync, "Item \(id): dropped media.\(note)")
        }

        // Cover-versioning fix: every list/shelf/search/detail fetch decodes a
        // `LibraryItem`, so recording the version here (rather than at each call site)
        // is what lets `shelfCoverURL` (Extensions.swift) bust its cache the moment the
        // server reports newer artwork, with no changes needed anywhere else that
        // decodes an item. `CoverVersions.record` itself ignores a `nil` `updatedAt` and
        // never moves a version backward.
        CoverVersions.record(itemId: id, updatedAt: updatedAt)
    }
}

struct Media: Codable {
    let metadata: MediaMetadata?
    let coverPath: String?
    let duration: Double?
    let chapters: [Chapter]?
    let audioFiles: [AudioFile]?
    let numChapters: Int?
    let numAudioFiles: Int?
    /// Populated only for `mediaType == "podcast"` items — each entry is one episode,
    /// played independently rather than as chapters of one continuous book. See
    /// `LibraryItem.isPodcast` / `PodcastEpisode`.
    let episodes: [PodcastEpisode]?
    /// Present for an ebook (no audio) library item — see `LibraryItem.isEbookOnly` /
    /// `Views/EbookReaderView.swift`. Audiobookshelf also supports a book having both
    /// an audio version and an ebook file, but this pass only handles the ebook-only
    /// case (see the scope note in `CHANGES_IMPLEMENTED.md`).
    let ebookFile: EbookFile?

    /// How many chapters the tolerant decode below dropped because the server sent them
    /// in a shape this client can't use (Item 11, `REVIEW-2026-09-09-REMAINING.md`).
    ///
    /// Zero for every payload that decodes cleanly, which is every payload today. It is
    /// part of `CodingKeys` on purpose: `[LibraryItem]` is encoded to the Up Next queue
    /// file (`PlayerViewModel.saveQueue`) and re-decoded on the next launch, and the
    /// user-facing note in `BookDetailView`/`PlayerView` should survive that round trip
    /// rather than quietly resetting to "nothing was dropped". A queue file written by
    /// an older build has no such key at all, so it is decoded with `decodeIfPresent`
    /// semantics and defaults to 0.
    var droppedChapterCount: Int = 0

    /// Why each of those chapters was dropped ("chapters[3]: null where Double required
    /// at [start]"), carried only as far as `LibraryItem.init(from:)` — the level at
    /// which the *item id* is in scope, so the log line can name the book. Deliberately
    /// absent from `CodingKeys`: this is decode-time diagnostics, not model state, and
    /// it must never be written into the Up Next queue file.
    var droppedChapterNotes: [String] = []

    enum CodingKeys: String, CodingKey {
        case metadata, coverPath, duration, chapters, audioFiles
        case numChapters, numAudioFiles, episodes, ebookFile
        case droppedChapterCount
    }
}

extension Media {

    /// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): `chapters` was a plain `[Chapter]?`
    /// with a strict `Chapter` decode, so ONE chapter carrying a `null`/absent/string
    /// `start` failed the whole `Media` — and with it the whole `LibraryItem` or
    /// `PlaybackSession` it sits in. Book detail and playback both broke for that title,
    /// with no indication of why. Batch 310 left it strict deliberately, because
    /// silently dropping a chapter changes the mapping `TrackTimeline` and the
    /// chapter-relative scrubber are built on; the user has since decided the tradeoff:
    /// **drop the malformed chapter and warn** (`Chapter.droppedChapterNote(count:)`,
    /// shown under both chapter lists).
    ///
    /// `episodes` goes through the same `LossyArray` for the same reason — one
    /// undecodable episode used to hide an entire podcast show's episode list.
    ///
    /// In an extension (not the struct body) so the compiler still synthesizes the
    /// memberwise initializer `DownloadedBook.asLibraryItem()` and
    /// `PlayerViewModel.restoreLastSession()` build a `Media` with — the same reason
    /// `MediaMetadata` and `MediaProgress` do this.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try c.decodeIfPresent(MediaMetadata.self, forKey: .metadata)
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        audioFiles = try c.decodeIfPresent([AudioFile].self, forKey: .audioFiles)
        ebookFile = try c.decodeIfPresent(EbookFile.self, forKey: .ebookFile)
        // Numbers through the §Sync-tolerant readers: a duration or count arriving as a
        // numeric string is the same class of single-field mismatch that used to fail a
        // whole item, and every consumer of these is already `?? 0`.
        duration = c.lenientDouble(.duration)
        numChapters = c.lenientInt(.numChapters)
        numAudioFiles = c.lenientInt(.numAudioFiles)

        // `try?`, not `try`: a `chapters` that isn't even an array (a hostile or badly
        // broken server) leaves the book chapterless rather than making it undecodable —
        // exactly the failure this change exists to remove.
        let lossyChapters = (try? c.decodeIfPresent(LossyArray<Chapter>.self, forKey: .chapters)) ?? nil
        chapters = lossyChapters?.elements
        let notes = (lossyChapters?.skipped ?? []).map { "chapters[\($0.index)]: \($0.reason)" }
        droppedChapterNotes = notes
        // A count already persisted in the payload (an Up Next queue file written by
        // this build, whose `chapters` array was filtered before it was encoded) and a
        // count derived from this decode are both authoritative for what they describe,
        // so the surviving figure is whichever is larger rather than either alone.
        droppedChapterCount = max(max(0, c.lenientInt(.droppedChapterCount) ?? 0), notes.count)

        let lossyEpisodes = (try? c.decodeIfPresent(LossyArray<PodcastEpisode>.self, forKey: .episodes)) ?? nil
        episodes = lossyEpisodes?.elements
        for skip in lossyEpisodes?.skipped ?? [] {
            ShelfLog.error(.sync, "Dropped media.episodes[\(skip.index)]: \(skip.reason)")
        }
    }
}

/// The ebook file attached to a library item (PDF/EPUB/MOBI/etc — Audiobookshelf itself
/// is format-agnostic here). ShelfHead can only actually *read* the PDF case in-app —
/// see `Views/EbookReaderView.swift`'s doc comment for why EPUB rendering wasn't
/// attempted in this pass.
struct EbookFile: Codable {
    let ino: String?
    let metadata: EbookFileMetadata?
}

struct EbookFileMetadata: Codable {
    let filename: String?
    let ext: String?

    /// `ext` as Audiobookshelf sends it carries a leading dot (".epub") and any case. This is
    /// lowercased with leading dots stripped ("epub"), and "" when the server sent none.
    var normalizedExtension: String {
        guard let ext else { return "" }
        var value = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }
}

/// One episode of a podcast library item. Podcasts in Audiobookshelf are modeled as a
/// single `LibraryItem` (the show) containing many episodes, each with its own audio
/// file and its own progress/session — unlike a book, which is one continuous
/// listen across all its audio tracks/chapters.
struct PodcastEpisode: Codable, Identifiable {
    let id: String
    let title: String?
    let subtitle: String?
    let description: String?
    /// Epoch milliseconds, matching Audiobookshelf's other `*At`/`publishedAt` fields.
    let publishedAt: Int?
    let audioFile: AudioFile?
    let duration: Double?

    /// Best-effort display date from `publishedAt`, formatted like the rest of the app
    /// (short, locale-aware). Nil if the server didn't provide one.
    var publishedDate: Date? {
        publishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, description, publishedAt, audioFile, duration
    }
}

extension PodcastEpisode {

    /// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): `publishedAt` was a strict `Int?`, so
    /// an epoch that arrived in exponent form (`1.7e12`) or as a numeric string threw a
    /// `typeMismatch` — and, before `Media.episodes` became a `LossyArray`, that one
    /// field took the entire podcast show's episode list with it. Same treatment
    /// `MediaProgress`'s epoch fields got in Batch 310.
    ///
    /// `id` stays required: it is this episode's identity, the path component of its
    /// `/play` call and the key `episodeProgressMap` looks its progress up by. An
    /// episode without one is dropped by the `LossyArray` above rather than guessed at.
    ///
    /// In an extension so the memberwise initializer is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        publishedAt = c.lenientInt(.publishedAt)
        audioFile = (try? c.decodeIfPresent(AudioFile.self, forKey: .audioFile)) ?? nil
        duration = c.lenientDouble(.duration)
    }
}

/// One entry of Audiobookshelf's structured `metadata.series[]`. Decoded tolerantly
/// because `sequence` arrives as a String on some endpoints and a Number on others,
/// and any field may be absent.
struct SeriesRef: Codable, Identifiable {
    let id: String?
    let name: String?
    let sequence: Double?

    enum CodingKeys: String, CodingKey { case id, name, sequence }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        // Accept a string ("1", "1.5") or a raw number.
        if let s = (try? c.decodeIfPresent(String.self, forKey: .sequence)) ?? nil {
            sequence = Double(s)
        } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .sequence)) ?? nil {
            sequence = d
        } else {
            sequence = nil
        }
    }
}

struct MediaMetadata: Codable {
    let title: String?
    let subtitle: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let description: String?
    let publishedYear: String?
    let publisher: String?
    let language: String?
    let genres: [String]?
    let isbn: String?
    let asin: String?
    /// Structured series list (id + name + sequence per series). Preferred over the
    /// `seriesName` display string for ordering.
    let series: [SeriesRef]?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, description
        case authorName, narratorName, seriesName
        case publishedYear, publisher, language
        case genres, isbn, asin, series
    }
}

extension MediaMetadata {

    /// Audiobookshelf returns `""` — not `null` — for metadata a book simply doesn't
    /// have, so `decodeIfPresent` hands back a present-but-blank `String` and every
    /// `if let` downstream succeeds on nothing.
    ///
    /// F3 (REVIEW_2026-09-04_UI.md): that produced a visible "Narrated by" label with
    /// no name after it — underlined, and tappable through to a narrator browse view
    /// for the empty string. `LibraryItem.title`/`.authorName` already guarded against
    /// exactly this with their own `trimmingCharacters(...).isEmpty` checks, so the
    /// codebase already knew the server does this; the guard just never reached the
    /// fields that pass straight through as optionals. Normalising once here covers
    /// `narratorName`, `seriesName`, `description`, `publisher`, `isbn` and the rest
    /// together, rather than re-deriving the same check at each call site.
    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    // In an extension (not the struct body) so the compiler still synthesizes the
    // memberwise initializer used by DownloadedBook/PlayerViewModel.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode every field tolerantly so an unexpected shape (notably `series`) yields
        // nil rather than failing decoding of the whole LibraryItem/PlaybackSession.
        func string(_ key: CodingKeys) -> String? {
            Self.blankToNil((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)
        }
        title = string(.title)
        subtitle = string(.subtitle)
        description = string(.description)
        authorName = string(.authorName)
        narratorName = string(.narratorName)
        seriesName = string(.seriesName)
        publishedYear = string(.publishedYear)
        publisher = string(.publisher)
        language = string(.language)
        // Same defect class, same visible symptom: a blank entry here renders as an
        // empty genre chip on `BookDetailView`.
        genres = ((try? c.decodeIfPresent([String].self, forKey: .genres)) ?? nil)
            .map { $0.compactMap(Self.blankToNil) }
        isbn = string(.isbn)
        asin = string(.asin)
        series = (try? c.decodeIfPresent([SeriesRef].self, forKey: .series)) ?? nil
    }

    /// Series position, preferring the structured `series[]` (correct for books that
    /// belong to multiple series) and falling back to scraping the display string
    /// (e.g. "The Primal Hunter #12" → 12).
    var seriesSequence: Double? {
        if let seq = series?.first?.sequence { return seq }
        return sequenceFromDisplayString
    }

    /// The sequence for a specific series by name — use this when ordering books within
    /// a known series, so a multi-series book uses the right number.
    func sequence(inSeriesNamed target: String) -> Double? {
        // Prefer the structured entry for this exact series (return its sequence even if
        // nil — never borrow a different series' number for a multi-series book).
        if let ref = series?.first(where: { $0.name == target }) {
            return ref.sequence
        }
        // No structured match — best-effort parse of the display string.
        return sequenceFromDisplayString
    }

    /// Whether a series *display* name already states `sequence` itself, so a caller
    /// about to append "· Book n" would be printing the same number twice.
    ///
    /// F6 (REVIEW_2026-09-04_UI.md): `BookDetailView`'s series chip rendered
    /// "The Primal Hunter #15 · Book 15" — the position twice, two different ways, four
    /// words apart. Audiobookshelf series display strings commonly carry the position
    /// already, which `sequenceFromDisplayString` right below has always relied on;
    /// this is the same knowledge used for presentation instead of ordering.
    ///
    /// Pure and static so it can be unit-tested directly, per the project's "extract a
    /// pure function when a bug fix needs a regression test" precedent
    /// (`SeriesOrdering`, `ProgressReconciler`, `DownloadManager.shouldReclaimOrphan
    /// Directory`). Recognises both suffix styles seen in real libraries: "Name #15"
    /// and "Name, Book 15".
    static func seriesName(_ name: String, alreadyStates sequence: Int) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = trimmed.range(
            of: #"(#\s*|\bbook\s+)(\d+)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return false }
        let digits = trimmed[markerRange].filter(\.isNumber)
        return Int(digits) == sequence
    }

    /// Whether a book's `description` is worth rendering an "About" section for.
    ///
    /// Pass 3 item 5 (REVIEW_2026-09-04_UI.md): server metadata sometimes lands a scrap
    /// in `description` — a real library rendered an entire About section whose whole
    /// body was the words "Chapter 84". F3's `blankToNil` above already drops empty and
    /// whitespace-only values at decode time; this is the same idea one step further,
    /// for text that is present but far too short to be a synopsis.
    ///
    /// The length floor is the whole rule. There is deliberately no pattern match for
    /// "Chapter N" or any other specific junk: what turns up in this field varies by
    /// server, scraper and import, so a matcher would only ever chase the last example
    /// anyone happened to see, while quietly failing on the next one. Twenty characters
    /// is below any real book description and above every scrap seen so far.
    static func isMeaningfulDescription(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    private var sequenceFromDisplayString: Double? {
        guard let name = seriesName, let hash = name.lastIndex(of: "#") else { return nil }
        let tail = name[name.index(after: hash)...]
        // The display string may list several series ("A #1, B #3"); take just the
        // first number after this "#".
        let number = tail.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }
}

struct Chapter: Codable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let title: String

    enum CodingKeys: String, CodingKey { case id, start, end, title }

    /// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): every container of chapters
    /// (`Media.chapters`, `PlaybackSession.chapters`) now decodes through
    /// `LossyArray<Chapter>`, so a throw here drops *this chapter* instead of failing the
    /// whole book or session. What that makes malformed, and why:
    ///
    /// - `id`, `start`, `end` missing, `null`, non-numeric or non-finite → dropped. They
    ///   are what every consumer is built on: `id` is the `ForEach`/`.id()` identity in
    ///   both chapter lists and the value `AudioPlayerService` compares to decide when
    ///   the Now Playing chapter changed; `start`/`end` are the half-open range
    ///   `PlayerViewModel.chapterIndex(in:at:)` and `TrackTimeline.chapter(at:)` resolve
    ///   the current chapter with, the bounds of the chapter-relative scrubber, the
    ///   end-of-chapter sleep timer's target, and the seek target of a tapped row. A
    ///   chapter that can't supply them isn't a chapter, and no sentinel is safer than
    ///   its absence. Both are read leniently first, so `"12.5"` is still accepted.
    /// - `title` missing/null → kept, with an empty title (unchanged behaviour; a
    ///   nameless chapter still positions correctly, and `looksLikeIntroOrOutro`
    ///   already guards against an empty title).
    /// - `end <= start`, or a negative time → **kept**, deliberately. Checked every
    ///   consumer first. An inverted or zero-length chapter can never be resolved as
    ///   "current" at all (the range check is half-open, so nothing satisfies
    ///   `time >= start && time < end`) and the player just reads whole-book while the
    ///   position is inside it; a negative `start` resolves normally, and every value
    ///   derived from it is already clamped — `chapterLength` floors at `0.001`,
    ///   `chapterElapsed` clamps into `0...chapterLength`, a tapped row's seek target
    ///   clamps at `max(0, time)` in `TrackTimeline.position(atAbsoluteTime:)`, and
    ///   `Double.safeSeconds` clamps a negative length to `0` before any `Int(...)`
    ///   conversion (that conversion *traps* on out-of-range input, which is why the
    ///   finiteness checks above are not optional). So the worst of it is a row reading
    ///   "0m", and dropping these instead would have a real cost:
    ///   `DownloadedBook.chapters` is a *strict* `[Chapter]` in the offline manifest, so
    ///   a rule that rejects a chapter an older build happily wrote would make that
    ///   book's manifest undecodable and the downloaded book vanish offline.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedId = c.lenientInt(.id) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "chapter id missing or not a number"
            ))
        }
        guard let decodedStart = c.lenientDouble(.start), decodedStart.isFinite else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "chapter start missing or not a finite number"
            ))
        }
        guard let decodedEnd = c.lenientDouble(.end), decodedEnd.isFinite else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "chapter end missing or not a finite number"
            ))
        }
        id = decodedId
        start = decodedStart
        end = decodedEnd
        // Tolerate a missing/null title so a nameless chapter still positions correctly.
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
    }

    /// The single home of the "we couldn't read some of this book's chapters" copy,
    /// shown as a caption under the chapter list in `BookDetailView` and in
    /// `PlayerView.ChapterListSheet` (Item 11). Nil when nothing was dropped, so both
    /// call sites are a plain `if let`.
    ///
    /// Pure and `static` so the wording — including the 1-vs-N grammar, the part most
    /// likely to regress — can be pinned by a test, per this project's "extract a pure
    /// function when a fix needs a regression test" precedent. Not localised, matching
    /// the rest of the app's copy.
    static func droppedChapterNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return String(localized: "1 chapter couldn't be read from the server and was skipped.")
        }
        return String(localized: "\(count) chapters couldn't be read from the server and were skipped.", comment: "Warning shown when several chapters could not be decoded. %lld is the number of skipped chapters (2 or more).")
    }

    /// Best-effort detection of a publisher intro/outro chapter by its title —
    /// "Opening Credits", "Also by this author", "About the Author", copyright/preview
    /// pages, etc. Deliberately conservative (whole-phrase matches, not single words
    /// like "credits" alone) so a chapter that happens to be *named* "Introduction" as
    /// real narrative content (common in nonfiction) isn't misclassified. Used to gate
    /// auto-skip — never applied unless the user has turned that on.
    var looksLikeIntroOrOutro: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        let phrases = [
            "opening credits", "closing credits", "end credits",
            "also by", "also available", "also in this series",
            "about the author", "about the narrator", "about the publisher",
            "copyright", "title page", "dedication page",
            "preview of", "excerpt from", "sneak peek",
            "audible original", "this has been an audible", "this is a production of"
        ]
        return phrases.contains { t.contains($0) }
    }

    /// True when the chapter titles carry their own numbering ("63. Something
    /// Incredibly Questionable", "12 — The Long Road"), so any UI that also prints a
    /// position number would be showing two numbering schemes at once.
    ///
    /// Pass 3 item 1 (REVIEW_2026-09-04_UI.md): `ChapterListSheet` printed the array
    /// index beside every title, so a self-numbered book read "65  63. Something
    /// Incredibly Questionable" — the same contradiction G3 removed from the full
    /// player's chapter caption. The intro/credits tracks most books ship with are what
    /// push the index out of step with the author's numbering, so the two disagree
    /// exactly where a reader is most likely to notice.
    ///
    /// Decided over the whole list rather than per row, because a book either numbers
    /// its chapters or it doesn't: one "Prologue" among 80 numbered titles shouldn't
    /// bring the index column back for all of them, and one stray "1. " in an otherwise
    /// unnumbered book shouldn't take it away. A clear majority (>50%) of the non-empty
    /// titles decides it; an empty or all-blank list is not self-numbered.
    ///
    /// Pure and static so it can be unit-tested directly, per the project's "extract a
    /// pure function when a bug fix needs a regression test" precedent.
    static func titlesAreSelfNumbered(_ titles: [String]) -> Bool {
        let candidates = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }

        // Leading digits alone aren't the signal — they have to be followed by
        // something that reads as a separator between a number and the chapter's name,
        // so "Opening Credits" and "The Long Road" keep their index column. Whitespace
        // counts as a separator ("12 The Long Road"), which does mean a numeric title
        // like "1984 and Beyond" matches on its own; the majority rule above is what
        // stops one such title from hiding the index for a whole unnumbered book.
        //
        // "Chapter 12" / "Chapter 12: The Long Road" is the other common self-numbering
        // scheme (Audiobookshelf's own generated chapter names use it), and it clashes
        // with the index column the same way — "2  Chapter 1" once an intro track shifts
        // the index. So an optional leading "chapter" word is skipped before the digits,
        // and in that form the digits may also simply end the title.
        let separators: Set<Character> = [".", ":", ")", "-", "\u{2013}", "\u{2014}"]
        let numbered = candidates.filter { title in
            var rest = Substring(title)
            var hadChapterWord = false
            if rest.lowercased().hasPrefix("chapter ") {
                rest = rest.dropFirst("chapter ".count).drop(while: \.isWhitespace)
                hadChapterWord = true
            }
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return false }
            guard let next = rest.dropFirst(digits.count).first else { return hadChapterWord }
            return separators.contains(next) || next.isWhitespace
        }
        return numbered.count * 2 > candidates.count
    }
}

struct AudioFile: Codable, Identifiable {
    // Stable identity: never mint a fresh UUID per access (that breaks ForEach diffing).
    var id: String { ino ?? metadata?.filename ?? "\(index ?? 0)" }
    let ino: String?
    let index: Int?
    let duration: Double?
    let metadata: AudioFileMetadata?
}

struct AudioFileMetadata: Codable {
    let filename: String?
    let ext: String?
    let path: String?
    let size: Int?
}

// MARK: - Media Progress

struct MediaProgress: Codable, Identifiable {
    let id: String
    let libraryItemId: String
    /// Set only for podcast-episode progress — a podcast's overall `libraryItemId`
    /// covers every episode, so this distinguishes which one a given progress record
    /// is actually for. Nil for a book/audiobook's progress.
    let episodeId: String?
    let duration: Double?
    let progress: Double?
    let currentTime: Double?
    let isFinished: Bool?
    let lastUpdate: Int?
    let startedAt: Int?
    let finishedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, episodeId, duration, progress, currentTime
        case isFinished, lastUpdate, startedAt, finishedAt
    }
}

extension MediaProgress {

    // §Sync (REVIEW-2026-09-09.md): tolerant decode so one malformed record is dropped by
    // `LossyArray` (or salvaged here) instead of failing the entire `/api/me` user object.
    // In an extension so the memberwise initializer `DownloadedBook.asLibraryItem()` and
    // the tests use is still synthesized.
    //
    // `libraryItemId` stays required: it is the key every consumer looks this record up
    // by (`userProgressMap`, `serverProgressMap`, `reconcile`) and the path component
    // of `PATCH /api/me/progress/<id>`. A record without it is unusable, so dropping it
    // is right.
    //
    // `id` is synthesized when absent. Checked every consumer first: nothing sends this
    // value back to the server — progress is written by `libraryItemId` and read by
    // `libraryItemId`/`episodeId` — and the `Identifiable` conformance is only ever used
    // locally, never as a `ForEach` identity over progress records. So a synthesized id
    // is safe here in a way it would NOT be if it were a server-side row key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let itemId = try c.decode(String.self, forKey: .libraryItemId)
        let episode = (try? c.decodeIfPresent(String.self, forKey: .episodeId)) ?? nil
        libraryItemId = itemId
        episodeId = episode
        if let decoded = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil),
           !decoded.isEmpty {
            id = decoded
        } else if let episode {
            // Matches how `episodeProgressMap` distinguishes episodes of one podcast.
            id = "\(itemId)-\(episode)"
        } else {
            id = itemId
        }
        // Every number below is accepted as a JSON number or a numeric string, and
        // `null`/absent/garbage becomes `nil` rather than a decode failure — these are
        // all already optional to their consumers (`?? 0` / `?? false` at each use).
        duration = c.lenientDouble(.duration)
        progress = c.lenientDouble(.progress)
        currentTime = c.lenientDouble(.currentTime)
        // Some server/plugin versions send 0/1 (or "true") rather than a JSON bool.
        isFinished = c.lenientBool(.isFinished)
        // Epoch milliseconds. Sent as an integer normally, but a fractional/exponent
        // form (`1.7e12`) fails a plain `Int` decode, which is exactly the class of
        // single-field mismatch that used to blank every book's progress.
        lastUpdate = c.lenientInt(.lastUpdate)
        startedAt = c.lenientInt(.startedAt)
        finishedAt = c.lenientInt(.finishedAt)
    }
}

// MARK: - Playback Session

struct PlaybackSessionRequest: Codable {
    let deviceInfo: DeviceInfo
    let forceDirectPlay: Bool
    let forceTranscode: Bool
    let mediaPlayer: String
    let supportedMimeTypes: [String]

    init() {
        self.deviceInfo = DeviceInfo()
        self.forceDirectPlay = true
        self.forceTranscode = false
        self.mediaPlayer = "ShelfHead"
        self.supportedMimeTypes = [
            "audio/mpeg",
            "audio/mp4",
            "audio/aac",
            "audio/x-m4a",
            "audio/x-m4b",
            "audio/ogg",
            "audio/flac"
        ]
    }
}

struct DeviceInfo: Codable {
    let deviceId: String
    let clientName: String
    let clientVersion: String
    let manufacturer: String
    let model: String
    let sdkVersion: Int

    init() {
        self.deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        self.clientName = "ShelfHead"
        // Report the real app + OS version so the server's device/session list is accurate.
        self.clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.manufacturer = "Apple"
        self.model = UIDevice.current.model
        self.sdkVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
}

struct PlaybackSession: Codable, Identifiable {
    let id: String
    let libraryItemId: String?
    let mediaType: String?
    let duration: Double?
    let playMethod: Int?
    let audioTracks: [AudioTrack]?
    let currentTime: Double?
    let startTime: Double?
    let chapters: [Chapter]?
    let libraryItem: LibraryItem?
    /// Chapters dropped by the tolerant decode below — see `Media.droppedChapterCount`,
    /// which this mirrors for the session's own chapter list (the one the player
    /// actually uses once playback starts). Declared last, with a default, so the
    /// memberwise initializer `DownloadedBook.localSession(localURLProvider:)` and
    /// `AudioPlayerService.adoptReopenedSession(_:replacing:)` call keeps working
    /// unchanged.
    var droppedChapterCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, mediaType, duration, playMethod
        case audioTracks, currentTime, startTime, chapters, libraryItem
        case droppedChapterCount
    }
}

extension PlaybackSession {

    /// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): the session carries its OWN chapter
    /// list — `PlayerViewModel.chapters` reads it in preference to the book's the moment
    /// a session exists — so a malformed chapter here failed `POST /api/items/<id>/play`
    /// outright and the book simply refused to start, separately from the `getItem`
    /// failure `Media` fixes. Both now drop the one bad chapter and count it.
    ///
    /// Logged here rather than in `Media` because `libraryItemId` is in scope at this
    /// level, so the line can name the book; `Media`'s own drops are logged by
    /// `LibraryItem.init(from:)` for the same reason.
    ///
    /// In an extension so the memberwise initializer is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let itemId = (try? c.decodeIfPresent(String.self, forKey: .libraryItemId)) ?? nil
        libraryItemId = itemId
        mediaType = (try? c.decodeIfPresent(String.self, forKey: .mediaType)) ?? nil
        duration = c.lenientDouble(.duration)
        playMethod = c.lenientInt(.playMethod)
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)
        currentTime = c.lenientDouble(.currentTime)
        startTime = c.lenientDouble(.startTime)
        libraryItem = try c.decodeIfPresent(LibraryItem.self, forKey: .libraryItem)

        let lossyChapters = (try? c.decodeIfPresent(LossyArray<Chapter>.self, forKey: .chapters)) ?? nil
        chapters = lossyChapters?.elements
        let skips = lossyChapters?.skipped ?? []
        droppedChapterCount = max(max(0, c.lenientInt(.droppedChapterCount) ?? 0), skips.count)
        for skip in skips {
            ShelfLog.error(.sync, "Session \(id) (item \(itemId ?? "unknown")): dropped chapters[\(skip.index)]: \(skip.reason)")
        }
    }
}

struct AudioTrack: Codable, Identifiable {
    // Combine index and contentUrl so two nil-index tracks don't collide on "0".
    var id: String { "\(index ?? -1)-\(contentUrl ?? "")" }
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let title: String?
    let contentUrl: String?
    let mimeType: String?
    let codec: String?
}

struct SyncSessionRequest: Codable {
    let currentTime: Double
    let timeListened: Double
    let duration: Double
}

// MARK: - Lossy array decoding

/// Decodes a JSON array element-by-element, skipping any element that fails to
/// decode instead of failing the whole array. Audiobookshelf's `personalized`
/// endpoint mixes shelves (book / series / authors / episode) whose entities have
/// different shapes, so a single unexpected element must not blank the Home screen.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    /// What was dropped, for callers that want to log it. §Sync (REVIEW-2026-09-09.md):
    /// `/api/me` progress and bookmarks now decode through this, and silently losing a
    /// row there is worth a log line — a user reporting "one book has no progress" is
    /// otherwise undiagnosable. Ignored by the existing shelf/session call sites.
    let skipped: [Skip]

    /// One dropped element: its index in the array and why it didn't decode.
    /// `reason` is a `DecodingError` summary (coding path + type names) — never a value
    /// from the payload, so it carries no secrets; `ShelfLog.redact()` still runs on it.
    struct Skip {
        let index: Int
        let reason: String
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        var skips: [Skip] = []
        while !container.isAtEnd {
            let before = container.currentIndex
            do {
                result.append(try container.decode(Element.self))
            } catch {
                skips.append(Skip(index: before, reason: Self.describe(error)))
                // Advance past the bad element by decoding it into a permissive box.
                _ = try? container.decode(AnyJSON.self)
            }
            // Safety net: if neither decode advanced the cursor, stop rather than loop.
            if container.currentIndex == before { break }
        }
        elements = result
        skipped = skips
    }

    /// A short, value-free description of a decode failure.
    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        guard let decodingError = error as? DecodingError else {
            return "\(type(of: error))"
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at [\(path(context))]"
        case .typeMismatch(let type, let context):
            return "type mismatch (expected \(type)) at [\(path(context))]"
        case .valueNotFound(let type, let context):
            return "null where \(type) required at [\(path(context))]"
        case .dataCorrupted(let context):
            return "corrupt value at [\(path(context))]: \(context.debugDescription)"
        @unknown default:
            return "undecodable element"
        }
    }

    /// Consumes any single JSON value so the unkeyed cursor advances past a skipped element.
    private struct AnyJSON: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { return }
            if (try? c.decode(Bool.self)) != nil { return }
            if (try? c.decode(Double.self)) != nil { return }
            if (try? c.decode(String.self)) != nil { return }
            if (try? c.decode([AnyJSON].self)) != nil { return }
            _ = try? c.decode([String: AnyJSON].self)
        }
    }
}

// MARK: - Tolerant scalar decoding

/// Number/bool fields that Audiobookshelf has shipped in more than one JSON shape.
///
/// §Sync (REVIEW-2026-09-09.md): a `Double` field arriving as `"12.5"`, an epoch-ms
/// `Int` field arriving as `1.7e12`, or an `isFinished` arriving as `1` each threw a
/// `typeMismatch` — and inside a record on the user object, one of those threw away
/// every book's progress and every bookmark. These accept the reasonable encodings and
/// return `nil` for anything else, never throwing, since each caller's field is already
/// optional. `SeriesRef.sequence` hand-rolled the same string-or-number dance for
/// `sequence`; this is that pattern generalized rather than re-derived per field.
extension KeyedDecodingContainer {

    func lenientDouble(_ key: Key) -> Double? {
        if let d = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return d }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(s) }
        return nil
    }

    /// Whole-number fields (epoch milliseconds, mostly). A fractional or exponent-form
    /// number is truncated, and clamped first: `Int(someDouble)` *traps* on a non-finite
    /// or out-of-range value, which is the same crash class `Double.safeSeconds` exists
    /// to prevent elsewhere in this file.
    func lenientInt(_ key: Key) -> Int? {
        if let i = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return i }
        guard let d = lenientDouble(key), d.isFinite else { return nil }
        return Int(d.clamped(to: -9_007_199_254_740_992...9_007_199_254_740_992))
    }

    /// `true`/`false`, or `1`/`0`, or `"true"`/`"1"`.
    func lenientBool(_ key: Key) -> Bool? {
        if let b = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil { return b }
        if let d = lenientDouble(key) { return d != 0 }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            switch s.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Personalized View

struct PersonalizedView: Codable, Identifiable {
    var id: String { labelStringKey }
    let label: String
    let labelStringKey: String
    let type: String?
    let entities: [LibraryItem]?

    enum CodingKeys: String, CodingKey { case label, labelStringKey, type, entities }

    // Tolerant decode so one malformed shelf (or one bad entity within a shelf)
    // can't fail the entire personalized response.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labelStringKey = (try? c.decode(String.self, forKey: .labelStringKey)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? labelStringKey
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        // Skip entities that don't decode as LibraryItem rather than dropping the shelf.
        entities = (try? c.decode(LossyArray<LibraryItem>.self, forKey: .entities))?.elements
    }

    /// Only "book"/"podcast" shelves contain real LibraryItems we can render as tiles.
    /// "series"/"authors"/"episode" shelves carry different entity shapes and are
    /// browsed from the Library tab instead.
    var isBookShelf: Bool {
        guard let type else { return true }
        return type == "book" || type == "podcast"
    }
}

// MARK: - Progress Update

struct ProgressUpdate: Codable {
    let progress: Double
    let currentTime: Double
    let isFinished: Bool
    let duration: Double
}

// MARK: - Convenience Extensions

extension LibraryItem {
    /// Bug fix (26 August 2026): server metadata's `title` is `String?`, and in
    /// practice can also come back as an empty (or whitespace-only) string, not just
    /// nil — most commonly on freshly-scanned items whose metadata hasn't been
    /// matched/enriched yet, which is exactly why this surfaced first on Home's
    /// "Recently Added" shelf (newly-added items are disproportionately likely to be
    /// exactly that kind of not-yet-enriched entry). The old `?? "Unknown Title"`
    /// fallback only caught the `nil` case, so an empty-string title rendered as a
    /// blank line next to a perfectly normal cover (`CachedCover`/`CoverImageView`
    /// resolve artwork from `item.id` directly, independent of this decoded field) —
    /// reading as "the title is missing" rather than the graceful "Unknown Title"
    /// fallback every other incomplete-metadata case in the app already gets.
    var title: String {
        guard let raw = media?.metadata?.title,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Unknown Title", comment: "Fallback title for a book with no title metadata")
        }
        return Self.displayTitle(raw)
    }

    /// G2 (REVIEW_2026-09-04_UI.md): Audible-sourced metadata — most Audiobookshelf
    /// libraries — carries the edition marker into the title ("Mark of the Fool 10
    /// (Unabridged)"). Every audiobook is unabridged unless it says otherwise, so the
    /// suffix is noise on every surface, and it's the first thing the mini player's
    /// ~95pt title column truncates for. Stripped for display only: the raw string is
    /// still `media?.metadata?.title` (the ebook reader uses it), and server-side sort
    /// and search never see this. Handles "(Unabridged)", "[Unabridged]",
    /// ": Unabridged" and " - Unabridged" at the end of the title, case-insensitively;
    /// a title that is *only* the marker, or has the word anywhere else, is untouched.
    static func displayTitle(_ raw: String) -> String {
        // W3 (REVIEW_2026-09-04_UI.md Pass 4): the rule itself now lives in
        // `SharedPlayback.normalizedTitle`, which the widget extension also compiles, so
        // the app and the widget's snapshot migration can't disagree about what a display
        // title is. `SharedPlaybackMigrationTests` pins the two entry points to the same
        // corpus; this is the single implementation both resolve to.
        SharedPlayback.normalizedTitle(raw)
    }

    /// Same empty-string gap as `title` above, fixed the same way.
    var authorName: String {
        guard let raw = media?.metadata?.authorName,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Unknown Author", comment: "Fallback author name for a book with no author metadata")
        }
        return raw
    }

    var narratorName: String? {
        media?.metadata?.narratorName
    }

    var seriesName: String? {
        media?.metadata?.seriesName
    }

    /// Position within its series, if the title encodes one (e.g. "… #12").
    /// Used by the smarter next-in-series ordering.
    var seriesSequence: Double? {
        media?.metadata?.seriesSequence
    }

    /// Position within a specific named series — correct for multi-series books.
    func sequence(inSeriesNamed name: String) -> Double? {
        media?.metadata?.sequence(inSeriesNamed: name)
    }

    /// The Audible ASIN, if this item was matched against the Audible provider during
    /// an ABS library scan. Not currently used by any feature (the Audnexus-based
    /// series lookup that used to read this was removed — see `CHANGES_IMPLEMENTED.md`
    /// Batch 207) — kept as a passthrough of ABS's own metadata rather than removed.
    var asin: String? {
        media?.metadata?.asin
    }

    var duration: Double {
        media?.duration ?? 0
    }

    var description: String? {
        media?.metadata?.description
    }

    var chapters: [Chapter] {
        media?.chapters ?? []
    }

    /// How many of this book's chapters the server sent in a shape this client couldn't
    /// use, and which were therefore left out of `chapters` (Item 11). Drives the note
    /// under the chapter list in `BookDetailView`; see `Chapter.droppedChapterNote(count:)`.
    var droppedChapterCount: Int {
        media?.droppedChapterCount ?? 0
    }

    var progressPercent: Double {
        mediaProgress?.progress ?? 0
    }

    var currentTime: Double {
        mediaProgress?.currentTime ?? 0
    }

    var isFinished: Bool {
        mediaProgress?.isFinished ?? false
    }
}

/// Series ordering over a fetched set of books, bridging `LibraryItem` to the pure
/// decisions in `SeriesOrdering`. Download state is supplied by the caller as a closure
/// rather than read from `DownloadManager` here, so this stays in the Models layer
/// without reaching into Services for it.
extension Array where Element == LibraryItem {
    private func seriesCandidates(
        inSeriesNamed name: String, isDownloaded: ((String) -> Bool)?
    ) -> [SeriesOrdering.Candidate] {
        map {
            SeriesOrdering.Candidate(
                id: $0.id,
                sequence: $0.sequence(inSeriesNamed: name),
                isFinished: $0.isFinished,
                isDownloaded: isDownloaded?($0.id) ?? false
            )
        }
    }

    private func item(matching candidate: SeriesOrdering.Candidate?) -> LibraryItem? {
        guard let candidate else { return nil }
        return first { $0.id == candidate.id }
    }

    /// Sequence order within `name`, unsequenced books last.
    func sortedBySeriesSequence(inSeriesNamed name: String) -> [LibraryItem] {
        sorted { SeriesOrdering.precedes($0.sequence(inSeriesNamed: name), $1.sequence(inSeriesNamed: name)) }
    }

    /// The next unfinished book after `book` within `name` — strictly later in the
    /// series, never an earlier one left unfinished. Pass `isDownloaded` to prefer an
    /// already-downloaded book over an earlier streamed one.
    func nextUnfinishedInSeries(
        after book: LibraryItem, seriesName name: String, isDownloaded: ((String) -> Bool)? = nil
    ) -> LibraryItem? {
        item(matching: SeriesOrdering.nextUnfinished(
            after: book.id,
            currentSequence: book.sequence(inSeriesNamed: name),
            in: seriesCandidates(inSeriesNamed: name, isDownloaded: isDownloaded),
            preferDownloaded: isDownloaded != nil
        ))
    }

    /// The next book after `book` regardless of progress — the fallback for when every
    /// later book in the series is already finished.
    func nextAvailableInSeries(after book: LibraryItem, seriesName name: String) -> LibraryItem? {
        item(matching: SeriesOrdering.nextAvailable(
            after: book.id,
            currentSequence: book.sequence(inSeriesNamed: name),
            in: seriesCandidates(inSeriesNamed: name, isDownloaded: nil)
        ))
    }
}

extension Double {
    /// S2/S4 (REVIEW_2026-08-20_UI_SECURITY.md): `Int(someDouble)` **traps** — crashes the
    /// process, not a throwing conversion — on `.nan`, `±.infinity`, or a value outside
    /// `Int64` range. Every value this is applied to (`formattedDuration`/`formattedTime`
    /// below, `AudioBookmark.id`, the `deleteBookmark` path interpolation) comes from an
    /// untrusted, user-supplied Audiobookshelf server — a compromised server, a buggy
    /// server build, a corrupted database row, or a MITM on an explicitly-permitted plain-
    /// HTTP LAN connection could otherwise hard-crash the client at will, repeatably, on
    /// every render. Clamps to 0...1 year in seconds, which comfortably covers any real
    /// audiobook duration/position while guaranteeing the value handed to `Int(...)` is
    /// always finite and in range.
    var safeSeconds: Int {
        guard self.isFinite else { return 0 }
        return Int(Swift.max(0, Swift.min(self, 86_400 * 365)))
    }

    var formattedDuration: String {
        let totalSeconds = self.safeSeconds
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(localized: "\(hours)h \(minutes)m", comment: "Duration with hours and minutes. First %lld is hours, second is minutes. e.g. 1h 20m")
        }
        // R6 (REVIEW_2026-09-04_UI.md): sub-minute durations (e.g. a 16s
        // "Opening Credits" chapter) used to floor to "0m". Show seconds
        // instead so a real, non-zero duration never displays as "0m".
        // Zero itself stays "0m" — `testFormattedDurationZero` and callers
        // that gate on `duration > 0` already treat "0m" as the no-duration
        // case, so changing it to "0s" would be a gratuitous behavior change.
        if totalSeconds == 0 {
            return String(localized: "0m", comment: "Zero duration in minutes")
        }
        if minutes > 0 {
            return String(localized: "\(minutes)m", comment: "Duration in minutes. %lld is minutes. e.g. 20m")
        }
        return String(localized: "\(totalSeconds)s", comment: "Duration in seconds. %lld is seconds. e.g. 16s")
    }

    var formattedTime: String {
        let totalSeconds = self.safeSeconds
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
