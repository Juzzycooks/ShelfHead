// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section.
//
// Critique 2026-10-06 (third pass, shape → harden, then colorize): pins the pure decisions
// behind the Watch's play target ("Play on Watch" first for a downloaded book, in both
// modes, holding the Watch's own mode while it's loaded), the eviction order (finished,
// then unstarted, never a book part-way through), the before-download room check, and the
// contrast-safe accent text.
import XCTest
@testable import ShelfHead_Watch

// MARK: - Play target

@MainActor
final class WatchBookPlayOptionsTests: XCTestCase {

    func testDownloadedBookPlaysOnWatchFirstInCompanionMode() {
        let options = WatchBookPlayOptions.decide(isDownloaded: true, isStandaloneMode: false, phoneIsReachable: true)
        XCTAssertEqual(options.primary, .watch)
        XCTAssertEqual(options.secondary, .iPhone)
    }

    func testDownloadedBookPlaysOnWatchFirstInStandaloneMode() {
        let options = WatchBookPlayOptions.decide(isDownloaded: true, isStandaloneMode: true, phoneIsReachable: false)
        XCTAssertEqual(options.primary, .watch)
        XCTAssertNil(options.secondary, "no iPhone to hand the book to")
    }

    func testNotDownloadedInCompanionModePlaysOnIPhone() {
        let options = WatchBookPlayOptions.decide(isDownloaded: false, isStandaloneMode: false, phoneIsReachable: true)
        XCTAssertEqual(options.primary, .iPhone)
        XCTAssertNil(options.secondary)
    }

    func testNotDownloadedInStandaloneStreamsOnWatchAndOffersAReachableIPhone() {
        XCTAssertEqual(WatchBookPlayOptions.decide(isDownloaded: false, isStandaloneMode: true, phoneIsReachable: true),
                       WatchBookPlayOptions(primary: .watch, secondary: .iPhone))
        XCTAssertEqual(WatchBookPlayOptions.decide(isDownloaded: false, isStandaloneMode: true, phoneIsReachable: false),
                       WatchBookPlayOptions(primary: .watch, secondary: nil))
    }
}

@MainActor
final class WatchPlayOnWatchPhoneActionTests: XCTestCase {

    private func decide(reachable: Bool = true, playing: Bool = true, phoneItem: String? = "phone-book",
                        stale: Bool = false, requested: String = "watch-book") -> WatchPlayOnWatchPhoneAction {
        WatchPlayOnWatchPhoneAction.decide(requestedItemId: requested, phoneIsReachable: reachable,
                                           phoneIsPlaying: playing, phoneItemId: phoneItem,
                                           phoneTitle: "Phone Book", phoneStateIsStale: stale)
    }

    func testDifferentBookPlayingOnIPhoneAsksFirst() {
        XCTAssertEqual(decide(), .confirmPausingPhone(currentTitle: "Phone Book"))
    }

    func testSameBookPlayingOnIPhoneIsAHandOff() {
        XCTAssertEqual(decide(requested: "phone-book"), .pausePhone)
    }

    func testNothingToDoWhenThePhoneIsAwayPausedOrStale() {
        XCTAssertEqual(decide(reachable: false), .nothing)
        XCTAssertEqual(decide(playing: false), .nothing)
        XCTAssertEqual(decide(stale: true), .nothing, "don't act on a snapshot too old to trust")
    }
}

@MainActor
final class WatchModeHoldTests: XCTestCase {

    func testALoadedWatchBookHoldsStandaloneWhateverThePreference() {
        for preference in WatchStore.ModePreference.allCases {
            for reachable in [true, false] {
                XCTAssertEqual(
                    WatchStore.nextMode(current: .companion, preference: preference, phoneIsReachable: reachable,
                                        hasUsableSession: true, standaloneIsLoaded: true, standaloneIsPlaying: false),
                    .standalone, "\(preference), reachable \(reachable)")
            }
        }
    }

    func testStoppingTheBookReturnsToAutomatic() {
        XCTAssertEqual(
            WatchStore.nextMode(current: .standalone, preference: .automatic, phoneIsReachable: true,
                                hasUsableSession: true, standaloneIsLoaded: false, standaloneIsPlaying: false),
            .companion)
        XCTAssertEqual(
            WatchStore.nextMode(current: .standalone, preference: .automatic, phoneIsReachable: false,
                                hasUsableSession: true, standaloneIsLoaded: false, standaloneIsPlaying: false),
            .standalone)
    }

    func testPreferenceTitlesAreFreeOfJargon() {
        for preference in WatchStore.ModePreference.allCases {
            for copy in [preference.title, preference.subtitle] {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains("companion"), copy)
                XCTAssertFalse(copy.localizedCaseInsensitiveContains("standalone"), copy)
            }
        }
        XCTAssertEqual(WatchStore.ModePreference.alwaysStandalone.title, "This Watch")
        XCTAssertEqual(WatchStore.ModePreference.alwaysCompanion.title, "iPhone")
    }
}

