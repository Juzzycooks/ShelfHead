import XCTest
@testable import ShelfHead

/// Exercises `WatchCommandValidator`/`WatchStaleness` directly, without a live
/// `WCSession` — these are exactly the interactions WATCH-1 (REVIEW_2026-08-12.md) was
/// about: a doc comment on `WatchModels.swift` already claimed this validator was
/// "exercised by unit tests," but it wasn't; this file makes that true.
final class WatchBridgeTests: XCTestCase {

    private let scope = WatchAccountScope(serverURL: "https://abs.example.com", accountId: "acct-1")
    private let otherScope = WatchAccountScope(serverURL: "https://abs.example.com", accountId: "acct-2")

    private func command(_ kind: WatchCommandKind, itemId: String? = "item-1") -> WatchPlaybackCommand {
        WatchPlaybackCommand(scope: scope, itemId: itemId, kind: kind)
    }

    /// `Result<Void, Failure>` isn't `Equatable` (`Void` isn't), so assert on the case
    /// directly rather than via `XCTAssertEqual(result, .success(()))`.
    private func assertSuccess(
        _ result: Result<Void, WatchCommandValidator.Failure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .failure(let reason) = result {
            XCTFail("Expected success, got failure(\(reason))", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Void, WatchCommandValidator.Failure>, _ expected: WatchCommandValidator.Failure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected failure(\(expected)), got success", file: file, line: line)
        case .failure(let reason):
            XCTAssertEqual(reason, expected, file: file, line: line)
        }
    }

    // MARK: - WatchStaleness threshold boundary

    func testExactlyAtThresholdIsNotYetStale() {
        let now = Date()
        let lastUpdated = now.addingTimeInterval(-WatchStaleness.threshold)
        // `isStale` uses a strict `>`, so exactly at the threshold is still fresh.
        XCTAssertFalse(WatchStaleness.isStale(lastUpdated: lastUpdated, now: now))
    }

    func testJustPastThresholdIsStale() {
        let now = Date()
        let lastUpdated = now.addingTimeInterval(-(WatchStaleness.threshold + 0.01))
        XCTAssertTrue(WatchStaleness.isStale(lastUpdated: lastUpdated, now: now))
    }

    func testWellWithinThresholdIsNotStale() {
        let now = Date()
        let lastUpdated = now.addingTimeInterval(-5)
        XCTAssertFalse(WatchStaleness.isStale(lastUpdated: lastUpdated, now: now))
    }

    // MARK: - WATCH-1: staleness only gates position-dependent commands

    func testStaleSnapshotBlocksAnAbsoluteSeek() {
        let now = Date()
        let staleUpdate = now.addingTimeInterval(-(WatchStaleness.threshold + 1))
        let result = WatchCommandValidator.validate(
            command(.seek(time: 120)),
            activeScope: scope, activeItemId: "item-1", stateLastUpdated: staleUpdate, now: now
        )
        assertFailure(result, .staleState)
    }

    func testStaleSnapshotDoesNotBlockPlayPause() {
        // This is the exact WATCH-1 regression: before scoping the staleness check to
        // position-dependent commands, a paused session left open past the threshold
        // (never refreshed because the old `pushIfNeeded` gated its periodic refresh
        // on `isPlaying`) made even play/pause fail here.
        let now = Date()
        let staleUpdate = now.addingTimeInterval(-(WatchStaleness.threshold + 1))
        let result = WatchCommandValidator.validate(
            command(.playPause),
            activeScope: scope, activeItemId: "item-1", stateLastUpdated: staleUpdate, now: now
        )
        assertSuccess(result)
    }

    func testStaleSnapshotDoesNotBlockPlaybackSpeed() {
        let now = Date()
        let staleUpdate = now.addingTimeInterval(-(WatchStaleness.threshold + 1))
        let result = WatchCommandValidator.validate(
            command(.setPlaybackSpeed(rate: 1.5)),
            activeScope: scope, activeItemId: "item-1", stateLastUpdated: staleUpdate, now: now
        )
        assertSuccess(result)
    }

    func testStaleSnapshotDoesNotBlockRewindOrForward() {
        let now = Date()
        let staleUpdate = now.addingTimeInterval(-(WatchStaleness.threshold + 1))
        for kind: WatchCommandKind in [.rewind(seconds: 15), .forward(seconds: 30)] {
            let result = WatchCommandValidator.validate(
                command(kind),
                activeScope: scope, activeItemId: "item-1", stateLastUpdated: staleUpdate, now: now
            )
            assertSuccess(result)
        }
    }

    func testStaleSnapshotBlocksBookmarkAndMarkFinished() {
        let now = Date()
        let staleUpdate = now.addingTimeInterval(-(WatchStaleness.threshold + 1))
        for kind: WatchCommandKind in [.addBookmark, .markFinished, .seekToBookmark(time: 42)] {
            let result = WatchCommandValidator.validate(
                command(kind),
                activeScope: scope, activeItemId: "item-1", stateLastUpdated: staleUpdate, now: now
            )
            assertFailure(result, .staleState)
        }
    }

    // MARK: - Scope / item / no-active-item

    func testScopeMismatchFails() {
        let result = WatchCommandValidator.validate(
            command(.playPause),
            activeScope: otherScope, activeItemId: "item-1", stateLastUpdated: Date()
        )
        assertFailure(result, .scopeMismatch)
    }

    func testItemMismatchFails() {
        let result = WatchCommandValidator.validate(
            command(.seek(time: 10), itemId: "item-1"),
            activeScope: scope, activeItemId: "item-2", stateLastUpdated: Date()
        )
        assertFailure(result, .itemMismatch)
    }

    func testNoActiveItemFailsForCommandsThatNeedOne() {
        let result = WatchCommandValidator.validate(
            command(.playPause),
            activeScope: scope, activeItemId: nil, stateLastUpdated: nil
        )
        assertFailure(result, .noActiveItem)
    }

    func testPlayItemDoesNotRequireAnActiveItem() {
        let result = WatchCommandValidator.validate(
            WatchPlaybackCommand(scope: scope, itemId: nil, kind: .playItem(itemId: "item-9")),
            activeScope: scope, activeItemId: nil, stateLastUpdated: nil
        )
        assertSuccess(result)
    }

    func testRequestSnapshotBypassesEverything() {
        // The one command a Watch that doesn't know its scope yet can send.
        let result = WatchCommandValidator.validate(
            WatchPlaybackCommand(scope: nil, itemId: nil, kind: .requestSnapshot),
            activeScope: nil, activeItemId: nil, stateLastUpdated: nil
        )
        assertSuccess(result)
    }

    // MARK: - Batch 414: markItemFinished

    func testMarkItemFinishedNeedsNoActiveOrMatchingItemOrFreshState() {
        let now = Date()
        let stale = now.addingTimeInterval(-(WatchStaleness.threshold + 1))
        let kind = WatchCommandKind.markItemFinished(itemId: "other-book")
        assertSuccess(WatchCommandValidator.validate(
            command(kind, itemId: "other-book"), activeScope: scope, activeItemId: nil, stateLastUpdated: nil, now: now))
        assertSuccess(WatchCommandValidator.validate(
            command(kind, itemId: "other-book"), activeScope: scope, activeItemId: "item-1", stateLastUpdated: stale, now: now))
    }

    func testMarkItemFinishedStillChecksScope() {
        let result = WatchCommandValidator.validate(
            command(.markItemFinished(itemId: "item-1")),
            activeScope: otherScope, activeItemId: "item-1", stateLastUpdated: Date()
        )
        assertFailure(result, .scopeMismatch)
    }

    func testMarkItemFinishedRoundTripsThroughJSON() throws {
        let original = command(.markItemFinished(itemId: "book-9"), itemId: "book-9")
        let decoded = try JSONDecoder().decode(WatchPlaybackCommand.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
