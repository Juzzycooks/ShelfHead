import XCTest
@testable import ShelfHead

/// W3 (REVIEW_2026-09-04_UI.md Pass 4): the now-playing record in the App Group is written
/// by the app and read by the widget, and nothing used to re-derive one left behind by an
/// older build. On a real upgraded device that meant a title still carrying "(Unabridged)"
/// (stripped everywhere else since G2) next to the widget's placeholder cover glyph,
/// because the cover was still embedded in the record under a `coverData` key this build's
/// decoder ignores while the `widget_cover.jpg` it actually reads had never been written.
///
/// Only the pure halves are covered here — deciding *whether* to migrate, what the record
/// becomes, and recovering the stranded bytes. The `UserDefaults`/file writes that
/// `SharedPlayback.read()` wraps around them talk to the real App Group container, which
/// is the same line `DownloadManager`'s orphan sweep is tested on.
final class SharedPlaybackMigrationTests: XCTestCase {

    /// A record as an older build wrote it: no `version`, an unstripped title, and the
    /// cover inline.
    private func legacyRecord(
        title: String = "The Primal Hunter 13 (Unabridged)", cover: Data? = Data("jpeg-bytes".utf8)
    ) -> Data {
        var object: [String: Any] = [
            "itemId": "li_abc",
            "title": title,
            "author": "Zogarth",
            "currentTime": 14_400,
            "duration": 75_826.29,
            "isPlaying": false,
            "updatedAt": 0
        ]
        // Base64, which is what `JSONEncoder` produced for the `Data` this key used to hold.
        if let cover { object["coverData"] = cover.base64EncodedString() }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func decode(_ data: Data) throws -> SharedPlayback.Snapshot {
        try JSONDecoder().decode(SharedPlayback.Snapshot.self, from: data)
    }

    // MARK: - Version stamp

    func testARecordWrittenBeforeTheStampExistedDecodesAsVersionZero() throws {
        XCTAssertEqual(try decode(legacyRecord()).version, 0)
    }

    func testEveryRecordThisBuildWritesIsStampedCurrent() {
        let fresh = SharedPlayback.Snapshot(
            itemId: "li_abc", title: "Anything", author: "A",
            currentTime: 0, duration: 1, isPlaying: false, updatedAt: Date())
        XCTAssertEqual(fresh.version, SharedPlayback.currentSnapshotVersion,
                       "The default on the memberwise init is what keeps AudioPlayerService's "
                       + "write sites from needing to know this exists")
    }

    // MARK: - What the migration produces

    func testLegacyRecordIsRewrittenWithTheDisplayTitle() throws {
        let migrated = try XCTUnwrap(SharedPlayback.migrating(decode(legacyRecord())))
        XCTAssertEqual(migrated.title, "The Primal Hunter 13",
                       "A user who upgrades and never presses play kept the old title forever")
        XCTAssertEqual(migrated.version, SharedPlayback.currentSnapshotVersion)
    }

    func testMigrationTouchesNothingElse() throws {
        let original = try decode(legacyRecord())
        let migrated = try XCTUnwrap(SharedPlayback.migrating(original))
        XCTAssertEqual(migrated.itemId, original.itemId)
        XCTAssertEqual(migrated.author, original.author)
        XCTAssertEqual(migrated.currentTime, original.currentTime)
        XCTAssertEqual(migrated.duration, original.duration)
        XCTAssertEqual(migrated.updatedAt, original.updatedAt)
    }

    /// The rewrite happens inside `read()`, which both targets call on every render —
    /// so "already done" has to be free, and doing it twice has to be harmless.
    func testMigrationIsIdempotent() throws {
        let migrated = try XCTUnwrap(SharedPlayback.migrating(decode(legacyRecord())))
        XCTAssertNil(SharedPlayback.migrating(migrated),
                     "A current record must not be rewritten again on every timeline render")
    }

    func testACurrentRecordIsLeftAlone() {
        let fresh = SharedPlayback.Snapshot(
            itemId: "li_abc", title: "Mark of the Fool 10 (Unabridged)", author: "A",
            currentTime: 0, duration: 1, isPlaying: false, updatedAt: Date())
        XCTAssertNil(SharedPlayback.migrating(fresh),
                     "Version, not the title's shape, is what decides — a title that legitimately "
                     + "contains the marker must survive a round trip untouched")
    }

    // MARK: - The stranded cover

    func testEmbeddedCoverIsRecoverableFromTheLegacyRecord() {
        XCTAssertEqual(SharedPlayback.embeddedCoverData(inRecord: legacyRecord()),
                       Data("jpeg-bytes".utf8))
    }

    func testRecordWithNoEmbeddedCoverYieldsNothing() {
        XCTAssertNil(SharedPlayback.embeddedCoverData(inRecord: legacyRecord(cover: nil)))
    }

    func testEmptyEmbeddedCoverIsNotWrittenOut() {
        XCTAssertNil(SharedPlayback.embeddedCoverData(inRecord: legacyRecord(cover: Data())),
                     "Writing a zero-byte widget_cover.jpg would be worse than no file at all")
    }

    func testCoverIsNotLostByTheEncodingRoundTrip() throws {
        // The rewrite re-encodes through this build's `Snapshot`, which has no `coverData`
        // key — so the bytes only survive if they are pulled out of the *raw* record first.
        let raw = legacyRecord()
        let rescued = SharedPlayback.embeddedCoverData(inRecord: raw)
        let migrated = try XCTUnwrap(SharedPlayback.migrating(decode(raw)))
        let reencoded = try JSONEncoder().encode(migrated)
        XCTAssertNotNil(rescued)
        XCTAssertNil(SharedPlayback.embeddedCoverData(inRecord: reencoded))
    }

    // MARK: - Parity with the app-side rule

    /// `SharedPlayback.normalizedTitle` is a deliberate re-implementation of
    /// `LibraryItem.displayTitle` — this file is compiled into the widget target, where
    /// `LibraryItem` doesn't exist. This is the guard against the copy drifting.
    func testNormalizedTitleAgreesWithLibraryItemDisplayTitle() {
        let corpus = [
            "The Primal Hunter 13 (Unabridged)",
            "Mark of the Fool 10 [Unabridged]",
            "Shadeslinger: The Ripple System, Book 1: Unabridged",
            "Some Book - Unabridged",
            "Some Book \u{2013} Unabridged",
            "Some Book \u{2014} Unabridged",
            "some book (unabridged)",
            "Unabridged",
            "(Unabridged)",
            "The Unabridged Journals of Sylvia Plath",
            "An Abridged History",
            "Plain Title",
            "",
            "   "
        ]
        for raw in corpus {
            XCTAssertEqual(SharedPlayback.normalizedTitle(raw), LibraryItem.displayTitle(raw),
                           "Drifted on \"\(raw)\"")
        }
    }
}
