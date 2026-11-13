import XCTest
@testable import ShelfHead_Watch

/// Batch 497 (REVIEW 2026-11-11 W6, W7): Book Details' Play and Download availability,
/// and the Watch half of the per-book speed round trip.
final class Batch497WatchDetailAndSpeedTests: XCTestCase {

    // MARK: W6 Book Details

    private func input(reachable: Bool = false, session: Bool = true,
                       network: Bool = true, server: Bool = true) -> WatchShelfInput {
        var input = WatchShelfInput()
        input.phoneIsReachable = reachable
        input.hasWatchSession = session
        input.networkIsAvailable = network
        input.serverIsReachable = server
        return input
    }

    func testStreamingOfflineIsUnavailable() {
        XCTAssertEqual(WatchBookDetailAvailability.playUnavailableReason(
            target: .watch, isDownloaded: false, isLoadedOnWatch: false, input: input(network: false)), .offline)
    }

    func testServerSilentIsUnavailable() {
        XCTAssertEqual(WatchBookDetailAvailability.playUnavailableReason(
            target: .watch, isDownloaded: false, isLoadedOnWatch: false, input: input(server: false)), .serverUnreachable)
    }

    func testNoSignInIsUnavailable() {
        XCTAssertEqual(WatchBookDetailAvailability.playUnavailableReason(
            target: .watch, isDownloaded: false, isLoadedOnWatch: false, input: input(session: false)), .noWatchSession)
    }

    func testADownloadPlaysOffline() {
        XCTAssertNil(WatchBookDetailAvailability.playUnavailableReason(
            target: .watch, isDownloaded: true, isLoadedOnWatch: false, input: input(session: false, network: false)))
    }

    func testTheBookLoadedOnTheWatchStillOpens() {
        XCTAssertNil(WatchBookDetailAvailability.playUnavailableReason(
            target: .watch, isDownloaded: false, isLoadedOnWatch: true, input: input(network: false)))
    }

    func testPlayOnIPhoneNeedsTheIPhone() {
        XCTAssertEqual(WatchBookDetailAvailability.playUnavailableReason(
            target: .iPhone, isDownloaded: false, isLoadedOnWatch: false, input: input(reachable: false)), .phoneOutOfReach)
        XCTAssertNil(WatchBookDetailAvailability.playUnavailableReason(
            target: .iPhone, isDownloaded: false, isLoadedOnWatch: false, input: input(reachable: true, network: false)))
    }

    func testOnlineAndSignedInStreams() {
        XCTAssertNil(WatchBookDetailAvailability.playUnavailableReason(
            target: .watch, isDownloaded: false, isLoadedOnWatch: false, input: input()))
    }

    func testDownloadNeedsANetworkAndTheServer() {
        XCTAssertNil(WatchBookDetailAvailability.downloadBlockedReason(input: input()))
        XCTAssertEqual(WatchBookDetailAvailability.downloadBlockedReason(input: input(network: false)), .offline)
        XCTAssertEqual(WatchBookDetailAvailability.downloadBlockedReason(input: input(server: false)), .serverUnreachable)
        XCTAssertEqual(WatchBookDetailAvailability.downloadBlockedReason(input: input(session: false)), .noWatchSession)
    }

    // MARK: W7 speed round trip

    func testANewWatchSpeedIsKeptAndSent() {
        let result = WatchPlaybackPreferences.settingWatchSpeed(1.5, forItem: "a", in: [:], phoneSpeeds: ["a": 1.2])
        XCTAssertEqual(result.map, ["a": 1.5])
        XCTAssertTrue(result.sendsToPhone)
    }

    func testASpeedThePhoneAlreadyHasIsNeitherKeptNorSent() {
        let result = WatchPlaybackPreferences.settingWatchSpeed(1.5, forItem: "a", in: ["b": 2.0], phoneSpeeds: ["a": 1.5])
        XCTAssertEqual(result.map, ["b": 2.0])
        XCTAssertFalse(result.sendsToPhone)
    }

    func testAnUnconfirmedEntryMeansTheNewSpeedIsSentEvenIfThePhoneMatches() {
        // 1.5 is on its way to the iPhone; going back to the iPhone's old 1.0 must follow it.
        let result = WatchPlaybackPreferences.settingWatchSpeed(1.0, forItem: "a", in: ["a": 1.5], phoneSpeeds: ["a": 1.0])
        XCTAssertEqual(result.map, ["a": 1.0])
        XCTAssertTrue(result.sendsToPhone)
    }

    func testThePhonesEchoConfirmsMatchingEntriesOnly() {
        let remaining = WatchPlaybackPreferences.acknowledged(
            watchBookSpeeds: ["a": 1.5, "b": 2.0, "c": 1.25],
            phoneSpeeds: ["a": 1.5, "b": 1.75])
        XCTAssertEqual(remaining, ["b": 2.0, "c": 1.25])
    }

    func testAnOldPhoneNeverConfirmsSoTheWatchKeepsItsSpeed() {
        let watch = ["a": 1.5]
        XCTAssertEqual(WatchPlaybackPreferences.acknowledged(watchBookSpeeds: watch, phoneSpeeds: nil), watch)
        XCTAssertEqual(WatchPlaybackPreferences.acknowledged(watchBookSpeeds: watch, phoneSpeeds: [:]), watch)
    }

    func testSpeedsMatchWithinThePhonesRounding() {
        XCTAssertTrue(WatchPlaybackPreferences.speedsMatch(1.25, 1.25))
        XCTAssertTrue(WatchPlaybackPreferences.speedsMatch(1.249999, 1.25))
        XCTAssertFalse(WatchPlaybackPreferences.speedsMatch(1.25, 1.3))
        XCTAssertFalse(WatchPlaybackPreferences.speedsMatch(nil, 1.25))
        XCTAssertFalse(WatchPlaybackPreferences.speedsMatch(.nan, .nan))
    }

    /// The round trip end to end through the pure steps: once the iPhone confirms, a later
    /// iPhone change for the book wins on the Watch (it didn't before Batch 497).
    func testAfterConfirmationALaterPhoneChangeWins() {
        var watch = WatchPlaybackPreferences.settingWatchSpeed(1.5, forItem: "a", in: [:], phoneSpeeds: ["a": 1.0]).map
        // The iPhone stores 1.5 and echoes its map.
        watch = WatchPlaybackPreferences.acknowledged(watchBookSpeeds: watch, phoneSpeeds: ["a": 1.5])
        XCTAssertTrue(watch.isEmpty)
        // Later the listener picks 2× on the iPhone.
        let later = WatchChapterSkipSettings(perBookSpeeds: ["a": 2.0])
        XCTAssertEqual(WatchPlaybackPreferences.startRate(itemId: "a", watchBookSpeeds: watch,
                                                          settings: later, watchLastRate: 1.5), 2.0)
    }

    func testThePayloadRoundTrips() throws {
        let update = WatchBookSpeedUpdate(itemId: "li_1", rate: 1.75)
        let decoded = try JSONDecoder().decode(WatchBookSpeedUpdate.self, from: JSONEncoder().encode(update))
        XCTAssertEqual(decoded, update)
    }
}
