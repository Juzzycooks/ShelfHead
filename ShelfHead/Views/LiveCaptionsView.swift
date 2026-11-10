import SwiftUI
import Translation

/// Batch 425 (Section C): live captions. Fills the player's artwork slot when "Show Captions"
/// is on, like Apple Music's lyrics replacing the cover: the line being spoken, large and in
/// cream, with the word being said in the accent colour, and a couple of lines either side
/// muted. Tapping a line seeks there (with the Jump back chip). Optionally each line is
/// translated on device under the original (`CaptionTranslator`).
///
/// HIG: Playing audio. The per-tick `currentTime` reads live in this view, not in
/// `PlayerView.body`, and the 0.1 s `TimelineView` only exists while playing.
struct LiveCaptionsView: View {
    let itemId: String

    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(SettingsKeys.captionTranslationLanguage) private var targetLanguage = ""

    @State private var transcript: Transcript?
    @State private var lastTick = Tick(time: 0, date: .now)
    @State private var translator = CaptionTranslator()
    /// Always holds a `TranslationSession.Configuration` (iOS 18+) or nil; typed `Any?` so this
    /// file's stored properties don't need an availability annotation on the whole view.
    @State private var translationConfig: Any?
    @State private var supportedTargets: [String] = []

    private struct Tick: Equatable {
        var time: Double
        var date: Date
    }

    private struct LoadKey: Hashable {
        let itemId: String
        let stateDescription: String
    }

    private struct ConfigKey: Hashable {
        let itemId: String
        let source: String?
        let target: String
    }

    // MARK: - Derived

    private var linesEachSide: Int { dynamicTypeSize >= .xxxLarge ? 1 : 2 }

    private var loadKey: LoadKey {
        LoadKey(itemId: itemId,
                stateDescription: String(describing: TranscriptionCenter.shared.state(for: itemId)))
    }

    private var configKey: ConfigKey {
        ConfigKey(itemId: itemId, source: transcript?.localeIdentifier, target: targetLanguage)
    }

    private var suggestedTarget: String? {
        guard let source = transcript?.localeIdentifier else { return nil }
        return CaptionTranslationLanguage.suggestedTarget(source: source,
                                                          preferredLanguages: Locale.preferredLanguages)
    }

    // MARK: - Body

    var body: some View {
        // Bottom-trailing, over the faded last line, so the button never covers live text.
        ZStack(alignment: .bottomTrailing) {
            captions
            if #available(iOS 18.0, *), transcript != nil {
                translateMenu
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .modifier(CaptionTranslationTask(config: translationConfig, translator: translator,
                                         segments: transcript?.segments ?? [],
                                         timeProvider: { playerViewModel.currentTime }))
        .task(id: loadKey) {
            transcript = TranscriptionCenter.shared.transcript(for: itemId)
        }
        .onChange(of: playerViewModel.currentTime, initial: true) { _, time in
            lastTick = Tick(time: time, date: .now)
            requestTranslationIfNeeded(time: time)
        }
        .onChange(of: configKey, initial: true) { _, _ in rebuildConfiguration() }
        .task {
            await loadSupportedTargets()
        }
    }

    /// While playing, a 0.1 s clock drives the word highlight; paused, the view is static.
    @ViewBuilder private var captions: some View {
        if playerViewModel.isPlaying {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                content(time: LiveCaptionPlanner.interpolatedTime(
                    lastTime: lastTick.time, lastTickDate: lastTick.date, now: context.date,
                    isPlaying: true, rate: playerViewModel.playbackRate))
            }
        } else {
            content(time: playerViewModel.currentTime)
        }
    }

    @ViewBuilder private func content(time: Double) -> some View {
        if let transcript, !transcript.segments.isEmpty {
            let window = LiveCaptionPlanner.window(segments: transcript.segments, time: time,
                                                   isComplete: transcript.isComplete,
                                                   before: linesEachSide, after: linesEachSide)
            if window.beyondTranscript {
                notReady(coveredUntil: transcript.coveredUntil)
            } else {
                lineStack(window: window, transcript: transcript, time: time)
            }
        } else {
            notReady(coveredUntil: nil)
        }
    }

