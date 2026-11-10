import XCTest
@testable import ShelfHead

/// Batch 458: mixtape link, sequencing and store tests.
final class MixtapeTests: XCTestCase {
    private func clip(_ item: String = "a", _ s: Double = 10, _ e: Double = 40, quote: String? = nil) -> MixtapeClip {
        MixtapeClip(itemId: item, start: s, end: e, label: "L", quote: quote, title: "Title", author: "Author")
    }

    func testLinkRoundTrip() throws {
        let tape = Mixtape(title: "Road trip", clips: [clip("a", 1.25, 31.5, quote: "Hello"), clip("b", 100, 130)])
        let enc = try MixtapeLink.encode(tape, serverURL: "https://abs.example.com/")
        XCTAssertFalse(enc.droppedQuotes)
        XCTAssertLessThanOrEqual(enc.url.absoluteString.count, MixtapeLink.maxURLLength)
        let dec = try MixtapeLink.decode(enc.url)
        XCTAssertEqual(dec.mixtape.title, "Road trip")
        XCTAssertEqual(dec.mixtape.clips.map(\.itemId), ["a", "b"])
        XCTAssertEqual(dec.mixtape.clips[0].start, 1.3, accuracy: 0.001)   // tenths
        XCTAssertEqual(dec.mixtape.clips[0].quote, "Hello")
        XCTAssertEqual(dec.serverFingerprint, MixtapeLink.fingerprint(forServer: "abs.example.com"))
    }

    func testLimits() {
        let many = Mixtape(title: "x", clips: (0..<26).map { _ in clip() })
        XCTAssertThrowsError(try MixtapeLink.encode(many, serverURL: "h")) { XCTAssertEqual($0 as? MixtapeLinkError, .tooManyClips) }
        XCTAssertThrowsError(try MixtapeLink.encode(Mixtape(title: "x"), serverURL: "h")) { XCTAssertEqual($0 as? MixtapeLinkError, .noClips) }
        // Long quotes are dropped to fit; if it still can't fit it throws.
        // Distinct random quotes: identical ones compress so well the link fits with them kept.
        let quoted = Mixtape(title: "x", clips: (0..<20).map { _ in
            clip(quote: (0..<6).map { _ in UUID().uuidString }.joined(separator: " ")) })
        let enc = try? MixtapeLink.encode(quoted, serverURL: "h")
        XCTAssertEqual(enc?.droppedQuotes, true)
        let hugeIds = Mixtape(title: "x", clips: (0..<25).map { i in
            MixtapeClip(itemId: UUID().uuidString, start: Double(i), end: Double(i) + 5, label: UUID().uuidString + UUID().uuidString,
                        title: UUID().uuidString + UUID().uuidString) })
        XCTAssertThrowsError(try MixtapeLink.encode(hugeIds, serverURL: "h")) { XCTAssertEqual($0 as? MixtapeLinkError, .tooLong) }
    }

    func testMalformedLinks() {
        func code(_ s: String) -> MixtapeLinkError? {
            do { _ = try MixtapeLink.decode(URL(string: s)!); return nil } catch { return error as? MixtapeLinkError }
        }
        XCTAssertEqual(code("https://example.com/mixtape"), .notAMixtapeLink)
        XCTAssertEqual(code("shelfhead://book/1"), .notAMixtapeLink)
        XCTAssertEqual(code("shelfhead://mixtape"), .malformed)
        XCTAssertEqual(code("shelfhead://mixtape?v=2&d=abc"), .unsupportedVersion)
        XCTAssertEqual(code("shelfhead://mixtape?v=1"), .malformed)
        XCTAssertEqual(code("shelfhead://mixtape?v=1&d=!!!"), .malformed)
        XCTAssertEqual(code("shelfhead://mixtape?v=1&d=AAAA"), .malformed)
        XCTAssertEqual(code("shelfhead://mixtape?v=1&d=" + String(repeating: "A", count: 9000)), .tooLong)
    }

    func testFingerprintNormalisation() {
        let f = MixtapeLink.fingerprint(forServer: "abs.example.com")
        XCTAssertEqual(f.count, 16)
        for s in ["https://ABS.Example.com", "http://abs.example.com/", "https://abs.example.com:443", "http://abs.example.com:80/path", "https://user:pw@abs.example.com"] {
            XCTAssertEqual(MixtapeLink.fingerprint(forServer: s), f, s)
        }
        XCTAssertNotEqual(MixtapeLink.fingerprint(forServer: "https://abs.example.com:13378"), f)
        XCTAssertEqual(MixtapeLink.normalisedHost("https://abs.example.com:13378/x"), "abs.example.com:13378")
    }

    func testSequencer() {
        let clips = [clip("a", 10, 40), clip("b", 5, 20)]
        func act(_ i: Int, _ item: String?, _ pos: Double) -> MixtapeSequencerAction {
            MixtapeSequencer.action(clips: clips, index: i, playingItemId: item, position: pos)
        }
        XCTAssertEqual(act(0, "a", 20), .continuePlaying)
        XCTAssertEqual(act(0, "a", 39.97), .advance(to: 1))
        XCTAssertEqual(act(0, "a", 90), .advance(to: 1))
        XCTAssertEqual(act(1, "b", 20), .finish)
        XCTAssertEqual(act(0, "other", 20), .abandon)
        XCTAssertEqual(act(0, nil, 20), .abandon)
        XCTAssertEqual(act(5, "a", 0), .finish)
    }

    func testOpsMoveRemoveRename() {
        let t = Mixtape(title: "t", clips: [clip("a"), clip("b"), clip("c")])
        XCTAssertEqual(MixtapeOps.moving(t, from: IndexSet(integer: 0), to: 3).clips.map(\.itemId), ["b", "c", "a"])
        XCTAssertEqual(MixtapeOps.moving(t, from: IndexSet(integer: 2), to: 0).clips.map(\.itemId), ["c", "a", "b"])
        XCTAssertEqual(MixtapeOps.removing(t, at: IndexSet([0, 2])).clips.map(\.itemId), ["b"])
        XCTAssertEqual(MixtapeOps.renamed(t, to: "  New ").title, "New")
        XCTAssertEqual(MixtapeOps.renamed(t, to: "  ").title, "t")
        let full = Mixtape(title: "f", clips: (0..<25).map { _ in clip() })
        XCTAssertNil(MixtapeOps.appending(clip(), to: full))
    }

    @MainActor
    func testStoreScopesAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixtapes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var scope = "one"
        let store = MixtapeStore(fileURL: url, scopeProvider: { scope })
        let made = store.create(title: "A", clips: [clip("a"), clip("b")])
        XCTAssertTrue(store.add(clip("c"), to: made.id))
        store.move(made.id, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.mixtape(id: made.id)?.clips.map(\.itemId), ["c", "a", "b"])
        store.removeClips(made.id, at: IndexSet(integer: 1))
        XCTAssertEqual(store.mixtape(id: made.id)?.clips.map(\.itemId), ["c", "b"])
        scope = "two"
        XCTAssertTrue(store.mixtapes.isEmpty)
        scope = "one"
        let reloaded = MixtapeStore(fileURL: url, scopeProvider: { "one" })
        XCTAssertEqual(reloaded.mixtapes.count, 1)
        reloaded.delete(made.id)
        XCTAssertTrue(reloaded.mixtapes.isEmpty)
    }
}
