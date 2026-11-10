import Foundation
import NaturalLanguage

/// Phase 1, Batch 422: the pure decisions behind on-device transcription. The service
/// (`TranscriptionService`) owns the I/O, the Speech framework and the background-task
/// plumbing; everything here is a function of its arguments so it can be pinned by unit
/// tests without a device, a model download or a real audio file.

/// A timed piece of transcriber output (normally one word), in **track** time, seconds
/// from the start of the audio file it came from.
struct TimedRun: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

// MARK: - Locale

/// Turns what Audiobookshelf says a book's language is into a `Locale` the transcriber
/// can be asked about, and picks the closest locale the transcriber actually supports.
enum TranscriptLocaleResolver {
    /// Language code (or script-qualified code) for each name, ISO 639-1/-2 code and
    /// native name worth recognising. Keys are lowercased. Deliberately the top ~25
    /// languages, not an exhaustive ISO list: an unknown value falls back to the
    /// listener's locale, which is the right guess most of the time.
    private static let languageTable: [String: String] = {
        let entries: [(code: String, names: [String])] = [
            ("en", ["english", "en", "eng"]),
            ("es", ["spanish", "español", "espanol", "castilian", "es", "spa"]),
            ("fr", ["french", "français", "francais", "fr", "fra", "fre"]),
            ("de", ["german", "deutsch", "de", "deu", "ger"]),
            ("it", ["italian", "italiano", "it", "ita"]),
            ("pt", ["portuguese", "português", "portugues", "pt", "por"]),
            ("nl", ["dutch", "nederlands", "nl", "nld", "dut"]),
            ("ru", ["russian", "русский", "ru", "rus"]),
            ("ja", ["japanese", "日本語", "ja", "jpn"]),
            ("ko", ["korean", "한국어", "ko", "kor"]),
            ("zh", ["chinese", "中文", "mandarin", "普通话", "汉语", "國語", "zh", "zho", "chi", "cmn"]),
            ("zh-Hans", ["simplified chinese", "简体中文"]),
            ("zh-Hant", ["traditional chinese", "繁體中文"]),
            ("ar", ["arabic", "العربية", "ar", "ara"]),
            ("hi", ["hindi", "हिन्दी", "hi", "hin"]),
            ("sv", ["swedish", "svenska", "sv", "swe"]),
            ("da", ["danish", "dansk", "da", "dan"]),
            ("nb", ["norwegian", "norsk", "nb", "no", "nor"]),
            ("fi", ["finnish", "suomi", "fi", "fin"]),
            ("pl", ["polish", "polski", "pl", "pol"]),
            ("tr", ["turkish", "türkçe", "turkce", "tr", "tur"]),
            ("he", ["hebrew", "עברית", "he", "heb"]),
            ("th", ["thai", "ไทย", "th", "tha"]),
            ("id", ["indonesian", "bahasa indonesia", "id", "ind"]),
            ("uk", ["ukrainian", "українська", "uk", "ukr"]),
            ("cs", ["czech", "čeština", "cestina", "cs", "ces", "cze"]),
            ("el", ["greek", "ελληνικά", "el", "ell", "gre"]),
            ("hu", ["hungarian", "magyar", "hu", "hun"]),
            ("ro", ["romanian", "română", "romana", "ro", "ron", "rum"]),
            ("vi", ["vietnamese", "tiếng việt", "vi", "vie"]),
        ]
        var table: [String: String] = [:]
        for entry in entries {
            for name in entry.names { table[name] = entry.code }
        }
        return table
    }()

    /// Turns an ABS `metadata.language` string ("English", "en", "eng", "en-GB", "Chinese",
    /// "中文", "zh-Hans", "Mandarin", "Deutsch", "French", ...) into a Locale; falls back to
    /// `fallback` when nil/unknown. A bare language ("French") yields a language-only
    /// locale ("fr"); `bestSupported` adds the region later.
    nonisolated static func candidateLocale(forBookLanguage language: String?, fallback: Locale) -> Locale {
        guard let language else { return fallback }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let key = trimmed.lowercased()
        if let code = languageTable[key] { return Locale(identifier: code) }

        // An identifier such as "en-GB", "en_gb", "eng-GB" or "zh-Hans": map the language
        // part through the table and re-case the script/region parts.
        let parts = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard parts.count > 1, let code = languageTable[parts[0].lowercased()] else { return fallback }
        var rebuilt = [code]
        for part in parts.dropFirst() {
            switch part.count {
            case 4: rebuilt.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
            case 2: rebuilt.append(part.uppercased())
            default: rebuilt.append(part)
            }
        }
        return Locale(identifier: rebuilt.joined(separator: "-"))
    }

