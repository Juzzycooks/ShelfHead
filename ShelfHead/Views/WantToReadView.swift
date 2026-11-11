import SwiftUI

/// Batch 443: the imported want-to-read list (Hardcover, Goodreads or StoryGraph). Books already
/// on the connected server are marked and open their book page.
///
/// Batch 490 (REVIEW 2026-11-11 L6): matched against the whole library
/// (`LibraryViewModel.wholeLibrarySnapshot()`), not just the pages Library happened to have
/// loaded, which marked most owned books as missing. While that loads the footer says so; if it
/// fails, nothing is marked missing. Re-skinned like `MixtapesView` (shelf ground, `Typo`,
/// empty state outside the List, titled toolbar item, tinted dialog).
struct WantToReadView: View {
    var model: ReadingSitesViewModel
    @Environment(LibraryViewModel.self) private var library
    @State private var confirmClear = false
    @State private var check: LibraryCheck = .checking

    /// Batch 490 (REVIEW 2026-11-11 L6): where the whole-library check stands.
    enum LibraryCheck {
        case checking
        /// `itemsById` holds only the matched books, keyed by item id.
        case done(owned: [String: String], itemsById: [String: LibraryItem], partial: Bool)
        case failed
    }

    /// Batch 490 (REVIEW 2026-11-11 L6): which want-to-read entries are already on the server,
    /// as entry id → library item id. Podcasts never match. Pure, pinned by `QuickWinsLibraryTests`.
    nonisolated static func ownedMatches(_ entries: [WantToReadEntry], in candidates: [ReadingSiteMatcher.Candidate]) -> [String: String] {
        guard !entries.isEmpty, !candidates.isEmpty else { return [:] }
        return ReadingListCSV.owned(entries, in: candidates)
    }

    /// Batch 490 (REVIEW 2026-11-11 L6): the matcher's view of the library's books.
    static func candidates(from items: [LibraryItem]) -> [ReadingSiteMatcher.Candidate] {
        items.filter { !$0.isPodcast }.map {
            ReadingSiteMatcher.Candidate(id: $0.id, title: $0.title, author: $0.authorName,
                                         isbn: $0.media?.metadata?.isbn, asin: $0.asin)
        }
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if model.wantToRead.isEmpty {
                // Polish pass (ST-8): the app's one empty-state component, sentence case.
                // Batch 490 (REVIEW 2026-11-11 L6): outside the List, as `MixtapesView` has it.
                EmptyStateView(icon: "bookmark", title: "Nothing here yet",
                               subtitle: "Import your want-to-read list from Settings › Reading Sites.")
            } else {
                List {
                    Section {
                        ForEach(model.wantToRead) { entry in
                            entryRow(entry)
                                .listRowBackground(Color.shelfCard)
                                // Batch 490 (REVIEW 2026-11-11 L6): was `.onDelete`, where one
                                // full swipe removed the entry. Now it takes a tap on Remove.
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { model.remove(entry) } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    } footer: {
                        footer
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Want to Read")
        .toolbar {
            if !model.wantToRead.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    // Batch 490 (REVIEW 2026-11-11 L6): a titled `Label` in the monochrome
                    // toolbar style, like Mixtapes' toolbar item.
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .monochromeToolbarItem()
                }
            }
        }
        .confirmationDialog("Clear the list?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearWantToRead() }
            Button("Cancel", role: .cancel) {}
        }
        .systemChromeTint()   // Batch 490 (REVIEW 2026-11-11 L6)
        .task(id: library.selectedLibrary?.id) { await runCheck() }
    }

    /// Batch 490 (REVIEW 2026-11-11 L6): fetch (or reuse) the whole-library snapshot, then
    /// match off the main actor — the matcher normalises every title in the library.
    private func runCheck() async {
        guard !model.wantToRead.isEmpty else { return }
        check = .checking
        do {
            let (items, partial) = try await library.wholeLibrarySnapshot()
            let candidates = Self.candidates(from: items)
            let entries = model.wantToRead
            let owned = await Task.detached(priority: .userInitiated) {
                Self.ownedMatches(entries, in: candidates)
            }.value
            guard !Task.isCancelled else { return }
            let wanted = Set(owned.values)
            var byId: [String: LibraryItem] = [:]
            for item in items where wanted.contains(item.id) { byId[item.id] = item }
            check = .done(owned: owned, itemsById: byId, partial: partial)
        } catch {
            guard !Task.isCancelled else { return }
            ShelfLog.error(.network, "Want to Read library check failed: \(error.localizedDescription)")
            check = .failed
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: WantToReadEntry) -> some View {
        if case .done(let owned, let byId, _) = check,
           let itemID = owned[entry.id], let item = byId[itemID] {
            NavigationLink(destination: BookDetailView(item: item)) {
                row(entry, onServer: true)
            }
        } else {
            row(entry, onServer: false)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch check {
        case .checking:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Typo.supporting(Text("Checking your library…"))
            }
            .foregroundStyle(Color.shelfMuted)
            .accessibilityElement(children: .combine)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Typo.supporting(Text("Couldn’t check your library, so no books are marked yet. Check your connection, then try again."))
                    .foregroundStyle(Color.shelfMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { Task { await runCheck() } }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(minHeight: 44)
            }
        case .done(let owned, _, let partial):
            let onServer = model.wantToRead.filter { owned[$0.id] != nil }.count
            VStack(alignment: .leading, spacing: 4) {
                Typo.supporting(Text("\(onServer.formatted()) of \(model.wantToRead.count.formatted()) are already on your server."))
                if partial {
                    Typo.supporting(Text("Checked the first \(LibraryViewModel.smartFilterItemCap) books only"))
                }
            }
            .foregroundStyle(Color.shelfMuted)
        }
    }

    private func row(_ entry: WantToReadEntry, onServer: Bool) -> some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Typo.rowTitle(Text(verbatim: entry.title))
                    .foregroundStyle(Color.shelfCream)
                if !entry.author.isEmpty {
                    Typo.supporting(Text(verbatim: entry.author))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            Spacer(minLength: Space.s)
            if onServer {
                Label("On your server", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.shelfAmberText)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(onServer ? Text("On your server") : Text(""))
    }
}
