import SwiftUI

/// Batch 442: opt-in release radar. Drop into a Form/List as a `Section` group (like
/// `TranscriptsSettingsView`'s content). `libraryItems` feeds "Check now".
struct ReleaseRadarSettingsSection: View {
    let libraryItems: [LibraryItem]

    @AppStorage(SettingsKeys.releaseRadarEnabled) private var enabled = false
    @AppStorage(SettingsKeys.releaseRadarRegion) private var regionRaw = ""
    @State private var radar = ReleaseRadarViewModel.shared

    private var region: Binding<AudibleRegion> {
        Binding(get: { AudibleRegion(rawValue: regionRaw) ?? AudibleRegion.default() },
                set: { regionRaw = $0.rawValue })
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $enabled) { settingRow("calendar.badge.clock", "Release Radar") }
                SettingsCaption(text: "ShelfHead asks Audible’s public catalogue about series names in your library. Nothing else is sent.")
            }
            if enabled {
                Picker(selection: region) {
                    ForEach(AudibleRegion.allCases) { r in Text(verbatim: r.displayName).tag(r) }
                } label: { settingRow("globe", "Audible Store") }
                Button {
                    Task { await radar.refreshIfNeeded(items: libraryItems, force: true) }
                } label: {
                    HStack {
                        settingRow("arrow.clockwise", "Check now")
                        if radar.isRefreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(radar.isRefreshing)
                HStack {
                    Text("Last checked")
                    Spacer()
                    if let last = radar.lastChecked {
                        Text(last, style: .relative).foregroundStyle(.secondary)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            RetroSectionHeader(title: "Release Radar")
        }
        .listRowBackground(Color.shelfCard)
    }
}
