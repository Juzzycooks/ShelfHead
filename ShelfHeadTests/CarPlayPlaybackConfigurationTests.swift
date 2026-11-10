import XCTest
import CarPlay
@testable import ShelfHead

// =============================================================================
// ShelfHead • CarPlayPlaybackConfigurationTests
// =============================================================================
//
// Batch 327: pins the pure decisions behind CarPlay's iOS 26.4
// `CPPlaybackConfiguration` adoption — the elapsed/duration/play-pause state pushed
// onto book rows, chapter rows and the Chapters details header:
//   - `bookPlaybackState(...)`: which of two sources of truth a row uses (the live
//     player for the loaded book, the server's progress record for every other book),
//     and when the glyph is a pause rather than a play.
//   - `chapterState(...)` / `chapterPlaybackState(...)`: chapter-relative elapsed and
//     duration, and the half-open "is the position inside this chapter" test.
//   - the clamping both of them funnel through, which is the part that actually
//     matters at runtime: `CMTime(seconds:preferredTimescale:)` encodes NaN, infinity
//     and negatives without complaint, and CarPlay would then draw a progress
//     indicator from garbage on a screen the driver is glancing at.
//
// Deliberately NOT covered here, for the same reason the rest of this file's CarPlay
// siblings draw that line (`CarPlayStateTests`, `CarPlayListWindowingTests`,
// `CarPlayAlertCopyTests`): everything that needs a live `CPInterfaceController` or a
// 26.4 head unit. That means `applyPlaybackConfiguration` (a two-line assignment into
// a `CPPlayableItem`), `attachChaptersHeader` / `refreshChaptersHeader` (template
// mutation), `loadChaptersHeaderCover` (network + `CPThumbnailImage` sizing) and the
// visual calls on the header (`wantsAdaptiveBackgroundStyle`, the placeholder's size in
// the header slot) — all flagged **[device check]** in
// `CHANGES_IMPLEMENTED.md` instead. Same precedent as
// `DownloadManager.shouldReclaimOrphanDirectory`: extract the decision, test the
// decision, leave the plumbing to a real device.
//
// Availability note: nothing in this file touches a 26.4 symbol. The state type and
// both builders are plain `nonisolated static` Swift with no CarPlay types in their
// signatures, precisely so they can be tested at the iOS 17.6 deployment target.
final class CarPlayPlaybackConfigurationTests: XCTestCase {

    // MARK: - Source of truth: current book vs. every other book

