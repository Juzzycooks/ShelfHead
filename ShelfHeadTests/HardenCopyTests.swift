import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): copy for Sign Out (this server), Remove All Servers, Sign
/// Out All Devices, a deleted bookmark's Undo toast and a
/// failed undo on Recent Changes. The views need live view models, so the wording is tested
/// as statics (the `LibraryView.isPrimaryScope` precedent).
@MainActor
final class HardenCopyTests: XCTestCase {

    // MARK: Sign Out (this server only — critique 2026-10-06, second run)

    private func plan(host: String = "abs.example.org", next: String? = nil, remaining: Int = 0)
        -> AuthViewModel.SignOutPlan {
        AuthViewModel.SignOutPlan(host: host, nextHost: next, remainingServers: remaining)
    }

    func testSignOutLabelAndTitleNameTheServer() {
        XCTAssertEqual(AccountSecuritySettingsView.signOutLabel(serverURL: "https://abs.example.org/abs"),
                       "Sign Out of abs.example.org")
        XCTAssertEqual(AccountSecuritySettingsView.signOutLabel(serverURL: ""), "Sign Out")
        XCTAssertEqual(AccountSecuritySettingsView.signOutTitle(host: "abs.example.org"), "Sign Out of abs.example.org?")
    }

    func testSignOutSaysItIsThisServerOnlyAndWhatHappensToDownloads() {
        let text = AccountSecuritySettingsView.signOutMessage(plan: plan(), unsyncedPositions: 0,
                                                              offlineWithBookLoaded: false)
        XCTAssertTrue(text.hasPrefix("Playback stops, Up Next is cleared"))
        XCTAssertTrue(text.contains("this server\u{2019}s saved sign-in is removed from this device"))
        XCTAssertTrue(text.contains("Downloaded books stay here and come back when you sign in to it again with the same username"))
        XCTAssertFalse(text.contains("every saved server"))
        XCTAssertFalse(text.contains("listening position"))
        XCTAssertFalse(text.contains("offline"))
        XCTAssertFalse(text.lowercased().contains("are you sure"))
    }

    func testSignOutNamesTheServerItSwitchesTo() {
        let text = AccountSecuritySettingsView.signOutMessage(plan: plan(next: "home.local", remaining: 2),
                                                              unsyncedPositions: 0, offlineWithBookLoaded: false)
        XCTAssertTrue(text.hasSuffix("ShelfHead then switches to home.local."))
    }

    func testSignOutWithoutAnAutomaticSwitchSaysTheOtherServersStay() {
        XCTAssertTrue(AccountSecuritySettingsView.signOutMessage(plan: plan(remaining: 1), unsyncedPositions: 0,
                                                                 offlineWithBookLoaded: false)
            .hasSuffix("Your other saved server stays, ready to sign in to."))
        XCTAssertTrue(AccountSecuritySettingsView.signOutMessage(plan: plan(remaining: 3), unsyncedPositions: 0,
                                                                 offlineWithBookLoaded: false)
            .hasSuffix("Your other saved servers stay, ready to sign in to."))
    }

    func testSignOutWarnsAboutUnsyncedPositions() {
        XCTAssertTrue(AccountSecuritySettingsView.signOutMessage(plan: plan(), unsyncedPositions: 1, offlineWithBookLoaded: false)
            .hasSuffix("1 listening position hasn\u{2019}t reached your server yet. It\u{2019}ll sync if you sign back in to this server within 30 days."))
        XCTAssertTrue(AccountSecuritySettingsView.signOutMessage(plan: plan(), unsyncedPositions: 3, offlineWithBookLoaded: true)
            .hasSuffix("3 listening positions haven\u{2019}t reached your server yet. They\u{2019}ll sync if you sign back in to this server within 30 days."))
    }

    func testSignOutWarnsWhenOfflineWithABookLoaded() {
        XCTAssertTrue(AccountSecuritySettingsView.signOutMessage(plan: plan(), unsyncedPositions: 0, offlineWithBookLoaded: true)
            .hasSuffix("You\u{2019}re offline, so your place in the current book won\u{2019}t reach your server."))
    }

    // MARK: Remove All Servers from This Device

    func testRemoveAllServersSaysWhatIsRemovedAndThatDownloadsStay() {
        let text = AccountSecuritySettingsView.removeAllServersMessage(serverCount: 3, unsyncedPositions: 0,
                                                                       offlineWithBookLoaded: false)
        XCTAssertTrue(text.hasPrefix("Signs out and removes all 3 saved servers and their passwords from this device."))
        XCTAssertTrue(text.contains("Downloaded books stay here and come back when you sign in to each server again"))
        XCTAssertFalse(text.lowercased().contains("are you sure"))
        XCTAssertTrue(AccountSecuritySettingsView.removeAllServersMessage(serverCount: 1, unsyncedPositions: 0,
                                                                          offlineWithBookLoaded: false)
            .hasPrefix("Signs out and removes your saved server and its password"))
    }

    func testRemoveAllServersKeepsTheUnsyncedWarning() {
        XCTAssertTrue(AccountSecuritySettingsView.removeAllServersMessage(serverCount: 2, unsyncedPositions: 2,
                                                                          offlineWithBookLoaded: false)
            .hasSuffix("They\u{2019}ll sync if you sign back in to that server within 30 days."))
    }

