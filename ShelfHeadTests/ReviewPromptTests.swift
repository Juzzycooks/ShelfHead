import XCTest
@testable import ShelfHead

/// ASO pass (`ShelfHead/AppStore/AppStoreListing.md`, 14 Sep 2026): "add an in-app review
/// prompt ... after finishing a book or a 7-day streak; never at launch/onboarding/
/// errors". `ReviewPromptManager.decision` is the pure function that encodes those
/// rules, extracted specifically so it can be pinned here rather than exercised through
/// live `UserDefaults` state and a real StoreKit prompt — matching this project's
/// established precedent of unit-testing a pure decision function rather than the
/// stateful I/O around it (see `DownloadOrphanSweepTests`'s header comment).
/// `@MainActor` because `ReviewPromptManager` itself is main-actor-isolated (though
/// `decision` is `nonisolated` and could be called off it too).
@MainActor
final class ReviewPromptTests: XCTestCase {

    private let install = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Install-age rule (never within 3 days of firstSeenAt)

    func testTooSoonAfterInstallIsNotEligible() {
        let now = install.addingTimeInterval(2 * 24 * 3600) // 2 days old
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            ),
            "A 2-day-old install must never be prompted, even with an otherwise-eligible trigger."
        )
    }

    func testInstallAgeBoundaryExactlyThreeDaysIsEligible() {
        let now = install.addingTimeInterval(3 * 24 * 3600) // exactly 3 days
        XCTAssertTrue(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            ),
            "The 3-day install-age gate uses >=, so exactly 3 days old should already be eligible."
        )
    }

    func testInstallAgeBoundaryOneSecondUnderThreeDaysIsNotEligible() {
        let now = install.addingTimeInterval(3 * 24 * 3600 - 1)
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            )
        )
    }

    // MARK: - Cooldown rule (never within 120 days of lastPromptedAt)

    func testWithinCooldownIsNotEligible() {
        let now = install.addingTimeInterval(200 * 24 * 3600)
        let lastPrompted = now.addingTimeInterval(-100 * 24 * 3600) // 100 days ago
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 5,
                streakDays: 0,
                lastPromptedAt: lastPrompted,
                firstSeenAt: install,
                now: now
            ),
            "100 days since the last prompt is still inside the 120-day cooldown."
        )
    }

    func testCooldownBoundaryExactly120DaysIsEligible() {
        let now = install.addingTimeInterval(300 * 24 * 3600)
        let lastPrompted = now.addingTimeInterval(-120 * 24 * 3600)
        XCTAssertTrue(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: lastPrompted,
                firstSeenAt: install,
                now: now
            ),
            "The 120-day cooldown uses >=, so exactly 120 days should already be eligible."
        )
    }

    func testCooldownBoundaryOneSecondUnder120DaysIsNotEligible() {
        let now = install.addingTimeInterval(300 * 24 * 3600)
        let lastPrompted = now.addingTimeInterval(-(120 * 24 * 3600 - 1))
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: lastPrompted,
                firstSeenAt: install,
                now: now
            )
        )
    }

    func testNoPriorPromptSkipsCooldownEntirely() {
        // A `nil` lastPromptedAt (never prompted before) must not be treated as "0 days
        // ago" — it must skip the cooldown check, not fail it.
        let now = install.addingTimeInterval(10 * 24 * 3600)
        XCTAssertTrue(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            )
        )
    }

    // MARK: - Trigger-specific thresholds

    func testBookFinishedRequiresAtLeastOne() {
        let now = install.addingTimeInterval(10 * 24 * 3600)
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 0,
                streakDays: 100,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            ),
            "The .bookFinished trigger must ignore streak days entirely and require booksFinished >= 1."
        )
        XCTAssertTrue(
            ReviewPromptManager.decision(
                trigger: .bookFinished,
                booksFinished: 1,
                streakDays: 0,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            )
        )
    }

    func testStreakRequiresAtLeastSevenDays() {
        let now = install.addingTimeInterval(10 * 24 * 3600)
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .streak,
                booksFinished: 50,
                streakDays: 6,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            ),
            "The .streak trigger must ignore booksFinished entirely and require streakDays >= 7."
        )
        XCTAssertTrue(
            ReviewPromptManager.decision(
                trigger: .streak,
                booksFinished: 0,
                streakDays: 7,
                lastPromptedAt: nil,
                firstSeenAt: install,
                now: now
            )
        )
    }

    func testStreakBoundarySixDaysIsNotEligibleSevenIs() {
        let now = install.addingTimeInterval(10 * 24 * 3600)
        XCTAssertFalse(
            ReviewPromptManager.decision(
                trigger: .streak, booksFinished: 0, streakDays: 6,
                lastPromptedAt: nil, firstSeenAt: install, now: now
            )
        )
        XCTAssertTrue(
            ReviewPromptManager.decision(
                trigger: .streak, booksFinished: 0, streakDays: 7,
                lastPromptedAt: nil, firstSeenAt: install, now: now
            )
        )
    }

    // MARK: - noteBookFinished / noteStreak wiring (state + promptRequested flag)

    /// `noteBookFinished()` must increment the persisted count *before* evaluating
    /// eligibility, so the very first finished book (0 -> 1) already counts.
    func testNoteBookFinishedSetsPromptRequestedOnFirstBook() {
        let defaults = Self.freshDefaults()
        // Back-date firstSeenAt past the install-age gate by writing directly, since a
        // fresh manager would otherwise stamp "now" as its own firstSeenAt.
        defaults.set(Date().addingTimeInterval(-10 * 24 * 3600), forKey: "review_firstSeenAt")
        let backdated = ReviewPromptManager(defaults: defaults)

        XCTAssertFalse(backdated.promptRequested)
        backdated.noteBookFinished()
        XCTAssertEqual(backdated.booksFinishedSinceInstall, 1)
        XCTAssertTrue(backdated.promptRequested, "Finishing the first book on a 10-day-old install should request a prompt.")
    }

    func testNoteStreakDoesNothingBelowSevenDays() {
        let defaults = Self.freshDefaults()
        defaults.set(Date().addingTimeInterval(-10 * 24 * 3600), forKey: "review_firstSeenAt")
        let manager = ReviewPromptManager(defaults: defaults)

        manager.noteStreak(days: 3)
        XCTAssertFalse(manager.promptRequested)

        manager.noteStreak(days: 7)
        XCTAssertTrue(manager.promptRequested)
    }

    func testMarkPromptedPersistsCooldownStart() {
        let defaults = Self.freshDefaults()
        defaults.set(Date().addingTimeInterval(-10 * 24 * 3600), forKey: "review_firstSeenAt")
        let manager = ReviewPromptManager(defaults: defaults)

        manager.noteStreak(days: 7)
        XCTAssertTrue(manager.promptRequested)
        manager.markPrompted()
        manager.promptRequested = false

        // Immediately re-triggering should now be blocked by the fresh 120-day cooldown.
        manager.noteStreak(days: 7)
        XCTAssertFalse(manager.promptRequested, "A prompt just recorded must block another one until the cooldown elapses.")
    }

    /// A throwaway `UserDefaults` suite, uniquely named per call, so tests never read or
    /// leak state through `UserDefaults.standard` or each other. Not explicitly torn
    /// down: each suite name is a fresh UUID, so there's nothing for a later test to
    /// collide with, and the process exiting reclaims it.
    private static func freshDefaults() -> UserDefaults {
        let suiteName = "ReviewPromptTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    // MARK: - writeReviewURL (pure URL builder for the Settings > About row)

    func testWriteReviewURLIsNilWhenAppStoreIDIsNil() {
        XCTAssertNil(ReviewPromptManager.writeReviewURL(appStoreID: nil))
    }

    func testWriteReviewURLIsNilWhenAppStoreIDIsEmpty() {
        XCTAssertNil(ReviewPromptManager.writeReviewURL(appStoreID: ""))
    }

    func testWriteReviewURLBuildsExpectedURL() {
        let url = ReviewPromptManager.writeReviewURL(appStoreID: "123456789")
        XCTAssertEqual(url?.absoluteString, "https://apps.apple.com/app/id123456789?action=write-review")
    }
}
