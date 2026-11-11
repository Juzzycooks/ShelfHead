import SwiftUI
import TipKit

// MARK: - Theme-aware elevation (D4, design brief 2026-08-12)

/// How strongly a surface should read as "raised."
enum ShelfElevation {
    /// A card/panel resting on the background — the common case.
    case card
    /// A smaller floating control (a badge, a chip) — a lighter touch than `.card`.
    case floating
}

extension View {
    /// Elevation that reads correctly in both themes: a soft shadow on dark grounds, a
    /// hairline border on light ones. A drop shadow on Light theme's warm-paper
    /// background tends to read as grime rather than depth (unlike a genuine floating
    /// element like the mini-player pill above, most card/panel surfaces in this app sit
    /// flush against the page) — a border communicates the same "this is a distinct
    /// surface" idea without that problem. Takes the shape explicitly so the light-mode
    /// border can match the surface's own corner radius/capsule/circle.
    @ViewBuilder
    ///
    /// Critique 2026-10-05 (shared tiles, 2nd): `shadowFromShape` (default `false`, so
    /// every existing call site is unchanged). The default `.shadow` is applied to the
    /// whole content, so on a translucent fill the shadow shows through under the text.
    /// With `true` the Dark shadow is cast by the shape only and masked out beneath it,
    /// so nothing darkens the surface itself. Light's hairline is identical either way.
    func shelfElevation<S: InsettableShape>(_ level: ShelfElevation = .card, in shape: S,
                                            shadowFromShape: Bool = false) -> some View {
        modifier(ShelfElevationModifier(level: level, shape: shape, shadowFromShape: shadowFromShape))
    }
}

private struct ShelfElevationModifier<S: InsettableShape>: ViewModifier {
    let level: ShelfElevation
    let shape: S
    var shadowFromShape: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// Dark-theme shadow parameters; nil in Light (hairline instead).
    private var darkShadow: (opacity: Double, radius: CGFloat, y: CGFloat)? {
        switch (level, colorScheme) {
        case (.card, .dark): return (0.35, 12, 6)
        case (.floating, .dark): return (0.2, 8, 3)
        default: return nil
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let s = darkShadow {
            if shadowFromShape {
                content.background {
                    shape.fill(Color.black)
                        .shadow(color: .black.opacity(s.opacity), radius: s.radius, y: s.y)
                        .mask {
                            // Everything except the shape's own footprint, so only the
                            // outer shadow survives and the fill never tints the content.
                            Rectangle().padding(-60)
                                .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                }
            } else {
                content.shadow(color: .black.opacity(s.opacity), radius: s.radius, y: s.y)
            }
        } else {
            content.overlay(shape.strokeBorder(Color.shelfCream.opacity(0.22), lineWidth: 1))
        }
    }
}

// MARK: - Liquid Glass helper

extension View {
    /// Applies iOS 26's native Liquid Glass in the given shape, falling back to a
    /// translucent `.ultraThinMaterial` pill (with stroke + shadow) on iOS 17–25.
    ///
    /// `interactive` controls whether the glass reacts to touch (Apple's guidance is that
    /// `.interactive()` belongs only on real controls — on a read-only surface the
    /// highlight/deformation on press advertises a tap target that does nothing). This
    /// used to be unconditional for all eight call sites, including two that can't be
    /// touched at all: the transient toast, and the scrubber's "PRECISE" badge, which
    /// carries an explicit `.allowsHitTesting(false)`. Defaults to `true` so the six
    /// genuine controls (mini-player card, tab item, the player's chips and menu button)
    /// keep exactly the behaviour they had.
    @ViewBuilder
    func glassPill<S: InsettableShape>(_ shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.clipShape(shape)
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                // D4 (design brief 2026-08-12): was 0.12 — roughly a 1.1:1 edge against
                // `shelfBackground` in Light theme, i.e. no visible boundary at all on
                // iOS ≤25's mini-player pill. Raised to 0.25, which still reads as a
                // hairline in Dark theme but is now actually visible in Light.
                .overlay(shape.strokeBorder(Color.shelfCream.opacity(0.25), lineWidth: 1))
                .clipShape(shape)
                // Kept in both themes: this is a floating pill casting a shadow onto
                // whatever's behind it, which is a normal elevation cue regardless of
                // page brightness — unlike the amber "glow" effects elsewhere in the
                // app, a plain dark drop shadow isn't dark-theme-specific.
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
    }
}

// MARK: - Cassette Reel (spins while playing)

struct CassetteReel: View {
    var spinning: Bool
    var size: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Honour Reduce Motion: hold the reel still rather than spinning continuously.
        let animate = spinning && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate * 60  // ~60°/sec
            reel.rotationEffect(.degrees(animate ? degrees : 0))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var reel: some View {
        ZStack {
            Circle().fill(Color.shelfSurface)
            Circle().strokeBorder(Color.shelfCream.opacity(0.25), lineWidth: 2)
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(Color.shelfCream.opacity(0.45))
                    .frame(width: 3, height: size * 0.30)
                    .offset(y: -size * 0.17)
                    .rotationEffect(.degrees(Double(i) / 6 * 360))
            }
            Circle().fill(Color.shelfCream.opacity(0.85)).frame(width: size * 0.20, height: size * 0.20)
        }
        // A tape reel is a dark physical object; keep its dark shell + cream spokes
        // in both themes rather than inverting under the light theme.
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Cassette body framing the cover art

struct CassetteView: View {
    let coverURL: URL?
    var spinning: Bool
    /// Matches the caller's `.frame(maxWidth: 306)` in `PlayerView.coverArtView()`.
    /// Fixed after user testing ("cassette player cuts off at the bottom"): this used
    /// to rely on `.fixedSize(horizontal: false, vertical: true)` to size itself from
    /// its own intrinsic content height (cover + reel window). That measurement isn't
    /// reliable for this exact combination — a conditionally-swapped, `.transition`-
    /// animated subtree (`if showsCassette { CassetteView } else { ... }`) nested inside
    /// a `ScrollView`'s content — so the shell was sometimes laid out shorter than its
    /// real content, clipping the reel window and the shell's own bottom edge. Taking
    /// the width explicitly and computing the height directly (below) removes that
    /// measurement step from this view's OWN sizing — but still left one more: after
    /// this fix, the clipping persisted, because the caller's shared `ZStack` (holding
    /// `if showsCassette { CassetteView } else { CachedCover }`) only ever contains
    /// ONE of the two branches at a time, so its own reported size still tracked
    /// whichever branch is currently active — meaning the container itself could still
    /// be the plain cover's shorter (306×306) box in the instant right after switching
    /// to cassette mode, before that box catches up to this view's real height. See
    /// `PlayerView.coverArtView()`, which now reserves `CassetteView.height(forWidth:)`
    /// worth of space UNCONDITIONALLY (regardless of which branch is showing) to close
    /// that gap for good.
    var width: CGFloat = 306

    private static let coverHorizontalPadding: CGFloat = 14
    private static let coverTopPadding: CGFloat = 14
    private static let contentSpacing: CGFloat = 12
    private static let reelWindowHeight: CGFloat = 60
    private static let reelWindowBottomPadding: CGFloat = 16

    /// The exact height this view renders at for a given `width` — `static` (not just
    /// an instance property) so `PlayerView.coverArtView()` can reserve the right
    /// amount of layout space for this view WITHOUT needing an actual instance of it,
    /// which matters because it needs that number even while the plain-cover branch
    /// (not this one) is what's currently on screen.
    static func height(forWidth width: CGFloat) -> CGFloat {
        let coverSide = max(0, width - coverHorizontalPadding * 2)
        return coverTopPadding + coverSide + contentSpacing + reelWindowHeight + reelWindowBottomPadding
    }

    /// `height(forWidth:)` is affine in `width` above zero (a square cover plus a fixed
    /// amount of chrome above/below it) — exposing that fixed amount directly lets a
    /// caller solve for the WIDTH that fits a given height *budget* (e.g.
    /// `PlayerView.coverArtView(artworkSize:)`, which needs to know how much of a
    /// vertical allowance the reel window + paddings eat into before the square cover
    /// even starts) without duplicating this view's padding constants itself.
    static var extraHeightBeyondWidth: CGFloat { height(forWidth: 0) }

    var body: some View {
        let coverSide = max(0, width - Self.coverHorizontalPadding * 2)
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color.cassetteShellTop, Color.cassetteShellBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                )
                // Soft top bevel: a faint cream highlight along the upper edge reads
                // as a molded plastic casing without heavy skeuomorphism.
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(colors: [Color.shelfCream.opacity(0.10), .clear],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
                // D4 shadow audit: kept in both themes and NOT converted to
                // `shelfElevation` — this shell always renders inside its own forced
                // `.environment(\.colorScheme, .dark)` (below), so from this view's own
                // perspective it's permanently "dark theme" regardless of what the rest
                // of the app is doing. The shadow it casts onto whatever page is behind
                // it (light or dark) is the same "a physical object rests on the page"
                // cue in both cases, which is the deliberate reasoning already recorded
                // on the forced-dark environment modifier below.
                .shadow(color: .black.opacity(0.6), radius: 18, x: 0, y: 12)

            VStack(spacing: Self.contentSpacing) {
                // Printed label = the cover art
                ZStack {
                    CachedCover(url: coverURL)
                }
                .frame(width: coverSide, height: coverSide)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.shelfCream.opacity(0.18), lineWidth: 1))
                .padding(.horizontal, Self.coverHorizontalPadding)
                .padding(.top, Self.coverTopPadding)

                // Reel window
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.35))
                    HStack(spacing: 0) {
                        CassetteReel(spinning: spinning)
                        Spacer()
                        // tape strip between reels
                        Rectangle().fill(Color.shelfCream.opacity(0.12)).frame(height: 6)
                        Spacer()
                        CassetteReel(spinning: spinning)
                    }
                    .padding(.horizontal, 26)
                }
                .frame(height: Self.reelWindowHeight)
                .padding(.horizontal, Self.coverHorizontalPadding)
                .padding(.bottom, Self.reelWindowBottomPadding)
            }
        }
        .frame(width: width, height: Self.height(forWidth: width))
        // The cassette is a dark physical object — keep its brown shell + cream detailing
        // in both themes (it reads as a gadget resting on the light page).
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Tape scrubber (D3, design brief 2026-08-12)
//
// Read this before touching the bars: they are a deterministic *texture*, not audio
// analysis. The app has never computed a loudness envelope and this does not either —
// heights come from a book-seeded xorshift PRNG (`waveformSeed`), so a given book always
// draws the same pattern and two books draw different ones, but nothing here corresponds
// to what the recording actually sounds like. A tall bar is not a loud passage.
//
// The history, so nobody re-litigates it from one side only. P-1
// (REVIEW_2026-09-14_DESIGN.md) argued that precisely because the pattern is stable per
// book it *looks* real enough to mislead, and Batch 318 replaced it with a plain 6pt rail
// + amber fill. The user then looked at that on device and asked for the waveform back:
// it is the look they want on Now Playing, with the caveat above understood and accepted.
// So this restores the visual only — the accessibility work that shipped alongside the
// rail (`accessibilityValueText`, spoken elapsed/remaining, the adjustable actions) and
// the real `chapterTicks`, now drawn as marks over the bars, both stay. If anyone ever
// does want this to be honest rather than decorative, the route is a coarse RMS pass at
// download time cached beside the file, feeding `barHeights` real numbers.
//
// Nothing about the gesture has changed through any of this: same direct-mapping drag
// math, same fine-scrub (PRECISE) mode, same 44pt hit target, same haptics, same Reduce
// Motion behaviour.
struct TapeScrubber: View {
    @Binding var value: Double                 // 0...1
    var onEditingChanged: (Bool) -> Void
    /// VoiceOver increment/decrement step, as a fraction of the bound range. Lets a
    /// caller give a chapterless multi-hour book a time-based step (e.g. ~30s) instead
    /// of a fixed 5%, which would mean a 36-minute jump per swipe on a 12-hour book.
    var accessibilityStepFraction: Double = 0.05
    /// Chapter-boundary marks, as 0...1 fractions of whatever range this scrubber
    /// currently represents — chapter-relative when the book has chapters, whole-book
    /// otherwise (see `PlayerProgressSection` in `PlayerView.swift`, which binds this).
    /// The caller decides what the range is and converts; this view only draws them.
    /// Empty by default, which is also the normal case for a chapter-scoped scrubber:
    /// a single chapter's interior contains no other chapter's boundary.
    var chapterTicks: [Double] = []
    /// Seeds the deterministic bar texture drawn behind the playhead — same book, same
    /// pattern, forever; different books, different patterns. Explicitly *not* audio
    /// analysis (see this section's note above). Defaults to `0`, which is a perfectly
    /// valid seed and just draws one fixed pattern — the right answer for a caller that
    /// has no book to key off.
    var waveformSeed: UInt64 = 0
    /// P-3 (REVIEW_2026-09-14_DESIGN.md): what VoiceOver should read out as this
    /// control's value — e.g. "12 minutes 44 seconds, 2 minutes 28 seconds remaining".
    /// `nil` falls back to the old percentage announcement, which is the honest default
    /// for a caller that genuinely has no time to report.
    var accessibilityValueText: String?

