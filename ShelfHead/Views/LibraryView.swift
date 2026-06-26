import SwiftUI

struct LibraryView: View {
    /// Incremented by the parent when the Library tab is re-tapped; changing it
    /// rebuilds the NavigationStack (pops to root).
    var resetToken: Int = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var browseMode: BrowseMode = .books
    /// Observed so the per-cell download badge refreshes when a download completes.
    @State private var downloadManager = DownloadManager.shared

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        @Bindable var libraryViewModel = libraryViewModel
        return NavigationStack {
            ZStack {
                Color.shelfBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Menu {
                        Picker("Browse", selection: $browseMode) {
                            ForEach(BrowseMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: browseMode.icon)
                            Text(browseMode.rawValue)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(Color.shelfAmber)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.vertical, 8)

                    switch browseMode {
                    case .books:
                        booksContent
                    case .series:
                        SeriesBrowseView()
                    case .authors:
                        AuthorsBrowseView()
                    case .collections:
                        CollectionsBrowseView()
                    case .playlists:
                        PlaylistsBrowseView()
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, isPresented: $isSearchActive, prompt: "Search books...")
            .onChange(of: searchText) { _, newValue in
                libraryViewModel.searchQuery = newValue
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
                    if libraryViewModel.searchQuery == newValue {
                        await libraryViewModel.search()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if browseMode == .books {
                        sortFilterMenu
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
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
                            Image(systemName: "building.columns.fill")
                                .foregroundColor(Color.shelfAmber)
                        }
                    }
                }
            }
            .refreshable {
                await libraryViewModel.refresh()
            }
            .errorAlert(message: $libraryViewModel.errorMessage) {
                Task { await libraryViewModel.refresh() }
            }
        }
        .id(resetToken)
    }

    @ViewBuilder
    private var booksContent: some View {
        if libraryViewModel.isLoadingItems && libraryViewModel.items.isEmpty {
            LoadingView("Loading library...")
        } else {
            ScrollView {
                if isSearchActive && !searchText.isEmpty {
                    searchResultsView
                } else {
                    libraryGridView
                }
            }
        }
    }

    // MARK: - Sort / Filter Menu

    private var sortFilterMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { libraryViewModel.sortOption },
                set: { newValue in
                    libraryViewModel.sortOption = newValue
                    Task { await libraryViewModel.applySortFilter() }
                }
            )) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Button {
                libraryViewModel.sortDescending.toggle()
                Task { await libraryViewModel.applySortFilter() }
            } label: {
                Label(libraryViewModel.sortDescending ? "Descending" : "Ascending",
                      systemImage: libraryViewModel.sortDescending ? "arrow.down" : "arrow.up")
            }

            Divider()

            Picker("Filter", selection: Binding(
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
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle\(libraryViewModel.progressFilter == .all ? "" : ".fill")")
                .foregroundColor(Color.shelfAmber)
        }
    }

    // MARK: - Library Grid

    private var libraryGridView: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(libraryViewModel.items) { item in
                let finished = libraryViewModel.progressFor(itemId: item.id)?.isFinished ?? item.isFinished
                let progress = libraryViewModel.progressFor(itemId: item.id)?.progress ?? item.progressPercent
                NavigationLink(destination: BookDetailView(item: item)) {
                    CassetteTile(
                        coverURL: shelfCoverURL(itemId: item.id),
                        title: item.title,
                        subtitle: item.authorName,
                        progress: finished ? 0 : progress,
                        downloaded: downloadManager.isDownloaded(itemId: item.id)
                    )
                }
                .buttonStyle(.plain)
                .task {
                    await libraryViewModel.loadMoreIfNeeded(currentItem: item)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        LazyVStack(spacing: 12) {
            if libraryViewModel.isSearching {
                LoadingView("Searching...")
            } else if libraryViewModel.searchResults.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    subtitle: "Try a different search term"
                )
            } else {
                ForEach(libraryViewModel.searchResults) { item in
                    NavigationLink(destination: BookDetailView(item: item)) {
                        SearchResultRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Library Grid Item

struct LibraryGridItem: View {
    let item: LibraryItem
    var progress: Double = 0
    var isFinished: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CoverImageView(
                    itemId: item.id,
                    width: (UIScreen.main.bounds.width - 60) / 3,
                    height: (UIScreen.main.bounds.width - 60) / 3
                )

                if progress > 0 && !isFinished {
                    BookProgressBar(progress: progress)
                        .padding(4)
                }
            }

            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundColor(.white)
                .lineLimit(2)

            Text(item.authorName)
                .font(.caption2)
                .foregroundColor(Color.shelfMuted)
                .lineLimit(1)
        }
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(itemId: item.id, width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(item.authorName)
                    .font(.caption)
                    .foregroundColor(Color.shelfMuted)
                    .lineLimit(1)

                if item.duration > 0 {
                    Text(item.duration.formattedDuration)
                        .font(.caption2)
                        .foregroundColor(Color.shelfMuted)
                }
            }

            Spacer()

            if item.progressPercent > 0 {
                CircularProgressView(progress: item.progressPercent)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(12)
        .shelfCardStyle()
    }
}

// MARK: - Circular Progress

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.shelfSurface, lineWidth: 3)

            Circle()
                .trim(from: 0, to: min(progress, 1.0))
                .stroke(Color.shelfAmber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(Int(progress * 100))%")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Color.shelfAmber)
        }
    }
}

#Preview {
    LibraryView(resetToken: 0)
        .environment(LibraryViewModel())
        .environment(PlayerViewModel())
}
