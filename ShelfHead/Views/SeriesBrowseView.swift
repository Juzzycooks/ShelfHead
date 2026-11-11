import SwiftUI

/// "1 book" / "12 books" for this file's series copy.
private func seriesBookCountPhrase(_ count: Int) -> String {
    count == 1
        ? String(localized: "1 book", comment: "Count phrase for exactly one book in a series")
        : String(localized: "\(count) books", comment: "Count phrase for several books in a series; %lld is the count")
}

struct SeriesBrowseView: View {
    /// Clearance for the mini-player + tab bar (passed from LibraryView).
    var bottomInset: CGFloat = 0
    /// Client-side name filter from the Library search field.
    var search: String = ""
    /// Critique 2026-10-05 (Library): tab re-tap scroll-to-top, as in Books.
    var scrollToTopSignal: Int = 0
    private static let topAnchorID = "series-top"
    @Environment(LibraryViewModel.self) private var libraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var filteredSeries: [Series] {
        let all = libraryViewModel.seriesList
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        // LS-6 (docs/design-review.md, Round 3): hoisted so the branch condition below
        // and the `.shelfAnimation(value:)` on the Group can't drift apart — mirrors
        // `HomeView`'s AN-3 `showsSkeleton` pattern.
        let showsSkeleton = libraryViewModel.isLoadingSeries && libraryViewModel.seriesList.isEmpty
        Group {
            if showsSkeleton {
                // Series is a grid of poster tiles, not a list, so it reuses
                // `SkeletonGrid` rather than `SkeletonList` — `SeriesTile` is the same
                // shape `SkeletonTile` already matches (a square poster + two text
                // bars), and both use the identical `.adaptive(150–200), spacing: 16`
                // columns. Was a centred `LoadingView` spinner, the odd one out next to
                // Library Books' shape-matched skeleton.
                ScrollView { SkeletonGrid() }
                    .scrollDisabled(true)
                    .accessibilityElement()
                    // Critique 2026-10-06 (harden): a real ellipsis, as every other loading label.
                    .accessibilityLabel("Loading series\u{2026}")
                    .transition(.opacity)
            } else if libraryViewModel.seriesList.isEmpty && libraryViewModel.seriesLoadFailed {
                // UI-11: distinguishes "the load failed" from "this library genuinely
                // has no series" — previously both looked identical.
                LoadFailedStateView(action: { Task { await libraryViewModel.loadSeries() } })
            } else if libraryViewModel.seriesList.isEmpty {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: LocalizedStringResource("No series"),
                    subtitle: LocalizedStringResource("This library has no series yet")
                )
            } else if filteredSeries.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matches",
                               subtitle: "No series match “\(search)”")
            } else {
                // A grid of series "posters" (cascaded book covers). Tapping a series
                // opens its own page rather than expanding an inline list.
                ScrollView {
                    Color.clear.frame(height: 0).id(Self.topAnchorID)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredSeries) { series in
                            LibraryRouteLink(.series(series), bottomInset: bottomInset) {
                                SeriesTile(series: series)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Batch 218 (R9): same `columns` config (`.adaptive(minimum:
                    // 150, maximum: 200)`, spacing 16) and same safe-at-every-
                    // SE-through-Pro-Max-width arithmetic as `LibraryView`'s grid
                    // margin — see that file's comment for the actual numbers.
                    // 16→20 doesn't change this grid's column count either.
                    .padding(.horizontal, Space.pageH)
                    .padding(.vertical, 12)
                    .padding(.bottom, 16 + bottomInset)
                }
                .scrollsToTop(signal: scrollToTopSignal, firstID: Self.topAnchorID)
                .transition(.opacity)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.25), value: showsSkeleton)
        .task {
            if libraryViewModel.seriesList.isEmpty {
                await libraryViewModel.loadSeries()
            }
        }
        .refreshable { await libraryViewModel.loadSeries() }
        .reexpandsTabBarOnAppear()
    }
}

// MARK: - Series tile (poster + name + count)

struct SeriesTile: View {
    let series: Series
    @Environment(LibraryViewModel.self) private var libraryViewModel

    private var total: Int { series.bookCount }

    /// Books in the series marked finished — prefers the shared progress map so it
    /// stays current, falling back to the item's own flag.
    private var finished: Int {
        (series.books ?? []).filter { book in
            libraryViewModel.progressFor(itemId: book.id)?.isFinished ?? book.isFinished
        }.count
    }

