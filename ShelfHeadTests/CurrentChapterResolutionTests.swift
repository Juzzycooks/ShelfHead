import XCTest
@testable import ShelfHead

/// Item 10 (REVIEW-2026-09-09.md, "redraw scope"): pins the two pure decisions the
/// player's chapter caching now rests on.
///
/// `PlayerViewModel.currentChapter` used to re-scan the whole chapter list on every
/// access, and the full player read it (directly, and through `hasChapters`/
/// `chapterStart`/`chapterElapsed`/…) many times per render at roughly two renders a
/// second. The fix memoises one resolution per position, keyed on the chapter list — so
/// what is worth pinning is (a) the resolution rule itself and (b) the key that decides
/// when that memo is still valid. Both are pure functions over their arguments, which is
/// this project's established line for what gets a test (see `PlayerAccessibilityLayout
/// Tests`' note): the *invalidation scope* the fix exists for is a SwiftUI runtime
/// behaviour and cannot be asserted from a unit test — it needs the SwiftUI Instruments
/// template on a device.
///
/// `@MainActor` because `PlayerViewModel` is, so its nested `ChapterListSignature` and
/// the memberwise construction below are reachable without threading isolation through
/// every assertion — the same reason `AuthViewModelURLTests`/`ColorThemeTests` are.
@MainActor
final class CurrentChapterResolutionTests: XCTestCase {

    /// `Chapter` only has a `Decodable` init (no memberwise one), same as
    /// `BookmarkMomentLabelTests` found — so fixtures are built through JSON.
    private func chapters(_ triples: [(Int, Double, Double)]) throws -> [Chapter] {
        let objects = triples.map { #"{"id": \#($0.0), "start": \#($0.1), "end": \#($0.2), "title": "Chapter \#($0.0)"}"# }
        let json = "[\(objects.joined(separator: ","))]"
        return try JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
    }

    // MARK: - `chapterIndex(in:at:)`

    func testResolvesTheChapterContainingTheTime() throws {
        let list = try chapters([(0, 0, 100), (1, 100, 250), (2, 250, 400)])
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: list, at: 0), 0)
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: list, at: 99.9), 0)
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: list, at: 175), 1)
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: list, at: 399.9), 2)
    }

    func testRangesAreHalfOpenSoABoundaryBelongsToTheNextChapter() throws {
        // The rule the two linear scans this replaces both used (`>= start`, `< end`).
        // It matters for the cache: the memo is held only while the position is still
        // inside the resolved chapter's own bounds, so `end` has to land in the next one
        // or a chapter change at an exact boundary would be missed.
        let list = try chapters([(0, 0, 100), (1, 100, 250)])
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: list, at: 100), 1)
    }

    func testNoChapterCoversTheTime() throws {
        let list = try chapters([(0, 10, 100), (1, 100, 250)])
        // Before the first chapter starts (an intro track the markers don't cover),
        // and past the end of the last one.
        XCTAssertNil(PlayerViewModel.chapterIndex(in: list, at: 5))
        XCTAssertNil(PlayerViewModel.chapterIndex(in: list, at: 250))
        // A gap between two chapters resolves to neither, rather than to the nearest.
        let gapped = try chapters([(0, 0, 100), (1, 150, 250)])
        XCTAssertNil(PlayerViewModel.chapterIndex(in: gapped, at: 120))
    }

    func testEmptyChapterListResolvesToNil() {
        XCTAssertNil(PlayerViewModel.chapterIndex(in: [], at: 0))
        XCTAssertNil(PlayerViewModel.chapterIndex(in: [], at: 1234))
    }

    func testFirstMatchWinsForOverlappingChapters() throws {
        // Malformed input (overlapping ranges) isn't rejected — it resolves to the first
        // match, exactly as the `first { … }` scans it replaces did. Pinned so a later
        // "optimise this to a binary search" change has to notice it would change the
        // answer for a list that isn't sorted/disjoint.
        let list = try chapters([(0, 0, 200), (1, 100, 250)])
        XCTAssertEqual(PlayerViewModel.chapterIndex(in: list, at: 150), 0)
    }

    // MARK: - `ChapterListSignature` — the cache's validity key

    func testSignatureMatchesForTheSameChapterList() throws {
        let list = try chapters([(0, 0, 100), (1, 100, 250)])
        XCTAssertEqual(PlayerViewModel.ChapterListSignature(list),
                       PlayerViewModel.ChapterListSignature(list))
    }

    func testSignatureDistinguishesDifferentChapterLists() throws {
        let book = try chapters([(0, 0, 100), (1, 100, 250)])
        // Different length (the common case: another book).
        let longer = try chapters([(0, 0, 100), (1, 100, 250), (2, 250, 400)])
        XCTAssertNotEqual(PlayerViewModel.ChapterListSignature(book),
                          PlayerViewModel.ChapterListSignature(longer))
        // Same count, different total duration — the "same number of chapters, different
        // book" case, which is exactly what a naive count-only key would miss.
        let sameCount = try chapters([(0, 0, 90), (1, 90, 500)])
        XCTAssertNotEqual(PlayerViewModel.ChapterListSignature(book),
                          PlayerViewModel.ChapterListSignature(sameCount))
        // Same count and same end, different starting id (an intro track shifting the
        // numbering).
        let shiftedIds = try chapters([(1, 0, 100), (2, 100, 250)])
        XCTAssertNotEqual(PlayerViewModel.ChapterListSignature(book),
                          PlayerViewModel.ChapterListSignature(shiftedIds))
    }

    func testSignatureOfAnEmptyListIsStable() {
        XCTAssertEqual(PlayerViewModel.ChapterListSignature([]),
                       PlayerViewModel.ChapterListSignature([]))
    }

    // MARK: - `ChapterListSheet`'s index-column decision

    func testShowsIndexDecisionMatchesTheSelfNumberedTest() throws {
        // `ChapterListSheet.showsIndex` is `!Chapter.titlesAreSelfNumbered(titles)`,
        // moved out of the per-render path into `@State` set from the sheet's `.task`.
        // `titlesAreSelfNumbered` itself is covered in `FormattingAndModelsTests`; this
        // pins the composed decision the row actually reads, so the polarity can't be
        // flipped by a later edit without a failing test.
        XCTAssertFalse(!Chapter.titlesAreSelfNumbered(["1. Dawn", "2. Dusk", "3. Night"]))
        XCTAssertTrue(!Chapter.titlesAreSelfNumbered(["Dawn", "Dusk", "Night"]))
    }
}
