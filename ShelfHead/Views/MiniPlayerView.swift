import SwiftUI

struct MiniPlayerView: View {
    /// D5 follow-up (design brief 2026-08-12): true when this is embedded in the
    /// iOS 26 `.tabViewBottomAccessory` (`ContentView`'s `modernTabs`) instead of
    /// the legacy path's floating `safeAreaInset` bar. User feedback on the real
    /// device: the bar looked "too small and cutoff" and "like a window inside a
    /// window." Root cause — `.tabViewBottomAccessory` already renders its own
    /// system Liquid Glass container at a fixed, compact height; this view's own
    /// `.glassPill` card (a SECOND, independently-clipped `.glassEffect` shape)
    /// plus its outer `.padding(.horizontal, 16)/.padding(.bottom, 8)` margin were
    /// both designed for the legacy bar floating freely over page content, not for
    /// living inside a container that already supplies its own glass chrome and
    /// insets — layered together, that's the "double window" look, and the
    /// legacy design's 44pt tap targets + vertical padding made the content taller
    /// than the system's fixed accessory slot, clipping it. When true, this skips
    /// the extra `.glassPill` card and outer margin entirely so the system's own
    /// container is the only chrome, and trims padding to fit its shorter height.
    var embeddedInSystemAccessory: Bool = false
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var bounceOffset: CGFloat = 60
    // Interactive swipe state — up expands to the full player (mirrors tapping the pill).
    // Critique 2026-10-06 (harden, user decision): swipe-down-to-stop is gone. A 60 pt
    // flick on a high-priority gesture ended the session with only a 6 s toast to undo it,
    // easy to hit one-handed. Stop now lives in the long-press menu (and stays a VoiceOver
    // action); a downward drag only rubber-bands and snaps back.
    @State private var dragOffset: CGFloat = 0
    // Code review fix (26 August 2026): this view read `skipBackwardInterval`/
    // `skipForwardInterval` as plain `UserDefaults` reads inside `body` — invisible to
    // SwiftUI's dependency tracking, so changing the interval in Settings didn't
    // invalidate this view. Worse here than in `DrivingModeView`: this bar stays
    // mounted continuously across tab switches, and the thing that usually re-renders
    // it (`playerViewModel.progress`) stops ticking while paused — exactly when
    // someone is likely to go change the interval in Settings.
    @AppStorage(SettingsKeys.skipBackwardInterval) private var skipBackwardInterval: Double = 15
    @AppStorage(SettingsKeys.skipForwardInterval) private var skipForwardInterval: Double = 30
    // Design-direction pass (17 Aug 2026): these were a local `@ScaledMetric`
    // spelling of "book title in a row" / "the line under it" — the exact two roles
    // `DesignTokens.swift`'s `Typo.rowTitle`/`Typo.rowSubtitle` already exist to name
    // (this file's title size, 14pt/subheadline, is an *exact* match; the subtitle
    // was 11pt/caption, a near-miss of `rowSubtitle`'s 12pt/caption now unified to
    // match). Removed in favor of those tokens below.

    // VD-7 (docs/design-review.md, Round 4): the play/pause glyph sits in the same
    // row as the title/subtitle column (`Typo.rowTitle`/`MiniPlayerSubtitleLine`,
    // both Dynamic-Type-aware, capped at `.xxLarge` just below) and fell further
    // out of proportion with them as text size grew. This bar's own hit target
    // (44×44) and background circle (32×32) are deliberately fixed — growing them
    // would break the compact bar — so the glyph is capped at 1.3× base, leaving
    // comfortable margin inside the 32pt circle rather than crowding it.
    @ScaledMetric(relativeTo: .subheadline) private var playPauseIconSizeMetric: CGFloat = 15
    private var playPauseIconSize: CGFloat { min(playPauseIconSizeMetric, 15 * 1.3) }