    // Rewritten from scratch (17 Aug 2026) after two rounds of drag-math bugs (see
    // CHANGES_IMPLEMENTED.md Batches 206/209) still left the scrubber feeling
    // "glitchy" and visibly worse than the waveform look from older builds. Researched
    // standard SwiftUI scrubber/slider implementations before rewriting: the
    // recommended, drift-free approach is to map `value` directly from the touch's
    // *absolute* position (`location.x / width`) every frame, not by accumulating
    // `.translation` deltas — translation is relative to the gesture's start point, so
    // any accumulation scheme (this file had two, both buggy) can drift out of sync
    // with the finger over a long drag. Direct mapping has no running state to drift:
    // wherever your finger is horizontally *is* the value, full stop, so "the scrubber
    // doesn't match where my finger goes" isn't structurally possible any more.
    @State private var isEditing = false
    @State private var isFineScrubbing = false
    /// Batch 490 (REVIEW 2026-11-11 V8): the knob casts its shadow in Dark only.
    @Environment(\.colorScheme) private var colorScheme
    /// Fine-scrub (precision mode) can't use direct mapping — the whole point is that
    /// physical finger movement should translate to a *smaller* value change. It's
    /// anchored instead: `anchorValue`/`anchorLocationX` capture where the knob and
    /// finger were the instant fine mode engaged, and further movement is added on
    /// top of that anchor at a fixed (not continuously-changing) gain. Re-anchoring
    /// only at the engage/disengage transition — never per-frame — is what avoids the
    /// retroactive-rescaling bug both previous versions had.
    @State private var anchorValue: Double = 0
    @State private var anchorLocationX: CGFloat = 0
    /// Bug fix (17 Aug 2026): vertical offset for fine-scrub used to be measured from
    /// the geometric center of this control (`geo.size.height / 2`) — but the control
    /// is only 44pt tall, so a thumb resting anywhere near its top or bottom edge (very
    /// normal; thumbs are wider than that) already started partway toward the 60pt
    /// threshold before moving at all, and any further natural vertical drift during a
    /// fast, deliberate seek swipe crossed it easily — "PRECISE" and the slowdown
    /// kicking in on what the user experienced as an ordinary scrub. Measuring from
    /// *where the touch actually started* instead only responds to real, deliberate
    /// further vertical movement, regardless of where within the control the touch
    /// happened to land.
    @State private var touchStartY: CGFloat = 0
    /// Tracks whether the last drag position was pinned at an edge (0 or 1), so the
    /// "chapter boundary" haptic below fires once on the transition rather than on
    /// every frame the drag continues to sit at that edge.
    @State private var wasAtEdge = false

    /// VD-6 (docs/design-review.md, Round 6): cache for `barHeights(seed:)`. `value`
    /// (and therefore `body`) re-evaluates roughly twice a second during playback, but
    /// the bar texture only ever depends on `waveformSeed`, which changes once per book —
    /// recomputing 44 bar heights on every tick was wasted work. `cachedSeed` starts
    /// `nil` so the very first render (before `.task` below has had a chance to run)
    /// always falls through to a synchronous recompute in `body`, rather than reading an
    /// empty/stale array and flashing a blank scrubber.
    @State private var cachedHeights: [CGFloat] = []
    @State private var cachedSeed: UInt64?

