import SwiftUI
import UIKit
// `@Observable`/`@ObservationIgnored` on `TabBarMinimizeCoordinator` below —
// explicit rather than relying on a re-export, matching `DownloadManager`/`AppLockManager`.
import Observation

// MARK: - Haptics

/// Lightweight haptic helper, gated by the user's Haptics setting. Safe to call
/// from anywhere on the main thread.
/// Batch 495 (REVIEW 2026-11-11 V7): one feedback per action class. Use the row's call;
/// don't pick an intensity per screen.
///
/// | Action class                                    | Call                     |
/// |-------------------------------------------------|--------------------------|
/// | Play / pause (any surface)                      | `impact(.medium)`        |
/// | Skip back / forward                             | `impact(.light)`         |
/// | Add to Up Next / Play Next                      | fired by `PlayerViewModel.addToQueue` / `playNext`; call sites add none |
/// | Selection (pickers, toggles, menus, filters)    | `selection()`            |
/// | Success (a save or bulk action that completed)  | `success()`              |
/// | Refused, nothing to do (no change was made)     | `warning()`              |
/// | Failure (the action was tried and failed)       | `error()`                |
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard SettingsStore.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func selection() {
        guard SettingsStore.hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        guard SettingsStore.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    /// Batch 495 (V7): an action that was refused before anything changed.
    static func warning() {
        guard SettingsStore.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    /// Batch 495 (V7): an action that failed. Failures used to fire `impact(.heavy)`.
    static func error() {
        guard SettingsStore.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Quick Play/Resume (shared by BookContextMenu and DownloadsView's swipe action)

/// UX-1 (docs/design-review.md, Round 3): the label/action pairing for a quick Play,
/// Resume, Play Again or Pause control on a book, so `BookContextMenu`'s new first item
/// and `DownloadsView`'s leading swipe action (which predates this and originally owned
/// this logic as private helpers) stay in lock-step rather than drifting apart.
///
/// `finished`/`progressPercent` are parameters rather than read from `item` directly:
/// callers with a `LibraryViewModel` in scope should pass
/// `libraryViewModel.progressFor(itemId:)`'s fields (falling back to the item's own),
/// matching how `BookContextMenu`'s other items already compute `finished` — but
/// `DownloadsView` keeps reading `item.isFinished`/`item.progressPercent` directly, as it
/// did before this extraction, so its behaviour is unchanged.
extension PlayerViewModel {
    /// Whether `item` is the book currently loaded in the player (any transport state).
    func isCurrentBook(_ item: LibraryItem) -> Bool {
        currentBook?.id == item.id
    }

    /// Pause when `item` is the current book and playing, Play Again when finished,
    /// Resume when there's progress, else Play.
    func quickPlayActionLabel(for item: LibraryItem, finished: Bool, progressPercent: Double) -> String {
        if isCurrentBook(item) && isPlaying { return String(localized: "Pause", comment: "Quick play button label when the book is playing (verb)") }
        if finished { return String(localized: "Play Again", comment: "Quick play button label for a finished book (verb)") }
        return progressPercent > 0
            ? String(localized: "Resume", comment: "Quick play button label for a book with progress (verb)")
            : String(localized: "Play", comment: "Quick play button label (verb)")
    }

    /// SF Symbol paired with `quickPlayActionLabel(for:finished:progressPercent:)`.
    func quickPlayActionSystemImage(for item: LibraryItem) -> String {
        isCurrentBook(item) && isPlaying ? "pause.fill" : "play.fill"
    }

    /// Resumes/starts `item` through the standard playback entry point (single-flight,
    /// publishes `pendingBook` for the instant "starting" mini player), or toggles
    /// play/pause if it's already the loaded book rather than restarting it.
    func quickPlayOrPause(_ item: LibraryItem) {
        if isCurrentBook(item) {
            togglePlayPause()
        } else {
            // Batch 490 (REVIEW 2026-11-11 L4): starting a different book replaces the one
            // loaded, so offer the "Jump back" Undo toast like Book Detail's Play does.
            // Pause/resume of the loaded book (above) never shows a toast.
            Task { await startPlaybackOfferingUndo(for: item) }
        }
    }
}

// MARK: - Book context menu (long-press actions on any cover)

/// Reusable long-press menu for a book cover — Play/Resume, Play Next / Add to Up
/// Next, Download, Mark Finished, with a cover preview. Reads the shared view models
/// itself so call sites only pass the item.
/// Library bulk select (docs/design/library-browse-shape-2026-10-05.md §3.2): `LibraryView`
/// publishes `true` while select mode is on, so the legacy `RetroTabBar` shell can hide.
/// Any `true` among descendants wins.
struct LibrarySelectingPreferenceKey: PreferenceKey {
    static let defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct LibrarySelectActionKey: EnvironmentKey {
    static let defaultValue: ((LibraryItem) -> Void)? = nil
}

extension EnvironmentValues {
    /// Non-nil inside Library's Books scope: enters select mode with the item selected.
    /// `BookContextMenu` shows a "Select" item only when this is set.
    var librarySelectAction: ((LibraryItem) -> Void)? {
        get { self[LibrarySelectActionKey.self] }
        set { self[LibrarySelectActionKey.self] = newValue }
    }
}

private struct LibraryDetailSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<LibraryItem?>? = nil
}

extension EnvironmentValues {
    /// iPhone Duo (§3): non-nil in the sidebar column of Library's split view at regular width
    /// (the inner display), and so in every screen pushed there (Series, Authors, Collections,
    /// Downloads). Setting it shows the book in the detail column. Nil everywhere else,
    /// including the detail column itself, whose own links push within it.
    var libraryDetailSelection: Binding<LibraryItem?>? {
        get { self[LibraryDetailSelectionKey.self] }
        set { self[LibraryDetailSelectionKey.self] = newValue }
    }
}

/// iPhone Duo (§3): a link to a book's detail. In Library's split view on the inner display
/// (`libraryDetailSelection` set) it fills the detail column and marks the open book
/// `.isSelected`; everywhere else it's the same `NavigationLink` to `BookDetailView` as before.
struct BookLink<Label: View>: View {
    @Environment(\.libraryDetailSelection) private var detailSelection
    let item: LibraryItem
    @ViewBuilder let label: () -> Label

    init(_ item: LibraryItem, @ViewBuilder label: @escaping () -> Label) {
        self.item = item
        self.label = label
    }

    var body: some View {
        if let detailSelection {
            Button { detailSelection.wrappedValue = item } label: { label() }
                .accessibilityAddTraits(detailSelection.wrappedValue?.id == item.id ? .isSelected : [])
        } else {
            NavigationLink(destination: BookDetailView(item: item)) { label() }
        }
    }
}

/// iPhone Duo (§3): the screens Library pushes. A view-destination `NavigationLink` in the
/// split view's sidebar opened its screen in the detail column (seen on the inner display,
/// Batch 420); Apple only promises a push "in the same column" for a link that presents a
/// data type the column's stack has a `navigationDestination` for (`NavigationSplitView`).
/// `LibraryView` registers that destination. Hashed and compared by `key`, since the
/// payload models aren't `Hashable`.
enum LibraryRoute: Hashable {
    case series(Series)
    case author(NamedEntity)
    case narrator(String)
    /// Batch 492 (REVIEW 2026-11-11 L1): a genre or tag from Library search.
    case genre(String)
    case tag(String)
    case collection(BookCollection)
    case playlist(Playlist)
    case downloads
    case downloadsSettings(showsDownloadedBooksLink: Bool)

    private var key: String {
        switch self {
        case .series(let series): "series:\(series.id)"
        case .author(let author): "author:\(author.id)"
        case .narrator(let name): "narrator:\(name)"
        case .genre(let name): "genre:\(name)"
        case .tag(let name): "tag:\(name)"
        case .collection(let collection): "collection:\(collection.id)"
        case .playlist(let playlist): "playlist:\(playlist.id)"
        case .downloads: "downloads"
        case .downloadsSettings(let showsLink): "downloadsSettings:\(showsLink)"
        }
    }

    static func == (lhs: LibraryRoute, rhs: LibraryRoute) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    @ViewBuilder func destination(bottomInset: CGFloat) -> some View {
        switch self {
        case .series(let series):
            SeriesDetailView(series: series, bottomInset: bottomInset)
        case .author(let author):
            AuthorBooksView(author: author)
        case .narrator(let name):
            NarratorBooksView(narrator: name)
        case .genre(let name):
            GenreBooksView(genre: name)
        case .tag(let name):
            GenreBooksView(genre: name, filterGroup: "tags")
        case .collection(let collection):
            BookCollectionDetailView(title: collection.displayName, books: collection.books ?? [], source: .collection(collection.id))
        case .playlist(let playlist):
            BookCollectionDetailView(title: playlist.displayName, books: playlist.libraryItems, source: .playlist(playlist.id))
        case .downloads:
            DownloadsView(bottomInset: bottomInset)
        case .downloadsSettings(let showsLink):
            DownloadsSettingsView(bottomInset: bottomInset, showsDownloadedBooksLink: showsLink)
        }
    }
}

/// iPhone Duo (§3): a link to one of Library's pushed screens. In the split view's sidebar on
/// the inner display (`libraryDetailSelection` set) it's a value link, so the screen pushes
/// in the sidebar and its books open on the right through `BookLink`; everywhere else it's
/// the same view-destination `NavigationLink` as before (Settings reaches Downloads this way
/// too, with no `LibraryView` in its stack to resolve a value).
struct LibraryRouteLink<Label: View>: View {
    @Environment(\.libraryDetailSelection) private var detailSelection
    let route: LibraryRoute
    var bottomInset: CGFloat = 0
    @ViewBuilder let label: () -> Label

    init(_ route: LibraryRoute, bottomInset: CGFloat = 0, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.bottomInset = bottomInset
        self.label = label
    }

    var body: some View {
        if detailSelection != nil {
            NavigationLink(value: route) { label() }
        } else {
            NavigationLink { route.destination(bottomInset: bottomInset) } label: { label() }
        }
    }
}

/// Critique 2026-10-06 (harden): one wording for "remove a download" wherever it is
/// confirmed (Library's List swipe, Book Detail, the long-press menu), so every entry point
/// says the same thing about what is lost (the audio on this device) and what isn't (progress).
enum RemoveDownloadConfirmation {
    static var title: String { String(localized: "Remove This Download?") }
    static var button: String { String(localized: "Remove Download", comment: "Destructive button that deletes a downloaded book from the device") }
    static func message(title: String) -> String {
        String(localized: "\u{201C}\(title)\u{201D} will be deleted from this device. Your progress is kept.", comment: "Confirmation message. %@ is the book title")
    }
}

// MARK: - Bookmark delete with Undo

/// Critique 2026-10-06 (harden): one bookmark delete for every surface that can delete one
/// (Book Detail's bookmark sheet, the player's Bookmarks sheet, All Bookmarks). The player
/// sheet and All Bookmarks used to delete for good, from a full swipe too; only Book Detail
/// offered Undo.
///
/// Delete runs at once, with no confirmation (HIG Undo and redo: the toast is the safety
/// net). The deleted bookmark is held for a 6 s Undo toast that re-creates it (time and
/// title) through `BookmarkSyncService`. The local note is keyed by item and time, so it
/// re-attaches by itself. Offline, the delete and the re-create both queue, in order: Undo
/// waits for the delete it reverses before it sends the create, so the server can't apply
/// them the wrong way round. Each surface owns one instance and mounts
/// `.bookmarkUndoToast(_:refresh:)` on itself, so the toast shows above a sheet.
@MainActor
@Observable
final class BookmarkDeleteUndo {
    /// The toast text while Undo is on offer; `nil` hides the toast.
    var message: String?
    /// The bookmark the toast would bring back.
    private(set) var deleted: AudioBookmark?
    @ObservationIgnored private var pendingDelete: Task<Void, Never>?

    /// Deletes `bookmark`, then runs `refresh` (reload the surface's list), and offers Undo.
    /// A later delete replaces the offer, as the app's other Undo toasts do.
    func delete(_ bookmark: AudioBookmark, refresh: @escaping @MainActor () async -> Void = {}) {
        deleted = bookmark
        message = Self.message(title: bookmark.title, time: bookmark.time)
        let previous = pendingDelete
        pendingDelete = Task { @MainActor in
            await previous?.value
            await BookmarkSyncService.shared.delete(itemId: bookmark.libraryItemId, time: bookmark.time)
            await refresh()
        }
    }

    /// The toast's Undo: re-creates the last deleted bookmark. Returns it at once, so a
    /// surface that removed the row itself can put it straight back.
    @discardableResult
    func undo(refresh: @escaping @MainActor () async -> Void = {}) -> AudioBookmark? {
        guard let bookmark = deleted else { return nil }
        deleted = nil
        message = nil
        let delete = pendingDelete
        Task { @MainActor in
            await delete?.value
            await BookmarkSyncService.shared.create(
                itemId: bookmark.libraryItemId, time: bookmark.time, title: bookmark.title)
            await refresh()
        }
        return bookmark
    }

    /// "Deleted “Battle at the gate”", or "Deleted bookmark at 1:02:03" when the title is
    /// just the time (the default for a bookmark with no note). Pure, pinned by
    /// `HardenCopyTests` and `BookmarkUndoTests`.
    nonisolated static func message(title: String, time: Double) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = time.formattedTime
        if trimmed.isEmpty || trimmed == stamp {
            return String(localized: "Deleted bookmark at \(stamp)", comment: "Toast after deleting a bookmark. %@ is a timestamp such as 1:02:03")
        }
        return String(localized: "Deleted \u{201C}\(trimmed)\u{201D}", comment: "Toast after deleting a bookmark. %@ is the bookmark note")
    }

    /// The Undo toast for a bookmark sheet or list: 6 s, persists under VoiceOver
    /// (`toast(action:)`), same style as the app's other Undo toasts.
    static let toastDuration: Double = 6
}

extension View {
    /// Mounts `undo`'s toast on this view. `refresh` reloads the surface's list after the
    /// re-create lands (a trailing closure binds here: it's the first closure parameter);
    /// `restored` runs at once with the bookmark Undo brings back, for a surface that
    /// removed the row itself.
    @MainActor
    func bookmarkUndoToast(_ undo: BookmarkDeleteUndo, bottomInset: CGFloat = 0,
                           refresh: @escaping @MainActor () async -> Void = {},
                           restored: @escaping (AudioBookmark) -> Void = { _ in }) -> some View {
        toast(message: Binding(get: { undo.message }, set: { undo.message = $0 }),
              style: .success, duration: BookmarkDeleteUndo.toastDuration, bottomInset: bottomInset,
              action: ToastAction(label: "Undo") {
                  if let bookmark = undo.undo(refresh: refresh) { restored(bookmark) }
              })
    }
}

// MARK: - Bookmark edit outcome

/// Critique 2026-10-06 (harden): what an Edit Bookmark Save tells the person. Pure, so the
/// copy and the "close only on success" rule are pinned by `BookmarkUndoTests`.
enum BookmarkEditFeedback {
    /// The sheet stays open with this message when the save didn't happen.
    static var failureMessage: String { String(localized: "Couldn\u{2019}t save this bookmark. Check you\u{2019}re signed in, then try again.") }

    /// Whether the edit sheet should close (and buzz success): a synced or queued save.
    static func shouldClose(after result: PlayerViewModel.BookmarkSaveResult?) -> Bool {
        result != nil
    }
}

struct BookContextMenu: ViewModifier {
    let item: LibraryItem
    @Environment(\.librarySelectAction) private var librarySelectAction
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var addToListKind: AddToListSheet.Kind?
    @State private var downloadManager = DownloadManager.shared
    /// Critique 2026-10-06 (harden): Remove Download from this menu used to delete at once;
    /// the List swipe and Book Detail already confirmed. Same dialog and copy now.
    @State private var confirmRemoveDownload = false

    /// Batch 492 (REVIEW 2026-11-11 L2): a podcast show is not a book. Play, Download, Mark as
    /// Finished and the queue actions are episode-level (Mark as Finished on a show wrote a
    /// book-type progress record with no episode), so a show gets no book menu; tapping it
    /// opens the show, whose page has the episode actions.
    nonisolated static func offersBookActions(isPodcast: Bool) -> Bool { !isPodcast }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !Self.offersBookActions(isPodcast: item.isPodcast) {
            content
        } else {
            bookMenu(content)
        }
    }

    @ViewBuilder
    private func bookMenu(_ content: Content) -> some View {
        let finished = libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
        // Batch 497 (L12): listening progress only (`progress` is never the reading fraction),
        // so a read-but-never-played audiobook says Play, not Resume.
        let progressPercent = libraryViewModel.progressFor(itemId: item.id)?.progress ?? item.progressPercent
        // CO-7 (Batch 353): item glyphs in the label colour on the menu's glass, as the
        // other system menus and dialogs now are. The cover inside keeps the app's tint.
        content
            .tint(Color.shelfAmberText)
            .contextMenu {
            if let select = librarySelectAction {
                Button { Haptics.selection(); select(item) } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
            // UX-1 (docs/design-review.md, Round 3): Play/Resume as the first item,
            // always shown — previously Play Next/Add to Up Next only appeared when a
            // *different* book was already playing, and there was no quick way to start
            // a book at all without opening Book Detail.
            Button {
                Haptics.selection()
                playerViewModel.quickPlayOrPause(item)
            } label: {
                Label(
                    playerViewModel.quickPlayActionLabel(for: item, finished: finished, progressPercent: progressPercent),
                    systemImage: playerViewModel.quickPlayActionSystemImage(for: item)
                )
            }
            if playerViewModel.currentBook != nil, playerViewModel.currentBook?.id != item.id {
                Button { playerViewModel.playNext(item) } label: {   // V7: playNext gives the feedback
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { playerViewModel.addToQueue(item) } label: {   // V7: addToQueue gives the feedback
                    Label("Add to Up Next", systemImage: "text.badge.plus")
                }
            }
            if !downloadManager.isDownloaded(itemId: item.id) {
                Button { Haptics.selection(); downloadManager.downloadBook(item) } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            } else {
                Button(role: .destructive) { confirmRemoveDownload = true } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
            Button {
                // Critique 2026-10-06 (harden): Mark Finished replaces the position, so
                // `markFinished(item:)` now snapshots it and raises the app-wide Undo toast
                // (`LibraryViewModel.progressUndoMessage`).
                Task { finished ? await libraryViewModel.markUnfinished(item: item)
                                : await libraryViewModel.markFinished(item: item) }
            } label: {
                Label(finished ? "Mark as Not Finished" : "Mark as Finished",
                      systemImage: finished ? "circle" : "checkmark.circle")
            }
            // REVIEW 2026-11-11 F2: Add to Playlist / Collection (collections need update permission).
            if ListEditing.offersAddToPlaylist(isPodcast: item.isPodcast) {
                Button { addToListKind = .playlist } label: {
                    Label("Add to Playlist…", systemImage: "music.note.list")
                }
            }
            if ListEditing.offersAddToCollection(user: authViewModel.currentUser, isPodcast: item.isPodcast) {
                Button { addToListKind = .collection } label: {
                    Label("Add to Collection…", systemImage: "rectangle.stack.badge.plus")
                }
            }
            // Batch 490 (REVIEW 2026-11-11 F1): ABS's "Remove from Continue Listening", only for
            // a started, unfinished book. Not destructive: progress is kept, and the toast offers Undo.
            if LibraryViewModel.shouldOfferRemoveFromContinueListening(
                progress: libraryViewModel.progressFor(itemId: item.id) ?? item.mediaProgress,
                isPodcast: item.isPodcast) {
                Button {
                    Haptics.selection()
                    Task { await libraryViewModel.removeFromContinueListening(item) }
                } label: {
                    Label("Remove from Continue Listening", systemImage: "eye.slash")
                }
            }
        } preview: {
            // UX-1: a square cover preview beside the menu, per the HIG's guidance for
            // `contextMenu(menuItems:preview:)` — sized to roughly the tile art seen
            // elsewhere in Library rather than the tiny row thumbnail this menu might be
            // attached to.
            CachedCover(url: shelfCoverURL(itemId: item.id))
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .sheet(item: $addToListKind) { kind in
            AddToListSheet(item: item, kind: kind)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(RemoveDownloadConfirmation.title,
                            isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
            Button(RemoveDownloadConfirmation.button, role: .destructive) {
                downloadManager.removeDownload(itemId: item.id)
                Haptics.impact(.medium)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RemoveDownloadConfirmation.message(title: item.title))
        }
        .systemChromeTint()
    }
}

extension View {
    func bookContextMenu(_ item: LibraryItem) -> some View { modifier(BookContextMenu(item: item)) }
}

// MARK: - Dynamic Type helper

/// Applies a fixed-point custom font that still scales with the user's Dynamic Type
/// setting (anchored to a text style). Use in place of `.font(.system(size:...))` for
/// bespoke sizes so they grow/shrink for accessibility.
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// A Dynamic-Type-aware replacement for `.font(.system(size:weight:design:))`.
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, relativeTo: style))
    }
}

/// Reads Settings → Accessibility → Reduce Motion so `.animation(_:value:)` call sites
/// don't each have to declare their own `@Environment(\.accessibilityReduceMotion)` to
/// respect it — before this existed, the review found Reduce Motion honoured at only 4 of
/// 16 animation sites across the app (the four that separately hand-rolled the same
/// `guard !reduceMotion else { return }` check around a `withAnimation` block, e.g.
/// `SkeletonTile`'s pulse). When Reduce Motion is on, this passes `nil` instead of
/// `animation`, so SwiftUI still applies the state change but without animating it —
/// the same "skip the motion, keep the result" behavior as the hand-rolled sites.
private struct ShelfAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// HIG audit 2026-09-17 L17 — Toolbars: "prefer using the default monochromatic
    /// appearance of toolbars." `ShelfHeadApp` applies the user's accent as a global
    /// `.tint`, so a bare navigation-bar item still renders amber; this pins a top-bar
    /// item's glyph to the label colour (`shelfCream`: espresso in Light, cream in Dark) on
    /// both the iOS 26 Liquid Glass bar and the legacy shell. Apply to the content of each
    /// `ToolbarItem` / `ToolbarItemGroup` in a navigation bar. Not for the player's own
    /// control row (`PlayerView+BottomRegion`), which is a custom transport strip, not a
    /// system toolbar, and not for the Home wordmark, which is the brand mark, not a control.
    func monochromeToolbarItem() -> some View {
        self
            .tint(Color.shelfCream)
            .foregroundStyle(Color.shelfCream)
    }

    /// CO-7 (docs/visual-design-review.md, Batch 353 pilot): the neutral tint for system
    /// dialogs and menus. iOS 27 draws `alert`/`confirmationDialog` buttons and menu glyphs
    /// on glass that takes its colour from whatever is behind it, where the app's amber
    /// text measured 1.7–4.2:1. The label colour gets the material's vibrancy instead, as
    /// Apple's own dialogs do (HIG Color: "apply color sparingly to the Liquid Glass
    /// material, and to symbols or text on the material").
    ///
    /// Apply it **directly after** the `.alert` / `.confirmationDialog` modifier, or on a
    /// `Menu` itself. A tint inside the dialog's actions closure is ignored on iOS 27; one
    /// on the presenter, outside the dialog modifier, is honoured. It also reaches the
    /// presenter's own subtree, so where that subtree has tinted controls, keep them amber
    /// with `.tint(Color.shelfAmberText)` just *before* the dialog modifier:
    /// `content.tint(.shelfAmberText).alert(…).systemChromeTint()`. Destructive buttons keep
    /// the system's red; the tint doesn't reach role colours.
    func systemChromeTint() -> some View {
        tint(Color.primary)
    }

    /// Drop-in, Reduce-Motion-aware replacement for `.animation(_:value:)`.
    func shelfAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(ShelfAnimationModifier(animation: animation, value: value))
    }
}

/// LG-3 (docs/visual-design-review.md, Round V2): the dismiss button for sheets that only
/// show information (Chapters, Bookmarks, Up Next). On iOS 26+ it's the system Close
/// button, `Button(role: .close)` (iOS 26.0, Apple docs `ButtonRole/close`: "a close
/// operation doesn't lose progress"), which draws the standard ✕ glyph. iOS 17–25 keep the
/// text "Done". Edit flows (Edit Bookmark) keep their Cancel/Save pair instead. Apply
/// `.monochromeToolbarItem()` at the call site, as for any nav-bar item.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button("Done", action: action)
        }
    }
}

