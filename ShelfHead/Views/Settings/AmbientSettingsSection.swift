import SwiftUI

/// Batch 439: Sound settings section wrapping `AmbientBedPicker`.
struct AmbientSettingsSection: View {
    var body: some View {
        Section {
            AmbientBedPicker()
        } header: {
            RetroSectionHeader(title: "Ambient Sound")
        }
        .listRowBackground(Color.shelfCard)
    }
}
