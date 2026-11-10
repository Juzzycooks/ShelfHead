import XCTest
@testable import ShelfHead

/// Review finding High 1/2 (30 October 2026): a headless launch (background URLSession
/// relaunch, BG refresh) must resolve the signed-in account's download scope before
/// `AuthStore` is seeded, or finished tracks are cancelled as foreign.
final class HeadlessScopeTests: XCTestCase {
    func testLiveScopeWins() {
        XCTAssertEqual(DownloadManager.resolveScopeKey(liveKey: "live", lastActiveKey: "old"), "live")
        XCTAssertEqual(DownloadManager.resolveScopeKey(liveKey: "live", lastActiveKey: nil), "live")
    }

    func testLastActiveScopeStandsInBeforeAuthStoreIsSeeded() {
        XCTAssertEqual(DownloadManager.resolveScopeKey(liveKey: nil, lastActiveKey: "old"), "old")
    }

    func testNoAccountKnownIsUnscoped() {
        XCTAssertEqual(DownloadManager.resolveScopeKey(liveKey: nil, lastActiveKey: nil), "unscoped")
        XCTAssertEqual(DownloadManager.resolveScopeKey(liveKey: nil, lastActiveKey: ""), "unscoped")
    }
}
