import SwiftUI
import UIKit
import TipKit

/// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
/// everything below is verbatim what lived on `PlayerView` itself.
///
/// This file is everything behind and inside the artwork slot: the cover-derived
/// background wash, the flexible/accessibility artwork slot and the cover-vs-cassette
/// face itself, plus the one cover URL both of them share.
extension PlayerView {
    // MARK: - Background

    var backgroundView: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            if let book = playerViewModel.currentBook {
                coverBackdrop(for: book)

                // F8: a very subtle per-chapter hue shift of the cover's own extracted
                // palette — gives a long book gentle background variation over time
                // without being distracting, and without re-extracting per chapter
                // (the same palette is just hue-rotated by how far through the book
                // the current chapter is).
                //
                // Item 10 (REVIEW-2026-09-09.md): its own view for the same reason
                // `PlayerProgressSection` is — resolving "which chapter are we in"
                // means reading `currentTime`, so inlined here it made the background
                // layer a playback-tick dependency of the entire player body.
                if let palette = bookPalette {
                    ChapterHueWash(palette: palette)
                }
            }
        }
        .task(id: playerViewModel.currentBook?.id) {
            bookPalette = nil
            guard let book = playerViewModel.currentBook, let url = coverURL(for: book.id) else { return }
            // Batch 286 flagged this as a third direct `URLSession.shared` call (the
            // CLAUDE.md bypass class); routed through the API type's absolute-URL entry
            // point alongside `CarPlayImageLoader` (C10, REVIEW_2026-09-04_UI.md Pass 4).
            guard let data = try? await AudiobookshelfAPI.shared.authorizedData(for: url),
                  let image = UIImage(data: data) else { return }
            // CoverPalette.from(_:) takes a CGImage (not UIImage) specifically so this
            // extraction can run off-main without moving a non-Sendable UIImage across
            // the actor boundary — see CoverPalette's doc comment in ShareCard.swift.
            let cg = image.normalizedUp().cgImage
            let extracted = await Task.detached(priority: .utility) { CoverPalette.from(cg) }.value
            if playerViewModel.currentBook?.id == book.id {
                bookPalette = extracted
            }
        }
    }

    /// The ambient cover wash behind the player: a vertical gradient in the cover's own
    /// dominant colour, fading out before it reaches the controls.
    ///
    /// F8 (REVIEW_2026-09-04_UI.md) — this used to be the cover art itself, blurred at
    /// radius 70 across a 460pt band at 28% opacity (plus `backgroundExtensionEffect()`
    /// on iOS 26). Measured on the running app in Light theme, that was *removing* colour
    /// rather than adding it: the paper background is `#F6F1E8` (R−B 14) and the band came
    /// out `#D9D7D0` (R−B 9) — both darker and less saturated. Blurring a whole cover at
    /// that radius averages it to a mid-tone regardless of how vivid the art is, so the
    /// top third of the player read as grime. In Dark the same luminance lift passed as a
    /// glow, which is why it survived an on-device check.
    ///
    /// The fix is to stop averaging. `CoverPalette.from(_:)` already extracts a dominant
    /// colour by prominence × colourfulness (it is what drives the per-chapter tint just
    /// below, and the share cards), and `bookPalette` already holds the result for the
    /// current book — so this needs no new extraction, no second network fetch, and no
    /// blurred bitmap. A saturated hue at low opacity genuinely tints the paper.
    ///
    /// `backgroundExtensionEffect()` is gone with it. Batch 284 left open whether it was
    /// earning its place; on iPhone it demonstrably wasn't — the band and its gradient
    /// mask were doing all the visible work, and its documented job (extending under
    /// sidebars and inspectors) has nothing to extend under on a full-screen player.
    /// Removing it also retires the `GeometryReader` that existed only to stop
    /// `CachedCover`'s intrinsic width from propagating out and shifting the whole player.
    ///
    /// Kept faint for the same reason as before: this sits behind the player's own text,
    /// and legibility is what sets the opacity. Dark needs less than Light — over espresso
    /// a vivid hue reads strongly at a fraction of what paper needs to show any tint.
    @ViewBuilder
    private func coverBackdrop(for book: LibraryItem) -> some View {
        if let palette = bookPalette {
            LinearGradient(
                stops: [
                    .init(color: palette.primaryAccent.opacity(colorScheme == .dark ? 0.20 : 0.30), location: 0),
                    .init(color: palette.primaryAccent.opacity(colorScheme == .dark ? 0.10 : 0.15), location: 0.42),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom)
            .frame(height: 520)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .shelfAnimation(.easeInOut(duration: 0.6), value: book.id)
        }
    }

    // MARK: - Cover Art

    /// The artwork slot — the one element on this screen whose size is negotiable.
    ///
    /// H1 (REVIEW_2026-09-04_UI.md Pass 3): the flexible `GeometryReader` version (the
    /// `else` branch, unchanged) is only correct while the column genuinely fits on one
    /// screen. At accessibility sizes it does not, the slot collapses below the artwork's
    /// own floor, and `max(110, …)` with nothing clipping it paints the cover over the
    /// title. Once the column is allowed to scroll there, "whatever vertical room is left
    /// over" stops being a meaningful quantity — there is no leftover to measure — and a
    /// `GeometryReader` under an unbounded height proposal would collapse to its 10pt
    /// default anyway. So the accessibility branch takes an explicit size instead.
    ///
    /// iPhone Duo (§4): `alwaysFlexible` is for the folded player, where the cover has a pane
    /// of its own that never scrolls, so the flexible branch is right at every text size.
    /// The flat layout passes nothing and gets exactly the branch it always did.
    @ViewBuilder
    func artworkSlot(in geometry: GeometryProxy, alwaysFlexible: Bool = false) -> some View {
        if usesAccessibilityLayout && !alwaysFlexible {
            // Measured off the screen rather than off the slot. The column's own width is
            // the 600pt iPad cap (or the screen, whichever is smaller) less its 2×24pt
            // side padding; the height budget deliberately keeps the cover to a minority
            // of the screen so the title is always on the first screenful and nobody has
            // to scroll to find out which book is playing. H5 in the same review is the
            // other half of this: at AX5 the fixed layout had shrunk the cover to a 110pt
            // thumbnail, and this restores it to the same 306pt the default layout aims
            // for whenever the screen has room.
            let artworkSize = Self.accessibilityArtworkSize(
                columnWidth: min(geometry.size.width, 600) - 48,
                availableHeight: geometry.size.height,
                showsCassette: showsCassetteShell)
            if let captionsItemId {
                // Batch 425: captions take the cover's place at the same size budget.
                LiveCaptionsView(itemId: captionsItemId)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(artworkSize, 220))
                    .padding(.top, 8)
            } else {
                coverArtView(artworkSize: artworkSize)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        } else {
            GeometryReader { artGeo in
                // Both branches share ONE computed width so toggling between
                // cover and cassette never jumps the artwork horizontally —
                // only cassette's height differs (it's deliberately taller than
                // its own width — see `CassetteView`), so the WIDTH budget has
                // to account for that extra height when solving for what fits.
                let widthBudget = showsCassetteShell
                    ? artGeo.size.height - CassetteView.extraHeightBeyondWidth
                    : artGeo.size.height
                // Critique 2026-10-05 (third run): the 110 pt floor applies only when the slot
                // has room for it. A hard `max(110, …)` with nothing clipping it is exactly
                // H1's failure — on an iPhone SE in the bedtime state it drew the cover over
                // the title. The single status line removes the usual cause; this is the
                // backstop so it can't happen at all.
                let fitted = min(306, min(artGeo.size.width, widthBudget))
                let artworkSize = max(min(110, max(0, widthBudget)), fitted)
                Group {
                    if let captionsItemId {
                        // Batch 425: captions fill the whole slot; the size still feeds the
                        // progress-caption logic below so that behaves as with the cover.
                        LiveCaptionsView(itemId: captionsItemId)
                    } else {
                        coverArtView(artworkSize: artworkSize)
                    }
                }
                .onChange(of: artworkSize, initial: true) { _, size in
                    let hide = Self.progressCaptionsHidden(currentlyHidden: hideProgressCaptions, artworkSize: size)
                    if hide != hideProgressCaptions { hideProgressCaptions = hide }
                }
                .frame(width: artGeo.size.width, height: artGeo.size.height, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 8)
        }
    }

    /// Batch 425: the current book's id when captions should replace the cover: the setting is
    /// on and the book is not a podcast and has transcript text (the same gate as the header menu).
    private var captionsItemId: String? {
        guard showsCaptions, let book = playerViewModel.currentBook, !book.isPodcast,
              Self.hasSearchableTranscript(TranscriptionCenter.shared.state(for: book.id)) else { return nil }
        return book.id
    }

    /// The square the artwork renders at once the column is allowed to scroll (H1,
    /// REVIEW_2026-09-04_UI.md Pass 3). Pure so the clamps can be pinned by a test rather
    /// than only eyeballed in a screenshot.
    ///
    /// Same 110…306pt clamp the fixed layout uses, so the two never disagree about how big
    /// a cover is allowed to be, bounded additionally by 40% of the screen height —
    /// enough that the title always shares the first screenful with the cover. Cassette
    /// renders taller than it is wide (`CassetteView.extraHeightBeyondWidth`), so its
    /// chrome comes out of the height budget *before* solving for width, exactly as the
    /// fixed branch does it; flipping the cover must never resize it.
    static func accessibilityArtworkSize(columnWidth: CGFloat,
                                         availableHeight: CGFloat,
                                         showsCassette: Bool) -> CGFloat {
        let cassetteChrome: CGFloat = showsCassette ? CassetteView.extraHeightBeyondWidth : 0
        let heightBudget = availableHeight * 0.4 - cassetteChrome
        return max(110, min(306, min(columnWidth, heightBudget)))
    }

    // D1 (design brief 2026-08-12): default to the plain, uncropped square cover — the
    // cassette becomes a state the user opts into by tapping, not the default. Stops the
    // reels from spinning (and the shell's aspect crop, fixed separately in
    // `CassetteView`) from being forced on every listener on the one screen where the
    // artwork carries the whole emotional payload.
    //
    // Fixed after user testing ("entire now playing screen should be visible in one
    // page, no scrolling at all"): this used to render at a fixed 306pt regardless of
    // screen size, inside a `ScrollView` that absorbed whatever didn't fit. Now that
    // the caller (`body`) has removed the `ScrollView` entirely and instead hands this
    // view whatever width the flexible artwork slot actually has room for on THIS
    // device (see `CassetteView.extraHeightBeyondWidth`'s doc comment for how that
    // budget is computed), this takes that size as a parameter instead of hardcoding
    // one — both branches share it so toggling between cover and cassette never jumps
    // the artwork's width, only its height (cassette is deliberately taller — see
    // `CassetteView`).
    private func coverArtView(artworkSize: CGFloat) -> some View {
        Group {
            if let book = playerViewModel.currentBook {
                // Batch 460: a non-classic deck skin draws its own face here; the classic
                // artwork below is passed through untouched. Batch 464: the cover/cassette
                // flip is Classic-only, so a skin's face always shows.
                DeckSkinStage(coverURL: coverURL(for: book.id),
                              spinning: playerViewModel.isPlaying,
                              rate: playerViewModel.playbackRate,
                              chapterIndex: { playerViewModel.currentChapterIndex },
                              palette: bookPalette,
                              size: artworkSize) {
                ZStack {
                    if showsCassette {
                        // Reels only spin in cassette mode, and only while playing —
                        // never while the plain-artwork face is what's on screen.
                        CassetteView(coverURL: coverURL(for: book.id),
                                     spinning: playerViewModel.isPlaying,
                                     width: artworkSize)
                            .transition(.opacity)
                    } else {
                        CachedCover(url: coverURL(for: book.id), fit: true)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: artworkSize, height: artworkSize)
                            // Code review fix (26 August 2026): raw `14` → `Radius.panel`,
                            // the token for exactly this role (see `HomeView`'s hero cover).
                            .clipShape(RoundedRectangle(cornerRadius: Self.playerCoverRadius(artworkSize)))
                            // D4 (design brief 2026-08-12): shadow + border in one
                            // call via `shelfElevation` rather than a manual
                            // shadow-in-both-themes + a separately-low-opacity
                            // border — Dark theme keeps a soft shadow, Light theme
                            // gets a visible hairline instead of a shadow that would
                            // read as grime on warm paper.
                            .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Self.playerCoverRadius(artworkSize)))
                            .transition(.opacity)
                    }
                }
                }
                // Fixed after user testing: a real `Button` here quietly fought the
                // swipe-down-to-dismiss `DragGesture` this view's caller attaches via
                // `.gesture(dismissDrag)` — SwiftUI's button press-recognition and an
                // externally-attached drag gesture don't compose cleanly on the same
                // view, which is what made the dismiss drag lose its spring "bounce
                // back" and feel clunky. A plain `.onTapGesture` plus an explicit
                // accessibility action gives the same tap-to-flip behavior without a
                // competing gesture recognizer.
                //
                // Also fixed after user testing: this used to additionally apply a real
                // `rotation3DEffect` (0→180°) alongside the crossfade, meant as an
                // optional "flip" flourish layered on top of the plain crossfade — in
                // practice a flat view rotated a full 180° around its Y axis ends up
                // mirrored (backwards) once the animation completes, since nothing here
                // counter-rotates the "back" face. That's the "cassette mirrors the
                // cover art" bug the brief itself warned a true two-sided flip risks —
                // removed the rotation entirely and kept the crossfade only, exactly
                // the documented fallback ("a correct crossfade is better than a janky
                // flip").
                .onTapGesture {
                    // Batch 464: a deck skin's face doesn't flip; only Classic has a cassette side.
                    guard deckSkinInUse == .classic else { return }
                    Haptics.impact(.light)
                    // P3-12 (third-pass review, 14 Aug 2026): this still animated the
                    // flip under Reduce Motion (`.easeInOut(duration: 0.25)` instead of
                    // no animation at all) — every other site in this file resolves to
                    // `nil` when `reduceMotion` is on (see the drag-to-dismiss and
                    // tap-to-close cases just above).
                    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82)) {
                        showsCassette.toggle()
                    }
                    // Code review fix (26 August 2026): TipKit hygiene — nothing in the
                    // app previously called `invalidate(reason:)`, so performing the
                    // action a tip teaches never retired that tip. This is the actual
                    // "tap the cover to flip it" gesture `CassetteFlipTip` exists to
                    // teach; retiring it here means it won't keep popping up for
                    // someone who's already found the gesture themselves.
                    CassetteFlipTip().invalidate(reason: .actionPerformed)
                }
                // P-6: a deliberate 4pt one-off, not a page margin — it only keeps the
                // artwork's own shadow/cassette shell off the column's edge inside the
                // 24pt margin the column already applies. No `Space.*` token this small.
                .padding(.horizontal, 4)
                // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10): shown on the second
                // full-player open (see `CassetteFlipTip`'s own doc comment / the
                // donation in this file's `.onAppear`).
                .popoverTip(CassetteFlipTip())
                // NEW-14 (follow-up review, 14 Aug 2026): without this, VoiceOver
                // could still surface this ZStack's own children (`CassetteView`'s
                // internal imagery, or `CachedCover`'s `Image(uiImage:)` plus its
                // decorative fallback `Image(systemName:)`) as separate, unlabelled
                // stops alongside — or instead of — the composite label/hint/action
                // below, since none of those children mark themselves
                // `.accessibilityHidden`. `.ignore` makes this whole region read as
                // exactly one element with exactly the label/trait/action this file
                // explicitly sets, the same "one opaque interactive element, not a
                // grab-bag of its children's own accessibility info" pattern already
                // used for the close-player region above.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(deckSkinInUse != .classic ? "Cover art" : showsCassette ? "Cassette view" : "Cover art")
                .accessibilityHint(deckSkinInUse == .classic ? Text("Double tap to switch between cover art and cassette view") : Text(verbatim: ""))
                .accessibilityAddTraits(deckSkinInUse == .classic ? .isButton : [])
                .accessibilityAction {
                    guard deckSkinInUse == .classic else { return }
                    Haptics.impact(.light)
                    // P3-12 (third-pass review, 14 Aug 2026): this still animated the
                    // flip under Reduce Motion (`.easeInOut(duration: 0.25)` instead of
                    // no animation at all) — every other site in this file resolves to
                    // `nil` when `reduceMotion` is on (see the drag-to-dismiss and
                    // tap-to-close cases just above).
                    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82)) {
                        showsCassette.toggle()
                    }
                }
            }
        }
    }

    private func coverURL(for itemId: String) -> URL? {
        // Clean URL (no token); CachedCover/CassetteView attach the auth header and
        // prefer a locally-cached cover when the book is downloaded. 900 (not 600):
        // the cassette label renders at ~278pt, which on a 3x device is ~834px of
        // display — 600 was already thin for that, and CoverImageCache.targetSize(for:)
        // now downsamples in-memory to whatever this URL's own width param says.
        shelfCoverURL(itemId: itemId, width: 900)
    }
}

