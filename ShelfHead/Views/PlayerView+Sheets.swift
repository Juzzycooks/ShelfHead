import SwiftUI

// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
// all four sheets below are verbatim what lived at the bottom of that file. These are the
// modal surfaces the full player presents: the chapter list, bookmarks, the Up Next queue
// and the playback-speed picker.

// MARK: - Chapter List Sheet

struct ChapterListSheet: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    // R1 (REVIEW_2026-09-04_UI.md): drives the initial scroll position; set in .task
    // rather than the old ScrollViewReader + .onAppear, which fired before the
    // LazyVStack's rows existed and silently no-op'd.
    @State private var scrolledChapterId: Int?
    /// Whether the index column beside each title is shown at all (Pass 3 item 1,
    /// REVIEW_2026-09-04_UI.md — see the row for what it's for).
    ///
    /// Item 10 (REVIEW-2026-09-09.md): this used to be a `let` inside the `ScrollView`'s
    /// builder. Computed once per *render* is not the same as computed once per chapter
    /// list, and this sheet re-renders on every playback tick (the current-chapter
    /// highlight has to move) — so `titlesAreSelfNumbered`, which trims and lowercases
    /// every title in the book, was re-scanning an 80+ entry list twice a second for an
    /// answer that can only change when the book does. `@State` set from the `.task`
    /// below is that same answer, computed when the list it describes actually changes.
    /// Defaults to true so the first frame matches an unnumbered book (the common case);
    /// the `.task` corrects it before the sheet has finished presenting.
    @State private var showsIndex = true

    /// Item 11 (REVIEW-2026-09-09-REMAINING.md): how many of this book's chapters the
    /// server sent in a shape the client couldn't use, and which were therefore dropped
    /// during decoding rather than failing the whole book/session.
    ///
    /// Resolved the same way `PlayerViewModel.chapters` resolves the list itself — the
    /// live session's own count while a session exists, the current book's otherwise —
    /// so the note always describes the list actually being shown. Read straight off
    /// `AudioPlayerService.shared` because the view model's `playerService` is private;
    /// this sheet already re-renders on every playback tick, so the extra observed read
    /// costs nothing it wasn't already paying.
    /// Batch 427 (Section E): the loaded book as the chapter suggester sees it, with whether
    /// to offer it and whether chapters made on this device are in effect. Set from `.task`
    /// (it reads the manifest and transcript meta) whenever the chapter list changes.
    @State private var suggestionContext: ChapterSuggestionContext?
    @State private var suggestionOffered = false
    @State private var overrideApplied = false
    @State private var confirmReset = false

    private var droppedChapterCount: Int {
        if let session = AudioPlayerService.shared.currentSession {
            return session.droppedChapterCount
        }
        return playerViewModel.currentBook?.droppedChapterCount ?? 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()

                // S2 (REVIEW_2026-09-04_UI.md): a book with no chapter markers otherwise
                // rendered a blank sheet — an empty LazyVStack inside an empty ScrollView.
                if playerViewModel.chapters.isEmpty {
                    // Item 11: when every chapter was dropped by the tolerant decode,
                    // say so in place of the usual "no chapter markers" line — the book
                    // does have chapters, they just couldn't be read.
                    VStack(spacing: 0) {
                        EmptyStateView(
                            icon: "list.bullet",
                            title: LocalizedStringResource("No chapters"),
                            subtitle: Chapter.droppedChapterNote(count: droppedChapterCount).map(LocalizedStringResource.verbatim)
                                ?? LocalizedStringResource("This book doesn't include chapter markers.", comment: "Empty state in the chapter list for a book with no chapters")
                        )
                        suggestionFooter
                            .padding(.bottom, Space.l)
                    }
                } else {
                ScrollView {
                    // Item 10 (REVIEW-2026-09-09.md): resolved once for the whole list
                    // instead of once per row. `isCurrentChapter(chapter)` was called
                    // three times inside every row's body (icon, title colour, row
                    // tint), and each call re-resolved the current chapter from the
                    // player — so a 90-chapter book paid ~270 resolutions per tick to
                    // decide one highlighted row. One `Int?` compared per row does the
                    // same job. (`PlayerViewModel` now memoises the resolution itself,
                    // which is the other half of the same fix.)
                    let currentChapterId = playerViewModel.currentChapter?.id

                    LazyVStack(spacing: 0) {
                        ForEach(Array(playerViewModel.chapters.enumerated()), id: \.element.id) { position, chapter in
                            let isCurrent = chapter.id == currentChapterId
                            Button {
                                // S8 (REVIEW_2026-09-04_UI.md)
                                Haptics.selection()
                                playerViewModel.seekToChapter(chapter)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    if isCurrent {
                                        Typo.supporting(Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(Color.shelfAmberText))
                                            .frame(width: 20)
                                    } else if showsIndex {
                                        // Pass 3 item 1 (REVIEW_2026-09-04_UI.md): the
                                        // index column beside a self-numbered title read
                                        // "65  63. Something Incredibly Questionable" —
                                        // the array index and the author's numbering
                                        // arguing a column apart, the same contradiction
                                        // G3 removed from the full player's chapter
                                        // caption. The row carries no explicit
                                        // accessibility label — VoiceOver composes one
                                        // from the children — so dropping the Text drops
                                        // the index from the spoken row too, which keeps
                                        // the two readings in step without a second code
                                        // path.
                                        Typo.fine(Text("\(position + 1)"), weight: .medium)
                                            .foregroundStyle(Color.shelfMuted)
                                            .frame(width: 20)
                                    } else {
                                        // Hold the gutter open so titles still line up
                                        // with the now-playing row's speaker icon, and
                                        // the divider's 48pt leading inset still lands
                                        // under the title rather than beside it.
                                        Color.clear.frame(width: 20, height: 1)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        // Same chapter name as the caption, bookmarks and
                                        // Jump back (critique 2026-10-05, third run).
                                        Typo.rowTitle(Text(PlayerView.displayChapterTitle(chapter.title)))
                                            .foregroundStyle(isCurrent ? Color.shelfAmberText : Color.shelfCream)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)

                                        Typo.fine(Text((chapter.end - chapter.start).formattedDuration))
                                            .foregroundStyle(Color.shelfMuted)
                                    }

                                    Spacer()

                                    Typo.figure(Text(chapter.start.formattedTime))
                                        .foregroundStyle(Color.shelfMuted)
                                }
                                .padding(.vertical, 12)
                                // P-6: `Space.l` is 16 — same value, named role.
                                .padding(.horizontal, Space.l)
                                .background(isCurrent ? Color.shelfAmber.opacity(0.06) : Color.clear)
                            }
                            .id(chapter.id)
                            // Critique 2026-10-06 (harden): the current row was marked only by
                            // an unlabelled speaker glyph; VoiceOver now hears it as selected.
                            .accessibilityLabel(isCurrent
                                ? String(localized: "Now playing, \(PlayerView.displayChapterTitle(chapter.title))", comment: "VoiceOver label for the current row in the chapter list. %@ is the chapter title")
                                : PlayerView.displayChapterTitle(chapter.title))
                            .accessibilityValue((chapter.end - chapter.start).formattedDuration)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])

                            Divider()
                                .background(Color.shelfSurface)
                                .padding(.leading, 48)
                        }
                    }
                    // S6 (REVIEW_2026-09-04_UI.md): style the flat scroll list as one
                    // inset card, matching the List-based Bookmarks/Up Next surfaces,
                    // instead of rows sitting directly on shelfBackground. clipShape
                    // after the background keeps the current-chapter row tint from
                    // spilling past the card's rounded corners.
                    .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    // P-6: `Space.l` is 16 — same value, named role.
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, 12)
                    .scrollTargetLayout()

                    // Item 11: one quiet caption under the list when some of the book's
                    // chapters couldn't be read from the server, in the same
                    // `.caption2` + `shelfMuted` styling the rows' own secondary text
                    // uses. Outside `.scrollTargetLayout()` so it never becomes a scroll
                    // target for `.scrollPosition(id:)`.
                    if let note = Chapter.droppedChapterNote(count: droppedChapterCount) {
                        Typo.fine(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // P-6: `Space.xl` is 20 — same value, named role. (The card
                            // above insets by 16 and its rows by another 16; this caption
                            // sits outside the card and deliberately splits the
                            // difference, so it is not `Space.l`.)
                            .padding(.horizontal, Space.xl)
                            .padding(.bottom, 16)
                    }

                    suggestionFooter
                        .padding(.bottom, Space.l)
                }
                .scrollPosition(id: $scrolledChapterId, anchor: .top)
                // R1 (REVIEW_2026-09-04_UI.md): .task runs after the first layout
                // pass, unlike .onAppear, which fired before the LazyVStack's rows
                // existed and made `proxy.scrollTo` a silent no-op.
                //
                // Anchor is `.top`, not `.center`, on purpose: the position is
                // resolved while the sheet is still sizing, against a frame taller
                // than the `.medium` detent it settles at. Rendered on the simulator,
                // `.center` left the current chapter just *above* the visible list;
                // `.top` lands it a few rows down with the previous chapters above
                // and the next ones below, which is the layout we want anyway.
                //
                // Item 10 (REVIEW-2026-09-09.md): keyed on the chapter list (via
                // `PlayerViewModel.ChapterListSignature`, an O(1) Equatable stand-in for
                // the array itself) so `showsIndex` is recomputed if the list is ever
                // swapped underneath an open sheet — an auto-advance into the next book
                // — rather than only on first appearance. On first appearance this runs
                // exactly when the un-keyed version did.
                .task(id: PlayerViewModel.ChapterListSignature(playerViewModel.chapters)) {
                    showsIndex = !Chapter.titlesAreSelfNumbered(playerViewModel.chapters.map(\.title))
                    scrolledChapterId = playerViewModel.currentChapter?.id
                }
                }
            }
            .task(id: PlayerViewModel.ChapterListSignature(playerViewModel.chapters)) {
                refreshSuggestionState()
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }   // LG-3
                        .monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
    }

    // MARK: Chapters made on this device (Batch 427, Section E)

    private func refreshSuggestionState() {
        guard let context = ChapterSuggestionContext.make(playerViewModel: playerViewModel) else {
            suggestionContext = nil; suggestionOffered = false; overrideApplied = false
            return
        }
        suggestionContext = context
        suggestionOffered = context.isOffered
        overrideApplied = ChapterOverrideStore.isApplied(itemId: context.itemId, server: context.serverChapters)
    }

    /// Under the list (and in the empty state): "Suggest Chapters…" for a book whose chapters
    /// are missing or useless, or, once chapters made on this iPhone are in effect, a note
    /// with a way back to the book's own.
    @ViewBuilder
    private var suggestionFooter: some View {
        if let context = suggestionContext {
            if overrideApplied {
                VStack(alignment: .leading, spacing: 8) {
                    Typo.supporting(Text("Chapters made on this iPhone"))
                        .foregroundStyle(Color.shelfMuted)
                    if suggestionOffered {
                        NavigationLink {
                            ChapterSuggestionsView(context: context)
                        } label: {
                            Label("Suggest Again…", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .tint(Color.shelfAmberText)
                    }
                    Button {
                        confirmReset = true
                    } label: {
                        Text("Use the Book's Chapters")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .tint(Color.shelfAmberText)
                }
                .padding(.horizontal, Space.xl)
                .confirmationDialog("Use the book's own chapters?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Use the Book's Chapters", role: .destructive) {
                        Haptics.selection()
                        ChapterOverrideStore.delete(itemId: context.itemId)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The chapters made on this iPhone will be removed.")
                }
            } else if suggestionOffered {
                NavigationLink {
                    ChapterSuggestionsView(context: context)
                } label: {
                    Label("Suggest Chapters…", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.shelfAmberText)
                .padding(.horizontal, Space.xl)
                .accessibilityHint("Finds chapter breaks from pauses and spoken chapter titles. Saved on this iPhone only.")
            }
        }
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksSheet: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false
    @State private var showNotePrompt = false
    @State private var noteText = ""
    // S3 (REVIEW_2026-09-04_UI.md): the moment being bookmarked, captured when the
    // button is tapped rather than re-read live when Save fires — otherwise a slow
    // typist ends up bookmarking wherever playback drifted to while they typed.
    @State private var pendingBookmarkTime: Double = 0
    // S5 (REVIEW_2026-09-04_UI.md): the bookmark currently being renamed from this
    // sheet's context menu / swipe action.
    @State private var editingBookmark: AudioBookmark?
    @State private var editNoteText = ""
    // Local free-text note (not the server `title`), edited alongside it below.
    @State private var editNoteBody = ""
    @State private var notesStore = BookmarkNotesStore.shared
    @State private var exportPayload: SharePayload?
    // Critique 2026-10-06 (harden): delete used to be immediate and final here (context menu
    // and a full-swipe `.onDelete`). Same Undo as Book Detail's sheet and All Bookmarks.
    @State private var bookmarkUndo = BookmarkDeleteUndo()
    // Critique 2026-10-06 (harden): Edit Bookmark's Save waits for the result; a failure
    // keeps the sheet open with this message.
    @State private var editSaveError: String?
    @State private var isSavingEdit = false
    // Y2 (REVIEW_2026-09-04_UI.md): lets the presenter turn a bookmark's note into a
    // Quote share card; nil (the default) means the presenter doesn't support it, so
    // existing callers of `BookmarksSheet()` keep working with no behaviour change.
    var onShareNote: ((AudioBookmark) -> Void)? = nil

    // R9 (REVIEW_2026-09-04_UI.md): the button behind this sheet shows chapter-relative
    // time once chapter data exists (pass 1 made the scrubber chapter-relative) — this
    // label keeps the sheet from disagreeing with that by showing whole-book time.
    /// Critique 2026-10-06 (clarify): the Add Bookmark field. Its text is saved as the
    /// bookmark's server title, so it is labelled as one (it said "Note (optional)", then Edit
    /// Bookmark showed it under "Title" beside a separate local Note).
    static var addFieldPlaceholder: String { String(localized: "Title (optional)", comment: "Placeholder in the Add Bookmark text field") }

    static func momentLabel(time: Double, chapter: Chapter?) -> String {
        if let chapter {
            return String(localized: "\(momentTime(time: time, chapter: chapter)) · \(PlayerView.displayChapterTitle(chapter.title))",
                          comment: "A bookmark moment. First %@ is the time within the chapter, second the chapter title")
        }
        return time.formattedTime
    }

    /// Just the time half of `momentLabel` — chapter-relative when a chapter exists.
    static func momentTime(time: Double, chapter: Chapter?) -> String {
        if let chapter { return (time - chapter.start).formattedTime }
        return time.formattedTime
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Button {
                        noteText = ""
                        pendingBookmarkTime = playerViewModel.currentTime // S3 (REVIEW_2026-09-04_UI.md)
                        showNotePrompt = true
                    } label: {
                        HStack {
                            Image(systemName: "bookmark.fill")
                            // R9 (REVIEW_2026-09-04_UI.md): chapter-relative time to match the
                            // scrubber behind the sheet; the chapter title goes on its own line
                            // (rendered on one line it truncated to "63...." — render 102).
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bookmark this moment · \(Self.momentTime(time: playerViewModel.currentTime, chapter: playerViewModel.currentChapter))")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                if let chapter = playerViewModel.currentChapter {
                                    // Critique 2026-10-06 (clarify): "002" reads "Chapter 2", as in
                                    // the chapter list and the rows below.
                                    Typo.supporting(Text(PlayerView.displayChapterTitle(chapter.title)))
                                        .opacity(0.85)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            if isAdding { Spacer(); ProgressView().tint(Color.onAccent) }
                        }
                        .shelfButtonStyle()
                    }
                    .disabled(isAdding)
                    .padding(16)

                    // LS-9 (docs/design-review.md): a bookmarks list that's still empty
                    // because the fetch hasn't landed yet isn't the same thing as a
                    // confirmed "no bookmarks" — showing the empty state for that gap,
                    // even briefly, reads as "your saved moments are gone". A refresh
                    // (bookmarks already present) keeps showing the list rather than
                    // blanking it while it re-fetches.
                    if !playerViewModel.bookmarks.isEmpty {
                        List {
                            ForEach(playerViewModel.bookmarks) { bookmark in
                                Button {
                                    // S8 (REVIEW_2026-09-04_UI.md)
                                    Haptics.selection()
                                    playerViewModel.seekToBookmark(bookmark)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Typo.supporting(Image(systemName: "bookmark.fill")
                                            .foregroundStyle(Color.shelfAmberText))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Typo.rowTitle(Text(bookmark.title))
                                                .foregroundStyle(Color.shelfCream)
                                                .lineLimit(1)
                                            if let note = notesStore.note(for: bookmark), !note.isEmpty {
                                                Typo.supporting(Text(note))
                                                    .foregroundStyle(Color.shelfMuted)
                                                    .lineLimit(2)
                                            }
                                            // Critique 2026-10-06 (clarify): chapter-relative time and chapter name, the
                                            // same `momentLabel` the add button uses; rows showed whole-book time.
                                            Typo.figure(Text(Self.momentLabel(time: bookmark.time, chapter: playerViewModel.chapters.last(where: { $0.start <= bookmark.time }))))
                                                .lineLimit(1)
                                                .foregroundStyle(Color.shelfMuted)
                                        }
                                        Spacer()
                                    }
                                }
                                .listRowBackground(Color.shelfCard)
                                // S5 (REVIEW_2026-09-04_UI.md): renaming a bookmark's note
                                // was only reachable from Book Detail — mirror it here.
                                .contextMenu {
                                    Button {
                                        editingBookmark = bookmark
                                        editNoteText = bookmark.title
                                        editNoteBody = notesStore.note(for: bookmark) ?? ""
                                    } label: { Label(BookDetailView.editBookmarkTitle, systemImage: "pencil") }
                                    // Y2 (REVIEW_2026-09-04_UI.md): only offer this when there's
                                    // an actual note to quote and a presenter wired up for it.
                                    if !bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       let onShareNote {
                                        Button {
                                            onShareNote(bookmark)
                                        } label: { Label("Share as Card", systemImage: "square.and.arrow.up") }
                                    }
                                    Button(role: .destructive) {
                                        deleteBookmark(bookmark)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                // Critique 2026-10-06 (harden): was `.onDelete`, whose full swipe
                                // deleted with no way back. An explicit action, no full swipe.
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteBookmark(bookmark)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                // Critique 2026-10-06 (clarify, colorize): the same name as the
                                // long-press menu, and the accent darkened so the system's white
                                // label clears AA (raw amber was ≈2.2:1), as Library's swipes do.
                                .swipeActions(edge: .leading) {
                                    Button {
                                        editingBookmark = bookmark
                                        editNoteText = bookmark.title
                                        editNoteBody = notesStore.note(for: bookmark) ?? ""
                                    } label: { Label(BookDetailView.editBookmarkTitle, systemImage: "pencil") }
                                    .tint(LibrarySwipeTint.amber)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                    } else if playerViewModel.isLoadingBookmarks {
                        // Delayed so a fast server's round trip doesn't flash a spinner
                        // (same reveal timing as LS-12's `DelayedProgressView` sites).
                        DelayedProgressView(delay: .milliseconds(250)) {
                            LoadingView("Loading bookmarks…")
                        } placeholder: {
                            Color.clear
                        }
                    } else if playerViewModel.bookmarksLoadFailed {
                        // Polish pass (CR-2): a failed fetch is not "No bookmarks".
                        EmptyStateView(icon: "bookmark", title: LocalizedStringResource("Couldn’t load bookmarks"),
                                       subtitle: LocalizedStringResource("Check your connection and try again."),
                                       actionTitle: LocalizedStringResource("Retry")) {
                            Task { await playerViewModel.loadBookmarks() }
                        }
                    } else {
                        EmptyStateView(icon: "bookmark", title: LocalizedStringResource("No bookmarks"), subtitle: LocalizedStringResource("Saved moments will appear here"))
                    }
                }
            }
            // Critique 2026-10-06 (harden): the sheet hosts its own Undo toast, so it shows
            // above the sheet rather than behind it on the player.
            .bookmarkUndoToast(bookmarkUndo) { await playerViewModel.loadBookmarks() }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        exportMarkdown()
                    } label: { Label("Export bookmarks", systemImage: "square.and.arrow.up") }   // iPhone Duo (§2): titled item
                        .monochromeToolbarItem()
                        // LS-9: nothing to export while the list is still loading either.
                        .disabled(playerViewModel.bookmarks.isEmpty || playerViewModel.isLoadingBookmarks)
                }
                .shelfVisibilityPriority(.low)
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }.monochromeToolbarItem()   // LG-3
                }
                .shelfVisibilityPriority(.high)
            }
            // S1 (REVIEW_2026-09-04_UI.md): keyed on the book id so a book change while
            // the sheet is open (auto-advance, Up Next) refetches instead of leaving
            // the previous book's bookmarks on screen.
            .task(id: playerViewModel.currentBook?.id) { await playerViewModel.loadBookmarks() }
            .sheet(item: $exportPayload) { payload in ActivityView(items: [payload.url]) }
            // CO-7 pilot (Batch 353): amber stays on the sheet's own controls (context-menu
            // glyphs, the loading spinner) via the inner tint; the alert's Save and Cancel
            // take the outer neutral tint. See `systemChromeTint()`.
            .tint(Color.shelfAmberText)
            .alert("Add Bookmark", isPresented: $showNotePrompt) {
                // Critique 2026-10-06 (clarify): this text is saved as the bookmark's title (Edit
                // Bookmark shows it under "Title", beside a separate local Note), so say so.
                TextField(BookmarksSheet.addFieldPlaceholder, text: $noteText)
                Button("Save") {
                    isAdding = true
                    Task {
                        // S3 (REVIEW_2026-09-04_UI.md): use the time captured when the
                        // button was tapped, not whatever `currentTime` drifted to while
                        // the note prompt was open.
                        // Critique 2026-10-06 (harden): the haptic fired whatever happened;
                        // now only when the save actually returned (nil = no current book),
                        // like the long-press path.
                        if await playerViewModel.addBookmark(at: pendingBookmarkTime, note: noteText) != nil {
                            Haptics.success()
                        }
                        noteText = ""
                        isAdding = false
                    }
                }
                Button("Cancel", role: .cancel) { noteText = "" }
            } message: {
                // R9 (REVIEW_2026-09-04_UI.md): same chapter-relative form as the button.
                Text("Bookmarking \(Self.momentLabel(time: pendingBookmarkTime, chapter: playerViewModel.currentChapter))")
            }
            .systemChromeTint()
            // S5 (REVIEW_2026-09-04_UI.md), extended to a two-field sheet: an alert can't
            // comfortably hold both the server title and a longer local note.
            .sheet(item: $editingBookmark) { bookmark in
                NavigationStack {
                    Form {
                        Section("Title") {
                            TextField("Title", text: $editNoteText)
                        }
                        Section("Note") {
                            TextEditor(text: $editNoteBody)
                                .frame(minHeight: 100)
                        }
                        if let editSaveError {
                            Section {
                                Label {
                                    Typo.supporting(Text(editSaveError))
                                        .foregroundStyle(Color.shelfCream)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.shelfOrange)
                                }
                            }
                        }
                    }
                    .navigationTitle("Edit Bookmark")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetCancelButton { editingBookmark = nil }.monochromeToolbarItem()   // iPhone Duo (§2)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            SheetConfirmButton(title: "Save") { saveEdit(bookmark) }
                                .disabled(isSavingEdit)
                        }
                        .shelfVisibilityPriority(.high)
                    }
                }
                .onDisappear { editSaveError = nil; isSavingEdit = false }
            }
        }
    }

    private func deleteBookmark(_ bookmark: AudioBookmark) {
        bookmarkUndo.delete(bookmark) { await playerViewModel.loadBookmarks() }
    }

    /// Critique 2026-10-06 (harden): the sheet used to close before the save returned, and
    /// buzzed success whatever happened. Now it waits: a synced or queued save (the view
    /// model posts its own "will sync" message for a queued one) keeps the local note,
    /// buzzes and closes; a failed one stays open and says so.
    private func saveEdit(_ bookmark: AudioBookmark) {
        let title = editNoteText
        let noteBody = editNoteBody
        isSavingEdit = true
        editSaveError = nil
        Task {
            let result = await playerViewModel.updateBookmark(bookmark, note: title)
            isSavingEdit = false
            if BookmarkEditFeedback.shouldClose(after: result) {
                notesStore.setNote(noteBody, for: bookmark)
                Haptics.success()
                editingBookmark = nil
            } else {
                Haptics.impact(.heavy)
                editSaveError = BookmarkEditFeedback.failureMessage
                // Critique 2026-10-06 (polish): the message appears below the editor, out
                // of VoiceOver focus (the Save button keeps it), so it's announced too.
                AccessibilityNotification.Announcement(BookmarkEditFeedback.failureMessage).post()
            }
        }
    }

    private func exportMarkdown() {
        let notes = notesStore.notes(forItemId: playerViewModel.currentBook?.id ?? "")
        let markdown = BookmarkMarkdownExporter.markdown(
            bookTitle: playerViewModel.currentBook?.title ?? "Bookmarks",
            author: playerViewModel.currentBook?.authorName,
            chapters: playerViewModel.chapters,
            bookmarks: playerViewModel.bookmarks,
            notes: notes)
        guard let url = BookmarkMarkdownExporter.writeExportFile(
            markdown: markdown,
            filenameStem: playerViewModel.currentBook?.title ?? "bookmarks") else { return }
        exportPayload = SharePayload(url: url)
    }
}