    /// Vertical distance (pt) from the touch's starting point before fine-scrub
    /// engages. Deliberately large and a fixed step (not a continuous function of
    /// offset, which is what made an earlier version misfire on ordinary,
    /// not-perfectly-horizontal swipes) — engaging only past a clear, deliberate
    /// "drag down" gesture.
    private let fineEngageThreshold: CGFloat = 60
    /// Must come back closer to the rail than the engage threshold before
    /// disengaging — a hysteresis gap so the mode doesn't flicker on/off right at the
    /// boundary.
    private let fineDisengageThreshold: CGFloat = 28
    private let fineGain: Double = 0.25

    /// Bar-texture geometry: 44 bars spanning the full width, 6…28pt tall. These are the
    /// numbers the look was tuned to on device. The bar count matching the 44pt hit-target
    /// frame below is a coincidence, not a relationship — changing one does not imply
    /// changing the other. Internal rather than private so the tests can pin them.
    static let barCount = 44
    static let minBarHeight: CGFloat = 6
    static let maxBarHeight: CGFloat = 28
    private let barSpacing: CGFloat = 2

    /// Deterministic bar heights for a seed: same seed in, same array out — every render,
    /// every launch, every process. Pure, so `PlayerScrubberFormattingTests` can pin it.
    ///
    /// xorshift64 rather than `SystemRandomNumberGenerator` because reproducibility is the
    /// entire point, and seeded by the caller rather than by `String.hashValue` because
    /// Swift seeds string hashing per process — the pre-318 call site passed
    /// `id.hashValue`, so the "stable per book" texture in fact redrew differently on
    /// every app launch. `waveformSeed(forBookID:)` below fixes that.
    static func barHeights(seed: UInt64, count: Int = TapeScrubber.barCount) -> [CGFloat] {
        // Zero is xorshift's fixed point — it maps to itself forever, which would draw 44
        // identical bars — so substitute a fixed non-zero constant for it.
        var state: UInt64 = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        return (0..<max(0, count)).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            // Top 53 bits → 0..<1: the standard way to pull a Double out of a 64-bit
            // integer generator without inheriting the low bits' weaker mixing.
            let unit = Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
            return minBarHeight + (maxBarHeight - minBarHeight) * CGFloat(unit)
        }
    }

    /// A stable seed for a book id. FNV-1a over the id's UTF-8 — unlike `hashValue` this is
    /// the same number in every process, so a book's texture survives an app relaunch.
    /// `nil`/empty (nothing playing) seeds 0, i.e. the default pattern.
    static func waveformSeed(forBookID id: String?) -> UInt64 {
        guard let id, !id.isEmpty else { return 0 }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    var body: some View {
        GeometryReader { geo in
            let railY = geo.size.height * 0.5
            let clamped = min(max(value, 0), 1)
            // VD-6: read the cache when it matches this render's seed; otherwise (first
            // render, or a seed change `.task` hasn't caught up to yet) recompute
            // synchronously so this frame is never wrong or blank. `barHeights` itself is
            // cheap per call — it's the every-tick *frequency* this avoids, not the cost
            // of any single call.
            let heights = cachedSeed == waveformSeed ? cachedHeights : Self.barHeights(seed: waveformSeed)
            ZStack {
                // The bar texture, amber up to the playhead and muted after it. Each bar
                // takes an equal share of exactly `geo.size.width`, which is the same
                // width the knob below measures its `geo.size.width * value` against —
                // that identity is load-bearing, and is what the old bar rendering got
                // wrong twice (a fixed-width `HStack` centred inside a wider container
                // while the knob positioned itself against the full width, so fill edge
                // and knob visibly disagreed).
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: barSpacing) {
                        ForEach(0..<Self.barCount, id: \.self) { index in
                            // A bar flips to amber once the playhead passes its *centre*,
                            // so the colour boundary lands under the knob rather than
                            // half a bar ahead of or behind it.
                            let played = (Double(index) + 0.5) / Double(Self.barCount) <= clamped
                            Capsule()
                                .fill(played ? Color.shelfAmber : Color.shelfMuted.opacity(0.3))
                                .frame(height: heights[index])
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: geo.size.width, height: Self.maxBarHeight)

                    // Chapter boundaries — real positions, unlike the bars behind them.
                    // Full bar height (not the old 6pt rail's), because a short tick
                    // drawn over 28pt bars reads as one more bar rather than as a mark;
                    // cream at 0.7 so it carries over both the amber and the muted runs.
                    // Usually empty for a chapter-scoped scrubber; see `chapterTicks`'
                    // doc comment. Keyed by position in the array, not by the `Double`
                    // itself: two chapters that share a start time (a zero-length
                    // chapter — real servers do ship these) would be one duplicate
                    // `ForEach` id.
                    ForEach(Array(chapterTicks.enumerated()), id: \.offset) { _, tick in
                        Rectangle()
                            .fill(Color.shelfCream.opacity(0.7))
                            .frame(width: 1.5, height: Self.maxBarHeight)
                            .offset(x: geo.size.width * CGFloat(min(max(tick, 0), 1)) - 0.75)
                    }
                }
                // Explicit width (not just a height) so the texture can't be handed a
                // different proposal by `.position` than the knob's own
                // `geo.size.width * value` maths assumes.
                .frame(width: geo.size.width, height: Self.maxBarHeight)
                .position(x: geo.size.width * 0.5, y: railY)
                .allowsHitTesting(false)

                // Playhead: a two-tone knob (amber ring + cream center) at the current
                // position, most visible while actively dragging.
                ZStack {
                    Circle().fill(Color.shelfAmber)
                    Circle().fill(Color.shelfCream).padding(3)
                }
                .frame(width: isEditing ? 18 : 14, height: isEditing ? 18 : 14)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                // Batch 490 (REVIEW 2026-11-11 V8): Paper Doesn't Cast — in Light the
                // knob keeps only the hairline stroke above, no drop shadow.
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0), radius: isEditing ? 5 : 3, y: 1)
                .position(x: geo.size.width * value, y: railY)
                .shelfAnimation(.easeOut(duration: 0.12), value: isEditing)
                .allowsHitTesting(false)

                // Fine-scrub indicator — an invisible mode is a confusing mode, so make
                // the reduced-gain state visible while it's engaged.
                if isFineScrubbing {
                    Text("PRECISE")
                        .scaledFont(11, weight: .bold, design: .rounded, relativeTo: .caption2)
                        .tracking(LocalizedText.tracking(1.2))
                        .foregroundStyle(Color.shelfAmberText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        // iOS 26/27 Liquid Glass polish pass (26 August 2026): matches
                        // the same `.ultraThinMaterial` → `glassPill()` swap made to
                        // PlayerView's floating chips, for the same reason (real
                        // Liquid Glass on 26+ instead of a manual material forever).
                        .glassPill(Capsule(), interactive: false)   // .allowsHitTesting(false) below
                        .position(x: min(max(geo.size.width * value, 30), geo.size.width - 30), y: railY - 22)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            // Polish pass (J3-7): the drag used to start at distance 0, so a touch that was
            // really a scroll (the player scrolls at accessibility sizes) grabbed the knob and
            // could leave it stuck mid-edit when the scroll cancelled the gesture. A small
            // minimum distance lets the scroll win; a plain tap still seeks through the
            // `SpatialTapGesture` below, and the commit still happens only on release.
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { tap in
                        guard !isEditing else { return }
                        Haptics.impact(.medium)
                        value = min(max(0, Double(tap.location.x / geo.size.width)), 1)
                        onEditingChanged(false)
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        if !isEditing {
                            isEditing = true
                            anchorValue = value
                            anchorLocationX = g.location.x
                            touchStartY = g.startLocation.y
                            Haptics.impact(.light)
                            onEditingChanged(true)
                        }
                        let verticalOffset = abs(g.location.y - touchStartY)
                        if !isFineScrubbing && verticalOffset >= fineEngageThreshold {
                            isFineScrubbing = true
                            anchorValue = value
                            anchorLocationX = g.location.x
                            // Code review fix (26 August 2026): this is the moment someone
                            // discovers fine-scrub on their own, by dragging down — exactly
                            // the behavior `FineScrubTip` exists to teach. Retiring the tip
                            // here the first time it happens means a self-discoverer never
                            // sees a tip for something they already found; see the donation
                            // fix in `.onEnded` below for the other half of this bug (the
                            // tip's own trigger count previously only advanced on scrubs
                            // that had *already* engaged fine-scrub, so the tip could only
                            // ever reach people who no longer needed it).
                            FineScrubTip().invalidate(reason: .actionPerformed)
                        } else if isFineScrubbing && verticalOffset <= fineDisengageThreshold {
                            isFineScrubbing = false
                        }

                        let newValue: Double
                        if isFineScrubbing {
                            // Anchored, fixed-gain relative movement — see the type's
                            // doc comment above for why this (and not direct mapping)
                            // is correct here.
                            let deltaX = Double(g.location.x - anchorLocationX)
                            newValue = min(max(0, anchorValue + (deltaX / geo.size.width) * fineGain), 1)
                        } else {
                            // Direct, stateless, drift-free: the value IS wherever the
                            // finger is horizontally.
                            newValue = min(max(0, Double(g.location.x / geo.size.width)), 1)
                        }
                        // "Chapter boundary" haptic: this scrubber is deliberately bound
                        // to chapter-relative progress when the book has chapters (see
                        // `PlayerProgressSection` in `PlayerView.swift`), not book-wide progress — a
                        // preserved, correct design decision — so a single drag can never
                        // cross into a *different* chapter. What it can do is reach the
                        // edge (0 or 1) of the current chapter's own range, which is that
                        // chapter's boundary with its neighbor. Fire once on the
                        // transition into an edge, not continuously while pinned there.
                        let atEdge = newValue <= 0.0001 || newValue >= 0.9999
                        if atEdge && !wasAtEdge { Haptics.selection() }
                        wasAtEdge = atEdge
                        value = newValue
                    }
                    .onEnded { _ in
                        // Code review fix (26 August 2026): this previously only counted
                        // a completed scrub toward `FineScrubTip.scrubCount` when
                        // `isFineScrubbing` was true — i.e. the tip's own rule
                        // (`scrubCount >= 3`) could only be satisfied by someone who had
                        // *already* used fine-scrub three times, which is exactly the
                        // group that never needs to be taught it. Count every completed
                        // scrub instead, so ordinary users who haven't discovered the
                        // gesture are the ones who reach the threshold and see the tip.
                        // Self-discoverers are covered separately by the `invalidate`
                        // call above, at the moment fine-scrub first engages.
                        FineScrubTip.scrubCount += 1
                        isEditing = false
                        isFineScrubbing = false
                        wasAtEdge = false
                        Haptics.impact(.medium)
                        onEditingChanged(false)
                    }
            )
        }
        // 44pt: the HIG hit-target minimum, and the height every layout on the player
        // has been measured against. It has survived both the P-1 rail rewrite and the
        // restoration of the bars unchanged — the graphic inside has been 6pt and 28pt
        // tall at different times; the touchable frame never moves.
        .frame(height: 44)
        // VD-6: populates `cachedHeights` off the render path whenever `waveformSeed`
        // changes (once per book, not once per tick). Runs on first appearance too, but
        // `body`'s synchronous fallback above already has the right heights by then —
        // this just brings the cache in sync so subsequent ticks can read it instead of
        // recomputing.
        .task(id: waveformSeed) {
            cachedHeights = Self.barHeights(seed: waveformSeed)
            cachedSeed = waveformSeed
        }
        // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10): shown once, after the
        // user's third fine-scrub this app lifetime (see `AppTips.swift`) — arrives
        // once fine-scrubbing is already a habit rather than on a screen they've
        // just met.
        .popoverTip(FineScrubTip())
        // VoiceOver: expose the scrubber as an adjustable control (the drag gesture alone
        // is invisible to assistive tech).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        // P-3 (REVIEW_2026-09-14_DESIGN.md): "38 percent" told a VoiceOver user nothing
        // they could act on — the whole point of the readout is *how much time*. The
        // caller already formats both halves for the counters right beneath this control,
        // so it passes the spoken version straight through rather than this view
        // reinventing a duration formatter it has no seconds to feed.
        .accessibilityValue(accessibilityValueText ?? String(localized: "\(Int((value * 100).rounded())) percent", comment: "VoiceOver value for the playback scrubber; %lld is the percentage through the book"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + accessibilityStepFraction)
            case .decrement: value = max(0, value - accessibilityStepFraction)
            @unknown default: return
            }
            onEditingChanged(false)
        }
    }
}

