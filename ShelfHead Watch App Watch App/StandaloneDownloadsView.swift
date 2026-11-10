import SwiftUI

/// Stage 5 — this Watch's own downloaded-items list, backed by
/// `WatchLocalDownloadManager` (own background session, own manifest storage): files
/// that physically exist in this Watch's own storage.
///
/// Batch 412 (Watch redesign, brief §6): one "On This Watch" list. In companion mode it
/// adds an "On iPhone" section mirroring what the *phone's* `DownloadManager` reports
/// (`WatchModels.swift`'s `WatchDownloadStatus`/`WatchDownloadSummary`); the old separate
/// `DownloadsView` screen is gone.
struct StandaloneDownloadsView: View {
    @Environment(WatchStore.self) private var watchStore
    // Batch 412 (Watch redesign): the iPhone's mirrored downloads are an inline section
    // here now, so the companion store and the play-replacement request live on this screen.
    @Environment(WatchConnectivityStore.self) private var phoneStore
    @State private var pendingRemoveId: String?
    @State private var pendingPlay: WatchPlayRequest?

    private var manager: WatchLocalDownloadManager { watchStore.localDownloads }

    private var showsPhoneSection: Bool {
        watchStore.mode == .companion && !phoneStore.downloads.isEmpty
    }

    /// One queued/downloading/failed item, keyed by itemId — this screen's own
    /// lightweight identity for rows that don't have a full `WatchLocalDownload`
    /// record yet (that only exists once a download completes). See `inFlightItems`
    /// and `WatchLocalDownloadManager.pendingTitleAuthor(for:)`.
    private struct InFlightItem: Identifiable {
        let id: String
        let title: String
        let author: String
        let state: WatchLocalDownloadState
    }

