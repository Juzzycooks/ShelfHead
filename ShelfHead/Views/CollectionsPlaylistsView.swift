import SwiftUI

private let bookGridColumns = [
    GridItem(.flexible(), spacing: 16),
    GridItem(.flexible(), spacing: 16)
]

// MARK: - Collections

struct CollectionsBrowseView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        Group {
            if libraryViewModel.isLoadingCollections && libraryViewModel.collections.isEmpty {
                LoadingView("Loading collections…")
            } else if libraryViewModel.collections.isEmpty {
                EmptyStateView(icon: "rectangle.stack", title: "No collections", subtitle: "Collections you create on your server appear here")
            } else {
                List {
                    ForEach(libraryViewModel.collections) { collection in
                        NavigationLink(destination: BookCollectionDetailView(title: collection.displayName, books: collection.books ?? [])) {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.stack.fill")
                                    .foregroundColor(Color.shelfAccent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.displayName).font(.subheadline.weight(.medium)).foregroundColor(.white)
                                    Text("\(collection.bookCount) book\(collection.bookCount == 1 ? "" : "s")")
                                        .font(.caption).foregroundColor(Color.shelfMuted)
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
        .task { if libraryViewModel.collections.isEmpty { await libraryViewModel.loadCollections() } }
    }
}

// MARK: - Playlists

struct PlaylistsBrowseView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        Group {
            if libraryViewModel.isLoadingPlaylists && libraryViewModel.playlists.isEmpty {
                LoadingView("Loading playlists…")
            } else if libraryViewModel.playlists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "No playlists", subtitle: "Playlists you create on your server appear here")
            } else {
                List {
                    ForEach(libraryViewModel.playlists) { playlist in
                        NavigationLink(destination: BookCollectionDetailView(title: playlist.displayName, books: playlist.libraryItems)) {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .foregroundColor(Color.shelfAccent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.displayName).font(.subheadline.weight(.medium)).foregroundColor(.white)
                                    Text("\(playlist.libraryItems.count) item\(playlist.libraryItems.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundColor(Color.shelfMuted)
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
        .task { if libraryViewModel.playlists.isEmpty { await libraryViewModel.loadPlaylists() } }
    }
}

// MARK: - Shared detail grid (used by both collections & playlists)

struct BookCollectionDetailView: View {
    let title: String
    let books: [LibraryItem]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if books.isEmpty {
                EmptyStateView(icon: "book.closed", title: "Empty", subtitle: "Nothing in here yet")
            } else {
                ScrollView {
                    LazyVGrid(columns: bookGridColumns, spacing: 20) {
                        ForEach(books) { item in
                            NavigationLink(destination: BookDetailView(item: item)) {
                                CassetteTile(
                                    coverURL: shelfCoverURL(itemId: item.id),
                                    title: item.title,
                                    subtitle: item.authorName
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
