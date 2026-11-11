import SwiftUI
import UIKit

struct LibraryView: View {
    /// Clearance for the mini-player + tab bar, measured by ContentView.
    var bottomInset: CGFloat = 0
    /// Tab-shell reconciliation (26 August 2026): bumped by `ContentView`'s
    /// `modernTabs` path when Library is re-tapped while already selected, mirroring
    /// `HomeView.scrollToTopSignal`'s exact pattern. Before this, reselecting Library
    /// on iOS 26 only reset `libraryPath` (popping any pushed navigation) but did
    /// nothing about scroll position, unlike the legacy tab shell (`legacyTabs`),
    /// where reselecting bumps `libraryReset` and fully remounts this view via
    /// `.id(...)` — a full rebuild that scrolls to the top as a side effect. Defaults
    /// to 0 so omitting it (the legacy path, and every call site before this fix) is
    /// harmless. Only wired up for the Books browse mode's own grid/list (see
    /// `topAnchorID` below) — the other five browse modes (Series/Authors/
    /// Narrators/Collections/Playlists) are each a separate view file with their own
    /// scroll container, out of scope for this pass; reselecting Library while
    /// browsing one of those still resets navigation but not scroll position.
    var scrollToTopSignal: Int = 0
    /// iPhone Duo (§3, docs/iphone-duo-readiness-2026-10-22.md): set by `ContentView`'s
    /// `librarySplitView` only at regular width (the inner display). A book tap then writes
    /// the book here for the split view's detail column instead of pushing Book Detail. Nil
    /// (compact width, and the legacy tab shell) keeps every book link a `NavigationLink`.
    var detailSelection: Binding<LibraryItem?>? = nil
    /// Critique 2026-10-05 (Library): the other five scopes now take the same signal
    /// (`ScrollsToTopOnSignal`), so the "Books only" boundary described above no longer holds.
    /// Stable anchor for the scroll-to-top above, tagged at the top of the Books
    /// grid/list content only — see `scrollToTopSignal`'s own doc comment for the
    /// explicit scope boundary.
    private static let topAnchorID = "library-top"
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(AuthViewModel.self) private var authViewModel
    /// For the `scrollToTopSignal` handling below — matches `HomeView`'s identical
    /// property and its `withAnimation(reduceMotion ? nil : ...)` pattern.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Stage 3 (REDESIGN_PROPOSAL_2026-08-26.md §2.1): lets the new ambient
    /// in-flight-downloads row below switch to the Settings tab (where download
    /// management now lives) the same way `HomeView`'s empty-state CTA already does.
    @Environment(TabRouter.self) private var tabRouter
    /// N-3 (REVIEW_2026-09-14_DESIGN.md): drives the accessibility-size fallback in
    /// `browseModeSwitcher` — a segmented control truncates badly at large Dynamic
    /// Type sizes, so this screen swaps to a `Menu` listing all six scopes instead.
    /// Same guard `LibraryFilterSheet`'s R4 fix already uses for its Smart Filter grid.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @State private var browseMode: BrowseMode = .books
    /// Observed so the per-cell download badge refreshes when a download completes.
    @State private var downloadManager = DownloadManager.shared
    /// Batch 218 (R10.9): was a one-time `NetworkMonitor.shared.isConnected` snapshot
    /// taken in `.onAppear` and never re-evaluated — a real connectivity change while
    /// this screen stayed mounted left the banner stale, out of sync with
    /// `ContentView`'s own `ConnectivityBanner`, which already observes this same
    /// `ReachabilityStore` live. Reading it directly here instead makes the two agree,
    /// and (being `@Observable`) re-renders this view whenever the status changes.
    @State private var reachability = ReachabilityStore.shared
    private var isOffline: Bool { reachability.status != .ok }
    /// "grid" (cassette tiles) or "list" (rows with swipe actions).
    @AppStorage(SettingsKeys.libraryLayout) private var libraryLayout = "grid"
    /// Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §4.1c): "comfortable" (default) or
    /// "compact" — see `columns` below for where this actually takes effect, and its
    /// own doc comment for the iPhone-only guard.
    @AppStorage(SettingsKeys.libraryGridDensity) private var libraryGridDensity = "comfortable"
    /// User feedback (26 August 2026): the old `libraryOptionsMenu` crammed Smart
    /// Filters (8 options), Sort (5 + direction), Progress filter (4), Downloaded
    /// -only, and Display (layout + density) into one cascading `Menu` — 20+ rows
    /// deep, called out directly as a "massive list." Replaced with a dedicated
    /// `LibraryFilterSheet` (below) presented from this flag instead of a `Menu`.
    @State private var showFilterSheet = false
    @State private var showUploadSheet = false
    // Code review fix (26 August 2026): doc comment said "Non-nil" — leftover from
    // when this was presumably an optional. It's a `Bool`; true while a "B-side"
    // shuffle pick is being handed to the player.
    @State private var isShufflingBSide = false
    @State private var shuffleToastMessage: String?
    /// The in-flight debounce for the server book-search — cancelled and replaced on
    /// every keystroke so rapid typing doesn't leave a pile of sleeping tasks (each
    /// individually harmless thanks to `search()`'s own generation guard, but avoidable).
    @State private var searchTask: Task<Void, Never>?
    /// Batch 490 (REVIEW 2026-11-11 L7): this account's last few submitted Titles searches,
    /// offered as search suggestions while the field is empty (`RecentLibrarySearches`).
    @State private var recentSearches: [String] = []
    /// Batch 445: Library search has two scopes in Books: the server search ("Titles") and "Ask", which
    /// answers a sentence like "a short unplayed mystery" from the whole library on device.
    @State private var searchScope: LibrarySearchScope = .titles
    @State private var moodSearch = MoodSearchViewModel()
    /// L1 (REVIEW_2026-08-20_UI_SECURITY.md): the swipe-to-remove "Remove" action used
    /// to call `downloadManager.removeDownload(itemId:)` immediately — a partial swipe
    /// is one of the easiest gestures to trigger by accident, and this was the one of
    /// three "remove a download" entry points with no confirmation (`BookDetailView`
    /// and `DownloadsView` both already confirm). Mirrors `DownloadsView`'s own
    /// item-presenting `.confirmationDialog` pattern, since (like that file) this is a
    /// list of items rather than one fixed book in scope.
    @State private var removalCandidate: LibraryItem?
    // These three rows sit in horizontal scroll views, so letting their text grow with
    // Dynamic Type just takes more scroll width rather than clipping/overlapping —
    // unlike CircularProgressView's tiny fixed-diameter badge text, which stays fixed
    // on purpose. Previously fixed `.font(.system(size:))` left them not scaling at all.
    @ScaledMetric private var modeIconSize: CGFloat = 13
    // U10 (REVIEW_2026-08-20_UI_SECURITY.md): `modeLabelSize`'s old 14pt/.semibold/
    // .rounded spec was byte-identical to `Typo.rowTitle` — removed in favor of that
    // token at its one call site below. `chipLabelSize` stays: it's still used for the
    // "×" glyph's own size in `removableChip`, only the label text migrated.
    @ScaledMetric private var chipLabelSize: CGFloat = 12
    /// Library browse plan §3.1 (2026-10-05): the scrubber stays visible and in focus order
    /// under VoiceOver (a focusable element that fades out is a trap).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    // MARK: Select mode state (Library browse plan §3.2, 2026-10-05)

    @State private var isSelecting = false
    /// Selected book ids. A `Set` of ids, so a selection survives a scrubber jump and page
    /// eviction (plan §3.2 "Scrubber", §6.4).
    @State private var selection: Set<String> = []
    /// Side table filled at selection time, so an action can still reach a selected book
    /// whose page was evicted (plan §6.4).
    @State private var selectedItemsById: [String: LibraryItem] = [:]
    @State private var showMarkFinishedConfirm = false
    @State private var pendingDownloadPlan: BulkDownloadPlan?
    @State private var isMarkingFinished = false
    @State private var markingCount = 0
    /// Refusals and failures from a bulk action (plan §3.2): one message, error style.
    @State private var bulkErrorMessage: String?
    /// "Marked 12 finished" with Undo (plan §3.2 "Undo"), and the snapshots it restores.
    @State private var finishUndoMessage: String?
    @State private var finishUndoSnapshots: [LibraryProgressSnapshot] = []

    // MARK: Scroll state (Library browse plan §3.1, §6.3, 2026-10-05)

    /// Top visible slot and "is scrolling", held in a small observable object so only the
    /// scrubber overlay re-renders as the top row changes, not this whole body.
    @State private var scroll = LibraryScrollTracker()
    /// Width of the Books content, for the adaptive grid's real column count (row snapping).
    @State private var contentWidth: CGFloat = 0
    /// iPhone Duo (§5): an active `.division` reserved region (the fold, iOS 27.1) runs
    /// top to bottom through the Books content. See `foldSplitsVertically(_:)`.
    @State private var foldSplitsGrid = false
    /// Bumped on a sort, filter or library change: the Books grid/list returns to the top
    /// without animation (plan §5 "Sort, filter or library change").
    @State private var resetScrollSignal = 0

    /// The local download set the Books composition needs, or nothing when it doesn't.
    private var downloadsForDisplay: [LibraryItem] {
        libraryViewModel.showsLocalDownloads ? downloadManager.downloadedLibraryItems() : []
    }

    /// Library browse plan §6.2 (2026-10-05): the one window the Books grid and list render,
    /// whether server-paged or a local set (smart filter, Downloaded, offline fallback,
    /// Recently Played) wrapped as a fully loaded window.
    private var booksWindow: LibraryPageWindow {
        libraryViewModel.displayWindow(downloads: downloadsForDisplay)
    }

