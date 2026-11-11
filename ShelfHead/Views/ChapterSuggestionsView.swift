import SwiftUI

// MARK: - Inputs

/// Batch 427 (Section E): what the chapter suggester needs to know about the loaded book.
/// Built from the server's own chapters, never the ones made on this device, so "suggest
/// again" and the offer check always judge the original markers.
struct ChapterSuggestionContext: Sendable {
    var itemId: String
    var bookDuration: Double
    var serverChapters: [Chapter]
    var droppedCount: Int
    var trackStarts: [Double]
    var trackTitles: [String]
    var isDownloaded: Bool

    var issues: [ChapterHealthIssue] {
        ChapterHealth.issues(chapters: serverChapters, droppedCount: droppedCount, bookDuration: bookDuration)
    }

    /// Cheap and synchronous enough for a view body: reads the player, the manifest and the
    /// small transcript meta file, never the transcript itself.
    @MainActor
    static func make(playerViewModel: PlayerViewModel) -> ChapterSuggestionContext? {
        guard let book = playerViewModel.currentBook else { return nil }
        let service = AudioPlayerService.shared
        let session = service.currentSession
        let isLiveBook = session != nil && service.currentItemId == book.id
        let server = isLiveBook ? (service.serverChapters ?? []) : book.chapters
        let dropped = isLiveBook ? service.serverDroppedChapterCount : book.droppedChapterCount
        let manifest = DownloadManager.shared.manifest(for: book.id)

        // Track boundaries: titles come from the session's tracks when this book is live,
        // otherwise only the manifest's start offsets are known.
        var pairs: [(start: Double, title: String)] = []
        if isLiveBook, let tracks = session?.audioTracks, tracks.count > 1 {
            pairs = tracks.map { ($0.startOffset ?? 0, $0.title ?? "") }
        } else if let manifest, manifest.tracks.count > 1 {
            pairs = manifest.tracks.map { ($0.startOffset, "") }
        }
        pairs = pairs.filter { $0.start > 0 }.sorted { $0.start < $1.start }

        var duration = playerViewModel.duration
        if duration <= 0 { duration = manifest?.duration ?? 0 }
        return ChapterSuggestionContext(
            itemId: book.id, bookDuration: duration, serverChapters: server, droppedCount: dropped,
            trackStarts: pairs.map(\.start), trackTitles: pairs.map(\.title),
            isDownloaded: manifest != nil && QuoteClipExporter.hasLocalAudio(itemId: book.id))
    }

    /// The offer: the book's chapters are missing or useless, and there is something to
    /// work from (downloaded audio, or a transcript with text).
    @MainActor
    var isOffered: Bool {
        guard !issues.isEmpty else { return false }
        if isDownloaded { return true }
        let meta = TranscriptStore.meta(itemId: itemId)
        return meta.fraction > 0 || meta.isComplete
    }
}

// MARK: - Model

@Observable @MainActor
final class ChapterSuggestionsModel {
    enum Phase: Equatable {
        case scanning(Double?)
        case ready
        case failed(String)
    }

    var phase: Phase = .scanning(nil)
    var suggestions: [ChapterSuggestion] = []
    /// What a cue said when it was found, so the source caption survives the user renaming it.
    private(set) var heardTitles: [Int: String] = [:]
    private var task: Task<Void, Never>?

    private struct TranscriptAnalysis: Sendable {
        var cues: [ChapterCue] = []
        var pauses: [SilenceGap] = []
        var hasText = false
    }

    /// Transcript work off the main actor: decoding the file, cue detection, and the
    /// pauses between segments (a cheap stand-in for audio silence when the book isn't downloaded).
    @concurrent nonisolated private static func analyseTranscript(itemId: String) async -> TranscriptAnalysis {
        guard let transcript = TranscriptStore.load(itemId: itemId), !transcript.segments.isEmpty else {
            return TranscriptAnalysis()
        }
        let segments = transcript.segments
        var pauses: [SilenceGap] = []
        for (previous, next) in zip(segments, segments.dropFirst()) where next.start - previous.end >= 1.5 {
            pauses.append(SilenceGap(start: previous.end, end: next.start))
        }
        return TranscriptAnalysis(cues: ChapterCueDetector.cues(in: segments), pauses: pauses, hasText: true)
    }

