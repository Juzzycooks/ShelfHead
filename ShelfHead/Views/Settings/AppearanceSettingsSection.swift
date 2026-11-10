import SwiftUI

/// The Appearance page's section (its own page from the Settings root since Critique
/// 2026-10-06, distill) — theme (light/dark/
/// system) and accent color pickers, both backed by the shared `ThemeStore` rather than
/// their own `@AppStorage` (see `ThemeStore.swift`). Split out of `SettingsView`
/// (UI-12, REVIEW_2026-08-12.md).
struct AppearanceSettingsSection: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        @Bindable var themeStore = themeStore
        Section {
            // P-8 (REVIEW_2026-09-14_DESIGN.md): moves the picker below the label at
            // accessibility sizes instead of the two fighting for the same line — see
            // `SettingsControlRow`'s own doc comment.
            SettingsControlRow(icon: "circle.lefthalf.filled", title: "Theme") {
                Picker("Theme", selection: $themeStore.appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
                .labelsHidden()
            }
            .settingsRowAnchor(SettingsRow.theme)

            VStack(alignment: .leading, spacing: 12) {
                // P-7 (REVIEW_2026-09-14_DESIGN.md): was a hand-built `HStack` with a
                // fixed 24pt `Color.shelfAccent` icon — neither accent-default (P-7)
                // nor scaled (P-8). `settingRow` fixes both at once.
                settingRow("paintpalette.fill", "Accent Colour")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(AppTheme.accentOptions, id: \.hex) { option in
                            let isSelected = themeStore.accentHex.caseInsensitiveCompare(option.hex) == .orderedSame
                            Button {
                                Haptics.selection()
                                themeStore.accentHex = option.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: option.hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle().strokeBorder(Color.shelfCream,
                                                              lineWidth: isSelected ? 3 : 0)
                                    )
                                    .overlay(
                                        Typo.fine(Image(systemName: "checkmark"), weight: .bold)
                                            .foregroundStyle(Color.onAccent)
                                            .opacity(isSelected ? 1 : 0)
                                    )
                                    // Critique 2026-10-06 (adapt): was 40 pt wide; a full 44 × 44
                                    // target now (HIG). Spacing tightened to keep the row's width.
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Critique 2026-10-06 (adapt): state as a trait, not as words in
                            // the label, so VoiceOver reports it the standard way.
                            .accessibilityLabel("\(option.name) accent")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .settingsRowAnchor(SettingsRow.accentColour)

        } header: {
            RetroSectionHeader(title: "Appearance")
        }
        .listRowBackground(Color.shelfCard)
    }
}
