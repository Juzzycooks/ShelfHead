import XCTest
@testable import ShelfHead_Watch

/// Batch 411: the Shelf's book list (`WatchShelf`).
final class WatchShelfDecisionsTests: XCTestCase {
    private func book(_ id: String, progress: Double = 0.3) -> WatchShelfBook {
        WatchShelfBook(itemId: id, title: "Title \(id)", author: "Author", progress: progress)
    }

    private func ids(_ sleeves: [WatchShelfSleeve]) -> [String] { sleeves.map(\.id) }

    // MARK: Order, de-duplication, cap

    func testOrderIsCurrentThenServerThenMirrorThenDownloadsThenBrowse() {
        var input = WatchShelfInput()
        input.phoneCurrent = book("p")
        input.serverInProgress = [book("s1"), book("s2")]
        input.mirroredInProgress = [book("m1")]
        input.downloads = [book("d1")]
        input.phoneIsReachable = true
        input.hasWatchSession = true
        XCTAssertEqual(ids(WatchShelf.sleeves(for: input)), ["p", "s1", "s2", "m1", "d1", WatchShelfSleeve.browseId])
    }

    func testDuplicatesKeepTheirFirstPlace() {
        var input = WatchShelfInput()
        input.phoneCurrent = book("a")
        input.serverInProgress = [book("a"), book("b")]
        input.mirroredInProgress = [book("b")]
        input.downloads = [book("a"), book("c")]
        input.phoneIsReachable = true
        let sleeves = WatchShelf.sleeves(for: input)
        XCTAssertEqual(ids(sleeves), ["a", "b", "c", WatchShelfSleeve.browseId])
        XCTAssertEqual(sleeves[0].kind, .current(source: .iPhone, isPlaying: false))
    }

    func testCapsAtTenBooksPlusBrowse() {
        var input = WatchShelfInput()
        input.serverInProgress = (0..<15).map { book("s\($0)") }
        input.hasWatchSession = true
        let sleeves = WatchShelf.sleeves(for: input)
        XCTAssertEqual(sleeves.count, WatchShelf.maxBooks + 1)
        XCTAssertEqual(sleeves.last?.kind, .browse)
    }

    func testWatchBookComesFirstInStandaloneOrWhileItPlays() {
        var input = WatchShelfInput()
        input.phoneCurrent = book("p")
        input.watchCurrent = book("w")
        input.phoneIsReachable = true
        XCTAssertEqual(ids(WatchShelf.sleeves(for: input)).prefix(2), ["p", "w"])

        input.watchIsPlaying = true
        XCTAssertEqual(ids(WatchShelf.sleeves(for: input)).prefix(2), ["w", "p"])

        input.watchIsPlaying = false
        input.isStandaloneMode = true
        XCTAssertEqual(ids(WatchShelf.sleeves(for: input)).prefix(2), ["w", "p"])
    }

    // MARK: Play target and availability

    func testDownloadedBookPlaysOnWatchEvenInCompanionMode() {
        var input = WatchShelfInput()
        input.downloads = [book("d")]
        input.phoneIsReachable = true
        XCTAssertEqual(WatchShelf.sleeves(for: input).first?.kind, .book(target: .watch, isAvailable: true))
    }

    func testServerBookPlaysOnPhoneInCompanionMode() {
        var input = WatchShelfInput()
        input.serverInProgress = [book("s")]
        input.phoneIsReachable = true
        input.hasWatchSession = true
        XCTAssertEqual(WatchShelf.sleeves(for: input).first?.kind, .book(target: .iPhone, isAvailable: true))
    }

    func testMirroredBookIsDimmedWhenThePhoneIsOutOfReach() {
        var input = WatchShelfInput()
        input.mirroredInProgress = [book("m")]
        input.phoneIsReachable = false
        input.isStandaloneMode = false
        input.hasWatchSession = false
        let sleeve = WatchShelf.sleeves(for: input).first
        XCTAssertEqual(sleeve?.kind, .book(target: .iPhone, isAvailable: false))
        XCTAssertEqual(sleeve?.sourceSystemImage, "iphone.slash")
        XCTAssertEqual(sleeve?.isAvailable, false)
    }

