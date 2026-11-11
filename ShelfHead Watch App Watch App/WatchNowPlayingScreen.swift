import SwiftUI
import WatchKit
import Accessibility
#if canImport(UIKit)
import UIKit
#endif

// Critique 2026-10-06 (shape → adapt + distill). The Watch is a player for runs. Before
// this file there were two Now Playing screens: companion's `NowPlayingView` (page 1 of a
// six-page pager) and `StandaloneNowPlayingView` (a 120pt cover, a two-line Title 3 title,
// the author and the time row stacked above Play, which pushed Play below the fold on
// 41/45mm). They had drifted: different cover sizes, different button sizes, speed and
// bookmark on one side only, sleep status nowhere on the first screen.
//
// `WatchNowPlayingScreen` is the one layout both modes now use. Each mode adapts its own
// stack into a `WatchNowPlayingModel` plus `WatchNowPlayingActions` (`NowPlayingView` for
// the phone relay, `StandaloneNowPlayingPage` for this Watch's engine). The first
// viewport holds what a runner reaches for: what's playing, where it's playing, how far
// in, and the transport. Everything else (chapter, author, speed, bookmark, sleep, mode
// extras) sits one crown-turn below.
//
// HIG pages consulted (via the JSON endpoint, 6 Oct 2026):
// - designing-for-watchos: "quick, glanceable, single-screen interactions";
//   "minimize the depth of hierarchy... use the Digital Crown".
// - digital-crown: "Anchor your app's navigation to the Digital Crown"; "Provide visual
//   feedback in response to Digital Crown interactions".
// - always-on: "dim nonessential content"; "Maintain a consistent layout... prefer
//   transitioning an interactive component to an unavailable appearance"; "aim to make
//   infrequent, subtle updates".
// - playing-audio: custom transport controls are fine for "custom increments for
//   skipping forward or backward".
//
// Batch 410 (Watch redesign, The Shelf — docs/design/watch-redesign-2026-10-21.md): the
// four-page vertical pager around this screen is gone in both modes. Chapters, Bookmarks,
// Sleep and a real Speed list open as shared sheets from the tool row
// (`WatchNowPlayingSheets.swift`), the modes' footers (Mark as Finished, Stop Playing)
// move behind "⋯" in the toolbar, and with nothing left to page the Digital Crown drives
// volume (`WatchVolumeControl`), as in Apple's Now Playing. Tapping the time row still
// lends the Crown to scrubbing until the seek commits, then volume takes it back. The
// screen no longer scrolls past the first viewport except at accessibility text sizes.

/// Everything the shared layout shows, in mode-neutral terms.
struct WatchNowPlayingModel {
    var title: String
    var author: String
    var chapterTitle: String?
    var coverData: Data?
    var elapsed: Double
    var duration: Double
    var isPlaying: Bool
    var isBuffering: Bool = false
    /// False while the book is still loading (standalone) — transport and scrubbing are
    /// shown but disabled so the layout doesn't jump when it lands.
    var isReady: Bool = true
    /// The real skip amounts, for the glyph and the VoiceOver label (`SkipLabels`).
    var skipBackwardSeconds: Double?
    var skipForwardSeconds: Double?
    /// Current rate, or nil where speed can't be changed.
    var speed: Double?
    /// Seconds until the sleep timer fires, or nil when no timer is running.
    var sleepSecondsLeft: Double?
    var source: WatchPlaybackSource
    var isStale: Bool = false
    /// The loaded book, for "Jump back" (only ever restores into the same book). Nil
    /// while nothing is loaded.
    var itemId: String? = nil
    /// Batch 410: what the shared sheets list.
    var chapters: [WatchChapterRow] = []
    /// Shown by the Chapters sheet when `chapters` is empty.
    var chaptersEmptyMessage: String = String(localized: "This book has no chapters")
    var bookmarks: [WatchBookmarkRow] = []
    var isLoadingBookmarks: Bool = false
    var sleepOption: WatchSleepTimerOption = .off
    /// Why the Sleep sheet's options can't be used right now, or nil.
    var sleepUnavailableReason: String? = nil

    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
    var sleepText: String? { sleepSecondsLeft.flatMap { WatchSleepStatus.remainingText(seconds: $0) } }
    /// "23m" for the header's status line, beside the moon glyph.
    var sleepShortText: String? { sleepSecondsLeft.flatMap { WatchSleepStatus.shortText(seconds: $0) } }
}