    /// The whole point of the current-item branch: the server's progress record is the
    /// STALE number for the book that is actually playing (it is only synced
    /// periodically, and not at all while offline), so the live player position has to
    /// win — otherwise the row under the driver's finger reads minutes behind the audio
    /// coming out of the speakers.
    func testCurrentBookUsesThePlayersLivePositionNotTheServerRecord() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 100, duration: 3600)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: "b1", isPlaying: true,
            playerTime: 2000, playerDuration: 3600)

        XCTAssertEqual(state.elapsed, 2000, "the loaded book must use the player's position, not the server's 100s.")
        XCTAssertEqual(state.duration, 3600)
        XCTAssertEqual(state.action, .pause)
    }

    /// The mirror case, and the one that would be easy to get wrong by reading
    /// `isPlaying` alone: a browse list shows many books while one is playing, and only
    /// the playing one may show a pause glyph.
    func testOtherBooksUseTheirOwnServerProgressAndNeverShowPause() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b2", currentTime: 450, duration: 7200)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: "b1", isPlaying: true,
            playerTime: 2000, playerDuration: 3600)

        XCTAssertEqual(state.elapsed, 450, "a non-current row must ignore the player's position entirely.")
        XCTAssertEqual(state.duration, 7200, "a non-current row must ignore the player's duration entirely.")
        XCTAssertEqual(state.action, .play, "only the loaded book may show a pause glyph.")
    }

    /// Nothing loaded at all — every row is a "play this" row.
    func testNoCurrentItemMeansEveryRowIsAPlayRow() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 450, duration: 7200)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: nil, isPlaying: false,
            playerTime: nil, playerDuration: nil)

        XCTAssertEqual(state.action, .play)
        XCTAssertEqual(state.elapsed, 450)
        XCTAssertEqual(state.duration, 7200)
    }

    /// Paused on the loaded book: still the live position (the driver just paused, the
    /// server may not know yet), but a play glyph, because tapping resumes.
    func testCurrentBookPausedKeepsTheLivePositionButShowsPlay() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 100, duration: 3600)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: "b1", isPlaying: false,
            playerTime: 2000, playerDuration: 3600)

        XCTAssertEqual(state.action, .play)
        XCTAssertEqual(state.elapsed, 2000)
    }

    /// `AudioPlayerService.duration` is 0 between "session started" and "asset ready",
    /// and `CarPlayCoordinator.livePlaybackState` passes `nil` rather than that 0 — so
    /// the fallback has to be the book's own duration, not "unknown". Without it,
    /// opening a list in the second after starting a book would blank the progress
    /// indicator on the very row that just started playing.
    func testCurrentBookFallsBackToTheServerDurationUntilThePlayerKnowsIt() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 900, duration: 3600)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: "b1", isPlaying: true,
            playerTime: 950, playerDuration: nil)

        XCTAssertEqual(state.duration, 3600, "a player that doesn't know the duration yet must not erase the book's own.")
        XCTAssertEqual(state.elapsed, 950)
    }

    /// The `WeakBookRow` re-apply path (`refreshNowPlayingIndicators`) calls the loose
    /// overload, so it has to agree with the `LibraryItem` one row for row — they are
    /// the same implementation, and this is what keeps that true.
    func testTheLooseOverloadAgreesWithTheLibraryItemOverload() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 450, duration: 7200)

        for (currentId, isPlaying) in [("b1", true), ("b1", false), ("other", true)] as [(String, Bool)] {
            let viaItem = CarPlayCoordinator.bookPlaybackState(
                book: book, currentItemId: currentId, isPlaying: isPlaying,
                playerTime: 1000, playerDuration: 7200)
            let viaLoose = CarPlayCoordinator.bookPlaybackState(
                serverElapsed: book.currentTime, serverDuration: book.duration,
                isCurrent: currentId == book.id, isPlaying: isPlaying,
                playerTime: currentId == book.id ? 1000 : nil,
                playerDuration: currentId == book.id ? 7200 : nil)
            XCTAssertEqual(viaItem, viaLoose, "currentId \(currentId), isPlaying \(isPlaying)")
        }
    }

    // MARK: - Clamping (the part that protects CMTime)

    /// A finished-but-not-marked-finished book, or a server record written against a
    /// longer edition of the same audio, can report a position past the end. CarPlay
    /// gets `duration`, not a fraction, so an elapsed beyond it is a real
    /// "indicator past the end of its own track" case.
    func testElapsedPastTheDurationIsClampedToTheDuration() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 9999, duration: 3600)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: nil, isPlaying: false,
            playerTime: nil, playerDuration: nil)

        XCTAssertEqual(state.elapsed, 3600)
        XCTAssertEqual(state.duration, 3600)
    }

    func testNegativeElapsedIsClampedToZero() {
        let state = CarPlayCoordinator.bookPlaybackState(
            serverElapsed: -500, serverDuration: 3600,
            isCurrent: false, isPlaying: false,
            playerTime: nil, playerDuration: nil)

        XCTAssertEqual(state.elapsed, 0)
        XCTAssertEqual(state.duration, 3600)
    }

    /// A non-finite duration is the one that would actually trap or draw nonsense.
    /// `Media.duration` is a decoded `Double?` straight off the server, so NaN and
    /// infinity are both reachable from a malformed payload, and the model layer
    /// deliberately does not reject them for a book (only for a chapter's `start`/`end`
    /// — see `Chapter.init(from:)`).
    func testNonFiniteDurationBecomesUnknownWithNoElapsed() {
        for duration in [Double.nan, .infinity, -.infinity, -60] {
            let state = CarPlayCoordinator.bookPlaybackState(
                serverElapsed: 500, serverDuration: duration,
                isCurrent: false, isPlaying: false,
                playerTime: nil, playerDuration: nil)

            XCTAssertEqual(state.duration, 0, "duration \(duration) must collapse to the documented unknown 0.")
            XCTAssertEqual(state.elapsed, 0, "with no duration there is nothing for elapsed to be a position within.")
        }
    }

    /// Same for a non-finite elapsed against a perfectly good duration: the row keeps
    /// its duration (so the indicator has a track) and starts at 0.
    func testNonFiniteElapsedBecomesZeroWithoutLosingTheDuration() {
        for elapsed in [Double.nan, .infinity, -.infinity] {
            let state = CarPlayCoordinator.bookPlaybackState(
                serverElapsed: elapsed, serverDuration: 3600,
                isCurrent: false, isPlaying: false,
                playerTime: nil, playerDuration: nil)

            XCTAssertEqual(state.elapsed, 0, "elapsed \(elapsed) must not reach CMTime.")
            XCTAssertEqual(state.duration, 3600)
        }
    }

    /// An ebook-only or not-yet-scanned item has `media.duration == nil`, so
    /// `LibraryItem.duration` is 0 — the "unknown" value `CPPlaybackConfiguration`
    /// documents. Elapsed must go with it, not sit at some absolute position inside a
    /// zero-length track.
    func testZeroDurationLeavesNoElapsed() {
        let book = ShelfHead.LibraryItem.testFixture(id: "b1", currentTime: 120, duration: 0)

        let state = CarPlayCoordinator.bookPlaybackState(
            book: book, currentItemId: "b1", isPlaying: true,
            playerTime: 120, playerDuration: 0)

        XCTAssertEqual(state.duration, 0)
        XCTAssertEqual(state.elapsed, 0)
        XCTAssertEqual(state.action, .pause, "an unknown duration says nothing about whether audio is playing.")
    }

    // MARK: - Chapter rows

    /// The chapter the position is inside: progress is measured from the chapter's own
    /// start, not from the start of the book, so the indicator matches the phone's
    /// chapter-relative scrubber rather than showing a nearly-full bar on every chapter
    /// late in a long book.
    func testChapterInsideTheCurrentPositionIsMeasuredFromItsOwnStart() {
        let chapter = Chapter.testFixture(id: 3, start: 1000, end: 1600, title: "Three")

        let state = CarPlayCoordinator.chapterPlaybackState(chapter: chapter, now: 1200, isPlaying: true)

        XCTAssertEqual(state.elapsed, 200)
        XCTAssertEqual(state.duration, 600)
        XCTAssertEqual(state.action, .pause)
    }

    /// Inside, but paused — a play glyph, because tapping the row seeks there and the
    /// audio is not moving.
    func testChapterInsideButPausedShowsPlay() {
        let chapter = Chapter.testFixture(id: 3, start: 1000, end: 1600, title: "Three")

        let state = CarPlayCoordinator.chapterPlaybackState(chapter: chapter, now: 1200, isPlaying: false)

        XCTAssertEqual(state.action, .play)
        XCTAssertEqual(state.elapsed, 200, "the position is still inside this chapter even while paused.")
    }

    /// Chapters ahead of the position are empty; chapters behind it are complete. Both
    /// fall out of the same clamp, and both must be `.play` even mid-playback — the
    /// pause glyph belongs to exactly one row in the list.
    func testChaptersOutsideThePositionReadEmptyOrCompleteAndNeverShowPause() {
        let chapter = Chapter.testFixture(id: 3, start: 1000, end: 1600, title: "Three")

        let ahead = CarPlayCoordinator.chapterPlaybackState(chapter: chapter, now: 200, isPlaying: true)
        XCTAssertEqual(ahead.elapsed, 0, "a chapter the position hasn't reached has no progress.")
        XCTAssertEqual(ahead.duration, 600)
        XCTAssertEqual(ahead.action, .play)

        let behind = CarPlayCoordinator.chapterPlaybackState(chapter: chapter, now: 5000, isPlaying: true)
        XCTAssertEqual(behind.elapsed, 600, "a chapter already passed reads as complete, not as 3400s long.")
        XCTAssertEqual(behind.duration, 600)
        XCTAssertEqual(behind.action, .play)
    }

    /// The boundary the rest of the app uses is half-open (`start ..< end`), so the
    /// instant a chapter ends belongs to the NEXT chapter — the same rule
    /// `renderChapterWindow`'s `isPlaying` and `PlayerViewModel.chapterIndex(in:at:)`
    /// apply. Exactly one row may show a pause glyph at any position.
    func testTheChapterBoundaryIsHalfOpenSoOnlyOneRowCanShowPause() {
        let first = Chapter.testFixture(id: 0, start: 0, end: 600, title: "One")
        let second = Chapter.testFixture(id: 1, start: 600, end: 1200, title: "Two")

        XCTAssertEqual(CarPlayCoordinator.chapterPlaybackState(chapter: first, now: 600, isPlaying: true).action, .play,
                       "at exactly `end`, the position has left this chapter.")
        XCTAssertEqual(CarPlayCoordinator.chapterPlaybackState(chapter: second, now: 600, isPlaying: true).action, .pause,
                       "at exactly `start`, the position is inside this one.")
    }

    /// `Chapter.init(from:)` deliberately KEEPS an inverted or zero-length chapter
    /// rather than dropping it (dropping would make an older build's offline manifest
    /// undecodable — see its doc comment), so this shape reaches CarPlay and has to
    /// degrade to "no progress indicator" instead of a negative `CMTime`.
    func testInvertedOrZeroLengthChapterHasNoDuration() {
        let inverted = Chapter.testFixture(id: 1, start: 900, end: 300, title: "Backwards")
        let invertedState = CarPlayCoordinator.chapterPlaybackState(chapter: inverted, now: 500, isPlaying: true)
        XCTAssertEqual(invertedState.duration, 0)
        XCTAssertEqual(invertedState.elapsed, 0)
        XCTAssertEqual(invertedState.action, .play, "nothing can satisfy `now >= start && now < end` here.")

        let empty = Chapter.testFixture(id: 2, start: 900, end: 900, title: "Zero")
        let emptyState = CarPlayCoordinator.chapterPlaybackState(chapter: empty, now: 900, isPlaying: true)
        XCTAssertEqual(emptyState.duration, 0)
        XCTAssertEqual(emptyState.elapsed, 0)
        XCTAssertEqual(emptyState.action, .play)
    }

    /// A negative `start` is another shape `Chapter` keeps on purpose, and
    /// `AudioPlayerService.currentTime` can be NaN before an asset is ready — the
    /// coordinator passes both straight through from live state.
    func testChapterToleratesANegativeStartAndANonFiniteNow() {
        let negative = Chapter.testFixture(id: 0, start: -30, end: 570, title: "Negative")
        let state = CarPlayCoordinator.chapterState(start: negative.start, end: negative.end,
                                                    now: 0, isPlaying: true)
        XCTAssertEqual(state.duration, 600)
        XCTAssertEqual(state.elapsed, 30, "0s into a chapter that starts at -30 is 30s in.")
        XCTAssertEqual(state.action, .pause)

        let nonFinite = CarPlayCoordinator.chapterState(start: 0, end: 600,
                                                        now: .nan, isPlaying: true)
        XCTAssertEqual(nonFinite.elapsed, 0)
        XCTAssertEqual(nonFinite.duration, 600)
        XCTAssertEqual(nonFinite.action, .play, "a NaN position is inside no chapter.")
    }

    /// The `WeakChapterRow` re-apply path calls the `start:end:` overload directly, so
    /// it has to be the same implementation the `Chapter` one forwards to.
    func testTheChapterOverloadsAgree() {
        let chapter = Chapter.testFixture(id: 3, start: 1000, end: 1600, title: "Three")
        for now in [0.0, 999, 1000, 1200, 1599, 1600, 5000] {
            for isPlaying in [true, false] {
                XCTAssertEqual(
                    CarPlayCoordinator.chapterPlaybackState(chapter: chapter, now: now, isPlaying: isPlaying),
                    CarPlayCoordinator.chapterState(start: chapter.start, end: chapter.end,
                                                    now: now, isPlaying: isPlaying),
                    "now \(now), isPlaying \(isPlaying)")
            }
        }
    }
}

