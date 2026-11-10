import XCTest
@testable import ShelfHead

/// Cover for `PersistedStoreLoad` (bottom of `Services/PendingBookmarkQueue.swift`), the
/// shared load path for the three persisted stores — `PendingBookmarkQueue`,
/// `PendingProgressQueue` and `PlaybackHistoryStore`.
///
/// The bug being pinned: all three used to latch `hasLoadedFromDisk = true` before reading
/// and `try?`-swallow both the read and the decode, so an unreadable or corrupt blob loaded
/// as "empty" and the next `persist()` wrote that emptiness over it. The decision half is a
/// pure function, tested here with no filesystem at all (the precedent
/// `DownloadManager.shouldReclaimOrphanDirectory` set); the thin wrappers are tested against
/// real scratch files and a scratch defaults suite.
final class PersistedStoreLoadTests: XCTestCase {

    private var dir: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-store-load-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("store.json")
    }

    override func tearDownWithError() throws {
        if let dir {
            // A test may have left a file mode 000 behind; restore it so the sweep works.
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in contents {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(name).path)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        dir = nil
        fileURL = nil
        try super.tearDownWithError()
    }

    private typealias Payload = [String: String]

    private func decodePayload(_ data: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: data)
    }

    private func loadFile() -> PersistedStoreLoad.Outcome<Payload> {
        PersistedStoreLoad.load(fileURL: fileURL, label: "Test", decode: decodePayload)
    }

    // MARK: - The pure decision

    func testAbsentBlobStartsEmptyAndMayPersist() {
        let decision = PersistedStoreLoad.decision(for: .absent)
        XCTAssertTrue(decision.markLoaded)
        XCTAssertFalse(decision.quarantine, "There is nothing to move aside on a first launch")
        XCTAssertTrue(decision.persistAllowed)
    }

    func testDecodedBlobMarksLoadedAndMayPersist() {
        XCTAssertEqual(
            PersistedStoreLoad.decision(for: .decoded),
            PersistedStoreLoad.Decision(markLoaded: true, quarantine: false, persistAllowed: true))
    }

    func testDecodeFailureQuarantinesThenStartsEmpty() {
        let decision = PersistedStoreLoad.decision(for: .decodeFailed)
        XCTAssertTrue(decision.quarantine, "Corrupt bytes must be preserved before anything overwrites them")
        XCTAssertTrue(decision.markLoaded, "Once the bytes are safely aside, starting empty is safe")
        XCTAssertTrue(decision.persistAllowed)
    }

    func testReadFailureNeitherLoadsNorPersists() {
        let decision = PersistedStoreLoad.decision(for: .readFailed)
        XCTAssertFalse(decision.markLoaded, "Leaving the flag false is what makes the next access retry")
        XCTAssertFalse(decision.persistAllowed, "This is the case the whole fix exists for")
        XCTAssertFalse(decision.quarantine, "We could not read the bytes; moving them is not on the table")
    }

    /// The invariant behind the fix: a store may only write once it has established what is
    /// there. If these two ever diverge, the data-destroying path is back.
    func testPersistIsAllowedExactlyWhenTheStoreMayMarkItselfLoaded() {
        for finding: PersistedStoreLoad.Finding in [.absent, .decoded, .decodeFailed, .readFailed] {
            let decision = PersistedStoreLoad.decision(for: finding)
            XCTAssertEqual(decision.markLoaded, decision.persistAllowed, "Diverged for \(finding.rawValue)")
        }
    }

    func testQuarantineNamesAreTheOriginalPlusSuffix() {
        XCTAssertEqual(
            PersistedStoreLoad.quarantineURL(for: URL(fileURLWithPath: "/tmp/q/queue.json")).path,
            "/tmp/q/queue.json.corrupt")
        XCTAssertEqual(PersistedStoreLoad.quarantineKey(for: "shelfhead_x"), "shelfhead_x.corrupt")
    }

    // MARK: - File wrapper

    func testAbsentFileLoadsEmpty() {
        guard case .empty = loadFile() else { return XCTFail("A file that was never written is not an error") }
    }

    func testMissingDirectoryLoadsEmpty() {
        let nested = dir.appendingPathComponent("never-created", isDirectory: true)
            .appendingPathComponent("store.json")
        let outcome: PersistedStoreLoad.Outcome<Payload> =
            PersistedStoreLoad.load(fileURL: nested, label: "Test", decode: decodePayload)
        guard case .empty = outcome else { return XCTFail("Expected .empty") }
    }

    func testValidFileDecodes() throws {
        try JSONEncoder().encode(["a": "1"]).write(to: fileURL)
        guard case .loaded(let value) = loadFile() else { return XCTFail("Expected .loaded") }
        XCTAssertEqual(value, ["a": "1"])
    }

    func testCorruptFileIsMovedAsideAndLoadsEmpty() throws {
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        guard case .empty = loadFile() else { return XCTFail("A corrupt file must load as empty, not fail the app") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "The corrupt file must be out of the way so a fresh one can be written")
        let quarantined = PersistedStoreLoad.quarantineURL(for: fileURL)
        XCTAssertEqual(try Data(contentsOf: quarantined), garbage,
                       "The original bytes are the whole point of quarantining rather than deleting")
    }

    /// The `.corrupt` slot holds the newest unreadable copy; `moveItem` would otherwise fail
    /// outright against an existing destination and leave the corrupt file in place forever.
    func testSecondCorruptLoadReplacesTheOlderQuarantine() throws {
        try Data("first garbage".utf8).write(to: fileURL)
        _ = loadFile()

        let second = Data("second garbage, different".utf8)
        try second.write(to: fileURL)
        guard case .empty = loadFile() else { return XCTFail("Expected .empty on the second corrupt load") }

        XCTAssertEqual(try Data(contentsOf: PersistedStoreLoad.quarantineURL(for: fileURL)), second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A file that exists but can't be opened is the dangerous case: the caller must be told
    /// to neither adopt an empty state nor write.
    func testUnreadableFileIsUnavailableAndLeftUntouched() throws {
        let original = try JSONEncoder().encode(["keep": "me"])
        try original.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        // Running as root (or on a filesystem that ignores modes) would defeat the setup.
        if (try? Data(contentsOf: fileURL)) != nil {
            throw XCTSkip("This environment can read a mode-000 file; the unreadable case can't be simulated")
        }

        guard case .unavailable = loadFile() else {
            return XCTFail("An unreadable file must not be reported as empty")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PersistedStoreLoad.quarantineURL(for: fileURL).path),
            "Bytes we could not read must not be moved either")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    // MARK: - UserDefaults wrapper

    private func makeSuite() throws -> (UserDefaults, String) {
        let name = "persisted-store-load-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        // Captures only the suite name, so the block stays trivially concurrency-safe.
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        return (defaults, name)
    }

    func testAbsentDefaultsKeyLoadsEmpty() throws {
        let (defaults, _) = try makeSuite()
        let outcome: PersistedStoreLoad.Outcome<Payload> = PersistedStoreLoad.load(
            defaults: defaults, key: "k", label: "Test", decode: decodePayload)
        guard case .empty = outcome else { return XCTFail("Expected .empty") }
    }

    func testValidDefaultsValueDecodes() throws {
        let (defaults, _) = try makeSuite()
        defaults.set(try JSONEncoder().encode(["a": "1"]), forKey: "k")
        let outcome: PersistedStoreLoad.Outcome<Payload> = PersistedStoreLoad.load(
            defaults: defaults, key: "k", label: "Test", decode: decodePayload)
        guard case .loaded(let value) = outcome else { return XCTFail("Expected .loaded") }
        XCTAssertEqual(value, ["a": "1"])
    }

    func testCorruptDefaultsValueIsMovedToTheCorruptKey() throws {
        let (defaults, _) = try makeSuite()
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "k")

        let outcome: PersistedStoreLoad.Outcome<Payload> = PersistedStoreLoad.load(
            defaults: defaults, key: "k", label: "Test", decode: decodePayload)
        guard case .empty = outcome else { return XCTFail("Expected .empty") }

        XCTAssertNil(defaults.data(forKey: "k"), "The unusable value must be cleared, not left to fail again")
        XCTAssertEqual(defaults.data(forKey: PersistedStoreLoad.quarantineKey(for: "k")), garbage)
    }

    func testSecondCorruptDefaultsValueReplacesTheOlderQuarantine() throws {
        let (defaults, _) = try makeSuite()
        defaults.set(Data("first".utf8), forKey: "k")
        let first: PersistedStoreLoad.Outcome<Payload> = PersistedStoreLoad.load(
            defaults: defaults, key: "k", label: "Test", decode: decodePayload)
        if case .loaded = first { XCTFail("\"first\" is not valid JSON for a dictionary") }

        let second = Data("second".utf8)
        defaults.set(second, forKey: "k")
        let outcome: PersistedStoreLoad.Outcome<Payload> = PersistedStoreLoad.load(
            defaults: defaults, key: "k", label: "Test", decode: decodePayload)
        guard case .empty = outcome else { return XCTFail("Expected .empty") }
        XCTAssertEqual(defaults.data(forKey: PersistedStoreLoad.quarantineKey(for: "k")), second)
    }
}
