import XCTest
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 Y6, F17): the pure decisions behind the Siri/Shortcuts and
/// Control Centre quick wins.
final class QuickWinsSystemTests: XCTestCase {

    // MARK: Sleep timer intent

    func testSleepTimerCeilingMatchesPlayerCustomRange() {
        XCTAssertEqual(StartSleepTimerIntent.maxSleepTimerMinutes, 180)
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(90), .valid(90))
        XCTAssertEqual(StartSleepTimerIntent.validatedSleepTimerMinutes(181), .capped(180))
    }

    func testConfirmationNamesTheValueActuallySet() {
        XCTAssertNil(StartSleepTimerIntent.confirmationMinutes(for: .tooLow))
        XCTAssertEqual(StartSleepTimerIntent.confirmationMinutes(for: .valid(45)), 45)
        XCTAssertEqual(StartSleepTimerIntent.confirmationMinutes(for: .capped(180)), 180)
    }

    // MARK: Book picker suggestions

    func testSuggestionsPutInProgressFirstNewestPlayedFirst() {
        let now = Date()
        let ids = AudiobookQuery.suggestedIDs(
            inProgress: [(id: "old", lastPlayed: now.addingTimeInterval(-500)),
                         (id: "new", lastPlayed: now)],
            downloadedIDs: ["a", "old", "b"])
        XCTAssertEqual(ids, ["new", "old", "a", "b"])
    }

    func testSuggestionsCapAtTenAndDedupe() {
        let downloaded = (0..<20).map { "d\($0)" }
        let ids = AudiobookQuery.suggestedIDs(inProgress: [(id: "d3", lastPlayed: Date())], downloadedIDs: downloaded)
        XCTAssertEqual(ids.count, 10)
        XCTAssertEqual(ids.first, "d3")
        XCTAssertEqual(Set(ids).count, 10)
    }

    func testSuggestionsWithNothingPublishedFallBackToDownloads() {
        XCTAssertEqual(AudiobookQuery.suggestedIDs(inProgress: [], downloadedIDs: ["x", "y"]), ["x", "y"])
        XCTAssertEqual(AudiobookQuery.suggestedIDs(inProgress: [], downloadedIDs: []), [])
    }

    // MARK: Control Centre skip guard

    private func snapshot(isPlaying: Bool, age: TimeInterval, now: Date) -> SharedPlayback.Snapshot {
        SharedPlayback.Snapshot(itemId: "i", title: "T", author: "A", currentTime: 10, duration: 100,
                                isPlaying: isPlaying, updatedAt: now.addingTimeInterval(-age))
    }

    func testControlSkipOnlyWhenFreshAndPlaying() {
        let now = Date()
        XCTAssertFalse(ControlSkipGuard.shouldPostSkip(snapshot: nil, now: now))
        XCTAssertTrue(ControlSkipGuard.shouldPostSkip(snapshot: snapshot(isPlaying: true, age: 5, now: now), now: now))
        XCTAssertFalse(ControlSkipGuard.shouldPostSkip(snapshot: snapshot(isPlaying: false, age: 5, now: now), now: now))
        XCTAssertFalse(ControlSkipGuard.shouldPostSkip(snapshot: snapshot(isPlaying: true, age: 120, now: now), now: now))
    }
}
