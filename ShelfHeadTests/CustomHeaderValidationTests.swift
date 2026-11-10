import XCTest
@testable import ShelfHead

/// Item 30 (REVIEW-2026-09-09.md): `AuthStore.isValidCustomHeaderValue` existed with no
/// UI caller at all — a pasted header value with a trailing newline (or any other control
/// character) was silently dropped by `AuthStore.sanitizedCustomHeaders` at send time,
/// with nothing in the header editor (`AccountSecuritySettingsView`, `AddServerView`)
/// explaining why. The fix wires both editors' per-row warning to this function, mirroring
/// the existing `isValidCustomHeaderName` warning exactly. `currentHeaderValueIsUsable`/
/// `headerValueIsUsable` in those two view files are thin `private` one-line delegations
/// to this same function with no extra logic (deliberately no trimming — see their doc
/// comments), so pinning `AuthStore.isValidCustomHeaderValue` directly here covers the
/// same decision math those `private` wrappers can't expose to a separate test file.
final class CustomHeaderValidationTests: XCTestCase {

    // MARK: - isValidCustomHeaderValue

    func testPlainValueIsValid() {
        XCTAssertTrue(AuthStore.isValidCustomHeaderValue("Bearer abc123"))
    }

    func testEmptyValueIsValid() {
        // A freshly-added, not-yet-filled-in row shouldn't be flagged.
        XCTAssertTrue(AuthStore.isValidCustomHeaderValue(""))
    }

    func testValueWithLeadingOrTrailingSpacesIsValid() {
        // A plain space is a legal header-value byte — only control characters (CR, LF,
        // other C0 bytes, DEL) are rejected.
        XCTAssertTrue(AuthStore.isValidCustomHeaderValue("  token with spaces  "))
    }

    func testValueWithTrailingNewlineIsInvalid() {
        // The paradigm case this fix exists for: a value pasted from somewhere that
        // appended a trailing newline.
        XCTAssertFalse(AuthStore.isValidCustomHeaderValue("abc123\n"))
    }

    func testValueWithEmbeddedCarriageReturnIsInvalid() {
        // CRLF header-smuggling shape.
        XCTAssertFalse(AuthStore.isValidCustomHeaderValue("abc\r\ninjected: true"))
    }

    func testValueWithOtherControlCharacterIsInvalid() {
        // Any C0 control byte, not just CR/LF — e.g. a tab or DEL.
        XCTAssertFalse(AuthStore.isValidCustomHeaderValue("abc\u{0007}def"))
        XCTAssertFalse(AuthStore.isValidCustomHeaderValue("abc\u{007F}def"))
    }

    // MARK: - sanitizedCustomHeaders drops what isValidCustomHeaderValue rejects

    func testSanitizedCustomHeadersDropsInvalidValue() {
        let sanitized = AuthStore.sanitizedCustomHeaders(["X-Test": "abc\n"])
        XCTAssertNil(sanitized["X-Test"])
    }

    func testSanitizedCustomHeadersKeepsValidValue() {
        let sanitized = AuthStore.sanitizedCustomHeaders(["X-Test": "abc123"])
        XCTAssertEqual(sanitized["X-Test"], "abc123")
    }
}