// MARK: - Book position rail (D3, design brief 2026-08-12)

/// A slim, non-interactive whole-book orientation strip shown beneath the (chapter-scoped)
/// `TapeScrubber` when a book has chapters — the scrubber already gives chapter-level
/// precision; what's missing without this is book-level orientation (where am I overall,
/// where are the chapter edges). Purely a display: the scrubber above it is the control.
struct BookPositionRail: View {
    let chapters: [Chapter]
    let duration: Double
    /// Whole-book 0...1 (not chapter-relative — that's what makes this complementary to
    /// the scrubber rather than a duplicate of it).
    let progress: Double
    let currentChapter: Chapter?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.shelfMuted.opacity(0.14))

                // Current chapter's span, subtly brighter than the rest of the rail.
                if duration > 0, let chapter = currentChapter {
                    let startX = width * CGFloat(min(max(chapter.start / duration, 0), 1))
                    let endX = width * CGFloat(min(max(chapter.end / duration, 0), 1))
                    Rectangle()
                        .fill(Color.shelfCream.opacity(0.12))
                        .frame(width: max(0, endX - startX))
                        .offset(x: startX)
                }

                Capsule().fill(Color.shelfAmber.opacity(0.6))
                    .frame(width: max(0, width * CGFloat(min(max(progress, 0), 1))))

                // Chapter tick marks. Skipped above 80 chapters — at that density they'd
                // merge into a solid line rather than reading as discrete marks.
                if duration > 0, chapters.count <= 80 {
                    ForEach(chapters) { chapter in
                        Rectangle()
                            .fill(Color.shelfCream.opacity(0.4))
                            .frame(width: 1)
                            .offset(x: width * CGFloat(min(max(chapter.start / duration, 0), 1)))
                    }
                }
            }
        }
        .frame(height: 3.5)
        .clipShape(Capsule())
        // Non-interactive and not a duplicate announcement: the counters/labels around
        // it already convey this information to VoiceOver in words (current chapter,
        // time elapsed/remaining), so a non-interactive visual rail with no further
        // detail to add would just be noise if it were exposed too.
        .accessibilityHidden(true)
    }
}

// MARK: - Now-playing equalizer badge

/// Small animated equalizer used to mark the currently-playing item in lists/grids.
/// Holds still (staggered static bars) when not animating or under Reduce Motion.
struct EqualizerBadge: View {
    var animating: Bool
    var color: Color = .white
    var barCount: Int = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = animating && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(0..<barCount), id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: barHeight(i: i, t: t, active: active))
                }
            }
            .frame(height: 16, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(i: Int, t: TimeInterval, active: Bool) -> CGFloat {
        let maxH: CGFloat = 16, minH: CGFloat = 4
        guard active else {
            let staticHeights: [CGFloat] = [10, 5, 14, 8]
            return staticHeights[i % staticHeights.count]
        }
        let phase = Double(i) * 0.7
        let v = (sin(t * 6 + phase) + 1) / 2   // 0...1
        return minH + (maxH - minH) * CGFloat(v)
    }
}

// MARK: - Cassette-styled cover tile (for grids & shelves)

