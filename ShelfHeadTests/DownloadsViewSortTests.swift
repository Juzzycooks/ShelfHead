import XCTest
@testable import ShelfHead

/// Pins Item 34 (perf review): `DownloadsSettingsView.downloadedBooks` used to redo its
/// own `manifest(for:)` walk over every downloaded item id on every `body` evaluation,
/// entirely bypassing `DownloadManager.downloadedLibraryItems()`'s own cache of that same
/// walk. The cache couldn't be adopted as-is, though — it sorts with
/// `localizedStandardCompare` (numeric-aware: "Book 2" before "Book 10"), while this
/// screen has always sorted with `localizedCaseInsensitiveCompare`, so switching to the
/// cache directly would silently reorder rows.
///
/// The fix re-sorts the cached list with
/// `DownloadsSettingsView.DownloadedBookSummary.isOrderedBeforeByTitle` — this pins that
/// pure comparator so a future change to `DownloadManager`'s own cached sort can't
/// quietly change this screen's row order again.
final class DownloadsViewSortTests: XCTestCase {

    private typealias Summary = DownloadsSettingsView.DownloadedBookSummary

    private func summary(_ id: String, _ title: String, _ author: String = "") -> Summary {
        Summary(id: id, title: title, author: author)
    }

    func testSortsCaseInsensitivelyByTitle() {
        let input = [
            summary("1", "zebra"),
            summary("2", "Apple"),
            summary("3", "banana"),
        ]
        let sorted = input.sorted(by: Summary.isOrderedBeforeByTitle)
        XCTAssertEqual(sorted.map(\.id), ["2", "3", "1"])
    }

    /// The specific case this fix has to preserve: this screen's historical
    /// `localizedCaseInsensitiveCompare` is NOT numeric-aware, unlike
    /// `DownloadManager.downloadedLibraryItems()`'s own `localizedStandardCompare`.
    /// "Book 10" sorts before "Book 2" here (plain character-by-character comparison,
    /// '1' < '2'), which is the opposite of what `localizedStandardCompare` would do.
    /// If this ever starts failing because the two now agree, it means the sort actually
    /// changed and `DownloadsSettingsView.downloadedBooks` needs re-checking against
    /// today's on-screen order rather than just updating this expectation.
    func testDoesNotUseNumericAwareOrdering() {
        let input = [summary("a", "Book 2"), summary("b", "Book 10")]
        let sorted = input.sorted(by: Summary.isOrderedBeforeByTitle)
        XCTAssertEqual(sorted.map(\.id), ["b", "a"])
    }

    func testStableRelativeOrderForEqualTitles() {
        // `sorted(by:)` is documented as not guaranteed-stable in general, but Swift's
        // current implementation is stable for the small counts this screen deals with;
        // this pins today's observed behavior for identical keys rather than asserting a
        // language guarantee.
        let input = [
            summary("first", "Same Title"),
            summary("second", "Same Title"),
        ]
        let sorted = input.sorted(by: Summary.isOrderedBeforeByTitle)
        XCTAssertEqual(sorted.map(\.id), ["first", "second"])
    }

    func testIsOrderedBeforeByTitleIsStrictWeakOrdering() {
        // `sorted(by:)` requires `areInIncreasingOrder` to report false for equal
        // elements (irreflexivity) — guard against a future edit reintroducing e.g. a
        // `<` on `localizedCaseInsensitiveCompare`'s raw `ComparisonResult` that could
        // violate this.
        let a = summary("a", "Same")
        let b = summary("b", "same")
        XCTAssertFalse(Summary.isOrderedBeforeByTitle(a, b))
        XCTAssertFalse(Summary.isOrderedBeforeByTitle(b, a))
    }
}
