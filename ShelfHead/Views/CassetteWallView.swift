import SwiftUI

// Batch 459: the Cassette Wall. Every finished book is a cassette standing spine-out on a
// shelf, grouped by the year it was finished, in a flat SwiftUI shelf. Batch 464 parked the
// iOS 18 RealityKit wall after the device test (CW1: "3d animation looks ugly and text is
// blurry. 2d is fine"); it's in docs/parked/cassette-wall-3d-batch-459/. DESIGN.md exception:
// an archive surface, tape hardware at rest.

// MARK: - Spine

/// Batch 459: one cassette spine, drawn in SwiftUI as the flat shelf's button face. Shell colour is seeded per
/// book (`CassetteWallLayout.shellTone`), ink from `CoverPalette.ink(on:)`. The only accent is
/// the small Finished Teal notch at the foot (Teal-Means-Done). Text is decorative here; the
/// callers carry the accessibility label, so Dynamic Type is capped inside the fixed spine.
struct CassetteSpineView: View {
    let book: FinishedBook
    var width: CGFloat = 44

    /// Spine aspect: 1 wide to 5 tall.
    static let aspect: CGFloat = 5
    var height: CGFloat { width * Self.aspect }

    private var shell: Color {
        let tone = CassetteWallLayout.shellTone(for: book.id)
        return Color(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness)
    }

    var body: some View {
        let ink = CoverPalette.ink(on: shell)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).fill(shell)
            RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous)
                .strokeBorder(ink.opacity(0.25), lineWidth: 1)
            VStack(spacing: 6) {
                Typo.fine(Text(verbatim: yearMarker), weight: .semibold)
                    .foregroundStyle(ink.opacity(0.8))
                    .padding(.top, 6)
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 2) {
                        Typo.supporting(Text(verbatim: book.title), weight: .semibold)
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Typo.fine(Text(verbatim: book.author))
                            .foregroundStyle(ink.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(width: geo.size.height, height: geo.size.width, alignment: .leading)
                    .rotationEffect(.degrees(-90), anchor: .topLeading)
                    .offset(y: geo.size.height)
                }
                Circle().fill(Color.shelfAccent)
                    .frame(width: 7, height: 7)
                    .padding(.bottom, 8)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    /// "'24": the two-digit year it was finished.
    private var yearMarker: String {
        let year = Calendar.current.component(.year, from: book.finishedAt)
        return "\u{2019}" + String(format: "%02d", year % 100)
    }
}

extension FinishedBook {
    /// "Title by Author, finished 4 Mar 2026", the VoiceOver label for a spine.
    var spineAccessibilityLabel: String {
        let date = finishedAt.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(title) by \(author), finished \(date)",
                      comment: "VoiceOver label for a finished-book cassette: %1$@ title, %2$@ author, %3$@ date")
    }
}

// MARK: - Wall

struct CassetteWallView: View {
    /// Called with a library item id when a cassette is tapped. When nil the wall pushes
    /// Book Detail itself.
    var onOpenBook: ((String) -> Void)?

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var catalog = FinishedBookCatalog.shared
    @State private var openBook: OpenBook?

    private struct OpenBook: Hashable, Identifiable { let id: String }

    init(onOpenBook: ((String) -> Void)? = nil) {
        self.onOpenBook = onOpenBook
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            // Batch 490 (REVIEW 2026-11-11 E2): a failed load no longer reads as "no finished books".
            switch FinishedCatalogDisplayState.resolve(isEmpty: catalog.books.isEmpty, isRefreshing: catalog.isRefreshing,
                                                       hasLoaded: catalog.hasLoaded, lastRefreshFailed: catalog.lastRefreshFailed) {
            case .loading:
                LoadingView("Loading your finished books\u{2026}")
            case .failed:
                EmptyStateView(icon: "books.vertical", title: LocalizedStringResource("Couldn\u{2019}t load your finished books"),
                               subtitle: .verbatim(StatsStaleness.failureSubtitle(status: ReachabilityStore.shared.status)),
                               actionTitle: LocalizedStringResource("Retry"),
                               action: { Task { await catalog.refresh() } })
            case .empty:
                // Polish pass (ST-8): the app's one empty-state component, sentence case.
                EmptyStateView(icon: "books.vertical", title: "No finished books yet",
                               subtitle: "Finish a book and its cassette appears on your wall.")
            case .content:
                content
            }
        }
        .navigationTitle("Cassette Wall")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openBook) { book in
            CassetteWallBookDestination(itemId: book.id)
        }
        .task { await catalog.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
            catalog.reset()
            Task { await catalog.refresh() }
        }
    }

    private var content: some View {
        CassetteFlatShelf(books: catalog.books, onOpenBook: open)
    }

    private func open(_ id: String) {
        if let onOpenBook { onOpenBook(id) } else { openBook = OpenBook(id: id) }
    }
}

// MARK: - Flat shelf

/// Batch 459: the wall itself (the only one since Batch 464): year sections of spines in a grid.
struct CassetteFlatShelf: View {
    let books: [FinishedBook]
    let onOpenBook: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: Space.s, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xl, pinnedViews: []) {
                ForEach(CassetteWallLayout.groupByYear(books)) { group in
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Typo.cardTitle(Text(verbatim: String(group.year)))
                                .foregroundStyle(Color.shelfCream)
                                .accessibilityAddTraits(.isHeader)
                            Typo.supporting(Text("\(group.books.count) finished"))
                                .foregroundStyle(Color.shelfMuted)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.m) {
                            ForEach(group.books) { book in
                                Button { onOpenBook(book.id) } label: {
                                    CassetteSpineView(book: book, width: 48)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(book.spineAccessibilityLabel)
                                .accessibilityHint("Opens the book")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }
}

// MARK: - Destination

/// Resolves a finished book's item (downloaded copy first, else the server) and shows Book
/// Detail; same approach as Stats' session rows.
struct CassetteWallBookDestination: View {
    let itemId: String
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var item: LibraryItem?
    @State private var failed = false

    var body: some View {
        Group {
            if let item {
                BookDetailView(item: item)
            } else {
                ZStack {
                    Color.shelfBackground.ignoresSafeArea()
                    if failed {
                        EmptyStateView(icon: "book.closed", title: LocalizedStringResource("Couldn\u{2019}t open this book"),
                                       subtitle: .verbatim(StatsStaleness.failureSubtitle(status: ReachabilityStore.shared.status)),
                                       // Batch 490 (REVIEW 2026-11-11 E6): the house word is "Retry".
                                       actionTitle: LocalizedStringResource("Retry"),
                                       action: { Task { await resolve() } })
                    } else {
                        LoadingView("Opening book\u{2026}")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard item == nil else { return }
        failed = false
        if let local = DownloadManager.shared.libraryItem(for: itemId) {
            item = local
        } else if let fetched = await libraryViewModel.getItemDetail(itemId: itemId) {
            item = fetched
        } else {
            failed = true
        }
    }
}