struct CassetteTile: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    var progress: Double = 0
    /// Critique 2026-10-05 (shared tiles): true for a finished book. Draws a small teal
    /// check badge at the cover's top-leading corner (the download badge owns
    /// top-trailing, so they never collide), hides the progress hairline, and adds
    /// "finished" to the VoiceOver label.
    var isFinished: Bool = false
    var downloaded: Bool = false
    /// 0...1 while a download is in flight; nil when not downloading.
    var downloadProgress: Double? = nil
    /// True when this tile is the currently-loaded book (shows a now-playing badge).
    var isNowPlaying: Bool = false
    /// Whether that book is actively playing (animates the badge).
    var isPlaying: Bool = false
    /// Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §4.1c): true when this tile is
    /// rendering inside Library's Compact grid density. At a ~100pt cover, the
    /// text block below is proportionally much larger relative to the tile (27% of
    /// tile height vs. 19% at Comfortable's ~168pt cover, per the proposal's own
    /// arithmetic) — so Compact drops the title to one line without
    /// `reservesSpace` and hides the subtitle entirely, roughly halving that block,
    /// instead of reserving the same fixed two-line-plus-subtitle space a much
    /// smaller cover can't visually support.
    var compact: Bool = false
    /// Library multi-select (plan 2026-10-05 §3.2): nil = not selecting (every existing
    /// caller). When set, the cover gets a checkmark-circle overlay at its bottom-trailing
    /// corner (the finished and download badges own the top corners), unselected tiles dim,
    /// and VoiceOver gets the selected trait plus a select/deselect hint.
    var selectionState: SelectionState? = nil

    enum SelectionState: Equatable {
        case unselected
        case selected
    }

    // Critique 2026-10-05 (shared tiles, 2nd): badge glyphs were fixed 15/16pt. They now
    // scale with Dynamic Type through a @ScaledMetric (DESIGN.md's sanctioned hardware
    // exception), capped so they stay small and inside even a ~100pt Compact cover.
    @ScaledMetric(relativeTo: .caption) private var badgeGlyphMetric: CGFloat = 15
    private var badgeGlyphSize: CGFloat { min(badgeGlyphMetric, 22) }
    // Critique 2026-10-05 (shared tiles): the subtitle used a 10pt `@ScaledMetric`
    // (below the 11pt floor, and off-token). It now renders through `Typo.fine`
    // (Caption 2, 11pt). The AX1 clamp on the caption block below is kept as-is so
    // grids stay usable at accessibility sizes.

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // D1b (design brief 2026-08-12): the tape band used to be a `ZStack` overlay
            // sitting *on top of* the cover, permanently occluding 12-16% of every tile's
            // artwork (24pt of a ~150-200pt tile). Moved to a sibling beneath the cover
            // instead — the full square cover now renders uncropped and unoccluded, with
            // the band as its own strip underneath. (HL-2, 30 September 2026: the band is
            // an overlay on the cover's bottom edge again, but only for the playing tile,
            // so every tile keeps the same height; see below.)
            //
            // Stage 5 (REDESIGN_PROPOSAL_2026-08-26.md §11): D1b fixed the band
            // *occluding* the cover; it didn't fix the band being pure decoration —
            // identical, unconditional, on every tile in every grid and shelf,
            // regardless of state. §11's governing rule is "tape hardware appears
            // only where audio is actually moving," so this reverses Batch 218/R10.12
            // (which kept the band as brand signature): the band is now this tile's
            // own signal that it's the one actually playing, spinning while it is,
            // rather than wallpaper under two hundred tiles. This is a deliberate
            // revisit of a decision `DESIGN_DIRECTION.md:114-119` explicitly logged as
            // settled — flagged rather than silently overridden, per this project's
            // own ground rules for touching a prior logged decision.
            // HL-2 (V3, 30 September 2026): the now-playing reel band is drawn over the
            // bottom of the cover (inside the shared clip) instead of stacked below it, so
            // the playing tile keeps the same square footprint as its neighbours and the
            // covers and titles in a row keep one baseline.
            CachedCover(url: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottom) {
                // Code review fix (26 August 2026): this band was gated on
                // `isNowPlaying && isPlaying`, so in a `LazyVGrid`/`LazyHStack` the
                // playing tile's row height changed by 14pt on every pause/resume,
                // shifting every row below it (and, on Home's shelf, nudging the
                // sections beneath). Gate the reserved space on `isNowPlaying` alone —
                // stable for as long as this tile IS the now-playing one, regardless of
                // transport state — and only spin the reel hubs (vs. sitting static)
                // when `isPlaying`, mirroring `EqualizerBadge`'s own established
                // "static when not animating" pattern just below.
                    // Critique 2026-10-05 (shared tiles): tape hardware only where audio is
                    // moving, so the band shows only while actually playing. It is an
                    // overlay (no height reservation, see HL-2 above), so hiding it on
                    // pause causes no layout shift; the 26 August note above predates HL-2.
                    // Critique 2026-10-05 (shared tiles, 2nd): the listening-progress
                    // hairline used to be a sibling row under the cover, so in-progress
                    // tiles were ~10pt taller than their neighbours and LazyVGrid rows
                    // centre-misaligned. It is now drawn inside the cover clip on the
                    // bottom edge (progress is real state, so an overlay is sanctioned by
                    // DESIGN.md). Every tile is the same height. When the reel band is
                    // showing, the line sits directly above it (stacked, never overlapping).
                    VStack(spacing: 0) {
                        if Self.showsProgressLine(progress: progress, isFinished: isFinished) {
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.45))
                                GeometryReader { geo in
                                    Rectangle().fill(Color.shelfAmber)
                                        .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                                }
                            }
                            .frame(height: 3)
                        }
                        if Self.showsReelBand(isNowPlaying: isNowPlaying, isPlaying: isPlaying) {
                            HStack(spacing: 6) {
                                CassetteTileReelHub(spinning: isPlaying)
                                Rectangle().fill(Color.shelfCream.opacity(0.25)).frame(height: 3)
                                CassetteTileReelHub(spinning: isPlaying)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 14)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.5))
                        }
                    }
                }
            // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 8pt radius → `Radius.chip`.
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color.shelfCream.opacity(0.14), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                // Critique 2026-10-05 (shared tiles): real-state finished mark.
                if isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: badgeGlyphSize))
                        .foregroundStyle(Color.shelfAccentText)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let dl = downloadProgress {
                    // In-progress download ring (amber = active state).
                    ZStack {
                        Circle().stroke(Color.shelfCream.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.02, min(dl, 1)))
                            .stroke(Color.shelfAmber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: badgeGlyphSize, height: badgeGlyphSize)
                    .padding(6)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(5)
                } else if downloaded {
                    // Cream keeps the badge legible without competing with the
                    // amber progress bar for attention (amber = active state only).
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: badgeGlyphSize))
                        .foregroundStyle(Color.shelfCream.opacity(0.9))
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let selectionState {
                    // Fill-or-Text: amber is the fill of the selected mark; unselected is a
                    // cream outline on a dark scrim so it reads on any cover.
                    Image(systemName: selectionState == .selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: badgeGlyphSize + 4))
                        .foregroundStyle(selectionState == .selected ? Color.shelfAmber : Color.shelfCream.opacity(0.9))
                        .padding(3)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                        .padding(.bottom, 3) // clear of the in-cover progress hairline
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if selectionState == .selected {
                    RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color.shelfAmber, lineWidth: 2)
                }
            }
            .opacity(selectionState == .unselected ? 0.6 : 1)
            // Code review fix (26 August 2026): this tile was signaling now-playing
            // twice — this centered amber-disc equalizer overlay AND the spinning tape
            // band above. Removed this one and kept the band: it's this tile's own
            // distinctive marker (per §11's "tape hardware only where audio is actually
            // moving," Stage 5), while `EqualizerBadge` stays the app's marker for
            // everywhere else it's used directly against a plain cover — the list rows
            // in `LibraryView`/`HomeView` — which don't render a `CassetteTile` at all
            // and so were never part of this duplication.
            // The cassette "face" (cover + tape window + badges) is a dark physical
            // object; keep its dark scrims + cream highlights in both themes. The
            // title/subtitle below stay adaptive so they read on a light grid.
            .environment(\.colorScheme, .dark)

            // Critique 2026-10-05 (shared tiles, 2nd): progress hairline moved onto the
            // cover's bottom edge (see the cover overlay above) so tile height is constant.

            // Two-line title (always reserves 2 lines so tiles align in a grid);
            // single-line author/narrator subtitle tucked close beneath.
            // HL-3 (V3): the two-line title reservation stays (rows align), but the spare
            // line now falls *below* the subtitle: the caption sits at the top of a block
            // sized by a hidden two-line title + subtitle.
            captionReserve.overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 2) {
                // Batch 218 (R9): was its own 11pt `@ScaledMetric` spelling of
                // "book title in a row" — `Typo.rowTitle` is the 14pt/.semibold
                // token the review names for exactly this role, already proven at
                // `HomeView`'s row call sites. CARE flagged by the review and worth
                // repeating here: this is a grid/shelf tile title, so 11→14pt
                // changes every `CassetteTile`'s rendered height in every grid and
                // shelf across the app — a real, visible proportion change nobody
                // has seen rendered (no simulator access in this environment).
                // Applying it anyway per the design owner's decision to finish the
                // migration rather than leave it stalled.
                Typo.rowTitle(Text(title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    Typo.fine(Text(subtitle))
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(1)
                }
            }
            }
            // Clamp the upper end so very large accessibility sizes enlarge the text
            // without shattering the grid layout.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.selectionAccessibilityLabel(base: tileA11yLabel, state: selectionState))
        .accessibilityHint(Self.selectionHint(selectionState) ?? "")
        .accessibilityAddTraits(selectionState == .selected ? .isSelected : [])
    }

    /// Plan §3.2: nil when not selecting (no hint at all).
    static func selectionHint(_ state: SelectionState?) -> String? {
        switch state {
        case nil: return nil
        case .unselected?: return String(localized: "Double-tap to select", comment: "VoiceOver hint on a book tile while multi-selecting")
        case .selected?: return String(localized: "Double-tap to deselect", comment: "VoiceOver hint on a book tile while multi-selecting")
        }
    }

    /// The tile label with its selection state appended. The selected trait already speaks
    /// "selected", so the label only adds "not selected" while selecting.
    static func selectionAccessibilityLabel(base: String, state: SelectionState?) -> String {
        switch state {
        case nil: return base
        case .unselected?: return String(localized: "\(base), not selected", comment: "VoiceOver label of an unselected book tile while selecting; %@ is the tile's normal label")
        case .selected?: return base
        }
    }

    /// Invisible stand-in that gives the caption its full height: a two-line title plus
    /// the subtitle (one line in Compact). Matches the real caption's fonts.
    private var captionReserve: some View {
        VStack(alignment: .leading, spacing: 2) {
            Typo.rowTitle(Text("Ag"))
                .lineLimit(compact ? 1 : 2, reservesSpace: true)
            if !compact {
                Typo.fine(Text("Ag")).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hidden()
    }

    /// UI-7: `.accessibilityElement(children: .combine)` followed by an explicit
    /// `.accessibilityLabel` **overrides** the combine rather than supplementing it —
    /// the previous label (`"title, subtitle"`, or `"...  now playing"`) silently
    /// dropped the download-progress ring, the downloaded badge, and the listening
    /// progress bar from what VoiceOver announces. A blind user browsing the grid had
    /// no way to tell which books were downloaded, which were mid-download, or how far
    /// through any of them they were — load-bearing information in an offline-first
    /// audiobook app. Built from state instead, so every visual badge this tile can show
    /// has a spoken equivalent.
    private var tileA11yLabel: String {
        Self.a11yLabel(title: title, subtitle: subtitle, progress: progress,
                       isFinished: isFinished, downloaded: downloaded,
                       downloadProgress: downloadProgress,
                       isNowPlaying: isNowPlaying, isPlaying: isPlaying)
    }

    /// Critique 2026-10-05 (shared tiles): pure so it can be unit-tested. A finished
    /// book says "finished" instead of a percentage.
    static func a11yLabel(title: String, subtitle: String, progress: Double = 0,
                          isFinished: Bool = false, downloaded: Bool = false,
                          downloadProgress: Double? = nil,
                          isNowPlaying: Bool = false, isPlaying: Bool = false) -> String {
        var parts = [title, subtitle]
        if isNowPlaying { parts.append(isPlaying ? String(localized: "now playing", comment: "VoiceOver fragment on a book tile") : String(localized: "paused", comment: "VoiceOver fragment on a book tile for the loaded but paused book")) }
        if isFinished {
            parts.append(String(localized: "finished", comment: "VoiceOver fragment on a book tile for a finished book"))
        } else if progress > 0 {
            parts.append(String(localized: "\(Int(progress * 100)) percent through", comment: "VoiceOver fragment on a book tile; %lld is the percentage listened"))
        }
        if let downloadProgress {
            parts.append(String(localized: "downloading, \(Int(downloadProgress * 100)) percent", comment: "VoiceOver fragment on a book tile; %lld is the download percentage"))
        } else if downloaded {
            parts.append(String(localized: "downloaded", comment: "VoiceOver fragment on a book tile for a downloaded book"))
        }
        return parts.joined(separator: ", ")
    }

    /// The reel band is tape hardware: shown only while audio is actually moving.
    static func showsReelBand(isNowPlaying: Bool, isPlaying: Bool) -> Bool {
        isNowPlaying && isPlaying
    }

    /// Critique 2026-10-05 (shared tiles, 2nd): the in-cover progress line shows for a
    /// started, unfinished book.
    static func showsProgressLine(progress: Double, isFinished: Bool) -> Bool {
        progress > 0 && !isFinished
    }

}

/// Stage 5 (REDESIGN_PROPOSAL_2026-08-26.md §11): `CassetteTile`'s reel-hub band is
/// now only rendered for the tile that's actually playing (see `CassetteTile.body`),
/// so its two hubs spin instead of sitting static — same governing rule, same
/// `TimelineView`-driven rotation approach as `CassetteReel` (the full-size player's
/// reel), just kept as its own tiny type rather than reusing that one directly: at a
/// ~14pt band height there's no room for `CassetteReel`'s capsule-spoke artwork, only
/// this tile's own simpler ring-and-dot hub.
private struct CassetteTileReelHub: View {
    var spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animate = spinning && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate * 90  // faster than the full-size reel — reads at a glance, this small
            hub.rotationEffect(.degrees(animate ? degrees : 0))
        }
        .accessibilityHidden(true)
    }

    private var hub: some View {
        // The original static hub's accent mark sat dead-center — radially
        // symmetric, so rotating it would have produced no visible motion at all.
        // Three off-center dots (in place of the one centered dot) so the spin
        // actually reads at this small a scale, echoing `CassetteReel`'s off-center
        // spokes without needing that much detail at 14pt.
        ZStack {
            Circle().fill(Color.shelfSurface)
            Circle().strokeBorder(Color.shelfCream.opacity(0.5), lineWidth: 2)
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.shelfCream.opacity(0.8))
                    .frame(width: 2.5, height: 2.5)
                    .offset(y: -4)
                    .rotationEffect(.degrees(Double(i) / 3 * 360))
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Library position scrubber

/// Plan 2026-10-05 §3.1: a trailing-edge vertical scrubber for long Library result sets.
/// Appears only while scrolling or dragging, and only when the count reaches
/// `LibraryScrubberMath.threshold`. Dragging reports row-snapped indices through `onJump`.
/// One VoiceOver element with an adjustable action stepping `LibraryScrubberMath.voiceOverStep`.
struct LibraryPositionScrubber: View {
    let count: Int
    let currentIndex: Int
    let onJump: (Int) -> Void
    let isVisible: Bool
    let columns: Int
    var pageSize: Int = 50

    @State private var dragIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Hardware exception (DESIGN.md): thumb metrics scale a little but are capped.
    @ScaledMetric(relativeTo: .body) private var thumbMetric: CGFloat = 44
    private var thumbHeight: CGFloat { min(max(thumbMetric, 44), 64) }

    static func isShown(count: Int, isVisible: Bool, isDragging: Bool) -> Bool {
        LibraryScrubberMath.showsScrubber(count: count) && (isVisible || isDragging)
    }

    /// VoiceOver value for the scrubber.
    static func accessibilityValue(index: Int, total: Int, locale: Locale = .current) -> String {
        LibraryScrubberMath.positionText(index: index, total: total, locale: locale)
    }

    /// Target index for a VoiceOver step, clamped to the list.
    static func steppedIndex(from index: Int, total: Int, increment: Bool) -> Int {
        guard total > 0 else { return 0 }
        let step = LibraryScrubberMath.voiceOverStep(total: total)
        return min(max(index + (increment ? step : -step), 0), total - 1)
    }

    var body: some View {
        if LibraryScrubberMath.showsScrubber(count: count) {
            let shown = Self.isShown(count: count, isVisible: isVisible, isDragging: dragIndex != nil)
            GeometryReader { geo in
                let displayIndex = dragIndex ?? currentIndex
                let travel = max(1, geo.size.height - thumbHeight)
                let y = CGFloat(LibraryScrubberMath.fraction(forIndex: displayIndex, count: count)) * travel
                ZStack(alignment: .topTrailing) {
                    Capsule()
                        .fill(Color.shelfAmber)
                        .frame(width: 6, height: thumbHeight)
                        .frame(width: 44, height: thumbHeight, alignment: .trailing)
                        .padding(.trailing, 2)
                        .offset(y: y)
                    if dragIndex != nil {
                        Typo.fine(Text(Self.accessibilityValue(index: displayIndex, total: count)))
                            .foregroundStyle(Color.shelfCream)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.shelfSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.shelfCream.opacity(0.2), lineWidth: 1))
                            .fixedSize()
                            .offset(x: -52, y: y + (thumbHeight - 28) / 2)
                            .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = Double((value.location.y - thumbHeight / 2) / travel)
                            let raw = LibraryScrubberMath.index(forFraction: fraction, count: count)
                            let snapped = LibraryScrubberMath.rowSnappedIndex(raw, columns: columns)
                            let previous = dragIndex ?? currentIndex
                            guard snapped != dragIndex else { return }
                            if dragIndex != nil,
                               LibraryScrubberMath.crossedPageBoundary(from: previous, to: snapped, pageSize: pageSize) {
                                Haptics.selection()
                            }
                            dragIndex = snapped
                            onJump(snapped)
                        }
                        .onEnded { _ in dragIndex = nil }
                )
            }
            .frame(width: 120)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Library position")
            .accessibilityValue(Self.accessibilityValue(index: dragIndex ?? currentIndex, total: count))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onJump(Self.steppedIndex(from: currentIndex, total: count, increment: true))
                case .decrement: onJump(Self.steppedIndex(from: currentIndex, total: count, increment: false))
                @unknown default: break
                }
            }
        }
    }
}

