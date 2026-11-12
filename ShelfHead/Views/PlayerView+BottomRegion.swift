import SwiftUI
import AVKit
import UIKit

/// Wraps `AVRoutePickerView` so AirPlay/output device selection works from the player.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        // One-time, non-scheme-dependent config only. Tint colours are NOT set here — see
        // `updateUIView` below for why.
        picker.prioritizesVideoDevices = false
        return picker
    }

    // Tints are assigned here, not in `makeUIView`, and deliberately re-derived from
    // `context.environment.colorScheme` on every call — do not "tidy" this back into
    // `makeUIView`. `shelfCream` is scheme-adaptive (`adaptive(light:dark:)` in
    // Extensions.swift), and `UIColor(Color.shelfCream).withAlphaComponent(0.5)` flattens
    // that dynamic colour to whichever trait collection happens to be ambient the instant
    // it's called. `makeUIView` runs exactly once, so a plain assignment there bakes in
    // whichever scheme was active when the player first appeared; flip light/dark (by hand,
    // or the system at sunset) while the full player is open and the AirPlay glyph is stuck
    // tinted for the old scheme. Fix: resolve `shelfCream` against an explicit
    // `UITraitCollection` built from the current `colorScheme` *before* flattening the
    // alpha, so the alpha lands on the correct scheme's colour every single time this runs,
    // instead of on whatever was ambient. `shelfAmber` carries the same
    // set-once-in-makeUIView exposure in principle (accent-colour changes are covered
    // separately by the `accentHex`-keyed subtree rebuild in ContentView, but colour-scheme
    // changes are not), so it's re-applied here too for the same reason.
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        let traits = UITraitCollection(
            userInterfaceStyle: context.environment.colorScheme == .dark ? .dark : .light
        )
        // Polish 2026-10-05: 0.7, the same inactive tone as the other four tool columns
        // (`ToolbarColumnLabel`); at 0.5 AirPlay read as the one disabled-looking tool.
        let inactiveTint = UIColor(Color.shelfCream).resolvedColor(with: traits).withAlphaComponent(0.7)
        let activeTint = UIColor(Color.shelfAmber)

        // Redundancy guard: `UIColor` is `Equatable`, and `updateUIView` can run many times
        // for reasons unrelated to tint (any SwiftUI state this view's environment depends
        // on) — skip the write when nothing actually changed to avoid needless redraws.
        if uiView.tintColor != inactiveTint {
            uiView.tintColor = inactiveTint
        }
        if uiView.activeTintColor != activeTint {
            uiView.activeTintColor = activeTint
        }
    }
}

/// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
/// everything below is verbatim what lived on `PlayerView` itself.
///
/// This file is the player's whole bottom region: the sleep-timer/Up Next status chips,
/// the five-column secondary toolbar (speed / sleep / chapters / bookmarks / AirPlay) and
/// the `GlassEffectContainer` that groups them on iOS 26+, together with the small
/// separately-observed views those columns render through. `toolbarIconSlotSide` lives
/// here with the row it sizes; `FormattingAndModelsTests` calls it directly, so its name
/// and signature are load-bearing.
extension PlayerView {
    /// Pure half of `toolbarIconSlot` so its floor can be pinned by a test.
    ///
    /// Floored at 44 — the HIG hit-target minimum, which the route picker must *physically*
    /// be since it hit-tests itself — and capped at 1.5×, the most this secondary row can
    /// grow before it starts competing with the transport controls above it for height. At
    /// the default 17pt glyph (15pt before HL-7, V5) this returns exactly 44, i.e. the
    /// literal it replaces.
    static func toolbarIconSlotSide(forIconSize iconSize: CGFloat) -> CGFloat {
        max(44, min(66, 44 * iconSize / 17))
    }

    // MARK: - Bottom Glass Region (iOS 26/27 Liquid Glass polish pass, 26 August 2026)

