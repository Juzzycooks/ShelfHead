import SwiftUI

/// "1 book" / "6 books" for collection copy in this file.
private func collectionBooksPhrase(_ count: Int) -> String {
    count == 1
        ? String(localized: "1 book", comment: "Count phrase for exactly one book in a collection")
        : String(localized: "\(count) books", comment: "Count phrase for several books in a collection; %lld is the count")
}

/// "1 item" / "6 items" for playlist copy in this file.
private func playlistItemsPhrase(_ count: Int) -> String {
    count == 1
        ? String(localized: "1 item", comment: "Count phrase for exactly one entry in a playlist")
        : String(localized: "\(count) items", comment: "Count phrase for several entries in a playlist; %lld is the count")
}

// Adaptive so iPad / landscape fill with more columns instead of two huge tiles
// (matches the main Library grid).
private let bookGridColumns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

// MARK: - Collections

struct CollectionsBrowseView: View {
    var search: String = ""
    /// Critique 2026-10-05 (Library): tab re-tap scroll-to-top, as in Books.
    var scrollToTopSignal: Int = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    private var filtered: [BookCollection] {
        let all = libraryViewModel.collections
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        // LS-6 (docs/design-review.md, Round 3): hoisted so the branch condition and
        // the `.shelfAnimation(value:)` below can't drift apart — mirrors `HomeView`'s
        // AN-3 `showsSkeleton` pattern.
        let showsSkeleton = libraryViewModel.isLoadingCollections && libraryViewModel.collections.isEmpty
        Group {
            if showsSkeleton {
                // Was a centred `LoadingView` spinner — the odd one out next to
                // Library Books' shape-matched skeleton. Row shape here is a leading
                // 28pt glyph + name/count, same as `AuthorsBrowseView`'s rows.
                SkeletonList()
                    .accessibilityElement()
                    .accessibilityLabel("Loading collections…")
                    .transition(.opacity)
            } else if libraryViewModel.collections.isEmpty && libraryViewModel.collectionsLoadFailed {
                // UI-11: distinguishes a failed load from a library with no collections.
                LoadFailedStateView(action: { Task { await libraryViewModel.loadCollections() } })
            } else if libraryViewModel.collections.isEmpty {
                EmptyStateView(icon: "rectangle.stack", title: LocalizedStringResource("No collections"), subtitle: LocalizedStringResource("Collections you create on your server appear here"))
            } else if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matches", subtitle: "No collections match “\(search)”")
            } else {
                List {
                    ForEach(filtered) { collection in
                        LibraryRouteLink(.collection(collection)) {
                            HStack(spacing: 12) {
                                // Decorative: the row's spoken label already says "collection"
                                // explicitly (see `rowAccessibilityLabel` below), so the glyph
                                // adds nothing a VoiceOver user doesn't already have.
                                Image(systemName: "rectangle.stack.fill")
                                    .foregroundStyle(Color.shelfMuted).frame(width: 28)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Typo.rowTitle(Text(collection.displayName)).foregroundStyle(Color.shelfCream)
                                    Typo.rowSubtitle(Text(collectionBooksPhrase(collection.bookCount)))
                                        .foregroundStyle(Color.shelfMuted)
                                }
                            }
                            .padding(.vertical, 4)
                            // N-4 (REVIEW_2026-09-14_DESIGN.md): this row had zero accessibility
                            // annotations — VoiceOver split it into an unlabelled decorative
                            // icon, the name, and the count as three separate stops with no
                            // indication this was a *collection* rather than a playlist or a
                            // plain book row. Composed into one element (name, kind, count),
                            // mirroring `LibraryListRow.rowA11yLabel`'s established pattern in
                            // this codebase.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.rowAccessibilityLabel(name: collection.displayName, bookCount: collection.bookCount))
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                }
                .scrollContentBackground(.hidden)
                .transition(.opacity)
                .scrollsToTop(signal: scrollToTopSignal, firstID: filtered.first?.id)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
        .task { if libraryViewModel.collections.isEmpty { await libraryViewModel.loadCollections() } }
        .refreshable { await libraryViewModel.loadCollections() }
        .reexpandsTabBarOnAppear()
    }

    /// Pure so it can be pinned with a regression test (see
    /// `ShelfHeadTests/HistoryAndCollectionsA11yTests.swift`) rather than only
    /// exercised through a live VoiceOver pass.
    static func rowAccessibilityLabel(name: String, bookCount: Int) -> String {
        String(localized: "\(name), collection, \(collectionBooksPhrase(bookCount))", comment: "VoiceOver label of a collection row; first %@ is the collection name, second %@ is a count phrase like '6 books'")
    }
}

// MARK: - Playlists

struct PlaylistsBrowseView: View {
    var search: String = ""
    /// Critique 2026-10-05 (Library): tab re-tap scroll-to-top, as in Books.
    var scrollToTopSignal: Int = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel

    private var filtered: [Playlist] {
        let all = libraryViewModel.playlists
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        // LS-6 (docs/design-review.md, Round 3): hoisted so the branch condition and
        // the `.shelfAnimation(value:)` below can't drift apart — mirrors `HomeView`'s
        // AN-3 `showsSkeleton` pattern.
        let showsSkeleton = libraryViewModel.isLoadingPlaylists && libraryViewModel.playlists.isEmpty
        Group {
            if showsSkeleton {
                // Was a centred `LoadingView` spinner — the odd one out next to
                // Library Books' shape-matched skeleton. Same row shape as
                // `CollectionsBrowseView` just above.
                SkeletonList()
                    .accessibilityElement()
                    .accessibilityLabel("Loading playlists…")
                    .transition(.opacity)
            } else if libraryViewModel.playlists.isEmpty && libraryViewModel.playlistsLoadFailed {
                // UI-11: distinguishes a failed load from a library with no playlists.
                LoadFailedStateView(action: { Task { await libraryViewModel.loadPlaylists() } })
            } else if libraryViewModel.playlists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: LocalizedStringResource("No playlists"), subtitle: LocalizedStringResource("Playlists you create on your server appear here"))
            } else if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matches", subtitle: "No playlists match “\(search)”")
            } else {
                List {
                    ForEach(filtered) { playlist in
                        LibraryRouteLink(.playlist(playlist)) {
                            HStack(spacing: 12) {
                                // Decorative — see the matching note in `CollectionsBrowseView`.
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(Color.shelfMuted).frame(width: 28)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Typo.rowTitle(Text(playlist.displayName)).foregroundStyle(Color.shelfCream)
                                    Typo.rowSubtitle(Text(playlistItemsPhrase(playlist.libraryItems.count)))
                                        .foregroundStyle(Color.shelfMuted)
                                }
                            }
                            .padding(.vertical, 4)
                            // N-4: same fix as `CollectionsBrowseView`'s row — one composed
                            // label (name, kind, count) instead of three unlabelled stops.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.rowAccessibilityLabel(name: playlist.displayName, itemCount: playlist.libraryItems.count))
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                }
                .scrollContentBackground(.hidden)
                .transition(.opacity)
                .scrollsToTop(signal: scrollToTopSignal, firstID: filtered.first?.id)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
        .task { if libraryViewModel.playlists.isEmpty { await libraryViewModel.loadPlaylists() } }
        .refreshable { await libraryViewModel.loadPlaylists() }
        .reexpandsTabBarOnAppear()
    }

    /// Pure so it can be pinned with a regression test (see
    /// `ShelfHeadTests/HistoryAndCollectionsA11yTests.swift`) rather than only
    /// exercised through a live VoiceOver pass.
    static func rowAccessibilityLabel(name: String, itemCount: Int) -> String {
        String(localized: "\(name), playlist, \(playlistItemsPhrase(itemCount))", comment: "VoiceOver label of a playlist row; first %@ is the playlist name, second %@ is a count phrase like '6 items'")
    }
}


// MARK: - Shared detail grid (used by both collections & playlists)

struct BookCollectionDetailView: View {
    /// Where the books come from, so the page can refresh. Nil keeps the old static
    /// behaviour (the `books` snapshot only).
    enum Source: Equatable {
        case collection(String)
        case playlist(String)
    }

    let title: String
    /// The snapshot from the list row; shown until (and unless) a refresh finds newer data.
    let books: [LibraryItem]
    var source: Source? = nil
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel

    /// Critique 2026-10-06 (shape → distill): was a static array with no refresh. Reads
    /// the view model's current copy by id, so pull-to-refresh shows server changes.
    private var items: [LibraryItem] {
        switch source {
        case .collection(let id)?:
            return libraryViewModel.collections.first { $0.id == id }?.books ?? books
        case .playlist(let id)?:
            return libraryViewModel.playlists.first { $0.id == id }?.libraryItems ?? books
        case nil:
            return books
        }
    }

    private var isLoading: Bool {
        switch source {
        case .collection?: return libraryViewModel.isLoadingCollections
        case .playlist?: return libraryViewModel.isLoadingPlaylists
        case nil: return false
        }
    }

    private var isPlaylist: Bool {
        if case .playlist? = source { return true }
        return false
    }

    private func isFinished(_ item: LibraryItem) -> Bool {
        libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
    }

    /// Books Play in Order and Add All can use: podcasts (a playlist's episode rows resolve
    /// to the whole show) and ebook-only items are left out.
    private var playable: [LibraryItem] {
        var seen = Set<String>()
        return items.filter { !$0.isPodcast && !$0.isEbookOnly && seen.insert($0.id).inserted }
    }

    private var plan: PlayInOrderPlan? {
        let candidates = playable
        return Self.playInOrderPlan(orderedIds: candidates.map(\.id),
                                    playable: Set(candidates.map(\.id)),
                                    finished: Set(candidates.filter { isFinished($0) }.map(\.id)))
    }

    var body: some View {
        let current = items
        let showsSkeleton = current.isEmpty && isLoading
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if showsSkeleton {
                ScrollView {
                    SkeletonGrid(padding: EdgeInsets(top: Space.l, leading: Space.pageH, bottom: Space.l, trailing: Space.pageH))
                }
                .scrollDisabled(true)
                .accessibilityElement()
                .accessibilityLabel("Loading\u{2026}")
                .transition(.opacity)
            } else if current.isEmpty {
                // In a ScrollView so pull-to-refresh works on the empty state too.
                ScrollView {
                    EmptyStateView(icon: "book.closed", title: "Nothing here yet",
                                   subtitle: isPlaylist
                                       ? "Add books to this playlist on your server, then pull to refresh."
                                       : "Add books to this collection on your server, then pull to refresh.")
                        .containerRelativeFrame(.vertical)
                }
                .transition(.opacity)
            } else {
                ScrollView {
                    header(current)
                    LazyVGrid(columns: bookGridColumns, spacing: 20) {
                        ForEach(current) { item in
                            BookLink(item) {
                                // Critique 2026-10-05 (Library): progress/download/finished state.
                                BookGridTile(item: item)
                            }
                            .buttonStyle(.plain)
                            // UX-1 (docs/design-review.md, Round 3): collection/playlist
                            // grids had no long-press menu, so starting playback meant
                            // opening Book Detail first. `PlayerViewModel`/`LibraryViewModel`
                            // aren't declared on this view — `BookContextMenu` reads them
                            // itself from the environment, which is injected at app root.
                            .bookContextMenu(item)
                        }
                    }
                    // VD-2 (docs/design-review.md, Round 6): was `.padding(16)`, a
                    // narrower gutter than the same `CassetteTile` grid in Library and
                    // Series (`Space.pageH`, 20).
                    .padding(.horizontal, Space.pageH)
                    .padding(.vertical, Space.l)
                }
                .transition(.opacity)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .reexpandsTabBarOnAppear()
    }

    private func reload() async {
        switch source {
        case .collection?: await libraryViewModel.loadCollections()
        case .playlist?: await libraryViewModel.loadPlaylists()
        case nil: break
        }
    }

    // MARK: Header

    /// Critique 2026-10-06 (shape → distill): One Hero Rule. Count and total length, one
    /// primary "Play in Order", one quieter "Add All to Up Next". On the ground, no card.
    @ViewBuilder
    private func header(_ current: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Typo.figure(Text(Self.summaryText(count: current.count,
                                              totalDuration: current.reduce(0) { $0 + $1.duration },
                                              isPlaylist: isPlaylist)))
                .foregroundStyle(Color.shelfMuted)

            if let plan, let start = playable.first(where: { $0.id == plan.startId }) {
                let loaded = playerViewModel.currentBook
                let caption = Self.playInOrderCaption(
                    startTitle: start.title, queuedCount: plan.queueIds.count,
                    loadedTitle: loaded.flatMap { $0.id == start.id ? nil : $0.title })
                Button {
                    Haptics.impact(.medium)
                    playInOrder(plan)
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "play.fill").accessibilityHidden(true)
                        Text("Play in Order")
                    }
                    .shelfButtonStyle()
                }
                .accessibilityHint(caption)
                .disabled(playerViewModel.isLoadingSession)

                Typo.supporting(Text(caption))
                    .foregroundStyle(Color.shelfMuted)
                    .accessibilityHidden(true)   // read as the button's hint

                Button {
                    Haptics.selection()
                    playerViewModel.addToQueue(playable)
                } label: {
                    // DESIGN.md: a secondary action is a text button in the
                    // `secondaryAction` role; 44 pt tall for the touch target.
                    Typo.secondaryAction(Label("Add All to Up Next", systemImage: "text.badge.plus"))
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.pageH)
        .padding(.top, Space.l)
    }

    /// Start the plan's first book, then queue the rest through the existing bulk
    /// `addToQueue` (one persist, one toast; already-queued books are skipped). Replacing
    /// the loaded book follows Book Detail's Play Instead: no confirm, the caption names it.
    /// The rest is queued only once the start really happened, so a refused start (cellular
    /// off, offline and not downloaded) doesn't leave a half-built queue behind.
    private func playInOrder(_ plan: PlayInOrderPlan) {
        let byId = Dictionary(playable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let start = byId[plan.startId] else { return }
        let rest = plan.queueIds.compactMap { byId[$0] }
        if playerViewModel.currentBook?.id == start.id, !playerViewModel.isAwaitingResume {
            // Already the loaded book: resume rather than restart its session.
            if !playerViewModel.isPlaying { playerViewModel.togglePlayPause() }
            playerViewModel.showFullPlayer = true
            if !rest.isEmpty { playerViewModel.addToQueue(rest) }
            return
        }
        Task {
            await playerViewModel.startPlayback(for: start)
            guard playerViewModel.currentBook?.id == start.id, !rest.isEmpty else { return }
            playerViewModel.addToQueue(rest)
        }
    }

    // MARK: Pure decisions (pinned by `DrillDownActionsTests`)

    struct PlayInOrderPlan: Equatable {
        let startId: String
        let queueIds: [String]
    }

    /// Starts at the first unfinished book in list order and queues the unfinished books
    /// after it. When everything is finished it starts again from the top and queues the
    /// rest. Ids not in `playable` and repeats are skipped. Nil when nothing is playable.
    static func playInOrderPlan(orderedIds: [String], playable: Set<String>, finished: Set<String>) -> PlayInOrderPlan? {
        var seen = Set<String>()
        let candidates = orderedIds.filter { playable.contains($0) && seen.insert($0).inserted }
        guard let first = candidates.first else { return nil }
        guard let startIndex = candidates.firstIndex(where: { !finished.contains($0) }) else {
            return PlayInOrderPlan(startId: first, queueIds: Array(candidates.dropFirst()))
        }
        let rest = candidates[(startIndex + 1)...].filter { !finished.contains($0) }
        return PlayInOrderPlan(startId: candidates[startIndex], queueIds: Array(rest))
    }

    /// "Starts with Dune, then 4 more in Up Next. Plays this book instead of X."
    static func playInOrderCaption(startTitle: String, queuedCount: Int, loadedTitle: String?) -> String {
        let lead = queuedCount <= 0
            ? String(localized: "Starts with \(startTitle).", comment: "Caption under Play in Order; %@ is the title of the first book to play")
            : String(localized: "Starts with \(startTitle), then \(queuedCount) more in Up Next.", comment: "Caption under Play in Order; first %@ is the title of the first book, %lld is how many more are queued")
        if let note = BookDetailView.playsInsteadNote(otherTitle: loadedTitle) {
            // Batch 403: two whole sentences, so no catalog key — "%@ %@" is shared with
            // verb + title and hours + minutes, which keep their space in Chinese.
            return LocalizedText.sentences([lead, note])
        }
        return lead
    }

    /// "6 books · 42h 10m" (playlists count "items"). Duration is left off when unknown.
    static func summaryText(count: Int, totalDuration: Double, isPlaylist: Bool) -> String {
        let base = isPlaylist ? playlistItemsPhrase(count) : collectionBooksPhrase(count)
        guard totalDuration >= 60 else { return base }
        return String(localized: "\(base) \u{00B7} \(totalDuration.formattedDuration)", comment: "Collection/playlist header; first %@ is a count phrase like '6 books', second %@ is the total duration like '42h 10m'")
    }
}
