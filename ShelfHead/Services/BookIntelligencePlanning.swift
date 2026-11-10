import Foundation

/// Batch 428: pure planning for book intelligence (Section F part 1): transcript chunking, per-chunk notes
/// cache, "Previously on…" and "I zoned out" passage selection, and the unavailable-reason copy. No I/O, no
/// FoundationModels; unit-tested in `BookIntelligencePlanningTests`.

// MARK: - Token estimate

nonisolated enum TokenEstimate {
    /// Heuristic: spaceless (zh/ja) scripts count one token per character; otherwise `ceil(characters / 4)`
    /// (a word is about 1.3 tokens). Empty text is 0.
    nonisolated static func tokens(_ text: String, spaceless: Bool) -> Int {
        let count = text.count
        if count == 0 { return 0 }
        return spaceless ? count : (count + 3) / 4
    }
}

// MARK: - Chunking

/// A fixed slice of the transcript, the unit notes are made and cached for.
nonisolated struct TranscriptChunk: Equatable, Sendable, Codable {
    var index: Int
    /// First segment's start, book seconds.
    var start: Double
    /// Last segment's end, book seconds.
    var end: Double
    /// Half-open range into `transcript.segments`.
    var segmentRange: Range<Int>
    /// The segments joined with " " (or "" when spaceless).
    var text: String

    init(index: Int, start: Double, end: Double, segmentRange: Range<Int>, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.segmentRange = segmentRange
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case index, start, end, lower, upper, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        let lower = try c.decode(Int.self, forKey: .lower)
        let upper = try c.decode(Int.self, forKey: .upper)
        guard lower <= upper else {
            throw DecodingError.dataCorruptedError(forKey: .upper, in: c,
                                                   debugDescription: "segment range upper < lower")
        }
        segmentRange = lower..<upper
        text = try c.decode(String.self, forKey: .text)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(segmentRange.lowerBound, forKey: .lower)
        try c.encode(segmentRange.upperBound, forKey: .upper)
        try c.encode(text, forKey: .text)
    }
}

nonisolated enum TranscriptChunker {
    nonisolated static let budgetTokens = 2_000

    /// Greedy left-to-right: add segments until the next would exceed `budgetTokens` (a single over-budget
    /// segment is its own chunk). Deterministic, so earlier chunks never change when a partial transcript
    /// grows, except the last chunk, which is still open (`lastIsClosed == false`) unless `transcriptComplete`.
    /// An empty transcript gives no chunks and `lastIsClosed == transcriptComplete`.
    nonisolated static func chunks(segments: [TranscriptSegment], spaceless: Bool,
                                   transcriptComplete: Bool) -> (chunks: [TranscriptChunk], lastIsClosed: Bool) {
        var result: [TranscriptChunk] = []
        var first = 0
        var used = 0
        for i in segments.indices {
            let cost = TokenEstimate.tokens(segments[i].text, spaceless: spaceless)
            if i > first && used + cost > budgetTokens {
                result.append(make(index: result.count, segments: segments, range: first..<i, spaceless: spaceless))
                first = i
                used = 0
            }
            used += cost
        }
        if first < segments.count {
            result.append(make(index: result.count, segments: segments, range: first..<segments.count,
                               spaceless: spaceless))
        }
        return (result, transcriptComplete)
    }

    /// Chunks whose `end` is at or before the frontier (fully heard), in order.
    nonisolated static func heard(_ chunks: [TranscriptChunk], frontier: Double) -> [TranscriptChunk] {
        chunks.filter { $0.end <= frontier }
    }

    nonisolated private static func make(index: Int, segments: [TranscriptSegment], range: Range<Int>,
                                         spaceless: Bool) -> TranscriptChunk {
        let slice = segments[range]
        return TranscriptChunk(index: index,
                               start: slice.first?.start ?? 0,
                               end: slice.last?.end ?? 0,
                               segmentRange: range,
                               text: slice.map(\.text).joined(separator: spaceless ? "" : " "))
    }
}

// MARK: - Notes

nonisolated enum NoteEntityKind: String, Codable, Sendable, CaseIterable { case person, place, term }

nonisolated struct NoteEntity: Codable, Equatable, Sendable {
    var name: String
    var kind: NoteEntityKind
    var note: String
}

/// Notes the model wrote for one chunk. Cached per book in the transcript folder.
nonisolated struct ChunkNotes: Codable, Equatable, Sendable {
    var chunkIndex: Int
    var start: Double
    var end: Double
    /// `NotesCache.hash` of the chunk text; a changed chunk regenerates.
    var sourceHash: String
    /// Two to four sentences.
    var summary: String
    var entities: [NoteEntity]
}

