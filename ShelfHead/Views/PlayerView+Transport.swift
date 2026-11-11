import SwiftUI

/// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
/// everything below is verbatim what lived on `PlayerView` itself.
///
/// This file is the transport row — the two chapter buttons, the two skip buttons and the
/// amber play/pause circle — in both of its homes (inline in the column below the
/// accessibility threshold, pinned above the home indicator at or above it), plus the two
/// pure metrics that keep it fitting the narrowest phone this app supports at AX5.
/// `cappedTransportMetric` and `transportRowSpacing` are called directly by
/// `PlayerAccessibilityLayoutTests`, so their names and signatures are load-bearing.
extension PlayerView {
    /// H3 (REVIEW_2026-09-04_UI.md Pass 3): caps a transport-row `@ScaledMetric` at 1.4×
    /// its own base — the room `transportRowSpacing` below establishes this row actually
    /// has before five controls stop fitting the narrowest phone this app supports at AX5.
    /// Uncapped scaling here would make H1/H5's "the artwork is squeezed to a thumbnail"
    /// problem worse in reverse (the transport row swallowing the screen instead), which is
    /// exactly what the review flagged as the reason a cap is load-bearing, not optional.
    /// `@ScaledMetric` never returns less than `base` at `.large` or below (`.large` is
    /// Dynamic Type's own floor), so `min(scaled, base * 1.4)` is exactly `base` there —
    /// the screen's current literal, unchanged by construction — which is what pins this
    /// with a test rather than a screenshot.
    static func cappedTransportMetric(_ scaled: CGFloat, base: CGFloat) -> CGFloat {
        min(scaled, base * 1.4)
    }

    /// H3: the transport row's inter-control spacing, pure so the AX5 fit claim is pinned
    /// by a test instead of eyeballed off a screenshot. `columnWidth` is this file's
    /// existing "screen width less the column's 2×24pt side padding" convention (see
    /// `toolbarLabelPointSize`'s comment above — 375 - 48 = 327 on the narrowest phone this
    /// app targets). The four chapter/skip buttons keep their fixed 46×46 frames (H3 only
    /// grows the glyphs inside them, not those frames); `playCircleDiameter` — the one
    /// literal that IS growing — is the only other row dimension that varies. Base spacing
    /// (18, the current literal) holds as long as the row's natural width at that spacing
    /// still fits; below that this closes the gap to whatever room is actually left,
    /// flooring to a whole point (a small safety margin against rounding, and because a
    /// fractional point spacing value has no visual meaning) and never below 8pt, so five
    /// controls stay legible as a row instead of merging into a smear. At `.large`,
    /// `playCircleDiameter` is exactly 64 and every phone this app supports is well over
    /// the ~320pt that needs, so this always returns the base 18 there — unchanged by
    /// construction.
    static func transportRowSpacing(columnWidth: CGFloat, playCircleDiameter: CGFloat) -> CGFloat {
        let fixedFramesWidth: CGFloat = 4 * 46
        let baseSpacing: CGFloat = 18
        let neededAtBaseSpacing = fixedFramesWidth + playCircleDiameter + 4 * baseSpacing
        guard neededAtBaseSpacing > columnWidth else { return baseSpacing }
        let remaining = columnWidth - fixedFramesWidth - playCircleDiameter
        return max(8, (remaining / 4).rounded(.down))
    }

    // MARK: - Controls

    // H3 (REVIEW_2026-09-04_UI.md Pass 3): takes `geometry` (the same `GeometryProxy`
    // `artworkSlot(in:)` already receives from `body`) so `transportRowSpacing` can
    // compute the row's actual available width instead of guessing it — the same
    // "screen width less the column's 2×24pt side padding, capped at the 600pt iPad
    // width" the column itself uses (see `body`'s `.frame(maxWidth: 600)`).
    func controlsView(in geometry: GeometryProxy) -> some View {
        controlsView(columnWidth: min(geometry.size.width, 600) - 48)
    }

