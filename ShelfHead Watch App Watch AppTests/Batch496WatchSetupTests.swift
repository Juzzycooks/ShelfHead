import XCTest
@testable import ShelfHead_Watch

/// Batch 496 (REVIEW 2026-11-11 W13): the setup page sits second on the Shelf until it is
/// answered, and an iPhone sign-out leaves a "Signed out on iPhone" page instead of a
/// silently un-set-up Watch.
@MainActor
final class Batch496WatchSetupTests: XCTestCase {

    private func book(_ id: String) -> WatchShelfSleeve {
        WatchShelfSleeve(id: id, kind: .book(target: .watch, isAvailable: true),
                         book: WatchShelfBook(itemId: id, title: id, author: "A", progress: 0.2))
    }

    private func current(_ id: String) -> WatchShelfSleeve {
        WatchShelfSleeve(id: id, kind: .current(source: .iPhone, isPlaying: true),
                         book: WatchShelfBook(itemId: id, title: id, author: "A", progress: 0.5))
    }

    private let browse = WatchShelfSleeve(id: WatchShelfSleeve.browseId, kind: .browse, book: nil)
    private let setup = WatchShelfSleeve(id: WatchShelfSleeve.setupId, kind: .setup, book: nil)

    // MARK: - Which page

    func testPromptNeedsNoSession() {
        XCTAssertNil(WatchRunSetupPrompt.prompt(hasNoSession: false, wasDismissed: false, wasCompleted: false,
                                                signedOutOnPhone: true))
    }

    func testFirstRunUntilAnswered() {
        XCTAssertEqual(WatchRunSetupPrompt.prompt(hasNoSession: true, wasDismissed: false, wasCompleted: false,
                                                  signedOutOnPhone: false), .firstRun)
        XCTAssertNil(WatchRunSetupPrompt.prompt(hasNoSession: true, wasDismissed: true, wasCompleted: false,
                                                signedOutOnPhone: false))
        XCTAssertNil(WatchRunSetupPrompt.prompt(hasNoSession: true, wasDismissed: false, wasCompleted: true,
                                                signedOutOnPhone: false))
    }

    /// A Watch that was set up (or dismissed the first-run page) is still told after the
    /// iPhone signs it out.
    func testSignedOutOnPhoneOverridesEarlierAnswers() {
        for dismissed in [true, false] {
            for completed in [true, false] {
                XCTAssertEqual(WatchRunSetupPrompt.prompt(hasNoSession: true, wasDismissed: dismissed,
                                                          wasCompleted: completed, signedOutOnPhone: true),
                               .signedOutOnPhone)
            }
        }
    }

    // MARK: - Where it goes

    func testNoPromptLeavesSleevesAlone() {
        let sleeves = [current("a"), book("b"), browse]
        XCTAssertEqual(WatchShelf.pages(sleeves: sleeves, prompt: nil).map(\.id), ["a", "b", WatchShelfSleeve.browseId])
    }

    func testPromptIsSecondAfterTheCurrentBook() {
        let sleeves = [current("a"), book("b"), book("c"), browse]
        let ids = WatchShelf.pages(sleeves: sleeves, prompt: .firstRun).map(\.id)
        XCTAssertEqual(ids, ["a", WatchShelfPage.setupPromptId, "b", "c", WatchShelfSleeve.browseId])
    }

    func testPromptIsSecondAfterTheFirstBookWithTenBooks() {
        let sleeves = (0..<10).map { book("b\($0)") } + [browse]
        let ids = WatchShelf.pages(sleeves: sleeves, prompt: .signedOutOnPhone).map(\.id)
        XCTAssertEqual(ids[1], WatchShelfPage.setupPromptId)
        XCTAssertEqual(ids.count, 12)
    }

    func testPromptIsFirstWithNoBooks() {
        let ids = WatchShelf.pages(sleeves: [browse], prompt: .firstRun).map(\.id)
        XCTAssertEqual(ids, [WatchShelfPage.setupPromptId, WatchShelfSleeve.browseId])
    }

    func testLoneSetupSleeveStaysForFirstRun() {
        XCTAssertEqual(WatchShelf.pages(sleeves: [setup], prompt: .firstRun), [.sleeve(setup)])
    }

    func testSignedOutPageReplacesLoneSetupSleeve() {
        XCTAssertEqual(WatchShelf.pages(sleeves: [setup], prompt: .signedOutOnPhone), [.setupPrompt(.signedOutOnPhone)])
    }

    // MARK: - Report to the iPhone

    func testReportWhileCheckingIsNil() {
        XCTAssertNil(WatchStore.setupReport(authState: .checking, sessionKind: nil, serverURL: nil,
                                            handoffAccountId: nil, signedOutOnPhone: false, now: 1))
    }

    func testActiveReportCarriesKindServerAndAccount() {
        let report = WatchStore.setupReport(authState: .active, sessionKind: .shared, serverURL: "https://abs.example.com",
                                            handoffAccountId: "acct-1", signedOutOnPhone: true, now: 1_800_000_000)
        XCTAssertEqual(report, WatchSetupReport(state: .active, sessionKind: "shared", serverURL: "https://abs.example.com",
                                                handoffAccountId: "acct-1", signedOutOnPhone: false, updatedAt: 1_800_000_000))
    }

    func testSignedOutReportHasNoLeftovers() {
        let report = WatchStore.setupReport(authState: .noSession, sessionKind: .dedicated, serverURL: "https://abs.example.com",
                                            handoffAccountId: "acct-1", signedOutOnPhone: true, now: 5)
        XCTAssertEqual(report, WatchSetupReport(state: .notSetUp, sessionKind: nil, serverURL: nil,
                                                handoffAccountId: nil, signedOutOnPhone: true, updatedAt: 5))
    }

    func testExpiredReport() {
        let report = WatchStore.setupReport(authState: .sessionExpired, sessionKind: .shared, serverURL: "s",
                                            handoffAccountId: nil, signedOutOnPhone: false, now: 5)
        XCTAssertEqual(report?.state, .expired)
    }

    func testReportRoundTripsAsJSON() throws {
        let report = WatchSetupReport(state: .active, sessionKind: "dedicated", serverURL: "https://abs.example.com",
                                      handoffAccountId: nil, signedOutOnPhone: false, updatedAt: 42)
        let decoded = try JSONDecoder().decode(WatchSetupReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
    }
}
