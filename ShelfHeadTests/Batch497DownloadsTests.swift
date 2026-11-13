import XCTest
import UIKit
@testable import ShelfHead

/// Batch 497: the download queue's battery trigger and the Settings search entry for Storage.
final class Batch497DownloadsTests: XCTestCase {
    func testPlugInWithChargingOnlyAdvances() {
        XCTAssertTrue(DownloadQueuePlan.batteryChangeWarrantsAdvance(from: .unplugged, to: .charging, chargingOnly: true))
        XCTAssertTrue(DownloadQueuePlan.batteryChangeWarrantsAdvance(from: .unknown, to: .full, chargingOnly: true))
    }

    func testOtherChangesDoNotAdvance() {
        // Charging to full is no change in policy; unplugging only closes the gate.
        XCTAssertFalse(DownloadQueuePlan.batteryChangeWarrantsAdvance(from: .charging, to: .full, chargingOnly: true))
        XCTAssertFalse(DownloadQueuePlan.batteryChangeWarrantsAdvance(from: .charging, to: .unplugged, chargingOnly: true))
        XCTAssertFalse(DownloadQueuePlan.batteryChangeWarrantsAdvance(from: .unplugged, to: .unknown, chargingOnly: true))
    }

    func testNoAdvanceWhenChargingOnlyIsOff() {
        XCTAssertFalse(DownloadQueuePlan.batteryChangeWarrantsAdvance(from: .unplugged, to: .charging, chargingOnly: false))
    }

    func testStorageSearchFindsTheWordsOnScreen() {
        let entry = SettingsSearchIndex.entries(includesClassicLockScreen: true).first { $0.row == SettingsRow.storage }
        XCTAssertNotNil(entry)
        let words = Set((entry?.keywords ?? []).map { $0.lowercased() })
        for term in ["free space", "cover cache", "transcripts", "ebooks", "other accounts"] {
            XCTAssertTrue(words.contains(term), term)
        }
    }
}
