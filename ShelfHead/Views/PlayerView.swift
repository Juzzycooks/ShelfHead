import SwiftUI
import TipKit

// N-5 (REVIEW_2026-09-14_DESIGN.md): this file used to be ~2,980 lines — the layout
// skeleton plus the speed sheet, chapters, bookmarks, sleep timer, share entry, Up Next
// chips, driving mode, the glass container and Batch 317/318's pinned transport and
// honest-rail work, all in one place. It now keeps only what the screen is made of at the
// top level: `PlayerView`'s state, environment, sizing metrics, `body`, and the
// gating view modifiers `body` applies (plus, at the end, the iPhone Duo folded layout
// the third of them swaps in). Everything else moved, verbatim and with its own
// doc comments intact, into `PlayerView+<Area>.swift` files beside this one:
//
//   PlayerView+Header.swift        drag handle, swipe-to-dismiss, "…" menu, share entry
//   PlayerView+Artwork.swift       cover background wash, artwork slot, cover/cassette
//   PlayerView+BookInfo.swift      title/author block and the chapter caption
//   PlayerView+Scrubber.swift      the THIS CHAPTER / WHOLE BOOK progress cluster
//   PlayerView+Transport.swift     transport row (inline and pinned) and its metrics
//   PlayerView+BottomRegion.swift  status chips, secondary toolbar, AirPlay picker
//   PlayerView+Formatting.swift    the pure, test-pinned formatting helpers
//   PlayerView+Sheets.swift        chapters / bookmarks / Up Next / speed sheets
//   PlayerView+DrivingMode.swift   the large-target in-hand driving surface
//
// Nothing was renamed and nothing changed shape; the only edits were access levels, where
// a member `body` (or another area) reads across a file boundary can no longer be
// `private`.

/// H1 (REVIEW_2026-09-04_UI.md Pass 3): gates the full player's "entire now playing screen
/// visible in one page, no scrolling at all" invariant on Dynamic Type.
///
/// That invariant (see the long comment in `PlayerView.body` for why the `ScrollView` was
/// removed in the first place) holds at every non-accessibility size and breaks at the
/// accessibility ones: the rows' natural heights simply exceed the screen, the artwork —
/// the only flexible element — is squeezed past its own 110pt floor, and with nothing
/// clipping it the cover is drawn straight over the title. The alternative minimum fix
/// (drop the floor, add `.clipped()`) only makes that failure quieter; it still trades the
/// cover against the title rather than giving the screen the room it's asking for.
///
/// Deliberately a `ViewModifier` rather than an `if` around the column itself: when
/// `enabled` is false this returns `content` completely untouched — no `ScrollView`, no
/// extra frame, no changed modifier order — so `.large` through `.xxxLarge` render exactly
/// as they did before this fix, by construction rather than by inspection.
///
/// `minHeight` keeps a column that's *shorter* than the screen (AX3 on a big phone) filling
/// it instead of bunching against the top; anything taller just scrolls.
private struct AccessibilityScrollColumn: ViewModifier {
    let enabled: Bool
    let minHeight: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            // Indicators deliberately left visible (the default): at these sizes the
            // column really is taller than the screen, and the scroll bar is the only
            // thing on the page that says so.
            ScrollView(.vertical) {
                content.frame(minHeight: minHeight, alignment: .top)
            }
            // Nothing to bounce against on the sizes where the column happens to fit.
            .scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

/// SB-3 (REVIEW_2026-09-14_DESIGN.md): pins a bottom bar above the home indicator via
/// `.safeAreaInset(edge: .bottom)` — Apple's own idiom for "this control must never be
/// hidden behind, or require scrolling past, content that can grow taller than the
/// screen." `.safeAreaInset` additionally grows the reserved bottom space of whatever
/// scrollable content sits inside `content` (here, `AccessibilityScrollColumn`'s
/// `ScrollView`, applied just before this modifier in `body`) by the pinned bar's own
/// measured height, so the last scrollable row can never end up hidden underneath it —
/// no manual height bookkeeping needed on either side.
///
/// Mirrors `AccessibilityScrollColumn` immediately above: `enabled` is the same
/// `usesAccessibilityLayout` threshold, and `false` returns `content` completely
/// untouched — no inset, no reserved space, no changed modifier order — so every size
/// below `.accessibility3` renders bit-for-bit as it did before this fix.
private struct PinnedAccessibilityTransport<Controls: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let controls: () -> Controls

    func body(content: Content) -> some View {
        if enabled {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                controls()
            }
        } else {
            content
        }
    }
}

/// iPhone Duo (§4, docs/iphone-duo-readiness-2026-10-22.md): swaps the flat column for the
/// folded layout while an active fold (`PlayerFold`, the hinge's `.division` reserved
/// region, iOS 27.1) crosses the player. Same shape as the two modifiers above: with no
/// fold — flat, fully open, closed, every other iPhone, every OS before 27.1, every SDK
/// before 27.1 — this returns `content` completely untouched, so the flat layout is the
/// one it always was by construction. The user chose "read the fold" over
/// `ArrangementView`, whose overlay style layers the controls over the cover on a flat
/// screen.
private struct PlayerFoldLayout<Folded: View>: ViewModifier {
    let fold: PlayerFold?
    @ViewBuilder let folded: (PlayerFold) -> Folded

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fold {
            folded(fold)
        } else {
            content
        }
    }
}

