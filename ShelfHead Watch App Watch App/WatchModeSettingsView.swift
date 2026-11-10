import SwiftUI

/// Mode override screen — direct fix for two real on-device symptoms reported
/// against this app (28 August 2026): downloads had no reachable code path at
/// all, and starting playback with the phone nearby always relayed to the phone
/// instead of playing on the Watch. Root cause was one gate, not two bugs:
/// `WatchStore.resolveMode()` only ever chose `.standalone` when the phone was
/// unreachable, with no override — see `WatchStore.ModePreference`'s own doc
/// comment for the full analysis.
///
/// Reached from `SettingsView` > Play On (Critique 2026-10-06; it spent a while buried
/// under Diagnostics > Troubleshooting as "Watch Mode").
///
/// P-9 item 1 (REVIEW_2026-09-14_DESIGN.md): choosing between two playback stacks is
/// not a decision to put in front of everyone — Automatic is the only mode the app
/// presents as a choice now, and the root screen no longer changes shape when the mode
/// flips (`WatchHomeView`), which was most of what made the override look necessary.
/// Nothing here is deleted or disabled: `WatchStore.ModePreference` and its
/// persistence are unchanged and this picker still works exactly as it did. It is
/// buried, and labelled as troubleshooting, not removed.
///
/// `SettingsView` is still the screen it hangs off, for the same reason as before:
/// it's the one screen linked from the root in both modes, so this stays reachable
/// regardless of which stack is currently live — which matters, since flipping between
/// them is the entire point.
struct WatchModeSettingsView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(WatchStore.ModePreference.allCases, id: \.self) { preference in
                    modeRow(preference)
                }
            } footer: {
                // Critique 2026-10-06 (shape → harden): moved here from Diagnostics >
                // Troubleshooting, in plain words. Automatic is still the answer for most
                // people, and a downloaded book always offers Play on Watch whatever this
                // says (`WatchBookPlayOptions`).
                VStack(alignment: .leading, spacing: 6) {
                    Text("Automatic suits most people. Downloaded books always offer Play on Watch, and a book playing on this Watch keeps playing here until you stop it.")
                    // The row itself is disabled below; this says why.
                    if store.authState != .active {
                        Text("This Watch needs its own sign-in first. Set it up in Settings > Account.")
                    }
                }
            }
        }
        // UI polish pass — see ChaptersView's identical comment: `.carousel` now
        // applies to every top-level list screen, not just the two roots.
        .listStyle(.carousel)
        .navigationTitle("Play On")
    }

    // UI polish pass (task tracked as "WatchModeSettingsView icons"): these three
    // rows were the one settings-style row group in the app with no leading icon
    // at all, breaking the icon-column rhythm every sibling screen
    // (`WatchSettingsView`, `WatchAccountView`) establishes via `WatchRow`. Not
    // switched to `WatchRow` itself since these rows need a trailing checkmark
    // plus per-row `.disabled` state that `WatchRow` doesn't expose — but they now
    // share its icon column width and font tiers.
    private func icon(for preference: WatchStore.ModePreference) -> String {
        switch preference {
        case .automatic: return "arrow.triangle.2.circlepath"
        case .alwaysCompanion: return "iphone"
        case .alwaysStandalone: return "applewatch"
        }
    }

    @ViewBuilder
    private func modeRow(_ preference: WatchStore.ModePreference) -> some View {
        let isDisabled = preference == .alwaysStandalone && store.authState != .active
        Button {
            store.setModePreference(preference)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: preference))
                    .font(WatchMetrics.rowIconFont())
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isDisabled ? WatchTheme.secondaryText : WatchTheme.icon)   // Critique 2026-10-06 (colorize): static icon, neutral
                    .watchIconColumn()
                VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                    Text(preference.title)
                        .font(WatchMetrics.contentRowTitleFont(weight: .medium))
                        .foregroundStyle(isDisabled ? WatchTheme.secondaryText : WatchTheme.primaryText)
                    Text(preference.subtitle)
                        .font(WatchMetrics.subtitleFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                }
                Spacer(minLength: 0)
                if store.modePreference == preference {
                    Image(systemName: "checkmark")
                        .font(WatchMetrics.secondaryFont(weight: .semibold))
                        .foregroundStyle(WatchTheme.accent)
                }
            }
            .padding(.vertical, WatchMetrics.rowVerticalPadding)
        }
        .disabled(isDisabled)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { WatchModeSettingsView() }
        .environment(WatchStore.shared)
}
