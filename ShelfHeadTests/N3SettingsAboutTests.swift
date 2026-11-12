import XCTest
@testable import ShelfHead

/// Batch 493 (REVIEW 2026-11-11 N3): Settings search coverage, the new Features & Tips rows,
/// and the About diagnostics report.
final class N3SettingsAboutTests: XCTestCase {

    // MARK: - Search coverage

    /// Every Settings page can be found by search: at least one entry opens it.
    func testEverySettingsPageHasAtLeastOneSearchEntry() {
        var state = SettingsSearchEntry.LiveState()
        state.savedServerCount = 2
        let pages = Set(SettingsSearchIndex.entries(includesClassicLockScreen: true, state: state).map(\.page))
        for page in SettingsPage.allCases {
            XCTAssertTrue(pages.contains(page), "No search entry opens \(page).")
        }
    }

    /// Every page the Settings root links to is a real page, and each is reachable by search.
    func testRootPagesAreSearchable() {
        let pages = Set(SettingsSearchIndex.entries(includesClassicLockScreen: true).map(\.page))
        for group in SettingsView.rootGroups(showsServerTools: true) {
            for page in group.pages {
                XCTAssertTrue(pages.contains(page), "\(page) is on the Settings root but not searchable.")
            }
        }
    }

    func testObviousTermsFindTheRightPage() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "widget").contains { $0.row == SettingsRow.featureWidget })
        XCTAssertTrue(SettingsSearchIndex.results(for: "watch").contains { $0.row == SettingsRow.featureWatch })
        XCTAssertTrue(SettingsSearchIndex.results(for: "goal").contains { $0.row == SettingsRow.featureDailyGoal })
        XCTAssertTrue(SettingsSearchIndex.results(for: "year in review").contains { $0.row == SettingsRow.featureYearInReview })
        XCTAssertTrue(SettingsSearchIndex.results(for: "chapters").contains { $0.row == SettingsRow.featureAutoChapters })
        XCTAssertTrue(SettingsSearchIndex.results(for: "mixtape").contains { $0.row == SettingsRow.featureClips })
    }

    // MARK: - Feedback diagnostics

    private let secretReport = FeedbackDiagnostics.report(
        appVersion: "7.6", build: "3", osVersion: "26.1", deviceModel: "iPhone17,1",
        serverVersion: "2.17.2", serverURL: "https://books.example.org:13378",
        settings: [("Wi-Fi only downloads", "On"),
                   ("Note", "token=abc123secret https://books.example.org:13378/api Bearer eyJhbGciOi.payload.sig books.example.org")],
        now: Date(timeIntervalSince1970: 0))

    func testReportKeepsTheUsefulFacts() {
        XCTAssertTrue(secretReport.contains("App: 7.6 (3)"))
        XCTAssertTrue(secretReport.contains("iOS: 26.1"))
        XCTAssertTrue(secretReport.contains("Device: iPhone17,1"))
        XCTAssertTrue(secretReport.contains("Audiobookshelf server: 2.17.2"))
        XCTAssertTrue(secretReport.contains("Wi-Fi only downloads: On"))
    }

    func testReportDropsTokensAndHostnames() {
        XCTAssertFalse(secretReport.contains("abc123secret"))
        XCTAssertFalse(secretReport.contains("eyJhbGciOi"))
        XCTAssertFalse(secretReport.contains("books.example.org"))
        XCTAssertFalse(secretReport.contains("13378"))
        XCTAssertTrue(secretReport.contains("your server"))
    }

    func testUnknownServerVersionSaysUnknown() {
        let report = FeedbackDiagnostics.report(appVersion: "1", build: "1", osVersion: "26", deviceModel: "x",
                                                serverVersion: nil, serverURL: "", settings: [])
        XCTAssertTrue(report.contains("Audiobookshelf server: unknown"))
    }

    func testScrubHostsHandlesABareHostAndAMissingScheme() {
        XCTAssertEqual(FeedbackDiagnostics.scrubHosts("connect to abs.home.lan now", serverURL: "abs.home.lan"),
                       "connect to your server now")
        XCTAssertEqual(FeedbackDiagnostics.scrubHosts("see http://10.0.0.5:8080/x", serverURL: ""),
                       "see your server/x")
    }

    func testLiveReportNeverContainsTheStoredServerAddress() {
        let report = FeedbackDiagnostics.report(serverVersion: "2.0", serverURL: "https://secret-host.example.net")
        XCTAssertFalse(report.contains("secret-host.example.net"))
        XCTAssertTrue(report.hasPrefix("ShelfHead feedback diagnostics"))
    }

    func testSettingStatesPrintOnOffOrDefault() {
        XCTAssertEqual(FeedbackDiagnostics.stateText(true), "On")
        XCTAssertEqual(FeedbackDiagnostics.stateText(false), "Off")
        XCTAssertEqual(FeedbackDiagnostics.stateText(1.5), "1.5")
        XCTAssertEqual(FeedbackDiagnostics.stateText(nil), "default")
    }
}
