import Foundation

/// Batch 429: pure planning for X-Ray and Ask the Book (Section F part 2): entity merging across chunk notes,
/// passage building, BM25 retrieval, Ask context packing, prompt text and citation parsing. No I/O, no
/// FoundationModels; unit-tested in `BookKnowledgePlanningTests`.

// MARK: - X-Ray

/// One person/place/term across the whole heard book.
nonisolated struct XRayEntry: Equatable, Sendable, Identifiable {
    /// Normalised key.
    var id: String
    /// Display name: the most frequent spelling, ties go to the longest.
    var name: String
    /// Majority kind across mentions, ties go person > place > term.
    var kind: NoteEntityKind
    /// Distinct notes, oldest first, at most 4.
    var notes: [String]
    /// Start of the first chunk that names it (book seconds).
    var firstMention: Double
    /// Chunks naming it.
    var mentionCount: Int
    /// Batch 432: every spelling merged into this entry, most frequent first (ties longest, then A-Z), at most
    /// `EntityMerger.maxAliases`. The detail page searches the transcript for all of them.
    var aliases: [String] = []
    /// Batch 432: every distinct note, oldest first, at most `EntityMerger.maxAllNotes`. `notes` is the first
    /// `maxNotes` of these; the profile prompt uses the whole list.
    var allNotes: [String] = []
}

nonisolated enum EntityMerger {
    nonisolated static let maxNotes = 4
    nonisolated static let maxAliases = 6
    nonisolated static let maxAllNotes = 30

    /// Normalised key: case- and diacritic-folded, trimmed, internal whitespace collapsed, a leading article
    /// ("the ", "a ", "an ") and a trailing possessive "'s" removed. CJK is unchanged except trimming.
    nonisolated static func key(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for article in ["the ", "an ", "a "] where s.hasPrefix(article) {
            let rest = String(s.dropFirst(article.count))
            if !rest.isEmpty { s = rest }
            break
        }
        if s.hasSuffix("'s") {
            let rest = String(s.dropLast(2))
            if !rest.isEmpty { s = rest }
        }
        return s
    }

    private struct Accumulator {
        var spellings: [String: Int] = [:]
        var kinds: [NoteEntityKind: Int] = [:]
        var notes: [(start: Double, text: String)] = []
        var chunks: Set<Int> = []
        var first: Double = .infinity

        mutating func absorb(_ other: Accumulator) {
            for (k, v) in other.spellings { spellings[k, default: 0] += v }
            for (k, v) in other.kinds { kinds[k, default: 0] += v }
            notes += other.notes
            chunks.formUnion(other.chunks)
            first = min(first, other.first)
        }
    }

    /// Merges entities across notes (only notes with `end <= frontier`). Also merges a single-word name into a
    /// multi-word entry when it equals that entry's first or last word AND exactly one multi-word entry matches
    /// ("Holden" into "James Holden"; "James" with both "James Holden" and "James Bond" stays separate).
    /// Sorted: kind order person, place, term; then mentionCount desc; then name.
    nonisolated static func merge(_ notes: [ChunkNotes], frontier: Double) -> [XRayEntry] {
        let heard = notes.filter { $0.end <= frontier }
            .sorted { ($0.start, $0.chunkIndex) < ($1.start, $1.chunkIndex) }
        var acc: [String: Accumulator] = [:]
        for note in heard {
            for entity in note.entities {
                let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let k = key(name)
                if k.isEmpty { continue }
                var a = acc[k] ?? Accumulator()
                a.spellings[name, default: 0] += 1
                a.kinds[entity.kind, default: 0] += 1
                let text = entity.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { a.notes.append((note.start, text)) }
                a.chunks.insert(note.chunkIndex)
                a.first = min(a.first, note.start)
                acc[k] = a
            }
        }

        // Single-word names fold into the one multi-word entry they match.
        let keys = acc.keys.sorted()
        let multi = keys.filter { $0.contains(" ") }
        for single in keys where !single.contains(" ") {
            let matches = multi.filter { m in
                let words = m.split(separator: " ")
                return words.first.map(String.init) == single || words.last.map(String.init) == single
            }
            guard matches.count == 1, let target = matches.first, let moving = acc[single] else { continue }
            acc[target]?.absorb(moving)
            acc[single] = nil
        }

        let order = NoteEntityKind.allCases
        var entries: [XRayEntry] = []
        for (k, a) in acc {
            let spellings = a.spellings.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
                return $0.key < $1.key
            }.map(\.key)
            let name = spellings.first ?? k
            let kind = order.max { l, r in
                let lc = a.kinds[l] ?? 0, rc = a.kinds[r] ?? 0
                if lc != rc { return lc < rc }
                return order.firstIndex(of: l)! > order.firstIndex(of: r)!
            } ?? .term
            var seen = Set<String>()
            var texts: [String] = []
            let sortedNotes = a.notes.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            for (_, n) in sortedNotes {
                let folded = n.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if seen.insert(folded).inserted { texts.append(n.text) }
                if texts.count == maxAllNotes { break }
            }
            entries.append(XRayEntry(id: k, name: name, kind: kind, notes: Array(texts.prefix(maxNotes)),
                                     firstMention: a.first, mentionCount: a.chunks.count,
                                     aliases: Array(spellings.prefix(maxAliases)), allNotes: texts))
        }
        return entries.sorted {
            let lk = order.firstIndex(of: $0.kind)!, rk = order.firstIndex(of: $1.kind)!
            if lk != rk { return lk < rk }
            if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }
}

