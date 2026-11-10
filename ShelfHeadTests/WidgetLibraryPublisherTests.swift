import XCTest
@testable import ShelfHead

/// Cover for the merge that decides which books the widget's configuration intent can
/// offer. The set is capped (`SharedLibrary.maxBooks`), so what survives the cap — and in
/// what order — is the whole behaviour.
@MainActor
final class WidgetLibraryPublisherTests: XCTestCase {

    private func book(_ id: String) -> SharedLibrary.PinnableBook {
        SharedLibrary.PinnableBook(
            id: id, title: "Title \(id)", author: "Author",
            currentTime: 60, duration: 3600, updatedAt: Date())
    }

    private func merged(
        continueListening: [String], upNext: [String]
    ) -> [String] {
        WidgetLibraryPublisher.merge(
            continueListening: continueListening.map(book),
            upNext: upNext.map(book)
        ).map(\.id)
    }

    func testQueuedBooksComeFirst() {
        XCTAssertEqual(merged(continueListening: ["c1", "c2"], upNext: ["u1"]), ["u1", "c1", "c2"],
                       "A queued book is a more deliberate signal than one that merely has progress")
    }

    func testBookInBothHalvesAppearsOnce() {
        XCTAssertEqual(merged(continueListening: ["x", "c2"], upNext: ["x"]), ["x", "c2"])
    }

    func testSetIsCappedAtMaxBooks() {
        let many = (1...30).map { "c\($0)" }
        XCTAssertEqual(merged(continueListening: many, upNext: []).count, SharedLibrary.maxBooks)
    }

    func testQueuedBookSurvivesTheCap() {
        let many = (1...30).map { "c\($0)" }
        XCTAssertEqual(merged(continueListening: many, upNext: ["q"]).first, "q",
                       "Ordering decides what the cap discards, so the queue must win it")
    }

    func testDuplicatesDoNotConsumeTwoSlots() {
        let many = (1...20).map { "c\($0)" }
        XCTAssertEqual(merged(continueListening: many, upNext: ["c1", "c2"]).count, SharedLibrary.maxBooks)
    }

    func testEmptyInputProducesEmptySet() {
        XCTAssertTrue(merged(continueListening: [], upNext: []).isEmpty)
    }

    // MARK: - W2: published progress

    /// W2 (REVIEW_2026-09-04_UI.md Pass 4). The Continue Listening entities the
    /// personalized view returns carry no `userMediaProgress`, so `item.currentTime` is
    /// zero for every one of them and the widget drew an empty bar with the whole book
    /// duration as time left. These pin the merge that fixes it.
    private func progress(
        currentTime: Double?, duration: Double? = nil, lastUpdate: Int? = nil
    ) -> MediaProgress {
        MediaProgress(
            id: "p", libraryItemId: "b", episodeId: nil, duration: duration,
            progress: nil, currentTime: currentTime, isFinished: false,
            lastUpdate: lastUpdate, startedAt: nil, finishedAt: nil)
    }

    func testSideProgressMapSuppliesThePositionTheShelfEntityLacks() {
        let resolved = WidgetLibraryPublisher.resolvedProgress(
            for: progress(currentTime: 14_400),
            itemCurrentTime: 0, itemDuration: 75_826.29, itemUpdatedAtMilliseconds: nil)
        XCTAssertEqual(resolved.currentTime, 14_400,
                       "A Continue Listening book must not be published at position zero")
        XCTAssertEqual(resolved.duration, 75_826.29)
    }

    func testItemProgressIsKeptWhenThereIsNoLookup() {
        let resolved = WidgetLibraryPublisher.resolvedProgress(
            for: nil, itemCurrentTime: 900, itemDuration: 3_600, itemUpdatedAtMilliseconds: nil)
        XCTAssertEqual(resolved.currentTime, 900,
                       "An Up Next book is fetched whole and already carries its own progress")
    }

    func testDurationFallsBackToTheProgressRecord() {
        let resolved = WidgetLibraryPublisher.resolvedProgress(
            for: progress(currentTime: 60, duration: 3_600),
            itemCurrentTime: 0, itemDuration: 0, itemUpdatedAtMilliseconds: nil)
        XCTAssertEqual(resolved.duration, 3_600,
                       "A zero duration collapses the widget's progress bar even with a good position")
    }

