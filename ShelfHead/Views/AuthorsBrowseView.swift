import SwiftUI

/// "1 book" / "12 books" for the Authors / Narrators copy in this file.
private func browseBookCountPhrase(_ count: Int) -> String {
    count == 1
        ? String(localized: "1 book", comment: "Count phrase for exactly one book under an author or narrator")
        : String(localized: "\(count) books", comment: "Count phrase for several books under an author or narrator; %lld is the count")
}

// MARK: - All Bookmarks (aggregated across every book)

struct AllBookmarksView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var bookmarks: [AudioBookmark] = []
    @State private var books: [String: LibraryItem] = [:]   // libraryItemId → item (resolved)
    /// Critique 2026-10-06 (harden): ids still being fetched. Their rows show a quiet
    /// "Loading…" title instead of "Book unavailable", which is kept for real failures.
    @State private var resolving: Set<String> = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var searchText = ""
    @State private var newestFirst = true
    @State private var notesStore = BookmarkNotesStore.shared
    @State private var exportPayload: SharePayload?
    /// Critique 2026-10-06 (harden): delete here was a full swipe with no way back. The
    /// shared Undo (Book Detail's sheet and the player's sheet use it too).
    @State private var bookmarkUndo = BookmarkDeleteUndo()

    private var filtered: [AudioBookmark] {
        let sorted = Self.sorted(bookmarks, newestFirst: newestFirst)
        guard !searchText.isEmpty else { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.title.lowercased().contains(q) ||
            (books[$0.libraryItemId]?.title.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading {
                LoadingView("Loading bookmarks…")
            } else if bookmarks.isEmpty && loadFailed {
                // UI-11: previously `getAllBookmarks()`'s error was swallowed by
                // `try?`, so a real failure looked identical to "no bookmarks saved."
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load",
                               subtitle: "Check your connection and try again.",
                               actionTitle: "Retry", action: { Task { await load() } })
            } else if bookmarks.isEmpty {
                EmptyStateView(icon: "bookmark", title: LocalizedStringResource("No bookmarks"),
                               subtitle: LocalizedStringResource("Bookmarks you save while listening show up here."))
            } else {
                let loaded = playerViewModel.currentBook
                // Polish pass (J3-3): sort + search-filter once for this pass, not per use.
                let shown = filtered
                List {
                    // Critique 2026-10-06 (harden + clarify): a tap on another book's bookmark
                    // replaces the loaded book. Said once, above the list, in Book Detail's words.
                    if let note = Self.playsInsteadHeader(loadedId: loaded?.id, loadedTitle: loaded?.title,
                                                          bookmarkItemIds: shown.map(\.libraryItemId)) {
                        Typo.supporting(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(shown) { bookmark in
                        Button { jump(to: bookmark) } label: { row(bookmark) }
                            .listRowBackground(Color.shelfCard)
                            .accessibilityHint(rowHint(bookmark, loaded: loaded))
                            // Critique 2026-10-06 (harden): no full swipe; Undo toast below.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(bookmark) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                // Explicit placement — see SettingsView.swift's `.searchable` comment:
                // iOS 26's default search placement floats near the bottom of the
                // screen, which collides with this app's own custom floating
                // mini-player + tab bar (not a real `TabView`, so the system doesn't
                // know to avoid it). Pinning to the nav bar keeps this consistent with
                // every other search field in the app.
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search bookmarks")
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                exportControl
                    .monochromeToolbarItem()
                    .disabled(bookmarks.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newestFirst.toggle() } label: {
                    // iPhone Duo (§2): a titled Label (icon-only in the nav bar).
                    Label(newestFirst ? "Newest first" : "Oldest first",
                          systemImage: newestFirst ? "arrow.down" : "arrow.up")
                }
                .monochromeToolbarItem()
            }
        }
        .sheet(item: $exportPayload) { payload in ActivityView(items: [payload.url]) }
        // The row comes back at once on Undo (`restore`); the re-create syncs behind it.
        .bookmarkUndoToast(bookmarkUndo,
                           bottomInset: bottomBarClearance(bottomInset: 0, hasMiniPlayer: playerViewModel.currentBook != nil),
                           restored: { restore($0) })
        .refreshable { await load() }
        .task { await load() }
        .reexpandsTabBarOnAppear()
    }

    // MARK: Export

    /// Critique 2026-10-06 (clarify): "Export All" used to export only the search results.
    /// With a search active it's now a menu naming both; otherwise one Export button. A
    /// monochrome glyph like every other bar item (was amber text).
    @ViewBuilder
    private var exportControl: some View {
        let scopes = Self.exportScopes(shownCount: filtered.count, totalCount: bookmarks.count)
        if scopes.count > 1 {
            Menu {
                ForEach(scopes, id: \.self) { scope in
                    Button(Self.exportTitle(scope, shownCount: filtered.count, totalCount: bookmarks.count)) {
                        export(scope)
                    }
                }
            } label: {
                Label("Export bookmarks", systemImage: "square.and.arrow.up") // iPhone Duo (§2)
            }
        } else {
            Button { export(.all) } label: {
                Label("Export all bookmarks", systemImage: "square.and.arrow.up")
            }
        }
    }

    enum ExportScope: Hashable { case shown, all }

    /// `.shown` only when a search hides some bookmarks; otherwise `.all` alone.
    static func exportScopes(shownCount: Int, totalCount: Int) -> [ExportScope] {
        guard totalCount > 0 else { return [] }
        return (shownCount > 0 && shownCount < totalCount) ? [.shown, .all] : [.all]
    }

    static func exportTitle(_ scope: ExportScope, shownCount: Int, totalCount: Int) -> String {
        switch scope {
        case .shown: return String(localized: "Export Shown (\(shownCount))", comment: "Export menu item for the bookmarks currently shown by the search; %lld is how many")
        case .all: return String(localized: "Export All (\(totalCount))", comment: "Export menu item for every bookmark; %lld is how many")
        }
    }

    /// One Markdown document for every book with bookmarks, `## <book title>` per
    /// section (this screen has no chapter data, so each section passes `chapters: []`).
    private func export(_ scope: ExportScope) {
        let source = scope == .shown ? filtered : Self.sorted(bookmarks, newestFirst: newestFirst)
        let grouped = Dictionary(grouping: source, by: { $0.libraryItemId })
        let sortedIds = grouped.keys.sorted { (books[$0]?.title ?? "") < (books[$1]?.title ?? "") }
        var sections: [String] = [scope == .shown
            ? String(localized: "# Bookmarks matching \u{201C}\(searchText)\u{201D}", comment: "Markdown heading in an exported bookmarks file; %@ is the search text. Keep the leading # (Markdown heading)")
            : String(localized: "# All Bookmarks", comment: "Markdown heading in an exported bookmarks file. Keep the leading # (Markdown heading)")]
        for itemId in sortedIds {
            guard let marks = grouped[itemId] else { continue }
            let title = books[itemId]?.title ?? String(localized: "Book unavailable", comment: "Placeholder title for a bookmark whose book could not be found")
            let notes = notesStore.notes(forItemId: itemId)
            var section = BookmarkMarkdownExporter.markdown(
                bookTitle: title, author: books[itemId]?.authorName, chapters: [],
                bookmarks: marks, notes: notes)
            section = section.replacingOccurrences(of: "# \(title)", with: "## \(title)")
            sections.append(section)
        }
        let markdown = sections.joined(separator: "\n\n")
        guard let url = BookmarkMarkdownExporter.writeExportFile(
            markdown: markdown, filenameStem: scope == .shown ? "bookmarks" : "all-bookmarks") else { return }
        exportPayload = SharePayload(url: url)
    }

    // MARK: Rows

    private func row(_ bookmark: AudioBookmark) -> some View {
        let item = books[bookmark.libraryItemId]
        let pending = item == nil && resolving.contains(bookmark.libraryItemId)
        let chapter = item?.chapters.first { bookmark.time >= $0.start && bookmark.time < $0.end }?.title
        return HStack(spacing: 12) {
            if let item {
                CoverImageView(itemId: item.id, width: 44, height: 44)
            } else {
                RoundedRectangle(cornerRadius: Radius.thumb).fill(Color.shelfSurface)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(Color.shelfMuted))
            }
            VStack(alignment: .leading, spacing: 2) {
                Typo.rowTitle(Text(item?.title ?? (pending
                    ? String(localized: "Loading\u{2026}", comment: "Placeholder title while a bookmark's book is being looked up")
                    : String(localized: "Book unavailable", comment: "Placeholder title for a bookmark whose book could not be found"))))
                    .foregroundStyle(item == nil ? Color.shelfMuted : Color.shelfCream)
                    .lineLimit(1)
                if !bookmark.title.isEmpty, bookmark.title != bookmark.time.formattedTime {
                    Typo.supporting(Text(bookmark.title)).foregroundStyle(Color.shelfCream.opacity(0.8)).lineLimit(2)
                }
                if let note = notesStore.note(for: bookmark), !note.isEmpty {
                    Typo.fine(Text(note)).foregroundStyle(Color.shelfMuted).lineLimit(2)
                }
                Typo.fine(HStack(spacing: 6) {
                    if let chapter, !chapter.isEmpty {
                        Text(chapter).lineLimit(1)
                        Text("·")
                    }
                    Text(bookmark.time.formattedTime).monospacedDigit()
                })
                .foregroundStyle(Color.shelfMuted)
            }
            Spacer()
            if item != nil {
                Image(systemName: "play.circle").foregroundStyle(Color.shelfMuted)
            }
        }
        .padding(.vertical, 4)
    }

    /// VoiceOver hears the replacement on each row that would cause it.
    private func rowHint(_ bookmark: AudioBookmark, loaded: LibraryItem?) -> String {
        guard let loaded, loaded.id != bookmark.libraryItemId, books[bookmark.libraryItemId] != nil else { return "" }
        return BookDetailView.playsInsteadNote(otherTitle: loaded.title) ?? ""
    }

    /// The note above the list: only when a book is loaded and at least one shown bookmark
    /// belongs to a different book. Pure, pinned by `DrillDownActionsTests`.
    static func playsInsteadHeader(loadedId: String?, loadedTitle: String?, bookmarkItemIds: [String]) -> String? {
        guard let loadedId,
              let title = loadedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              bookmarkItemIds.contains(where: { $0 != loadedId }) else { return nil }
        return String(localized: "Bookmarks from other books play instead of \(title).", comment: "Note above the All Bookmarks list; %@ is the title of the book currently loaded in the player")
    }

    /// Critique 2026-10-06 (harden): used to `await startPlayback` and then seek whatever
    /// happened. A start that returns early (cellular blocked, offline and not downloaded,
    /// the single-flight guard) leaves the OTHER book loaded, and the seek then moved that
    /// book. Same rule as Book Detail's chapter and bookmark taps (`chapterTapAction`,
    /// `shouldSeekAfterStart`). A same-book jump goes through `seekToBookmark`, so the
    /// player offers "Jump back".
    private func jump(to bookmark: AudioBookmark) {
        guard let item = books[bookmark.libraryItemId] else { return }   // unavailable book
        switch BookDetailView.chapterTapAction(
            isThisBookLoaded: playerViewModel.currentBook?.id == item.id,
            isAwaitingResume: playerViewModel.isAwaitingResume) {
        case .seekThenOpenPlayer:
            playerViewModel.seekToBookmark(bookmark)
            playerViewModel.showFullPlayer = true
        case .startThenSeek:
            Task {
                await playerViewModel.startPlayback(for: item)
                if BookDetailView.shouldSeekAfterStart(loadedBookId: playerViewModel.currentBook?.id,
                                                       itemId: item.id,
                                                       isAwaitingResume: playerViewModel.isAwaitingResume) {
                    playerViewModel.seekToBookmark(bookmark)
                }
            }
        }
    }

    private func delete(_ bookmark: AudioBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarkUndo.delete(bookmark)
    }

    private func restore(_ bookmark: AudioBookmark) {
        guard !bookmarks.contains(where: { $0.id == bookmark.id }) else { return }
        bookmarks.append(bookmark)   // `filtered` sorts by `createdAt`, so it lands where it was
    }

    // MARK: Loading

    /// How many book lookups run at once while the list fills in.
    static let resolveConcurrency = 4

    static func sorted(_ bookmarks: [AudioBookmark], newestFirst: Bool) -> [AudioBookmark] {
        bookmarks.sorted {
            newestFirst ? ($0.createdAt ?? 0) > ($1.createdAt ?? 0)
                        : ($0.createdAt ?? 0) < ($1.createdAt ?? 0)
        }
    }

    /// The order books are looked up in: the order their first bookmark appears on screen,
    /// each book once, so the top of the list fills in first.
    static func resolutionOrder(_ bookmarks: [AudioBookmark], newestFirst: Bool) -> [String] {
        var seen = Set<String>()
        return sorted(bookmarks, newestFirst: newestFirst)
            .map(\.libraryItemId)
            .filter { seen.insert($0).inserted }
    }

    private func load() async {
        // Critique 2026-10-06 (harden): the spinner is only for the very first fetch; a
        // refresh keeps the list on screen.
        if bookmarks.isEmpty { isLoading = true }
        loadFailed = false
        do {
            bookmarks = try await AudiobookshelfAPI.shared.getAllBookmarks()
        } catch {
            // A cancelled pull-to-refresh must not be treated as a real failure, and a
            // transient failure shouldn't blow away bookmarks already shown.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled && bookmarks.isEmpty { loadFailed = true }
        }
        // Critique 2026-10-06 (harden): the list used to wait behind a spinner until every
        // book had resolved, one request at a time. It now shows at once and each book's
        // rows fill in as its lookup returns.
        isLoading = false
        await resolveBooks()
    }

    /// Resolve each book once: a local (offline) manifest first, else the server, with at
    /// most `resolveConcurrency` requests in flight. Best-effort (`try?`): a book that
    /// can't be resolved shows "Book unavailable" on its rows, the list itself is fine.
    private func resolveBooks() async {
        var remote: [String] = []
        for id in Self.resolutionOrder(bookmarks, newestFirst: newestFirst)
        where books[id] == nil && !resolving.contains(id) {
            if let local = DownloadManager.shared.libraryItem(for: id) {
                books[id] = local
            } else {
                remote.append(id)
            }
        }
        guard !remote.isEmpty else { return }
        resolving.formUnion(remote)
        await withTaskGroup(of: (String, LibraryItem?).self) { group in
            var pending = remote.makeIterator()
            for _ in 0..<Self.resolveConcurrency {
                guard let id = pending.next() else { break }
                group.addTask { (id, try? await AudiobookshelfAPI.shared.getItem(itemId: id)) }
            }
            while let result = await group.next() {
                if let item = result.1 { books[result.0] = item }
                resolving.remove(result.0)
                if let next = pending.next() {
                    group.addTask { (next, try? await AudiobookshelfAPI.shared.getItem(itemId: next)) }
                }
            }
        }
    }
}

// MARK: - Authors

// MARK: - Starred-first sections (Authors / Narrators)

/// Pure copy and ordering decisions for the Starred / All sections (library-browse
/// plan §3.3, Q6), pinned by `AuthorsBrowseSectionsTests`.
enum BrowseStarredSections {
    enum Kind { case authors, narrators }

    static var starredTitle: String { String(localized: "Starred", comment: "Section header and VoiceOver word for starred authors and narrators") }

    /// Critique 2026-10-06 (colorize): the page's star toggle, spoken as the UI names it.
    static func toggleLabel(isStarred: Bool) -> String { isStarred ? starredTitle : String(localized: "Star", comment: "VoiceOver label of the star toggle on an author or narrator page (verb)") }

    static func allTitle(for kind: Kind) -> String {
        switch kind {
        case .authors: return String(localized: "All Authors", comment: "Section header listing every author after the starred ones")
        case .narrators: return String(localized: "All Narrators", comment: "Section header listing every narrator after the starred ones")
        }
    }

    /// Headers show only when at least one starred name is present, so a user with no
    /// stars sees today's flat list unchanged.
    static func showsSections(starredCount: Int) -> Bool { starredCount > 0 }

    /// The row displayed first: the first starred item when any, else the first of `rest`.
    /// Scroll-to-top must target this, not the unsplit list's first item.
    static func displayedFirst<T>(starred: [T], rest: [T]) -> T? { starred.first ?? rest.first }
}

struct BrowseStarredSplit<T> {
    let starred: [T]
    let rest: [T]
    var displayedFirst: T? { BrowseStarredSections.displayedFirst(starred: starred, rest: rest) }
}

struct AuthorsBrowseView: View {
    var search: String = ""
    /// Critique 2026-10-05 (Library): tab re-tap scroll-to-top, as in Books.
    var scrollToTopSignal: Int = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel
    /// Observed so a star toggle immediately re-renders every row (favorites are also
    /// used offline by the "New From Favourites" smart filter — see `FavoritesStore`).
    @State private var favorites = FavoritesStore.shared
    @State private var artworkStore = BrowseArtworkStore()

    private var authors: [NamedEntity] {
        let all = libraryViewModel.filterData?.authors ?? []
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        // LS-6 (docs/design-review.md, Round 3): hoisted so the branch condition and
        // the `.shelfAnimation(value:)` below can't drift apart — mirrors `HomeView`'s
        // AN-3 `showsSkeleton` pattern.
        let showsSkeleton = libraryViewModel.isLoadingFilterData && libraryViewModel.filterData == nil
        // Polish pass (J3-2): filter and star-split once per body. They were each recomputed
        // three times (empty check, list, scroll-to-top id).
        let authors = self.authors
        let split = Self.split(authors, favorites: favorites)
        Group {
            // UI-11: previously had no loading OR failure check at all — the very
            // first `.task` load showed "No authors" (a false empty state) for however
            // long `loadFilterData()` took, and a genuine failure looked identical to a
            // library that really has none.
            if showsSkeleton {
                // Was a centred `LoadingView` spinner — the odd one out next to
                // Library Books' shape-matched skeleton. Row shape here is a leading
                // 28pt circular glyph + name + (sometimes) a trailing star, matched by
                // `SkeletonListRow`'s default `.circle` leading art.
                SkeletonList()
                    .accessibilityElement()
                    .accessibilityLabel("Loading authors…")
                    .transition(.opacity)
            } else if libraryViewModel.filterData == nil && libraryViewModel.filterDataLoadFailed {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load",
                               subtitle: "Check your connection and try again.",
                               actionTitle: "Retry", action: { Task { await libraryViewModel.loadFilterData() } })
            } else if authors.isEmpty {
                EmptyStateView(
                    icon: search.isEmpty ? "person.2" : "magnifyingglass",
                    title: search.isEmpty ? "No authors" : "No matches",
                    subtitle: search.isEmpty ? "Author data will appear once your library is scanned"
                                             : "No authors match “\(search)”"
                )
            } else {
                List {
                    if !BrowseStarredSections.showsSections(starredCount: split.starred.count) {
                        ForEach(split.rest, id: \.id) { author in authorRow(author) }
                    } else {
                        Section {
                            ForEach(split.starred, id: \.id) { author in authorRow(author) }
                        } header: { RetroSectionHeader(title: .verbatim(BrowseStarredSections.starredTitle)) }
                        Section {
                            ForEach(split.rest, id: \.id) { author in authorRow(author) }
                        } header: { RetroSectionHeader(title: .verbatim(BrowseStarredSections.allTitle(for: .authors))) }
                    }
                }
                .scrollContentBackground(.hidden)
                .transition(.opacity)
                .scrollsToTop(signal: scrollToTopSignal, firstID: split.displayedFirst?.id)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
        .task {
            if libraryViewModel.filterData == nil {
                await libraryViewModel.loadFilterData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in artworkStore.reset() }
        .reexpandsTabBarOnAppear()
    }

    @ViewBuilder
    private func authorRow(_ author: NamedEntity) -> some View {
        let isFavorite = favorites.isFavoriteAuthor(author.name)
        LibraryRouteLink(.author(author)) {
            HStack(spacing: 12) {
                // Design-direction pass (17 Aug 2026), point 8: a plain
                // leading icon identical on every row isn't an action or
                // state — was amber, diluting it as the "something's
                // active/actionable here" signal; muted like any other
                // decorative glyph now. The favorite star just below
                // stays amber — that one's real state.
                // HIG audit 2026-09-17 H4: decorative, hidden from VoiceOver —
                // the row's composed label below already covers name/favourite.
                // ID-3 (V5): the server's author photo, else a mosaic of their covers.
                BrowseRowArt(artwork: artworkStore.artwork[BrowseArtworkStore.authorKey(author)],
                             placeholderSymbol: "person.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Typo.rowTitle(Text(author.name))
                        .foregroundStyle(Color.shelfCream)
                    if let count = artworkStore.artwork[BrowseArtworkStore.authorKey(author)]?.bookCount {
                        Typo.rowSubtitle(Text(browseBookCountPhrase(count)))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }
                Spacer()
                if isFavorite {
                    // iOS 26/27 Liquid Glass polish pass (26 August
                    // 2026): `.symbolEffect(.bounce, value:)` is the
                    // documented discrete-effect trigger form. **[device
                    // check]**: this glyph only mounts while
                    // `isFavorite` is true (an insert, not a value
                    // change on an already-mounted view), so whether
                    // this actually plays a bounce on that first
                    // appearance (vs. needing the view to already
                    // exist and see `isFavorite` flip) isn't
                    // confirmed without a simulator — harmless either
                    // way (worst case, no animation, same as before).
                    Typo.supporting(Image(systemName: "star.fill")
                        .foregroundStyle(Color.shelfAmberText))
                        .shelfSymbolBounce(value: isFavorite)
                }
            }
            .padding(.vertical, 4)
            // HIG audit 2026-09-17 H4: mirrors CollectionsPlaylistsView's N-4
            // fix — was three unlabelled VoiceOver stops (decorative icon,
            // name, star), never saying "favourite". Composed into one element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rowAccessibilityLabel(name: author.name, isFavorite: isFavorite))
        }
        .listRowBackground(Color.shelfCard)
        .task { await artworkStore.loadAuthor(author) }
        // Critique 2026-10-06 (colorize): was raw `shelfAmber` (white label ≈2:1) and a full
        // swipe, so a one-handed swipe starred by accident. Library's swipe fill and a
        // deliberate tap, as on Library's rows.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Haptics.selection()
                favorites.toggleFavoriteAuthor(author.name)
            } label: {
                Label(isFavorite ? "Unstar" : "Star", systemImage: isFavorite ? "star.slash" : "star.fill")
            }
            .tint(LibrarySwipeTint.amber)
        }
    }

    /// Pure so it can be pinned with a regression test, mirroring
    /// `CollectionsBrowseView.rowAccessibilityLabel`'s established pattern.
    /// Critique 2026-10-06 (colorize): said "Favourite" while the UI says Star / Starred.
    static func rowAccessibilityLabel(name: String, isFavorite: Bool) -> String {
        isFavorite ? String(localized: "\(name), \(BrowseStarredSections.starredTitle)", comment: "VoiceOver label of an author/narrator row that is starred; first %@ is the name, second is the word Starred") : name
    }
}

struct AuthorBooksView: View {
    let author: NamedEntity

    /// Critique 2026-10-05 (Library): pure, tested in `LibraryStateTests`. The series name
    /// when the book has one, otherwise its duration, otherwise nothing (an empty string
    /// keeps the tile's two-line footprint without repeating the author).
    static func tileSubtitle(for item: LibraryItem) -> String {
        if let series = item.seriesName, !series.isEmpty { return series }
        if item.duration > 0 { return item.duration.formattedDuration }
        // Critique 2026-10-05 (Library, 2nd): was "", which VoiceOver read as "Title, , finished"
        // (the tile joins its parts). A non-empty, true fallback instead.
        return String(localized: "Standalone", comment: "Subtitle of a book that does not belong to a series and has no known duration")
    }

    var body: some View {
        PersonBooksPage(kind: .author, name: author.name,
                        filter: APIFilter.encode(group: "authors", value: author.id),
                        tileSubtitle: { AuthorBooksView.tileSubtitle(for: $0) })
    }
}

// MARK: - Author / Narrator page (Critique 2026-10-06, shape → distill)

/// Sort orders for an author's or narrator's books. Client-side over the fetched set.
enum BookDrillDownSort: String, CaseIterable, Identifiable {
    case title, newest, series

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return String(localized: "Title", comment: "Sort option on an author or narrator page")
        case .newest: return String(localized: "Newest", comment: "Sort option on an author or narrator page: newest published first")
        case .series: return String(localized: "Series", comment: "Sort option on an author or narrator page: grouped by series")
        }
    }

    /// Pure, pinned by `DrillDownActionsTests`.
    /// - title: A–Z (Finder-style, so "Book 2" sorts before "Book 10").
    /// - newest: published year, newest first, unknown years last; then most recently added.
    /// - series: series A–Z with standalone books last, sequence order inside each series.
    static func sorted(_ items: [LibraryItem], by sort: BookDrillDownSort) -> [LibraryItem] {
        func titleOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
            let r = a.title.localizedStandardCompare(b.title)
            return r == .orderedSame ? a.id < b.id : r == .orderedAscending
        }
        switch sort {
        case .title:
            return items.sorted(by: titleOrder)
        case .newest:
            return items.sorted { a, b in
                let ya = publishedYear(a), yb = publishedYear(b)
                if ya != yb {
                    guard let ya else { return false }
                    guard let yb else { return true }
                    return ya > yb
                }
                let addedA = a.addedAt ?? 0, addedB = b.addedAt ?? 0
                if addedA != addedB { return addedA > addedB }
                return titleOrder(a, b)
            }
        case .series:
            return items.sorted { a, b in
                let sa = seriesKey(a), sb = seriesKey(b)
                switch (sa, sb) {
                case (nil, nil): return titleOrder(a, b)
                case (_?, nil): return true
                case (nil, _?): return false
                case let (x?, y?):
                    let r = x.localizedStandardCompare(y)
                    if r != .orderedSame { return r == .orderedAscending }
                    let qa = a.sequence(inSeriesNamed: x), qb = b.sequence(inSeriesNamed: x)
                    if qa != qb { return SeriesOrdering.precedes(qa, qb) }
                    return titleOrder(a, b)
                }
            }
        }
    }

    /// The book's series name without a trailing "#3": the structured series entry when
    /// the server sent one, else the display string.
    static func seriesKey(_ item: LibraryItem) -> String? {
        if let name = item.media?.metadata?.series?.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        guard let display = item.seriesName else { return nil }
        let stripped = display
            .replacingOccurrences(of: #"\s*#\s*\d+(\.\d+)?\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    static func publishedYear(_ item: LibraryItem) -> Int? {
        item.media?.metadata?.publishedYear.flatMap { Int($0.prefix(4)) }
    }

    /// "12 books · 3 series" for the page header.
    static func countText(books: [LibraryItem]) -> String {
        let n = books.count
        let base = browseBookCountPhrase(n)
        let seriesCount = Set(books.compactMap { seriesKey($0)?.lowercased() }).count
        guard seriesCount > 0 else { return base }
        return String(localized: "\(base) \u{00B7} \(seriesCount) series", comment: "Author/narrator page header; first %@ is a count phrase like '12 books', %lld is the number of series")
    }
}

/// The shared author / narrator page: a header (name, counts), a monochrome star toggle
/// and a sort menu in the bar, then the grid. Was a bare cover grid with no actions, and
/// starring was swipe-only on the list row.
private struct PersonBooksPage: View {
    enum Kind { case author, narrator }

    let kind: Kind
    let name: String
    let filter: String
    var tileSubtitle: ((LibraryItem) -> String)? = nil

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var favorites = FavoritesStore.shared
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var sort: BookDrillDownSort = .title
    /// Polish pass (J3-3): `books` in `sort` order, recomputed when either changes instead of
    /// sorting inside `body`'s `ForEach` on every pass.
    @State private var sortedBooks: [LibraryItem] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var isStarred: Bool {
        kind == .author ? favorites.isFavoriteAuthor(name) : favorites.isFavoriteNarrator(name)
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading {
                // LS-6 (docs/design-review.md, Round 3): was a centred `LoadingView`
                // spinner — the odd one out next to Library Books' shape-matched
                // skeleton. Same `CassetteTile` grid as Library, but this grid pads
                // `Space.pageH` horizontally and `Space.l` vertically (VD-2) rather
                // than Library's `.horizontal 20 / .top 8`, hence the explicit
                // `padding:` here.
                ScrollView {
                    SkeletonGrid(padding: EdgeInsets(top: Space.l, leading: Space.pageH, bottom: Space.l, trailing: Space.pageH))
                }
                .scrollDisabled(true)
                .accessibilityElement()
                .accessibilityLabel("Loading…")
                .transition(.opacity)
            } else if loadFailed {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load",
                               subtitle: "Check your connection and try again.",
                               actionTitle: "Retry", action: { Task { await load() } })
            } else if books.isEmpty {
                EmptyStateView(icon: "book.closed", title: LocalizedStringResource("No books"),
                               subtitle: .verbatim(kind == .author ? String(localized: "Nothing found for this author") : String(localized: "Nothing found for \(name)", comment: "Empty state; %@ is a narrator\u{2019}s name")))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Typo.heroTitle(Text(name))
                            .foregroundStyle(Color.shelfCream)
                            .lineLimit(2)
                        Typo.figure(Text(BookDrillDownSort.countText(books: books)))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.pageH)
                    .padding(.top, Space.l)
                    .accessibilityElement(children: .combine)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(sortedBooks) { item in
                            BookLink(item) {
                                // Critique 2026-10-05 (Library): on an author's page every tile
                                // used to repeat the author (the screen's own subject). Series
                                // name, else duration, says something new; progress, download and
                                // finished state come through like they do in Library.
                                if let tileSubtitle {
                                    BookGridTile(item: item, subtitle: tileSubtitle(item))
                                } else {
                                    BookGridTile(item: item)
                                }
                            }
                            .buttonStyle(.plain)
                            // UX-1 (docs/design-review.md, Round 3): these grids had no
                            // long-press menu, so starting playback meant opening Book
                            // Detail first.
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
        .shelfAnimation(.easeInOut(duration: 0.25), value: isLoading)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(BookDrillDownSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down") // iPhone Duo (§2)
                }
                .monochromeToolbarItem()
                .accessibilityValue(sort.label)
                .disabled(books.isEmpty)

                // Critique 2026-10-06 (shape): starring was swipe-only on the list row. A
                // monochrome bar toggle, named Star / Starred like the rest of the app.
                Button {
                    Haptics.selection()
                    if kind == .author { favorites.toggleFavoriteAuthor(name) } else { favorites.toggleFavoriteNarrator(name) }
                } label: {
                    Label(BrowseStarredSections.toggleLabel(isStarred: isStarred),
                          systemImage: isStarred ? "star.fill" : "star")
                }
                .monochromeToolbarItem()
                .accessibilityAddTraits(isStarred ? .isSelected : [])
            }
        }
        .systemChromeTint()
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: sort) { _, newSort in sortedBooks = BookDrillDownSort.sorted(books, by: newSort) }
        .reexpandsTabBarOnAppear()
    }

    private func load() async {
        isLoading = books.isEmpty
        loadFailed = false
        if let result = await libraryViewModel.items(filteredBy: filter) {
            books = result
            sortedBooks = BookDrillDownSort.sorted(result, by: sort)
        } else if books.isEmpty {
            loadFailed = true
        }
        isLoading = false
    }
}

