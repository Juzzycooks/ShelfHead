import SwiftUI

/// Now Playing for standalone mode — this Watch's own engine (`StandaloneAudioEngine`),
/// no phone.
///
/// Stage 3 (addendum §10.2) built this as a parallel screen to the companion
/// `NowPlayingPagerView`. Critique 2026-10-06 (shape → adapt + distill) did the merge
/// that stage deferred, at the layout level: this is now the standalone *pager*, with the
/// same four pages in the same order as companion (since removed, Batch 410),
/// and its first page is the shared `WatchNowPlayingScreen` fed from the engine
/// (`StandaloneNowPlayingPage`). The old screen stacked a 120pt cover, a two-line Title 3
/// title, the author and the time row above Play, which pushed Play below the fold on
/// 41/45mm; chapters, sleep and bookmarks were links at the bottom of the scroll. Speed
/// is new here (`StandaloneAudioEngine.setPlaybackRate`).
///
/// Batch 410 (Watch redesign, The Shelf): the pager is gone here as in companion mode.
/// Chapters, Bookmarks and Sleep are the shared sheets `WatchNowPlayingScreen` opens, fed
/// from the engine; Stop Playing moved from the footer into the "⋯" sheet.
///
/// Reached from Recently Added and Downloads (cover bytes in hand, `coverData`), from
/// `StandaloneLibraryView` (no cover yet, `coverItemId`), and from the home hero.
/// `coverData` wins if both are given.
struct StandaloneNowPlayingView: View {
    @Environment(WatchStore.self) private var watchStore
    @Environment(\.dismiss) private var dismiss

    let itemId: String
    let title: String
    let author: String
    var coverData: Data? = nil
    /// Stage 4: when set (and `coverData` is nil), the cover is fetched live via
    /// `WatchCoverLoader` instead of rendered from already-in-hand bytes.
    var coverItemId: String? = nil

    /// One copy of the cover bytes drives both the sharp cover and the blurred backdrop
    /// (31 August 2026). `WatchCoverLoader` caches by URL, so this is usually a cache hit.
    @State private var resolvedCoverData: Data?
    /// Set when pushing this book would cut off a different book already playing — on
    /// this Watch, or (Critique 2026-10-06, shape → harden) on the iPhone, now that "Play
    /// on Watch" is offered while the phone is nearby.
    @State private var pendingReplace: PendingReplace?
    @State private var confirmedReplace = false

    /// What the confirmation is about: the book playing and where it's playing.
    private struct PendingReplace: Equatable {
        enum Place: Equatable { case watch, iPhone }
        let currentTitle: String
        let place: Place

        var message: String {
            switch place {
            // Critique 2026-10-06 (polish): same shape as companion's "stops on your iPhone".
            case .watch: return String(localized: "\u{201C}\(currentTitle)\u{201D} stops on this Watch.", comment: "Confirmation message; %@ is the title of the book now playing")
            // Pausing keeps the iPhone's place, so it says pauses, not stops.
            case .iPhone: return String(localized: "\u{201C}\(currentTitle)\u{201D} pauses on your iPhone.", comment: "Confirmation message; %@ is the title of the book now playing")
            }
        }
    }
    /// Critique 2026-10-06 (harden): one bookmark store for the tool row's Bookmark
    /// button and the Bookmarks sheet, so a bookmark just added is in the list.
    @State private var bookmarks = StandaloneBookmarkStore(api: WatchAudiobookshelfAPI.shared, queue: WatchPendingBookmarkQueue.shared)
    /// Batch 490 (REVIEW 2026-11-11 W5): a different book the engine loaded while this
    /// screen was up (started from another screen, Siri, a hand-off). The screen follows
    /// it instead of sitting on "Starting…" for the book it was opened with.
    @State private var followed: FollowedBook?

    private struct FollowedBook: Equatable {
        let itemId: String
        let title: String
        let author: String
    }

    private var engine: StandaloneAudioEngine { watchStore.standalone }
    private var shownItemId: String { followed?.itemId ?? itemId }