struct PlayerView: View {
    @Environment(PlayerViewModel.self) var playerViewModel
    @Environment(LibraryViewModel.self) var libraryViewModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// D4 (design brief 2026-08-12): the play button's amber glow below is dark-theme-only
    /// — on light theme's warm paper background a colored glow reads as a smudge, not a
    /// glow, since the effect assumes a dark ground to shine against.
    @Environment(\.colorScheme) var colorScheme
    /// Tapping the book title on the full player opens Book Detail through the same
    /// `shelfhead://book/<id>` route Spotlight and widgets use (App Lock-gated at the root).
    @Environment(\.openURL) var openURL
    /// H1 / H2 (REVIEW_2026-09-04_UI.md Pass 3): the accessibility Dynamic Type sizes are
    /// where two of this screen's layout invariants stop holding — "the whole player fits
    /// in one page, no scrolling at all" (the artwork is squeezed past its own floor and
    /// ends up painted over the title, rendered at AX4/AX5 in
    /// `docs/review-2026-09-04-screens/60-ax-player-ax4-light.png`) and "five bottom-toolbar
    /// labels fit on one line each" (they wrap, and a wrapped label lifts its own icon out
    /// of the row, rendered at AX1). Both fixes below are gated on this, so nothing at
    /// `.large` — or at any other non-accessibility size — changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The single threshold both H1 and H2 key off. Integration note (build 27's first
    /// render): gating on `isAccessibilitySize` — i.e. from AX1 — made the column scroll
    /// and the cover grow at AX1, pushing the bottom toolbar below the fold on a screen
    /// the audit had measured as fitting fine there (~200pt art, clean). The audit's own
    /// numbers put the collision at AX3 ("touching", ~145pt) and AX4+ (overlapping), so
    /// AX3 is where the one-page invariant actually stops holding. AX1/AX2 keep the fitted
    /// single-screen layout, with H2's 11pt label clamp doing its work there.
    var usesAccessibilityLayout: Bool { dynamicTypeSize >= .accessibility3 }
    @State var showSpeedPicker = false
    @State var shareSession: ShareSession?
    @State var showBookDetails = false
    @State var showChapters = false
    @State var showBookmarks = false
    @State var showQueue = false
    @State var showChapterSkip = false
    /// Batch 424: Search in Book (transcript search).
    @State var showTranscriptSearch = false
    /// Batch 426: the quote-clip editor.
    @State var showClipEditor = false
    /// Batch 455: the book club, composing a post at the current position.
    @State var showBookClub = false
    /// Batch 428: "Previously On…" and "I Zoned Out" (Apple Intelligence, iOS 26+).
    @State var showRecap = false
    @State var showZonedOut = false
    /// Batch 429: X-Ray and Ask the Book.
    @State var showXRay = false
    @State var showAskBook = false
    /// Batch 431: the EPUB reader, following the audio.
    @State var showReadAlong = false
    /// Batch 427: a book with no chapters still opens the chapter list when it can be offered
    /// suggested chapters (that sheet is where Suggest Chapters… lives). Checked in a task, not
    /// the body, because the check reads the manifest and transcript meta from disk.
    @State var chapterSuggestionsOffered = false
    @State var showDrivingMode = false
    /// P-14 (REVIEW_2026-09-14_DESIGN.md): the `@Observable` singleton behind the
    /// Listening Profile row in the header menu. Held as `@State` (not read statically off
    /// `.shared` at the call site) for the same reason `PlaybackSettingsSection` does —
    /// that's what makes `activeProfile` an observed dependency, so the menu's own label
    /// and checkmark update when the profile is changed from Settings or CarPlay.
    @State var listeningProfileManager = ListeningProfileManager.shared
    @State var dragOffset: CGFloat = 0
    /// Cover-derived palette for the current book, used to gently tint the background
    /// per chapter (F8). Nil until the async extraction in `backgroundView`
    /// (`PlayerView+Artwork.swift`) finishes; the plain blurred-cover background renders
    /// fine without it in the meantime.
    @State var bookPalette: CoverPalette?
    /// D1 (design brief 2026-08-12): the full player's cover defaults to the plain
    /// square artwork; tapping it flips to the cassette. `@AppStorage` (not `@State`)
    /// so the choice persists across player opens/relaunches instead of resetting to
    /// plain every time.
    @AppStorage(SettingsKeys.playerShowsCassette) var showsCassette = false
    /// Batch 464: observed here (not read from `SettingsStore`) so the artwork sizing and the
    /// transport keys follow a skin change made while the player is open.
    @AppStorage(SettingsKeys.deckSkin) var deckSkinRaw = DeckSkin.default.rawValue
    /// Batch 425 (Section C): live captions in the artwork slot instead of the cover.
    @AppStorage(SettingsKeys.playerShowsCaptions) var showsCaptions = false
    // Batch 218 (R10.11): this file used to read `skipBackwardInterval`/
    // `skipForwardInterval` directly inside `body` — a plain `UserDefaults` read isn't
    // something SwiftUI can observe, so a mid-session change in Settings wasn't
    // guaranteed to invalidate this persistent overlay's view until something else
    // happened to re-render it. `@AppStorage` on the same keys is the pattern already
    // used everywhere else in the app that reads these two settings (see
    // `PlaybackSettingsSection`), so this adopts that instead of inventing a third way.
    @AppStorage(SettingsKeys.skipBackwardInterval) var skipBackwardInterval: Double = 15
    @AppStorage(SettingsKeys.skipForwardInterval) var skipForwardInterval: Double = 30

