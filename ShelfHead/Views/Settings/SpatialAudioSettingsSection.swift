import SwiftUI

/// Batch 440: opt-in Spatial Audio on supporting headphones. Default off. The lead plugs
/// this section into the Sound page.
struct SpatialAudioSettingsSection: View {
    @AppStorage(SettingsKeys.spatialAudioEnabled) private var enabled = false
    @State private var observer = SpatialAudioObserver.shared

    private var statusText: LocalizedStringResource {
        switch observer.status(settingEnabled: enabled) {
        case .unavailable: "Connect AirPods or Beats that support Spatial Audio"
        case .availableOff, .on: "Your headphones support Spatial Audio"
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $enabled) {
                    settingRow("headphones", "Spatial Audio")
                }
                .onChange(of: enabled) { _, _ in
                    AudioPlayerService.shared.refreshSpatialAudio()
                }
                SettingsCaption(text: statusText)
                SettingsCaption(text: "Audiobooks are stereo recordings, so this widens the sound rather than placing voices around you. Head tracking and Fixed or Head Tracked are chosen in Control Centre: touch and hold the volume slider.")
            }
        } header: {
            // Batch 490 (REVIEW 2026-11-11 V4): the retro header and card rows every other
            // Settings section uses (was a plain system header on the default row colour).
            RetroSectionHeader(title: "Spatial Audio")
        }
        .listRowBackground(Color.shelfCard)
    }
}
