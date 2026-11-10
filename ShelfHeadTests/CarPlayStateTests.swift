import XCTest
import CarPlay
@testable import ShelfHead

// =============================================================================
// ShelfHead • CarPlayStateTests
// =============================================================================
//
// C5/C6/C7 (REVIEW_2026-09-04_UI.md Pass 4): pins the pure functions behind three
// CarPlay findings that couldn't be verified any other way in this environment (no
// real Xcode/simulator/head unit available — see CLAUDE.md's "investigate before
// fixing" norm):
//   - C5: Home's three-way empty state (not signed in / offline-or-failed / a
//     genuinely empty library), extracted as `homeEmptyStateVariants`.
//   - C7: the playback-rate ladder, extracted as `nextPlaybackRate`, and its display
//     text, `formattedPlaybackRate`.
// C6 (the Setup tab rebuild-on-change plumbing) and C8 (the transient bookmark
// confirmation) are deliberately NOT covered here — both are template-mutation and
// timer-scheduling paths against a live `CPListTemplate`/`CPInterfaceController`,
// the same "isn't unit-tested, since it needs a live interface controller" line
// `CarPlayListWindowingTests.swift` and `CarPlayAlertCopyTests.swift` already draw
// around `applyWindowedItems`/`renderChapterWindow`/`presentAlert`. Same shape and
// precedent as both of those existing files (and, further back,
// `DownloadManager.shouldReclaimOrphanDirectory`): extract the decision, test the
// decision, leave the live-template plumbing to a real device.
final class CarPlayStateTests: XCTestCase {

    // MARK: - nextPlaybackRate (C7)

    /// The bug this replaces: `[1.0, 1.25, 1.5, 1.75, 2.0].first(where: { $0 > current
    /// }) ?? rates[0]` sent 2.5× (a rate this app fully supports) straight to 1.0× —
    /// less than half speed, mid-sentence. The fix must not reproduce that: nothing
    /// above the ladder's minimum should ever land back at the app's DEFAULT (1.0×)
    /// except by passing all the way around through the real top of the range.
    func testNextPlaybackRateNeverWrapsToOneExceptFromTheTopOfTheRange() {
        for current: Float in [1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75] {
            let next = CarPlayCoordinator.nextPlaybackRate(after: current)
            XCTAssertNotEqual(next, 1.0, "stepping up from \(current)x must not wrap to 1.0x — that was the exact bug (2.5x -> 1.0x).")
            XCTAssertGreaterThan(next, current, "stepping up from \(current)x should move forward, not backward or in place.")
        }
    }

