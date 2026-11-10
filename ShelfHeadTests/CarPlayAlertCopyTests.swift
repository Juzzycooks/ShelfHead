import XCTest
@testable import ShelfHead

/// C4 (REVIEW_2026-09-04_UI.md Pass 4): "every failure in the car is silent — there is
/// no `CPAlertTemplate` anywhere in `Services/`". The fix presents one, and the only
/// part of it that can be checked without a vehicle display is the copy: CarPlay picks
/// the FIRST variant the screen can fit, so an out-of-order `titleVariants` array means
/// a narrow head unit falls through to nothing usable, and an over-long "short" variant
/// means it truncates mid-word at 70km/h. Neither failure is visible in the simulator's
/// 800x480 default, which is why it's pinned here instead.
///
/// Following this target's precedent (`DownloadOrphanSweepTests`): the presentation path
/// itself — `presentAlert`, its `presentedTemplate` stacking guard, `CPInterfaceController`
/// — isn't unit-tested, since it needs a live interface controller. What's tested is the
/// pure copy function it was split out from.
final class CarPlayAlertCopyTests: XCTestCase {

    /// CarPlay's contract for `titleVariants`: longest first, so the system can walk down
    /// to whatever the vehicle's display fits. A variant that isn't shorter than the one
    /// before it is dead weight at best and skips the readable option at worst.
    private func assertVariantContract(_ variants: [String],
                                       _ label: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertFalse(variants.isEmpty, "\(label): an alert with no title says nothing.",
                       file: file, line: line)
        for variant in variants {
            XCTAssertFalse(variant.isEmpty, "\(label): empty variant.", file: file, line: line)
            // A driving glance, not a sentence to read. The longest string in use is 45
            // characters; this is the ceiling that keeps it that way.
            XCTAssertLessThanOrEqual(variant.count, 48,
                                     "\(label): \"\(variant)\" is too long to take in while driving.",
                                     file: file, line: line)
        }
        for (shorter, longer) in zip(variants.dropFirst(), variants) {
            XCTAssertLessThan(shorter.count, longer.count,
                              "\(label): variants must be strictly longest-first — \"\(shorter)\" does not shorten \"\(longer)\".",
                              file: file, line: line)
        }
    }

    func testPlaybackFailureVariantsFollowCarPlayContract() {
        assertVariantContract(CarPlayCoordinator.playbackFailureAlertVariants(isOnline: true), "playback/online")
        assertVariantContract(CarPlayCoordinator.playbackFailureAlertVariants(isOnline: false), "playback/offline")
    }

    func testListLoadFailureVariantsFollowCarPlayContract() {
        assertVariantContract(CarPlayCoordinator.listLoadFailureAlertVariants(isOnline: true), "list/online")
        assertVariantContract(CarPlayCoordinator.listLoadFailureAlertVariants(isOnline: false), "list/offline")
    }

    func testNoPlaybackVariantsFollowCarPlayContract() {
        assertVariantContract(CarPlayCoordinator.noPlaybackAlertVariants, "no playback")
    }

    /// The whole point of consulting `NetworkMonitor` at the failure site: the two cases
    /// have different answers for the driver ("your server didn't answer" is something to
    /// check later; "you're offline" means go to Downloads now), so they must not
    /// collapse into one generic string.
    func testOfflineAndOnlineFailuresSayDifferentThings() {
        XCTAssertNotEqual(CarPlayCoordinator.playbackFailureAlertVariants(isOnline: true),
                          CarPlayCoordinator.playbackFailureAlertVariants(isOnline: false),
                          "An offline failure and a server failure must not read identically.")
        XCTAssertNotEqual(CarPlayCoordinator.listLoadFailureAlertVariants(isOnline: true),
                          CarPlayCoordinator.listLoadFailureAlertVariants(isOnline: false),
                          "An offline failure and a server failure must not read identically.")
    }

    /// No file names, error codes, or server URLs in copy a driver reads at speed —
    /// the review's explicit constraint on this fix.
    func testCopyCarriesNoTechnicalDetail() {
        let all = CarPlayCoordinator.playbackFailureAlertVariants(isOnline: true)
            + CarPlayCoordinator.playbackFailureAlertVariants(isOnline: false)
            + CarPlayCoordinator.listLoadFailureAlertVariants(isOnline: true)
            + CarPlayCoordinator.listLoadFailureAlertVariants(isOnline: false)
            + CarPlayCoordinator.noPlaybackAlertVariants
        for variant in all {
            XCTAssertFalse(variant.contains(".swift"), "\"\(variant)\" leaks a file name.")
            XCTAssertFalse(variant.contains("http"), "\"\(variant)\" leaks a URL.")
            XCTAssertNil(variant.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")),
                         "\"\(variant)\" carries a number — likely an error code.")
        }
    }
}
