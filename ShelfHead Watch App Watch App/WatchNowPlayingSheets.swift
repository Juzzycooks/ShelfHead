import SwiftUI
import WatchKit
import Accessibility

// Batch 410 (Watch redesign, The Shelf — docs/design/watch-redesign-2026-10-21.md §6):
// Speed, Sleep, Chapters and Bookmarks as single sheets shared by both modes. Before
// this they were pages 2–4 of a vertical pager, written twice: `ChaptersView`,
// `BookmarksView` and `SleepTimerView` read `WatchConnectivityStore`, and
// `StandaloneChaptersView`, `StandaloneBookmarksView` and `StandaloneSleepTimerView` read
// `StandaloneAudioEngine`. These read only what the Now Playing model hands them and call
// back through `WatchNowPlayingActions`, so the two modes can't drift apart again.
//
// Each sheet is a NavigationStack around a plain List (no `.carousel`: the brief's
// anti-goals). Picking a speed, a sleep option, a chapter or a bookmark dismisses the
// sheet, so a change is one tap after the Crown has found the row. The system supplies
// the sheet's close button; nothing here invents its own.
//
// HIG pages consulted (via scripts/appledoc.sh, 21 Oct 2026): designing-for-watchos
// ("quick, glanceable, single-screen interactions"), modality (sheets for a "simple
// task... that people can complete and dismiss"), playing-audio.

// MARK: - Speed

