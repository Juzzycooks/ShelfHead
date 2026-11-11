import SwiftUI

/// Batch 424: "Search in Book". Searches the on-device transcript and jumps to the match.
/// The index is built once off the main actor; each (debounced) query runs off-main too.
/// Matches past how far the listener has heard are hidden by default, since a hit can
/// spoil the story; a footer toggle brings them in.
struct TranscriptSearchSheet: View {
    let itemId: String
    let bookTitle: String
    let chapters: [Chapter]
    let onSelect: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var includeAhead = false
    @State private var phase: Phase = .building
    @State private var index: TranscriptSearchIndex?
    @State private var transcript: Transcript?
    @State private var results: TranscriptSearchResults = .empty
    /// Kept so the toggle still reads "(N more)" after turning it on empties `hiddenAheadCount`.
    @State private var lastHiddenCount = 0

    private enum Phase { case building, noTranscript, ready }

    private struct SearchKey: Hashable {
        let query: String
        let includeAhead: Bool
        let ready: Bool
    }

    init(itemId: String, bookTitle: String, chapters: [Chapter], onSelect: @escaping (Double) -> Void) {
        self.itemId = itemId
        self.bookTitle = bookTitle
        self.chapters = chapters
        self.onSelect = onSelect
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearchable: Bool { TranscriptSearch.isSearchable(trimmedQuery) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Search in Book")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Search what's said"))
            .modifier(AutoFocusSearchModifier())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                }
            }
        }
        .systemChromeTint()
        .task { await buildIndex() }
        .task(id: SearchKey(query: trimmedQuery, includeAhead: includeAhead, ready: index != nil)) {
            await runSearch()
        }
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        switch phase {
        case .building:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noTranscript:
            // Polish pass (ST-8): the app's one empty-state component.
            EmptyStateView(icon: "text.magnifyingglass", title: "No transcript yet",
                           subtitle: "Make a transcript from Book Details to search what’s said in this book.")
        case .ready:
            if !isSearchable {
                VStack(spacing: 12) {
                    ContentUnavailableView {
                        Label("Search what’s said in this book", systemImage: "text.magnifyingglass")
                    } description: {
                        Text("Type a word or phrase to find the moment it was spoken.")
                    }
                    coverageNote
                        .padding(.horizontal, 20)
                }
            } else if results.hits.isEmpty && results.hiddenAheadCount == 0 {
                VStack(spacing: 12) {
                    ContentUnavailableView.search(text: trimmedQuery)
                    coverageNote
                        .padding(.horizontal, 20)
                }
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(results.hits) { hit in
                    row(hit)
                        .listRowBackground(Color.shelfCard)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    if results.isTruncated {
                        Typo.supporting(Text("Showing the first \(TranscriptSearch.defaultLimit) matches"))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    if results.hiddenAheadCount > 0 || includeAhead {
                        aheadToggle
                    }
                    coverageNote
                }
                .padding(.top, 6)
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var coverageNote: some View {
        if let transcript, !transcript.isComplete {
            Typo.supporting(Text("Transcript covers the first \(transcript.coveredUntil.formattedDuration) so far"))
                .foregroundStyle(Color.shelfMuted)
                .multilineTextAlignment(.leading)
        }
    }

    private var aheadToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $includeAhead) {
                if lastHiddenCount > 0 {
                    Text("Include parts you haven't heard (\(lastHiddenCount) more)")
                } else {
                    Text("Include parts you haven't heard")
                }
            }
            .tint(Color.shelfAmber)
            .frame(minHeight: 44)
            Typo.supporting(Text("Matches from later in the book might spoil the story."))
                .foregroundStyle(Color.shelfMuted)
        }
    }

    // MARK: - Rows

    private func row(_ hit: TranscriptSearchHit) -> some View {
        // Batch 490 (REVIEW 2026-11-11 P5): the time is chapter-relative beside its chapter title,
        // as the player shows it (whole-book time only for a chapterless book).
        let chapter = BookMoment.chapter(at: hit.time, in: chapters)
        let chapterTitle = chapter.map { PlayerView.displayChapterTitle($0.title) }
        let timeText = BookmarksSheet.momentTime(time: hit.time, chapter: chapter)
        let snippet = Self.highlighted(hit)
        return Button {
            Haptics.selection()
            dismiss()
            onSelect(hit.time)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    if let chapterTitle {
                        Typo.supporting(Text(verbatim: chapterTitle))
                            .foregroundStyle(Color.shelfMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Typo.figure(Text(verbatim: timeText))
                        .foregroundStyle(Color.shelfMuted)
                        .monospacedDigit()
                }
                Typo.rowTitle(Text(snippet))
                    .foregroundStyle(Color.shelfCream)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [chapterTitle, timeText, hit.snippet].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint("Plays from this point")
        .accessibilityAddTraits(.isButton)
    }

    /// The snippet as an `AttributedString` with each match bold in the accent text colour.
    /// Ranges that don't map back (a stale or out-of-range NSRange) are skipped.
    static func highlighted(_ hit: TranscriptSearchHit) -> AttributedString {
        var attributed = AttributedString(hit.snippet)
        for nsRange in hit.highlights {
            guard let strRange = Range(nsRange, in: hit.snippet),
                  let lower = AttributedString.Index(strRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(strRange.upperBound, within: attributed),
                  lower <= upper else { continue }
            // Emphasis, not a `.font`: a font here replaces the row's `Typo` size, so the match
            // rendered a size larger than the rest of the snippet.
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            attributed[lower..<upper].foregroundColor = Color.shelfAmberText
        }
        return attributed
    }

    // MARK: - Work

    private func buildIndex() async {
        guard let loaded = TranscriptionCenter.shared.transcript(for: itemId), !loaded.segments.isEmpty else {
            phase = .noTranscript
            return
        }
        transcript = loaded
        let built = await Task.detached(priority: .userInitiated) {
            TranscriptSearchIndex(transcript: loaded)
        }.value
        index = built
        phase = .ready
    }

    private func runSearch() async {
        guard let index else { return }
        let text = trimmedQuery
        guard TranscriptSearch.isSearchable(text) else {
            results = .empty
            lastHiddenCount = 0
            return
        }
        // Debounce: a cancelled task (next keystroke) throws out of the sleep.
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        let frontier: Double? = TranscriptionCenter.shared.frontier(for: itemId)
        let ahead = includeAhead
        let found = await Task.detached(priority: .userInitiated) {
            TranscriptSearch.search(text, in: index, frontier: frontier, includeAhead: ahead)
        }.value
        guard !Task.isCancelled else { return }
        results = found
        if !ahead { lastHiddenCount = found.hiddenAheadCount }
    }
}

/// Focuses the search field when the sheet opens. `searchFocused` is iOS 18+.
private struct AutoFocusSearchModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            Focused(content: content)
        } else {
            content
        }
    }

    @available(iOS 18.0, *)
    private struct Focused: View {
        let content: Content
        @FocusState private var focused: Bool
        var body: some View {
            content
                .searchFocused($focused)
                .task { focused = true }
        }
    }
}
