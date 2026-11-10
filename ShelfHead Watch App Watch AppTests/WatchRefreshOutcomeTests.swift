import XCTest
@testable import ShelfHead_Watch

/// Review Medium 35 (30 October 2026): only 401/403 is a rejected refresh.
final class WatchRefreshOutcomeTests: XCTestCase {
    func testRejectedOnlyFor401And403() {
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: 401, transportError: nil, decodedToken: false), .rejected)
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: 403, transportError: nil, decodedToken: false), .rejected)
    }

    func testTransientFailuresCouldNotComplete() {
        for code in [429, 500, 502, 503, 404] {
            XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: code, transportError: nil, decodedToken: false), .couldNotComplete, "\(code)")
        }
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: nil, transportError: URLError(.timedOut), decodedToken: false), .couldNotComplete)
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: nil, transportError: nil, decodedToken: false), .couldNotComplete)
    }

    func testOKWithAndWithoutToken() {
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: 200, transportError: nil, decodedToken: true), .refreshed)
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: 200, transportError: nil, decodedToken: false), .couldNotComplete)
    }
}
