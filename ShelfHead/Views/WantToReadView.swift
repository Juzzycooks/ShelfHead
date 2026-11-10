import SwiftUI

/// Batch 443: the imported want-to-read list (Hardcover, Goodreads or StoryGraph). Books already
/// on the connected server are marked and open their book page.
struct WantToReadView: View {
    var model: ReadingSitesViewModel
    @Environment(LibraryViewModel.self) private var library
    @State private var confirmClear = false

    var body: some View {
        let candidates = library.items.filter { !$0.isPodcast }.map {
            ReadingSiteMatcher.Candidate(id: $0.id, title: $0.title, author: $0.authorName,
                                         isbn: $0.media?.metadata?.isbn, asin: $0.asin)
        }
        let owned = ReadingListCSV.owned(model.wantToRead, in: candidates)
        let byID = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let onServer = model.wantToRead.filter { owned[$0.id] != nil }.count

        List {
            if model.wantToRead.isEmpty {
                // Polish pass (ST-8): the app's one empty-state component, sentence case.
                EmptyStateView(icon: "bookmark", title: "Nothing here yet",
                               subtitle: "Import your want-to-read list from Settings › Reading Sites.")
            } else {
                Section {
                    ForEach(model.wantToRead) { entry in
                        if let itemID = owned[entry.id], let item = byID[itemID] {
                            NavigationLink(destination: BookDetailView(item: item)) {
                                row(entry, onServer: true)
                            }
                        } else {
                            row(entry, onServer: false)
                        }
                    }
                    .onDelete { offsets in offsets.map { model.wantToRead[$0] }.forEach(model.remove) }
                } footer: {
                    Text("\(onServer.formatted()) of \(model.wantToRead.count.formatted()) are already on your server.")
                }
                .listRowBackground(Color.shelfCard)
            }
        }
        .navigationTitle("Want to Read")
        .toolbar {
            if !model.wantToRead.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear the list?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearWantToRead() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ entry: WantToReadEntry, onServer: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title).font(.body)
                if !entry.author.isEmpty {
                    Text(verbatim: entry.author).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if onServer {
                Label("On your server", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.shelfAmberText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(onServer ? Text("On your server") : Text(""))
    }
}