// MARK: - Printed-label section header

struct RetroSectionHeader: View {
    let title: LocalizedStringResource
    init(title: LocalizedStringResource) { self.title = title }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        // R3 (REVIEW_2026-09-04_UI.md): title wins the width fight; the rule
        // collapses and is dropped at accessibility sizes (rendered:
        // PREFEREN/CES at AX3).
        HStack(spacing: 8) {
            // Stage 5 (REDESIGN_PROPOSAL_2026-08-26.md §11): the `recordingtape`
            // glyph used to lead every single section header in the app —
            // identical, decorative, on every header regardless of what it's
            // introducing. Same pattern Batch 216 already fixed in
            // `AuthorsBrowseView` ("decorative icon, identical on every row, for no
            // differentiating reason"); this survived that sweep only because it was
            // taupe rather than amber, so the amber-discipline pass didn't catch it.
            // Removed under §11's governing rule — tape hardware appears only where
            // audio is actually moving, and a section header never is.
            Typo.sectionTitle(Text(String(localized: title).uppercased()))
                // Critique 2026-10-05 (shared tiles): speak the original-case title and
                // expose it as a heading (VoiceOver headings rotor).
                .accessibilityLabel(Text(title))
                .accessibilityAddTraits(.isHeader)
                .tracking(LocalizedText.tracking(1.5))
                .foregroundStyle(Color.shelfCream.opacity(0.8))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1) // AX: rule is gone, so a word-wrapped second line is safe and beats truncating
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
            if !dynamicTypeSize.isAccessibilitySize {
                Rectangle()
                    .fill(
                        LinearGradient(colors: [Color.shelfMuted.opacity(0.28), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - Tape-deck tab bar

struct RetroTabItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: LocalizedStringResource
    /// An optional count badge on the icon — e.g. downloads in flight on the Downloads
    /// tab. `nil` (the default) or a non-positive count draws nothing at all, so the
    /// existing `RetroTabItem(icon:label:)` call sites are unaffected.
    ///
    /// Deferred out of Batch 317: the iOS 26 path (`ContentView.modernTabs`) already gets
    /// badges for free from the native `TabView`, and this legacy bar — the only surface
    /// that actually renders on iOS 17–25 — had no equivalent, so the same count would
    /// appear on one OS and silently vanish on the other.
    var badge: Int?
    /// What the badge counts, spoken. VoiceOver reads the tab as its label plus this
    /// value — `badge: 3, badgeDescription: "downloading"` announces "Downloads, 3
    /// downloading". `nil` announces just the number, which is the honest fallback for a
    /// caller that hasn't said what it's counting.
    var badgeDescription: String?

    init(icon: String, label: LocalizedStringResource, badge: Int? = nil, badgeDescription: String? = nil) {
        self.icon = icon
        self.label = label
        self.badge = badge
        self.badgeDescription = badgeDescription
    }

}

struct RetroTabBar: View {
    @Binding var selection: Int
    let items: [RetroTabItem]
    var onRetap: ((Int) -> Void)?

    // VD-7 (docs/design-review.md, Round 4): the tab glyph sits directly above its
    // own label (`.scaledFont(9, relativeTo: .caption2)` below), so a fixed glyph
    // fell out of proportion with the label as text size grew. `relativeTo:
    // .caption2` matches the label; the whole bar is already clamped to
    // `.xLarge` (see `body`'s trailing `.dynamicTypeSize` below), so growth is
    // modest, but still capped at 1.3× base to keep four columns fitting the
    // narrowest supported phone.
    @ScaledMetric(relativeTo: .caption2) private var tabIconSizeMetric: CGFloat = 18
    private var tabIconSize: CGFloat { min(tabIconSizeMetric, 18 * 1.3) }

    /// Selected-tab highlight. Written as tinted Liquid Glass on iOS 26 / soft amber pill
    /// on fallback, but `RetroTabBar` itself is only ever instantiated by
    /// `ContentView.bottomBar` (line 207), which is only reachable from `legacyTabs` —
    /// i.e. iOS 17–25. `modernTabs` (iOS 26+) uses the native `TabView` +
    /// `.tabViewBottomAccessory` instead of this tab bar entirely (D5 / Batch 163), so the
    /// `#available(iOS 26.0, *)` branch below can never execute in the shipping app — on
    /// iOS 17–25, where this bar actually renders, the `else` branch is the only one that
    /// ever runs, and an iOS 26 user never reaches this view at all. Kept for SwiftUI
    /// previews and in case `RetroTabBar` is ever reused on iOS 26.
    @ViewBuilder private var selectionGlass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Color.shelfAmber).interactive(), in: Capsule())
        } else {
            Capsule().fill(Color.shelfAmber.opacity(0.16))
        }
    }