    private var subtitle: String {
        finished > 0
            ? String(localized: "\(finished)/\(total) finished", comment: "Series row subtitle; first %lld is books finished, second %lld is the total books in the series")
            : seriesBookCountPhrase(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SeriesPoster(books: series.books ?? [])
                .aspectRatio(1, contentMode: .fit)
                // IC-5 (V3, user decision 26 September): the progress ring that sat on the
                // front cover's corner is gone; the "n/N finished" caption carries it.

            // HL-3 (V3): spare title line falls below "n/N finished", not between them.
            captionReserve.overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 2) {
                // U10 (REVIEW_2026-08-20_UI_SECURITY.md): was its own 11pt `@ScaledMetric`
                // spelling of "book title in a row," byte-identical in role to
                // `CassetteTile`'s own R9 migration to `Typo.rowTitle` (14pt/.semibold) —
                // see that struct's comment (RetroComponents.swift) for the same caveat:
                // 11→14pt changes this tile's rendered height in every grid it appears in.
                Typo.rowTitle(Text(series.displayName))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Critique 2026-10-05 (Library): was a 10pt `.system(size:)` (below the
                // 11pt floor) in amber. Fully finished is the one state this line carries,
                // and finished is teal in this app; amber is for actions and live state.
                Typo.fine(Text(subtitle))
                    .foregroundStyle(finished == total && total > 0 ? Color.shelfAccentText : Color.shelfMuted)
                    .lineLimit(1)
            }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(series.displayName), \(subtitle)")
    }

    /// Hidden two-line title + subtitle that sizes the caption block.
    private var captionReserve: some View {
        VStack(alignment: .leading, spacing: 2) {
            Typo.rowTitle(Text("Ag")).lineLimit(2, reservesSpace: true)
            Typo.fine(Text("Ag")).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hidden()
    }
}

// MARK: - Cascaded cover poster

/// Up to three book covers fanned into a stack, forming a "poster" for the series.
struct SeriesPoster: View {
    let books: [LibraryItem]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cover = side * 0.74
            let step = side * 0.10
            let shown = Array(books.prefix(3))

            ZStack {
                if shown.isEmpty {
                    // Critique 2026-10-06 (distill): `Radius.chip` like every grid cover, and the
                    // glyph sized by the frame (`resizable` + `scaledToFit`) rather than a bare
                    // `.font(.system(size:))` (DESIGN.md Token-Only Rule). It still scales with
                    // the tile, which is what the geometry-derived size was for.
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(Color.shelfCard)
                        .frame(width: cover, height: cover)
                        .overlay(
                            Image(systemName: "square.stack.3d.up.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: side * 0.26, height: side * 0.26)
                                .foregroundStyle(Color.shelfMuted)
                        )
                        .accessibilityHidden(true)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { pair in
                        let depth = CGFloat(pair.offset)   // 0 = front
                        CachedCover(url: shelfCoverURL(itemId: pair.element.id))
                            .aspectRatio(1, contentMode: .fill)
                            .frame(width: cover, height: cover)
                            // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 8pt radius → `Radius.chip`.
                            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                            .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                                .strokeBorder(Color.shelfCream.opacity(0.14), lineWidth: 1))
                            // Critique 2026-10-06 (distill): was a hard 45 % black shadow in
                            // both themes, which reads as grime on Light's paper (DESIGN.md
                            // Paper-Doesn't-Cast Rule). `shelfElevation(.floating)` keeps a
                            // soft shadow in Dark to separate the fanned covers and gives
                            // Light a hairline instead.
                            .shelfElevation(.floating, in: RoundedRectangle(cornerRadius: Radius.chip))
                            .scaleEffect(1 - depth * 0.08)
                            .offset(x: depth * step, y: -depth * step * 0.6)
                            // Front cover on top, deeper covers peeking behind.
                            .zIndex(Double(shown.count - pair.offset))
                            .opacity(1 - depth * 0.12)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
}

// MARK: - Series detail page (books in sequence)

struct SeriesDetailView: View {
    let series: Series
    var bottomInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var downloadManager = DownloadManager.shared
    @State private var pendingAction: SeriesBulkAction?
    @State private var resultMessage: String?
    @State private var working = false
    // LS-10 (docs/design-review.md, Round 3): sequential mark finished/unfinished
    // progress, plus which verb to show while it's running (captured separately from
    // `pendingAction`, which the confirmation dialog clears as soon as it dismisses).
    @State private var bulkDone = 0
    @State private var bulkTotal = 0
    @State private var bulkFinishing = true
    @State private var autoDownloadOn = false
    /// Critique 2026-10-06 (harden): Mark series finished / unfinished now snapshot first and
    /// offer the same 6 s Undo as Library's bulk Mark Finished (`restoreProgress`). The
    /// snapshots `markFinished(items:)` returned used to be thrown away.
    @State private var undoMessage: String?
    @State private var undoSnapshots: [LibraryProgressSnapshot] = []
    /// A gap in the sequence numbers you actually own (e.g. have #1, #2, #4, not #3) —
    /// purely local, computed on appear. See `LibraryViewModel.missingSequenceGap`.
    @State private var missingBookGap: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// iPhone Duo (§3): set in Library's split-view sidebar on the inner display. Opening a
    /// series there shows its hero book (the one Play targets) in the detail column, unless
    /// the column already shows a book from this series: `onAppear` can run again while the
    /// page is up, and must not replace a book picked from it.
    @Environment(\.libraryDetailSelection) private var detailSelection

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    /// Critique 2026-10-05 (Library, 2nd): how far to lift the sequence badge so it clears
    /// the tile's bottom-edge furniture: the 3 pt progress line and the 14 pt reel band.
    static func sequenceBadgeBottomInset(progressLine: Bool, reelBand: Bool) -> CGFloat {
        (progressLine ? 3 : 0) + (reelBand ? 14 : 0)
    }

    /// Critique 2026-10-05 (Library): text for the series-number badge from a book's real
    /// sequence in this series. Whole numbers print without a decimal ("3"), fractional
    /// ones keep it ("2.5"); a book with no sequence gets no badge rather than a made-up
    /// number. Pure, pinned by `LibraryStateTests`.
    static func sequenceBadgeText(_ sequence: Double?) -> String? {
        guard let sequence, sequence.isFinite, sequence >= 0 else { return nil }
        if sequence.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(sequence)) }
        return String(sequence)
    }

    // MARK: Bulk-action helpers

    private var books: [LibraryItem] { series.books ?? [] }
    private func isFinished(_ item: LibraryItem) -> Bool {
        libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
    }
    private var unheard: [LibraryItem] { books.filter { !isFinished($0) } }
    /// The books "Mark series unfinished" changes: only the finished ones.
    private var finishedBooks: [LibraryItem] { books.filter { isFinished($0) } }
    private var undownloadedUnheard: [LibraryItem] {
        unheard.filter { !downloadManager.isDownloaded(itemId: $0.id) && !downloadManager.isDownloading(itemId: $0.id) }
    }
    /// Every book in the series not yet downloaded, regardless of listen status —
    /// distinct from "Download unheard" (which skips already-finished books). Surfaces
    /// what per-series auto-download already does one book at a time, as a single
    /// explicit action (AudioBooth ships this as "Download entire series").
    private var undownloadedAll: [LibraryItem] {
        books.filter { !downloadManager.isDownloaded(itemId: $0.id) && !downloadManager.isDownloading(itemId: $0.id) }
    }
    /// Critique 2026-10-06 (distill): the grid iterated `series.books` in server order; it
    /// now uses the same sequence order as the hero and the series badges.
    private var orderedBooks: [LibraryItem] {
        books.sortedBySeriesSequence(inSeriesNamed: series.displayName)
    }
    private func hasStarted(_ item: LibraryItem) -> Bool {
        (libraryViewModel.progressFor(itemId: item.id)?.progress ?? item.progressPercent) > 0
    }

    /// Critique 2026-10-06 (shape → distill): the hero row's target and state. Was the
    /// "Play from next unfinished" item buried in the ••• menu. Same next-unfinished rule
    /// (earliest unfinished in sequence order, live progress), except that a loaded,
    /// unfinished book from this series wins so the button can say Resume / Pause.
    private var currentHeroPlan: SeriesHeroPlan? {
        let ordered = orderedBooks
        return Self.heroPlan(
            orderedIds: ordered.map(\.id),
            finished: Set(ordered.filter { isFinished($0) }.map(\.id)),
            started: Set(ordered.filter { hasStarted($0) }.map(\.id)),
            loadedId: playerViewModel.currentBook?.id,
            isPlaying: playerViewModel.isPlaying)
    }

    // MARK: Hero decisions (pure, pinned by `DrillDownActionsTests`)

    enum SeriesHeroState: Equatable {
        /// Nothing in the series heard yet.
        case start
        /// Some books heard; the target is the next unfinished one.
        case continueAt
        /// The target is the loaded book and it's paused (or restored, awaiting resume).
        case resume
        /// The target is the loaded book and it's playing.
        case pause
        /// Every book is finished: start again from the first.
        case listenAgain
    }

    struct SeriesHeroPlan: Equatable {
        let targetId: String
        let state: SeriesHeroState
    }

    static func heroPlan(orderedIds: [String], finished: Set<String>, started: Set<String>,
                         loadedId: String?, isPlaying: Bool) -> SeriesHeroPlan? {
        guard let first = orderedIds.first else { return nil }
        let loadedState: SeriesHeroState = isPlaying ? .pause : .resume
        if let loadedId, orderedIds.contains(loadedId), !finished.contains(loadedId) {
            return SeriesHeroPlan(targetId: loadedId, state: loadedState)
        }
        guard let next = orderedIds.first(where: { !finished.contains($0) }) else {
            return SeriesHeroPlan(targetId: first, state: loadedId == first ? loadedState : .listenAgain)
        }
        let anyHeard = orderedIds.contains { finished.contains($0) || started.contains($0) }
        return SeriesHeroPlan(targetId: next, state: anyHeard ? .continueAt : .start)
    }

    /// "Continue · Book 4". `sequenceText` is `sequenceBadgeText` of the target's position.
    static func heroButtonLabel(_ state: SeriesHeroState, sequenceText: String?) -> String {
        switch state {
        case .start: return String(localized: "Start Series", comment: "Series hero button: no book in the series started yet")
        case .continueAt:
            if let sequenceText { return String(localized: "Continue \u{00B7} Book \(sequenceText)", comment: "Series hero button; %@ is the book’s position in the series, e.g. 4") }
            return String(localized: "Continue Series", comment: "Series hero button when the next book has no known position")
        case .resume:
            if let sequenceText { return String(localized: "Resume \u{00B7} Book \(sequenceText)", comment: "Series hero button for the book already loaded in the player; %@ is the book’s position in the series") }
            return String(localized: "Resume", comment: "Series hero button for the book already loaded in the player (verb)")
        case .pause:
            if let sequenceText { return String(localized: "Pause \u{00B7} Book \(sequenceText)", comment: "Series hero button while the series book is playing; %@ is the book’s position in the series") }
            return String(localized: "Pause", comment: "Series hero button while the series book is playing (verb)")
        case .listenAgain: return String(localized: "Listen Again", comment: "Series hero button when every book in the series is finished")
        }
    }

    /// "3 of 7 finished" under the series name.
    static func progressText(finished: Int, total: Int) -> String {
        guard total > 0 else { return String(localized: "No books yet", comment: "Series progress text for a series with no books") }
        if finished <= 0 { return seriesBookCountPhrase(total) }
        if finished >= total {
            return total == 1
                ? String(localized: "Finished", comment: "Series progress text: the series' only book is finished")
                : String(localized: "All \(total) finished", comment: "Series progress text; %lld is the number of books, all finished")
        }
        return String(localized: "\(finished) of \(total) finished", comment: "Series progress text; first %lld is books finished, second %lld is the total")
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            ScrollView {
                if let plan = currentHeroPlan {
                    seriesHero(plan)
                }

                // LS-10 (docs/design-review.md, Round 3): the only feedback for a
                // sequential mark finished/unfinished used to be the toolbar menu
                // dimming, which reads as "did nothing" for a big series. Determinate
                // progress plus a live count while `working` is true.
                if working {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(bulkDone), total: Double(max(bulkTotal, 1)))
                            .tint(Color.shelfAmberText)
                            .frame(maxWidth: 80)
                        Text(bulkFinishing
                             ? "Marking \(bulkDone) of \(bulkTotal) finished\u{2026}"
                             : "Marking \(bulkDone) of \(bulkTotal) not finished\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(Color.shelfMuted)
                        Spacer(minLength: 0)
                    }
                    // VD-8 (docs/design-review.md): tokens instead of literals. Radius 10
                    // had no token; `Radius.card` (12) is the role other `shelfCard` inline
                    // cards use (Downloads rows), 2 pt away, and reads the same.
                    .padding(Space.m)
                    .background(Color.shelfCard)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .padding(.horizontal, Space.pageH)
                    .padding(.top, Space.m)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(bulkFinishing ? Text("Marking books finished") : Text("Marking books not finished"))
                    .accessibilityValue("\(bulkDone) of \(bulkTotal)")
                    .transition(.opacity)
                }

                if let gap = missingBookGap {
                    HStack(spacing: 10) {
                        // Critique 2026-10-06 (colorize): a warning glyph is orange
                        // (DESIGN.md: `shelfOrange` for warning glyphs, amber is for
                        // action/live state); the sentence beside it stays cream.
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.shelfOrange)
                            .accessibilityHidden(true)
                        Typo.supporting(Text("Book \(gap) isn\u{2019}t in your library — the rest of the series skips over it."))
                            .foregroundStyle(Color.shelfCream)
                        Spacer(minLength: 0)
                    }
                    // VD-8 (docs/design-review.md): tokens instead of literals. Radius 10
                    // had no token; `Radius.card` (12) is the role other `shelfCard` inline
                    // cards use (Downloads rows), 2 pt away, and reads the same.
                    .padding(Space.m)
                    .background(Color.shelfCard)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    // Batch 218 (R9): page margin, not grid-critical.
                    .padding(.horizontal, Space.pageH)
                    .padding(.top, Space.m)
                    .accessibilityElement(children: .combine)
                }

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(orderedBooks) { item in
                        BookLink(item) {
                            // Critique 2026-10-05 (Library): progress/download/finished state
                            // now shows here too (the tile used to get none of it).
                            BookGridTile(item: item)
                            .overlay(alignment: .topLeading) {
                                // The real series position (`#2.5`, or a gap-skipping `#4`),
                                // not the array index + 1, which mislabelled any series with
                                // a gap, a novella, or a different server ordering. Sits on
                                // the cover's bottom-leading corner because the top-leading
                                // corner belongs to the tile's finished mark. Neutral
                                // (surface + cream): a sequence number is a fact, not an
                                // action or a live state, so it isn't amber.
                                if let label = Self.sequenceBadgeText(item.sequence(inSeriesNamed: series.displayName)) {
                                    // Critique 2026-10-05 (Library, 2nd): the badge sat on the
                                    // cover's bottom edge, under the 14 pt now-playing reel band
                                    // and the 3 pt progress line, and its surface fill was a
                                    // paper capsule in Light. It now lifts above whichever of
                                    // those is showing and uses the same dark scrim as the
                                    // finished and download badges.
                                    let mp = libraryViewModel.progressFor(itemId: item.id)
                                    let lift = Self.sequenceBadgeBottomInset(
                                        progressLine: CassetteTile.showsProgressLine(
                                            progress: mp?.progress ?? item.progressPercent,
                                            isFinished: mp?.isFinished ?? item.isFinished),
                                        reelBand: CassetteTile.showsReelBand(
                                            isNowPlaying: playerViewModel.currentBook?.id == item.id,
                                            isPlaying: playerViewModel.isPlaying)
                                    )
                                    GeometryReader { geo in
                                        Color.clear
                                            .frame(width: geo.size.width, height: geo.size.width)
                                            .overlay(alignment: .bottomLeading) {
                                                Typo.fine(Text(label), weight: .bold)
                                                    .foregroundStyle(Color.shelfCream)
                                                    .padding(.horizontal, 6)
                                                    .frame(minWidth: 22, minHeight: 22)
                                                    .background(Color.black.opacity(0.55), in: Capsule())
                                                    .padding(.leading, 6)
                                                    .padding(.bottom, 6 + lift)
                                                    .accessibilityLabel("Book \(label)")
                                            }
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        // UX-1 (docs/design-review.md, Round 3): series detail's grid had
                        // no long-press menu at all, so this was one of the "open Book
                        // Detail just to press Play" surfaces the finding calls out.
                        .bookContextMenu(item)
                    }
                }
                // Batch 218 (R9): same `columns` config as `filteredSeries`'s grid
                // above — same safe-at-every-checked-width arithmetic applies.
                // Only the horizontal component moves to `Space.pageH`; vertical
                // stays 16 (unrelated to the column-count question).
                .padding(.horizontal, Space.pageH)
                .padding(.vertical, 16)
                .padding(.bottom, bottomInset)
            }
            .shelfAnimation(.default, value: working)
        }
        .navigationTitle(series.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            autoDownloadOn = SettingsStore.seriesAutoDownloadEnabled(series.displayName)
            missingBookGap = libraryViewModel.missingSequenceGap(in: books, seriesName: series.displayName)
            if let detailSelection, !books.contains(where: { $0.id == detailSelection.wrappedValue?.id }) {
                if let targetId = currentHeroPlan?.targetId,
                   let book = books.first(where: { $0.id == targetId }) {
                    detailSelection.wrappedValue = book
                }
            }
        }
        // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
        .toolbar {
            // iPhone Duo (§2): on iOS 27 these fold into the system overflow menu.
            #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.0, *) {
                ToolbarOverflowMenu {
                    seriesActionsMenuContents.disabled(working)
                }
            } else {
                seriesActionsToolbarItem
            }
            #else
            seriesActionsToolbarItem
            #endif
        }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .confirmationDialog(confirmTitle, isPresented: confirmBinding, titleVisibility: .visible,
                            presenting: pendingAction) { action in
            // Critique 2026-10-06 (harden): only Mark Finished replaces positions, so only it is
            // destructive; "unfinished" keeps every position and was wrongly styled red.
            Button(confirmButtonTitle(action), role: action == .markFinished ? .destructive : nil) {
                perform(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmMessage(action))
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Series", isPresented: Binding(get: { resultMessage != nil },
                                              set: { if !$0 { resultMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        .systemChromeTint()
        .toast(message: $undoMessage, style: .success, duration: 6,
               bottomInset: bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil),
               action: ToastAction(label: "Undo") { undoBulkChange() })
        .reexpandsTabBarOnAppear()
    }

    // iPhone Duo (§2): the series-actions menu body, shared by the iOS 27 overflow menu and
    // the pre-27 ellipsis button.
    @ViewBuilder
    private var seriesActionsMenuContents: some View {
        // Critique 2026-10-06 (distill): "Play from next unfinished" moved out of
        // this menu to the hero's primary button; the menu keeps the rest.
        if !undownloadedUnheard.isEmpty {
            Button { pendingAction = .downloadUnheard } label: {
                Label("Download unheard (\(undownloadedUnheard.count))", systemImage: "arrow.down.circle")
            }
        }
        if !undownloadedAll.isEmpty {
            Button { pendingAction = .downloadAll } label: {
                Label("Download entire series (\(undownloadedAll.count))", systemImage: "arrow.down.circle.fill")
            }
        }
        Toggle(isOn: Binding(
            get: { autoDownloadOn },
            set: { autoDownloadOn = $0; SettingsStore.setSeriesAutoDownload($0, for: series.displayName) }
        )) {
            Label("Auto-download next", systemImage: "arrow.down.circle.dotted")
        }
        Divider()
        Button { pendingAction = .markFinished } label: {
            Label("Mark series finished", systemImage: "checkmark.circle")
        }
        // Critique 2026-10-06 (harden): only offered when something is finished.
        if !finishedBooks.isEmpty {
            Button { pendingAction = .markUnfinished } label: {
                Label("Mark series unfinished", systemImage: "circle")
            }
        }
        // Batch 490 (REVIEW 2026-11-11 F1): ABS's per-series hide from its Continue Series
        // shelf (Home's "Next in Series", so named here), offered only while that shelf shows
        // a book from this series.
        // Progress is untouched; the app-wide toast offers Undo.
        if LibraryViewModel.seriesIsInContinueSeries(
            seriesBookIds: Set(orderedBooks.map(\.id)),
            shelves: libraryViewModel.personalizedShelves) {
            Button {
                Haptics.selection()
                Task { await libraryViewModel.removeSeriesFromContinueListening(seriesId: series.id, title: series.displayName) }
            } label: {
                Label("Remove from Next in Series", systemImage: "eye.slash")
            }
        }
    }

    @ToolbarContentBuilder
    private var seriesActionsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                seriesActionsMenuContents
            } label: {
                // LG-2 (docs/visual-design-review.md, Round V1): plain symbol, not the
                // circle variant — the glass toolbar container already draws the ring.
                Label("Series actions", systemImage: "ellipsis")
            }
            .monochromeToolbarItem()
            .disabled(working)
        }
    }

    // MARK: Hero row

    /// Critique 2026-10-06 (shape → distill): One Hero Rule. The series name, "3 of 7
    /// finished" over a thin rail, the target book's cover and title, and one primary
    /// button. Sits on the ground, no card (Fewer-Containers Rule). Stacks vertically at
    /// accessibility sizes so the title can wrap.
    @ViewBuilder
    private func seriesHero(_ plan: SeriesHeroPlan) -> some View {
        let ordered = orderedBooks
        if let target = ordered.first(where: { $0.id == plan.targetId }) {
            let total = ordered.count
            let finishedCount = ordered.filter { isFinished($0) }.count
            let label = Self.heroButtonLabel(
                plan.state, sequenceText: Self.sequenceBadgeText(target.sequence(inSeriesNamed: series.displayName)))
            let isLoadedState = plan.state == .resume || plan.state == .pause
            // Same replacement rule and copy as Book Detail's Play Instead: no confirm, but
            // the loaded book is named before the tap replaces it.
            let note: String? = isLoadedState ? nil : BookDetailView.playsInsteadNote(
                otherTitle: playerViewModel.currentBook.flatMap { $0.id == target.id ? nil : $0.title })
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Space.m))

            VStack(alignment: .leading, spacing: Space.m) {
                layout {
                    CoverImageView(itemId: target.id, width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Typo.heroTitle(Text(series.displayName))
                            .foregroundStyle(Color.shelfCream)
                            .lineLimit(2)
                        Typo.metadata(Text(target.title))
                            .foregroundStyle(Color.shelfMuted)
                            .lineLimit(2)
                        Typo.figure(Text(Self.progressText(finished: finishedCount, total: total)))
                            .foregroundStyle(finishedCount == total && total > 0 ? Color.shelfAccentText : Color.shelfMuted)
                            .padding(.top, 2)
                        BookProgressBar(progress: total > 0 ? Double(finishedCount) / Double(total) : 0)
                            .frame(height: 4)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)

                Button {
                    Haptics.impact(.medium)
                    if isLoadedState {
                        playerViewModel.togglePlayPause()
                    } else {
                        // Batch 490 (REVIEW 2026-11-11 L4): replacing the loaded book offers "Jump back".
                        Task { await playerViewModel.startPlaybackOfferingUndo(for: target) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: plan.state == .pause ? "pause.fill" : "play.fill")
                            .accessibilityHidden(true)
                        Text(label)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .shelfButtonStyle()
                }
                .accessibilityLabel(label)
                .accessibilityHint(note ?? "")

                if let note {
                    Typo.supporting(Text(note))
                        .foregroundStyle(Color.shelfMuted)
                        .accessibilityHidden(true)   // read as the button's hint
                }
            }
            .padding(.horizontal, Space.pageH)
            .padding(.top, Space.l)
        }
    }

    // MARK: Bulk actions

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
    }
    private var confirmTitle: String { Self.confirmTitle(for: pendingAction) }
    /// How many books the action changes: every book to finish, only finished ones to unfinish.
    private func affectedCount(_ action: SeriesBulkAction) -> Int {
        action == .markUnfinished ? finishedBooks.count : books.count
    }
    private func confirmButtonTitle(_ action: SeriesBulkAction) -> String {
        Self.confirmButtonTitle(action, bookCount: affectedCount(action),
                                unheardToDownload: undownloadedUnheard.count, allToDownload: undownloadedAll.count)
    }
    private func confirmMessage(_ action: SeriesBulkAction) -> String {
        Self.confirmMessage(action, bookCount: affectedCount(action),
                            unheardToDownload: undownloadedUnheard.count, allToDownload: undownloadedAll.count,
                            inProgress: action == .markFinished ? libraryViewModel.inProgressCount(of: books) : 0)
    }

    // Pure confirm copy, pinned by `SeriesBulkCopyTests`.
    static func confirmTitle(for action: SeriesBulkAction?) -> String {
        switch action {
        case .markFinished: return String(localized: "Mark whole series finished?", comment: "Series confirmation dialog title")
        case .markUnfinished: return String(localized: "Mark whole series unfinished?", comment: "Series confirmation dialog title")
        case .downloadUnheard: return String(localized: "Download unheard books?", comment: "Series confirmation dialog title")
        case .downloadAll: return String(localized: "Download entire series?", comment: "Series confirmation dialog title")
        case .none: return ""
        }
    }
    static func confirmButtonTitle(_ action: SeriesBulkAction, bookCount: Int, unheardToDownload: Int, allToDownload: Int) -> String {
        switch action {
        case .markFinished: return String(localized: "Mark \(bookCount) Finished", comment: "Series confirmation button; %lld is the number of books")
        case .markUnfinished: return String(localized: "Mark \(bookCount) Unfinished", comment: "Series confirmation button; %lld is the number of books")
        case .downloadUnheard: return String(localized: "Download \(unheardToDownload)", comment: "Series confirmation button; %lld is the number of books to download")
        case .downloadAll: return String(localized: "Download \(allToDownload)", comment: "Series confirmation button; %lld is the number of books to download")
        }
    }
    /// Critique 2026-10-06 (harden): Mark Finished reuses Library's bulk wording, which names
    /// how many in-progress positions will be replaced and that Undo follows.
    static func confirmMessage(_ action: SeriesBulkAction, bookCount: Int, unheardToDownload: Int, allToDownload: Int,
                               inProgress: Int = 0) -> String {
        switch action {
        case .markFinished:
            return LibraryView.markFinishedConfirmMessage(count: bookCount, inProgress: inProgress)
        case .markUnfinished:
            return bookCount == 1
                ? String(localized: "This updates 1 finished book on the server. Positions are kept. You can undo this right after.", comment: "Series Mark Unfinished confirmation, one book")
                : String(localized: "This updates \(bookCount) finished books on the server. Positions are kept. You can undo this right after.", comment: "Series Mark Unfinished confirmation; %lld is the number of books")
        case .downloadUnheard:
            return unheardToDownload == 1
                ? String(localized: "Queues 1 unfinished book for download (respects your Wi-Fi-only setting).", comment: "Series download confirmation, one book")
                : String(localized: "Queues \(unheardToDownload) unfinished books for download (respects your Wi-Fi-only setting).", comment: "Series download confirmation; %lld is the number of books")
        case .downloadAll:
            return allToDownload == 1
                ? String(localized: "Queues all 1 remaining book in the series for download, including already-finished ones (respects your Wi-Fi-only setting).", comment: "Series download-everything confirmation, one book")
                : String(localized: "Queues all \(allToDownload) remaining books in the series for download, including already-finished ones (respects your Wi-Fi-only setting).", comment: "Series download-everything confirmation; %lld is the number of books")
        }
    }
    static func failureMessage(count: Int) -> String {
        count == 1
            ? String(localized: "1 book couldn’t be updated. Try again.", comment: "Series bulk action failure, one book")
            : String(localized: "\(count) books couldn’t be updated. Try again.", comment: "Series bulk action failure; %lld is the number of books")
    }

    /// The Undo toast after Mark series unfinished, worded like Library's
    /// `markedFinishedToast`.
    static func markedUnfinishedToast(succeeded: Int, failed: Int) -> String {
        if failed > 0 {
            return String(localized: "Marked \(succeeded) unfinished. \(seriesBookCountPhrase(failed)) couldn\u{2019}t be updated. Try again.", comment: "Toast after a partly failed Mark series unfinished; first %lld is how many succeeded, %@ is a count phrase like '2 books' for the failures")
        }
        return String(localized: "Marked \(succeeded) unfinished", comment: "Toast after Mark series unfinished; %lld is the number of books")
    }

    /// Mark series unfinished's targets: each finished book's snapshot with the finished
    /// flag cleared and its position kept, for `restoreProgress` (one batch request instead
    /// of a PATCH per book). Pure, pinned by `SeriesBulkCopyTests`.
    static func unfinishedTargets(_ snapshots: [LibraryProgressSnapshot]) -> [LibraryProgressSnapshot] {
        snapshots.map {
            LibraryProgressSnapshot(itemId: $0.itemId, title: $0.title, currentTime: $0.currentTime,
                                    progress: $0.progress, isFinished: false, duration: $0.duration)
        }
    }

    private func perform(_ action: SeriesBulkAction) {
        switch action {
        case .downloadUnheard:
            queueDownloads(undownloadedUnheard)
        case .downloadAll:
            queueDownloads(undownloadedAll)
        case .markFinished:
            markSeriesFinished()
        case .markUnfinished:
            markSeriesUnfinished()
        }
    }

    /// Critique 2026-10-06 (harden): Library's bulk path exactly. One batch request; the
    /// snapshots it returns back a 6 s Undo toast (`restoreProgress`).
    private func markSeriesFinished() {
        let targets = books
        guard !targets.isEmpty else { return }
        beginWork(finishing: true, count: targets.count)
        Task {
            let result = await libraryViewModel.markFinished(items: targets)
            bulkDone = bulkTotal
            working = false
            offerUndo(result.snapshots,
                      message: LibraryView.markedFinishedToast(succeeded: result.succeeded.count, failed: result.failed.count),
                      failed: result.failed.count)
        }
    }

    /// Critique 2026-10-06 (harden): was one sequential PATCH per book, with no Undo. Now one
    /// batch through `restoreProgress` (finished flag off, positions kept) for the finished
    /// books only, each recorded in Recent Changes as the single path does, then Undo.
    private func markSeriesUnfinished() {
        let targets = finishedBooks
        guard !targets.isEmpty else { return }
        guard libraryViewModel.canMarkFinished else {
            resultMessage = Self.failureMessage(count: targets.count)
            return
        }
        beginWork(finishing: false, count: targets.count)
        let snapshots = targets.map {
            LibraryViewModel.progressSnapshot(itemId: $0.id, title: $0.title,
                                              prior: libraryViewModel.progressFor(itemId: $0.id) ?? $0.mediaProgress,
                                              duration: $0.duration)
        }
        Task {
            let failedIds = Set(await libraryViewModel.restoreProgress(Self.unfinishedTargets(snapshots), reload: true))
            let succeeded = snapshots.filter { !failedIds.contains($0.itemId) }
            for snapshot in succeeded {
                PlaybackHistoryStore.shared.record(
                    itemId: snapshot.itemId, title: snapshot.title, action: .markedUnfinished,
                    previousCurrentTime: snapshot.currentTime, previousIsFinished: snapshot.isFinished,
                    previousDuration: snapshot.duration)
            }
            bulkDone = bulkTotal
            working = false
            offerUndo(succeeded,
                      message: Self.markedUnfinishedToast(succeeded: succeeded.count, failed: failedIds.count),
                      failed: failedIds.count)
        }
    }

    private func beginWork(finishing: Bool, count: Int) {
        working = true
        bulkFinishing = finishing
        bulkTotal = count
        bulkDone = 0
    }

    private func offerUndo(_ snapshots: [LibraryProgressSnapshot], message: String, failed: Int) {
        if !snapshots.isEmpty {
            undoSnapshots = snapshots
            undoMessage = message
        } else if failed > 0 {
            resultMessage = Self.failureMessage(count: failed)
        }
        // LS-10: success haptic only when every request in the batch succeeded.
        if failed == 0 { Haptics.success() } else { Haptics.impact(.heavy) }
    }

    /// Undo: every book back to its snapshot in one batch, as Library's bulk Undo.
    private func undoBulkChange() {
        let snapshots = undoSnapshots
        undoSnapshots = []
        guard !snapshots.isEmpty else { return }
        Task {
            let failed = await libraryViewModel.restoreProgress(snapshots, reload: true)
            if !failed.isEmpty { resultMessage = LibraryView.undoFailureMessage(count: failed.count) }
        }
    }

    /// Plans and queues a bulk download; a refused plan (Wi-Fi only / low space) is
    /// surfaced through the same alert as other series errors and queues nothing.
    private func queueDownloads(_ items: [LibraryItem]) {
        let plan = downloadManager.bulkDownloadPlan(for: items)
        if let refusal = plan.refusal {
            if refusal != .nothingToDownload { resultMessage = refusal.message }
            return
        }
        downloadManager.downloadBooks(plan)
    }

}

enum SeriesBulkAction: Identifiable, Equatable {
    case markFinished, markUnfinished, downloadUnheard, downloadAll
    var id: Int { hashValue }
}

/// Polish pass (ST-1): the Series/Collections/Playlists "load failed" state said a bare
/// "Couldn't load". Same offline vs. server-unreachable split as Library's failed first load.
struct LoadFailedStateView: View {
    var action: () -> Void
    @State private var reachability = ReachabilityStore.shared

    var body: some View {
        let offline = reachability.status == .offline
        EmptyStateView(
            icon: offline ? "wifi.slash" : "exclamationmark.icloud",
            title: offline ? "You\u{2019}re offline" : "Can\u{2019}t reach your server",
            subtitle: offline ? "Your downloads still play." : "Check your connection and try again.",
            actionTitle: "Retry",
            action: { Haptics.selection(); action() }
        )
    }
}
