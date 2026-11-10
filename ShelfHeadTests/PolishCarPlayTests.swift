import XCTest
@testable import ShelfHead

/// Polish pass (CP-5, CR-1): pure decisions behind CarPlay Home's downloads fallback and the
/// duration formatting guard. The templates themselves need a live interface controller.
final class PolishCarPlayTests: XCTestCase {

    private func book(_ id: String, progress: Double, finished: Bool = false, lastUpdate: Int?) -> ShelfHead.LibraryItem {
        let metadata = MediaMetadata(
            title: id, subtitle: nil, authorName: nil, narratorName: nil,
            seriesName: nil, description: nil, publishedYear: nil, publisher: nil,
            language: nil, genres: nil, isbn: nil, asin: nil, series: nil)
        let media = Media(
            metadata: metadata, coverPath: nil, duration: 3600, chapters: nil, audioFiles: nil,
            numChapters: nil, numAudioFiles: nil, episodes: nil, ebookFile: nil)
        let mp = MediaProgress(
            id: id, libraryItemId: id, episodeId: nil, duration: 3600, progress: progress,
            currentTime: progress * 3600, isFinished: finished, lastUpdate: lastUpdate, startedAt: nil, finishedAt: nil)
        return ShelfHead.LibraryItem(
            id: id, ino: nil, libraryId: nil, mediaType: "book", media: media,
            numFiles: nil, size: nil, addedAt: nil, updatedAt: nil, mediaProgress: mp)
    }

    func testDownloadedShelfPutsInProgressFirst() throws {
        let items = [
            book("fresh", progress: 0, lastUpdate: 900),
            book("half", progress: 0.5, lastUpdate: 100),
            book("done", progress: 1, finished: true, lastUpdate: 800),
            book("recent", progress: 0.2, lastUpdate: 500)
        ]
        let shelf = try XCTUnwrap(CarPlayCoordinator.downloadedHomeShelf(items, limit: 10))
        XCTAssertEqual(shelf.items.map(\.id), ["recent", "half", "fresh", "done"])
    }

    func testDownloadedShelfRespectsLimitAndEmpty() {
        XCTAssertNil(CarPlayCoordinator.downloadedHomeShelf([], limit: 10))
        let items = (0..<5).map { (i: Int) in book("b\(i)", progress: 0.1, lastUpdate: i) }
        XCTAssertEqual(CarPlayCoordinator.downloadedHomeShelf(items, limit: 2)?.items.count, 2)
    }

    func testDownloadedFallbackOnlyOnFailedFirstLoad() {
        XCTAssertTrue(CarPlayCoordinator.shouldAppendDownloadedShelf(loadFailed: true, hadSections: false))
        XCTAssertFalse(CarPlayCoordinator.shouldAppendDownloadedShelf(loadFailed: true, hadSections: true))
        XCTAssertFalse(CarPlayCoordinator.shouldAppendDownloadedShelf(loadFailed: false, hadSections: false))
    }

    func testWholeSecondsNeverTraps() {
        XCTAssertEqual(CarPlayCoordinator.wholeSeconds(.nan), 0)
        XCTAssertEqual(CarPlayCoordinator.wholeSeconds(.infinity), 0)
        XCTAssertEqual(CarPlayCoordinator.wholeSeconds(-5), 0)
        XCTAssertEqual(CarPlayCoordinator.wholeSeconds(125.9), 125)
        XCTAssertGreaterThan(CarPlayCoordinator.wholeSeconds(1e300), 0)
    }
}
