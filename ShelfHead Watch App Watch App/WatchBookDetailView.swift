import SwiftUI
import Accessibility
import WatchKit

/// Critique 2026-10-06 (harden, then shape → onboard): one book, from Library or "On This
/// Watch", with the two things a runner prepares: play it, and put it on the Watch.
///
/// **Why it exists.** Library rows used to tap straight into playback on this Watch,
/// which is why Library was dead whenever the iPhone was nearby (a second player behind
/// the phone's back), and the only way to download was a hidden swipe whose existence a
/// footer had to explain. Preparing for a run happens at home, with the phone in the
/// room, so both had to work there.
///
/// - **Play** (Critique 2026-10-06, third pass, shape → harden): a book on this Watch
///   plays here first in *both* modes — "Play on Watch" is primary and "Play on iPhone"
///   secondary (`WatchBookPlayOptions`). It used to follow the mode, so with the phone in
///   the room a downloaded book only offered "Play on iPhone" and a run started on the
///   phone on the counter. "Play on Watch" pushes `StandaloneNowPlayingView`, which pauses
///   a playing iPhone (asking first when it's a different book) and asks before replacing
///   a different book on the Watch; once the book loads the Watch holds its own mode until
///   it's stopped (`WatchStore.nextMode`). "Play on iPhone" goes through the same
///   replace-what's-playing confirmation as Recently Added. A book that isn't downloaded
///   still follows the mode.
/// - **Room** (same pass): before downloading, the book's size against the room left, and
///   what would be removed to make room (finished, then unstarted books — never one
///   part-way through). If it can only fit by removing a part-played book, it says so and
///   doesn't download (`WatchDownloadRoomPlan`).
/// - **Download to Watch** is a visible button in both modes, using this Watch's own
///   session and background download (`WatchLocalDownloadManager`). The row swipe
///   stays as an accelerator.
///
/// HIG (designing-for-watchos, via the JSON endpoint): "minimize the depth of
/// hierarchy" — this is one level below the list, and both actions are on its first
/// screen.
struct WatchBookDetailView: View {
    @Environment(WatchStore.self) private var watchStore
    @Environment(WatchConnectivityStore.self) private var companion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let itemId: String
    let title: String
    let author: String
    var duration: Double? = nil
    var currentTime: Double? = nil
    var progress: Double? = nil
    var isFinished: Bool = false
    /// The book's size on the server, when known (`WatchLibraryItem.sizeBytes`).
    var sizeBytes: Int64? = nil

    @State private var pendingPlay: WatchPlayRequest?
    @State private var pendingRemoveId: String?
    /// Critique 2026-10-06 (harden): whether this book fits, worked out before the
    /// Download button is offered. `nil` until checked, or when the size isn't known.
    @State private var roomPlan: WatchDownloadRoomPlan?
    /// Batch 413: Mark as Finished's confirmation, request and outcome.
    @State private var confirmsMarkFinished = false
    @State private var isMarkingFinished = false
    @State private var markedFinished = false
    @State private var markFinishedFailed = false

    private var manager: WatchLocalDownloadManager { watchStore.localDownloads }
    private var downloadState: WatchLocalDownloadState { manager.states[itemId] ?? .notDownloaded }
    private var playOptions: WatchBookPlayOptions {
        WatchBookPlayOptions.decide(isDownloaded: manager.isDownloaded(itemId: itemId),
                                    isStandaloneMode: watchStore.mode == .standalone,
                                    phoneIsReachable: companion.isReachable)
    }
    private var hasWatchSession: Bool { watchStore.authState == .active }

