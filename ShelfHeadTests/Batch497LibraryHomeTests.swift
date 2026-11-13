import XCTest
@testable import ShelfHead

/// Batch 497: reading progress shows only on ebook-only books (L12), Home's Listen Again and
/// narrator See all (N4), and the profile picker's gate for the account already signed in (N5).
@MainActor
final class Batch497LibraryHomeTests: XCTestCase {

    // MARK: - L12: which progress a tile shows

    func testShownProgressRules() {
        typealias L = ShelfHead.LibraryItem
        // Ebook-only: the reading fraction, clamped.
        XCTAssertEqual(L.shownProgress(isEbookOnly: true, listening: 0, reading: 0.6), 0.6)
        XCTAssertEqual(L.shownProgress(isEbookOnly: true, listening: nil, reading: 1.4), 1)
        // Ebook-only with nothing read: whatever listening says (0 for a book with no audio).
        XCTAssertEqual(L.shownProgress(isEbookOnly: true, listening: 0, reading: nil), 0)
        XCTAssertEqual(L.shownProgress(isEbookOnly: true, listening: nil, reading: .nan), 0)
        // Anything with audio: listening only, never the companion ebook's reading.
        XCTAssertEqual(L.shownProgress(isEbookOnly: false, listening: 0, reading: 0.6), 0)
        XCTAssertEqual(L.shownProgress(isEbookOnly: false, listening: nil, reading: 0.6), 0)
        XCTAssertEqual(L.shownProgress(isEbookOnly: false, listening: 0.25, reading: 0.6), 0.25)
    }

