import Foundation
import Observation
import Translation

/// Batch 425 (Section C): the translation driver behind live captions. One per captions view.
///
/// Holds translated lines for one (book, target language) pair, in memory only. The actual
/// `TranslationSession` is only ever handed in by SwiftUI's `.translationTask` closure and is
/// never stored here: Apple's docs say a session used after its view disappears, or after the
/// configuration changes, is a fatal error. `run` therefore takes the session as an argument,
/// uses it for the duration of the call, and lets go.
@MainActor
@Observable
final class CaptionTranslator {
    /// Index in the transcript's segments -> the source text that was translated and its translation.
    private(set) var translations: [Int: (source: String, text: String)] = [:]
    private(set) var inFlight: Set<Int> = []
    private(set) var lastError: String?

    /// Set by the view when it has asked SwiftUI to run the action (a new or invalidated
    /// configuration) and cleared when `run` starts, so a 0.5 s tick can't invalidate the
    /// configuration twice and cancel the run that is about to start.
    @ObservationIgnored var runRequested = false
    /// True for the whole of `run`, including between batches when nothing is in flight. The view
    /// must not invalidate the configuration then: the running loop still holds the old session,
    /// and using a session after its configuration changed is a fatal error.
    @ObservationIgnored private(set) var isRunning = false

    @ObservationIgnored private var itemId: String?
    @ObservationIgnored private var target: String?

    /// Most translate calls one `run` makes. The next anchor change asks for another run.
    private static let maxBatchesPerRun = 5

    /// Forget everything when the book or the target language changes; same pair is a no-op.
    func reset(itemId: String, target: String) {
        guard self.itemId != itemId || self.target != target else { return }
        self.itemId = itemId
        self.target = target
        translations = [:]
        inFlight = []
        lastError = nil
        runRequested = false
        generation += 1 // Review 4 Low (caption generation): orphan any batch still in flight
        isRunning = false // Review 5 Medium 5: the orphaned run's defer won't clear it (generation mismatch)
    }

    /// Review 4 Low (caption generation): bumped by `reset` and each run start.
    private var generation = 0

    /// Language[-script] identifiers the Translation framework supports ("fr", "zh-Hans"), deduplicated
    /// (en-US and en-GB both reduce to "en"). Shared by the captions menu and Settings. `@concurrent`
    /// so the non-Sendable `LanguageAvailability` is made and used off the main actor.
    @available(iOS 18.0, *)
    @concurrent nonisolated static func supportedTargetIdentifiers() async -> [String] {
        var seen = Set<String>()
        var identifiers: [String] = []
        for language in await LanguageAvailability().supportedLanguages {
            guard let code = language.languageCode?.identifier else { continue }
            let id = language.script.map { "\(code)-\($0.identifier)" } ?? code
            if seen.insert(id).inserted { identifiers.append(id) }
        }
        return identifiers
    }

    /// Clears a failure so the next anchor change may try again (the menu re-selecting a language).
    func clearError() { lastError = nil }

    /// The translation for a line, only if it was made from the line's current text.
    func translation(for index: Int, segment: TranscriptSegment) -> String? {
        guard let entry = translations[index], entry.source == segment.text, !entry.text.isEmpty else { return nil }
        return entry.text
    }

    /// Segments still to translate near `time`: done lines count only while their source text is unchanged.
    func pendingBatch(segments: [TranscriptSegment], time: Double) -> [Int] {
        var done = Set<Int>()
        for (index, entry) in translations where index < segments.count && entry.source == segments[index].text {
            done.insert(index)
        }
        return LiveCaptionPlanner.translationBatch(segments: segments, time: time, done: done, inFlight: inFlight)
    }

    /// Translates batches ahead of the playhead until nothing is pending, the task is cancelled,
    /// about five batches are done, or the first error. `timeProvider` is read fresh each loop
    /// so a long run follows the playhead. Prompts the user to download missing languages;
    /// declining throws, which lands in `lastError`.
    @available(iOS 18.0, *)
    func run(session: TranslationSession,
             segments: [TranscriptSegment],
             timeProvider: @MainActor () -> Double) async {
        runRequested = false
        generation += 1
        let myGeneration = generation
        isRunning = true
        defer { if generation == myGeneration { isRunning = false } }
        var batches = 0
        while batches < Self.maxBatchesPerRun, !Task.isCancelled {
            let batch = pendingBatch(segments: segments, time: timeProvider())
                .filter { $0 < segments.count }
            guard !batch.isEmpty else { return }
            batches += 1

            // Blank lines have nothing to translate; mark them done so they are not requested again.
            var requested: [Int] = []
            for index in batch {
                if segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translations[index] = (segments[index].text, "")
                } else {
                    requested.append(index)
                }
            }
            guard !requested.isEmpty else { continue }

            inFlight.formUnion(requested)
            let requests = requested.map {
                TranslationSession.Request(sourceText: segments[$0].text, clientIdentifier: String($0))
            }
            do {
                let responses = try await session.translations(from: requests)
                guard generation == myGeneration else { return }
                for response in responses {
                    guard let id = response.clientIdentifier, let index = Int(id),
                          index < segments.count, requested.contains(index) else { continue }
                    translations[index] = (segments[index].text, response.targetText)
                }
                inFlight.subtract(requested)
            } catch {
                guard generation == myGeneration else { return }
                inFlight.subtract(requested)
                if Task.isCancelled || error is CancellationError { return }
                lastError = String(localized: "Translation unavailable",
                                   comment: "Captions: shown when translating the lines failed")
                return
            }
        }
    }
}
