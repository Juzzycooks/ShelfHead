import XCTest
@testable import ShelfHead

/// Item 11 (`REVIEW-2026-09-09-REMAINING.md`): `Media.chapters` and
/// `PlaybackSession.chapters` were plain arrays of a strictly-decoded `Chapter`, so ONE
/// chapter carrying a `null` (or absent, or string) `start` failed the whole `getItem`
/// **and** the whole `POST /api/items/<id>/play` decode for that title — book detail
/// showed nothing and the book refused to play, with nothing on screen to say why.
/// Batch 310 left this strict deliberately, because dropping a chapter changes the
/// mapping `TrackTimeline` and the chapter-relative scrubber are built on. The user's
/// decision was to **drop the malformed chapter and warn**, which is what these pin:
///
/// - what counts as malformed (and, just as importantly, what does *not*),
/// - that the surviving chapters keep their order and their ids,
/// - that the count of dropped chapters round-trips through the Up Next queue file's
///   JSON while a file written by an older build (no such key) still decodes,
/// - the exact user-facing copy, including its 1-vs-N grammar,
/// - what happens to a position that falls in the gap a dropped chapter leaves behind,
/// - and the same lossy treatment for podcast episodes, collections and playlists.
///
/// Plain `JSONDecoder()`/`JSONEncoder()` throughout — the same configuration
/// `AudiobookshelfAPI.get` and `PlayerViewModel.saveQueue` use.
///
/// `@MainActor` for the same reason `CurrentChapterResolutionTests` is: `PlayerViewModel`
/// is main-actor isolated, and the gap test below reaches for its chapter resolution.
@MainActor
final class LossyChapterDecodingTests: XCTestCase {

    private func decodeItem(_ json: String) throws -> ShelfHead.LibraryItem {
        try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }

    private func decodeSession(_ json: String) throws -> PlaybackSession {
        try JSONDecoder().decode(PlaybackSession.self, from: Data(json.utf8))
    }

