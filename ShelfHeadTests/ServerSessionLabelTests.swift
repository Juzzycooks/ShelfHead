import XCTest
@testable import ShelfHead

/// Pins `AuthSession.displayName`/`symbolName`'s pure naming logic plus a decode of a
/// real `/api/me/sessions` response (Audiobookshelf 2.36), rather than only exercising
/// it against a live server.
final class ServerSessionLabelTests: XCTestCase {
    func testDisplayNamePrefersClientName() {
        XCTAssertEqual(AuthSession.displayName(clientName: "ShelfHead", vendor: "Apple", model: "iPhone", userAgent: "x"), "ShelfHead")
    }

    func testDisplayNameFallsBackToVendorModel() {
        XCTAssertEqual(AuthSession.displayName(clientName: nil, vendor: "Apple", model: "iPhone", userAgent: "x"), "Apple iPhone")
    }

    func testDisplayNameFallsBackToUserAgentPrefix() {
        XCTAssertEqual(AuthSession.displayName(clientName: nil, vendor: nil, model: nil, userAgent: "ShelfHead/5.7 (iPhone; iOS 27.0)"), "ShelfHead")
    }

    func testDisplayNameFallsBackToUnknown() {
        XCTAssertEqual(AuthSession.displayName(clientName: nil, vendor: nil, model: nil, userAgent: nil), "Unknown device")
    }

    func testSymbolNames() {
        XCTAssertEqual(AuthSession.symbolName(deviceType: nil, model: "iPhone", userAgent: nil), "iphone")
        XCTAssertEqual(AuthSession.symbolName(deviceType: nil, model: "iPad", userAgent: nil), "ipad")
        XCTAssertEqual(AuthSession.symbolName(deviceType: "desktop", model: nil, userAgent: nil), "desktopcomputer")
        XCTAssertEqual(AuthSession.symbolName(deviceType: nil, model: nil, userAgent: "Mozilla/5.0"), "desktopcomputer")
        XCTAssertEqual(AuthSession.symbolName(deviceType: nil, model: nil, userAgent: nil), "questionmark.circle")
    }

    func testDecodesSampleSessionsResponse() throws {
        let json = """
        {"total":1,"numPages":1,"page":0,"itemsPerPage":10,"sessions":[
          {"id":"uuid","ipAddress":"::ffff:1.2.3.4","userAgent":"ShelfHead/5.7 (iPhone; iOS 27.0)",
           "deviceInfo":{"deviceType":"mobile","model":"iPhone","vendor":"Apple"},
           "createdAt":1789554777626,"updatedAt":1789554777626,"current":true},
          {"id":"uuid2","ipAddress":"::ffff:5.6.7.8","userAgent":"other","deviceInfo":null,
           "createdAt":1789554777626,"updatedAt":1789554777626,"current":false}
        ]}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(AuthSessionsPage.self, from: json)
        XCTAssertEqual(page.sessions.count, 2)
        XCTAssertEqual(page.sessions[0].current, true)
        XCTAssertEqual(page.sessions[0].deviceInfo?.model, "iPhone")
        XCTAssertNil(page.sessions[1].deviceInfo)
        XCTAssertEqual(page.sessions[1].current, false)
    }
}
