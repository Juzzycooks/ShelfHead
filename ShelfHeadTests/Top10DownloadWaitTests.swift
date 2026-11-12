import XCTest
@testable import ShelfHead

/// D1 (REVIEW 2026-11-11): a manual download started without Wi-Fi is accepted and waits,
/// and "Download Now" lifts Wi-Fi-only for one book only.
final class Top10DownloadWaitTests: XCTestCase {
    func testWaitsOnlyWhenWiFiOnlyAndOffWiFi() {
        XCTAssertTrue(DownloadPolicyStatus.waitsForWiFi(wifiOnly: true, onWiFi: false, cellularOverridden: false))
        XCTAssertFalse(DownloadPolicyStatus.waitsForWiFi(wifiOnly: true, onWiFi: true, cellularOverridden: false))
        XCTAssertFalse(DownloadPolicyStatus.waitsForWiFi(wifiOnly: false, onWiFi: false, cellularOverridden: false))
    }

    func testOverrideStopsWaiting() {
        XCTAssertFalse(DownloadPolicyStatus.waitsForWiFi(wifiOnly: true, onWiFi: false, cellularOverridden: true))
    }

    func testCellularAllowedOnlyWhenSettingOffOrOverridden() {
        XCTAssertFalse(DownloadPolicyStatus.allowsCellularAccess(wifiOnly: true, cellularOverridden: false))
        XCTAssertTrue(DownloadPolicyStatus.allowsCellularAccess(wifiOnly: true, cellularOverridden: true))
        XCTAssertTrue(DownloadPolicyStatus.allowsCellularAccess(wifiOnly: false, cellularOverridden: false))
    }

    func testRowStatusIsWaitingFromTheStartAndDownloadingAfterOverride() {
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: true, isConnected: true, isOnWiFi: false), .waitingForWiFi)
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: true, isConnected: true, isOnWiFi: false,
                                                   cellularOverridden: true), .downloading)
        // Offline still outranks, even with an override.
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: true, isConnected: false, isOnWiFi: false,
                                                   cellularOverridden: true), .waitingForNetwork)
    }

    func testBulkPlanIsAcceptedNotRefusedWithoutWiFi() {
        let plan = DownloadManager.bulkDownloadPlan(items: [], isDownloaded: { _ in false }, isDownloading: { _ in false },
                                                    wifiOnly: true, onWiFi: false, freeBytes: nil)
        // Empty selection is still "nothing to download", never a Wi-Fi refusal.
        XCTAssertEqual(plan.refusal, .nothingToDownload)
        XCTAssertTrue(plan.waitsForWiFi)
        let onWiFi = DownloadManager.bulkDownloadPlan(items: [], isDownloaded: { _ in false }, isDownloading: { _ in false },
                                                      wifiOnly: true, onWiFi: true, freeBytes: nil)
        XCTAssertFalse(onWiFi.waitsForWiFi)
    }

    func testCopy() {
        XCTAssertTrue(DownloadPolicyStatus.willDownloadOnWiFiMessage.contains("\u{2011}"))
        XCTAssertTrue(DownloadPolicyStatus.downloadNowTitle(bytes: 412_000_000).contains("("))
        XCTAssertFalse(DownloadPolicyStatus.downloadNowTitle(bytes: 0).contains("("))
    }
}
