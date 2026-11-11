import SwiftUI

/// Shared row builders used across the Settings root menu and every split-out page —
/// extracted out of `SettingsView` (previously private methods on that one struct) so
/// `AccountSecuritySettingsView`, `PlaybackSettingsSection`, `SleepTimerSettingsSection`,
/// `AudioSettingsSection`, `AppearanceSettingsSection`, `DownloadsSettingsView`
/// (`Views/DownloadsView.swift` — merged from the former `DownloadsNotificationsSettingsView`
/// and `DownloadsStorageSettingsView` in Batch 266), and `DiagnosticsSettingsView` can
/// all use them without each duplicating its own copy.
/// Part of UI-12's "Split SettingsView.swift into Views/Settings/" (REVIEW_2026-08-12.md).

/// P-8 (REVIEW_2026-09-14_DESIGN.md): shared cap for a row icon's `@ScaledMetric`,
/// mirroring `PlayerView.cappedTransportMetric` — `min(scaled, base * factor)`
/// guarantees exactly `base` at `.large` and below (`@ScaledMetric` never returns
/// less than `base` there, `.large` being Dynamic Type's own floor) while stopping an
/// icon from ballooning past a size that still reads as "an icon" once AX sizes kick
/// in. 1.6× is the same order of growth `PlayerView`'s row-level metrics allow
/// themselves (1.4×–1.5×) — slightly more headroom here since these icons sit beside
/// wrapping multi-line text rather than a fixed transport row that must keep five
/// controls on one line.
private func cappedRowMetric(_ scaled: CGFloat, base: CGFloat) -> CGFloat {
    min(scaled, base * 1.6)
}

/// A row with a colored icon tile + title + optional subtitle, used for the top-level
/// category menu (`NavigationLink` adds the chevron).
///
/// Real build error (CRIT-3, Batch 135 → fixed here): `Color.shelfAmber`/`onAccent`
/// were marked `@MainActor` when `ThemeStore`'s cached-color statics got that
/// annotation, but this is a plain top-level (free) function, not a method on a
/// `View`-conforming struct — being textually inside `Views/` does NOT make a free
/// function main-actor-isolated the way it does for an actual View's body/methods.
/// Batch 135's own call-site sweep missed exactly this distinction. `@MainActor` here
/// matches every real caller (SwiftUI view bodies), which are already on the main actor.
///
/// Second real build error, on the very next attempt: `@MainActor` on the function
/// itself does NOT cover its own default-parameter-value expressions — Swift checks a
/// default argument's isolation against the declaration's own lexical context, which
/// for a global function is nonisolated, regardless of any isolation attribute on the
/// function. `tint: Color = Color.shelfAmber` therefore still failed with the exact
/// same "referenced from a nonisolated context" error, just moved from the function
/// body to its signature. Fixed by making the default `nil` (isolation-free) and
/// resolving the real default *inside* the body instead, where `@MainActor` genuinely
/// does apply.
///
/// P-7 (REVIEW_2026-09-14_DESIGN.md): every call site used to pass its own `tint:`
/// (Amber/Accent/Amber/Accent…) with no semantic reason for which rows got which —
/// see `SettingsView.swift`'s root menu. New rule, applied at every call site across
/// the files this engineer owns: `Color.shelfAmber` (the app's actual accent) is the
/// default for every row; the emphasis colour is reserved for a destructive or
/// "pay attention" row (Diagnostics, Remove All Downloads, Sign Out, Delete account,
/// anything with `role: .destructive`). `tint` staying an explicit parameter (rather
/// than being removed) is what lets those specific rows still opt into emphasis.
///
/// P-8 (REVIEW_2026-09-14_DESIGN.md): converted from a plain HStack-returning function
/// to a view struct (`MenuRowLabel`) — see `SettingRowLabel`'s own comment below for
/// why a free function can't hold `@ScaledMetric`. The icon tile was a bare 29×29
/// frame with a fixed 15pt glyph, completely inert under Dynamic Type; both now scale
/// via `@ScaledMetric`, capped by `cappedRowMetric` so the tile keeps pace with a
/// wrapping multi-line title without swallowing the row at AX5.
@MainActor
func menuRow(_ icon: String, _ title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil, tint: Color? = nil) -> some View {
    MenuRowLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
}