    /// Critique 2026-10-05 (Mini player, 2nd): layout constants the progress-line insets derive from.
    private enum Metrics {
        static let coverSize: CGFloat = 38
        static let coverGap: CGFloat = 12
        static let playHitSize: CGFloat = 44
        static let playGap: CGFloat = 12
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Rubber-band while dragging; only a completed upward swipe past the
                // threshold expands. Downward travel is damped harder, since it no longer
                // does anything (Critique 2026-10-06, harden).
                let dy = value.translation.height
                dragOffset = dy < 0 ? dy * 0.5 : dy * 0.15
            }
            .onEnded { value in
                // LS-2 (docs/design-review.md): while a start is in flight there's no
                // live session to expand into — snap back instead of opening an
                // empty full player.
                guard playerViewModel.pendingBook == nil else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                    return
                }
                let dy = value.translation.height
                let vy = value.velocity.height
                if dy < -40 || vy < -500 {
                    Haptics.impact(.light)
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.85)) {
                        dragOffset = 0
                        playerViewModel.showFullPlayer = true
                    }
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    var body: some View {
        // LS-2 (docs/design-review.md): mounts on `displayedBook`, not `currentBook` —
        // the pending book (a start in flight) shows the mini player with its own
        // cover/title immediately, before the session round trip returns.
        if playerViewModel.hasMiniPlayer {
            Button {
                // Expand into the full player (presented as an overlay by ContentView).
                // Design review 2026-09-23 AN-2: the local `withAnimation` wrapper here
                // only ever animated this one flip with the identical spring curve the
                // host now applies via `.shelfAnimation(value: showFullPlayer)` in
                // `ContentView` — removed as redundant. (The other call site just below,
                // in `swipeGesture`, also animates `dragOffset` in the same transaction
                // and is kept.)
                // LS-2: no live session exists yet while a start is in flight — opening
                // the full player here would show it empty/stale, so ignore the tap.
                guard playerViewModel.pendingBook == nil else { return }
                playerViewModel.showFullPlayer = true
            } label: {
                miniPlayerContent
            }
            .buttonStyle(.plain)
            // Critique 2026-10-05 (Mini player): composite label. The per-second values
            // (chapter countdown, sleep minutes) are deliberately left out so VoiceOver
            // isn't re-announcing a changing label; the visible line carries them.
            // DEVICE CHECK: the play/pause Button is nested inside this Button; confirm
            // VoiceOver still exposes it as its own element.
            .accessibilityLabel(MiniPlayerStatus.accessibilityLabel(
                title: playerViewModel.displayedBook?.title ?? "",
                isPlaying: playerViewModel.isPlaying,
                isStalled: playerViewModel.transportStalled,
                isStreaming: playerViewModel.isStreamingCurrentBook,
                sleepArmed: playerViewModel.isSleepTimerActive,
                author: playerViewModel.displayedBook?.authorName ?? "",
                // Critique 2026-10-05 (Mini player, 2nd): "loading" while a start/buffer is
                // in flight; "You're offline" when the device itself has no network.
                isLoading: playerViewModel.isTransportWaiting,
                // Critique 2026-10-06 (harden): the debounced status the banner and Driving
                // Mode show, so one failed ping doesn't flip this label.
                reachability: DisplayedReachability.shared.status))
            .accessibilityHint("Opens the player")
            // Critique 2026-10-05 (Mini player): the text column is capped at xxLarge, so
            // offer the Large Content Viewer (SwiftUI, iOS 15.0) for AX sizes.
            .accessibilityShowsLargeContentViewer {
                Label(playerViewModel.displayedBook?.title ?? "",
                      systemImage: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .highPriorityGesture(swipeGesture)
            // Critique 2026-10-06 (harden, user decision): Stop moved off the swipe into the
            // long-press menu (SwiftUI `contextMenu(menuItems:)`, iOS 13.0). Its own view so
            // the menu's reads don't widen this bar's invalidation.
            .contextMenu { MiniPlayerMenuItems(player: playerViewModel) }
            // Swipe up isn't discoverable (or performable) via VoiceOver — the
            // tap-to-expand action is already exposed by the Button itself, so only the
            // stop action needs an explicit custom action here.
            // Critique 2026-10-05 (Mini player, 2nd): the nested play/pause Button can be
            // swallowed by this element in VoiceOver, so offer the same toggle as an action
            // here too. DEVICE CHECK: confirm it shows in the actions rotor.
            .accessibilityAction(named: playerViewModel.isPlaying ? "Pause" : "Resume") {
                Haptics.impact(.light)
                playerViewModel.togglePlayPause()
            }
            .accessibilityAction(named: "Stop Playback") {
                // LS-2: same guard as the long-press menu's Stop — no session to stop yet
                // while a start is in flight.
                guard playerViewModel.pendingBook == nil else { return }
                playerViewModel.stopWithUndo()
            }
            // SB-2b (REVIEW_2026-09-14_DESIGN.md): the bar's two visible skip
            // buttons are gone (see `coreContent`) so the row can give their
            // width back to the title/subtitle text, which was truncating to
            // "The Primal H…" on a 393pt phone. Skip back/forward are still one
            // reachable action away for VoiceOver users — as custom actions on
            // this same element, right alongside "Stop Playback" — even though
            // there's no longer a visible glyph for them; sighted users reach
            // them via the full player (swipe/tap up) or the lock screen.
            .accessibilityAction(named: SkipLabels.accessibilityLabel(backward: true, seconds: skipBackwardInterval)) {
                Haptics.impact(.light)
                playerViewModel.skipBackward()
            }
            .accessibilityAction(named: SkipLabels.accessibilityLabel(backward: false, seconds: skipForwardInterval)) {
                Haptics.impact(.light)
                playerViewModel.skipForward()
            }
            // The entrance bounce + drag rubber-banding both animate this view's own
            // y-offset, which only makes sense for the legacy path's freely-floating
            // bar. The system accessory clips its content to a fixed slot, so
            // offsetting it there just risks the bar visibly sliding out of/into that
            // clipped bounds rather than reading as a bounce — skip the offset (but
            // keep `swipeGesture`'s actual expand action) when embedded.
            .offset(y: embeddedInSystemAccessory ? 0 : bounceOffset + dragOffset)
            // Hide the mini-player while the full player is up so it doesn't peek.
            .opacity(playerViewModel.showFullPlayer ? 0 : 1)
            .onAppear {
                if !appeared {
                    appeared = true
                    // Skip the entrance bounce under Reduce Motion.
                    if reduceMotion {
                        bounceOffset = 0
                    } else {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0)) {
                            bounceOffset = 0
                        }
                    }
                }
            }
            // LS-2: keyed on `displayedBook`, not `currentBook` — so the bounce fires the
            // moment the bar's cover/title actually change (when a start begins), not
            // only once the session round trip lands. `displayedBook` doesn't change
            // again when `pendingBook` clears and `currentBook` catches up to the same
            // id, so this doesn't double-bounce.
            .onChange(of: playerViewModel.displayedBook?.id) { _, _ in
                // Bounce when a new book starts (unless Reduce Motion is on).
                if reduceMotion { bounceOffset = 0; return }
                bounceOffset = 30
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                    bounceOffset = 0
                }
            }
        }
    }

    // MARK: - Foreground colours

    /// The system renders `.tabViewBottomAccessory` content in a **vibrancy context**: an
    /// explicit palette colour gets blended into the glass rather than drawn opaquely. On
    /// device that made the title render as pale cream on near-white glass (barely
    /// legible), while the subtitle happened to survive. Semantic styles are the ones the
    /// system actually adapts for that context, but title/subtitle deliberately keep the
    /// app palette in BOTH hosting contexts instead — switching them to
    /// `.primary`/`.secondary` inside the accessory was tried and is wrong: it rendered
    /// white-on-near-white in Light appearance. `shelfCream` is already adaptive
    /// (`2A211A` light / `F4E9D6` dark) and is the correct token here.
    ///
    /// SB-2b removed the two skip buttons that used to need a third, quieter colour
    /// (`controlColor`) shared between them; the remaining play/pause button is styled
    /// on its own (`Color.onAccent` on a `Color.shelfAmber` circle) rather than through
    /// this pair, since it was never blended through the vibrancy problem above.
    ///
    /// CO-2 (docs/visual-design-review.md, Round V2) revisits that for the embedded case.
    /// The white-on-near-white failure came from the accessory resolving against a DARK
    /// trait collection, which `ContentView` now fixes by forcing `\.colorScheme` on the
    /// accessory. With that in place, `.primary` / `.secondary` let the system apply glass
    /// vibrancy, so the second line stays legible at iOS 27's Clear glass setting, where a
    /// fixed mid-tone like `shelfMuted` ends up the same luminance as whatever scrolls
    /// behind it. The floating legacy card (iOS 17–25) keeps the app palette.
    private var titleStyle: AnyShapeStyle {
        embeddedInSystemAccessory ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.shelfCream)
    }
    private var subtitleStyle: AnyShapeStyle {
        embeddedInSystemAccessory ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.shelfMuted)
    }

    /// D5 follow-up: only the core content is shared between the two hosting
    /// contexts now — the outer chrome (glass card vs. none, and how much padding
    /// surrounds it) differs enough between them that splitting it out here reads
    /// more clearly than threading conditionals through every padding call below.
    @ViewBuilder
    private var miniPlayerContent: some View {
        if embeddedInSystemAccessory {
            // D5 follow-up, round 3: round 2's flat `Color.shelfCard` fill was an
            // opaque, app-themed card sitting on top of the tab row's own native
            // translucent Liquid Glass material below it — two visually different
            // materials stacked, which read as "doesn't match the tab buttons."
            // Reverted to no background/shape of our own at all: the system's
            // `.tabViewBottomAccessory` container supplies its own native
            // material, and letting our content sit directly on it (rather than
            // painting a second, different-looking surface over part of it) is
            // what actually makes it look like one continuous native bar instead
            // of a patchwork of materials. Just enough padding to keep the 44pt
            // buttons clear of the accessory's own edges.
            coreContent
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        } else {
            coreContent
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // This `else` branch (no `embeddedInSystemAccessory`) is only ever
                // constructed by `ContentView.bottomBar`, which is only reachable from
                // `legacyTabs` — i.e. iOS 17–25. So although `glassPill` still has a real
                // iOS 26 branch (matching the tab pill below it), that branch can never
                // execute here in the shipping app: the one iOS 26 caller of this view
                // always passes `embeddedInSystemAccessory: true` and takes the `if`
                // branch above instead, which skips `glassPill` entirely in favor of the
                // system's own `.tabViewBottomAccessory` chrome (D5 / Batch 163). Kept for
                // previews and in case this branch is ever reused. On iOS 17–25, where this
                // branch actually renders, the `.ultraThinMaterial` fallback is the only
                // path it ever takes.
                // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 22pt radius → `Radius.pill`.
                .glassPill(RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
                // Make the WHOLE pill tappable, not just the opaque bits —
                // otherwise the gap between the title and the button (the
                // `Spacer`) doesn't expand the player. The nested play/pause
                // button still captures its own tap.
                .contentShape(RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    private var coreContent: some View {
        VStack(spacing: 0) {
            // Progress line (now an overlay on the row below) — thin and quiet so it reads as playback position,
            // not a global loading bar.
            //
            // Item 10 (REVIEW-2026-09-09.md): its own view. This bar stays mounted
            // continuously (it is only `.opacity(0)`'d while the full player is up — see
            // `body`), so reading `progress` here inside `coreContent`, which is inlined
            // into `body`, rebuilt the entire mini-player — cover, reel overlay, title,
            // the transport button — twice a second, including while it was invisible
            // behind the full player. A 2pt line is now the only thing that does.
            // SB-2b (REVIEW_2026-09-14_DESIGN.md): this bar previously carried three
            // 44pt transport buttons (skip back / play-pause / skip forward) beside the
            // title column, which is what made "The Primal Hunter 13" truncate to "The
            // Primal H…" even after Pass 3 item 2 tightened the stack's own spacing —
            // three 44pt frames plus their gaps left only ~148pt for text on a 393pt
            // phone. The reviewer's direction: the mini-player is identity + a single
            // resume/pause affordance, not a second transport bar — skip belongs on the
            // full player (already has it) and the lock screen (already has it via
            // `SharedPlayback`/`PlaybackIntents`). Removing the two skip buttons hands
            // their ~88pt + gaps straight to the title/subtitle column below. Skip
            // back/forward stay reachable for VoiceOver users as custom actions on the
            // outer expand-button (see `body`) even with no visible glyph here.
            HStack(spacing: 0) {
                // Cover with a little spinning reel overlay for the tape-deck feel.
                // LS-2: `displayedBook`, not `currentBook` — while a start is in flight
                // this is the tapped book, so its cover shows immediately rather than
                // whatever was playing before (or nothing, if this is the first play).
                if let book = playerViewModel.displayedBook {
                    ZStack(alignment: .bottomTrailing) {
                        CoverImageView(itemId: book.id, width: Metrics.coverSize, height: Metrics.coverSize)
                        // UI-12 (perf): `CassetteReel` already pauses its own
                        // `TimelineView` whenever `spinning` is false (see its doc
                        // comment) — but this mini-player instance previously spun
                        // whenever `isPlaying` was true regardless of whether the mini
                        // player itself was actually visible. While the full player is
                        // up, this view is only `.opacity(0)`'d (not removed — its
                        // layout slot has to keep reserving space for the tab bar's
                        // `safeAreaInset` measurement below), so a hidden 30fps
                        // `TimelineView` kept ticking here on top of the two legitimate,
                        // visible ones inside the full player's own `CassetteView` —
                        // three concurrent 30fps timers for one visible reel pair.
                        // Folding visibility into `spinning` stops it without touching
                        // that layout contract.
                        // Critique 2026-10-05 (Mini player): DESIGN.md puts tape hardware only
                        // where audio moves, so the reel is absent while paused.
                        // Critique 2026-10-05 (Mini player, 2nd): fades in/out rather than
                        // popping (Reduce Motion: instant, via `shelfAnimation`). Kept
                        // mounted but only spins while visible and playing.
                        CassetteReel(spinning: playerViewModel.isPlaying && !playerViewModel.showFullPlayer, size: 14)
                            .padding(2)
                            .opacity(playerViewModel.isPlaying ? 1 : 0)
                            .shelfAnimation(.easeInOut(duration: 0.25), value: playerViewModel.isPlaying)
                    }
                    // Pass 3 item 2: the stack's own spacing is 0 now, so the one gap
                    // that still has to read as a gap is spelled out here. Carried by
                    // the cover rather than the title column so it disappears with the
                    // cover instead of leaving a stray leading inset behind it.
                    .padding(.trailing, Metrics.coverGap)
                }

                // Title & chapter/author
                VStack(alignment: .leading, spacing: 2) {
                    // LS-2: `displayedBook` — the pending book's title while a start is
                    // in flight, matching the cover above.
                    Typo.rowTitle(Text(playerViewModel.displayedBook?.title ?? ""))
                        .foregroundStyle(titleStyle)
                        .lineLimit(1)

                    // Item 10 (REVIEW-2026-09-09.md): the second line is its own view
                    // for the same reason the progress bar above is — both the chapter
                    // countdown and the "is there a chapter at all" test read playback
                    // position, and inlined here they made the title, the cover and the
                    // transport buttons beside them tick-frequency dependencies too.
                    MiniPlayerSubtitleLine(style: subtitleStyle)
                }
                // Keep the mini-player compact even at large text sizes.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)

                // The text column no longer has to compete with two skip buttons for
                // width, so a plain flexible spacer (rather than the old fixed 12pt
                // floor between two adjacent 44pt frames) is enough breathing room
                // before the one remaining control.
                Spacer(minLength: Metrics.playGap)

                // Play/Pause — the single transport affordance SB-2b leaves on this
                // bar. Skip back/forward live on the full player and the lock screen;
                // see the `HStack`'s header comment and the VoiceOver custom actions
                // in `body`.
                Button {
                    Haptics.impact(.light)
                    playerViewModel.togglePlayPause()
                } label: {
                    // iOS 26/27 Liquid Glass polish pass (26 August 2026): same
                    // `.symbolEffect(.replace)` treatment as the full player's
                    // transport button, gated through `shelfAnimation` for Reduce
                    // Motion.
                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: playPauseIconSize, weight: .semibold))
                        .foregroundStyle(Color.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                        .shelfAnimation(.easeOut(duration: 0.2), value: playerViewModel.isPlaying)
                        .frame(width: 32, height: 32)
                        .background(Color.shelfAmber)
                        .clipShape(Circle())
                        // LS-1 (docs/design-review.md): ring sits just outside the
                        // 32pt circle (40pt diameter) but still inside the 44pt hit
                        // frame below, so buffering shows without shrinking the tap
                        // target. `isBuffering` changes rarely, so reading it here
                        // (rather than splitting it into its own subview, like the
                        // tick-frequency reads below) doesn't reintroduce the
                        // invalidation problem Item 10 split those out to avoid.
                        .bufferingRing(isActive: playerViewModel.isTransportWaiting, diameter: 40, lineWidth: 2.2)
                        .frame(width: Metrics.playHitSize, height: Metrics.playHitSize)   // ≥44pt hit target
                        .contentShape(Rectangle())
                }
                // Critique 2026-10-05 (Mini player): "Resume" for a paused current book,
                // matching Home's hero button.
                .accessibilityLabel(playerViewModel.isPlaying ? "Pause" : "Resume")
                .accessibilityValue(playerViewModel.isTransportWaiting ? "Loading" : "")
            }
            // Critique 2026-10-05 (Mini player): the progress line sits under the text
            // column (past the 38pt cover + 12pt gap, short of the 44pt play button + 12pt
            // spacer) instead of running edge to edge under the capsule's rounded corners.
            .overlay(alignment: .bottom) {
                MiniPlayerProgressLine()
                    // Critique 2026-10-05 (Mini player, 2nd): derived from the cover and
                    // play-button sizes rather than hard-coded 50 / 56.
                    .padding(.leading, Metrics.coverSize + Metrics.coverGap)
                    .padding(.trailing, Metrics.playHitSize + Metrics.playGap)
            }
        }
    }
}

/// The mini-player's 2pt playback-position line.
///
/// Item 10 (REVIEW-2026-09-09.md): the whole reason this is a separate view is
/// invalidation scope — `progress` changes about twice a second for as long as something
/// is playing, and this is the only part of the bar that has to redraw when it does. See
/// the call site in `coreContent` for the full note. Visually identical: same two
/// rectangles, same fills, same `linear(0.5)` animation, same 2pt height.
private struct MiniPlayerProgressLine: View {
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        // Critique 2026-10-05 (Mini player): chapter progress when chapters exist (matches
        // the "left in chapter" text), whole book otherwise; track at 0.15 so it reads.
        let fraction = MiniPlayerStatus.progressFraction(
            hasChapter: playerViewModel.currentChapter != nil,
            chapterElapsed: playerViewModel.chapterElapsed,
            chapterLength: playerViewModel.chapterLength,
            bookProgress: playerViewModel.progress)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.shelfCream.opacity(0.15))
                // LS-2: while a start is in flight, `progress` is still the *previous*
                // book's position (there's no session for the pending book yet) — hide
                // the amber fill rather than show a stale progress bar under the new
                // cover/title above it.
                if playerViewModel.pendingBook == nil {
                    Capsule()
                        .fill(Color.shelfAmber.opacity(0.85))
                        .frame(width: geometry.size.width * fraction)
                        .shelfAnimation(.linear(duration: 0.5), value: fraction)
                }
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// The line under the mini-player's title: time left in the current chapter when the book
/// has chapters, the author's name when it doesn't.
///
/// Item 10 (REVIEW-2026-09-09.md): extracted so the per-second countdown invalidates one
/// `Text` rather than the whole bar. `style` is passed in because which style this is
/// depends on the hosting context, which only `MiniPlayerView` knows (see its
/// `subtitleStyle`). Content, fonts, `ViewThatFits` order and `lineLimit` are unchanged.
private struct MiniPlayerSubtitleLine: View {
    let style: AnyShapeStyle

    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        if let pending = playerViewModel.pendingBook {
            // LS-2: while a start is in flight, `currentChapter` (if a chapter list is
            // even still around) belongs to the *previous* book's live session — showing
            // its countdown here under the pending book's cover/title would misrepresent
            // it as still playing. The pending book's author (`authorName` already falls
            // back to "Unknown Author") is short, VoiceOver-friendly orientation instead.
            Typo.rowSubtitle(Text(pending.authorName))
                .foregroundStyle(style)
                .lineLimit(1)
        } else {
            // Critique 2026-10-05 (Mini player): status vocabulary — stall, then sleep
            // timer, then the chapter countdown / author. Only this small view reads the
            // ticking values (Item 13 isolation).
            let hasChapter = playerViewModel.currentChapter != nil
            let remaining = max(0, playerViewModel.chapterLength - playerViewModel.chapterElapsed)
            let line = MiniPlayerStatus.line(
                isStalled: playerViewModel.transportStalled,
                isStreaming: playerViewModel.isStreamingCurrentBook,
                sleepOption: playerViewModel.sleepTimerOption,
                sleepRemaining: playerViewModel.sleepTimerRemaining,
                chapterRemaining: hasChapter ? remaining : nil,
                author: playerViewModel.currentBook?.authorName ?? "",
                // Critique 2026-10-06 (harden): debounced, matching the banner.
                reachability: DisplayedReachability.shared.status,
                playbackRate: Double(playerViewModel.playbackRate))
            // G4 (REVIEW_2026-09-04_UI.md): time left in the chapter rather than a
            // truncating chapter title; `ViewThatFits` drops to the short form instead of
            // truncating, and monospaced digits stop the line jittering each second.
            // Critique 2026-10-05 (Mini player, 2nd): the stalled/offline state keeps the normal
            // subtitle style (orange text failed AA in Light) and carries its warning in a
            // small orange glyph, which is a fill, not text.
            let stalled = line.kind == .stalled
            ViewThatFits(in: .horizontal) {
                statusRow(line.full, stalled: stalled)
                statusRow(line.short, stalled: stalled)
            }
            .monospacedDigit()
            .foregroundStyle(style)
            .lineLimit(1)
        }
    }
}

private extension MiniPlayerSubtitleLine {
    @ViewBuilder
    func statusRow(_ text: String, stalled: Bool) -> some View {
        if stalled {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.shelfOrange)
                    .accessibilityHidden(true)
                Typo.rowSubtitle(Text(text))
            }
        } else {
            Typo.rowSubtitle(Text(text))
        }
    }
}