// MARK: - Up Next Queue Sheet

struct QueueSheet: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    /// Presented from a queue row's "View Book Details" action — the queue itself only
    /// ever showed cover/title/author before, with no way to check a book's description,
    /// duration, or series context before deciding whether to keep it queued.
    @State private var detailItem: LibraryItem?
    // S4 (REVIEW_2026-09-04_UI.md): "Clear" used to wipe the whole queue with no
    // confirmation — a single mistap could lose every queued book.
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()

                if playerViewModel.upNext.isEmpty {
                    EmptyStateView(icon: "text.line.first.and.arrowtriangle.forward",
                                   title: LocalizedStringResource("Nothing queued"),
                                   subtitle: LocalizedStringResource("Open another book, tap More options, then choose Up Next to line it up."))
                } else {
                    List {
                        ForEach(playerViewModel.upNext) { item in
                            Button {
                                Haptics.selection()
                                playerViewModel.playFromQueue(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImageView(itemId: item.id, width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Typo.rowTitle(Text(item.title))
                                            .foregroundStyle(Color.shelfCream).lineLimit(2)
                                        Typo.rowSubtitle(Text(item.authorName))
                                            .foregroundStyle(Color.shelfMuted).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(Color.shelfMuted)
                                }
                            }
                            .listRowBackground(Color.shelfCard)
                            // View details without leaving the queue, and jump an item to
                            // the front without dragging it there row-by-row.
                            .contextMenu {
                                Button {
                                    Haptics.selection()
                                    detailItem = item
                                } label: {
                                    Label("View Book Details", systemImage: "info.circle")
                                }
                                if playerViewModel.upNext.first?.id != item.id {
                                    Button {
                                        Haptics.selection()
                                        playerViewModel.playNext(item)
                                    } label: {
                                        Label("Move to Top", systemImage: "arrow.up.to.line")
                                    }
                                }
                                Button(role: .destructive) {
                                    playerViewModel.removeFromQueueWithUndo(item)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            // Critique 2026-10-06 (harden): was `.onDelete`, whose full swipe
                            // removed a queued book with no way back. An explicit action, no
                            // full swipe, and an Undo toast (below), like the bookmark rows.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    playerViewModel.removeFromQueueWithUndo(item)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { from, to in
                            playerViewModel.moveInQueue(from: from, to: to)   // persists the new order
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .sheet(item: $detailItem) { item in
                // UI-10: the queue's "View Book Details" — same sheet-vs-overlay
                // mismatch as `showBookDetails` above.
                NavigationStack { BookDetailView(item: item, isPresentedModally: true) }
            }
            // Critique 2026-10-06 (harden): hosted in the sheet so it shows above it; 6 s, and
            // it persists under VoiceOver (`toast(action:)`).
            .toast(message: Binding(get: { playerViewModel.queueRemovalUndoMessage },
                                    set: { playerViewModel.queueRemovalUndoMessage = $0 }),
                   style: .info, duration: 6,
                   action: ToastAction(label: "Undo") { playerViewModel.undoQueueRemoval() })
            // The offer belongs to this sheet; don't bring it back on the next open.
            .onDisappear { playerViewModel.queueRemovalUndoMessage = nil }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !playerViewModel.upNext.isEmpty {
                        // iPhone Duo (§2): symbol so the item isn't text-only
                        Button { showClearConfirmation = true } label: { Label("Clear", systemImage: "trash") } // S4 (REVIEW_2026-09-04_UI.md)
                            .foregroundStyle(Color.shelfMuted)
                    }
                }
                .shelfVisibilityPriority(.low)
                // LG-3 (Round V2): Edit and Close are separate items. In one
                // `ToolbarItemGroup` the two text buttons rendered as a single glass
                // capsule reading "Edit Done" (HIG Toolbars: keep text-labelled actions
                // separate).
                ToolbarItem(placement: .topBarTrailing) {
                    if playerViewModel.upNext.count > 1 {
                        EditButton().monochromeToolbarItem()   // drag to reorder
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }.monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)
            }
            // S4 (REVIEW_2026-09-04_UI.md): confirm before wiping the whole queue —
            // the per-item swipe/context "Remove" above is untouched.
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .confirmationDialog("Clear Up Next?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button(Self.clearQueueButtonTitle(count: playerViewModel.upNext.count), role: .destructive) {
                    playerViewModel.clearQueue()
                }
            } message: {
                Text("Removes every queued book. Your listening progress isn't affected.")
            }
            .systemChromeTint()
        }
    }

    /// S4 (REVIEW_2026-09-04_UI.md): pure so it's testable without a live queue.
    static func clearQueueButtonTitle(count: Int) -> String {
        count == 1 ? String(localized: "Clear 1 Book", comment: "Destructive button in the Clear Up Next confirmation, one book queued")
                   : String(localized: "Clear \(count) Books", comment: "Destructive button in the Clear Up Next confirmation. %lld is the number of queued books (not 1)")
    }
}