    // Dynamic Type: the Now Playing text scales with the user's preferred size.
    @ScaledMetric var npTitleSize: CGFloat = 19
    /// Critique 2026-10-06 (harden): the title was the one uncapped `@ScaledMetric` on this
    /// screen, so at AX5 two lines of it pushed the transport down. Capped at 1.4× like the
    /// transport row (`cappedTransportMetric`); the title already wraps to two lines.
    var npTitleSizeCapped: CGFloat { Self.cappedTransportMetric(npTitleSize, base: 19) }
    // Critique 2026-10-05 (typeset): `npAuthorSize` (13) is gone — the author line now uses
    // `Typo.metadata`, the role DESIGN.md names for exactly that line, at the same 13pt.
    /// The ••• overflow glyph. Was a fixed 15pt while everything around it scaled.
    @ScaledMetric var headerMenuGlyphMetric: CGFloat = 15
    /// See `progressCaptionsHidden`; written from the artwork slot's measured size.
    @State var hideProgressCaptions = false
    /// The bottom tool row's measured width (`toolbarLabelPointSize`).
    @State var toolbarRowWidth: CGFloat = 0
    // `npChapterSize` moved with the chapter caption itself into
    // `PlayerChapterCaption` (item 10, REVIEW-2026-09-09.md) — a `@ScaledMetric`
    // resolves against its own view's environment, which is the same environment here,
    // so the rendered point size is unchanged.
    // The bottom toolbar's icon/label sizes were left fixed when Dynamic Type support
    // was added elsewhere on this screen — at larger accessibility text sizes the
    // "Bookmark"/"AirPlay" labels below each icon would wrap or clip against their
    // 44pt-min neighbours while the rest of the screen kept scaling normally.
    // HL-7 (V5, accepted 26 September 2026): glyphs 15 → 17 pt and labels 9 → 11 pt, so
    // size (not colour) keeps the row secondary but not disabled-looking.
    @ScaledMetric var toolbarIconSize: CGFloat = 17
    @ScaledMetric private var toolbarLabelSize: CGFloat = 11

    // H3 (REVIEW_2026-09-04_UI.md Pass 3): the transport row (skip glyphs + the amber
    // play circle) was the one thing on this screen still using fixed literals while
    // everything else scaled. `cappedTransportMetric` (above) clamps each of these at
    // 1.4× its own base before use — see `transportPlayCircleSize`/etc. below.
    @ScaledMetric private var transportChapterGlyphMetric: CGFloat = 16
    @ScaledMetric private var transportSkipGlyphMetric: CGFloat = 22
    @ScaledMetric private var transportPlayGlyphMetric: CGFloat = 24
    @ScaledMetric private var transportPlayCircleMetric: CGFloat = 64

    // H4 (REVIEW_2026-09-04_UI.md Pass 3): the drag handle's `chevron.down` was a
    // hardcoded 10pt next to text that triples in size at AX5 — this tracks the
    // wordmark's own `relativeTo: .caption2` so the two scale together.
    @ScaledMetric(relativeTo: .caption2) var dragHandleChevronMetric: CGFloat = 10

    /// H2 (REVIEW_2026-09-04_UI.md Pass 3): the point size the bottom toolbar's labels
    /// actually render at, clamped so they stop growing while all five still fit their own
    /// fifth of the row.
    ///
    /// This can NOT be done with `.dynamicTypeSize(...DynamicTypeSize.xxLarge)`, the clamp
    /// `SpeedSheet` uses further down this file (and the one the review proposed here):
    /// that modifier changes the environment *below* it, while `toolbarLabelSize` is a
    /// `@ScaledMetric` already resolved against this view's own environment, and
    /// `.font(.system(size:))` with an explicit point size never consults `dynamicTypeSize`
    /// in the first place. On this row the modifier would compile, read as a fix, and do
    /// nothing. Clamping the metric is the only lever that has an effect.
    ///
    /// Why 11: the narrowest phone this app runs on is 375pt wide, less the column's 2×24pt
    /// padding, over five equal columns = 65.4pt each. The longest label, "Bookmarks", is
    /// ≈5.1em, so ≈56pt at 11pt — comfortably inside that. The unclamped metric passes
    /// through 11pt at `.xxLarge` (9 × 21/17 ≈ 11.1) and reaches ≈12.2pt at `.xxxLarge`
    /// (≈62pt of a 65.4pt column, no margin at all) and ≈14.8pt at AX1 (≈75pt — which is
    /// exactly what wrapped "Bookmarks" to "Bookmark" / "s" in the review's AX1 capture).
    /// HL-7 (V5, 30 September 2026): the base label is now 11pt (was 9pt) and the cap 12pt
    /// (was 11pt), so the row reads as secondary without looking disabled. 12pt "Bookmarks"
    /// is ≈61pt of the 65.4pt column (tight, so the cap stays there); the analysis above
    /// used the old 9pt base.
    var toolbarLabelPointSize: CGFloat {
        Self.toolbarLabelPointSize(scaled: toolbarLabelSize, rowWidth: toolbarRowWidth)
    }

