import XCTest
@testable import ShelfHead

/// Item 9 (REVIEW-2026-09-09-REMAINING.md): the paused/interrupted download resume blobs
/// were the one store in `DownloadManager` written without `.atomic`. They are produced by
/// `cancel(byProducingResumeData:)`, i.e. at exactly the moment the app is being
/// backgrounded or suspended, so an interrupted write was a live possibility — and a
/// truncated blob is not inert: `restorePausedDownloads` reads it back on the next launch
/// and `resumeDownload`/`retryOrFail` hand it to `downloadTask(withResumeData:)`, which
/// then either fails outright (burning one of `maxRetries`) or silently restarts the track
/// from byte zero while the UI claims it resumed.
///
/// The write half of the fix (`persistPausedResume` now passing `options: .atomic`) is a
/// filesystem call and isn't unit-tested directly, matching this target's existing scope
/// (see `DownloadManagerScopeTests`'s header). What's pinned here is the read half: the
/// pure `shouldUseResumeBlob(_:)` gate all three readers now go through, following the
/// `shouldReclaimOrphanDirectory` / `failureAction` precedent for this file.
///
/// Several cases below exist because `PropertyListSerialization` is more permissive than
/// it looks — it also reads old-style OpenStep/ASCII plists, so a lone byte is a valid
/// plist (the string it spells) and pure whitespace is a valid *empty dictionary*. A
/// parse-only gate would have accepted the most truncated blobs of all; that's why
/// `shouldUseResumeBlob` requires a non-empty dictionary root.
///
/// `@MainActor`: `DownloadManager` is a main-actor type.
@MainActor
final class DownloadResumeBlobTests: XCTestCase {

    // MARK: - Helpers

    /// A genuine, minimal binary property list — built through the same serializer the
    /// gate parses with, rather than hardcoded bytes, so this test can't drift from what
    /// `PropertyListSerialization` actually accepts.
    private func binaryPlist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    private func xmlPlist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    /// The shape `URLSession` actually hands back from `cancel(byProducingResumeData:)`.
    private func realisticResumeBlob() throws -> Data {
        try binaryPlist([
            "NSURLSessionResumeInfoVersion": 2,
            "NSURLSessionResumeCurrentRequest": Data(repeating: 0x41, count: 128),
            "NSURLSessionResumeOriginalRequest": Data(repeating: 0x42, count: 128),
            "NSURLSessionResumeBytesReceived": 12_345_678,
            "NSURLSessionResumeInfoTempFileName": "CFNetworkDownload_9zQ1x2.tmp",
            "NSURLSessionResumeEntityTag": "\"a1b2c3\""
        ])
    }

    // MARK: - The bug

    /// The exact bug: a resume blob whose write was cut short. A binary plist keeps its
    /// object-offset table and 32-byte trailer at the *end* of the file, so a truncated
    /// blob is unparseable rather than "valid but shorter" — which is what makes this
    /// check able to catch it at all.
    func testTruncatedResumeBlobIsRejected() throws {
        let good = try binaryPlist(["NSURLSessionResumeInfoTempFileName": "CFNetworkDownload_ab12cd.tmp",
                                    "NSURLSessionResumeBytesReceived": 4_194_304])
        XCTAssertTrue(DownloadManager.shouldUseResumeBlob(good),
                      "The intact blob must be usable, or this test proves nothing about the truncated ones.")

        for keptBytes in [1, 2, 8, 12, good.count / 2, good.count - 1] {
            XCTAssertFalse(
                DownloadManager.shouldUseResumeBlob(Data(good.prefix(keptBytes))),
                "A resume blob truncated to \(keptBytes) of \(good.count) bytes must be discarded — feeding it to downloadTask(withResumeData:) either throws or silently restarts the track from zero."
            )
        }
    }

    /// Every possible truncation point of a realistically shaped blob, not just a
    /// hand-picked few — this is the property the fix actually needs to hold, and it's the
    /// check that caught a parse-only version of the gate letting one-byte prefixes
    /// through as OpenStep strings.
    func testNoPrefixOfARealResumeBlobIsEverAccepted() throws {
        let blob = try realisticResumeBlob()
        XCTAssertTrue(DownloadManager.shouldUseResumeBlob(blob))
        for keptBytes in 1..<blob.count {
            XCTAssertFalse(
                DownloadManager.shouldUseResumeBlob(Data(blob.prefix(keptBytes))),
                "Prefix of length \(keptBytes) (of \(blob.count)) was accepted; no partial write of a resume blob may be treated as resumable."
            )
        }
    }

