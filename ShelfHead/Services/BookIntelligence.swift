import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Batch 428 (Section F, part 1): the on-device "book intelligence" engine behind "Previously On…"
/// and "I Zoned Out". It turns the Section A transcript into short per-chunk notes with Apple's
/// on-device language model (FoundationModels, iOS 26+), caches them beside the transcript, and
/// answers two questions from them: "what happened so far?" and "what did I just miss?".
///
/// Everything is limited to the listening frontier (`TranscriptionCenter.frontier(for:)`): no
/// note is ever made from, or shown for, a part of the book the listener hasn't reached. Nothing
/// leaves the device. The pure decisions (chunking, budgets, prompts, messages) live in
/// `BookIntelligencePlanning.swift`; this file is the I/O and model glue.

/// A failure the UI can explain: the reason carries its own localised message and retry flag.
nonisolated struct BookIntelligenceError: Error, Sendable, Equatable {
    var reason: IntelligenceUnavailable
}

#if canImport(FoundationModels)
/// What the model writes for one chunk. Mapped into `ChunkNotes` straight after.
@available(iOS 26.0, *)
@Generable
nonisolated struct GeneratedChunkNotes {
    @Guide(description: "Two to four sentences: what happens in this part of the audiobook, plainly, past tense.")
    var summary: String

    @Guide(description: "The most important named people, places and terms in this part. Leave empty if there are none.",
           .maximumCount(8))
    var entities: [GeneratedNoteEntity]
}

@available(iOS 26.0, *)
@Generable
nonisolated struct GeneratedNoteEntity {
    @Guide(description: "The name as it would be written, with normal capital letters.")
    var name: String

    @Guide(description: "Exactly one of: person, place, term.")
    var kind: String

    // Batch 432: richer than the original "one short phrase" so X-Ray has more to merge. Deliberately NOT a
    // `NotesCache.currentVersion` bump (that would discard a long book's cached notes): old notes keep their
    // short wording, new ones are richer.
    @Guide(description: "One sentence: who or what this is, their role or relationship to others, and what they did in this part. Use only this part.")
    var note: String
}

/// Batch 433: what the model writes for the montage script.
@available(iOS 26.0, *)
@Generable
nonisolated struct GeneratedRecapScript {
    @Guide(description: "Four to six moments, in the order they happen in the book.", .maximumCount(6))
    var beats: [GeneratedRecapBeat]
}

@available(iOS 26.0, *)
@Generable
nonisolated struct GeneratedRecapBeat {
    @Guide(description: "One short past-tense sentence, 8 to 20 words, that sets up the moment. Plain spoken words, no brackets.")
    var line: String

    @Guide(description: "The number of the chosen moment, as written in square brackets in the list.")
    var moment: Int
}
#endif

/// Batch 429: what Ask the Book streams back. `.partial` carries the answer so far (markers hidden);
/// `.done` carries the final text (markers removed) and the cited passages, in order of citation.
nonisolated enum AskUpdate: Sendable, Equatable {
    case partial(String)
    case done(answer: String, citations: [Passage])
}

@MainActor
@Observable
final class BookIntelligence {
    static let shared = BookIntelligence()

    /// Why the model can't run right now; nil = available. Refreshed by `refreshAvailability()`.
    private(set) var availability: IntelligenceUnavailable?

    private init() {
        refreshAvailability()
    }

    // MARK: - Availability

    func refreshAvailability() {
        availability = Self.currentAvailability()
    }

