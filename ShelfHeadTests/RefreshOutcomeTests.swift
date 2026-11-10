import XCTest
@testable import ShelfHead

/// Pins `AudiobookshelfAPI.classifyRefreshResult` (review High 6, 30 October 2026): only a
/// 401/403 from `/auth/refresh` is a rejected session; anything that merely failed to
/// complete must never be reported as one.
final class RefreshOutcomeTests: XCTestCase {
    private func classify(_ status: Int?, error: Error? = nil, decoded: Bool = false) -> RefreshOutcome {
        AudiobookshelfAPI.classifyRefreshResult(statusCode: status, transportError: error, decodedToken: decoded)
    }

    func testDecodable200IsRefreshed() {
        XCTAssertEqual(classify(200, decoded: true), .refreshed)
    }

    func testUndecodable200CouldNotComplete() {
        XCTAssertEqual(classify(200, decoded: false), .couldNotComplete)
    }

    func test401And403AreRejected() {
        XCTAssertEqual(classify(401), .rejected)
        XCTAssertEqual(classify(403), .rejected)
    }

    func testServerAndThrottleStatusesCouldNotComplete() {
        for status in [429, 500, 502, 503, 404, 204] {
            XCTAssertEqual(classify(status), .couldNotComplete, "status \(status)")
        }
    }

    func testTransportErrorsCouldNotComplete() {
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .networkConnectionLost] {
            XCTAssertEqual(classify(nil, error: URLError(code)), .couldNotComplete)
        }
    }

    func testMissingHTTPResponseCouldNotComplete() {
        XCTAssertEqual(classify(nil), .couldNotComplete)
    }
}
