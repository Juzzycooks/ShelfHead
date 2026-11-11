// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section.
//
// Batch 490 (REVIEW 2026-11-11 W1, W4, W11, W14, F29): pins the pure decisions behind the
// Watch library quick wins: the "bigger than the limit" room plan and its copy, the
// Storage Limit setting and the cap built from it, saving and stopping this Watch before
// Play on iPhone, leaving podcast libraries out of the standalone picker, and the
// Sessions row's device name and last-used date.
import XCTest
@testable import ShelfHead_Watch

@MainActor
final class QuickWinsWatchLibraryTests: XCTestCase {

    private let mib: Int64 = 1024 * 1024

    private func download(_ id: String, bytes: Int64) -> WatchLocalDownload {
        WatchLocalDownload(id: id, title: id, author: "Author", duration: 3600, tracks: [], totalBytes: bytes,
                           downloadedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - W1: bigger than the limit

    func testBookBiggerThanTheLimitIsItsOwnOutcome() {
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 600 * mib, downloads: [], capBytes: 500 * mib,
                                                  limitBytes: 500 * mib, protectedItemIds: [], listening: [:]),
                       .biggerThanLimit)
    }

    func testBiggerThanTheLimitWinsOverRemovableBooks() {
        // A finished book could be removed, but removing it can never make a 600 MB book fit 500 MB.
        let items = [download("done", bytes: 100 * mib)]
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 600 * mib, downloads: items, capBytes: 500 * mib,
                                                  limitBytes: 500 * mib, protectedItemIds: [],
                                                  listening: ["done": .finished]),
                       .biggerThanLimit)
    }

    func testABookExactlyAtTheLimitIsNotTooBig() {
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 500 * mib, downloads: [], capBytes: 500 * mib,
                                                  limitBytes: 500 * mib, protectedItemIds: [], listening: [:]),
                       .fits)
    }

    func testWithoutALimitThePlanIsUnchanged() {
        let items = [download("reading", bytes: 400)]
        XCTAssertEqual(WatchDownloadRoomPlan.plan(newBytes: 200, downloads: items, capBytes: 450, protectedItemIds: [],
                                                  listening: ["reading": .inProgress]),
                       .noRoom)
    }

    func testBiggerThanLimitCopyPointsAtTheSettingWhenALargerLimitFits() {
        XCTAssertEqual(WatchDownloadRoomCopy.biggerThanLimit(bookBytes: 612_000_000, limitBytes: 500 * mib),
                       "This book is 612 MB. ShelfHead keeps up to 500 MB on this Watch. Raise the Storage Limit to download it.")
    }

    func testBiggerThanLimitCopySaysStreamWhenNoLimitFits() {
        XCTAssertEqual(WatchDownloadRoomCopy.biggerThanLimit(bookBytes: 5_200_000_000, limitBytes: 4096 * mib),
                       "This book is 5.2 GB. ShelfHead keeps up to 4 GB on this Watch, so stream it instead.")
    }

    // MARK: - F29: Storage Limit

    func testStorageLimitDefaultsTo500MB() {
        XCTAssertEqual(WatchDownloadStorageLimit.default, .mb500)
        XCTAssertEqual(WatchDownloadStorageLimit.stored(0), .mb500, "nothing stored")
        XCTAssertEqual(WatchDownloadStorageLimit.stored(3), .mb500, "unknown value")
        XCTAssertEqual(WatchDownloadStorageLimit.stored(2048), .gb2)
        XCTAssertEqual(WatchDownloadStorageLimit.default.bytes, WatchDownloadCap.fixedCeilingBytes,
                       "the default keeps the old fixed ceiling")
    }

    func testStorageLimitChoicesAndLabels() {
        XCTAssertEqual(WatchDownloadStorageLimit.allCases.map(\.rawValue), [500, 1024, 2048, 4096])
        XCTAssertEqual(WatchDownloadStorageLimit.allCases.map(\.label), ["500 MB", "1 GB", "2 GB", "4 GB"])
        XCTAssertEqual(WatchDownloadStorageLimit.gb4.bytes, 4 * 1024 * mib)
    }

    func testCanRaiseOnlyWhenSomeChoiceFits() {
        XCTAssertTrue(WatchDownloadStorageLimit.canRaise(toFit: 3 * 1024 * mib))
        XCTAssertTrue(WatchDownloadStorageLimit.canRaise(toFit: 4 * 1024 * mib))
        XCTAssertFalse(WatchDownloadStorageLimit.canRaise(toFit: 4 * 1024 * mib + 1))
    }

    func testCapIsTheSmallerOfTheLimitAndHalfTheFreeSpace() {
        let limit = WatchDownloadStorageLimit.gb2.bytes
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: nil, limitBytes: limit), limit,
                       "free space unknown: the limit")
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: 10 * 1024 * mib, limitBytes: limit), limit)
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: 2 * 1024 * mib, limitBytes: limit), 1024 * mib,
                       "half the free space when that is smaller")
        XCTAssertEqual(WatchDownloadCap.capBytes(availableBytes: 2 * 1024 * mib, pendingBytes: 1024 * mib, limitBytes: limit),
                       512 * mib)
    }

    // MARK: - W4: Play on iPhone while this Watch has a book loaded

    func testPlayOnPhoneLeavesAnIdleWatchAlone() {
        XCTAssertEqual(WatchPlayOnPhoneWatchAction.decide(engineIsLoaded: false, engineIsPlaying: false, engineTitle: ""),
                       .nothing)
    }

    func testPlayOnPhoneStopsAPausedWatchWithoutAsking() {
        XCTAssertEqual(WatchPlayOnPhoneWatchAction.decide(engineIsLoaded: true, engineIsPlaying: false, engineTitle: "Dune"),
                       .stopWatch)
    }

    func testPlayOnPhoneAsksBeforeStoppingAPlayingWatch() {
        XCTAssertEqual(WatchPlayOnPhoneWatchAction.decide(engineIsLoaded: true, engineIsPlaying: true, engineTitle: "Dune"),
                       .confirmStoppingWatch(currentTitle: "Dune"))
    }

    // MARK: - W11: podcast libraries

    func testPodcastLibrariesAreLeftOut() {
        XCTAssertFalse(WatchLibraryChoice.isPlayable(mediaType: "podcast"))
        XCTAssertFalse(WatchLibraryChoice.isPlayable(mediaType: "Podcast"))
        XCTAssertTrue(WatchLibraryChoice.isPlayable(mediaType: "book"))
        XCTAssertTrue(WatchLibraryChoice.isPlayable(mediaType: nil), "older servers send no media type")
    }

    func testDefaultLibraryKeepsAStoredChoiceOnlyWhenOffered() {
        XCTAssertEqual(WatchLibraryChoice.defaultLibraryId(candidateIds: ["a", "b"], storedId: "b"), "b")
        XCTAssertEqual(WatchLibraryChoice.defaultLibraryId(candidateIds: ["a", "b"], storedId: "pod"), "a",
                       "a stored podcast library falls back to the first book library")
        XCTAssertEqual(WatchLibraryChoice.defaultLibraryId(candidateIds: ["a"], storedId: nil), "a")
        XCTAssertNil(WatchLibraryChoice.defaultLibraryId(candidateIds: [], storedId: "pod"))
    }

    // MARK: - W14: Sessions row

    func testDeviceNameIsTheUserAgentPrefix() {
        XCTAssertEqual(WatchSessionLabel.deviceName(userAgent: "ShelfHead/7.5 CFNetwork/3826 Darwin/25.0.0"), "ShelfHead")
        XCTAssertEqual(WatchSessionLabel.deviceName(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"), "Mozilla")
        XCTAssertEqual(WatchSessionLabel.deviceName(userAgent: "okhttp (Android)"), "okhttp")
        XCTAssertEqual(WatchSessionLabel.deviceName(userAgent: "Plain Name"), "Plain Name")
    }

    func testDeviceNameIsNilWhenNothingReadable() {
        XCTAssertNil(WatchSessionLabel.deviceName(userAgent: nil))
        XCTAssertNil(WatchSessionLabel.deviceName(userAgent: ""))
        XCTAssertNil(WatchSessionLabel.deviceName(userAgent: "/1.0"))
        XCTAssertNil(WatchSessionLabel.deviceName(userAgent: "  (x)"))
    }

    func testLastUsedPrefersUpdatedAt() {
        XCTAssertEqual(WatchSessionLabel.lastUsedDate(updatedAtMs: 1_700_000_000_000, createdAtMs: 1_600_000_000_000),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(WatchSessionLabel.lastUsedDate(updatedAtMs: nil, createdAtMs: 1_600_000_000_000),
                       Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertNil(WatchSessionLabel.lastUsedDate(updatedAtMs: nil, createdAtMs: nil))
        XCTAssertNil(WatchSessionLabel.lastUsedDate(updatedAtMs: 0, createdAtMs: nil))
    }
}