    nonisolated static func currentAvailability() -> IntelligenceUnavailable? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .osTooOld }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            @unknown default: return .failed
            }
        @unknown default:
            return .failed
        }
        #else
        return .osTooOld
        #endif
    }

    // MARK: - Public API

    /// Notes for every fully heard chunk (up to `frontier`), oldest first. Missing notes are made
    /// one chunk at a time and saved as they land, so a cancelled or failed run keeps its progress.
    /// `progress` runs on the main actor with 0...1 over the chunks that still needed notes.
    func notes(itemId: String, upTo frontier: Double,
               progress: @escaping (Double) -> Void = { _ in }) async throws -> [ChunkNotes] {
        try await fill(itemId: itemId, upTo: frontier, deadline: nil, recentLimit: nil, progress: progress)
    }

    /// How many of the most recent heard chunks a recap makes notes for (about two hours of audio).
    /// Older chunks are left to the overnight warm-up, so a first recap deep into a long book doesn't
    /// make notes for the whole book before it can answer.
    nonisolated static let recapChunkLimit = 12

    /// A "previously on" recap of what the listener has heard, from the notes. Never throws a raw error.
    func recap(itemId: String, title: String, author: String,
               progress: @escaping (Double) -> Void = { _ in }) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw BookIntelligenceError(reason: .osTooOld) }
        refreshAvailability()
        if let availability { throw BookIntelligenceError(reason: availability) }

        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        let notes = try await fill(itemId: itemId, upTo: frontier, deadline: nil,
                                   recentLimit: Self.recapChunkLimit, progress: progress)
        let locale = Self.cachedLocaleIdentifier(itemId: itemId) ?? ""
        let spaceless = ClipText.isSpaceless(localeIdentifier: locale)
        let chosen = RecapPlanner.recapNotes(notes, frontier: frontier, spaceless: spaceless)
        guard !chosen.isEmpty else { throw BookIntelligenceError(reason: .notHeardYet) }

        let prompt = RecapPlanner.recapPrompt(title: title, author: author, notes: chosen)
        let instructions = """
        Write a 'previously on' recap for a listener returning to an audiobook. Use only the notes \
        given. Never mention anything not in them. 4-6 sentences, past tense, no markdown, no \
        questions. It may be read aloud, so write for the ear: short sentences of under 20 words, \
        no brackets, lists or abbreviations. Answer in the language of the notes.
        """
        let text = try await Self.generateText(instructions: instructions, prompt: prompt, timeout: 30)
        return Self.trimmedAtSentence(text, limit: 1_200)
        #else
        throw BookIntelligenceError(reason: .osTooOld)
        #endif
    }

    /// Batch 433: the narrator montage plan for "Previously On…": a few key moments from the heard book,
    /// optionally linked by short spoken lines. Notes errors (not heard, no transcript, availability) throw
    /// like `recap`; a failure of the script step itself falls back to notes-only moments instead.
    func recapProgram(itemId: String, title: String, author: String, summary: String, spokenLinks: Bool,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> RecapProgram {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw BookIntelligenceError(reason: .osTooOld) }
        refreshAvailability()
        if let availability { throw BookIntelligenceError(reason: availability) }

        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        let notes = try await fill(itemId: itemId, upTo: frontier, deadline: nil,
                                   recentLimit: Self.recapChunkLimit, progress: progress)
        let locale = Self.cachedLocaleIdentifier(itemId: itemId) ?? ""
        let spaceless = ClipText.isSpaceless(localeIdentifier: locale)
        let chosen = RecapPlanner.recapNotes(notes, frontier: frontier, spaceless: spaceless)
        guard !chosen.isEmpty else { throw BookIntelligenceError(reason: .notHeardYet) }

        let hash = RecapProgramPlanner.inputHash(notes: chosen, spokenLinks: spokenLinks)
        if let cached = Self.cachedRecapProgram(itemId: itemId),
           cached.inputHash == hash, cached.version == RecapProgram.currentVersion {
            return cached
        }

        let source = await Self.loadRecapSource(itemId: itemId, notes: chosen, spaceless: spaceless)
        let madeThrough = chosen.last?.end ?? 0
        guard let source, !source.candidates.isEmpty else {
            // No sentences to play: a speech-only program from the written recap.
            return RecapProgramPlanner.program(itemId: itemId, summary: summary, beats: [], segments: [],
                                               spokenLinks: spokenLinks, spaceless: spaceless,
                                               madeThrough: madeThrough, inputHash: hash)
        }

        let fitted = RecapProgramPlanner.fit(title: title, author: author, notes: chosen,
                                             candidates: source.candidates, spaceless: spaceless)
        let prompt = RecapProgramPlanner.scriptPrompt(title: title, author: author, notes: fitted.notes,
                                                      candidates: fitted.candidates, spaceless: spaceless)
        let instructions = """
        You plan a 'previously on' montage for a listener returning to an audiobook. From the numbered \
        moments, pick 4-6 that best remind them of the story so far, in the order they happen, favouring \
        plot turns and character moments. Use only the notes and moments given; never mention anything not \
        in them. For each pick, write one short past-tense line, no markdown, that sets it up, and give the \
        moment's number. The lines are spoken aloud between the moments, so write for the ear: plain words, \
        no brackets or abbreviations. Answer in the language of the notes.
        """
        var beats: [(line: String, candidate: RecapMomentCandidate)] = []
        var modelSucceeded = false
        do {
            let lines = try await Self.generateRecapScript(instructions: instructions, prompt: prompt, timeout: 30)
            beats = RecapProgramPlanner.beats(fromModel: lines, candidates: fitted.candidates)
            modelSucceeded = beats.count >= RecapProgramPlanner.minBeats
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ShelfLog.error(.storage, "Recap script failed, using notes only: \(error.localizedDescription)")
        }
        if !modelSucceeded {
            beats = RecapProgramPlanner.fallbackBeats(notes: chosen, candidates: source.candidates)
        }
        let program = RecapProgramPlanner.program(itemId: itemId, summary: summary, beats: beats,
                                                  segments: source.segments, spokenLinks: spokenLinks,
                                                  spaceless: spaceless, madeThrough: madeThrough,
                                                  inputHash: hash)
        // A notes-only fallback isn't kept: a later run should get another try at the model's script.
        if modelSucceeded { Self.saveRecapProgram(program, itemId: itemId) }
        return program
        #else
        throw BookIntelligenceError(reason: .osTooOld)
        #endif
    }

    /// The stored montage plan, or nil when absent, undecodable or from another `RecapProgram.currentVersion`.
    nonisolated static func cachedRecapProgram(itemId: String) -> RecapProgram? {
        let url = recapProgramURL(itemId: itemId, scopeKey: TranscriptStore.currentScopeKey())
        guard let data = try? Data(contentsOf: url),
              let program = try? JSONDecoder().decode(RecapProgram.self, from: data),
              program.version == RecapProgram.currentVersion else { return nil }
        return program
    }

    private nonisolated struct RecapSource: Sendable {
        var candidates: [RecapMomentCandidate]
        var segments: [TranscriptSegment]
    }

    @concurrent
    private nonisolated static func loadRecapSource(itemId: String, notes: [ChunkNotes],
                                                    spaceless: Bool) async -> RecapSource? {
        guard let transcript = TranscriptStore.load(itemId: itemId), !transcript.segments.isEmpty else { return nil }
        let candidates = RecapProgramPlanner.candidates(notes: notes, segments: transcript.segments,
                                                        spaceless: spaceless)
        return RecapSource(candidates: candidates, segments: transcript.segments)
    }

    private nonisolated static func recapProgramURL(itemId: String, scopeKey: String) -> URL {
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey).appendingPathComponent("recap-program.json")
    }

    /// Same atomic write and file protection as `saveCache`; skipped when the item directory doesn't exist.
    @discardableResult
    nonisolated static func saveRecapProgram(_ program: RecapProgram, itemId: String,
                                             scopeKey: String = TranscriptStore.currentScopeKey()) -> Bool {
        let url = recapProgramURL(itemId: itemId, scopeKey: scopeKey)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return false }
        do {
            let data = try JSONEncoder().encode(program)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            ShelfLog.error(.storage, "Recap program save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A short summary of the last five minutes before `time`, plus where to rewind to to hear it
    /// again. Works straight from the transcript; no notes needed.
    func zonedOut(itemId: String, at time: Double) async throws -> (summary: String, rewindTo: Double) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw BookIntelligenceError(reason: .osTooOld) }
        refreshAvailability()
        if let availability { throw BookIntelligenceError(reason: availability) }

        guard let passage = await Self.loadPassage(itemId: itemId, time: time) else {
            throw BookIntelligenceError(reason: .noTranscript)
        }
        guard let found = passage.passage, found.end >= time - 90 else {
            // Nothing transcribed up to here yet.
            throw BookIntelligenceError(reason: .notHeardYet)
        }
        let instructions = """
        Summarise what was just said in this audiobook passage in 2-3 plain sentences, past tense, \
        for a listener who lost focus. Use only the passage. Answer in the language of the passage.
        """
        let text = try await Self.generateText(instructions: instructions, prompt: found.text, timeout: 30)
        return (Self.trimmedAtSentence(text, limit: 700), found.start)
        #else
        throw BookIntelligenceError(reason: .osTooOld)
        #endif
    }

    // MARK: - X-Ray and Ask (Batch 429, Section F part 2)

    /// X-Ray: every person, place and term named in the heard part of the book, merged across the
    /// chunk notes. Makes any missing notes first (same pipeline and progress as the recap), then
    /// merges; there is no extra model call.
    func xray(itemId: String, progress: @escaping (Double) -> Void = { _ in }) async throws -> [XRayEntry] {
        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        let notes = try await fill(itemId: itemId, upTo: frontier, deadline: nil, recentLimit: nil, progress: progress)
        return EntityMerger.merge(notes, frontier: frontier)
    }

    /// Batch 432: the transcript segments that name `entry` (any of its spellings), at or before the
    /// listening frontier, in book order. Empty when there is no transcript.
    func xrayMentions(itemId: String, entry: XRayEntry) async -> [XRayMention] {
        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        return await Self.loadMentions(itemId: itemId, entry: entry, frontier: frontier)
    }

    /// Batch 432: a 2-4 sentence profile of `entry` written on device from its notes and the passages that
    /// name it, up to the frontier. Cached in `xray.json`; a cached profile is returned even when the model
    /// is unavailable, and one made from different input (the listener moved on) is regenerated. Pass
    /// `mentions` from `xrayMentions` to skip searching the transcript again.
    func xrayProfile(itemId: String, entry: XRayEntry, mentions: [XRayMention]? = nil) async throws -> String {
        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        let found: [XRayMention]
        if let mentions { found = mentions } else {
            found = await Self.loadMentions(itemId: itemId, entry: entry, frontier: frontier)
        }
        let locale = Self.cachedLocaleIdentifier(itemId: itemId) ?? ""
        let spaceless = ClipText.isSpaceless(localeIdentifier: locale)
        let prompt = XRayProfilePlanner.prompt(entry: entry, mentions: found, spaceless: spaceless)
        let hash = XRayProfilePlanner.inputHash(prompt)
        if let cached = await Self.cachedProfile(itemId: itemId, entryId: entry.id, hash: hash, locale: locale) {
            return cached
        }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw BookIntelligenceError(reason: .osTooOld) }
        refreshAvailability()
        if let availability { throw BookIntelligenceError(reason: availability) }
        guard !entry.allNotes.isEmpty || !found.isEmpty else { throw BookIntelligenceError(reason: .notHeardYet) }

        let instructions = """
        You write an X-Ray entry about one person, place or term in an audiobook, for a listener \
        partway through it. Use only the notes and passages given. Never guess what happens later. \
        2-4 sentences: who or what it is, its role and relationships to others, and what has happened \
        with it so far. State only what the text shows; no "possibly" or "might". Write normal \
        sentences with capital letters, opening with the name and who or what it is. No \
        markdown, no lists. Answer in the language of the passages.
        """
        let scopeKey = TranscriptStore.currentScopeKey() // Review 4 Low (scope at save time): before the await
        let text = try await Self.generateText(instructions: instructions, prompt: prompt, timeout: 30)
        let profile = Self.trimmedAtSentence(text, limit: 800)
        await Self.storeProfile(itemId: itemId, entryId: entry.id, hash: hash, locale: locale, text: profile, scopeKey: scopeKey)
        return profile
        #else
        throw BookIntelligenceError(reason: .osTooOld)
        #endif
    }

    @concurrent
    private nonisolated static func loadMentions(itemId: String, entry: XRayEntry, frontier: Double) async -> [XRayMention] {
        guard let transcript = TranscriptStore.load(itemId: itemId), !transcript.segments.isEmpty else { return [] }
        let index = TranscriptSearchIndex(transcript: transcript)
        return XRayMentionFinder.mentions(for: entry, in: index, frontier: frontier)
    }

    @concurrent
    private nonisolated static func cachedProfile(itemId: String, entryId: String, hash: String,
                                                  locale: String) async -> String? {
        guard let cache = loadProfileCache(itemId: itemId), cache.localeIdentifier == locale else { return nil }
        return cache.profile(for: entryId, hash: hash)
    }

    @concurrent
    private nonisolated static func storeProfile(itemId: String, entryId: String, hash: String,
                                                 locale: String, text: String, scopeKey: String) async {
        var cache = loadProfileCache(itemId: itemId, scopeKey: scopeKey)
        if cache == nil || cache?.version != XRayProfileCache.currentVersion || cache?.localeIdentifier != locale {
            cache = .empty(itemId: itemId, localeIdentifier: locale)
        }
        cache?.store(id: entryId, hash: hash, text: text)
        if let cache { saveProfileCache(cache, itemId: itemId, scopeKey: scopeKey) }
    }

    /// Ask the Book: answers one question from the heard part of the transcript (BM25-retrieved
    /// passages plus already-cached chunk notes; Ask never makes missing notes). Yields growing
    /// `.partial` snapshots (citation markers hidden), then `.done`. The stream throws
    /// `BookIntelligenceError` on failure or after 40 seconds, and stops when the consumer cancels.
    func ask(itemId: String, title: String, author: String,
             question: String) -> AsyncThrowingStream<AskUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.runAsk(itemId: itemId, title: title, author: author,
                                          question: question, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runAsk(itemId: String, title: String, author: String, question: String,
                        continuation: AsyncThrowingStream<AskUpdate, Error>.Continuation) async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw BookIntelligenceError(reason: .osTooOld) }
        refreshAvailability()
        if let availability { throw BookIntelligenceError(reason: availability) }

        let trimmedQuestion = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !trimmedQuestion.isEmpty else { throw BookIntelligenceError(reason: .failed) }

        let frontier = TranscriptionCenter.shared.frontier(for: itemId)
        let load = await Self.makeAskContext(itemId: itemId, frontier: frontier, question: trimmedQuestion)
        guard load.hasTranscript else { throw BookIntelligenceError(reason: .noTranscript) }
        guard load.heardAny else { throw BookIntelligenceError(reason: .notHeardYet) }
        try Task.checkCancellation()

        guard !load.context.isEmpty else {
            // Nothing heard so far mentions what was asked: say so without a model call.
            let none = String(localized: "I can't tell from what you've heard so far.",
                              comment: "Ask the Book answer when no heard passage relates to the question")
            continuation.yield(.done(answer: none, citations: []))
            return
        }

        let prompt = AskPlanner.prompt(title: title, author: author, question: trimmedQuestion, context: load.context)
        let raw = try await Self.streamAnswer(prompt: prompt, continuation: continuation)
        try Task.checkCancellation()
        let answer = AskPlanner.displayText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw BookIntelligenceError(reason: .failed) }
        let cited = AskPlanner.citations(in: raw, passageCount: load.context.count).map { load.context[$0] }
        continuation.yield(.done(answer: answer, citations: cited))
        #else
        throw BookIntelligenceError(reason: .osTooOld)
        #endif
    }

    private nonisolated struct AskLoad: Sendable {
        var hasTranscript: Bool
        var heardAny: Bool
        var context: [Passage]
    }

    /// Loads the transcript and cached notes off the main actor and picks the context for the question.
    @concurrent
    private nonisolated static func makeAskContext(itemId: String, frontier: Double, question: String) async -> AskLoad {
        let scopeKey = TranscriptStore.currentScopeKey()
        guard let transcript = TranscriptStore.load(itemId: itemId, scopeKey: scopeKey),
              !transcript.segments.isEmpty else {
            return AskLoad(hasTranscript: false, heardAny: false, context: [])
        }
        let spaceless = ClipText.isSpaceless(localeIdentifier: transcript.localeIdentifier)
        let passages = PassageBuilder.passages(segments: transcript.segments, frontier: frontier, spaceless: spaceless)
        guard !passages.isEmpty else { return AskLoad(hasTranscript: true, heardAny: false, context: []) }
        var notes: [ChunkNotes] = []
        if let cache = loadCache(itemId: itemId, scopeKey: scopeKey),
           cache.version == NotesCache.currentVersion,
           cache.localeIdentifier == transcript.localeIdentifier {
            notes = cache.notes.filter { $0.end <= frontier }
        }
        let context = AskPlanner.context(question: question, passages: passages, notes: notes, spaceless: spaceless)
        return AskLoad(hasTranscript: true, heardAny: true, context: context)
    }

    /// A partial snapshot for display: citation markers removed, plus any "[2" still being typed.
    private nonisolated static func partialDisplay(_ text: String) -> String {
        var visible = text
        if let open = visible.lastIndex(of: "["), !visible[open...].contains("]") {
            visible = String(visible[..<open])
        }
        return AskPlanner.displayText(visible)
    }

    #if canImport(FoundationModels)
    /// Streams the model's answer (foreground only), yielding display snapshots; returns the full raw text.
    @available(iOS 26.0, *)
    @concurrent
    private nonisolated static func streamAnswer(
        prompt: String, continuation: AsyncThrowingStream<AskUpdate, Error>.Continuation
    ) async throws -> String {
        let instructions = """
        Answer the listener's question about an audiobook using only the numbered passages. Speak to \
        the listener as "you". Cite passages like [2]. If the passages don't answer it, say you can't \
        tell from what you've heard so far. Never guess about later events. Answer in the language of the question. Short: 2-5 \
        sentences, no markdown.
        """
        return try await withTimeout(seconds: 40) {
            let session = LanguageModelSession(instructions: instructions)
            var latest = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                latest = snapshot.content
                continuation.yield(.partial(partialDisplay(latest)))
            }
            return latest
        }
    }
    #endif

    /// BCP-47 identifier the book's transcript was made in, for choosing a speech voice.
    func transcriptLocaleIdentifier(itemId: String) -> String? {
        Self.cachedLocaleIdentifier(itemId: itemId)
    }

    /// Overnight: makes missing notes for the given books' heard parts, stopping at `deadline`, on
    /// cancellation, or at the first rate limit. Skipped in Low Power Mode or when the model is unavailable.
    func warmNotes(itemIds: [String], deadline: Date) async {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        refreshAvailability()
        guard availability == nil else { return }
        for id in itemIds {
            if Task.isCancelled || Date() >= deadline { return }
            let meta = TranscriptStore.meta(itemId: id)
            guard meta.fraction > 0 || meta.isComplete else { continue }
            let frontier = TranscriptionCenter.shared.frontier(for: id)
            guard frontier > 0 else { continue }
            do {
                _ = try await fill(itemId: id, upTo: frontier, deadline: deadline, recentLimit: nil, progress: { _ in })
            } catch let error as BookIntelligenceError {
                if error.reason == .rateLimited { return }
            } catch {
                return   // cancelled
            }
        }
    }

    // MARK: - Last offered (auto recap)

    private nonisolated static func offeredKey(_ itemId: String) -> String { "bookIntelligence.recapOffered.\(itemId)" }

    /// When "Previously On…" was last offered for this book on its page, or nil.
    nonisolated static func lastOfferedAt(itemId: String) -> Date? {
        let value = UserDefaults.standard.double(forKey: offeredKey(itemId))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    nonisolated static func markOffered(itemId: String, at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: offeredKey(itemId))
    }

    // MARK: - Notes pipeline

    /// What the main actor needs from the transcript before generating: the closed, heard chunks,
    /// the notes already valid for them, and the locale.
    private nonisolated struct NotesPlan: Sendable {
        var heard: [TranscriptChunk]
        var cache: NotesCache
        var valid: [Int: ChunkNotes]
        var scopeKey: String
    }

    /// `recentLimit` limits note-making to the last N heard chunks (nil = all of them); notes already
    /// cached for older chunks are still returned.
    private func fill(itemId: String, upTo frontier: Double, deadline: Date?, recentLimit: Int?,
                      progress: @escaping (Double) -> Void) async throws -> [ChunkNotes] {
        guard let plan = await Self.makePlan(itemId: itemId, frontier: frontier) else {
            throw BookIntelligenceError(reason: .noTranscript)
        }
        guard !plan.heard.isEmpty else { throw BookIntelligenceError(reason: .notHeardYet) }
        let wanted = recentLimit.map { Array(plan.heard.suffix($0)) } ?? plan.heard
        let missing = wanted.filter { plan.valid[$0.index] == nil }
        var cache = plan.cache
        var done = 0
        progress(missing.isEmpty ? 1 : 0)

        #if canImport(FoundationModels)
        if !missing.isEmpty {
            guard #available(iOS 26.0, *) else { throw BookIntelligenceError(reason: .osTooOld) }
            refreshAvailability()
            if let availability { throw BookIntelligenceError(reason: availability) }
            for chunk in missing {
                try Task.checkCancellation()
                if let deadline, Date() >= deadline { break }
                cache = try await Self.makeAndStoreNotes(for: chunk, cache: cache, itemId: itemId, scopeKey: plan.scopeKey)
                done += 1
                progress(Double(done) / Double(missing.count))
            }
        }
        #endif

        let valid = cache.valid(for: plan.heard)
        return plan.heard.compactMap { valid[$0.index] }
    }

    @concurrent
    private nonisolated static func makePlan(itemId: String, frontier: Double) async -> NotesPlan? {
        let scopeKey = TranscriptStore.currentScopeKey()
        guard let transcript = TranscriptStore.load(itemId: itemId, scopeKey: scopeKey),
              !transcript.segments.isEmpty else { return nil }
        let spaceless = ClipText.isSpaceless(localeIdentifier: transcript.localeIdentifier)
        let result = TranscriptChunker.chunks(segments: transcript.segments, spaceless: spaceless,
                                              transcriptComplete: transcript.isComplete)
        // A still-growing last chunk is left alone: its text (and hash) would change.
        let closed = result.lastIsClosed ? result.chunks : Array(result.chunks.dropLast())
        let heard = TranscriptChunker.heard(closed, frontier: frontier)

        var cache = loadCache(itemId: itemId, scopeKey: scopeKey)
        if cache == nil || cache?.version != NotesCache.currentVersion
            || cache?.localeIdentifier != transcript.localeIdentifier {
            cache = NotesCache(version: NotesCache.currentVersion, itemId: itemId,
                               localeIdentifier: transcript.localeIdentifier, notes: [])
        }
        let current = cache!
        return NotesPlan(heard: heard, cache: current, valid: current.valid(for: heard), scopeKey: scopeKey)
    }

    #if canImport(FoundationModels)
    /// Makes the notes for one chunk, merges them into `cache` (dropping any stale entry for the
    /// same index), saves, and returns the new cache.
    @available(iOS 26.0, *)
    @concurrent
    private nonisolated static func makeAndStoreNotes(for chunk: TranscriptChunk, cache: NotesCache,
                                                      itemId: String, scopeKey: String) async throws -> NotesCache {
        let notes = try await generateChunkNotes(chunk)
        var updated = cache
        updated.notes.removeAll { $0.chunkIndex == chunk.index }
        updated.notes.append(notes)
        updated.notes.sort { $0.chunkIndex < $1.chunkIndex }
        saveCache(updated, itemId: itemId, scopeKey: scopeKey)
        return updated
    }

    @available(iOS 26.0, *)
    private nonisolated static func generateChunkNotes(_ chunk: TranscriptChunk) async throws -> ChunkNotes {
        let instructions = """
        You take notes on one part of an audiobook. Use only the text given. Never add anything \
        that is not in it. Answer in the language of the passage.
        """
        let generated: GeneratedChunkNotes = try await withTimeout(seconds: 45) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: chunk.text, generating: GeneratedChunkNotes.self)
            return response.content
        }
        let entities = generated.entities.compactMap { entity -> NoteEntity? in
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let kind = NoteEntityKind(rawValue: entity.kind.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) ?? .term
            return NoteEntity(name: name, kind: kind,
                              note: entity.note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ChunkNotes(chunkIndex: chunk.index, start: chunk.start, end: chunk.end,
                          sourceHash: NotesCache.hash(chunk.text),
                          summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                          entities: entities)
    }

    /// One free-text answer from a fresh session, with a timeout, errors mapped. Used by the
    /// recap and "I zoned out".
    @available(iOS 26.0, *)
    @concurrent
    private nonisolated static func generateText(instructions: String, prompt: String,
                                                 timeout: Double) async throws -> String {
        let text: String = try await withTimeout(seconds: timeout) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BookIntelligenceError(reason: .failed) }
        return trimmed
    }

    /// Batch 433: the montage script from a fresh session: (line, moment number) pairs as the model wrote them.
    @available(iOS 26.0, *)
    @concurrent
    private nonisolated static func generateRecapScript(instructions: String, prompt: String,
                                                        timeout: Double) async throws -> [(line: String, moment: Int)] {
        let script: GeneratedRecapScript = try await withTimeout(seconds: timeout) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: GeneratedRecapScript.self)
            return response.content
        }
        return script.beats.map { ($0.line, $0.moment) }
    }
    #endif

    // MARK: - Zoned-out passage

    private nonisolated struct PassageResult: Sendable {
        var passage: (start: Double, end: Double, text: String)?
    }

    @concurrent
    private nonisolated static func loadPassage(itemId: String, time: Double) async -> PassageResult? {
        guard let transcript = TranscriptStore.load(itemId: itemId), !transcript.segments.isEmpty else { return nil }
        let spaceless = ClipText.isSpaceless(localeIdentifier: transcript.localeIdentifier)
        return PassageResult(passage: ZonedOutPlanner.passage(segments: transcript.segments, time: time,
                                                              spaceless: spaceless))
    }

    // MARK: - Timeout and error mapping

    /// Races `operation` against a sleep. Errors from the model are mapped to `BookIntelligenceError`;
    /// cancellation is passed through as `CancellationError`.
    private nonisolated static func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                do { return try await operation() } catch { throw mapError(error) }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BookIntelligenceError(reason: .timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BookIntelligenceError(reason: .failed) }
            return first
        }
    }

    nonisolated static func mapError(_ error: Error) -> Error {
        if error is CancellationError || error is BookIntelligenceError { return error }
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: return BookIntelligenceError(reason: .contextTooLarge)
            case .rateLimited: return BookIntelligenceError(reason: .rateLimited)
            case .guardrailViolation, .refusal: return BookIntelligenceError(reason: .refused)
            case .unsupportedLanguageOrLocale: return BookIntelligenceError(reason: .unsupportedLanguage)
            case .timeout: return BookIntelligenceError(reason: .timedOut)
            default: return BookIntelligenceError(reason: .failed)
            }
        }
        if #available(iOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return BookIntelligenceError(reason: .contextTooLarge)
            case .assetsUnavailable: return BookIntelligenceError(reason: .modelNotReady)
            case .guardrailViolation, .refusal: return BookIntelligenceError(reason: .refused)
            case .unsupportedLanguageOrLocale: return BookIntelligenceError(reason: .unsupportedLanguage)
            case .rateLimited, .concurrentRequests: return BookIntelligenceError(reason: .rateLimited)
            default: return BookIntelligenceError(reason: .failed)
            }
        }
        #endif
        return BookIntelligenceError(reason: .failed)
    }

    // MARK: - Text helpers

    /// Cuts `text` to at most `limit` characters at the last sentence end; falls back to a hard
    /// cut with an ellipsis when there is no sentence end in range.
    nonisolated static func trimmedAtSentence(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = String(trimmed.prefix(limit))
        let enders: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
        if let last = head.lastIndex(where: { enders.contains($0) }) {
            return String(head[...last])
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    // MARK: - notes.json

    private nonisolated static func notesURL(itemId: String, scopeKey: String) -> URL {
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey).appendingPathComponent("notes.json")
    }

    /// The stored cache, or nil when absent or undecodable.
    nonisolated static func loadCache(itemId: String, scopeKey: String = TranscriptStore.currentScopeKey()) -> NotesCache? {
        guard let data = try? Data(contentsOf: notesURL(itemId: itemId, scopeKey: scopeKey)) else { return nil }
        return try? JSONDecoder().decode(NotesCache.self, from: data)
    }

    /// Atomic write with the same file protection the transcript uses. The item directory exists
    /// whenever there is a transcript to make notes from; if it doesn't, the write is skipped.
    @discardableResult
    nonisolated static func saveCache(_ cache: NotesCache, itemId: String,
                                      scopeKey: String = TranscriptStore.currentScopeKey()) -> Bool {
        let url = notesURL(itemId: itemId, scopeKey: scopeKey)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return false }
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            ShelfLog.error(.storage, "Notes save failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - xray.json (Batch 432)

    private nonisolated static func xrayURL(itemId: String, scopeKey: String) -> URL {
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey).appendingPathComponent("xray.json")
    }

    nonisolated static func loadProfileCache(itemId: String,
                                             scopeKey: String = TranscriptStore.currentScopeKey()) -> XRayProfileCache? {
        guard let data = try? Data(contentsOf: xrayURL(itemId: itemId, scopeKey: scopeKey)) else { return nil }
        return try? JSONDecoder().decode(XRayProfileCache.self, from: data)
    }

    /// Same atomic write and file protection as `saveCache`; skipped when the item directory doesn't exist.
    @discardableResult
    nonisolated static func saveProfileCache(_ cache: XRayProfileCache, itemId: String,
                                             scopeKey: String = TranscriptStore.currentScopeKey()) -> Bool {
        let url = xrayURL(itemId: itemId, scopeKey: scopeKey)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return false }
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            ShelfLog.error(.storage, "X-Ray profile save failed: \(error.localizedDescription)")
            return false
        }
    }

    private nonisolated static func cachedLocaleIdentifier(itemId: String) -> String? {
        loadCache(itemId: itemId)?.localeIdentifier
    }
}
