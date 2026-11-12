import XCTest
@testable import ShelfHead

/// Pins the pure bulk-download planner (library multi-select, Wave 1 step 4).
final class BulkDownloadPlanTests: XCTestCase {
    private func item(_ id: String, size: Int? = 1_000_000, podcast: Bool = false) -> ShelfHead.LibraryItem {
        let json = """
        {"id":"\(id)","mediaType":"\(podcast ? "podcast" : "book")"\(size.map { ",\"size\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }

    private func plan(_ items: [ShelfHead.LibraryItem], downloaded: Set<String> = [], downloading: Set<String> = [],
                      wifiOnly: Bool = false, onWiFi: Bool = true, free: Int64? = 100_000_000_000,
                      cap: Int = 50) -> BulkDownloadPlan {
        DownloadManager.bulkDownloadPlan(items: items, isDownloaded: { downloaded.contains($0) },
                                         isDownloading: { downloading.contains($0) }, wifiOnly: wifiOnly,
                                         onWiFi: onWiFi, freeBytes: free, cap: cap)
    }

    func testSkipsDownloadedAndInFlight() {
        let p = plan([item("a"), item("b"), item("c")], downloaded: ["a"], downloading: ["b"])
        XCTAssertEqual(p.toDownload.map(\.id), ["c"])
        XCTAssertEqual(p.skipped.map(\.reason), [.alreadyDownloaded, .inFlight])
        XCTAssertNil(p.refusal)
    }

    func testPodcastsExcluded() {
        let p = plan([item("a"), item("p", podcast: true)])
        XCTAssertEqual(p.toDownload.map(\.id), ["a"])
        XCTAssertEqual(p.skipped, [.init(itemId: "p", reason: .podcast)])
    }

    func testSizeSumCountsUnknownSeparately() {
        let p = plan([item("a", size: 2_000), item("b", size: nil), item("c", size: 3_000)])
        XCTAssertEqual(p.totalKnownBytes, 5_000)
        XCTAssertEqual(p.unknownSizeCount, 1)
    }

    func testInsufficientSpaceRefuses() {
        let p = plan([item("a", size: 600_000_000), item("b", size: 600_000_000)], free: 1_000_000_000)
        XCTAssertEqual(p.refusal, .insufficientSpace)
        XCTAssertEqual(plan([item("a", size: 600_000_000)], free: 1_000_000_000).refusal, nil)
    }

    func testUnknownFreeSpaceFailsOpen() {
        XCTAssertNil(plan([item("a", size: 600_000_000)], free: nil).refusal)
    }

    /// D1 (review, 12 Nov 2026): Wi-Fi-only off Wi-Fi no longer refuses; the books queue and wait.
    func testWifiOnlyOffWifiQueuesAndWaits() {
        let off = plan([item("a")], wifiOnly: true, onWiFi: false)
        XCTAssertNil(off.refusal)
        XCTAssertEqual(off.toDownload.map(\.id), ["a"])
        XCTAssertTrue(off.waitsForWiFi)
        XCTAssertFalse(plan([item("a")], wifiOnly: true, onWiFi: true).waitsForWiFi)
        XCTAssertFalse(plan([item("a")], wifiOnly: false, onWiFi: false).waitsForWiFi)
    }

    func testCapQueuesFirstNAndReportsRestOverCap() {
        let items = (0..<55).map { item("b\($0)") }
        let p = plan(items)
        XCTAssertEqual(p.toDownload.count, 50)
        XCTAssertEqual(p.overCapCount, 5)
        XCTAssertEqual(p.toDownload.last?.id, "b49")
    }

    func testConfirmationAboveFive() {
        XCTAssertFalse(plan((0..<5).map { item("b\($0)") }).needsConfirmation)
        XCTAssertTrue(plan((0..<6).map { item("b\($0)") }).needsConfirmation)
    }

    func testNothingToDownloadRefuses() {
        XCTAssertEqual(plan([item("a")], downloaded: ["a"]).refusal, .nothingToDownload)
    }

    func testDuplicatesCollapsed() {
        XCTAssertEqual(plan([item("a"), item("a")]).toDownload.count, 1)
    }

    func testSummaryWording() {
        let p = plan((0..<12).map { item("b\($0)", size: 400_000_000) }, wifiOnly: true)
        XCTAssertTrue(p.summary.hasPrefix("Download 12 books? About "))
        XCTAssertTrue(p.summary.contains("Respects your Wi-Fi-only setting."))
    }
}