/// Critique 2026-10-06 (harden, user decision): the mini player's long-press menu, where Stop
/// lives now that swipe-down no longer stops playback. Stop goes through `stopWithUndo()`, so
/// the "Stopped … Undo" toast still follows. Its own view so reading the player here doesn't
/// widen `MiniPlayerView.body`'s dependencies; it reads only values that change rarely (no
/// per-second countdown — the bar's own second line carries that).
private struct MiniPlayerMenuItems: View {
    let player: PlayerViewModel

    var body: some View {
        // LS-2: nothing to open or stop while a start is in flight.
        let pending = player.pendingBook != nil
        let sleep = MiniPlayerStatus.menuSleepStatus(option: player.sleepTimerOption)
        if let sleep {
            // The section title shows the armed timer above the actions.
            Section(sleep) { primaryItems(pending: pending) }
        } else {
            primaryItems(pending: pending)
        }
        Divider()
        Button(role: .destructive) {
            guard player.pendingBook == nil else { return }
            Haptics.impact(.light)
            player.stopWithUndo()
        } label: {
            Label(MiniPlayerStatus.stopMenuTitle, systemImage: "stop.fill")
        }
        .disabled(pending)
    }

    @ViewBuilder
    private func primaryItems(pending: Bool) -> some View {
        Button {
            player.showFullPlayer = true
        } label: {
            Label("Open Player", systemImage: "chevron.up")
        }
        .disabled(pending)
        Button {
            Haptics.impact(.light)
            player.togglePlayPause()
        } label: {
            Label(player.isPlaying ? "Pause" : "Resume",
                  systemImage: player.isPlaying ? "pause.fill" : "play.fill")
        }
    }
}

