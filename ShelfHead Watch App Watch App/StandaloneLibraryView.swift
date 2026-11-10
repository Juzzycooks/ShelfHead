import SwiftUI

/// Stage 4 — replaces the bounded companion-mirror picker
/// (`RecentlyAddedView` and the iPhone downloads mirror) as the standalone entry point: real paging,
/// real search, against this Watch's own connection to the server. See
/// `WatchStandaloneLibraryStore`'s own doc comment for why this exists at all.
///
/// Critique 2026-10-06 (harden): rows open `WatchBookDetailView` (Play + Download to
/// Watch) instead of tapping straight into playback on this Watch. That direct tap was
/// why Library was dead with the iPhone nearby, and the only way to download was a
/// hidden swipe. Live in both modes now (`WatchRootTiles`); the detail's Play follows
/// the mode. The trailing swipe stays as an accelerator.
struct StandaloneLibraryView: View {
    @Environment(WatchStore.self) private var watchStore
    @State private var pendingRemoveId: String?

    /// Reads `watchStore.library` rather than owning a local `@State` instance — this
    /// store's paging/search/selected-library state should survive navigating away to
    /// play something and back, the same reason `watchStore.standalone` (the playback
    /// engine) lives on `WatchStore` rather than being recreated per screen.
    private var store: WatchStandaloneLibraryStore { watchStore.library }

