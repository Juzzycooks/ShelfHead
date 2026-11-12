import SwiftUI

// Batch 463: the Listening Passport. Every genre, narrator and publication decade you have
// finished a book in earns a stamp, plus milestone stamps for 1/5/10/25/50/100 finished
// books. Built from `FinishedBookCatalog`; the stamp rules are `PassportStamps`.
// DESIGN.md: earned stamps are Finished Teal (Teal-Means-Done), everything else is
// monochrome, no tape hardware, no motion.

// MARK: - Display helpers

extension PassportStamp {
    var symbol: String {
        switch kind {
        case .genre: return "theatermasks"
        case .narrator: return "mic"
        case .decade: return "calendar"
        case .milestone: return "flag.checkered"
        }
    }

    var kindTitle: String {
        switch kind {
        case .genre: return String(localized: "Genre", comment: "Passport stamp kind, used in VoiceOver")
        case .narrator: return String(localized: "Narrator", comment: "Passport stamp kind, used in VoiceOver")
        case .decade: return String(localized: "Decade", comment: "Passport stamp kind, used in VoiceOver")
        case .milestone: return String(localized: "Milestone", comment: "Passport stamp kind, used in VoiceOver")
        }
    }

    /// "Fantasy", "Jim Dale", "1990s", "First book", "25 books".
    var displayName: String {
        guard let n = threshold else { return name }
        if n == 1 { return String(localized: "First book", comment: "Passport milestone stamp for the first finished book") }
        return String(localized: "\(n.formatted()) books", comment: "Passport milestone stamp: %@ is a count such as 25")
    }

    /// "Narrator stamp: Jim Dale, earned 3 March 2026 with Harry Potter".
    var accessibilityText: String {
        let date = earnedAt.formatted(date: .long, time: .omitted)
        return String(localized: "\(kindTitle) stamp: \(displayName), earned \(date) with \(earnedByTitle)",
                      comment: "VoiceOver label for a passport stamp: %1$@ kind, %2$@ name, %3$@ date, %4$@ book title")
    }
}

// MARK: - Stamp badge

struct PassportStampBadge: View {
    let stamp: PassportStamp

