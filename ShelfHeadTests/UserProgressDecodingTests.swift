import XCTest
@testable import ShelfHead

/// §Sync (REVIEW-2026-09-09.md): one malformed record in `/api/me` used to fail the whole
/// `User` decode, and `LibraryViewModel.loadUserProgress()` swallowed that error. The
/// visible result was an account that looked like it had never listened to anything:
/// no progress on any book, an empty All Bookmarks, `DownloadManager.reconcile` never
/// running, and `AudioPlayerService.serverProgressMap` empty so queued offline
/// positions were pushed over whatever the server held.
///
/// These pin the tolerant decode that replaced it. Same plain `JSONDecoder()` the app
/// uses for every response (`AudiobookshelfAPI.get`), so the fixtures exercise the real
/// configuration rather than a stricter/looser one.
final class UserProgressDecodingTests: XCTestCase {

    private func decodeUser(_ json: String) throws -> User {
        try JSONDecoder().decode(User.self, from: Data(json.utf8))
    }

    private func decodeProgress(_ json: String) throws -> MediaProgress {
        try JSONDecoder().decode(MediaProgress.self, from: Data(json.utf8))
    }

    // MARK: - A whole valid payload still decodes exactly as before

    func testFullyValidPayloadRoundTrips() throws {
        let user = try decodeUser(#"""
        {
          "id": "u1", "username": "justin", "token": "legacy",
          "accessToken": "jwt", "refreshToken": "refresh",
          "type": "root", "isActive": true,
          "mediaProgress": [
            {"id": "p1", "libraryItemId": "b1", "duration": 3600.5, "progress": 0.25,
             "currentTime": 900.25, "isFinished": false, "lastUpdate": 1700000000000,
             "startedAt": 1600000000000, "finishedAt": null}
          ],
          "bookmarks": [
            {"libraryItemId": "b1", "title": "Good bit", "time": 42.5, "createdAt": 1700000000000}
          ]
        }
        """#)

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.username, "justin")
        XCTAssertEqual(user.effectiveAccessToken, "jwt", "accessToken must win over the legacy token")
        XCTAssertEqual(user.refreshToken, "refresh")
        XCTAssertEqual(user.type, "root")
        XCTAssertEqual(user.isActive, true)

        let progress = try XCTUnwrap(user.mediaProgress?.first)
        XCTAssertEqual(progress.id, "p1")
        XCTAssertEqual(progress.libraryItemId, "b1")
        XCTAssertNil(progress.episodeId)
        XCTAssertEqual(progress.duration, 3600.5)
        XCTAssertEqual(progress.progress, 0.25)
        XCTAssertEqual(progress.currentTime, 900.25)
        XCTAssertEqual(progress.isFinished, false)
        XCTAssertEqual(progress.lastUpdate, 1_700_000_000_000)
        XCTAssertEqual(progress.startedAt, 1_600_000_000_000)
        XCTAssertNil(progress.finishedAt)

        let bookmark = try XCTUnwrap(user.bookmarks?.first)
        XCTAssertEqual(bookmark.libraryItemId, "b1")
        XCTAssertEqual(bookmark.title, "Good bit")
        XCTAssertEqual(bookmark.time, 42.5)
        XCTAssertEqual(bookmark.createdAt, 1_700_000_000_000)
        XCTAssertEqual(bookmark.id, "b1-42", "identity is (item, whole seconds) — the delete endpoint's key")
    }

    /// Encode-decode round trip: the tolerant decoders are hand-written, so this also
    /// checks the `CodingKeys` they introduced still line up with the synthesized
    /// `encode(to:)` on both record types.
    func testDecodedUserSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = try decodeUser(#"""
        {
          "id": "u1", "username": "justin", "accessToken": "jwt", "isActive": true,
          "mediaProgress": [
            {"id": "p1", "libraryItemId": "b1", "duration": 3600, "progress": 0.5,
             "currentTime": 1800, "isFinished": false, "lastUpdate": 1700000000000}
          ],
          "bookmarks": [{"libraryItemId": "b1", "title": "Note", "time": 42}]
        }
        """#)

        let round = try JSONDecoder().decode(User.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(round.id, original.id)
        XCTAssertEqual(round.username, original.username)
        XCTAssertEqual(round.accessToken, original.accessToken)
        XCTAssertEqual(round.isActive, original.isActive)
        XCTAssertEqual(round.mediaProgress?.count, 1)
        XCTAssertEqual(round.mediaProgress?.first?.id, "p1")
        XCTAssertEqual(round.mediaProgress?.first?.libraryItemId, "b1")
        XCTAssertEqual(round.mediaProgress?.first?.currentTime, 1800)
        XCTAssertEqual(round.mediaProgress?.first?.lastUpdate, 1_700_000_000_000)
        XCTAssertEqual(round.bookmarks?.first?.title, "Note")
        XCTAssertEqual(round.bookmarks?.first?.time, 42)
    }

    /// A user with no progress/bookmark keys at all (a brand new account) decodes to nil
    /// arrays rather than throwing — `loadUserProgress` relies on that to leave its maps
    /// untouched.
    func testMinimalUserDecodes() throws {
        let user = try decodeUser(#"{"id":"u1","username":"justin"}"#)
        XCTAssertNil(user.mediaProgress)
        XCTAssertNil(user.bookmarks)
        XCTAssertNil(user.effectiveAccessToken)
    }

    // MARK: - One bad record no longer takes the whole payload down

    func testMalformedProgressElementIsDroppedAndTheGoodOnesSurvive() throws {
        // The middle record has a null `libraryItemId` — the one field that genuinely
        // cannot be salvaged, since it is the key every consumer looks progress up by.
        let user = try decodeUser(#"""
        {
          "id": "u1", "username": "justin",
          "mediaProgress": [
            {"id": "p1", "libraryItemId": "b1", "currentTime": 10},
            {"id": "p2", "libraryItemId": null, "currentTime": 20},
            {"id": "p3", "libraryItemId": "b3", "currentTime": 30}
          ]
        }
        """#)

        let ids = (user.mediaProgress ?? []).map(\.libraryItemId)
        XCTAssertEqual(ids, ["b1", "b3"], "Only the unusable record should be dropped")
    }

    func testProgressElementOfTheWrongTypeEntirelyIsDropped() throws {
        let user = try decodeUser(#"""
        {
          "id": "u1", "username": "justin",
          "mediaProgress": ["not-an-object", {"libraryItemId": "b2", "currentTime": 5}]
        }
        """#)
        XCTAssertEqual((user.mediaProgress ?? []).map(\.libraryItemId), ["b2"])
    }

    func testMalformedBookmarkIsDroppedAndTheGoodOnesSurvive() throws {
        // A bookmark with no `time` is meaningless (nothing to seek to, and no identity
        // for the delete endpoint), so it is dropped rather than defaulted to zero.
        let user = try decodeUser(#"""
        {
          "id": "u1", "username": "justin",
          "bookmarks": [
            {"libraryItemId": "b1", "title": "One", "time": 10},
            {"libraryItemId": "b1", "title": "No time", "time": null},
            {"libraryItemId": "b2", "title": "Two", "time": 20}
          ]
        }
        """#)

        XCTAssertEqual((user.bookmarks ?? []).map(\.title), ["One", "Two"])
    }

    func testBookmarkWithoutATitleKeepsAnEmptyNote() throws {
        // A missing note is not a reason to lose the bookmark — the UI already renders an
        // untitled bookmark by its timestamp (same call `Chapter.title` makes).
        let user = try decodeUser(#"""
        {
          "id": "u1", "username": "justin",
          "bookmarks": [
            {"libraryItemId": "b1", "time": 10},
            {"libraryItemId": "b1", "title": null, "time": 20}
          ]
        }
        """#)

        XCTAssertEqual((user.bookmarks ?? []).count, 2)
        XCTAssertEqual((user.bookmarks ?? []).map(\.title), ["", ""])
    }

    /// `LoginResponse` decodes a `User` too, so before the fix a single bad progress row
    /// also failed sign-in outright — not just the progress refresh.
    func testLoginResponseSurvivesABadProgressRecord() throws {
        let response = try JSONDecoder().decode(LoginResponse.self, from: Data(#"""
        {
          "user": {
            "id": "u1", "username": "justin", "accessToken": "jwt",
            "mediaProgress": [{"libraryItemId": null}, {"libraryItemId": "b1"}]
          },
          "userDefaultLibraryId": "lib1"
        }
        """#.utf8))

        XCTAssertEqual(response.user.effectiveAccessToken, "jwt")
        XCTAssertEqual((response.user.mediaProgress ?? []).count, 1)
    }

    // MARK: - Synthesized progress id

    /// `MediaProgress.id` is never sent back to the server (progress is written by
    /// `libraryItemId` via `PATCH /api/me/progress/<id>`) and is never used as a
    /// `ForEach` identity over progress records, so synthesizing it is safe.
    func testProgressIdIsSynthesizedFromTheItemIdWhenMissing() throws {
        let progress = try decodeProgress(#"{"libraryItemId":"b1","currentTime":10}"#)
        XCTAssertEqual(progress.id, "b1")
    }

    func testProgressIdIsSynthesizedFromItemAndEpisodeForAPodcast() throws {
        let progress = try decodeProgress(#"{"libraryItemId":"pod1","episodeId":"ep7","currentTime":10}"#)
        XCTAssertEqual(progress.id, "pod1-ep7",
                       "An episode's id must not collapse onto the show's id")
        XCTAssertEqual(progress.episodeId, "ep7")
    }

    func testBlankProgressIdIsAlsoSynthesized() throws {
        let progress = try decodeProgress(#"{"id":"","libraryItemId":"b1"}"#)
        XCTAssertEqual(progress.id, "b1")
    }

    func testProgressWithoutAnItemIdIsStillRejected() {
        // The complement of the synthesized-id tests: `libraryItemId` is not optional,
        // because a record that can't name its book can't be looked up or written back.
        XCTAssertThrowsError(try decodeProgress(#"{"id":"p1","currentTime":10}"#))
    }

    // MARK: - Numeric fields: int vs double vs string vs null

    func testIntegerNumbersDecodeIntoDoubleFields() throws {
        let progress = try decodeProgress(#"""
        {"libraryItemId":"b1","duration":3600,"progress":1,"currentTime":900}
        """#)
        XCTAssertEqual(progress.duration, 3600)
        XCTAssertEqual(progress.progress, 1)
        XCTAssertEqual(progress.currentTime, 900)
    }

    func testNumericStringsDecodeIntoDoubleFields() throws {
        let progress = try decodeProgress(#"""
        {"libraryItemId":"b1","duration":"3600.5","currentTime":"900.25"}
        """#)
        XCTAssertEqual(progress.duration, 3600.5)
        XCTAssertEqual(progress.currentTime, 900.25)
    }

    /// Epoch milliseconds in exponent/fractional form used to fail a plain `Int` decode —
    /// and `lastUpdate` is the field the whole last-write-wins reconciliation turns on.
    func testFractionalEpochMillisecondsStillYieldLastUpdate() throws {
        let progress = try decodeProgress(#"""
        {"libraryItemId":"b1","lastUpdate":1700000000000.0,"startedAt":"1600000000000"}
        """#)
        XCTAssertEqual(progress.lastUpdate, 1_700_000_000_000)
        XCTAssertEqual(progress.startedAt, 1_600_000_000_000)
    }

    func testNonFiniteEpochValueYieldsNilRatherThanTrapping() throws {
        // `Int(someDouble)` traps on a non-finite/out-of-range value; a hostile or
        // corrupt payload must produce `nil`, not a crash on launch.
        let progress = try decodeProgress(#"{"libraryItemId":"b1","lastUpdate":"1e400"}"#)
        XCTAssertNil(progress.lastUpdate)
    }

    func testIsFinishedAcceptsZeroAndOne() throws {
        XCTAssertEqual(try decodeProgress(#"{"libraryItemId":"b1","isFinished":1}"#).isFinished, true)
        XCTAssertEqual(try decodeProgress(#"{"libraryItemId":"b1","isFinished":0}"#).isFinished, false)
        XCTAssertEqual(try decodeProgress(#"{"libraryItemId":"b1","isFinished":"true"}"#).isFinished, true)
    }

    func testUnusableNumbersBecomeNilRatherThanFailingTheRecord() throws {
        let progress = try decodeProgress(#"""
        {"libraryItemId":"b1","duration":null,"currentTime":"soon","isFinished":"maybe"}
        """#)
        XCTAssertEqual(progress.libraryItemId, "b1", "The record itself must still survive")
        XCTAssertNil(progress.duration)
        XCTAssertNil(progress.currentTime)
        XCTAssertNil(progress.isFinished)
    }

    func testBookmarkTimeAcceptsAnIntegerOrAString() throws {
        let ints = try JSONDecoder().decode([AudioBookmark].self, from: Data(#"""
        [{"libraryItemId":"b1","time":10},{"libraryItemId":"b1","time":"20.5"}]
        """#.utf8))
        XCTAssertEqual(ints.map(\.time), [10, 20.5])
    }

    // MARK: - LossyArray diagnostics

    /// The drop is logged, so "one book lost its progress" is diagnosable from an
    /// exported diagnostics file instead of being silent.
    func testLossyArrayRecordsTheIndexAndReasonOfEachDroppedElement() throws {
        let array = try JSONDecoder().decode(LossyArray<MediaProgress>.self, from: Data(#"""
        [{"libraryItemId":"b1"},{"libraryItemId":null},{"libraryItemId":"b3"},7]
        """#.utf8))

        XCTAssertEqual(array.elements.map(\.libraryItemId), ["b1", "b3"])
        XCTAssertEqual(array.skipped.map(\.index), [1, 3])
        XCTAssertFalse(array.skipped[0].reason.isEmpty)
        for skip in array.skipped {
            XCTAssertFalse(skip.reason.contains("token"), "A skip reason must never carry a secret")
        }
    }

    func testLossyArrayReportsNothingSkippedForACleanArray() throws {
        let array = try JSONDecoder().decode(LossyArray<MediaProgress>.self, from: Data(#"""
        [{"libraryItemId":"b1"},{"libraryItemId":"b2"}]
        """#.utf8))
        XCTAssertEqual(array.elements.count, 2)
        XCTAssertTrue(array.skipped.isEmpty)
    }
}
