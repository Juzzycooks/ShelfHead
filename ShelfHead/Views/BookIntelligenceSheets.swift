import SwiftUI
import AVFoundation

// MARK: - Shared pieces

/// Batch 428: speaks a recap aloud. Kept alive for the sheet's lifetime (a synthesizer that is
/// deallocated mid-utterance goes silent). It does not touch the audio session: the synthesizer
/// uses the app's own session, which is the one playback already configured.
@Observable @MainActor
final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` in the best installed voice for `localeIdentifier` (the transcript's language;
    /// Batch 432, see `SpeechVoicePicker`), or the system default voice when none matches.
    func speak(_ text: String, localeIdentifier: String?) {
        stop()
        var voice: AVSpeechSynthesisVoice?
        if let picked = Self.bestVoice(localeIdentifier: localeIdentifier) {
            voice = AVSpeechSynthesisVoice(identifier: picked.identifier)
        } else if let localeIdentifier, !localeIdentifier.isEmpty {
            voice = AVSpeechSynthesisVoice(language: localeIdentifier)
        }
        // Batch 435: cleaned for listening, paced (slower, pauses between sentences), see `SpeechScript`.
        let utterance = SpeechScript.utterance(for: text, voice: voice)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// The installed voice "Read It to Me" would use: highest quality in the transcript's language,
    /// never a novelty voice or the user's Personal Voice.
    static func bestVoice(localeIdentifier: String?) -> SpeechVoiceCandidate? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { voice in
            SpeechVoiceCandidate(identifier: voice.identifier, language: voice.language,
                                 quality: voice.quality.rawValue,
                                 isExcluded: voice.voiceTraits.contains(.isNoveltyVoice)
                                     || voice.voiceTraits.contains(.isPersonalVoice))
        }
        let fallback = Locale.current.language.languageCode?.identifier ?? "en"
        let lookup = (localeIdentifier?.isEmpty == false ? localeIdentifier! : fallback)
            .replacingOccurrences(of: "_", with: "-")
        return SpeechVoicePicker.best(candidates, localeIdentifier: localeIdentifier, fallbackLanguage: fallback,
                                      preferredIdentifier: AVSpeechSynthesisVoice(language: lookup)?.identifier)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

/// Why the model couldn't answer, in the app's words: orange glyph, cream sentence (DESIGN.md
/// orange rule), and a Retry when trying again can help.
struct IntelligenceFailureView: View {
    let reason: IntelligenceUnavailable
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.shelfOrange)
                    .accessibilityHidden(true)
                Typo.supporting(Text(verbatim: reason.message))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if reason.isRetryable {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .tint(Color.shelfAmberText)
                    .frame(minHeight: 44)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// "Written on this iPhone…" line with the sparkle that marks generated text (HIG: Generative AI).
struct GeneratedFooter: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.shelfMuted)
                .accessibilityHidden(true)
            Typo.fine(Text(verbatim: text))
                .foregroundStyle(Color.shelfMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Batch 490 (REVIEW 2026-11-11 P5): names a moment in the book the way the player does. The
/// player shows chapter-relative time ("12:44 · Chapter 3") once chapters exist, and these sheets
/// used to show whole-book time ("7:42:10"), so tapping one described the same jump in two
/// schemes. Built on `BookmarksSheet.momentLabel` (the house format) and the player's own
/// chapter rule (`PlayerViewModel.chapterIndex(in:at:)`); a chapterless book keeps plain time.
@MainActor
enum BookMoment {
    /// The chapter covering `time`, by the player's half-open `[start, end)` rule.
    static func chapter(at time: Double, in chapters: [Chapter]) -> Chapter? {
        PlayerViewModel.chapterIndex(in: chapters, at: time).map { chapters[$0] }
    }

    /// "12:44 · Chapter 3", or plain time when no chapter covers `time`.
    static func label(time: Double, chapters: [Chapter]) -> String {
        BookmarksSheet.momentLabel(time: time, chapter: chapter(at: time, in: chapters))
    }

    /// Just the time half: chapter-relative when a chapter covers `time`.
    static func time(_ time: Double, chapters: [Chapter]) -> String {
        BookmarksSheet.momentTime(time: time, chapter: chapter(at: time, in: chapters))
    }

    /// The chapters to name moments in `itemId` by: the player's (which include chapters made on
    /// this device) when that book is the one loaded, else none, so a sheet opened from Book
    /// Detail for another book falls back to plain time rather than borrowing the wrong chapters.
    static func chapters(for itemId: String, player: PlayerViewModel) -> [Chapter] {
        player.currentBook?.id == itemId ? player.chapters : []
    }
}

// MARK: - Previously On…

/// Batch 428: a "previously on" recap of what the listener has heard, written on this device from
/// per-chunk notes. Making the notes the first time can take a while for a long book, so the
/// sheet shows determinate progress; afterwards the notes are cached and it is near-instant.
struct RecapSheet: View {
    let itemId: String
    let title: String
    let author: String
    /// Batch 490 (REVIEW 2026-11-11 P5): as `XRaySheet.chapters`.
    var chapters: [Chapter]? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel

    private enum Phase {
        case loading(Double)
        case ready(String)
        case failed(IntelligenceUnavailable)
    }

    @State private var phase: Phase = .loading(0)
    @State private var attempt = 0
    @State private var reader = SpeechReader()
    /// Batch 432: only the compact voice is installed for the book's language.
    @State private var suggestsBetterVoice = false
    /// Batch 433: the narrator montage. It outlives this sheet (Lock Screen / CarPlay).
    @State private var montage = RecapPlaybackController.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                switch phase {
                case .loading(let fraction): loading(fraction)
                case .ready(let text): ready(text)
                case .failed(let reason): IntelligenceFailureView(reason: reason) { attempt += 1 }
                }
            }
            .navigationTitle("Previously On\u{2026}")
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
        .onDisappear { reader.stop() }
    }

    private func load() async {
        reader.stop()
        phase = .loading(0)
        do {
            let text = try await BookIntelligence.shared.recap(itemId: itemId, title: title, author: author) { fraction in
                phase = .loading(fraction)
            }
            suggestsBetterVoice = SpeechVoicePicker.shouldSuggestBetterVoice(
                SpeechReader.bestVoice(localeIdentifier: BookIntelligence.shared.transcriptLocaleIdentifier(itemId: itemId)))
            phase = .ready(text)
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

    private func ready(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(Color.shelfCream)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)

                montageSection(text)

                Button {
                    Haptics.selection()
                    if reader.isSpeaking {
                        reader.stop()
                    } else {
                        // The book would talk over the voice, so pause it first.
                        if playerViewModel.isPlaying { playerViewModel.togglePlayPause() }
                        reader.speak(text, localeIdentifier: BookIntelligence.shared.transcriptLocaleIdentifier(itemId: itemId))
                    }
                } label: {
                    Label(reader.isSpeaking ? "Stop" : "Read It to Me",
                          systemImage: reader.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.shelfAmberText)
                .disabled(isMontageActive)

                if suggestsBetterVoice {
                    // iOS 26 renamed Accessibility › Spoken Content to Read & Speak. Siri's own voices
                    // can't be offered here: `AVSpeechSynthesizer` doesn't vend them to apps (WWDC20
                    // "Create a seamless speech experience in your apps").
                    Typo.supporting(Group {
                        if #available(iOS 26, *) {
                            Text("For a more natural voice, go to Settings \u{203A} Accessibility \u{203A} Read & Speak \u{203A} Voices, choose the book's language and download a voice marked Enhanced or Premium.")
                        } else {
                            Text("For a more natural voice, go to Settings \u{203A} Accessibility \u{203A} Spoken Content \u{203A} Voices, choose the book's language and download a voice marked Enhanced or Premium.")
                        }
                    })
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                GeneratedFooter(text: String(localized: "Written on this iPhone from the parts you've heard.",
                                             comment: "Footer under a generated 'previously on' recap"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: Batch 433 narrator montage

    /// The montage state for this book only; another book's recap doesn't show here.
    private var isMontageForThisBook: Bool { montage.itemId == itemId }

    private var isMontageActive: Bool {
        guard isMontageForThisBook else { return false }
        switch montage.phase {
        case .preparing, .playing, .paused: return true
        case .idle, .failed: return false
        }
    }

    private func startMontage(_ text: String) {
        Haptics.selection()
        reader.stop()
        Task { await montage.start(itemId: itemId, title: title, author: author, summary: text, resumeBookAfter: false) }
    }

    @ViewBuilder
    private func montageSection(_ text: String) -> some View {
        let phase = isMontageForThisBook ? montage.phase : .idle
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .idle:
                montagePlayButton(text)
            case .preparing(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(Color.shelfAmber)
                    Typo.supporting(Text("Preparing the recap\u{2026}"))
                        .foregroundStyle(Color.shelfMuted)
                    Typo.fine(Text("It's put together on this iPhone."))
                        .foregroundStyle(Color.shelfMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                Button("Cancel") { Haptics.selection(); montage.stop() }
                    .buttonStyle(.bordered)
                    .tint(Color.shelfAmberText)
                    .frame(minHeight: 44)
            case .playing, .paused:
                montageTransport(isPlaying: phase == .playing)
                montageMoments
                if let manifest = montage.manifest, !manifest.hasNarratorAudio {
                    Typo.supporting(Text("The narrator's audio couldn't be reached, so this recap is spoken only. Download the book to hear the narrator offline."))
                        .foregroundStyle(Color.shelfMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                        .accessibilityHidden(true)
                    Typo.supporting(Text(verbatim: message))
                        .foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                montagePlayButton(text, title: "Try Again")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func montagePlayButton(_ text: String, title: LocalizedStringKey = "Play the Recap") -> some View {
        Button {
            startMontage(text)
        } label: {
            Label(title, systemImage: "play.fill")
                // Batch 490 (REVIEW 2026-11-11 V2): ink on the accent fill is contrast-picked, not
                // the white `.borderedProminent` draws (about 2:1 on VU Amber), as Rewind below does.
                .foregroundStyle(Color.onAccent)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.shelfAmber)
    }

    private func montageTransport(isPlaying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { Haptics.selection(); montage.overrideSkip(forward: false) } label: {
                    Image(systemName: "backward.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Previous moment")
                Button { Haptics.selection(); montage.overrideTogglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                Button { Haptics.selection(); montage.overrideSkip(forward: true) } label: {
                    Image(systemName: "forward.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next moment")
                Spacer(minLength: 8)
                Button { Haptics.selection(); montage.stop() } label: {
                    Image(systemName: "stop.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Stop recap")
            }
            .buttonStyle(.bordered)
            .tint(Color.shelfAmberText)
            .font(.body)
            // Its own line: beside the four buttons it wrapped onto two lines on an iPhone 17.
            Typo.supporting(Text(verbatim: "\(RecapPlanner.timestamp(montage.elapsed)) / \(RecapPlanner.timestamp(montage.duration))"))
                .foregroundStyle(Color.shelfMuted)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    /// The moments, current one highlighted. Clips show their book timestamp; spoken links are quieter.
    @ViewBuilder
    private var montageMoments: some View {
        if let marks = montage.manifest?.marks, !marks.isEmpty {
            // Batch 490 (REVIEW 2026-11-11 P5): moments named as the player names them.
            let chapters = self.chapters ?? BookMoment.chapters(for: itemId, player: playerViewModel)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                    let isCurrent = index == montage.currentMarkIndex
                    switch mark.item {
                    case .clip(let start, _, let clipText):
                        let moment = BookMoment.label(time: start, chapters: chapters)
                        VStack(alignment: .leading, spacing: 2) {
                            Typo.fine(Text(verbatim: moment))
                                .foregroundStyle(isCurrent ? Color.shelfAmberText : Color.shelfMuted)
                                .monospacedDigit()
                            Typo.supporting(Text(verbatim: clipText))
                                .foregroundStyle(Color.shelfCream)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .momentRow(isCurrent: isCurrent)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("Moment at \(moment): \(clipText)"))
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    case .speech(let line):
                        Typo.fine(Text(verbatim: line))
                            .italic()
                            .foregroundStyle(Color.shelfMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .momentRow(isCurrent: isCurrent)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    /// Batch 433: current-moment highlight; plain colour change, so nothing to gate on Reduce Motion.
    func momentRow(isCurrent: Bool) -> some View {
        self
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isCurrent ? Color.shelfAmber : Color.clear)
                    .frame(width: 3)
            }
    }
}

// MARK: - I Zoned Out

/// Batch 428: "What Just Happened" — a short summary of the last five minutes, with a button that
/// rewinds to the start of the passage it summarised. Rewinding goes through
/// `seek(to:reason: .zonedOut)`, so the Jump back chip can undo it.
struct ZonedOutSheet: View {
    let itemId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel

    private enum Phase {
        case loading
        case ready(summary: String, rewindTo: Double)
        case failed(IntelligenceUnavailable)
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                switch phase {
                case .loading: loading
                case .ready(let summary, let rewindTo): ready(summary: summary, rewindTo: rewindTo)
                case .failed(let reason): IntelligenceFailureView(reason: reason) { attempt += 1 }
                }
            }
            // Batch 490 (REVIEW 2026-11-11 P11): the same name as the ⋯ menu row that opens it
            // (it was "What Just Happened").
            .navigationTitle("I Zoned Out")
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
        phase = .loading
        do {
            let result = try await BookIntelligence.shared.zonedOut(itemId: itemId, at: playerViewModel.currentTime)
            phase = .ready(summary: result.summary, rewindTo: result.rewindTo)
        } catch is CancellationError {
            return
        } catch let error as BookIntelligenceError {
            phase = .failed(error.reason)
        } catch {
            phase = .failed(.failed)
        }
    }

    private var loading: some View {
        VStack(spacing: 16) {
            ProgressView()
            Typo.rowTitle(Text("Reading the last few minutes\u{2026}"))
                .foregroundStyle(Color.shelfCream)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .accessibilityElement(children: .combine)
    }

    private func ready(summary: String, rewindTo: Double) -> some View {
        // Batch 490 (REVIEW 2026-11-11 P5): "Rewind to 12:44 · Chapter 3", as the player names it.
        let moment = BookMoment.label(time: rewindTo, chapters: BookMoment.chapters(for: itemId, player: playerViewModel))
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: summary)
                    .font(.body)
                    .foregroundStyle(Color.shelfCream)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))   // Batch 490 (REVIEW 2026-11-11 V8)

                Button {
                    Haptics.selection()
                    playerViewModel.seek(to: rewindTo, reason: .zonedOut)
                    dismiss()
                } label: {
                    Text(String(localized: "Rewind to \(moment)",
                                comment: "Button on the I Zoned Out sheet. %@ is a moment like 12:40 · Chapter 3 (a plain time like 1:12:40 when the book has no chapters)"))
                        // Ink on the accent fill is contrast-picked, not white (DESIGN.md).
                        .foregroundStyle(Color.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.shelfAmber)

                GeneratedFooter(text: String(localized: "Written on this iPhone from the last few minutes of the book.",
                                             comment: "Footer under a generated 'what just happened' summary"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}
