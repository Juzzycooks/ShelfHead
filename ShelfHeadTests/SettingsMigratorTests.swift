import XCTest
@testable import ShelfHead

/// Cover for `SettingsMigrator.startingVersion(...)` — the part of the migration runner
/// that has to be right.
///
/// Getting it wrong re-runs a migration on an install that already has it: step 1 would
/// re-hide Home sections the user deliberately un-hid, which surfaces as "the app reset my
/// Home screen" and would be blamed on almost anything before a settings migration. The
/// three `Bool` flags this replaced are still on disk for every existing install, so the
/// legacy-inference path below is the one every upgrading user actually takes.
final class SettingsMigratorTests: XCTestCase {

    private func version(
        stored: Int? = nil, v2: Bool = false, v3: Bool = false, icon: Bool = false
    ) -> Int {
        SettingsMigrator.startingVersion(
            storedVersion: stored,
            homeDefaultsV2Applied: v2,
            homeDefaultOrderV3Applied: v3,
            alternateIconRevertApplied: icon)
    }

    // MARK: - Fresh install

    func testFreshInstallStartsAtZeroAndRunsEverything() {
        XCTAssertEqual(version(), 0)
    }

    // MARK: - Upgrading installs (the legacy flags)

    func testInstallPastEveryLegacyFlagIsFullyMigrated() {
        XCTAssertEqual(version(v2: true, v3: true, icon: true), SettingsMigrator.currentVersion,
                       "An up-to-date install must run no steps at all")
    }

    func testInstallPastVisibilitySeedOnlyResumesAtOrderSeed() {
        XCTAssertEqual(version(v2: true), 1)
    }

    func testInstallPastBothHomeSeedsResumesAtIconRevert() {
        XCTAssertEqual(version(v2: true, v3: true), 2)
    }

    /// The flags shipped in order and each ran unconditionally at launch, so a later flag
    /// set without an earlier one shouldn't occur. If it somehow does, stopping at the
    /// first unset flag re-runs a step whose own guard is idempotent, rather than skipping
    /// one that genuinely never ran.
    func testGapInLegacyFlagsFallsBackToTheFirstUnsetStep() {
        XCTAssertEqual(version(v2: false, v3: true, icon: true), 0)
        XCTAssertEqual(version(v2: true, v3: false, icon: true), 1)
    }

    // MARK: - Stored version wins

    func testStoredVersionTakesPrecedenceOverLegacyFlags() {
        XCTAssertEqual(version(stored: 2, v2: false, v3: false, icon: false), 2,
                       "Once a version is written, the legacy flags are history")
    }

    func testStoredVersionIsClampedIntoRange() {
        XCTAssertEqual(version(stored: -5), 0, "A corrupt negative must not index a step that doesn't exist")
        XCTAssertEqual(version(stored: 99), SettingsMigrator.currentVersion,
                       "A version from a newer build must not re-run this build's steps")
    }

    func testStoredZeroStillRunsEverything() {
        XCTAssertEqual(version(stored: 0, v2: true, v3: true, icon: true), 0)
    }
}