/// The full player's per-chapter background hue wash (F8).
///
/// Item 10 (REVIEW-2026-09-09.md): `chapterHueShiftFraction` used to be a computed
/// property of `PlayerView`, read from `backgroundView` — so the single cheapest layer on
/// the screen made the entire player body (cover art, transport row, bottom toolbar) a
/// dependency of the playback tick, since resolving the current chapter reads
/// `currentTime`. Reading the player from down here scopes that invalidation to this one
/// layer. The `.opacity`/`.blendMode`/animation values are unchanged.
private struct ChapterHueWash: View {
    let palette: CoverPalette

    @Environment(PlayerViewModel.self) private var playerViewModel

    /// How far through the book (by chapter index) the current chapter is, as a small
    /// fraction of the hue wheel — deliberately narrow (±~5%) so it reads as ambience,
    /// not a visible color-cycling effect.
    ///
    /// Item 10: takes the index straight from `PlayerViewModel.currentChapterIndex`
    /// instead of re-deriving it with a second `chapters.firstIndex(where:)` scan over
    /// the same list the resolution had just walked.
    private var chapterHueShiftFraction: Double {
        guard let index = playerViewModel.currentChapterIndex else { return 0 }
        return (Double(index) / Double(max(playerViewModel.chapters.count - 1, 1))) * 0.05
    }

    var body: some View {
        palette.hueShifted(chapterHueShiftFraction).background
            .opacity(0.10)
            .blendMode(.overlay)
            .ignoresSafeArea()
            .shelfAnimation(.easeInOut(duration: 1.5), value: playerViewModel.currentChapter?.id)
    }
}
