import XCTest
@testable import ShelfHead_Watch

/// Polish pass (J6): the Watch in-progress shelf cache (WA-3), the progress-sync status and
/// connectivity edge (WA-4/WA-5), and the download failure copy.
@MainActor
final class PolishWatchTests: XCTestCase {
    private var tempFile: URL!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("PolishWatchTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile)
        super.tearDown()
    }

    private func item(id: String, currentTime: Double?, lastUpdate: Int?, finished: Bool = false) throws -> WatchLibraryItem {
        var progress = "\"id\":\"p-\(id)\",\"libraryItemId\":\"\(id)\",\"isFinished\":\(finished)"
        if let currentTime { progress += ",\"currentTime\":\(currentTime),\"progress\":0.5" }
        if let lastUpdate { progress += ",\"lastUpdate\":\(lastUpdate)" }
        let json = """
        {"id":"\(id)","libraryId":"lib","mediaType":"book",
         "media":{"metadata":{"title":"Title \(id)","authorName":"Author"},"duration":1000,
                  "chapters":[{"id":0,"start":0,"end":500,"title":"One"}]},
         "userMediaProgress":{\(progress)}}
        """
        return try JSONDecoder().decode(WatchLibraryItem.self, from: Data(json.utf8))
    }

    // MARK: WA-3 cache rules

    func testCacheLivesInCachesDirectory() {
        XCTAssertTrue(WatchInProgressCache.defaultFileURL().path.contains("/Caches/"))
    }