    /// Ink for the selected label. Written as dark on the amber-tinted glass (iOS 26) /
    /// amber on the subtle fallback pill, but per `selectionGlass`'s doc comment above,
    /// `RetroTabBar` is only ever reached via `legacyTabs` (iOS 17–25) — `modernTabs`
    /// (iOS 26+) never instantiates this view (D5 / Batch 163) — so the `Color.onAccent`
    /// branch below can never execute in the shipping app; `shelfAmberText` is the only
    /// value this property ever returns at runtime. Kept for previews / reuse.
    ///
    /// Review 2026-08-19: the fallback branch returned raw `shelfAmber`, which
    /// `Extensions.swift`'s own palette doc reserves for FILLS precisely because it
    /// measures ~1.9:1 as a foreground on Light theme's paper background. This is the
    /// selected *tab label* — the single most persistently visible piece of text in the
    /// app on iOS 17–25 — so it was the worst-placed instance of that mistake.
    /// `shelfAmberText` is identical in Dark theme and darkened to clear AA in Light.
    private var selectedTextColor: Color {
        if #available(iOS 26.0, *) { return Color.onAccent }
        return Color.shelfAmberText
    }

    /// What a badge of `count` prints. Capped so a runaway queue can't widen the badge
    /// past the glyph it sits on — the bar is fixed-height and evenly divided, and a
    /// four-digit badge would collide with the next tab's icon.
    static func badgeText(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    /// The spoken form of a badge — "3 downloading", or just "3" when the caller hasn't
    /// said what it's counting. `nil` when there's no badge to announce, so the tab keeps
    /// its label-only announcement. Pure so the string can be pinned by a test rather
    /// than checked by opening VoiceOver.
    static func badgeAccessibilityValue(count: Int?, description: String?) -> String? {
        guard let count, count > 0 else { return nil }
        guard let description, !description.isEmpty else { return "\(count)" }
        return String(localized: "\(count) \(description)", comment: "VoiceOver badge value on a tab; first is the count, second is what it counts, e.g. '3 downloading'")
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let selected = selection == index
                Button {
                    if selected {
                        // Same tab tapped again — notify parent to pop to root
                        onRetap?(index)
                    }
                    selection = index
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: tabIconSize, weight: .semibold))
                            // Count badge, drawn as an overlay so it adds nothing to the
                            // icon's own layout footprint — this bar is fixed-height and
                            // every column has to stay exactly as tall as its neighbours
                            // (same reasoning as the player toolbar's equal icon slots).
                            .overlay(alignment: .topTrailing) {
                                if let count = item.badge, count > 0 {
                                    // Batch 490 (REVIEW 2026-11-11 A5): scales with Dynamic
                                    // Type like the tab label below (was a fixed 9pt); the
                                    // bar's xLarge clamp still bounds it.
                                    Text(Self.badgeText(count))
                                        .scaledFont(9, weight: .bold, design: .rounded, relativeTo: .caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(Color.onAccent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.shelfAmber))
                                        // Hairline in the bar's own ground colour so the
                                        // badge reads as sitting *on* the glyph rather
                                        // than merging into it at small sizes.
                                        .overlay(Capsule().strokeBorder(Color.shelfBackground.opacity(0.6), lineWidth: 1))
                                        .offset(x: 11, y: -7)
                                        // The whole tab already carries one accessibility
                                        // label/value below; a second element here would
                                        // just repeat the count into the rotor.
                                        .accessibilityHidden(true)
                                }
                            }
                        Text(String(localized: item.label).uppercased())
                            .scaledFont(9, weight: .bold, design: .rounded, relativeTo: .caption2)
                            .tracking(LocalizedText.tracking(1))
                    }
                    // U5 (REVIEW_2026-08-20_UI_SECURITY.md): 0.55 measured 3.54:1
                    // Light against `shelfBackground` — the unselected state is 3 of
                    // 4 tabs at all times, the default state of the app's most
                    // persistently visible text on the iOS 17–25 fallback path. 0.75
                    // clears 4.5:1.
                    .foregroundStyle(selected ? selectedTextColor : Color.shelfCream.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    // Selected tab highlight — see `selectionGlass`'s doc comment above for
                    // why the iOS 26 glass branch it contains never actually runs here.
                    .background { if selected { selectionGlass } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.label))
                .accessibilityValue(Self.badgeAccessibilityValue(
                    count: item.badge, description: item.badgeDescription) ?? "")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(6)
        // `glassPill` still carries a real iOS 26 Liquid Glass branch, inset from the
        // screen edges so it hovers over the content, but this whole `RetroTabBar` is only
        // ever instantiated by `ContentView.bottomBar` (line 207), reachable only from
        // `legacyTabs` — i.e. iOS 17–25 — since `modernTabs` (iOS 26+) uses the native
        // `TabView` + `.tabViewBottomAccessory` instead (D5 / Batch 163). So the glass
        // branch can't execute in the shipping app; on iOS 17–25, where this bar actually
        // renders, the `.ultraThinMaterial` capsule fallback is the only path it ever
        // takes. Left as real glass code for previews and in case this bar is ever
        // reused on iOS 26.
        .glassPill(Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        // Let the labels scale for accessibility, but clamp so the fixed-height bar
        // doesn't overflow at the largest AX sizes.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

// MARK: - Tape counter readout (mechanical digits)

struct TapeCounter: View {

    /// How loudly this readout presents itself.
    ///
    /// P-2 (REVIEW_2026-09-14_DESIGN.md): the player showed five separate time
    /// representations at once, and `chip` — cream digits in a near-black LCD window —
    /// was the highest-contrast element on the whole screen, so the eye landed on a
    /// timestamp before the play button. `plain` is the demoted spelling the player now
    /// uses: the same monospaced digits, no window, `shelfMuted`. `chip` stays the
    /// default so the deck-face look is still available (and so any future caller that
    /// genuinely wants an LCD window gets it without re-deriving the colour rules below).
    enum Style {
        /// Cream digits in a dark LCD window — the cassette deck's own readout.
        case chip
        /// Quiet monospaced digits on whatever's behind them, no window.
        case plain
    }

    /// The chip's own window colour. Deliberately a fixed literal rather than an
    /// `adaptive(...)` token: this is a physical LCD window on the deck's face, and a
    /// window that turns pale in Light theme stops being one.
    ///
    /// F2 (REVIEW_2026-09-04_UI.md): this was `Color.black.opacity(0.45)`. Over the dark
    /// theme's espresso that resolved to `#0B0906` and looked right — but over Light
    /// theme's paper it resolved to `#878580`, a grey lozenge that read as a *disabled
    /// button*, and put cream digits at **3.12:1**, under WCAG AA's 4.5:1 for this 13pt
    /// text. The two chips flanking the player's scrubber were the least attractive
    /// element on the app's most-used screen. This value is the colour the translucent
    /// version already resolved to in Dark, so the Dark appearance is unchanged and only
    /// Light is repaired.
    private static let window = Color.lcdWindow

    let text: String
    var style: Style = .chip

    @ViewBuilder
    var body: some View {
        switch style {
        case .chip:
            Text(text)
                // HIG audit 2026-09-17 M6: fixed-size digits didn't grow with Dynamic Type.
                .scaledFont(13, weight: .bold, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(Color.shelfCream)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Self.window)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.shelfCream.opacity(0.12), lineWidth: 1))
                // A mechanical LCD readout: keep cream digits on a dark chip in both themes.
                // The forced scheme is what keeps `shelfCream` on its cream (dark-theme)
                // variant — without it the digits would go espresso-on-black in Light.
                .environment(\.colorScheme, .dark)
        case .plain:
            // No window, so no forced colour scheme either — `shelfMuted` is already the
            // palette's scheme-adaptive "quiet text" value, measured at 5.60:1 (Light) /
            // 6.24:1 (Dark) against the background in REVIEW_2026-09-14_DESIGN.md's
            // contrast table, i.e. this passes AA in both themes where the chip variant
            // needed a hand-picked window colour (F2) to get there.
            //
            // Same 13pt monospaced digits at a lighter weight: the digit rhythm is what
            // makes a counter readable at a glance while it ticks; the boldness is what
            // made it shout.
            Text(text)
                // HIG audit 2026-09-17 M6: fixed-size digits didn't grow with Dynamic Type.
                .scaledFont(13, weight: .medium, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(Color.shelfMuted)
        }
    }
}

// MARK: - Buffering ring (LS-1, docs/design-review.md)

/// A small rotating arc drawn just outside a play button's circle — the shared visual
/// both the mini player and the full player transport use for "playback is intended but
/// AVPlayer is stalled" (`AudioPlayerService.isBuffering`, surfaced as
/// `PlayerViewModel.isTransportWaiting`). Before this, that state was tracked but never
/// shown, so a stall on a slow connection looked identical to normal playback.
///
/// The play/pause glyph underneath never changes for this — only the ring appears —
/// so the button keeps its meaning and stays tappable throughout a stall. Don't use this
/// as a general-purpose spinner; it's sized and coloured for sitting around a transport
/// play circle specifically.
struct BufferingRing: View {
    var diameter: CGFloat
    var lineWidth: CGFloat
    /// Known trap in this codebase (see `SettingsComponents.swift`'s note on
    /// `menuRow(tint:)`): a default argument's isolation is checked against the
    /// *declaration's* own lexical context, not any caller's, so `Color = .shelfAmber`
    /// here — a `@MainActor` computed property used as a stored-property default on a
    /// `View` conformer's synthesized init — hits the same "referenced from a
    /// nonisolated context" failure a free function's default parameter did there.
    /// `nil` is isolation-free; the real default resolves in `body`, which genuinely is
    /// main-actor-isolated.
    var tint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationDegrees: Double = 0