// MARK: - X-Ray detail (Batch 432)

/// One transcript segment that names an X-Ray entry.
nonisolated struct XRayMention: Equatable, Sendable, Identifiable {
    var id: Int { segmentIndex }
    var segmentIndex: Int
    /// Book time the segment starts (what a tap seeks to).
    var time: Double
    var snippet: String
}

nonisolated enum XRayMentionFinder {
    /// Hits asked of the search per spelling.
    nonisolated static let perTermLimit = 200

    /// What is searched for: the display name, every alias and the normalised key, de-duplicated ignoring case
    /// and accents (the search is case- and accent-insensitive anyway), in that order.
    nonisolated static func searchTerms(for entry: XRayEntry) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in [entry.name] + entry.aliases + [entry.id] {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if !term.isEmpty, seen.insert(folded).inserted { terms.append(term) }
        }
        return terms
    }

    /// Segments naming the entry under any of its spellings, at or before `frontier` (never ahead), unioned
    /// by segment index and returned in book order.
    nonisolated static func mentions(for entry: XRayEntry, in index: TranscriptSearchIndex,
                                     frontier: Double) -> [XRayMention] {
        var byIndex: [Int: XRayMention] = [:]
        for term in searchTerms(for: entry) {
            let result = TranscriptSearch.search(term, in: index, frontier: frontier, includeAhead: false,
                                                 limit: perTermLimit)
            for hit in result.hits where hit.time <= frontier && byIndex[hit.segmentIndex] == nil {
                byIndex[hit.segmentIndex] = XRayMention(segmentIndex: hit.segmentIndex, time: hit.time,
                                                        snippet: hit.snippet)
            }
        }
        return byIndex.values.sorted { $0.segmentIndex < $1.segmentIndex }
    }
}

