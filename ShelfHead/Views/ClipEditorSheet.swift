import SwiftUI

/// Batch 426: "Clip…" from the player's ⋯ menu. Picks a short range of the current book
/// (default: the last 30 s, snapped to transcript sentences), shows its text, and shares it
/// as a quote card (plus an .m4a when the book is downloaded) or saves it as a bookmark.
struct ClipEditorSheet: View {
    let itemId: String
    let bookTitle: String
    /// (quote text or nil, chapter title at the start, exported audio or nil). The caller
    /// dismisses this sheet and presents the share composer.
    let onShare: (_ quote: String?, _ attribution: String?, _ audioURL: URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel

    @State private var range = ClipRange(start: 0, end: 30)
    @State private var segments: [TranscriptSegment] = []
    @State private var spaceless = false
    @State private var hasTranscript = false
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showAddToMixtape = false
    @State private var addedToMixtape: String?

    private var bookDuration: Double { playerViewModel.duration }
    private var hasLocalAudio: Bool { QuoteClipExporter.hasLocalAudio(itemId: itemId) }
    private var isBusy: Bool { isExporting || isSaving }
    private var clipText: String { ClipText.text(for: range, segments: segments, spaceless: spaceless) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        timeSummary
                        endEditor(isEnd: false)
                        endEditor(isEnd: true)
                        previewButton
                        quoteCard
                        actions
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .monochromeToolbarItem()
                }
            }
        }
        .systemChromeTint()
        .onAppear(perform: configure)
        .onDisappear { stopPreview() }
        .sheet(isPresented: $showAddToMixtape) {
            AddToMixtapeSheet(clip: MixtapeClip(itemId: itemId, start: range.start, end: range.end,
                                                quote: clipText.isEmpty ? nil : clipText,
                                                title: bookTitle,
                                                author: playerViewModel.currentBook?.authorName)) { addedToMixtape = $0 }
        }
    }

    // MARK: - Pieces

    private var timeSummary: some View {
        let from = range.start.formattedTime
        let to = range.end.formattedTime
        let length = range.duration.formattedDuration
        return HStack(alignment: .firstTextBaseline) {
            Typo.figure(Text(verbatim: "\(from) – \(to)"))
                .foregroundStyle(Color.shelfCream)
                .monospacedDigit()
            Spacer(minLength: 8)
            Typo.figure(Text(verbatim: length))
                .foregroundStyle(Color.shelfMuted)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "From \(from) to \(to), \(length)", comment: "VoiceOver: clip range. First two %@ are timestamps, the last is a duration such as 28 seconds"))
    }

    private func endEditor(isEnd: Bool) -> some View {
        let title = isEnd ? String(localized: "End", comment: "Clip editor: label for the end of the clip") : String(localized: "Start", comment: "Clip editor: label for the start of the clip")
        let time = (isEnd ? range.end : range.start).formattedTime
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Typo.sectionTitle(Text(title))
                    .foregroundStyle(Color.shelfCream)
                Spacer(minLength: 8)
                Typo.figure(Text(verbatim: time))
                    .foregroundStyle(Color.shelfMuted)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                nudgeButton(Image(systemName: "backward.end.fill"),
                            label: isEnd ? String(localized: "End one sentence earlier", comment: "VoiceOver: clip editor nudge") : String(localized: "Start one sentence earlier", comment: "VoiceOver: clip editor nudge")) {
                    ClipRangeSnapper.nudgedBySentence(range, end: isEnd, delta: -1, bookDuration: bookDuration, segments: segments)
                }
                nudgeButton(Text(verbatim: "\u{2212}1s").monospacedDigit(),
                            label: isEnd ? String(localized: "End one second earlier", comment: "VoiceOver: clip editor nudge") : String(localized: "Start one second earlier", comment: "VoiceOver: clip editor nudge")) {
                    ClipRangeSnapper.nudged(range, end: isEnd, by: -1, bookDuration: bookDuration)
                }
                nudgeButton(Text(verbatim: "+1s").monospacedDigit(),
                            label: isEnd ? String(localized: "End one second later", comment: "VoiceOver: clip editor nudge") : String(localized: "Start one second later", comment: "VoiceOver: clip editor nudge")) {
                    ClipRangeSnapper.nudged(range, end: isEnd, by: 1, bookDuration: bookDuration)
                }
                nudgeButton(Image(systemName: "forward.end.fill"),
                            label: isEnd ? String(localized: "End one sentence later", comment: "VoiceOver: clip editor nudge") : String(localized: "Start one sentence later", comment: "VoiceOver: clip editor nudge")) {
                    ClipRangeSnapper.nudgedBySentence(range, end: isEnd, delta: 1, bookDuration: bookDuration, segments: segments)
                }
            }
        }
        .padding(14)
        .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// `face` is a glyph, or "−1s"/"+1s" text: there is no one-second SF Symbol (`gobackward.1`
    /// doesn't exist and drew an empty button in the simulator check).
    private func nudgeButton<Face: View>(_ face: Face, label: String,
                                         _ change: @escaping () -> ClipRange) -> some View {
        Button {
            Haptics.selection()
            range = change()
            errorMessage = nil
            // A running preview was for the old range.
            if isPreviewing { stopPreview() }
        } label: {
            face
                .font(.body.weight(.semibold))
                // On the card, so the surface variant (DESIGN.md, the Fill-or-Text Rule).
                .foregroundStyle(Color.shelfAmberTextOnSurface)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(Color.shelfMuted)
        .disabled(isBusy)
        .accessibilityLabel(label)
    }

    private var previewButton: some View {
        Button {
            Haptics.selection()
            if isPreviewing { stopPreview() } else { startPreview() }
        } label: {
            Label(isPreviewing ? "Stop" : "Preview", systemImage: isPreviewing ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(Color.shelfAmberText)
        .disabled(isBusy)
        .accessibilityHint("Plays the clip from its start")
    }

    private var quoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Typo.supporting(Text("Quote"))
                .foregroundStyle(Color.shelfMuted)
            if clipText.isEmpty {
                Typo.rowSubtitle(Text(hasTranscript ? "No text in this range" : "No transcript for this part"))
                    .foregroundStyle(Color.shelfMuted)
            } else {
                ScrollView {
                    Typo.rowTitle(Text(verbatim: clipText))
                        .foregroundStyle(Color.shelfCream)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await share() }
            } label: {
                HStack(spacing: 8) {
                    if isExporting { ProgressView().tint(Color.onAccent) }
                    Text("Share Clip")
                }
                // Ink on the accent fill is contrast-picked, not white (DESIGN.md).
                .foregroundStyle(Color.onAccent)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.shelfAmber)
            .disabled(isBusy)

            Button {
                Task { await saveBookmark() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving { ProgressView() }
                    Text("Save as Bookmark")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.shelfAmberText)
            .disabled(isBusy)

            Button {
                stopPreview()
                showAddToMixtape = true
            } label: {
                Label("Add to Mixtape", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.shelfAmberText)
            .disabled(isBusy)
            if let addedToMixtape {
                Typo.supporting(Text("Added to \(addedToMixtape)"))
                    .foregroundStyle(Color.shelfMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !hasLocalAudio {
                Typo.supporting(Text("This book isn't downloaded, so the clip shares as a quote card without audio."))
                    .foregroundStyle(Color.shelfMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                // DESIGN.md: a warning is an orange glyph beside cream words, never orange or red text.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                        .accessibilityHidden(true)
                    Typo.supporting(Text(verbatim: errorMessage))
                        .foregroundStyle(Color.shelfCream)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Work

    private func configure() {
        let transcript = TranscriptionCenter.shared.transcript(for: itemId)
        segments = transcript?.segments ?? []
        hasTranscript = !segments.isEmpty
        spaceless = ClipText.isSpaceless(localeIdentifier: transcript?.localeIdentifier ?? "")
        range = ClipRangeSnapper.defaultRange(playhead: playerViewModel.currentTime,
                                              bookDuration: bookDuration, segments: segments)
    }

    private func startPreview() {
        previewTask?.cancel()
        let clip = range
        playerViewModel.seek(to: clip.start, reason: .clip)
        if !playerViewModel.isPlaying { playerViewModel.togglePlayPause() }
        isPreviewing = true
        previewTask = Task { @MainActor in
            // Give the seek a moment to land so the first poll doesn't see the old position.
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                if playerViewModel.currentTime >= clip.end || !playerViewModel.isPlaying { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            if playerViewModel.isPlaying { playerViewModel.togglePlayPause() }
            isPreviewing = false
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        if isPreviewing, playerViewModel.isPlaying { playerViewModel.togglePlayPause() }
        isPreviewing = false
    }

    private var attribution: String? {
        playerViewModel.chapters.last(where: { $0.start <= range.start })
            .map { PlayerView.displayChapterTitle($0.title) }
    }

    private func share() async {
        stopPreview()
        errorMessage = nil
        let text = clipText
        var audioURL: URL?
        if hasLocalAudio {
            isExporting = true
            defer { isExporting = false }
            do {
                audioURL = try await QuoteClipExporter.export(itemId: itemId, range: range, title: bookTitle)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        onShare(text.isEmpty ? nil : text, attribution, audioURL)
    }

    private func saveBookmark() async {
        stopPreview()
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        let text = clipText
        let note = text.isEmpty ? nil : ClipText.bookmarkNote(text, spaceless: spaceless)
        if await playerViewModel.addBookmark(at: range.start, note: note) != nil {
            Haptics.success()
            dismiss()
        } else {
            errorMessage = String(localized: "Couldn't save the bookmark", comment: "Clip editor: inline error when saving the clip as a bookmark fails")
        }
    }
}