// MARK: - Chapter Skip Sheet (per-book override of the timed chapter skip)

/// Per-book override for Settings > Playback > Skip at Chapter Start / End. "Use default"
/// removes the override; turning it off seeds the override with the current default so
/// nothing changes until a picker is touched. Every change is written immediately.
struct ChapterSkipSheet: View {
    let itemId: String
    var bookTitle: String?

    @Environment(\.dismiss) private var dismiss
    @State private var useDefault: Bool
    @State private var start: Int
    @State private var end: Int

    private var defaults: ChapterSkip { SettingsStore.defaultChapterSkip }

    init(itemId: String, bookTitle: String? = nil) {
        self.itemId = itemId
        self.bookTitle = bookTitle
        let override = SettingsStore.chapterSkipOverride(forItem: itemId)
        let seed = override ?? SettingsStore.defaultChapterSkip
        _useDefault = State(initialValue: override == nil)
        _start = State(initialValue: seed.start)
        _end = State(initialValue: seed.end)
    }

    /// Writes happen in the bindings' setters (user changes only), so opening the sheet
    /// never re-writes the override or plays a haptic.
    private func write() {
        SettingsStore.setChapterSkipOverride(useDefault ? nil : ChapterSkip(start: start, end: end), forItem: itemId)
    }

    private func binding<V: Equatable>(_ value: Binding<V>, then: @escaping () -> Void = {}) -> Binding<V> {
        Binding(get: { value.wrappedValue }, set: { newValue in
            guard newValue != value.wrappedValue else { return }
            Haptics.selection()
            value.wrappedValue = newValue
            then()
            write()
        })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                Form {
                    Section {
                        Toggle("Use default", isOn: binding($useDefault) {
                            if !useDefault { start = defaults.start; end = defaults.end }
                        })
                        Typo.supporting(Text("Default: start \(ChapterSkip.label(defaults.start)) \u{00B7} end \(ChapterSkip.label(defaults.end))"))
                            .foregroundStyle(Color.shelfMuted)
                    } footer: {
                        if let bookTitle, !bookTitle.isEmpty {
                            Text(bookTitle)
                        }
                    }
                    .listRowBackground(Color.shelfCard)

                    if !useDefault {
                        Section {
                            Picker("Chapter start", selection: binding($start)) {
                                ForEach(ChapterSkip.options, id: \.self) { Text(ChapterSkip.label($0)).tag($0) }
                            }
                            Picker("Chapter end", selection: binding($end)) {
                                ForEach(ChapterSkip.options, id: \.self) { Text(ChapterSkip.label($0)).tag($0) }
                            }
                        }
                        .listRowBackground(Color.shelfCard)
                    }

                    Section {
                    } footer: {
                        Text("Applies to this book only \u{00B7} deliberate seeks never skip")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Chapter Skip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }.monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
    }
}

// MARK: - Playback Speed Sheet (presets + fine adjust)

struct SpeedSheet: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    // S7 (REVIEW_2026-09-04_UI.md): the 40pt readout was fixed-size and, at AX3,
    // rendered smaller than the "Playback Speed" `.headline` title above it.
    @ScaledMetric(relativeTo: .largeTitle) private var speedReadoutMetric: CGFloat = 40
    // Critique 2026-10-06 (harden): capped at 1.4x like the transport row so the readout
    // can't outgrow the sheet at AX5.
    private var speedReadoutSize: CGFloat { PlayerView.cappedTransportMetric(speedReadoutMetric, base: 40) }
    // VD-7 (docs/design-review.md, Round 4): the −/+ stepper glyphs flank the
    // scaled speed readout above in the same "fine adjust" row, so they fell out
    // of proportion with it at larger text sizes. Capped at 1.4× base (the same
    // ratio `PlayerView.cappedTransportMetric` uses for the transport row's own
    // glyphs) so the glyph stays inside the 48×48 circle rather than crowding
    // its edge.
    @ScaledMetric(relativeTo: .largeTitle) private var stepperIconSizeMetric: CGFloat = 18
    private var stepperIconSize: CGFloat { min(stepperIconSizeMetric, 18 * 1.4) }