    var body: some View {
        StandaloneNowPlayingPage(
            itemId: shownItemId, title: followed?.title ?? title, author: followed?.author ?? author,
            coverData: resolvedCoverData,
            isAwaitingConfirmation: pendingReplace != nil,
            bookmarks: bookmarks,
            onStopped: { dismiss() })
        .task(id: itemId) {
            // Critique 2026-10-06 (harden): pushing a book used to start it at once,
            // which silently replaced a different book already playing on the Watch.
            // Same book: show it. Nothing loaded, or a paused different book: play.
            // A different book playing right now: ask first.
            //
            // Build-fix (Stage 4) history: `play(...)` tears down and rebuilds the
            // player itself, so no stop-before-switch is needed here.
            //
            // Critique 2026-10-06 (shape → harden): this screen is now also reached from
            // companion mode ("Play on Watch" is a downloaded book's primary action in
            // both modes). The Watch and the iPhone shouldn't both play into the same
            // headphones, so a playing iPhone is paused through the existing command
            // channel: at once when it's the same book (a hand-off — the engine resumes
            // from the iPhone's snapshot), after the same replace question when it's a
            // different one (`WatchPlayOnWatchPhoneAction`). Once the book loads, the
            // Watch holds its own mode until it's stopped (`WatchStore.nextMode`).
            switch StandalonePlayRequest.decide(
                requestedItemId: itemId, loadedItemId: engine.currentItemId,
                isLoaded: engine.isLoaded, isPlaying: engine.isPlaying, loadedTitle: engine.itemTitle) {
            case .playNow:
                switch watchStore.phoneActionForPlayingOnWatch(itemId: itemId) {
                case .nothing:
                    await engine.play(itemId: itemId, title: title, author: author)
                case .pausePhone:
                    watchStore.pausePhoneIfPlaying()
                    await engine.play(itemId: itemId, title: title, author: author)
                case .confirmPausingPhone(let currentTitle):
                    pendingReplace = PendingReplace(currentTitle: currentTitle, place: .iPhone)
                }
            case .alreadyLoaded:
                break
            case .confirmReplacing(let currentTitle):
                pendingReplace = PendingReplace(currentTitle: currentTitle, place: .watch)
            }
        }
        .task(id: shownItemId) {
            if let followed {
                // Batch 490 (W5): the followed book's own cover, not the one passed in.
                resolvedCoverData = nil
                resolvedCoverData = await WatchCoverLoader.shared.loadCoverData(itemId: followed.itemId, width: 240)
            } else if let coverData {
                resolvedCoverData = coverData
            } else {
                resolvedCoverData = await WatchCoverLoader.shared.loadCoverData(itemId: coverItemId ?? itemId, width: 240)
            }
        }
        .onChange(of: engine.currentItemId) { previous, loaded in
            guard StandaloneNowPlayingFollow.shouldFollow(
                shownItemId: shownItemId, previousLoadedItemId: previous, newLoadedItemId: loaded,
                isLoaded: engine.isLoaded, isConfirming: pendingReplace != nil),
                  let loaded else { return }
            followed = loaded == itemId ? nil : FollowedBook(itemId: loaded, title: engine.itemTitle, author: engine.itemAuthor)
        }
        .confirmationDialog(
            "Play \u{201C}\(title)\u{201D}?",
            isPresented: Binding(
                get: { pendingReplace != nil },
                set: { presented in
                    guard !presented else { return }
                    // Dismissed without choosing Play (Cancel, or swiped away): go back
                    // to where the tap came from, leaving the current book playing.
                    if !confirmedReplace { dismiss() }
                    pendingReplace = nil
                }),
            titleVisibility: .visible
        ) {
            Button("Play") {
                confirmedReplace = true
                Task {
                    // A no-op unless the iPhone is reachable and playing.
                    watchStore.pausePhoneIfPlaying()
                    await engine.play(itemId: itemId, title: title, author: author)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingReplace?.message ?? "")
        }
        // Stage 4: no longer stops playback on disappear — leaving this screen while a
        // book keeps playing is the normal case. "Stop" (toolbar) ends it explicitly.
    }
}

/// The standalone adapter for `WatchNowPlayingScreen`: engine state in, engine commands
/// out. Until the requested book is the one loaded (still starting, or waiting on the
/// replace confirmation), it shows that book's title with the transport disabled, so the
/// layout doesn't jump when playback lands.
private struct StandaloneNowPlayingPage: View {
    @Environment(WatchStore.self) private var watchStore
    let itemId: String
    let title: String
    let author: String
    let coverData: Data?
    let isAwaitingConfirmation: Bool
    /// Shared with the Bookmarks sheet (see `StandaloneNowPlayingView.bookmarks`).
    let bookmarks: StandaloneBookmarkStore
    /// Critique 2026-10-06 (harden): after Stop, leave this screen (there's nothing left
    /// to control); the hero then offers "Resume".
    let onStopped: () -> Void