    /// One label size for all five tool columns (critique 2026-10-05, fourth run). Each
    /// label used to shrink on its own (`minimumScaleFactor`), so on narrow phones
    /// "Bookmarks" rendered smaller than "Sleep" beside it. The cap is the size at which the
    /// longest label ("Bookmarks", ≈ 5.4 × its point size wide in SF Pro medium) fits one
    /// fifth of the row less 8 pt of inset. 12 pt stays the ceiling; 0 width = unmeasured.
    static func toolbarLabelPointSize(scaled: CGFloat, rowWidth: CGFloat) -> CGFloat {
        let base = min(scaled, 12)
        guard rowWidth > 0 else { return base }
        return min(base, max(8, (rowWidth / 5 - 8) / 5.4))
    }

    /// H2 (REVIEW_2026-09-04_UI.md Pass 3): the square slot every icon in the bottom toolbar
    /// sits in — the four SF Symbols *and* AirPlay's real `AVRoutePickerView`.
    ///
    /// Both were previously pinned to a literal 44 (see `toolbarButton` for why they must
    /// match: `HStack` centres each column on its own height, so unequal columns misalign
    /// every icon in the row, not just the odd one out). A fixed 44 was right while the
    /// glyphs were 15pt, but `toolbarIconSize` reaches ≈47pt at AX5 — the SF Symbols
    /// overflow their own slot, while the route picker, a real `UIView` that draws its glyph
    /// from its bounds, stays exactly 44 and reads as disabled beside them. Growing the slot
    /// by the same ratio the glyph metric has grown by keeps the two in proportion and keeps
    /// all five columns exactly as tall as each other.
    var toolbarIconSlot: CGFloat { Self.toolbarIconSlotSide(forIconSize: toolbarIconSize) }