nonisolated enum XRayProfilePlanner {
    /// Character budgets for the prompt body, sized for the 4,096-token context (spaced scripts about four
    /// characters a token, spaceless one), leaving room for instructions and the answer.
    nonisolated static let spacedBudgetChars = 6_000
    nonisolated static let spacelessBudgetChars = 2_200
    /// One passage is cut to this many characters.
    nonisolated static let maxSnippetChars = 240
    /// Most passages ever sent.
    nonisolated static let maxPassages = 40
    nonisolated static let headCount = 3
    nonisolated static let tailCount = 3

    nonisolated static func budgetChars(spaceless: Bool) -> Int {
        spaceless ? spacelessBudgetChars : spacedBudgetChars
    }

    /// `count` indices out of `0..<total`, ascending: the first `headCount` and the last `tailCount` always
    /// (when `count` allows; the head wins a short count), the rest evenly spaced between them. All of them
    /// when `count >= total`.
    nonisolated static func sampleIndices(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        if count >= total { return Array(0..<total) }
        let head = min(headCount, count)
        let tail = min(tailCount, count - head)
        let middle = count - head - tail
        var result = Array(0..<head)
        if middle > 0 {
            let span = total - head - tail
            for k in 0..<middle { result.append(head + (2 * k + 1) * span / (2 * middle)) }
        }
        result.append(contentsOf: (total - tail)..<total)
        return result
    }

    /// Up to `limit` mentions sampled across the whole list (for the detail page's list).
    nonisolated static func sample(_ mentions: [XRayMention], limit: Int) -> [XRayMention] {
        sampleIndices(total: mentions.count, count: limit).map { mentions[$0] }
    }

    private nonisolated static func clipped(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        return flat.count > maxSnippetChars ? String(flat.prefix(maxSnippetChars)) + "\u{2026}" : flat
    }

    /// The model prompt: name, kind and other spellings; the distinct notes (until a third of the budget is
    /// used); then "(time) passage" lines sampled across the heard book, as many as the rest of the budget
    /// holds (first and most recent always kept, the rest evenly spaced).
    nonisolated static func prompt(entry: XRayEntry, mentions: [XRayMention], spaceless: Bool) -> String {
        let budget = budgetChars(spaceless: spaceless)
        var lines = ["Name: \(entry.name)", "Kind: \(entry.kind.rawValue)"]
        let others = entry.aliases.filter { $0 != entry.name }
        if !others.isEmpty { lines.append("Also written as: " + others.joined(separator: ", ")) }
        var used = lines.reduce(0) { $0 + $1.count + 1 }

        var noteLines: [String] = []
        var noteChars = 0
        for note in entry.allNotes {
            let line = "- " + clipped(note)
            if noteChars + line.count + 1 > budget / 3 { break }
            noteLines.append(line)
            noteChars += line.count + 1
        }
        if !noteLines.isEmpty {
            lines.append("")
            lines.append("Notes from the parts heard so far, oldest first:")
            lines.append(contentsOf: noteLines)
            used += noteChars + 52
        }

        let remaining = budget - used
        let formatted = mentions.map { "(\(RecapPlanner.timestamp($0.time))) " + clipped($0.snippet) }
        var count = min(maxPassages, formatted.count)
        var chosen: [Int] = []
        while count > 0 {
            let indices = sampleIndices(total: formatted.count, count: count)
            if indices.reduce(0, { $0 + formatted[$1].count + 1 }) <= remaining {
                chosen = indices
                break
            }
            count -= 1
        }
        if !chosen.isEmpty {
            lines.append("")
            lines.append("Passages that name it, in book order:")
            lines.append(contentsOf: chosen.map { formatted[$0] })
        }
        return lines.joined(separator: "\n")
    }

    /// Cache key for a profile: `NotesCache.hash` of the whole prompt, so new mentions, new notes or a
    /// different budget regenerate it.
    nonisolated static func inputHash(_ prompt: String) -> String { NotesCache.hash(prompt) }
}

/// Batch 432: profiles written for X-Ray detail pages, cached in `xray.json` beside `notes.json`.
nonisolated struct XRayProfileCache: Codable, Equatable, Sendable {
    nonisolated static let currentVersion = 1
    nonisolated static let capacity = 200

    struct Record: Codable, Equatable, Sendable {
        var id: String
        var hash: String
        var text: String
    }

    var version: Int
    var itemId: String
    var localeIdentifier: String
    /// Oldest first.
    var records: [Record]

    nonisolated static func empty(itemId: String, localeIdentifier: String) -> XRayProfileCache {
        XRayProfileCache(version: currentVersion, itemId: itemId, localeIdentifier: localeIdentifier, records: [])
    }

    /// The stored profile for `id` when it was made from the same input; nil otherwise (or on another version).
    func profile(for id: String, hash: String) -> String? {
        guard version == Self.currentVersion else { return nil }
        return records.first { $0.id == id && $0.hash == hash }?.text
    }

    /// Replaces any record for `id`, appends, and drops the oldest beyond `capacity`.
    mutating func store(id: String, hash: String, text: String) {
        records.removeAll { $0.id == id }
        records.append(Record(id: id, hash: hash, text: text))
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }
}

// MARK: - Passages

/// A retrievable passage for Ask.
nonisolated struct Passage: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