// MARK: - Eviction

@MainActor
final class WatchDownloadListeningTests: XCTestCase {

    func testClassifiesByPosition() {
        XCTAssertEqual(WatchDownloadListening.classify(position: nil, duration: 3600), .unstarted)
        XCTAssertEqual(WatchDownloadListening.classify(position: 0, duration: 3600), .unstarted)
        XCTAssertEqual(WatchDownloadListening.classify(position: 5, duration: 3600), .inProgress)
        XCTAssertEqual(WatchDownloadListening.classify(position: 3590, duration: 3600), .finished)
        XCTAssertEqual(WatchDownloadListening.classify(position: 3600, duration: 3600), .finished,
                       "at the very end is finished, not the 0 a resume would restart from")
    }

    func testNewerServerFinishBeatsAnOlderWatchPosition() {
        let server = WatchServerProgress(currentTime: 3600, lastUpdateMs: 2_000)
        XCTAssertEqual(WatchDownloadListening.classify(server: server, localTime: 1200, localUpdatedAtMs: 1_000, duration: 3600),
                       .finished)
    }

    func testNewerWatchPositionBeatsAnOlderServerStart() {
        let server = WatchServerProgress(currentTime: 0, lastUpdateMs: 1_000)
        XCTAssertEqual(WatchDownloadListening.classify(server: server, localTime: 1200, localUpdatedAtMs: 2_000, duration: 3600),
                       .inProgress)
    }

    func testNothingKnownIsUnstarted() {
        XCTAssertEqual(WatchDownloadListening.classify(server: nil, localTime: nil, localUpdatedAtMs: nil, duration: 3600),
                       .unstarted)
    }
}

@MainActor
final class WatchEvictionOrderTests: XCTestCase {

    private func download(_ id: String, bytes: Int64 = 100, ageDays: Double) -> WatchLocalDownload {
        WatchLocalDownload(id: id, title: "Title \(id)", author: "Author", duration: 3600, tracks: [], totalBytes: bytes,
                           downloadedAt: Date(timeIntervalSince1970: 1_700_000_000 - ageDays * 86_400))
    }

    func testFinishedGoesBeforeUnstartedEvenWhenNewer() {
        let items = [download("old-unstarted", ageDays: 30), download("new-finished", ageDays: 1)]
        let victims = WatchLocalDownloadManager.evictionVictims(
            downloads: items, totalBytesUsed: 200, capBytes: 150, protectedItemIds: [],
            listening: ["old-unstarted": .unstarted, "new-finished": .finished])
        XCTAssertEqual(victims, ["new-finished"])
    }

    func testOldestFinishedFirst() {
        let items = [download("f-new", ageDays: 1), download("f-old", ageDays: 10), download("u", ageDays: 20)]
        let victims = WatchLocalDownloadManager.evictionVictims(
            downloads: items, totalBytesUsed: 300, capBytes: 100, protectedItemIds: [],
            listening: ["f-new": .finished, "f-old": .finished, "u": .unstarted])
        XCTAssertEqual(victims, ["f-old", "f-new"])
    }

    func testNeverAnInProgressBookEvenIfTheCapStaysExceeded() {
        // The regression: sorting by `downloadedAt` alone took today's half-finished book.
        let items = [download("half-finished", ageDays: 30), download("unstarted", ageDays: 1)]
        let victims = WatchLocalDownloadManager.evictionVictims(
            downloads: items, totalBytesUsed: 200, capBytes: 50, protectedItemIds: [],
            listening: ["half-finished": .inProgress, "unstarted": .unstarted])
        XCTAssertEqual(victims, ["unstarted"])
    }

    func testAnUnclassifiedBookIsKept() {
        let items = [download("unknown", ageDays: 30)]
        XCTAssertEqual(WatchLocalDownloadManager.evictionVictims(
            downloads: items, totalBytesUsed: 100, capBytes: 10, protectedItemIds: [], listening: [:]), [])
    }
}

@MainActor
final class WatchDownloadRoomPlanTests: XCTestCase {

    private func download(_ id: String, bytes: Int64, ageDays: Double) -> WatchLocalDownload {
        WatchLocalDownload(id: id, title: id, author: "Author", duration: 3600, tracks: [], totalBytes: bytes,
                           downloadedAt: Date(timeIntervalSince1970: 1_700_000_000 - ageDays * 86_400))
    }