    private var engine: StandaloneAudioEngine { watchStore.standalone }
    private var isThisBookLoaded: Bool { engine.isLoaded && engine.currentItemId == itemId }

    var body: some View {
        WatchNowPlayingScreen(model: model, actions: actions) {
            notice
        } moreActions: {
            StopPlayingRow(isLoaded: isThisBookLoaded)
        }
        // Batch 410: Stop now sits in the "⋯" sheet, which can't pop this screen itself.
        // Leaving once the book unloads covers Stop, and the end of the book too.
        .onChange(of: isThisBookLoaded) { wasLoaded, isLoaded in
            if wasLoaded && !isLoaded && !engine.isLoaded { onStopped() }
        }
    }

    private var model: WatchNowPlayingModel {
        guard isThisBookLoaded else {
            return WatchNowPlayingModel(
                title: title, author: author, chapterTitle: nil, coverData: coverData,
                elapsed: 0, duration: 0, isPlaying: false, isReady: false,
                skipBackwardSeconds: engine.skipBackwardInterval,
                skipForwardSeconds: engine.skipForwardInterval,
                speed: engine.playbackRate, sleepSecondsLeft: nil, source: .watch,
                sleepUnavailableReason: String(localized: "Play a book on this Watch to set a sleep timer."))
        }
        return WatchNowPlayingModel(
            title: engine.itemTitle.isEmpty ? title : engine.itemTitle,
            author: engine.itemAuthor.isEmpty ? author : engine.itemAuthor,
            chapterTitle: StandaloneSleepTimer.chapter(in: engine.chapters, at: engine.currentTime)?.title,
            coverData: coverData,
            elapsed: engine.currentTime,
            duration: engine.duration,
            isPlaying: engine.isPlaying,
            // Batch 490 (REVIEW 2026-11-11 F29): the ring while a stream stalls; never
            // for a download (`StandaloneAudioEngine.isBuffering`).
            isBuffering: engine.isBuffering,
            // The engine's own intervals (its skip commands and the remote-command
            // router's `preferredIntervals` use the same values; Batch 495 W7 made them
            // the iPhone's), so the glyph and the VoiceOver label state what a tap does.
            skipBackwardSeconds: engine.skipBackwardInterval,
            skipForwardSeconds: engine.skipForwardInterval,
            speed: engine.playbackRate,
            sleepSecondsLeft: engine.sleepTimer?.secondsLeft(currentTime: engine.currentTime),
            source: .watch,
            itemId: engine.currentItemId,
            chapters: engine.chapters.map { WatchChapterRow(id: $0.id, title: $0.title, start: $0.start, end: $0.end) },
            chaptersEmptyMessage: String(localized: "No chapters for this book"),
            bookmarks: bookmarks.bookmarks.map {
                WatchBookmarkRow(id: $0.id, title: $0.title, time: $0.time, isPending: $0.isPending)
            },
            isLoadingBookmarks: bookmarks.isLoading,
            sleepOption: engine.sleepTimer?.option ?? .off)
    }

    private var actions: WatchNowPlayingActions {
        WatchNowPlayingActions(
            togglePlayPause: { engine.togglePlayPause() },
            skipBackward: { engine.skipBackward() },
            skipForward: { engine.skipForward() },
            seek: { engine.seek(to: $0) },
            setSpeed: { engine.setPlaybackRate($0) },
            addBookmark: { report in addBookmark(report: report) },
            setSleepTimer: { engine.setSleepTimer($0) },
            extendSleepTimer: { engine.extendSleepTimer() },
            seekToChapter: { engine.seek(to: $0.start) },
            seekToBookmark: { engine.seek(to: $0.time) },
            loadBookmarks: {
                if let itemId = engine.currentItemId { await bookmarks.load(itemId: itemId) }
            })
    }