/// iPhone Duo (docs/iphone-duo-readiness-2026-10-22.md §2): the outer display puts every bar
/// in a vertical side bar, and a title-only toolbar item is never placed there. These are the
/// Cancel and Save/Done halves of an edit flow, as `SheetCloseButton` is for a plain dismiss.
/// On iOS 26+ they're the system role buttons (`Button(role:action:)`, iOS 26.0): `.cancel`
/// draws the ✕ glyph, `.confirm` (Apple docs `ButtonRole/confirm`, iOS 26.0) the ✓ glyph, and
/// both carry their title for VoiceOver and the vertical bar. iOS 17–25 keep the text. Put
/// them in `.cancellationAction` / `.confirmationAction` placements and apply
/// `.monochromeToolbarItem()` at the call site (except a confirm the sheet wants prominent).
struct SheetCancelButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .cancel, action: action)
        } else {
            Button("Cancel", role: .cancel, action: action)
        }
    }
}

struct SheetConfirmButton: View {
    /// The pre-iOS 26 text, e.g. "Save" or "Done".
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .confirm, action: action)
        } else {
            Button(title, action: action)
        }
    }
}

/// Reads Settings → Accessibility → Reduce Motion so `.symbolEffect(.bounce, value:)` call
/// sites don't each have to declare their own `@Environment(\.accessibilityReduceMotion)` —
/// same rationale as `ShelfAnimationModifier` above. When Reduce Motion is on, this applies
/// `.symbolEffectsRemoved(true)` alongside the effect, so SwiftUI suppresses the bounce.
private struct ShelfSymbolBounceModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, value: value)
            .symbolEffectsRemoved(reduceMotion)
    }
}

extension View {
    /// Drop-in, Reduce-Motion-aware replacement for `.symbolEffect(.bounce, value:)`.
    func shelfSymbolBounce<Value: Equatable>(value: Value) -> some View {
        modifier(ShelfSymbolBounceModifier(value: value))
    }
}

// MARK: - iPhone Duo (iOS 27.0 / 27.1 SDK APIs)

// iPhone Duo work (docs/iphone-duo-readiness-2026-10-22.md). Every use of an iOS 27.0 or
// 27.1 SwiftUI API sits inside `#if canImport(SwiftUI, _version: 8.0.85)` as well as an
// `#available` check. 8.0.85 is the SwiftUI in the iOS 27.1 SDK (Xcode 27.1, module
// version 8.0.85.29); CI's `macos-26` image (Xcode 26.x) and any older SDK compile the
// fallback branch instead, so the app still builds there without the Duo behaviour.

/// How much a toolbar item matters when the bar runs out of room (the outer display of
/// iPhone Duo puts every bar in one vertical side bar, which holds fewer items).
enum ShelfToolbarPriority {
    case high, low
}