private struct MenuRowLabel: View {
    let icon: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource?
    let tint: Color?

    @ScaledMetric(relativeTo: .body) private var glyphMetric: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var tileMetric: CGFloat = 29
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var glyphSize: CGFloat { cappedRowMetric(glyphMetric, base: 15) }
    private var tileSide: CGFloat { cappedRowMetric(tileMetric, base: 29) }

    var body: some View {
        // Critique 2026-10-06 (distill): the category tiles were solid amber fills, so
        // the accent sat on every root row as decoration, not signal (DESIGN.md, One
        // Light Rule). A quiet tile now: recessed well fill, muted glyph. An explicit
        // `tint` still colours the glyph, and must be a text-safe colour.
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(tint ?? Color.shelfMuted)
                .frame(width: tileSide, height: tileSide)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.shelfSurface))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(Color.shelfCream)
                if let subtitle, !String(localized: subtitle).isEmpty {
                    Typo.supporting(Text(subtitle))
                        .foregroundStyle(Color.shelfMuted)
                        // Polish pass (Phase 5): let the subtitle wrap at accessibility sizes.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A simple icon + label row, used for every individual toggle/picker/button inside a
/// Settings page.
///
/// R7 (REVIEW_2026-09-04_UI.md): the fixed 24pt icon slot below used to collide with
/// the label at AX3 — a free function can't hold `@ScaledMetric`, so the row is now a
/// tiny view struct that can, and `settingRow` just wraps it to keep every existing
/// call site compiling unchanged.
///
/// P-7 (REVIEW_2026-09-14_DESIGN.md): this struct's icon color used to be hard-coded
/// to `Color.shelfAccent` — since virtually every individual setting row app-wide
/// (Sleep Timer's toggles, Playback's toggles, Account & Security's "Stay signed in"/
/// "Add token to stream URL"/"Require Face ID", Diagnostics's sync/bookmark/link rows,
/// Downloads' toggles in the file that engineer owns) is built through this one
/// function, that single hard-coded default was the actual root cause of the ABAB
/// noise the review called out in Account & Security (the "key" icon) and elsewhere —
/// not per-call-site alternation, one shared default that happened to be the
/// *emphasis* colour applied to rows that are almost never destructive/attention.
/// Default flipped to `Color.shelfAmber` (the accent) and an optional `tint`
/// parameter added, mirroring `menuRow`, so a genuinely destructive/attention row
/// built with `settingRow` can still opt into emphasis explicitly. No current call
/// site in the files this engineer owns needs that override — every plain toggle/
/// picker/link row here is a normal setting, not a destructive or attention one.
///
/// P-8 (REVIEW_2026-09-14_DESIGN.md): the icon itself had no explicit `.font()`, so —
/// unlike the `iconSlot` frame around it, which DID grow via `@ScaledMetric` — the SF
/// Symbol glyph rendered at its native fixed size regardless of Dynamic Type. Result:
/// a growing empty box around a static-size icon, which is exactly the "icon stays
/// ~24pt while the label balloons to ~34pt at AX3" the review measured. Both the
/// glyph's `.font(size:)` and its containing slot are now `@ScaledMetric`, capped via
/// `cappedRowMetric` the same way `MenuRowLabel`'s tile is.
struct SettingRowLabel: View {
    let icon: String
    let text: LocalizedStringResource
    var tint: Color? = nil

    init(icon: String, text: LocalizedStringResource, tint: Color? = nil) {
        self.icon = icon
        self.text = text
        self.tint = tint
    }

    @ScaledMetric(relativeTo: .body) private var glyphMetric: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var slotMetric: CGFloat = 24

    private var glyphSize: CGFloat { cappedRowMetric(glyphMetric, base: 17) }
    private var iconSlot: CGFloat { cappedRowMetric(slotMetric, base: 24) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: glyphSize))
                // Critique 2026-10-06 (colorize): raw shelfAmber glyphs were ~1.9:1 on Light
                // paper and made every row shout. Neutral by default; an explicit `tint`
                // (state/emphasis) still wins, and must itself be a text-safe colour.
                .foregroundStyle(tint ?? Color.shelfMuted)
                // Critique 2026-10-06 (colorize): fixed width (was `minWidth`) so titles
                // align across rows whatever each symbol's intrinsic width.
                .frame(width: iconSlot)
            Text(text)
                .foregroundStyle(Color.shelfCream)
        }
    }
}

