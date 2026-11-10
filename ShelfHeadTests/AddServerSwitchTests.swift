import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (harden, second run): signing in through Add Server while signed in
/// to another server is an account switch — it confirms and tears down first. Pins
/// `AuthViewModel.addServerSignInKind`, the decision the form and `login`/`loginWithOIDC`
/// act on.
final class AddServerSwitchTests: XCTestCase {

    private func kind(signedIn: Bool = true,
                      current: String = "https://books.example.com", currentUser: String = "demo",
                      new: String, newUser: String?) -> AuthViewModel.AddServerSignInKind {
        AuthViewModel.addServerSignInKind(isAuthenticated: signedIn,
                                          currentServerURL: current, currentUsername: currentUser,
                                          newServerURL: new, newUsername: newUser)
    }

    func testNobodySignedInIsAPlainSignIn() {
        XCTAssertEqual(kind(signedIn: false, new: "https://other.example.com", newUser: "x"), .firstSignIn)
        XCTAssertEqual(kind(signedIn: false, new: "https://other.example.com", newUser: nil), .firstSignIn)
    }

    func testADifferentServerIsASwitch() {
        XCTAssertEqual(kind(new: "https://other.example.com", newUser: "demo"), .switchesAccount)
    }

    func testADifferentUserOnTheSameServerIsASwitch() {
        XCTAssertEqual(kind(new: "https://books.example.com", newUser: "kid"), .switchesAccount)
    }

    func testTheSameServerAndUserIsAReSignInNotASwitch() {
        XCTAssertEqual(kind(new: "https://books.example.com", newUser: "demo"), .sameAccount)
        // Typed without a scheme, different host case, trailing slash: same server.
        XCTAssertEqual(kind(new: "Books.Example.com/", newUser: "demo"), .sameAccount)
        // The http fallback of the same address is the same server too.
        XCTAssertEqual(kind(new: "http://books.example.com", newUser: "demo"), .sameAccount)
    }

    func testADifferentPortOrSubpathIsADifferentServer() {
        XCTAssertEqual(kind(new: "https://books.example.com:8443", newUser: "demo"), .switchesAccount)
        XCTAssertEqual(kind(new: "https://books.example.com/abs", newUser: "demo"), .switchesAccount)
    }

    func testSingleSignOnOverALiveSessionIsAlwaysASwitch() {
        // The user isn't known until the identity provider answers.
        XCTAssertEqual(kind(new: "https://books.example.com", newUser: nil), .switchesAccount)
    }
}
