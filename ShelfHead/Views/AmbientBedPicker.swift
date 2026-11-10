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
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundStyle(selected ? Color.shelfAmber : Color.shelfMuted)
                Text(verbatim: title)
                    .foregroundStyle(Color.shelfCream)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.shelfAmber)
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

/// Batch 439: the player's "Ambient Sound" sheet.
struct AmbientBedSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AmbientBedPicker()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .background(Color.shelfBackground)
            .navigationTitle("Ambient Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Batch 439: presents `AmbientBedSheet` when the ⋯ menu raises `AmbientBedEngine.pickerRequested`.
/// Used as a `.background` so `PlayerView.swift` needs no new state.
struct AmbientSheetHost: View {
    @State private var engine = AmbientBedEngine.shared

    var body: some View {
        Color.clear
            .sheet(isPresented: $engine.pickerRequested) {
                AmbientBedSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}
