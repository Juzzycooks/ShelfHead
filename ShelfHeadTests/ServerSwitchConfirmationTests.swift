import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden): one confirmation wherever the signed-in server changes
/// (Settings > Servers, the Other Servers shelf and screen). Pins its copy.
final class ServerSwitchConfirmationTests: XCTestCase {

    func testTitleNamesTheServer() {
        XCTAssertEqual(ServerSwitchConfirmation.title(host: "abs.example.org"), "Switch to abs.example.org?")
    }

    func testButtonSaysWhetherABookOpens() {
        XCTAssertEqual(ServerSwitchConfirmation.confirmButton(opensBook: true), "Switch & Open")
        XCTAssertEqual(ServerSwitchConfirmation.confirmButton(opensBook: false), "Switch")
    }

    func testMessageNamesTheBookThatStops() {
        XCTAssertEqual(
            ServerSwitchConfirmation.message(currentBookTitle: "Dune"),
            "\u{201C}Dune\u{201D} stops and Up Next is cleared. Your place in it is saved."
        )
    }

    func testNoMessageWhenNothingIsLoaded() {
        XCTAssertNil(ServerSwitchConfirmation.message(currentBookTitle: nil))
        XCTAssertNil(ServerSwitchConfirmation.message(currentBookTitle: "   "))
    }

    func testNeverAsksAreYouSure() {
        let all = [
            ServerSwitchConfirmation.title(host: "h"),
            ServerSwitchConfirmation.message(currentBookTitle: "B") ?? "",
        ].joined(separator: " ").lowercased()
        XCTAssertFalse(all.contains("are you sure"))
    }
}