    /// The sleep-timer/Up Next status chips plus `bottomToolbar`, grouped into one
    /// `GlassEffectContainer` on iOS 26+ so their individual glass shapes (the chips'
    /// `glassPill`, the toolbar's per-button active pill) can blend at the edges when
    /// they end up close together, rather than each compositing as its own
    /// disconnected material. See the call site's own doc comment (in `body`) for why
    /// this stops at the toolbar/chips and doesn't also pull in `playerHeaderMenu`, and
    /// why no `.glassEffectID` morphing is used between them. Plain, unwrapped content
    /// on iOS 17–25 — `GlassEffectContainer` doesn't exist there, and nothing inside
    /// this region needs one (each fallback material already stands on its own).
    @ViewBuilder var bottomGlassRegion: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                bottomGlassRegionContent
            }
        } else {
            bottomGlassRegionContent
        }
    }

    @ViewBuilder private var bottomGlassRegionContent: some View {
        // Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §5.1) merged the sleep and Up Next chips
        // into one status line; critique 2026-10-05 (third run) adds "Jump back" to that same
        // line. See `StatusChipRow`.
        StatusChipRow(onOpenQueue: { showQueue = true })

        bottomToolbar
            .padding(.top, 18)
    }

    private var bottomToolbar: some View {
        // H2 (REVIEW_2026-09-04_UI.md Pass 3): `.top`, not the default `.center`. A column
        // whose label wraps grows taller than its neighbours, and centring each column on
        // its own height then lifts that column's icon visibly above the rest of the row —
        // the AX1 "Bookmark" / "s" capture, and reachable at the default size too whenever
        // the sleep column reads "End of chapter +2". Top-aligning the row means the five
        // icon slots line up no matter what any label does underneath them. A no-op
        // wherever every column is the same height, which is every state except that one.
        // IC-4 (docs/visual-design-review.md, Round V1): forces outline-only glyphs for
        // this row so a future icon added here can't silently drift to a `.fill` variant
        // the way the sleep and bookmark icons did (fixed below).
        HStack(alignment: .top, spacing: 0) {
            toolbarButton(icon: "speedometer", label: LocalizedStringResource(stringLiteral: speedLabel), active: playerViewModel.playbackRate != 1.0,
                          accessibilityLabel: "Playback speed, \(speedLabel)",
                          accessibilityHint: "Opens the speed picker") {
                showSpeedPicker = true
            }
            .sheet(isPresented: $showSpeedPicker) {
                SpeedSheet()
                    .environment(playerViewModel)
                    // Code review fix (26 August 2026): added `.large` as an escape
                    // valve for large accessibility Dynamic Type sizes, where the now-
                    // scrollable content (see `SpeedSheet.body`) may not fully fit at
                    // the fixed 340pt height. [device check] on the exact size this
                    // first becomes necessary at.
                    // Batch 490 (REVIEW 2026-11-11 P7): `.medium` instead of a fixed 340pt,
                    // which clipped the ×/WPM controls once they moved to the top.
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }

            // Item 13 (REVIEW-2026-09-09.md): was `toolbarButton(... label: sleepTimerText ...)`
            // right here — `sleepTimerText` reads `playerViewModel.sleepTimerRemaining`,
            // which ticks every second while a countdown timer is running, and that read
            // happened during `PlayerView.body`'s own evaluation (this call sits inside
            // `bottomToolbar`, which `body` calls directly). One second of a running sleep
            // timer therefore re-ran the whole player screen. `SleepTimerToolbarButton`
            // reads `playerViewModel` itself so the tick only invalidates this one column;
            // it renders through the same `ToolbarButtonContent` the other three buttons
            // still get from `toolbarButton` below, so the sizing math is identical.
            //
            // Critique 2026-10-05 (distill): the timer used to open a `confirmationDialog`
            // with up to 13 options, no mark on the current one, and "Off" first even with
            // no timer running. It's now a system `Menu` (HIG Menus) — see
            // `SleepTimerToolbarButton` for what it holds.
            SleepTimerToolbarButton(
                toolbarIconSize: toolbarIconSize,
                toolbarIconSlot: toolbarIconSlot,
                toolbarLabelPointSize: toolbarLabelPointSize,
                usesAccessibilityLayout: usesAccessibilityLayout
            )

            // Critique 2026-10-05: disabled for a book with no chapters (a podcast
            // episode, a single-file book) rather than opening an empty sheet. Batch 427:
            // unless that sheet can offer suggested chapters.
            toolbarButton(icon: "list.bullet", label: "Chapters", active: false,
                          accessibilityHint: "Opens the chapter list",
                          enabled: playerViewModel.hasChapterList || chapterSuggestionsOffered) {
                showChapters = true
            }

            // Batch 218 (R10.1): the visible label was singular ("Bookmark"),
            // which reads as "save this moment" — but tapping opens the bookmarks
            // *list/sheet*, not an add action (adding happens from inside that
            // sheet). The accessibility label already correctly said "Bookmarks";
            // aligned the visible text to match what actually happens on tap.
            // IC-4 (docs/visual-design-review.md, Round V1): was "bookmark.fill" — the
            // only other filled glyph in this row besides the sleep icon below, next to
            // three outline peers.
            toolbarButton(icon: "bookmark", label: "Bookmarks", active: false,
                          accessibilityHint: "Opens saved bookmarks, or add one for this moment") {
                showBookmarks = true
            }
            // Polish 2026-10-05 (critique minor): adding a bookmark took the sheet, its add
            // button and a note alert. Long-press is the one-step path, the iOS pattern for
            // a secondary action on a control; the sheet keeps the with-a-note path.
            // VoiceOver gets the same action from the actions rotor.
            .contextMenu {
                Button { addQuickBookmark() } label: {
                    Label("Add Bookmark Here", systemImage: "bookmark")
                }
            }
            // CO-7: the menu row's glyph in the label colour, like every other menu here.
            .systemChromeTint()
            .accessibilityAction(named: "Add bookmark here") { addQuickBookmark() }

            VStack(spacing: 3) {
                // UI-12: `RoutePickerView` wraps a real `UIView` (`AVRoutePickerView`),
                // which handles its own touches directly — unlike a SwiftUI `Button`,
                // the enclosing `.frame(minHeight: 44)` on the `VStack` below does
                // nothing for it, since that frame only constrains *layout*, not the
                // `UIViewRepresentable`'s own hit-testing. Sized to the full 44x44
                // minimum directly on the picker itself instead of the 30x30 it was
                // rendered at.
                //
                // H2 (REVIEW_2026-09-04_UI.md Pass 3): the hardcoded 44×44 made this the
                // only glyph in the row that never grew — by AX5 the four SF Symbols were
                // roughly double it and it read as disabled. `toolbarIconSlot` is the same
                // scaled slot those four now use, so this column stays exactly as tall as
                // they are and the picker grows with them, never below the 44pt floor.
                // **[device check]**: the frame is the only lever SwiftUI has here —
                // `AVRoutePickerView` renders its own glyph from its bounds and exposes no
                // image or symbol-size API — so how closely the glyph tracks the SF Symbols
                // at AX4/AX5 has to be eyeballed on a device rather than assumed.
                RoutePickerView()
                    .frame(width: toolbarIconSlot, height: toolbarIconSlot)
                // H2: icons-only from AX3 (`usesAccessibilityLayout`), same as the four `toolbarButton`
                // columns. The `.accessibilityLabel("AirPlay")` below is unaffected, and
                // `AVRoutePickerView` supplies its own label to VoiceOver regardless.
                if !usesAccessibilityLayout {
                    Text("AirPlay")
                        .font(.system(size: toolbarLabelPointSize, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(Color.shelfCream.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            // Same natural-height hold as `ToolbarColumnLabel` (critique 2026-10-05, second
            // run), or this column alone compresses under pressure and sits ~8 pt high.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("AirPlay")
        }
        // IC-4 (docs/visual-design-review.md, Round V1): on the container, not each
        // glyph, so it can't be missed on a future column added to this HStack.
        .symbolVariant(.none)
        // Feeds `toolbarLabelPointSize`'s width cap (critique 2026-10-05, fourth run).
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarRowWidth = $0 }
        // Design-direction pass (17 Aug 2026), points 2 & 5: this row used to sit
        // inside its own `.ultraThinMaterial` card with a hairline border — one more
        // "card inside surface" layer stacked right below the sleep-timer/Up Next
        // chips, competing with the cover/transport controls above for "which of
        // these is the important part of the screen." Speed/sleep/chapters/
        // bookmarks/AirPlay are explicitly the secondary layer (point 5); dropping
        // the card lets it sit directly on the background like point 2 asks, with
        // just a hairline top divider to mark where the primary layer ends — each
        // button's own active-state pill (below) is the only "card" left here, and
        // only appears for a control that's genuinely on.
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.shelfCream.opacity(0.08)).frame(height: 1)
        }
    }

    private func toolbarButton(icon: String, label: LocalizedStringResource, active: Bool,
                                accessibilityLabel: LocalizedStringResource? = nil, accessibilityHint: LocalizedStringResource? = nil,
                                enabled: Bool = true,
                                action: @escaping () -> Void) -> some View {
        // Item 13 (REVIEW-2026-09-09.md): the actual button/pill rendering used to live
        // right in this method's body. Pulled out into `ToolbarButtonContent` so
        // `SleepTimerToolbarButton` (below) can render an identical column from its own,
        // separately-observed `body` instead of going through this instance method (which
        // would tie its rendering back to `PlayerView`'s own body evaluation). This
        // wrapper keeps every existing call site (speed/chapters/bookmarks) unchanged.
        ToolbarButtonContent(icon: icon, label: label, active: active,
                             accessibilityLabel: accessibilityLabel, accessibilityHint: accessibilityHint,
                             toolbarIconSize: toolbarIconSize, toolbarIconSlot: toolbarIconSlot,
                             toolbarLabelPointSize: toolbarLabelPointSize,
                             usesAccessibilityLayout: usesAccessibilityLayout, enabled: enabled, action: action)
    }

    // MARK: - Helpers

    /// Bookmarks the current moment in one step and confirms it with the app's toast,
    /// unless `addBookmark` already posted its offline "will sync" note.
    private func addQuickBookmark() {
        let time = playerViewModel.currentTime
        let chapter = playerViewModel.currentChapter
        Task {
            // No book → no save → no false confirmation (critique 2026-10-05, second run).
            guard let result = await playerViewModel.addBookmark(at: time) else { return }
            Haptics.success()
            // `.queued` already posted its own "will sync" message. The moment is said in
            // the chapter-relative form the counters and the bookmark list use.
            if result == .synced {
                playerViewModel.infoMessage = String(localized: "Bookmarked \(BookmarksSheet.momentLabel(time: time, chapter: chapter))", comment: "Toast after a bookmark is saved. %@ is the moment, e.g. '12:44 · Chapter 3'")
            }
        }
    }

    /// Cleanup pass (Batch N-5 redundancy close-out): was its own formatting body,
    /// identical to `SpeedSheet.label(_:)` — both now share `PlayerView.speedLabel(_:)`
    /// in `PlayerView+Formatting.swift`.
    private var speedLabel: String {
        PlayerView.speedLabel(Double(playerViewModel.playbackRate))
    }

    // Item 13 (REVIEW-2026-09-09.md): `sleepTimerText` and `sleepStatusChip` used to live
    // here as computed properties, both reading `playerViewModel.sleepTimerRemaining` —
    // a value that ticks every second while a countdown timer is running. Reading them
    // from `PlayerView`'s own body (via `bottomToolbar`/`bottomGlassRegionContent`) meant
    // one second of a running sleep timer re-rendered the entire player screen, not just
    // the chip/column showing the countdown. Moved to `SleepTimerToolbarButton` and
    // `SleepStatusChip` below, which each read `playerViewModel` from their own `body` so
    // the tick invalidates only that small view. See those types' doc comments.

    // MARK: - Up Next chip


}

// MARK: - Toolbar button rendering (Item 13, REVIEW-2026-09-09.md)

/// The actual button/pill visual for one `bottomToolbar` column — icon, optional label,
/// active-state pill, hit target and accessibility wiring. Pulled out of `PlayerView`'s
/// `toolbarButton(...)` instance method so `SleepTimerToolbarButton` below can render the
/// identical column from its own `body` without needing an instance of `PlayerView`
/// itself. Every parameter here is a plain, already-resolved value — none of them is an
/// `@Observable` read — so this type carries no observation of its own; whichever caller
/// constructs it (`PlayerView.toolbarButton` or `SleepTimerToolbarButton`) is the one
/// whose body re-runs when the values feeding it change.
private struct ToolbarButtonContent: View {
    let icon: String
    let label: LocalizedStringResource
    let active: Bool
    let accessibilityLabel: LocalizedStringResource?
    let accessibilityHint: LocalizedStringResource?
    let toolbarIconSize: CGFloat
    let toolbarIconSlot: CGFloat
    let toolbarLabelPointSize: CGFloat
    let usesAccessibilityLayout: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            ToolbarColumnLabel(icon: icon, label: label, active: active,
                               toolbarIconSize: toolbarIconSize, toolbarIconSlot: toolbarIconSlot,
                               toolbarLabelPointSize: toolbarLabelPointSize,
                               usesAccessibilityLayout: usesAccessibilityLayout, enabled: enabled)
        }
        .disabled(!enabled)
        // Custom label/hint override the default icon+visible-text reading when the
        // visible text alone is ambiguous out of context (e.g. "1.5×" or "Sleeps in 8:02").
        .accessibilityElement(children: accessibilityLabel == nil ? .combine : .ignore)
        .accessibilityLabel(Text(accessibilityLabel ?? label))
        .accessibilityHint(accessibilityHint.map { Text($0) } ?? Text(verbatim: ""))
    }
}

