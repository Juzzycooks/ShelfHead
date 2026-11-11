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
                // Batch 490 (REVIEW 2026-11-11 E4): says where the result appears.
                SettingsCaption(text: "ShelfHead asks Audible’s public catalogue about series names in your library. Nothing else is sent. Shows as a shelf on Home.")
                // Batch 490 (REVIEW 2026-11-11 E4): the check runs as soon as the toggle goes on,
                // and its progress and outcome show here instead of nothing until the next launch.
                if enabled {
                    checkStatus
                        .padding(.leading, 32)
                }
            }
            .onChange(of: enabled) { _, isOn in
                guard isOn else { return }
                Task { await radar.refreshIfNeeded(items: libraryItems, force: true) }
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
                    // Batch 490 (REVIEW 2026-11-11 V4): taupe token, not `.secondary`.
                    if let last = radar.lastChecked {
                        Text(last, style: .relative).foregroundStyle(Color.shelfMuted)
                    } else {
                        Text("Never").foregroundStyle(Color.shelfMuted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            RetroSectionHeader(title: "Release Radar")
        }
        .listRowBackground(Color.shelfCard)
    }

    /// Batch 490 (REVIEW 2026-11-11 E4): "Checking your series…" while a check runs, then how many books
    /// it found (or that there's nothing yet). Nothing before the first check has finished.
    @ViewBuilder private var checkStatus: some View {
        if radar.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                    .shelfSpinner()
                Typo.supporting(Text("Checking your series\u{2026}"))
                    .foregroundStyle(Color.shelfMuted)
            }
            .accessibilityElement(children: .combine)
        } else if radar.lastChecked != nil {
            Typo.supporting(Text(verbatim: ReleaseRadarViewModel.checkSummary(count: radar.entries.count)))
                .foregroundStyle(radar.entries.isEmpty ? Color.shelfMuted : Color.shelfCream)
        }
    }
}
