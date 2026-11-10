import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (clarify, harden): plain copy on Settings' server screens —
/// Server Diagnostics' live status and `.notAudiobookshelf` advice, Server Backups'
/// error messages (were raw `localizedDescription`), and Active Sessions' per-device
/// sign-out confirmation title.
@MainActor
final class SettingsClarityTests: XCTestCase {

    // MARK: - Server Diagnostics

    func testLiveStatusCopy() {
        XCTAssertEqual(ServerDiagnosticsView.liveStatusCopy(.ok), "Connected")
        XCTAssertEqual(ServerDiagnosticsView.liveStatusCopy(.offline), "This iPhone is offline")
        XCTAssertEqual(ServerDiagnosticsView.liveStatusCopy(.serverUnreachable), "Your server isn\u{2019}t answering")
    }

    func testNotAudiobookshelfHasAdvice() {
        let advice = ServerDiagnosticsView.notAudiobookshelfAdvice
        XCTAssertTrue(advice.contains("Audiobookshelf"))
        XCTAssertTrue(advice.contains("Reverse Proxy Headers"), "Should point at where to fix a proxy gate.")
    }

    // MARK: - Server Backups

    func testBackupLoadFailureCopyIsPlain() {
        XCTAssertTrue(ServerBackupsView.loadFailureMessage(for: URLError(.notConnectedToInternet)).hasPrefix("You\u{2019}re offline"))
        XCTAssertTrue(ServerBackupsView.loadFailureMessage(for: APIError.unauthorized).contains("expired"))
        XCTAssertEqual(ServerBackupsView.loadFailureMessage(for: APIError.serverError(500)),
                       "Your server didn\u{2019}t answer. Try again in a moment.")
    }

    func testBackupCreateFailureCopyIsPlain() {
        XCTAssertTrue(ServerBackupsView.createFailureMessage(for: URLError(.networkConnectionLost)).contains("no backup was made"))
        XCTAssertEqual(ServerBackupsView.createFailureMessage(for: APIError.forbidden), "Only server admins can make backups.")
        let generic = ServerBackupsView.createFailureMessage(for: APIError.httpError(418))
        XCTAssertFalse(generic.contains("418"), "No internal codes in the primary message.")
    }

    // MARK: - Active Sessions

    func testSessionSignOutTitleNamesTheDevice() {
        XCTAssertEqual(ActiveSessionsView.sessionSignOutTitle(deviceName: "Kitchen iPad"),
                       "Sign Out \u{201C}Kitchen iPad\u{201D}?")
        XCTAssertEqual(ActiveSessionsView.sessionSignOutTitle(deviceName: "  "), "Sign Out This Device?")
    }
}
