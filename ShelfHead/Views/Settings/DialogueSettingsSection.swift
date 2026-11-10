import SwiftUI

/// Batch 438: Sound settings section for dialogue enhancement and matched loudness. Both default
/// off. Each change re-applies processing at once (`refreshAudioProcessing()` attaches the audio tap
/// to the current item if it wasn't there yet).
struct DialogueSettingsSection: View {
    @AppStorage(SettingsKeys.dialogueEnhance) private var dialogueEnhance = false
    @AppStorage(SettingsKeys.matchLoudness) private var matchLoudness = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $dialogueEnhance) {
                    settingRow("waveform.and.mic", "Clearer voices")
                }
                SettingsCaption(text: "Trims low rumble and muddiness and lifts speech clarity.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $matchLoudness) {
                    settingRow("speaker.wave.2.fill", "Even volume across books")
                }
                SettingsCaption(text: "Slowly nudges quiet or loud books toward the same level.")
            }
        } header: {
            RetroSectionHeader(title: "Voice & Level")
        }
        .listRowBackground(Color.shelfCard)
        .onChange(of: dialogueEnhance) { _, _ in AudioPlayerService.shared.refreshAudioProcessing() }
        .onChange(of: matchLoudness) { _, _ in AudioPlayerService.shared.refreshAudioProcessing() }
    }
}
