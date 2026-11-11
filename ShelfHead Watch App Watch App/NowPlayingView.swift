import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Screen 2 — Now Playing, companion mode. State comes from `WatchConnectivityStore`,
/// with local time estimated between snapshots via `WatchProgressEstimator` (see
/// `store.estimatedCurrentTime`) rather than re-syncing every second.
///
/// Critique 2026-10-06 (adapt + distill): this is now only the companion *adapter*. The
/// layout itself is `WatchNowPlayingScreen`, shared with standalone mode, so the two
/// modes can't drift apart again. What used to live on the Controls page (Speed,
/// Bookmark) and the Progress page (Mark as Finished) is folded in here: Speed and
/// Bookmark in the shared tool row, Mark as Finished in this adapter's footer. The
/// crown-scrub history (WATCH-4, NEW-3, P3-7, HIG audit L13) moved with the code into
/// `WatchNowPlayingScreen`; the behaviour is unchanged — the crown pages by default and
/// scrubs only once the time row is tapped.
struct NowPlayingView: View {
    // Batch 410 (Watch redesign): `NowPlayingPagerView` is gone. This adapter is the
    // whole companion Now Playing now; Chapters, Bookmarks and Sleep are the shared
    // sheets `WatchNowPlayingScreen` opens, fed from this model, and Mark as Finished
    // moved from the footer into the "⋯" sheet. "Jump back" state moved into the
    // screen, which owns the sheets that trigger it.
    @Environment(WatchConnectivityStore.self) private var store
    @Environment(WatchStore.self) private var watchStore

    var body: some View {
        Group {
            if let state = store.playbackState, state.hasActiveItem {
                WatchNowPlayingScreen(
                    model: model(for: state),
                    actions: actions,
                    notice: { phoneNotice(for: state) },
                    moreActions: { MarkFinishedRow(title: state.title) }
                )
            } else if store.hasReceivedAnySnapshot {
                WatchOpenOniPhoneEmptyState(systemImage: "play.slash", message: "Nothing playing on iPhone")
                    .containerBackground(WatchTheme.nowPlayingBackground, for: .navigation)
            } else {
                WatchOpenOniPhoneEmptyState()
                    .containerBackground(WatchTheme.nowPlayingBackground, for: .navigation)
            }
        }
    }

