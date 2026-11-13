import SwiftUI

/// Critique 2026-10-06 (distill): this file used to hold `PlaybackAppearanceSettingsView`,
/// one page of ~30 controls (Listening Profile / Playback / Sleep Timer / Audio /
/// Appearance) whose Playback group mixed speed and skips with Spotlight, Classic Lock
/// Screen and iCloud sync. It's now split into five pages reached straight from the
/// Settings root — Playback, Sleep Timer, Sound, Appearance, System & Privacy — each a
/// `SettingsCategoryPage` around the same `Section` views, so every binding and side
/// effect is unchanged; only where a control lives moved. The file name is kept (the
/// `ShelfHead/` folder isn't a synced group, so no project-file change).
///
/// `SettingsDestinationView` is the one router from a `SettingsPage` to its screen, used
/// by both the root menu and search results, so the two can't send the same page to
/// different places. `focusRow` (a `SettingsRow` id) scrolls the page to that row and
/// highlights it; pages owned elsewhere (Recent Changes) ignore it.
struct SettingsDestinationView: View {
    let page: SettingsPage
    var bottomInset: CGFloat = 0
    var focusRow: String? = nil
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        switch page {
        case .account:
            AccountSecuritySettingsView(bottomInset: bottomInset, focusRow: focusRow)
        case .playback:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                PlaybackSettingsSection()
            }
        case .sleepTimer:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                SleepTimerSettingsSection()
            }
        case .sound:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                AudioSettingsSection()
                DialogueSettingsSection()
                    .settingsRowAnchor(SettingsRow.dialogue)
                SpatialAudioSettingsSection()
                    .settingsRowAnchor(SettingsRow.spatialAudio)
                AmbientSettingsSection()
                    .settingsRowAnchor(SettingsRow.ambientSound)
            }
        case .appearance:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                AppearanceSettingsSection()
                DeckSkinSettingsSection()
                    .settingsRowAnchor(SettingsRow.deckSkin)
            }
        case .systemPrivacy:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                SystemPrivacySettingsSection(bottomInset: bottomInset)
                // Batch 492 (N2): Export/Import Settings moved here from Account & Security.
                SettingsBackupSection()
            }
        case .downloads:
            DownloadsSettingsView(bottomInset: bottomInset, focusRow: focusRow)
        case .diagnostics:
            DiagnosticsSettingsView(bottomInset: bottomInset, focusRow: focusRow)
        case .recentChanges:
            PlaybackHistoryView(bottomInset: bottomInset)
        case .household:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                HouseholdSettingsView()
            }
        // Batch 492 (REVIEW 2026-11-11 N2): Kids was the bottom half of the Household page; it is
        // its own page now, linked from the Settings root.
        case .kids:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                KidsSettingsView()
                    .settingsRowAnchor(SettingsRow.kids)
            }
        case .serverTools:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                ServerToolsSettingsSection(bottomInset: bottomInset)
            }
        // Batch 492 (N1 part 3): Release Radar's own page (was a section of System & Privacy).
        case .releaseRadar:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                ReleaseRadarSettingsSection(libraryItems: libraryViewModel.items)
                    .settingsRowAnchor(SettingsRow.releaseRadar)
                    .listRowBackground(Color.shelfCard)
            }
        case .transcripts:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                TranscriptsSettingsView()
            }
        case .readingSites:
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                ReadingSitesView()
                    .settingsRowAnchor(SettingsRow.readingSites)
            }
        case .appleWatch:
            // Batch 496 (REVIEW 2026-11-11 W13): what the Watch can do and whether it is signed in.
            SettingsCategoryPage(title: .verbatim(page.title), bottomInset: bottomInset, focusRow: focusRow) {
                AppleWatchSettingsSection()
            }
        case .featuresTips:
            FeaturesTipsView(bottomInset: bottomInset, focusRow: focusRow)
        }
    }
}