    // Adaptive so iPad / landscape fill with more columns instead of two huge covers.
    //
    // Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §4.1c): Compact is deliberately
    // iPhone-only (`UIDevice.current.userInterfaceIdiom == .phone`), not a
    // horizontal-size-class check — iPad is `.regular` in some multitasking
    // layouts too, and the proposal's own arithmetic explicitly calls out that iPad
    // needs its own density curve rather than inheriting whatever an iPhone option
    // computes to. At `minimum: 96`, the narrowest supported iPhone (SE, 375pt,
    // `Space.pageH` margins + 16pt inter-column spacing) solves to 3 columns with a
    // 12pt clearance margin — `100` (the number in the proposal's own worked
    // arithmetic) would have cleared by only 3pt, close enough that a future 2pt
    // change to `Space.pageH` or this spacing could silently drop the SE back to 2
    // columns; `96` buys real headroom for the identical visual result.
    private var columns: [GridItem] {
        // iPhone Duo (§5): Apple's iPhone Duo guidance, "If your layout is a grid, use an
        // even number of columns so your content divides cleanly at the fold". With the
        // fold across the grid and an odd adaptive count, drop to the even count below it.
        if foldSplitsGrid, let even = foldEvenColumnCount {
            let compact = UIDevice.current.userInterfaceIdiom == .phone && libraryGridDensity == "compact"
            return Array(repeating: GridItem(.flexible(minimum: compact ? 96 : 150), spacing: 16), count: even)
        }
        if UIDevice.current.userInterfaceIdiom == .phone && libraryGridDensity == "compact" {
            return [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 16)]
        }
        return [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]
    }

    /// Only the modes this library actually has. A mode is shown while its data is still
    /// loading (unknown) and hidden once it's confirmed empty, so chips don't flicker out.
    private var availableModes: [BrowseMode] {
        var modes: [BrowseMode] = [.books]
        // UI-11 (REVIEW_2026-08-12.md): `seriesLoaded`/`collectionsLoaded`/
        // `playlistsLoaded` are deliberately still set `true` on a genuine load
        // failure too (see `LibraryViewModel.loadSeries()` etc.) so this "hide once
        // confirmed empty" check doesn't churn retrying forever — but that means a
        // failed load looks exactly like "confirmed empty" here, and would hide the
        // tab entirely, permanently burying the new Retry state those views now show.
        // The `xLoadFailed` flags added alongside `xLoaded` keep the tab visible
        // specifically for that failure case, so it stays reachable.
        if !libraryViewModel.seriesLoaded || !libraryViewModel.seriesList.isEmpty || libraryViewModel.seriesLoadFailed {
            modes.append(.series)
        }
        let fd = libraryViewModel.filterData
        // `authors`/`narrators` are optional arrays; treat "unknown" (fd nil) as
        // available — this also already covers a `loadFilterData()` failure, since
        // `filterData` stays `nil` in that case too (unlike the three `xLoaded` flags
        // above, nothing here ever flips to "confirmed empty" on failure).
        if fd == nil || !((fd?.authors ?? []).isEmpty) { modes.append(.authors) }
        if fd == nil || !((fd?.narrators ?? []).isEmpty) { modes.append(.narrators) }
        if !libraryViewModel.collectionsLoaded || !libraryViewModel.collections.isEmpty || libraryViewModel.collectionsLoadFailed {
            modes.append(.collections)
        }
        if !libraryViewModel.playlistsLoaded || !libraryViewModel.playlists.isEmpty || libraryViewModel.playlistsLoadFailed {
            modes.append(.playlists)
        }
        return modes
    }

    /// N-3 (REVIEW_2026-09-14_DESIGN.md): pure classification of a `BrowseMode` as a
    /// "primary" scope (shown as a segment in `browseModeSwitcher`'s default-size
    /// layout) vs. a "secondary" one (reachable only from the compact trailing
    /// `moreScopesMenu`). PM call: Books/Series/Authors/Narrators are the primary,
    /// high-frequency scopes; Collections/Playlists are secondary. Pulled out as a
    /// static, `availableModes`-independent function — this project's convention
    /// (see `DownloadManager.shouldReclaimOrphanDirectory`) is to extract a pure
    /// decision like this one so it can be pinned with a unit test
    /// (`LibraryScopeControlTests`) rather than only exercised through the view.
    static func isPrimaryScope(_ mode: BrowseMode) -> Bool {
        switch mode {
        case .books, .series, .authors, .narrators:
            return true
        case .collections, .playlists:
            return false
        }
    }

    // MARK: - Select mode copy (Library browse plan §3.2, 2026-10-05; pinned by LibrarySelectionCopyTests)

    /// The three bulk actions in the select-mode bar. Glyphs match the swipe actions and
    /// `BookContextMenu`.
    enum BulkAction: CaseIterable {
        case upNext, download, markFinished

        /// The short visible label under the glyph.
        var title: String {
            switch self {
            case .upNext: return String(localized: "Up Next", comment: "Bulk action label under the glyph in the Library select-mode bar: add the selected books to the Up Next queue")
            case .download: return String(localized: "Download", comment: "Bulk action label under the glyph in the Library select-mode bar (verb)")
            case .markFinished: return String(localized: "Mark Finished", comment: "Bulk action label under the glyph in the Library select-mode bar")
            }
        }

        var systemImage: String {
            switch self {
            case .upNext: return "text.badge.plus"
            case .download: return "arrow.down.circle"
            case .markFinished: return "checkmark.circle"
            }
        }
    }

    /// The nav title while selecting, the Photos convention: "Select Books", "1 Book",
    /// "12 Books" (short, per HIG Toolbars' title guidance).
    static func selectionTitle(count: Int) -> String {
        switch count {
        case ..<1: return String(localized: "Select Books", comment: "Library navigation title while in select mode with nothing selected")
        case 1: return String(localized: "1 Book", comment: "Library navigation title in select mode with one book selected")
        default: return String(localized: "\(count) Books", comment: "Library navigation title in select mode; %lld is the number of selected books")
        }
    }

    /// "1 book" / "12 books", the count phrase the select-mode sentences below embed.
    private static func booksPhrase(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 book", comment: "Count phrase for exactly one book, embedded in select-mode sentences")
            : String(localized: "\(count) books", comment: "Count phrase for several books, embedded in select-mode sentences; %lld is the count")
    }

    /// The spoken label for a bulk action, carrying the count ("Download 12 books").
    /// With nothing selected it is the plain action name.
    static func bulkActionLabel(_ action: BulkAction, count: Int) -> String {
        let books = booksPhrase(count)
        switch action {
        case .upNext: return count < 1
            ? String(localized: "Add to Up Next", comment: "Accessibility label for the bulk Up Next action with nothing selected")
            : String(localized: "Add \(books) to Up Next", comment: "Accessibility label for the bulk Up Next action; %@ is a count phrase like '12 books'")
        case .download: return count < 1
            ? String(localized: "Download", comment: "Accessibility label for the bulk Download action with nothing selected (verb)")
            : String(localized: "Download \(books)", comment: "Accessibility label for the bulk Download action; %@ is a count phrase like '12 books'")
        case .markFinished: return count < 1
            ? String(localized: "Mark Finished", comment: "Accessibility label for the bulk Mark Finished action with nothing selected")
            : String(localized: "Mark \(books) finished", comment: "Accessibility label for the bulk Mark Finished action; %@ is a count phrase like '12 books'")
        }
    }

    /// "Mark 12 books finished?" (plan §3.2 "Confirm").
    static func markFinishedConfirmTitle(count: Int) -> String {
        String(localized: "Mark \(booksPhrase(count)) finished?", comment: "Confirmation dialog title; %@ is a count phrase like '12 books'")
    }

    /// The destructive button, Series detail's wording: "Mark 12 Finished".
    static func markFinishedConfirmButton(count: Int) -> String {
        String(localized: "Mark \(count) Finished", comment: "Destructive confirmation button; %lld is the number of books")
    }

    /// "This updates 12 books on the server. 3 are in progress — their positions will be
    /// replaced. You can undo this right after." The in-progress sentence is left out when
    /// nothing would lose a position (PRODUCT.md principle 2: say what will be lost).
    static func markFinishedConfirmMessage(count: Int, inProgress: Int) -> String {
        // Whole sentences, so each can be translated (and re-ordered) on its own.
        var sentences = [String(localized: "This updates \(booksPhrase(count)) on the server.", comment: "Mark Finished confirmation, first sentence; %@ is a count phrase like '12 books'")]
        let started = min(max(inProgress, 0), max(count, 0))
        if started == 1 {
            sentences.append(count == 1
                ? String(localized: "It\u{2019}s in progress \u{2014} its position will be replaced.", comment: "Mark Finished confirmation: the single selected book is in progress")
                : String(localized: "1 is in progress \u{2014} its position will be replaced.", comment: "Mark Finished confirmation: one of several selected books is in progress"))
        } else if started > 1 {
            sentences.append(String(localized: "\(started) are in progress \u{2014} their positions will be replaced.", comment: "Mark Finished confirmation: several selected books are in progress; %lld is how many"))
        }
        sentences.append(String(localized: "You can undo this right after.", comment: "Mark Finished confirmation, last sentence"))
        return LocalizedText.sentences(sentences)
    }

    /// The Undo toast after a bulk Mark Finished. A partial failure says how many didn't
    /// update; those stay selected for Try Again (plan §3.2 "Partial failure").
    static func markedFinishedToast(succeeded: Int, failed: Int) -> String {
        if failed > 0 {
            return String(localized: "Marked \(succeeded) finished. \(booksPhrase(failed)) couldn\u{2019}t be updated. Try again.", comment: "Toast after a partly failed bulk Mark Finished; first %lld is how many succeeded, %@ is a count phrase like '2 books' for the failures")
        }
        return String(localized: "Marked \(succeeded) finished", comment: "Toast after a bulk Mark Finished; %lld is the number of books")
    }

    /// Nothing updated at all: "2 books couldn't be updated. Try again."
    static func bulkFinishFailureMessage(count: Int) -> String {
        String(localized: "\(booksPhrase(count)) couldn\u{2019}t be updated. Try again.", comment: "Bulk Mark Finished failed entirely; %@ is a count phrase like '2 books'")
    }

    /// Undo didn't restore every book. Each one is still undoable from Recent Changes
    /// (Critique 2026-10-06 (harden): the screen's new name, was "Playback History").
    static func undoFailureMessage(count: Int) -> String {
        String(localized: "Couldn\u{2019}t undo \(booksPhrase(count)). Try again from Recent Changes.", comment: "Undo of bulk Mark Finished failed; %@ is a count phrase like '2 books'. 'Recent Changes' is a screen name")
    }

    /// "Download 12 books?" (plan §3.2 "Bulk Download limits").
    static func downloadConfirmTitle(count: Int) -> String {
        // Batch 400: the same keys `BulkDownloadPlan.summary` opens with, so
        // `downloadConfirmDetail` can strip it in every language, not only English.
        count == 1 ? String(localized: "Download 1 book?")
                   : String(localized: "Download \(count) books?", comment: "Bulk download confirmation. %lld is the number of books (2 or more)")
    }

    /// `BulkDownloadPlan.summary` minus its leading question (which is the dialog title),
    /// so the dialog doesn't say it twice. Falls back to the whole summary.
    static func downloadConfirmDetail(summary: String, count: Int) -> String {
        let title = downloadConfirmTitle(count: count)
        guard summary.hasPrefix(title) else { return summary }
        return String(summary.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The line above the action bar: progress while marking, the reason while offline,
    /// nothing otherwise.
    static func selectionStatusLine(isMarkingFinished: Bool, markingCount: Int, serverReachable: Bool) -> String? {
        if isMarkingFinished {
            return String(localized: "Marking \(booksPhrase(markingCount)) finished\u{2026}", comment: "Status line while bulk Mark Finished runs; %@ is a count phrase like '12 books'")
        }
        if !serverReachable { return String(localized: "Offline. Download and Mark Finished need your server.", comment: "Status line above the select-mode action bar when offline") }
        return nil
    }

    /// The primary scopes this library actually has, in `BrowseMode`'s declared order.
    /// Filtered through `availableModes` so a library that hasn't got (say) Narrators
    /// yet still doesn't show an empty segment.
    private var primaryModes: [BrowseMode] {
        availableModes.filter { Self.isPrimaryScope($0) }
    }

    /// The secondary scopes (Collections/Playlists) this library actually has —
    /// reachable from `moreScopesMenu` instead of a segment. Empty when the current
    /// library has neither (the menu hides itself in that case).
    private var secondaryModes: [BrowseMode] {
        availableModes.filter { !Self.isPrimaryScope($0) }
    }

    /// Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §4.1b): identical reasoning and
    /// implementation to `SettingsView.searchPlacement` — this screen hardcoded
    /// `.navigationBarDrawer(.always)` for the same reason that file's own comment
    /// documents (avoiding a collision with the legacy custom bottom bar), which means
    /// it never got iOS 26's collapsing floating search field either. Duplicated
    /// rather than shared: it's a two-line computed property, and sharing it would mean
    /// introducing a cross-file dependency for something this small.
    private var searchPlacement: SearchFieldPlacement {
        if #available(iOS 26.0, *) {
            return .automatic
        }
        return .navigationBarDrawer(displayMode: .always)
    }

    private var searchPrompt: String {
        switch browseMode {
        case .books where searchScope == .ask:
            return String(localized: "Try \u{201C}a short unplayed mystery\u{201D}", comment: "Library search field prompt, Ask scope")
        case .books:       return String(localized: "Search books, authors, series…", comment: "Library search field prompt, Books scope")
        case .series:      return String(localized: "Search series", comment: "Library search field prompt, Series scope")
        case .authors:     return String(localized: "Search authors", comment: "Library search field prompt, Authors scope")
        case .narrators:   return String(localized: "Search narrators", comment: "Library search field prompt, Narrators scope")
        case .collections: return String(localized: "Search collections", comment: "Library search field prompt, Collections scope")
        case .playlists:   return String(localized: "Search playlists", comment: "Library search field prompt, Playlists scope")
        }
    }

    var body: some View {
        selectModeChrome(mainContent)
    }

    private var mainContent: some View {
        // NavigationStack provided by ContentView (see HomeView note) so the
        // mini-player/tab-bar inset propagates into the grid correctly.
        return ZStack {
            // No .ignoresSafeArea() (see HomeView note) so the grid's ScrollView
            // keeps its bottom safe-area inset and clears the mini-player. The
            // full-bleed fill is the `.background(...)` on this ZStack instead.
            Color.shelfBackground

                VStack(spacing: 0) {
                    if isOffline && !libraryViewModel.downloadedOnly && libraryViewModel.itemsSource == .server {
                        // Critique 2026-10-05 (Library): the full-width amber "Offline" bar
                        // duplicated the root `ConnectivityBanner` (which already says
                        // offline vs. server unreachable and outranks the player). What's
                        // left is only the action the banner can't offer: a neutral,
                        // user-initiated "Show downloads" (amber is for live state, and an
                        // offline notice isn't an action). Deliberately a tap, not
                        // automatic — Batch 218 (R10.9) removed the automatic version.
                        Button {
                            Haptics.selection()
                            // Critique 2026-10-05 (Library, 2nd): one intent that also drops a
                            // smart filter, so no chip claims a filter that isn't applied. The
                            // row also hides once the load itself fell back to downloads.
                            libraryViewModel.showDownloads()
                        } label: {
                            Typo.supporting(HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                Text("Show downloads")
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .scaledFont(11, weight: .semibold, relativeTo: .caption)
                            }, weight: .medium)
                            .foregroundStyle(Color.shelfCream)
                            .padding(.horizontal, Space.pageH)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.shelfSurface)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show downloads")
                        .accessibilityHint("You're offline. Filters the library to books on this device.")
                    }

                    librarySubtitle

                    // Reverted per user feedback (26 August 2026): Stage 4 had replaced
                    // this permanent chip row with a `ToolbarItem(.principal)` title
                    // menu (see the removed comment that used to sit where
                    // `browseModeSwitcher` is defined below). The user said the old
                    // Library tab looked nicer, so the chip row is back and the title
                    // menu is gone.
                    // LG-5 (V5): on iOS 26+ the scope picker lives in a `safeAreaBar` at the
                    // top (see `libraryScopeBar` below) so it joins the bar region.
                    if !usesScopeBar {
                        browseModeSwitcher
                    }

                    if browseMode == .books {
                        activeFilterChips
                        booksCountLine
                    }

                    // Pass 3 item 3's hard bottom scroll edge (Batch 290) hung off this
                    // `Group`; reverted on user report (4 Sep 2026) — the solid band
                    // misbehaved as it regrew, and see-through is preferred.
                    Group {
                        switch browseMode {
                        case .books:
                            booksContent
                        case .series:
                            SeriesBrowseView(bottomInset: bottomInset, search: searchText, scrollToTopSignal: scrollToTopSignal)
                        case .authors:
                            AuthorsBrowseView(search: searchText, scrollToTopSignal: scrollToTopSignal)
                        case .narrators:
                            NarratorsBrowseView(search: searchText, scrollToTopSignal: scrollToTopSignal)
                        case .collections:
                            CollectionsBrowseView(search: searchText, scrollToTopSignal: scrollToTopSignal)
                        case .playlists:
                            PlaylistsBrowseView(search: searchText, scrollToTopSignal: scrollToTopSignal)
                        }
                    }
                }
                // Library browse plan §3.2 (2026-10-05): the select-mode action bar sits at
                // the bottom, in Casey's reach, and insets the grid/list above it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isSelecting && browseMode == .books {
                        LibrarySelectionBar(
                            selected: selectedItemsInOrder(booksWindow),
                            showsDownload: !libraryViewModel.downloadedOnly,
                            serverReachable: !isOffline,
                            isMarkingFinished: isMarkingFinished,
                            markingCount: markingCount,
                            onUpNext: performUpNext,
                            onDownload: performDownload,
                            onMarkFinished: { showMarkFinishedConfirm = true }
                        )
                        // Anchored on the bar so the iPad/iOS 26 popover points at the
                        // button that asked, not the top of the screen (sim check, Batch 375).
                        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
                        // Plan §3.2 "Mark Finished: confirm, then undo" (HIG Action sheets: destructive
                        // choice prominent). Same wording family as Series detail.
                        .confirmationDialog(
                            Self.markFinishedConfirmTitle(count: (isSelecting ? selection.count : 0)),
                            isPresented: $showMarkFinishedConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(Self.markFinishedConfirmButton(count: (isSelecting ? selection.count : 0)), role: .destructive) {
                                performMarkFinished()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(Self.markFinishedConfirmMessage(
                                count: (isSelecting ? selection.count : 0),
                                inProgress: showMarkFinishedConfirm
                                    ? libraryViewModel.inProgressCount(of: selectedItemsInOrder(booksWindow)) : 0
                            ))
                        }
                        .systemChromeTint()
                        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
                        // Plan §3.2 "Bulk Download limits": confirm above 5 books, with the size.
                        .confirmationDialog(
                            Self.downloadConfirmTitle(count: pendingDownloadPlan?.toDownload.count ?? 0),
                            isPresented: Binding(get: { pendingDownloadPlan != nil },
                                                 set: { if !$0 { pendingDownloadPlan = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDownloadPlan
                        ) { plan in
                            Button("Download \(plan.toDownload.count)") { startDownloads(plan) }
                            Button("Cancel", role: .cancel) {}
                        } message: { plan in
                            Text(Self.downloadConfirmDetail(summary: plan.summary, count: plan.toDownload.count))
                        }
                        .systemChromeTint()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .shelfAnimation(.easeInOut(duration: 0.25), value: isSelecting)
            }
            // Black bar behind the bottom pills (user report, real device, iOS 26; Batch 307):
            // the 139pt strip under the floating tab bar + accessory — the bottom
            // safe-area inset the bare `Color` above deliberately doesn't cover — showed
            // the system `TabView`/`NavigationStack` host's opaque `systemBackground`
            // wherever the scrolled content wasn't opaque. Worst in list mode: `List` +
            // `.scrollContentBackground(.hidden)` + `.listRowBackground` paint only the
            // rows, so the whole strip was solid black there. See `HomeView`'s identical
            // fix for the measured account. This must stay on the outermost ZStack (not
            // on the `List`), and it's a `.background` rather than `.ignoresSafeArea()`
            // on the fill above so the grid keeps the bottom inset the note above is about.
            .background(Color.shelfBackground.ignoresSafeArea())
            .libraryScopeBar(enabled: usesScopeBar) { browseModeSwitcher }
            // Reverted per user feedback (26 August 2026): Stage 4 had switched this
            // to `browseMode.rawValue` so the principal-toolbar title menu could show
            // the current mode as the visible nav title. With that menu gone (see
            // `browseModeSwitcher` below), the title goes back to the static "Library".
            // Library browse plan §3.2: "Select Books" / "1 Book" / "12 Books" while selecting.
            .navigationTitle(isSelecting ? Self.selectionTitle(count: selection.count) : String(localized: "Library", comment: "Navigation title of the Library tab"))
            .navigationBarTitleDisplayMode(.inline)
            // Batch 218 (R10.9): this `.onAppear` used to force `downloadedOnly =
            // true` the moment the screen appeared offline — a silent mutation of
            // the user's own filter choice that, combined with the removable
            // "Downloaded ×" chip (`activeFilterChips`), meant tapping that chip
            // while genuinely offline could empty the visible library with no
            // obvious cause. `isOffline` above is now just the informational
            // banner; it no longer changes what's actually being filtered.
            // Front-load the light browse lists so we know which modes to show.
            .task { await libraryViewModel.loadBrowseAvailability() }
            // The initial library often isn't selected yet when the view first appears
            // (so the front-load above no-ops). Re-run once a library is set, otherwise the
            // Collections/Playlists chips linger until the mode is visited.
            .onChange(of: libraryViewModel.selectedLibrary?.id) { _, id in
                if id != nil { Task { await libraryViewModel.loadBrowseAvailability() } }
            }
            // Search now shows on every mode. In Books it runs a server search; in the other
            // modes the query is passed into the browse view and filters its list by name.
            .searchable(text: $searchText,
                        placement: searchPlacement,
                        prompt: searchPrompt)
            // Batch 445 (HIG Searching: scopes narrow the search; shown while searching). Books only.
            .searchScopes($searchScope) {
                if browseMode == .books {
                    Text("Titles").tag(LibrarySearchScope.titles)
                    Text("Ask").tag(LibrarySearchScope.ask)
                }
            }
            // Batch 490 (REVIEW 2026-11-11 L7): suggestions while the field is empty — recent
            // Titles searches (with Clear), or three example sentences in Ask (HIG Searching).
            .searchSuggestions { searchSuggestionRows }
            // Ask is a sentence, so it runs on Search (return), not per keystroke.
            .onSubmit(of: .search) {
                runAskIfNeeded()
                // Batch 490 (REVIEW 2026-11-11 L7): remember a submitted Titles search.
                if browseMode == .books, searchScope == .titles {
                    recentSearches = RecentLibrarySearches.record(searchText)
                }
            }
            .task(id: libraryViewModel.selectedLibrary?.id) {
                // Batch 490 (REVIEW 2026-11-11 L7): per account, so reload after a switch.
                recentSearches = RecentLibrarySearches.load()
            }
            .onChange(of: searchScope) { _, scope in
                searchTask?.cancel()
                moodSearch.reset()
                if scope == .ask {
                    libraryViewModel.searchQuery = ""
                    runAskIfNeeded()
                } else if browseMode == .books, !searchText.isEmpty {
                    libraryViewModel.searchQuery = searchText
                    Task { await libraryViewModel.search() }
                }
            }
            .onChange(of: libraryViewModel.selectedLibrary?.id) { _, _ in
                moodSearch.invalidateSnapshot()
                // Review Low (search after library switch, 30 October 2026): the query and
                // results were for the old library; clear the field (the view model clears
                // its results in `selectLibrary`).
                searchTask?.cancel()
                moodSearch.reset()
                if !searchText.isEmpty { searchText = "" }
            }
            .onChange(of: searchText) { _, newValue in
                // Plan §11: no select mode in search; starting a search leaves it.
                if !newValue.isEmpty { exitSelectMode() }
                // Batch 490 (REVIEW 2026-11-11 L7): picking an Ask example fills the field;
                // run it at once rather than waiting for a Search tap.
                if browseMode == .books, searchScope == .ask,
                   RecentLibrarySearches.askExamples.contains(newValue) {
                    runAskIfNeeded()
                    return
                }
                // Only the server book-search is debounced here; other modes filter locally.
                guard browseMode == .books, searchScope == .titles else { return }
                searchTask?.cancel()
                libraryViewModel.searchQuery = newValue
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
                    guard !Task.isCancelled, libraryViewModel.searchQuery == newValue else { return }
                    await libraryViewModel.search()
                }
            }
            .onDisappear {
                searchTask?.cancel()
                // Plan §3.2: leaving the tab leaves select mode (nothing can be pushed while
                // selecting, so a disappear here is the tab going away).
                exitSelectMode()
            }
            .onChange(of: browseMode) { _, mode in
                exitSelectMode()
                // Batch 445: Ask is Books-only; other modes have no scope bar to leave it.
                if mode != .books && searchScope == .ask {
                    searchScope = .titles
                    moodSearch.reset()
                }
                // Returning to Books with an active query — run the book search now.
                if mode == .books && !searchText.isEmpty && searchScope == .titles {
                    libraryViewModel.searchQuery = searchText
                    Task { await libraryViewModel.search() }
                }
            }
            // N-6 (Batch 319) / Critique 2026-10-05 (Library): Home's Smart Filters shelf and
            // the `shelfhead://library?smartFilter=` deep link ask for Books scope via
            // `LibraryViewModel.requestedBrowseMode`. This consumer used to hang off
            // `libraryListView` only, so it never ran in grid layout or while another scope
            // (Series, Authors, ...) was showing. It lives on the always-present container
            // now. `onAppear` covers a request set before this view mounted (a fresh
            // remount on the legacy tab shell), which `onChange` alone never sees.
            .onChange(of: libraryViewModel.requestedBrowseMode) { _, _ in consumeRequestedBrowseMode() }
            .onAppear { consumeRequestedBrowseMode() }
            // Batch 490 (REVIEW 2026-11-11 F14): `shelfhead://search?q=` fills the search field.
            .onChange(of: libraryViewModel.requestedSearchText) { _, _ in consumeRequestedSearchText() }
            .onAppear { consumeRequestedSearchText() }
            .onChange(of: availableModes) { _, modes in
                // If the current mode turns out not to exist, fall back to Books.
                if !modes.contains(browseMode) { browseMode = .books }
            }
            // Batch 447: Upload from the Library bar, not only Settings › Account & Security.
            .sheet(isPresented: $showUploadSheet) {
                UploadSheet(onOpenLibrary: { id in
                    guard let library = libraryViewModel.libraries.first(where: { $0.id == id }) else { return }
                    Task { await libraryViewModel.selectLibrary(library) }
                })
            }
            // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
            .toolbar {
                // Batch 447: "+" adds books to the server, for accounts with the upload permission.
                // Books mode only, and out of the way while selecting or searching. Low priority so on
                // iPhone Duo it overflows before Select and the options button.
                ToolbarItem(placement: .topBarTrailing) {
                    if browseMode == .books, !isSelecting, searchText.isEmpty,
                       authViewModel.currentUser?.canUpload == true {
                        Button {
                            showUploadSheet = true
                        } label: {
                            Label("Upload Books", systemImage: "plus")
                        }
                        .monochromeToolbarItem()
                        .accessibilityHint("Sends audiobook or ebook files from this device to your server")
                    }
                }
                .shelfVisibilityPriority(.low)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if browseMode == .books && isSelecting {
                        // Plan §3.2: the trailing button becomes Done. Monochrome on every
                        // version (Monochrome Chrome Rule), semibold as the bar's one primary action.
                        // iPhone Duo (§2): a symbol so the item reaches the vertical bar.
                        Button {
                            Haptics.selection()
                            exitSelectMode()
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                        .fontWeight(.semibold)
                        .monochromeToolbarItem()
                    } else if browseMode == .books {
                        // Plan §3.2: "Select" is text (HIG Toolbars: edit-like actions aren't
                        // well represented by symbols). Hidden while searching (§11).
                        if searchText.isEmpty {
                            Button {
                                Haptics.selection()
                                enterSelectMode(with: nil)
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            .monochromeToolbarItem()
                            .disabled(!canEnterSelectMode)
                            .accessibilityHint("Choose several books to act on at once")
                        }
                        // Design review (14 Aug 2026), item 3: this nav bar used to have
                        // four icon-only trailing controls (grid/list, shuffle, smart
                        // filters, sort/filter) plus the library switcher and a browse-
                        // mode switcher below — seven ways to change what you're looking
                        // at. B-side (the app's best small feature) got a real labelled
                        // home instead of the bare `shuffle` glyph (see `bSideButton`),
                        // and the display toggle + both filter menus collapsed into one
                        // menu with sections — a display preference doesn't need its own
                        // permanent nav bar icon, and smart filters/sort/progress filter/
                        // downloaded-only are all answers to the same question ("what am
                        // I looking at"). Redesigned again per direct user feedback
                        // (26 August 2026) — see `libraryOptionsButton`'s own doc
                        // comment: same merged scope, now a dedicated sheet
                        // (`LibraryFilterSheet`) instead of one giant cascading menu.
                        libraryOptionsButton
                    }
                }
                .shelfVisibilityPriority(.high) // iPhone Duo (§2): Select/Done + sort & filter stay in the bar
                ToolbarItemGroup(placement: .topBarLeading) {
                    if isSelecting {
                        // Plan §11 Q3 (C): only for a local result set of 200 or fewer. The
                        // Downloads badge and library switcher hide while selecting (§3.2).
                        if libraryViewModel.canSelectAll(downloads: downloadsForDisplay) {
                            Button { toggleSelectAll() } label: {
                                Label(allLoadedSelected ? "Deselect All" : "Select All",
                                      systemImage: allLoadedSelected ? "circle" : "checkmark.circle")
                            }
                            .monochromeToolbarItem()
                        }
                    } else {
                        // 16 September 2026 (user request): Downloads' designated home in the
                        // Library nav bar now that the tab is gone — always present, with the
                        // in-flight/failed count badged on it, opening the dedicated
                        // `DownloadsView` (books); settings stay under its gear. Reads of `activeDownloads`/
                        // `failedDownloads` stay inside `DownloadActivityBadge`'s own body.
                        DownloadActivityBadge(bottomInset: bottomInset)
                        if libraryViewModel.libraries.count > 1 {
                            Menu {
                                ForEach(libraryViewModel.libraries) { library in
                                    Button {
                                        Task { await libraryViewModel.selectLibrary(library) }
                                    } label: {
                                        HStack {
                                            Text(library.name)
                                            if library.id == libraryViewModel.selectedLibrary?.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                // Batch 218 (R10.7): was `building.columns.fill` — a
                                // different glyph than `HomeView`'s identical "switch
                                // library" menu, which uses `square.stack.fill`. Same
                                // action, same icon now.
                                Label("Switch library", systemImage: "square.stack.fill")
                            }
                            .monochromeToolbarItem()
                        }
                    }
                }
                .shelfVisibilityPriority(.high) // iPhone Duo (§2): Downloads never overflows
            }
            // UX-4 audit (Batch 355): the library error alert moved to `MainTabView`, its one
            // owner; this tab and Home both used to present it.
            // iPhone Duo (§3): resolves `LibraryRouteLink`'s value links, so Library's pushed
            // screens stay in the split view's sidebar on the inner display. The selection is
            // passed on explicitly: the `libraryDetailSelection` that `ContentView` sets on the
            // sidebar's stack didn't reach these destinations, so their `BookLink`s fell back
            // to a `NavigationLink` that only filled the detail column once.
            .navigationDestination(for: LibraryRoute.self) {
                $0.destination(bottomInset: bottomInset)
                    .environment(\.libraryDetailSelection, detailSelection)
            }
            .toast(message: $shuffleToastMessage, style: .info, bottomInset: bottomInset)
            // L1 (REVIEW_2026-08-20_UI_SECURITY.md): same confirmation
            // `DownloadsView`/`BookDetailView` already show before deleting a download.
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .confirmationDialog(
                RemoveDownloadConfirmation.title,
                isPresented: Binding(get: { removalCandidate != nil },
                                     set: { if !$0 { removalCandidate = nil } }),
                titleVisibility: .visible,
                presenting: removalCandidate
            ) { item in
                Button(RemoveDownloadConfirmation.button, role: .destructive) {
                    downloadManager.removeDownload(itemId: item.id)
                    Haptics.impact(.medium)
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(RemoveDownloadConfirmation.message(title: item.title))
            }
            .systemChromeTint()
            .reexpandsTabBarOnAppear()
    }

    // MARK: - Select mode chrome (Library browse plan §3.2, 2026-10-05)

    /// Everything select mode adds around the Library: the tab-bar signals, the Mark
    /// Finished and Download confirmations, the Undo toast, and the exit triggers. Kept off
    /// `mainContent`'s long modifier chain so each half type-checks on its own.
    private func selectModeChrome<Content: View>(_ content: Content) -> some View {
        content
            // Step 10's contract: the legacy `RetroTabBar` hides while this is true.
            .preference(key: LibrarySelectingPreferenceKey.self, value: isSelecting)
            // The iOS 26 native `TabView` (`toolbar(_:for:)`, iOS 16.0). A no-op on the legacy
            // shell, which has no system tab bar.
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            // Plan §3.2 "Undo": 6 s, and under VoiceOver it persists with focus on Undo
            // (the mini player's Undo pattern, built into `toast(action:)`).
            .toast(message: $finishUndoMessage, style: .success, duration: 6, bottomInset: bottomInset,
                   action: ToastAction(label: "Undo") { undoMarkFinished() })
            .toast(message: $bulkErrorMessage, duration: 4, bottomInset: bottomInset)
            // Exit triggers (plan §3.2 "Reach", §5): sort, filter or account change.
            .onChange(of: libraryViewModel.sortOption) { _, _ in queryChanged() }
            .onChange(of: libraryViewModel.sortDescending) { _, _ in queryChanged() }
            .onChange(of: libraryViewModel.progressFilter) { _, _ in queryChanged() }
            .onChange(of: libraryViewModel.downloadedOnly) { _, _ in queryChanged() }
            .onChange(of: libraryViewModel.smartFilter) { _, _ in queryChanged() }
            .onChange(of: libraryViewModel.selectedLibrary?.id) { _, _ in queryChanged() }
            .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
                exitSelectMode()
                scroll.reset()
            }
    }

    /// A different result set: leave select mode and go back to the top (plan §5).
    private func queryChanged() {
        exitSelectMode()
        scroll.reset()
        resetScrollSignal &+= 1
    }

    // MARK: - Select mode (Library browse plan §3.2, 2026-10-05)

    /// Select is offered in Books scope with a result set on screen, never while searching
    /// (plan §11: no select mode in search) or during the first load (§5).
    private var canEnterSelectMode: Bool {
        browseMode == .books && searchText.isEmpty && !showsBooksSkeleton && booksWindow.total > 0
    }

    /// `BookContextMenu`'s "Select" hook: enters select mode with that book selected.
    private var contextMenuSelectAction: ((LibraryItem) -> Void)? {
        guard canEnterSelectMode, !isSelecting else { return nil }
        return { item in enterSelectMode(with: item) }
    }

    private func enterSelectMode(with item: LibraryItem?) {
        guard canEnterSelectMode else { return }
        selection = []
        selectedItemsById = [:]
        if let item {
            selection = [item.id]
            selectedItemsById[item.id] = item
        }
        isSelecting = true
        libraryViewModel.loadSmallResultForSelectAll()
        AccessibilityNotification.Announcement("Select mode. Double tap books to select them.").post()
    }

    /// Done, any action that completes, or an exit trigger (mode, filter, sort, library or
    /// account change, search start, leaving the tab).
    private func exitSelectMode() {
        guard isSelecting || !selection.isEmpty else { return }
        isSelecting = false
        selection = []
        selectedItemsById = [:]
        showMarkFinishedConfirm = false
        pendingDownloadPlan = nil
    }

    private func toggleSelection(_ item: LibraryItem) {
        Haptics.selection()
        if selection.contains(item.id) {
            selection.remove(item.id)
            selectedItemsById[item.id] = nil
        } else {
            selection.insert(item.id)
            selectedItemsById[item.id] = item
        }
    }

    /// Selected books in on-screen order (Up Next appends in that order, plan §3.2), then any
    /// whose page has been evicted, from the side table.
    private func selectedItemsInOrder(_ window: LibraryPageWindow) -> [LibraryItem] {
        var ordered: [LibraryItem] = []
        var seen = Set<String>()
        for item in window.loadedInOrder where selection.contains(item.id) {
            if seen.insert(item.id).inserted { ordered.append(item) }
        }
        let rest = selection.subtracting(seen).compactMap { selectedItemsById[$0] }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return ordered + rest
    }

    private var allLoadedSelected: Bool {
        let window = booksWindow
        return window.total > 0 && selection.count >= window.total
            && window.loadedInOrder.allSatisfy { selection.contains($0.id) }
    }

    /// Plan §11 Q3 (C): Select All only for a local result set of 200 or fewer.
    private func toggleSelectAll() {
        Haptics.selection()
        if allLoadedSelected {
            selection = []
            selectedItemsById = [:]
        } else {
            for item in booksWindow.loadedInOrder {
                selection.insert(item.id)
                selectedItemsById[item.id] = item
            }
        }
    }

    private func performUpNext() {
        let items = selectedItemsInOrder(booksWindow)
        guard !items.isEmpty else { return }
        // One persist, one toast ("Added 10 to Up Next · 2 were already queued").
        playerViewModel.addToQueue(items)
        exitSelectMode()
    }

    /// Plan §3.2 "Bulk Download limits": one up-front plan. A refusal (Wi-Fi only, free
    /// space, nothing to download) is one message and starts nothing; more than 5 books
    /// asks first; at most 50 per action.
    private func performDownload() {
        let items = selectedItemsInOrder(booksWindow)
        guard !items.isEmpty else { return }
        let plan = downloadManager.bulkDownloadPlan(for: items)
        if let refusal = plan.refusal {
            Haptics.impact(.heavy)
            bulkErrorMessage = refusal.message
            return
        }
        if plan.needsConfirmation {
            pendingDownloadPlan = plan
        } else {
            startDownloads(plan)
        }
    }

    private func startDownloads(_ plan: BulkDownloadPlan) {
        downloadManager.downloadBooks(plan)
        Haptics.success()
        exitSelectMode()
    }

    /// Plan §3.2 "Mark Finished: confirm, then undo".
    private func performMarkFinished() {
        let items = selectedItemsInOrder(booksWindow)
        guard !items.isEmpty, libraryViewModel.canMarkFinished, !isMarkingFinished else { return }
        isMarkingFinished = true
        markingCount = items.count
        Task {
            let result = await libraryViewModel.markFinished(items: items)
            isMarkingFinished = false
            if !result.snapshots.isEmpty {
                finishUndoSnapshots = result.snapshots
                finishUndoMessage = Self.markedFinishedToast(
                    succeeded: result.succeeded.count, failed: result.failed.count
                )
            } else if !result.failed.isEmpty {
                bulkErrorMessage = Self.bulkFinishFailureMessage(count: result.failed.count)
            }
            if result.allSucceeded {
                Haptics.success()
                exitSelectMode()
            } else {
                // The ones that failed stay selected, so Try Again is one tap.
                Haptics.impact(.heavy)
                let failed = Set(result.failed)
                selection = selection.intersection(failed)
                selectedItemsById = selectedItemsById.filter { failed.contains($0.key) }
            }
        }
    }

    /// Undo: restore every book in the batch from its snapshot, in one batch request and
    /// one progress read (plan §3.2 "Undo", HIG Undo and redo: revert multiple changes at once).
    private func undoMarkFinished() {
        let snapshots = finishUndoSnapshots
        finishUndoSnapshots = []
        guard !snapshots.isEmpty else { return }
        Task {
            let failed = await libraryViewModel.restoreProgress(snapshots, reload: true)
            if !failed.isEmpty { bulkErrorMessage = Self.undoFailureMessage(count: failed.count) }
        }
    }

    private func consumeRequestedBrowseMode() {
        guard let mode = libraryViewModel.requestedBrowseMode else { return }
        browseMode = mode
        libraryViewModel.requestedBrowseMode = nil
    }

    /// Batch 490 (REVIEW 2026-11-11 F14): a search link's text goes into the Titles search.
    /// Setting `searchText` runs the existing debounced server search through its `onChange`.
    private func consumeRequestedSearchText() {
        guard let text = libraryViewModel.requestedSearchText else { return }
        libraryViewModel.requestedSearchText = nil
        guard !text.isEmpty else { return }
        searchScope = .titles
        searchText = text
    }

    /// "B-side" shuffle — picks a random book you haven't started at all (no
    /// progress recorded, per `progressFor(itemId:)`, not just 0% which can also mean
    /// "explicitly reset") and hands it straight to the player, like flipping a
    /// cassette over to see what's on the other side.
    private func shuffleBSide() {
        let unstarted = libraryViewModel.items.filter {
            libraryViewModel.progressFor(itemId: $0.id) == nil
        }
        guard let pick = unstarted.randomElement() else {
            Haptics.impact(.heavy)
            shuffleToastMessage = String(localized: "Every book in this library has already been started.", comment: "Toast when the B-side shuffle finds no unstarted book")
            return
        }
        Haptics.selection()
        isShufflingBSide = true
        Task {
            // Critique 2026-10-06 (harden): "Playing instead of … Undo" when it replaced a book.
            await playerViewModel.startPlaybackOfferingUndo(for: pick)
            isShufflingBSide = false
        }
    }

    // MARK: - Ambient download activity (Stage 3, REDESIGN_PROPOSAL_2026-08-26.md §2.1)
    //
    // Code review fix (26 August 2026): was a full-width banner row directly in the
    // scroll content. That worked when it was the only thing above the grid, but the
    // Batch 227 revert brought `browseModeSwitcher` back too (the user preferred the
    // chip row over Stage 4's title menu) — with both this banner AND that switcher
    // present, plus the offline banner when relevant, Library's top chrome grew to
    // roughly 170pt before the first cover, the opposite of Stage 3's intent. Since
    // the chip row stays (that's the part the user actually wanted back), this moved
    // the other side instead: a small toolbar badge, same information (active vs.
    // failed count) and same destination (Settings' download management), without
    // permanently claiming a full-width row. Shown regardless of `browseMode` (unlike
    // `libraryOptionsButton`, which only applies to Books) since downloads aren't
    // specific to any one browse mode.
    //
    // Item 13 (REVIEW-2026-09-09.md): the badge itself moved out to the standalone
    // `DownloadActivityBadge` view below `LibraryView`'s closing brace — see that
    // type's doc comment for why.

    // MARK: - Active library subtitle

    /// Small "which library/server am I looking at" line under the nav title — mostly
    /// useful for multi-library/multi-account setups where it's otherwise easy to lose
    /// track of scope while browsing.
    @ViewBuilder
    private var librarySubtitle: some View {
        // F7 (REVIEW_2026-09-04_UI.md): gated on the same `count > 1` condition the
        // library switcher in `.toolbar` already uses. This line exists to disambiguate
        // *which* library you're browsing — with only one, it's a grey word pinned under
        // the nav bar with no affordance and nothing to disambiguate, which is what a
        // single-library account (the common case) was seeing.
        if libraryViewModel.libraries.count > 1,
           let name = libraryViewModel.selectedLibrary?.name {
            // Critique 2026-10-05 (Library): was a bare `.font(.system(size:))`.
            Typo.supporting(Text(name), weight: .medium)
                .foregroundStyle(Color.shelfMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Batch 218 (R9): propagates `Space.pageH` — this file used 16pt
                // margins throughout while Home (an adjacent tab) used 20pt, the
                // exact "visible 4pt mismatch" `Space.pageH`'s own doc comment
                // calls out. See `libraryGrid`'s comment below for the one site in
                // this file where that 4pt change needed real arithmetic first.
                .padding(.horizontal, Space.pageH)
                .padding(.top, 6)
                .accessibilityLabel("Library: \(name)")
        }
    }

    // MARK: - Browse mode switcher

    /// N-3 (REVIEW_2026-09-14_DESIGN.md): the review's finding on the horizontally
    /// scrolling chip row this used to be — "Books / Series / Authors / Narrators
    /// scroll horizontally, 'Narr…' clipped. Four scopes, not filters." These six
    /// `BrowseMode` cases pick *what set of things* you're browsing (a scope), which
    /// is a different kind of control than `activeFilterChips` below it (which narrows
    /// *within* a scope) — the scrolling-chip treatment made the two look identical
    /// and let the primary scopes clip off-screen with no visual hint more existed.
    ///
    /// Chose a segmented `Picker` over `.searchable`/`.searchScopes` for the primary
    /// four: `.searchScopes` only renders while the search field is active/focused
    /// (SwiftUI hides scope bars until the user taps into search), so it can't stand
    /// in for a permanently visible scope switcher here — this screen needs the
    /// control available with an empty, unfocused search field, which is the normal
    /// state when just browsing. A segmented control has no such requirement and
    /// shows every primary scope at once, un-clipped, at default text sizes.
    ///
    /// Collections/Playlists (never clipped in the old row, but also never the
    /// reviewer's focus — "Reviewer counted four") move to a compact trailing `Menu`
    /// per the PM's call, so the segmented control stays four items wide instead of
    /// six (six segments is where a segmented control starts truncating labels again,
    /// the exact defect being fixed). At accessibility Dynamic Type sizes a segmented
    /// control truncates unreadably regardless of item count, so this falls back to
    /// `browseModeMenu` — a single `Menu` listing all six — the same fallback shape
    /// `LibraryFilterSheet`'s R4 fix already uses for its Smart Filter grid.
    /// LG-5 (docs/visual-design-review.md, V5): true where `safeAreaBar` exists (iOS 26.0,
    /// Apple docs `View/safeAreaBar(edge:alignment:spacing:content:)`).
    private var usesScopeBar: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @ViewBuilder
    private var browseModeSwitcher: some View {
        if dynamicTypeSize.isAccessibilitySize {
            browseModeMenu
        } else {
            HStack(spacing: 8) {
                if !primaryModes.isEmpty {
                    Picker("Browse scope", selection: Binding(
                        get: { browseMode },
                        set: { newMode in
                            // Matches the old chip row's haptic-per-tap — fired only on
                            // a genuine user selection, not the `availableModes`
                            // auto-fallback-to-Books below (which sets `browseMode`
                            // directly, bypassing this setter).
                            Haptics.selection()
                            browseMode = newMode
                        }
                    )) {
                        ForEach(primaryModes) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Choose what to browse")
                }
                if !secondaryModes.isEmpty {
                    moreScopesMenu
                }
            }
            .padding(.horizontal, Space.pageH)
            .padding(.vertical, 8)
        }
    }

    /// Compact trailing `Menu` for the scopes `primaryModes` doesn't have room for
    /// (Collections/Playlists). Shows "More" with a generic glyph when neither is
    /// active, or the active one's own icon + name (highlighted, amber-filled) when
    /// the user is currently browsing one of them — so the active scope is never
    /// hidden behind a mystery "More" label.
    @ViewBuilder
    private var moreScopesMenu: some View {
        let active: BrowseMode? = secondaryModes.contains(browseMode) ? browseMode : nil
        let a11yLabel = active.map { String(localized: "More scopes. Currently browsing \($0.label).", comment: "Accessibility label of the Library More-scopes menu; %@ is the current scope name, e.g. Collections") }
            ?? String(localized: "More scopes", comment: "Accessibility label and chip text of the Library menu that holds the Collections and Playlists scopes")
        Menu {
            ForEach(secondaryModes) { mode in
                Button {
                    Haptics.selection()
                    browseMode = mode
                } label: {
                    HStack {
                        Label(mode.label, systemImage: mode.icon)
                        if browseMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active?.icon ?? "ellipsis.circle")
                    .font(.system(size: modeIconSize, weight: .semibold))
                Typo.chip(Text(active?.label ?? String(localized: "More", comment: "Chip text of the Library menu that holds the Collections and Playlists scopes")), weight: .semibold)
            }
            .foregroundStyle(active != nil ? Color.onAccent : Color.shelfCream)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(active != nil ? Color.shelfAmber : Color.shelfSurface))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(a11yLabel)
        .accessibilityHint("Browse Collections or Playlists")
        .accessibilityAddTraits(active != nil ? [.isSelected] : [])
    }

    /// Accessibility-size fallback (`dynamicTypeSize.isAccessibilitySize`) for the
    /// whole switcher: a segmented control truncates badly at large Dynamic Type, so
    /// this lists all six `availableModes` in one `Menu` instead — same shape as the
    /// library switcher `Menu` in `.toolbar` below, and as `moreScopesMenu` above.
    private var browseModeMenu: some View {
        Menu {
            ForEach(availableModes) { mode in
                Button {
                    Haptics.selection()
                    browseMode = mode
                } label: {
                    HStack {
                        Label(mode.label, systemImage: mode.icon)
                        if browseMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: browseMode.icon)
                    .font(.system(size: modeIconSize, weight: .semibold))
                Typo.rowTitle(Text(browseMode.label))
                Image(systemName: "chevron.up.chevron.down")
                    // VD-7 (docs/design-review.md, Round 4): sits beside `Typo.rowTitle`'s
                    // text and `modeIconSize` (both already scaling) in this same capsule
                    // — this glyph was the one unscaled member of the trio.
                    .scaledFont(11, weight: .semibold)
            }
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.shelfAmber))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, Space.pageH)
        .padding(.vertical, 8)
        .accessibilityLabel("Browsing \(browseMode.label)")
        .accessibilityHint("Double tap to choose a different browse scope")
    }

    // MARK: - Active filter chips (design-direction pass, 17 Aug 2026, point 4)

    /// Design-direction pass, point 4: this used to be an always-visible row of every
    /// progress-filter option plus "Downloaded" as a segmented-control-style bar — the
    /// same UI for both *choosing* a filter and *seeing* the current one, taking up a
    /// full row of screen space even when nothing was filtered (every book showing).
    /// Per the review: `libraryOptionsButton`'s `LibraryFilterSheet` (26 August 2026
    /// redesign of what used to be `libraryOptionsMenu`) is where you configure (smart
    /// filters, progress filter, downloaded-only, sort — it already has all of these),
    /// and this row's only job now is to tell you *why* you're seeing this result set, as
    /// compact removable chips — one per active filter, each with an "×" to clear it
    /// individually. Renders nothing at all when no filter is active, rather than a
    /// permanent "All" pill sitting there doing nothing.
    @ViewBuilder
    private var activeFilterChips: some View {
        // Critique 2026-10-05 (Library, 2nd): chips come from the *effective* filters, so a
        // chip never claims a filter that is being overridden (smart filter outranks
        // progress + Downloaded; Recently Played ignores the progress filter).
        let effective = LibraryLocalQuery.effectiveFilters(
            smartFilter: libraryViewModel.smartFilter, progressFilter: libraryViewModel.progressFilter,
            downloadedOnly: libraryViewModel.downloadedOnly, sort: libraryViewModel.sortOption
        )
        let hasDownloadedOnly = effective.downloadedOnly
        if !effective.isEmpty {
            // Critique 2026-10-05 (Library): the server search takes only a query (no
            // filter, no sort — `AudiobookshelfAPI.search(libraryId:query:)`), and the
            // offline fallback searches every downloaded book. So while a search is active
            // every chip below is inert; dim them and say so rather than let them claim a
            // result set they no longer shape.
            let searchActive = !searchText.isEmpty
            VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let smart = effective.smartFilter {
                            removableChip(label: smart.label, inactive: searchActive) {
                                Task { await libraryViewModel.selectSmartFilter(nil) }
                            }
                        }
                        if let progressChip = effective.progress {
                            removableChip(label: progressChip.label, inactive: searchActive) {
                                libraryViewModel.progressFilter = .all
                                Task { await libraryViewModel.applySortFilter() }
                            }
                        }
                        if hasDownloadedOnly {
                            removableChip(label: String(localized: "Downloaded", comment: "Removable filter chip in Library: showing only downloaded books"), inactive: searchActive) {
                                libraryViewModel.downloadedOnly = false
                            }
                        }
                    }
                }
                // 16 September 2026: Downloads has no tab of its own — transfers,
                // preferences and storage moved to Settings > Downloads
                // (`DownloadsSettingsView`). Keeping them one tap away from here,
                // rather than three taps through Settings, while the Downloaded chip
                // (this view's own browsing half of that old tab) is active.
                if hasDownloadedOnly {
                    LibraryRouteLink(.downloadsSettings(showsDownloadedBooksLink: true), bottomInset: bottomInset) {
                        Typo.supporting(Label("Manage", systemImage: "slider.horizontal.3"), weight: .medium)
                            .foregroundStyle(Color.shelfAmberText)
                    }
                }
            }
            .opacity(searchActive ? 0.45 : 1)
            // Critique 2026-10-05 (Library, 2nd): dimmed chips are non-interactive too.
            .allowsHitTesting(!searchActive)
            if searchActive {
                Typo.supporting(Text("Search ignores filters"))
                    .foregroundStyle(Color.shelfMuted)
            } else if effective.smartFilter != nil && libraryViewModel.smartFilterSnapshotIsPartial {
                // Review Medium 30 (30 October 2026): past `smartFilterItemCap` the smart
                // filter only saw part of the library, so say so instead of implying a full result.
                Typo.supporting(Text("Checked the first \(LibraryViewModel.smartFilterItemCap) books only"))
                    .foregroundStyle(Color.shelfMuted)
            }
            }
            .padding(.horizontal, Space.pageH)
            .padding(.bottom, 8)
        }
    }

    /// Critique 2026-10-05 (Library): wayfinding. A quiet "1,240 books · Title A–Z" line
    /// under the scope bar so the size of the library and the active sort are visible
    /// without opening the filter sheet. Uses the server total (not the pages loaded so
    /// far). Hidden while a search is active (search has neither a total nor a sort), while
    /// the skeleton shows, and when there is nothing to count.
    @ViewBuilder
    private var booksCountLine: some View {
        let count = libraryViewModel.totalResultCount(
            downloads: libraryViewModel.showsLocalDownloads ? downloadManager.downloadedLibraryItems() : []
        )
        if searchText.isEmpty, !showsBooksSkeleton, count > 0 {
            Typo.supporting(Text(LibraryLocalQuery.countAndSortLine(
                count: count, sort: libraryViewModel.sortOption,
                descending: libraryViewModel.sortDescending,
                downloadedOnly: libraryViewModel.downloadedOnly,
                smartFilter: libraryViewModel.smartFilter,
                offlineFallback: libraryViewModel.itemsSource == .offlineFallback
            )))
            .monospacedDigit()
            .foregroundStyle(Color.shelfMuted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)   // Polish pass (J3-9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.pageH)
            .padding(.bottom, 6)
            // The scope bar and filters are the controls; this is read-only context.
            .accessibilityAddTraits(.isStaticText)
        }
    }

    /// A single active-filter pill with an "×" — tapping anywhere on it clears that
    /// one filter (no separate tap target for the × vs. the label; the whole chip is
    /// the "remove" affordance, same as removable-token patterns elsewhere on iOS).
    /// Always amber-filled: unlike the old selector bar's chips (which needed to show
    /// both a selected and unselected state), every chip here represents something
    /// currently active, so it's a legitimate use of amber for "current state" — not
    /// decoration.
    private func removableChip(label: String, inactive: Bool = false, onRemove: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            onRemove()
        } label: {
            HStack(spacing: 4) {
                // U10 (REVIEW_2026-08-20_UI_SECURITY.md): was its own 12pt/.semibold/
                // .rounded spelling of `Typo.chip(weight: .semibold)`'s exact spec.
                Typo.chip(Text(label), weight: .semibold)
                Image(systemName: "xmark")
                    .font(.system(size: max(chipLabelSize - 2, 9), weight: .bold))
            }
            // P-6 (REVIEW_2026-09-14_DESIGN.md): 12pt literal → `Space.m`, no visual change.
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .foregroundStyle(Color.onAccent)
            .background(Color.shelfAmber, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inactive ? Text("\(label) filter, inactive while searching") : Text("\(label) filter"))
        .accessibilityHint(inactive ? Text(verbatim: "") : Text("Double tap to remove this filter"))
    }

    // AN-3 (docs/design-review.md, Round 3): computed once so `booksContent`'s branch
    // condition and the `.shelfAnimation(value:)` key below can't drift apart.
    private var showsBooksSkeleton: Bool {
        (libraryViewModel.isLoadingItems && libraryViewModel.items.isEmpty)
            || (libraryViewModel.isLoadingSmartFilter && libraryViewModel.smartFilterItems.isEmpty)
    }

    @ViewBuilder
    private var booksContent: some View {
        // AN-3: the animation is scoped to this inner `Group` (not the `browseMode`
        // switch `Group` at the call site) so a skeleton → content swap doesn't also
        // animate an unrelated `browseMode` change landing in the same transaction.
        Group {
        if showsBooksSkeleton {
            // Skeleton grid instead of a centered spinner — same shape as
            // `libraryGridView`'s real tiles, so the layout doesn't jump once
            // content arrives.
            ScrollView { SkeletonGrid() }
                .scrollDisabled(true)
                .transition(.opacity)
        } else if !searchText.isEmpty && searchScope == .ask {
            ScrollView {
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                askResultsView
            }
                .scrollsToTop(signal: scrollToTopSignal, firstID: Self.topAnchorID)
                .transition(.opacity)
        } else if !searchText.isEmpty {
            ScrollView {
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                searchResultsView
            }
                .scrollsToTop(signal: scrollToTopSignal, firstID: Self.topAnchorID)
                // Batch 218 (R10.10): this called `refresh()` — the whole-library
                // reload — even while search results were on screen, so pulling
                // to refresh a search did nothing to the search itself. Re-runs
                // the active query instead; `refresh()` is only appropriate when
                // there's no search in progress (the branches below).
                .refreshable { await Task { await libraryViewModel.search() }.value }
                // AN-3: fades in alongside the other arms below so a skeleton →
                // empty-state (or any other arm) swap isn't a hard cut either.
                .transition(.opacity)
        } else if libraryLayout == "list" {
            libraryListView   // a List (so rows get swipe actions), with its own refresh
                .transition(.opacity)
        } else {
            // Tab-shell reconciliation (26 August 2026): wrapped in `ScrollViewReader`
            // so `scrollToTopSignal` (see that property's doc comment) can scroll this
            // grid back to the top on tab reselect, mirroring `HomeView`'s identical
            // wiring.
            let window = booksWindow
            let showsScrubber = LibraryScrubberMath.showsScrubber(count: window.total)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    Color.clear.frame(height: 0).id(Self.topAnchorID)
                    libraryGridView(window)
                }
                // Library browse plan §6.3 (2026-10-05): `scrollPosition(id:)` (iOS 17.0)
                // reports the top-most slot of the `scrollTargetLayout()` grid, which drives
                // the scrubber's resting position and page loading. Jumps write through the
                // proxy (no animation for anyone, plan §3.1 "Release").
                .scrollPosition(id: gridTopSlotBinding, anchor: .top)
                // HIG Scroll views: no second indicator on the scrubber's axis.
                .scrollIndicators(showsScrubber ? .hidden : .automatic, axes: .vertical)
                .modifier(LibraryScrollPhaseTracking(tracker: scroll))
                .modifier(LibraryScrubberPlacement {
                    scrubberOverlay(window: window, columns: gridColumnCount) { index in
                        scrollProxy.scrollTo(index, anchor: .top)
                    }
                })
                // Detach so ending the pull gesture can't cancel the requests
                // mid-flight (that cancellation collapsed the grid to downloads-only).
                // Plan §5: pull to refresh is off while selecting.
                .refreshable {
                    guard !isSelecting else { return }
                    await Task { await libraryViewModel.refresh() }.value
                }
                .onChange(of: scrollToTopSignal) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
                .onChange(of: resetScrollSignal) { _, _ in
                    scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
            }
            .transition(.opacity)
        }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsBooksSkeleton)
        // Library browse plan §8 step 9: `BookContextMenu` shows "Select" while this is set
        // (Books scope, not searching, not already selecting).
        .environment(\.librarySelectAction, contextMenuSelectAction)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .onGeometryChange(for: Bool.self) { Self.foldSplitsVertically($0) } action: { foldSplitsGrid = $0 }
    }

    // MARK: - Slot loading and the scrubber (Library browse plan §3.1, §6.3, 2026-10-05)

    /// The grid's real column count for the current width, mirroring `columns`' adaptive
    /// solve (minimum + 16 pt spacing inside `Space.pageH` margins). Used to row-snap the
    /// scrubber and size the page-load window.
    private var gridColumnCount: Int {
        if foldSplitsGrid, let even = foldEvenColumnCount { return even }  // iPhone Duo (§5)
        let compact = UIDevice.current.userInterfaceIdiom == .phone && libraryGridDensity == "compact"
        return Self.adaptiveColumnCount(width: contentWidth, minimum: compact ? 96 : 150)
    }

    /// iPhone Duo (§5): the column count to use while the fold splits the grid, or nil to
    /// keep the adaptive grid (its count is already even, or too small to change).
    private var foldEvenColumnCount: Int? {
        let compact = UIDevice.current.userInterfaceIdiom == .phone && libraryGridDensity == "compact"
        return Self.evenColumnCount(adaptive: Self.adaptiveColumnCount(width: contentWidth, minimum: compact ? 96 : 150))
    }

    /// Pure: an odd adaptive count of 3 or more drops to the even count below it (fewer,
    /// wider tiles, so the gap between the middle two columns sits on the fold); otherwise nil.
    static func evenColumnCount(adaptive: Int) -> Int? {
        adaptive >= 3 && !adaptive.isMultiple(of: 2) ? adaptive - 1 : nil
    }

    /// iPhone Duo (§5): whether an active `.division` reserved region (iOS 27.1,
    /// `GeometryProxy.reservedRegions(kind:)`) runs vertically through this view: taller
    /// than wide and strictly inside its width. False before iOS 27.1 and on older SDKs.
    nonisolated static func foldSplitsVertically(_ proxy: GeometryProxy) -> Bool {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            let width = proxy.size.width
            return proxy.reservedRegions(kind: .division).contains { region in
                region.isActive && region.frame.height > region.frame.width
                    && region.frame.minX > 0 && region.frame.maxX < width
            }
        }
        #endif
        return false
    }

    /// Pure: how many `GridItem(.adaptive(minimum:, spacing: 16))` columns fit `width`
    /// after the page margins. At least 1.
    static func adaptiveColumnCount(width: CGFloat, minimum: CGFloat, spacing: CGFloat = 16,
                                    margin: CGFloat = Space.pageH) -> Int {
        let available = max(0, width - 2 * margin)
        return max(1, Int((available + spacing) / (minimum + spacing)))
    }

    /// Read side of `scrollPosition(id:)`: the tracker's top slot. Written by SwiftUI as the
    /// user scrolls. This view's body never reads the tracker, so a scroll doesn't re-run it.
    private var gridTopSlotBinding: Binding<Int?> {
        Binding(
            get: { scroll.topIndex },
            set: { newValue in
                guard let index = newValue else { return }
                topSlotChanged(index, span: gridColumnCount * 6)
            }
        )
    }

    /// A new top slot from scrolling (grid binding or list row visibility): updates the
    /// scrubber position, shows it (the iOS 17 fallback rhythm), and asks for the pages
    /// under the visible window once scrolling settles.
    private func topSlotChanged(_ index: Int, span: Int) {
        guard index != scroll.topIndex else { return }
        scroll.topIndex = index
        scroll.noteActivity()
        requestPages(around: index...(index + max(1, span)))
    }

    /// Library browse plan §6.5 (2026-10-05): page fetches start once scrolling or a
    /// scrubber drag has rested for 300 ms (the dwell rule), not on every row.
    private func requestPages(around range: ClosedRange<Int>) {
        // Local sets (smart filter, Downloaded, offline fallback, Recently Played) are fully
        // loaded; only a server-paged query has pages to fetch.
        guard libraryViewModel.isWindowed else { return }
        let viewModel = libraryViewModel
        scroll.scheduleFetch { viewModel.ensurePagesLoaded(around: range) }
    }

    /// The scrubber's jump: moves the scroll position at once (no animation) and loads the
    /// target page after the 300 ms dwell. Selection persists across jumps (plan §3.2).
    private func scrubberJumped(to index: Int, scrollTo: (Int) -> Void) {
        scroll.topIndex = index
        scroll.noteActivity()
        scrollTo(index)
        guard libraryViewModel.isWindowed else { return }
        let viewModel = libraryViewModel
        scroll.scheduleFetch { viewModel.jump(to: index) }
    }

    /// The trailing position scrubber, Books scope only, at 120+ books (plan §3.1).
    @ViewBuilder
    private func scrubberOverlay(window: LibraryPageWindow, columns: Int,
                                 scrollTo: @escaping (Int) -> Void) -> some View {
        if LibraryScrubberMath.showsScrubber(count: window.total) {
            LibraryScrubberOverlay(
                tracker: scroll,
                count: window.total,
                columns: columns,
                alwaysVisible: voiceOverEnabled
            ) { index in
                scrubberJumped(to: index, scrollTo: scrollTo)
            }
            .padding(.top, Space.s)
            .padding(.bottom, Space.s + bottomInset)
        }
    }

    // MARK: - Library List (rows + swipe actions)

    @ViewBuilder
    private var libraryListView: some View {
        let window = booksWindow
        if window.total == 0 && !libraryViewModel.isLoadingItems && !libraryViewModel.isLoadingSmartFilter {
            ScrollView { libraryEmptyState }
                .refreshable { await Task { await libraryViewModel.refresh() }.value }
        } else {
            let showsScrubber = LibraryScrubberMath.showsScrubber(count: window.total)
            let canFetch = libraryViewModel.canFetchPages
            // Tab-shell reconciliation (26 August 2026): same `scrollToTopSignal`
            // wiring as the grid branch above, adapted for a `List` — an invisible
            // zero-height row carries the anchor id instead of a `Color.clear`
            // spacer directly inside a `ScrollView`, since a `List`'s rows are the
            // only children `scrollProxy.scrollTo` can target here.
            ScrollViewReader { scrollProxy in
            // Library browse plan §3.2 (2026-10-05): the system multi-select. Apple docs
            // `List`: "To enable multiple selections with tap gestures, put the list into
            // edit mode". The binding stays attached outside select mode (swapping the
            // initializer would rebuild the list and lose the scroll position); with edit
            // mode inactive a tap still navigates.
            List(selection: listSelectionBinding) {
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled(true)
                    .id(Self.topAnchorID)

                // Library browse plan §6.2 (2026-10-05): one row per slot, keyed by slot
                // index, so a placeholder and the row that replaces it share an identity.
                ForEach(0..<window.total, id: \.self) { index in
                    listSlot(window.slot(at: index), index: index, canFetch: canFetch)
                        // iPhone Duo (§3): the row whose book fills the detail column reads
                        // as selected, as a split view's list does.
                        .listRowBackground(isInDetail(window.slot(at: index)) ? Color.shelfSurface : Color.shelfBackground)
                        .listRowSeparatorTint(Color.shelfMuted.opacity(0.2))
                        // iOS 17 has no visible-row API for `List` (plan §6.3): each row's
                        // appear/disappear, reduced to the lowest visible index.
                        .onAppear { listRowVisibility(index, visible: true) }
                        .onDisappear { listRowVisibility(index, visible: false) }
                }
            }
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
            }
            .onChange(of: resetScrollSignal) { _, _ in
                scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(showsScrubber ? .hidden : .automatic, axes: .vertical)
            .modifier(LibraryScrollPhaseTracking(tracker: scroll))
            // HIG Lists and tables advises no index over trailing disclosure chevrons; the
            // scrubber is shown here only while scrolling (plan §3.1 "List layout caveat").
            .modifier(LibraryScrubberPlacement {
                scrubberOverlay(window: window, columns: 1) { index in
                    scrollProxy.scrollTo(index, anchor: .top)
                }
            })
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomInset) }
            .refreshable {
                guard !isSelecting else { return }
                await Task { await libraryViewModel.refresh() }.value
            }
            }
        }
    }

    /// One list slot: a book row (navigating, or selectable in edit mode) or a placeholder row.
    @ViewBuilder
    private func listSlot(_ slot: LibraryPageWindow.Slot, index: Int, canFetch: Bool) -> some View {
        switch slot {
        case .item(let item):
            LibraryListRow(item: item, navigates: !isSelecting, onOpen: detailSelection.map { selection in
                { selection.wrappedValue = $0 } })
                .tag(item.id)
                // iPhone Duo (§3): the book open in the split view's detail column.
                .accessibilityAddTraits(isInDetail(item) ? .isSelected : [])
                // UX-1 (docs/design-review.md, Round 3): list rows had no way to
                // start playback without opening Book Detail — a leading swipe
                // now offers the same Play/Resume action as `DownloadsView`'s
                // list, and the long-press menu matches the grid's. (The system
                // suspends swipe actions in edit mode.)
                // Batch 490 (REVIEW 2026-11-11 L4): no full swipe — a long swipe used to
                // replace the loaded book with no chance to stop; now it takes a tap, and
                // `quickPlayOrPause` offers "Jump back" when it replaces one.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    leadingPlayAction(for: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeActions(for: item)
                }
                .bookContextMenu(item)
        case .placeholder(_, let state):
            LibraryPlaceholderRow(index: index, state: state, offline: !canFetch) {
                libraryViewModel.retryPage(containing: index)
            }
            // Plan §3.2: unloaded slots can't be selected (`selectionDisabled`, iOS 17.0).
            .selectionDisabled(true)
            .onAppear { placeholderAppeared(index, span: 14) }
        }
    }

    /// An unloaded slot came on screen: load the pages from the top visible slot down to it.
    /// Far from the tracked top (a stale top after a layout change) it loads around itself.
    private func placeholderAppeared(_ index: Int, span: Int) {
        let top = scroll.topIndex
        if top <= index && index - top <= span * 2 {
            requestPages(around: top...max(index, top + span))
        } else {
            requestPages(around: index...(index + span))
        }
    }

    /// List row visibility bookkeeping → top slot (plan §6.3, iOS 17 path).
    private func listRowVisibility(_ index: Int, visible: Bool) {
        if visible { scroll.visibleRows.insert(index) } else { scroll.visibleRows.remove(index) }
        guard let top = scroll.visibleRows.min() else { return }
        topSlotChanged(top, span: max(14, scroll.visibleRows.count))
    }

    /// `List(selection:)`'s binding: writes go through the side table so every selected
    /// id keeps its `LibraryItem` (plan §6.4).
    private var listSelectionBinding: Binding<Set<String>> {
        Binding(
            get: { selection },
            set: { newValue in
                guard isSelecting else { return }
                let added = newValue.subtracting(selection)
                if !added.isEmpty {
                    for item in booksWindow.loadedInOrder where added.contains(item.id) {
                        selectedItemsById[item.id] = item
                    }
                }
                let kept = newValue.filter { selectedItemsById[$0] != nil }
                for id in selection.subtracting(kept) { selectedItemsById[id] = nil }
                selection = kept
            }
        )
    }

    /// Leading swipe action: quick Play/Resume/Pause — UX-1 (docs/design-review.md,
    /// Round 3). Mirrors `DownloadsView`'s Play/Resume swipe via the shared
    /// `PlayerViewModel` helper, computing `finished`/`progress` the same way
    /// `swipeActions(for:)` below and `LibraryListRow` already do (server progress
    /// first, falling back to the item's own fields).
    @ViewBuilder
    private func leadingPlayAction(for item: LibraryItem) -> some View {
        let finished = libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
        let progress = libraryViewModel.progressFor(itemId: item.id)?.progress ?? item.progressPercent
        Button {
            playerViewModel.quickPlayOrPause(item)
        } label: {
            Label(
                playerViewModel.quickPlayActionLabel(for: item, finished: finished, progressPercent: progress),
                systemImage: playerViewModel.quickPlayActionSystemImage(for: item)
            )
        }
        // Critique 2026-10-06 (colorize): fixed darker tint so the system's white label
        // clears AA; see `LibrarySwipeTint`.
        .tint(LibrarySwipeTint.amber)
        .accessibilityLabel(playerViewModel.quickPlayActionLabel(for: item, finished: finished, progressPercent: progress))
    }

    /// Shared swipe actions (also usable from the grid's context menu).
    @ViewBuilder
    private func swipeActions(for item: LibraryItem) -> some View {
        let finished = libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
        Button {
            // Critique 2026-10-06 (harden): the swipe now gets the same Undo toast as every
            // other single-book Mark Finished (`LibraryViewModel.progressUndoMessage`).
            Task { finished ? await libraryViewModel.markUnfinished(item: item)
                            : await libraryViewModel.markFinished(item: item) }
        } label: {
            // Critique 2026-10-06 (clarify): the same verbs as Book Detail's menu ("Unfinish"
            // was the odd one out). DEVICE CHECK: the longer swipe label's fit.
            Label(LibraryView.finishedToggleTitle(finished: finished),
                  systemImage: finished ? "circle" : "checkmark.circle.fill")
        }
        .tint(LibrarySwipeTint.teal)

        if downloadManager.isDownloaded(itemId: item.id) {
            // L1 (REVIEW_2026-08-20_UI_SECURITY.md): confirm before deleting, matching
            // `BookDetailView`/`DownloadsView`'s existing confirmations for the same
            // action — see `removalCandidate` and the `.confirmationDialog` in `body`.
            Button(role: .destructive) {
                removalCandidate = item
            } label: { Label("Remove", systemImage: "trash") }
        } else {
            Button {
                Haptics.selection(); downloadManager.downloadBook(item)
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .tint(LibrarySwipeTint.amber)
        }

        if playerViewModel.currentBook?.id != item.id {
            Button {
                Haptics.selection(); playerViewModel.addToQueue(item)
            } label: { Label("Up Next", systemImage: "text.badge.plus") }
            .tint(LibrarySwipeTint.neutral)
        }
    }

    // MARK: - Library Options (redesigned per user feedback, 26 August 2026)

    /// Whether anything in the filter sheet is in a non-default state — drives the
    /// filled-vs-outline icon, the one visual signal for "something's active" without
    /// opening the sheet.
    private var libraryOptionsActive: Bool {
        libraryViewModel.smartFilter != nil
            || libraryViewModel.progressFilter != .all
            || libraryViewModel.downloadedOnly
    }

    /// User feedback (26 August 2026): "the filtering is not the best, when you select
    /// the ellipsis in top right its a massive list, how can we change this to make it
    /// more intuitive and user friendly?" — the old `libraryOptionsMenu` (a single
    /// cascading `Menu`) merged Smart Filters (8 rows), Sort (5 + direction), Progress
    /// filter (4), Downloaded-only, and Display (layout + density) into one 20+-row
    /// list, all at equal visual weight regardless of how often each is actually used.
    /// Replaced with a plain button that opens `LibraryFilterSheet` — a real, spacious
    /// sheet with each concern in its own titled `Section`, segmented controls instead
    /// of stacked rows where the choice is small and closed-set (direction, progress
    /// filter, layout, density), and a "Reset All Filters" row that only appears once
    /// something's actually active. Same total functionality as before — nothing
    /// removed, only given room to breathe.
    private var libraryOptionsButton: some View {
        Button {
            Haptics.selection()
            showFilterSheet = true
        } label: {
            // iPhone Duo (§2): a Label (icon-only in the nav bar) so the item has a title.
            Label {
                Text("Sort, filter, and display options")
            } icon: {
            if libraryViewModel.isLoadingSmartFilter {
                // U6 (REVIEW_2026-08-20_UI_SECURITY.md): raw `shelfAmber` as a spinner
                // tint is a foreground, not a fill — 1.87:1 in Light, under the 3:1
                // non-text floor. `shelfAmberText` (no opacity) is the safe token.
                ProgressView().monochromeToolbarItem()
            } else {
                // HIG audit 2026-09-17 L17: this glyph carries state, not just chrome —
                // the `.fill` variant plus amber IS the "a filter is active" indicator,
                // so amber stays for the active state; only the inactive state goes
                // monochrome.
                // LG-2 (docs/visual-design-review.md, Round V1): drop the circle variant
                // (double ring inside the glass toolbar button) and use a small amber dot
                // badge to carry the "active" state that the `.fill` shape used to convey.
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(libraryOptionsActive ? Color.shelfAmberText : Color.shelfCream)
                    .overlay(alignment: .topTrailing) {
                        if libraryOptionsActive {
                            Circle()
                                .fill(Color.shelfAmber)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
            }
            }
        }
        // iPhone Duo (§2): the Label's icon takes the item's tint, not the glyph's own style.
        .tint(libraryOptionsActive ? Color.shelfAmberText : Color.shelfCream)
        .foregroundStyle(libraryOptionsActive ? Color.shelfAmberText : Color.shelfCream)
        .accessibilityValue(libraryOptionsActive ? Text("Active") : Text(verbatim: ""))
        .sheet(isPresented: $showFilterSheet) {
            LibraryFilterSheet()
                .environment(libraryViewModel)
        }
    }

    // MARK: - Pagination footer (LS-5)
    //
    // Library browse plan §5 (2026-10-05): the next-page spinner footer is gone. The grid
    // and list now render every slot of the result set, with placeholder tiles for pages
    // not loaded yet, so there is no "end of what's loaded" for a footer to sit at.

    // MARK: - Library Grid

    @ViewBuilder
    private func libraryGridView(_ window: LibraryPageWindow) -> some View {
        if window.total == 0 && !libraryViewModel.isLoadingItems && !libraryViewModel.isLoadingSmartFilter {
            libraryEmptyState
        } else {
            libraryGrid(window)
        }
    }

    /// Design review (14 Aug 2026), item 3: whether there's actually anything for
    /// `shuffleBSide()` to pick from — checked against the FULL library (`items`), not
    /// `displayedItems`, since B-side is a "surprise me from what I own" feature and
    /// should stay offered even while the current view is filtered down to nothing.
    private var hasUnstartedBooks: Bool {
        libraryViewModel.items.contains { libraryViewModel.progressFor(itemId: $0.id) == nil }
    }

    /// Design review (14 Aug 2026), item 3: B-side used to be a bare `shuffle` glyph in
    /// the nav bar — most people would read that as "shuffle the list order," not "play
    /// a random unstarted book," so the app's best small-personality feature was
    /// effectively invisible. Given a real, labelled home instead: this button (shown in
    /// the empty state below, and as a row in Home's browse zone).
    @ViewBuilder
    private var bSideButton: some View {
        if hasUnstartedBooks {
            // Critique 2026-10-06 (harden): say visibly that it replaces the loaded book.
            let playsInstead = PlayerViewModel.playsInsteadSubtitle(loadedTitle: playerViewModel.displayedBook?.title)
            VStack(spacing: 6) {
                Button {
                    shuffleBSide()
                } label: {
                    HStack(spacing: Space.s) {
                        if isShufflingBSide {
                            ProgressView().tint(Color.shelfAmberText)
                        } else {
                            Image(systemName: "shuffle")
                        }
                        Text("Flip to a B-side")
                    }
                    .font(.subheadline.weight(.semibold))
                    // G5 (REVIEW_2026-09-04_UI.md): this only renders inside the empty state,
                    // stacked under "Clear Filter" / "Clear Smart Filter" — and both were
                    // filled accent pills of identical weight, so the screen offered two
                    // primary actions and no hierarchy. The filter action is what the person
                    // came here for; B-side is the optional detour, so it takes the tinted
                    // secondary treatment (same recipe as Book Detail's download pill, F9).
                    .foregroundStyle(Color.shelfAmberText)
                    // Batch 218 (R9): this was the "stray 20" the review flagged
                    // alongside this file's six 16pt margins — same numeric value as
                    // `Space.pageH` by coincidence, now actually named as it.
                    .padding(.horizontal, Space.pageH)
                    .padding(.vertical, 10)
                    .background(Color.shelfAmber.opacity(0.12), in: Capsule())
                }
                .disabled(isShufflingBSide)
                .accessibilityLabel("Flip to a B-side")
                .accessibilityHint(HomeBSideCard.accessibilityHint(playsInstead: playsInstead))
                if let playsInstead {
                    Typo.supporting(Text(playsInstead))
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)   // Polish pass (J3-9)
                        .accessibilityHidden(true)   // already in the button's hint
                }
            }
        }
    }

    /// Critique 2026-10-06 (clarify): the finished toggle's wording, shared by the list swipe
    /// and the grid's long-press menu, matching Book Detail's "Mark as (Not) Finished".
    static func finishedToggleTitle(finished: Bool) -> String {
        finished
            ? String(localized: "Mark as Not Finished", comment: "Menu/swipe action on a book that is currently finished")
            : String(localized: "Mark as Finished", comment: "Menu/swipe action on a book that is not finished")
    }

    /// Shared empty state for grid + list.
    @ViewBuilder
    private var libraryEmptyState: some View {
        VStack(spacing: 16) {
            if let smartFilter = libraryViewModel.smartFilter {
                if libraryViewModel.smartFilterFailed {
                    // Critique 2026-10-05 (Library): a failed bulk fetch is not "no books
                    // match". Nothing was cached, so Retry re-fetches.
                    EmptyStateView(
                        icon: "wifi.exclamationmark",
                        title: LocalizedStringResource("Couldn\u{2019}t load"),
                        subtitle: LocalizedStringResource("Couldn\u{2019}t reach your server to check \u{201C}\(smartFilter.label)\u{201D}."),
                        actionTitle: LocalizedStringResource("Retry"),
                        action: { Task { await libraryViewModel.selectSmartFilter(smartFilter) } }
                    )
                } else {
                    EmptyStateView(
                        icon: smartFilter.icon,
                        title: "Nothing here",
                        subtitle: "No books currently match \u{201C}\(smartFilter.label)\u{201D}.",
                        actionTitle: "Clear Smart Filter",
                        action: { Task { await libraryViewModel.selectSmartFilter(nil) } }
                    )
                }
            } else if libraryViewModel.itemsSource == .failed && !libraryViewModel.downloadedOnly {
                // Critique 2026-10-05 (Library, 2nd): a failed first load with nothing to show
                // used to read "No books here · This library doesn't have any books yet".
                // Same honest state as Home: offline vs. server unreachable, Retry, and the
                // downloads way out when there are any.
                let offline = reachability.status == .offline
                let hasDownloads = !downloadManager.downloadedItems.isEmpty
                EmptyStateView(
                    icon: offline ? "wifi.slash" : "exclamationmark.icloud",
                    title: offline ? "You\u{2019}re offline" : "Can\u{2019}t reach your server",
                    subtitle: hasDownloads ? "Your downloads still play." : "Check your connection and try again.",
                    actionTitle: "Retry",
                    action: { Haptics.selection(); Task { await libraryViewModel.refresh() } }
                )
                if hasDownloads {
                    Button {
                        Haptics.selection()
                        libraryViewModel.showDownloads()
                    } label: {
                        Text("Show Downloads")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Effective filters, so the copy doesn't blame a progress filter that
                // Recently Played ignores.
                let effective = LibraryLocalQuery.effectiveFilters(
                    smartFilter: nil, progressFilter: libraryViewModel.progressFilter,
                    downloadedOnly: libraryViewModel.downloadedOnly, sort: libraryViewModel.sortOption
                )
                let filtering = !effective.isEmpty
                // Critique 2026-10-05 (Library): "No downloads yet" only when there are no
                // downloads at all; a progress filter that hides every download is
                // "Nothing matches", with the filter as the way out.
                let noDownloadsAtAll = effective.downloadedOnly && effective.progress == nil
                EmptyStateView(
                    icon: libraryViewModel.downloadedOnly ? "arrow.down.circle" : "books.vertical",
                    title: noDownloadsAtAll ? "No downloads yet"
                                            : (filtering ? "Nothing matches" : "No books here"),
                    subtitle: noDownloadsAtAll
                        ? "Books you download appear here for offline listening."
                        : (filtering ? "No books match the current filter."
                                     : "This library doesn't have any books yet."),
                    actionTitle: filtering ? "Clear Filter" : nil,
                    action: filtering ? {
                        libraryViewModel.downloadedOnly = false
                        libraryViewModel.progressFilter = .all
                        Task { await libraryViewModel.applySortFilter() }
                    } : nil
                )
            }
            // G5: someone who filtered to "Downloaded" is looking for their offline books;
            // "play a random *unstarted* book" (which also needs the server) is the
            // opposite of that. Every other empty state keeps the offer.
            if !libraryViewModel.downloadedOnly {
                bSideButton
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, Space.pageH)
    }

    private func libraryGrid(_ window: LibraryPageWindow) -> some View {
        let compact = UIDevice.current.userInterfaceIdiom == .phone && libraryGridDensity == "compact"
        let canFetch = libraryViewModel.canFetchPages
        return VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 20) {
                // Library browse plan §6.2 (2026-10-05): iterate every slot of the result
                // set, keyed by slot index (not item id), so a placeholder and the tile that
                // replaces it share an identity and nothing shifts when a page lands. A
                // `LazyVGrid` only builds the visible rows.
                ForEach(0..<window.total, id: \.self) { index in
                    gridSlot(window.slot(at: index), index: index, compact: compact, canFetch: canFetch)
                }
            }
            // The scroll targets for `scrollPosition(id:)` (iOS 17.0, plan §6.3).
            .scrollTargetLayout()
        }
        // Batch 218 (R9): the review flagged this as a "grid-critical" margin —
        // `columns` is `GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)`,
        // so widening the margin from 16 to 20 changes the adaptive-column solve.
        // Worked the arithmetic by hand for the SE-through-Pro-Max range before
        // changing it: column count is `floor((width - 2×margin + spacing) /
        // (minimum + spacing))`. At 375/390/393/414/428/430pt, that resolves to 2
        // columns at BOTH margin 16 and margin 20 — the extra 4pt never pushes any
        // of those widths across a column boundary (the jump to 3 columns needs
        // ≥482pt of available width even at margin 16, well past this range). Safe
        // to migrate this site along with the rest of the file. Applied to the
        // outer `VStack` (LS-5) rather than the `LazyVGrid` directly, which passes
        // the same available width down to the grid, so this solve is unchanged.
        .padding(.horizontal, Space.pageH)
        .padding(.vertical, 12)
        .padding(.bottom, 16 + bottomInset)
    }

    /// iPhone Duo (§3): a book's link. In the inner display's split view (`detailSelection`
    /// set) it puts the book in the detail column; otherwise it is the same
    /// `NavigationLink` to Book Detail as before.
    @ViewBuilder
    private func bookLink<Label: View>(_ item: LibraryItem, @ViewBuilder label: () -> Label) -> some View {
        if let detailSelection {
            Button { detailSelection.wrappedValue = item } label: { label() }
                .accessibilityAddTraits(isInDetail(item) ? .isSelected : [])
        } else {
            NavigationLink(destination: BookDetailView(item: item)) { label() }
        }
    }

    /// iPhone Duo (§3): whether this book is the one in the split view's detail column.
    private func isInDetail(_ item: LibraryItem) -> Bool {
        detailSelection?.wrappedValue?.id == item.id
    }

    private func isInDetail(_ slot: LibraryPageWindow.Slot) -> Bool {
        if case .item(let item) = slot { return isInDetail(item) }
        return false
    }

    /// One grid slot: a book tile (a link, or a selection toggle in select mode) or a
    /// placeholder tile for a page not loaded yet (plan §5).
    @ViewBuilder
    private func gridSlot(_ slot: LibraryPageWindow.Slot, index: Int, compact: Bool, canFetch: Bool) -> some View {
        switch slot {
        case .item(let item):
            let mp = libraryViewModel.progressFor(itemId: item.id)
            // Item 10 (REVIEW-2026-09-09.md): the two download reads used to sit
            // right here, in this grid's own body. `DownloadManager.progress(for:)`
            // and `isDownloading(itemId:)` both read `activeDownloads`, which is
            // rewritten on every progress callback of every transfer — so one
            // download in flight re-ran this whole `LazyVGrid` body (every visible
            // tile's `progressFor` lookups, `shelfCoverURL`, the lot) at the
            // download delegate's callback rate. `LibraryGridTile` reads the
            // manager itself, the way `LibraryListRow` further down this file
            // already does, so a progress callback invalidates the tiles and
            // nothing above them. Same `CassetteTile`, same arguments.
            // Critique 2026-10-05 (Library): the progress was zeroed for a finished
            // book and no finished state was passed, so a finished book looked
            // identical to one never started. `isFinished` is the real state.
            let tile = LibraryGridTile(
                item: item,
                progress: mp?.progress ?? item.progressPercent,
                isFinished: mp?.isFinished ?? item.isFinished,
                isNowPlaying: playerViewModel.currentBook?.id == item.id,
                isPlaying: playerViewModel.isPlaying,
                compact: compact,
                selectionState: isSelecting ? (selection.contains(item.id) ? .selected : .unselected) : nil
            )
            if isSelecting {
                // Library browse plan §3.2: SwiftUI has no grid selection, so the grid builds
                // its own, as Photos does — each tile toggles instead of navigating.
                // `CassetteTile` carries the selected trait and the select/deselect hint.
                Button {
                    toggleSelection(item)
                } label: {
                    tile
                }
                .buttonStyle(.plain)
            } else {
                bookLink(item) {
                    tile
                        // iPhone Duo (§3): the open book's quiet "you are here" mark — the
                        // list row's `shelfSurface` fill, as a plate behind the tile. Not the
                        // amber 2 pt cover ring, which is bulk-select's "chosen" mark.
                        .background {
                            if isInDetail(item) {
                                RoundedRectangle(cornerRadius: Radius.chip + 6)
                                    .fill(Color.shelfSurface)
                                    .padding(-6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .bookContextMenu(item)
            }
        case .placeholder(_, let state):
            LibraryPlaceholderTile(index: index, state: state, offline: !canFetch, compact: compact) {
                libraryViewModel.retryPage(containing: index)
            }
            .onAppear { placeholderAppeared(index, span: gridColumnCount * 6) }
        }
    }


    // MARK: - Search Results

    private var searchResultsView: some View {
        // Critique 2026-10-05 (Library): rows are plain (cover, text, divider) like the list
        // layout's rows instead of each sitting in its own card (Fewer Containers).
        // Batch 490 (REVIEW 2026-11-11 L7): the previous results stay on screen while the
        // next keystroke's request runs; the spinner only shows when there's nothing yet.
        let hasAnyResult = !libraryViewModel.searchResults.isEmpty
            || !libraryViewModel.searchAuthors.isEmpty || !libraryViewModel.searchNarrators.isEmpty
        return LazyVStack(spacing: 0) {
            if libraryViewModel.isSearching && !hasAnyResult {
                LoadingView("Searching\u{2026}")
            } else if !hasAnyResult {
                searchEmptyState
            } else {
                searchStatusNote
                ForEach(libraryViewModel.searchResults) { item in
                    bookLink(item) {
                        SearchResultRow(item: item)
                    }
                    .buttonStyle(.plain)
                    // L4 (REVIEW_2026-08-20_UI_SECURITY.md): this was the only book-
                    // listing surface with no context menu and no swipe actions —
                    // search is exactly where "found it, queue it" is the intent.
                    .bookContextMenu(item)
                    Divider().overlay(Color.shelfMuted.opacity(0.2))
                    // Batch 490 (REVIEW 2026-11-11 L1): the old note here said the search
                    // endpoint couldn't be limited or paged. It takes `limit` (ABS's
                    // `LibraryController.search`: `req.query.limit || 12`), so the request now
                    // asks for `AudiobookshelfAPI.searchResultLimit` (50). It still has no
                    // page cursor, so there's no "load more" here.
                }
                searchPeopleSection(title: "Authors", people: libraryViewModel.searchAuthors, isAuthor: true)
                searchPeopleSection(title: "Narrators", people: libraryViewModel.searchNarrators, isAuthor: false)
            }
        }
        .padding(.horizontal, Space.pageH)
        .padding(.vertical, 12)
        .padding(.bottom, bottomInset)
    }

    /// Batch 490 (REVIEW 2026-11-11 L1): the author or narrator matches of an online search,
    /// under the book list. Each row opens that person's books, as Library's Authors and
    /// Narrators modes do. Hidden when the group is empty (and always for a podcast library).
    @ViewBuilder
    private func searchPeopleSection(title: LocalizedStringResource, people: [AudiobookshelfAPI.SearchGroups.Person], isAuthor: Bool) -> some View {
        if !people.isEmpty {
            RetroSectionHeader(title: title)
                .padding(.top, Space.l)
                .padding(.bottom, 4)
            ForEach(people, id: \.self) { person in
                if isAuthor, let id = person.id {
                    LibraryRouteLink(.author(NamedEntity(id: id, name: person.name)), bottomInset: bottomInset) {
                        SearchPersonRow(person: person, isAuthor: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    LibraryRouteLink(.narrator(person.name), bottomInset: bottomInset) {
                        SearchPersonRow(person: person, isAuthor: false)
                    }
                    .buttonStyle(.plain)
                }
                Divider().overlay(Color.shelfMuted.opacity(0.2))
            }
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 L7): the rows under an empty search field. Books only (the
    /// other modes filter their own list as you type). Each row fills the field through
    /// `searchCompletion`; Clear has none, so it isn't a completion, just a button.
    @ViewBuilder
    private var searchSuggestionRows: some View {
        if browseMode == .books, searchText.isEmpty {
            if searchScope == .ask {
                Section("Try asking") {
                    ForEach(RecentLibrarySearches.askExamples, id: \.self) { example in
                        Label {
                            Text(verbatim: example)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .searchCompletion(example)
                    }
                }
            } else if !recentSearches.isEmpty {
                Section {
                    ForEach(recentSearches, id: \.self) { query in
                        Label {
                            Text(verbatim: query)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .searchCompletion(query)
                    }
                    Button {
                        recentSearches = RecentLibrarySearches.clear()
                    } label: {
                        Text("Clear")
                            .foregroundStyle(Color.shelfAmberText)
                    }
                    .accessibilityLabel(Text("Clear recent searches"))
                } header: {
                    Text("Recent searches")
                }
            }
        }
    }

    /// Batch 445: starts an Ask search for the current text. Local: only the snapshot fetch touches the server.
    private func runAskIfNeeded() {
        guard browseMode == .books, searchScope == .ask,
              !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let libraryId = libraryViewModel.selectedLibrary?.id else { return }
        let text = searchText
        let viewModel = libraryViewModel
        Task {
            await moodSearch.ask(text, libraryId: libraryId) { item in
                viewModel.progressFor(itemId: item.id) ?? item.mediaProgress
            }
        }
    }

    /// Batch 445: results of an Ask search, as a plain book list with a one-line reason per book.
    @ViewBuilder
    private var askResultsView: some View {
        LazyVStack(spacing: 0) {
            if moodSearch.phase == .searching {
                LoadingView("Searching\u{2026}")
            } else if moodSearch.phase == .failed {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: LocalizedStringResource("Couldn\u{2019}t load your library"),
                    subtitle: LocalizedStringResource("Ask reads every book in your library, which needs your server."),
                    actionTitle: LocalizedStringResource("Retry"),
                    action: { runAskIfNeeded() }
                )
            } else if moodSearch.answeredText != searchText || moodSearch.phase == .idle {
                ContentUnavailableView(
                    String(localized: "Ask Your Library", comment: "Ask search: title before a question is sent"),
                    systemImage: "sparkles",
                    description: Text("Describe what you feel like, then tap Search. For example \u{201C}something cosy under 8 hours\u{201D}."))
            } else if moodSearch.matches.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                if let understood = moodSearch.understood {
                    let summary = MoodReasonText.understood(understood)
                    if !summary.isEmpty {
                        Typo.fine(Text(verbatim: summary))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)
                    }
                }
                // Batch 490 (REVIEW 2026-11-11 E6): Ask reads at most `snapshotCap` books;
                // say so rather than imply the whole library was checked. Same string as
                // the smart-filter note.
                if moodSearch.snapshotIsPartial {
                    Typo.fine(Text("Checked the first \(MoodSearchViewModel.snapshotCap) books only"))
                        .foregroundStyle(Color.shelfMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                }
                ForEach(moodSearch.matches) { match in
                    bookLink(match.item) {
                        MoodResultRow(match: match)
                    }
                    .buttonStyle(.plain)
                    .bookContextMenu(match.item)
                    Divider().overlay(Color.shelfMuted.opacity(0.2))
                }
            }
        }
        .padding(.horizontal, Space.pageH)
        .padding(.vertical, 12)
        .padding(.bottom, bottomInset)
    }

    /// Critique 2026-10-05 (Library): three different situations used to render as "No
    /// results": nothing matched, the server couldn't be reached, and the device was
    /// offline. They are different, and only one of them is fixed by a different search term.
    @ViewBuilder
    private var searchEmptyState: some View {
        if libraryViewModel.searchFailed {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: LocalizedStringResource("Couldn\u{2019}t reach your server"),
                subtitle: LocalizedStringResource("Search needs your server. No downloaded books match either."),
                actionTitle: LocalizedStringResource("Retry"),
                action: { Task { await libraryViewModel.search() } }
            )
        } else if libraryViewModel.searchIsLocal {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No downloaded matches",
                subtitle: "You\u{2019}re offline, so only downloaded books are searched.",
                actionTitle: "Clear Search",
                action: { searchText = "" }
            )
        } else {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No results",
                subtitle: "Try a different search term",
                actionTitle: "Clear Search",
                action: { searchText = "" }
            )
        }
    }

    /// One quiet line above results that came from the downloaded books on this device
    /// rather than the server (offline), with Retry when the server request itself failed.
    @ViewBuilder
    private var searchStatusNote: some View {
        if libraryViewModel.searchFailed || libraryViewModel.searchIsLocal {
            HStack(spacing: 8) {
                Typo.supporting(Text(libraryViewModel.searchFailed
                    ? "Couldn\u{2019}t reach your server. Showing downloaded matches."
                    : "Offline. Searching downloaded books only."))
                    .foregroundStyle(Color.shelfMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if libraryViewModel.searchFailed {
                    Button("Retry") { Task { await libraryViewModel.search() } }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(minHeight: 44)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Download activity toolbar badge

/// Item 13 (REVIEW-2026-09-09.md): used to be a computed property on `LibraryView`
/// (`downloadActivityBadge`) gated by an `if !downloadManager.activeDownloads.isEmpty ||
/// !downloadManager.failedDownloads.isEmpty` check in the toolbar builder — both reads
/// happened during `LibraryView.body`'s own evaluation, so every progress callback of
/// every in-flight download (the delegate's callback rate, not a per-second tick)
/// re-ran the *entire* Library body: the grid, the shelves, the chip row, all of it.
/// Same defect, same fix shape as `LibraryGridTile`/`LibraryListRow` further down this
/// file (Item 10): pull the observed reads into their own small view so a progress tick
/// invalidates only this badge.
///
/// `LibraryView`'s toolbar now includes this type unconditionally; when there's nothing
/// to show it renders `EmptyView()`, which contributes no width to the toolbar — the
/// same "not there at all" result the old `if` around the call site produced, just with
/// the decision made inside this view's body instead of the parent's.
private struct DownloadActivityBadge: View {
    var bottomInset: CGFloat = 0
    @State private var downloadManager = DownloadManager.shared

    private func summary(active: Int, failed: Int) -> String {
        var parts: [String] = []
        if active > 0 { parts.append(String(localized: "\(active) downloading", comment: "Accessibility summary of the Library downloads button; %lld is the number of active downloads")) }
        if failed > 0 { parts.append(String(localized: "\(failed) failed", comment: "Accessibility summary of the Library downloads button; %lld is the number of failed downloads")) }
        return parts.isEmpty
            ? String(localized: "Downloads", comment: "Accessibility label of the Library toolbar button that opens Downloads")
            : String(localized: "Downloads: \(parts.joined(separator: ", "))", comment: "Accessibility label of the Library downloads button while transfers are active; %@ is a list such as '2 downloading, 1 failed'")
    }

    var body: some View {
        let activeCount = downloadManager.activeDownloads.count
        let failedCount = downloadManager.failedDownloads.count
        LibraryRouteLink(.downloads, bottomInset: bottomInset) {
            // iPhone Duo (§2): a Label (icon-only in the nav bar) so the item has a title;
            // the badge ZStack is its icon.
            Label {
                Text(summary(active: activeCount, failed: failedCount))
            } icon: {
            ZStack(alignment: .topTrailing) {
                // HIG audit 2026-09-17 L17: the failure state (`shelfOrangeInk`) is a
                // meaningful status colour and stays; the default glyph (no failures)
                // was amber chrome with no status to encode, so it goes monochrome.
                // LG-2 (docs/visual-design-review.md, Round V1): a circle-variant glyph
                // inside a glass toolbar button draws a ring inside a ring on iOS 26/27
                // — use the plain symbol; the glass container already supplies the ring.
                Image(systemName: failedCount > 0 ? "exclamationmark.triangle.fill" : "arrow.down")
                    // DESIGN.md (orange rule): `shelfOrangeInk` is the ink drawn *on* an orange
                    // fill (near-black or white), so on glass it never read as orange. The
                    // warning glyph itself is `shelfOrange`.
                    .foregroundStyle(failedCount > 0 ? Color.shelfOrange : Color.shelfCream)
                if activeCount + failedCount > 0 {
                    // Critique 2026-10-05 (Library, 2nd): was a fixed 10 pt; now a text-style token (12 pt at default).
                    Typo.figure(Text("\(activeCount + failedCount)"), weight: .bold)
                        .foregroundStyle(Color.onAccent)
                        .padding(3)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(failedCount > 0 ? Color.shelfOrange : Color.shelfAmber, in: Circle())
                        .offset(x: 10, y: -8)
                }
            }
            // HIG audit 2026-09-17 L3: icon-only label had no explicit tap-target
            // frame (Apple's 44 pt minimum); the ZStack's natural size just centers
            // in the larger frame, so the icon/badge stay positioned exactly as
            // before relative to each other.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            }
        }
        // iPhone Duo (§2): as a Label, the bar draws the icon in the item's tint and ignores
        // the glyph's own `foregroundStyle`, so the state colour is set on the item itself.
        .tint(failedCount > 0 ? Color.shelfOrange : Color.shelfCream)
        .foregroundStyle(failedCount > 0 ? Color.shelfOrange : Color.shelfCream)
        .accessibilityHint("Opens your downloads")
    }
}

// MARK: - Library Filter Sheet (redesigned per user feedback, 26 August 2026)

/// Replaces the old `libraryOptionsMenu` cascading `Menu`. First redesign (still
/// direct user feedback, same day) put all four concerns — Smart Filters, Sort,
/// Progress Filter + Downloaded-only, Display — into one scrolling `List` with a
/// `Section` each; user feedback on THAT was "sheet feels cluttered or too long," even
/// split into sections. This version cuts what's on screen at once two ways: (1) a
/// segmented `FilterTab` picker at the top shows exactly one of Filters/Sort/Display at
/// a time instead of stacking all three vertically — roughly a third the scroll length
/// of the previous version for the same total content; (2) Smart Filters (8 options,
/// previously 8 full-width `List` rows) are now a 2-column grid of compact chips, about
/// half the vertical height for the same choices. `@AppStorage` keys (not bindings
/// passed in) so this stays in sync with `LibraryView`'s own copies of
/// `libraryLayout`/`libraryGridDensity` automatically — both read/write the same
/// underlying `UserDefaults` key.
struct LibraryFilterSheet: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.dismiss) private var dismiss
    // R4 (REVIEW_2026-09-04_UI.md)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(SettingsKeys.libraryLayout) private var libraryLayout = "grid"
    @AppStorage(SettingsKeys.libraryGridDensity) private var libraryGridDensity = "comfortable"
    @State private var tab: FilterTab = .filters
    private enum FilterTab: String, CaseIterable, Identifiable {
        case filters = "Filters"
        case sort = "Sort"
        case display = "Display"
        var id: String { rawValue }
        /// `rawValue` stays the identifier; this is the visible, localizable segment name.
        var title: LocalizedStringKey {
            switch self {
            case .filters: return "Filters"
            case .sort: return "Sort"
            case .display: return "Display"
            }
        }
    }

    private var anyFilterActive: Bool {
        libraryViewModel.smartFilter != nil
            || libraryViewModel.progressFilter != .all
            || libraryViewModel.downloadedOnly
    }

    /// F1 (REVIEW_2026-09-04_UI.md): a Smart Filter takes over `displayedItems`
    /// outright (`LibraryView.displayedItems`), so Progress / Downloaded-only / Sort
    /// have no effect while one is active — but the controls stayed enabled with no
    /// indication of that. Used to disable + caption those groups rather than change
    /// any actual filtering behavior.
    private var smartFilterActive: Bool {
        libraryViewModel.smartFilter != nil
    }

    /// F3 (REVIEW_2026-09-04_UI.md): mirrors `LibraryView.displayedItems` — the
    /// source of truth for what's actually shown — without threading
    /// `DownloadManager` through here. `LibraryView` reads it via its own
    /// `@State private var downloadManager = DownloadManager.shared`, which is
    /// view-local state, so per the fix's own fallback this duplicates the 5-line
    /// composition against the shared singleton directly rather than promoting it
    /// onto `LibraryViewModel`.
    ///
    /// Critique 2026-10-05 (Library): this used `items.count` — the number of *pages loaded
    /// so far* (50, 100, ...) — as the headline "N books". It now reads the server total
    /// (and the filtered/sorted download set when "Downloaded only" is on) through the
    /// same view-model composition the grid uses.
    private var resultCount: Int {
        libraryViewModel.totalResultCount(
            downloads: libraryViewModel.showsLocalDownloads ? DownloadManager.shared.downloadedLibraryItems() : []
        )
    }

    /// Critique 2026-10-05 (Library): "Recently Played" swaps the library for the in-progress
    /// list, which has no progress filter and no direction. Those controls say so instead of
    /// staying live and doing nothing.
    private var recentSortActive: Bool {
        libraryViewModel.smartFilter == nil && libraryViewModel.sortOption.isRecentlyPlayed
    }

    /// F3 (REVIEW_2026-09-04_UI.md): the count line shows "Loading…" instead of "No
    /// books match" while the relevant source list is still being fetched, matching
    /// whichever branch `resultCount` above is reading from.
    private var isLoadingResults: Bool {
        libraryViewModel.smartFilter != nil
            ? libraryViewModel.isLoadingSmartFilter
            : libraryViewModel.isLoadingItems
    }

    /// F3 (REVIEW_2026-09-04_UI.md): pure copy function, pinned by
    /// `LibraryFilterSheetCopyTests`. No "shown" suffix — kept parallel with the
    /// zero-result case ("No books match"), which reads oddly as "0 books shown".
    static func resultCountLabel(_ n: Int) -> String {
        switch n {
        case 0: return String(localized: "No books match", comment: "Result count line in the Library filter sheet when nothing matches")
        case 1: return String(localized: "1 book", comment: "Result count line in the Library filter sheet for exactly one book")
        default: return String(localized: "\(n) books", comment: "Result count line in the Library filter sheet; %lld is the number of books")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(FilterTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Space.pageH)
                // Trimmed a little (26 August 2026, alongside filtersTab's own cuts)
                // to free a few more points for whichever tab is active at `.medium`.
                .padding(.top, 8)
                .padding(.bottom, 6)

                // F3 (REVIEW_2026-09-04_UI.md): a live result count, visible on every
                // tab (not just Filters) since Sort/Display changes affect it too.
                Text(isLoadingResults ? String(localized: "Loading…", comment: "Placeholder for the result count in the Library filter sheet while results load") : Self.resultCountLabel(resultCount))
                    .font(.footnote)
                    .foregroundStyle(Color.shelfMuted)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.pageH)
                    .padding(.bottom, 6)

                // Bug fix, take 2 (26 August 2026): the `.frame(maxHeight: .infinity,
                // alignment: .top)` tried here previously did NOT fix the confirmed
                // top-of-sheet overlap — user still saw it clipped after that change.
                // That fix targeted the wrong layer: it controls how this VStack
                // positions itself *within* the space it's given, not how
                // `NavigationStack` positions this (possibly oversized) VStack within
                // *its* content slot — and an unbounded VStack with no scroll
                // container has no forced clip boundary, so an oversized one can still
                // render past the top of the area below the inline nav bar regardless
                // of that inner alignment.
                // The actual fix is what was here before Batch 235 removed it: a
                // `ScrollView` is the primitive that clips/bounds oversized content to
                // its container and anchors it to the top, which is exactly the
                // guarantee needed. `.scrollBounceBehavior(.basedOnSize)` keeps it from
                // ever feeling "scrollable" when content fits (no bounce, no
                // indicator) — it only actually scrolls if a tab's content genuinely
                // exceeds the sheet's height at the current detent, which is a much
                // better failure mode than clipping content the user can't reach.
                ScrollView {
                    switch tab {
                    case .filters: filtersTab
                    case .sort: sortTab
                    case .display: displayTab
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle("Filters & Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // F5 (REVIEW_2026-09-04_UI.md): hoisted out of `filtersTab` so
                // Reset is reachable from every tab, not just Filters.
                ToolbarItem(placement: .topBarLeading) {
                    if anyFilterActive {
                        Button {
                            Haptics.selection()
                            Task {
                                await libraryViewModel.selectSmartFilter(nil)
                                libraryViewModel.progressFilter = .all
                                libraryViewModel.downloadedOnly = false
                                await libraryViewModel.applySortFilter()
                            }
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise") // iPhone Duo (§2)
                        }
                        // Critique 2026-10-05 (Library, 2nd): Reset is chrome, not status;
                        // neutral per the Monochrome Chrome rule (was shelfOrange).
                        .monochromeToolbarItem()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() } // iPhone Duo (§2)
                        .monochromeToolbarItem()
                }
            }
        }
        // Reverted the per-tab adaptive detent (26 August 2026): back to a plain
        // `.medium`/`.large` with no forced switch to `.large` for Filters. Trimmed
        // `filtersTab`'s own spacing/padding below instead so its content actually
        // fits at `.medium` — see that view's doc comment for the specific cuts.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Filters tab (Smart Filters grid + Progress + Downloaded-only)

    private var filtersTab: some View {
        // User feedback (26 August 2026): "make it not scrollable since everything can
        // fit in the popup" — dropped the `ScrollView` wrapper this used to have (the
        // Sort/Display tabs never had one; this is the only tab that did, left over
        // from the earlier single-scrolling-List version). Plain `VStack`, matching
        // the other two tabs.
        //
        // Code review follow-up (26 August 2026): a `ScrollView` was reinstated one
        // level up, at `LibraryFilterSheet.body`, as the actual fix for the nav-bar
        // overlap bug this caused — but this tab's own content still ran to roughly
        // 480pt against `.medium`'s ~426pt, so it would always need to scroll there.
        // Per request, trimmed this tab's spacing/padding (22→14 between sections,
        // 10→8 within them, grid spacing 8→6, and the vertical padding on the
        // Downloaded-only row/Reset button and the outer `.padding` below) to close
        // most of that gap while keeping every tap target at its accessibility
        // minimum (chips and the toggle row both still hit 44pt). Whatever gap
        // remains in the worst case (every chip label wrapping to 2 lines, Reset
        // showing) still resolves gracefully via that outer `ScrollView`.
        VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    // F4 (REVIEW_2026-09-04_UI.md)
                    RetroSectionHeader(title: "Smart Filters")
                    // 2-column chip grid instead of 8 full-width `List` rows — the
                    // single biggest contributor to the previous version's "too long"
                    // feedback, since these 8 options alone were 8 rows tall.
                    // R4 (REVIEW_2026-09-04_UI.md): a fixed 2-column grid left every
                    // chip label truncated at accessibility sizes ("Down-loade…",
                    // "No Progr…") — a single flexible column gives each chip the full
                    // width it needs to wrap instead.
                    // Follow-up to Batch 319/320 (CHANGES_IMPLEMENTED.md): the Home
                    // Smart Filters shelf that used to show a live "N books" count
                    // now defaults to hidden, so this grid is most users' only
                    // remaining route to Smart Filters. `smartFilterCounts` is read
                    // once per `filtersTab` render (not once per chip) — matching
                    // `cachedSmartFilterCounts()`'s own doc comment that it's an
                    // O(filters × library) pass fine to call when something changed,
                    // not fine on a hot per-chip path.
                    let smartFilterCounts = libraryViewModel.cachedSmartFilterCounts()
                    LazyVGrid(
                        columns: dynamicTypeSize.isAccessibilitySize
                            ? [GridItem(.flexible())]
                            : [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 6
                    ) {
                        ForEach(SmartFilter.allCases) { filter in
                            smartFilterChip(filter, counts: smartFilterCounts)
                        }
                    }

                    // F2 (REVIEW_2026-09-04_UI.md)
                    if let f = libraryViewModel.smartFilter {
                        Typo.supporting(Text(f.subtitle))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    } else {
                        // Follow-up to Batch 319/320: nothing else here explains what
                        // the chips do or where the counts come from now that the
                        // Home shelf (which used to carry that context) is hidden by
                        // default. One line, `.caption2` (smaller than the active
                        // subtitle above) to hold the sheet's height discipline —
                        // history in this struct's own header comment is "sheet feels
                        // cluttered or too long."
                        Typo.fine(Text("Tap a Smart Filter to browse it."))
                            .foregroundStyle(Color.shelfMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    // F4 (REVIEW_2026-09-04_UI.md)
                    RetroSectionHeader(title: "Progress")
                    Picker("Progress", selection: Binding(
                        get: { libraryViewModel.progressFilter },
                        set: { newValue in
                            libraryViewModel.progressFilter = newValue
                            Task { await libraryViewModel.applySortFilter() }
                        }
                    )) {
                        ForEach(LibraryProgressFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    // F1 (REVIEW_2026-09-04_UI.md)
                    .disabled(smartFilterActive || recentSortActive)
                    .opacity(smartFilterActive || recentSortActive ? 0.45 : 1)
                    if recentSortActive {
                        Typo.supporting(Text("Not used while sorting by Recently Played"))
                            .foregroundStyle(Color.shelfMuted)
                    }

                    Toggle(isOn: Binding(
                        get: { libraryViewModel.downloadedOnly },
                        set: { libraryViewModel.downloadedOnly = $0 }   // client-side; no reload
                    )) {
                        Label("Downloaded only", systemImage: "arrow.down.circle")
                            .foregroundStyle(Color.shelfCream)
                    }
                    // P-6 (REVIEW_2026-09-14_DESIGN.md): 12pt literal → `Space.m`, no visual change.
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 8)
                    .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card))
                    // F1 (REVIEW_2026-09-04_UI.md)
                    .disabled(smartFilterActive)
                    .opacity(smartFilterActive ? 0.45 : 1)

                    // F1 (REVIEW_2026-09-04_UI.md)
                    if smartFilterActive {
                        Typo.supporting(Text("Not used while a Smart Filter is on"))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }

                // F5 (REVIEW_2026-09-04_UI.md): "Reset All Filters" moved to a
                // toolbar item on `body` so it's reachable from every tab, not just
                // Filters — removed here to keep a single Reset control.
        }
        .padding(.horizontal, Space.pageH)
        .padding(.vertical, 12)
    }

    /// What number (if any) belongs on a chip. The active filter prefers its own live
    /// `smartFilterItems.count` over the cached bulk-snapshot count whenever that count
    /// isn't mid-fetch — it's the exact list the sheet's own result-count line already
    /// shows, so the active chip and that line never disagree. Every other chip has no
    /// live list to read, so it falls back to the snapshot `cached` passed in (built
    /// once per `filtersTab` render by `cachedSmartFilterCounts()`, which is `[:]`
    /// until some filter has been opened this session — see that function's own doc
    /// comment for why it deliberately never fetches).
    private func smartFilterChipCount(for filter: SmartFilter, isActive: Bool, cached: [SmartFilter: Int]) -> Int? {
        if isActive && !libraryViewModel.isLoadingSmartFilter {
            return libraryViewModel.smartFilterItems.count
        }
        return cached[filter]
    }

    /// Pure copy for a chip's optional trailing count — nil hides the count entirely
    /// (no snapshot yet, or the active filter is still mid-fetch), while `0` is a
    /// legitimate "matches nothing right now" answer and must still render, not be
    /// treated as absent. Pinned by `LibraryFilterSheetCopyTests`.
    static func smartFilterChipCountText(_ count: Int?) -> String? {
        guard let count else { return nil }
        return "\(count)"
    }

    /// Pure copy for a chip's VoiceOver label — folds in "<N> books" only when a count
    /// is available, so a chip with no count yet still just reads its plain label
    /// instead of a stale or misleading number. Selection is announced separately via
    /// `.accessibilityAddTraits(.isSelected)` on the chip itself (see `smartFilterChip`
    /// below), so this string deliberately doesn't also say "selected" — that would be
    /// VoiceOver announcing the same state twice. Pinned by
    /// `LibraryFilterSheetCopyTests`.
    static func smartFilterChipAccessibilityLabel(label: String, count: Int?) -> String {
        guard let count else { return label }
        let books = count == 1
            ? String(localized: "1 book", comment: "VoiceOver count phrase for exactly one book")
            : String(localized: "\(count) books", comment: "VoiceOver count phrase for several books; %lld is the count")
        return String(localized: "\(label), \(books)", comment: "VoiceOver label of a Smart Filter chip; first %@ is the filter name, second %@ is a count phrase like '12 books'")
    }

    /// A single Smart Filter as a compact, two-line-capable chip — tapping the already
    /// -active filter clears it (one tap on, the same tap off, instead of needing a
    /// separate "Clear" row to find first).
    ///
    /// Follow-up to Batch 319/320 (CHANGES_IMPLEMENTED.md): now shows a trailing
    /// match count when one is free (see `smartFilterChipCount(for:isActive:cached:)`),
    /// matching what the Home Smart Filters shelf already does for its own cards. At
    /// accessibility sizes the count moves to its own line under the label rather than
    /// sharing the label's row, so it can never be the thing that forces truncation —
    /// R4's fix for this same chip (the 2-line wrap below) is otherwise untouched.
    private func smartFilterChip(_ filter: SmartFilter, counts: [SmartFilter: Int]) -> some View {
        let isActive = libraryViewModel.smartFilter == filter
        let count = smartFilterChipCount(for: filter, isActive: isActive, cached: counts)
        let countText = Self.smartFilterChipCountText(count)
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let mutedTint = isActive ? Color.onAccent.opacity(0.75) : Color.shelfMuted
        return Button {
            Haptics.selection()
            Task { await libraryViewModel.selectSmartFilter(isActive ? nil : filter) }
        } label: {
            HStack(spacing: 6) {
                Typo.supporting(Image(systemName: filter.icon))
                VStack(alignment: .leading, spacing: 2) {
                    Text(filter.label)
                        .font(.footnote.weight(.medium))
                        // R4 (REVIEW_2026-09-04_UI.md): let the label wrap freely at
                        // accessibility sizes instead of truncating at 2 lines.
                        .lineLimit(isAccessibilitySize ? nil : 2)
                        .minimumScaleFactor(0.9)
                        .multilineTextAlignment(.leading)
                    // Accessibility sizes: the count gets its own line instead of
                    // fighting the label for width on the same row, so it's never
                    // the reason a wrapped label gets squeezed or truncated.
                    if isAccessibilitySize, let countText {
                        Typo.figure(Text("\(countText) books"), fine: true)
                            .foregroundStyle(mutedTint)
                    }
                }
                Spacer(minLength: 0)
                // Compact sizes: trailing count stays on the label's own row —
                // there's room, and it keeps the chip visually one line tall.
                if !isAccessibilitySize, let countText {
                    Text(countText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(mutedTint)
                }
            }
            .foregroundStyle(isActive ? Color.onAccent : Color.shelfCream)
            // P-6 (REVIEW_2026-09-14_DESIGN.md): deliberate one-off — no `Space.*` token
            // matches 10pt (s=8, m=12); this chip's two-line wrap math (see the vertical
            // padding comment just below) was tuned around this exact value.
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // `minHeight: 44` is the accessibility/HIG floor — untouched. The vertical
            // padding trim above only shaves height off 2-line-wrapped chip labels,
            // which already render taller than 44pt regardless of this padding.
            .frame(minHeight: 44, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Color.shelfAmber : Color.shelfCard,
                        in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.smartFilterChipAccessibilityLabel(label: filter.label, count: count))
        // R4 (REVIEW_2026-09-04_UI.md)
        .accessibilityHint(filter.subtitle)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Sort tab

    private var sortTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                // F4 (REVIEW_2026-09-04_UI.md)
                RetroSectionHeader(title: "Sort by")
                // `.menu` style, not `.inline` — 5 options as an always-expanded
                // inline list would add 5 rows of height to a sheet this redesign is
                // specifically trying to shorten; collapsed to one tappable row
                // (current value + chevron) that expands into a native menu overlay
                // on tap instead.
                Picker("Sort by", selection: Binding(
                    get: { libraryViewModel.sortOption },
                    set: { newValue in
                        libraryViewModel.sortOption = newValue
                        Task { await libraryViewModel.applySortFilter() }
                    }
                )) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(LibraryLocalQuery.sortOptionLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.shelfAmberText)
                // P-6 (REVIEW_2026-09-14_DESIGN.md): 12pt literal → `Space.m`, no visual change.
                .padding(.horizontal, Space.m)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card))
                // F1 (REVIEW_2026-09-04_UI.md)
                .disabled(smartFilterActive)
                .opacity(smartFilterActive ? 0.45 : 1)
                // F1 (REVIEW_2026-09-04_UI.md)
                if smartFilterActive {
                    Typo.supporting(Text("Not used while a Smart Filter is on"))
                        .foregroundStyle(Color.shelfMuted)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                // F4 (REVIEW_2026-09-04_UI.md)
                RetroSectionHeader(title: "Direction")
                Picker("Direction", selection: Binding(
                    get: { libraryViewModel.sortDescending },
                    set: { newValue in
                        libraryViewModel.sortDescending = newValue
                        Task { await libraryViewModel.applySortFilter() }
                    }
                )) {
                    // Code review fix (26 August 2026): `.pickerStyle(.segmented)`
                    // renders a `Label`'s image only, silently dropping its text — this
                    // read as two bare arrows with no "Ascending"/"Descending" visible
                    // anywhere. Plain `Text` tags instead.
                    Text("Ascending").tag(false)
                    Text("Descending").tag(true)
                }
                .pickerStyle(.segmented)
                // F1 (REVIEW_2026-09-04_UI.md)
                .disabled(smartFilterActive || recentSortActive)
                .opacity(smartFilterActive || recentSortActive ? 0.45 : 1)
                // F1 (REVIEW_2026-09-04_UI.md)
                if smartFilterActive {
                    Typo.supporting(Text("Not used while a Smart Filter is on"))
                        .foregroundStyle(Color.shelfMuted)
                } else if recentSortActive {
                    Typo.supporting(Text("Recently Played is always newest first"))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
        }
        .padding(Space.pageH)
    }

    // MARK: - Display tab

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                // Design review (14 Aug 2026), item 3: grid/list used to be its own
                // permanent nav bar icon — a display preference, not a frequent
                // per-session action.
                // F4 (REVIEW_2026-09-04_UI.md)
                RetroSectionHeader(title: "Layout")
                Picker("Layout", selection: $libraryLayout) {
                    // Code review fix (26 August 2026): same `.pickerStyle(.segmented)`
                    // + `Label` bug as the Sort tab's Direction picker — the segmented
                    // style shows only a `Label`'s icon, dropping "Grid"/"List" text
                    // entirely. Plain `Text` tags instead.
                    Text("Grid").tag("grid")
                    Text("List").tag("list")
                }
                .pickerStyle(.segmented)
            }

            // Stage 4 (REDESIGN_PROPOSAL_2026-08-26.md §4.1c): iPhone-only — see
            // `LibraryView.columns`' own doc comment for why this isn't offered on
            // iPad. Only shown in Grid layout, since it has no effect on List.
            if libraryLayout == "grid" && UIDevice.current.userInterfaceIdiom == .phone {
                VStack(alignment: .leading, spacing: 10) {
                    // F4 (REVIEW_2026-09-04_UI.md)
                    RetroSectionHeader(title: "Grid Density")
                    Picker("Grid Density", selection: $libraryGridDensity) {
                        Text("Comfortable").tag("comfortable")
                        Text("Compact").tag("compact")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .padding(Space.pageH)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: LibraryItem
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel

    // Critique 2026-10-05 (Library): the row read only the (often absent) progress on the
    // search payload, so a finished book showed nothing. Same resolution as the list rows.
    private var isFinished: Bool { libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished }
    private var progress: Double { libraryViewModel.progressFor(itemId: item.id)?.progress ?? item.progressPercent }

    /// UI-7: previously this row had no `accessibilityElement` at all, so VoiceOver
    /// emitted a separate, unlabelled stop for the cover image plus a separate stop for
    /// `CircularProgressView`'s own (also unlabelled, 8pt-and-unreadable-anyway) percent
    /// text — title, author, duration, and progress read as four-plus disconnected
    /// elements instead of one describable row.
    private var rowA11yLabel: String {
        var parts = [item.title, item.authorName]
        if playerViewModel.currentBook?.id == item.id {
            parts.append(playerViewModel.isPlaying
                ? String(localized: "now playing", comment: "VoiceOver fragment in a book row's label: this book is playing")
                : String(localized: "paused", comment: "VoiceOver fragment in a book row's label: this book is paused"))
        }
        if item.duration > 0 { parts.append(item.duration.formattedDuration) }
        if isFinished {
            parts.append(String(localized: "finished", comment: "VoiceOver fragment in a book row's label: the book is finished"))
        } else if progress > 0 {
            parts.append(String(localized: "\(Int(progress * 100)) percent through", comment: "VoiceOver fragment in a book row's label; %lld is the listening progress percentage"))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(itemId: item.id, width: 56, height: 56)
                .overlay {
                    if playerViewModel.currentBook?.id == item.id {
                        ZStack {
                            Color.black.opacity(0.3)
                            EqualizerBadge(animating: playerViewModel.isPlaying, color: Color.onAccent)
                                .padding(7)
                                .background(Color.shelfAmber, in: Circle())
                                .scaleEffect(0.8)
                        }
                        // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 8pt radius → `Radius.chip`.
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                        .allowsHitTesting(false)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                // Batch 218 (R9): was its own `.subheadline.weight(.medium))`
                // spelling of "book title in a row" — one of the five `Typo
                // .rowTitle`'s own doc comment lists as the review's unification
                // target. Now shares that token with `HomeView`'s rows.
                Typo.rowTitle(Text(item.title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)   // Polish pass (J3-9)

                Typo.rowSubtitle(Text(item.authorName))
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(1)

                if item.duration > 0 {
                    Typo.fine(Text(item.duration.formattedDuration))
                        .foregroundStyle(Color.shelfMuted)
                }
            }

            Spacer()

            if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.shelfAccent)
            } else if progress > 0 {
                CircularProgressView(progress: progress)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowA11yLabel)
    }
}

/// Batch 490 (REVIEW 2026-11-11 L1): one author or narrator match in Library search. Same
/// plain-row shape as `SearchResultRow`, with a symbol where the cover would be; one
/// VoiceOver element that reads as a link.
struct SearchPersonRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let person: AudiobookshelfAPI.SearchGroups.Person
    let isAuthor: Bool

    /// "1 book" / "12 books"; nil when the server sent no count. Pure.
    nonisolated static func bookCountText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 book", comment: "Library search: an author or narrator with one book")
            : String(localized: "\(count.formatted()) books", comment: "Library search: an author's or narrator's book count; %@ is a number such as 12")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isAuthor ? "person.fill" : "mic.fill")
                .font(.title3)
                .foregroundStyle(Color.shelfMuted)
                .frame(width: 56, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Typo.rowTitle(Text(verbatim: person.name))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if let count = Self.bookCountText(person.numBooks) {
                    Typo.fine(Text(verbatim: count))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.shelfMuted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [person.name, Self.bookCountText(person.numBooks)].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(isAuthor ? Text("Opens this author’s books") : Text("Opens this narrator’s books"))
    }
}

/// One tile in `LibraryView`'s grid.
///
/// Item 10 (REVIEW-2026-09-09.md): exists purely to own the per-item download reads. It
/// takes everything that doesn't change at download-progress frequency (the item, the
/// listening progress, the now-playing flags, the density) as plain values from the grid,
/// and reads `DownloadManager` itself for the two things that do. That's the same shape
/// `LibraryListRow` below already has, and it follows the same principle as
/// `DownloadsView`'s `ActiveDownloadRow` (which is handed one `DownloadTask` rather than
/// the whole dictionary): a progress tick should invalidate the badge that shows it, not
/// the screen around it.
///
/// `@State private var downloadManager = DownloadManager.shared` rather than an
/// `@Environment` — the singleton is view-local observable state, exactly as `LibraryView`
/// and `LibraryListRow` both hold it.
struct LibraryGridTile: View {
    let item: LibraryItem
    /// Critique 2026-10-05 (Library): optional subtitle override (the Author grid shows the
    /// series or duration instead of repeating the author on every tile). Nil = author.
    var subtitle: String? = nil
    let progress: Double
    var isFinished: Bool = false
    let isNowPlaying: Bool
    let isPlaying: Bool
    let compact: Bool
    /// Library browse plan §3.2 (2026-10-05): nil outside select mode.
    var selectionState: CassetteTile.SelectionState? = nil

    @State private var downloadManager = DownloadManager.shared

    var body: some View {
        CassetteTile(
            coverURL: shelfCoverURL(itemId: item.id),
            title: item.title,
            subtitle: subtitle ?? item.authorName,
            progress: progress,
            isFinished: isFinished,
            downloaded: downloadManager.isDownloaded(itemId: item.id),
            downloadProgress: downloadManager.isDownloading(itemId: item.id)
                ? downloadManager.progress(for: item.id) : nil,
            isNowPlaying: isNowPlaying,
            isPlaying: isPlaying,
            compact: compact,
            selectionState: selectionState
        )
    }
}

/// Critique 2026-10-05 (Library): the drill-down grids (Series detail, Author, Narrator,
/// Genre, Collection and Playlist) built bare `CassetteTile`s with no progress, download or
/// finished state, so a finished or downloaded book looked the same there as in Library.
/// This resolves that state the way Library's own grid does (server progress first, then
/// the item's own fields) and reuses `LibraryGridTile`, so the download reads stay in the
/// tile and a transfer tick doesn't re-run the surrounding grid.
struct BookGridTile: View {
    let item: LibraryItem
    var subtitle: String? = nil
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        let mp = libraryViewModel.progressFor(itemId: item.id)
        LibraryGridTile(
            item: item,
            subtitle: subtitle,
            progress: mp?.progress ?? item.progressPercent,
            isFinished: mp?.isFinished ?? item.isFinished,
            isNowPlaying: playerViewModel.currentBook?.id == item.id,
            isPlaying: playerViewModel.isPlaying,
            compact: false
        )
    }
}

// MARK: - Scroll to top on tab re-tap

/// Critique 2026-10-05 (Library): tab re-tap only scrolled the Books grid/list to the top;
/// every other scope reset navigation but left its scroll position. Wrap a scroll container
/// (any depth below) and give it the id of its first row.
private struct ScrollsToTopOnSignal<ID: Hashable>: ViewModifier {
    let signal: Int
    let firstID: ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: signal) { _, _ in
                guard let firstID else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(firstID, anchor: .top)
                }
            }
        }
    }
}

extension View {
    func scrollsToTop<ID: Hashable>(signal: Int, firstID: ID?) -> some View {
        modifier(ScrollsToTopOnSignal(signal: signal, firstID: firstID))
    }
}

// MARK: - Library list row (compact, for list layout)

struct LibraryListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: LibraryItem
    /// Deferred item (Batch 317, `CHANGES_IMPLEMENTED.md`): an optional trailing/
    /// secondary detail line rendered under the author name in `Color.shelfMuted`
    /// caption style — e.g. `DownloadsView`'s "Downloaded Books" section passes a
    /// duration string here (see `DownloadRowDetail` in `DownloadsView.swift`). Defaults
    /// to `nil` so every existing call site (`LibraryView`'s own list rows) is unchanged.
    var detail: String? = nil
    /// Library browse plan §3.2 (2026-10-05): false in select mode, where the list's edit
    /// mode owns the tap (select/deselect) and the row must not also push Book Detail.
    var navigates: Bool = true
    /// iPhone Duo (§3): when set (Library in the inner display's split view), a tap hands
    /// the book to this instead of pushing Book Detail. Nil everywhere else.
    var onOpen: ((LibraryItem) -> Void)? = nil
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var downloadManager = DownloadManager.shared

    /// UI-7: this row previously had no `accessibilityElement` at all — VoiceOver split
    /// it into the cover, title, author, an unlabelled `arrow.down.circle.fill`, an
    /// unlabelled `checkmark.circle.fill`, and (when neither applied) a bare "45%" from
    /// `CircularProgressView`'s own inline text, with no indication which number meant
    /// what. Built into one label instead, mirroring `CassetteTile.tileA11yLabel`'s
    /// grid-view equivalent.
    ///
    /// `detail` (Batch 317 follow-up) is folded in last, after the existing
    /// finished/progress/downloaded parts, so a VoiceOver user hears it as an
    /// additional fact about the row rather than displacing anything already announced.
    private func rowA11yLabel(finished: Bool, progress: Double, downloaded: Bool) -> String {
        var parts = [item.title, item.authorName]
        if playerViewModel.currentBook?.id == item.id {
            parts.append(playerViewModel.isPlaying
                ? String(localized: "now playing", comment: "VoiceOver fragment in a book row's label: this book is playing")
                : String(localized: "paused", comment: "VoiceOver fragment in a book row's label: this book is paused"))
        }
        if finished {
            parts.append(String(localized: "finished", comment: "VoiceOver fragment in a book row's label: the book is finished"))
        } else if progress > 0 {
            parts.append(String(localized: "\(Int(progress * 100)) percent through", comment: "VoiceOver fragment in a book row's label; %lld is the listening progress percentage"))
        }
        if downloaded { parts.append(String(localized: "downloaded", comment: "VoiceOver fragment in a book row's label: the book is downloaded")) }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let finished = libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
        let progress = libraryViewModel.progressFor(itemId: item.id)?.progress ?? item.progressPercent
        let downloaded = downloadManager.isDownloaded(itemId: item.id)
        Group {
            if navigates, let onOpen {
                Button { onOpen(item) } label: {
                    rowContent(finished: finished, progress: progress, downloaded: downloaded)
                }
                .buttonStyle(.plain)
            } else if navigates {
                NavigationLink(destination: BookDetailView(item: item)) {
                    rowContent(finished: finished, progress: progress, downloaded: downloaded)
                }
                .buttonStyle(.plain)
            } else {
                rowContent(finished: finished, progress: progress, downloaded: downloaded)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowA11yLabel(finished: finished, progress: progress, downloaded: downloaded))
    }

    private func rowContent(finished: Bool, progress: Double, downloaded: Bool) -> some View {
            HStack(spacing: 12) {
                CoverImageView(itemId: item.id, width: 52, height: 52)
                    .overlay {
                        if playerViewModel.currentBook?.id == item.id {
                            ZStack {
                                Color.black.opacity(0.3)
                                EqualizerBadge(animating: playerViewModel.isPlaying, color: Color.onAccent)
                                    .padding(6)
                                    .background(Color.shelfAmber, in: Circle())
                                    .scaleEffect(0.75)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                            .allowsHitTesting(false)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    // Batch 218 (R9): same unification as `SearchResultRow` above.
                    Typo.rowTitle(Text(item.title))
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)   // Polish pass (J3-9)
                    Typo.rowSubtitle(Text(item.authorName))
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(1)
                    // Batch 317 follow-up: the optional secondary detail line (see
                    // `detail`'s own doc comment above) — same muted caption treatment
                    // as the author line, one size down, so it reads as a subordinate
                    // fact rather than competing with title/author.
                    if let detail {
                        Typo.fine(Text(detail))
                            .foregroundStyle(Color.shelfMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if downloaded {
                    // iOS 26/27 Liquid Glass polish pass (26 August 2026): same
                    // `.symbolEffect(.bounce, value:)` treatment as the favorite-star
                    // icons in AuthorsBrowseView/NarratorsBrowseView — see that
                    // file's doc comment for the mount-vs-value-change caveat, which
                    // applies here too (this icon only mounts once `downloaded` is
                    // true).
                    Typo.supporting(Image(systemName: "arrow.down.circle.fill"))
                        .foregroundStyle(Color.shelfMuted)
                        .shelfSymbolBounce(value: downloaded)
                }
                if finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.shelfAccent)
                } else if progress > 0 {
                    CircularProgressView(progress: progress)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

// MARK: - Circular Progress

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            // CO-6 (docs/visual-design-review.md, Round V1): the track was nearly
            // invisible on the Light list background (under the 3:1 non-text floor).
            Circle()
                .stroke(Color.shelfMuted.opacity(0.35), lineWidth: 3)

            Circle()
                .trim(from: 0, to: min(progress, 1.0))
                .stroke(Color.shelfAmber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // UI-3: this used to render the percentage as an 8pt fixed-size `Text` crammed
        // inside a 28-32pt ring — unreadable at any text size, and it couldn't be made
        // Dynamic-Type-aware without the number itself outgrowing the ring it sits in.
        // Every call site already builds its own composite VoiceOver label that
        // includes this same percentage in words ("N percent through"), so rather than
        // duplicate that as a separate `accessibilityValue` here (and risk the two
        // drifting out of sync), this view is purely decorative for accessibility —
        // hidden so it doesn't also surface as its own unlabelled element.
        .accessibilityHidden(true)
    }
}

#Preview {
    LibraryView()
        .environment(LibraryViewModel())
        .environment(PlayerViewModel())
}


/// LG-5: pins the Library's scope picker in the top bar region on iOS 26+, so it shares the
/// search field's scroll-edge treatment instead of sitting in content below the bar's
/// hairline. Does nothing below iOS 26 (the caller keeps the picker in its own stack).
private struct LibraryScopeBar<Bar: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if enabled, #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top) { bar() }
        } else {
            content
        }
    }
}

private extension View {
    func libraryScopeBar<Bar: View>(enabled: Bool, @ViewBuilder bar: @escaping () -> Bar) -> some View {
        modifier(LibraryScopeBar(enabled: enabled, bar: bar))
    }
}

// MARK: - Books scroll tracking (Library browse plan §3.1, §6.3, 2026-10-05)

/// The Books grid/list's scroll state: the top visible slot, whether the user is scrolling,
/// and the debounced page-load request. An observable object rather than `@State` values on
/// `LibraryView`, so a scroll re-renders only the scrubber overlay that reads it.
@MainActor
@Observable
final class LibraryScrollTracker {
    /// Top-most visible slot index (0-based).
    var topIndex: Int = 0
    /// True while scrolling and for 1.5 s after it stops (plan §3.1 "Rest").
    private(set) var isScrolling = false

    /// List rows currently on screen (iOS 17 has no visible-row API for `List`).
    @ObservationIgnored var visibleRows: Set<Int> = []
    /// iOS 18+: the scroll phase says a gesture is still in progress, so don't fade.
    @ObservationIgnored private var phaseActive = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    /// How long the scrubber lingers after scrolling stops, as the system indicator does.
    static let lingerNanoseconds: UInt64 = 1_500_000_000
    /// Library browse plan §3.1 (2026-10-05): the dwell before a page fetch.
    static let dwellNanoseconds: UInt64 = 300_000_000

    /// Scroll position moved (any OS): show, and fade 1.5 s after the last movement unless
    /// the iOS 18 scroll phase says a gesture is still going.
    func noteActivity() {
        if !isScrolling { isScrolling = true }
        if !phaseActive { scheduleHide() }
    }

    /// iOS 18+ (`onScrollPhaseChange`, iOS 18.0): scrolling started or stopped.
    func phaseChanged(isScrolling scrolling: Bool) {
        phaseActive = scrolling
        if scrolling {
            hideTask?.cancel()
            if !isScrolling { isScrolling = true }
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LibraryScrollTracker.lingerNanoseconds)
            guard !Task.isCancelled, let self else { return }
            if self.isScrolling { self.isScrolling = false }
        }
    }

    /// Runs `work` once nothing newer has been requested for the dwell interval. The latest
    /// request wins, so a fling or a scrubber drag fetches only where it comes to rest.
    func scheduleFetch(_ work: @escaping @MainActor () -> Void) {
        fetchTask?.cancel()
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: LibraryScrollTracker.dwellNanoseconds)
            guard !Task.isCancelled else { return }
            work()
        }
    }

    /// Back to the top with nothing pending (sort, filter, library or account change).
    func reset() {
        fetchTask?.cancel()
        visibleRows = []
        if topIndex != 0 { topIndex = 0 }
    }
}

/// iOS 18+: drive the scrubber's show/hide from the scroll phase (`onScrollPhaseChange(_:)`,
/// iOS 18.0, Apple docs). On iOS 17 the tracker falls back to "show on position change,
/// fade 1.5 s after the last change" (plan §6.3).
struct LibraryScrollPhaseTracking: ViewModifier {
    let tracker: LibraryScrollTracker

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                tracker.phaseChanged(isScrolling: newPhase.isScrolling)
            }
        } else {
            content
        }
    }
}

/// The only reader of `LibraryScrollTracker`'s observed state, so a scroll re-renders this
/// and not `LibraryView`. Hosts `LibraryPositionScrubber` (plan §3.1).
///
/// Hit testing: the scrubber lays itself out 120 pt wide (room for its bubble) with a
/// full-frame content shape. This overlay gives it a 44 pt frame on the trailing edge and
/// limits hit testing to that strip, so taps on tiles under the bubble's side still land
/// while the scrubber is visible. The bubble still draws outside the strip (no clipping).
struct LibraryScrubberOverlay: View {
    let tracker: LibraryScrollTracker
    let count: Int
    let columns: Int
    /// VoiceOver on: always shown and focusable (plan §3.1 "Always present for VoiceOver").
    let alwaysVisible: Bool
    let onJump: (Int) -> Void

    var body: some View {
        let visible = alwaysVisible || tracker.isScrolling
        LibraryPositionScrubber(
            count: count,
            currentIndex: min(max(tracker.topIndex, 0), max(count - 1, 0)),
            onJump: onJump,
            isVisible: visible,
            columns: columns,
            pageSize: LibraryPageWindow.defaultPageSize
        )
        .frame(width: 44, alignment: .trailing)
        .contentShape(Rectangle())
        .allowsHitTesting(visible)
    }
}

/// iPhone Duo (§5, docs/iphone-duo-readiness-2026-10-22.md): overlays the position
/// scrubber on the trailing edge, as before, unless the toolbar is a vertical side bar on
/// that edge (`toolbarVerticalEdge`, iOS 27.1: the outer display's vertical bars; nil when
/// bars are horizontal). Then the scrubber moves to the leading edge so the two don't
/// stack up. Older systems and SDKs keep the trailing placement.
struct LibraryScrubberPlacement<Scrubber: View>: ViewModifier {
    @ViewBuilder let scrubber: Scrubber

    func body(content: Content) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.modifier(ToolbarEdgeScrubberPlacement(scrubber: scrubber))
        } else {
            content.overlay(alignment: .trailing) { scrubber }
        }
        #else
        content.overlay(alignment: .trailing) { scrubber }
        #endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
/// iPhone Duo (§5): the iOS 27.1 half of `LibraryScrubberPlacement`, a separate view so
/// the 27.1-only environment key is read only where it exists.
@available(iOS 27.1, *)
private struct ToolbarEdgeScrubberPlacement<Scrubber: View>: ViewModifier {
    let scrubber: Scrubber
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let moved = toolbarVerticalEdge == .trailing
        content.overlay(alignment: moved ? .leading : .trailing) {
            // `LibraryPositionScrubber` (RetroComponents) draws its thumb on its trailing
            // edge and its bubble 52 pt before it. Flipping the layout direction mirrors
            // both, offsets included (checked with `ImageRenderer`: a trailing-aligned
            // view with `offset(x: -50)` lands at the mirrored position under RTL), so
            // the thumb hugs the leading edge with the bubble inboard of it.
            scrubber.environment(\.layoutDirection,
                                 moved ? (layoutDirection == .leftToRight ? .rightToLeft : .leftToRight) : layoutDirection)
        }
    }
}
#endif

// MARK: - Swipe action tints

/// Critique 2026-10-06 (colorize): swipe-action labels are drawn white by the system and
/// `tint(_:)` only sets the button background (Apple, `View.swipeActions(edge:allowsFullSwipe:content:)`
/// and `Button` role/tint behaviour; there's no documented API for the label colour). The
/// brand fills put white at 2.2:1 (amber E8A838) and 4.0:1 (teal 1C8E82), and the dark-mode
/// muted taupe at 3.0:1, so these are fixed darker fills of the same hues, theme-independent
/// because white needs a dark background in both appearances. Contrast with white is pinned
/// by `HardenCopyTests.testSwipeActionTintsClearAAWithWhite` for every accent.
enum LibrarySwipeTint {
    // Derived from the user's accent rather than fixed hexes (DESIGN.md: no hard-coded
    // hex in a View; the accent is user-selectable). Each is the accent family's own hue,
    // darkened just enough for the system's white swipe label to clear 4.5:1.
    static var amberHex: String { AppTheme.adjustedHexForContrast(AppTheme.accentHex, backgroundHex: "FFFFFF") }
    static var tealHex: String {
        AppTheme.adjustedHexForContrast(
            AppTheme.hueHarmonizedHex(anchorHex: AppTheme.SecondaryAnchor.accentLight, accentHex: AppTheme.accentHex),
            backgroundHex: "FFFFFF")
    }
    /// Taupe Ink (`shelfMuted`'s Light value), which already clears 4.5:1 with white.
    /// Critique 2026-10-06 (polish): read from the token rather than repeating the hex.
    static let neutralHex = Color.shelfMutedLightHex
    static var amber: Color { Color(hex: amberHex) }
    static var teal: Color { Color(hex: tealHex) }
    static var neutral: Color { Color(hex: neutralHex) }

    /// WCAG contrast of white against `hex`.
    static func whiteContrast(hex: String) -> Double {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let l = ContrastInk.relativeLuminance(r: Double((value >> 16) & 0xFF) / 255,
                                              g: Double((value >> 8) & 0xFF) / 255,
                                              b: Double(value & 0xFF) / 255)
        return 1.05 / (l + 0.05)
    }
}

// MARK: - Placeholder slots (Library browse plan §5, 2026-10-05)

/// What a placeholder slot says, for VoiceOver and the glyph. Pure, pinned by
/// `LibrarySelectionCopyTests`.
enum LibraryPlaceholderCopy {
    /// "Book 1,451, loading" / "…, couldn't load" / "…, not loaded, offline".
    static func accessibilityLabel(index: Int, state: LibraryPageWindow.PlaceholderState,
                                   offline: Bool, locale: Locale = .current) -> String {
        let number = (max(index, 0) + 1).formatted(IntegerFormatStyle<Int>.number.locale(locale))
        switch state {
        case .failed: return String(localized: "Book \(number), couldn\u{2019}t load", comment: "VoiceOver label of a Library slot whose page failed to load; %@ is the formatted book position")
        case .loading: return String(localized: "Book \(number), loading", comment: "VoiceOver label of a Library slot still loading; %@ is the formatted book position")
        case .notRequested:
            return offline
                ? String(localized: "Book \(number), not loaded, offline", comment: "VoiceOver label of a Library slot that is not loaded because the device is offline; %@ is the formatted book position")
                : String(localized: "Book \(number), loading", comment: "VoiceOver label of a Library slot still loading; %@ is the formatted book position")
        }
    }

    /// The glyph on an unloaded slot: failed → retry, offline → offline, otherwise none.
    static func systemImage(state: LibraryPageWindow.PlaceholderState, offline: Bool) -> String? {
        if state == .failed { return "exclamationmark.arrow.circlepath" }
        if offline && state != .loading { return "wifi.slash" }
        return nil
    }
}

/// An unloaded grid slot: `SkeletonTile`'s look, with `CassetteTile`'s exact height (a
/// square cover plus the caption reserve), so a page landing doesn't move the layout.
/// A failed page's slots retry on tap (plan §5).
struct LibraryPlaceholderTile: View {
    let index: Int
    let state: LibraryPageWindow.PlaceholderState
    let offline: Bool
    let compact: Bool
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let glyph = LibraryPlaceholderCopy.systemImage(state: state, offline: offline)
        let canRetry = state == .failed && !offline
        Button {
            if canRetry { Haptics.selection(); onRetry() }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(Color.shelfSurface)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let glyph {
                            Typo.metadata(Image(systemName: glyph))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                // Same hidden caption block as `CassetteTile.captionReserve`, with the
                // skeleton bars drawn over it.
                VStack(alignment: .leading, spacing: 2) {
                    Typo.rowTitle(Text("Ag")).lineLimit(compact ? 1 : 2, reservesSpace: true)
                    if !compact { Typo.fine(Text("Ag")).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.shelfSurface).frame(width: 70, height: 9)
                        if !compact {
                            RoundedRectangle(cornerRadius: 3).fill(Color.shelfSurface).frame(width: 46, height: 8)
                        }
                    }
                    .padding(.top, 3)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .opacity(state == .loading && pulse ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(canRetry)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryPlaceholderCopy.accessibilityLabel(index: index, state: state, offline: offline))
        .accessibilityHint(canRetry ? Text("Double-tap to try again") : Text(verbatim: ""))
        .accessibilityAddTraits(canRetry ? .isButton : [])
        .accessibilityRemoveTraits(canRetry ? [] : .isButton)
    }
}

/// An unloaded list slot, the height of `LibraryListRow` (52 pt cover, 4 pt padding).
struct LibraryPlaceholderRow: View {
    let index: Int
    let state: LibraryPageWindow.PlaceholderState
    let offline: Bool
    let onRetry: () -> Void

    var body: some View {
        let glyph = LibraryPlaceholderCopy.systemImage(state: state, offline: offline)
        let canRetry = state == .failed && !offline
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(Color.shelfSurface)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color.shelfSurface).frame(width: 140, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Color.shelfSurface).frame(width: 90, height: 8)
            }
            Spacer(minLength: 8)
            if let glyph {
                Typo.supporting(Image(systemName: glyph))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if canRetry { Haptics.selection(); onRetry() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryPlaceholderCopy.accessibilityLabel(index: index, state: state, offline: offline))
        .accessibilityHint(canRetry ? Text("Double-tap to try again") : Text(verbatim: ""))
        .accessibilityAddTraits(canRetry ? .isButton : [])
        .accessibilityAction { if canRetry { onRetry() } }
    }
}

// MARK: - Select mode action bar (Library browse plan §3.2, 2026-10-05)

/// The three bulk actions along the bottom while selecting: Up Next, Download, Mark
/// Finished, each an icon with a text label. Its own view so the per-book download reads
/// (which change at transfer-callback rate) invalidate only this bar, not the Library body
/// (the same reason as `LibraryGridTile`, Item 10).
///
/// It is a floating glass pill (the player's floating-chip family), not a hand-built copy of
/// the system toolbar.
struct LibrarySelectionBar: View {
    let selected: [LibraryItem]
    /// Hidden when the result set is already "Downloaded only" (plan §5).
    let showsDownload: Bool
    /// Server reachable (Download and Mark Finished need it; Up Next is local).
    let serverReachable: Bool
    let isMarkingFinished: Bool
    let markingCount: Int
    let onUpNext: () -> Void
    let onDownload: () -> Void
    let onMarkFinished: () -> Void
    @State private var downloadManager = DownloadManager.shared

    var body: some View {
        let count = selected.count
        // Plan §3.2 "Disabled states": Download is off when every selected book is already
        // downloaded or downloading, or is a podcast (podcasts aren't downloadable).
        let anyDownloadable = selected.contains {
            !$0.isPodcast && !downloadManager.isDownloaded(itemId: $0.id) && !downloadManager.isDownloading(itemId: $0.id)
        }
        let status = LibraryView.selectionStatusLine(
            isMarkingFinished: isMarkingFinished, markingCount: markingCount, serverReachable: serverReachable
        )
        VStack(spacing: Space.s) {
            if let status {
                HStack(spacing: 6) {
                    if isMarkingFinished {
                        ProgressView().controlSize(.small).shelfSpinner()
                    } else {
                        Image(systemName: "wifi.slash").accessibilityHidden(true)
                    }
                    Typo.supporting(Text(status))
                }
                .foregroundStyle(Color.shelfMuted)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 0) {
                actionButton(.upNext, count: count, enabled: count > 0 && !isMarkingFinished,
                             disabledHint: nil, action: onUpNext)
                if showsDownload {
                    actionButton(.download, count: count,
                                 enabled: count > 0 && serverReachable && anyDownloadable && !isMarkingFinished,
                                 disabledHint: !serverReachable
                                    ? String(localized: "Needs your server", comment: "VoiceOver hint on a disabled bulk action in the Library select bar")
                                    : (count > 0 && !anyDownloadable
                                        ? String(localized: "Already downloaded or downloading", comment: "VoiceOver hint on the disabled bulk Download action")
                                        : nil),
                                 action: onDownload)
                }
                actionButton(.markFinished, count: count,
                             enabled: count > 0 && serverReachable && !isMarkingFinished,
                             disabledHint: !serverReachable
                                ? String(localized: "Needs your server", comment: "VoiceOver hint on a disabled bulk action in the Library select bar")
                                : nil,
                             action: onMarkFinished)
            }
            .padding(.horizontal, Space.s)
            .glassPill(Capsule(), interactive: false)
        }
        .padding(.horizontal, Space.pageH)
        .padding(.top, Space.s)
        .padding(.bottom, Space.s)
    }

    private func actionButton(_ action: LibraryView.BulkAction, count: Int, enabled: Bool,
                              disabledHint: String?, action perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            perform()
        } label: {
            VStack(spacing: 3) {
                Typo.metadata(Image(systemName: action.systemImage))
                Typo.fine(Text(action.title), weight: .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.shelfCream)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(LibraryView.bulkActionLabel(action, count: count))
        .accessibilityHint(enabled ? "" : (disabledHint ?? ""))
    }
}

/// Batch 445: the two scopes of Library search in Books.
enum LibrarySearchScope: Hashable {
    case titles
    case ask
}

/// Batch 490 (REVIEW 2026-11-11 L7): the last few Titles searches the listener submitted,
/// per account (server + user), in `UserDefaults` under `keyPrefix` + the account's scope key.
/// Never sent anywhere. Cleared with the Clear suggestion row.
enum RecentLibrarySearches {
    /// UserDefaults key prefix; the full key appends `TranscriptStore.currentScopeKey()`.
    /// Default when absent: no recent searches.
    static let keyPrefix = "libraryRecentSearches."
    static let limit = 5

    /// Three example sentences for the Ask scope's empty field (localised, so they match
    /// what `MoodQueryParser` reads in the listener's language).
    static var askExamples: [String] {
        [String(localized: "something cosy under 8 hours", comment: "Ask search example suggestion"),
         String(localized: "a thriller I haven’t started", comment: "Ask search example suggestion"),
         String(localized: "funny and short", comment: "Ask search example suggestion")]
    }

    /// Puts `query` first, drops an earlier copy (case-insensitive) and blanks, and keeps at
    /// most `limit`. Pure, pinned by `QuickWinsLibraryTests`.
    nonisolated static func adding(_ query: String, to list: [String], limit: Int = 5) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(list.prefix(limit)) }
        let rest = list.filter { $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame }
        return Array(([trimmed] + rest).prefix(limit))
    }

    private static var key: String { keyPrefix + TranscriptStore.currentScopeKey() }

    static func load() -> [String] {
        Array((UserDefaults.standard.stringArray(forKey: key) ?? []).prefix(limit))
    }

    @discardableResult
    static func record(_ query: String) -> [String] {
        let updated = adding(query, to: load(), limit: limit)
        UserDefaults.standard.set(updated, forKey: key)
        return updated
    }

    @discardableResult
    static func clear() -> [String] {
        UserDefaults.standard.removeObject(forKey: key)
        return []
    }
}
