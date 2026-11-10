import XCTest
@testable import ShelfHead

// Batch 472 review fixes (30 October 2026): Medium 25/26 and the auto-download Low.
final class DownloadReviewFixesTests: XCTestCase {

    // MARK: Medium 25 — retry versus fail

    func testTransientStatusesAreRetriedWithBackoff() {
        for code in [429, 500, 502, 503, 504] {
            XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: code, attempts: 0, retryAfter: nil), .retry(delay: 2))
        }
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 502, attempts: 1, retryAfter: nil), .retry(delay: 4))
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 502, attempts: 2, retryAfter: nil), .retry(delay: 8))
    }

    func testRetriesAreBounded() {
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 503, attempts: 3, retryAfter: nil), .fail)
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 503, attempts: 9, retryAfter: nil), .fail)
    }

    func testPermanentStatusesFailImmediately() {
        for code in [400, 403, 404, 410, 501] {
            XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: code, attempts: 0, retryAfter: nil), .fail)
        }
    }

    func testRetryAfterLengthensButIsCapped() {
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 429, attempts: 0, retryAfter: 20), .retry(delay: 20))
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 429, attempts: 0, retryAfter: 1), .retry(delay: 2))
        XCTAssertEqual(DownloadManager.httpStatusRetryDecision(statusCode: 429, attempts: 0, retryAfter: 9999), .retry(delay: 60))
    }

    func testPartialTracksAreKeptOnlyWhenSomeFinished() {
        XCTAssertFalse(DownloadManager.shouldKeepPartialTracks(completedTracks: 0))
        XCTAssertTrue(DownloadManager.shouldKeepPartialTracks(completedTracks: 1))
        XCTAssertTrue(DownloadManager.shouldKeepPartialTracks(completedTracks: 19))
    }

    // MARK: Medium 26 — rebuilt track URLs

    func testSanitizedTrackURLKeepsAPlainURL() {
        let url = URL(string: "https://abs.example.com/api/items/abc/file/123/download")!
        XCTAssertEqual(DownloadManager.sanitizedTrackURL(url), url)
    }

    func testSanitizedTrackURLStripsTokenQuery() {
        let url = URL(string: "https://abs.example.com/api/items/abc/file/123/download?token=secret&x=1")!
        XCTAssertEqual(DownloadManager.sanitizedTrackURL(url)?.absoluteString,
                       "https://abs.example.com/api/items/abc/file/123/download?x=1")
        let only = URL(string: "https://abs.example.com/a?token=secret")!
        XCTAssertEqual(DownloadManager.sanitizedTrackURL(only)?.absoluteString, "https://abs.example.com/a")
    }

    func testSanitizedTrackURLNil() {
        XCTAssertNil(DownloadManager.sanitizedTrackURL(nil))
    }

    // MARK: Low — auto-download

    func testAutoDownloadSkipsRemovedAndFailedBooks() {
        func ok(_ id: String, removed: Set<String> = [], failed: Set<String> = [],
                downloaded: Bool = false, downloading: Bool = false) -> Bool {
            DownloadManager.shouldAutoDownload(itemId: id, isDownloaded: downloaded, isDownloading: downloading,
                                               userRemoved: removed, failed: failed)
        }
        XCTAssertTrue(ok("a"))
        XCTAssertFalse(ok("a", removed: ["a"]))
        XCTAssertFalse(ok("a", failed: ["a"]))
        XCTAssertFalse(ok("a", downloaded: true))
        XCTAssertFalse(ok("a", downloading: true))
        XCTAssertTrue(ok("a", removed: ["b"], failed: ["c"]))
    }

    func testUserRemovedKeyIsScopedAndPurged() {
        let scope = DownloadManager.scopeKey(serverURL: "https://abs.example.com", accountId: "u")
        let key = DownloadManager.userRemovedItemsKey(scope: scope)
        XCTAssertTrue(key.hasSuffix("." + scope))
        XCTAssertTrue(DownloadManager.scopedDefaultsKeys(scope: scope).contains(key))
    }
}