    /// iPhone Duo (§4): the same row sized to an explicit column, for the folded player's
    /// controls pane (`foldedPlayerLayout`), which is narrower than the screen. The flat
    /// layout still calls `controlsView(in:)` above, which passes exactly the width it
    /// always computed, so its row is unchanged.
    func controlsView(columnWidth: CGFloat) -> some View {
        let spacing = Self.transportRowSpacing(columnWidth: columnWidth, playCircleDiameter: transportPlayCircleSize)
        return HStack(alignment: .center, spacing: spacing) {
            transportButton("backward.end.fill", label: "Previous chapter", size: transportChapterGlyphSize,
                            role: .chapter, enabled: playerViewModel.hasChapterList) {
                DeckCue.shared.wind(-1)
                playerViewModel.previousChapter()
            }

            // P3-6 (third-pass review, 14 Aug 2026): this used to hardcode "gobackward.15"/
            // "Skip back 15 seconds" regardless of `skipBackwardInterval` —
            // the exact bug already fixed on the Watch app and in the widget, missed here
            // on the highest-traffic of the three surfaces. Now shares `SkipLabels`
            // (`Shared/SkipLabels.swift`) with both.
            transportButton(SkipLabels.symbolName(backward: true, seconds: skipBackwardInterval),
                             label: .verbatim(SkipLabels.accessibilityLabel(backward: true, seconds: skipBackwardInterval)),
                             size: transportSkipGlyphSize) {
                DeckCue.shared.wind(-1)
                playerViewModel.skipBackward()
            }

            Button {
                DeckFeedback.press(skin: deckSkinInUse, heavy: true)
                playerViewModel.togglePlayPause()
            } label: {
                ZStack {
                    // Batch 465: on a skin, Play latches down while the book plays.
                    DeckPlayShape(skin: deckSkinInUse, palette: bookPalette, latched: playerViewModel.isPlaying)
                        // H3 (REVIEW_2026-09-04_UI.md Pass 3): was a fixed 64 — the
                        // primary action on this screen, unchanged while everything
                        // else around it scaled with Dynamic Type. Capped at 1.4× so
                        // it can't outgrow the room `transportRowSpacing` accounts for.
                        .frame(width: transportPlayCircleSize, height: transportPlayCircleSize)
                        // D4: dark-theme-only glow. In light theme "playing" is already
                        // expressed through the equalizer badge elsewhere and the fill's
                        // own saturation — an amber halo on warm paper just reads as a
                        // smudge, not a glow, since the effect assumes a dark ground.
                        .shadow(color: Color.shelfAmber.opacity(
                            colorScheme == .dark && playerViewModel.isPlaying ? 0.5 : 0
                        ), radius: 12)

                    // iOS 26/27 Liquid Glass polish pass (26 August 2026): the
                    // play/pause glyph used to hard-swap with no transition at all.
                    // `.symbolEffect(.replace)` is the native SF Symbols morph iOS 26
                    // uses for this exact case; paired with `shelfAnimation` (not a
                    // bare `.animation`) so Reduce Motion still suppresses it, same as
                    // every other animation in this file.
                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: transportPlayGlyphSize, weight: .bold))
                        .foregroundStyle(deckSkinInUse == .fromTheCover ? (bookPalette ?? .brand).onPrimaryAccent : Color.onAccent)
                        .offset(x: playerViewModel.isPlaying ? 0 : 2,
                                y: deckSkinInUse != .classic && playerViewModel.isPlaying ? deckSkinInUse.keyTravel : 0)
                        .contentTransition(.symbolEffect(.replace))
                        .shelfAnimation(.easeOut(duration: 0.2), value: playerViewModel.isPlaying)
                }
                // LS-1 (docs/design-review.md): ring sits just outside the play
                // circle (6pt over its diameter, so ≤3pt overflow on each side plus
                // half the ring's own stroke width — well under the ~6pt-per-side
                // budget `transportRowSpacing` leaves before it starts colliding with
                // the neighbouring skip buttons) and scales with
                // `transportPlayCircleSize` so it still fits at AX5. An overlay, so
                // it doesn't change this row's layout.
                .bufferingRing(
                    isActive: playerViewModel.isTransportWaiting,
                    diameter: transportPlayCircleSize + 10,
                    lineWidth: 3
                )
            }
            .accessibilityLabel(playerViewModel.isPlaying ? "Pause" : "Play")
            .accessibilityValue(playerViewModel.isTransportWaiting ? "Loading" : "")
            // Batch 490 (REVIEW 2026-11-11 A1): as Driving Mode's Play already does —
            // VoiceOver stays quiet once Play starts audio instead of talking over it.
            .accessibilityAddTraits(playerViewModel.isPlaying ? [] : .startsMediaSession)

            transportButton(SkipLabels.symbolName(backward: false, seconds: skipForwardInterval),
                             label: .verbatim(SkipLabels.accessibilityLabel(backward: false, seconds: skipForwardInterval)),
                             size: transportSkipGlyphSize) {
                DeckCue.shared.wind(1)
                playerViewModel.skipForward()
            }