    var body: some View {
        Group {
            switch store.librariesState {
            case .idle, .loading:
                // LS-13 (docs/design-review.md, Round 3): was pinned to the Group's
                // natural (top-leading) layout instead of sitting centred like every
                // other full-screen loading state.
                ProgressView().tint(WatchTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                WatchStandaloneErrorState(message: .verbatim(message)) {
                    Task { await store.reloadLibraries() }
                }
            case .loaded:
                libraryContent
            }
        }
        .navigationTitle("Library")
        .confirmsDownloadRemoval($pendingRemoveId)
        .task { await store.loadLibrariesIfNeeded() }
        .task(id: store.selectedLibraryId) { await store.loadInProgress() }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if store.libraries.isEmpty {
            WatchStandaloneErrorState(message: "No libraries found on this server.") {
                Task { await store.reloadLibraries() }
            }
        } else {
            List {
                if store.libraries.count > 1 {
                    librarySwitcher
                }
                itemsSection
            }
            .searchable(text: Binding(
                get: { store.searchQuery },
                set: { store.searchQuery = $0; store.search() }
            ))
            // Real on-device bug fix (29 August 2026): the Batch 264 UI polish pass
            // applied `.listStyle(.carousel)` here for visual consistency with every
            // other top-level list — but this is the one screen where `.swipeActions`
            // (below, `downloadSwipeAction(for:)`) is the ONLY way to start a
            // download, and `.carousel`'s own drag/focus-scrolling gesture competes
            // with and effectively swallows the swipe-to-reveal gesture `.swipeActions`
            // needs, per real user report ("no option to download a book"). Reverted
            // to the default list style on this screen specifically — function over
            // visual consistency where the two conflict.
        }
    }

    private var librarySwitcher: some View {
        Picker("Library", selection: Binding(
            get: { store.selectedLibraryId ?? "" },
            set: { newValue in Task { await store.selectLibrary(newValue) } }
        )) {
            ForEach(store.libraries) { library in
                Text(library.name).tag(library.id)
            }
        }
        .pickerStyle(.navigationLink)
    }

    @ViewBuilder
    private var itemsSection: some View {
        // `.searchable`'s query drives `store.search()` above; while it's non-empty,
        // the list shows search results instead of the paged browse list — same
        // single-list-swaps-content pattern the phone's own Library search uses,
        // just without a separate results screen since this Watch list is already
        // narrow.
        if !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchResultsSection
        } else {
            // Batch 412 (Watch redesign): In Progress and the mirrored shelves sit above
            // the long paged list, where paging can't bury them, and show whatever state
            // that list is in (loading, failed or empty).
            inProgressSection
            WatchFromiPhoneSection()
            browseSection
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        switch store.searchState {
        case .idle, .loading:
            ProgressView().tint(WatchTheme.accent)
        case .failed(let message):
            Text(message).font(WatchMetrics.secondaryFont()).foregroundStyle(WatchTheme.secondaryText)
        case .loaded:
            if store.searchResults.isEmpty {
                Text("No results").font(WatchMetrics.secondaryFont()).foregroundStyle(WatchTheme.secondaryText)
            } else {
                ForEach(store.searchResults) { item in
                    libraryItemRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var browseSection: some View {
        switch store.itemsState {
        case .idle, .loading:
            ProgressView().tint(WatchTheme.accent)
        case .failed(let message):
            WatchStandaloneErrorState(message: .verbatim(message)) {
                Task { await store.loadMoreItems() }
            }
        case .loaded:
            if store.items.isEmpty {
                Text("This library is empty.").font(WatchMetrics.secondaryFont()).foregroundStyle(WatchTheme.secondaryText)
            } else {
                // UX fix (31 August 2026), direct user request ("make downloads more
                // intuitive"): swiping a row (`downloadSwipeAction(for:)` below) is
                // the ONLY way to start a download on this screen — no button, no
                // menu, nothing else hints it exists. A first-time standalone user
                // has no way to discover it short of accidentally swiping. A plain
                // `Section` footer is the same low-risk, already-established pattern
                // this app uses elsewhere for exactly this kind of "here's how this
                // screen works" note (e.g. `WatchModeSettingsView`'s own footer) —
                // not a one-time dismissible tip (no TipKit setup exists anywhere in
                // this target yet, and introducing one for a single hint is more
                // machinery than a persistent one-line footer needs).
                Section {
                    ForEach(store.items) { item in
                        libraryItemRow(item)
                            .onAppear {
                                guard item.id == store.items.last?.id else { return }
                                Task { await store.loadMoreItems() }
                            }
                    }
                    if store.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView().tint(WatchTheme.accent)
                            Spacer()
                        }
                    }
                } footer: {
                    // Critique 2026-10-06 (harden): Download is a visible button on the
                    // book now; the swipe is a shortcut, so the hint says both.
                    Text("Tap a book to play or download it. Swipe left to download quickly.")
                        .font(WatchMetrics.captionFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                }
            }
        }
    }

    /// Critique 2026-10-06 (adapt): the books part-way through, first — the one to take
    /// on a run is usually one of these — each with Download to Watch right under it
    /// rather than behind a swipe or a second screen.
    @ViewBuilder
    private var inProgressSection: some View {
        if !store.inProgressItems.isEmpty {
            Section("In Progress") {
                ForEach(store.inProgressItems) { item in
                    libraryItemRow(item)
                    if (watchStore.localDownloads.states[item.id] ?? .notDownloaded) == .notDownloaded {
                        Button {
                            WatchHaptics.tap()
                            Task {
                                await watchStore.localDownloads.startDownload(
                                    itemId: item.id,
                                    title: item.media?.metadata?.title ?? String(localized: "Untitled"),
                                    author: item.media?.metadata?.authorName ?? String(localized: "Unknown Author"),
                                    expectedBytes: item.sizeBytes)
                            }
                        } label: {
                            Label("Download to Watch", systemImage: "arrow.down.circle")
                                .font(WatchMetrics.secondaryFont(weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel("Download \(item.media?.metadata?.title ?? String(localized: "this book")) to Watch")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func libraryItemRow(_ item: WatchLibraryItem) -> some View {
        NavigationLink {
            WatchBookDetailView(item: item)
        } label: {
            // Batch 412 (Watch redesign): the shared `WatchBookRow` (40pt cover, two-line
            // title). Stage 5's status glyph stays, as the trailing slot: a swipe action
            // alone is easy to miss as the only way to tell a row is downloaded.
            WatchBookRow(
                title: item.media?.metadata?.title ?? String(localized: "Untitled"),
                author: item.media?.metadata?.authorName ?? String(localized: "Unknown Author"),
                progress: item.mediaProgress?.progress,
                cover: { StandaloneCoverThumbnail(itemId: item.id, side: 40) },
                trailing: { downloadStatusGlyph(for: item.id) })
            .accessibilityElement(children: .combine)
        }
        // Critique 2026-10-06 (harden): no full swipe, so Remove can't fire by overshoot.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            downloadSwipeAction(for: item)
        }
    }

    @ViewBuilder
    private func downloadStatusGlyph(for itemId: String) -> some View {
        switch watchStore.localDownloads.states[itemId] ?? .notDownloaded {
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(WatchMetrics.secondaryFont())
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WatchTheme.icon)   // Critique 2026-10-06 (colorize): static state, not live
        case .queued:
            ProgressView().tint(WatchTheme.accent).controlSize(.mini)
        case .downloading(let progress):
            ProgressView(value: progress).tint(WatchTheme.accent).frame(width: 20)
        case .failed(let reason):
            // UX fix (31 August 2026): the failure reason (`WatchLocalDownloadState
            // .failed(String)`) was captured by `WatchLocalDownloadManager` but never
            // shown anywhere — this glyph was a bare exclamation mark with no way to
            // learn *why* short of guessing. VoiceOver users now hear the real reason
            // directly; sighted users get the fuller picture in
            // `StandaloneDownloadsView`'s new in-progress section (see that file),
            // which is a better home for the full text than a tooltip-less watchOS
            // glyph.
            Image(systemName: "exclamationmark.circle")
                .font(WatchMetrics.secondaryFont())
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WatchTheme.danger)
                .accessibilityLabel("Download failed: \(reason)")
        case .notDownloaded:
            EmptyView()
        }
    }

    /// Stage 5 — download/cancel/remove, one swipe action whose label and effect
    /// depend on this item's current `WatchLocalDownloadState`. A `@ViewBuilder`
    /// function rather than a single `Button` with branching properties: each case's
    /// `Button` differs enough (role, tint, action) that a shared return type isn't
    /// natural here, and `@ViewBuilder` handles that directly.
    @ViewBuilder
    private func downloadSwipeAction(for item: WatchLibraryItem) -> some View {
        let manager = watchStore.localDownloads
        switch manager.states[item.id] ?? .notDownloaded {
        case .notDownloaded:
            Button {
                Task {
                    await manager.startDownload(
                        itemId: item.id,
                        title: item.media?.metadata?.title ?? String(localized: "Untitled"),
                        author: item.media?.metadata?.authorName ?? String(localized: "Unknown Author"),
                        expectedBytes: item.sizeBytes)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(WatchTheme.accent)
        case .failed:
            // UX fix (31 August 2026): same action as `.notDownloaded` above
            // (`startDownload` already handles retrying a failed item cleanly — see
            // its own guard), but labeled "Retry" instead of "Download" so this row's
            // swipe action doesn't claim to be starting a fresh download when it's
            // actually the second attempt at one that just failed.
            Button {
                Task {
                    await manager.startDownload(
                        itemId: item.id,
                        title: item.media?.metadata?.title ?? String(localized: "Untitled"),
                        author: item.media?.metadata?.authorName ?? String(localized: "Unknown Author"),
                        expectedBytes: item.sizeBytes)
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(WatchTheme.accent)
        case .queued, .downloading:
            Button(role: .destructive) {
                manager.cancelDownload(itemId: item.id)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        case .downloaded:
            Button(role: .destructive) {
                pendingRemoveId = item.id
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

/// Shared "couldn't load, tap to retry" state for standalone screens that hit the
/// network directly — distinct from `WatchOpenOniPhoneEmptyState` (companion mode's
/// "open this on iPhone" dead-end), since a standalone failure is retryable from right
/// here, not a redirect to another device.
struct WatchStandaloneErrorState: View {
    let message: LocalizedStringResource
    let retry: () -> Void

    init(message: LocalizedStringResource, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    // Visual polish pass (31 August 2026) — see `WatchOpenOniPhoneEmptyState`'s
    // identical comment: wrapped in `WatchCard` and given a warning-tinted glyph
    // instead of a bare gray icon, so a retryable failure reads as a designed state
    // rather than a placeholder. `WatchTheme.warning`, not `.danger` — this is a
    // recoverable "couldn't reach it right now," not a hard failure.
    var body: some View {
        WatchCard {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(WatchMetrics.heroGlyphFont())
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WatchTheme.warning)
                Text(message)
                    .font(WatchMetrics.secondaryFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Retry", action: retry)
                    .font(WatchMetrics.secondaryFont(weight: .semibold))
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 4)
    }
}

#Preview {
    NavigationStack { StandaloneLibraryView() }
        .environment(WatchStore.shared)
}
