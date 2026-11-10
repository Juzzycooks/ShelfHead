import SwiftUI

/// Batch 460: Settings > Appearance > Deck. A thumbnail grid for the six skins plus the
/// Button sounds toggle (off by default). Returns a `Section`; the lead places it in the form.
struct DeckSkinSettingsSection: View {
    @AppStorage(SettingsKeys.deckSkin) private var skinRaw = DeckSkin.default.rawValue
    @AppStorage(SettingsKeys.deckButtonSounds) private var buttonSounds = false
    // Polish pass (Phase 5): the deck glyph was a fixed 26pt; scales with Dynamic Type, capped
    // so it stays inside the 64pt tile.
    @ScaledMetric(relativeTo: .title2) private var skinGlyphSize: CGFloat = 26

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(DeckSkin.allCases) { skin in
                    thumbnail(skin)
                }
            }
            .padding(.vertical, 4)
            Toggle("Button sounds", isOn: $buttonSounds)
        } header: {
            Text("Deck")
        } footer: {
            Text("Each deck redraws the player’s artwork and keys. From the Cover takes its colours from the book that’s playing. Button sounds are short clicks when you press a player key. They follow the volume, and, as with other playback audio, play even when the Silent switch is on, so they are off by default.")
        }
    }

    private func thumbnail(_ skin: DeckSkin) -> some View {
        let selected = skinRaw == skin.rawValue
        return Button {
            skinRaw = skin.rawValue
            Haptics.selection()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.shelfSurface)
                    Image(systemName: skin.symbolName)
                        .font(.system(size: min(skinGlyphSize, 40), weight: .regular))
                        .foregroundStyle(Color.shelfCream.opacity(0.85))
                }
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.shelfCream.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 1))
                Text(skin.displayName)
                    .font(.caption)
                    .foregroundStyle(Color.shelfCream)
                    .multilineTextAlignment(.center)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