    /// Picks the best match from the transcriber's supported locales: exact identifier, then same language
    /// with the fallback's region, then same language any region (stable order). Nil when no language match.
    ///
    /// Chinese is matched by script as well: `zh-Hans` (or a CN/SG region) prefers a `zh-CN`
    /// style locale and `zh-Hant` (TW/HK/MO) prefers `zh-TW`/`zh-HK`, since the transcriber
    /// lists regions where a book's metadata names scripts.
    nonisolated static func bestSupported(_ candidate: Locale, among supported: [Locale], preferredRegion: String?) -> Locale? {
        let wanted = normalized(candidate.identifier)
        if let exact = supported.first(where: { normalized($0.identifier) == wanted }) { return exact }

        let wantedParts = parts(of: candidate.identifier)
        let language = wantedParts.language
        guard !language.isEmpty else { return nil }
        var pool = supported.filter { parts(of: $0.identifier).language == language }
        guard !pool.isEmpty else { return nil }

        if language == "zh", let variant = chineseVariant(of: wantedParts) {
            let matching = pool.filter { chineseVariant(of: parts(of: $0.identifier)) == variant }
            if !matching.isEmpty { pool = matching }
        }

        for region in [wantedParts.region, preferredRegion?.lowercased()] {
            guard let region, !region.isEmpty else { continue }
            if let match = pool.first(where: { parts(of: $0.identifier).region == region }) {
                return match
            }
        }
        return pool.first
    }

    private enum ChineseVariant { case simplified, traditional }

    /// Language, script and region exactly as written in the identifier. Deliberately not
    /// `Locale.language.script`/`.region`, which fill in likely values ("zh" reads back as
    /// Hans/CN) and would stop a bare "zh" from honouring the preferred region.
    private nonisolated static func parts(of identifier: String) -> (language: String, script: String?, region: String?) {
        let pieces = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let language = pieces.first ?? ""
        var script: String?
        var region: String?
        for piece in pieces.dropFirst() {
            if piece.count == 4, piece.allSatisfy(\.isLetter) { script = piece }
            else if (piece.count == 2 && piece.allSatisfy(\.isLetter)) || (piece.count == 3 && piece.allSatisfy(\.isNumber)) { region = piece }
        }
        return (language, script, region)
    }

    /// Script of a Chinese locale: its explicit script, else implied by its region.
    private nonisolated static func chineseVariant(of parts: (language: String, script: String?, region: String?)) -> ChineseVariant? {
        if parts.script == "hans" { return .simplified }
        if parts.script == "hant" { return .traditional }
        switch parts.region {
        case "cn", "sg": return .simplified
        case "tw", "hk", "mo": return .traditional
        default: return nil
        }
    }