    /// UX fix (31 August 2026), direct user request ("make downloads more
    /// intuitive"): this screen used to only ever read `manager.downloads`, which
    /// is populated exclusively on completion (`writeManifest`) — a book that was
    /// just swiped to download in Library never appeared here at all until it
    /// finished, and a failed download vanished into `manager.states` with nothing
    /// on this screen to show for it. A user who swiped "Download" then opened
    /// Downloads to check progress found an unchanged (or empty) list and
    /// reasonably concluded nothing had happened. This now surfaces every
    /// non-terminal state directly, sorted for stability (dictionary iteration
    /// order isn't guaranteed).
    private var inFlightItems: [InFlightItem] {
        manager.states.compactMap { itemId, state -> InFlightItem? in
            switch state {
            case .queued, .downloading, .failed:
                let meta = manager.pendingTitleAuthor(for: itemId)
                return InFlightItem(id: itemId, title: meta?.title ?? String(localized: "Untitled"), author: meta?.author ?? "", state: state)
            case .notDownloaded, .downloaded:
                return nil
            }
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            // Critique 2026-10-06 (harden): eviction used to be silent, so a book could
            // vanish from this list with nothing to say why. Said once, until OK.
            if let notice = manager.evictionNotice {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(notice.message, systemImage: "info.circle")
                            .font(WatchMetrics.captionFont())
                            .foregroundStyle(WatchTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("OK") { manager.dismissEvictionNotice() }
                            .font(WatchMetrics.secondaryFont())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            if inFlightItems.isEmpty && manager.downloads.isEmpty {
                emptyState
            } else {
                if !inFlightItems.isEmpty {
                    Section("In Progress") {
                        ForEach(inFlightItems) { item in
                            inFlightRow(item)
                        }
                    }
                }
                if !manager.downloads.isEmpty {
                    // Only labeled "Downloaded" once there's an "In Progress"
                    // section above it to disambiguate from — a `Section("")` would
                    // still reserve header space for an empty title, so this stays a
                    // genuinely unlabeled group (matching this screen's original,
                    // pre-fix appearance) rather than an empty-string one whenever
                    // nothing's in flight.
                    if inFlightItems.isEmpty && !showsPhoneSection {
                        ForEach(sortedDownloads, id: \.id) { download in
                            downloadRow(download)
                        }
                    } else if inFlightItems.isEmpty {
                        // Batch 412: the screen is titled "Downloads" now, so this Watch's
                        // books need their own label beside the "On iPhone" section.
                        Section("On This Watch") {
                            ForEach(sortedDownloads, id: \.id) { download in
                                downloadRow(download)
                            }
                        }
                    } else {
                        Section("Downloaded") {
                            ForEach(sortedDownloads, id: \.id) { download in
                                downloadRow(download)
                            }
                        }
                    }
                }
            }
            storageSection
            if showsPhoneSection {
                iPhoneDownloadsSection
            }
        }
        // Default list style on purpose (no `.listStyle(.carousel)`): the `.swipeActions`
        // "Remove" below is the only way to delete a downloaded book here, and
        // `.carousel`'s gesture competes with it (real on-device bug, 29 August 2026).
        // Batch 412: titled "Downloads" to match the Library button that opens it (it was
        // "On This Watch", which also wrapped to two lines on 40 mm).
        .navigationTitle("Downloads")
        .confirmsDownloadRemoval($pendingRemoveId)
        .confirmsPlayReplacement($pendingPlay)
        .task { manager.refreshAvailableCapacity() }
    }

    /// Critique 2026-10-06 (harden, onboard): "Swipe a book in Library to download it"
    /// pointed at a path that didn't exist with the iPhone nearby. Now it names the real
    /// next step: Library when this Watch has a session, setup when it doesn't.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(watchStore.authState == .active
                 ? "Nothing on this Watch yet. Download a book from Library to take it on a run."
                 : "Set up this Watch to download books and play them without your iPhone.")
                .font(WatchMetrics.secondaryFont())
                .foregroundStyle(WatchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                if watchStore.authState == .active {
                    StandaloneLibraryView()
                } else {
                    WatchAccountView()
                }
            } label: {
                Label(watchStore.authState == .active ? "Open Library" : "Set Up",
                      systemImage: watchStore.authState == .active ? "book.fill" : "applewatch")
                    .font(WatchMetrics.secondaryFont(weight: .semibold))
            }
        }
    }

    /// Batch 412 (Watch redesign): the iPhone's own downloads, mirrored inline in companion
    /// mode (was a link row to a separate screen). A tap asks the phone to play; with the
    /// phone out of reach the rows are plain and the footer says where to play.
    private var iPhoneDownloadsSection: some View {
        Section {
            ForEach(phoneStore.downloads) { download in
                if phoneStore.isReachable {
                    Button {
                        phoneStore.requestPlay(itemId: download.id, title: download.title, pending: $pendingPlay)
                    } label: {
                        iPhoneDownloadRow(download)
                    }
                    .buttonStyle(.plain)
                } else {
                    iPhoneDownloadRow(download)
                }
            }
        } header: {
            Text("On iPhone")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Books downloaded on your iPhone. They play on the iPhone.")
                if !phoneStore.isReachable {
                    Label("Open on iPhone to play", systemImage: "iphone.gen3")
                }
            }
        }
    }

    private func iPhoneDownloadRow(_ download: WatchDownloadSummary) -> some View {
        WatchBookRow(title: download.title, author: download.author,
                     cover: { CoverThumbnail(data: download.coverData, side: WatchBookRow<EmptyView, EmptyView, EmptyView>.coverSide) },
                     detail: { iPhoneStatusDetail(download.status) })
            .accessibilityElement(children: .combine)
    }

    /// Only the states that need saying; a "Downloaded" badge on every row was noise.
    @ViewBuilder
    private func iPhoneStatusDetail(_ status: WatchDownloadStatus) -> some View {
        switch status {
        case .queued:
            WatchStatusBadge(text: "Queued", systemImage: "clock", tint: WatchTheme.secondaryText)
        case .downloading(let progress):
            // The bar is accessibility-hidden, so the percentage is what VoiceOver reads.
            VStack(alignment: .leading, spacing: 2) {
                WatchLinearProgressBar(progress: progress).frame(height: 3)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(WatchMetrics.captionFont().monospacedDigit())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
        case .failed:
            WatchStatusBadge(text: "Failed", systemImage: "exclamationmark", tint: WatchTheme.alert)
        case .downloaded:
            EmptyView()
        }
    }

    /// "1 book" / "N books"; nil with none. Critique 2026-10-06 (polish): read "1 books".
    nonisolated static func iPhoneDownloadsCount(_ count: Int) -> String? {
        count <= 0 ? nil : (count == 1 ? String(localized: "1 book") : String(localized: "\(count) books"))
    }

    private var sortedDownloads: [WatchLocalDownload] {
        manager.downloads.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    /// Listening progress as 0...1 from the manifest's synced position; nil when unknown.
    private func downloadFraction(_ download: WatchLocalDownload) -> Double? {
        guard download.duration > 0, let current = download.serverProgress?.currentTime else { return nil }
        return min(max(current / download.duration, 0), 1)
    }

    private func downloadRow(_ download: WatchLocalDownload) -> some View {
        NavigationLink {
            // Standalone: one tap plays, the run's fastest path. Companion: the iPhone
            // owns Now Playing, so the row opens the book (Play on iPhone, Remove).
            if watchStore.mode == .standalone {
                StandaloneNowPlayingView(
                    itemId: download.id,
                    title: download.title,
                    author: download.author,
                    coverData: nil,
                    coverItemId: download.id
                )
            } else {
                WatchBookDetailView(
                    itemId: download.id, title: download.title, author: download.author,
                    duration: download.duration > 0 ? download.duration : nil,
                    currentTime: download.serverProgress?.currentTime)
            }
        } label: {
            WatchBookRow(title: download.title, author: download.author, progress: downloadFraction(download),
                         cover: { LocalCoverThumbnail(itemId: download.id, side: WatchBookRow<EmptyView, EmptyView, EmptyView>.coverSide) })
                .accessibilityElement(children: .combine)
        }
        // Critique 2026-10-06 (harden): no full swipe + confirmation, a delete can't be an overshoot.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingRemoveId = download.id
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// UX fix (31 August 2026) — see `inFlightItems`'s own doc comment. A queued,
    /// downloading, or failed row: same title/author/cover treatment as a completed
    /// `downloadRow`, but not a `NavigationLink` (there's nothing playable yet) and
    /// with a status detail line in place of the second line of text, plus a swipe
    /// action appropriate to its own state instead of always "Remove".
    @ViewBuilder
    private func inFlightRow(_ item: InFlightItem) -> some View {
        WatchBookRow(title: item.title, author: item.author,
                     cover: { LocalCoverThumbnail(itemId: item.id, side: WatchBookRow<EmptyView, EmptyView, EmptyView>.coverSide) },
                     detail: { inFlightStatusDetail(item.state) })
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing) {
            switch item.state {
            case .queued, .downloading:
                Button(role: .destructive) {
                    manager.cancelDownload(itemId: item.id)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            case .failed:
                Button {
                    Task { await manager.startDownload(itemId: item.id, title: item.title, author: item.author) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .tint(WatchTheme.accent)
                Button(role: .destructive) {
                    manager.cancelDownload(itemId: item.id)
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
            case .notDownloaded, .downloaded:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func inFlightStatusDetail(_ state: WatchLocalDownloadState) -> some View {
        switch state {
        case .queued:
            // Visual polish pass (31 August 2026) — see `WatchStatusBadge`'s own
            // doc comment; the "On iPhone" rows use the same badge (Batch 412).
            WatchStatusBadge(text: "Queued", systemImage: "clock", tint: WatchTheme.secondaryText)
        case .downloading(let progress):
            WatchLinearProgressBar(progress: progress)
                .frame(height: 3)
                .padding(.top, 2)
        case .failed(let reason):
            // Critique 2026-10-06 (colorize): alert glyph, cream sentence. No line limit:
            // "Not enough room on this Watch…" names its fix in its second half.
            WatchAlertNotice(text: .verbatim(reason), font: WatchMetrics.captionFont())
        case .notDownloaded, .downloaded:
            EmptyView()
        }
    }

    /// User-visible storage accounting — the "and/or be user-visible" half of the
    /// public-release amendment's §9.4 requirement on the eviction cap (the other
    /// half, deriving the cap from actual runtime-available storage, lives in
    /// `WatchLocalDownloadManager.evictIfNeeded()` itself). Without this, an old
    /// download disappearing because a newer one didn't fit would have nothing on
    /// screen to explain why.
    @ViewBuilder
    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ByteCountFormatter.string(fromByteCount: manager.totalBytesUsed, countStyle: .file)) used")
                    .font(WatchMetrics.subtitleFont().monospacedDigit())
                    .foregroundStyle(WatchTheme.secondaryText)
                if let available = manager.availableCapacityBytes {
                    Text("\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free on this Watch")
                        .font(WatchMetrics.captionFont().monospacedDigit())
                        .foregroundStyle(WatchTheme.secondaryText)
                }
            }
        }
    }
}

// Critique 2026-10-06 (harden): `Data(contentsOf:)` ran synchronously in row bodies, on every
// body evaluation, which hitches scrolling.
/// A downloaded book's cover from this Watch's own storage, read off the main thread.
/// Falls back to the network-backed thumbnail when there is no local file.
struct LocalCoverThumbnail: View {
    @Environment(WatchStore.self) private var watchStore
    let itemId: String
    let side: CGFloat
    /// Batch 413: passed through to the network thumbnail's title cover.
    var title: String? = nil
    var author: String? = nil
    @State private var data: Data?

    var body: some View {
        Group {
            if let data {
                CoverThumbnail(data: data, side: side)
            } else {
                StandaloneCoverThumbnail(itemId: itemId, side: side, title: title, author: author)
            }
        }
        .task(id: itemId) {
            guard let url = watchStore.localDownloads.localCoverURL(itemId: itemId) else {
                data = nil
                return
            }
            data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        }
    }
}

/// Confirms removing a downloaded book from this Watch. Progress lives on the server and in
/// the pending-progress queue, not in the download directory, so it survives the removal.
private struct DownloadRemovalConfirmation: ViewModifier {
    @Environment(WatchStore.self) private var watchStore
    @Binding var pendingId: String?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            // Critique 2026-10-06 (polish): the phone's wording (`RemoveDownloadConfirmation`).
            "Remove this download?",
            isPresented: Binding(get: { pendingId != nil }, set: { if !$0 { pendingId = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                if let id = pendingId { watchStore.localDownloads.removeDownload(itemId: id) }
                pendingId = nil
            }
            Button("Cancel", role: .cancel) { pendingId = nil }
        } message: {
            Text("Your progress is kept.")
        }
    }
}

extension View {
    func confirmsDownloadRemoval(_ pendingId: Binding<String?>) -> some View {
        modifier(DownloadRemovalConfirmation(pendingId: pendingId))
    }
}

#Preview {
    NavigationStack { StandaloneDownloadsView() }
        .environment(WatchStore.shared)
}