    var body: some View {
        VStack(spacing: Space.s) {
            ZStack {
                Circle().strokeBorder(Color.shelfAccent, lineWidth: 2)
                Circle().strokeBorder(Color.shelfAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(5)
                Image(systemName: stamp.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.shelfAccentText)
            }
            .frame(width: 64, height: 64)
            Typo.rowTitle(Text(verbatim: stamp.displayName))
                .foregroundStyle(Color.shelfCream)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Typo.fine(Text(verbatim: stamp.earnedAt.formatted(date: .abbreviated, time: .omitted)))
                .foregroundStyle(Color.shelfMuted)
            Typo.fine(Text(verbatim: stamp.earnedByTitle))
                .foregroundStyle(Color.shelfMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(Space.m)
        .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Shareable card

/// Batch 463: the compact page that is rendered to an image for sharing. Fixed 360 x 480 so
/// it renders the same everywhere; Dynamic Type is capped because the size is fixed.
struct PassportCardView: View {
    let stamps: [PassportStamp]
    let booksFinished: Int
    let summary: PassportSummary

    static let size = CGSize(width: 360, height: 480)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Listening Passport")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Color.shelfCream)
            Text(verbatim: "\(String(localized: "\(booksFinished) books finished")) \u{00B7} \(String(localized: "\(stamps.count) stamps"))")
                .font(.footnote).foregroundStyle(Color.shelfMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 3), spacing: Space.s) {
                ForEach(Array(stamps.prefix(9))) { stamp in
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().strokeBorder(Color.shelfAccent, lineWidth: 2)
                            Image(systemName: stamp.symbol).foregroundStyle(Color.shelfAccentText)
                        }
                        .frame(width: 44, height: 44)
                        Text(verbatim: stamp.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.shelfCream)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            Spacer(minLength: 0)
            if let g = summary.topGenre {
                Text("Top genre: \(g)").font(.footnote).foregroundStyle(Color.shelfCream)
            }
            if let n = summary.favouriteNarrator {
                Text("Favourite narrator: \(n)").font(.footnote).foregroundStyle(Color.shelfCream)
            }
        }
        .padding(Space.xl)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.shelfBackground)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.large)
    }

    /// Renders the card at 3x. Main actor: `ImageRenderer` needs it.
    @MainActor static func render(stamps: [PassportStamp], booksFinished: Int, summary: PassportSummary) -> UIImage? {
        let renderer = ImageRenderer(content: PassportCardView(stamps: stamps, booksFinished: booksFinished, summary: summary))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Screen

struct ListeningPassportView: View {
    @State private var catalog = FinishedBookCatalog.shared
    @State private var openBook: OpenBook?
    @State private var cardImage: UIImage?
    @State private var showingShareSheet = false

    private struct OpenBook: Hashable, Identifiable { let id: String }

    private var stamps: [PassportStamp] { PassportStamps.stamps(from: catalog.books) }
    private var summary: PassportSummary { PassportStamps.summary(catalog.books) }
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Space.m)]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            // Batch 490 (REVIEW 2026-11-11 E2): a failed load no longer reads as "no stamps yet".
            switch FinishedCatalogDisplayState.resolve(isEmpty: catalog.books.isEmpty, isRefreshing: catalog.isRefreshing,
                                                       hasLoaded: catalog.hasLoaded, lastRefreshFailed: catalog.lastRefreshFailed) {
            case .loading:
                LoadingView("Loading your finished books\u{2026}")
            case .failed:
                EmptyStateView(icon: "airplane.departure", title: LocalizedStringResource("Couldn\u{2019}t load your finished books"),
                               subtitle: .verbatim(StatsStaleness.failureSubtitle(status: ReachabilityStore.shared.status)),
                               actionTitle: LocalizedStringResource("Retry"),
                               action: { Task { await catalog.refresh() } })
            case .empty:
                // Polish pass (ST-8): the app's one empty-state component, sentence case.
                EmptyStateView(icon: "airplane.departure", title: "No stamps yet",
                               subtitle: "Finish a book and your passport gets its first stamp.")
            case .content:
                content
            }
        }
        .navigationTitle("Listening Passport")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if cardImage != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    // Batch 464: a share sheet without SharePlay (`ActivityView`), not `ShareLink`.
                    Button { showingShareSheet = true } label: {
                        Label("Share Passport", systemImage: "square.and.arrow.up")
                    }
                    .monochromeToolbarItem()
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let cardImage { ActivityView(items: [cardImage]) }
        }
        .navigationDestination(item: $openBook) { book in
            CassetteWallBookDestination(itemId: book.id)
        }
        .task { await catalog.refresh() }
        .task(id: catalog.books) { renderCard() }
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
            catalog.reset()
            cardImage = nil
            Task { await catalog.refresh() }
        }
    }

    private func renderCard() {
        guard !catalog.books.isEmpty else { cardImage = nil; return }
        cardImage = PassportCardView.render(stamps: stamps, booksFinished: catalog.books.count, summary: summary)
    }

    private var content: some View {
        let all = stamps
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header(all)
                section("Milestones", .milestone, all)
                section("Genres", .genre, all)
                section("Narrators", .narrator, all)
                section("Decades", .decade, all)
            }
            .padding(.horizontal, Space.pageH)
            .padding(.vertical, Space.l)
        }
    }

    private func header(_ all: [PassportStamp]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Typo.cardTitle(Text("\(all.count) stamps"))
                .foregroundStyle(Color.shelfCream)
            Typo.rowSubtitle(Text("\(catalog.books.count) books finished"))
                .foregroundStyle(Color.shelfMuted)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, _ kind: PassportStamp.Kind, _ all: [PassportStamp]) -> some View {
        let items = PassportStamps.stamps(kind, in: all)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                RetroSectionHeader(title: title)
                LazyVGrid(columns: columns, spacing: Space.m) {
                    ForEach(items) { stamp in
                        Button { openBook = OpenBook(id: stamp.earnedByBookID) } label: {
                            PassportStampBadge(stamp: stamp)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(stamp.accessibilityText)
                        .accessibilityHint(Text("Opens the book that earned it"))
                    }
                }
            }
        }
    }
}