    private nonisolated static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

// MARK: - Segmenting

/// Groups the transcriber's word-level runs into sentence segments with word timing.
enum SegmentBuilder {
    /// Characters that end a sentence, and quotes/brackets that may trail one.
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", "»", ")", "]", "」", "』", "）"]

    private struct Pending {
        var start: Double
        var end: Double
        var text = ""
        var wordStarts: [Float] = []
        var wordOffsets: [Int32] = []
    }

    /// Groups runs into sentence segments in BOOK time (adds `trackOffset`). Splits at sentence-final
    /// punctuation (. ! ? … 。 ！ ？ and closing quotes after them), at a pause > `pauseSplit` seconds,
    /// or when a segment exceeds `maxDuration` seconds. Joins words with a single space unless `spaceless`
    /// (CJK), trims stray whitespace in run text, fills wordStarts (offset from segment start) and
    /// wordOffsets (UTF-16) for each run. Empty/whitespace runs are skipped.
    ///
    /// A punctuation-only run ("," or "." or a closing quote) is glued to the previous word
    /// instead of becoming a word of its own, so word highlighting never lands on a comma.
    nonisolated static func segments(from runs: [TimedRun], trackOffset: Double, spaceless: Bool,
                                     pauseSplit: Double = 1.2, maxDuration: Double = 25) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: Pending?
        // A "." only ends the sentence once the next word confirms it ("Mr. Smith",
        // "J. R. R. Tolkien" and "St. Ives" don't), so the split waits one word.
        var breakPending = false

        func flush() {
            guard let pending = current else { return }
            result.append(TranscriptSegment(
                start: pending.start, end: pending.end, text: pending.text,
                wordStarts: pending.wordStarts, wordOffsets: pending.wordOffsets))
            current = nil
        }

        for run in runs {
            let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = run.start + trackOffset
            let end = max(run.end + trackOffset, start)

            if isPunctuationOnly(text) {
                if current != nil {
                    current!.text += text
                    current!.end = max(current!.end, end)
                } else if !result.isEmpty, text.allSatisfy({ closers.contains($0) }) {
                    // A closing quote that arrived after its sentence was already emitted.
                    result[result.count - 1].text += text
                    result[result.count - 1].end = max(result[result.count - 1].end, end)
                    continue
                } else {
                    current = Pending(start: start, end: end)
                    current!.wordStarts.append(0)
                    current!.wordOffsets.append(0)
                    current!.text = text
                }
            } else {
                if let pending = current {
                    if breakPending, isSentenceBreak(after: pending.text, next: text) {
                        flush()
                    } else if start - pending.end > pauseSplit || end - pending.start > maxDuration {
                        flush()
                    }
                }
                breakPending = false
                if current == nil { current = Pending(start: start, end: end) }
                if !current!.text.isEmpty, !spaceless { current!.text += " " }
                current!.wordStarts.append(Float(max(0, start - current!.start)))
                current!.wordOffsets.append(Int32(current!.text.utf16.count))
                current!.text += text
                current!.end = max(current!.end, end)
            }

            if let pending = current, endsSentence(pending.text) {
                if endsWithAmbiguousPeriod(pending.text) {
                    breakPending = true
                } else {
                    flush()
                }
            }
        }
        flush()
        return result
    }

    /// True for locales whose script is written without spaces (zh, ja, th, lo, km, my).
    nonisolated static func isSpaceless(localeIdentifier: String) -> Bool {
        let language = localeIdentifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { $0.lowercased() } ?? ""
        return ["zh", "ja", "th", "lo", "km", "my", "yue"].contains(language)
    }

    /// True when `text` is nothing but punctuation (a "," or "." or a quote mark).
    private nonisolated static func isPunctuationOnly(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    /// Lowercased abbreviations (without their ".") that don't end a sentence.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "st", "sr", "jr", "mt", "ft", "vs", "etc", "no", "vol",
        "ch", "fig", "gen", "col", "capt", "lt", "sgt", "rev", "hon", "gov", "sen", "rep", "pres",
        "approx", "dept", "est", "inc", "ltd", "co", "corp", "ave", "rd", "blvd", "e.g", "i.e", "a.m", "p.m"
    ]

    /// True when the text ends in "." (possibly followed by closing quotes), the one terminator
    /// that's also used for abbreviations, initials and numbers.
    private nonisolated static func endsWithAmbiguousPeriod(_ text: String) -> Bool {
        let trimmed = text.reversed().drop { closers.contains($0) }
        return trimmed.first == "."
    }

    /// Decides whether a pending "." ends the sentence, now that the next word is known.
    /// Not a break after a known abbreviation or a single-letter initial, or before a word
    /// that starts in lowercase or with a digit; otherwise Apple's sentence tokenizer has the
    /// final say, which catches the abbreviations the list doesn't.
    nonisolated static func isSentenceBreak(after text: String, next: String) -> Bool {
        let lastWord = text.split(whereSeparator: { $0 == " " }).last.map(String.init) ?? text
        var token = lastWord.lowercased()
        while let last = token.last, closers.contains(last) || last == "." { token.removeLast() }
        token = String(token.drop { "\"'\u{201C}\u{2018}(«[".contains($0) })
        if abbreviations.contains(token) { return false }
        if token.count == 1, token.first?.isLetter == true { return false }
        if let first = next.first(where: { !"\"'\u{201C}\u{2018}(«[".contains($0) }),
           first.isLowercase || first.isNumber {
            return false
        }
        let joined = text + " " + next
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = joined
        let boundary = joined.index(joined.startIndex, offsetBy: text.count)
        var splits = false
        tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
            if range.upperBound >= boundary, range.lowerBound <= boundary {
                splits = range.upperBound <= joined.index(after: boundary)
                return false
            }
            return true
        }
        return splits
    }

    /// True when `text` ends in sentence-final punctuation, ignoring closing quotes after it.
    private nonisolated static func endsSentence(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let before = text.index(before: index)
            let ch = text[before]
            if closers.contains(ch) { index = before; continue }
            return terminators.contains(ch)
        }
        return false
    }
}