// MARK: - Fixtures

private extension Chapter {
    /// `Chapter` has a throwing `init(from decoder:)` and therefore no memberwise
    /// initializer — round-trips through JSON, the same approach
    /// `CarPlayListWindowingTests` and `TrackTimelineTests` already take.
    static func testFixture(id: Int, start: Double, end: Double, title: String) -> Chapter {
        let json: [String: Any] = ["id": id, "start": start, "end": end, "title": title]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Chapter.self, from: data)
    }
}

// Module-qualified, matching `CarPlayListWindowingTests`: unqualified `LibraryItem` was
// reported ambiguous for type lookup by the iOS 26 toolchain, and the app type is meant.
private extension ShelfHead.LibraryItem {
    /// `LibraryItem`'s custom `init(from decoder:)` lives in an extension precisely so
    /// the ordinary memberwise initializer is still synthesized — used here (and by
    /// `DownloadedBook.asLibraryItem()` in the app) rather than round-tripping JSON.
    ///
    /// `currentTime` and `duration` are the two fields these tests are about:
    /// `LibraryItem.duration` reads `media.duration` and `LibraryItem.currentTime` reads
    /// `mediaProgress.currentTime`, so they have to be set a level down.
    static func testFixture(id: String, currentTime: Double, duration: Double) -> ShelfHead.LibraryItem {
        let metadata = MediaMetadata(
            title: id, subtitle: nil, authorName: nil, narratorName: nil,
            seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
            language: nil, genres: nil, isbn: nil, asin: nil, series: nil
        )
        let media = Media(
            metadata: metadata, coverPath: nil, duration: duration, chapters: nil, audioFiles: nil,
            numChapters: nil, numAudioFiles: nil, episodes: nil, ebookFile: nil
        )
        let progress = MediaProgress(
            id: id, libraryItemId: id, episodeId: nil, duration: duration,
            progress: duration > 0 ? currentTime / duration : 0,
            currentTime: currentTime, isFinished: false, lastUpdate: nil,
            startedAt: nil, finishedAt: nil
        )
        return LibraryItem(
            id: id, ino: nil, libraryId: nil, mediaType: "book", media: media,
            numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: progress
        )
    }
}