/// What the shared layout's controls do. Optional actions hide their control.
struct WatchNowPlayingActions {
    var togglePlayPause: () -> Void
    var skipBackward: () -> Void
    var skipForward: () -> Void
    var seek: (Double) -> Void
    /// Batch 410: any rate from the Speed sheet (was `cycleSpeed`, one preset per tap).
    var setSpeed: ((Double) -> Void)? = nil
    /// Critique 2026-10-06 (harden): reports the real outcome (the iPhone's reply in
    /// companion mode, the server or the offline queue in standalone), so the tool row
    /// stops claiming "Saved" for a bookmark that never landed.
    var addBookmark: ((@escaping (WatchBookmarkOutcome) -> Void) -> Void)? = nil
    var setSleepTimer: ((WatchSleepTimerOption) -> Void)? = nil
    /// Batch 490 (REVIEW 2026-11-11 F29): "Add 15 Minutes" in the Sleep sheet. Shown
    /// only while a countdown runs (`WatchSleepExtend.isAvailable`).
    var extendSleepTimer: (() -> Void)? = nil
    /// Companion mode seeks by chapter id (`seekToChapter`), standalone by time.
    var seekToChapter: ((WatchChapterRow) -> Void)? = nil
    var seekToBookmark: ((WatchBookmarkRow) -> Void)? = nil
    /// Run when the Bookmarks sheet opens (standalone fetches and flushes its queue).
    var loadBookmarks: (() async -> Void)? = nil
}

/// The one Now Playing layout. `notice` sits between the time row and the transport (the
/// standalone route warning, an error, a loading spinner); `moreActions` fills the "⋯"
/// sheet below Bookmarks (companion's Mark as Finished, standalone's Stop Playing).
struct WatchNowPlayingScreen<Notice: View, MoreActions: View>: View {
    let model: WatchNowPlayingModel
    let actions: WatchNowPlayingActions
    let notice: () -> Notice
    let moreActions: () -> MoreActions

    init(model: WatchNowPlayingModel, actions: WatchNowPlayingActions,
         @ViewBuilder notice: @escaping () -> Notice,
         @ViewBuilder moreActions: @escaping () -> MoreActions) {
        self.model = model
        self.actions = actions
        self.notice = notice
        self.moreActions = moreActions
    }

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// Critique 2026-10-06 (adapt): at accessibility text sizes the header drops the
    /// cover and the title's second line before Play is pushed below the fold.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Digital Crown scrubbing, moved here unchanged from the two screens it used to be
    // copied between — see the history on `NowPlayingView` (WATCH-4, NEW-3, P3-7, L13)
    // and `StandaloneNowPlayingView` (PL-5). Batch 410: unfocused, the Crown is volume
    // (`WatchVolumeControl`); a tap on the time row focuses it and the Crown scrubs; a
    // committed seek or another tap hands the Crown back to volume.
    @State private var crownPosition: Double = 0
    @State private var isScrubbingWithCrown = false
    @State private var crownSeekTask: Task<Void, Never>?
    /// Batch 490 (REVIEW 2026-11-11 W9): hands the Crown back to volume after
    /// `WatchCrownScrub.releaseAfterIdle` with no movement. Restarted by every turn.
    @State private var crownReleaseTask: Task<Void, Never>?
    @State private var programmaticCrownValue: Double?
    @FocusState private var isScrubFocused: Bool
    /// The Bookmark button's outcome after a tap ("Saving…", "Saved", "Not Saved"),
    /// cleared after `WatchBookmarkOutcome.displaySeconds`.
    @State private var bookmarkOutcome: WatchBookmarkOutcome?
    @State private var bookmarkResetTask: Task<Void, Never>?
    /// Batch 410: the open tool sheet, if any.
    @State private var sheet: WatchNowPlayingSheet?
    /// Bumped to hand the Crown back to the volume control.
    @State private var volumeFocusRequest = 0
    /// Critique 2026-10-06 (harden): "Jump back" after a chapter or bookmark tap, for
    /// `WatchJumpBack.visibleSeconds`. Lived on each mode's pager before Batch 410.
    @State private var jumpBack: WatchJumpBack?
    @State private var jumpBackExpiry: Task<Void, Never>?

