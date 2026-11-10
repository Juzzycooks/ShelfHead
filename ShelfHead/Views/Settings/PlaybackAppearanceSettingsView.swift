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
                KidsSettingsView()
                    .settingsRowAnchor(SettingsRow.kids)
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
        case .featuresTips:
            FeaturesTipsView(bottomInset: bottomInset, focusRow: focusRow)
        }
    }
}