    func start(_ context: ChapterSuggestionContext) {
        task?.cancel()
        phase = .scanning(nil)
        task = Task { await run(context) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(_ context: ChapterSuggestionContext) async {
        let analysis = await Self.analyseTranscript(itemId: context.itemId)
        guard !Task.isCancelled else { return }
        var gaps = analysis.pauses
        var scanFailure: Error?
        if context.isDownloaded {
            do {
                gaps = try await SilenceScanner.scan(itemId: context.itemId) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .scanning = self.phase else { return }
                        self.phase = .scanning(fraction)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                scanFailure = error
            }
        }
        guard !Task.isCancelled else { return }
        if let scanFailure, !analysis.hasText {
            phase = .failed(scanFailure.localizedDescription)
            return
        }
        let proposal = ChapterProposalBuilder.suggestions(
            bookDuration: context.bookDuration, serverChapters: context.serverChapters,
            cues: analysis.cues, trackStarts: context.trackStarts, trackTitles: context.trackTitles,
            gaps: gaps)
        heardTitles = Dictionary(uniqueKeysWithValues: proposal.filter { $0.source == .cue }.map { ($0.id, $0.title) })
        suggestions = proposal
        phase = .ready
    }

    var includedCount: Int { suggestions.filter(\.isIncluded).count }
    /// Only the opening chapter at 0: nothing was found.
    var foundNothing: Bool { suggestions.count < 2 }

    func nudge(id: Int, by seconds: Double, bookDuration: Double) {
        suggestions = ChapterProposalBuilder.nudged(suggestions, id: id, by: seconds, bookDuration: bookDuration)
    }
}

// MARK: - View

/// Batch 427: pushed from the chapter list. Shows chapters found from pauses, spoken
/// announcements and track starts; the listener keeps, renames and nudges them, then saves
/// them on this device (nothing is sent to the server).
struct ChapterSuggestionsView: View {
    let context: ChapterSuggestionContext

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var model = ChapterSuggestionsModel()
    @State private var saveFailed = false
    @FocusState private var focusedId: Int?

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            switch model.phase {
            case .scanning(let fraction):
                scanning(fraction)
            case .failed(let message):
                failure(message)
            case .ready:
                if model.foundNothing { nothingFound } else { results }
            }
        }
        .navigationTitle("Suggested Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            // Batch 490 (REVIEW 2026-11-11 V1): the shared Cancel and Save, as Edit Bookmark uses.
            ToolbarItem(placement: .cancellationAction) {
                SheetCancelButton { dismiss() }
                    .monochromeToolbarItem()
            }
            ToolbarItem(placement: .confirmationAction) {
                SheetConfirmButton(title: "Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(model.phase != .ready || model.includedCount < 2)
                    .monochromeToolbarItem()
            }
            .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
        }
        .onAppear { if model.suggestions.isEmpty, model.phase == .scanning(nil) { model.start(context) } }
        .onDisappear { model.cancel() }
    }

    // MARK: States

    private func scanning(_ fraction: Double?) -> some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction)
                    .tint(Color.shelfAmber)
                    .frame(maxWidth: 280)
                Typo.supporting(Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0)))))
                    .foregroundStyle(Color.shelfMuted)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
            Typo.rowTitle(Text("Listening for chapter breaks…"))
                .foregroundStyle(Color.shelfCream)
                .multilineTextAlignment(.center)
            if context.isDownloaded {
                Typo.supporting(Text("This reads the downloaded audio on this iPhone and can take a minute for a long book."))
                    .foregroundStyle(Color.shelfMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.xl)
        .accessibilityElement(children: .combine)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.shelfOrange)
                    .accessibilityHidden(true)
                Typo.supporting(Text(verbatim: message))
                    .foregroundStyle(Color.shelfCream)
            }
            Button("Try Again") { model.start(context) }
                .buttonStyle(.bordered)
                .tint(Color.shelfAmberText)
                .frame(minHeight: 44)
        }
        .padding(Space.xl)
    }

    private var nothingFound: some View {
        EmptyStateView(
            icon: "wand.and.stars",
            title: LocalizedStringResource("No clear chapter breaks found", comment: "Chapter suggestions: empty state title"),
            subtitle: LocalizedStringResource("ShelfHead looked for long pauses, spoken chapter titles and file boundaries, and none were clear enough to suggest.", comment: "Chapter suggestions: why nothing was found")
        )
    }

    private var results: some View {
        List {
            Section {
                ForEach($model.suggestions) { $suggestion in
                    row($suggestion)
                        .listRowBackground(Color.shelfCard)
                }
            } header: {
                Typo.supporting(Text("Keep the ones that look right, rename them, and move any that are off. They're saved on this iPhone only."))
                    .foregroundStyle(Color.shelfMuted)
                    .textCase(nil)
            }
            if saveFailed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                        .accessibilityHidden(true)
                    Typo.supporting(Text("Couldn't save the chapters"))
                        .foregroundStyle(Color.shelfCream)
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(_ suggestion: Binding<ChapterSuggestion>) -> some View {
        let value = suggestion.wrappedValue
        let isFirst = value.start <= 0
        return HStack(spacing: 8) {
            Button {
                Haptics.selection()
                suggestion.wrappedValue.isIncluded.toggle()
            } label: {
                Image(systemName: value.isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(value.isIncluded ? Color.shelfAmberTextOnSurface : Color.shelfMuted)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFirst)
            .accessibilityLabel(value.isIncluded
                ? String(localized: "Keep this chapter", comment: "VoiceOver: checkbox on a suggested chapter, currently on")
                : String(localized: "Skip this chapter", comment: "VoiceOver: checkbox on a suggested chapter, currently off"))
            .accessibilityValue(value.isIncluded
                ? String(localized: "Kept", comment: "VoiceOver value: suggested chapter is kept")
                : String(localized: "Skipped", comment: "VoiceOver value: suggested chapter is skipped"))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Chapter title", text: suggestion.title)
                    .font(.body)
                    .foregroundStyle(Color.shelfCream)
                    .focused($focusedId, equals: value.id)
                    .submitLabel(.done)
                    .frame(minHeight: 44)
                    .accessibilityLabel(String(localized: "Chapter title", comment: "VoiceOver: text field for a suggested chapter's title"))
                HStack(spacing: 8) {
                    Typo.fine(Text(verbatim: value.start.formattedTime))
                        .monospacedDigit()
                        .foregroundStyle(Color.shelfCream)
                    Typo.fine(Text(verbatim: sourceCaption(value)))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            .opacity(value.isIncluded ? 1 : 0.5)

            Spacer(minLength: 0)

            if playerViewModel.currentBook?.id == context.itemId {
                Button {
                    play(from: value.start)
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(Color.shelfAmberTextOnSurface)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Play from here", comment: "VoiceOver: plays the book from a suggested chapter's start"))
            }

            if !isFirst {
                Menu {
                    nudgeButtons(value)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Move chapter start", comment: "VoiceOver: menu that nudges a suggested chapter earlier or later"))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isFirst {
                Button { model.nudge(id: value.id, by: -5, bookDuration: context.bookDuration) } label: {
                    Text(verbatim: "\u{2212}5s")
                }
                .tint(Color.shelfMuted)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isFirst {
                Button { model.nudge(id: value.id, by: 5, bookDuration: context.bookDuration) } label: {
                    Text(verbatim: "+5s")
                }
                .tint(Color.shelfMuted)
            }
        }
    }

    @ViewBuilder
    private func nudgeButtons(_ value: ChapterSuggestion) -> some View {
        Button("Earlier by 30 seconds", systemImage: "gobackward.30") {
            model.nudge(id: value.id, by: -30, bookDuration: context.bookDuration)
        }
        Button("Earlier by 5 seconds", systemImage: "gobackward.5") {
            model.nudge(id: value.id, by: -5, bookDuration: context.bookDuration)
        }
        Button("Later by 5 seconds", systemImage: "goforward.5") {
            model.nudge(id: value.id, by: 5, bookDuration: context.bookDuration)
        }
        Button("Later by 30 seconds", systemImage: "goforward.30") {
            model.nudge(id: value.id, by: 30, bookDuration: context.bookDuration)
        }
    }

    private func sourceCaption(_ value: ChapterSuggestion) -> String {
        switch value.source {
        case .cue:
            let heard = model.heardTitles[value.id] ?? value.title
            return String(localized: "Heard “\(heard)”", comment: "Chapter suggestions: where a suggestion came from. %@ is the words the narrator said, such as Chapter 4")
        case .silence:
            return String(localized: "Long pause", comment: "Chapter suggestions: a suggestion placed at a long pause in the audio")
        case .track:
            return String(localized: "Track start", comment: "Chapter suggestions: a suggestion placed where an audio file begins")
        case .server:
            return String(localized: "From the book", comment: "Chapter suggestions: a suggestion taken from the book's own chapters")
        case .start:
            return String(localized: "Start", comment: "Chapter suggestions: the opening chapter at the start of the book")
        }
    }

    // MARK: Actions

    private func play(from time: Double) {
        Haptics.selection()
        focusedId = nil
        playerViewModel.seek(to: time, reason: .chapterReview)
        if !playerViewModel.isPlaying { playerViewModel.togglePlayPause() }
    }

    private func save() {
        focusedId = nil
        let chapters = ChapterProposalBuilder.chapters(from: model.suggestions, bookDuration: context.bookDuration)
        guard chapters.count >= 2 else { return }
        let override = ChapterOverride(
            version: ChapterOverride.currentVersion, itemId: context.itemId, chapters: chapters,
            serverSignature: ChapterOverrideResolver.serverSignature(context.serverChapters), savedAt: Date())
        if ChapterOverrideStore.save(override) {
            Haptics.success()
            dismiss()
        } else {
            saveFailed = true
        }
    }
}