    var body: some View {
        let resolvedTint = tint ?? Color.shelfAmber
        Group {
            if reduceMotion {
                // A spinning arc is exactly the motion Reduce Motion exists to
                // suppress — a static, dimmer full ring still reads as "something's
                // happening" without any rotation.
                Circle()
                    .stroke(resolvedTint.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(resolvedTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(rotationDegrees))
                    .onAppear {
                        // Indeterminate spin, not a value-driven state change, so this
                        // is a `withAnimation` rather than `.shelfAnimation(_:value:)` —
                        // but it's already gated behind the `reduceMotion` branch above,
                        // matching this app's "never animate without a Reduce Motion
                        // gate" rule.
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            rotationDegrees = 360
                        }
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Overlays a `BufferingRing` around this view (a play button's circle) while
    /// `isActive` is true. Wrapped in `DelayedProgressView` so a micro-stall under
    /// ~300ms never flickers the ring on and off — only a genuinely perceptible stall
    /// shows it. Purely an overlay: doesn't change this view's layout size, so callers
    /// don't need to reserve extra room for it.
    func bufferingRing(isActive: Bool, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        overlay {
            if isActive {
                DelayedProgressView(delay: .milliseconds(300)) {
                    BufferingRing(diameter: diameter, lineWidth: lineWidth)
                }
            }
        }
    }
}
