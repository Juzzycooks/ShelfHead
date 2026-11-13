import SwiftUI

/// Batch 439: compact ambient sound picker (None, Rain, Fireplace, Train Cabin, Brown Noise) with a
/// level slider. Used in the player's "Ambient Sound" sheet and in Sound settings.
struct AmbientBedPicker: View {
    @State private var engine = AmbientBedEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                row(title: String(localized: "None", comment: "Ambient sound: off"),
                    icon: "speaker.slash", bed: nil)
                ForEach(AmbientBed.allCases) { bed in
                    Divider().overlay(Color.shelfMuted.opacity(0.25))
                    row(title: bed.label, icon: bed.icon, bed: bed)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Slider(value: Binding(get: { engine.level }, set: { engine.setLevel($0) }), in: 0...1) {
                    Text("Ambient level")
                }
                .tint(Color.shelfAmber)
                .disabled(engine.bed == nil)
                .accessibilityLabel("Ambient level")
                .accessibilityValue(Text("\(Int((engine.level * 100).rounded())) percent"))
                Typo.supporting(Text("Plays quietly under the narration while a book is playing."))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
    }

    private func row(title: String, icon: String, bed: AmbientBed?) -> some View {
        let selected = engine.bed == bed
        return Button {
            Haptics.selection()
            engine.select(bed)
        } label: {
            HStack(spacing: 12) {
                // Batch 490 (REVIEW 2026-11-11 V6): accent ink, not the raw accent fill (about 1.9:1
                // in Light). The surface variant, since the picker also sits on a card in Settings.
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundStyle(selected ? Color.shelfAmberTextOnSurface : Color.shelfMuted)
                Text(verbatim: title)
                    .foregroundStyle(Color.shelfCream)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.shelfAmberTextOnSurface)   // Batch 490 (REVIEW 2026-11-11 V6)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Batch 496 (REVIEW 2026-11-11 P3): which sections the player's Sound sheet shows. Pure so the
/// decision is pinned by tests. Everything the sheet shows is the same section view, with the same
/// `@AppStorage` keys, that Settings › Sound shows; nothing here turns anything on.
enum SoundSheetLayout {
    enum Section: Equatable { case volumeAndTone, voiceAndLevel, spatialAudio, ambientSound }

    /// - Parameters:
    ///   - spatialHeadphonesConnected: the current route supports Spatial Audio.
    ///   - spatialEnabled: the listener's setting; kept visible while on so it can always be turned off.
    static func sections(spatialHeadphonesConnected: Bool, spatialEnabled: Bool) -> [Section] {
        var result: [Section] = [.volumeAndTone, .voiceAndLevel]
        if spatialHeadphonesConnected || spatialEnabled { result.append(.spatialAudio) }
        result.append(.ambientSound)
        return result
    }

    /// The per-book "format not supported" notice only makes sense with a book loaded and the
    /// tone processing reporting it can't handle that book's audio.
    static func showsFormatNotice(hasBook: Bool, formatUnsupported: Bool) -> Bool {
        hasBook && formatUnsupported
    }
}

/// Batch 496 (REVIEW 2026-11-11 P3): the player's "Sound…" sheet — the Settings › Sound sections
/// (and the ambient picker) next to the book you are hearing. Opening it changes nothing; the
/// sections' own `onChange` handlers call `refreshAudioProcessing()`, so edits apply live.
struct SoundSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel
    @AppStorage(SettingsKeys.spatialAudioEnabled) private var spatialEnabled = false
    @State private var spatial = SpatialAudioObserver.shared
    @State private var processingStatus = AudioProcessingStatus.shared

    var body: some View {
        let sections = SoundSheetLayout.sections(spatialHeadphonesConnected: spatial.portSupportsSpatial,
                                                 spatialEnabled: spatialEnabled)
        let showsNotice = SoundSheetLayout.showsFormatNotice(hasBook: playerViewModel.currentBook != nil,
                                                             formatUnsupported: processingStatus.formatUnsupportedThisSession)
        NavigationStack {
            List {
                ForEach(sections, id: \.self) { section in
                    switch section {
                    case .volumeAndTone: AudioSettingsSection(showsFormatNotice: showsNotice)
                    case .voiceAndLevel: DialogueSettingsSection()
                    case .spatialAudio: SpatialAudioSettingsSection()
                    case .ambientSound: AmbientSettingsSection()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .tint(Color.shelfAmberText) // CO-7: switches keep the accent under systemChromeTint() below
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Batch 490 (REVIEW 2026-11-11 V1): the shared close button, as the player's sheets use.
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
        .systemChromeTint()
    }
}

extension SoundSheetLayout.Section: Hashable {}

/// Presents `SoundSheet` when the ⋯ menu raises `AmbientBedEngine.pickerRequested` (the flag keeps
/// its Batch 439 name; `AmbientBedEngine` isn't part of this change). Used as a `.background` so
/// `PlayerView.swift` needs no new state.
struct AmbientSheetHost: View {
    @State private var engine = AmbientBedEngine.shared

    var body: some View {
        Color.clear
            .sheet(isPresented: $engine.pickerRequested) {
                SoundSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}
