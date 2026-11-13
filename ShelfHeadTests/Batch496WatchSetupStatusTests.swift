import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 W13): Settings › Apple Watch reads the Watch's setup report
/// and says whether this iPhone's account is the one set up there.
final class Batch496WatchSetupStatusTests: XCTestCase {

    private func report(_ state: WatchSetupReport.State, kind: String? = nil, server: String? = nil,
                        accountId: String? = nil, signedOutOnPhone: Bool = false) -> WatchSetupReport {
        WatchSetupReport(state: state, sessionKind: kind, serverURL: server, handoffAccountId: accountId,
                         signedOutOnPhone: signedOutOnPhone, updatedAt: 1_000)
    }

    private func decide(_ report: WatchSetupReport?, account: String? = "A",
                        server: String? = "https://abs.example.com") -> WatchSetupStatus {
        WatchSetupStatus.decide(report: report, currentAccountId: account, currentServerURL: server)
    }

    // MARK: - decide

    func testNoReportIsUnknown() {
        XCTAssertEqual(decide(nil), .unknown)
    }

    func testNotSetUp() {
        XCTAssertEqual(decide(report(.notSetUp)), .notSetUp)
    }

    func testSignedOutByThisPhone() {
        XCTAssertEqual(decide(report(.notSetUp, signedOutOnPhone: true)), .signedOutOnPhone)
    }

    func testExpired() {
        XCTAssertEqual(decide(report(.expired)), .expired)
    }

    func testHandedOverFromThisAccount() {
        XCTAssertEqual(decide(report(.active, kind: "dedicated", server: "https://abs.example.com", accountId: "A")),
                       .thisAccount(isBorrowed: false))
        XCTAssertEqual(decide(report(.active, kind: "durable", accountId: "A")),
                       .thisAccount(isBorrowed: false))
    }

    func testSSOHandOverIsBorrowed() {
        XCTAssertEqual(decide(report(.active, kind: WatchHandoffSessionKind.shared.rawValue, accountId: "A")),
                       .thisAccount(isBorrowed: true))
    }

    /// Same server, different account (a child profile on the same server, say): not "this account".
    func testHandedOverFromAnotherAccount() {
        XCTAssertEqual(decide(report(.active, kind: "dedicated", server: "https://abs.example.com", accountId: "B")),
                       .otherAccount)
        XCTAssertEqual(decide(report(.active, kind: "dedicated", accountId: "A"), account: nil), .otherAccount)
    }

    func testOwnSignInOnTheSameServerIgnoresCaseAndTrailingSlash() {
        XCTAssertEqual(decide(report(.active, kind: "dedicated", server: "HTTPS://ABS.example.com/")),
                       .ownSignInSameServer)
    }

    func testOwnSignInOnAnotherServer() {
        XCTAssertEqual(decide(report(.active, kind: "dedicated", server: "https://other.example.com")),
                       .otherAccount)
        XCTAssertEqual(decide(report(.active, kind: "dedicated", server: "https://abs.example.com"), server: nil),
                       .otherAccount)
    }

    // MARK: - offersSignIn

    func testSignInIsOfferedUnlessThisAccountIsAlreadyOnTheWatch() {
        XCTAssertFalse(WatchSetupStatus.thisAccount(isBorrowed: false).offersSignIn)
        XCTAssertTrue(WatchSetupStatus.thisAccount(isBorrowed: true).offersSignIn)
        let others: [WatchSetupStatus] = [.unknown, .notSetUp, .signedOutOnPhone, .ownSignInSameServer,
                                          .otherAccount, .expired]
        for status in others {
            XCTAssertTrue(status.offersSignIn, "\(status)")
        }
    }

    // MARK: - Page visibility and search

    func testPageNeedsAPairedWatchOrTheWatchApp() {
        XCTAssertFalse(WatchSetupModel.showsSettingsPage(isPaired: false, isWatchAppInstalled: false))
        XCTAssertTrue(WatchSetupModel.showsSettingsPage(isPaired: true, isWatchAppInstalled: false))
        XCTAssertTrue(WatchSetupModel.showsSettingsPage(isPaired: false, isWatchAppInstalled: true))
        XCTAssertTrue(WatchSetupModel.showsSettingsPage(isPaired: true, isWatchAppInstalled: true))
    }

    func testPageTitle() {
        XCTAssertEqual(SettingsPage.appleWatch.title, "Apple Watch")
    }

    func testSearchFindsThePageOnlyWithAWatch() {
        var state = SettingsSearchEntry.LiveState()
        XCTAssertTrue(SettingsSearchIndex.results(for: "set up watch", state: state)
            .contains { $0.row == SettingsRow.watchStatus })
        XCTAssertTrue(SettingsSearchIndex.results(for: "without iphone", state: state)
            .contains { $0.row == SettingsRow.watchCapabilities })

        state.hasPairedWatch = false
        XCTAssertFalse(SettingsSearchIndex.results(for: "watch", state: state).contains { $0.page == .appleWatch })
        // The Features & Tips row stays findable without a Watch.
        XCTAssertTrue(SettingsSearchIndex.results(for: "watch", state: state)
            .contains { $0.row == SettingsRow.featureWatch })
    }

    func testReportRoundTripsThroughJSON() throws {
        let original = report(.active, kind: "shared", server: "https://abs.example.com", accountId: "A")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WatchSetupReport.self, from: data), original)
    }
}