            transportButton("forward.end.fill", label: "Next chapter", size: transportChapterGlyphSize,
                            role: .chapter, enabled: playerViewModel.hasChapterList && playerViewModel.canSkipToNextChapter) {
                DeckCue.shared.wind(1)
                playerViewModel.nextChapter()
            }
        }
        // Batch 465: on a skin the keys sit in the deck's own housing.
        .background {
            if deckSkinInUse != .classic {
                DeckKeyPlate(skin: deckSkinInUse, palette: bookPalette)
                    .padding(.horizontal, -12)
                    .padding(.vertical, -10)
            }
        }
    }

    /// SB-3 (REVIEW_2026-09-14_DESIGN.md): the transport row's home once
    /// `usesAccessibilityLayout` moves it out of the scrollable column and into
    /// `PinnedAccessibilityTransport`'s `.safeAreaInset` (see `body`). Renders the exact
    /// same `controlsView(in:)` — same metrics, same caps, same haptics, same
    /// accessibility labels — just in a different position in the tree, so nothing about
    /// the row's own behaviour changes, only where it sits on screen.
    ///
    /// The hairline divider matches `bottomToolbar`'s own top divider (in
    /// `PlayerView+BottomRegion.swift`) — the established "no card, just a seam"
    /// treatment this screen already uses for its
    /// secondary control rows — and `Color.shelfBackground` is the same flat fill
    /// `backgroundView` paints everywhere else, so the pinned bar reads as part of the
    /// same page rather than a distinct floating panel. The fill isn't cosmetic: this bar
    /// sits in a `.safeAreaInset`, layered over the scrollable column above it, and
    /// without an opaque background the artwork or title would show through as they
    /// scroll underneath it.
    @ViewBuilder
    func pinnedTransportBar(in geometry: GeometryProxy) -> some View {
        pinnedTransportBar(columnWidth: min(geometry.size.width, 600) - 48)
    }

    /// iPhone Duo (§4): `pinnedTransportBar(in:)` for a pane narrower than the screen (see
    /// `controlsView(columnWidth:)`).
    @ViewBuilder
    func pinnedTransportBar(columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.shelfCream.opacity(0.08)).frame(height: 1)
            controlsView(columnWidth: columnWidth)
                .padding(.top, 16)
                .padding(.bottom, 10)
        }
        // P-6: matches the scrolling column's own 24pt margin above, so the pinned bar
        // lines up with the content it replaces. Deliberately not `Space.pageH` (20).
        .padding(.horizontal, 24)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Color.shelfBackground)
    }

    /// Which tier of the transport row a button belongs to. Critique 2026-10-05: ⏮ and ⟲15
    /// used to share one tone and weight, so the chapter restart (up to a whole chapter of
    /// rewind) read as the same kind of control as a 15-second nudge right beside it. The
    /// skips keep the row's 0.7 cream; the chapter buttons step down a tier (0.55, regular
    /// weight) so the hand learns the outer pair are the big jumps.
    enum TransportRole { case skip, chapter }

    /// Batch 460: the skin the transport keys are drawn in (classic when From the Cover is
    /// selected in light appearance).
    var deckSkinInUse: DeckSkin {
        // Batch 466: From the Cover no longer falls back to Classic in light appearance; every
        // skin is dark hardware in both themes (device test DS2).
        DeckSkin(rawValue: deckSkinRaw) ?? .classic
    }

    /// Batch 464: the classic cassette is on screen (it's taller than wide, so the artwork
    /// sizing makes room for it). Never true under a deck skin, whose face is square.
    var showsCassetteShell: Bool {
        showsCassette && deckSkinInUse == .classic
    }

    private func transportButton(_ icon: String, label: LocalizedStringResource, size: CGFloat,
                                 role: TransportRole = .skip, enabled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        let skin = deckSkinInUse
        return Button {
            // Batch 460: classic keeps its plain haptic; other skins use their own pattern.
            // Optional button sounds (default off) follow the same press.
            DeckFeedback.press(skin: skin)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: role == .chapter ? .regular : .medium))
                // Quieter than the amber play/pause so the primary action dominates.
                // Batch 465: a skin's light key caps take dark ink.
                .foregroundStyle((skin == .classic ? Color.shelfCream : skin.keyInk(palette: bookPalette))
                    .opacity(Self.transportGlyphOpacity(role: role, enabled: enabled, onSkin: skin != .classic)))
                .frame(width: 46, height: 46)
        }
        .deckKeyStyle(skin, palette: bookPalette)
        // A book with no chapters (a podcast episode, a single-file book) disables ⏮/⏭
        // instead of letting them fall back to the skip intervals ⟲/⟳ already provide.
        // Same 46pt frames either way, so the row doesn't reflow.
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    /// The glyph opacity for a transport button. Pure so the tiers are pinned by a test.
    /// Measured against what's actually behind the row (critique 2026-10-05, second run:
    /// the Light cover wash fades to ≈ F6F1E7 there, sampled from the simulator): 0.55 is
    /// about 3.5:1 in Light and 5.4:1 in Dark, clearing the 3:1 non-text floor with margin.
    /// It was 0.5, which measured 3.07:1 in Light — technically over, with no room. 0.25
    /// (disabled) is about 2:1 / 1.7:1, meant to read as unavailable.
    ///
    /// Batch 465: on a skin the glyph sits on its own key cap, not on the page, so it runs at
    /// full ink (0.85 for the chapter tier); disabled stays 0.25.
    static func transportGlyphOpacity(role: TransportRole, enabled: Bool, onSkin: Bool = false) -> Double {
        guard enabled else { return 0.25 }
        if onSkin { return role == .chapter ? 0.85 : 1 }
        return role == .chapter ? 0.55 : 0.7
    }
}

extension View {
    /// Batch 460: key styling for non-classic deck skins; classic returns the view untouched.
    /// Batch 465: From the Cover gets keys too, in the book's colours.
    @ViewBuilder
    func deckKeyStyle(_ skin: DeckSkin, palette: CoverPalette? = nil) -> some View {
        if skin == .classic {
            self
        } else {
            self.buttonStyle(DeckKeyStyle(skin: skin, palette: palette))
        }
    }
}
