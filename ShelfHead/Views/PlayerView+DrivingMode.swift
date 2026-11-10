import SwiftUI

// MARK: - Driving mode (large-target, in-hand)

/// A stripped-back, big-button player for glancing/tapping while on the move
/// (in-hand or on a phone mount, not CarPlay). Everything is oversized and high-contrast.
///
/// Batch 406 redesign (docs/design/driving-mode-redesign-2026-10-21.md): the one player
/// surface the critiques never redesigned. It applies the CarPlay HIG's driver principles
/// (scan from the seat, primary content large, nothing nonessential, test for night and
/// sunlight) to the phone:
/// - Portrait and landscape layouts, picked by the vertical size class (HIG Layout: decide
///   by size class, not orientation). Phone mounts are often landscape.
/// - A thick chapter progress bar with "left in chapter" under the title, so "where am I"
///   reads in one glance instead of only "what book".
/// - A read-only sleep-timer glance in the top row (the timer is set from the main player).
/// - The skip intervals printed under their circles: the numbered SF Symbol snaps to the
///   nearest shipped glyph, so a 20 s setting showed "15".
/// - A `ViewThatFits` ladder (full → compact → scrolling compact) so AX5 on an iPhone SE
///   never clips; scrolling is the last resort, not the default.
/// - The status announcer lives once at the root, so the measuring that `ViewThatFits`
///   does can't post a VoiceOver announcement twice.
/// Every behaviour from Batches 367–372 is kept: Magic Tap, escape, the Bookmark capsule
/// with honest confirmation, the loading ring, the failure line with Try Again (the root
/// alert stands down via `isDrivingModePresented`), the single announcement, the status
/// line, "left in book", and the scaled exit.
struct DrivingModeView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    // Code review fix (26 August 2026): this view read `skipBackwardInterval`/
    // `skipForwardInterval` as plain `UserDefaults` reads inside `body` — the exact bug
    // Batch 218/R10.11 fixed in the main `PlayerView` transport row by switching to
    // `@AppStorage` on the same keys. A `UserDefaults` read is invisible to SwiftUI's
    // dependency tracking, so changing the interval in Settings never invalidated this
    // view's skip glyphs/labels while Driving Mode was open.
    @AppStorage(SettingsKeys.skipBackwardInterval) private var skipBackwardInterval: Double = 15
    @AppStorage(SettingsKeys.skipForwardInterval) private var skipForwardInterval: Double = 30

    // HIG audit 2026-09-17 M6: title, time-left and the big transport circles were fixed
    // `.system(size:)` literals that never grew with Dynamic Type — the one screen where
    // that matters most, since it exists for glanceability. Same house pattern as
    // `PlayerView`'s transport row (`PlayerView.cappedTransportMetric`): each
    // `@ScaledMetric` is capped at 1.4× its own base, so five/three big-target elements
    // stay legible instead of blowing out the screen at AX5, and at `.large` each resolves
    // to exactly the old literal (`min(scaled, base * 1.4) == base` there by construction).
    // DESIGN.md's Token-Only Rule names this screen's hardware as the sanctioned exception.
    @ScaledMetric private var titleSizeMetric: CGFloat = 26
    @ScaledMetric private var timeLeftSizeMetric: CGFloat = 20
    @ScaledMetric private var skipButtonSizeMetric: CGFloat = 84
    @ScaledMetric private var playButtonSizeMetric: CGFloat = 140
    // Critique 2026-10-05 (adapt): the exit glyph was a fixed 20pt on the one screen built
    // for glanceability. Same 1.4× cap as the rest of this screen.
    @ScaledMetric private var exitGlyphSizeMetric: CGFloat = 20
    @ScaledMetric private var bookmarkLabelSizeMetric: CGFloat = 20
    // Critique 2026-10-06 (adapt): the chapter line was an uncapped `.font(.title3)` (20pt
    // base) on a screen whose every other text is capped at 1.4×.
    @ScaledMetric private var chapterSizeMetric: CGFloat = 20
    /// Batch 406: the interval printed under each skip circle ("15s").
    @ScaledMetric private var skipCaptionSizeMetric: CGFloat = 18
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Batch 406: the area inside the screen's 24pt margins, measured so the transport can
    /// size itself to the column it actually gets (portrait: the whole width; landscape: the
    /// controls column, and the height too). 327 × 599 is the iPhone SE portrait column,
    /// the narrowest this app supports, used until the first measure lands.
    @State private var contentSize = CGSize(width: 327, height: 599)
    /// iPhone Duo (§4): an active fold across the content area (`PlayerFold`, iOS 27.1),
    /// measured from the same view as `contentSize` so the two share coordinates. Nil on
    /// every other device, posture, OS and SDK, which leaves the layouts below untouched.
    @State private var fold: PlayerFold?
    /// Briefly true after the Bookmark button saves, so the button itself confirms it —
    /// the app's toast sits behind this full-screen cover, and a driver shouldn't have to
    /// read one anyway. A confirmation, not an offer, so a short clock is fine here.
    @State private var bookmarkSaved: PlayerViewModel.BookmarkSaveResult?

    private var titleSize: CGFloat { PlayerView.cappedTransportMetric(titleSizeMetric, base: 26) }
    private var timeLeftSize: CGFloat { PlayerView.cappedTransportMetric(timeLeftSizeMetric, base: 20) }
    private var skipButtonSize: CGFloat { PlayerView.cappedTransportMetric(skipButtonSizeMetric, base: 84) }
    private var playButtonSize: CGFloat { PlayerView.cappedTransportMetric(playButtonSizeMetric, base: 140) }
    private var exitGlyphSize: CGFloat { PlayerView.cappedTransportMetric(exitGlyphSizeMetric, base: 20) }
    private var chapterSize: CGFloat { PlayerView.cappedTransportMetric(chapterSizeMetric, base: 20) }
    private var bookmarkLabelSize: CGFloat { PlayerView.cappedTransportMetric(bookmarkLabelSizeMetric, base: 20) }
    private var skipCaptionSize: CGFloat { PlayerView.cappedTransportMetric(skipCaptionSizeMetric, base: 18) }

    private var hasBook: Bool { playerViewModel.currentBook != nil }
    /// HIG Layout: "Determine layout based on size classes, not device type or orientation."
    /// Every iPhone in landscape is vertically compact.
    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var exitDiameter: CGFloat { max(44, exitGlyphSize * 2.6) }
    private var bookmarkHeight: CGFloat { 64 }

    /// Landscape splits the content into an info column and a controls column; the controls
    /// get the larger share so the transport keeps the SE portrait column's 327pt.
    private static let landscapeGap: CGFloat = 24
    private var landscapeControlsWidth: CGFloat {
        // iPhone Duo (§4): folded like a book, the controls column is exactly the trailing
        // side of the fold, so the big targets never straddle it.
        if let fold, fold.runsVertically { return fold.panes(in: contentSize).second }
        return ((contentSize.width - Self.landscapeGap) * 0.55).rounded(.down)
    }
    /// The gap between the two landscape columns: the fold itself when folded like a book.
    private var landscapeColumnGap: CGFloat {
        if let fold, fold.runsVertically { return fold.panes(in: contentSize).gap }
        return Self.landscapeGap
    }
    /// iPhone Duo (§4): folded like a book, the two-column landscape layout puts the info on
    /// one side of the fold and the controls on the other, whatever the size class says.
    private var usesColumns: Bool { isLandscape || fold?.runsVertically == true }

    private var transport: TransportSizes {
        // iPhone Duo (§4): folded like a laptop, the transport and Bookmark have the room
        // below the fold, so that height bounds the play circle (same reservations as
        // landscape, less the exit row, which stays above the fold).
        if let fold, !fold.runsVertically {
            let reserved = bookmarkHeight + skipCaptionSize * 1.4 + 2 * 12
            return Self.transportSizes(columnWidth: contentSize.width,
                                       maxPlay: fold.panes(in: contentSize).second - reserved,
                                       skip: skipButtonSize, play: playButtonSize)
        }
        if usesColumns {
            // Height is the binding constraint here: the exit row, the skip captions, the
            // Bookmark capsule and the stack's gaps come out of the column first.
            let reserved = exitDiameter + bookmarkHeight + skipCaptionSize * 1.4 + 3 * 12
            return Self.transportSizes(columnWidth: landscapeControlsWidth,
                                       maxPlay: contentSize.height - reserved,
                                       skip: skipButtonSize, play: playButtonSize)
        }
        // Portrait is width-bound on every phone; the 30% height cap only stops the circle
        // from swallowing a short column before `ViewThatFits` has to step down.
        return Self.transportSizes(columnWidth: contentSize.width,
                                   maxPlay: contentSize.height * 0.3,
                                   skip: skipButtonSize, play: playButtonSize)
    }

    struct TransportSizes: Equatable {
        var skip: CGFloat
        var play: CGFloat
        var spacing: CGFloat
    }

    /// Critique 2026-10-06 (adapt): the transport row was fixed 84 + 140 + 84 + 2×16 = 340pt
    /// in a 327pt column on iPhone SE, and ~463pt at the 1.4× Dynamic Type cap, so the skip
    /// buttons clipped. Pure so the fit is pinned by `DrivingModeTransportTests`.
    ///
    /// `skip`/`play` are the preferred (already capped) diameters. The row keeps `spacing`
    /// between the three buttons and leaves `ringAllowance` for the play button's loading
    /// ring (diameter + 12); if the three don't fit they shrink together, keeping their
    /// ratio so Play stays dominant (~1.67x skip), but never below 60pt (skip) / 96pt (play).
    static func transportSizes(columnWidth: CGFloat, skip: CGFloat, play: CGFloat) -> TransportSizes {
        let spacing: CGFloat = 12
        let ringAllowance: CGFloat = 12
        let preferred = 2 * skip + play
        let available = columnWidth - 2 * spacing - ringAllowance
        guard preferred > available, preferred > 0 else {
            return TransportSizes(skip: skip, play: play, spacing: spacing)
        }
        let scale = available / preferred
        return TransportSizes(skip: max(60, (skip * scale).rounded(.down)),
                              play: max(96, (play * scale).rounded(.down)),
                              spacing: spacing)
    }

    /// Batch 406: the width fit above, then a height fit for landscape (a phone mount's
    /// column is ~330pt tall on iPhone SE). `maxPlay` is the tallest the play circle may be
    /// (less its 12pt ring); when it's smaller both circles shrink by the same ratio, with
    /// the same 60/96pt floors, so Play stays dominant and every target stays well above
    /// the HIG's 44pt minimum.
    static func transportSizes(columnWidth: CGFloat, maxPlay: CGFloat, skip: CGFloat, play: CGFloat) -> TransportSizes {
        let fitted = transportSizes(columnWidth: columnWidth, skip: skip, play: play)
        let ringAllowance: CGFloat = 12
        let limit = maxPlay - ringAllowance
        guard fitted.play > limit, fitted.play > 0, limit > 0 else { return fitted }
        let scale = limit / fitted.play
        return TransportSizes(skip: max(60, (fitted.skip * scale).rounded(.down)),
                              play: max(96, (fitted.play * scale).rounded(.down)),
                              spacing: fitted.spacing)
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()

            Group {
                if let fold, !fold.runsVertically {
                    stackedFoldLayout(fold)
                } else if usesColumns { landscapeLayout } else { portraitLayout }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
            // iPhone Duo (§4): read from the view that positions the layouts (Apple,
            // `ReservedRegion`), so the fold's frame is in the same space as `contentSize`.
            .onGeometryChange(for: PlayerFold?.self) { PlayerFold.current(in: $0) } action: { fold = $0 }
            .padding(.horizontal, 24)
            .padding(.vertical, isLandscape ? 16 : 24)
        }
        // DESIGN.md: "Dark is the default appearance and the tuned one." This screen stays
        // dark whatever the theme: a bright paper screen in a dark car at night is glare,
        // and the burnt-orange status line is only tuned to pass (5.3:1) on espresso.
        .environment(\.colorScheme, .dark)
        // Batch 406: the environment override above recolours the content but not the
        // status bar, which in the Light theme drew dark glyphs on espresso. Per the docs
        // this applies to "the nearest enclosing presentation", i.e. this cover only.
        .preferredColorScheme(.dark)
        // The status announcer is mounted once, here, rather than inside the status line:
        // `ViewThatFits` builds more than one copy of the layout to measure it.
        .background { DrivingStatusAnnouncer() }
        // VoiceOver's two-finger double-tap plays/pauses from anywhere on this screen,
        // the standard media shortcut (HIG Playing audio) — a glance-free way to stop.
        .accessibilityAction(.magicTap) { playerViewModel.togglePlayPause() }
        // VoiceOver's two-finger scrub closes it, like any other modal (it's a full-screen
        // cover, so there's no swipe-down).
        .accessibilityAction(.escape) { dismiss() }
        // Tells the root alert to stand down while this cover is up (fourth run).
        .onAppear { playerViewModel.isDrivingModePresented = true }
        .onDisappear { playerViewModel.isDrivingModePresented = false }
    }

    // MARK: Layouts

    /// Portrait, top to bottom: sleep glance + exit, what and where (title, chapter, a thick
    /// chapter bar), news (status line), the transport, Bookmark. At accessibility sizes the
    /// ladder steps down to the compact column, and only then to scrolling.
    private var portraitLayout: some View {
        ViewThatFits(in: .vertical) {
            portraitColumn(compact: false)
            portraitColumn(compact: true)
            ScrollView { portraitColumn(compact: true) }
                .scrollIndicators(.hidden)
        }
    }

    private func portraitColumn(compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 20) {
            topRow
            Spacer(minLength: 0)
            infoBlock(compact: compact, alignment: .center)
            Spacer(minLength: 0)
            transportRow
            Spacer(minLength: 0)
            bookmarkButton
        }
    }

    /// Landscape (phone mounts): information on the leading side, controls on the trailing
    /// side, nearer a right-hand driver's reach and the edge a mount leaves clear.
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: landscapeColumnGap) {
            ViewThatFits(in: .vertical) {
                landscapeInfo(compact: false)
                landscapeInfo(compact: true)
                ScrollView { landscapeInfo(compact: true) }
                    .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 12) {
                HStack { Spacer(minLength: 0); exitButton }
                Spacer(minLength: 0)
                transportRow
                Spacer(minLength: 0)
                bookmarkButton
            }
            .frame(width: landscapeControlsWidth)
            .frame(maxHeight: .infinity)
        }
    }

    /// iPhone Duo (§4), folded like a laptop: the portrait column cut at the fold — sleep
    /// glance, exit and the info above it, the transport and Bookmark below it — with the
    /// fold's height left clear. The info keeps the portrait ladder (full → compact →
    /// scrolling compact) within its half.
    private func stackedFoldLayout(_ fold: PlayerFold) -> some View {
        let panes = fold.panes(in: contentSize)
        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                topRow
                ViewThatFits(in: .vertical) {
                    infoBlock(compact: false, alignment: .center)
                    infoBlock(compact: true, alignment: .center)
                    ScrollView { infoBlock(compact: true, alignment: .center) }
                        .scrollIndicators(.hidden)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: panes.first)

            Color.clear
                .frame(height: panes.gap)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Spacer(minLength: 0)
                transportRow
                Spacer(minLength: 0)
                bookmarkButton
            }
            .frame(height: panes.second)
        }
    }

    private func landscapeInfo(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            DrivingSleepGlance(size: timeLeftSize)
            Spacer(minLength: 0)
            infoBlock(compact: compact, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack(alignment: .center, spacing: 12) {
            DrivingSleepGlance(size: timeLeftSize)
            Spacer(minLength: 0)
            exitButton
        }
    }

    private var exitButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: exitGlyphSize, weight: .bold))
                .foregroundStyle(Color.shelfCream)
                .frame(width: exitDiameter, height: exitDiameter)
                .background(Color.shelfSurface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit driving mode")
    }

    /// Title, chapter, progress and status. Title and chapter are both full Cream Readout:
    /// on this screen "which chapter" is as much a glance answer as "which book".
    private func infoBlock(compact: Bool, alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: compact ? 8 : 12) {
            // Critique 2026-10-06 (clarify): with no book the transport and bookmark are
            // disabled below, so the empty state reads as such.
            Text(playerViewModel.currentBook?.title ?? String(localized: "Nothing playing", comment: "Driving Mode title when no book is loaded"))
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.shelfCream)
                .multilineTextAlignment(textAlignment)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(compact ? 0.8 : 1)
                .accessibilityAddTraits(.isHeader)
            if let chapter = playerViewModel.currentChapter?.title {
                Text(PlayerView.displayChapterTitle(chapter))
                    .font(.system(size: chapterSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shelfCream)
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if hasBook {
                DrivingProgress(size: timeLeftSize, showsBookTime: !compact, alignment: alignment)
            }
            DrivingStatusLine(size: timeLeftSize, alignment: alignment)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private var transportRow: some View {
        HStack(alignment: .top, spacing: transport.spacing) {
            // P3-6 (third-pass review, 14 Aug 2026): this second full-screen player
            // surface hardcoded the same "gobackward.15"/"goforward.30" glyphs as
            // `controlsView` above — same fix, same shared `SkipLabels` helper.
            skipButton(backward: true, seconds: skipBackwardInterval) {
                Haptics.impact(.medium); playerViewModel.skipBackward()
            }
            playButton
            skipButton(backward: false, seconds: skipForwardInterval) {
                Haptics.impact(.medium); playerViewModel.skipForward()
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(!hasBook)
        .opacity(hasBook ? 1 : 0.4)
    }

    private var playButton: some View {
        Button {
            Haptics.impact(.medium); playerViewModel.togglePlayPause()
        } label: {
            Circle()
                .fill(Color.shelfAmber)
                .frame(width: transport.play, height: transport.play)
                .overlay {
                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: transport.play * 0.38, weight: .bold))
                        .foregroundStyle(Color.onAccent)
                        // iOS 26/27 Liquid Glass polish pass (26 August 2026): the same
                        // `.symbolEffect(.replace)` as the main transport. Batch 406: a hard
                        // cut under Reduce Motion (HIG Accessibility, Motion).
                        .contentTransition(reduceMotion ? ContentTransition.identity : .symbolEffect(.replace))
                }
        }
        .buttonStyle(.plain)
        // Critique 2026-10-05 (adapt): the same loading ring as the main player's play
        // circle, so a stalled stream doesn't look like a tap that didn't register.
        .bufferingRing(isActive: playerViewModel.isTransportWaiting,
                       diameter: transport.play + 12, lineWidth: 4)
        .accessibilityLabel(playerViewModel.isPlaying ? "Pause" : "Play")
        .accessibilityValue(playerViewModel.isTransportWaiting ? "Loading" : "")
        // Batch 406: VoiceOver stops talking when Play starts audio (`startsMediaSession`),
        // so its own speech doesn't land on top of the book.
        .accessibilityAddTraits(playerViewModel.isPlaying ? [] : .startsMediaSession)
    }

    /// A skip circle with its real interval printed underneath. The numbered glyph snaps to
    /// the nearest symbol SF Symbols ships (`SkipLabels.symbolName`), so the caption is the
    /// one place a 20 s or 120 s setting is stated exactly. The whole column is the target.
    private func skipButton(backward: Bool, seconds: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color.shelfSurface)
                    .frame(width: transport.skip, height: transport.skip)
                    .overlay {
                        Image(systemName: SkipLabels.symbolName(backward: backward, seconds: seconds))
                            .font(.system(size: transport.skip * 0.42, weight: .bold))
                            .foregroundStyle(Color.shelfCream)
                    }
                Text(seconds.formattedDuration)
                    .font(.system(size: skipCaptionSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // U13 (REVIEW_2026-08-20_UI_SECURITY.md): the label always states the configured
        // interval, never a generic "Skip back".
        .accessibilityLabel(SkipLabels.accessibilityLabel(backward: backward, seconds: seconds))
        // Centres the skip circle on the play circle; the caption hangs below the row's
        // centre line instead of pushing the circle up.
        .padding(.top, max(0, (transport.play - transport.skip) / 2))
    }

    /// One wide target that bookmarks "now" (critique 2026-10-05, adapt): Driving Mode had
    /// no way to mark a moment without leaving it, and the main player's route is a sheet,
    /// a button and an alert. Full width, 64 pt tall, under the transport so it can't be
    /// mistaken for play/pause.
    private var bookmarkButton: some View {
        Button {
            guard bookmarkSaved == nil else { return }
            Task {
                // Critique 2026-10-05 (second run): confirm only after the save returns —
                // the haptic and label used to fire first — and say "will sync" here,
                // because the app's toast saying so sits behind this cover.
                guard let result = await playerViewModel.addBookmarkAtCurrentTime() else { return }
                Haptics.success()
                bookmarkSaved = result
                // Only for a synced save: a queued one already posts the app's "will sync"
                // toast, which VoiceOver announces even behind this cover — announcing here
                // too said it twice (critique 2026-10-05, third run).
                if result == .synced { AccessibilityNotification.Announcement(String(localized: "Bookmarked", comment: "VoiceOver announcement after a bookmark is saved")).post() }
                try? await Task.sleep(for: .seconds(2))
                bookmarkSaved = nil
            }
        } label: {
            Label(bookmarkSaved == nil ? String(localized: "Bookmark", comment: "Driving Mode button that bookmarks the current moment (verb)")
                    : (bookmarkSaved == .synced ? String(localized: "Bookmarked", comment: "Driving Mode button label after a bookmark is saved")
                       : String(localized: "Saved · will sync", comment: "Driving Mode button label after an offline bookmark is queued")),
                  systemImage: bookmarkSaved == nil ? "bookmark" : "checkmark")
                .font(.system(size: bookmarkLabelSize, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shelfCream)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: bookmarkHeight)
                .background(Color.shelfSurface, in: Capsule())
                .contentTransition(reduceMotion ? ContentTransition.identity : .symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!hasBook)
        .opacity(hasBook ? 1 : 0.4)
        .accessibilityLabel(bookmarkSaved == nil ? "Bookmark this moment" : "Bookmarked")
    }
}

// MARK: - Progress

/// Batch 406: where you are, at a glance — a thick bar (amber fill: progress is live state
/// under DESIGN.md's One Light Rule) and the wall-clock time left in the chapter, at the
/// current speed, like the sleep countdown. Books without chapters show the whole book.
/// Its own view so the per-second `currentTime` tick invalidates only this block.
private struct DrivingProgress: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.colorSchemeContrast) private var contrast
    let size: CGFloat
    /// The "≈… left in book" line gives way first in the compact layout; the book-level
    /// time is still on the main player.
    let showsBookTime: Bool
    let alignment: HorizontalAlignment

    private var rate: Double { max(Double(playerViewModel.playbackRate), 0.1) }
    private var hasChapters: Bool { playerViewModel.hasChapters }
    private var fraction: Double {
        let value = hasChapters ? playerViewModel.chapterProgress
            : (playerViewModel.duration > 0 ? playerViewModel.currentTime / playerViewModel.duration : 0)
        return min(max(value.isFinite ? value : 0, 0), 1)
    }
    /// Secondary readouts go to full Cream Readout under Increase Contrast (HIG Accessibility:
    /// provide a higher-contrast scheme when the setting is on).
    private var secondary: Color { contrast == .increased ? Color.shelfCream : Color.shelfMuted }

    private var leadingText: String {
        if hasChapters {
            let left = max(0, playerViewModel.chapterLength - playerViewModel.chapterElapsed) / rate
            return String(localized: "\(left.formattedTime) left in chapter", comment: "Driving Mode: wall-clock time left in the current chapter at the current speed. %@ is a time such as 12:03")
        }
        return bookText
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.shelfSurface)
                    Capsule().fill(Color.shelfAmber)
                        .frame(width: max(10, proxy.size.width * fraction))
                }
            }
            .frame(height: 10)

            // Critique 2026-10-05 (adapt): "≈… left in book" at the current speed, the same
            // wording as the main player's time-left line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    readout(leadingText, primary: true)
                    if showsBookTime && hasChapters && playerViewModel.remainingListeningTime > 1 {
                        Spacer(minLength: 0)
                        readout(bookText, primary: false)
                    }
                }
                VStack(alignment: alignment, spacing: 4) {
                    readout(leadingText, primary: true)
                    if showsBookTime && hasChapters && playerViewModel.remainingListeningTime > 1 {
                        readout(bookText, primary: false)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasChapters ? String(localized: "Chapter progress", comment: "Driving Mode VoiceOver label for the chapter progress bar")
                                        : String(localized: "Book progress", comment: "Driving Mode VoiceOver label for the book progress bar"))
        .accessibilityValue(accessibilityValue)
    }

    private var bookText: String {
        String(localized: "≈\(playerViewModel.remainingListeningTime.formattedDuration) left in book", comment: "Driving Mode: approximate time left in the book at the current speed. %@ is a duration such as 19h 35m")
    }

    private var accessibilityValue: String {
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        if hasChapters, showsBookTime, playerViewModel.remainingListeningTime > 1 {
            return "\(percent), \(leadingText), \(String(localized: "About \(playerViewModel.remainingListeningTime.formattedDuration) left in this book"))"
        }
        return "\(percent), \(leadingText)"
    }

    private func readout(_ text: String, primary: Bool) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(primary ? Color.shelfCream : secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

// MARK: - Sleep timer glance

/// Batch 406: the armed sleep timer, read-only (it's set from the main player, where the
/// controls have room). The same line as the mini player and the player's chip, from the
/// one shared `MiniPlayerStatus.sleepText`. Nothing at all when no timer is armed. Its own
/// view so the countdown's per-second tick invalidates only this line.
private struct DrivingSleepGlance: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let size: CGFloat

    private var text: String? {
        guard playerViewModel.sleepTimerOption != .off else { return nil }
        let chapterRemaining = playerViewModel.currentChapter != nil
            ? max(0, playerViewModel.chapterLength - playerViewModel.chapterElapsed) : nil
        return MiniPlayerStatus.sleepText(option: playerViewModel.sleepTimerOption,
                                          remaining: playerViewModel.sleepTimerRemaining,
                                          chapterRemaining: chapterRemaining,
                                          rate: Double(playerViewModel.playbackRate))
            ?? String(localized: "Sleep timer on", comment: "Sleep timer status chip fallback text when a timer is armed")
    }

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color.shelfAmberText)   // an armed timer is live state
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(text)
        }
    }
}

