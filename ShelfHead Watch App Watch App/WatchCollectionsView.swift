import SwiftUI

/// "Collections" — lists the phone's collections, capped to a small count/size
/// (`WatchSessionManager.collectionsCap`/`collectionBookCap`) since this stays a
/// companion controller rather than a full library browser. Tapping a collection drills
/// into its (also capped) book list; tapping a book asks the phone to play it.
struct WatchCollectionsView: View {
    @Environment(WatchConnectivityStore.self) private var store

    var body: some View {
        Group {
            if store.collections.isEmpty {
                WatchOpenOniPhoneEmptyState(systemImage: "folder", message: "Open ShelfHead on iPhone to sync collections")
            } else {
                List(store.collections) { collection in
                    NavigationLink {
                        CollectionBooksView(collection: collection)
                    } label: {
                        WatchRow(
                            systemImage: "folder.fill",
                            title: .verbatim(collection.name),
                            subtitle: collection.bookCount == 1 ? "1 book" : "\(collection.bookCount) books")
                    }
                }
                // Batch 412: default list style (no `.carousel` on Library screens).
            }
        }
        .navigationTitle("Collections")
    }
}

/// Books within a single collection. If the collection has more books than were
/// mirrored to the Watch (`bookCount` > `books.count`), says so rather than silently
/// truncating without explanation.
struct CollectionBooksView: View {
    @Environment(WatchConnectivityStore.self) private var store
    @State private var pendingPlay: WatchPlayRequest?
    let collection: WatchCollectionSummary

    var body: some View {
        Group {
            if collection.books.isEmpty {
                WatchOpenOniPhoneEmptyState(systemImage: "book", message: "No books synced for this collection")
            } else {
                List {
                    ForEach(collection.books) { book in
                        Button {
                            store.requestPlay(itemId: book.id, title: book.title, pending: $pendingPlay)
                        } label: {
                            BookSummaryRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                    if collection.bookCount > collection.books.count {
                        Text("+ \(collection.bookCount - collection.books.count) more on iPhone")
                            .font(WatchMetrics.subtitleFont())
                            .foregroundStyle(WatchTheme.secondaryText)
                    }
                }
            }
        }
        .navigationTitle(collection.name)
        .confirmsPlayReplacement($pendingPlay)
    }
}

#Preview {
    NavigationStack { WatchCollectionsView() }
        .environment(WatchConnectivityStore.shared)
}
