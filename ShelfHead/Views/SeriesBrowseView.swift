import SwiftUI

struct SeriesBrowseView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        Group {
            if libraryViewModel.isLoadingSeries && libraryViewModel.seriesList.isEmpty {
                LoadingView("Loading series...")
            } else if libraryViewModel.seriesList.isEmpty {
                EmptyStateView(
                    icon: "books.vertical",
                    title: "No series",
                    subtitle: "This library has no series yet"
                )
            } else {
                List {
                    ForEach(libraryViewModel.seriesList) { series in
                        NavigationLink(destination: SeriesDetailView(series: series)) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .foregroundColor(Color.shelfAccent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(series.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(.white)
                                    Text("\(series.bookCount) book\(series.bookCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(Color.shelfMuted)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task {
            if libraryViewModel.seriesList.isEmpty {
                await libraryViewModel.loadSeries()
            }
        }
    }
}

struct SeriesDetailView: View {
    let series: Series

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array((series.books ?? []).enumerated()), id: \.element.id) { index, item in
                        NavigationLink(destination: BookDetailView(item: item)) {
                            CassetteTile(
                                coverURL: shelfCoverURL(itemId: item.id),
                                title: item.title,
                                subtitle: item.authorName
                            )
                            .overlay(alignment: .topLeading) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(Color.shelfBackground)
                                    .frame(width: 22, height: 22)
                                    .background(Color.shelfAmber)
                                    .clipShape(Circle())
                                    .padding(6)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(series.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