    /// Quick presets, most-used first.
    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var rate: Double { Double(playerViewModel.playbackRate) }

    // Batch 437: speed by target words per minute.
    @State private var wpmMode = SettingsStore.speedModeIsWPM
    @State private var targetWPM = SettingsStore.targetWPM
    private var narratorPace: Double? { playerViewModel.currentNarratorPace }

    private func applyWPM() {
        guard let pace = narratorPace else { return }
        playerViewModel.setPlaybackRate(NarratorPace.rate(targetWPM: Double(targetWPM), paceWPM: pace))
    }

    /// Mode picker plus, in WPM mode, the target stepper and the "reads at N wpm" line.
    /// A multiplier picked by hand wins: leave WPM mode so the next book doesn't overwrite it.
    private func leaveWPMMode() {
        guard wpmMode else { return }
        wpmMode = false
        SettingsStore.speedModeIsWPM = false
    }

    @ViewBuilder private var wpmSection: some View {
        VStack(spacing: 10) {
            if let pace = narratorPace {
                Picker("Speed mode", selection: Binding(
                    get: { wpmMode },
                    set: { wpmMode = $0; SettingsStore.speedModeIsWPM = $0; if $0 { applyWPM() } }
                )) {
                    Text(verbatim: "×").tag(false)
                    Text("WPM").tag(true)
                }
                .pickerStyle(.segmented)
                if wpmMode {
                    Stepper(value: Binding(
                        get: { targetWPM },
                        set: { targetWPM = $0; SettingsStore.targetWPM = $0; applyWPM() }
                    ), in: NarratorPace.targetRange, step: NarratorPace.targetStep) {
                        Text("Target \(targetWPM) wpm").font(.subheadline.weight(.semibold))
                    }
                    let resulting = NarratorPace.rate(targetWPM: Double(targetWPM), paceWPM: pace)
                    Typo.supporting(Text("Narrator reads at \(Int(pace.rounded())) wpm → \(label(resulting))"))
                        .foregroundStyle(Color.shelfMuted)
                }
            } else {
                Typo.supporting(Text("Transcribe this book to set speed by words per minute."))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .padding(.horizontal, Space.xl)
    }

    /// Cleanup pass (Batch N-5 redundancy close-out): was its own formatting body,
    /// identical to `PlayerView.bottomToolbar`'s `speedLabel` — both now share
    /// `PlayerView.speedLabel(_:)` in `PlayerView+Formatting.swift`.
    private func label(_ value: Double) -> String {
        PlayerView.speedLabel(value)
    }

    var body: some View {
        // Critique 2026-10-06 (harden): the one sheet here without a NavigationStack,
        // title or Close button (Cancel/Close was drag-only); same chrome as the others.
        NavigationStack {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()

            // Code review fix (26 August 2026): this content had no scroll container
            // and a fixed `.presentationDetents([.height(340)])` (applied where this
            // sheet is presented, in `PlayerView+BottomRegion.swift`) — at default
            // Dynamic Type it fits with room to spare, but the header, the 40pt rate
            // readout, and the closing caption are all unclamped (only the preset grid
            // is, at `.accessibility1`), so at larger accessibility text sizes the
            // stack can exceed 340pt with nowhere to go and no way to reach the rest.
            // Same failure mode the Library filter sheet chased across Batches
            // 235–241; same fix — a `ScrollView` with `.scrollBounceBehavior(.basedOnSize)`
            // so it's indistinguishable from static content when everything fits, and
            // an added `.large` detent as the actual escape valve when it doesn't.
            ScrollView {
            VStack(spacing: 20) {
                // (The "Playback Speed" title is the navigation title below.)

                // Fine adjust: − / current / +
                HStack(spacing: 24) {
                    stepperButton("minus", canRepeat: { rate > 0.5 }) { Haptics.selection(); leaveWPMMode(); playerViewModel.nudgeSpeed(by: -0.05) }
                        .disabled(rate <= 0.5)

                    Text(label(rate))
                        .font(.system(size: speedReadoutSize, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(minWidth: 120)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .shelfAnimation(.snappy, value: rate)

                    stepperButton("plus", canRepeat: { rate < 3.0 }) { Haptics.selection(); leaveWPMMode(); playerViewModel.nudgeSpeed(by: 0.05) }
                        .disabled(rate >= 3.0)
                }

                // Presets
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(presets, id: \.self) { value in
                        let selected = abs(rate - value) < 0.001
                        Button {
                            Haptics.selection()
                            leaveWPMMode()
                            playerViewModel.setPlaybackRate(value)
                        } label: {
                            Text(label(value))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(selected ? Color.shelfAmber : Color.shelfSurface,
                                            in: RoundedRectangle(cornerRadius: Radius.chip))
                                .foregroundStyle(selected ? Color.onAccent : Color.shelfCream)
                        }
                        .buttonStyle(.plain)
                        // Critique 2026-10-05 (typeset): "selected" was spelled into the
                        // label; the `.isSelected` trait is how VoiceOver announces it.
                        .accessibilityLabel("\(label(value)) speed")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                // P-6: `Space.xl` is 20 — same value, named role.
                .padding(.horizontal, Space.xl)
                // U9 (REVIEW_2026-08-20_UI_SECURITY.md): 4 fixed columns with no
                // `lineLimit`/fixed height meant an accessibility-size "1.75×" label had
                // room to wrap and grow the cell rather than clip — not broken, but a
                // cramped-layout hazard. Clamp at `.accessibility1`, matching
                // `HomeWeekStatsCard` (HomeView.swift), `CassetteTile` and `SeriesTile`
                // (RetroComponents.swift / SeriesBrowseView.swift).
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)

                // Polish pass (J3-12): during SharePlay the group owns the rate and it isn't saved.
                Typo.supporting(playerViewModel.isListeningTogether
                                ? Text("Applies while you listen together · not saved for this book")
                                : Text("Applies to this book · remembered next time"))
                    .foregroundStyle(Color.shelfMuted)

                wpmSection

                Spacer(minLength: 0)
            }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Playback Speed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SheetCloseButton { dismiss() }.monochromeToolbarItem()
            }
            .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
        }
        }
    }

    /// Polish pass (J3-8): spoken form of the rate for VoiceOver ("1.25 times"), since the
    /// glyph-only −/+ buttons otherwise say nothing about where the speed is now.
    static func spokenSpeed(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? "\(Int(rate))" : rate.formatted(.number.precision(.fractionLength(0...2)))
        return String(localized: "\(text) times", comment: "VoiceOver value for the playback speed; %@ is a number such as 1.25")
    }

    /// Hold-to-repeat timing (J3-8): first repeat after `holdDelay`, then every `repeatInterval`.
    static let holdDelay: Duration = .milliseconds(450)
    static let repeatInterval: Duration = .milliseconds(120)

    private func stepperButton(_ icon: String, canRepeat: @escaping () -> Bool,
                               action: @escaping () -> Void) -> some View {
        SpeedStepperButton(icon: icon, iconSize: stepperIconSize, canRepeat: canRepeat, action: action)
            .accessibilityLabel(icon == "minus" ? "Slower" : "Faster")
            .accessibilityValue(Self.spokenSpeed(rate))
    }
}

/// A −/+ button that steps once on tap and keeps stepping while held (standard stepper
/// behaviour). Still a real `Button`, so VoiceOver activation and Switch Control are unchanged.
/// A plain button style that reports press-down and release (including a cancelled press).
private struct PressReportingButtonStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

private struct SpeedStepperButton: View {
    let icon: String
    let iconSize: CGFloat
    let canRepeat: () -> Bool
    let action: () -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var didRepeat = false

    var body: some View {
        Button {
            // The release after a hold also fires the tap; swallow it so a hold doesn't add a step.
            if didRepeat { didRepeat = false; return }
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(Color.shelfCream)
                .frame(width: 48, height: 48)
                .background(Color.shelfSurface, in: Circle())
        }
        // Polish pass (J3-8): the hold is driven by the button's own pressed state, so a
        // touch that turns into a scroll (or slides off the button) cancels the repeat the
        // same way it cancels the tap. A zero-distance DragGesture would block the sheet's
        // ScrollView and keep repeating after the finger left the button.
        .buttonStyle(PressReportingButtonStyle { pressed in
            if pressed {
                guard holdTask == nil else { return }
                didRepeat = false
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: SpeedSheet.holdDelay)
                    while !Task.isCancelled, canRepeat() {
                        didRepeat = true
                        action()
                        try? await Task.sleep(for: SpeedSheet.repeatInterval)
                    }
                }
            } else {
                holdTask?.cancel()
                holdTask = nil
            }
        })
        .onDisappear { holdTask?.cancel(); holdTask = nil }
    }
}
