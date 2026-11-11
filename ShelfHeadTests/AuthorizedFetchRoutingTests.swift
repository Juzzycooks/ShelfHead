import XCTest
import UIKit
@testable import ShelfHead

/// Item 6 (REVIEW-2026-09-09 remaining, "the four remaining direct `URLSession` fetches"):
/// the two cover fetch paths in `Extensions.swift` and the ebook fetch in
/// `EbookReaderView` now go through `AudiobookshelfAPI.authorizedData(for:)` instead of
/// `URLSession.shared.data(for:)`, so they get the centralized auth headers *and* the
/// silent refresh-and-retry-once on a 401.
///
/// The fetch itself is network I/O and isn't tested here (CLAUDE.md's precedent: pin the
/// pure decision functions, not the stateful I/O). What is pinned is the decision logic
/// the change moved or introduced:
///
/// - `CoverImageCache.isRemoteCover` — the "is this worth putting in the disk cover
///   cache / does it need auth headers" test, which used to be spelled out inline in
///   three places and now has one definition shared by the fetch and the cache tier.
/// - `CoverImageCache.targetSize` — the downsample/cache-budget behaviour that had to
///   survive the reroute unchanged (the cache layering deliberately stayed in
///   `Extensions.swift` around the API call rather than moving into the API type).
/// - `EbookReaderView.downloadFailureMessage` — new: the reader used to inspect the
///   `HTTPURLResponse` itself; `authorizedData` throws an `APIError` on any non-2xx
///   instead, so the status → message decision moved into this pure function.
final class AuthorizedFetchRoutingTests: XCTestCase {

    // MARK: - Which cover URLs are remote (auth + disk cache tier)

    func testRemoteCoverSchemes() {
        XCTAssertTrue(CoverImageCache.isRemoteCover(URL(string: "https://books.example/api/items/abc/cover?width=300")!))
        XCTAssertTrue(CoverImageCache.isRemoteCover(URL(string: "http://192.168.1.10:13378/api/items/abc/cover?width=300")!))
    }

    func testLocalCoverIsNotRemote() {
        // `shelfCoverURL` returns a `file://` URL for a downloaded book's cover; those
        // must never be run through the disk cover cache (they're already local) and
        // must not be treated as needing a bearer token.
        XCTAssertFalse(CoverImageCache.isRemoteCover(URL(fileURLWithPath: "/tmp/covers/abc.jpg")))
        XCTAssertFalse(CoverImageCache.isRemoteCover(URL(string: "data:image/jpeg;base64,AAAA")!))
    }

    // MARK: - Downsample target (unchanged by the reroute)

    func testTargetSizeUsesWidthQueryParameter() {
        let url = URL(string: "https://books.example/api/items/abc/cover?width=900")!
        XCTAssertEqual(CoverImageCache.targetSize(for: url), CGSize(width: 900, height: 900))
    }

    func testTargetSizeFallsBackTo300WithoutAWidth() {
        let url = URL(string: "https://books.example/api/items/abc/cover")!
        XCTAssertEqual(CoverImageCache.targetSize(for: url), CGSize(width: 300, height: 300))
    }

    func testTargetSizeForLocalCoverMatchesWhatWasDownloaded() {
        // Downloaded covers are saved at `cover?width=600`; a file URL carries no query
        // to read back, so 600 is the right floor rather than the generic 300 default.
        XCTAssertEqual(CoverImageCache.targetSize(for: URL(fileURLWithPath: "/tmp/covers/abc.jpg")),
                       CGSize(width: 600, height: 600))
    }

    // MARK: - Ebook fetch failure messages

    func testExpiredSessionMessageMentionsSigningInAgain() {
        // A 401 reaching here means `authorizedData` already refreshed and retried once.
        let message = EbookReaderView.downloadFailureMessage(for: APIError.unauthorized)
        XCTAssertTrue(message.lowercased().contains("session"), message)
        XCTAssertTrue(message.lowercased().contains("sign"), message)
    }

    func testForbiddenMessageTalksAboutPermission() {
        let message = EbookReaderView.downloadFailureMessage(for: APIError.forbidden)
        XCTAssertTrue(message.lowercased().contains("permission"), message)
    }

    func testNotFoundMessageSaysTheFileWasNotFound() {
        let message = EbookReaderView.downloadFailureMessage(for: APIError.notFound)
        XCTAssertTrue(message.lowercased().contains("find"), message)
    }

    // Batch 490 (REVIEW 2026-11-11 E6): the three tests below changed with the copy. The
    // reader no longer shows an HTTP status code or a raw system error description.
    func testServerAndHTTPErrorsDoNotShowTheStatusCode() {
        let server = EbookReaderView.downloadFailureMessage(for: APIError.serverError(503))
        let http = EbookReaderView.downloadFailureMessage(for: APIError.httpError(418))
        XCTAssertFalse(server.contains("503"), server)
        XCTAssertFalse(http.contains("418"), http)
        XCTAssertFalse(server.contains("HTTP"), server)
        XCTAssertEqual(server, "Your server couldn’t send this file. Try again in a moment.")
    }

    func testGenericServerFailureUsesTheServerWording() {
        XCTAssertEqual(EbookReaderView.downloadFailureMessage(for: APIError.invalidResponse),
                       "Your server couldn’t send this file. Try again in a moment.")
    }

    func testNonAPIErrorMapsToOfflineWithoutTheSystemText() {
        let underlying = URLError(.notConnectedToInternet)
        let message = EbookReaderView.downloadFailureMessage(for: underlying)
        XCTAssertEqual(message, "You’re offline. Connect to the internet to open this book.")
        XCTAssertFalse(message.contains(underlying.localizedDescription), message)
    }
}