nonisolated struct NotesCache: Codable, Equatable, Sendable {
    nonisolated static let currentVersion = 1
    var version: Int
    var itemId: String
    var localeIdentifier: String
    var notes: [ChunkNotes]

    /// Notes still valid for `chunks` (same index and `sourceHash`), keyed by chunk index. Empty when the cache
    /// was written by a different `version`.
    func valid(for chunks: [TranscriptChunk]) -> [Int: ChunkNotes] {
        guard version == NotesCache.currentVersion else { return [:] }
        var byIndex: [Int: ChunkNotes] = [:]
        for note in notes { byIndex[note.chunkIndex] = note }
        var result: [Int: ChunkNotes] = [:]
        for chunk in chunks {
            if let note = byIndex[chunk.index], note.sourceHash == NotesCache.hash(chunk.text) {
                result[chunk.index] = note
            }
        }
        return result
    }

    /// FNV-1a 64-bit over the UTF-8 bytes, as 16 lowercase hex characters.
    nonisolated static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16, uppercase: false)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

// MARK: - Previously on…

nonisolated enum RecapPlanner {
    nonisolated static let awayThreshold: TimeInterval = 3 * 86_400
    /// Frontier (seconds) a book needs before a recap is worth offering.
    nonisolated static let minimumFrontier: Double = 10 * 60

    /// Offer "Previously on…" automatically: last listened at least 3 days ago (exactly 3 days counts), the
    /// frontier is past 10 minutes, and not already offered since that last listen (`lastOfferedAt >=
    /// lastListened` means it was).
    nonisolated static func shouldOffer(lastListened: Date?, now: Date, frontier: Double,
                                        lastOfferedAt: Date?) -> Bool {
        guard let lastListened else { return false }
        guard now.timeIntervalSince(lastListened) >= awayThreshold else { return false }
        guard frontier > minimumFrontier else { return false }
        if let lastOfferedAt, lastOfferedAt >= lastListened { return false }
        return true
    }

    /// The notes to recap: heard notes (`end <= frontier`), newest first, as many as fit `budgetTokens`
    /// measured on their summaries (stopping at the first that doesn't fit), then returned oldest first.
    nonisolated static func recapNotes(_ notes: [ChunkNotes], frontier: Double, spaceless: Bool,
                                       budgetTokens: Int = 2_400) -> [ChunkNotes] {
        let heard = notes.filter { $0.end <= frontier }.sorted { $0.start < $1.start }
        var picked: [ChunkNotes] = []
        var used = 0
        for note in heard.reversed() {
            let cost = TokenEstimate.tokens(note.summary, spaceless: spaceless)
            if used + cost > budgetTokens { break }
            used += cost
            picked.append(note)
        }
        return picked.reversed()
    }

    /// Prompt text: a "Book:" line, an "Author:" line when there is one, a blank line, then one
    /// "Part n (t1–t2): summary" line per note in order. Times are m:ss under an hour, h:mm:ss from an hour.
    nonisolated static func recapPrompt(title: String, author: String, notes: [ChunkNotes]) -> String {
        var lines = ["Book: \(title)"]
        if !author.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Author: \(author)") }
        lines.append("")
        for (i, note) in notes.enumerated() {
            lines.append("Part \(i + 1) (\(timestamp(note.start))–\(timestamp(note.end))): \(note.summary)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func timestamp(_ seconds: Double) -> String {
        let total = Int((seconds.isFinite ? max(0, seconds) : 0).rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - I zoned out

nonisolated enum ZonedOutPlanner {
    nonisolated static let window: Double = 5 * 60

    /// The passage to summarise for "I zoned out": segments overlapping `[time - window, time]`, trimmed from
    /// the FRONT until within `budgetTokens` (at least the last segment is always kept). `start` is the first
    /// kept segment's start, the "rewind to" target. Nil when no segments overlap.
    nonisolated static func passage(segments: [TranscriptSegment], time: Double, spaceless: Bool,
                                    budgetTokens: Int = 2_600) -> (start: Double, end: Double, text: String)? {
        guard time.isFinite else { return nil }
        let lower = time - window
        var kept = segments.filter { $0.end > lower && $0.start < time }
        guard !kept.isEmpty else { return nil }
        var total = kept.reduce(0) { $0 + TokenEstimate.tokens($1.text, spaceless: spaceless) }
        while kept.count > 1 && total > budgetTokens {
            total -= TokenEstimate.tokens(kept.removeFirst().text, spaceless: spaceless)
        }
        return (kept[0].start, kept[kept.count - 1].end,
                kept.map(\.text).joined(separator: spaceless ? "" : " "))
    }
}

// MARK: - Unavailable reasons

/// Why intelligence can't run, in the app's own words. Pure mapping so the copy is tested.
nonisolated enum IntelligenceUnavailable: Equatable, Sendable {
    case osTooOld, deviceNotEligible, appleIntelligenceOff, modelNotReady, noTranscript, notHeardYet,
         rateLimited, unsupportedLanguage, refused, contextTooLarge, timedOut, failed

    /// Localised one-line message.
    var message: String {
        switch self {
        case .osTooOld:
            return String(localized: "Needs iOS 26 or later.",
                          comment: "Why Apple Intelligence features are unavailable: the iOS version is too old")
        case .deviceNotEligible:
            return String(localized: "This iPhone doesn't support Apple Intelligence.",
                          comment: "Why Apple Intelligence features are unavailable: unsupported device")
        case .appleIntelligenceOff:
            return String(localized: "Turn on Apple Intelligence in Settings to use this.",
                          comment: "Why Apple Intelligence features are unavailable: switched off in Settings")
        case .modelNotReady:
            return String(localized: "Apple Intelligence is still getting ready. Try again in a little while.",
                          comment: "Why Apple Intelligence features are unavailable: the model is still downloading")
        case .noTranscript:
            return String(localized: "Transcribe this book first.",
                          comment: "Why recaps are unavailable: the book has no transcript yet")
        case .notHeardYet:
            return String(localized: "Listen a little further first.",
                          comment: "Why recaps are unavailable: not enough of the book has been heard")
        case .rateLimited:
            return String(localized: "Too many requests just now. Try again in a minute.",
                          comment: "Why Apple Intelligence features are unavailable: rate limited")
        case .unsupportedLanguage:
            return String(localized: "Apple Intelligence doesn't support this book's language yet.",
                          comment: "Why Apple Intelligence features are unavailable: unsupported transcript language")
        case .refused:
            return String(localized: "Apple Intelligence couldn't write this one.",
                          comment: "Shown when the model declined or its safety guardrails blocked a recap")
        case .contextTooLarge:
            return String(localized: "This part is too long to summarise.",
                          comment: "Shown when the passage exceeds the model's context window")
        case .timedOut:
            return String(localized: "This took too long. Try again.",
                          comment: "Shown when generating a recap timed out")
        case .failed:
            return String(localized: "Something went wrong. Try again.",
                          comment: "Generic failure while generating a recap")
        }
    }

    /// Whether a Retry button makes sense.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timedOut, .failed, .modelNotReady: return true
        case .osTooOld, .deviceNotEligible, .appleIntelligenceOff, .noTranscript, .notHeardYet,
             .unsupportedLanguage, .refused, .contextTooLarge: return false
        }
    }
}

// MARK: - Read It to Me voice

/// Batch 432: picks the voice "Read It to Me" speaks with. `AVSpeechSynthesisVoice(language:)` hands back the
/// compact default voice even when a far better Enhanced or Premium one is installed, so the sheet sounded
/// robotic. Siri's own voices aren't offered to apps; this is the best of what `speechVoices()` lists.
nonisolated struct SpeechVoiceCandidate: Equatable, Sendable {
    var identifier: String
    /// BCP 47, as `AVSpeechSynthesisVoice.language` gives it ("en-AU", "zh-CN").
    var language: String
    /// `AVSpeechSynthesisVoiceQuality.rawValue`: 1 default, 2 enhanced, 3 premium.
    var quality: Int
    /// Novelty voices (character voices) and the user's Personal Voice are never picked.
    var isExcluded: Bool
}

nonisolated enum SpeechVoicePicker {
    /// `AVSpeechSynthesisVoiceQuality.default.rawValue`.
    nonisolated static let defaultQuality = 1

    /// The best voice for `localeIdentifier` ("en_AU" or "en-AU"; nil or empty = `fallbackLanguage`): only voices
    /// in the same language, then highest quality, then the exact region, then `preferredIdentifier` (the
    /// system's own pick for the locale), then identifier for a stable answer. Nil when no voice speaks it.
    nonisolated static func best(_ voices: [SpeechVoiceCandidate], localeIdentifier: String?,
                                 fallbackLanguage: String, preferredIdentifier: String? = nil) -> SpeechVoiceCandidate? {
        let raw = (localeIdentifier?.isEmpty == false ? localeIdentifier! : fallbackLanguage)
        let wanted = normalised(raw)
        let language = languagePart(wanted)
        guard !language.isEmpty else { return nil }
        let matching = voices.filter { !$0.isExcluded && languagePart(normalised($0.language)) == language }
        return matching.max { l, r in
            if l.quality != r.quality { return l.quality < r.quality }
            let le = normalised(l.language) == wanted, re = normalised(r.language) == wanted
            if le != re { return !le }
            let lp = l.identifier == preferredIdentifier, rp = r.identifier == preferredIdentifier
            if lp != rp { return !lp }
            return l.identifier > r.identifier
        }
    }

    /// True when the best voice is only the compact default one, so the sheet can say how to get a better one.
    nonisolated static func shouldSuggestBetterVoice(_ best: SpeechVoiceCandidate?) -> Bool {
        (best?.quality ?? defaultQuality) <= defaultQuality
    }

    private nonisolated static func normalised(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// The spoken language. Hong Kong Chinese voices speak Cantonese, so "zh-HK" counts as "yue" and is never
    /// picked for a Mandarin transcript (or the other way round).
    private nonisolated static func languagePart(_ identifier: String) -> String {
        if identifier.hasPrefix("zh-hk") || identifier.hasPrefix("zh-hant-hk") { return "yue" }
        return String(identifier.split(separator: "-").first ?? "")
    }
}
