import XCTest
@testable import ShelfHead

/// Polish pass (J2 / J1-8): pure rules behind the launch changes. Home shelves disk cache
/// (version, decode failure, scope), failure copy, Spotlight change check, launch summary line.
@MainActor
final class PolishLaunchTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PolishLaunchTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func shelves() throws -> [PersonalizedView] {
        let json = """
        [{"label":"Continue Listening","labelStringKey":"LabelContinueListening","type":"book",
          "entities":[{"id":"li_1","libraryId":"lib1","mediaType":"book"}]}]
        """
        return try JSONDecoder().decode([PersonalizedView].self, from: Data(json.utf8))
    }

    // MARK: Home shelves cache

    func testRoundTripReturnsShelvesForSameScopeAndLibrary() throws {
        HomeShelvesCache.save(try shelves(), scope: "scopeA", libraryId: "lib1", in: dir)
        let loaded = HomeShelvesCache.load(scope: "scopeA", libraryId: "lib1", in: dir)
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?.first?.labelStringKey, "LabelContinueListening")
        XCTAssertEqual(loaded?.first?.entities?.first?.id, "li_1")
    }

    func testOtherScopeNeverReadsAnotherAccountsFile() throws {
        HomeShelvesCache.save(try shelves(), scope: "scopeA", libraryId: "lib1", in: dir)
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeB", libraryId: "lib1", in: dir))
        XCTAssertNotEqual(HomeShelvesCache.fileName(forScope: "scopeA"), HomeShelvesCache.fileName(forScope: "scopeB"))
    }

    func testScopeStoredInsideFileIsRechecked() throws {
        // A file for scope A copied under scope B's name must still be refused.
        let data = try XCTUnwrap(HomeShelvesCache.encode(try shelves(), scope: "scopeA", libraryId: "lib1"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: HomeShelvesCache.fileURL(forScope: "scopeB", in: dir))
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeB", libraryId: "lib1", in: dir))
    }

    func testDifferentLibraryIsIgnored() throws {
        HomeShelvesCache.save(try shelves(), scope: "scopeA", libraryId: "lib1", in: dir)
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeA", libraryId: "lib2", in: dir))
    }

    func testVersionMismatchIsIgnoredAndNotDeleted() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = HomeShelvesCache.fileURL(forScope: "scopeA", in: dir)
        let future = #"{"version":\#(HomeShelvesCache.currentVersion + 1),"somethingNew":true}"#
        try Data(future.utf8).write(to: url)
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeA", libraryId: "lib1", in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDecodeFailureDeletesTheFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = HomeShelvesCache.fileURL(forScope: "scopeA", in: dir)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeA", libraryId: "lib1", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Right version, wrong shape: also corrupt.
        try Data(#"{"version":\#(HomeShelvesCache.currentVersion),"scope":5}"#.utf8).write(to: url)
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeA", libraryId: "lib1", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveAllClearsEveryScope() throws {
        HomeShelvesCache.save(try shelves(), scope: "scopeA", libraryId: "lib1", in: dir)
        HomeShelvesCache.save(try shelves(), scope: "scopeB", libraryId: "lib1", in: dir)
        HomeShelvesCache.removeAll(in: dir)
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeA", libraryId: "lib1", in: dir))
        XCTAssertNil(HomeShelvesCache.load(scope: "scopeB", libraryId: "lib1", in: dir))
    }

    func testUnscopedIsNeverCached() throws {
        HomeShelvesCache.save(try shelves(), scope: "unscoped", libraryId: "lib1", in: dir)
        XCTAssertNil(HomeShelvesCache.load(scope: "unscoped", libraryId: "lib1", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCacheLivesInTheCachesDirectory() {
        XCTAssertTrue(HomeShelvesCache.directory.path.contains("/Library/Caches/"))
    }

    // MARK: Failure copy

    func testFailureKindSplitsOfflineUnreachableOther() {
        XCTAssertEqual(LibraryViewModel.loadFailureKind(reachability: .offline, error: URLError(.timedOut)), .offline)
        XCTAssertEqual(LibraryViewModel.loadFailureKind(reachability: .ok, error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(LibraryViewModel.loadFailureKind(reachability: .ok, error: URLError(.cannotConnectToHost)), .serverUnreachable)
        XCTAssertEqual(LibraryViewModel.loadFailureKind(reachability: .serverUnreachable, error: URLError(.userAuthenticationRequired)), .serverUnreachable)
        XCTAssertEqual(LibraryViewModel.loadFailureKind(reachability: .ok, error: URLError(.userAuthenticationRequired)), .other)
    }

    func testFailureMessagesNeverCarrySystemText() {
        for kind in [LibraryViewModel.LoadFailureKind.offline, .serverUnreachable, .other] {
            let text = LibraryViewModel.loadFailureMessage(kind)
            XCTAssertFalse(text.contains("Failed to"), text)
            XCTAssertFalse(text.contains("%@"), text)
        }
    }

    // MARK: Spotlight change check

    func testSpotlightSignatureIsStableAndChangesWithContent() throws {
        func item(_ id: String) throws -> ShelfHead.LibraryItem {
            try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(#"{"id":"\#(id)"}"#.utf8))
        }
        let a = try [item("1"), item("2")]
        XCTAssertEqual(SpotlightIndexer.signature(for: a), SpotlightIndexer.signature(for: try [item("1"), item("2")]))
        XCTAssertNotEqual(SpotlightIndexer.signature(for: a), SpotlightIndexer.signature(for: try [item("2"), item("1")]))
        XCTAssertNotEqual(SpotlightIndexer.signature(for: a), SpotlightIndexer.signature(for: try [item("1")]))
    }

    func testSpotlightShouldIndexOnlyWhenSignatureDiffers() {
        XCTAssertTrue(SpotlightIndexer.shouldIndex(newSignature: "x", lastSignature: nil))
        XCTAssertTrue(SpotlightIndexer.shouldIndex(newSignature: "x", lastSignature: "y"))
        XCTAssertFalse(SpotlightIndexer.shouldIndex(newSignature: "x", lastSignature: "x"))
    }

    // MARK: Launch summary

    func testLaunchSummaryLineListsMilestonesInOrder() {
        let line = LaunchTrace.summaryLine(["firstPlayable": 900, "appInitEnd": 120, "splashDismissed": 400, "homeFirstShelves": 650])
        XCTAssertEqual(line, "Launch (ms since process start): appInitEnd=120ms splashDismissed=400ms homeFirstShelves=650ms firstPlayable=900ms")
    }
}