/// Pure decisions for the mini player's second line, progress line and VoiceOver label
/// (critique 2026-10-05, Mini player), pinned by `MiniPlayerStateTests`.
enum MiniPlayerStatus {
    enum Kind: Equatable { case stalled, sleep, chapter, author }
    struct Line: Equatable {
        let kind: Kind
        let full: String
        let short: String
    }

    /// The one sleep-timer status line, shared by this bar and the full player's
    /// `SleepStatusChip` (PlayerView+BottomRegion.swift); nil when off.
    ///
    /// Critique 2026-10-06 (clarify): the two used to disagree for end-of-chapter ("Sleeps in
    /// 12:03" here, "Sleeps at end of chapter" on the chip), and this one counted media time,
    /// so at 1.5× it said 18 minutes for a 12-minute wait. `chapterRemaining` is media
    /// seconds; it is divided by `rate` so the countdown is wall-clock, like the minutes timer.
    static func sleepText(option: SleepTimerOption, remaining: TimeInterval,
                          chapterRemaining: TimeInterval? = nil, rate: Double = 1) -> String? {
        switch option {
        case .off: return nil
        case .endOfChapter:
            if let rem = chapterRemaining, rem > 0 {
                return countdown(rem / max(rate, 0.1))
            }
            return String(localized: "Sleeps at end of chapter", comment: "Mini player / sleep chip status when the timer ends at the chapter end")
        case .chapters(let n):
            return n == 1 ? String(localized: "Sleeps after 1 more chapter", comment: "Sleep timer status: one more chapter")
                          : String(localized: "Sleeps after \(n) more chapters", comment: "Sleep timer status. %lld is the number of chapters (not 1)")
        case .endOfBook: return String(localized: "Sleeps at end of book", comment: "Sleep timer status when the timer ends at the end of the book")
        case .minutes:
            if remaining > 0 { return countdown(remaining) }
            return String(localized: "Sleep timer on", comment: "Sleep timer status when a timer is armed but has no countdown to show")
        }
    }

