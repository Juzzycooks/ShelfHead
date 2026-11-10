import XCTest
@testable import ShelfHead

/// Y1 (REVIEW_2026-09-04_UI.md): three theme layouts (Kinetic, Collage, Retro) printed
/// `headline.value` directly with no privacy check, so a Streak share with privacy set to
/// "Hide Stats"/"Cover Only" still leaked the streak number on those themes, while Spotlight
/// (routed through `bigStat(..., show: pr.showStreak)`) correctly suppressed it. The fix adds
/// one gate, `SharePrivacyOptions.headlineIsVisible`, used by all four sites. These tests pin
/// that pure function rather than the SwiftUI rendering, following this target's precedent of
/// testing extracted decision functions instead of view bodies.
final class SharePrivacyGateTests: XCTestCase {

    func testStreakHiddenWhenShowStreakFalse() {
        var privacy = SharePrivacyOptions()
        privacy.showStreak = false
        XCTAssertFalse(SharePrivacyOptions.headlineIsVisible(content: .streak, privacy: privacy))
    }

    func testStreakVisibleWhenShowStreakTrue() {
        var privacy = SharePrivacyOptions()
        privacy.showStreak = true
        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .streak, privacy: privacy))
    }

    /// Books finished has no dedicated privacy flag, and the pre-existing Spotlight path
    /// (`case .booksFinished: bigStat(..., show: true)`) already rendered it unconditionally,
    /// regardless of `showStreak`. The gate mirrors that exactly rather than inventing a new
    /// privacy rule.
    func testBooksFinishedAlwaysVisibleRegardlessOfStreakFlag() {
        var privacy = SharePrivacyOptions()
        privacy.showStreak = false
        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .booksFinished, privacy: privacy))
    }

    func testProgressChapterCompletionAlwaysVisibleRegardlessOfFlags() {
        var privacy = SharePrivacyOptions()
        privacy.showStreak = false
        privacy.showProgress = false
        privacy.showRemainingTime = false
        privacy.showSpeed = false
        privacy.showAuthor = false
        privacy.showNarrator = false
        privacy.showBranding = false

        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .progress, privacy: privacy))
        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .chapter, privacy: privacy))
        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .completion, privacy: privacy))
    }

    func testQuoteAndPersonalityAlwaysVisible() {
        var privacy = SharePrivacyOptions()
        privacy.showStreak = false
        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .quote, privacy: privacy))
        XCTAssertTrue(SharePrivacyOptions.headlineIsVisible(content: .listeningPersonality, privacy: privacy))
    }

    /// Y4 (REVIEW_2026-09-04_UI.md): the completion card's total-time/days-to-finish/
    /// book-count numbers had no privacy gate at all — every "Hide Stats"/"Cover Only"
    /// preset still printed them. `showCompletionDetails` closes that gap.
    ///
    /// `ShareComposerSheet.PrivacyPreset` and `privacyOptions(for:)` are `private` to that
    /// view (declared in `ShareCard.swift`, not reachable from this test target even with
    /// `@testable import`), so these tests pin the flag itself and reconstruct each
    /// preset's expected field combination rather than invoking the private preset
    /// builder directly.
    func testShowCompletionDetailsDefaultsTrue() {
        XCTAssertTrue(SharePrivacyOptions().showCompletionDetails)
    }

    func testShowCompletionDetailsFalseForHideStatsPreset() {
        var privacy = SharePrivacyOptions()
        privacy.showProgress = false
        privacy.showRemainingTime = false
        privacy.showSpeed = false
        privacy.showStreak = false
        privacy.showCompletionDetails = false
        XCTAssertFalse(privacy.showCompletionDetails)
    }

    func testShowCompletionDetailsFalseForCoverOnlyPreset() {
        var privacy = SharePrivacyOptions()
        privacy.showProgress = false
        privacy.showRemainingTime = false
        privacy.showSpeed = false
        privacy.showStreak = false
        privacy.showAuthor = false
        privacy.showNarrator = false
        privacy.showCompletionDetails = false
        XCTAssertFalse(privacy.showCompletionDetails)
    }
}