// MARK: - Resume / restart

/// Decisions about an existing, possibly partial, transcript.
enum TranscriptionPlan {
    /// Where to resume: the first track not in completedTracks (respecting `partial` for that track),
    /// or nil when complete.
    nonisolated static func resumePoint(for transcript: Transcript) -> PartialProgress? {
        let done = Set(transcript.completedTracks)
        guard transcript.trackCount > 0,
              let index = (0..<transcript.trackCount).first(where: { !done.contains($0) }) else { return nil }
        if let partial = transcript.partial, partial.trackIndex == index {
            return PartialProgress(trackIndex: index, secondsInTrack: max(0, partial.secondsInTrack))
        }
        return PartialProgress(trackIndex: index, secondsInTrack: 0)
    }

    /// True when an existing transcript must be thrown away: older version, different audioSignature,
    /// different trackCount, or a different locale than `localeIdentifier`.
    nonisolated static func mustRestart(_ existing: Transcript, audioSignature: String, trackCount: Int,
                                        localeIdentifier: String) -> Bool {
        func normalize(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-").lowercased() }
        return existing.version != Transcript.currentVersion
            || existing.audioSignature != audioSignature
            || existing.trackCount != trackCount
            || normalize(existing.localeIdentifier) != normalize(localeIdentifier)
    }

    /// Appends new segments (book time) keeping `segments` sorted and dropping any existing segment that
    /// starts at or after the first new segment's start (re-transcribed overlap after a resume).
    /// Returns the transcript unchanged when `new` is empty; otherwise stamps `updatedAt`.
    nonisolated static func appending(_ new: [TranscriptSegment], to transcript: Transcript) -> Transcript {
        guard let firstStart = new.map(\.start).min() else { return transcript }
        var updated = transcript
        let kept = transcript.segments.filter { $0.start < firstStart }
        updated.segments = (kept + new).sorted { $0.start < $1.start }
        updated.updatedAt = Date()
        return updated
    }
}

// MARK: - Listening frontier

/// How much of the book the listener has already heard. Transcription is only worth
/// showing (and spoiler-safe to search) up to this point.
enum ListeningFrontier {
    /// How far the listener has heard: the max of the stored high-water mark, server progress time and the
    /// live position (nils/non-finite ignored, never negative).
    nonisolated static func frontier(storedHighWater: Double?, progressTime: Double?, currentTime: Double?) -> Double {
        [storedHighWater, progressTime, currentTime]
            .compactMap { $0 }
            .filter { $0.isFinite }
            .reduce(0) { max($0, $1) }
    }
}

// MARK: - Overnight scheduling

/// Whether the overnight transcription task should do work right now.
enum TranscriptionScheduleDecision: Equatable {
    case run, skipDisabled, skipNotCharging, skipLowPower, skipThermal, skipNothingToDo

    /// Thermal .serious/.critical skip; .nominal/.fair run. Precedence: disabled, nothing to do, not charging,
    /// low power, thermal.
    nonisolated static func overnight(enabled: Bool, isCharging: Bool, lowPowerMode: Bool,
                                      thermalState: ProcessInfo.ThermalState, pendingCount: Int) -> TranscriptionScheduleDecision {
        if !enabled { return .skipDisabled }
        if pendingCount <= 0 { return .skipNothingToDo }
        if !isCharging { return .skipNotCharging }
        if lowPowerMode { return .skipLowPower }
        switch thermalState {
        case .serious, .critical: return .skipThermal
        default: return .run
        }
    }
}