    /// Critique 2026-10-06 (harden): the long-press menu's Stop, matching the VoiceOver action.
    static var stopMenuTitle: String { String(localized: "Stop Playback", comment: "Mini player long-press menu action that stops playback") }

    /// The armed timer for the long-press menu's section title, without a per-second figure
    /// (a menu is a snapshot, and reading the countdown would re-render the bar every tick).
    static func menuSleepStatus(option: SleepTimerOption) -> String? {
        sleepText(option: option, remaining: 0)
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        return String(localized: "Sleeps in \(clock)", comment: "Sleep timer countdown. %@ is the time left, e.g. 14:25")
    }

    /// Priority: stalled while streaming, then an armed sleep timer, then the chapter
    /// countdown (when the book has chapters), then the author.
    static func line(isStalled: Bool, isStreaming: Bool, sleepOption: SleepTimerOption,
                     sleepRemaining: TimeInterval, chapterRemaining: TimeInterval?,
                     author: String, reachability: ReachabilityStore.Status = .ok,
                     playbackRate: Double = 1) -> Line {
        if isStalled && isStreaming {
            // Critique 2026-10-05 (Mini player, 2nd): the device being offline is not the
            // server's fault.
            if reachability == .offline {
                return Line(kind: .stalled, full: String(localized: "You're offline", comment: "Mini player status when the device has no network"),
                            short: String(localized: "You're offline", comment: "Mini player status when the device has no network"))
            }
            return Line(kind: .stalled, full: String(localized: "Waiting for your server", comment: "Mini player status when a stream has stalled"),
                        short: String(localized: "Waiting for server", comment: "Mini player status when a stream has stalled (short form)"))
        }
        if let sleep = sleepText(option: sleepOption, remaining: sleepRemaining,
                                 chapterRemaining: chapterRemaining, rate: playbackRate) {
            return Line(kind: .sleep, full: sleep, short: sleep)
        }
        if let rem = chapterRemaining {
            return Line(kind: .chapter, full: String(localized: "\(rem.formattedTime) left in chapter", comment: "Mini player line. %@ is the time left in the chapter, e.g. 12:44"),
                        short: String(localized: "\(rem.formattedTime) left", comment: "Mini player line (short form). %@ is the time left in the chapter"))
        }
        return Line(kind: .author, full: author, short: author)
    }