/// 0.5× to 3.0×, opened on the current speed. Was a cycle through six presets on each
/// tap of the tool row, so getting back to 1× from 1.25× took five taps.
struct WatchSpeedSheet: View {
    let current: Double
    let onSelect: (Double) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(WatchSpeedOptions.options(including: current), id: \.self) { speed in
                    let selected = WatchSpeedOptions.matches(speed, current)
                    Button {
                        WatchHaptics.tap()
                        onSelect(speed)
                        dismiss()
                    } label: {
                        HStack {
                            Text(verbatim: WatchSpeedCycler.label(for: speed))
                                .font(WatchMetrics.contentRowTitleFont(weight: selected ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(selected ? WatchTheme.accentText : WatchTheme.primaryText)
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(WatchTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text(verbatim: WatchSpeedCycler.label(for: speed)))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .id(speed)
                }
                .onAppear {
                    let options = WatchSpeedOptions.options(including: current)
                    if let row = options.first(where: { WatchSpeedOptions.matches($0, current) }) {
                        proxy.scrollTo(row, anchor: .center)
                    }
                }
            }
            .navigationTitle("Speed")
        }
    }
}

// MARK: - Sleep

/// The sleep timer presets with the running timer on top. `unavailableReason` replaces
/// the old silently-disabled list when nothing is playing.
struct WatchSleepSheet: View {
    let selected: WatchSleepTimerOption
    let remainingText: String?
    /// Why the options can't be used right now, or nil when they can.
    let unavailableReason: String?
    /// End of Chapter needs chapter data, which a download played offline can lack.
    let hasChapters: Bool
    let onSelect: (WatchSleepTimerOption) -> Void
    /// Batch 490 (REVIEW 2026-11-11 F29): "Add 15 Minutes", or nil to hide the row. The
    /// caller passes nil unless a countdown is running (`WatchSleepExtend.isAvailable`),
    /// so an end-of-chapter timer never shows it.
    var onExtend: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let unavailableReason {
                    Section {
                        Text(unavailableReason)
                            .font(WatchMetrics.secondaryFont())
                            .foregroundStyle(WatchTheme.secondaryText)
                    }
                }
                if let remainingText {
                    Section {
                        Label(remainingText, systemImage: "moon.zzz.fill")
                            .font(WatchMetrics.secondaryFont(weight: .medium).monospacedDigit())
                            .foregroundStyle(WatchTheme.accentText)
                        if let onExtend {
                            Button {
                                WatchHaptics.tap()
                                onExtend()
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(WatchTheme.icon)
                                        .watchIconColumn()
                                    Text("Add 15 Minutes")
                                        .font(WatchMetrics.contentRowTitleFont())
                                        .foregroundStyle(WatchTheme.primaryText)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel(String(localized: "Add 15 minutes to the sleep timer"))
                        }
                    }
                }
                ForEach(WatchSleepTimerOption.presets, id: \.self) { option in
                    let isSelected = selected == option
                    let needsChapters = option == .endOfChapter && !hasChapters
                    Button {
                        WatchHaptics.tap()
                        onSelect(option)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: Self.icon(for: option))
                                .foregroundStyle(WatchTheme.icon)
                                .watchIconColumn()
                            VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                                Text(option.label)
                                    .font(WatchMetrics.contentRowTitleFont())
                                    .foregroundStyle(WatchTheme.primaryText)
                                if needsChapters && unavailableReason == nil {
                                    Text("This book has no chapters")
                                        .font(WatchMetrics.subtitleFont())
                                        .foregroundStyle(WatchTheme.secondaryText)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark").foregroundStyle(WatchTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(unavailableReason != nil || needsChapters)
                    .accessibilityLabel(option.label)
                    .accessibilityHint(needsChapters ? String(localized: "Unavailable, this book has no chapters") : "")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }

    static func icon(for option: WatchSleepTimerOption) -> String {
        switch option {
        case .off: return "moon.slash"
        case .minutes: return "timer"
        case .endOfChapter: return "moon"
        }
    }
}

// MARK: - Chapters

/// The book's chapters, opened on the current one (`ScrollViewReader`, watchOS 7.0+).
struct WatchChaptersSheet: View {
    let chapters: [WatchChapterRow]
    let currentTime: Double
    /// Shown instead of the list when there are no chapters (`WatchChaptersEmptyState`
    /// in companion mode tells "not synced" from "none").
    let emptyMessage: String
    let onSelect: (WatchChapterRow) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = WatchChapterRow.current(in: chapters, at: currentTime)
        NavigationStack {
            Group {
                if chapters.isEmpty {
                    WatchOpenOniPhoneEmptyState(systemImage: "list.bullet", message: .verbatim(emptyMessage))
                } else {
                    ScrollViewReader { proxy in
                        List(chapters) { chapter in
                            let isCurrent = chapter.id == current?.id
                            Button {
                                WatchHaptics.tap()
                                onSelect(chapter)
                                dismiss()
                            } label: {
                                row(chapter, isCurrent: isCurrent)
                            }
                            .listRowBackground(isCurrent ? WatchTheme.accent.opacity(0.18) : nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(isCurrent
                                ? "\(chapter.title), starts at \(chapter.start.watchFormattedTime), currently playing"
                                : "\(chapter.title), starts at \(chapter.start.watchFormattedTime)")
                            .id(chapter.id)
                        }
                        .onAppear {
                            if let current { proxy.scrollTo(current.id, anchor: .center) }
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
        }
    }

    private func row(_ chapter: WatchChapterRow, isCurrent: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                Text(chapter.title)
                    .font(WatchMetrics.contentRowTitleFont(weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? WatchTheme.accentText : WatchTheme.primaryText)
                    // AX-10: wraps to two lines, three at accessibility sizes.
                    .lineLimit(2...3)
                    .multilineTextAlignment(.leading)
                Text(chapter.start.watchFormattedTime)
                    .font(WatchMetrics.subtitleFont().monospacedDigit())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "play.fill")
                    .font(WatchMetrics.secondaryFont())
                    .foregroundStyle(WatchTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Bookmarks

/// The playing book's bookmarks, with Add at the top. Opened by a long press on the tool
/// row's Bookmark button (a plain tap adds one) or from More.
struct WatchBookmarksSheet: View {
    let bookmarks: [WatchBookmarkRow]
    let isLoading: Bool
    let canAdd: Bool
    /// Same contract as `WatchNowPlayingActions.addBookmark`: reports the real outcome.
    let onAdd: ((@escaping (WatchBookmarkOutcome) -> Void) -> Void)?
    let onSelect: (WatchBookmarkRow) -> Void
    /// Standalone loads its list from the server (and flushes the offline queue) here;
    /// companion's list arrives with the iPhone's snapshot.
    let onLoad: (() async -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var outcome: WatchBookmarkOutcome?
    @State private var outcomeResetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let onAdd {
                    Section {
                        Button {
                            guard outcome != .saving else { return }
                            show(.saving)
                            onAdd { show($0) }
                        } label: {
                            Label(outcome?.title ?? String(localized: "Bookmark Current Position"),
                                  systemImage: outcome?.systemImage ?? "bookmark.fill")
                                .font(WatchMetrics.secondaryFont(weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        // Batch 490 (REVIEW 2026-11-11 W14): a lit amber slab under
                        // Always-On breaks Dim-the-Picture; it goes quiet like the rest.
                        .tint(isLuminanceReduced ? WatchTheme.secondaryText : WatchTheme.accent)
                        .disabled(!canAdd)
                        .accessibilityLabel(outcome?.accessibilityLabel ?? String(localized: "Bookmark current position"))
                        .accessibilityHint(canAdd ? "" : String(localized: "Unavailable while nothing is playing"))
                    }
                }
                if bookmarks.isEmpty {
                    Text(isLoading ? "Loading…" : "No bookmarks for this book yet")
                        .font(WatchMetrics.subtitleFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                }
                ForEach(bookmarks) { bookmark in
                    Button {
                        WatchHaptics.tap()
                        onSelect(bookmark)
                        dismiss()
                    } label: {
                        row(bookmark)
                    }
                    .accessibilityLabel(bookmark.isPending
                        ? "\(bookmark.title), at \(bookmark.time.watchFormattedTime), waiting to sync"
                        : "\(bookmark.title), at \(bookmark.time.watchFormattedTime)")
                }
            }
            .navigationTitle("Bookmarks")
        }
        .task { await onLoad?() }
        .onDisappear { outcomeResetTask?.cancel() }
    }

    private func row(_ bookmark: WatchBookmarkRow) -> some View {
        HStack {
            Image(systemName: bookmark.isPending ? "arrow.triangle.2.circlepath" : "bookmark.fill")
                .foregroundStyle(WatchTheme.icon)
                .font(WatchMetrics.contentRowTitleFont())
                .watchIconColumn()
            VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
                Text(bookmark.title)
                    .font(WatchMetrics.contentRowTitleFont())
                    .foregroundStyle(WatchTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Group {
                    if bookmark.isPending {
                        Text("\(bookmark.time.watchFormattedTime) · waiting to sync")
                    } else {
                        Text(bookmark.time.watchFormattedTime)
                    }
                }
                .font(WatchMetrics.subtitleFont().monospacedDigit())
                .foregroundStyle(WatchTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// The outcome on the button, one result haptic, a VoiceOver announcement, then back
    /// to the plain label — the same rhythm as the tool row's Bookmark button.
    private func show(_ newOutcome: WatchBookmarkOutcome) {
        outcome = newOutcome
        // Batch 490 (REVIEW 2026-11-11 W8): one rule for both Bookmark buttons; a save
        // kept offline now buzzes success too, since it was saved.
        switch WatchFeedbackHaptic.forBookmark(newOutcome) {
        case .success: WatchHaptics.success()
        case .failure: WatchHaptics.failure()
        case nil: break
        }
        if newOutcome != .saving {
            AccessibilityNotification.Announcement(newOutcome.accessibilityLabel).post()
        }
        outcomeResetTask?.cancel()
        outcomeResetTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(newOutcome.displaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            outcome = nil
        }
    }
}

// MARK: - More

/// The "⋯" sheet: the actions that used to sit below the fold as each mode's footer
/// (Mark as Finished, Stop Playing) and the Bookmarks list. Batch 490 (REVIEW 2026-11-11
/// W5): Downloads is gone from here. It pushed the whole downloads screen on top of a
/// sheet on top of Now Playing; it lives in Library's toolbar and Settings. watchOS has no
/// `Menu` (Apple docs: iOS 14, macOS 11, tvOS 17, visionOS 1 — no watchOS), so this is a
/// sheet with a plain list.
struct WatchNowPlayingMoreSheet<ModeActions: View>: View {
    let onShowBookmarks: (() -> Void)?
    @ViewBuilder let modeActions: () -> ModeActions

    var body: some View {
        NavigationStack {
            List {
                if let onShowBookmarks {
                    Button {
                        onShowBookmarks()
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark")
                    }
                }
                modeActions()
            }
            .navigationTitle("More")
        }
    }
}

// MARK: - Volume

/// The Digital Crown as volume on Now Playing, the way Apple's own Now Playing does it.
/// `WKInterfaceVolumeControl.init(origin:)` is documented "for use in SwiftUI" (watchOS
/// 6.0), hosted through `WKInterfaceObjectRepresentable` (watchOS 6.0); `.companion`
/// drives the iPhone's volume, `.local` this Watch's. Checked against
/// developer.apple.com/documentation/watchkit/wkinterfacevolumecontrol and the SDK header
/// (`focus()` "Sets the volume control as the focus for input from the Digital Crown").
///
/// `focusRequest` re-takes the Crown when it changes: on appear, after a sheet closes,
/// and after a Crown scrub on the time row hands it back.
struct WatchVolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin
    var focusRequest: Int

    final class Coordinator {
        var lastFocusRequest: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: origin)
        control.setTintColor(UIColor(WatchTheme.accent))
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.setTintColor(UIColor(WatchTheme.accent))
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        control.focus()
    }
}
