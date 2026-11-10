import XCTest
@testable import ShelfHead

/// Pins ARCH-4 (REVIEW_2026-08-12.md): `DownloadSessionDelegate.integrityFailureReason`
/// used to compare a finished download's file size directly against the response's
/// `Content-Length`. That's correct for a normal 200 response, but wrong for a 206
/// Partial Content response (issued whenever a download resumes from `resumeData`,
/// i.e. every relaunch-across pause/resume and every dropped-connection retry) —
/// there, `Content-Length` is only the *remaining* bytes at the time the range request
/// was made, while the finished file on disk is the fully reassembled track. Comparing
/// them directly rejected every resumed download as "incomplete," which meant the
/// resume/retry machinery could never actually finish a track.
final class DownloadIntegrityTests: XCTestCase {

    private var tempURL: URL!

    override func tearDown() {
        if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        tempURL = nil
        super.tearDown()
    }

    private func writeTempFile(_ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? data.write(to: url)
        tempURL = url
        return url
    }

    private func response(statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://abs.example.com/track.m4b")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: - Plain 200 responses (unchanged behavior)

    func test200WithMatchingContentLengthPasses() {
        let data = Data(repeating: 0xFF, count: 1000)
        let url = writeTempFile(data)
        let resp = response(statusCode: 200, headers: ["Content-Length": "1000"])
        XCTAssertNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    func test200WithTruncatedFileFails() {
        // Server declared 1000 bytes but the file on disk is only 500 — a genuinely
        // truncated transfer that still reported HTTP success.
        let data = Data(repeating: 0xFF, count: 500)
        let url = writeTempFile(data)
        let resp = response(statusCode: 200, headers: ["Content-Length": "1000"])
        XCTAssertNotNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    // MARK: - 206 Partial Content (the ARCH-4 fix)

    func test206WithContentRangeAndMatchingTotalPasses() {
        // The exact resumed-download shape: Content-Length is only the remaining 500
        // bytes of a 1000-byte file, but Content-Range's total (1000) matches the
        // fully-reassembled file on disk.
        let data = Data(repeating: 0xAB, count: 1000)
        let url = writeTempFile(data)
        let resp = response(statusCode: 206, headers: [
            "Content-Length": "500",
            "Content-Range": "bytes 500-999/1000",
        ])
        XCTAssertNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    func test206WithContentRangeMismatchedTotalFails() {
        let data = Data(repeating: 0xAB, count: 900)
        let url = writeTempFile(data)
        let resp = response(statusCode: 206, headers: [
            "Content-Length": "500",
            "Content-Range": "bytes 500-999/1000",
        ])
        XCTAssertNotNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    func test206WithoutContentRangeHeaderDoesNotFalsePositive() {
        // No Content-Range to parse a total from — can't validate size, but shouldn't
        // crash or reject solely because Content-Length undercounts a resumed file.
        let data = Data(repeating: 0xAB, count: 1000)
        let url = writeTempFile(data)
        let resp = response(statusCode: 206, headers: ["Content-Length": "500"])
        XCTAssertNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    // MARK: - Error pages served with a 200 status

    func testFileStartingWithAngleBracketFails() {
        let data = Data("<html><body>Please log in</body></html>".utf8)
        let url = writeTempFile(data)
        let resp = response(statusCode: 200, headers: ["Content-Length": "\(data.count)"])
        XCTAssertNotNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    func testFileStartingWithCurlyBraceFails() {
        let data = Data("{\"error\": \"unauthorized\"}".utf8)
        let url = writeTempFile(data)
        let resp = response(statusCode: 200, headers: ["Content-Length": "\(data.count)"])
        XCTAssertNotNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    func testRealAudioHeaderPasses() {
        // A real .m4b/.mp4-family file starts with an `ftyp` box, not an angle bracket or brace.
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftypM4A ".utf8))
        data.append(Data(repeating: 0x00, count: 992))
        let url = writeTempFile(data)
        let resp = response(statusCode: 200, headers: ["Content-Length": "\(data.count)"])
        XCTAssertNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    // MARK: - Zero-byte file

    func testEmptyFileFails() {
        let url = writeTempFile(Data())
        let resp = response(statusCode: 200, headers: ["Content-Length": "0"])
        XCTAssertNotNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: resp))
    }

    // MARK: - No response at all (defensive path)

    func testNoResponseSkipsLengthCheckButStillChecksFileShape() {
        let data = Data(repeating: 0xAB, count: 1000)
        let url = writeTempFile(data)
        XCTAssertNil(DownloadSessionDelegate.integrityFailureReason(at: url, response: nil))
    }

    // MARK: - `DownloadManager.fileHealthIssue` (Item 25, perf review)
    //
    // Pins the pure classification `verifyDownload`/`verifyDownloadAsync` both funnel
    // through (via the shared, private `classifyTracks`) — moving the per-track
    // `FileHandle` reads off the main actor (Item 25) must not change which tracks are
    // reported healthy vs. broken, so this is tested independently of which of the two
    // entry points calls it, or which thread it runs on.

    func testFileHealthIssueMissingFileReportsMissing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(DownloadManager.fileHealthIssue(at: url), "Missing")
    }

    func testFileHealthIssueEmptyFileReportsEmpty() {
        let url = writeTempFile(Data())
        XCTAssertEqual(DownloadManager.fileHealthIssue(at: url), "Empty file")
    }

    func testFileHealthIssueHTMLErrorPageIsFlagged() {
        let data = Data("<html><body>Please log in</body></html>".utf8)
        let url = writeTempFile(data)
        XCTAssertNotNil(DownloadManager.fileHealthIssue(at: url))
    }

    func testFileHealthIssueJSONErrorPageIsFlagged() {
        let data = Data("{\"error\": \"unauthorized\"}".utf8)
        let url = writeTempFile(data)
        XCTAssertNotNil(DownloadManager.fileHealthIssue(at: url))
    }

    func testFileHealthIssueRealAudioHeaderIsHealthy() {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftypM4A ".utf8))
        data.append(Data(repeating: 0x00, count: 992))
        let url = writeTempFile(data)
        XCTAssertNil(DownloadManager.fileHealthIssue(at: url))
    }
}