nonisolated enum PassageBuilder {
    /// Groups consecutive segments (ending at or before `frontier`) into passages of about `targetTokens`
    /// (default 220), never splitting a segment: a segment that would push a non-empty passage past the target
    /// starts the next one. Blank segments are skipped.
    nonisolated static func passages(segments: [TranscriptSegment], frontier: Double, spaceless: Bool,
                                     targetTokens: Int = 220) -> [Passage] {
        var result: [Passage] = []
        var texts: [String] = []
        var start = 0.0
        var end = 0.0
        var used = 0
        func flush() {
            guard !texts.isEmpty else { return }
            result.append(Passage(start: start, end: end, text: texts.joined(separator: spaceless ? "" : " ")))
            texts = []
            used = 0
        }
        for seg in segments where seg.end <= frontier {
            if seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let cost = TokenEstimate.tokens(seg.text, spaceless: spaceless)
            if !texts.isEmpty && used + cost > targetTokens { flush() }
            if texts.isEmpty { start = seg.start }
            texts.append(seg.text)
            end = seg.end
            used += cost
        }
        flush()
        return result
    }
}

// MARK: - BM25

nonisolated enum BM25 {
    nonisolated static let k1 = 1.2
    nonisolated static let b = 0.75

    nonisolated static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those",
        "he", "she", "they", "we", "you", "i", "his", "her", "their", "our", "your", "my", "me", "him", "them",
        "as", "what", "who", "whom", "which", "when", "where", "why", "how", "did", "do", "does",
        "not", "no", "if", "so", "than", "then", "there", "about", "has", "have", "had", "will", "would",
        "can", "could"
    ]

    /// Han, Hiragana, Katakana and Hangul (mirrors the transcript search's spaceless scripts).
    nonisolated static func isSpaceless(_ sc: Unicode.Scalar) -> Bool {
        switch sc.value {
        case 0x1100...0x11FF, 0x3005...0x3007, 0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFF66...0xFF9F, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    /// Lowercased, diacritic-folded word tokens for spaced scripts (stopwords and single letters dropped;
    /// apostrophes split words); for CJK, character bigrams, plus the single character for a 1-char run.
    nonisolated static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out: [String] = []
        var word = String.UnicodeScalarView()
        var run: [Unicode.Scalar] = []

        func flushWord() {
            defer { word = String.UnicodeScalarView() }
            let s = String(word)
            if s.isEmpty || stopwords.contains(s) { return }
            if s.unicodeScalars.count == 1, let sc = s.unicodeScalars.first,
               !CharacterSet.decimalDigits.contains(sc) { return }
            out.append(s)
        }
        func flushRun() {
            defer { run = [] }
            if run.count == 1 {
                out.append(String(Character(run[0])))
            } else if run.count > 1 {
                for i in 0..<(run.count - 1) {
                    var v = String.UnicodeScalarView()
                    v.append(run[i])
                    v.append(run[i + 1])
                    out.append(String(v))
                }
            }
        }

        for sc in folded.unicodeScalars {
            if isSpaceless(sc) {
                flushWord()
                run.append(sc)
            } else if CharacterSet.alphanumerics.contains(sc) || CharacterSet.nonBaseCharacters.contains(sc) {
                flushRun()
                word.append(sc)
            } else {
                flushWord()
                flushRun()
            }
        }
        flushWord()
        flushRun()
        return out
    }

    /// Okapi BM25 (k1 1.2, b 0.75; idf = ln(1 + (N - n + 0.5) / (n + 0.5)) so scores stay positive). Returns the
    /// indices of `documents` with score > 0, best first (ties by lower index), at most `k`.
    nonisolated static func rank(query: String, documents: [String], k: Int) -> [Int] {
        guard k > 0, !documents.isEmpty else { return [] }
        var queryTokens: [String] = []
        var seenQuery = Set<String>()
        for t in tokens(query) where seenQuery.insert(t).inserted { queryTokens.append(t) }
        guard !queryTokens.isEmpty else { return [] }

        let docs = documents.map { tokens($0) }
        let n = Double(docs.count)
        let avg = max(1.0, Double(docs.reduce(0) { $0 + $1.count }) / n)
        let counts: [[String: Int]] = docs.map { d in
            var c: [String: Int] = [:]
            for t in d { c[t, default: 0] += 1 }
            return c
        }
        var idf: [String: Double] = [:]
        for q in queryTokens {
            let df = Double(counts.reduce(0) { $0 + ($1[q] != nil ? 1 : 0) })
            idf[q] = log(1 + (n - df + 0.5) / (df + 0.5))
        }
        var scored: [(index: Int, score: Double)] = []
        for (i, c) in counts.enumerated() {
            let len = Double(docs[i].count)
            var score = 0.0
            for q in queryTokens {
                guard let f = c[q].map(Double.init) else { continue }
                score += (idf[q] ?? 0) * f * (k1 + 1) / (f + k1 * (1 - b + b * len / avg))
            }
            if score > 0 { scored.append((i, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(k).map(\.index)
    }
}

// MARK: - Ask

nonisolated enum AskPlanner {
    /// Maximum note summaries added beside the best passage.
    nonisolated static let maxNoteSummaries = 2

    /// The context for one question. Passages are ranked with BM25 over their text; best first they are added
    /// while the running `TokenEstimate` total fits `budgetTokens` (one that doesn't fit is skipped, not a
    /// stop). Right after the best-ranked passage that fits, up to 2 chunk-note summaries overlapping it
    /// (`note.start < end && note.end > start`, earliest first) are added as extra `Passage`s carrying the
    /// note's start/end and summary, counted in the same budget. Callers pass heard notes only. The result is
    /// in book order (start, then end, then pick order). Empty when no passage matches the question.
    nonisolated static func context(question: String, passages: [Passage], notes: [ChunkNotes], spaceless: Bool,
                                    budgetTokens: Int = 2_600) -> [Passage] {
        let ranked = BM25.rank(query: question, documents: passages.map(\.text), k: passages.count)
        var picked: [Passage] = []
        var used = 0
        var addedNotes = false
        for index in ranked {
            let p = passages[index]
            let cost = TokenEstimate.tokens(p.text, spaceless: spaceless)
            if used + cost > budgetTokens { continue }
            used += cost
            picked.append(p)
            if !addedNotes {
                addedNotes = true
                let overlapping = notes
                    .filter { $0.start < p.end && $0.end > p.start }
                    .sorted { ($0.start, $0.chunkIndex) < ($1.start, $1.chunkIndex) }
                    .prefix(maxNoteSummaries)
                for note in overlapping {
                    let summary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if summary.isEmpty { continue }
                    let c = TokenEstimate.tokens(summary, spaceless: spaceless)
                    if used + c > budgetTokens { continue }
                    used += c
                    picked.append(Passage(start: note.start, end: note.end, text: summary))
                }
            }
        }
        return picked.enumerated().sorted {
            let a = $0.element, b = $1.element
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// Prompt: "Book:" line, "Author:" line when there is one, blank line, then "[n] (time) text" per passage
    /// (n 1-based, what the model cites; time via `RecapPlanner.timestamp`, so m:ss under an hour and h:mm:ss
    /// from an hour), blank line, "Question: ...".
    nonisolated static func prompt(title: String, author: String, question: String, context: [Passage]) -> String {
        var lines = ["Book: \(title)"]
        if !author.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Author: \(author)") }
        lines.append("")
        for (i, p) in context.enumerated() {
            lines.append("[\(i + 1)] (\(RecapPlanner.timestamp(p.start))) \(p.text)")
        }
        lines.append("")
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    private nonisolated static let markerPattern = #"\[\s*(\d+(?:\s*[,;]\s*\d+)*)\s*\]"#

    /// Citations in the answer: "[3]" or "[1, 4]" become 0-based passage indices, deduped, in order of
    /// appearance, out-of-range dropped.
    nonisolated static func citations(in answer: String, passageCount: Int) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return [] }
        let ns = answer as NSString
        var result: [Int] = []
        for m in regex.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            for part in inner.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                guard let n = Int(part.trimmingCharacters(in: .whitespaces)),
                      n >= 1, n <= passageCount else { continue }
                if !result.contains(n - 1) { result.append(n - 1) }
            }
        }
        return result
    }

    /// The answer with citation markers (and the space before each) removed, repeated spaces collapsed, trimmed.
    nonisolated static func displayText(_ answer: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[ \t]*"# + markerPattern),
              let spaces = try? NSRegularExpression(pattern: #"[ \t]{2,}"#) else { return answer }
        var s = regex.stringByReplacingMatches(in: answer, range: NSRange(location: 0, length: (answer as NSString).length),
                                               withTemplate: "")
        s = spaces.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
