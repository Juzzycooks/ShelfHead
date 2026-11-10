import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): Recent Changes is scoped to the account each change was
/// made on. Pins `PlaybackHistoryStore.isUndoable`/`sections`, the backward-compatible
/// decode, and the screen's group copy.
@MainActor
final class PlaybackHistoryScopeTests: XCTestCase {

    private typealias Entry = PlaybackHistoryStore.HistoryEntry

    private func entry(_ itemId: String, account: String?, host: String? = nil,
                       at seconds: TimeInterval = 0) -> Entry {
        Entry(id: UUID(), itemId: itemId, title: "Book \(itemId)", action: .markedFinished,
              timestamp: Date(timeIntervalSince1970: seconds),
              previousCurrentTime: 10, previousIsFinished: false, previousDuration: 100,
              accountId: account, serverHost: host)
    }

    // MARK: - Undo

    func testOnlyTheCurrentAccountsNewestEntryForABookIsUndoable() {
        let newer = entry("item", account: "A")
        let older = entry("item", account: "A")
        let entries = [newer, older]
        XCTAssertTrue(PlaybackHistoryStore.isUndoable(newer, in: entries, currentAccountId: "A"))
        XCTAssertFalse(PlaybackHistoryStore.isUndoable(older, in: entries, currentAccountId: "A"))
    }

    func testAnotherServersEntryIsNotUndoable() {
        let other = entry("item", account: "B")
        XCTAssertFalse(PlaybackHistoryStore.isUndoable(other, in: [other], currentAccountId: "A"))
    }

    func testAnotherServersNewerEntryForTheSameIdDoesNotSupersedeThisOne() {
        // Item ids are per server; the same id on another server is a different book.
        let otherServer = entry("item", account: "B")
        let mine = entry("item", account: "A")
        XCTAssertTrue(PlaybackHistoryStore.isUndoable(mine, in: [otherServer, mine], currentAccountId: "A"))
    }

    func testLegacyEntryWithNoAccountIsNeverUndoable() {
        let legacy = entry("item", account: nil)
        XCTAssertFalse(PlaybackHistoryStore.isUndoable(legacy, in: [legacy], currentAccountId: "A"))
        XCTAssertFalse(PlaybackHistoryStore.isUndoable(legacy, in: [legacy], currentAccountId: nil))
    }

    // MARK: - Grouping

    func testSectionsPutThisAccountFirstThenOtherServersThenUnknown() {
        let b1 = entry("1", account: "B", host: "b.example.org")
        let mine = entry("2", account: "A", host: "a.example.org")
        let legacy = entry("3", account: nil)
        let c1 = entry("4", account: "C", host: "c.example.org")
        let b2 = entry("5", account: "B", host: "b.example.org")
        let sections = PlaybackHistoryStore.sections(for: [b1, mine, legacy, c1, b2], currentAccountId: "A")
        XCTAssertEqual(sections.map(\.kind), [.current, .otherServer(host: "b.example.org"),
                                              .otherServer(host: "c.example.org"), .unknownServer])
        XCTAssertEqual(sections[0].entries, [mine])
        XCTAssertEqual(sections[1].entries, [b1, b2])
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    func testTwoAccountsOnOneHostAreTwoGroups() {
        let x = entry("1", account: "X", host: "same.example.org")
        let y = entry("2", account: "Y", host: "same.example.org")
        let sections = PlaybackHistoryStore.sections(for: [x, y], currentAccountId: "A")
        XCTAssertEqual(sections.count, 2)
        XCTAssertNotEqual(sections[0].id, sections[1].id)
    }

    func testNoEntriesNoSections() {
        XCTAssertTrue(PlaybackHistoryStore.sections(for: [], currentAccountId: "A").isEmpty)
    }

    // MARK: - Backward-compatible decode

    func testEntriesRecordedBeforeAccountsDecodeAsUnknownAccount() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","itemId":"li_1","title":"Dune","action":"markedFinished",
          "timestamp":0,"previousCurrentTime":12,"previousIsFinished":false,"previousDuration":300}]
        """
        let decoded = try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].accountId)
        XCTAssertNil(decoded[0].serverHost)
    }

    func testAccountRoundTrips() throws {
        let original = entry("li_1", account: "A", host: "a.example.org")
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([Entry].self, from: data)
        XCTAssertEqual(decoded, [original])
    }

    // MARK: - Screen copy

    func testGroupHeadings() {
        XCTAssertNil(PlaybackHistoryView.sectionTitle(for: .current))
        XCTAssertEqual(PlaybackHistoryView.sectionTitle(for: .otherServer(host: "b.example.org")), "On b.example.org")
        XCTAssertEqual(PlaybackHistoryView.sectionTitle(for: .unknownServer), "Server not recorded")
    }

    func testOtherServerRowSaysHowToUndoIt() {
        let other = entry("1", account: "B", host: "b.example.org")
        let label = PlaybackHistoryView.rowAccessibilityLabel(for: other, undoable: false,
                                                              groupKind: .otherServer(host: "b.example.org"))
        XCTAssertTrue(label.hasSuffix("on b.example.org, switch to that server to undo"))
        XCTAssertFalse(label.contains("changed again since"))
    }
}
