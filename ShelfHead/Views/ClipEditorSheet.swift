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
    /// Batch 490 (REVIEW 2026-11-11 P8): where the book was, and whether it was playing, when the
    /// editor opened, and whether a preview has taken over the playhead since.
    @State private var openedAt: Double = 0
    @State private var wasPlayingAtOpen = false
    @State private var didPreview = false
    @State private var capturedOpening = false

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
                // Batch 490 (REVIEW 2026-11-11 V1): the shared Cancel, as the player's edit sheets use.
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                        .monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)   // iPhone Duo (§2)
            }
        }
        .systemChromeTint()
        .onAppear(perform: configure)
        .onDisappear { restorePlayback() }
        .sheet(isPresented: $showAddToMixtape) {
            AddToMixtapeSheet(clip: MixtapeClip(itemId: itemId, start: range.start, end: range.end,
                                                quote: clipText.isEmpty ? nil : clipText,
                                                title: bookTitle,
                                                author: playerViewModel.currentBook?.authorName)) { addedToMixtape = $0 }
        }
    }

    // MARK: - Pieces

    /// Batch 490 (REVIEW 2026-11-11 P5): the chapters to name the range by.
    private var chapters: [Chapter] { BookMoment.chapters(for: itemId, player: playerViewModel) }

    private var timeSummary: some View {
        // Batch 490 (REVIEW 2026-11-11 P5): the range as the player names moments: chapter-relative
        // with the chapter title under it, whole-book time only for a chapterless book.
        let labels = ClipRangeLabel.make(range, chapters: chapters)
        let from = labels.from
        let to = labels.to
        let length = range.duration.formattedDuration
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Typo.figure(Text(verbatim: "\(from) – \(to)"))
                    .foregroundStyle(Color.shelfCream)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Typo.figure(Text(verbatim: length))
                    .foregroundStyle(Color.shelfMuted)
                    .monospacedDigit()
            }
            if let chapterTitle = labels.chapterTitle {
                Typo.supporting(Text(verbatim: chapterTitle))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "From \(from) to \(to), \(length)", comment: "VoiceOver: clip range. First two %@ are timestamps, the last is a duration such as 28 seconds"))
                            + Text(verbatim: labels.chapterTitle.map { ", \($0)" } ?? ""))
    }

    private func endEditor(isEnd: Bool) -> some View {
        let title = isEnd ? String(localized: "End", comment: "Clip editor: label for the end of the clip") : String(localized: "Start", comment: "Clip editor: label for the start of the clip")
        // Batch 490 (REVIEW 2026-11-11 P5): the same labels as the range line above (chapter-relative).
        let labels = ClipRangeLabel.make(range, chapters: chapters)
        let time = isEnd ? labels.to : labels.from
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
        .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)
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
        .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)
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
        // Batch 490 (REVIEW 2026-11-11 P8): remembered so closing the editor puts the book back.
        // Once per opening: a second `onAppear` (after a child sheet) must not overwrite it.
        if !capturedOpening {
            openedAt = playerViewModel.currentTime
            wasPlayingAtOpen = playerViewModel.isPlaying
            capturedOpening = true
        }
    }

    private func startPreview() {
        previewTask?.cancel()
        let clip = range
        didPreview = true   // Batch 490 (REVIEW 2026-11-11 P8)
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

    /// Batch 490 (REVIEW 2026-11-11 P8): a preview takes over the real playhead (it seeks to the
    /// clip, plays it and pauses at its end). Closing the editor, however it closes (Cancel, a
    /// swipe, Share, Save as Bookmark), puts the book back where it was and as it was: playing or
    /// paused. Nothing is touched when there was no preview, so a book that played on while the
    /// editor was open isn't pulled back.
    ///
    /// The restore seek goes through `seek(to:reason: .clip)` so it also clears the smart-rewind
    /// pause stamp (resuming here is not a resume after a pause), and then the Jump back offer is
    /// cleared: the preview's own offer pointed at the place the restore just returned to, and the
    /// restore isn't a jump the listener made, so it gets no offer of its own.
    private func restorePlayback() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        let plan = ClipEditorRestore.plan(didPreview: didPreview,
                                          isSameBook: playerViewModel.currentBook?.id == itemId,
                                          openedAt: openedAt, wasPlaying: wasPlayingAtOpen,
                                          currentTime: playerViewModel.currentTime,
                                          isPlaying: playerViewModel.isPlaying)
        didPreview = false
        if let time = plan.seekTo { playerViewModel.seek(to: time, reason: .clip) }
        if plan.clearsJumpBack { playerViewModel.seekUndoTime = nil }
        if plan.togglePlayPause { playerViewModel.togglePlayPause() }
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

/// Batch 490 (REVIEW 2026-11-11 P8): what closing the clip editor does to the player. Pure, so the
/// rule is pinned by `QuickWinsPlayerSheetsTests`.
enum ClipEditorRestore {
    struct Plan: Equatable {
        /// Where to put the playhead back, or nil to leave it.
        var seekTo: Double?
        /// Whether to flip play/pause so the book is as it was when the editor opened.
        var togglePlayPause: Bool
        /// Whether to drop the Jump back offer. A preview's offer points back at where the editor
        /// opened, which is where the book is once restored, so it would offer a jump to here.
        var clearsJumpBack: Bool

        static let leaveAlone = Plan(seekTo: nil, togglePlayPause: false, clearsJumpBack: false)
    }

    /// Closer than this to where it opened counts as already there (no seek, no smart-rewind change).
    static let positionTolerance: Double = 0.5

    /// - Parameters:
    ///   - didPreview: a preview ran while the editor was open (only a preview moves the playhead).
    ///   - isSameBook: the editor's book is still the loaded one; another book is never touched.
    ///   - openedAt, wasPlaying: the position and play state when the editor opened.
    ///   - currentTime, isPlaying: the player now, after any preview was cancelled.
    static func plan(didPreview: Bool, isSameBook: Bool, openedAt: Double, wasPlaying: Bool,
                     currentTime: Double, isPlaying: Bool) -> Plan {
        guard didPreview, isSameBook else { return .leaveAlone }
        let seekTo: Double? = abs(currentTime - openedAt) > positionTolerance ? max(0, openedAt) : nil
        return Plan(seekTo: seekTo, togglePlayPause: isPlaying != wasPlaying, clearsJumpBack: true)
    }
}

/// Batch 490 (REVIEW 2026-11-11 P5): the clip editor's range line in the player's terms. When both
/// ends fall in one chapter, the times are relative to it and its title is shown once; when the
/// range crosses a chapter boundary each end carries its own chapter ("59:50 · Chapter 2 –
/// 0:20 · Chapter 3"); a chapterless book keeps whole-book times.
@MainActor
enum ClipRangeLabel {
    struct Labels: Equatable {
        var from: String
        var to: String
        var chapterTitle: String?
    }

    static func make(_ range: ClipRange, chapters: [Chapter]) -> Labels {
        let startChapter = BookMoment.chapter(at: range.start, in: chapters)
        // A clip that ends exactly on its chapter's end belongs to that chapter, not the next one
        // (the chapter rule is half-open, so the end time alone would name the next chapter).
        let endChapter = startChapter.flatMap { range.end <= $0.end ? $0 : nil }
            ?? BookMoment.chapter(at: range.end, in: chapters)
        if let startChapter, let endChapter, startChapter.id == endChapter.id {
            return Labels(from: BookmarksSheet.momentTime(time: range.start, chapter: startChapter),
                          to: BookmarksSheet.momentTime(time: range.end, chapter: startChapter),
                          chapterTitle: PlayerView.displayChapterTitle(startChapter.title))
        }
        if startChapter == nil, endChapter == nil {
            return Labels(from: range.start.formattedTime, to: range.end.formattedTime, chapterTitle: nil)
        }
        return Labels(from: BookmarksSheet.momentLabel(time: range.start, chapter: startChapter),
                      to: BookmarksSheet.momentLabel(time: range.end, chapter: endChapter),
                      chapterTitle: nil)
    }
}
