import SwiftUI

/// Batch 429 (Section F, part 2): X-Ray and Ask the Book. Both are written on this iPhone by the
/// on-device model from the part of the book the listener has heard (never beyond the frontier),
/// and both jump back into the book through `seek(to:reason:)`, so the Jump back chip can undo them.
///
/// From Book Detail the book may not be the one loaded in the player, so both sheets take an
/// optional `onSeek` that the page uses to start the book first; from the player they seek directly.

typealias KnowledgeSeek = (_ time: Double, _ reason: PlayerViewModel.SeekUndoReason) -> Void

// MARK: - X-Ray

/// People, places and terms named so far, merged across the whole heard book.
struct XRaySheet: View {
    let itemId: String
    let title: String
    var onSeek: KnowledgeSeek? = nil
    /// Batch 490 (REVIEW 2026-11-11 P5): the book's chapters, for a presenter whose book may not be
    /// the loaded one (Book Detail). Nil uses the player's when this is the loaded book.
    var chapters: [Chapter]? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Phase {
        case loading(Double)
        case ready([XRayEntry])
        case failed(IntelligenceUnavailable)
    }

    @State private var phase: Phase = .loading(0)
    @State private var attempt = 0
    @State private var selectedKind: NoteEntityKind = .person
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                switch phase {
                case .loading(let fraction): loading(fraction)
                case .ready(let entries):
                    ready(entries)
                        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                                    prompt: Text("Search names and notes"))
                case .failed(let reason): IntelligenceFailureView(reason: reason) { attempt += 1 }
                }
            }
            .navigationTitle("X-Ray")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Batch 490 (REVIEW 2026-11-11 V1): the shared close button, as the player's sheets use.
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
        .systemChromeTint()
        .task(id: attempt) { await load() }
    }

    private func load() async {
        phase = .loading(0)
        do {
            let entries = try await BookIntelligence.shared.xray(itemId: itemId) { fraction in
                phase = .loading(fraction)
            }
            phase = .ready(entries)
        } catch is CancellationError {
            return
        } catch let error as BookIntelligenceError {
            phase = .failed(error.reason)
        } catch {
            phase = .failed(.failed)
        }
    }

    private func loading(_ fraction: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: fraction)
                .tint(Color.shelfAmber)
                .frame(maxWidth: 280)
            Typo.supporting(Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0)))))
                .foregroundStyle(Color.shelfMuted)
                .monospacedDigit()
            Typo.rowTitle(Text("Reading what you've heard\u{2026}"))
                .foregroundStyle(Color.shelfCream)
                .multilineTextAlignment(.center)
            Typo.supporting(Text("The first time can take a few minutes for a long book. It happens on this iPhone."))
                .foregroundStyle(Color.shelfMuted)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }

    // MARK: Ready

    private func kindTitle(_ kind: NoteEntityKind) -> LocalizedStringResource {
        switch kind {
        case .person: return "People"
        case .place: return "Places"
        case .term: return "Terms"
        }
    }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Batch 490 (REVIEW 2026-11-11 P5): chapters to name moments by (none when this sheet is for
    /// a book other than the loaded one and the presenter passed none, which keeps plain time).
    private var momentChapters: [Chapter] { chapters ?? BookMoment.chapters(for: itemId, player: playerViewModel) }

    private func ready(_ entries: [XRayEntry]) -> some View {
        let presentKinds = NoteEntityKind.allCases.filter { kind in entries.contains { $0.kind == kind } }
        let activeKind = presentKinds.contains(selectedKind) ? selectedKind : (presentKinds.first ?? .person)
        let searching = !trimmedSearch.isEmpty
        let shown: [XRayEntry] = searching
            ? entries.filter { entry in
                entry.name.localizedCaseInsensitiveContains(trimmedSearch)
                    || entry.aliases.contains { $0.localizedCaseInsensitiveContains(trimmedSearch) }
                    || entry.allNotes.contains { $0.localizedCaseInsensitiveContains(trimmedSearch) }
            }
            : entries.filter { $0.kind == activeKind }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if entries.isEmpty {
                    emptyState
                } else {
                    if !searching, presentKinds.count > 1 {
                        Picker("Kind", selection: Binding(get: { activeKind }, set: { selectedKind = $0 })) {
                            ForEach(presentKinds, id: \.self) { kind in
                                Text(kindTitle(kind)).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if shown.isEmpty {
                        Typo.supporting(Text("No matches"))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(shown) { entry in row(entry) }
                    }
                }
                GeneratedFooter(text: String(localized: "From notes written on this iPhone about the parts you've heard.",
                                             comment: "Footer under the X-Ray list of people, places and terms"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Typo.rowTitle(Text("Nobody named yet"))
                .foregroundStyle(Color.shelfCream)
            Typo.supporting(Text("Listen a little further and the people, places and terms will show up here."))
                .foregroundStyle(Color.shelfMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
        .accessibilityElement(children: .combine)
    }

    private func row(_ entry: XRayEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Batch 432: the name and notes open the detail page; "First mentioned" stays a separate button.
            NavigationLink {
                XRayDetailView(itemId: itemId, entry: entry, chapters: momentChapters) { time in seek(to: time) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Typo.rowTitle(Text(verbatim: entry.name))
                            .foregroundStyle(Color.shelfCream)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(entry.notes.prefix(2).enumerated()), id: \.offset) { _, note in
                            Typo.supporting(Text(verbatim: note))
                                .foregroundStyle(Color.shelfMuted)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.shelfMuted)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows the profile and every mention"))
            Button {
                Haptics.selection()
                seek(to: entry.firstMention)
            } label: {
                // Batch 490 (REVIEW 2026-11-11 P5): the moment as the player names it.
                Text(String(localized: "First mentioned at \(BookMoment.label(time: entry.firstMention, chapters: momentChapters))",
                            comment: "Button on an X-Ray entry. %@ is a moment like 12:40 · Chapter 3 (a plain time like 1:12:40 when the book has no chapters); it jumps to where the name first came up"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.shelfAmberTextOnSurface)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)
    }

    private func seek(to time: Double) {
        if let onSeek {
            onSeek(time, .xray)
        } else {
            playerViewModel.seek(to: time, reason: .xray)
        }
        dismiss()
    }
}

// MARK: - X-Ray detail (Batch 432)

/// One entry's page: an on-device profile written from the notes and the passages that name it, the
/// passages themselves (each seeks), and the raw notes. Nothing past the listening frontier is used.
struct XRayDetailView: View {
    let itemId: String
    let entry: XRayEntry
    /// Batch 490 (REVIEW 2026-11-11 P5): names each mention as the player would ("12:44 · Chapter 3").
    var chapters: [Chapter] = []
    let onSeek: (Double) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private enum ProfilePhase {
        case loading
        case ready(String)
        case failed(IntelligenceUnavailable)
    }

    @State private var phase: ProfilePhase = .loading
    @State private var mentions: [XRayMention]?
    @State private var attempt = 0

    private static let shownMentions = 30

    private func kindTitle(_ kind: NoteEntityKind) -> LocalizedStringResource {
        switch kind {
        case .person: return "Person"
        case .place: return "Place"
        case .term: return "Term"
        }
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    profileSection
                    mentionsSection
                    notesSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(Text(verbatim: entry.name))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let found: [XRayMention]
            if let mentions { found = mentions } else {
                found = await BookIntelligence.shared.xrayMentions(itemId: itemId, entry: entry)
                mentions = found
            }
            let text = try await BookIntelligence.shared.xrayProfile(itemId: itemId, entry: entry, mentions: found)
            phase = .ready(text)
        } catch is CancellationError {
            return
        } catch let error as BookIntelligenceError {
            phase = .failed(error.reason)
        } catch {
            phase = .failed(.failed)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Typo.supporting(Text(kindTitle(entry.kind)))
                .foregroundStyle(Color.shelfMuted)
            Typo.rowTitle(Text(verbatim: entry.name))
                .foregroundStyle(Color.shelfCream)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var profileSection: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Typo.supporting(Text("Writing a profile\u{2026}"))
                    .foregroundStyle(Color.shelfMuted)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        case .ready(let text):
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(Color.shelfCream)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                GeneratedFooter(text: String(localized: "Written on this iPhone from the parts you've heard. It can be wrong.",
                                             comment: "Footer on the Ask the Book sheet: answers are generated on device and may be wrong"))
            }
            .padding(16)
            .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)
        case .failed(let reason):
            IntelligenceFailureView(reason: reason) { attempt += 1 }
                .padding(.horizontal, -Space.xl)
        }
    }

    @ViewBuilder private var mentionsSection: some View {
        if let mentions, !mentions.isEmpty {
            let shown = XRayProfilePlanner.sample(mentions, limit: Self.shownMentions)
            VStack(alignment: .leading, spacing: 8) {
                Typo.cardTitle(Text("Mentions"))
                    .foregroundStyle(Color.shelfCream)
                    .accessibilityAddTraits(.isHeader)
                if shown.count < mentions.count {
                    Typo.supporting(Text("Showing \(shown.count) of \(mentions.count), spread across what you've heard"))
                        .foregroundStyle(Color.shelfMuted)
                }
                ForEach(shown) { mention in mentionRow(mention) }
            }
        }
    }

    private func mentionRow(_ mention: XRayMention) -> some View {
        let stamp = BookMoment.label(time: mention.time, chapters: chapters)   // Batch 490 (REVIEW 2026-11-11 P5)
        return Button {
            Haptics.selection()
            onSeek(mention.time)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: stamp)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.shelfAmberTextOnSurface)
                Typo.supporting(Text(verbatim: mention.snippet))
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8): a row
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(stamp). \(mention.snippet)"))
        .accessibilityHint(Text("Jumps to this point in the book"))
    }

    @ViewBuilder private var notesSection: some View {
        if !entry.allNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Typo.supporting(Text("Notes"))
                    .foregroundStyle(Color.shelfMuted)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(entry.allNotes.enumerated()), id: \.offset) { _, note in
                    Typo.fine(Text(verbatim: note))
                        .foregroundStyle(Color.shelfMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Ask the Book

/// One question and its answer, kept for the life of the sheet only.
private struct AskExchange: Identifiable {
    let id = UUID()
    var question: String
    var answer: String
    var citations: [Passage]
}

/// A question that is being answered, or that failed.
private struct AskInFlight {
    var question: String
    var partial = ""
    var failure: IntelligenceUnavailable?
}

struct AskBookSheet: View {
    let itemId: String
    let title: String
    let author: String
    var onSeek: KnowledgeSeek? = nil
    /// Batch 490 (REVIEW 2026-11-11 P5): as `XRaySheet.chapters`.
    var chapters: [Chapter]? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var history: [AskExchange] = []
    @State private var inFlight: AskInFlight?
    @State private var isAnswering = false
    @State private var answerTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private static let historyLimit = 5

    private var canAsk: Bool {
        !isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                conversation
            }
            .navigationTitle("Ask the Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Batch 490 (REVIEW 2026-11-11 V1): the shared close button, as the player's sheets use.
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        }
        .systemChromeTint()
        .onDisappear { answerTask?.cancel() }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if history.isEmpty && inFlight == nil {
                        Typo.supporting(Text("Ask about the people, places or events you've heard so far. It won't spoil what's ahead."))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(history) { exchange in
                        exchangeView(exchange)
                    }
                    if let inFlight { inFlightView(inFlight) }
                    GeneratedFooter(text: String(localized: "Written on this iPhone from the parts you've heard. It can be wrong.",
                                                 comment: "Footer on the Ask the Book sheet: answers are generated on device and may be wrong"))
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // Batch 490 (REVIEW 2026-11-11 A5): no animated scroll under Reduce Motion.
            .onChange(of: history.count) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: inFlight?.question) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func questionBubble(_ text: String) -> some View {
        Typo.rowTitle(Text(verbatim: text))
            .foregroundStyle(Color.shelfCream)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func answerCard(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.body)
            .foregroundStyle(Color.shelfCream)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)
    }

    private func exchangeView(_ exchange: AskExchange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionBubble(exchange.question)
            answerCard(exchange.answer)
            if !exchange.citations.isEmpty {
                Typo.fine(Text("Where it comes from"))
                    .foregroundStyle(Color.shelfMuted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(exchange.citations.enumerated()), id: \.offset) { _, passage in
                        citationChip(passage)
                    }
                }
            }
        }
    }

    private func citationChip(_ passage: Passage) -> some View {
        // Batch 490 (REVIEW 2026-11-11 P5): the moment as the player names it. It can now carry a
        // chapter title, so the chip may wrap to two lines (the grid's columns are wider for it).
        let stamp = BookMoment.label(time: passage.start, chapters: chapters ?? BookMoment.chapters(for: itemId, player: playerViewModel))
        return Button {
            Haptics.selection()
            seek(to: passage.start)
        } label: {
            Text(verbatim: stamp)
                .monospacedDigit()
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(Color.shelfAmberTextOnSurface)
        .accessibilityLabel(Text("Play from \(stamp)"))
    }

    @ViewBuilder
    private func inFlightView(_ state: AskInFlight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionBubble(state.question)
            if let reason = state.failure {
                IntelligenceFailureView(reason: reason) { ask(state.question) }
                    .padding(.horizontal, -Space.xl)
            } else if state.partial.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Typo.supporting(Text("Looking through what you've heard\u{2026}"))
                        .foregroundStyle(Color.shelfMuted)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            } else {
                answerCard(state.partial)
            }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask a question", text: $draft)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { ask(draft) }
                .textFieldStyle(.plain)
                .foregroundStyle(Color.shelfCream)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)
            Button {
                ask(draft)
            } label: {
                Text("Ask")
                    .fontWeight(.semibold)
                    // Ink on the accent fill is contrast-picked, not white (DESIGN.md).
                    .foregroundStyle(canAsk ? Color.onAccent : Color.shelfMuted)
                    .padding(.horizontal, 18)
                    .frame(minWidth: 44, minHeight: 44)
                    // Drawn by hand: a disabled .borderedProminent button is forced to a near-black
                    // fill whatever the tint, so the empty state read as a black hole. Disabled, it
                    // is a muted card like the field beside it.
                    .background(canAsk ? Color.shelfAmber : Color.shelfCard, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canAsk)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.shelfBackground)
    }

    // MARK: Actions

    private func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        draft = ""
        inFlight = AskInFlight(question: question)
        isAnswering = true
        answerTask = Task {
            do {
                for try await update in BookIntelligence.shared.ask(itemId: itemId, title: title,
                                                                   author: author, question: question) {
                    switch update {
                    case .partial(let snapshot):
                        inFlight?.partial = snapshot
                    case .done(let answer, let citations):
                        history.append(AskExchange(question: question, answer: answer, citations: citations))
                        history = Array(history.suffix(Self.historyLimit))
                        inFlight = nil
                    }
                }
                // A stream that ends without an answer shouldn't leave a spinner behind.
                if inFlight != nil, inFlight?.failure == nil { inFlight?.failure = .failed }
            } catch is CancellationError {
                inFlight = nil
            } catch let error as BookIntelligenceError {
                inFlight?.failure = error.reason
            } catch {
                inFlight?.failure = .failed
            }
            isAnswering = false
        }
    }

    private func seek(to time: Double) {
        if let onSeek {
            onSeek(time, .ask)
        } else {
            playerViewModel.seek(to: time, reason: .ask)
        }
        dismiss()
    }
}
