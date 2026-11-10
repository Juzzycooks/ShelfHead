import SwiftUI

/// The Sound page's section (its own page from the Settings root since Critique
/// 2026-10-06, distill; previously "Audio" on "Playback & Appearance") — the real-time volume
/// boost / bass / treble tone controls (see `AudioProcessingChain.swift`), split out of
/// the original monolithic "Playback" section (UI-12, REVIEW_2026-08-12.md).
struct AudioSettingsSection: View {
    @AppStorage(SettingsKeys.volumeBoostDB) private var volumeBoostDB: Double = 0
    @AppStorage(SettingsKeys.bassBoostDB) private var bassBoostDB: Double = 0
    @AppStorage(SettingsKeys.trebleBoostDB) private var trebleBoostDB: Double = 0
    /// L3 (REVIEW_2026-08-20_UI_SECURITY.md): was log-only — a user who turned these
    /// on got no toast, no badge, just controls that quietly stopped working. See
    /// `AudioProcessingStatus`'s doc comment (`AudioProcessingChain.swift`).
    @State private var processingStatus = AudioProcessingStatus.shared

    var body: some View {
        Section {
            if processingStatus.formatUnsupportedThisSession {
                Typo.supporting(Label {
                    Text("This book’s audio format isn’t supported by these controls — volume boost, bass, and treble are off for this playback session.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                })
                // DESIGN.md (orange rule): orange glyph, cream sentence — Burnt Orange is
                // ~4.4:1 as text on Light cards.
                .foregroundStyle(Color.shelfCream)
            }
            VStack(alignment: .leading, spacing: 6) {
                settingRow("speaker.wave.3.fill", "Volume boost")
                Slider(value: $volumeBoostDB, in: 0...12, step: 1) {
                    Text("Volume boost")
                }
                .tint(Color.shelfAmber)
                .onChange(of: volumeBoostDB) { _, _ in AudioPlayerService.shared.refreshAudioProcessing() }
                // HIG audit 2026-09-17 M7: without this, VoiceOver spoke the slider's raw
                // 0–12 position rather than the visible caption below it.
                .accessibilityLabel("Volume boost")
                .accessibilityValue(volumeBoostDB == 0 ? "Off" : "+\(Int(volumeBoostDB)) decibels")
                Typo.supporting(Text(volumeBoostDB == 0 ? "Off" : "+\(Int(volumeBoostDB)) dB"))
                    .foregroundStyle(Color.shelfMuted)
            }
            .settingsRowAnchor(SettingsRow.volumeBoost)
            VStack(alignment: .leading, spacing: 6) {
                settingRow("dial.low.fill", "Bass")
                Slider(value: $bassBoostDB, in: -6...6, step: 1) {
                    Text("Bass")
                }
                .tint(Color.shelfAmber)
                .onChange(of: bassBoostDB) { _, _ in AudioPlayerService.shared.refreshAudioProcessing() }
                // HIG audit 2026-09-17 M7: same fix as volume boost above, reusing
                // `toneLabel(_:)` (T5) so the spoken value can never drift from the
                // caption underneath — "dB" spelled out for speech clarity.
                .accessibilityLabel("Bass")
                .accessibilityValue(Self.toneAccessibilityValue(bassBoostDB))
                // T5 (REVIEW_2026-09-04_UI.md)
                Typo.supporting(Text(Self.toneLabel(bassBoostDB)))
                    .foregroundStyle(Color.shelfMuted)
            }
            VStack(alignment: .leading, spacing: 6) {
                settingRow("dial.high.fill", "Treble")
                Slider(value: $trebleBoostDB, in: -6...6, step: 1) {
                    Text("Treble")
                }
                .tint(Color.shelfAmber)
                .onChange(of: trebleBoostDB) { _, _ in AudioPlayerService.shared.refreshAudioProcessing() }
                // HIG audit 2026-09-17 M7: same fix as bass above.
                .accessibilityLabel("Treble")
                .accessibilityValue(Self.toneAccessibilityValue(trebleBoostDB))
                // T5 (REVIEW_2026-09-04_UI.md)
                Typo.supporting(Text(Self.toneLabel(trebleBoostDB)))
                    .foregroundStyle(Color.shelfMuted)
                Typo.fine(Text("Adjusts instantly, even mid-track."))
                    .foregroundStyle(Color.shelfMuted)
            }
        } header: {
            RetroSectionHeader(title: "Volume & Tone")
        }
        .listRowBackground(Color.shelfCard)
        // AN-6 (docs/design-review.md, Round 6): animate the unsupported-format
        // notice's row appearing/disappearing instead of the layout jumping. This
        // row is driven by a runtime status (whether the current book's format
        // supports these controls this session), not a user toggle, but animating
        // it is still harmless — it's still a row insertion under a control block.
        // `.shelfAnimation` is a no-op (nil animation) under Reduce Motion.
        .shelfAnimation(.default, value: processingStatus.formatUnsupportedThisSession)
    }

    /// T5 (REVIEW_2026-09-04_UI.md): Bass/Treble had sliders with no numeric readout,
    /// unlike Volume Boost. Pure so it's unit-testable independent of the view.
    static func toneLabel(_ db: Double) -> String {
        let rounded = Int(db.rounded())
        if rounded == 0 { return String(localized: "Flat", comment: "Tone control readout when bass/treble is at 0 dB") }
        if rounded > 0 { return String(localized: "+\(rounded) dB", comment: "Tone control readout, positive decibels. %lld is the amount.") }
        return String(localized: "\u{2212}\(-rounded) dB", comment: "Tone control readout, negative decibels (leading minus sign). %lld is the magnitude.")
    }

    /// The spoken form of `toneLabel(_:)`. Batch 400: was `toneLabel` with "dB" swapped
    /// for "decibels", which stops matching once the readout is translated.
    static func toneAccessibilityValue(_ db: Double) -> String {
        let rounded = Int(db.rounded())
        if rounded == 0 { return toneLabel(db) }
        if rounded > 0 { return String(localized: "+\(rounded) decibels", comment: "VoiceOver value of a tone control, positive. %lld is the amount.") }
        return String(localized: "\u{2212}\(-rounded) decibels", comment: "VoiceOver value of a tone control, negative (leading minus sign). %lld is the magnitude.")
    }
}
