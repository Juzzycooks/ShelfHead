import XCTest
@testable import ShelfHead

final class Batch472AccountsTests: XCTestCase {
    private let a = ServerAccount(id: "A", serverURL: "https://abs.example.com", username: "sam")
    private let b = ServerAccount(id: "B", serverURL: "https://abs.example.com", username: "kim")

    func testMatchingAccountByExactURLAndUsername() {
        XCTAssertEqual(AuthViewModel.matchingAccountId(in: [a, b], serverURL: "https://abs.example.com", username: "kim"), "B")
    }

    func testMatchingAccountIgnoresScheme() {
        XCTAssertEqual(AuthViewModel.matchingAccountId(in: [a, b], serverURL: "http://abs.example.com", username: "sam"), "A")
    }

    func testNoMatchForUnknownUserOrEmptyUsername() {
        XCTAssertNil(AuthViewModel.matchingAccountId(in: [a, b], serverURL: "https://abs.example.com", username: "zed"))
        XCTAssertNil(AuthViewModel.matchingAccountId(in: [a, b], serverURL: "https://abs.example.com", username: ""))
        XCTAssertNil(AuthViewModel.matchingAccountId(in: [a, b], serverURL: "https://abs.example.com", username: nil))
        XCTAssertNil(AuthViewModel.matchingAccountId(in: [], serverURL: "https://abs.example.com", username: "sam"))
    }

    func testOtherServersRefusesUnacknowledgedPlainHTTPToPublicHost() {
        XCTAssertTrue(OtherServersStore.shouldRefusePlainHTTP(serverURL: "http://abs.example.com", acknowledged: false))
        XCTAssertFalse(OtherServersStore.shouldRefusePlainHTTP(serverURL: "http://abs.example.com", acknowledged: true))
        XCTAssertFalse(OtherServersStore.shouldRefusePlainHTTP(serverURL: "https://abs.example.com", acknowledged: false))
        XCTAssertFalse(OtherServersStore.shouldRefusePlainHTTP(serverURL: "http://192.168.1.10:13378", acknowledged: false))
    }
}