    /// Chapter progress when chapters exist, whole-book otherwise; clamped to 0...1.
    static func progressFraction(hasChapter: Bool, chapterElapsed: Double, chapterLength: Double,
                                 bookProgress: Double) -> Double {
        let raw = hasChapter ? (chapterLength > 0 ? chapterElapsed / chapterLength : 0) : bookProgress
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// "<title>, playing|paused, <second line>" without per-second values.
    static func accessibilityLabel(title: String, isPlaying: Bool, isStalled: Bool,
                                   isStreaming: Bool, sleepArmed: Bool, author: String,
                                   isLoading: Bool = false,
                                   reachability: ReachabilityStore.Status = .ok) -> String {
        let second: String
        if isStalled && isStreaming { second = reachability == .offline ? String(localized: "You're offline", comment: "Mini player status when the device has no network") : String(localized: "Waiting for your server", comment: "Mini player status when a stream has stalled") }
        else if sleepArmed { second = String(localized: "Sleep timer on", comment: "Sleep timer status when a timer is armed") }
        else { second = author }
        return [title,
                isPlaying ? String(localized: "playing", comment: "VoiceOver: mini player state, lowercase, follows the book title") : String(localized: "paused", comment: "VoiceOver: mini player state, lowercase, follows the book title"),
                isLoading ? String(localized: "loading", comment: "VoiceOver: mini player buffering state, lowercase") : "",
                second]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

#Preview {
    VStack {
        Spacer()
        MiniPlayerView()
    }
    .background(Color.shelfBackground)
    .environment(PlayerViewModel())
}

// Critique 2026-10-05 (Mini player): the `.tabViewBottomAccessory` variant.
#Preview("Embedded in system accessory") {
    VStack {
        Spacer()
        MiniPlayerView(embeddedInSystemAccessory: true)
    }
    .background(Color.shelfBackground)
    .environment(PlayerViewModel())
}
