import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 E3, cache half): the Stats tab's disk cache decisions.
final class Batch496StatsCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-cache-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func payload(scope: String = "server|acct", version: Int = StatsCache.currentVersion,
                         savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StatsCache.Payload {
        let items = ListeningStatsItems(byId: ["b1": ListeningStatsItem(id: "b1", timeListening: 3600, title: "Dune", author: "Frank Herbert")])
        return StatsCache.Payload(
            version: version, scope: scope, savedAt: savedAt,
            stats: ListeningStats(totalTime: 7200, today: 600, days: ["2023-11-14": 1800], items: items),
            sessions: [], libraryId: "lib1",
            library: StatsCache.LibrarySummary(LibraryStats(totalItems: 12, totalAuthors: 5, totalDuration: 1000, totalSize: 2000)),
            finishedBooks: 4)
    }

    func testRoundTripKeepsEveryFigure() throws {
        StatsCache.write(payload(), in: dir)
        let loaded = try XCTUnwrap(StatsCache.load(scope: "server|acct", in: dir))
        XCTAssertEqual(loaded.stats.totalTime, 7200)
        XCTAssertEqual(loaded.stats.today, 600)
        XCTAssertEqual(loaded.stats.days, ["2023-11-14": 1800])
        XCTAssertEqual(loaded.stats.items?.byId["b1"]?.title, "Dune")
        XCTAssertEqual(loaded.stats.items?.byId["b1"]?.author, "Frank Herbert")
        XCTAssertEqual(loaded.library?.libraryStats, LibraryStats(totalItems: 12, totalAuthors: 5, totalDuration: 1000, totalSize: 2000))
        XCTAssertEqual(loaded.libraryId, "lib1")
        XCTAssertEqual(loaded.finishedBooks, 4)
        XCTAssertEqual(loaded.savedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testVersionMismatchIsIgnoredAndFileKept() throws {
        let data = try XCTUnwrap(StatsCache.encode(payload(version: StatsCache.currentVersion + 1)))
        if case .ignore = StatsCache.decode(data, scope: "server|acct") {} else { XCTFail("expected ignore") }
        StatsCache.write(payload(version: StatsCache.currentVersion + 1), in: dir)
        XCTAssertNil(StatsCache.load(scope: "server|acct", in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: StatsCache.fileURL(forScope: "server|acct", in: dir).path))
    }

    func testFutureShapeUnderNewVersionIsIgnoredNotCorrupt() {
        let data = Data(#"{"version": 99, "somethingNew": true}"#.utf8)
        if case .ignore = StatsCache.decode(data, scope: "s") {} else { XCTFail("expected ignore") }
    }

    func testWrongScopeIsIgnoredEvenIfTheFileIsFoundUnderThisName() throws {
        // Another account's payload planted under this scope's file name is never returned.
        let other = payload(scope: "server|other")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(StatsCache.encode(other)).write(to: StatsCache.fileURL(forScope: "server|acct", in: dir))
        XCTAssertNil(StatsCache.load(scope: "server|acct", in: dir))
    }

    func testEachScopeGetsItsOwnFile() {
        XCTAssertNotEqual(StatsCache.fileName(forScope: "a"), StatsCache.fileName(forScope: "b"))
        StatsCache.write(payload(scope: "a"), in: dir)
        XCTAssertNil(StatsCache.load(scope: "b", in: dir))
        XCTAssertNotNil(StatsCache.load(scope: "a", in: dir))
    }

    func testCorruptFileIsDeletedAndReadsAsNil() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = StatsCache.fileURL(forScope: "server|acct", in: dir)
        try Data("not json".utf8).write(to: url)
        if case .corrupt = StatsCache.decode(Data("not json".utf8), scope: "server|acct") {} else { XCTFail("expected corrupt") }
        XCTAssertNil(StatsCache.load(scope: "server|acct", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnsignedScopesAreNeverCached() {
        XCTAssertFalse(StatsCache.isCacheable(scope: ""))
        XCTAssertFalse(StatsCache.isCacheable(scope: "unscoped"))
        StatsCache.write(payload(scope: "unscoped"), in: dir)
        XCTAssertNil(StatsCache.load(scope: "unscoped", in: dir))
    }

    func testRemoveAllDeletesEveryScope() {
        StatsCache.write(payload(scope: "a"), in: dir)
        StatsCache.write(payload(scope: "b"), in: dir)
        StatsCache.removeAll(in: dir)
        XCTAssertNil(StatsCache.load(scope: "a", in: dir))
        XCTAssertNil(StatsCache.load(scope: "b", in: dir))
    }

    // MARK: Time-dependent and derived figures

    func testTodayFromAnEarlierDayIsNotShown() {
        let cal = Calendar.current
        let loaded = Date(timeIntervalSince1970: 1_700_000_000)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: loaded)!
        XCTAssertEqual(StatsCache.todaySeconds(600, loadedAt: loaded, now: loaded), 600)
        XCTAssertNil(StatsCache.todaySeconds(600, loadedAt: loaded, now: tomorrow))
        XCTAssertNil(StatsCache.todaySeconds(nil, loadedAt: loaded, now: loaded))
    }

    func testFinishedCountPrefersLiveThenCachedOnlyWhileCached() {
        XCTAssertEqual(StatsCache.finishedCount(live: 7, cached: 4, statsAreCached: true), 7)
        XCTAssertEqual(StatsCache.finishedCount(live: 0, cached: 4, statsAreCached: true), 4)
        XCTAssertEqual(StatsCache.finishedCount(live: 0, cached: 4, statsAreCached: false), 0)
        XCTAssertEqual(StatsCache.finishedCount(live: 0, cached: nil, statsAreCached: true), 0)
    }

    func testLibraryTotalsOnlyForTheSameLibraryWhileCached() {
        let live = LibraryStats(totalItems: 1)
        let cached = LibraryStats(totalItems: 2)
        XCTAssertEqual(StatsCache.libraryStatsToShow(live: live, cached: cached, cachedLibraryId: "l", selectedLibraryId: "l", statsAreCached: true), live)
        XCTAssertEqual(StatsCache.libraryStatsToShow(live: nil, cached: cached, cachedLibraryId: "l", selectedLibraryId: "l", statsAreCached: true), cached)
        XCTAssertNil(StatsCache.libraryStatsToShow(live: nil, cached: cached, cachedLibraryId: "l", selectedLibraryId: "other", statsAreCached: true))
        XCTAssertNil(StatsCache.libraryStatsToShow(live: nil, cached: cached, cachedLibraryId: "l", selectedLibraryId: "l", statsAreCached: false))
    }

    func testCSVExportNeedsLiveFigures() {
        XCTAssertNil(StatsCache.exportableDays(["2023-11-14": 60], statsAreCached: true))
        XCTAssertEqual(StatsCache.exportableDays(["2023-11-14": 60], statsAreCached: false), ["2023-11-14": 60])
    }

    // MARK: Staleness wording

    func testCachedWhileLoadingNamesTheDateRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        let when = f.localizedString(for: yesterday, relativeTo: now)
        XCTAssertTrue(StatsStaleness.cachedWhileLoading(asOf: yesterday, now: now).contains(when))
    }

    func testFailedMessageOverCachedFiguresNamesTheDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        let when = f.localizedString(for: yesterday, relativeTo: now)
        XCTAssertTrue(StatsStaleness.message(asOf: yesterday, now: now, status: .offline).contains(when))
    }
}