    func testFitsWithRoomToSpare() {
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 100, downloads: [download("a", bytes: 100, ageDays: 1)],
                                                  capBytes: 500, protectedItemIds: [], listening: ["a": .inProgress]),
                       .fits)
    }

    func testFitsAfterRemovingFinishedBooks() {
        let items = [download("done", bytes: 200, ageDays: 5), download("reading", bytes: 200, ageDays: 1)]
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 200, downloads: items, capBytes: 450, protectedItemIds: [],
                                                  listening: ["done": .finished, "reading": .inProgress]),
                       .fitsAfterRemoving(["done"]))
    }

    func testNoRoomWhenOnlyAPartPlayedBookCouldMakeIt() {
        let items = [download("reading", bytes: 400, ageDays: 1)]
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 200, downloads: items, capBytes: 450, protectedItemIds: [],
                                                  listening: ["reading": .inProgress]),
                       .noRoom)
    }

    func testTheLoadedBookIsNeverPartOfThePlan() {
        let items = [download("playing", bytes: 400, ageDays: 9)]
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 200, downloads: items, capBytes: 450, protectedItemIds: ["playing"],
                                                  listening: ["playing": .finished]),
                       .noRoom)
    }

    func testCap() {
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: nil), WatchDownloadCap.fixedCeilingBytes)
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: 400), 200)
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: 400, pendingBytes: 100), 150,
                       "measured against the free space left after the download")
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: 10 * 1024 * 1024 * 1024), WatchDownloadCap.fixedCeilingBytes)
    }

    func testCopy() {
        XCTAssertEqual(WatchDownloadRoomCopy.noRoom(title: "Dune"),
                       "Not enough room on this Watch. Remove a book to download \u{201C}Dune\u{201D}.")
        XCTAssertEqual(WatchDownloadRoomCopy.removed(titles: ["Dune"]), "Removed \u{201C}Dune\u{201D} to make room.")
        XCTAssertEqual(WatchDownloadRoomCopy.willRemove(titles: ["A", "B", "C"]),
                       "Removes 3 finished or unstarted books to make room.")
        XCTAssertEqual(WatchDownloadRoomCopy.removed(titles: []), "")
    }
}

// MARK: - Library

@MainActor
final class WatchLibraryThirdCritiqueTests: XCTestCase {

    func testInProgressFilter() {
        XCTAssertTrue(WatchLibraryInProgressFilter.keeps(itemLibraryId: "lib", isPodcast: false, isFinished: false, selectedLibraryId: "lib"))
        XCTAssertFalse(WatchLibraryInProgressFilter.keeps(itemLibraryId: "other", isPodcast: false, isFinished: false, selectedLibraryId: "lib"))
        XCTAssertFalse(WatchLibraryInProgressFilter.keeps(itemLibraryId: "lib", isPodcast: true, isFinished: false, selectedLibraryId: "lib"))
        XCTAssertFalse(WatchLibraryInProgressFilter.keeps(itemLibraryId: "lib", isPodcast: false, isFinished: true, selectedLibraryId: "lib"))
        XCTAssertTrue(WatchLibraryInProgressFilter.keeps(itemLibraryId: nil, isPodcast: false, isFinished: false, selectedLibraryId: "lib"))
    }

    func testLibraryItemDecodesItsSize() throws {
        let json = #"{"id":"li_1","libraryId":"lib","mediaType":"book","size":123456789}"#
        let item = try JSONDecoder().decode(WatchLibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.sizeBytes, 123_456_789)
        let noSize = try JSONDecoder().decode(WatchLibraryItem.self, from: Data(#"{"id":"li_2"}"#.utf8))
        XCTAssertNil(noSize.sizeBytes)
    }
}

// MARK: - Palette

@MainActor
final class WatchAccentTextTests: XCTestCase {

    /// The phone's nine accents (`AppTheme.accentOptions`).
    private let phoneAccents = ["E8A838", "E0612F", "2FB6A8", "3B82F6", "6366F1", "8B5CF6", "EC4899", "EF4444", "22C55E"]
    /// The Watch's dark grounds: the top of the Now Playing wash, the card, black.
    private let grounds = ["2E2114", "241B12", "000000"]

    func testEveryPhoneAccentClearsAAAsTextOnEveryDarkGround() throws {
        for accent in phoneAccents {
            let text = WatchPaletteMath.readableText(accentHex: accent, onHex: WatchPaletteMath.lightestGroundHex)
            for ground in grounds {
                let ratio = WatchPaletteMath.contrastRatio(text, try XCTUnwrap(WatchPaletteMath.rgb(hex: ground)))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "accent \(accent) on \(ground): \(ratio)")
            }
        }
    }

    func testAnAccentThatAlreadyReadsIsUnchanged() throws {
        let amber = try XCTUnwrap(WatchPaletteMath.rgb(hex: "E8A838"))
        XCTAssertEqual(WatchPaletteMath.readableText(accentHex: "E8A838", onHex: WatchPaletteMath.lightestGroundHex), amber)
    }

    func testIndigoIsLiftedButKeepsItsHue() throws {
        let indigo = try XCTUnwrap(WatchPaletteMath.rgb(hex: "6366F1"))
        let lifted = WatchPaletteMath.readableText(accentHex: "6366F1", onHex: WatchPaletteMath.lightestGroundHex)
        XCTAssertNotEqual(lifted, indigo)
        XCTAssertEqual(WatchPaletteMath.hsb(lifted).h, WatchPaletteMath.hsb(indigo).h, accuracy: 0.01)
    }
}
