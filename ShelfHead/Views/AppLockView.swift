import SwiftUI

/// Full-screen cover shown while `AppLockManager.isLocked` is true. Opaque (not a blur
/// over the real content) so nothing sensitive is visible even for a frame — the app's
/// last screen simply isn't drawn underneath while this is up (see `ContentView`, which
/// only mounts `MainTabView` behind this in the view hierarchy, never removes it, but
/// this sits above it at a high `zIndex`).
struct AppLockView: View {
    /// SEC-3: `false` when this is only up to blank the app-switcher snapshot while
    /// the scene is briefly `.inactive` (not actually locked yet) — a Face ID prompt
    /// firing just because a system sheet or notification pull-down passed through
    /// would be jarring and pointless. Manual unlock via the button still works either
    /// way; this only gates the automatic prompt-on-appear.
    var showsPrompt: Bool = true
    let onUnlock: () -> Void

    // HIG audit 2026-09-17 M11: read the device's actual biometry so the glyph and
    // button copy below match it instead of hardcoding Face ID.
    @State private var appLock = AppLockManager.shared

    // AX-5 (docs/design-review.md, Round 4): the lock glyph was a fixed
    // `.font(.system(size: 44))` that didn't grow with Dynamic Type while the title
    // right below it (`.title3`, see `body`) did. `relativeTo: .title3` keeps this
    // scaling in step with that title instead of falling behind it at AX sizes. Base
    // value (44) is the screen's original literal, so default-size rendering is
    // unchanged.
    @ScaledMetric(relativeTo: .title3) private var lockGlyphSize: CGFloat = 44

    // AX-5: mirrors the `min(scaled, base * factor)` cap convention used elsewhere in
    // the app (`PlayerView.cappedTransportMetric`, `SettingsComponents`'
    // `cappedRowMetric`) — `@ScaledMetric` never returns less than `base` at `.large`
    // and below (`.large` is Dynamic Type's own floor), so this is exactly 44 there,
    // unchanged by construction. At AX sizes it grows with the title but stops at 1.5x
    // so the glyph stays proportional to the title rather than ballooning past what
    // still reads as an icon above it.
    private var cappedLockGlyphSize: CGFloat {
        min(lockGlyphSize, 44 * 1.5)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // AX-5: mirrors `PlayerView`'s `usesAccessibilityLayout` threshold. Below this,
    // `body` renders the plain, non-scrolling `VStack` exactly as before; at or above
    // it, the title (wrapping) and the button (also growing) can together exceed even
    // the shortest supported phone's height (iPhone SE, 667pt), which would push the
    // unlock button off screen with no way to reach it — so this size class gets a
    // `ScrollView` instead.
    private var needsScrollableLayout: Bool { dynamicTypeSize >= .accessibility3 }

    // AX-12 (docs/design-review.md, follow-up): the glyph and button title used to come
    // from two separate switches in this view (one only covering Face ID/Touch ID, the
    // other used for the button copy), so a device with Optic ID — or a future biometry
    // case — could show a mismatched padlock glyph next to a correct-sounding button.
    // Both now read `AppLockManager.biometrySymbolName`/`biometryDisplayName` directly,
    // the single shared source of truth.

    // AX-5: the icon is decorative — `lockContent`'s title text already says "ShelfHead
    // is Locked", so this would only be a redundant extra VoiceOver stop ahead of it
    // (the same reasoning `EmptyStateView`'s icon fix (AX-3) uses).
    private var lockContent: some View {
        VStack(spacing: 20) {
            Image(systemName: appLock.biometrySymbolName)
                .font(.system(size: cappedLockGlyphSize))
                .foregroundStyle(Color.shelfAmberText)
                .accessibilityHidden(true)
            Text("ShelfHead is Locked")
                // HIG audit 2026-09-17 M6: fixed 20pt didn't grow with Dynamic
                // Type; a text-style-relative rounded font (matching
                // `YearInReviewView`'s `.font(.system(.largeTitle, design:
                // .rounded))` pattern) scales properly instead.
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(Color.shelfCream)
            Button {
                onUnlock()
            } label: {
                // HIG audit 2026-09-17 M11: glyph and title now follow the
                // device's real biometry instead of always claiming Face ID.
                // AX-12: both read from `AppLockManager` so they can't drift
                // from the big glyph above or from each other.
                Label("Unlock with \(appLock.biometryDisplayName)", systemImage: appLock.biometrySymbolName)
                    .shelfButtonStyle()
            }
            // Critique 2026-10-06 (colorize): was borderedProminent + raw amber (white
            // text on amber, ~2:1); the project's primary style uses Amber Ink.
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
        }
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if needsScrollableLayout {
                // AX-5: only reached at `.accessibility3` and above — below that,
                // the `else` branch renders `lockContent` exactly as before, so
                // default-size layout is bit-for-bit unchanged. Indicators
                // deliberately left visible (the default), matching `PlayerView`'s
                // own `AccessibilityScrollColumn`: at these sizes the column really
                // can be taller than the screen, and the scroll bar is the only
                // thing on the page that says so.
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        lockContent
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                lockContent
            }
        }
        // Prompt automatically the moment this view appears, so the Face ID sheet
        // shows up immediately rather than requiring an extra tap on first return —
        // but only when actually locked (see `showsPrompt`).
        .task { if showsPrompt { onUnlock() } }
        .accessibilityAddTraits(.isModal)
    }
}