    /// A library item whose media carries exactly the chapter JSON handed in.
    private func item(chaptersJSON: String, extraMediaKeys: String = "") throws -> ShelfHead.LibraryItem {
        try decodeItem(#"""
        {
          "id": "b1", "mediaType": "book",
          "media": {
            "metadata": {"title": "A Book", "authorName": "An Author"},
            "duration": 500, "numChapters": 5, "numAudioFiles": 1\#(extraMediaKeys),
            "chapters": \#(chaptersJSON)
          }
        }
        """#)
    }

    // MARK: - The failure this exists to remove

    func testOneNullStartChapterIsDroppedAndTheOtherFourSurviveInOrder() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": 0,    "end": 100, "title": "One"},
          {"id": 1, "start": 100,  "end": 200, "title": "Two"},
          {"id": 2, "start": null, "end": 300, "title": "Three"},
          {"id": 3, "start": 300,  "end": 400, "title": "Four"},
          {"id": 4, "start": 400,  "end": 500, "title": "Five"}
        ]
        """#)

        XCTAssertEqual(decoded.chapters.count, 4, "only the malformed chapter should be dropped")
        XCTAssertEqual(decoded.chapters.map(\.id), [0, 1, 3, 4], "surviving chapters keep their ids, in order")
        XCTAssertEqual(decoded.chapters.map(\.title), ["One", "Two", "Four", "Five"])
        XCTAssertEqual(decoded.droppedChapterCount, 1)
        XCTAssertEqual(decoded.title, "A Book", "the rest of the item must be unaffected")
    }

    func testChapterWithANonNumericStartIsDropped() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": 0, "end": 100, "title": "One"},
          {"id": 1, "start": "sometime", "end": 200, "title": "Two"}
        ]
        """#)
        XCTAssertEqual(decoded.chapters.map(\.id), [0])
        XCTAssertEqual(decoded.droppedChapterCount, 1)
    }

    func testChapterMissingItsEndIsDropped() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": 0, "title": "No end"},
          {"id": 1, "start": 100, "end": 200, "title": "Two"}
        ]
        """#)
        XCTAssertEqual(decoded.chapters.map(\.id), [1])
        XCTAssertEqual(decoded.droppedChapterCount, 1)
    }

    func testChapterWithoutAnIdIsDropped() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"start": 0, "end": 100, "title": "No id"},
          {"id": 1, "start": 100, "end": 200, "title": "Two"}
        ]
        """#)
        XCTAssertEqual(decoded.chapters.map(\.id), [1], "id is the ForEach/seek identity; a chapter without one can't be listed")
        XCTAssertEqual(decoded.droppedChapterCount, 1)
    }

    func testEveryChapterMalformedLeavesAnEmptyListAndTheItemStillDecodes() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": null, "end": 100, "title": "One"},
          {"id": 1, "start": null, "end": 200, "title": "Two"},
          {"id": 2, "start": null, "end": 300, "title": "Three"}
        ]
        """#)
        XCTAssertTrue(decoded.chapters.isEmpty)
        XCTAssertEqual(decoded.droppedChapterCount, 3)
        XCTAssertEqual(decoded.title, "A Book", "the book itself must still open — chapterless, not missing")
        XCTAssertEqual(decoded.duration, 500)
    }

    // MARK: - What is deliberately NOT malformed

    func testNumericStringTimesAreAccepted() throws {
        let decoded = try item(chaptersJSON: #"""
        [{"id": 0, "start": "10.5", "end": "100", "title": "Stringly typed"}]
        """#)
        XCTAssertEqual(decoded.chapters.count, 1)
        XCTAssertEqual(decoded.chapters.first?.start, 10.5)
        XCTAssertEqual(decoded.chapters.first?.end, 100)
        XCTAssertEqual(decoded.droppedChapterCount, 0)
    }

    func testAChapterWithoutATitleIsKeptWithAnEmptyTitle() throws {
        let decoded = try item(chaptersJSON: #"""
        [{"id": 0, "start": 0, "end": 100, "title": null}]
        """#)
        XCTAssertEqual(decoded.chapters.first?.title, "")
        XCTAssertEqual(decoded.droppedChapterCount, 0)
    }

    /// Documents the rule chosen in `Chapter.init(from:)`: a zero-length or inverted
    /// chapter is *kept*. It can never be resolved as "current" (the range check is
    /// half-open), every derived value clamps, and dropping it would make an offline
    /// manifest written by an older build undecodable — `DownloadedBook.chapters` is a
    /// strict `[Chapter]`.
    func testZeroLengthAndInvertedChaptersAreKeptNotDropped() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": 0, "end": 0, "title": "Zero length"},
          {"id": 1, "start": 300, "end": 200, "title": "Inverted"},
          {"id": 2, "start": -5, "end": 100, "title": "Negative start"}
        ]
        """#)
        XCTAssertEqual(decoded.chapters.count, 3)
        XCTAssertEqual(decoded.droppedChapterCount, 0)
        // None of them can be resolved as the current chapter, and nothing traps.
        XCTAssertNil(PlayerViewModel.chapterIndex(in: decoded.chapters, at: 250))
        XCTAssertEqual((0.0 - 0.0).formattedDuration, "0m")
        XCTAssertEqual((200.0 - 300.0).formattedDuration, "0m", "safeSeconds clamps a negative length")
    }

    // MARK: - Round trip through the Up Next queue file

    func testLegacyItemJSONWithoutTheDroppedCountKeyDecodesWithZero() throws {
        // Exactly the shape `PlayerViewModel.saveQueue` wrote before this change: no
        // `droppedChapterCount` key anywhere in the media object.
        let decoded = try decodeItem(#"""
        {
          "id": "b1", "ino": "9", "libraryId": "lib1", "mediaType": "book",
          "numFiles": 3, "size": 1234, "addedAt": 1600000000000, "updatedAt": 1700000000000,
          "media": {
            "metadata": {"title": "A Book"},
            "coverPath": "/covers/b1.jpg", "duration": 300,
            "numChapters": 2, "numAudioFiles": 1,
            "chapters": [
              {"id": 0, "start": 0, "end": 100, "title": "One"},
              {"id": 1, "start": 100, "end": 300, "title": "Two"}
            ]
          },
          "userMediaProgress": {"libraryItemId": "b1", "currentTime": 42, "progress": 0.14}
        }
        """#)

        XCTAssertEqual(decoded.droppedChapterCount, 0, "an old queue file has no count and must default to zero")
        XCTAssertEqual(decoded.chapters.count, 2)
        // The hand-written `LibraryItem`/`Media` decoders must still carry every field
        // the synthesized ones did.
        XCTAssertEqual(decoded.ino, "9")
        XCTAssertEqual(decoded.libraryId, "lib1")
        XCTAssertEqual(decoded.mediaType, "book")
        XCTAssertEqual(decoded.numFiles, 3)
        XCTAssertEqual(decoded.size, 1234)
        XCTAssertEqual(decoded.addedAt, 1_600_000_000_000)
        XCTAssertEqual(decoded.updatedAt, 1_700_000_000_000)
        XCTAssertEqual(decoded.media?.coverPath, "/covers/b1.jpg")
        XCTAssertEqual(decoded.media?.numChapters, 2)
        XCTAssertEqual(decoded.media?.numAudioFiles, 1)
        XCTAssertEqual(decoded.duration, 300)
        XCTAssertEqual(decoded.mediaProgress?.currentTime, 42)
    }

    func testTheDroppedCountSurvivesTheQueueFilesEncodeDecodeRoundTrip() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": 0, "end": 100, "title": "One"},
          {"id": 1, "start": null, "end": 200, "title": "Two"},
          {"id": 2, "start": 200, "end": 300, "title": "Three"}
        ]
        """#)
        XCTAssertEqual(decoded.droppedChapterCount, 1)

        // `[ShelfHead.LibraryItem]` is exactly what goes into (and comes back out of) upNext.json.
        let data = try JSONEncoder().encode([decoded])
        let round = try JSONDecoder().decode([ShelfHead.LibraryItem].self, from: data)

        XCTAssertEqual(round.first?.chapters.map(\.id), [0, 2])
        XCTAssertEqual(round.first?.droppedChapterCount, 1, "the warning must survive a relaunch, not silently reset")
    }

    func testAPersistedCountIsKeptEvenWhenTheChaptersInThatPayloadAreAllFine() throws {
        let decoded = try item(
            chaptersJSON: #"[{"id": 0, "start": 0, "end": 100, "title": "One"}]"#,
            extraMediaKeys: #", "droppedChapterCount": 2"#
        )
        XCTAssertEqual(decoded.chapters.count, 1)
        XCTAssertEqual(decoded.droppedChapterCount, 2, "the array was filtered before it was written; the count is the only record left")
    }

    // MARK: - Playback session (the other half of the same bug)

    func testSessionDropsAMalformedChapterAndStillDecodes() throws {
        let session = try decodeSession(#"""
        {
          "id": "sess-1", "libraryItemId": "b1", "mediaType": "book",
          "duration": 300, "playMethod": 0, "currentTime": 12, "startTime": 12,
          "audioTracks": [{"index": 0, "startOffset": 0, "duration": 300, "contentUrl": "/x.m4b"}],
          "chapters": [
            {"id": 0, "start": 0, "end": 100, "title": "One"},
            {"id": 1, "start": "", "end": 200, "title": "Two"},
            {"id": 2, "start": 200, "end": 300, "title": "Three"}
          ]
        }
        """#)

        XCTAssertEqual(session.id, "sess-1")
        XCTAssertEqual(session.chapters?.map(\.id), [0, 2])
        XCTAssertEqual(session.droppedChapterCount, 1)
        XCTAssertEqual(session.audioTracks?.count, 1)
        XCTAssertEqual(session.currentTime, 12)
        XCTAssertEqual(session.duration, 300)
        XCTAssertEqual(session.playMethod, 0)
    }

    func testLegacySessionJSONWithoutTheCountKeyDecodesWithZero() throws {
        let session = try decodeSession(#"""
        {
          "id": "sess-2", "libraryItemId": "b1",
          "chapters": [{"id": 0, "start": 0, "end": 100, "title": "One"}]
        }
        """#)
        XCTAssertEqual(session.droppedChapterCount, 0)
        XCTAssertEqual(session.chapters?.count, 1)
        XCTAssertNil(session.duration)
    }

    func testSessionCountSurvivesAnEncodeDecodeRoundTrip() throws {
        let session = try decodeSession(#"""
        {
          "id": "sess-3", "libraryItemId": "b1",
          "chapters": [{"id": 0, "start": null, "end": 100, "title": "One"}]
        }
        """#)
        let round = try JSONDecoder().decode(PlaybackSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(round.droppedChapterCount, 1)
        XCTAssertEqual(round.chapters?.count, 0)
    }

    // MARK: - The user-facing copy

    func testNoteIsNilWhenNothingWasDropped() {
        XCTAssertNil(Chapter.droppedChapterNote(count: 0))
        XCTAssertNil(Chapter.droppedChapterNote(count: -1))
    }

    func testNoteIsSingularForOneChapter() {
        XCTAssertEqual(
            Chapter.droppedChapterNote(count: 1),
            "1 chapter couldn't be read from the server and was skipped."
        )
    }

    func testNoteIsPluralForMoreThanOneChapter() {
        XCTAssertEqual(
            Chapter.droppedChapterNote(count: 4),
            "4 chapters couldn't be read from the server and were skipped."
        )
    }

    // MARK: - What a dropped chapter leaves behind: a gap

    /// Pins the behaviour that *already* existed for a time no chapter covers, since a
    /// dropped chapter now makes it reachable in the field: both resolvers return `nil`
    /// rather than snapping to a neighbour. `PlayerViewModel` then falls back to
    /// whole-book values (`hasChapters == false`, `chapterStart = 0`,
    /// `chapterEnd = duration`) — the same state a book with no chapters at all is in —
    /// so nothing shows a negative chapter-relative time and nothing crashes. The player
    /// simply reads whole-book while the position is inside the gap, and returns to
    /// chapter-relative on the far side of it.
    func testATimeInsideTheGapLeftByADroppedChapterBelongsToNoChapter() throws {
        let decoded = try item(chaptersJSON: #"""
        [
          {"id": 0, "start": 0, "end": 100, "title": "One"},
          {"id": 1, "start": null, "end": 200, "title": "Two"},
          {"id": 2, "start": 200, "end": 300, "title": "Three"}
        ]
        """#)
        let chapters = decoded.chapters
        XCTAssertEqual(chapters.map(\.id), [0, 2])

        // Inside the gap (100..<200) — no chapter, on either resolver.
        XCTAssertNil(PlayerViewModel.chapterIndex(in: chapters, at: 100))
        XCTAssertNil(PlayerViewModel.chapterIndex(in: chapters, at: 150))
        XCTAssertNil(PlayerViewModel.chapterIndex(in: chapters, at: 199.9))

        let timeline = TrackTimeline(
            tracks: [AudioTrack(index: 0, startOffset: 0, duration: 300, title: nil,
                                contentUrl: "/x.m4b", mimeType: nil, codec: nil)],
            chapters: chapters
        )
        XCTAssertNil(timeline.chapter(at: 150))

        // Either side of the gap still resolves exactly as before.
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: chapters, at: 50), 0)
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: chapters, at: 250), 1)
        XCTAssertEqual(timeline.chapter(at: 250)?.title, "Three")

        // And the position still resolves to a real track — the gap is a chapter-level
        // hole only, never a playback one.
        XCTAssertEqual(timeline.position(atAbsoluteTime: 150),
                       TrackTimeline.Position(trackIndex: 0, offsetInTrack: 150))
    }

    // MARK: - Podcast episodes

    func testEpisodePublishedAtAcceptsAStringAndAnExponentForm() throws {
        let show = try decodeItem(#"""
        {
          "id": "p1", "mediaType": "podcast",
          "media": {
            "metadata": {"title": "A Show"},
            "episodes": [
              {"id": "e1", "title": "String epoch", "publishedAt": "1700000000000"},
              {"id": "e2", "title": "Exponent epoch", "publishedAt": 1.7e12},
              {"id": "e3", "title": "No epoch", "publishedAt": null}
            ]
          }
        }
        """#)

        let episodes = try XCTUnwrap(show.media?.episodes)
        XCTAssertEqual(episodes.count, 3, "a strict Int used to fail all three of these")
        XCTAssertEqual(episodes[0].publishedAt, 1_700_000_000_000)
        XCTAssertEqual(episodes[1].publishedAt, 1_700_000_000_000)
        XCTAssertNil(episodes[2].publishedAt)
        XCTAssertNil(episodes[2].publishedDate)
    }

    func testOneUndecodableEpisodeIsDroppedAndTheShowKeepsTheRest() throws {
        let show = try decodeItem(#"""
        {
          "id": "p1", "mediaType": "podcast",
          "media": {
            "metadata": {"title": "A Show"},
            "episodes": [
              {"id": "e1", "title": "Good", "duration": 1800},
              {"title": "No id at all"},
              {"id": "e3", "title": "Also good", "duration": "1500"}
            ]
          }
        }
        """#)

        let episodes = try XCTUnwrap(show.media?.episodes)
        XCTAssertEqual(episodes.map(\.id), ["e1", "e3"])
        XCTAssertEqual(episodes[1].duration, 1500, "a numeric-string duration is accepted")
    }

    // MARK: - Collections & playlists

    func testOneMalformedCollectionIsDroppedAndTheGoodOnesSurvive() throws {
        let response = try JSONDecoder().decode(CollectionsResponse.self, from: Data(#"""
        {
          "collections": [
            {"id": "c1", "name": "Favourites", "books": []},
            {"id": null, "name": "Broken"},
            {"id": "c3", "name": "Winter reads", "books": []}
          ]
        }
        """#.utf8))

        XCTAssertEqual(response.collections.map(\.id), ["c1", "c3"], "one bad row must not hide every collection")
        XCTAssertEqual(response.collections.first?.displayName, "Favourites")
    }

    func testOneMalformedPlaylistIsDroppedAndTheGoodOnesSurvive() throws {
        let response = try JSONDecoder().decode(PlaylistsResponse.self, from: Data(#"""
        {
          "playlists": [
            {"id": "pl1", "name": "Short listens", "items": []},
            {"name": "No id"},
            {"id": "pl3", "name": "Road trip", "items": []}
          ]
        }
        """#.utf8))

        XCTAssertEqual(response.playlists.map(\.id), ["pl1", "pl3"])
        XCTAssertEqual(response.playlists.last?.displayName, "Road trip")
    }

    // MARK: - The offline manifest

    private func decodeManifest(_ json: String) throws -> DownloadedBook {
        try JSONDecoder().decode(DownloadedBook.self, from: Data(json.utf8))
    }

    /// Every manifest already on disk was written before `droppedChapterCount` existed.
    /// Swift's *synthesized* `Decodable` would have thrown `keyNotFound` for it — and a
    /// manifest that won't decode is a downloaded book that vanishes from the app — so
    /// this is the test that says the hand-written initializer is doing its job.
    func testLegacyManifestWithoutTheDroppedCountKeyStillDecodes() throws {
        let manifest = try decodeManifest(#"""
        {
          "id": "b1", "title": "A Book", "author": "An Author", "narrator": "A Narrator",
          "duration": 300, "currentTime": 42, "lastUpdate": 1700000000000,
          "chapters": [
            {"id": 0, "start": 0, "end": 100, "title": "One"},
            {"id": 1, "start": 100, "end": 300, "title": "Two"}
          ],
          "tracks": [{"index": 0, "startOffset": 0, "duration": 300, "filename": "t0.m4b"}]
        }
        """#)

        XCTAssertEqual(manifest.droppedChapterCount, 0)
        XCTAssertEqual(manifest.chapters.map(\.id), [0, 1])
        XCTAssertEqual(manifest.tracks.count, 1)
        XCTAssertEqual(manifest.currentTime, 42)
        XCTAssertEqual(manifest.lastUpdate, 1_700_000_000_000)
        XCTAssertEqual(manifest.narrator, "A Narrator")
    }

    /// The other half of "no existing manifest can newly fail": `Chapter`'s new rules
    /// only reject missing/null/non-numeric/non-finite times, so the zero-length and
    /// inverted chapters an older build happily wrote still decode.
    func testLegacyManifestWithAZeroLengthOrInvertedChapterStillDecodes() throws {
        let manifest = try decodeManifest(#"""
        {
          "id": "b1", "title": "A Book", "author": "An Author",
          "duration": 300, "currentTime": 0,
          "chapters": [
            {"id": 0, "start": 0, "end": 0, "title": "Zero length"},
            {"id": 1, "start": 300, "end": 200, "title": "Inverted"}
          ],
          "tracks": [{"index": 0, "startOffset": 0, "duration": 300, "filename": "t0.m4b"}]
        }
        """#)
        XCTAssertEqual(manifest.chapters.count, 2)
        XCTAssertEqual(manifest.droppedChapterCount, 0)
    }

    /// A manifest whose chapter list has somehow been corrupted on disk degrades to the
    /// chapters it can still read instead of failing — the failure mode here is the
    /// worst in the app (the whole downloaded book, files and all, disappears).
    func testAManifestWithAnUnreadableChapterKeepsTheBookAndCountsTheDrop() throws {
        let manifest = try decodeManifest(#"""
        {
          "id": "b1", "title": "A Book", "author": "An Author",
          "duration": 300, "currentTime": 0,
          "chapters": [
            {"id": 0, "start": 0, "end": 100, "title": "One"},
            {"id": 1, "start": null, "end": 300, "title": "Two"}
          ],
          "tracks": [{"index": 0, "startOffset": 0, "duration": 300, "filename": "t0.m4b"}]
        }
        """#)
        XCTAssertEqual(manifest.chapters.map(\.id), [0])
        XCTAssertEqual(manifest.droppedChapterCount, 1)
    }

    func testTheManifestsDroppedCountSurvivesItsOwnEncodeDecodeRoundTrip() throws {
        let fixtures = try chapterFixtures()
        let manifest = DownloadedBook(
            id: "b1", title: "A Book", author: "An Author", narrator: nil,
            duration: 300,
            chapters: fixtures,
            tracks: [.init(index: 0, startOffset: 0, duration: 300, filename: "t0.m4b")],
            currentTime: 10, lastUpdate: nil, droppedChapterCount: 2
        )
        let round = try JSONDecoder().decode(DownloadedBook.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(round.droppedChapterCount, 2)
        XCTAssertEqual(round.chapters.count, 2)
    }

    /// The whole point of putting the count in the manifest: both surfaces that show the
    /// note offline read it from something this manifest builds.
    func testTheOfflineLibraryItemAndSessionBothCarryTheCount() throws {
        let fixtures = try chapterFixtures()
        let manifest = DownloadedBook(
            id: "b1", title: "A Book", author: "An Author", narrator: nil,
            duration: 300,
            chapters: fixtures,
            tracks: [.init(index: 0, startOffset: 0, duration: 300, filename: "t0.m4b")],
            currentTime: 10, lastUpdate: nil, droppedChapterCount: 3
        )

        // `BookDetailView` reads this one.
        XCTAssertEqual(manifest.asLibraryItem().droppedChapterCount, 3)
        XCTAssertEqual(Chapter.droppedChapterNote(count: manifest.asLibraryItem().droppedChapterCount),
                       "3 chapters couldn't be read from the server and were skipped.")

        // `PlayerView.ChapterListSheet` reads the live session's count once playback
        // starts, and offline that session is this one.
        let session = manifest.localSession { _ in URL(string: "file:///tmp/t0.m4b") }
        XCTAssertEqual(session.droppedChapterCount, 3)
        XCTAssertEqual(session.chapters?.count, 2)
        XCTAssertTrue(session.id.hasPrefix("offline-"))
    }

    /// `Chapter` has no memberwise initializer (it owns its `Decodable` one), so manifest
    /// fixtures come through JSON, same as `TrackTimelineTests` does it.
    private func chapterFixtures() throws -> [Chapter] {
        try JSONDecoder().decode([Chapter].self, from: Data(#"""
        [
          {"id": 0, "start": 0, "end": 100, "title": "One"},
          {"id": 1, "start": 100, "end": 300, "title": "Two"}
        ]
        """#.utf8))
    }

    func testAnEmptyOrAbsentCollectionsKeyDecodesAsEmptyRatherThanThrowing() throws {
        let empty = try JSONDecoder().decode(CollectionsResponse.self, from: Data(#"{"collections": []}"#.utf8))
        XCTAssertTrue(empty.collections.isEmpty)

        let absent = try JSONDecoder().decode(PlaylistsResponse.self, from: Data(#"{}"#.utf8))
        XCTAssertTrue(absent.playlists.isEmpty)
    }
}