// MARK: - Status

/// The one place the status line's text and tone are worked out, shared by the visible
/// line and the root announcer so the two can never disagree.
@MainActor
private enum DrivingStatus {
    static func header(_ vm: PlayerViewModel) -> PlayerView.HeaderStatus {
        PlayerView.headerStatus(isPlaying: vm.isPlaying,
                                isWaiting: vm.isTransportWaiting,
                                stalled: vm.transportStalled,
                                isStreaming: vm.isStreamingCurrentBook)
    }

    static func line(_ vm: PlayerViewModel) -> String? {
        PlayerView.drivingStatusLine(
            // Critique 2026-10-06 (harden): the debounced status the banner uses, not the raw
            // store, so one failed ping doesn't flash orange at a driver.
            reachability: DisplayedReachability.shared.status,
            header: header(vm),
            isStreaming: vm.isStreamingCurrentBook,
            startFailure: vm.startFailureMessage,
            showsLoading: vm.transportWaitingLong)
    }

    static func isQuiet(_ vm: PlayerViewModel) -> Bool {
        PlayerView.drivingStatusIsQuiet(reachability: DisplayedReachability.shared.status,
                                        isStreaming: vm.isStreamingCurrentBook,
                                        startFailure: vm.startFailureMessage)
    }
}

/// Driving Mode's one-line status (`PlayerView.drivingStatusLine`), in burnt orange — the
/// emphasis colour DESIGN.md reserves for alarm and connectivity — at the time-left size so
/// it reads at arm's length. Reads the single stall clock in `PlayerViewModel` (fourth run;
/// it used to keep its own). A failed start shows here with a Try Again, because the app's
/// alert stands down while this cover is up. (DESIGN.md's Fill-or-Text Rule normally keeps
/// orange off text; Batch 382 kept this line as the named exception because the screen is
/// forced Dark, where it measures 5.3:1.)
private struct DrivingStatusLine: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let size: CGFloat
    var alignment: HorizontalAlignment = .center

    var body: some View {
        let line = DrivingStatus.line(playerViewModel)
        VStack(alignment: alignment, spacing: 10) {
            if let line {
                Text(line)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    // Critique 2026-10-06 (clarify): "using your download" is calm news, muted;
                    // orange is for listening at risk.
                    .foregroundStyle(DrivingStatus.isQuiet(playerViewModel) ? Color.shelfMuted : Color.shelfOrange)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity)
            }
            if playerViewModel.startFailureMessage != nil {
                Button {
                    Haptics.selection()
                    playerViewModel.retryFailedStart()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: size, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.shelfCream)
                        .padding(.horizontal, 24)
                        .frame(minHeight: 56)
                        .background(Color.shelfSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: line)
    }
}

/// Announce only what nothing else announces: a failed start and a stall. The
/// connectivity banner, still mounted underneath this cover, already speaks
/// offline / can't-reach changes — speaking them here too said everything twice.
/// Batch 406: moved out of `DrivingStatusLine` and mounted once at the root, because the
/// line now sits inside `ViewThatFits`, which may build more than one copy of it.
private struct DrivingStatusAnnouncer: View {
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        let line = DrivingStatus.line(playerViewModel)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: line) { _, newLine in
                guard let newLine else { return }
                if newLine == playerViewModel.startFailureMessage || DrivingStatus.header(playerViewModel) == .waitingForServer {
                    AccessibilityNotification.Announcement(newLine).post()
                }
            }
    }
}