    /// Critique 2026-10-06 (adapt): sized from the screen, not fixed — 44 + 54 + 44 +
    /// 2 × 12 is wider than a 40 mm screen. See `WatchTransportLayout`.
    private var transportLayout: WatchTransportLayout {
        WatchTransportLayout.forScreenWidth(WKInterfaceDevice.current().screenBounds.width)
    }

    private var headerLayout: WatchNowPlayingHeaderLayout {
        WatchNowPlayingHeaderLayout.forAccessibilitySize(dynamicTypeSize.isAccessibilitySize)
    }

    private var visibleJumpBack: WatchJumpBack? {
        jumpBack?.canApply(currentItemId: model.itemId) == true ? jumpBack : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                if model.isStale {
                    StaleBanner()
                }
                header
                scrubRow
                notice()
                if let jumpBack = visibleJumpBack {
                    jumpBackChip(jumpBack)
                        .transition(.opacity)
                }
                transport
                toolRow
                    .disabled(!model.isReady)
                    .opacity(isLuminanceReduced ? 0.5 : 1)
                if isScrubFocused {
                    Text("Turn Crown to scrub · tap to finish")
                        .font(WatchMetrics.captionFont())
                        .foregroundStyle(WatchTheme.accentText)   // Critique 2026-10-06 (colorize)
                        .accessibilitySortPriority(-1)
                }
            }
            .padding(.horizontal, WatchMetrics.scrollContentHorizontalPadding)
        }
        .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: visibleJumpBack)
        .containerBackground(for: .navigation) { backdrop }
        // No "Now Playing" title (the adapters dropped theirs in Batch 410): like Apple's
        // Now Playing, the book is the title, and the line it took lets the tool row fit
        // the first viewport.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sheet = .more
                } label: {
                    Image(systemName: "ellipsis")
                        .font(WatchMetrics.rowIconFont())
                        .foregroundStyle(WatchTheme.icon)
                }
                .tint(WatchTheme.cardBackground)
                .accessibilityLabel("More")
            }
        }
        .sheet(item: $sheet, onDismiss: { volumeFocusRequest += 1 }) { sheet in
            sheetContent(sheet)
        }
        .onChange(of: crownPosition) { _, newValue in
            // Programmatic-echo guard, verbatim from the NEW-3/P3-7 fixes: consume
            // `programmaticCrownValue` on the first change after it's set, `<= 0.5`.
            let expectedProgrammatic = programmaticCrownValue
            programmaticCrownValue = nil
            if let expectedProgrammatic, abs(expectedProgrammatic - newValue) <= 0.5 {
                return
            }
            commitCrownSeek(to: newValue)
        }
        .onChange(of: isScrubFocused) { _, focused in
            if focused {
                scheduleCrownRelease()
            } else {
                crownReleaseTask?.cancel()
                volumeFocusRequest += 1
            }
        }
        .onAppear {
            programmaticCrownValue = model.elapsed
            crownPosition = model.elapsed
            volumeFocusRequest += 1
        }
        .onChange(of: model.elapsed) { _, newValue in
            guard !isScrubbingWithCrown else { return }
            programmaticCrownValue = newValue
            crownPosition = newValue
        }
        .onDisappear {
            crownSeekTask?.cancel()
            crownReleaseTask?.cancel()
            bookmarkResetTask?.cancel()
            jumpBackExpiry?.cancel()
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WatchNowPlayingSheet) -> some View {
        switch sheet {
        case .speed:
            WatchSpeedSheet(current: model.speed ?? 1) { actions.setSpeed?($0) }
        case .sleep:
            WatchSleepSheet(selected: model.sleepOption,
                            remainingText: model.sleepText,
                            unavailableReason: model.sleepUnavailableReason,
                            hasChapters: !model.chapters.isEmpty,
                            onSelect: { actions.setSleepTimer?($0) },
                            onExtend: WatchSleepExtend.isAvailable(option: model.sleepOption, secondsLeft: model.sleepSecondsLeft)
                                ? actions.extendSleepTimer : nil)
        case .chapters:
            WatchChaptersSheet(chapters: model.chapters,
                               currentTime: model.elapsed,
                               emptyMessage: model.chaptersEmptyMessage) { chapter in
                let from = model.elapsed
                actions.seekToChapter?(chapter)
                offerJumpBack(from: from, to: chapter.start)
            }
        case .bookmarks:
            WatchBookmarksSheet(bookmarks: model.bookmarks,
                                isLoading: model.isLoadingBookmarks,
                                canAdd: model.isReady,
                                onAdd: actions.addBookmark,
                                onSelect: { bookmark in
                                    let from = model.elapsed
                                    actions.seekToBookmark?(bookmark)
                                    offerJumpBack(from: from, to: bookmark.time)
                                },
                                onLoad: actions.loadBookmarks)
        case .more:
            WatchNowPlayingMoreSheet(
                onShowBookmarks: actions.seekToBookmark == nil ? nil : { self.sheet = .bookmarks },
                modeActions: moreActions)
        }
    }

    // MARK: - First viewport

    /// Small cover, a two-line title, and one status line: where it's playing and, when a
    /// timer is running, how long until sleep. Sized so the transport stays on the first
    /// screen of a 41mm watch at the default text size.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if headerLayout.showsCover {
                CoverThumbnail(data: model.coverData, side: coverSide, spinning: model.isPlaying)
                    .opacity(isLuminanceReduced ? 0.6 : 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(WatchMetrics.navigationRowTitleFont(weight: .bold))
                    .foregroundStyle(WatchTheme.primaryText)
                    .lineLimit(headerLayout.titleLineLimit)
                    .multilineTextAlignment(.leading)
                statusLine
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            // Hosts the Crown's volume input. A `WKInterfaceObjectRepresentable` in the
            // toolbar didn't render (simulator, 21 Oct), so it sits at the header's
            // trailing edge; the system draws the level and the focus ring.
            WatchVolumeControl(origin: model.source == .iPhone ? .companion : .local,
                               focusRequest: volumeFocusRequest)
                // It draws itself at about 40 pt whatever frame it's given (simulator,
                // 21 Oct), so it's scaled into the 28 pt slot.
                .frame(width: 40, height: 40)
                .scaleEffect(0.7)
                .frame(width: 28, height: 28)
                .opacity(isLuminanceReduced ? 0 : 1)
                .accessibilityLabel(model.source == .iPhone ? "iPhone volume" : "Watch volume")
        }
    }

    /// Batch 410: the cover grows on bigger screens now that the screen doesn't scroll
    /// (`WatchNowPlayingHeaderLayout.coverSide`).
    private var coverSide: CGFloat {
        let bounds = WKInterfaceDevice.current().screenBounds
        return WatchNowPlayingHeaderLayout.coverSide(screenWidth: bounds.width, screenHeight: bounds.height)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            // Batch 410: the glyph alone (iphone / applewatch, the Shelf's source marks); the
            // word was truncating to "iPh…" beside the volume control.
            Image(systemName: model.source.systemImage)
                .foregroundStyle(WatchTheme.secondaryText)
                .accessibilityLabel(model.source.accessibilityLabel)
            if let sleepText = model.sleepShortText {
                Text(verbatim: "·").foregroundStyle(WatchTheme.secondaryText).accessibilityHidden(true)
                // A running timer is live state, so it takes the accent (The One Light
                // Rule); dimmed with everything else under Always-On.
                Label(sleepText, systemImage: "moon.zzz.fill")
                    .labelStyle(WatchCompactLabelStyle())
                    // Critique 2026-10-06 (colorize): accent as caption text → `accentText`.
                    .foregroundStyle(isLuminanceReduced ? WatchTheme.secondaryText : WatchTheme.accentText)
                    .monospacedDigit()
                    .accessibilityLabel("Sleep timer, \(model.sleepText ?? sleepText)")
            }
        }
        .font(WatchMetrics.captionFont(weight: .medium))
        .lineLimit(1)
    }

    /// Progress plus elapsed/remaining, the crown-scrub target. Under Always-On the times
    /// drop to minutes (`WatchNowPlayingTime`), since the dimmed screen updates rarely and
    /// a seconds readout would sit visibly wrong.
    private var scrubRow: some View {
        VStack(spacing: 3) {
            WatchLinearProgressBar(progress: model.progress)
            HStack {
                Text(WatchNowPlayingTime.elapsed(model.elapsed, minuteLevel: isLuminanceReduced))
                Spacer()
                Text(WatchNowPlayingTime.remaining(model.duration - model.elapsed, minuteLevel: isLuminanceReduced))
            }
            .font(WatchMetrics.captionFont().monospacedDigit())
            .foregroundStyle(WatchTheme.secondaryText)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background {
            if isScrubFocused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(WatchTheme.accent.opacity(0.15))
            }
        }
        .overlay {
            if isScrubFocused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WatchTheme.accent, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.isReady else { return }
            isScrubFocused.toggle()
        }
        .focusable(model.isReady)
        .focused($isScrubFocused)
        .digitalCrownRotation(
            $crownPosition,
            from: 0, through: max(model.duration, 1), by: 1,
            sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true
        )
        // P3-7: one adjustable "Playback position" stop for VoiceOver, through the same
        // commit path a crown turn takes.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(model.elapsed.watchFormattedTime) of \(model.duration.watchFormattedTime)")
        .accessibilityAdjustableAction { direction in
            guard model.isReady else { return }
            let step: Double = 15
            let newValue: Double
            switch direction {
            case .increment: newValue = min(model.duration, model.elapsed + step)
            case .decrement: newValue = max(0, model.elapsed - step)
            @unknown default: return
            }
            commitCrownSeek(to: newValue)
        }
    }

    private var transport: some View {
        let layout = transportLayout
        return HStack(spacing: layout.spacing) {
            WatchControlButton(
                systemImage: SkipLabels.symbolName(backward: true, seconds: model.skipBackwardSeconds),
                label: .verbatim(SkipLabels.accessibilityLabel(backward: true, seconds: model.skipBackwardSeconds)),
                size: layout.skip
            ) {
                actions.skipBackward()
            }
            WatchControlButton(
                systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPlaying ? "Pause" : "Play",
                size: layout.play,
                showsBufferingRing: model.isBuffering
            ) {
                actions.togglePlayPause()
            }
            // Batch 490 (REVIEW 2026-11-11 W2): double tap (Apple Watch Series 9 / Ultra 2
            // and later) plays or pauses, like Apple's Now Playing. Off while a tool sheet
            // is up, so a sheet never shares the gesture with it.
            .modifier(WatchPrimaryActionShortcut(isEnabled: sheet == nil && model.isReady))
            WatchControlButton(
                systemImage: SkipLabels.symbolName(backward: false, seconds: model.skipForwardSeconds),
                label: .verbatim(SkipLabels.accessibilityLabel(backward: false, seconds: model.skipForwardSeconds)),
                size: layout.skip
            ) {
                actions.skipForward()
            }
        }
        .disabled(!model.isReady)
        .padding(.top, 2)
    }

    // MARK: - Tools

    /// Speed, Sleep, Chapters, Bookmark: each one tap from the transport. Speed and
    /// Sleep show their current value. Bookmark adds on a tap (the run case: no sheet to
    /// dismiss) and lists on a long press; the list is also in "⋯".
    @ViewBuilder
    private var toolRow: some View {
        HStack(spacing: 2) {
            if let speed = model.speed, actions.setSpeed != nil {
                let label = WatchSpeedCycler.label(for: speed)
                toolButton(systemImage: "speedometer", title: label,
                           accessibilityLabel: String(localized: "Playback speed, \(label)"),
                           accessibilityHint: String(localized: "Opens speed options"),
                           action: { sheet = .speed })
            }
            if actions.setSleepTimer != nil {
                toolButton(systemImage: model.sleepText == nil ? "moon.zzz" : "moon.zzz.fill",
                           title: model.sleepText ?? String(localized: "Sleep", comment: "Short label under the sleep timer button on the Watch Now Playing screen"),
                           accessibilityLabel: model.sleepText.map { String(localized: "Sleep timer, \($0)") } ?? String(localized: "Sleep timer, off"),
                           accessibilityHint: String(localized: "Opens sleep timer options"),
                           action: { sheet = .sleep })
            }
            if actions.seekToChapter != nil {
                toolButton(systemImage: "list.bullet",
                           title: String(localized: "Chapters", comment: "Short label under the chapters button on the Watch Now Playing screen"),
                           accessibilityLabel: String(localized: "Chapters"),
                           accessibilityHint: String(localized: "Opens the chapter list"),
                           action: { sheet = .chapters })
            }
            if let addBookmark = actions.addBookmark {
                bookmarkTool(addBookmark: addBookmark)
            }
        }
    }

    /// A tap adds a bookmark; a long press opens the list. Not a `Button`: a Button's tap
    /// would also fire when the long press lifts. VoiceOver gets both as actions.
    private func bookmarkTool(addBookmark: @escaping (@escaping (WatchBookmarkOutcome) -> Void) -> Void) -> some View {
        let add = {
            guard bookmarkOutcome != .saving else { return }
            // Batch 490 (REVIEW 2026-11-11 W8): no tap haptic here; the outcome plays the
            // one haptic a bookmark add gets (`WatchFeedbackHaptic.forBookmark`).
            show(bookmarkOutcome: .saving)
            addBookmark { outcome in show(bookmarkOutcome: outcome) }
        }
        return toolLabel(systemImage: bookmarkOutcome?.systemImage ?? "bookmark",
                         title: bookmarkOutcome?.title ?? String(localized: "Bookmark", comment: "Short label under the add-bookmark button on the Watch Now Playing screen"))
            .onTapGesture { add() }
            .onLongPressGesture(minimumDuration: 0.5) {
                WatchHaptics.tap()
                sheet = .bookmarks
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bookmarkOutcome?.accessibilityLabel ?? String(localized: "Add bookmark at current position"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { add() }
            .accessibilityAction(named: Text("Show Bookmarks")) { sheet = .bookmarks }
    }

    private func toolButton(systemImage: String, title: String, accessibilityLabel: String,
                            accessibilityHint: String, action: @escaping () -> Void) -> some View {
        Button {
            WatchHaptics.tap()
            action()
        } label: {
            toolLabel(systemImage: systemImage, title: title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private func toolLabel(systemImage: String, title: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(WatchMetrics.rowIconFont())
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WatchTheme.icon)
            Text(title)
                .font(WatchMetrics.captionFont(weight: .medium).monospacedDigit())
                .foregroundStyle(WatchTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// Shows `outcome` on the Bookmark button, then returns it to "Bookmark".
    private func show(bookmarkOutcome outcome: WatchBookmarkOutcome) {
        bookmarkOutcome = outcome
        // Batch 490 (REVIEW 2026-11-11 W8): success too now, since nothing else plays one.
        switch WatchFeedbackHaptic.forBookmark(outcome) {
        case .success: WatchHaptics.success()
        case .failure: WatchHaptics.failure()
        case nil: break
        }
        // Critique 2026-10-06 (polish): the result only changed the button's label, which
        // VoiceOver doesn't re-read by itself. `AccessibilityNotification.Announcement` is
        // watchOS 10.0 (Apple docs), this target's floor.
        if outcome != .saving {
            AccessibilityNotification.Announcement(outcome.accessibilityLabel).post()
        }
        bookmarkResetTask?.cancel()
        bookmarkResetTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(outcome.displaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            bookmarkOutcome = nil
        }
    }

    /// Critique 2026-10-06 (harden): the undo for a chapter or bookmark jump. Sits right
    /// above the transport for `WatchJumpBack.visibleSeconds`, so it's on screen when
    /// the sheet closes.
    private func jumpBackChip(_ jumpBack: WatchJumpBack) -> some View {
        Button {
            WatchHaptics.tap()
            restoreJumpBack()
        } label: {
            Label(jumpBack.label, systemImage: "arrow.uturn.backward")
                .font(WatchMetrics.secondaryFont(weight: .semibold).monospacedDigit())
                .foregroundStyle(WatchTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(jumpBack.label)
        .accessibilityHint("Undoes the last chapter or bookmark jump")
    }

    private func offerJumpBack(from: Double, to: Double) {
        guard let offer = WatchJumpBack.make(itemId: model.itemId, from: from, to: to) else { return }
        jumpBack = offer
        jumpBackExpiry?.cancel()
        jumpBackExpiry = Task {
            try? await Task.sleep(nanoseconds: UInt64(WatchJumpBack.visibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            jumpBack = nil
        }
    }

    private func restoreJumpBack() {
        guard let offer = jumpBack else { return }
        jumpBack = nil
        jumpBackExpiry?.cancel()
        guard offer.canApply(currentItemId: model.itemId) else { return }
        actions.seek(offer.restoreTime)
    }

    // MARK: - Backdrop

    /// The blurred-cover backdrop standalone already had, now for both modes, carried by
    /// the navigation container background (the pager page's until Batch 410). Under Always-On the HIG suggests
    /// "removing the images and using dimmed colors", so it falls back to black.
    private var backdrop: some View {
        // Own view so the decode + blur only re-run when the cover bytes change, not on
        // every ~1 s playback tick that re-evaluates this screen's body.
        WatchCoverBackdrop(coverData: model.coverData)
    }

    // MARK: - Crown commit

    /// Shared by a real crown turn (once its debounce elapses) and the VoiceOver
    /// adjustable action. A still-turning crown keeps resetting the debounce, so the
    /// seek commits once the user stops for 350ms.
    ///
    /// Batch 490 (REVIEW 2026-11-11 W9): committing no longer drops focus. A pause to
    /// check the time used to hand the Crown back to volume, so the next turn changed the
    /// volume instead. The Crown now stays on the scrubber until the row is tapped again
    /// or `WatchCrownScrub.releaseAfterIdle` passes with no movement.
    private func commitCrownSeek(to newValue: Double) {
        isScrubbingWithCrown = true
        if isScrubFocused { scheduleCrownRelease() }
        crownSeekTask?.cancel()
        crownSeekTask = Task {
            try? await Task.sleep(nanoseconds: WatchCrownScrub.nanoseconds(WatchCrownScrub.seekDebounce))
            guard !Task.isCancelled else { return }
            programmaticCrownValue = newValue
            crownPosition = newValue
            actions.seek(newValue)
            isScrubbingWithCrown = false
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 W9): (re)starts the idle countdown that returns the
    /// Crown to volume.
    private func scheduleCrownRelease() {
        crownReleaseTask?.cancel()
        crownReleaseTask = Task {
            try? await Task.sleep(nanoseconds: WatchCrownScrub.nanoseconds(WatchCrownScrub.releaseAfterIdle))
            guard !Task.isCancelled else { return }
            isScrubFocused = false
        }
    }
}

extension WatchNowPlayingScreen where MoreActions == EmptyView {
    init(model: WatchNowPlayingModel, actions: WatchNowPlayingActions,
         @ViewBuilder notice: @escaping () -> Notice) {
        self.init(model: model, actions: actions, notice: notice, moreActions: { EmptyView() })
    }
}

/// Batch 490 (REVIEW 2026-11-11 W2): makes Play/Pause the scene's double-tap primary
/// action. `handGestureShortcut(_:isEnabled:)` is watchOS 11.0 (Apple docs), above this
/// target's watchOS 10 floor, so earlier systems get the control unchanged.
private struct WatchPrimaryActionShortcut: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction, isEnabled: isEnabled)
        } else {
            content
        }
    }
}

/// Icon and title side by side with a tight gap, for the one-line status rows.
struct WatchCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// Blurred cover behind Now Playing. Split out of `WatchNowPlayingScreen` so SwiftUI can
/// skip its body (and the `UIImage(data:)` decode) while `coverData` is unchanged.
private struct WatchCoverBackdrop: View {
    let coverData: Data?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        #if canImport(UIKit)
        if !isLuminanceReduced, let data = coverData, let image = WatchDecodedCoverCache.image(for: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 20)
                .overlay(WatchTheme.background.opacity(0.6))
                .transition(.opacity)
        } else if isLuminanceReduced {
            WatchTheme.background
        } else {
            WatchTheme.nowPlayingBackground
        }
        #else
        WatchTheme.nowPlayingBackground
        #endif
    }
}