extension ToolbarContent {
    /// `visibilityPriority(_:)` (iOS 27.0, Apple docs `ToolbarContent/visibilityPriority(_:)`:
    /// "items with a lower priority move into the overflow menu before items with a higher
    /// priority"). A no-op before iOS 27 and on older SDKs.
    @MainActor @ToolbarContentBuilder
    func shelfVisibilityPriority(_ priority: ShelfToolbarPriority) -> some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.0, *) {
            self.visibilityPriority(priority == .high ? .high : .low)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Appearance & Theme

/// User-facing appearance choice, stored as a raw string in `SettingsKeys.appearance`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return String(localized: "System", comment: "Appearance option: follow the system")
        case .light: return String(localized: "Light", comment: "Appearance option: light mode")
        case .dark: return String(localized: "Dark", comment: "Appearance option: dark mode")
        }
    }
    /// The scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// Shared WCAG contrast helpers. Used by `AppTheme.onAccentColor` (the accent picker's
/// on-fill ink) and `CoverPalette` (share-card / cover-derived palettes) so there is
/// exactly one gamma-correct luminance formula and one "which ink actually wins"
/// decision in the app, rather than two independently-wrong implementations of the same
/// idea (both previously applied the WCAG 0.2126/0.7152/0.0722 weights directly to
/// non-linear sRGB component values, and picked ink via an arbitrary luminance cutoff
/// instead of by measured contrast — see REVIEW_2026-08-12.md UI-2 for the measured
/// failures that produced, e.g. Teal `2FB6A8` choosing white ink at 2.51:1 instead of
/// black at 8.38:1).
enum ContrastInk {
    /// WCAG relative luminance, 0...1, from gamma-corrected (linearized) sRGB
    /// components each in 0...1. Feeding raw (non-linear) component values into the
    /// weights directly under/over-weights colours near the linearization knee — that's
    /// exactly what made Teal compute to 0.598, just under an 0.6 cutoff, and take the
    /// wrong ink.
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Picks whichever of near-black / white achieves the higher WCAG contrast ratio
    /// against a background of the given relative luminance. Deliberately *not* a fixed
    /// luminance threshold — a threshold has a cutoff a background can land near (see
    /// above); comparing the two actual achievable ratios doesn't.
    /// The dark ink actually returned below. Not pure black — a near-black espresso that
    /// matches the app's design language.
    static let darkInkWhiteComponent: Double = 0.08

    /// Luminance of `darkInkWhiteComponent`, ~0.0072 rather than 0.
    private static let darkInkLuminance = relativeLuminance(
        r: darkInkWhiteComponent, g: darkInkWhiteComponent, b: darkInkWhiteComponent)

    static func bestInk(forBackgroundLuminance bg: Double) -> Color {
        let contrastWithWhite = 1.05 / (bg + 0.05)
        // Was `(bg + 0.05) / 0.05`, i.e. the contrast of *pure black* — but the ink
        // actually returned is `Color(white: 0.08)`, luminance ~0.0072. That overstated
        // the dark option by ~14%, so for a background near the crossover this could
        // choose dark ink when white genuinely scored higher with the ink it then used.
        // Indigo (6366F1) was the one selectable accent where that happened: dark ink at
        // 4.11:1 where white achieves 4.47:1. Comparing against the real ink makes the
        // decision agree with what's drawn.
        let contrastWithDarkInk = (bg + 0.05) / (darkInkLuminance + 0.05)
        return contrastWithDarkInk >= contrastWithWhite ? Color(white: darkInkWhiteComponent) : .white
    }
}

/// Central theme accessors. Appearance defaults to `.dark` to preserve the app's
/// original tuned look; the accent defaults to the classic amber.
enum AppTheme {
    static let defaultAccentHex = "E8A838"

    /// Selectable accent swatches (name + hex). The first is the original amber.
    static var accentOptions: [(name: String, hex: String)] { [
        (String(localized: "Amber", comment: "Accent colour name"),   "E8A838"),
        (String(localized: "Orange", comment: "Accent colour name"),  "E0612F"),
        (String(localized: "Teal", comment: "Accent colour name"),    "2FB6A8"),
        (String(localized: "Blue", comment: "Accent colour name"),    "3B82F6"),
        (String(localized: "Indigo", comment: "Accent colour name"),  "6366F1"),
        (String(localized: "Purple", comment: "Accent colour name"),  "8B5CF6"),
        (String(localized: "Pink", comment: "Accent colour name"),    "EC4899"),
        (String(localized: "Red", comment: "Accent colour name"),     "EF4444"),
        (String(localized: "Green", comment: "Accent colour name"),   "22C55E")
    ] }

