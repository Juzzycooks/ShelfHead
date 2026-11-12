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
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showItemsEditor = false
    @State private var editNotice: String?

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

    /// L3: grid rows with unique ids (item id + episode id). Collections and the static
    /// snapshot carry no episode ids.
    private var entries: [PlaylistEntry] {
        if case .playlist(let id)? = source,
           let playlist = libraryViewModel.playlists.first(where: { $0.id == id }) {
            return playlist.entries
        }
        return items.map { PlaylistEntry(item: $0, episodeId: nil) }
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
                        ForEach(entries) { entry in
                            let item = entry.item
                            if let episode = entry.episode {
                                // L3: a playlist episode plays that episode (it used to open the
                                // whole show, and two episodes of one show shared an id).
                                Button {
                                    Haptics.selection()
                                    Task { await playerViewModel.startPlaybackOfferingUndo(for: item, episode: episode) }
                                } label: {
                                    BookGridTile(item: item)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(String(localized: "Plays this episode"))
                                .contextMenu {
                                    Button {
                                        Haptics.selection()
                                        playerViewModel.playNext(item, episode: episode)
                                    } label: {
                                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    Button {
                                        Haptics.selection()
                                        playerViewModel.addToQueue(item, episode: episode)
                                    } label: {
                                        Label("Add to Up Next", systemImage: "text.badge.plus")
                                    }
                                }
                            } else {
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
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEditAnything {
                ToolbarItem(placement: .topBarTrailing) { editMenu }
            }
        }
        .alert(isPlaylist ? String(localized: "Rename Playlist") : String(localized: "Rename Collection"), isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename() }
                .disabled(ListEditing.trimmedName(renameText) == nil)
        }
        .confirmationDialog(isPlaylist ? String(localized: "Delete this playlist?") : String(localized: "Delete this collection?"),
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(isPlaylist ? String(localized: "Delete Playlist") : String(localized: "Delete Collection"), role: .destructive) { deleteList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The books stay in your library.")
        }
        .sheet(isPresented: $showItemsEditor) { itemsEditor }
        .toast(message: $editNotice)
        .refreshable { await reload() }
        .reexpandsTabBarOnAppear()
    }

    // MARK: Editing (REVIEW 2026-11-11 F2)

    /// The live name (a rename shows at once); the pushed `title` until the list is found.
    private var currentTitle: String {
        switch source {
        case .collection(let id)?: return libraryViewModel.collections.first { $0.id == id }?.displayName ?? title
        case .playlist(let id)?: return libraryViewModel.playlists.first { $0.id == id }?.displayName ?? title
        case nil: return title
        }
    }

    private var canEditAnything: Bool {
        switch source {
        case .collection?: return ListEditing.canEditCollection(user: authViewModel.currentUser)
        case .playlist?: return true
        case nil: return false
        }
    }

    private var editMenu: some View {
        Menu {
            Button {
                renameText = currentTitle
                showRename = true
            } label: { Label("Rename\u{2026}", systemImage: "pencil") }
            Button { showItemsEditor = true } label: {
                Label(isPlaylist ? String(localized: "Edit Items\u{2026}") : String(localized: "Remove Books\u{2026}"), systemImage: "list.bullet")
            }
            .disabled(entries.isEmpty)
            if isPlaylist || ListEditing.canDeleteCollection(user: authViewModel.currentUser) {
                Divider()
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label(isPlaylist ? String(localized: "Delete Playlist\u{2026}") : String(localized: "Delete Collection\u{2026}"), systemImage: "trash")
                }
            }
        } label: {
            Label("Edit", systemImage: "ellipsis")
        }
        .monochromeToolbarItem()
    }

    private var editorRows: [ListItemsEditor.Row] {
        entries.map { entry in
            ListItemsEditor.Row(ref: PlaylistItemRef(libraryItemId: entry.item.id, episodeId: entry.episodeId),
                                title: entry.episode?.title ?? entry.item.title)
        }
    }

    private var itemsEditor: some View {
        // Re-ordering sends every row, so it needs each playlist row to be one the app decoded.
        var canReorder = false
        if case .playlist(let id)? = source, let playlist = libraryViewModel.playlists.first(where: { $0.id == id }) {
            canReorder = playlist.entries.count == (playlist.items?.count ?? -1)
        }
        return ListItemsEditor(rows: editorRows, canReorder: canReorder) { edited in
            await saveItems(edited)
        }
        .presentationDetents([.large])
    }

    private func saveItems(_ edited: [ListItemsEditor.Row]) async -> Bool {
        let outcome = ListEditing.editOutcome(original: editorRows.map(\.ref), edited: edited.map(\.ref))
        do {
            switch source {
            case .collection(let id)?:
                try await libraryViewModel.removeFromCollection(id: id, bookIds: outcome.removed.map(\.libraryItemId))
            case .playlist(let id)?:
                try await libraryViewModel.updatePlaylistItems(id: id, removed: outcome.removed, order: outcome.order)
                // The server deletes a playlist whose last item is removed.
                if edited.isEmpty { dismiss() }
            case nil: break
            }
            Haptics.success()
            return true
        } catch {
            editNotice = ListEditing.failureMessage
            return false
        }
    }

    private func rename() {
        guard let name = ListEditing.trimmedName(renameText) else { return }
        Task {
            do {
                switch source {
                case .collection(let id)?: try await libraryViewModel.renameCollection(id: id, name: name)
                case .playlist(let id)?: try await libraryViewModel.renamePlaylist(id: id, name: name)
                case nil: break
                }
            } catch { editNotice = ListEditing.failureMessage }
        }
    }

    private func deleteList() {
        Task {
            do {
                switch source {
                case .collection(let id)?: try await libraryViewModel.deleteCollection(id: id)
                case .playlist(let id)?: try await libraryViewModel.deletePlaylist(id: id)
                case nil: break
                }
                Haptics.success()
                dismiss()
            } catch { editNotice = ListEditing.failureMessage }
        }
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
            // Batch 490 (REVIEW 2026-11-11 L4): replacing the loaded book offers "Jump back".
            await playerViewModel.startPlaybackOfferingUndo(for: start)
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

// MARK: - Editing lists (REVIEW 2026-11-11 F2)

/// Pure decisions behind Add to Playlist / Collection and the list editor, pinned by
/// `ShelfHeadTests/Top10PlaylistEditTests.swift`.
enum ListEditing {
    /// A name the server will accept: trimmed, non-empty. Nil means keep the Save button disabled.
    static func trimmedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// ABS answers 403 to collection POST/PATCH unless the user `canUpdate` (admins always can), so
    /// "Add to Collection" is offered only then. A podcast show is not a book (collections are books only).
    static func offersAddToCollection(user: User?, isPodcast: Bool) -> Bool {
        !isPodcast && user?.canUpdateLibrary == true
    }

    /// Playlists are the user's own, so any signed-in user may add a book. Shows are excluded: a
    /// playlist takes episodes, which Book Detail does not pick.
    static func offersAddToPlaylist(isPodcast: Bool) -> Bool { !isPodcast }

    /// Collection DELETE needs `canDelete` on the server (admins always have it).
    static func canDeleteCollection(user: User?) -> Bool {
        user?.isAdmin == true || user?.permissions?.delete == true
    }

    /// Renaming and removing books are PATCH/POST on the server, so they need update permission.
    static func canEditCollection(user: User?) -> Bool { user?.canUpdateLibrary == true }

    /// The rows of a playlist as write payloads; nil if any row lacks a library item id (re-ordering
    /// needs every row, so the editor then offers removal only).
    static func playlistRefs(_ items: [PlaylistItem]) -> [PlaylistItemRef]? {
        var refs: [PlaylistItemRef] = []
        for row in items {
            guard let id = row.libraryItemId ?? row.libraryItem?.id else { return nil }
            refs.append(PlaylistItemRef(libraryItemId: id, episodeId: row.episodeId))
        }
        return refs
    }

    /// What Done should send: the rows removed, and, only when the survivors' order differs from the
    /// original order, the full survivor list for the re-order PATCH.
    static func editOutcome(original: [PlaylistItemRef], edited: [PlaylistItemRef])
        -> (removed: [PlaylistItemRef], order: [PlaylistItemRef]?) {
        let kept = Set(edited.map { $0.libraryItemId + "#" + ($0.episodeId ?? "") })
        let removed = original.filter { !kept.contains($0.libraryItemId + "#" + ($0.episodeId ?? "")) }
        let editedKeys = Set(edited.map { $0.libraryItemId + "#" + ($0.episodeId ?? "") })
        let survivorsInOriginalOrder = original.filter { editedKeys.contains($0.libraryItemId + "#" + ($0.episodeId ?? "")) }
        return (removed, survivorsInOriginalOrder == edited ? nil : edited)
    }

    static var failureMessage: String {
        String(localized: "Couldn\u{2019}t save that change. Check your connection and permissions, then try again.",
               comment: "Toast when adding to, editing or deleting a playlist or collection fails")
    }
}

/// "Add to Playlist…" / "Add to Collection…": existing lists for the library, tap to add, or make a new
/// one holding this book. Standard List plus an alert with a text field.
struct AddToListSheet: View {
    enum Kind: String, Identifiable { case playlist, collection; var id: String { rawValue } }

    let item: LibraryItem
    let kind: Kind
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private struct Row: Identifiable { let id: String; let name: String; let count: Int; let contains: Bool }

    private var rows: [Row] {
        switch kind {
        case .playlist:
            return libraryViewModel.playlists.map { p in
                Row(id: p.id, name: p.displayName, count: p.items?.count ?? 0,
                    contains: (p.items ?? []).contains { ($0.libraryItemId ?? $0.libraryItem?.id) == item.id })
            }
        case .collection:
            return libraryViewModel.collections.map { c in
                Row(id: c.id, name: c.displayName, count: c.bookCount,
                    contains: (c.books ?? []).contains { $0.id == item.id })
            }
        }
    }

    private var isLoading: Bool {
        kind == .playlist ? libraryViewModel.isLoadingPlaylists : libraryViewModel.isLoadingCollections
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        showNewAlert = true
                    } label: {
                        Label(kind == .playlist ? String(localized: "New Playlist\u{2026}") : String(localized: "New Collection\u{2026}"), systemImage: "plus")
                    }
                    .disabled(busy)
                }
                Section {
                    if rows.isEmpty && isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(rows) { row in
                        Button {
                            add(to: row.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: row.name).foregroundStyle(Color.shelfCream)
                                    Text(kind == .playlist ? playlistItemsPhrase(row.count) : collectionBooksPhrase(row.count))
                                        .font(.caption).foregroundStyle(Color.shelfMuted)
                                }
                                Spacer()
                                if row.contains {
                                    Image(systemName: "checkmark").foregroundStyle(Color.shelfAmberText)
                                        .accessibilityLabel("Already added")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(row.contains || busy)
                    }
                }
            }
            .navigationTitle(kind == .playlist ? String(localized: "Add to Playlist") : String(localized: "Add to Collection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(kind == .playlist ? String(localized: "New Playlist") : String(localized: "New Collection"), isPresented: $showNewAlert) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
                    .disabled(ListEditing.trimmedName(newName) == nil)
            } message: {
                Text("It starts with this book.")
            }
            .alert("Couldn\u{2019}t Add", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                switch kind {
                case .playlist: if !libraryViewModel.playlistsLoaded { await libraryViewModel.loadPlaylists() }
                case .collection: if !libraryViewModel.collectionsLoaded { await libraryViewModel.loadCollections() }
                }
            }
        }
    }

    private func add(to id: String) {
        busy = true
        Task {
            do {
                switch kind {
                case .playlist: try await libraryViewModel.addToPlaylist(id: id, item: item)
                case .collection: try await libraryViewModel.addToCollection(id: id, item: item)
                }
                Haptics.success()
                dismiss()
            } catch {
                errorMessage = ListEditing.failureMessage
            }
            busy = false
        }
    }

    private func create() {
        guard let name = ListEditing.trimmedName(newName) else { return }
        busy = true
        Task {
            do {
                switch kind {
                case .playlist: try await libraryViewModel.createPlaylist(name: name, with: item)
                case .collection: try await libraryViewModel.createCollection(name: name, with: item)
                }
                Haptics.success()
                dismiss()
            } catch {
                errorMessage = ListEditing.failureMessage
            }
            busy = false
        }
    }
}

/// Edit Items for a collection or playlist: swipe (or the red minus) to remove, drag handles to
/// re-order a playlist. Nothing is sent until Done.
struct ListItemsEditor: View {
    struct Row: Identifiable, Equatable {
        let ref: PlaylistItemRef
        let title: String
        var id: String { ref.libraryItemId + "#" + (ref.episodeId ?? "") }
    }

    let rows: [Row]
    let canReorder: Bool
    /// Returns true when the save worked (the editor then closes).
    let onSave: ([Row]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var edited: [Row] = []
    @State private var saving = false

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        return { from, to in edited.move(fromOffsets: from, toOffset: to) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(edited) { row in
                    Text(verbatim: row.title).foregroundStyle(Color.shelfCream)
                }
                .onDelete { edited.remove(atOffsets: $0) }
                .onMove(perform: moveAction)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saving = true
                        Task {
                            if await onSave(edited) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || edited == rows)
                }
            }
            .onAppear { if edited.isEmpty { edited = rows } }
        }
    }
}