    // H3 (REVIEW_2026-09-04_UI.md Pass 3): capped, scaled sizes for the transport row.
    // Each resolves to exactly its call site's old literal at `.large` — see
    // `cappedTransportMetric`'s own comment for why that's guaranteed, not assumed.
    var transportChapterGlyphSize: CGFloat {
        Self.cappedTransportMetric(transportChapterGlyphMetric, base: 16)
    }
    var transportSkipGlyphSize: CGFloat {
        Self.cappedTransportMetric(transportSkipGlyphMetric, base: 22)
    }
    var transportPlayGlyphSize: CGFloat {
        Self.cappedTransportMetric(transportPlayGlyphMetric, base: 24)
    }
    var transportPlayCircleSize: CGFloat {
        Self.cappedTransportMetric(transportPlayCircleMetric, base: 64)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                VStack(spacing: 0) {
                    // Drag handle — the drag-to-dismiss lives here so it never
                    // fights the content below it.
                    //
                    // H1 (REVIEW_2026-09-04_UI.md Pass 3): at accessibility sizes this
                    // handle is the ONLY place swipe-to-dismiss still lives (the artwork
                    // and title below drop theirs — see their `including:` masks). It
                    // keeps `.gesture` rather than `.simultaneousGesture`, so on the
                    // handle's own strip the drag is recognised exclusively and the
                    // enclosing scroll view doesn't also pan; everywhere else on the
                    // screen scrolls normally. Tap-to-close (in `dragHandle`, now in
                    // `PlayerView+Header.swift`) is unaffected and remains the
                    // discoverable way out at any size.
                    dragHandle
                        .padding(.top, 14)
                        // P-6: deliberately 24, not `Space.pageH` (20) — this is the
                        // player column's own margin, matched below and in
                        // `pinnedTransportBar(in:)`, and `toolbarLabelPointSize`/
                        // `controlsView(in:)` both size themselves off the 2x24 it
                        // produces. Changing it is a layout change, not a token swap.
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                        // AX-4 (docs/design-review.md, Round 4): tap-to-close used to sit
                        // inside `dragHandle`, on its unpadded ~28 pt content, under the
                        // HIG's 44 pt minimum. Attached here, after the padding, the whole
                        // strip (~50 pt at the default size, taller as the wordmark scales)
                        // is the target, with no layout change. Still `onTapGesture` plus
                        // `.isButton` rather than a `Button`: `PlayerView+Artwork.swift`'s
                        // cover records that a real `Button` on a view carrying
                        // `dismissDrag` broke the drag's spring after user testing. The
                        // accessibility element moved with it, so VoiceOver's focus frame
                        // matches the hit region.
                        .onTapGesture {
                            dismissFullPlayer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Close player")
                        // Critique 2026-10-05 (second run): the label above replaces the
                        // combined children, so the status word was never spoken. The
                        // stall state is announced separately (`PlayerHeaderStatusLabel`).
                        .accessibilityValue(PlayerView.headerStatus(
                            isPlaying: playerViewModel.isPlaying,
                            isWaiting: playerViewModel.isTransportWaiting,
                            stalled: playerViewModel.transportStalled,
                            isStreaming: playerViewModel.isStreamingCurrentBook).spokenText)
                        .accessibilityAddTraits(.isButton)
                        .gesture(dismissDrag)

                    // Fixed after user testing ("entire now playing screen should be
                    // visible in one page, no scrolling at all"): this used to be a
                    // `ScrollView` with a fixed 306pt artwork, which is exactly why
                    // scrolling was ever needed — on shorter screens (or with Dynamic
                    // Type turned up, or both chips below showing at once) the fixed-
                    // size content simply didn't fit. Rather than continuing to patch
                    // the `ScrollView` (the previous few batches' entire saga), removed
                    // it: every element below now takes its own natural, un-scaled
                    // size EXCEPT the artwork, which is the one flexible element
                    // (`.frame(maxHeight: .infinity)`) — it's handed however much
                    // vertical room is actually left over once everything else has
                    // claimed its own space, computed fresh by SwiftUI's own layout
                    // engine every render rather than estimated by hand here. That
                    // guarantees the whole screen always fits without scrolling, on any
                    // device size or Dynamic Type setting, at the cost of the artwork
                    // itself shrinking on more crowded configurations instead.
                    //
                    // H1 (REVIEW_2026-09-04_UI.md Pass 3): that reasoning is still right at
                    // every non-accessibility size and wrong at the accessibility ones —
                    // see `artworkSlot(in:)` and `AccessibilityScrollColumn` for where the
                    // invariant is gated instead of abandoned.
                    artworkSlot(in: geometry)
                        .contentShape(Rectangle())
                        // H1: at accessibility sizes the column scrolls, and a
                        // `.simultaneousGesture` drag is by definition recognised
                        // alongside the scroll view's own pan — dragging the cover would
                        // scroll the content AND slide the whole player down at once.
                        // The `.subviews` mask turns *this* gesture off there (the
                        // cover's own tap-to-flip, a subview gesture, still works),
                        // leaving swipe-to-dismiss scoped to the drag handle above, which
                        // stays put at the top of the screen. `.all` is the modifier's
                        // own default, so the fixed layout is bit-for-bit unaffected.
                        .simultaneousGesture(dismissDrag,
                                             including: usesAccessibilityLayout ? .subviews : .all)

                    // Book Info — likewise draggable to dismiss. `.simultaneousGesture`
                    // (not `.gesture`) here and above so a drag starting on the cover
                    // art or title doesn't get exclusively claimed by `dismissDrag` —
                    // see that gesture's own doc comment for the bug this fixed.
                    bookInfoView
                        .padding(.top, 14)
                        .contentShape(Rectangle())
                        // H1: same scoping as the artwork above — off at accessibility
                        // sizes so it can't be recognised simultaneously with the scroll.
                        .simultaneousGesture(dismissDrag,
                                             including: usesAccessibilityLayout ? .subviews : .all)

                    // Batch 458: "Clip 2 of 5" with Next clip and Stop while a mixtape plays.
                    // Renders nothing otherwise, so the fixed layout is unchanged.
                    MixtapeBanner()
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                    // Batch 456: "SharePlay · 2 people" with Leave while a session is live.
                    ListenTogetherStatusBanner()
                        .padding(.horizontal, 24)
                        .padding(.top, 10)

                    // Progress Slider + Times
                    //
                    // Item 10 (REVIEW-2026-09-09.md): its own view, not a computed
                    // property of this one. Everything on this screen that reads
                    // `currentTime`/`progress`/`chapterElapsed` lives in there, and a
                    // computed property is inlined into *this* body's dependencies —
                    // so the whole full player, cover art and toolbar included, was
                    // being invalidated twice a second by the scrubber's own position.
                    PlayerProgressSection(showsCaptions: !hideProgressCaptions)
                        .padding(.top, 18)

                    // Main Controls
                    //
                    // SB-3 (REVIEW_2026-09-14_DESIGN.md): only rendered inline here below
                    // the accessibility threshold. At `.accessibility3`+ this moves to a
                    // `.safeAreaInset(edge: .bottom)` pinned bar instead (see
                    // `PinnedAccessibilityTransport` below and `pinnedTransportBar(in:)`
                    // in `PlayerView+Transport.swift`) so play/pause can never end up
                    // scrolled off the bottom of the screen —
                    // exactly the failure `AccessibilityScrollColumn` (above) allows once the
                    // artwork/title/progress cluster above genuinely doesn't fit one screen.
                    if !usesAccessibilityLayout {
                        controlsView(in: geometry)
                            .padding(.top, 22)
                    }

                    // iOS 26/27 Liquid Glass polish pass (26 August 2026): the
                    // sleep/Up-Next chips and the toolbar's own active-state pills, both
                    // in `PlayerView+BottomRegion.swift`, are the screen's whole bottom
                    // region and already all real Liquid Glass individually
                    // (`glassPill`/the toolbar pill above) — grouped into one
                    // `bottomGlassRegion` (also in `PlayerView+BottomRegion.swift`) so
                    // they share a `GlassEffectContainer` on iOS 26+ and can blend at the
                    // edges when close together, per Apple's own "group related
                    // elements" guidance, instead of each rendering as an
                    // independent, disconnected material. Deliberately NOT extended
                    // to `playerHeaderMenu` (top-right corner, via the `.overlay`
                    // below) — that glass circle sits nowhere near this bottom
                    // region, so putting it in the same container would have no
                    // actual blending effect, just a misleading grouping.
                    //
                    // Also deliberately does NOT use `.glassEffectID` morphing
                    // between the chips and the toolbar pills: that API is for one
                    // glass *shape* continuing as another across a state change
                    // (e.g. a selected-tab indicator sliding to a new tab) — the
                    // sleep chip and the sleep toolbar-button's pill are two
                    // different UI elements, not the same shape moving, so tagging
                    // them with matching IDs would misuse the API to fake a morph
                    // that isn't really happening. `GlassEffectContainer` grouping
                    // (real, correct here) without `glassEffectID` (not a genuine
                    // fit here) is the honest scope for this screen.
                    bottomGlassRegion
                }
                // P-6: the player column's own 24pt margin — see `dragHandle` above for
                // why this one is deliberately not `Space.pageH`.
                .padding(.horizontal, 24)
                // On iPad / landscape, cap the column width and centre it so the
                // player doesn't stretch into huge side margins.
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .padding(.bottom, max(geometry.safeAreaInsets.bottom, 16))
                // H1 (REVIEW_2026-09-04_UI.md Pass 3): a no-op — literally `content` —
                // at every size below `.accessibility1`. See the modifier's own comment.
                .modifier(AccessibilityScrollColumn(
                    enabled: usesAccessibilityLayout,
                    minHeight: geometry.size.height))
                // SB-3 (REVIEW_2026-09-14_DESIGN.md): pins the transport row (play/pause +
                // skip glyphs) above the home indicator at accessibility sizes, where the
                // column above (now scrollable, see `AccessibilityScrollColumn` right above)
                // can genuinely grow taller than the screen — without this, play/pause was
                // just another row in that scroll and could end up below the fold, exactly
                // what a low-vision/VoiceOver user can least afford to hunt for. A no-op —
                // literally `content` — below `.accessibility3`, so nothing here changes the
                // default layout `AccessibilityScrollColumn` already leaves untouched.
                .modifier(PinnedAccessibilityTransport(
                    enabled: usesAccessibilityLayout,
                    controls: { pinnedTransportBar(in: geometry) }))
                // iPhone Duo (§4): read here, from the `GeometryReader` that positions the
                // column, so the fold's frame and the panes share one coordinate space
                // (Apple, `ReservedRegion`). Nil, and so a no-op, without an active fold.
                // `backgroundView` above, the header menu overlay and `dismissDrag`'s
                // offset below are outside it and unaffected.
                .modifier(PlayerFoldLayout(fold: PlayerFold.current(in: geometry)) { fold in
                    foldedPlayerLayout(fold, in: geometry)
                })
            }
            .overlay(alignment: .topTrailing) {
                playerHeaderMenu
                    .padding(.top, 8)
                    // H4 (REVIEW_2026-09-04_UI.md Pass 3): named, not a literal — see
                    // `headerMenuReservedTrailingWidth` for why the drag handle reserves
                    // its trailing space by reading this same constant.
                    .padding(.trailing, Self.headerMenuButtonTrailingPadding)
            }
            .offset(y: dragOffset)
        }
        // HIG audit 2026-09-17 M9: VoiceOver has no built-in escape gesture on a custom
        // full-screen overlay (this is a ZStack, not a `.sheet`, so it doesn't get the
        // system's two-finger-scrub-to-dismiss for free). Routes through the exact same
        // `dismissFullPlayer()` the drag handle's tap uses, in `PlayerView+Header.swift`.
        .accessibilityAction(.escape) { dismissFullPlayer() }
        // iOS 26/27 Liquid Glass polish pass (26 August 2026): these three sheets had
        // no `.presentationDetents`/`.presentationDragIndicator` at all (unlike
        // `SpeedSheet` in `PlayerView+Sheets.swift`, which already sets both) — meaning
        // they only ever opened as a full-height modal with no partial-height peek or
        // drag affordance. `[.medium, .large]` matches the same two-height pattern
        // Apple's own Podcasts/Music chapter and queue sheets use. Deliberately did NOT
        // add `.presentationBackground(.thinMaterial)` here — each sheet's own root
        // (`QueueSheet`/`ChapterListSheet`/`BookmarksSheet`, in `PlayerView+Sheets.swift`)
        // paints an opaque `Color.shelfBackground.ignoresSafeArea()` behind its content, so a
        // translucent presentation background would sit invisibly underneath that
        // fill rather than actually showing through — adding it would be dead code
        // that looks like glass but isn't. Making these sheets genuinely translucent
        // would mean removing that opaque fill too, a real visual change to how
        // legible list content reads over whatever's behind the sheet, which needs
        // on-device verification rather than a guess.
        .sheet(isPresented: $showQueue) {
            QueueSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showChapterSkip) {
            if let book = playerViewModel.currentBook {
                ChapterSkipSheet(itemId: book.id, bookTitle: book.title)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showTranscriptSearch) {
            if let book = playerViewModel.currentBook {
                TranscriptSearchSheet(itemId: book.id, bookTitle: book.title, chapters: playerViewModel.chapters,
                                      onSelect: { time in playerViewModel.seek(to: time, reason: .search) })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .task(id: "\(playerViewModel.currentBook?.id ?? "")|\(playerViewModel.chapters.count)|\(playerViewModel.duration > 0)") {
            chapterSuggestionsOffered = ChapterSuggestionContext.make(playerViewModel: playerViewModel)?.isOffered ?? false
        }
        // Batch 426: quote clips. The editor closes first, then the composer opens (two sheets
        // can't be up at once on this view), hence the short hand-off delay.
        .sheet(isPresented: $showBookClub) {
            if let book = playerViewModel.currentBook {
                BookClubView(item: book, chapters: playerViewModel.chapters,
                             myPositionSeconds: playerViewModel.currentTime, isFinished: false, startComposing: true)
            }
        }
        .sheet(isPresented: $showClipEditor) {
            if let book = playerViewModel.currentBook {
                ClipEditorSheet(itemId: book.id, bookTitle: book.title, onShare: { quote, attribution, audioURL in
                    showClipEditor = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        await presentShare(quote: quote, quoteIsPassage: true, quoteAttribution: attribution,
                                           attachments: audioURL.map { [$0] } ?? [])
                    }
                })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        // Batch 428: on-device recap and "what did I just miss".
        .sheet(isPresented: $showRecap) {
            if let book = playerViewModel.currentBook {
                RecapSheet(itemId: book.id, title: book.title, author: book.authorName)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showZonedOut) {
            if let book = playerViewModel.currentBook {
                ZonedOutSheet(itemId: book.id)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showXRay) {
            if let book = playerViewModel.currentBook {
                XRaySheet(itemId: book.id, title: book.title)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showAskBook) {
            if let book = playerViewModel.currentBook {
                AskBookSheet(itemId: book.id, title: book.title, author: book.authorName)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showReadAlong) {
            if #available(iOS 26.0, *), let book = playerViewModel.currentBook {
                EbookReaderView(item: book, followsPlayback: true)
            }
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBookmarks) {
            // Y2 (REVIEW_2026-09-04_UI.md): close Bookmarks first, then open the share
            // composer with the note as the Quote card's text.
            BookmarksSheet(onShareNote: { bookmark in
                showBookmarks = false
                Task { await presentShare(quote: bookmark.title) }
            })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showDrivingMode) {
            DrivingModeView()
                .environment(playerViewModel)
        }
        .sheet(isPresented: $showBookDetails) {
            if let book = playerViewModel.currentBook {
                // UI-10: presented as a sheet, so BookDetailView needs to know to
                // dismiss itself before asking the (ZStack-overlay, not sheet) full
                // player to show — see that flag's doc comment.
                NavigationStack { BookDetailView(item: book, isPresentedModally: true) }
            }
        }
        .sheet(item: $shareSession) { session in
            ShareComposerSheet(context: session.context, attachments: session.attachments)
        }
        .statusBarHidden(false)
        // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10): donates to `CassetteFlipTip`
        // on every full-player open (its rule fires once the count reaches 2, i.e.
        // the *second* open — the first is for getting oriented).
        .onAppear {
            CassetteFlipTip.playerOpenCount += 1
        }
        // Donates real elapsed minutes to `DrivingModeTip` — a `.task` rather than a
        // manually-managed `Timer` so it's automatically cancelled the instant this
        // view disappears (dismissing the player), with no separate cleanup call
        // needed. Only accumulates while this screen is open AND actually playing;
        // time spent playing via the mini-player alone doesn't count toward this
        // particular tip, since its own trigger point (the ellipsis menu) only
        // exists here. **[device check]**: no simulator to confirm the 60s cadence
        // feels right or that this doesn't measurably affect battery over a long
        // session — sleeping for 60s at a time between checks should be cheap, but
        // that's an assumption, not a measurement.
        .task {
            // Code review fix (26 August 2026), take 2: the first fix here stopped the
            // loop once `minutesPlayedLifetime` (then still named `minutesPlayedThisSession`)
            // hit its own threshold, but missed that opening Driving Mode retires the tip
            // (`DrivingModeTip().invalidate(reason:)`, in `playerHeaderMenu`, now in
            // `PlayerView+Header.swift`) independently of that counter — someone who
            // opens Driving Mode at minute 5
            // had a retired tip and a loop that kept writing to TipKit's persisted
            // datastore for another ~15 minutes, for a tip that could no longer be shown.
            // `drivingModeOpened` closes that: set the instant Driving Mode is opened,
            // checked here too.
            while !Task.isCancelled && !DrivingModeTip.drivingModeOpened && DrivingModeTip.minutesPlayedLifetime < 20 {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                if playerViewModel.isPlaying {
                    DrivingModeTip.minutesPlayedLifetime += 1
                }
            }
        }
    }
}

// MARK: - iPhone Duo folded layout

extension PlayerView {
    /// iPhone Duo (§4): the player while the device is partly folded. The same pieces as the
    /// flat column, in the same order, cut at the fold so nothing straddles it — Apple:
    /// "move only what's necessary… favor small adjustments over rearrangement". Each pane
    /// is sized to its own side with the fold's width (or height) left clear between them.
    ///
    /// - Folded like a book (the fold runs top to bottom): the cover alone on the leading
    ///   side, centred; the drag handle, title, scrubber, transport and the status/tool rows
    ///   on the trailing side, bottom-anchored as in the flat column. The ••• menu overlay
    ///   (top trailing, outside this) lands above that pane, beside the handle, as it does
    ///   on a flat screen.
    /// - Folded like a laptop (the fold runs across): the flat column cut after the title —
    ///   handle, cover and title above the fold (the cover still the flexible element),
    ///   scrubber, transport and the status/tool rows below it.
    ///
    /// The status line (sleep, "Jump back", Up Next) stays in `bottomGlassRegion`, so it
    /// always sits wholly inside the controls pane, never across the fold. At accessibility
    /// sizes the controls pane scrolls with its transport pinned, exactly like the flat
    /// column (`AccessibilityScrollColumn` / `PinnedAccessibilityTransport`); the cover's
    /// pane never scrolls, so it always takes the flexible artwork slot.
    @ViewBuilder
    func foldedPlayerLayout(_ fold: PlayerFold, in geometry: GeometryProxy) -> some View {
        let size = geometry.size
        let panes = fold.panes(in: size)
        if fold.runsVertically {
            HStack(spacing: 0) {
                // The cover's side. The slot is given the height of the cover it will draw
                // (plus the slot's own 8pt top padding and the cassette's extra height), then
                // centred, because the flexible slot top-aligns its cover.
                let cassetteChrome: CGFloat = showsCassetteShell ? CassetteView.extraHeightBeyondWidth : 0
                let coverSide = max(0, min(306, panes.first - 48, size.height - 48 - cassetteChrome - 8))
                artworkSlot(in: geometry, alwaysFlexible: true)
                    .frame(height: coverSide + cassetteChrome + 8)
                    .padding(.horizontal, 24)
                    .frame(width: panes.first)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissDrag)

                // The fold itself: kept clear.
                Color.clear
                    .frame(width: panes.gap)
                    .accessibilityHidden(true)

                foldedControlsPane(columnWidth: panes.second - 48,
                                   bottomInset: geometry.safeAreaInsets.bottom,
                                   paneHeight: size.height,
                                   includesHeader: true)
                    .frame(width: panes.second)
            }
        } else {
            VStack(spacing: 0) {
                // Above the fold: the top of the flat column, unchanged in order.
                VStack(spacing: 0) {
                    foldedDragHandleStrip

                    artworkSlot(in: geometry, alwaysFlexible: true)
                        .contentShape(Rectangle())
                        .simultaneousGesture(dismissDrag)

                    bookInfoView
                        .padding(.top, 14)
                        .contentShape(Rectangle())
                        .simultaneousGesture(dismissDrag)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .frame(height: panes.first)

                Color.clear
                    .frame(height: panes.gap)
                    .accessibilityHidden(true)

                // Below the fold: the rest of the flat column.
                foldedControlsPane(columnWidth: min(size.width, 600) - 48,
                                   bottomInset: geometry.safeAreaInsets.bottom,
                                   paneHeight: panes.second,
                                   includesHeader: false)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                    .frame(height: panes.second)
            }
        }
    }

    /// iPhone Duo (§4): the controls side of the fold. With `includesHeader` (book posture)
    /// it carries the drag handle and title too, bottom-anchored under the handle the way
    /// the flat column's flexible cover pushes them down; without it (laptop posture) it is
    /// the scrubber, transport and status/tool rows, centred in the room below the fold.
    private func foldedControlsPane(columnWidth: CGFloat,
                                    bottomInset: CGFloat,
                                    paneHeight: CGFloat,
                                    includesHeader: Bool) -> some View {
        VStack(spacing: 0) {
            if includesHeader {
                foldedDragHandleStrip
                Spacer(minLength: 0)
                bookInfoView
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissDrag,
                                         including: usesAccessibilityLayout ? .subviews : .all)
            }

            PlayerProgressSection(showsCaptions: !hideProgressCaptions)
                .padding(.top, includesHeader ? 18 : 0)

            if !usesAccessibilityLayout {
                controlsView(columnWidth: columnWidth)
                    .padding(.top, 22)
            }

            bottomGlassRegion
        }
        .padding(.horizontal, 24)
        // The flat column's home-indicator clearance applies to whichever pane reaches the
        // bottom edge, which is the controls pane in both postures.
        .padding(.bottom, max(bottomInset, 16))
        .frame(maxHeight: .infinity)
        .modifier(AccessibilityScrollColumn(
            enabled: usesAccessibilityLayout,
            minHeight: paneHeight))
        .modifier(PinnedAccessibilityTransport(
            enabled: usesAccessibilityLayout,
            controls: { pinnedTransportBar(columnWidth: columnWidth) }))
    }
}

#Preview {
    PlayerView()
        .environment(PlayerViewModel())
}
