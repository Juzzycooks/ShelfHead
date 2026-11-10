import XCTest
@testable import ShelfHead

/// Polish pass (J4: DL-1, DL-2, DL-3, DL-5, DL-6, DL-7): the pure decision functions behind
/// the downloads/offline fixes.
final class PolishDownloadsTests: XCTestCase {

    // MARK: DL-1 row status

    func testStatusPausedWinsOverEverything() {
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: true, wifiOnly: true, isConnected: false, isOnWiFi: false), .paused)
    }

    func testStatusWaitingForWiFiOnCellularWithWiFiOnly() {
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: true, isConnected: true, isOnWiFi: false), .waitingForWiFi)
    }

    func testStatusWaitingForNetworkWhenOffline() {
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: true, isConnected: false, isOnWiFi: false), .waitingForNetwork)
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: false, isConnected: false, isOnWiFi: false), .waitingForNetwork)
    }

    func testStatusDownloadingWhenNothingBlocks() {
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: true, isConnected: true, isOnWiFi: true), .downloading)
        XCTAssertEqual(ActiveDownloadStatus.choose(isPaused: false, wifiOnly: false, isConnected: true, isOnWiFi: false), .downloading)
    }

    // MARK: DL-3 auto-download gates

    func testAutoDownloadDeferralOrderAndClear() {
        typealias P = DownloadPolicyStatus
        XCTAssertEqual(P.autoDownloadDeferral(wifiOnly: true, onWiFi: false, chargingOnly: true, isCharging: false), .wifi)
        XCTAssertEqual(P.autoDownloadDeferral(wifiOnly: true, onWiFi: true, chargingOnly: true, isCharging: false), .power)
        XCTAssertNil(P.autoDownloadDeferral(wifiOnly: true, onWiFi: true, chargingOnly: true, isCharging: true))
        XCTAssertNil(P.autoDownloadDeferral(wifiOnly: false, onWiFi: false, chargingOnly: false, isCharging: false))
    }

    // MARK: DL-2 bytes / ETA

    func testExpectedTotalIsExactOnceEveryTrackReported() {
        XCTAssertEqual(DownloadPolicyStatus.expectedTotalBytes(knownExpectedSum: 900, tracksReported: 3, totalTracks: 3, written: 100, progress: 0.1), 900)
    }

    func testExpectedTotalExtrapolatesAndNeedsSomeProgress() {
        XCTAssertEqual(DownloadPolicyStatus.expectedTotalBytes(knownExpectedSum: 300, tracksReported: 1, totalTracks: 3, written: 100, progress: 0.1), 1_000)
        XCTAssertEqual(DownloadPolicyStatus.expectedTotalBytes(knownExpectedSum: 300, tracksReported: 1, totalTracks: 3, written: 100, progress: 0.001), 0)
    }

    func testETAOnlyWhenStable() {
        typealias P = DownloadPolicyStatus
        XCTAssertNil(P.etaSeconds(remainingBytes: 1_000_000_000, bytesPerSecond: 5_000_000, samples: 2))
        XCTAssertEqual(P.etaSeconds(remainingBytes: 1_000_000_000, bytesPerSecond: 5_000_000, samples: 5), 200)
        XCTAssertNil(P.etaSeconds(remainingBytes: 0, bytesPerSecond: 5_000_000, samples: 9))
        XCTAssertNil(P.etaSeconds(remainingBytes: 1_000_000_000, bytesPerSecond: 10, samples: 9))
        // Implausibly long (> 48 h) is dropped rather than shown.
        XCTAssertNil(P.etaSeconds(remainingBytes: 100_000_000_000, bytesPerSecond: 100_000, samples: 9))
    }

    func testSmoothedSpeedSeedsThenBlends() {
        XCTAssertEqual(DownloadPolicyStatus.smoothedSpeed(previous: 0, samples: 0, instant: 1_000), 1_000)
        XCTAssertEqual(DownloadPolicyStatus.smoothedSpeed(previous: 1_000, samples: 1, instant: 2_000), 1_300, accuracy: 0.001)
    }

    func testDownloadTaskRecordNeedsFiveSecondsOfSamplesBeforeAnETA() {
        let task = DownloadTask(itemId: "a", title: "A")
        let t0 = Date()
        task.record(written: 0, expected: 1_000_000_000, at: t0)
        for i in 1...4 {
            task.record(written: Int64(i) * 10_000_000, expected: 1_000_000_000, at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertNil(task.etaSeconds, "four samples is not stable yet")
        task.record(written: 50_000_000, expected: 1_000_000_000, at: t0.addingTimeInterval(5))
        XCTAssertNotNil(task.etaSeconds)
        XCTAssertEqual(task.bytesWritten, 50_000_000)
    }

    func testProgressDetailCopy() {
        XCTAssertNil(DownloadProgressCopy.detail(written: 0, expected: 1_000, etaSeconds: nil))
        XCTAssertNil(DownloadProgressCopy.detail(written: 10, expected: 0, etaSeconds: nil))
        let plain = DownloadProgressCopy.detail(written: 120_000_000, expected: 1_400_000_000, etaSeconds: nil)
        XCTAssertNotNil(plain)
        XCTAssertFalse(plain!.contains("\u{00B7}"))
        let withETA = DownloadProgressCopy.detail(written: 120_000_000, expected: 1_400_000_000, etaSeconds: 240)
        XCTAssertTrue(withETA!.contains("\u{00B7}"))
    }

    func testETATextBuckets() {
        XCTAssertNotNil(DownloadProgressCopy.etaText(seconds: 30))
        XCTAssertTrue(DownloadProgressCopy.etaText(seconds: 61)!.contains("2"))   // rounds up to 2 min
        XCTAssertTrue(DownloadProgressCopy.etaText(seconds: 4_800)!.contains("1"))
        XCTAssertNil(DownloadProgressCopy.etaText(seconds: -1))
    }

    // MARK: DL-5 failure copy

    func testHTTPStatusCopyNeverShowsCodes() {
        for code in [400, 401, 403, 404, 410, 429, 500, 502, 503, 504, 418] {
            let text = DownloadFailureCopy.message(forHTTPStatus: code)
            XCTAssertFalse(text.contains("HTTP"), "\(code)")
            XCTAssertFalse(text.contains("\(code)"), "\(code)")
        }
        XCTAssertEqual(DownloadFailureCopy.message(forHTTPStatus: 404), DownloadFailureCopy.notFound)
        XCTAssertEqual(DownloadFailureCopy.message(forHTTPStatus: 403), DownloadFailureCopy.signInAgain)
        XCTAssertEqual(DownloadFailureCopy.message(forHTTPStatus: 503), DownloadFailureCopy.serverBusy)
    }

    func testOutOfSpaceDetection() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertTrue(DownloadFailureCopy.isOutOfSpace(cocoa))
        XCTAssertTrue(DownloadFailureCopy.isOutOfSpace(posix))
        XCTAssertTrue(DownloadFailureCopy.isOutOfSpace(wrapped))
        XCTAssertFalse(DownloadFailureCopy.isOutOfSpace(URLError(.timedOut)))
        XCTAssertEqual(DownloadFailureCopy.message(for: cocoa), DownloadFailureCopy.outOfSpace)
        XCTAssertEqual(DownloadFailureCopy.message(for: URLError(.networkConnectionLost)), DownloadFailureCopy.connection)
        XCTAssertEqual(DownloadFailureCopy.message(for: NSError(domain: "x", code: 1)), DownloadFailureCopy.generic)
    }

    // MARK: DL-6 snooze

    func testSnoozedConflictStaysQuietUntilEitherSideChanges() {
        let base = ProgressConflict.Stamp(localTime: 100, serverTime: 900, localLastUpdate: 5, serverLastUpdate: 4)
        XCTAssertTrue(ProgressConflict.shouldRaise(snoozed: nil, current: base))
        XCTAssertFalse(ProgressConflict.shouldRaise(snoozed: base, current: base))
        XCTAssertTrue(ProgressConflict.shouldRaise(snoozed: base, current: .init(localTime: 101, serverTime: 900, localLastUpdate: 5, serverLastUpdate: 4)))
        XCTAssertTrue(ProgressConflict.shouldRaise(snoozed: base, current: .init(localTime: 100, serverTime: 900, localLastUpdate: 5, serverLastUpdate: 6)))
    }

    func testConflictStampTreatsMissingTimestampsAsZero() {
        let c = ProgressConflict(itemId: "i", title: "T", localTime: 1, serverTime: 2, duration: 3)
        XCTAssertEqual(c.stamp, ProgressConflict.Stamp(localTime: 1, serverTime: 2, localLastUpdate: 0, serverLastUpdate: 0))
    }

    func testLastPlayedSummary() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(ProgressConflict.lastPlayedSummary(localLastUpdate: nil, serverLastUpdate: 0, now: now))
        let both = ProgressConflict.lastPlayedSummary(localLastUpdate: (2_000_000 - 7_200) * 1000,
                                                      serverLastUpdate: (2_000_000 - 86_400) * 1000, now: now)
        XCTAssertNotNil(both)
        XCTAssertTrue(both!.contains("\u{00B7}"))
        let one = ProgressConflict.lastPlayedSummary(localLastUpdate: (2_000_000 - 7_200) * 1000, serverLastUpdate: nil, now: now)
        XCTAssertFalse(one!.contains("\u{00B7}"))
    }

    // MARK: DL-7 banner link

    func testDownloadsLinkOnlyOfflineWithDownloads() {
        XCTAssertTrue(ConnectivityCopy.showsDownloadsLink(status: .offline, hasDownloads: true))
        XCTAssertFalse(ConnectivityCopy.showsDownloadsLink(status: .offline, hasDownloads: false))
        XCTAssertFalse(ConnectivityCopy.showsDownloadsLink(status: .serverUnreachable, hasDownloads: true))
        XCTAssertFalse(ConnectivityCopy.showsDownloadsLink(status: .ok, hasDownloads: true))
    }
}