    func testNextPlaybackRateStepsByAQuarterInTheMiddleOfTheRange() {
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 1.0), 1.25)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 1.25), 1.5)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 1.5), 1.75)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 1.75), 2.0)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 2.0), 2.25)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 2.25), 2.5)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 2.5), 2.75)
    }

    /// The only wrap in the whole function, and it must be visible: exactly at the
    /// app's real top of range (`PlayerViewModel.setPlaybackRate` clamps to 3.0),
    /// wrap to the bottom (0.5), not to 1.0 and not stuck at 3.0.
    func testNextPlaybackRateWrapsFromTheTopOfTheRangeToTheBottom() {
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 3.0), 0.5)
    }

    func testNextPlaybackRateFromTheBottomOfTheRangeStepsUpNormally() {
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 0.5), 0.75)
    }

    /// `current` can be off the 0.25 grid entirely — the phone's fine −/+0.05 stepper
    /// (`PlayerViewModel.nudgeSpeed`) can leave the rate at something like 1.05x. The
    /// button must still move FORWARD to the next grid stop above it, not get stuck
    /// re-selecting a stop at or behind where it already is.
    func testNextPlaybackRateFromAnOffGridRateAdvancesToTheNextGridStopAbove() {
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 1.05), 1.25)
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: 1.9), 2.0)
    }

    /// Defensive: an out-of-range starting rate (shouldn't happen given the app's own
    /// 0.5-3.0 clamp, but this function doesn't assume its caller enforced that)
    /// still returns something inside 0.5...3.0 rather than escaping the range.
    func testNextPlaybackRateClampsAnOutOfRangeStartingRateIntoTheValidRange() {
        let fromBelow = CarPlayCoordinator.nextPlaybackRate(after: 0.1)
        XCTAssertGreaterThanOrEqual(fromBelow, 0.5)
        XCTAssertLessThanOrEqual(fromBelow, 3.0)

        let fromAbove = CarPlayCoordinator.nextPlaybackRate(after: 10.0)
        XCTAssertGreaterThanOrEqual(fromAbove, 0.5)
        XCTAssertLessThanOrEqual(fromAbove, 3.0)
    }

    /// Walking the button repeatedly from the bottom should visit every quarter-step
    /// stop in order and land back on 0.5x after exactly as many taps as there are
    /// stops — i.e. it's a closed loop over the real range, not an open-ended climb.
    func testNextPlaybackRateWalksTheFullLadderAndReturnsToTheStart() {
        var rate: Float = 0.5
        var seen: [Float] = [rate]
        for _ in 0..<10 {
            rate = CarPlayCoordinator.nextPlaybackRate(after: rate)
            seen.append(rate)
        }
        XCTAssertEqual(seen, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0])
        XCTAssertEqual(CarPlayCoordinator.nextPlaybackRate(after: seen.last!), 0.5, "one more tap past 3.0x must return to the bottom.")
    }

    // MARK: - formattedPlaybackRate (C7)

    /// `CPNowPlayingPlaybackRateButton` has no numeric label of its own — this text
    /// is the only place the driver can see where the rate landed, so a whole-number
    /// rate must not read as "1.00x" the way a naive `%.2f` would print it.
    func testFormattedPlaybackRateDropsTrailingZerosOnWholeRates() {
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(1.0), "1×")
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(2.0), "2×")
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(0.5), "0.5×")
    }

    func testFormattedPlaybackRateShowsQuarterStepsExactly() {
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(1.25), "1.25×")
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(1.5), "1.5×")
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(2.75), "2.75×")
    }

    /// A rate left over from the phone's fine stepper (off the button's own 0.25
    /// grid) must still render as SOMETHING readable rather than being silently
    /// rounded to the nearest grid stop and lying about the actual rate.
    func testFormattedPlaybackRateShowsAnOffGridRateExactly() {
        XCTAssertEqual(CarPlayCoordinator.formattedPlaybackRate(1.05), "1.05×")
    }

    // MARK: - homeEmptyStateVariants (C5)

    /// The exact bug: offline (or a failed load) used to say "Nothing to show yet" —
    /// a confident false statement about an empty library when the real situation is
    /// a full library the car just can't reach right now.
    func testHomeEmptyStateDoesNotClaimTheLibraryIsEmptyWhenOfflineOrFailed() {
        let offline = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: false, loadFailed: false)
        for text in offline.title + offline.subtitle {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("nothing"),
                           "\"\(text)\" claims the library is empty, but it's actually just unreachable.")
        }
        let failed = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: true, loadFailed: true)
        for text in failed.title + failed.subtitle {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("nothing"),
                           "\"\(text)\" claims the library is empty, but the load just failed.")
        }
    }

    /// Offline/failed copy should point at the one tab guaranteed to work off-signal.
    func testHomeEmptyStateOfflineOrFailedPointsAtDownloads() {
        let offline = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: false, loadFailed: false)
        XCTAssertTrue(offline.subtitle.contains { $0.localizedCaseInsensitiveContains("download") },
                     "offline copy should point the driver at Downloads, the tab that still works.")

        let failed = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: true, loadFailed: true)
        XCTAssertTrue(failed.subtitle.contains { $0.localizedCaseInsensitiveContains("download") },
                     "a failed load should give the same actionable pointer as offline.")
    }

    /// Not signed in is a distinct third case — different from both "offline" and
    /// "empty", and the one case that actually needs the phone.
    func testHomeEmptyStateNotConfiguredMentionsSigningIn() {
        let notSignedIn = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: false, isOnline: true, loadFailed: false)
        let allText = (notSignedIn.title + notSignedIn.subtitle).joined(separator: " ")
        XCTAssertTrue(allText.localizedCaseInsensitiveContains("sign in"),
                     "not-signed-in copy should say to sign in, not something generic.")
    }

    /// Online, load succeeded, still empty: THIS is the one case allowed to say the
    /// library is empty — the whole point of separating the three cases (C5).
    func testHomeEmptyStateGenuinelyEmptyLibraryIsTheOnlyCaseThatSaysSo() {
        let genuinelyEmpty = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: true, loadFailed: false)
        XCTAssertFalse(genuinelyEmpty.title.isEmpty, "the empty view should get a title, not just a subtitle — it never did before this fix.")
        XCTAssertFalse(genuinelyEmpty.subtitle.isEmpty)
    }

    /// All three cases must read differently from each other — collapsing any two
    /// back together is exactly the bug this fix removes.
    func testHomeEmptyStateAllThreeCasesReadDifferently() {
        let notSignedIn = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: false, isOnline: true, loadFailed: false)
        let offline = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: false, loadFailed: false)
        let genuinelyEmpty = CarPlayCoordinator.homeEmptyStateVariants(isConfigured: true, isOnline: true, loadFailed: false)

        XCTAssertNotEqual(notSignedIn.subtitle, offline.subtitle)
        XCTAssertNotEqual(notSignedIn.subtitle, genuinelyEmpty.subtitle)
        XCTAssertNotEqual(offline.subtitle, genuinelyEmpty.subtitle)
    }

    /// Neither array should ever come back empty — an empty `title`/`subtitle` array
    /// is indistinguishable from this function never having been wired up at all
    /// (`emptyViewTitleVariants` was never set anywhere before this fix).
    func testHomeEmptyStateNeverReturnsEmptyArrays() {
        for isConfigured in [true, false] {
            for isOnline in [true, false] {
                for loadFailed in [true, false] {
                    let variants = CarPlayCoordinator.homeEmptyStateVariants(
                        isConfigured: isConfigured, isOnline: isOnline, loadFailed: loadFailed)
                    XCTAssertFalse(variants.title.isEmpty, "isConfigured:\(isConfigured) isOnline:\(isOnline) loadFailed:\(loadFailed)")
                    XCTAssertFalse(variants.subtitle.isEmpty, "isConfigured:\(isConfigured) isOnline:\(isOnline) loadFailed:\(loadFailed)")
                    for text in variants.title + variants.subtitle {
                        XCTAssertFalse(text.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - shouldOfferKeyboardRows (CarPlay-audio Search-row gating)

    /// The bug this replaces: the Library tab's Search row pushed a
    /// `CPSearchTemplate` unconditionally, with nothing anywhere consulting
    /// `CPSessionConfiguration` — so a vehicle reporting `.keyboard` in
    /// `limitedUserInterfaces` (typically while the car is in motion, refusing to
    /// show a keyboard) still sent the driver to a screen they can't type into.
    func testShouldOfferKeyboardRowsIsFalseWhenTheVehicleLimitsTheKeyboard() {
        XCTAssertFalse(CarPlayCoordinator.shouldOfferKeyboardRows(limitedUserInterfaces: .keyboard))
    }

    /// With no limits reported at all (the common case, parked or a vehicle that
    /// doesn't restrict the keyboard), Search must stay a live control.
    func testShouldOfferKeyboardRowsIsTrueWhenNothingIsLimited() {
        XCTAssertTrue(CarPlayCoordinator.shouldOfferKeyboardRows(limitedUserInterfaces: []))
    }

    /// `.lists` is a separate system limit (handled elsewhere, by the existing
    /// `maximumItemCount`/`maximumSectionCount` capping) and must not, on its own,
    /// also gate Search — only `.keyboard` should.
    func testShouldOfferKeyboardRowsIgnoresTheListLimitOnItsOwn() {
        XCTAssertTrue(CarPlayCoordinator.shouldOfferKeyboardRows(limitedUserInterfaces: .lists))
    }

    /// Both limits reported together must still gate Search on `.keyboard` alone.
    func testShouldOfferKeyboardRowsIsFalseWhenKeyboardIsLimitedAlongsideList() {
        XCTAssertFalse(CarPlayCoordinator.shouldOfferKeyboardRows(limitedUserInterfaces: [.keyboard, .lists]))
    }

    // MARK: - Polish pass Phase 2a (CP-3): a failed Home refresh keeps the shelves

    func testFailedRefreshKeepsShelvesOnScreen() {
        XCTAssertTrue(CarPlayCoordinator.shouldKeepHomeSections(loadFailed: true, isAccountSwitch: false, hasSections: true))
    }

    func testSuccessfulRefreshOrEmptyScreenOrAccountSwitchDoesNotKeep() {
        XCTAssertFalse(CarPlayCoordinator.shouldKeepHomeSections(loadFailed: false, isAccountSwitch: false, hasSections: true))
        XCTAssertFalse(CarPlayCoordinator.shouldKeepHomeSections(loadFailed: true, isAccountSwitch: false, hasSections: false))
        XCTAssertFalse(CarPlayCoordinator.shouldKeepHomeSections(loadFailed: true, isAccountSwitch: true, hasSections: true))
    }
}