    private func item(_ id: String, media: [String: Any], progress: [String: Any]? = nil) -> ShelfHead.LibraryItem {
        var json: [String: Any] = ["id": id, "mediaType": "book", "media": media]
        if let progress { json["userMediaProgress"] = progress }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ShelfHead.LibraryItem.self, from: data)
    }

    private let readOnlyRecord: [String: Any] = [
        "libraryItemId": "x", "duration": 0, "progress": 0, "currentTime": 0, "isFinished": false, "ebookProgress": 0.6
    ]

    func testListPayloadEbookOnlyBookShowsReading() {
        // Minified list shape: `ebookFormat`, no `ebookFile` (Audiobookshelf `Book.toOldJSONMinified`).
        let book = item("e", media: ["numAudioFiles": 0, "ebookFormat": "epub"], progress: readOnlyRecord)
        XCTAssertTrue(book.hasEbookAndNoAudio)
        XCTAssertTrue(book.isEbookOnly, "one rule for every payload shape")
        XCTAssertEqual(book.progressPercent, 0)
        XCTAssertEqual(book.shownProgress(nil), 0.6)
    }

    func testEbookOnlyRuleAcrossPayloadShapes() {
        typealias L = ShelfHead.LibraryItem
        // Expanded: ebookFile and a count of 0.
        XCTAssertTrue(L.isEbookOnly(hasEbookFile: true, ebookFormat: "epub", numAudioFiles: 0, audioFileCount: 0))
        // Minified list: ebookFormat only.
        XCTAssertTrue(L.isEbookOnly(hasEbookFile: false, ebookFormat: "pdf", numAudioFiles: 0, audioFileCount: nil))
        // An audiobook with a companion ebook is not ebook-only, in either shape.
        XCTAssertFalse(L.isEbookOnly(hasEbookFile: true, ebookFormat: "epub", numAudioFiles: 12, audioFileCount: 12))
        XCTAssertFalse(L.isEbookOnly(hasEbookFile: false, ebookFormat: "epub", numAudioFiles: 12, audioFileCount: nil))
        // The plain payload has no numAudioFiles: the audioFiles array decides.
        XCTAssertFalse(L.isEbookOnly(hasEbookFile: true, ebookFormat: nil, numAudioFiles: nil, audioFileCount: 3))
        XCTAssertTrue(L.isEbookOnly(hasEbookFile: true, ebookFormat: nil, numAudioFiles: nil, audioFileCount: 0))
        // No ebook at all, or an empty format string.
        XCTAssertFalse(L.isEbookOnly(hasEbookFile: false, ebookFormat: nil, numAudioFiles: 0, audioFileCount: nil))
        XCTAssertFalse(L.isEbookOnly(hasEbookFile: false, ebookFormat: "", numAudioFiles: 0, audioFileCount: nil))
    }

    func testAudiobookWithReadCompanionEbookShowsNoProgress() {
        let book = item("a", media: ["numAudioFiles": 12, "ebookFormat": "epub"], progress: readOnlyRecord)
        XCTAssertFalse(book.hasEbookAndNoAudio)
        XCTAssertEqual(book.shownProgress(nil), 0, "reading never shows as listening")
        XCTAssertEqual(book.shownProgress(book.mediaProgress), 0)
        XCTAssertEqual(book.progressPercent, 0, "quick play follows this, so it says Play, not Resume")
    }

    func testProgressMapRecordWinsOverTheItemsOwn() {
        let book = item("e", media: ["numAudioFiles": 0, "ebookFormat": "pdf"], progress: readOnlyRecord)
        let fresher = MediaProgress(id: "e", libraryItemId: "e", episodeId: nil, duration: 0, progress: 0,
                                    currentTime: 0, isFinished: false, lastUpdate: nil, startedAt: nil,
                                    finishedAt: nil, ebookProgress: 0.8)
        XCTAssertEqual(book.shownProgress(fresher), 0.8)
    }

    func testPlainAudiobookIsUnchanged() {
        let book = item("p", media: ["numAudioFiles": 3],
                        progress: ["libraryItemId": "p", "duration": 3600, "progress": 0.4, "currentTime": 1440])
        XCTAssertFalse(book.hasEbookAndNoAudio)
        XCTAssertEqual(book.shownProgress(nil), 0.4)
    }

    func testEbookFormatSurvivesTheQueueFileRoundTrip() throws {
        let book = item("e", media: ["numAudioFiles": 0, "ebookFormat": "epub"])
        let again = try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(again.media?.ebookFormat, "epub")
        XCTAssertTrue(again.hasEbookAndNoAudio)
    }

    func testNearlyFinishedUsesWhatTheTileShows() {
        let ebook = item("e", media: ["numAudioFiles": 0, "ebookFormat": "epub"])
        let companion = item("c", media: ["numAudioFiles": 4, "ebookFormat": "epub"])
        let listened = item("l", media: ["numAudioFiles": 4])
        func read(_ id: String, _ fraction: Double) -> MediaProgress {
            MediaProgress(id: id, libraryItemId: id, episodeId: nil, duration: 0, progress: 0, currentTime: 0,
                          isFinished: false, lastUpdate: nil, startedAt: nil, finishedAt: nil, ebookProgress: fraction)
        }
        let progress: [String: MediaProgress] = [
            "e": read("e", 0.95),
            "c": read("c", 0.95),
            "l": MediaProgress(id: "l", libraryItemId: "l", episodeId: nil, duration: 3600, progress: 0.92,
                               currentTime: 3312, isFinished: false, lastUpdate: nil, startedAt: nil, finishedAt: nil)
        ]
        let ids = LibraryViewModel.applySmartFilter(
            .nearlyFinished, to: [ebook, companion, listened], now: Date(),
            progress: { progress[$0.id] }, isDownloaded: { _ in false }, isFavorite: { _ in false }
        ).map(\.id)
        XCTAssertEqual(ids, ["e", "l"], "a read companion ebook doesn't make an audiobook nearly finished")
    }

    // MARK: - N4: See all for Listen Again and the narrator shelf

    func testListenAgainAndNarratorShelvesHaveSeeAll() {
        XCTAssertEqual(HomeState.seeAllDestination(forSectionKey: "LabelListenAgain"), .listenAgain)
        XCTAssertEqual(HomeState.seeAllDestination(forSectionKey: HomeView.narratorShelfKey), .narrators)
        XCTAssertNil(HomeState.seeAllDestination(forSectionKey: "LabelDiscover"), "random by design")
    }

    func testPagedQueries() {
        XCTAssertEqual(HomeState.pagedQuery(for: .recentlyAdded),
                       HomeState.PagedShelfQuery(sort: "addedAt", desc: true, filter: nil))
        let listenAgain = HomeState.pagedQuery(for: .listenAgain)
        XCTAssertEqual(listenAgain?.sort, "progress.finishedAt")
        XCTAssertEqual(listenAgain?.desc, true)
        // `progress.` + base64("finished"), the server's own Listen Again filter.
        XCTAssertEqual(listenAgain?.filter, "progress.ZmluaXNoZWQ=")
        for other: HomeState.SeeAllDestination in [.series, .downloads, .alsoInProgress, .narrators] {
            XCTAssertNil(HomeState.pagedQuery(for: other))
        }
    }

    func testNewSeeAllLabelsNameTheShelf() {
        let all: [HomeState.SeeAllDestination] = [.recentlyAdded, .series, .downloads, .alsoInProgress, .listenAgain, .narrators]
        let labels = all.map(HomeState.seeAllAccessibilityLabel)
        XCTAssertEqual(Set(labels).count, all.count)
        XCTAssertEqual(HomeState.seeAllAccessibilityLabel(.listenAgain), "See all finished books")
        XCTAssertEqual(HomeState.seeAllAccessibilityLabel(.narrators), "See all narrators")
    }

    // MARK: - N5: the picker's gate per tap

    private func gate(current: String?, tapped: String, kid: Bool, anyKid: Bool = true, home: Bool) -> Bool {
        ParentGate.pickerTapNeedsGate(currentAccountId: current, tappedAccountId: tapped,
                                      tappedIsKid: kid, anyKidSaved: anyKid, openedInSession: home)
    }

    func testHomePickerTappingTheActiveGrownUpJustCloses() {
        XCTAssertFalse(gate(current: "parent", tapped: "parent", kid: false, home: true))
    }

    func testChildTappingTheirOwnTileJustCloses() {
        XCTAssertFalse(gate(current: "kid", tapped: "kid", kid: true, home: true))
        XCTAssertFalse(gate(current: "kid", tapped: "kid", kid: true, home: false))
    }

    func testEveryRealSwitchToAGrownUpKeepsTheGate() {
        XCTAssertTrue(gate(current: "kid", tapped: "parent", kid: false, home: true))
        XCTAssertTrue(gate(current: "parent", tapped: "parent2", kid: false, home: true))
        XCTAssertTrue(gate(current: nil, tapped: "parent", kid: false, home: true), "signed out: a real switch")
    }

    func testLaunchPickerStillGatesTheRestoredGrownUp() {
        // Review 2 High 1: at launch nobody has chosen the restored session yet.
        XCTAssertTrue(gate(current: "parent", tapped: "parent", kid: false, home: false))
    }

    func testNoChildSavedNeverGates() {
        XCTAssertFalse(gate(current: "a", tapped: "b", kid: false, anyKid: false, home: true))
        XCTAssertFalse(gate(current: "a", tapped: "b", kid: false, anyKid: false, home: false))
    }

    func testSwitchToAnotherChildIsNotGated() {
        XCTAssertFalse(gate(current: "parent", tapped: "kid2", kid: true, home: true))
    }
}