@MainActor
func settingRow(_ icon: String, _ text: LocalizedStringResource, tint: Color? = nil) -> some View {
    SettingRowLabel(icon: icon, text: text, tint: tint)
}

/// P-8 (REVIEW_2026-09-14_DESIGN.md): a settings row pairing a leading icon+label
/// (`settingRow`) with a trailing control (`Picker`, `DatePicker`, …). The rows this
/// replaces (see `PlaybackSettingsSection`'s "Default Speed"/"Skip Back"/"Skip
/// Forward", `SleepTimerSettingsSection`'s "Window start/end"/"Timer length"/"Shake
/// gesture", `AppearanceSettingsSection`'s "Theme") used to build the icon as a
/// sibling of the whole control inside one plain `HStack` — fine at the default text
/// size, but at AX3 the control's own internal label wraps/grows independently of
/// that sibling icon, so the icon visually detaches from the text it's meant to sit
/// beside (the exact "stepper wraps and its icon detaches" the review measured on
/// Default Speed).
///
/// Below `.accessibility3` (the same threshold `PlayerView.usesAccessibilityLayout`
/// uses) this renders as `LabeledContent` — icon+label leading, control trailing,
/// matching every row's classic look. At/above it, the control moves BELOW the
/// icon+label in a `VStack` instead of the two competing for the same line. The
/// control itself is unchanged either way — only its position moves — so a `Picker`
/// passed in should give itself a real (accessible) label and hide it visually with
/// `.labelsHidden()`, since `settingRow` is already the row's one visible label.
struct SettingsControlRow<Control: View>: View {
    let icon: String
    let title: LocalizedStringResource
    let control: () -> Control

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var usesAccessibilityLayout: Bool { dynamicTypeSize >= .accessibility3 }

    init(icon: String, title: LocalizedStringResource, @ViewBuilder control: @escaping () -> Control) {
        self.icon = icon
        self.title = title
        self.control = control
    }

    var body: some View {
        if usesAccessibilityLayout {
            VStack(alignment: .leading, spacing: 8) {
                settingRow(icon, title)
                control()
            }
        } else {
            LabeledContent {
                control()
            } label: {
                settingRow(icon, title)
            }
        }
    }
}

// MARK: - Search anchors (Critique 2026-10-06, clarify)

private struct SettingsHighlightedRowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row a Settings search result just landed on, highlighted for a moment.
    var settingsHighlightedRow: String? {
        get { self[SettingsHighlightedRowKey.self] }
        set { self[SettingsHighlightedRowKey.self] = newValue }
    }
}

/// Critique 2026-10-06 (clarify): marks a Settings row as a search destination. Gives the
/// row its `SettingsRow` id for `ScrollViewReader`, and a brief highlight while it's the
/// row a search result opened. Applies the row's card background itself, so the
/// highlight can replace it for a moment.
private struct SettingsRowAnchorModifier: ViewModifier {
    let id: String
    @Environment(\.settingsHighlightedRow) private var highlightedRow

    func body(content: Content) -> some View {
        content
            .id(id)
            .listRowBackground(
                ZStack {
                    Color.shelfCard
                    // A selected-state wash, the accent's job (DESIGN.md: selected controls).
                    Color.shelfAmber.opacity(highlightedRow == id ? 0.22 : 0)
                }
            )
    }
}

extension View {
    /// See `SettingsRowAnchorModifier`.
    func settingsRowAnchor(_ id: String) -> some View {
        modifier(SettingsRowAnchorModifier(id: id))
    }
}

/// Critique 2026-10-06 (clarify): a Settings page's `List`, inside a `ScrollViewReader`,
/// that scrolls to `focusRow` on first appearance and highlights it for about two
/// seconds. Search results used to land at the top of the page and leave the user to
/// hunt. Under Reduce Motion the scroll jumps instead of animating, and (Batch 490, REVIEW
/// 2026-11-11 A5) the highlight switches on and off without the fade.
struct SettingsAnchoredList<Content: View>: View {
    let focusRow: String?
    let content: Content