// MARK: - Row artwork (ID-3, docs/visual-design-review.md, V5)

/// What an Authors or Narrators row shows in place of the old identical glyph: the server's photo
/// for an author when there is one, otherwise a small mosaic of that person's covers. Narrators
/// have no photos on the server, so they always use the mosaic.
struct BrowseArtwork {
    var photoURL: URL?
    var coverIDs: [String]
    var bookCount: Int?
}

/// Loads `BrowseArtwork` lazily, one row at a time (rows are in a `List`, so only visible rows
/// ask), and remembers it for the life of the screen.
@MainActor
@Observable
final class BrowseArtworkStore {
    private(set) var artwork: [String: BrowseArtwork] = [:]
    private var inFlight: Set<String> = []

    func reset() {
        artwork = [:]
        inFlight = []
    }

    func loadAuthor(_ author: NamedEntity) async {
        let key = "a:\(author.id)"
        guard artwork[key] == nil, inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }
        guard let result = try? await AudiobookshelfAPI.shared.getAuthorArtwork(authorId: author.id) else { return }
        artwork[key] = BrowseArtwork(
            photoURL: result.hasImage ? authorImageURL(authorId: author.id) : nil,
            coverIDs: Array(result.itemIds.prefix(4)),
            bookCount: result.itemIds.count)
    }

    func loadNarrator(_ name: String, using libraryViewModel: LibraryViewModel) async {
        let key = "n:\(name)"
        guard artwork[key] == nil, inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }
        let filter = APIFilter.encode(group: "narrators", value: name)
        guard let items = await libraryViewModel.items(filteredBy: filter, limit: 4, allPages: false) else { return }
        artwork[key] = BrowseArtwork(photoURL: nil, coverIDs: items.map(\.id), bookCount: nil)
    }

    static func authorKey(_ author: NamedEntity) -> String { "a:\(author.id)" }
    static func narratorKey(_ name: String) -> String { "n:\(name)" }
}