    static var appearance: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.appearance) ?? "") ?? .dark
    }

    static var accentHex: String {
        UserDefaults.standard.string(forKey: SettingsKeys.accentColor) ?? defaultAccentHex
    }

    /// UI-8: `Color.shelfAmber` (this property) has 211 call sites app-wide — 49 in
    /// `SettingsView`, 25 in `PlayerView`, 20 each in `HomeView`/`LibraryView`/
    /// `BookDetailView` — and `WaveformScrubber` (renamed `TapeScrubber` under D3,
    /// design brief 2026-08-12 — it no longer renders bars at all) used to read it up to
    /// 50 times (once per bar) on every single progress tick. Before this cache existed, *every one* of
    /// those reads independently re-ran `Color(hex:)`'s `UserDefaults` lookup +
    /// `trimmingCharacters` + a fresh `Scanner` allocation — 50 `UserDefaults` reads and
    /// 50 `Scanner` allocations per scrubber redraw alone. `ThemeStore` is the one place
    /// that already knows exactly when `accentHex` changes (its own `didSet`), so it's
    /// the natural single owner of the computed `Color` this recomputes from — this
    /// property just forwards to it instead of recomputing from `UserDefaults` itself.
    // CRIT-3 step 2 (REVIEW_2026-08-12.md): `@MainActor` propagated down from
    // `ThemeStore` (now `@MainActor`, see that type) — these four static vars all
    // synchronously read `ThemeStore.shared.cached*`, so they must share its isolation.
    // Every one of their ~211 call sites is already inside a SwiftUI `View.body` or
    // another already-`@MainActor` context, so this doesn't require any call-site
    // changes.
    @MainActor static var accentColor: Color { ThemeStore.shared.cachedAccentColor }

    /// The actual `Color(hex:)` + `UserDefaults` computation `accentColor` used to run on
    /// every access — now called exactly once per `accentHex` change, from
    /// `ThemeStore.recomputeCachedAccentColors()`.
    static func computeAccentColor(hex: String) -> Color { Color(hex: hex) }

    /// Best-contrast ink (near-black or white) for text/icons placed *on* the
    /// accent fill. Chosen by measured WCAG contrast ratio (via `ContrastInk`) rather
    /// than an arbitrary luminance threshold, so every accent swatch — not just the
    /// ones far from the old 0.6 cutoff — gets the ink that actually reads best. Also
    /// drops the old `.opacity(0.85)` on the black ink, which silently reduced the very
    /// contrast this type just calculated.
    ///
    /// UI-8: cached the same way as `accentColor` above — see its doc comment.
    @MainActor static var onAccentColor: Color { ThemeStore.shared.cachedOnAccentColor }

    static func computeOnAccentColor(hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        let luminance = ContrastInk.relativeLuminance(r: r, g: g, b: b)
        return ContrastInk.bestInk(forBackgroundLuminance: luminance)
    }

    /// Accent adjusted just enough to clear WCAG AA (4.5:1) text contrast against
    /// `shelfBackground`'s resolved color in whichever theme is active, via
    /// `adjustedHexForContrast`. This is computed per-swatch/per-theme rather than a
    /// fixed darken-in-Light-only factor: while the raw accent as text clears ~9:1 in
    /// Dark theme for most swatches (as the review measured for Amber), two of the nine
    /// selectable accents — Indigo `6366F1` and Purple `8B5CF6` — measure just under
    /// 4.5:1 against the *Dark* background too (4.20:1 and 4.43:1), which a
    /// dark-theme-always-passes assumption would have missed. This is a *text/icon
    /// foreground* token only — fills (buttons, progress bars, badges) should keep
    /// using the raw `accentColor`/`shelfAmber`; darkening/lightening those would just
    /// make the app's signature accent look muddy for no contrast benefit, since fills
    /// aren't text.
    /// UI-8: cached like `accentColor` above. Unlike the other three cached properties,
    /// caching this one doesn't eliminate *all* the work on every use — the returned
    /// `Color` wraps a `UIColor { traits in ... }` closure that UIKit still re-invokes
    /// whenever it resolves the color against current traits (that's what makes it
    /// adapt live to a Light/Dark switch without needing a SwiftUI re-render), and that
    /// closure still runs the full `adjustedHexForContrast` search each time. What this
    /// cache *does* remove is the outer `accentHex` `UserDefaults` read and `Color`
    /// wrapper construction that used to happen on every one of this property's own call
    /// sites, on top of that unavoidable per-trait-resolution cost.
    @MainActor static var accentTextColor: Color { ThemeStore.shared.cachedAccentTextColor }

    static func computeAccentTextColor(hex: String) -> Color {
        Color(UIColor { traits in
            let backgroundHex = traits.userInterfaceStyle == .dark ? "16110C" : "F7F2E9"
            let adjusted = Self.adjustedHexForContrast(hex, backgroundHex: backgroundHex)
            return UIColor(Color(hex: adjusted))
        })
    }

    /// Critique 2026-10-06 (colorize): the surfaces accent text can sit on besides the ground.
    /// `shelfSurface` is the binding one in both themes (Light: Paper Well `EAE1D2` is darker
    /// than the white card; Dark: Deck Well `32261A` is lighter than the `2A2016` card), so a
    /// colour that clears 4.5:1 on it also clears it on `shelfCard`.
    static let surfaceLightHex = "EAE1D2"
    static let surfaceDarkHex = "32261A"

    /// `accentTextColor` re-tuned against `shelfSurface`/`shelfCard` instead of the ground.
    /// `shelfAmberText` measures about 3.9:1 on Paper Well; this clears 4.5:1 there.
    static func accentTextOnSurfaceHex(hex: String, dark: Bool) -> String {
        adjustedHexForContrast(hex, backgroundHex: dark ? surfaceDarkHex : surfaceLightHex)
    }

    static func computeAccentTextOnSurfaceColor(hex: String) -> Color {
        let light = accentTextOnSurfaceHex(hex: hex, dark: false)
        let dark = accentTextOnSurfaceHex(hex: hex, dark: true)
        return Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    @MainActor static var accentTextOnSurfaceColor: Color { ThemeStore.shared.cachedAccentTextOnSurface }

    private static func rgbComponents(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        return (
            Double((int >> 16) & 0xFF) / 255.0,
            Double((int >> 8) & 0xFF) / 255.0,
            Double(int & 0xFF) / 255.0
        )
    }

    private static func hexString(r: Double, g: Double, b: Double) -> String {
        func channel(_ v: Double) -> UInt64 { UInt64((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// Nudges `hex` toward black or white — whichever direction actually increases
    /// contrast against `backgroundHex` — in small linear-RGB steps until it clears
    /// `targetRatio`, or until it reaches that endpoint. A general fix (works for any
    /// accent against any known background) rather than a fixed per-theme adjustment
    /// factor, which is what let Indigo/Purple slip through as "Dark theme is always
    /// fine" above. Returns `hex` unchanged if it already clears the target.
    static func adjustedHexForContrast(_ hex: String, backgroundHex: String, targetRatio: Double = 4.5) -> String {
        let bg = rgbComponents(backgroundHex)
        let backgroundLuminance = ContrastInk.relativeLuminance(r: bg.r, g: bg.g, b: bg.b)
        let original = rgbComponents(hex)

        func ratio(_ luminance: Double) -> Double {
            let lighter = max(luminance, backgroundLuminance), darker = min(luminance, backgroundLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }

        let originalLuminance = ContrastInk.relativeLuminance(r: original.r, g: original.g, b: original.b)
        guard ratio(originalLuminance) < targetRatio else { return hex }

        // Does pushing all the way to black or all the way to white achieve more
        // contrast against this background? That's the direction to step in.
        // The loop below must judge the colour it will actually *return*. Stepping until
        // the float components clear the target, then quantizing to 8-bit in
        // `hexString`, can round the luminance back under it — that is how Teal (2FB6A8)
        // came out at 4.4973:1 against the Light background for a 4.5 target. Measuring
        // the quantized value makes the returned hex genuinely satisfy the contract.
        func quantizedLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func q(_ v: Double) -> Double { (min(1, max(0, v)) * 255).rounded() / 255 }
            return ContrastInk.relativeLuminance(r: q(r), g: q(g), b: q(b))
        }

        let stepsTowardBlack = ratio(0) >= ratio(1)
        var (r, g, b) = original
        var t = 0.0
        while ratio(quantizedLuminance(r, g, b)) < targetRatio && t < 1.0 {
            t += 0.02
            if stepsTowardBlack {
                r = original.r * (1 - t)
                g = original.g * (1 - t)
                b = original.b * (1 - t)
            } else {
                r = original.r + (1 - original.r) * t
                g = original.g + (1 - original.g) * t
                b = original.b + (1 - original.b) * t
            }
        }
        return hexString(r: r, g: g, b: b)
    }

    // MARK: - Hue-harmonised secondary palette (F1, REVIEW_2026-09-04_UI.md)

    /// Rotates `anchorHex`'s hue by the same amount the user's accent has been rotated
    /// away from the default accent, keeping the anchor's own saturation and brightness.
    ///
    /// The retro palette is three colours — amber (primary), teal (secondary), burnt
    /// orange (emphasis) — and the teal and orange were chosen to sit at a particular
    /// interval from *amber*. Once `shelfAmber` became user-selectable, only the primary
    /// moved: `shelfAccent` and `shelfOrange` stayed pinned to their literals, so an
    /// Indigo accent produced Settings icon tiles alternating indigo and teal with no
    /// semantic reason for the alternation, and the app's only green (the Book Detail
    /// series chip) reading as foreign. Rotating by the *delta* preserves the interval
    /// that made the trio work at any accent.
    ///
    /// Keeping the anchor's S/B (rather than the accent's) is what preserves each
    /// colour's character — teal stays the muted one, orange stays the vivid one.
    ///
    /// Invariant, pinned by `ColorThemeTests`: when the accent is `defaultAccentHex`
    /// the delta is zero, so this returns the anchor unchanged and every derived colour
    /// is bit-identical to the literal it replaced. An achromatic accent (a grey or
    /// near-white swatch) has no meaningful hue, so it also returns the anchor unchanged
    /// rather than rotating by an arbitrary amount.
    static func hueHarmonizedHex(anchorHex: String, accentHex: String) -> String {
        let accent = hsbComponents(accentHex)
        let base = hsbComponents(defaultAccentHex)
        guard accent.s > 0.05, base.s > 0.05 else { return anchorHex }

        let delta = accent.h - base.h
        guard abs(delta) > 0.0001 else { return anchorHex }

        let anchor = hsbComponents(anchorHex)
        var hue = (anchor.h + delta).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }

        let rotated = UIColor(hue: hue, saturation: anchor.s, brightness: anchor.b, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rotated.getRed(&r, green: &g, blue: &b, alpha: &a)
        return hexString(r: Double(r), g: Double(g), b: Double(b))
    }

    private static func hsbComponents(_ hex: String) -> (h: Double, s: Double, b: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    /// The literals the secondary palette is anchored on — the values that shipped
    /// alongside the default amber, and what every derivation above rotates *from*.
    enum SecondaryAnchor {
        static let accentLight = "1C8E82"      // retro teal
        static let accentDark  = "2FB6A8"
        static let orangeLight = "C9531F"      // burnt orange
        static let orangeDark  = "E0612F"
    }

    /// The secondary accent (was the fixed retro teal), harmonised to the live accent.
    /// Adaptive light/dark, and both hexes are derived once here rather than inside the
    /// trait closure, so resolving the colour stays a plain lookup.
    static func computeSecondaryAccentColor(accentHex: String) -> Color {
        let light = hueHarmonizedHex(anchorHex: SecondaryAnchor.accentLight, accentHex: accentHex)
        let dark = hueHarmonizedHex(anchorHex: SecondaryAnchor.accentDark, accentHex: accentHex)
        return Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// Foreground-safe variant of the above — §12.1's existing contrast correction, now
    /// applied to the derived hue instead of the hardcoded teal.
    static func computeSecondaryAccentTextColor(accentHex: String) -> Color {
        let light = adjustedHexForContrast(
            hueHarmonizedHex(anchorHex: SecondaryAnchor.accentLight, accentHex: accentHex),
            backgroundHex: "F7F2E9")
        let dark = adjustedHexForContrast(
            hueHarmonizedHex(anchorHex: SecondaryAnchor.accentDark, accentHex: accentHex),
            backgroundHex: "16110C")
        return Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// The emphasis colour (was the fixed burnt orange), harmonised the same way.
    static func computeEmphasisColor(accentHex: String) -> Color {
        let light = hueHarmonizedHex(anchorHex: SecondaryAnchor.orangeLight, accentHex: accentHex)
        let dark = hueHarmonizedHex(anchorHex: SecondaryAnchor.orangeDark, accentHex: accentHex)
        return Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// D4's contrast-safe ink for text drawn *on* the emphasis fill, following the
    /// derived hue rather than the literal.
    static func computeEmphasisInkColor(accentHex: String) -> Color {
        let light = hueHarmonizedHex(anchorHex: SecondaryAnchor.orangeLight, accentHex: accentHex)
        let dark = hueHarmonizedHex(anchorHex: SecondaryAnchor.orangeDark, accentHex: accentHex)
        return Color(UIColor { traits in
            UIColor(computeOnAccentColor(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    @MainActor static var secondaryAccentColor: Color { ThemeStore.shared.cachedSecondaryAccent }
    @MainActor static var secondaryAccentTextColor: Color { ThemeStore.shared.cachedSecondaryAccentText }
    @MainActor static var emphasisColor: Color { ThemeStore.shared.cachedEmphasis }
    @MainActor static var emphasisInkColor: Color { ThemeStore.shared.cachedEmphasisInk }

    /// A darker shade of the current accent, for the primary-button gradient's lower
    /// stop. Derived from the accent so any accent (not just amber) reads correctly.
    ///
    /// UI-8: cached like `accentColor` above.
    @MainActor static var accentDarkColor: Color { ThemeStore.shared.cachedAccentDarkColor }

    static func computeAccentDarkColor(hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        let f = 0.82   // ~18% darker
        return Color(.sRGB, red: r * f, green: g * f, blue: b * f, opacity: 1)
    }
}

// MARK: - Color Extensions

extension Color {
    // Retro tape-deck palette. Each semantic color is adaptive (light/dark) so the app
    // supports a Light theme; the dark values are the original tuned palette.

    /// Adaptive color that resolves per the environment's light/dark trait.
    static func adaptive(light: String, dark: String) -> Color {
        Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// Primary amber/gold — VU-meter glow, controls, progress. **User-selectable**
    /// via the Accent picker (defaults to the original amber). Reserved for FILLS
    /// (buttons, progress bars, badges, `.tint`/`.background`/`.fill`/`.stroke`) — for
    /// text or icon *foreground* color, use `shelfAmberText` instead, which stays
    /// legible in Light theme (see UI-1 in REVIEW_2026-08-12.md: the raw accent as text
    /// measures as low as ~1.9:1 on the Light background).
    // CRIT-3 step 2: `@MainActor` propagated from `AppTheme`'s cached accessors above.
    @MainActor static var shelfAmber: Color { AppTheme.accentColor }

    /// Accent color for text and icon *foregrounds* (`.foregroundColor`/
    /// `.foregroundStyle`) — darkened enough in Light theme to clear WCAG AA (~4.5:1).
    /// Identical to `shelfAmber` in Dark theme, where the raw accent already reads well.
    @MainActor static var shelfAmberText: Color { AppTheme.accentTextColor }

    /// Critique 2026-10-06 (colorize): accent text on `shelfSurface` / `shelfCard` (pills,
    /// cards, wells). `shelfAmberText` is tuned for the ground and falls under AA there
    /// (about 3.9:1 on Paper Well); this one is tuned for the surface, ≥4.5:1 on both.
    @MainActor static var shelfAmberTextOnSurface: Color { AppTheme.accentTextOnSurfaceColor }

    /// Contrast-aware ink for text/icons drawn on the accent fill (see AppTheme).
    @MainActor static var onAccent: Color { AppTheme.onAccentColor }

    /// A darker shade of the accent (for the primary-button gradient's lower stop).
    @MainActor static var shelfAmberDark: Color { AppTheme.accentDarkColor }

    /// Deep warm espresso background (the "deck" body) / warm paper in light mode.
    static let shelfBackground = adaptive(light: "F7F2E9", dark: "16110C")

    /// Raised card / panel. CO-4 (V5, accepted 26 September 2026): the dark value was
    /// `241B12`, about 1.1:1 against the `16110C` ground; lifted to `2A2016` so cards read
    /// as slabs. Light is unchanged. Cream and muted text stay well above 4.5:1 on it.
    static let shelfCard = adaptive(light: "FFFFFF", dark: "2A2016")

    /// Retro teal accent for secondary interactive bits.
    ///
    /// F1 (REVIEW_2026-09-04_UI.md): was `adaptive(light: "1C8E82", dark: "2FB6A8")`.
    /// Those literals were picked to sit at a particular interval from the *default
    /// amber*; once the accent became user-selectable only the primary moved, so an
    /// Indigo accent left Settings alternating indigo and teal tiles for no reason a
    /// user could read as intentional. Now rotated by the accent's own hue delta, which
    /// returns those exact literals when the accent is the default amber.
    @MainActor static var shelfAccent: Color { AppTheme.secondaryAccentColor }

    /// §12.1 (REDESIGN_PROPOSAL_2026-08-26.md): `shelfAccent` as *text* on
    /// `shelfBackground` measures 3.14:1 in Light theme (raw teal `1C8E82` is close to
    /// the paper background's own mid-luminance neighborhood) — well under WCAG AA's
    /// 4.5:1 floor for normal-size text/icons, and the failure is Light-theme-only,
    /// which is why five prior review passes missed it: the app defaults to Dark
    /// (`AppTheme.appearance` falls back to `.dark`), and Dark already clears 6.33:1.
    /// Mirrors `shelfOrangeInk` immediately below and `AppTheme.accentTextColor` above:
    /// `shelfAccent` itself stays untouched for fills (capsule/badge backgrounds,
    /// `.tint`, progress indicators) — this is a foreground-only token, darkened just
    /// enough via the already-general `AppTheme.adjustedHexForContrast` to clear 4.5:1
    /// against whichever background is actually resolved. Use this anywhere
    /// `shelfAccent` is currently used as a `.foregroundColor`/`.foregroundStyle`
    /// (e.g. the series capsule in `BookDetailView.swift`), not as a fill.
    /// F1: same §12.1 contrast correction, now applied to the accent-derived hue.
    @MainActor static var shelfAccentText: Color { AppTheme.secondaryAccentTextColor }

    /// Muted secondary text (darker taupe in light mode for contrast).
    static let shelfMuted = adaptive(light: shelfMutedLightHex, dark: "A89177")
    /// `shelfMuted`'s Light value (Taupe Ink). Also the fixed neutral swipe-action fill
    /// (`LibrarySwipeTint.neutral`), which needs it in both appearances.
    static let shelfMutedLightHex = "6E5E49"

    /// Elevated surface (knobs, wells).
    static let shelfSurface = adaptive(light: "EAE1D2", dark: "32261A")

    /// Burnt orange — peaks/emphasis, "record" dot.
    ///
    /// F1: hue-harmonised to the accent for the same reason as `shelfAccent` above; the
    /// original `C9531F`/`E0612F` are what this resolves to at the default amber.
    @MainActor static var shelfOrange: Color { AppTheme.emphasisColor }

    /// D4 (design brief 2026-08-12): contrast-safe ink for text/icons drawn on
    /// `shelfOrange` — `ConnectivityBanner` is the one real usage. Plain white measured
    /// ~4.43:1 in Light theme, marginally under WCAG AA's 4.5:1 for the banner's 13pt
    /// semibold label. Computed per-theme via `ContrastInk` (through
    /// `AppTheme.computeOnAccentColor`, which despite its accent-specific name is just
    /// "best ink for a hex") rather than assumed white, mirroring how `onAccentColor`
    /// already does this for the user-selectable accent.
    @MainActor static var shelfOrangeInk: Color { AppTheme.emphasisInkColor }

    /// Primary readout text — dark espresso in light mode, cream in dark mode.
    static let shelfCream = adaptive(light: "2A211A", dark: "F4E9D6")

    // Fixed tape-hardware literals (DESIGN.md: LCD Window, Cassette Shell). Deliberately not
    // `adaptive(...)`: they're physical objects that stay dark in both themes, like the
    // reels. Named here so the hardware reads its colours from one place (polish
    // 2026-10-05; they were inline hex in `TapeCounter` and `CassetteView`).
    static let lcdWindow = Color(hex: "0B0906")
    static let cassetteShellTop = Color(hex: "3A2B1C")
    static let cassetteShellBottom = Color(hex: "281D12")
    /// Cream ink and detailing on the deck skins' dark hardware (Batch 466). `shelfCream`'s
    /// dark-theme value, fixed, because the keys stay dark in light appearance too.
    static let deckCream = Color(hex: "F4E9D6")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Cover URL helper

/// Percent-encodes a server-supplied identifier before it's interpolated into a URL
/// path, so an id containing `/`, `?`, `#`, etc. can't break the request or redirect
/// it elsewhere. Mirrors `AudiobookshelfAPI`'s private `pc(_:)` — that one can't be
/// reused directly outside the actor, so this is the shared version for the handful
/// of call sites (cover URLs, Now Playing artwork, download paths) that build URLs/
/// file paths from an item id outside the API layer.
func percentEncodedPathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}

/// Registry of the most-recently-seen `updatedAt` (epoch ms, exactly as
/// `LibraryItem.updatedAt` decodes it) per item id, so a replaced cover on the server
/// can bust every cache tier keyed on the cover URL (`CoverImageCache`'s `NSCache`,
/// `DiskCoverCache`, and `CachedCover`'s own `.task(id: url)`).
///
/// Bug this exists to fix: `shelfCoverURL` used to build `.../cover?width=<w>`, which
/// never changes when the server-side artwork does — every tier above keys on that URL,
/// so a replaced cover just kept resolving to the same cache entry everywhere except
/// wherever hadn't populated one yet. Populated as items decode
/// (`LibraryItem.init(from:)`, AudiobookshelfModels.swift) from every list, shelf,
/// search, and detail fetch, with no call-site changes needed there.
///
/// `nonisolated` and lock-protected rather than actor-isolated: `LibraryItem.init(from:)`
/// runs on whatever thread/actor happens to be decoding it (a background `URLSession`
/// completion, a main-actor view model, a test), and must be able to record a version
/// without hopping anywhere first.
nonisolated enum CoverVersions {
    private static let lock = NSLock()
    private static var versions: [String: Int] = [:]

    /// Fires when `record` observes a previously-known version move *forward* for an
    /// item — never for an item recorded for the first time (there's no prior version to
    /// have gone stale from) and never when the value is unchanged or older (a stale/
    /// out-of-order payload shouldn't trigger anything). `DownloadManager.init()` sets
    /// this once, so a downloaded book's local cover can be refreshed without
    /// `AudiobookshelfModels.swift` importing any download concerns.
    nonisolated(unsafe) static var onVersionObserved: (@Sendable (String, Int) -> Void)?

    /// Records `itemId`'s current `updatedAt`. Ignores `nil` (a payload that omitted the
    /// field) and never moves a version backward. Returns whether this call actually
    /// changed a *previously known* value (i.e. there was already a recorded version and
    /// this one is newer) — `false` for the first sighting of an item, for an unchanged
    /// value, or for an older/out-of-order one.
    @discardableResult
    static func record(itemId: String, updatedAt: Int?) -> Bool {
        guard let updatedAt else { return false }
        lock.lock()
        let previous = versions[itemId]
        let isGenuineChange = previous != nil && updatedAt > previous!
        if previous == nil || updatedAt > previous! {
            versions[itemId] = updatedAt
        }
        lock.unlock()
        if isGenuineChange { onVersionObserved?(itemId, updatedAt) }
        return isGenuineChange
    }

    /// The most recently recorded version for `itemId`, or `nil` if none has been seen
    /// this launch.
    static func version(for itemId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return versions[itemId]
    }

    /// Clears every recorded version. Call alongside `DiskCoverCache.clear()` on
    /// sign-out/account removal (currently `AuthViewModel.tearDownAccountScopedState(reason:)`,
    /// which already calls `DiskCoverCache.clear()` — see that call site), and from tests.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        versions.removeAll()
    }
}

/// Appends a cache-busting `ts` query item (matching Audiobookshelf's own web client,
/// which stamps cover requests with `?ts=<updatedAt>`; the server ignores unknown query
/// params) when `version` is known, so a changed cover produces a genuinely different
/// URL — every cache tier a cover URL passes through keys on the URL itself. Returns
/// `base` unchanged when `version` is `nil` (nothing known yet to bust against).
///
/// Pure and `nonisolated`: no I/O, no actor-isolated state, safe to call from anywhere.
nonisolated func coverCacheBustedURL(base: URL, version: Int?) -> URL {
    guard let version else { return base }
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
    var items = components.queryItems ?? []
    items.append(URLQueryItem(name: "ts", value: String(version)))
    components.queryItems = items
    return components.url ?? base
}

/// `@MainActor`: reads `DownloadManager.shared.localCoverURL`, which touches
/// `downloadedItems` (main-actor-isolated state now that `DownloadManager` is
/// `@MainActor`). Every current call site is already on the main actor (SwiftUI
/// views, `CarPlayImageLoader`/`CarPlayCoordinator`, `ShareCard`), so this just makes
/// that existing assumption compiler-enforced.
@MainActor
func shelfCoverURL(itemId: String, width: Int = 300) -> URL? {
    // Prefer a locally-cached cover so downloaded books show art offline.
    // REVIEW-2026-09-09 item 10: this used to call `localCoverURL(itemId:)`, which
    // stats the cover file on disk — a synchronous `FileManager.fileExists` on the main
    // actor from inside `body`, twice a second for the current book (mini-player + full
    // player) and once per visible tile on every Library body pass. `localCoverURL(for:)`
    // consults `DownloadManager`'s in-memory `itemsWithLocalCover` instead, which is kept
    // current at cover-write, scope load, completion, repair and removal.
    //
    // Cover-versioning bug fix: a downloaded book's cover otherwise never refreshes even
    // after `DownloadManager.refreshLocalCoverIfStale` rewrites `cover.jpg` on disk — the
    // physical path is identical, so every URL-keyed cache tier (and `CachedCover`'s own
    // `.task(id: url)`, which only refires when its `url` argument actually changes)
    // would keep serving the stale bitmap forever. Busting against the manifest's own
    // `coverUpdatedAt` (bumped exactly when the file is rewritten) makes the URL change
    // exactly when the on-disk bytes do.
    if let local = DownloadManager.shared.localCoverURL(for: itemId) {
        return coverCacheBustedURL(base: local, version: DownloadManager.shared.manifest(for: itemId)?.coverUpdatedAt)
    }
    let server = AuthStore.shared.serverURL
    // Clean URL — the access token is sent in the Authorization header (every cover
    // fetch goes through `AudiobookshelfAPI.authorizedData(for:)`, which builds the
    // request via `AuthStore.authorizedRequest(url:)`) instead of the query string,
    // keeping it out of server / reverse-proxy logs. Also makes this a stable cache key
    // across token rotation — and, now, a cache key that changes when the server's own
    // `updatedAt` for the item does, via `coverCacheBustedURL`/`CoverVersions` above, so
    // a replaced cover doesn't keep resolving to the same stale cache entry everywhere
    // that entry already existed.
    guard let base = URL(string: "\(server)/api/items/\(percentEncodedPathComponent(itemId))/cover?width=\(width)") else {
        return nil
    }
    return coverCacheBustedURL(base: base, version: CoverVersions.version(for: itemId))
}

/// ID-3 (V5): the server's photo for an author (`GET /api/authors/{id}/image`). It 404s when the
/// author has none, so callers check `AudiobookshelfAPI.getAuthorArtwork(authorId:)` first.
func authorImageURL(authorId: String, width: Int = 160) -> URL? {
    URL(string: "\(AuthStore.shared.serverURL)/api/authors/\(percentEncodedPathComponent(authorId))/image?width=\(width)")
}

// MARK: - Bottom clearance (UI-12, REVIEW_2026-08-12.md)

/// The height reserved so a scrollable screen's last row clears the floating
/// mini-player + tab bar. Was duplicated verbatim across `SettingsView` (twice),
/// `ServerDiagnosticsView`, `DownloadHealthView`, `StatsView`, and `YearInReviewView —
/// and had already drifted once: `PlaybackHistoryView`'s copy dropped the "is a book
/// currently loaded" branch entirely and always fell back to a flat 88pt, so its last
/// row sat behind the mini-player on any screen where one was actually showing while
/// every other page correctly reserved the taller 152pt in that case. One shared
/// function instead of N independently-maintained copies.
func bottomBarClearance(bottomInset: CGFloat, hasMiniPlayer: Bool) -> CGFloat {
    // NEW-4 (follow-up review, 14 Aug 2026): on iOS 26+, `MainTabView`'s real system
    // `TabView` + `.tabViewBottomAccessory` (`modernTabs`) already gives every child
    // `NavigationStack` — Settings and its subpages included — its own correct
    // safe-area inset automatically. There is no legacy `bottomBar`/
    // `BottomBarHeightKey` measurement pipeline on that path at all, so
    // `bottomInset` legitimately stays 0 there forever, not "measurement hasn't
    // landed yet." The `0` branch below was written for the legacy path's own
    // startup race (before its `PreferenceKey` reports its first real value) —
    // reusing that same "0 means fallback" semantics for both cases added up to
    // 152pt of pure dead space, on top of the system's own already-correct inset,
    // at the bottom of every Settings page on iOS 26.
    if #available(iOS 26.0, *) { return 0 }
    return bottomInset > 0 ? bottomInset + 16 : (hasMiniPlayer ? 152 : 88)
}

// MARK: - Tab bar minimize coordinator (iOS 26)

/// Drives the value `MainTabView.modernTabs` passes to `.tabBarMinimizeBehavior(...)`
/// on iOS 26+, so that minimise-on-scroll can be on everywhere without the bar ever
/// getting stuck minimised.
///
/// **The problem.** The wanted behaviour is plain: the native tab bar minimises when
/// you scroll down, on any page, and comes back when you scroll up.
/// `.tabBarMinimizeBehavior(.onScrollDown)` is exactly that — but only while there is
/// something left to scroll. Batch 320's user report: minimise the bar by scrolling
/// Downloads, push Download Settings (a list too short to scroll), and the bar is
/// stuck minimised with no gesture left anywhere to bring it back. iOS 26 ships no API
/// to expand the tab bar programmatically, so Batch 320 fell back to
/// `.tabBarMinimizeBehavior(selectedTab <= 1 ? .onScrollDown : .never)` — minimise on
/// scroll only on the two tabs whose content is reliably long. The user has since
/// decided the opposite: minimise-on-scroll should work on *every* page, Settings and
/// its sub-pages included.
///
/// **The lever.** Batch 320 observed one thing on device that turns out to be the fix:
/// changing the *value* handed to `.tabBarMinimizeBehavior(...)` re-expands an
/// already-minimised bar. That batch saw it by accident — switching from Home to
/// Settings flipped the value from `.onScrollDown` to `.never` and the bar came back.
/// So instead of pinning the behaviour per tab, this coordinator flips the value to
/// `.never` for a single beat whenever a new screen appears (a push, a pop back, a tab
/// switch, an account change, a deep link) and then puts it straight back to
/// `.onScrollDown`. The flip forces the expand; the flip back leaves normal
/// minimise-on-scroll in force for the screen the user just landed on.
///
/// The ~100ms window is long enough that SwiftUI commits the two values as two
/// distinct updates (setting and clearing the flag in one runloop pass would coalesce
/// into no change at all, and therefore no expand) and short enough that the user
/// cannot realistically start a scroll inside it — so no scroll-down gesture is
/// swallowed by the temporary `.never`.
///
/// This is a workaround for a missing API, not a design: if a future SDK grows a real
/// "expand the tab bar" call, this whole type collapses into that one call. Nothing
/// here is gated on `#available` — the type is plain Swift so call sites compile on
/// the app's iOS 17.6 deployment target; below iOS 26 nothing ever reads `suspended`
/// and the whole mechanism is inert.
@MainActor
@Observable
final class TabBarMinimizeCoordinator {
    static let shared = TabBarMinimizeCoordinator()

    /// `true` only for the brief window in which the `TabView` should pass `.never`
    /// instead of `.onScrollDown`. Read from `MainTabView.modernTabs`.
    private(set) var suspended = false

    /// How long `.never` stays in force before `.onScrollDown` is restored.
    /// Injectable purely so `TabBarMinimizeCoordinatorTests` can drive this with a
    /// short window instead of sleeping a tenth of a second per assertion — the app
    /// only ever uses `shared`, and so only ever the default.
    let window: Duration

    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    init(window: Duration = .milliseconds(100)) {
        self.window = window
    }

    /// Expand the tab bar if it is currently minimised, then hand control straight
    /// back to `.onScrollDown`.
    ///
    /// Safe to call repeatedly and in bursts: each call cancels the pending restore
    /// and starts the window over, so a tab switch whose destination screen also fires
    /// `reexpandsTabBarOnAppear()` in the same frame collapses into one flip rather
    /// than two overlapping ones fighting over the flag.
    func reexpand() {
        restoreTask?.cancel()
        suspended = true
        restoreTask = Task { [window] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self.suspended = false
        }
    }
}

extension View {
    /// Re-expands the iOS 26 tab bar whenever this screen appears — both on the push
    /// that creates it and on the pop back to it, which is the case Batch 320 had no
    /// answer for. Apply once, to the outermost view in a screen's `body`.
    ///
    /// A no-op below iOS 26 (nothing reads `TabBarMinimizeCoordinator.suspended`
    /// there) and harmless on anything presented outside the tab hierarchy, so it is
    /// simply omitted from sheets and from the full-player overlay rather than needing
    /// to be guarded. See `TabBarMinimizeCoordinator` for why "a screen appeared" is
    /// the trigger and why there is no direct expand call to make instead.
    func reexpandsTabBarOnAppear() -> some View {
        // Also on disappear (PM addition, Batch 321): when a pushed screen is popped,
        // its `onDisappear` fires whether or not SwiftUI re-fires the underlying
        // screen's `onAppear`, so pop-to-parent is covered from both sides. Harmless
        // elsewhere — a deeper push re-fires the coordinator anyway.
        onAppear { TabBarMinimizeCoordinator.shared.reexpand() }
            .onDisappear { TabBarMinimizeCoordinator.shared.reexpand() }
    }
}

// MARK: - View Extensions

extension View {
    /// iOS 26/27 Liquid Glass polish pass (26 August 2026): was a bare fill + clip with
    /// no elevation cue at all — every other raised surface in the app (BookDetailView's
    /// header cover, HomeView's hero card, etc.) already routes through `shelfElevation`
    /// for the theme-aware "soft shadow in Dark, hairline border in Light" treatment;
    /// this shared row/card style had drifted out of sync with that convention. Also
    /// swapped the hardcoded `12` for `Radius.card` (same numeric value, now a named
    /// token) so this and every other card-radius call site move together.
    /// Shared "padded stat/summary panel" style — iOS 26/27 Liquid Glass polish pass
    /// (26 August 2026): `StatsView.swift` (6 sites) and `YearInReviewView.swift`
    /// (3 sites) had each independently reinvented
    /// `.background(Color.shelfCard) + .clipShape(RoundedRectangle(cornerRadius: 14/16))`
    /// with no elevation cue and two slightly different radii between them. Converged
    /// on `Radius.panel` and routed through `shelfElevation` for the same theme-aware
    /// "soft shadow in Dark, hairline border in Light" depth every other card in the
    /// app already has.
    func statPanelStyle() -> some View {
        self
            .background(Color.shelfCard)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
            .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.panel))
    }

    func shelfCardStyle() -> some View {
        self
            .background(Color.shelfCard)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    /// Presents an alert whenever `message` becomes non-nil, clearing it on dismiss.
    /// Pass `retry` to add a Retry button (e.g. for failed loads).
    func errorAlert(title: LocalizedStringKey = "Something went wrong", message: Binding<String?>, retry: (() -> Void)? = nil) -> some View {
        // CO-7: missed by the Batch 353 sweep (its grep looked for `.alert(`, and this calls
        // `alert(` bare). Same pair as every other dialog: see `systemChromeTint()`.
        tint(Color.shelfAmberText)
            .alert(
                title,
                isPresented: Binding(
                    get: { message.wrappedValue != nil },
                    set: { if !$0 { message.wrappedValue = nil } }
                )
            ) {
                if let retry {
                    Button("Retry") {
                        message.wrappedValue = nil
                        retry()
                    }
                }
                Button("OK", role: .cancel) { message.wrappedValue = nil }
            } message: {
                Text(message.wrappedValue ?? "")
            }
            .systemChromeTint()
    }

    /// Shows a transient toast at the bottom whenever `message` becomes non-nil.
    /// `bottomInset` should clear the mini-player + tab bar when present (0 otherwise).
    /// Critique 2026-10-05 (Mini player): optional `action` adds a trailing button (e.g. Undo).
    func toast(message: Binding<String?>, style: ToastStyle = .error, duration: Double = 3, bottomInset: CGFloat = 0, action: ToastAction? = nil) -> some View {
        modifier(ToastModifier(message: message, style: style, duration: duration, bottomInset: bottomInset, action: action))
    }

    func shelfButtonStyle() -> some View {
        self
            .font(.headline)
            .foregroundStyle(Color.onAccent)   // contrast-aware ink on the accent fill (any accent / theme)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                // Subtle vertical gradient (amber → slightly deeper amber) so the
                // primary action feels premium and dimensional rather than flat.
                LinearGradient(
                    colors: [Color.shelfAmber, Color.shelfAmberDark],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Batch 434: the Book Detail pinned bar's button. A content-hugging capsule (the HIG's
    /// prominent compact button) instead of the full-width slab: same accent fill and ink, but
    /// it shares its row with the progress line rather than taking a row of its own. 44 pt
    /// minimum height keeps the touch target.
    func shelfCompactButtonStyle() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.onAccent)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color.shelfAmber, in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Toast

/// Visual style for a toast. Error is the default; success/info are for positive
/// confirmations (e.g. "Added to Up Next").
enum ToastStyle {
    case error, success, info

    var icon: String {
        switch self {
        case .error:   return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }
    // Real build error: `shelfAmber` is `@MainActor`-isolated (Batch 135), but
    // `ToastStyle` itself is a plain (non-isolated) enum, so this computed property
    // inherited no isolation from its enclosing type — same class of gap as Batch 140's
    // `menuRow`/`settingRow` fix, just on a property instead of a free function.
    // `@MainActor` directly on the property is sufficient here rather than isolating the
    // whole enum, since `icon` above touches no actor-isolated state and every real
    // caller of `.tint` is already a `View` body (main-actor) — grepped all consumers.
    @MainActor
    var tint: Color {
        switch self {
        // Critique 2026-10-06 (colorize): orange rule, not raw red. The glyph is an icon
        // (3:1 floor); the message stays cream.
        case .error:   return Color.shelfOrange
        case .success: return Color.shelfAccent
        // Critique 2026-10-05 (Mini player, 2nd): the glyph is a foreground, so it uses the
        // text-safe amber (Fill-or-Text rule), not the fill amber.
        case .info:    return Color.shelfAmberText
        }
    }
}

/// LG-4 (docs/visual-design-review.md, Round V1): the toast's drop shadow, kept only
/// for the iOS 17–25 fallback where `glassPill` renders `.ultraThinMaterial` instead
/// of real Liquid Glass. On iOS 26+, Liquid Glass already draws its own depth, so
/// this shadow is dropped there rather than stacked on top of it.
private struct LegacyToastShadow: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        }
    }
}

/// A button on a toast (Critique 2026-10-05, Mini player). Tapping it runs `handler` and
/// dismisses the toast.
struct ToastAction {
    let label: LocalizedStringResource
    let handler: () -> Void
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var style: ToastStyle = .error
    let duration: Double
    var bottomInset: CGFloat = 0
    var action: ToastAction? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Critique 2026-10-05 (Mini player, 2nd): SwiftUI's VoiceOver flag (iOS 15.0, Apple docs
    // EnvironmentValues/accessibilityVoiceOverEnabled) and focus state (iOS 15.0).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var actionFocused: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let msg = message {
                    HStack(spacing: 8) {
                        Image(systemName: style.icon)
                            .foregroundStyle(style.tint)
                        Text(msg)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.shelfCream)
                            .lineLimit(2)
                        if let action {
                            // Critique 2026-10-05 (Mini player): real Button, 44pt target.
                            // A toast with an action is the iOS undo pattern, so it is
                            // time-limited by `duration` like the rest (callers pass 6 s).
                            Button {
                                let run = action.handler
                                message = nil
                                run()
                            } label: {
                                Text(action.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.shelfAmberText)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityFocused($actionFocused)
                        }
                    }
                    // A toast with an action stays until dismissed under VoiceOver, so it
                    // needs a way out: Escape (two-finger scrub) or a named action.
                    .accessibilityAction(.escape) { if action != nil { message = nil } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, action == nil ? 12 : 2)
                    // Code review fix (26 August 2026): missed by Batch 228's
                    // `.regularMaterial` → `glassPill` sweep, and the `12` here should
                    // also have been `Radius.card` rather than a raw literal.
                    .glassPill(RoundedRectangle(cornerRadius: Radius.card), interactive: false)
                    // D4 shadow audit (follow-up review, 14 Aug 2026): kept in both
                    // themes — a floating toast pill casting a shadow onto whatever's
                    // behind it, the same "floating control, not a page-resting card"
                    // reasoning already recorded on `glassPill`'s identical shadow.
                    // LG-4 (docs/visual-design-review.md, Round V1): on iOS 26+ `glassPill`
                    // is real Liquid Glass with its own depth, so this shadow doubled up
                    // into a dark halo under the glass rim. `glassPill` itself only falls
                    // back to `.ultraThinMaterial` below iOS 26, which is where a shadow is
                    // still needed — so restrict it to that fallback.
                    .modifier(LegacyToastShadow())
                    .padding(.horizontal, 24)
                    // Sit just above the mini-player/tab bar when one is shown; otherwise
                    // float a small margin off the bottom (was a hardcoded 140pt that left
                    // a big gap when nothing was playing).
                    .padding(.bottom, (bottomInset > 0 ? bottomInset : 24) + 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: msg) {
                        // Critique 2026-10-05 (second run): toasts were silent to VoiceOver,
                        // so error and confirmation copy never reached it. Same API as
                        // `ConnectivityBanner` (AccessibilityNotification.Announcement, iOS 17.0).
                        AccessibilityNotification.Announcement(action.map { String(localized: "\(msg). \(String(localized: $0.label)) available", comment: "VoiceOver announcement for a toast with an action. First %@ is the toast message, second is the action name such as Undo") } ?? msg).post()
                        if action != nil, voiceOverEnabled {
                            // Critique 2026-10-05 (Mini player, 2nd): a 6 s Undo can't be
                            // reached by swipe navigation, so under VoiceOver it persists
                            // until dismissed or acted on, and focus moves to its button.
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            actionFocused = true
                            return
                        }
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        withAnimation(reduceMotion ? nil : .default) { message = nil }
                    }
                }
            }
            .shelfAnimation(.spring(response: 0.4, dampingFraction: 0.8), value: message)
    }
}

// MARK: - Cached cover image

/// In-memory cover cache so rebuilding a view (e.g. the tab "scroll to top" reset)
/// repaints artwork instantly instead of re-fetching and flashing blank.
enum CoverImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 300
        c.totalCostLimit = 96 * 1024 * 1024   // ~96 MB cap so decoded covers can't grow unbounded
        return c
    }()

    /// `NSCache`'s cost is meant to approximate the memory the object actually holds.
    /// Using the compressed JPEG's byte count (as this cache used to) understates that
    /// by roughly an order of magnitude — a ~40KB compressed 600×600 cover decodes to
    /// ~1.4MB of RGBA in memory — so the "96MB" limit above could in practice hold
    /// several hundred MB of real decoded bitmaps before either limit tripped. Use the
    /// image's actual decoded footprint instead.
    static func decodedCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    /// The downsample target for a given cover URL, derived from its own `width` query
    /// param — callers already encode their intended resolution there (`shelfCoverURL`
    /// defaults to 300 for grid tiles, `CoverImageView` passes `width * 2`, the player
    /// and share card pass 600/900). A single hardcoded downsample size for every
    /// caller was wrong: it made share-card exports and the full player's cassette
    /// label render from a 300px source no matter how large they actually needed it,
    /// while grid tiles are exactly where the memory win matters.
    ///
    /// A local downloaded-book cover (`file://`) is a special case: `shelfCoverURL`
    /// returns `DownloadManager.localCoverURL` before it ever consults its own
    /// `width` argument, so whatever the caller asked for (900 from the player,
    /// 400 from a grid tile) is discarded at the URL level and there's no query
    /// param here to read back — these are exactly the covers someone is actually
    /// sitting in the player with, so falling back to the generic 300 default would
    /// under-serve them. Special-cased to 600, matching the resolution
    /// `enqueueDownload` actually saved the file at (`cover?width=600`), so a
    /// downloaded book's cassette label/detail cover isn't downsampled below what's
    /// already on disk. Any other URL with no `width` param at all (shouldn't
    /// happen in practice, since every remote call site sets one) falls back to
    /// 300, matching `shelfCoverURL`'s own default.
    static func targetSize(for url: URL) -> CGSize {
        if url.isFileURL { return CGSize(width: 600, height: 600) }
        let w = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "width" }?.value
            .flatMap(Double.init) ?? 300
        return CGSize(width: w, height: w)
    }

    /// Best-effort warm of an item's cover so it renders instantly later (used to
    /// prefetch the next queued book near the end of the current one).
    ///
    /// `@MainActor`: `shelfCoverURL` is `@MainActor` (reads `DownloadManager` state).
    /// Its only caller, `PlayerViewModel.prefetchNext()`, is already `@MainActor`; the
    /// actual network/disk work below still runs off-actor inside `Task.detached`.
    @MainActor
    static func prefetch(itemId: String) {
        guard let url = shelfCoverURL(itemId: itemId) else { return }
        if shared.object(forKey: url as NSURL) != nil { return }
        Task.detached(priority: .utility) {
            // Disk tier (F3) — checked before the network, skipped entirely for
            // already-local downloaded-book covers (file:// URLs; see shelfCoverURL).
            // Downsampled to this URL's own requested size (see `targetSize(for:)`) so
            // a prefetched cover doesn't quietly eat more cache budget than one loaded
            // normally through the same URL would. `?? image` falls back to the full
            // decode if thumbnailing fails, rather than dropping the cover entirely.
            let size = targetSize(for: url)
            guard let data = await coverData(for: url), let decoded = UIImage(data: data) else { return }
            let image = decoded.preparingThumbnail(of: size) ?? decoded
            shared.setObject(image, forKey: url as NSURL, cost: decodedCost(of: image))
        }
    }

    /// Cover bytes for `url`, checking the disk tier before the network and populating it
    /// after — the single place a cover is actually fetched.
    ///
    /// Consolidated here when `WidgetLibraryPublisher` needed cover bytes too: rather than
    /// become a third copy of this disk-then-network dance, both callers share this one.
    ///
    /// Item 6 (REVIEW-2026-09-09 remaining): this used to be the "known bypass" the
    /// comment here previously documented — it built its request with
    /// `authorizedCoverRequest` and called `URLSession.shared.data(for:)` directly, so a
    /// cover request that 401d got none of the silent refresh-and-retry every other
    /// authenticated call gets. Behind a reverse proxy, or simply after the access token
    /// rotated, every cover on screen stayed a placeholder until something *else*
    /// happened to refresh the token. It now goes through
    /// `AudiobookshelfAPI.authorizedData(for:)`, which is the same
    /// `AuthStore.authorizedRequest(url:)` (bearer + per-account custom headers) plus one
    /// refresh-and-retry on 401.
    ///
    /// The old worry about a burst of parallel cover loads causing a refresh storm
    /// doesn't apply: `AudiobookshelfAPI.refreshIfPossible` keeps a single in-flight
    /// `refreshTask` on the actor, so N simultaneous 401s await one refresh and then each
    /// retry once. The disk/memory cache layering stays here rather than moving into the
    /// API type, and neither request carried a custom `cachePolicy` (both use
    /// `URLRequest`'s default), so cache semantics are unchanged.
    ///
    /// Non-2xx still isn't cached: `authorizedData` throws (`validateStatus`) on anything
    /// outside 200...299, so `try?` turns a 401/404 body into `nil` before
    /// `DiskCoverCache.store` can see it — the same guarantee the explicit
    /// `statusCode == 200` check used to give.
    static func coverData(for url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        let isRemote = isRemoteCover(url)
        if isRemote, let diskData = DiskCoverCache.data(for: url) {
            // Item 15 (REVIEW-2026-09-09-REMAINING.md): still returned immediately — a
            // stale-but-present disk copy beats a blank cell — but past TTL, kick a
            // background re-check so replaced server artwork eventually shows up instead
            // of sitting until LRU eviction happens to reach it. Fire-and-forget, never
            // awaited: this cold-load path must not get slower.
            revalidateDiskCoverIfNeeded(url: url, cachedData: diskData)
            return diskData
        }
        guard let data = try? await AudiobookshelfAPI.shared.authorizedData(for: url) else { return nil }
        if isRemote { DiskCoverCache.store(data, for: url) }
        return data
    }

    /// Background half of item 15's revalidation. `DiskCoverCache` only tracks and
    /// judges staleness (`storedAt`/`needsRevalidation`); this is the one place that
    /// actually re-fetches and decides whether the result changed anything, since it
    /// needs the network call (`AudiobookshelfAPI.authorizedData(for:)`) and the
    /// in-memory `shared` cache, neither of which `DiskCoverCache` knows about.
    ///
    /// No conditional request exists here (no ETag/If-None-Match) — `authorizedData(for:)`
    /// hands back only decoded body bytes, not response headers, so there's nothing
    /// cheap to condition on without widening that method's contract for this one
    /// caller. A full re-fetch past the TTL, compared byte-for-byte, is the accepted
    /// trade for staying inside this batch's allowed files.
    private static func revalidateDiskCoverIfNeeded(url: URL, cachedData: Data) {
        guard let storedAt = DiskCoverCache.storedAt(for: url),
              DiskCoverCache.needsRevalidation(storedAt: storedAt, now: Date(), ttl: DiskCoverCache.coverTTL)
        else { return }
        Task.detached(priority: .background) {
            guard let fresh = try? await AudiobookshelfAPI.shared.authorizedData(for: url) else { return }
            guard fresh != cachedData else {
                // Unchanged — refresh the timestamp so the next load doesn't re-check
                // again until another full TTL window has passed.
                DiskCoverCache.touch(url)
                return
            }
            DiskCoverCache.store(fresh, for: url)
            // Replace the in-memory decode too, or the stale bitmap would keep showing
            // (from `shared`) until process relaunch even though the disk tier is
            // current. `NSCache` is thread-safe, so this can run directly on the
            // detached task like `prefetch(itemId:)` above already does.
            guard let decoded = UIImage(data: fresh) else { return }
            let size = targetSize(for: url)
            let image = decoded.preparingThumbnail(of: size) ?? decoded
            shared.setObject(image, forKey: url as NSURL, cost: decodedCost(of: image))
        }
    }

    /// Whether a cover URL is fetched from the server (and so is worth putting in the
    /// disk cache) rather than read from local storage. Was spelled out inline in three
    /// places; one definition so the disk-cache tier and the fetch path can't disagree
    /// about what "remote" means.
    static func isRemoteCover(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// Drops one URL's in-memory entry. `shelfCoverURL`'s cache-busted local URLs (see
    /// `coverCacheBustedURL`) already make a refreshed downloaded cover resolve to a new
    /// URL — a cache miss by construction — so this is a defensive cleanup for the
    /// now-orphaned previous entry (`DownloadManager.refreshLocalCoverIfStale`), not the
    /// mechanism the refresh actually depends on.
    static func evict(url: URL) {
        shared.removeObject(forKey: url as NSURL)
    }
}

/// Decodes a cover off the main actor, wired so it actually stops when the caller's
/// `.task` is cancelled.
///
/// Item 10 (REVIEW-2026-09-09.md): `CachedCover` below did this work in a bare
/// `Task.detached`, which inherits nothing from the `.task` that spawned it — not its
/// isolation and, the point here, not its cancellation. Scrolling a grid fast enough
/// that cells are recycled mid-load left every one of those detached decodes running to
/// completion (a disk read plus a full decode plus a downsample each) for a cell that no
/// longer exists, and then paying the in-memory cache's eviction cost to store the
/// result. Handing the detached task's own handle to `withTaskCancellationHandler` is
/// what connects the two: cancelling the `.task` cancels this decode, and the
/// `Task.isCancelled` check inside runs before the expensive part rather than after it.
/// The work itself still happens off the main actor exactly as before — this only adds
/// the two cancellation checks around it.
private func cancellableCoverDecode(_ decode: @escaping @Sendable () -> UIImage?) async -> UIImage? {
    if Task.isCancelled { return nil }
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
        if Task.isCancelled { return nil }
        return decode()
    }
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// A cover that fills its frame, backed by `CoverImageCache`. Reads the cache
/// synchronously at init, so a cached image shows immediately with no blank frame.
struct CachedCover: View {
    let url: URL?
    /// IC-2: draw the whole image (`.fit`) over a blurred, scaled copy of itself instead
    /// of cropping to fill. Only used for the player and Book Detail; a square cover
    /// looks the same either way, so the backdrop is skipped for those.
    var fit: Bool = false
    @State private var image: UIImage?
    /// Polish pass (J3-11): `.task(id: url)` only re-ran when the URL changed, so a cover that
    /// failed once (flaky network) stayed a placeholder for as long as the player or Book
    /// Detail stayed on screen. A failed remote load now schedules up to `retryDelays.count`
    /// retries, spaced out so a down server isn't hammered; `retryToken` re-keys the task.
    @State private var retryToken = 0
    @State private var failedAttempts = 0
    static let retryDelays: [Int] = [4, 15, 45]
    private struct LoadKey: Equatable { let url: URL?; let token: Int }
    // Design review 2026-09-23 AN-1: only the async disk/network loads fade in; the
    // synchronous cache-hit paths below never touch this, so a warm cover still renders
    // on the first frame with no fade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The URL `image` was actually loaded for.
    ///
    /// Item 10 (REVIEW-2026-09-09.md): `image` is `@State`, so it outlives a change of
    /// `url` whenever this view keeps its identity — which is exactly what the two
    /// highest-traffic call sites do. `MiniPlayerView`'s `CoverImageView(itemId:)` and
    /// `PlayerView.coverArtView`'s `CachedCover(url:)` are the same view in the same
    /// position across a book change (auto-advance, or just starting something else), so
    /// `.task(id: url)`'s `if image != nil { return }` fired with nothing having cleared
    /// the previous book's artwork first, and the wrong cover stayed on screen for the
    /// rest of the session. Tracking which URL the held image belongs to is what makes
    /// "already loaded" mean "already loaded *for this url*".
    @State private var loadedURL: URL?

    init(url: URL?, fit: Bool = false) {
        self.url = url
        self.fit = fit
        // Seeded from the in-memory cache so an already-decoded cover renders on the
        // first frame with no placeholder flash (unchanged). `loadedURL` is seeded
        // alongside it so that first image is never mistaken for a stale one.
        let cached = url.flatMap { CoverImageCache.shared.object(forKey: $0 as NSURL) }
        _image = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    /// The image to draw this pass. A held image only counts while it belongs to the
    /// current `url`; the frame `url` changes on, this falls back to a synchronous
    /// in-memory cache lookup for the *new* URL instead. That ordering matters: `.task`
    /// can only run after the frame that changed `url`, so without this the stale cover
    /// would still be drawn once more (and, for an uncached new cover, until the network
    /// fetch returned). An already-cached cover therefore still swaps with no flash.
    private var displayImage: UIImage? {
        if loadedURL == url, let image { return image }
        return url.flatMap { CoverImageCache.shared.object(forKey: $0 as NSURL) }
    }

    @ViewBuilder
    private func coverImage(_ image: UIImage) -> some View {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        if fit && abs(ratio - 1) > 0.02 {
            ZStack {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 24)
                            .scaleEffect(1.15)
                            .opacity(0.85)
                    }
                    .clipped()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }

    var body: some View {
        ZStack {
            if let image = displayImage {
                coverImage(image)
                    // Design review 2026-09-23 AN-1: pairs with the withAnimation around
                    // the async assignments below — a synchronous cache hit never wraps
                    // its `image =` write in an animation, so this transition never plays
                    // for that path and the warm cover still appears on the first frame.
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color.shelfSurface)
                    .overlay(Image(systemName: "book.closed.fill").foregroundStyle(Color.shelfMuted))
            }
        }
        .onChange(of: url) { _, _ in failedAttempts = 0 }
        .task(id: LoadKey(url: url, token: retryToken)) {
            // Item 10 (REVIEW-2026-09-09.md): drop an image held for a *previous* URL
            // before the "already loaded" early return below can see it, re-seeding from
            // the in-memory cache for the new URL — the same lookup `displayImage` has
            // already done for this frame, so a cached cover never flashes. Skipped
            // entirely when there is nothing to clear and nothing to seed, so this can't
            // turn into a redundant `@State` write (and a redundant render) per pass.
            if loadedURL != url {
                let cached = url.flatMap { CoverImageCache.shared.object(forKey: $0 as NSURL) }
                if image != nil || cached != nil {
                    image = cached
                    loadedURL = cached == nil ? nil : url
                }
            }
            if image != nil { return }
            guard let url else { return }
            if let cached = CoverImageCache.shared.object(forKey: url as NSURL) {
                image = cached
                loadedURL = url
                return
            }
            // Disk tier (F3): a cold launch has an empty in-memory NSCache, so this is
            // what makes the library grid render instantly instead of every cover
            // flashing blank while it re-downloads. Skipped for already-local
            // downloaded-book covers (file:// URLs; see shelfCoverURL).
            let isRemote = CoverImageCache.isRemoteCover(url)
            // The disk read (a blocking `Data(contentsOf:)`, slower on a cold Caches/
            // page) plus decode plus downsample all happen off-main in one detached
            // task. `.task` runs in the view's isolation context (the main actor for
            // SwiftUI views), so doing this inline would block the main thread on
            // every cell — barely noticeable per cell, but a fast grid scroll fires
            // dozens of these in a single run-loop pass, which is exactly the kind of
            // thing that turns into intermittent, hard-to-diagnose scroll hitching.
            // Downsampling to the actual display size (not the ~600px the server
            // returns) also means far more covers fit in the same in-memory cache
            // budget — a decoded 300×300 cover is roughly a quarter the size of 600×600.
            // Item 10: `cancellableCoverDecode` (above) is the same detached decode this
            // has always done, plus the cancellation plumbing the bare `Task.detached`
            // had no way to see. The `Task.isCancelled` check after each await is the
            // "before caching" half — a decode that finished just as the cell was
            // recycled shouldn't take a slot in the in-memory cache (or assign to a
            // `@State` nobody is showing).
            if isRemote {
                let display = await cancellableCoverDecode {
                    guard let decoded = DiskCoverCache.data(for: url).flatMap({ UIImage(data: $0) }) else { return nil as UIImage? }
                    let size = CoverImageCache.targetSize(for: url)
                    return decoded.preparingThumbnail(of: size) ?? decoded
                }
                if Task.isCancelled { return }
                if let display {
                    CoverImageCache.shared.setObject(display, forKey: url as NSURL, cost: CoverImageCache.decodedCost(of: display))
                    // Design review 2026-09-23 AN-1: fade the disk-cache pop-in; skipped
                    // entirely under Reduce Motion.
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        image = display
                        loadedURL = url
                    }
                    return
                }
            }
            // Item 6 (REVIEW-2026-09-09 remaining): was
            // `URLSession.shared.data(for: authorizedCoverRequest(url))`, which both
            // skipped the API type's refresh-and-retry-once on a 401 *and* discarded the
            // response entirely — a 401/404 error body would be handed to `UIImage(data:)`
            // and, if that somehow decoded, written into the disk cover cache. Going
            // through `authorizedData(for:)` fixes both: it throws on any non-2xx
            // (`validateStatus`), so `try?` drops the response before it can be decoded or
            // cached, and it refreshes once and retries once on a 401 like every other
            // authenticated call. A `file://` cover is handled there too (read directly,
            // no headers), matching what this line's `URLSession` file-URL fetch did.
            if let data = try? await AudiobookshelfAPI.shared.authorizedData(for: url) {
                let display = await cancellableCoverDecode {
                    guard let decoded = UIImage(data: data) else { return nil as UIImage? }
                    let size = CoverImageCache.targetSize(for: url)
                    return decoded.preparingThumbnail(of: size) ?? decoded
                }
                if Task.isCancelled { return }
                if let display {
                    CoverImageCache.shared.setObject(display, forKey: url as NSURL, cost: CoverImageCache.decodedCost(of: display))
                    // Design review 2026-09-23 AN-1: fade the network pop-in; skipped
                    // entirely under Reduce Motion.
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        image = display
                        loadedURL = url
                    }
                    if isRemote { DiskCoverCache.store(data, for: url) }
                    return
                }
            }
            // Polish pass (J3-11): nothing loaded. Try again later while still on screen
            // (the task is cancelled when the view goes away or the URL changes).
            if isRemote, !Task.isCancelled, failedAttempts < Self.retryDelays.count {
                let delay = Self.retryDelays[failedAttempts]
                failedAttempts += 1
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled { retryToken += 1 }
            }
        }
    }
}

// MARK: - Cover Image View

struct CoverImageView: View {
    let itemId: String
    let width: CGFloat
    let height: CGFloat
    /// IC-2: show the whole cover (aspect-fit over a blurred copy of itself) rather than
    /// cropping it. For large covers only (Book Detail); thumbnails keep `.fill`.
    let fit: Bool

    init(itemId: String, width: CGFloat = 120, height: CGFloat = 120, fit: Bool = false) {
        self.itemId = itemId
        self.width = width
        self.height = height
        self.fit = fit
    }

    var body: some View {
        // V3 / IC-1 (30 September 2026): the radius follows the cover's size
        // (`Radius.cover(side:)`) and the edge is one cream hairline in both themes, no
        // shadow. Callers used to clip a second time at radius 6, which cut away this
        // view's own shadow and hairline at the corners; they no longer do.
        let radius = Radius.cover(side: min(width, height))
        CachedCover(url: shelfCoverURL(itemId: itemId, width: Int(width * 2)), fit: fit)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.shelfCream.opacity(0.14), lineWidth: 1))
    }
}

// MARK: - Progress Bar

struct BookProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.shelfSurface)
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.shelfAmber)
                    .frame(width: geometry.size.width * min(progress, 1.0), height: 4)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Spinner tint

extension View {
    /// LS-13 (docs/design-review.md, Round 3): the brand tint for an indeterminate
    /// `ProgressView`. Uses `shelfAmberText`, not `shelfAmber` — per the U6 note below,
    /// an indeterminate spinner's `.tint` ring IS the entire glyph (a foreground, not a
    /// fill behind ink), and raw `shelfAmber` measured 1.87:1 on `shelfBackground` in
    /// Light, under the 3:1 non-text floor. Skip this on a spinner sitting on a filled
    /// amber background, where the amber-on-amber tint would be unreadable — use the
    /// surrounding control's foreground colour there instead.
    func shelfSpinner() -> some View {
        tint(Color.shelfAmberText)
    }
}

// MARK: - Loading View

struct LoadingView: View {
    let message: LocalizedStringResource

    init(_ message: LocalizedStringResource = "Loading...") {
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                // U6 (REVIEW_2026-08-20_UI_SECURITY.md): an indeterminate `ProgressView`'s
                // `.tint` ring IS the entire glyph (a foreground, not a fill behind ink) —
                // raw `shelfAmber` measured 1.87:1 on `shelfBackground` in Light, under the
                // 3:1 non-text floor. `shelfAmberText` (no opacity — see U2) is the
                // contrast-safe foreground token for this role.
                .shelfSpinner()
                .scaleEffect(1.2)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.shelfMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Delayed progress reveal

/// Shows `content` only after it has stayed mounted, continuously, for `delay`; shows
/// `placeholder` until then. LS-12 (docs/design-review.md, Round 2): swapping straight
/// to a spinner the instant an async op starts reads as a flash rather than useful
/// feedback on a fast server — the HIG's loading guidance is to show progress only once
/// a wait is actually perceptible, not on every asynchronous hop.
///
/// The reveal timer is a `.task`, so it lives and dies with this view. Callers get "only
/// after N ms of *continuous* loading" for free simply by mounting this conditionally —
/// e.g. `if isLoading { DelayedProgressView(delay: .milliseconds(250)) { spinner } placeholder: { normalLabel } }`.
/// If the underlying condition flips back to false before `delay` elapses, this view (and
/// its pending sleep) is torn down before `visible` is ever set, so `content` never
/// appears. Planned reuse beyond the Play button (this finding): a 300 ms buffering
/// indicator and a "starting session" state.
struct DelayedProgressView<Content: View, Placeholder: View>: View {
    let delay: Duration
    let content: () -> Content
    let placeholder: () -> Placeholder

    @State private var visible = false

    init(
        delay: Duration = .milliseconds(250),
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.delay = delay
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        // Both layers stay mounted the whole time and are only crossfaded via
        // opacity, so the button/label this sits inside never changes size.
        // `accessibilityHidden` keeps VoiceOver from reading the off-screen layer
        // while it's faded out.
        ZStack {
            placeholder()
                .opacity(visible ? 0 : 1)
                .accessibilityHidden(visible)
            content()
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(!visible)
        }
        .shelfAnimation(.easeOut(duration: 0.18), value: visible)
        .task {
            do {
                try await Task.sleep(for: delay)
                visible = true
            } catch {
                // Cancelled because this view was unmounted before `delay` elapsed
                // (the caller's condition already flipped back to false) — leave
                // `visible` false; there's nothing left to reveal into.
            }
        }
    }
}

extension DelayedProgressView where Content == ProgressView<EmptyView, EmptyView>, Placeholder == EmptyView {
    /// Plain `ProgressView()` after `delay`, nothing shown before it.
    init(delay: Duration = .milliseconds(250)) {
        self.init(delay: delay, content: { ProgressView() }, placeholder: { EmptyView() })
    }
}

// No `init(delay:placeholder:)` convenience on purpose: its lone closure would compete
// with `init(delay:content:)` below for every trailing-closure call, making
// `DelayedProgressView(delay:) { … }` ambiguous. Pass both closures to the main init.
extension DelayedProgressView where Placeholder == EmptyView {
    /// Caller-supplied content after `delay`, nothing shown before it.
    init(delay: Duration = .milliseconds(250), @ViewBuilder content: @escaping () -> Content) {
        self.init(delay: delay, content: content, placeholder: { EmptyView() })
    }
}

// MARK: - Skeleton loading placeholders

/// A single placeholder tile — a square `shelfSurface` block (matching `CassetteTile`'s
/// cover) plus two skeleton text bars, with a slow pulse so a cold-launch grid reads as
/// "loading" rather than "broken". Used by both Home and Library so the very first frame
/// after launch already looks like the shape of the content that's about to arrive,
/// instead of a centered spinner that gives no sense of how much is coming.
struct SkeletonTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.shelfSurface)
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.shelfSurface)
                .frame(width: 70, height: 9)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.shelfSurface)
                .frame(width: 46, height: 8)
        }
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// A skeleton grid matching `LibraryView`'s adaptive column layout — shown while the
/// first page of items is loading.
struct SkeletonGrid: View {
    var count: Int = 8
    // LS-6 (docs/design-review.md, Round 3): the three book-grid destinations
    // (AuthorBooksView, NarratorBooksView, GenreBooksView) share this grid's column
    // config and spacing but pad the `LazyVGrid` with a flat `.padding(16)` rather
    // than Library's `.horizontal 20 / .top 8` — a parameter instead of a second,
    // near-duplicate skeleton so the skeleton→content swap doesn't shift either way.
    var padding: EdgeInsets = EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20)
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(0..<count, id: \.self) { _ in SkeletonTile() }
        }
        .padding(padding)
    }
}

