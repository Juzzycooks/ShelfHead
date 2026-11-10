import XCTest
@testable import ShelfHead

/// Batch 456: pure parts of Listen Together (SharePlay).
final class ListenTogetherTests: XCTestCase {
    func testIdentifierRoundTrip() {
        let id = ListenTogetherIdentifier.encode(itemId: "li_abc123", trackIndex: 4)
        XCTAssertEqual(id, "li_abc123#4")
        let parsed = ListenTogetherIdentifier.parse(id)
        XCTAssertEqual(parsed?.itemId, "li_abc123")
        XCTAssertEqual(parsed?.trackIndex, 4)
    }

    func testIdentifierSplitsOnLastHashAndRejectsMalformed() {
        XCTAssertEqual(ListenTogetherIdentifier.parse("a#b#2")?.itemId, "a#b")
        XCTAssertNil(ListenTogetherIdentifier.parse("nohash"))
        XCTAssertNil(ListenTogetherIdentifier.parse("#3"))
        XCTAssertNil(ListenTogetherIdentifier.parse("x#abc"))
        XCTAssertNil(ListenTogetherIdentifier.parse("x#-1"))
        XCTAssertEqual(ListenTogetherIdentifier.encode(itemId: "x", trackIndex: -5), "x#0")
    }

    func testMessageCodableRoundTrip() throws {
        let messages: [ListenTogetherMessage] = [
            .bookChanged(itemId: "li_1", title: "Dune"),
            .trackChanged(itemId: "li_1", trackIndex: 7),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            XCTAssertEqual(try JSONDecoder().decode(ListenTogetherMessage.self, from: data), message)
        }
    }

    func testActivityCodableRoundTrip() throws {
        let activity = ListenTogetherActivity(libraryItemId: "li_1", serverFingerprint: "abcd", title: "Dune", author: "Frank Herbert")
        let data = try JSONEncoder().encode(activity)
        let back = try JSONDecoder().decode(ListenTogetherActivity.self, from: data)
        XCTAssertEqual(back.libraryItemId, "li_1")
        XCTAssertEqual(back.serverFingerprint, "abcd")
    }

    func testFingerprintMatchDecision() {
        let mine = ServerFingerprint.fingerprint(forServerURL: "https://books.example.com")
        let same = ServerFingerprint.fingerprint(forServerURL: "https://BOOKS.example.com/")
        let other = ServerFingerprint.fingerprint(forServerURL: "https://other.example.com")
        XCTAssertTrue(ListenTogetherLogic.fingerprintsMatch(same, mine))
        XCTAssertFalse(ListenTogetherLogic.fingerprintsMatch(other, mine))
        XCTAssertFalse(ListenTogetherLogic.fingerprintsMatch("", ""), "an unknown server never matches")
    }

    func testStateTransitions() {
        typealias L = ListenTogetherLogic
        var s = ListenTogetherState.idle
        s = L.reduce(s, .startedSharing)
        XCTAssertEqual(s, .waiting)
        s = L.reduce(s, .joined(participants: 2, title: "Dune"))
        XCTAssertEqual(s, .active(participants: 2, title: "Dune"))
        s = L.reduce(s, .participantsChanged(3))
        XCTAssertEqual(s, .active(participants: 3, title: "Dune"))
        XCTAssertEqual(L.reduce(s, .startedSharing), s, "sharing again while active changes nothing")
        XCTAssertEqual(L.reduce(s, .left), .idle)
        XCTAssertEqual(L.reduce(s, .invalidated(failed: true)), .unavailable)
        XCTAssertEqual(L.reduce(s, .invalidated(failed: false)), .idle)
    }

    func testForeignServerAndNoticeDismissal() {
        typealias L = ListenTogetherLogic
        let s = L.reduce(.idle, .sessionOffered(matchesMyServer: false, title: "Dune"))
        XCTAssertEqual(s, .notOnYourServer(title: "Dune"))
        XCTAssertEqual(L.reduce(s, .dismissedNotice), .idle)
        XCTAssertEqual(L.reduce(.unavailable, .dismissedNotice), .idle)
        XCTAssertEqual(L.reduce(.waiting, .dismissedNotice), .waiting)
        XCTAssertEqual(L.reduce(.idle, .participantsChanged(4)), .idle, "count changes outside a session are ignored")
        XCTAssertEqual(L.displayCount(0), 1)
    }
}
