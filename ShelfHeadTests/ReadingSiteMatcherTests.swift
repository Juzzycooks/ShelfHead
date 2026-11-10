import XCTest
@testable import ShelfHead

/// Batch 443: matching, ISBN handling, throttle and cache for the reading-site sync.
final class ReadingSiteMatcherTests: XCTestCase {
    typealias C = ReadingSiteMatcher.Candidate

    func testTitleNormalisation() {
        XCTAssertEqual(ReadingSiteMatcher.normalizedTitle("Dune (Dune, #1)"), "dune")
        XCTAssertEqual(ReadingSiteMatcher.normalizedTitle("Café Société: Unabridged"), "cafe societe")
        XCTAssertEqual(ReadingSiteMatcher.coreTitle("The Name of the Wind: Kingkiller Chronicle"), "name of the wind")
    }

    func testAuthorMatching() {
        XCTAssertTrue(ReadingSiteMatcher.authorsMatch("J.R.R. Tolkien", "Tolkien, J. R. R."))
        XCTAssertTrue(ReadingSiteMatcher.authorsMatch("Frank Herbert", "Frank Herbert, Brian Herbert"))
        XCTAssertFalse(ReadingSiteMatcher.authorsMatch("Frank Herbert", "Jane Austen"))
        XCTAssertFalse(ReadingSiteMatcher.authorsMatch("", "Jane Austen"))
    }

    func testIsbn10To13() {
        XCTAssertEqual(ReadingSiteMatcher.isbn13("0441013597"), "9780441013593")
        XCTAssertEqual(ReadingSiteMatcher.isbn13("978-0-441-01359-3"), "9780441013593")
        XCTAssertEqual(ReadingSiteMatcher.isbn13("080442957X"), "9780804429573")
        XCTAssertNil(ReadingSiteMatcher.isbn13("123"))
        XCTAssertNil(ReadingSiteMatcher.isbn13(nil))
    }

    func testMatchOrderIsbnThenAsinThenTitle() {
        let lib = [
            C(id: "title", title: "Dune", author: "Frank Herbert", isbn: nil, asin: nil),
            C(id: "asin", title: "Unrelated", author: "X", isbn: nil, asin: "B002V0QK4C"),
            C(id: "isbn", title: "Different", author: "Y", isbn: "9780441013593", asin: nil)
        ]
        XCTAssertEqual(ReadingSiteMatcher.match(title: "Dune", author: "Frank Herbert", isbn: "0441013597", asin: "B002V0QK4C", in: lib), "isbn")
        XCTAssertEqual(ReadingSiteMatcher.match(title: "Dune", author: "Frank Herbert", isbn: nil, asin: "b002v0qk4c", in: lib), "asin")
        XCTAssertEqual(ReadingSiteMatcher.match(title: "Dune", author: "Frank Herbert", isbn: nil, asin: nil, in: lib), "title")
    }

    func testTitleMatchNeedsAuthor() {
        let lib = [C(id: "a", title: "Dune", author: "Frank Herbert", isbn: nil, asin: nil)]
        XCTAssertNil(ReadingSiteMatcher.match(title: "Dune", author: "Someone Else", isbn: nil, asin: nil, in: lib))
        XCTAssertNil(ReadingSiteMatcher.match(title: "Dune Messiah", author: "Frank Herbert", isbn: nil, asin: nil, in: lib))
    }

    func testProgressThrottle() {
        let now = Date()
        XCTAssertTrue(ReadingSiteMatcher.shouldSendProgress(lastSent: nil, now: now))
        XCTAssertFalse(ReadingSiteMatcher.shouldSendProgress(lastSent: now.addingTimeInterval(-599), now: now))
        XCTAssertTrue(ReadingSiteMatcher.shouldSendProgress(lastSent: now.addingTimeInterval(-600), now: now))
    }

    func testRatingClamp() {
        XCTAssertNil(ReadingSiteMatcher.clampedRating(0))
        XCTAssertEqual(ReadingSiteMatcher.clampedRating(0.2), 0.5)
        XCTAssertEqual(ReadingSiteMatcher.clampedRating(3.7), 3.5)
        XCTAssertEqual(ReadingSiteMatcher.clampedRating(9), 5)
    }

    func testMatchCacheHitMissAndRetry() {
        var cache = ReadingMatchCache()
        let t0 = Date()
        XCTAssertEqual(cache.lookup("x", now: t0), .unknown)
        cache.record("x", bookID: 42, now: t0)
        XCTAssertEqual(cache.lookup("x", now: t0.addingTimeInterval(9_999_999)), .hit(42))
        cache.record("y", bookID: nil, now: t0)
        XCTAssertEqual(cache.lookup("y", now: t0.addingTimeInterval(3600)), .recentMiss)
        XCTAssertEqual(cache.lookup("y", now: t0.addingTimeInterval(8 * 24 * 3600)), .unknown)
    }

    func testHardcoverTokenCleaningAndRequest() {
        XCTAssertEqual(HardcoverAPI.cleanedToken("  Bearer abc.def \n"), "abc.def")
        XCTAssertEqual(HardcoverAPI.cleanedToken("abc"), "abc")
        let req = HardcoverAPI.makeRequest(query: "{ me { id } }", variables: [:], token: "tok")
        XCTAssertEqual(req.url?.absoluteString, "https://api.hardcover.app/v1/graphql")
        XCTAssertEqual(req.value(forHTTPHeaderField: "authorization"), "Bearer tok")
        XCTAssertThrowsError(try HardcoverAPI.parseData(Data(#"{"errors":[{"message":"boom"}]}"#.utf8)))
        let me = try? HardcoverAPI.parseData(Data(#"{"data":{"me":[{"username":"j"}]}}"#.utf8))
        XCTAssertEqual(me.flatMap { HardcoverAPI.firstMe($0)?["username"] as? String }, "j")
    }
}