/// A skeleton "shelf" — a header bar placeholder plus a horizontal row of skeleton
/// tiles — matching the shape of `CompactShelfRow` on Home.
struct SkeletonShelfRow: View {
    var tileCount: Int = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.shelfSurface)
                .frame(width: 140, height: 14)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<tileCount, id: \.self) { _ in
                        SkeletonTile().frame(width: 120)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDisabled(true)   // static placeholder — no real content to scroll to yet
        }
    }
}

/// A few stacked `SkeletonShelfRow`s, shown in place of Home's `LoadingView` while the
/// first personalized-shelves fetch is in flight.
struct SkeletonHomeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SkeletonShelfRow()
            SkeletonShelfRow()
            SkeletonShelfRow()
        }
        .padding(.top, 8)
    }
}

/// A single placeholder list row — a leading icon-slot shape plus two skeleton text
/// bars — matching the Authors/Narrators/Collections/Playlists row layout (a fixed-
/// width leading glyph, a title line, a caption-sized subtitle line). LS-6 (docs/
/// design-review.md, Round 3): those four lists loaded behind a centred `LoadingView`
/// spinner, the odd one out next to Home and Library Books' shape-matched skeletons.
/// Pulses exactly like `SkeletonTile`.
struct SkeletonListRow: View {
    /// All four rows this stands in for use a circular SF Symbol (`person.crop.circle.fill`,
    /// `mic.circle.fill`, …) in their leading slot, not a rectangular cover — `.roundedSquare`
    /// is here for a future list whose leading art is actually a cover/avatar image.
    enum LeadingArtShape {
        case circle
        case roundedSquare(cornerRadius: CGFloat = 4)
    }

