import XCTest
@testable import ShelfHead_Watch

/// Batch 495 (REVIEW 2026-11-11 W6): the Shelf says which books are on the Watch, and a
/// stream that can't play right now is dimmed with its reason.
final class Batch495WatchShelfTests: XCTestCase {
    private func book(_ id: String) -> WatchShelfBook {
        WatchShelfBook(itemId: id, title: "Title \(id)", author: "Author", progress: 0.3)
    }

    private func standaloneInput() -> WatchShelfInput {
        var input = WatchShelfInput()
        input.isStandaloneMode = true
        input.hasWatchSession = true
        return input
    }

    // MARK: Downloaded mark

    func testDownloadedBooksCarryTheMarkAndStreamsDont() {
        var input = standaloneInput()
        input.serverInProgress = [book("s")]
        input.downloads = [book("d")]
        let sleeves = WatchShelf.sleeves(for: input)
        XCTAssertEqual(sleeves.first { $0.id == "s" }?.isDownloaded, false)
        XCTAssertEqual(sleeves.first { $0.id == "d" }?.isDownloaded, true)
        XCTAssertEqual(sleeves.last?.kind, .browse)
        XCTAssertEqual(sleeves.last?.isDownloaded, false)
    }

    func testCurrentBookAndFinishedDownloadsUseTheFullDownloadedSet() {
        var input = standaloneInput()
        input.watchCurrent = book("w")
        input.serverInProgress = [book("f")]
        // "f" is downloaded but finished, so `downloads` (shelf order) leaves it off.
        input.downloadedItemIds = ["w", "f"]
        let sleeves = WatchShelf.sleeves(for: input)
        XCTAssertEqual(sleeves.first { $0.id == "w" }?.isDownloaded, true)
        XCTAssertEqual(sleeves.first { $0.id == "f" }?.isDownloaded, true)
        XCTAssertEqual(sleeves.first { $0.id == "f" }?.kind, .book(target: .watch, isAvailable: true))
    }

    // MARK: Can't play right now

    func testOfflineStreamIsDimmedWithItsReasonAndDownloadsStayPlayable() {
        var input = standaloneInput()
        input.networkIsAvailable = false
        input.serverInProgress = [book("s")]
        input.downloads = [book("d")]
        let sleeves = WatchShelf.sleeves(for: input)
        let stream = sleeves.first { $0.id == "s" }
        XCTAssertEqual(stream?.kind, .book(target: .watch, isAvailable: false))
        XCTAssertEqual(stream?.unavailableReason, .offline)
        XCTAssertEqual(stream?.sourceSystemImage, "wifi.slash")
        let download = sleeves.first { $0.id == "d" }
        XCTAssertEqual(download?.kind, .book(target: .watch, isAvailable: true))
        XCTAssertNil(download?.unavailableReason)
    }

    func testCachedInProgressListMeansTheServerIsUnreachable() {
        var input = standaloneInput()
        input.serverIsReachable = false
        input.serverInProgress = [book("s")]
        let stream = WatchShelf.sleeves(for: input).first
        XCTAssertEqual(stream?.isAvailable, false)
        XCTAssertEqual(stream?.unavailableReason, .serverUnreachable)
    }

    func testNoWatchSessionOutranksTheNetwork() {
        var input = WatchShelfInput()
        input.isStandaloneMode = true
        input.networkIsAvailable = false
        input.mirroredInProgress = [book("m")]
        XCTAssertEqual(WatchShelf.sleeves(for: input).first?.unavailableReason, .noWatchSession)
    }

    func testPhoneOutOfReachKeepsTheCrossedOutPhone() {
        var input = WatchShelfInput()
        input.mirroredInProgress = [book("m")]
        input.phoneIsReachable = false
        input.networkIsAvailable = false
        let sleeve = WatchShelf.sleeves(for: input).first
        XCTAssertEqual(sleeve?.unavailableReason, .phoneOutOfReach)
        XCTAssertEqual(sleeve?.sourceSystemImage, "iphone.slash")
    }

    func testCompanionBooksPlayingOnThePhoneIgnoreTheWatchNetwork() {
        var input = WatchShelfInput()
        input.phoneIsReachable = true
        input.hasWatchSession = true
        input.networkIsAvailable = false
        input.serverIsReachable = false
        input.serverInProgress = [book("s")]
        let sleeve = WatchShelf.sleeves(for: input).first
        XCTAssertEqual(sleeve?.kind, .book(target: .iPhone, isAvailable: true))
        XCTAssertNil(sleeve?.unavailableReason)
    }

    func testAvailableSleevesHaveNoReasonAndCurrentSleevesAreNeverDimmed() {
        var input = standaloneInput()
        input.networkIsAvailable = false
        input.watchCurrent = book("w")
        let sleeve = WatchShelf.sleeves(for: input).first
        XCTAssertEqual(sleeve?.kind, .current(source: .watch, isPlaying: false))
        XCTAssertEqual(sleeve?.isAvailable, true)
        XCTAssertNil(sleeve?.unavailableReason)
    }

    func testUnavailableReasonMatrix() {
        var input = standaloneInput()
        XCTAssertNil(WatchShelf.unavailableReason(target: .watch, isDownloaded: false, input: input))
        input.networkIsAvailable = false
        XCTAssertNil(WatchShelf.unavailableReason(target: .watch, isDownloaded: true, input: input),
                     "a download always plays")
        XCTAssertEqual(WatchShelf.unavailableReason(target: .watch, isDownloaded: false, input: input), .offline)
        input.phoneIsReachable = true
        XCTAssertNil(WatchShelf.unavailableReason(target: .iPhone, isDownloaded: false, input: input))
    }
}
