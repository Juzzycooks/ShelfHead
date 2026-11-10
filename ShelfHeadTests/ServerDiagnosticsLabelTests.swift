import XCTest
@testable import ShelfHead

/// R8 (REVIEW_2026-09-04_UI.md): `ServerDiagnosticsView` showed "—" for the active
/// account (a legacy single-account session has no saved `ServerAccount`, only
/// `AccountStore.currentAccountId` — but it's still signed in) and a raw UUID for the
/// selected library. Pins the two pure label functions the view's rows now call.
final class ServerDiagnosticsLabelTests: XCTestCase {

    func testAccountLabelUsesUsernameAndHostWhenAccountResolved() {
        let account = ServerAccount(id: "acc-1", serverURL: "https://audiobooks.example.com", username: "justin")
        XCTAssertEqual(
            ServerDiagnosticsView.accountLabel(account: account, isSignedIn: true),
            "justin on audiobooks.example.com"
        )
    }

    func testAccountLabelSignedInWithoutSavedAccount() {
        XCTAssertEqual(
            ServerDiagnosticsView.accountLabel(account: nil, isSignedIn: true),
            "Signed in (not saved as an account)"
        )
    }

    func testAccountLabelNotSignedIn() {
        XCTAssertEqual(ServerDiagnosticsView.accountLabel(account: nil, isSignedIn: false), "\u{2014}")
    }

    func testLibraryLabelResolvesNameFromMatchingLibrary() {
        let libraries = [Library(id: "lib-1", name: "Audiobooks", mediaType: "book", icon: nil, folders: nil)]
        XCTAssertEqual(ServerDiagnosticsView.libraryLabel(id: "lib-1", libraries: libraries), "Audiobooks")
    }

    func testLibraryLabelFallsBackToTruncatedIdWhenUnresolved() {
        XCTAssertEqual(
            ServerDiagnosticsView.libraryLabel(id: "0123456789abcdef", libraries: []),
            "Unknown (01234567\u{2026})"
        )
    }

    func testLibraryLabelIsDashWhenNoIdSelected() {
        XCTAssertEqual(ServerDiagnosticsView.libraryLabel(id: nil, libraries: []), "\u{2014}")
    }

    // T6 (REVIEW_2026-09-04_UI.md)
    func testStorageScopeLabelShowsHostAndKeySuffix() {
        let key = DownloadPaths.scopeKey(serverURL: "https://abs.example.com", accountId: "acct-123")
        let expectedSuffix = String(key.suffix(6))
        XCTAssertEqual(
            ServerDiagnosticsView.storageScopeLabel(key),
            "abs.example.com \u{00B7} \u{2026}\(expectedSuffix)"
        )
    }

    func testStorageScopeLabelReturnsUnknownFormatKeyUnchanged() {
        XCTAssertEqual(ServerDiagnosticsView.storageScopeLabel("unscoped"), "unscoped")
    }
}