    var leadingShape: LeadingArtShape = .circle
    var leadingSize: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            leadingArt
                .frame(width: 28)   // matches the real rows' `.frame(width: 28)` icon slot
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.shelfSurface)
                    .frame(width: 140, height: 11)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.shelfSurface)
                    .frame(width: 70, height: 9)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var leadingArt: some View {
        switch leadingShape {
        case .circle:
            Circle()
                .fill(Color.shelfSurface)
                .frame(width: leadingSize, height: leadingSize)
        case .roundedSquare(let cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.shelfSurface)
                .frame(width: leadingSize, height: leadingSize)
        }
    }
}

/// A `List` of `SkeletonListRow`s, matching the row insets, dividers and
/// `Color.shelfCard` row background the real Authors/Narrators/Collections/Playlists
/// lists use, so the list→content swap doesn't shift.
struct SkeletonList: View {
    var rows: Int = 8
    var leadingShape: SkeletonListRow.LeadingArtShape = .circle
    var leadingSize: CGFloat = 22

    var body: some View {
        List {
            ForEach(0..<rows, id: \.self) { _ in
                SkeletonListRow(leadingShape: leadingShape, leadingSize: leadingSize)
                    .listRowBackground(Color.shelfCard)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }
}

// MARK: - Shake detection

/// A hidden view controller that becomes first responder and reports device shakes.
/// Used for "shake to reset the sleep timer".
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let vc = ShakeViewController()
        vc.onShake = onShake
        return vc
    }