    @State private var highlightedRow: String?
    @State private var didFocus = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(focusRow: String?, @ViewBuilder content: () -> Content) {
        self.focusRow = focusRow
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                content
            }
            .scrollContentBackground(.hidden)
            .environment(\.settingsHighlightedRow, highlightedRow)
            .task {
                // Once per push: coming back from a sub-page shouldn't replay it.
                guard let focusRow, !didFocus else { return }
                didFocus = true
                // Let the push transition and the List's first layout land.
                try? await Task.sleep(nanoseconds: 350_000_000)
                // Critique 2026-10-06 (polish): left the page before it landed — stop.
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    proxy.scrollTo(focusRow, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(focusRow, anchor: .center)
                    }
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { highlightedRow = focusRow }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                // Cancelled mid-highlight: clear it at once rather than leave it lit.
                guard !Task.isCancelled else { highlightedRow = nil; return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { highlightedRow = nil }
            }
        }
    }
}

// MARK: - One-line captions with an info popover (Critique 2026-10-06, distill)

/// Critique 2026-10-06 (distill): captions under Settings controls ran 30–70 words. Each
/// is now one short line; the longer explanation, where there is one, sits behind an ⓘ
/// that opens a popover (a popover on iPhone too, via `presentationCompactAdaptation`,
/// iOS 16.4+). The button is its own VoiceOver element ("More about …"), outside the
/// control's label, so the control's own label stays short.
struct SettingsCaption: View {
    let text: LocalizedStringResource
    var topic: LocalizedStringResource? = nil
    var detail: LocalizedStringResource? = nil
    /// Leading inset that lines the caption up with the row title after `settingRow`'s icon.
    var leadingInset: CGFloat = 32

    init(text: LocalizedStringResource, topic: LocalizedStringResource? = nil,
         detail: LocalizedStringResource? = nil, leadingInset: CGFloat = 32) {
        self.text = text
        self.topic = topic
        self.detail = detail
        self.leadingInset = leadingInset
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Typo.supporting(Text(text))
                .foregroundStyle(Color.shelfMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                SettingsInfoButton(topic: topic ?? text, detail: detail)
                    // Keeps the 44 pt target without inflating the caption line.
                    .padding(.vertical, -Space.s)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
    }
}

/// The ⓘ behind a `SettingsCaption`. Muted, not accent: it's a tertiary control.
struct SettingsInfoButton: View {
    let topic: LocalizedStringResource
    let detail: LocalizedStringResource
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Typo.metadata(Image(systemName: "info.circle"))
                .foregroundStyle(Color.shelfMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // Its own tap target inside a List row that also holds a Toggle or Picker.
        .buttonStyle(.borderless)
        .accessibilityLabel("More about \(String(localized: topic))")
        .popover(isPresented: $isPresented) {
            Text(detail)
                .foregroundStyle(Color.shelfCream)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(Space.l)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Color.shelfCard)
        }
    }
}

/// Critique 2026-10-06 (distill): a Settings category page — one titled, anchored list.
/// Every page split out of the old "Playback & Appearance" uses it, so they share the
/// background, bottom clearance and search-anchor behaviour.
struct SettingsCategoryPage<Content: View>: View {
    let title: LocalizedStringResource
    var bottomInset: CGFloat = 0
    var focusRow: String? = nil
    let content: Content
    @Environment(PlayerViewModel.self) private var playerViewModel

    init(title: LocalizedStringResource, bottomInset: CGFloat = 0, focusRow: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.bottomInset = bottomInset
        self.focusRow = focusRow
        self.content = content()
    }

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        SettingsAnchoredList(focusRow: focusRow) {
            content
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
        .reexpandsTabBarOnAppear()
    }
}

extension View {
    /// `settingsRowAnchor(_:)` only when `id` is non-nil — for the first row of a
    /// `ForEach`, where only one row may carry the anchor id.
    @ViewBuilder
    func settingsRowAnchor(ifPresent id: String?) -> some View {
        if let id {
            settingsRowAnchor(id)
        } else {
            self
        }
    }
}