    func testStandaloneStreamingNeedsAWatchSession() {
        var input = WatchShelfInput()
        input.mirroredInProgress = [book("m")]
        input.isStandaloneMode = true
        input.downloads = [book("d")]
        XCTAssertEqual(WatchShelf.sleeves(for: input).first?.kind, .book(target: .watch, isAvailable: false))
        input.hasWatchSession = true
        XCTAssertEqual(WatchShelf.sleeves(for: input).first?.kind, .book(target: .watch, isAvailable: true))
    }

    // MARK: Empty states

    func testSignedOutWithNoPhoneAndNothingShowsOnlySetup() {
        XCTAssertEqual(WatchShelf.sleeves(for: WatchShelfInput()).map(\.kind), [.setup])
    }

    func testNothingInProgressWithAPhoneShowsBrowse() {
        var input = WatchShelfInput()
        input.phoneIsReachable = true
        XCTAssertEqual(WatchShelf.sleeves(for: input).map(\.kind), [.browse])
    }

    func testDownloadsAloneNeverShowSetup() {
        var input = WatchShelfInput()
        input.downloads = [book("d")]
        XCTAssertEqual(ids(WatchShelf.sleeves(for: input)), ["d", WatchShelfSleeve.browseId])
    }

    // MARK: Downloads order

    func testDownloadsOrderStartedByLastPlayThenUnstartedByDateAndDropFinished() {
        let day: TimeInterval = 86_400
        func input(_ id: String, position: Double?, playedAt: Double?, downloaded: TimeInterval) -> WatchResumeInput {
            WatchResumeInput(itemId: id, title: id, author: "", duration: 1_000,
                             downloadedAt: Date(timeIntervalSince1970: downloaded),
                             lastPosition: position, lastPlayedAt: playedAt)
        }
        let ordered = WatchShelf.orderedDownloads([
            input("old-start", position: 100, playedAt: 1_000, downloaded: day),
            input("new-start", position: 200, playedAt: 5_000, downloaded: day),
            input("unstarted-old", position: nil, playedAt: nil, downloaded: day),
            input("unstarted-new", position: 0, playedAt: nil, downloaded: 3 * day),
            input("finished", position: 990, playedAt: 9_000, downloaded: day),
        ])
        XCTAssertEqual(ordered.map(\.itemId), ["new-start", "old-start", "unstarted-new", "unstarted-old"])
        XCTAssertEqual(ordered.first?.progress ?? 0, 0.2, accuracy: 0.0001)
    }

    func testMirrorKeepsOnlyPartPlayedBooks() {
        let books = [
            WatchBookSummary(id: "a", title: "A", author: "", durationSeconds: 1, progress: nil, coverData: nil),
            WatchBookSummary(id: "b", title: "B", author: "", durationSeconds: 1, progress: 0, coverData: nil),
            WatchBookSummary(id: "c", title: "C", author: "", durationSeconds: 1, progress: 0.5, coverData: nil),
            WatchBookSummary(id: "d", title: "D", author: "", durationSeconds: 1, progress: 0.995, coverData: nil),
        ]
        XCTAssertEqual(WatchShelf.mirroredInProgress(books).map(\.itemId), ["c"])
    }

    // MARK: Figures and layout

    func testPercentRoundsDownAndClamps() {
        XCTAssertEqual(WatchShelf.percentText(0.999), (0.99).formatted(.percent.precision(.fractionLength(0))))
        XCTAssertEqual(WatchShelf.percentText(-1), (0.0).formatted(.percent.precision(.fractionLength(0))))
        XCTAssertEqual(WatchShelf.percentText(.nan), (0.0).formatted(.percent.precision(.fractionLength(0))))
    }

    func testCoverSideIsSeventyPercentUnlessHeightLimits() {
        // 46 mm: 208 x 248 pt. 70% of 208 = 145; 248 - 96 = 152.
        XCTAssertEqual(WatchShelf.coverSide(screenWidth: 208, screenHeight: 248, isAccessibilitySize: false), 145)
        // 40 mm: 162 x 197. 70% = 113; 197 - 96 = 101, so height wins.
        XCTAssertEqual(WatchShelf.coverSide(screenWidth: 162, screenHeight: 197, isAccessibilitySize: false), 101)
        // Accessibility sizes: half the width.
        XCTAssertEqual(WatchShelf.coverSide(screenWidth: 208, screenHeight: 248, isAccessibilitySize: true), 104)
        // Never below the floor.
        XCTAssertEqual(WatchShelf.coverSide(screenWidth: 80, screenHeight: 100, isAccessibilitySize: false), WatchShelf.minimumCoverSide)
    }
}