    // MARK: - Lines

    private func lineStack(window: LiveCaptionWindow, transcript: Transcript, time: Double) -> some View {
        let anchor = window.anchor
        // Before the first line there is no anchor: everything shown is upcoming.
        let before = window.lines.filter { index in anchor.map { index < $0 } ?? false }
        let after = window.lines.filter { index in anchor.map { index > $0 } ?? true }

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(before, id: \.self) { index in
                    line(index, transcript: transcript, window: window, time: time)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)

            if let anchor {
                line(anchor, transcript: transcript, window: window, time: time)
                    // The spoken line always gets its full height; the greedy halves around it
                    // otherwise squeezed it to one truncated line (simulator check).
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 14)
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(after, id: \.self) { index in
                    line(index, transcript: transcript, window: window, time: time)
                }
                if translator.lastError != nil {
                    Typo.supporting(Text("Translation unavailable"))
                        .foregroundStyle(Color.shelfMuted)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            // Keep the following lines clear of the translate button in the bottom-trailing corner.
            .padding(.trailing, 52)
        }
        .padding(.horizontal, 8)
        // The halves size to their lines, which can be taller than the slot; without a bounded
        // frame before the clip they spilled over the title below (simulator check).
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .mask(fadeMask)
        .shelfAnimation(.easeInOut(duration: 0.3), value: window.anchor)
    }

    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.16),
            .init(color: .black, location: 0.84),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private func line(_ index: Int, transcript: Transcript, window: LiveCaptionWindow, time: Double) -> some View {
        if index < transcript.segments.count {
            let segment = transcript.segments[index]
            let isAnchor = index == window.anchor
            let translation = isTranslating ? translator.translation(for: index, segment: segment) : nil
            let highlight = isAnchor && window.anchorIsLive
                ? LiveCaptionPlanner.highlightRange(in: segment, at: time) : nil

            Button {
                Haptics.selection()
                playerViewModel.seek(to: segment.start, reason: .caption)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if isAnchor {
                        Text(Self.attributed(segment.text, highlight: highlight))
                            .scaledFont(24, weight: .semibold, design: .rounded, relativeTo: .title2)
                            .foregroundStyle(Color.shelfCream)
                    } else {
                        Typo.rowTitle(Text(verbatim: segment.text))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    if let translation {
                        if isAnchor {
                            Typo.rowTitle(Text(verbatim: translation))
                                .foregroundStyle(Color.shelfCream.opacity(0.8))
                        } else {
                            Typo.supporting(Text(verbatim: translation))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: [segment.text, translation].compactMap { $0 }.joined(separator: ". ")))
            .accessibilityHint("Plays from here")
            .accessibilityAddTraits(isAnchor ? .isSelected : [])
        }
    }

    /// The line with the word being spoken bold in the accent text colour. Emphasis, never a
    /// `.font`: a font on a run would replace the Typo size for that word.
    static func attributed(_ text: String, highlight: NSRange?) -> AttributedString {
        var attributed = AttributedString(text)
        if let nsRange = highlight,
           let strRange = Range(nsRange, in: text),
           let lower = AttributedString.Index(strRange.lowerBound, within: attributed),
           let upper = AttributedString.Index(strRange.upperBound, within: attributed),
           lower < upper {
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            attributed[lower..<upper].foregroundColor = Color.shelfAmberText
        }
        return attributed
    }

    private func notReady(coveredUntil: Double?) -> some View {
        VStack(spacing: 6) {
            Typo.rowTitle(Text("Captions aren't ready for this part yet"))
                .foregroundStyle(Color.shelfCream)
            if let coveredUntil, coveredUntil > 0 {
                Typo.supporting(Text("Transcript covers the first \(coveredUntil.formattedDuration)"))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Translation

    private var isTranslating: Bool { translationConfig != nil }

    /// Builds (or clears) the configuration. A new configuration makes `.translationTask` run
    /// by itself, so mark the run as requested to keep the playback tick from invalidating it.
    private func rebuildConfiguration() {
        guard #available(iOS 18.0, *) else { translationConfig = nil; return }
        guard !targetLanguage.isEmpty, let source = transcript?.localeIdentifier,
              CaptionTranslationLanguage.isTranslation(source: source, target: targetLanguage) else {
            translationConfig = nil
            return
        }
        translator.reset(itemId: itemId, target: targetLanguage)
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: targetLanguage))
        // An equal configuration doesn't re-run the task, so only flag a run when it will happen.
        if (translationConfig as? TranslationSession.Configuration) != config {
            translator.runRequested = true
            translationConfig = config
        }
    }

    /// When nothing is in flight and lines ahead still lack a translation, ask SwiftUI for a
    /// fresh session. The session never leaves the `.translationTask` closure.
    private func requestTranslationIfNeeded(time: Double) {
        guard #available(iOS 18.0, *), var config = translationConfig as? TranslationSession.Configuration,
              let segments = transcript?.segments,
              translator.inFlight.isEmpty, !translator.isRunning, !translator.runRequested, translator.lastError == nil,
              !translator.pendingBatch(segments: segments, time: time).isEmpty else { return }
        translator.runRequested = true
        config.invalidate()
        translationConfig = config
    }

    private func loadSupportedTargets() async {
        guard #available(iOS 18.0, *) else { return }
        supportedTargets = await CaptionTranslator.supportedTargetIdentifiers()
    }

    private static func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Top-trailing translate menu: Don't Translate, the suggested language, and every other
    /// supported language in a submenu. Writes the same setting the Settings picker does.
    @available(iOS 18.0, *)
    private var translateMenu: some View {
        let source = transcript?.localeIdentifier ?? ""
        let others = supportedTargets
            .filter { CaptionTranslationLanguage.isTranslation(source: source, target: $0) }
            .sorted { Self.displayName($0).localizedCaseInsensitiveCompare(Self.displayName($1)) == .orderedAscending }
        return Menu {
            Picker(selection: Binding(get: { targetLanguage },
                                      set: { newValue in
                                          Haptics.selection()
                                          translator.clearError()
                                          targetLanguage = newValue
                                      })) {
                Text("Don't Translate").tag("")
                if let suggestedTarget {
                    Text("Translate to \(Self.displayName(suggestedTarget))").tag(suggestedTarget)
                }
            } label: { Text("Translate") }
            if !others.isEmpty {
                Menu("More Languages\u{2026}") {
                    Picker(selection: Binding(get: { targetLanguage },
                                              set: { newValue in
                                                  Haptics.selection()
                                                  translator.clearError()
                                                  targetLanguage = newValue
                                              })) {
                        ForEach(others, id: \.self) { id in
                            Text(verbatim: Self.displayName(id)).tag(id)
                        }
                    } label: { Text("Languages") }
                }
            }
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isTranslating ? Color.shelfAmberText : Color.shelfCream)
                .frame(width: 36, height: 36)
                .glassPill(Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .systemChromeTint()
        .accessibilityLabel("Translate captions")
    }
}

/// Attaches `.translationTask` on iOS 18+ and does nothing earlier. The configuration is
/// carried as `Any?` by the view and cast here, so the session only ever exists inside the closure.
private struct CaptionTranslationTask: ViewModifier {
    let config: Any?
    let translator: CaptionTranslator
    let segments: [TranscriptSegment]
    let timeProvider: @MainActor () -> Double

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationTask(config as? TranslationSession.Configuration) { session in
                await translator.run(session: session, segments: segments, timeProvider: timeProvider)
            }
        } else {
            content
        }
    }
}