/// The 44 pt leading thumbnail for an Authors / Narrators row.
private struct BrowseRowArt: View {
    let artwork: BrowseArtwork?
    let placeholderSymbol: String
    private let side: CGFloat = 44

    var body: some View {
        Group {
            if let url = artwork?.photoURL {
                CachedCover(url: url)
            } else if let ids = artwork?.coverIDs, !ids.isEmpty {
                mosaic(ids)
            } else {
                Rectangle().fill(Color.shelfSurface)
                    .overlay(Image(systemName: placeholderSymbol).foregroundStyle(Color.shelfMuted))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.thumb))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumb).strokeBorder(Color.shelfCream.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// One cover fills the tile; two or more sit in a 2 × 2 grid (empty cells stay surface-coloured).
    @ViewBuilder
    private func mosaic(_ ids: [String]) -> some View {
        if ids.count == 1 {
            CachedCover(url: shelfCoverURL(itemId: ids[0], width: 120))
        } else {
            let cell = side / 2
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { col in
                            let index = row * 2 + col
                            Group {
                                if index < ids.count {
                                    CachedCover(url: shelfCoverURL(itemId: ids[index], width: 80))
                                } else {
                                    Color.shelfSurface
                                }
                            }
                            .frame(width: cell, height: cell)
                            .clipped()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Narrators

struct NarratorsBrowseView: View {
    var search: String = ""
    /// Critique 2026-10-05 (Library): tab re-tap scroll-to-top, as in Books.
    var scrollToTopSignal: Int = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel
    /// See `AuthorsBrowseView`'s identical property for why this is observed here too.
    @State private var favorites = FavoritesStore.shared
    @State private var artworkStore = BrowseArtworkStore()

    /// Polish pass (J3-2): the alphabetical sort of the whole narrator list is cached against
    /// the list it was made from (`.task(id:)` below refreshes it when the server data changes),
    /// so a body pass only filters. Before the first task run it sorts inline.
    @State private var sortedCache: (source: [String], sorted: [String])?

    private static func alphabetical(_ names: [String]) -> [String] {
        names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var narrators: [String] {
        let raw = libraryViewModel.filterData?.narrators ?? []
        let all: [String]
        if let cache = sortedCache, cache.source == raw { all = cache.sorted } else { all = Self.alphabetical(raw) }
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        // LS-6 (docs/design-review.md, Round 3): hoisted so the branch condition and
        // the `.shelfAnimation(value:)` below can't drift apart — mirrors `HomeView`'s
        // AN-3 `showsSkeleton` pattern.
        let showsSkeleton = libraryViewModel.filterData == nil && !libraryViewModel.filterDataLoadFailed
        // Polish pass (J3-2): once per body, not three times.
        let narrators = self.narrators
        let split = Self.split(narrators, favorites: favorites)
        Group {
            // UI-11: the old `filterData == nil` check alone meant a genuine failure
            // left this spinner running forever, since nothing ever told it to stop.
            if libraryViewModel.filterData == nil && libraryViewModel.filterDataLoadFailed {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load",
                               subtitle: "Check your connection and try again.",
                               actionTitle: "Retry", action: { Task { await libraryViewModel.loadFilterData() } })
            } else if showsSkeleton {
                // Was a centred `LoadingView` spinner — the odd one out next to
                // Library Books' shape-matched skeleton. Same row shape as
                // `AuthorsBrowseView` (28pt circular glyph + name + optional star).
                SkeletonList()
                    .accessibilityElement()
                    .accessibilityLabel("Loading narrators…")
                    .transition(.opacity)
            } else if narrators.isEmpty {
                EmptyStateView(
                    icon: search.isEmpty ? "mic" : "magnifyingglass",
                    title: search.isEmpty ? "No narrators" : "No matches",
                    subtitle: search.isEmpty ? "Narrator data will appear once your library is scanned"
                                             : "No narrators match “\(search)”"
                )
            } else {
                List {
                    if !BrowseStarredSections.showsSections(starredCount: split.starred.count) {
                        ForEach(split.rest, id: \.self) { narrator in narratorRow(narrator) }
                    } else {
                        Section {
                            ForEach(split.starred, id: \.self) { narrator in narratorRow(narrator) }
                        } header: { RetroSectionHeader(title: .verbatim(BrowseStarredSections.starredTitle)) }
                        Section {
                            ForEach(split.rest, id: \.self) { narrator in narratorRow(narrator) }
                        } header: { RetroSectionHeader(title: .verbatim(BrowseStarredSections.allTitle(for: .narrators))) }
                    }
                }
                .scrollContentBackground(.hidden)
                .transition(.opacity)
                .scrollsToTop(signal: scrollToTopSignal, firstID: split.displayedFirst)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
        .task(id: libraryViewModel.filterData?.narrators ?? []) {
            let raw = libraryViewModel.filterData?.narrators ?? []
            sortedCache = (raw, Self.alphabetical(raw))
        }
        .task {
            if libraryViewModel.filterData == nil {
                await libraryViewModel.loadFilterData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in artworkStore.reset() }
        .reexpandsTabBarOnAppear()
    }

    @ViewBuilder
    private func narratorRow(_ narrator: String) -> some View {
        let isFavorite = favorites.isFavoriteNarrator(narrator)
        LibraryRouteLink(.narrator(narrator)) {
            HStack(spacing: 12) {
                // Design-direction pass, point 8: same fix as the
                // Authors list's leading icon just above — decorative,
                // identical on every row, not a state; muted now.
                // HIG audit 2026-09-17 H4: decorative, hidden from VoiceOver —
                // the row's composed label below already covers name/favourite.
                // ID-3 (V5): narrators have no photos on the server; a cover mosaic.
                BrowseRowArt(artwork: artworkStore.artwork[BrowseArtworkStore.narratorKey(narrator)],
                             placeholderSymbol: "mic.fill")
                Typo.rowTitle(Text(narrator))
                    .foregroundStyle(Color.shelfCream)
                Spacer()
                if isFavorite {
                    // Same `.symbolEffect(.bounce, value:)` polish as
                    // `AuthorsBrowseView`'s identical star icon above
                    // — see that file's doc comment for the
                    // mount-vs-value-change [device check] caveat.
                    Typo.supporting(Image(systemName: "star.fill")
                        .foregroundStyle(Color.shelfAmberText))
                        .shelfSymbolBounce(value: isFavorite)
                }
            }
            .padding(.vertical, 4)
            // HIG audit 2026-09-17 H4: mirrors CollectionsPlaylistsView's N-4
            // fix — was three unlabelled VoiceOver stops (decorative icon,
            // name, star), never saying "favourite". Composed into one element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rowAccessibilityLabel(name: narrator, isFavorite: isFavorite))
        }
        .listRowBackground(Color.shelfCard)
        .task { await artworkStore.loadNarrator(narrator, using: libraryViewModel) }
        // Critique 2026-10-06 (colorize): was raw `shelfAmber` (white label ≈2:1) and a full
        // swipe, so a one-handed swipe starred by accident. Library's swipe fill and a
        // deliberate tap, as on Library's rows.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Haptics.selection()
                favorites.toggleFavoriteNarrator(narrator)
            } label: {
                Label(isFavorite ? "Unstar" : "Star", systemImage: isFavorite ? "star.slash" : "star.fill")
            }
            .tint(LibrarySwipeTint.amber)
        }
    }

    /// Pure so it can be pinned with a regression test, mirroring
    /// `CollectionsBrowseView.rowAccessibilityLabel`'s established pattern.
    /// Critique 2026-10-06 (colorize): said "Favourite" while the UI says Star / Starred.
    static func rowAccessibilityLabel(name: String, isFavorite: Bool) -> String {
        isFavorite ? String(localized: "\(name), \(BrowseStarredSections.starredTitle)", comment: "VoiceOver label of an author/narrator row that is starred; first %@ is the name, second is the word Starred") : name
    }

    /// Starred narrators first, no repeats in `rest` (library-browse plan §3.3, Q6).
    static func split(_ items: [String], favorites: FavoritesStore) -> BrowseStarredSplit<String> {
        let r = FavoritesStore.starredFirst(items, name: { $0 }, isStarred: { favorites.favoriteNarrators.contains($0) })
        return BrowseStarredSplit(starred: r.starred, rest: r.rest)
    }
}

struct NarratorBooksView: View {
    let narrator: String

    var body: some View {
        PersonBooksPage(kind: .narrator, name: narrator,
                        filter: APIFilter.encode(group: "narrators", value: narrator))
    }
}

/// Books for a single genre — the destination of the tappable genre chips on the
/// book detail screen.
struct GenreBooksView: View {
    let genre: String
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading {
                // LS-6 (docs/design-review.md, Round 3): was a centred `LoadingView`
                // spinner — the odd one out next to Library Books' shape-matched
                // skeleton. See `AuthorBooksView`'s identical fix for why `padding:`
                // is explicit here (this grid pads `Space.pageH` / `Space.l`, VD-2).
                ScrollView {
                    SkeletonGrid(padding: EdgeInsets(top: Space.l, leading: Space.pageH, bottom: Space.l, trailing: Space.pageH))
                }
                .scrollDisabled(true)
                .accessibilityElement()
                .accessibilityLabel("Loading…")
                .transition(.opacity)
            } else if loadFailed {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load",
                               subtitle: "Check your connection and try again.",
                               actionTitle: "Retry", action: { Task { await load() } })
            } else if books.isEmpty {
                EmptyStateView(icon: "book.closed", title: LocalizedStringResource("No books"), subtitle: LocalizedStringResource("Nothing found for \(genre)"))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(books) { item in
                            BookLink(item) {
                                // Critique 2026-10-05 (Library): progress/download/finished state.
                                BookGridTile(item: item)
                            }
                            .buttonStyle(.plain)
                            // UX-1 (docs/design-review.md, Round 3): genre books had no
                            // long-press menu, so starting playback meant opening Book
                            // Detail first.
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
        .shelfAnimation(.easeInOut(duration: 0.25), value: isLoading)
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .reexpandsTabBarOnAppear()
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        let filter = APIFilter.encode(group: "genres", value: genre)
        if let result = await libraryViewModel.items(filteredBy: filter) {
            books = result
        } else {
            loadFailed = true
        }
        isLoading = false
    }
}

extension AuthorsBrowseView {
    /// Starred authors first, no repeats in `rest` (library-browse plan §3.3, Q6).
    static func split(_ items: [NamedEntity], favorites: FavoritesStore) -> BrowseStarredSplit<NamedEntity> {
        let r = FavoritesStore.starredFirst(items, name: { $0.name }, isStarred: { favorites.favoriteAuthors.contains($0) })
        return BrowseStarredSplit(starred: r.starred, rest: r.rest)
    }
}