    /// Polish pass (WA-6): an inline, self-clearing status where a "Command Failed" alert used to
    /// cover the screen, with a way out when this Watch can play the book itself.
    @ViewBuilder
    private func phoneNotice(for state: WatchPlaybackState) -> some View {
        if store.phoneUnreachableNotice {
            VStack(spacing: 4) {
                Label("iPhone not reachable", systemImage: "iphone.slash")
                    .font(WatchMetrics.captionFont(weight: .medium))
                    .foregroundStyle(WatchTheme.secondaryText)
                if watchStore.authState == .active {
                    Button {
                        Task {
                            await watchStore.standalone.play(itemId: state.itemId, title: state.title, author: state.author)
                        }
                    } label: {
                        Label("Play on this Watch", systemImage: "applewatch")
                            .font(WatchMetrics.captionFont(weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Starts this book on the Watch instead of your iPhone")
                }
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        }
    }

    private func model(for state: WatchPlaybackState) -> WatchNowPlayingModel {
        let sleepLeft: Double? = (state.sleepTimerOption != .off && state.sleepTimerRemaining > 0)
            ? state.sleepTimerRemaining : nil
        return WatchNowPlayingModel(
            title: state.title,
            author: state.author,
            chapterTitle: state.chapterTitle,
            coverData: state.coverData,
            elapsed: store.estimatedCurrentTime,
            duration: state.duration,
            isPlaying: state.isPlaying,
            // LS-1: buffering was tracked but never shown.
            isBuffering: state.isBuffering,
            // WATCH-5 / Review 2026-08-19: the phone's real synced intervals, through
            // `SkipLabels` so an unshipped symbol snaps to the nearest one.
            skipBackwardSeconds: state.skipBackwardInterval,
            skipForwardSeconds: state.skipForwardInterval,
            speed: state.playbackRate,
            sleepSecondsLeft: sleepLeft,
            source: .iPhone,
            isStale: store.isStateStale,
            itemId: state.itemId,
            chapters: store.chapters.map { WatchChapterRow(id: $0.id, title: $0.title, start: $0.start, end: $0.end) },
            // Critique 2026-10-06 (clarify): "not synced yet" and "no chapters" read differently.
            chaptersEmptyMessage: WatchChaptersEmptyState.message(hasActiveItem: true, isStale: store.isStateStale),
            bookmarks: store.bookmarks.map { WatchBookmarkRow(id: $0.id, title: $0.title, time: $0.time) },
            // WATCH-5: the phone's synced option, not what was last tapped here.
            sleepOption: state.sleepTimerOption
        )
    }

    private var actions: WatchNowPlayingActions {
        WatchNowPlayingActions(
            togglePlayPause: { store.togglePlayPause() },
            skipBackward: { store.rewind() },
            skipForward: { store.forward() },
            seek: { store.seek(to: $0) },
            setSpeed: { store.setPlaybackSpeed($0) },
            addBookmark: { report in
                store.addBookmarkAtCurrentPosition { ok in report(ok ? .saved : .failed) }
            },
            setSleepTimer: { store.setSleepTimer($0) },
            // Batch 490 (REVIEW 2026-11-11 F29): "Add 15 Minutes", applied on the phone.
            extendSleepTimer: { store.extendSleepTimer() },
            seekToChapter: { row in
                store.seekToChapter(WatchChapterSummary(id: row.id, title: row.title, start: row.start, end: row.end))
            },
            seekToBookmark: { row in
                store.seekToBookmark(WatchBookmarkSummary(id: row.id, title: row.title, time: row.time))
            }
        )
    }
}

/// Mark as Finished, in the "⋯" sheet. Was its own pager page (`BookProgressView`), then
/// Now Playing's footer; same confirmation, and disabled with a visible reason when the
/// phone can't take it (`markFinished()` refuses while unreachable).
private struct MarkFinishedRow: View {
    @Environment(WatchConnectivityStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var showConfirm = false

    var body: some View {
        let reason: String? = !store.isReachable ? String(localized: "Needs your iPhone nearby")
            : store.isStateStale ? String(localized: "Waiting for your iPhone to sync") : nil
        Button {
            showConfirm = true
        } label: {
            VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                Label("Mark as Finished", systemImage: "checkmark.circle")
                if let reason {
                    Text(reason)
                        .font(WatchMetrics.captionFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(reason != nil)
        .accessibilityHint(reason ?? "")
        .confirmationDialog(
            "Mark \u{201C}\(title)\u{201D} as finished?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark as Finished") {
                store.markFinished()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Small cover thumbnail with a graceful book-icon fallback when no cover data has
/// synced yet (covers are fetched lazily and pushed after the first snapshot).
///
/// Stage 5 (REDESIGN_PROPOSAL_2026-08-26.md §8.1b, §14.6): `spinning` adds a small
/// reel badge in the corner — the same "tape hardware appears only where audio is
/// actually moving" signal `CassetteTile`/`MiniPlayerView` already give on the phone,
/// now on the one Watch surface where "is it actually playing" is the single most-
/// asked question. Timer-gating mirrors those two exactly: paused whenever
/// `spinning` is false OR the scene isn't `.active` (the Watch equivalent of
/// `MiniPlayerView` folding its own visibility into the same check) — an
/// always-on-display timer that keeps ticking after the app is backgrounded would be
/// a battery bug, not a design flourish, so this reel has no path to running when
/// nobody can see it.
struct CoverThumbnail: View {
    let data: Data?
    var side: CGFloat = 44
    var spinning: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let data, let image = WatchDecodedCoverCache.image(for: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    // AN-10 (docs/design-review.md): fades in when the cover bytes arrive
                    // with the phone's snapshot, like the AN-1 standalone thumbnail.
                    .transition(.opacity)
            } else {
                fallback
                    .transition(.opacity)
            }
            #else
            fallback
            #endif
        }
        // AN-10: keyed on "has a cover", so only the placeholder → cover change animates.
        // A cover that's already in `data` when the view first appears renders straight
        // away (the value never changes), and Reduce Motion gets no animation via
        // `watchAnimation`.
        .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: data != nil)
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if spinning {
                WatchSpinningReelBadge(active: scenePhase == .active)
                    .padding(2)
            }
        }
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(WatchTheme.cardBorder)
            .overlay(Image(systemName: "book.closed.fill").foregroundStyle(WatchTheme.secondaryText))
    }
}

/// Stage 5 (REDESIGN_PROPOSAL_2026-08-26.md §8.1b): the reel itself. `active` being
/// false stops the `TimelineView`'s timer outright (not just visually — `paused:`
/// on `.animation(...)` means no ticks are scheduled at all), the same guarantee
/// `CassetteReel`/`CassetteTileReelHub` give on the phone.
///
/// PL-10 (docs/design-review.md, Round 5): wrist-down/Always-On is a separate state
/// from `scenePhase == .active` — the scene stays `.active` while the display just
/// dims, so `isLuminanceReduced` is the signal to fold in here. Per
/// developer.apple.com/documentation/swiftui/environmentvalues/isluminancereduced
/// (checked via scripts/appledoc.sh; watchOS 8.0+), watchOS sets this `true` when the
/// user lowers their wrist but keeps the view visible rather than blurring it, so the
/// badge would otherwise keep ticking the `TimelineView` at up to 15 fps the whole
/// time the wrist is down — wasted battery on a screen nobody's reading, on top of
/// looking wrong. Folding it into `animate` pauses the `TimelineView`'s timer outright
/// (same `paused:` guarantee as the Reduce Motion case above).
private struct WatchSpinningReelBadge: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let animate = active && !reduceMotion && !isLuminanceReduced
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !animate)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate * 90
            // Rests at a fixed 0° rather than the angle mid-spin when it stopped —
            // matches the Reduce Motion behaviour already below, so wrist-down doesn't
            // introduce a second "stuck at an arbitrary angle" look.
            reel.rotationEffect(.degrees(animate ? degrees : 0))
        }
        .frame(width: 12, height: 12)
        .background(Color.black.opacity(0.55), in: Circle())
        .accessibilityHidden(true)
    }

    private var reel: some View {
        ZStack {
            Circle().strokeBorder(WatchTheme.secondaryText, lineWidth: 1.5)
            Circle().fill(WatchTheme.secondaryText).frame(width: 6, height: 6)
                .offset(y: -3.5)
        }
        .padding(1.5)
    }
}

/// Shown whenever the last known playback snapshot is older than
/// `WatchStaleness.threshold` — signals to the user that what they're seeing (and any
/// action they take) may not reflect the phone's real state.
///
/// Critique 2026-10-06 (colorize): was hard-coded black ink on the accent fill. The
/// accent means "press here / live", and a stale state is a warning, so the fill is now
/// DESIGN.md's Burnt Orange (`WatchTheme.alert`) with contrast-picked ink
/// (`WatchTheme.alertInk`), the phone's `shelfOrange`/`shelfOrangeInk` pair.
struct StaleBanner: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Syncing…")
        }
        .font(WatchMetrics.subtitleFont(weight: .medium))
        .foregroundStyle(WatchTheme.alertInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(WatchTheme.alert, in: Capsule())
        .accessibilityLabel("Playback state is out of date, syncing with iPhone")
    }
}

#Preview {
    NavigationStack { NowPlayingView() }
        .environment(WatchConnectivityStore.shared)
        .environment(WatchStore.shared)
}