    /// The trailing bytes specifically: an interrupted write loses the tail, which is
    /// where a bplist's trailer lives.
    func testResumeBlobMissingItsTrailerIsRejected() throws {
        let good = try binaryPlist(["NSURLSessionResumeInfoVersion": 2])
        XCTAssertGreaterThan(good.count, 32)
        XCTAssertFalse(
            DownloadManager.shouldUseResumeBlob(good.dropLast(8)),
            "Losing the last 8 bytes loses part of the bplist trailer; that blob must not be resumed from."
        )
    }

    // MARK: - The degenerate inputs

    /// No resume data at all — `cancel(byProducingResumeData:)` is allowed to hand back
    /// nil, and `pausedResumeData[key]` is empty for a track that was never paused.
    func testNilBlobIsRejected() {
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(nil))
    }

    /// A zero-byte file is exactly what a write that was killed before flushing anything
    /// leaves behind on disk for `restorePausedDownloads` to find.
    func testEmptyBlobIsRejected() {
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data()))
    }

    /// Bytes that are not a property list in any format.
    func testGarbageBytesAreRejected() {
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data(repeating: 0x00, count: 512)),
                       "A block of zeroes is a classic torn-write result, not a plist.")
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data("not a resume blob".utf8)))
    }

    /// A blob that starts with the right signature but is otherwise nonsense must not pass
    /// on the strength of its header alone — the parse, not the prefix, is the check.
    /// (`bplist00` on its own is the trap: the OpenStep parser reads it as a valid plist
    /// *string*, so only the dictionary-root requirement rejects it.)
    func testBinaryPlistHeaderAloneIsRejected() {
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data("bplist00".utf8)))
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data("bplist00\u{00}\u{00}garbage".utf8)))
    }

    /// `PropertyListSerialization` parses whitespace-only input as an empty dictionary, so
    /// "it parsed" alone is not enough — a blob with no keys can't resume anything.
    func testWhitespaceOnlyAndEmptyDictionaryBlobsAreRejected() throws {
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(Data(repeating: 0x20, count: 4096)),
                       "Whitespace parses as an empty plist dictionary; it is not resume data.")
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(try binaryPlist([:])),
                       "A well-formed but keyless plist carries no temp-file name or byte count — useless to downloadTask(withResumeData:).")
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(try xmlPlist([:])))
    }

    /// A plist whose root is an array or a string is well-formed but is not resume data.
    func testNonDictionaryRootIsRejected() throws {
        let array = try PropertyListSerialization.data(fromPropertyList: ["a", "b"] as [Any],
                                                       format: .binary, options: 0)
        XCTAssertFalse(DownloadManager.shouldUseResumeBlob(array))
    }

    // MARK: - The behavior that must be preserved

    /// The whole point of the store: a well-formed blob still resumes. A false negative
    /// here would silently turn every pause/resume into a full re-download.
    func testValidMinimalPlistIsAccepted() throws {
        XCTAssertTrue(DownloadManager.shouldUseResumeBlob(try binaryPlist(["NSURLSessionResumeInfoVersion": 2])),
                      "A single-key well-formed binary plist must pass: the gate checks well-formedness, not the resume-data schema.")
        XCTAssertTrue(DownloadManager.shouldUseResumeBlob(try xmlPlist(["NSURLSessionResumeInfoVersion": 2])),
                      "Resume data was XML-plist-shaped historically; the gate must not be binary-only.")
    }

    /// A realistically-shaped blob (the keys `URLSession` actually puts in one) passes.
    func testRealisticallyShapedResumeBlobIsAccepted() throws {
        XCTAssertTrue(DownloadManager.shouldUseResumeBlob(try realisticResumeBlob()))
    }

    /// The gate is a total function over arbitrary bytes: it must answer, never trap.
    /// `restorePausedDownloads` runs on every launch against whatever is on disk.
    func testArbitraryBytesNeverTrap() {
        for length in [1, 2, 7, 31, 33, 1024] {
            var bytes = Data(count: length)
            for i in 0..<length { bytes[i] = UInt8((i &* 37 &+ 11) % 256) }
            XCTAssertFalse(DownloadManager.shouldUseResumeBlob(bytes),
                           "Pseudo-random \(length)-byte input is not resume data.")
        }
    }
}
