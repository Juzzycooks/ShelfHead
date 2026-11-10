import XCTest
@testable import ShelfHead

/// Review test gap (Smart Filters, 30 October 2026): the enum's identity and copy, the snapshot
/// cap, and each filter's match rule through the pure `LibraryViewModel.applySmartFilter`
/// overload (clock, progress, downloads and favourites passed in).
@MainActor
final class SmartFilterRuleTests: XCTestCase {
    func testThereAreEightFiltersWithUniqueIds() {
        XCTAssertEqual(SmartFilter.allCases.count, 8)
        XCTAssertEqual(Set(SmartFilter.allCases.map(\.id)).count, 8)
    }

    func testRawValuesRoundTripForDeepLinks() {
        for f in SmartFilter.allCases { XCTAssertEqual(SmartFilter(rawValue: f.rawValue), f) }
        XCTAssertNil(SmartFilter(rawValue: "nope"))
    }

    func testEveryFilterHasALabelSubtitleAndIcon() {
        for f in SmartFilter.allCases {
            XCTAssertFalse(f.label.isEmpty, f.rawValue)
            XCTAssertFalse(f.subtitle.isEmpty, f.rawValue)
            XCTAssertFalse(f.icon.isEmpty, f.rawValue)
        }
    }

    func testLabelsAreDistinct() {
        XCTAssertEqual(Set(SmartFilter.allCases.map(\.label)).count, 8)
    }

    func testSnapshotCapIsTwentyThousand() {
        XCTAssertEqual(LibraryViewModel.smartFilterItemCap, 20_000)
    }

    // MARK: - Match rules

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func item(_ id: String, duration: Double = 3600, series: String? = nil, cover: Bool = true,
                      addedDaysAgo: Double? = nil, author: String = "A") -> ShelfHead.LibraryItem {
        var media: [String: Any] = ["duration": duration, "metadata": ["title": id, "authorName": author]
            .merging(series.map { ["seriesName": $0] } ?? [:]) { a, _ in a }]
        if cover { media["coverPath"] = "/c/\(id).jpg" }
        var json: [String: Any] = ["id": id, "mediaType": "book", "media": media]
        if let ago = addedDaysAgo { json["addedAt"] = Int((now.timeIntervalSince1970 - ago * day) * 1000) }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ShelfHead.LibraryItem.self, from: data)
    }

    private func mp(_ id: String, progress: Double = 0.5, finished: Bool = false,
                    currentTime: Double = 100, updatedDaysAgo: Double = 1) -> MediaProgress {
        MediaProgress(id: "p-\(id)", libraryItemId: id, episodeId: nil, duration: 3600, progress: progress,
                      currentTime: currentTime, isFinished: finished,
                      lastUpdate: Int((now.timeIntervalSince1970 - updatedDaysAgo * day) * 1000),
                      startedAt: nil, finishedAt: nil)
    }

    private func ids(_ filter: SmartFilter, _ source: [ShelfHead.LibraryItem],
                     progress: [String: MediaProgress] = [:], downloaded: Set<String> = [],
                     favorites: Set<String> = []) -> [String] {
        LibraryViewModel.applySmartFilter(
            filter, to: source, now: now,
            progress: { progress[$0.id] }, isDownloaded: { downloaded.contains($0) },
            isFavorite: { favorites.contains($0.authorName) }
        ).map(\.id)
    }

    func testDownloadedUnfinishedNeedsADownloadThatIsNotFinished() {
        let r = ids(.downloadedUnfinished, [item("a"), item("b"), item("c")],
                    progress: ["b": mp("b", finished: true)], downloaded: ["a", "b"])
        XCTAssertEqual(r, ["a"])
    }

    func testNearlyFinishedIsNinetyPercentAndUnfinished() {
        let r = ids(.nearlyFinished, [item("a"), item("b"), item("c"), item("d")],
                    progress: ["a": mp("a", progress: 0.9), "b": mp("b", progress: 0.89),
                               "c": mp("c", progress: 0.95, finished: true)])
        XCTAssertEqual(r, ["a"])
    }

    func testStaleIsStartedUnfinishedAndUntouchedForThirtyDays() {
        let r = ids(.stale, [item("a"), item("b"), item("c"), item("d")],
                    progress: ["a": mp("a", updatedDaysAgo: 31), "b": mp("b", updatedDaysAgo: 29),
                               "c": mp("c", currentTime: 0, updatedDaysAgo: 40),
                               "d": mp("d", finished: true, updatedDaysAgo: 40)])
        XCTAssertEqual(r, ["a"])
    }

    func testShortAndLongListenBounds() {
        let source = [item("zero", duration: 0), item("short", duration: 2 * 3600 - 1),
                      item("two", duration: 2 * 3600), item("twenty", duration: 20 * 3600),
                      item("long", duration: 20 * 3600 + 1)]
        XCTAssertEqual(ids(.shortListens, source), ["short"])
        XCTAssertEqual(ids(.longListens, source), ["long"])
    }

    func testUnplayedInStartedSeries() {
        let source = [item("s1", series: "S #1"), item("s2", series: "S #1"),
                      item("t1", series: "T"), item("solo")]
        let r = ids(.unplayedInStartedSeries, source, progress: ["s1": mp("s1")])
        XCTAssertEqual(r, ["s2"])
    }

    func testMissingCovers() {
        XCTAssertEqual(ids(.missingCovers, [item("a"), item("b", cover: false)]), ["b"])
    }

    func testFavoriteNewArrivalsNeedsAFavouriteAndThirtyDays() {
        let source = [item("new", addedDaysAgo: 5, author: "Fav"), item("old", addedDaysAgo: 31, author: "Fav"),
                      item("other", addedDaysAgo: 5, author: "Else"), item("undated", author: "Fav")]
        XCTAssertEqual(ids(.favoriteNewArrivals, source, favorites: ["Fav"]), ["new"])
    }
}
