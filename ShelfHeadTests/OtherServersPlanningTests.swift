import XCTest
@testable import ShelfHead

/// Pins `OtherServersStore.interleave` — the pure round-robin merge behind the Home
/// "On Other Servers" shelf's `mergedItems` — since the store itself talks to the
/// Keychain/network and isn't unit-testable directly.
final class OtherServersPlanningTests: XCTestCase {
    func testInterleaveRoundRobinsUnevenLists() {
        let result = OtherServersStore.interleave([["a", "b", "c"], ["1", "2"], ["x"]])
        XCTAssertEqual(result, ["a", "1", "x", "b", "2", "c"])
    }

    func testInterleaveEmptyListsYieldsEmpty() {
        XCTAssertEqual(OtherServersStore.interleave([[String]]()), [])
        XCTAssertEqual(OtherServersStore.interleave([[String](), [String]()]), [])
    }

    func testInterleaveSingleListIsUnchanged() {
        XCTAssertEqual(OtherServersStore.interleave([[1, 2, 3]]), [1, 2, 3])
    }
}
