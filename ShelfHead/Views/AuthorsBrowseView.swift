import SwiftUI

struct AuthorsBrowseView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel

    private var authors: [NamedEntity] {
        libraryViewModel.filterData?.authors ?? []
    }

    var body: some View {
        Group {
            if authors.isEmpty {
                EmptyStateView(
                    icon: "person.2",
                    title: "No authors",
                    subtitle: "Author data will appear once your library is scanned"
                )
            } else {
                List {
                    ForEach(authors) { author in
                        NavigationLink(destination: AuthorBooksView(author: author)) {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundColor(Color.shelfAmber)
                                    .frame(width: 28)
                                Text(author.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.white)
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
            if libraryViewModel.filterData == nil {
                await libraryViewModel.loadFilterData()
            }
        }
    }
}

struct AuthorBooksView: View {
    let author: NamedEntity
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var books: [LibraryItem] = []
    @State private var isLoading = true

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if isLoading {
                LoadingView("Loading…")
            } else if books.isEmpty {
                EmptyStateView(icon: "book.closed", title: "No books", subtitle: "Nothing found for this author")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
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
        .navigationTitle(author.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let filter = APIFilter.encode(group: "authors", value: author.id)
            books = await libraryViewModel.items(filteredBy: filter)
            isLoading = false
        }
    }
}