    func testRoundTripKeepsTheShelfFieldsAndDropsChapters() throws {
        WatchInProgressCache.save([try item(id: "a", currentTime: 300, lastUpdate: 5000)], scope: "https://abs.example", to: tempFile)
        let loaded = try XCTUnwrap(WatchInProgressCache.load(scope: "https://abs.example", from: tempFile))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "a")
        XCTAssertEqual(loaded[0].media?.metadata?.title, "Title a")
        XCTAssertEqual(loaded[0].mediaProgress?.currentTime, 300)
        XCTAssertNil(loaded[0].media?.chapters, "chapter lists are the bulk of an item and the shelf doesn't need them")
    }

    func testAnotherAccountScopeCannotReadTheCache() throws {
        WatchInProgressCache.save([try item(id: "a", currentTime: 300, lastUpdate: 5000)], scope: "https://one.example", to: tempFile)
        XCTAssertNil(WatchInProgressCache.load(scope: "https://two.example", from: tempFile))
        XCTAssertNil(WatchInProgressCache.load(scope: "", from: tempFile), "no session means no cache")
    }

    func testVersionMismatchIsIgnored() throws {
        let file = WatchInProgressCacheFile(version: WatchInProgressCache.version + 1, scope: "s", savedAt: Date(), items: [])
        XCTAssertFalse(WatchInProgressCache.isUsable(file, scope: "s"))
        let current = WatchInProgressCacheFile(version: WatchInProgressCache.version, scope: "s", savedAt: Date(), items: [])
        XCTAssertTrue(WatchInProgressCache.isUsable(current, scope: "s"))
    }

    func testDecodeFailureDeletesTheFileAndCarriesOn() throws {
        try Data("not json".utf8).write(to: tempFile)
        XCTAssertNil(WatchInProgressCache.load(scope: "s", from: tempFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    func testClearRemovesTheFile() throws {
        WatchInProgressCache.save([try item(id: "a", currentTime: 1, lastUpdate: 1)], scope: "s", to: tempFile)
        WatchInProgressCache.clear(at: tempFile)
        XCTAssertNil(WatchInProgressCache.load(scope: "s", from: tempFile))
    }

    func testMissingTimestampStaysUnknownNotZero() throws {
        let items = [try item(id: "a", currentTime: 300, lastUpdate: nil)]
        let reading = try XCTUnwrap(WatchInProgressCache.reading(itemId: "a", in: items))
        XCTAssertEqual(reading.currentTime, 300)
        XCTAssertNil(reading.lastUpdateMs)
    }

    func testFinishedOrPositionlessBooksOfferNoResumeReading() throws {
        let items = [try item(id: "done", currentTime: 900, lastUpdate: 1, finished: true),
                     try item(id: "none", currentTime: nil, lastUpdate: 1)]
        XCTAssertNil(WatchInProgressCache.reading(itemId: "done", in: items))
        XCTAssertNil(WatchInProgressCache.reading(itemId: "none", in: items))
        XCTAssertNil(WatchInProgressCache.reading(itemId: "absent", in: items))
    }

    /// The cached position is only an offline floor: when the server answered, it is not offered.
    func testCachedReadingIsOnlyOfferedWhenTheServerDidNotAnswer() {
        let cached = WatchServerProgress(currentTime: 900, lastUpdateMs: 1_000)
        let fresh = WatchServerProgress(currentTime: 100, lastUpdateMs: 2_000)
        XCTAssertNil(WatchInProgressCache.resumeCandidate(fresh: fresh, cached: cached))
        XCTAssertEqual(WatchInProgressCache.resumeCandidate(fresh: nil, cached: cached), cached)
        // And through the real picker with a fresh reading, the cache can't beat it.
        let best = WatchServerProgressPicker.newest([fresh, WatchInProgressCache.resumeCandidate(fresh: fresh, cached: cached)])
        XCTAssertEqual(best, fresh)
    }

    /// Offline, with nothing fresher, the resume position is never behind the cached one.
    func testOfflineResumeIsNeverBehindTheCachedReading() {
        let cached = WatchServerProgress(currentTime: 900, lastUpdateMs: 1_000)
        let best = WatchServerProgressPicker.newest([nil, nil, nil, cached])
        let position = StandaloneAudioEngine.resumePosition(
            serverTime: best?.currentTime, serverLastUpdateMs: best?.lastUpdateMs,
            localTime: 400, localLastUpdateMs: nil, duration: 5_000)
        XCTAssertEqual(position, 900, "unknown local clock: the further-ahead position wins")
    }

    /// The cache never touches the pending-progress queue, so it can't be pushed as new listening.
    func testSavingAndLoadingTheCacheNeverQueuesProgress() async throws {
        let queueFile = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: queueFile) }
        let queue = WatchPendingProgressQueue(fileURL: queueFile)
        WatchInProgressCache.save([try item(id: "a", currentTime: 300, lastUpdate: 5000)], scope: "s", to: tempFile)
        _ = WatchInProgressCache.load(scope: "s", from: tempFile)
        let entries = await queue.allEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: WA-4 / WA-5

    func testSyncStatusTextDistinguishesSyncedOneAndMany() {
        let synced = WatchProgressSyncCoordinator.statusText(pendingCount: 0)
        let one = WatchProgressSyncCoordinator.statusText(pendingCount: 1)
        let many = WatchProgressSyncCoordinator.statusText(pendingCount: 3)
        XCTAssertEqual(Set([synced, one, many]).count, 3)
        XCTAssertTrue(many.contains("3"))
    }

    func testFlushOnlyOnALossToRegainEdge() {
        XCTAssertFalse(WatchProgressSyncCoordinator.shouldFlushOnPathChange(previouslySatisfied: nil, nowSatisfied: true), "first report just records")
        XCTAssertFalse(WatchProgressSyncCoordinator.shouldFlushOnPathChange(previouslySatisfied: true, nowSatisfied: true))
        XCTAssertFalse(WatchProgressSyncCoordinator.shouldFlushOnPathChange(previouslySatisfied: true, nowSatisfied: false))
        XCTAssertTrue(WatchProgressSyncCoordinator.shouldFlushOnPathChange(previouslySatisfied: false, nowSatisfied: true))
    }

    // MARK: Download failure copy

    func testTransferFailureCopyHidesErrorDetail() {
        let offline = WatchLocalDownloadManager.transferFailureReason(for: URLError(.notConnectedToInternet))
        let unreachable = WatchLocalDownloadManager.transferFailureReason(for: URLError(.timedOut))
        let other = WatchLocalDownloadManager.transferFailureReason(for: URLError(.badServerResponse))
        XCTAssertEqual(Set([offline, unreachable, other]).count, 3)
        for text in [offline, unreachable, other, WatchLocalDownloadManager.rejectedDownloadReason()] {
            XCTAssertFalse(text.contains("NSURLErrorDomain"))
            XCTAssertFalse(text.contains("HTTP"))
            XCTAssertFalse(text.contains("-10"))
        }
    }
}
