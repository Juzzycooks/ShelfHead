import XCTest
@testable import ShelfHead

/// Up Next entries that can carry a podcast episode: persistence (old `[LibraryItem]` files
/// still load), dedupe by entry id, and the finished-entry skip decision.
final class UpNextEpisodeTests: XCTestCase {
    private func decodeItem(_ json: String) throws -> ShelfHead.LibraryItem {
        try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }

    private func show(_ id: String = "show") throws -> ShelfHead.LibraryItem {
        try decodeItem(#"{"id":"\#(id)","mediaType":"podcast"}"#)
    }

    private func episode(_ id: String, title: String? = nil) throws -> PodcastEpisode {
        let t = title.map { #","title":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(PodcastEpisode.self, from: Data(#"{"id":"\#(id)"\#(t)}"#.utf8))
    }

    // MARK: Persistence

    func testLegacyLibraryItemArrayLoadsAsBookEntries() throws {
        let data = Data(#"[{"id":"a"},{"id":"b"}]"#.utf8)
        let entries = try XCTUnwrap(PlayerViewModel.decodeQueue(data))
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
        XCTAssertTrue(entries.allSatisfy { $0.episode == nil })
    }

    func testEntriesRoundTripIncludingEpisodes() throws {
        let queue = [UpNextEntry(item: try decodeItem(#"{"id":"a"}"#)),
                     UpNextEntry(item: try show(), episode: try episode("e1", title: "One")),
                     UpNextEntry(item: try show(), episode: try episode("e2"))]
        let data = try JSONEncoder().encode(queue)
        let back = try XCTUnwrap(PlayerViewModel.decodeQueue(data))
        XCTAssertEqual(back.map(\.id), ["a", "show#e1", "show#e2"])
        XCTAssertEqual(back[1].episode?.title, "One")
        XCTAssertNil(back[0].episode)
    }

    func testMixedOldAndNewElementsAndABadOneStillLoad() throws {
        let entry = UpNextEntry(item: try show(), episode: try episode("e1"))
        let new = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        let data = Data(#"[{"id":"a"},\#(new),{"id":42}]"#.utf8)
        XCTAssertEqual(PlayerViewModel.decodeQueue(data)?.map(\.id), ["a", "show#e1"])
    }

    func testEpisodeThatCannotBeDecodedDropsTheEntryRatherThanQueueingTheShow() throws {
        let data = Data(#"[{"item":{"id":"show"},"episode":{"title":"no id"}},{"id":"a"}]"#.utf8)
        XCTAssertEqual(PlayerViewModel.decodeQueue(data)?.map(\.id), ["a"])
    }

    // MARK: Identity and dedupe

    func testTwoEpisodesOfOneShowAreDistinctEntries() throws {
        let s = try show()
        let one = UpNextEntry(item: s, episode: try episode("e1"))
        let two = UpNextEntry(item: s, episode: try episode("e2"))
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(Set([one, two, one]).count, 2)
        // The bulk-add plan keys on these ids, so the second episode is not "already queued".
        let plan = PlayerViewModel.queueAddPlan(addingIds: [two.id], existingIds: [one.id], currentId: nil)
        XCTAssertEqual(plan.idsToAppend, [two.id])
        let again = PlayerViewModel.queueAddPlan(addingIds: [one.id], existingIds: [one.id], currentId: nil)
        XCTAssertTrue(again.idsToAppend.isEmpty)
    }

    func testBookEntryIdIsTheItemId() throws {
        XCTAssertEqual(UpNextEntry(item: try decodeItem(#"{"id":"a"}"#)).id, "a")
    }

    func testEpisodeRowShowsEpisodeTitleOverShowName() throws {
        let s = try decodeItem(#"{"id":"show","mediaType":"podcast","media":{"metadata":{"title":"The Show"}}}"#)
        let e = UpNextEntry(item: s, episode: try episode("e1", title: "Episode One"))
        XCTAssertEqual(e.title, "Episode One")
        XCTAssertEqual(e.subtitle, "The Show")
    }

    // MARK: Loaded / finished decisions

    func testEntryLoadedNeedsTheSameEpisode() throws {
        let e = UpNextEntry(item: try show(), episode: try episode("e1"))
        XCTAssertTrue(PlayerViewModel.isEntryLoaded(e, currentItemId: "show", currentEpisodeId: "e1"))
        XCTAssertFalse(PlayerViewModel.isEntryLoaded(e, currentItemId: "show", currentEpisodeId: "e2"))
        XCTAssertFalse(PlayerViewModel.isEntryLoaded(e, currentItemId: "show", currentEpisodeId: nil))
        let book = UpNextEntry(item: try decodeItem(#"{"id":"a"}"#))
        XCTAssertTrue(PlayerViewModel.isEntryLoaded(book, currentItemId: "a", currentEpisodeId: nil))
    }

    func testFreshServerAnswerWinsForBooksAndEpisodes() throws {
        let book = UpNextEntry(item: try decodeItem(#"{"id":"a"}"#))
        let ep = UpNextEntry(item: try show(), episode: try episode("e1"))
        XCTAssertTrue(PlayerViewModel.shouldSkipQueueEntry(book, freshFinished: true))
        XCTAssertFalse(PlayerViewModel.shouldSkipQueueEntry(book, freshFinished: false))
        XCTAssertTrue(PlayerViewModel.shouldSkipQueueEntry(ep, freshFinished: true))
        XCTAssertFalse(PlayerViewModel.shouldSkipQueueEntry(ep, freshFinished: false))
    }

    func testWithoutAServerAnswerABookUsesItsSnapshotAndAnEpisodeIsKept() throws {
        let finishedBook = UpNextEntry(item: try decodeItem(
            #"{"id":"b","userMediaProgress":{"id":"p","libraryItemId":"b","isFinished":true}}"#))
        XCTAssertTrue(PlayerViewModel.shouldSkipQueueEntry(finishedBook, freshFinished: nil))
        // The show's own mediaProgress says nothing about one episode, so it must not skip it.
        let showWithFinishedProgress = try decodeItem(
            #"{"id":"show","mediaType":"podcast","userMediaProgress":{"id":"p","libraryItemId":"show","isFinished":true}}"#)
        let ep = UpNextEntry(item: showWithFinishedProgress, episode: try episode("e1"))
        XCTAssertFalse(PlayerViewModel.shouldSkipQueueEntry(ep, freshFinished: nil))
    }
}
