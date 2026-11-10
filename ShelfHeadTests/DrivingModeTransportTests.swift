import XCTest
@testable import ShelfHead

/// Critique 2026-10-06 (adapt): Driving Mode's transport row used fixed 84/140/84 + 2x16
/// frames (340pt) in a 327pt iPhone SE column, and clipped at the 1.4x Dynamic Type cap.
final class DrivingModeTransportTests: XCTestCase {
    private func total(_ t: DrivingModeView.TransportSizes) -> CGFloat {
        2 * t.skip + t.play + 2 * t.spacing
    }

    func testDefaultTypeOnNarrowestPhoneFitsWithRingRoom() {
        let t = DrivingModeView.transportSizes(columnWidth: 327, skip: 84, play: 140)
        XCTAssertLessThanOrEqual(total(t) + 12, 327)   // +12: the buffering ring
        XCTAssertGreaterThanOrEqual(t.skip, 60)
        XCTAssertGreaterThanOrEqual(t.play, 96)
        XCTAssertGreaterThan(t.play, t.skip * 1.5)
    }

    func testAX5CapOnNarrowestPhoneFitsAndKeepsPlayDominant() {
        let t = DrivingModeView.transportSizes(columnWidth: 327, skip: 84 * 1.4, play: 140 * 1.4)
        XCTAssertLessThanOrEqual(total(t) + 12, 327)
        XCTAssertGreaterThanOrEqual(t.skip, 60)
        XCTAssertGreaterThanOrEqual(t.play, 96)
        XCTAssertGreaterThan(t.play, t.skip * 1.5)
    }

    func testRoomyColumnsKeepPreferredSizes() {
        for width in [CGFloat(345), 392] {   // 393 and 440 pt phones less 48pt padding
            let t = DrivingModeView.transportSizes(columnWidth: width, skip: 84, play: 140)
            XCTAssertEqual(t.skip, 84)
            XCTAssertEqual(t.play, 140)
        }
    }

    func testWideColumnAtAX5ShrinksOnlyAsNeeded() {
        let t = DrivingModeView.transportSizes(columnWidth: 392, skip: 84 * 1.4, play: 140 * 1.4)
        XCTAssertLessThanOrEqual(total(t) + 12, 392)
        XCTAssertGreaterThan(t.skip, 84)
    }

    func testBannerCopyNamesTheDownloadWhenUsingLocally() {
        XCTAssertNil(ConnectivityCopy.message(for: .ok, usingDownload: true))
        XCTAssertEqual(ConnectivityCopy.message(for: .offline, usingDownload: false), "You're offline")
        XCTAssertEqual(ConnectivityCopy.message(for: .offline, usingDownload: true), "Offline \u{00B7} using your download")
        XCTAssertEqual(ConnectivityCopy.message(for: .serverUnreachable, usingDownload: false), "Can't reach your server")
        XCTAssertEqual(ConnectivityCopy.message(for: .serverUnreachable, usingDownload: true),
                       "Can't reach your server \u{00B7} using your download")
    }
}