/// The icon-over-label column every `bottomToolbar` control draws, split out of
/// `ToolbarButtonContent` so the sleep timer's `Menu` (critique 2026-10-05, distill) can use
/// the identical column as its label. Sizing, active pill and colours are unchanged.
private struct ToolbarColumnLabel: View {
    let icon: String
    let label: LocalizedStringResource
    let active: Bool
    let toolbarIconSize: CGFloat
    let toolbarIconSlot: CGFloat
    let toolbarLabelPointSize: CGFloat
    let usesAccessibilityLayout: Bool
    var enabled: Bool = true

    // CO-3 (docs/visual-design-review.md, Round V1): the active pill behind this label is
    // tinted Liquid Glass on iOS 26+ (`Color.shelfAmber`, see `ToolbarActivePill`), which
    // drops amber-on-amber text as low as ~2.4:1. `Color.onAccent` is contrast-aware ink
    // for that fill, same pattern as `RetroTabBar.selectedTextColor` in
    // RetroComponents.swift. The iOS 17–25 pill is a flat, much lighter tint, where
    // `shelfAmberText` still reads fine, so that fallback is unchanged.
    private var activeInk: Color {
        if #available(iOS 26.0, *) { return Color.onAccent }
        return Color.shelfAmberText
    }

    var body: some View {
        VStack(spacing: 3) {
            // Fixed after user testing: icons/labels across the toolbar didn't line
            // up. Root cause is the AirPlay column further down, whose real
            // `RoutePickerView` is forced to a fixed 44x44 (a real `UIView`, so its
            // hit-testable bounds must physically be that size — see that column's
            // own comment) while these four SF Symbol icons were left to their
            // natural (much shorter) rendered height. `HStack`'s default `.center`
            // cross-axis alignment centers each column independently around its own
            // total content height, so the taller AirPlay column and these shorter
            // ones ended up centered at different points — misaligning every icon
            // and label in the row, not just AirPlay's. Giving this icon the same
            // fixed 44pt-tall slot makes every column's total content height equal,
            // so they all center identically.
            //
            // H2 (REVIEW_2026-09-04_UI.md Pass 3): the 44 is now `toolbarIconSlot` —
            // still exactly 44 at the default size, but scaled (and shared with the
            // AirPlay column) so the equal-height guarantee this comment describes
            // survives the accessibility sizes, where a ~47pt glyph no longer fits a
            // fixed 44pt box.
            Image(systemName: icon)
                .font(.system(size: toolbarIconSize))
                .frame(height: toolbarIconSlot)
            // H2: from AX1 up, five labels cannot share a phone's width one line each
            // at any point size that's still proportionate to a 40pt body — AX3
            // rendered "Chapt…" / "Book…" with the columns touching. Dropping the text
            // beats ellipsising it: VoiceOver loses nothing (every caller either passes
            // an explicit `accessibilityLabel` or falls through to `label` itself,
            // below), and what's left is five plain, larger, well-spaced glyphs.
            // The tradeoff worth naming: the speed column's visible "1.5×" goes with
            // it. The amber active pill still says the setting is on, and the value is
            // one tap away in the speed sheet. The sleep column's countdown is not
            // lost — `SleepStatusChip` above shows it in full whenever a timer is armed.
            if !usesAccessibilityLayout {
                Text(label)
                    .font(.system(size: toolbarLabelPointSize, weight: .medium))
                    // Critique 2026-10-05 (third run): with the column held at its natural
                    // height (`fixedSize`, below), a long label could wrap — "Bookmark/s"
                    // on an iPhone SE. One line that shrinks instead.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        // ≥44pt hit target (HIG minimum) with the whole area tappable — already
        // satisfied by the icon's own 44pt-tall slot above, so no extra vertical
        // padding is needed here (adding any would re-introduce the same per-column
        // height mismatch against the AirPlay column this fix just resolved).
        .foregroundStyle(active ? activeInk : Color.shelfCream.opacity(enabled ? 0.7 : 0.25))
        .frame(maxWidth: .infinity, minHeight: 44)
        // Critique 2026-10-05 (second run), root cause found in the simulator: this screen
        // doesn't scroll below the AX layout, so when the status chips and "Jump back" all
        // show, the row is squeezed and each column was compressed to its 44 pt minimum
        // while its icon-plus-label content (~60 pt) spilled out below. Invisible on the
        // plain columns; on an active one the pill (sized to the frame) covered only the
        // glyph and "Sleep" hung below it in dark ink. Holding the column at its natural
        // height makes the flexible artwork above give way instead. (Batches 365 and 369
        // blamed the glass and the Menu; both theories were wrong.)
        .fixedSize(horizontal: false, vertical: true)
        // Previously the only signal an option was "on" (speed ≠1×, a sleep timer
        // running) was the icon/label switching to amber — easy to miss at a glance.
        // A soft background pill makes the active state read immediately, matching
        // the selected treatment already used for chips elsewhere (Library filters,
        // Share presets).
        //
        // iOS 26/27 Liquid Glass polish pass (26 August 2026): was a flat
        // `Color.shelfAmber.opacity(0.14)` fill on every iOS version. On 26+ this
        // now mirrors `RetroTabBar`'s `selectionGlass` — tinted, interactive
        // Liquid Glass instead of a flat tint — since this pill lives inside
        // `bottomToolbar`'s own `GlassEffectContainer` (below) alongside the
        // sleep-timer/Up Next chips just above it, so its glass can blend with
        // theirs when they're close together instead of reading as a separate,
        // disconnected material. The iOS 17–25 fallback is the exact original
        // flat fill, unchanged.
        //
        // CO-3 (Batch 353): the tinted glass used to sit on a `Color.clear` shape in
        // `.background`, and inside `bottomGlassRegion`'s `GlassEffectContainer` the
        // combined glass was composited over the label, so an active pill showed as a
        // solid amber tile with no glyph or text. The glass now goes on the column
        // content itself (Apple: `glassEffect(_:in:)` "renders a shape anchored behind
        // a view"), toggled with `Glass.identity` when inactive so the view's identity
        // doesn't change. See `ToolbarActivePill`.
        .modifier(ToolbarActivePill(active: active))
        .contentShape(Rectangle())
    }
}

/// CO-3 (Batch 353): the active-state pill behind a `bottomToolbar` column. On iOS 26+
/// it's tinted, interactive Liquid Glass applied to the column content (not to an empty
/// background shape, which the surrounding `GlassEffectContainer` drew over the label),
/// with `Glass.identity` (iOS 26.0) when inactive. The 4pt horizontal padding is applied
/// to every column, active or not, so column widths stay equal. The iOS 17–25 fallback
/// is the original flat fill, unchanged.
private struct ToolbarActivePill: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                // P-6: a deliberate one-off; no `Space.*` token is this small.
                .padding(.horizontal, 4)
                .glassEffect(active ? .regular.tint(Color.shelfAmber).interactive() : .identity,
                             in: RoundedRectangle(cornerRadius: Radius.card))
        } else {
            content.background {
                if active {
                    RoundedRectangle(cornerRadius: Radius.card).fill(Color.shelfAmber.opacity(0.14))
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

/// The sleep-timer column in `bottomToolbar`. Item 13 (REVIEW-2026-09-09.md): this used
/// to be a plain `toolbarButton(...)` call inside `PlayerView.bottomToolbar`, fed
/// `sleepTimerText` (a computed property reading `playerViewModel.sleepTimerRemaining`,
/// which ticks every second while a countdown is running) — so every tick re-ran the
/// whole `PlayerView.body`. This type reads `playerViewModel` from its own `body`
/// instead, so the tick invalidates only this one column. The four sizing values are
/// plain, already-resolved `CGFloat`/`Bool`s handed down from `PlayerView` (its
/// `@ScaledMetric`/`@Environment(\.dynamicTypeSize)`-derived `toolbarIconSize`/
/// `toolbarIconSlot`/`toolbarLabelPointSize`/`usesAccessibilityLayout`) so the sizing math
/// stays byte-identical to the other three toolbar columns — those don't change with the
/// sleep timer, so passing them down doesn't reintroduce the per-tick dependency.
private struct SleepTimerToolbarButton: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let toolbarIconSize: CGFloat
    let toolbarIconSlot: CGFloat
    let toolbarLabelPointSize: CGFloat
    let usesAccessibilityLayout: Bool
    /// Batch 490 (REVIEW 2026-11-11 F20): the "Custom…" length picker.
    @State private var showCustomSleep = false

    private var spokenSleepValue: String {
        let remaining = playerViewModel.sleepTimerRemaining
        if remaining > 0 {
            let mins = Int(remaining) / 60
            if mins > 0 {
                return mins == 1 ? String(localized: "1 minute left", comment: "VoiceOver value of the sleep timer button: one minute remains")
                                 : String(localized: "\(mins) minutes left", comment: "VoiceOver value of the sleep timer button. %lld is minutes remaining (not 1)")
            }
            return String(localized: "\(Int(remaining)) seconds left", comment: "VoiceOver value of the sleep timer button. %lld is seconds remaining")
        }
        return playerViewModel.sleepTimerOption == .off ? String(localized: "Off", comment: "VoiceOver value of the sleep timer button when no timer is set") : playerViewModel.sleepTimerOption.label
    }

    /// One menu row per option. A `Toggle` inside a `Menu` draws the system checkmark
    /// when on, which marks the armed option without a `Picker` (whose selection would be
    /// the unlisted `.off` whenever no timer runs). Choosing the already-armed row is a
    /// no-op rather than turning it off; "Turn Off" is the explicit way to do that.
    private func optionToggle(_ option: SleepTimerOption) -> some View {
        Toggle(option.label, isOn: Binding(
            get: { playerViewModel.sleepTimerOption == option },
            set: { isOn in
                guard isOn else { return }
                Haptics.selection()
                playerViewModel.setSleepTimer(option)
            }
        ))
    }

    /// Shake-to-reset/extend is otherwise easy to never discover; the old dialog carried
    /// this line as its message (F2). Shown as the picks' section header when shaking does
    /// something.
    private var shakeHint: LocalizedStringResource? {
        switch SettingsStore.shakeAction {
        case .off: return nil
        case .reset: return "Shake anytime to reset the timer"
        case .extend: return "Shake anytime to extend the timer by 15 minutes"
        }
    }

    /// "Skip tonight" is only offered while the bedtime window is on and hasn't already
    /// been skipped — unchanged from the dialog this menu replaces.
    private var offersSkipTonight: Bool {
        SettingsStore.scheduledSleepTimerEnabled
            && (SettingsStore.scheduledSleepTimerSuppressedUntil ?? .distantPast) <= Date()
    }

    var body: some View {
        let hasChapters = !playerViewModel.chapters.isEmpty
        let isActive = playerViewModel.sleepTimerOption != .off
        // Critique 2026-10-05 (distill), HIG Menus: a system menu instead of the old
        // 13-row dialog. Top level is at most two actions (only while a timer runs) plus
        // the four common picks; the other presets sit one level down in "More". `Toggle`
        // rows give the native checkmark. The menu opens from the bottom of the
        // screen, so `.automatic` order puts the first items nearest the finger.
        Menu {
            if isActive {
                Section {
                    if playerViewModel.sleepTimerRemaining > 0 {
                        Button {
                            Haptics.selection()
                            playerViewModel.extendSleepTimer(by: 15 * 60)
                        } label: { Label("Add 15 Minutes", systemImage: "plus") }
                    }
                    // Batch 490 (REVIEW 2026-11-11 F20): same as the chip's "+1 chapter".
                    if AudioPlayerService.optionAfterAddingChapter(playerViewModel.sleepTimerOption) != nil {
                        Button {
                            Haptics.selection()
                            playerViewModel.extendSleepTimerByOneChapter()
                        } label: { Label("Add 1 Chapter", systemImage: "plus") }
                    }
                    // Goes through `turnOffSleepTimer()` so the player offers the
                    // "Sleep timer off · Undo" chip, same as the status chip's ✕.
                    Button {
                        Haptics.selection()
                        playerViewModel.turnOffSleepTimer()
                    } label: { Label("Turn Off", systemImage: "moon.zzz") }
                }
            }
            Section {
                ForEach(SleepTimerOption.menuQuickPicks(hasChapters: hasChapters), id: \.label) { option in
                    optionToggle(option)
                }
                Menu {
                    ForEach(SleepTimerOption.menuMorePicks(hasChapters: hasChapters), id: \.label) { option in
                        optionToggle(option)
                    }
                    // Batch 490 (REVIEW 2026-11-11 F20): any length from 1 to 180 minutes.
                    Button {
                        Haptics.selection()
                        showCustomSleep = true
                    } label: { Label("Custom\u{2026}", systemImage: "timer") }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            } header: {
                if let shakeHint { Text(shakeHint) }
            }
            if offersSkipTonight {
                Section {
                    Button {
                        Haptics.selection()
                        playerViewModel.skipScheduledSleepTimerTonight()
                    } label: { Label("Skip Scheduled Timer Tonight", systemImage: "bed.double") }
                }
            }
        } label: {
            // IC-4 (docs/visual-design-review.md, Round V1): was "moon.zzz.fill" — the
            // status chip's own moon glyph (`SleepStatusChip` below) stays filled; it isn't
            // part of this row.
            // Critique 2026-10-05 (clarify): the visible label stays "Sleep". The
            // countdown used to show here as "14m" while the status chip above said
            // "Sleeps in 14:25" — the same timer spelled twice. The chip owns the time;
            // the active pill says a timer is on; VoiceOver still hears the time.
            ToolbarColumnLabel(
                icon: "moon.zzz",
                label: "Sleep",
                active: isActive,
                toolbarIconSize: toolbarIconSize,
                toolbarIconSlot: toolbarIconSlot,
                toolbarLabelPointSize: toolbarLabelPointSize,
                usesAccessibilityLayout: usesAccessibilityLayout
            )
        }
        // CO-7: menu text and checkmarks in the label colour, not amber on glass.
        .systemChromeTint()
        .sheet(isPresented: $showCustomSleep) {
            CustomSleepTimerSheet { minutes in
                playerViewModel.setSleepTimer(.minutes(minutes))
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .accessibilityLabel("Sleep timer")
        // Critique 2026-10-05 (second run): was spoken "29m". `spokenSleepValue` says it in
        // words; the visible label stays "Sleep".
        .accessibilityValue(spokenSleepValue)
        .accessibilityHint("Opens sleep timer options")
    }
}

/// Batch 490 (REVIEW 2026-11-11 F20): "Custom…" in the Sleep menu's More. A wheel of 1–180
/// minutes, like Clock's timer; Start arms an ordinary `.minutes(n)` timer, so the Live
/// Activity, widgets, Control Center and Watch see nothing new.
private struct CustomSleepTimerSheet: View {
    let onStart: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = SleepTimerOption.clampedCustomMinutes(
        SettingsStore.defaultSleepTimerMinutes > 0 ? SettingsStore.defaultSleepTimerMinutes : 30)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                Picker("Minutes", selection: $minutes) {
                    ForEach(Array(SleepTimerOption.customMinutesRange), id: \.self) { value in
                        Text(SleepTimerOption.minutes(value).label).tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .padding(.horizontal, Space.xl)
            }
            .navigationTitle("Custom Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }.monochromeToolbarItem()
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "Start") {
                        Haptics.selection()
                        onStart(SleepTimerOption.clampedCustomMinutes(minutes))
                        dismiss()
                    }
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
    }
}

/// The active sleep-timer status chip shown above `bottomToolbar` (in
/// `bottomGlassRegionContent`) whenever a timer is armed. Item 13 (REVIEW-2026-09-09.md):
/// same defect and same fix shape as `SleepTimerToolbarButton` above — this used to be a
/// `PlayerView` computed property (`sleepStatusChip`) reading `sleepChipLabel`, which
/// reads `playerViewModel.sleepTimerRemaining` and re-formats it every second a countdown
/// is running. Reading `playerViewModel` here instead means the tick invalidates only
/// this chip, not the screen around it. `PlayerView.bottomGlassRegionContent` still reads
/// `playerViewModel.sleepTimerOption`/`.upNext` itself to decide *which* chip(s) to show —
/// that's a structural, not per-tick, read (it only changes when the timer is armed/
/// disarmed or Up Next gains/loses an entry), so leaving it there doesn't reintroduce the
/// per-second whole-screen invalidation this fix removes.
private struct SleepStatusChip: View {
    @Environment(PlayerViewModel.self) private var playerViewModel

    /// Critique 2026-10-06 (clarify): the same line as the mini player's, from the one shared
    /// `MiniPlayerStatus.sleepText` — end-of-chapter shows the wall-clock time left in the
    /// chapter (media time divided by speed) instead of a different phrase on each surface.
    private var sleepChipLabel: String {
        let hasChapter = playerViewModel.currentChapter != nil
        let chapterRemaining = hasChapter
            ? max(0, playerViewModel.chapterLength - playerViewModel.chapterElapsed) : nil
        return MiniPlayerStatus.sleepText(option: playerViewModel.sleepTimerOption,
                                          remaining: playerViewModel.sleepTimerRemaining,
                                          chapterRemaining: chapterRemaining,
                                          rate: Double(playerViewModel.playbackRate))
            ?? String(localized: "Sleep timer on", comment: "Sleep timer status chip fallback text when a timer is armed")
    }

    var body: some View {
        // UI-4: this chip and `upNextChip` (in `PlayerView`) below had six near-identical
        // `.font(.system(size: 12, ..., design: .rounded))` calls between them, each
        // separately deciding the weight — `Typo.chip` is the one shared "12pt rounded
        // chip label" role, parameterized only by the weight each label actually needs.
        HStack(spacing: 10) {
            Typo.chip(Image(systemName: "moon.zzz.fill"))
                .foregroundStyle(Color.shelfAmberText)        // active = amber is appropriate
                // The label beside it already says "Sleeps in…"; the glyph would only add
                // an unlabelled "moon" stop to the VoiceOver rotor.
                .accessibilityHidden(true)
            Typo.chip(Text(sleepChipLabel), weight: .medium)
                .foregroundStyle(Color.shelfCream.opacity(0.85))
                .monospacedDigit()

            // Extend only applies to a running countdown.
            // Batch 490 (REVIEW 2026-11-11 F20): a chapter timer's extension is a chapter,
            // in the slot +15m takes for a countdown (+15m stays in the Sleep menu, where
            // it turns a chapter timer into minutes).
            if AudioPlayerService.optionAfterAddingChapter(playerViewModel.sleepTimerOption) != nil {
                Divider().frame(height: 14).overlay(Color.shelfCream.opacity(0.12))
                    .padding(.horizontal, 2)
                Button {
                    Haptics.selection()
                    playerViewModel.extendSleepTimerByOneChapter()
                } label: {
                    Typo.chip(Text("+1 chapter"), weight: .semibold)
                        .frame(minWidth: 20, minHeight: 20)
                        .contentShape(Rectangle().inset(by: -12))
                }
                .foregroundStyle(Color.shelfAmberText)
                .buttonStyle(.plain)
                .accessibilityLabel("Add 1 chapter")
                .accessibilityHint("Stops the sleep timer one chapter later")
            } else if playerViewModel.sleepTimerRemaining > 0 {
                // Critique 2026-10-05: 2pt either side of the divider keeps the two
                // enlarged hit areas below (+15m's reaches 12pt right, ✕'s 12pt left)
                // from overlapping across what was a 21pt gap.
                Divider().frame(height: 14).overlay(Color.shelfCream.opacity(0.12))
                    .padding(.horizontal, 2)
                Button { playerViewModel.extendSleepTimer(by: 15 * 60) } label: {
                    Typo.chip(Text("+15m"), weight: .semibold)
                        .frame(minWidth: 20, minHeight: 20)
                        // Critique 2026-10-05: the 44pt target used to be a
                        // `.overlay(Color.clear.frame(width: 44, height: 44))`. A clear
                        // fill isn't hit-tested in SwiftUI, so the real target was the
                        // ~30×15pt text. A content shape grown 12pt on every side makes
                        // the tappable area ≥44pt without changing the chip's height.
                        .contentShape(Rectangle().inset(by: -12))
                }
                .foregroundStyle(Color.shelfAmberText)
                .buttonStyle(.plain)
                .accessibilityLabel("Add 15 minutes")
                .accessibilityHint("Extends the sleep timer")
            }

            Button {
                playerViewModel.turnOffSleepTimer()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(10, weight: .bold, relativeTo: .caption2)
                    // Batch 490 (REVIEW 2026-11-11 A5): was cream at 55%, under 3:1 on the
                    // glass in Light; the muted token clears it in both themes.
                    .foregroundStyle(Color.shelfMuted)
                    // Batch 218 (R10.6): UI-12's original fix gave this glyph a
                    // real `.frame(width: 44, height: 44)` to get a HIG-minimum
                    // tap target — correct on its own, but that 44pt height, plus
                    // this chip's own vertical padding on top of it, is exactly
                    // what made the whole capsule ~60pt tall on a screen built not
                    // to scroll. Shrunk the glyph's own layout footprint back down
                    // and moved the 44×44 tap target into an invisible `.overlay`
                    // instead: an overlay's size doesn't feed into this HStack's
                    // own height the way a real `.frame` on a direct child does,
                    // so the capsule can go back to sizing itself from the much
                    // shorter text/icon content next to it while the × still gets
                    // a full HIG-minimum touch target.
                    .frame(width: 20, height: 20)
                    // Critique 2026-10-05: see +15m above — the clear overlay this used
                    // never received taps. 20pt grown by 12pt per side is 44×44.
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn off sleep timer")
            .accessibilityHint("You can undo this")
        }
        // P-6: 14, matching `upNextChip`'s own chip inset above — see there for why no
        // token spells this.
        .padding(.horizontal, 14)
        // Code review fix (26 August 2026): was 6 — `upNextChip` right below uses 8.
        // Batch 4's merge (§5.1) puts these two capsules side by side in the same
        // `HStack`/`GlassEffectContainer` when both are active, where the ~4pt height
        // difference read as a rendering glitch rather than two matched chips.
        // Standardized on 8, the taller of the two — this chip already carries the
        // taller content (the ✕'s own 20pt frame), so raising it costs the least.
        .padding(.vertical, 8)
        // Liquid Glass audit (7 September 2026): this chip is a bare `HStack`, not a
        // `Button` — only the embedded `+15m` and ✕ buttons are actually tappable, so the
        // default `interactive: true` made the whole capsule deform/highlight on press
        // while most of its surface did nothing. Same reasoning already recorded on
        // `glassPill`'s doc comment (interactive glass on a read-only surface advertises a
        // tap target that isn't there) and the same fix already applied at the toast pill
        // (`Extensions.swift:802`) and the PRECISE badge (`RetroComponents.swift:394`).
        // Contrast `upNextChip` right below, which IS wrapped in a `Button` and correctly
        // stays interactive.
        .glassPill(Capsule(), interactive: false)
    }
}

/// Critique 2026-10-05: shown in the sleep chip's place right after its ✕ turns the timer
/// off. One tap puts the same timer back (`PlayerViewModel.undoSleepTimerOff()`); it goes
/// away on the same explicit events as "Jump back" (setting any timer, a book change, the
/// player closing), never on a clock — HIG audit M2's reasoning applies equally here.
private struct SleepUndoChip: View {
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        Button { playerViewModel.undoSleepTimerOff() } label: {
            HStack(spacing: 8) {
                Typo.chip(Image(systemName: "moon.zzz"))
                    .foregroundStyle(Color.shelfMuted)
                Typo.chip(Text("Sleep timer off"), weight: .medium)
                    .foregroundStyle(Color.shelfCream.opacity(0.85))
                Divider().frame(height: 14).overlay(Color.shelfCream.opacity(0.12))
                Typo.chip(Text("Undo"), weight: .semibold)
                    .foregroundStyle(Color.shelfAmberText)
            }
            // Matches `SleepStatusChip`'s and `upNextChip`'s 14×8 inset so the capsules
            // keep one height when they share the row.
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassPill(Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep timer off. Undo")
        .accessibilityHint("Turns the sleep timer back on")
        .transition(.opacity)
    }
}

/// The player's single status line. Third run (critique 2026-10-05): "Jump back", the sleep
/// timer (or its Undo) and Up Next share one row, because each extra row came straight out of
/// the cover's height on an iPhone SE. Fourth run (user decision, "sleep anchored, others
/// flow"): the sleep chip is the bedtime safety readout, so it's always first and always
/// whole — the scrolling row this replaces cut it to "Sleeps in 29:" with +15m and ✕
/// off-screen whenever Jump back was up. Jump back and Up Next share what's left through
/// `ViewThatFits`: full, then compact ("↶ 0:29", "Up Next (2)"), then dropped. No sideways
/// scrolling, one centred alignment for any chip count. Its own view so the per-second reads
/// (`activeSeekUndoTime` follows `currentTime`) don't re-run `PlayerView.body` (Item 13).
struct StatusChipRow: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let onOpenQueue: () -> Void

    private var hasSleep: Bool { playerViewModel.sleepTimerOption != .off || playerViewModel.sleepUndo != nil }
    private var hasJump: Bool { playerViewModel.activeSeekUndoTime != nil }
    private var hasUpNext: Bool { !playerViewModel.upNext.isEmpty }
    private var isEmpty: Bool { !hasSleep && !hasJump && !hasUpNext }

    var body: some View {
        HStack(spacing: 10) {
            if playerViewModel.sleepTimerOption != .off {
                SleepStatusChip().fixedSize()
            } else if playerViewModel.sleepUndo != nil {
                SleepUndoChip().fixedSize()
            }
            if hasJump || hasUpNext {
                ViewThatFits(in: .horizontal) {
                    flowing(jumpCompact: false, upNextCompact: false)
                    flowing(jumpCompact: true, upNextCompact: false)
                    flowing(jumpCompact: true, upNextCompact: true)
                    // Last resort: only the most urgent of the two, compact.
                    if hasJump { JumpBackChip(compact: true) } else { UpNextChip(compact: true, onOpen: onOpenQueue) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isEmpty ? 0 : 14)
        .shelfAnimation(.easeInOut(duration: 0.2), value: [hasSleep, hasJump, hasUpNext])
        // Latch a retired Jump back (see `PlayerViewModel.retireStaleSeekUndo`).
        .onChange(of: playerViewModel.isSeekUndoStale) { _, stale in
            if stale { playerViewModel.retireStaleSeekUndo() }
        }
        // A Jump back appearing used to be silent to VoiceOver, so after an accidental ⏭
        // there was no way to know an undo existed (fourth run).
        .onChange(of: playerViewModel.seekUndoTime) { old, new in
            if old == nil, new != nil { AccessibilityNotification.Announcement(String(localized: "Jump back available", comment: "VoiceOver announcement when an undo-seek chip appears")).post() }
        }
    }

    private func flowing(jumpCompact: Bool, upNextCompact: Bool) -> some View {
        HStack(spacing: 10) {
            if hasJump { JumpBackChip(compact: jumpCompact) }
            if hasUpNext { UpNextChip(compact: upNextCompact, onOpen: onOpenQueue) }
        }
        .fixedSize()
    }
}

/// The Up Next status chip. Full: "Up Next · <title> (2) ›"; compact: "Up Next (2)".
private struct UpNextChip: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let compact: Bool
    let onOpen: () -> Void

    var body: some View {
        Button { onOpen() } label: {
            HStack(spacing: 10) {
                Typo.chip(Image(systemName: "text.line.first.and.arrowtriangle.forward"))
                    .foregroundStyle(Color.shelfMuted)
                Typo.chip(Text("Up Next"), weight: .semibold)
                    .foregroundStyle(Color.shelfCream.opacity(0.85))
                if !compact, let next = playerViewModel.upNext.first {
                    Typo.chip(Text("· \(next.title)"))
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(1)
                }
                Typo.chip(Text("(\(playerViewModel.upNext.count))"), weight: .medium)
                    .foregroundStyle(Color.shelfMuted)
                if !compact {
                    Image(systemName: "chevron.right")
                        .scaledFont(10, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(Color.shelfMuted)
                        // Decorative — the capsule is one button with its own label.
                        .accessibilityHidden(true)
                }
            }
            // P-6: 14 is a deliberate chip inset shared by every status chip.
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassPill(Capsule())
            // Critique 2026-10-05 (third run): ~31 pt tall with no hit-area floor.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Batch 403: "Up Next, 1 books" read wrong in English too.
        .accessibilityLabel(playerViewModel.upNext.count == 1
            ? String(localized: "Up Next, 1 item", comment: "VoiceOver label of the Up Next button with one entry queued (a book or a podcast episode)")
            : String(localized: "Up Next, \(playerViewModel.upNext.count) items", comment: "VoiceOver label of the Up Next button; %lld is the number of queued entries (books or podcast episodes)"))
    }
}

/// "Jump back to …" ↶ / "Go forward to …" ↷ — wording follows the direction the undo moves,
/// not what caused the jump (fourth run, user decision). Compact form is the arrow plus the
/// chapter-relative time.
private struct JumpBackChip: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let compact: Bool

    var body: some View {
        if let undo = playerViewModel.activeSeekUndoTime {
            let forward = PlayerViewModel.seekUndoGoesForward(undoTime: undo, currentTime: playerViewModel.currentTime)
            let full = PlayerView.jumpBackLabel(undoTime: undo,
                                                chapters: playerViewModel.chapters,
                                                currentChapterId: playerViewModel.currentChapter?.id,
                                                verb: forward ? String(localized: "Go forward to", comment: "Redo-chip verb before a time or chapter, e.g. 'Go forward to 12:44'")
                                                         : String(localized: "Jump back to", comment: "Undo-chip verb before a time or chapter, e.g. 'Jump back to 12:44'"))
            Button {
                playerViewModel.undoSeek()
            } label: {
                Typo.secondaryAction(
                    HStack(spacing: 6) {
                        Image(systemName: forward ? "arrow.uturn.forward" : "arrow.uturn.backward")
                        Text(compact ? PlayerView.jumpBackCompactLabel(undoTime: undo, chapters: playerViewModel.chapters) : full)
                            .lineLimit(1)
                    }
                )
                .foregroundStyle(Color.shelfAmberText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassPill(Capsule())
                // The seek-undo affordance gets a 44 pt hit area around the capsule.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale))
            // The compact form still speaks in full.
            .accessibilityLabel(full)
            .accessibilityHint(playerViewModel.seekUndoReason.accessibilityHint)
        }
    }
}
