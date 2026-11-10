import XCTest
@testable import ShelfHead

/// T10 (REVIEW_2026-09-04_UI.md): `DownloadsSettingsView`'s "Remove All Downloads"
/// confirmation and `DownloadHealthView`'s "Remove all downloads" action used two
/// different presentation styles (`.confirmationDialog` vs. `.alert`) and two different
/// messages for the same destructive call (`DownloadManager.removeAllDownloads()`). The
/// fix unifies both onto `RemoveAllDownloadsCopy`, a pure string namespace, so this pins
/// the one thing that can be checked without walking either view's SwiftUI body: the
/// composed message reads correctly with and without a known storage size.
final class RemoveAllDownloadsCopyTests: XCTestCase {

    func testMessageWithSizeContainsTheSize() {
        let message = RemoveAllDownloadsCopy.message(storageUsed: "1.2 GB")
        XCTAssertTrue(message.contains("1.2 GB"))
    }

    func testMessageWithoutSizeDoesNotMentionFrees() {
        let message = RemoveAllDownloadsCopy.message(storageUsed: nil)
        XCTAssertFalse(message.contains("frees"))
    }

    func testBothMessagesMentionLibrary() {
        XCTAssertTrue(RemoveAllDownloadsCopy.message(storageUsed: "1.2 GB").contains("library"))
        XCTAssertTrue(RemoveAllDownloadsCopy.message(storageUsed: nil).contains("library"))
    }
}
