import Foundation
import UIKit

/// Ordered, one-time settings migrations, run once from `ShelfHeadApp.init()`.
///
/// These used to be three separate `SettingsStore` functions, each with its own `Bool`
/// flag and each re-implementing the same "set the flag, then decide whether to act"
/// prologue, called in a specific order from `ShelfHeadApp.init()` — where the ordering
/// constraint that actually matters (steps 1 and 2 must complete before `HomeView` seeds
/// its `@State` from `hiddenHomeSections`/`homeSectionOrder`, which happens the first time
/// that view is initialized) existed only as a comment at the call site. Nothing stopped a
/// later change from adding a fourth call in the wrong place, or from a step quietly
/// running twice.
///
/// A single monotonic version makes that structural: steps run in order, exactly once,
/// and adding one means appending a `case` and bumping `currentVersion` rather than
/// inventing another flag.
///
/// **Not** included here: `SettingsStore.reconcileNewHomeBrowseSections(...)`. Despite
/// having a flag of its own, it is not a one-time migration — it runs on every Home
/// recompute so the browse-zone cap keeps applying to shelf types that appear later. Its
/// flag marks a first-run bootstrap within an ongoing process, which is a different thing
/// from a migration that must never repeat.
enum SettingsMigrator {

    /// Bump when appending a step to `apply(step:)`.
    static let currentVersion = 3

    private static let versionKey = "settings_schemaVersion"

    // The pre-version flags. Read only by `startingVersion(...)` below, to place an
    // existing install on the version line; never written again.
    private static let legacyHomeDefaultsV2Key = "settings_homeDefaultsV2Applied"
    private static let legacyHomeDefaultOrderV3Key = "settings_homeDefaultOrderV3Applied"
    private static let legacyAlternateIconRevertKey = "settings_alternateIconRevertApplied"

    /// Where an install already on disk sits on the version line.
    ///
    /// This is the part that has to be right: getting it wrong re-runs a migration on an
    /// existing install, and step 1 re-hiding Home sections someone deliberately un-hid is
    /// exactly the kind of silent, user-visible regression that would be blamed on
    /// anything but a settings migration. Pure and separately tested for that reason —
    /// see `SettingsMigratorTests`.
    ///
    /// A stored version always wins. Without one, the legacy flags are read as a
    /// **contiguous prefix**: the three shipped in this order and each ran unconditionally
    /// at launch, so any install past a given step necessarily has every earlier flag set.
    /// Stopping at the first unset flag is therefore both correct for every real install
    /// and conservative for a hypothetical gap — it re-runs a step whose own guard is
    /// idempotent rather than skipping one that never ran.
    static func startingVersion(
        storedVersion: Int?,
        homeDefaultsV2Applied: Bool,
        homeDefaultOrderV3Applied: Bool,
        alternateIconRevertApplied: Bool
    ) -> Int {
        if let storedVersion { return max(0, min(storedVersion, currentVersion)) }
        guard homeDefaultsV2Applied else { return 0 }
        guard homeDefaultOrderV3Applied else { return 1 }
        guard alternateIconRevertApplied else { return 2 }
        return currentVersion
    }

    /// Runs every step the install hasn't seen, in order, persisting after each one so an
    /// interrupted launch resumes rather than restarting.
    ///
    /// Must be called before any view reads the settings these steps seed — see the type's
    /// doc comment.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: versionKey) as? Int
        var version = startingVersion(
            storedVersion: stored,
            homeDefaultsV2Applied: defaults.bool(forKey: legacyHomeDefaultsV2Key),
            homeDefaultOrderV3Applied: defaults.bool(forKey: legacyHomeDefaultOrderV3Key),
            alternateIconRevertApplied: defaults.bool(forKey: legacyAlternateIconRevertKey)
        )
        while version < currentVersion {
            version += 1
            apply(step: version)
            defaults.set(version, forKey: versionKey)
        }
    }

    private static func apply(step: Int) {
        switch step {
        case 1: seedHomeSectionVisibility()
        case 2: seedHomeSectionOrder()
        case 3: revertAlternateAppIcon()
        default: break
        }
    }

    // MARK: - Step 1 (was `applyHomeDefaultsV2IfNeeded`)

    /// Rebalances Home's default section visibility from "show everything" to a capped
    /// BROWSE zone: Next in Series, Recently Added and the downloaded shelf stay visible;
    /// Discover, Listen Again, narrator favourites and the weekly stats teaser are hidden
    /// by default. `LabelContinueListening` (the NOW zone) is untouched — it isn't part of
    /// the cap.
    ///
    /// The list is fixed and hardcoded rather than "whatever is available right now"
    /// because this runs before any network call has loaded `personalizedShelves`, so
    /// "available" would be empty at the moment it has to decide. A section key introduced
    /// later simply defaults to visible, which is the safer failure mode for a feature
    /// nobody has deliberately hidden.
    ///
    /// Only touches an account that has never customised Home — both `hiddenHomeSections`
    /// and `homeSectionOrder` still empty. A non-empty either one means the user has
    /// already expressed a preference (reordering counts), and it is left alone.
    private static func seedHomeSectionVisibility() {
        guard SettingsStore.hiddenHomeSections.isEmpty, SettingsStore.homeSectionOrder.isEmpty else { return }
        let hideByDefault: Set<String> = [
            "LabelDiscover", "LabelListenAgain",
            HomeView.narratorShelfKey, HomeView.weekStatsKey
        ]
        UserDefaults.standard.set(Array(hideByDefault), forKey: SettingsKeys.hiddenHomeSections)
    }

    // MARK: - Step 2 (was `applyHomeDefaultOrderV3IfNeeded`)

    /// Seeds a default BROWSE-tier order — Next in Series → B-Side → Recently Added →
    /// Downloaded — reordering the default from "what exists" toward "what do I play next".
    ///
    /// Only names the four keys whose relative order actually changes;
    /// `SettingsStore.mergedHomeSectionOrder(saved:available:)` appends anything else
    /// (Discover, Listen Again, narrator favourites, Your Week, or a shelf type this list
    /// doesn't know about) after them in `available`'s own order, so the merge still
    /// produces a complete order.
    ///
    /// Skipped entirely for an account that has already dragged its own order, even once.
    private static func seedHomeSectionOrder() {
        guard SettingsStore.homeSectionOrder.isEmpty else { return }
        let seedOrder = [
            "LabelContinueSeries", HomeView.bSideKey,
            "LabelRecentlyAdded", HomeView.downloadedShelfKey
        ]
        UserDefaults.standard.set(seedOrder, forKey: SettingsKeys.homeSectionOrder)
    }

    // MARK: - Step 3 (was `revertAlternateAppIconIfNeeded`)

    /// The alternate-app-icon picker (Cassette/Book/Monogram) was removed along with the
    /// asset-catalog entries backing those names, under App Store Review Guideline 4.6.
    /// Anyone who had actually selected one is left with iOS pointing at an icon name no
    /// longer in the bundle — reverted explicitly here rather than left to iOS's undefined
    /// behaviour for a missing alternate icon. Also clears the now-unused
    /// `settings_iconVariant` default, which would otherwise linger forever.
    private static func revertAlternateAppIcon() {
        UserDefaults.standard.removeObject(forKey: "settings_iconVariant")
        guard UIApplication.shared.alternateIconName != nil else { return }
        UIApplication.shared.setAlternateIconName(nil) { error in
            if let error {
                ShelfLog.error(.storage, "revertAlternateAppIcon: setAlternateIconName(nil) failed: \(error.localizedDescription)")
            }
        }
    }
}