    func updateUIViewController(_ vc: ShakeViewController, context: Context) {
        vc.onShake = onShake
    }
}

final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
        super.motionEnded(motion, with: event)
    }
}

extension View {
    /// Calls `action` when the device is shaken (best-effort; relies on being in the
    /// responder chain). Attach near the app root.
    func onShake(perform action: @escaping () -> Void) -> some View {
        background(ShakeDetector(onShake: action).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    /// Optional call-to-action button (e.g. "Clear Search" / "Browse Library").
    var actionTitle: LocalizedStringResource? = nil
    var action: (() -> Void)? = nil

    init(icon: String, title: LocalizedStringResource, subtitle: LocalizedStringResource,
         actionTitle: LocalizedStringResource? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    // AX-3 (docs/design-review.md, Round 4): the glyph was a fixed
    // `.font(.system(size: 48))` that didn't grow with Dynamic Type. Base value (48)
    // is the previous literal, so default-size rendering is unchanged.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48

    // AX-3: mirrors the `min(scaled, base * factor)` cap convention used elsewhere
    // in the app (`AppLockView.cappedLockGlyphSize`, `PlayerView.cappedTransportMetric`,
    // `SettingsComponents`' `cappedRowMetric`). The glyph doesn't sit in a fixed frame
    // here (the VStack is free to grow), so there's no clipping risk either way, but
    // the cap keeps it proportional to the title rather than ballooning past what
    // still reads as an icon at the largest accessibility sizes.
    private var cappedIconSize: CGFloat {
        min(iconSize, 48 * 1.5)
    }

    var body: some View {
        // AX-3: rebuilt on `ContentUnavailableView`, Apple's iOS 17+ template for
        // this exact pattern (confirmed with `scripts/appledoc.sh` against
        // https://developer.apple.com/documentation/swiftui/contentunavailableview —
        // "Availability: iOS 17.0, ...", comfortably inside the app's 17.6 floor).
        // Its default background is transparent, so it doesn't paint over whatever
        // this is placed on.
        //
        // Title and subtitle are composed together inside the `label` closure (with
        // `description` left empty) and explicitly combined into a single VoiceOver
        // element, rather than relying on ContentUnavailableView's own label/description
        // split — the fetched documentation doesn't detail that split's accessibility
        // behaviour closely enough to trust it sight-unseen. This keeps the icon from
        // ever being its own stop and keeps the action button a distinct element.
        ContentUnavailableView {
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: cappedIconSize))
                    .foregroundStyle(Color.shelfMuted)
                    // AX-3: decorative — the title already names the state, so the
                    // symbol name must not be announced as its own stop.
                    .accessibilityHidden(true)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.shelfCream)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.shelfMuted)
                    .multilineTextAlignment(.center)
            }
            // AX-3: one VoiceOver stop for title + subtitle instead of two, with the
            // header trait carried over from the title.
            .accessibilityElement(children: .combine)
        } description: {
            EmptyView()
        } actions: {
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 20)
                        // Critique 2026-10-05 (Mini player, 2nd): 44pt minimum height (was
                        // ~38pt: subheadline + 2 x 10 padding); the whole capsule is the target.
                        .frame(minHeight: 44)
                        .background(Color.shelfAmber, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Verbatim text (Batch 400)

extension LocalizedStringResource {
    /// Text that must be shown as-is — a book, author or server name, or a string that is
    /// already localized. A string literal passed where a `LocalizedStringResource` is
    /// expected is a catalog key; a runtime value has to say so explicitly, because the
    /// `@_disfavoredOverload` `String` bridges this replaced were sometimes chosen for
    /// literals too, which kept those literals out of the String Catalog.
    static func verbatim(_ text: some StringProtocol) -> LocalizedStringResource {
        LocalizedStringResource(stringLiteral: String(text))
    }
}

/// Batch 403 (Simplified Chinese, Phase 3): Chinese and Japanese are written without
/// spaces between sentences or letter-spacing inside words. Keyed off the localization
/// the strings actually resolved to (`Bundle.main.preferredLocalizations`), not
/// `Locale.current`, so an English UI in a Chinese region stays spaced and vice versa.
enum LocalizedText {
    static var isSpacelessScript: Bool { isSpacelessScript(Bundle.main.preferredLocalizations.first) }

    /// Pure, for tests.
    static func isSpacelessScript(_ localization: String?) -> Bool {
        guard let localization else { return false }
        return localization.hasPrefix("zh") || localization.hasPrefix("ja")
    }

    /// Joins whole, already-punctuated sentences: "A. B." in English, "甲。乙。" in Chinese.
    static func sentences(_ parts: [String]) -> String {
        sentences(parts, spaceless: isSpacelessScript)
    }

    static func sentences(_ parts: [String], spaceless: Bool) -> String {
        parts.joined(separator: spaceless ? "" : " ")
    }

    /// Letter-spacing for small-caps eyebrow labels; spreading CJK characters apart
    /// reads as separate words, so they get none.
    static func tracking(_ value: CGFloat) -> CGFloat { isSpacelessScript ? 0 : value }
}
