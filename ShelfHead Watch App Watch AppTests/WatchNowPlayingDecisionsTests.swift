// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and every sibling file in
// this target.
//
// Critique 2026-10-06 (shape → adapt + distill): pins the pure decisions behind the
// unified Watch Now Playing — the shared sleep copy, Always-On
// minute readouts, the standalone replace-a-playing-book decision, the cold-launch
// resume candidate, and the palette maths for the fallback accent, finished teal and
// alert ink. The SwiftUI layout itself isn't driven here.
import XCTest
@testable import ShelfHead_Watch

final class WatchNowPlayingDecisionsTests: XCTestCase {

    // MARK: - Sleep copy

    func testSleepTextCountsSecondsUnderAMinute() {
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 30), "30s left",
                       "companion used to say 1m left for the final 30 seconds")
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 15), "15s left")
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 0.4), "1s left")
    }

    func testSleepTextRoundsMinutesUp() {
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 900), "15m left")
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 870), "15m left", "14.5 minutes rounds up")
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 60), "1m left")
        XCTAssertEqual(WatchSleepStatus.remainingText(seconds: 59.5), "1m left", "never \"60s left\"")
    }

    func testSleepTextIsNilWhenNothingIsLeft() {
        XCTAssertNil(WatchSleepStatus.remainingText(seconds: 0))
        XCTAssertNil(WatchSleepStatus.remainingText(seconds: -3))
        XCTAssertNil(WatchSleepStatus.remainingText(seconds: .nan))
    }

    func testStandaloneTimerLabelMatchesSharedCopy() throws {
        let timer = try XCTUnwrap(StandaloneSleepTimer.minutes(15))
        XCTAssertEqual(timer.remainingLabel(currentTime: 0), WatchSleepStatus.remainingText(seconds: 900))
    }

    // MARK: - Always-On time readouts

    func testTimesShowSecondsNormally() {
        XCTAssertEqual(WatchNowPlayingTime.elapsed(3723, minuteLevel: false), "1:02:03")
        XCTAssertEqual(WatchNowPlayingTime.remaining(65, minuteLevel: false), "-1:05")
    }

    func testTimesDropToMinutesUnderAlwaysOn() {
        XCTAssertEqual(WatchNowPlayingTime.elapsed(3723, minuteLevel: true), "1h 2m", "elapsed rounds down")
        XCTAssertEqual(WatchNowPlayingTime.remaining(3723, minuteLevel: true), "-1h 3m", "remaining rounds up")
        XCTAssertEqual(WatchNowPlayingTime.remaining(20, minuteLevel: true), "-1m", "the last partial minute isn't 0m")
        XCTAssertEqual(WatchNowPlayingTime.elapsed(20, minuteLevel: true), "0m")
        XCTAssertEqual(WatchNowPlayingTime.remaining(-5, minuteLevel: true), "-0m")
    }

    // MARK: - Standalone play request

    func testNothingLoadedPlays() {
        XCTAssertEqual(StandalonePlayRequest.decide(requestedItemId: "b", loadedItemId: nil, isLoaded: false,
                                                    isPlaying: false, loadedTitle: ""), .playNow)
    }

    func testStoppedBookWithSameIdPlaysAgain() {
        // The engine keeps `currentItemId` after a stop; the resume hero must still start it.
        XCTAssertEqual(StandalonePlayRequest.decide(requestedItemId: "a", loadedItemId: "a", isLoaded: false,
                                                    isPlaying: false, loadedTitle: "A"), .playNow)
    }

    func testSameLoadedBookIsNotRestarted() {
        XCTAssertEqual(StandalonePlayRequest.decide(requestedItemId: "a", loadedItemId: "a", isLoaded: true,
                                                    isPlaying: true, loadedTitle: "A"), .alreadyLoaded)
    }

    func testDifferentPlayingBookAsksFirst() {
        XCTAssertEqual(StandalonePlayRequest.decide(requestedItemId: "b", loadedItemId: "a", isLoaded: true,
                                                    isPlaying: true, loadedTitle: "A"),
                       .confirmReplacing(currentTitle: "A"))
    }

    func testDifferentPausedBookPlaysWithoutAsking() {
        XCTAssertEqual(StandalonePlayRequest.decide(requestedItemId: "b", loadedItemId: "a", isLoaded: true,
                                                    isPlaying: false, loadedTitle: "A"), .playNow)
    }

    // MARK: - Cold-launch resume candidate

    private func input(_ id: String, duration: Double = 3600, downloaded: TimeInterval = 0,
                       position: Double? = nil, playedAt: Double? = nil) -> WatchResumeInput {
        WatchResumeInput(itemId: id, title: id.uppercased(), author: "Author", duration: duration,
                         downloadedAt: Date(timeIntervalSince1970: downloaded),
                         lastPosition: position, lastPlayedAt: playedAt)
    }

    func testNoDownloadsMeansNoCandidate() {
        XCTAssertNil(WatchResumeCandidate.pick(from: []))
    }

    func testMostRecentlyPlayedInProgressBookWins() throws {
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [
            input("old", downloaded: 300, position: 100, playedAt: 1_000),
            input("recent", downloaded: 100, position: 1800, playedAt: 5_000),
            input("unstarted", downloaded: 900),
        ]))
        XCTAssertEqual(pick.itemId, "recent")
        XCTAssertEqual(pick.kind, .resume)
        XCTAssertEqual(pick.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(pick.title, "RECENT")
    }

    func testFinishedBooksAreSkipped() throws {
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [
            input("done", position: 3590, playedAt: 9_000),
            input("midway", position: 600, playedAt: 1_000),
        ]))
        XCTAssertEqual(pick.itemId, "midway", "within 30s of the end counts as finished")
    }

    func testFallsBackToNewestUnstartedDownload() throws {
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [
            input("done", position: 3600, playedAt: 9_000),
            input("older", downloaded: 100),
            input("newer", downloaded: 500, position: 0),
        ]))
        XCTAssertEqual(pick.itemId, "newer")
        XCTAssertEqual(pick.kind, .start)
        XCTAssertEqual(pick.progress, 0)
    }

    func testEverythingFinishedMeansNoCandidate() {
        XCTAssertNil(WatchResumeCandidate.pick(from: [input("done", position: 3595, playedAt: 1)]))
    }

    func testUnknownDurationStillCountsAsInProgress() throws {
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [input("x", duration: 0, position: 42, playedAt: 1)]))
        XCTAssertEqual(pick.kind, .resume)
        XCTAssertEqual(pick.progress, 0)
    }

    func testPlayTimeTieGoesToNewerDownload() throws {
        let pick = try XCTUnwrap(WatchResumeCandidate.pick(from: [
            input("a", downloaded: 100, position: 10, playedAt: nil),
            input("b", downloaded: 200, position: 10, playedAt: nil),
        ]))
        XCTAssertEqual(pick.itemId, "b")
    }

    // MARK: - Palette

    func testDefaultAccentIsVUAmber() throws {
        let rgb = try XCTUnwrap(WatchPaletteMath.rgb(hex: WatchPaletteMath.defaultAccentHex))
        XCTAssertEqual(rgb.r, 0xE8 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgb.g, 0xA8 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgb.b, 0x38 / 255, accuracy: 0.0001)
    }

    func testDefaultAccentLeavesAnchorsUnchanged() throws {
        let teal = try XCTUnwrap(WatchPaletteMath.rgb(hex: "2FB6A8"))
        XCTAssertEqual(WatchPaletteMath.harmonized(anchorHex: "2FB6A8", accentHex: "E8A838"), teal)
        XCTAssertEqual(WatchPaletteMath.harmonized(anchorHex: "2FB6A8", accentHex: nil), teal)
        XCTAssertEqual(WatchPaletteMath.harmonized(anchorHex: "2FB6A8", accentHex: "808080"), teal,
                       "an achromatic accent has no hue to rotate by")
    }

    func testHarmonizedAnchorKeepsSaturationAndBrightness() {
        let teal = WatchPaletteMath.hsb(WatchPaletteMath.rgb(hex: "2FB6A8")!)
        let rotated = WatchPaletteMath.hsb(WatchPaletteMath.harmonized(anchorHex: "2FB6A8", accentHex: "6366F1"))
        XCTAssertEqual(rotated.s, teal.s, accuracy: 0.001)
        XCTAssertEqual(rotated.b, teal.b, accuracy: 0.001)
        XCTAssertNotEqual(rotated.h, teal.h, accuracy: 0.01)
    }

    func testHSBRoundTrips() {
        for hex in ["E8A838", "2FB6A8", "E0612F", "6366F1", "FFFFFF", "000000"] {
            let rgb = WatchPaletteMath.rgb(hex: hex)!
            let hsb = WatchPaletteMath.hsb(rgb)
            let back = WatchPaletteMath.rgb(h: hsb.h, s: hsb.s, b: hsb.b)
            XCTAssertEqual(back.r, rgb.r, accuracy: 0.002, hex)
            XCTAssertEqual(back.g, rgb.g, accuracy: 0.002, hex)
            XCTAssertEqual(back.b, rgb.b, accuracy: 0.002, hex)
        }
    }

    func testAlertInkIsContrastPicked() {
        // Burnt Orange: near-black ink measures about 5.2:1, white about 3.6:1.
        XCTAssertTrue(WatchPaletteMath.prefersDarkInk(on: WatchPaletteMath.rgb(hex: "E0612F")!))
        // A dark fill takes white.
        XCTAssertFalse(WatchPaletteMath.prefersDarkInk(on: WatchPaletteMath.rgb(hex: "1C3A6E")!))
    }

    func testBadHexIsRejected() {
        XCTAssertNil(WatchPaletteMath.rgb(hex: "12345"))
        XCTAssertNil(WatchPaletteMath.rgb(hex: "GGGGGG"))
    }
}
