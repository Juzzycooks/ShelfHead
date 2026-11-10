import XCTest
@testable import ShelfHead_Watch

/// Batch 362: the complication's tap target. The widget extension spells the URL itself (it can't
/// import the app), so this pins the spelling it uses.
final class WatchDeepLinkTests: XCTestCase {
    func testComplicationURLOpensNowPlaying() {
        XCTAssertEqual(WatchDeepLink(url: URL(string: "shelfhead://nowplaying")!), .nowPlaying)
        XCTAssertEqual(WatchDeepLink(url: WatchDeepLink.nowPlayingURL), .nowPlaying)
        XCTAssertEqual(WatchDeepLink(url: URL(string: "ShelfHead://NowPlaying")!), .nowPlaying)
    }

    func testOtherURLsAreIgnored() {
        XCTAssertNil(WatchDeepLink(url: URL(string: "shelfhead://library")!))
        XCTAssertNil(WatchDeepLink(url: URL(string: "https://nowplaying")!))
        XCTAssertNil(WatchDeepLink(url: URL(string: "shelfhead:")!))
    }
}