    func testRemovingTheCurrentServerSaysTheOthersStay() {
        XCTAssertEqual(AccountSecuritySettingsView.removeAccountMessage(username: "demo", host: "h", isCurrent: false),
                       "\u{201C}demo on h\u{201D} and its downloads are removed from this device.")
        XCTAssertTrue(AccountSecuritySettingsView.removeAccountMessage(username: "demo", host: "h", isCurrent: true)
            .hasSuffix("You\u{2019}re signed out of it; your other saved servers stay."))
    }

    // MARK: Sign Out All Devices

    func testSignOutAllDevicesIsThisAccountOnThisServer() {
        let text = ActiveSessionsView.signOutAllMessage(plan: plan(), username: "demo",
                                                        unsyncedPositions: 0, offlineWithBookLoaded: false)
        XCTAssertTrue(text.hasPrefix("Ends every session for \u{201C}demo\u{201D} on abs.example.org, including this one."))
        XCTAssertTrue(text.hasSuffix("This device signs out of abs.example.org; downloads stay."))
        XCTAssertTrue(ActiveSessionsView.signOutAllMessage(plan: plan(next: "home.local", remaining: 1), username: "demo",
                                                           unsyncedPositions: 0, offlineWithBookLoaded: false)
            .hasSuffix("This device switches to home.local; downloads stay."))
    }

    func testSignOutAllDevicesReusesTheUnsyncedWarning() {
        XCTAssertTrue(ActiveSessionsView.signOutAllMessage(plan: plan(), username: "demo",
                                                           unsyncedPositions: 1, offlineWithBookLoaded: false)
            .hasSuffix("It\u{2019}ll sync if you sign back in to this server within 30 days."))
    }

    func testActiveSessionsErrorsArePlainCopy() {
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual(ActiveSessionsView.loadFailureMessage(for: offline),
                       "You\u{2019}re offline. Connect to the internet and try again.")
        XCTAssertEqual(ActiveSessionsView.loadFailureMessage(for: APIError.serverError(500)),
                       "Your server didn\u{2019}t answer. Try again in a moment.")
        XCTAssertTrue(ActiveSessionsView.endSessionFailureMessage(for: offline).hasPrefix("You\u{2019}re offline"))
        XCTAssertFalse(ActiveSessionsView.endSessionFailureMessage(for: APIError.serverError(500)).contains("500"))
    }

    // MARK: Bookmark Undo

    func testDeletedBookmarkWithANoteNamesIt() {
        XCTAssertEqual(BookDetailView.bookmarkDeletedMessage(title: "The gate", time: 125),
                       "Deleted \u{201C}The gate\u{201D}")
    }

    func testDeletedBookmarkWithOnlyATimeSaysTheTime() {
        XCTAssertEqual(BookDetailView.bookmarkDeletedMessage(title: "2:05", time: 125), "Deleted bookmark at 2:05")
        XCTAssertEqual(BookDetailView.bookmarkDeletedMessage(title: "", time: 3723), "Deleted bookmark at 1:02:03")
    }

    // MARK: Recent Changes

    func testUndoFailureCopy() {
        XCTAssertEqual(PlaybackHistoryView.undoFailureTitle, "Couldn\u{2019}t Undo")
        XCTAssertEqual(PlaybackHistoryView.undoFailureMessage(reachability: .serverUnreachable),
                       "Couldn\u{2019}t reach your server, so nothing changed. Try again when connected.")
        XCTAssertEqual(PlaybackHistoryView.undoFailureMessage(reachability: .offline),
                       "This device is offline, so nothing changed. Try again when connected.")
        // Critique 2026-10-06: no network cause asserted when reachability is fine.
        XCTAssertEqual(PlaybackHistoryView.undoFailureMessage(reachability: .ok),
                       "Couldn\u{2019}t undo this change. Try again.")
    }

    func testClearRecentChangesCopyNamesWhatClearingMeans() {
        XCTAssertEqual(PlaybackHistoryView.clearAlertTitle, "Clear Recent Changes?")
        XCTAssertTrue(PlaybackHistoryView.clearAlertMessage.contains("undo entries"))
        XCTAssertTrue(PlaybackHistoryView.clearAlertMessage.contains("server"))
        XCTAssertEqual(PlaybackHistoryView.supersededCaption, "Changed since")
    }

    func testRepairSummaryPluralisation() {
        XCTAssertEqual(DownloadHealthView.repairSummary(broken: 1, total: 1), "1 track of 1 needs repair")
        XCTAssertEqual(DownloadHealthView.repairSummary(broken: 1, total: 8), "1 track of 8 needs repair")
        XCTAssertEqual(DownloadHealthView.repairSummary(broken: 3, total: 8), "3 tracks of 8 need repair")
    }

    func testSwipeActionTintsClearAAWithWhite() {
        // Every selectable accent, not just the default: the tints follow the accent.
        for (_, accent) in AppTheme.accentOptions {
            let amber = AppTheme.adjustedHexForContrast(accent, backgroundHex: "FFFFFF")
            let teal = AppTheme.adjustedHexForContrast(
                AppTheme.hueHarmonizedHex(anchorHex: AppTheme.SecondaryAnchor.accentLight, accentHex: accent),
                backgroundHex: "FFFFFF")
            for hex in [amber, teal, LibrarySwipeTint.neutralHex] {
                XCTAssertGreaterThanOrEqual(LibrarySwipeTint.whiteContrast(hex: hex), 4.5, "\(accent) → \(hex)")
            }
        }
    }

    func testBulkUndoFailurePointsAtRecentChanges() {
        XCTAssertEqual(LibraryView.undoFailureMessage(count: 2),
                       "Couldn\u{2019}t undo 2 books. Try again from Recent Changes.")
    }
}