    func testStampComesFromLastUpdateInMilliseconds() {
        let resolved = WidgetLibraryPublisher.resolvedProgress(
            for: progress(currentTime: 60, lastUpdate: 1_753_144_481_000),
            itemCurrentTime: 0, itemDuration: 3_600, itemUpdatedAtMilliseconds: nil)
        XCTAssertEqual(resolved.updatedAt, Date(timeIntervalSince1970: 1_753_144_481))
    }

    func testStampFallsBackToTheItemsOwnTimestamp() {
        let resolved = WidgetLibraryPublisher.resolvedProgress(
            for: nil, itemCurrentTime: 0, itemDuration: 3_600,
            itemUpdatedAtMilliseconds: 1_753_144_481_000)
        XCTAssertEqual(resolved.updatedAt, Date(timeIntervalSince1970: 1_753_144_481))
    }

    /// The `previous != payload` no-op in `commit` compares `PinnableBook`s field by
    /// field, `updatedAt` included. Stamping that with `Date()` made every republish
    /// differ from the last, so the guard reloaded WidgetKit on every pull-to-refresh
    /// against a rate-limited budget. Unchanged inputs must produce an identical stamp.
    func testUnchangedInputProducesAnIdenticalResultSoTheNoOpGuardHolds() {
        func resolve() -> WidgetLibraryPublisher.ResolvedProgress {
            WidgetLibraryPublisher.resolvedProgress(
                for: progress(currentTime: 14_400, lastUpdate: 1_753_144_481_000),
                itemCurrentTime: 0, itemDuration: 75_826.29, itemUpdatedAtMilliseconds: nil)
        }
        XCTAssertEqual(resolve(), resolve())
    }

    func testUndatableBookIsStillStableAcrossRepublishes() {
        func resolve() -> WidgetLibraryPublisher.ResolvedProgress {
            WidgetLibraryPublisher.resolvedProgress(
                for: nil, itemCurrentTime: 0, itemDuration: 3_600, itemUpdatedAtMilliseconds: nil)
        }
        XCTAssertEqual(resolve(), resolve(), "An unknown stamp must not read as a change")
        XCTAssertEqual(resolve().updatedAt, .distantPast)
    }

    func testProgressAdvancingIsStillSeenAsAChange() {
        let before = WidgetLibraryPublisher.resolvedProgress(
            for: progress(currentTime: 100, lastUpdate: 1_753_144_481_000),
            itemCurrentTime: 0, itemDuration: 3_600, itemUpdatedAtMilliseconds: nil)
        let after = WidgetLibraryPublisher.resolvedProgress(
            for: progress(currentTime: 200, lastUpdate: 1_753_148_000_000),
            itemCurrentTime: 0, itemDuration: 3_600, itemUpdatedAtMilliseconds: nil)
        XCTAssertNotEqual(before, after,
                          "The no-op guard must still let real listening through to WidgetKit")
    }

    // MARK: - Cover filenames

    /// Cover files are named from a hash of the item id, not the id itself, because the id
    /// is server-supplied and this builds a path. These are the ids that would matter if
    /// it were used directly.
    func testCoverFilenamesAreSafeForHostileItemIds() {
        let hostile = ["../../etc/passwd", "..", ".", "a/b/c", "", "id with spaces"]
        var produced = Set<String>()
        for id in hostile {
            SharedLibrary.writeCover(Data("x".utf8), for: id)
            XCTAssertNotNil(SharedLibrary.readCover(for: id), "Round trip must work for \(id)")
            produced.insert(id)
        }
        XCTAssertEqual(produced.count, hostile.count)
        SharedLibrary.pruneCovers(keeping: [])
    }

    func testPruneRemovesCoversNoLongerPublished() {
        SharedLibrary.writeCover(Data("keep".utf8), for: "keep-me")
        SharedLibrary.writeCover(Data("drop".utf8), for: "drop-me")
        SharedLibrary.pruneCovers(keeping: ["keep-me"])
        XCTAssertNotNil(SharedLibrary.readCover(for: "keep-me"))
        XCTAssertNil(SharedLibrary.readCover(for: "drop-me"),
                     "A book leaving the published set must not leave its cover behind forever")
        SharedLibrary.pruneCovers(keeping: [])
    }
}
