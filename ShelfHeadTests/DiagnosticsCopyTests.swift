import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): pins the plain-words copy for Diagnostics > Sync Now and
/// Server Diagnostics' live check / session rows.
final class DiagnosticsCopyTests: XCTestCase {
    func testSyncNothingWaiting() {
        XCTAssertEqual(SyncNowResult(positionsBefore: 0, positionsAfter: 0, bookmarksBefore: 0, bookmarksAfter: 0).message,
                       "Nothing waiting to sync.")
    }

    func testSyncAllSynced() {
        XCTAssertEqual(SyncNowResult(positionsBefore: 3, positionsAfter: 0, bookmarksBefore: 0, bookmarksAfter: 0).message,
                       "Synced 3 items.")
        XCTAssertEqual(SyncNowResult(positionsBefore: 1, positionsAfter: 0, bookmarksBefore: 0, bookmarksAfter: 0).message,
                       "Synced 1 item.")
    }

    func testSyncUnreachable() {
        XCTAssertEqual(SyncNowResult(positionsBefore: 2, positionsAfter: 2, bookmarksBefore: 0, bookmarksAfter: 0).message,
                       "Couldn\u{2019}t reach your server \u{2014} 2 still waiting.")
    }

    func testSyncPartial() {
        XCTAssertEqual(SyncNowResult(positionsBefore: 3, positionsAfter: 1, bookmarksBefore: 0, bookmarksAfter: 0).message,
                       "Synced 2 \u{2014} 1 still waiting.")
    }

    func testCheckOutcomeCopy() {
        XCTAssertEqual(ServerDiagnosticsView.checkOutcomeCopy(.reachable), "Your server answered.")
        XCTAssertEqual(ServerDiagnosticsView.checkOutcomeCopy(.unreachable), "Couldn\u{2019}t reach your server.")
    }

    func testSessionLabel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ServerDiagnosticsView.sessionLabel(hasAccessToken: false, hasRefreshToken: false, expiry: nil, now: now), "Signed out")
        XCTAssertEqual(ServerDiagnosticsView.sessionLabel(hasAccessToken: true, hasRefreshToken: true, expiry: nil, now: now), "Signed in")
        XCTAssertEqual(ServerDiagnosticsView.sessionLabel(hasAccessToken: true, hasRefreshToken: true, expiry: now.addingTimeInterval(-5), now: now),
                       "Signed in \u{00B7} renews automatically")
        XCTAssertEqual(ServerDiagnosticsView.sessionLabel(hasAccessToken: true, hasRefreshToken: false, expiry: now.addingTimeInterval(-5), now: now),
                       "Session expired \u{00B7} sign in again")
        XCTAssertTrue(ServerDiagnosticsView.sessionLabel(hasAccessToken: true, hasRefreshToken: true, expiry: now.addingTimeInterval(60), now: now)
            .hasPrefix("Signed in \u{00B7} valid until "))
    }
}