    /// Tries the server, queues offline (`StandaloneBookmarkStore.add`).
    /// Critique 2026-10-06 (harden): reports what happened — sent, or kept on the Watch
    /// to sync later — instead of a blanket "Saved".
    private func addBookmark(report: @escaping (WatchBookmarkOutcome) -> Void) {
        guard let itemId = engine.currentItemId else {
            report(.failed)
            return
        }
        let chapter = StandaloneSleepTimer.chapter(in: engine.chapters, at: engine.currentTime)?.title
        let time = engine.currentTime
        Task {
            // Review 6 Low (dropped bookmark): a bookmark the server refused isn't "saved offline".
            switch await bookmarks.addOutcome(itemId: itemId, time: time, chapterTitle: chapter) {
            // Batch 490 (REVIEW 2026-11-11 W8): no `WatchHaptics.success()` here; the
            // outcome UI plays it, and both together buzzed twice.
            case .sent: report(.saved)
            case .queued: report(.savedOffline)
            case .dropped: report(.failed)
            }
        }
    }

    /// Between the time row and the transport: an error, the audio-route notice
    /// (§10.4 — never a silent speaker fallback), or a spinner while the session starts
    /// (PL-6).
    ///
    /// Critique 2026-10-06 (harden): the route notice now reports what activation
    /// actually did (`StandaloneRouteIssue`), after the system has had its chance to
    /// connect headphones or show its picker. Its button works whether the book is
    /// still to load or already loaded and paused (a mid-run disconnect); the old "Play
    /// Anyway" only appeared before loading.
    @ViewBuilder
    private var notice: some View {
        if let errorMessage = engine.errorMessage {
            // Critique 2026-10-06 (colorize): alert-hued glyph, cream sentence.
            WatchAlertNotice(text: .verbatim(errorMessage), alignment: .center)
        }
        if let issue = engine.routeIssue, !isAwaitingConfirmation {
            VStack(spacing: 6) {
                Label(issue.message, systemImage: issue == .speakerOnly ? "speaker.wave.2" : "headphones")
                    .font(WatchMetrics.subtitleFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .multilineTextAlignment(.center)
                if let actionTitle = issue.actionTitle {
                    Button(actionTitle) {
                        let acceptSpeaker = issue == .speakerOnly
                        Task {
                            if isThisBookLoaded {
                                await engine.resume(acknowledgingSpeakerRoute: acceptSpeaker)
                            } else {
                                await engine.play(itemId: itemId, title: title, author: author,
                                                  acknowledgingSpeakerRoute: acceptSpeaker)
                            }
                        }
                    }
                    .font(WatchMetrics.secondaryFont(weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
        } else if !isThisBookLoaded && engine.errorMessage == nil && !isAwaitingConfirmation {
            // Critique 2026-10-06 (harden): was a bare spinner for up to 3 s while a
            // download checks the server for a newer place. Now it says what's happening.
            HStack(spacing: 6) {
                ProgressView()
                    .tint(WatchTheme.accent)
                    .controlSize(.mini)
                Text(engine.isCheckingPlace ? "Checking your place\u{2026}" : "Starting\u{2026}")
                    .font(WatchMetrics.subtitleFont())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview {
    NavigationStack {
        StandaloneNowPlayingView(itemId: "preview", title: "Preview Book", author: "Preview Author", coverData: nil)
    }
    .environment(WatchStore.shared)
}

/// Stop Playing, in the "⋯" sheet. Was the foot of Now Playing below the tool row; before
/// that an unconfirmed toolbar button that touched Downloads on 40 mm. Not confirmed —
/// Stop saves the place and the hero offers Resume, and the HIG's alerts page says to
/// "avoid displaying alerts for common, undoable actions, even when they're destructive".
private struct StopPlayingRow: View {
    @Environment(WatchStore.self) private var watchStore
    @Environment(\.dismiss) private var dismiss
    let isLoaded: Bool

    var body: some View {
        if isLoaded {
            Button(role: .destructive) {
                dismiss()
                watchStore.standalone.stop()
            } label: {
                Label("Stop Playing", systemImage: "stop.fill")
            }
            .accessibilityHint("Saves your place and leaves Now Playing")
        }
    }
}