    /// Re-check the room whenever what's on the Watch changes.
    private var roomCheckKey: String {
        "\(itemId)|\(manager.downloads.count)|\(manager.totalBytesUsed)|\(sizeBytes ?? 0)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 10) {
                header
                playButtons
                downloadSection
                markFinishedSection
            }
            .padding(.horizontal, WatchMetrics.scrollContentHorizontalPadding)
        }
        // Batch 412 (Watch redesign): no generic "Book" title; the book is the title.
        .navigationTitle("")
        .task(id: roomCheckKey) {
            guard sizeBytes != nil, !manager.isDownloaded(itemId: itemId) else {
                roomPlan = nil
                return
            }
            roomPlan = await manager.roomPlan(forBytes: sizeBytes)
        }
        .confirmsPlayReplacement($pendingPlay)
        .confirmsDownloadRemoval($pendingRemoveId)
        .confirmationDialog(
            "Mark \u{201C}\(title)\u{201D} as finished?",
            isPresented: $confirmsMarkFinished,
            titleVisibility: .visible
        ) {
            Button("Mark as Finished") { markFinished() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Mark as Finished

    private var markFinishedPath: WatchMarkFinishedPath {
        WatchMarkFinishedPath.decide(itemId: itemId,
                                     isFinished: isFinished || markedFinished,
                                     hasWatchSession: hasWatchSession,
                                     phoneIsReachable: companion.isReachable)
    }

    /// Batch 413: last on the screen, under Download: it is the least frequent action, and
    /// it asks first. Hidden when the book is already finished; disabled, with the reason,
    /// when only the iPhone could write it and it is out of reach.
    @ViewBuilder
    private var markFinishedSection: some View {
        let path = markFinishedPath
        if path != .hidden {
            VStack(spacing: 6) {
                if markFinishedFailed {
                    WatchAlertNotice(text: "Couldn\u{2019}t mark as finished. Check your connection and try again.",
                                     font: WatchMetrics.captionFont())
                }
                Button {
                    confirmsMarkFinished = true
                } label: {
                    Label("Mark as Finished", systemImage: "checkmark.circle")
                        .font(WatchMetrics.secondaryFont(weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(WatchTheme.cardBackground)
                .foregroundStyle(WatchTheme.primaryText)
                .disabled(path == .needsPhone || isMarkingFinished)
                .accessibilityHint(path == .needsPhone ? String(localized: "Needs your iPhone nearby") : "")
                if path == .needsPhone {
                    Text("Needs your iPhone nearby")
                        .font(WatchMetrics.captionFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 4)
        }
    }

    private func markFinished() {
        switch markFinishedPath {
        case .server:
            isMarkingFinished = true
            markFinishedFailed = false
            Task {
                do {
                    try await watchStore.markFinishedOnServer(itemId: itemId)
                    markedFinished = true
                    WatchHaptics.success()
                    AccessibilityNotification.Announcement(String(localized: "Finished")).post()
                } catch {
                    markFinishedFailed = true
                    WatchHaptics.failure()
                }
                isMarkingFinished = false
            }
        case .phone:
            // Batch 414: the iPhone writes it (`.markItemFinished`), for any book. Its reply
            // is the real outcome; the haptic and any failure alert come from
            // `WatchConnectivityStore.reportOutcome`, so none are added here.
            isMarkingFinished = true
            companion.markFinished(itemId: itemId) { ok in
                isMarkingFinished = false
                guard ok else { return }
                markedFinished = true
                AccessibilityNotification.Announcement(String(localized: "Finished")).post()
            }
        case .needsPhone, .hidden:
            break
        }
    }

    // MARK: - Header

    /// Batch 412 (Watch redesign): cover-led header, like the Shelf. A large centred cover
    /// (about 60% of the screen width, 40% at accessibility sizes, never over 40% of the height), then title, author and
    /// progress centred beneath. One combined VoiceOver element; the cover is decorative.
    private var coverSide: CGFloat {
        let bounds = WKInterfaceDevice.current().screenBounds
        let side = bounds.width * (dynamicTypeSize.isAccessibilitySize ? 0.4 : 0.6)
        // Batch 412 capture pass: capped by height so the title and the top of Play
        // still show on 40/41 mm without scrolling.
        return min(side, bounds.height * 0.4).rounded()
    }

    private var header: some View {
        VStack(spacing: 8) {
            Group {
                if manager.isDownloaded(itemId: itemId) {
                    LocalCoverThumbnail(itemId: itemId, side: coverSide, title: title, author: author)
                } else {
                    StandaloneCoverThumbnail(itemId: itemId, side: coverSide, title: title, author: author)
                }
            }
            .frame(width: coverSide, height: coverSide)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            VStack(spacing: WatchMetrics.titleSubtitleSpacing) {
                Text(title)
                    .font(WatchMetrics.navigationRowTitleFont(weight: .bold))
                    .foregroundStyle(WatchTheme.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(author)
                    .font(WatchMetrics.subtitleFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .lineLimit(2)
                Text(WatchBookProgressText.text(currentTime: currentTime, duration: duration,
                                                progress: progress, isFinished: isFinished || markedFinished))
                    .font(WatchMetrics.captionFont(weight: .medium).monospacedDigit())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Play

    @ViewBuilder
    private var playButtons: some View {
        let options = playOptions
        playControl(options.primary)
            .buttonStyle(.borderedProminent)
            .tint(WatchTheme.accent)
        if let secondary = options.secondary {
            playControl(secondary)
                .buttonStyle(.bordered)
                .tint(WatchTheme.cardBackground)
                .foregroundStyle(WatchTheme.primaryText)
        }
    }

    @ViewBuilder
    private func playControl(_ target: WatchBookPlayTarget) -> some View {
        switch target {
        case .watch:
            NavigationLink {
                StandaloneNowPlayingView(itemId: itemId, title: title, author: author, coverItemId: itemId)
            } label: {
                playLabel(target)
            }
        case .iPhone:
            Button {
                companion.requestPlay(itemId: itemId, title: title, pending: $pendingPlay)
            } label: {
                playLabel(target)
            }
            .disabled(!companion.isReachable)
            .accessibilityHint(companion.isReachable ? "" : String(localized: "Unavailable, your iPhone isn\u{2019}t reachable"))
        }
    }

    private func playLabel(_ target: WatchBookPlayTarget) -> some View {
        Label(target.buttonTitle, systemImage: target.systemImage)
            .font(WatchMetrics.secondaryFont(weight: .semibold))
            .frame(maxWidth: .infinity)
    }

    // MARK: - Download

    @ViewBuilder
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch downloadState {
            case .notDownloaded:
                if roomPlan == .noRoom {
                    noRoomNotice
                } else {
                    Button {
                        startDownload()
                    } label: {
                        Label("Download to Watch", systemImage: "arrow.down.circle")
                            .font(WatchMetrics.secondaryFont(weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(WatchTheme.cardBackground)
                    .foregroundStyle(WatchTheme.primaryText)
                    .disabled(!hasWatchSession)
                    roomLines
                }
                if !hasWatchSession {
                    NavigationLink {
                        WatchAccountView()
                    } label: {
                        Text("Set up this Watch to download")
                            .font(WatchMetrics.captionFont(weight: .medium))
                            .foregroundStyle(WatchTheme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            case .queued:
                statusLine("Waiting to download", systemImage: "clock")
                cancelButton
            case .downloading(let fraction):
                statusLine("Downloading \(Int((fraction * 100).rounded()))%", systemImage: "arrow.down.circle")
                WatchLinearProgressBar(progress: fraction).frame(height: 3)
                    .accessibilityHidden(true)
                cancelButton
            case .failed where roomPlan == .noRoom:
                // Still no room: Try Again would fail the same way, so point at the fix.
                noRoomNotice
            case .failed(let reason):
                // Critique 2026-10-06 (colorize): alert glyph, cream sentence.
                WatchAlertNotice(text: .verbatim(reason), font: WatchMetrics.captionFont())
                Button {
                    startDownload()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(WatchMetrics.secondaryFont(weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(WatchTheme.cardBackground)
                .foregroundStyle(WatchTheme.primaryText)
                .disabled(!hasWatchSession)
            case .downloaded:
                statusLine("On This Watch", systemImage: "checkmark.circle.fill")
                // Critique 2026-10-06 (shape → harden): "Plays on this Watch when your
                // iPhone isn't nearby" is gone — it plays here now, phone or not.
                if let notice = manager.evictionNotice, notice.forItemId == itemId {
                    evictionNoticeView(notice)
                }
                Button(role: .destructive) {
                    pendingRemoveId = itemId
                } label: {
                    Label("Remove Download", systemImage: "trash")
                        .font(WatchMetrics.secondaryFont())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Size against room, and what downloading would remove. Only when the size is known.
    @ViewBuilder
    private var roomLines: some View {
        if let sizeBytes {
            Text(WatchDownloadRoomCopy.sizeLine(bookBytes: sizeBytes, roomBytes: manager.roomForDownloadsBytes))
                .font(WatchMetrics.captionFont().monospacedDigit())
                .foregroundStyle(WatchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if case .fitsAfterRemoving(let ids) = roomPlan {
                Text(WatchDownloadRoomCopy.willRemove(titles: ids.compactMap { manager.downloads[$0]?.title }))
                    .font(WatchMetrics.captionFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Critique 2026-10-06 (harden): the only way to make room is to remove a book that's
    /// part-way through, which the Watch won't do on its own. Says so, and offers the
    /// list where a book can be removed.
    @ViewBuilder
    private var noRoomNotice: some View {
        WatchAlertNotice(text: .verbatim(WatchDownloadRoomCopy.noRoom(title: title)), font: WatchMetrics.captionFont())
        if let sizeBytes {
            Text(WatchDownloadRoomCopy.sizeLine(bookBytes: sizeBytes, roomBytes: manager.roomForDownloadsBytes))
                .font(WatchMetrics.captionFont().monospacedDigit())
                .foregroundStyle(WatchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        NavigationLink {
            StandaloneDownloadsView()
        } label: {
            Label("On This Watch", systemImage: "applewatch")
                .font(WatchMetrics.secondaryFont(weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(WatchTheme.cardBackground)
        .foregroundStyle(WatchTheme.primaryText)
    }

    /// "Removed “X” to make room." on the book that needed the room, until dismissed.
    private func evictionNoticeView(_ notice: WatchLocalDownloadManager.EvictionNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(notice.message, systemImage: "info.circle")
                .font(WatchMetrics.captionFont())
                .foregroundStyle(WatchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { manager.dismissEvictionNotice() }
                .font(WatchMetrics.secondaryFont())
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .onAppear { AccessibilityNotification.Announcement(notice.message).post() }
    }

    private func statusLine(_ text: LocalizedStringResource, systemImage: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
        }
            .font(WatchMetrics.secondaryFont(weight: .medium).monospacedDigit())
            .foregroundStyle(WatchTheme.primaryText)
    }

    private var cancelButton: some View {
        Button(role: .destructive) {
            manager.cancelDownload(itemId: itemId)
        } label: {
            Text("Cancel Download")
                .font(WatchMetrics.secondaryFont())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func startDownload() {
        WatchHaptics.tap()
        Task { await manager.startDownload(itemId: itemId, title: title, author: author, expectedBytes: sizeBytes) }
    }
}

extension WatchBookDetailView {
    /// From a Library row (`WatchLibraryItem`, with the server's progress attached).
    init(item: WatchLibraryItem) {
        self.init(itemId: item.id,
                  title: item.media?.metadata?.title ?? String(localized: "Untitled"),
                  author: item.media?.metadata?.authorName ?? String(localized: "Unknown Author"),
                  duration: item.media?.duration,
                  currentTime: item.mediaProgress?.currentTime,
                  progress: item.mediaProgress?.progress,
                  isFinished: item.mediaProgress?.isFinished ?? false,
                  sizeBytes: item.sizeBytes)
    }
}

#Preview {
    NavigationStack {
        WatchBookDetailView(itemId: "preview", title: "Preview Book", author: "Preview Author", duration: 36_000, currentTime: 9_000)
    }
    .environment(WatchStore.shared)
    .environment(WatchConnectivityStore.shared)
}

/// Batch 413: who writes Mark as Finished for a book on Book Details. This Watch's own
/// session writes to the server; without one, the iPhone does (Batch 414:
/// `.markItemFinished` names the book, so it no longer has to be the one playing).
nonisolated enum WatchMarkFinishedPath: Equatable, Sendable {
    case server
    case phone
    /// No Watch session and the iPhone is out of reach: shown, disabled, with a reason.
    case needsPhone
    case hidden

    static func decide(itemId: String, isFinished: Bool, hasWatchSession: Bool,
                       phoneIsReachable: Bool) -> WatchMarkFinishedPath {
        if isFinished { return .hidden }
        if hasWatchSession { return .server }
        return phoneIsReachable ? .phone : .needsPhone
    }
}
