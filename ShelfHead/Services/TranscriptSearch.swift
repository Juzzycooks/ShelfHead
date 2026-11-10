import Foundation

// Batch 424: "search inside the audio". Pure, Foundation-only matching over a
// `Transcript`'s segments. Nothing here touches I/O, the main actor or UI.
//
// Complexity (n = total folded UTF-16 units across the book, m = query length):
//   * `TranscriptSearchIndex.init`: O(total text), once per transcript. Folding is done per
//     grapheme with an ASCII fast path and a per-index cache for everything else.
//   * One query: O(n * m) worst case, near O(n) in practice (a first-unit check rejects most
//     positions). Segment text is never re-folded per query; snippets and highlights are only
//     built for the hits that are actually returned.
//
// Matching rules (the brief left these to us):
//   * Folding: case, diacritic and width insensitive (fixed POSIX locale). Apostrophes and
//     modifier-apostrophes are dropped ("don't" == "don’t" == "dont"); every other run of
//     punctuation or whitespace collapses to one separator, so "wait, what?" == "wait what".
//     Kana and Hangul skip the diacritic strip (it would turn が into か).
//   * Spaced scripts: the query is split into words. Tier 1 is a contiguous phrase starting
//     on a word boundary where every word but the last must be a whole word and the last may
//     be a prefix ("old lightho" matches "the old lighthouse"). The phrase may also run from
//     a segment into the immediately following one (reported on the first segment). Tier 2:
//     every word is present as a word PREFIX, in order and close together. Tier 3: every
//     word present as a word prefix anywhere in the segment.
//   * Spaceless scripts (query has Han/Kana/Hangul): whitespace is ignored on both sides and
//     the query is a substring match against the segment's folded text. Mixed queries
//     ("第4章 Harry") take this path too. Also allowed to cross into the next segment.

// MARK: - Index

/// A transcript prepared for repeated queries: folded text per segment plus a map back to the original
/// UTF-16 offsets. Build once per transcript (off the main actor for big books), query on every keystroke.
nonisolated struct TranscriptSearchIndex: Sendable {
    let itemId: String
    let segmentCount: Int

    /// Folded text of every segment, concatenated with a single space between segments.
    fileprivate let units: [UInt16]
    /// For each folded unit, the UTF-16 range [start, end) of the original grapheme it came from.
    fileprivate let origStart: [Int32]
    fileprivate let origEnd: [Int32]
    /// Range of each segment inside `units` (end exclusive).
    fileprivate let segStart: [Int]
    fileprivate let segEnd: [Int]
    fileprivate let times: [Double]
    fileprivate let texts: [String]

    init(transcript: Transcript) {
        self.init(itemId: transcript.itemId, segments: transcript.segments)
    }

    init(itemId: String, segments: [TranscriptSegment]) {
        var buf = FoldBuffer()
        let estimate = segments.reduce(0) { $0 + $1.text.utf16.count + 1 }
        buf.units.reserveCapacity(estimate)
        buf.starts.reserveCapacity(estimate)
        buf.ends.reserveCapacity(estimate)
        var cache: [Character: [UInt16]] = [:]
        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(segments.count)
        ends.reserveCapacity(segments.count)
        for (i, segment) in segments.enumerated() {
            if i > 0 {
                buf.units.append(0x20)
                buf.starts.append(0)
                buf.ends.append(0)
            }
            let s = buf.units.count
            TranscriptFolding.fold(segment.text, into: &buf, cache: &cache)
            starts.append(s)
            ends.append(buf.units.count)
        }
        self.itemId = itemId
        self.segmentCount = segments.count
        self.units = buf.units
        self.origStart = buf.starts
        self.origEnd = buf.ends
        self.segStart = starts
        self.segEnd = ends
        self.times = segments.map { $0.start }
        self.texts = segments.map { $0.text }
    }
}

// MARK: - Results

nonisolated struct TranscriptSearchHit: Equatable, Sendable, Identifiable {
    var id: Int { segmentIndex }
    let segmentIndex: Int
    let time: Double                 // book time to seek to: the segment's start
    let score: Double                // higher is better
    let snippet: String              // display text: the segment (plus a little context), trimmed with "…"
    let highlights: [NSRange]        // UTF-16 ranges inside `snippet` to emphasise
}

nonisolated struct TranscriptSearchResults: Equatable, Sendable {
    let hits: [TranscriptSearchHit]  // in BOOK ORDER (ascending time), capped at `limit`
    let hiddenAheadCount: Int        // matches past the frontier left out (0 when includeAhead)
    let isTruncated: Bool            // more than `limit` matches existed
    nonisolated static let empty = TranscriptSearchResults(hits: [], hiddenAheadCount: 0, isTruncated: false)
}

// MARK: - Public API

enum TranscriptSearch {
    nonisolated static let defaultLimit = 200

    /// Minimum query: 2 non-whitespace characters for spaced scripts, 1 Han/Kana/Hangul character.
    nonisolated static func isSearchable(_ query: String) -> Bool {
        var count = 0
        for ch in query where !ch.isWhitespace {
            if ch.unicodeScalars.contains(where: TranscriptFolding.isSpacelessScalar) { return true }
            count += 1
            if count >= 2 { return true }
        }
        return false
    }

    nonisolated static func search(_ query: String, in index: TranscriptSearchIndex,
                                   frontier: Double?, includeAhead: Bool,
                                   limit: Int = defaultLimit) -> TranscriptSearchResults {
        guard isSearchable(query), index.segmentCount > 0,
              let prepared = TranscriptMatcher.prepare(query) else { return .empty }
        let matches = TranscriptMatcher.matches(prepared, in: index)
        guard !matches.isEmpty else { return .empty }

        let cap = max(0, limit)
        var kept: [TranscriptMatcher.SegmentMatch] = []
        var hidden = 0
        var truncated = false
        for m in matches {
            if !includeAhead, let f = frontier, index.times[m.segment] > f {
                hidden += 1
                continue
            }
            if kept.count < cap { kept.append(m) } else { truncated = true }
        }
        let hits = kept.map { TranscriptMatcher.hit(for: $0, query: prepared, in: index) }
        return TranscriptSearchResults(hits: hits, hiddenAheadCount: hidden, isTruncated: truncated)
    }

    /// Siri's pick: the highest-scoring hit at or before `before` (nil = anywhere); ties → the one closest
    /// before `before` (latest). Ignores the limit's book-order cap (scores all matches).
    nonisolated static func bestMatch(_ query: String, in index: TranscriptSearchIndex,
                                      before: Double?) -> TranscriptSearchHit? {
        guard isSearchable(query), index.segmentCount > 0,
              let prepared = TranscriptMatcher.prepare(query) else { return nil }
        var best: TranscriptMatcher.SegmentMatch?
        for m in TranscriptMatcher.matches(prepared, in: index) {
            if let b = before, index.times[m.segment] > b { continue }
            // Matches ascend in time, so `>=` lets a later equal score win the tie.
            if best == nil || m.score >= best!.score { best = m }
        }
        guard let best else { return nil }
        return TranscriptMatcher.hit(for: best, query: prepared, in: index)
    }
}

// MARK: - Folding

private nonisolated struct FoldBuffer {
    var units: [UInt16] = []
    var starts: [Int32] = []
    var ends: [Int32] = []

    /// Appends one folded unit. Separators never lead a segment and never repeat.
    mutating func push(_ unit: UInt16, _ s: Int32, _ e: Int32, floor: Int) {
        if unit == 0x20 {
            guard units.count > floor, units[units.count - 1] != 0x20 else { return }
        }
        units.append(unit)
        starts.append(s)
        ends.append(e)
    }

    mutating func trimTrailingSeparator(floor: Int) {
        if units.count > floor, units[units.count - 1] == 0x20 {
            units.removeLast()
            starts.removeLast()
            ends.removeLast()
        }
    }
}

private nonisolated enum TranscriptFolding {
    static let posix = Locale(identifier: "en_US_POSIX")

    enum Kind { case keep, drop, separator }

    /// Folds `text` onto the end of `buf`, recording for every folded unit the UTF-16 range of the
    /// original grapheme it came from. Folding can change length (ß → ss, combining marks vanish),
    /// so the map is built per Character, never by assuming equal lengths.
    static func fold(_ text: String, into buf: inout FoldBuffer, cache: inout [Character: [UInt16]]) {
        let floor = buf.units.count
        var offset: Int32 = 0
        for ch in text {
            let s = offset
            let e = offset + Int32(ch.utf16.count)
            offset = e
            if let a = ch.asciiValue {
                switch a {
                case 0x41...0x5A: buf.push(UInt16(a + 32), s, e, floor: floor)
                case 0x61...0x7A, 0x30...0x39: buf.push(UInt16(a), s, e, floor: floor)
                case 0x27, 0x60: break   // apostrophe, backtick: dropped so "don't" == "dont"
                default: buf.push(0x20, s, e, floor: floor)
                }
                continue
            }
            let folded: [UInt16]
            if let cached = cache[ch] {
                folded = cached
            } else {
                folded = foldGrapheme(ch)
                cache[ch] = folded
            }
            for u in folded { buf.push(u, s, e, floor: floor) }
        }
        buf.trimTrailingSeparator(floor: floor)
    }

    static func foldGrapheme(_ ch: Character) -> [UInt16] {
        let spaceless = ch.unicodeScalars.contains(where: isSpacelessScalar)
        let options: String.CompareOptions = spaceless
            ? [.caseInsensitive, .widthInsensitive]
            : [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let folded = String(ch).folding(options: options, locale: posix)
        var out: [UInt16] = []
        for sc in folded.unicodeScalars {
            switch classify(sc) {
            case .keep:
                if sc.value < 0x10000 {
                    out.append(UInt16(sc.value))
                } else {
                    let v = sc.value - 0x10000
                    out.append(UInt16(0xD800 + (v >> 10)))
                    out.append(UInt16(0xDC00 + (v & 0x3FF)))
                }
            case .drop:
                break
            case .separator:
                if out.last != 0x20 { out.append(0x20) }
            }
        }
        return out
    }

    static func classify(_ sc: Unicode.Scalar) -> Kind {
        switch sc.value {
        case 0x27, 0x60, 0xB4, 0x2BB, 0x2BC, 0x2018, 0x2019, 0x201B, 0x2032:
            return .drop
        default:
            break
        }
        switch sc.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return .keep
        default:
            return .separator
        }
    }

    /// Han, Hiragana, Katakana and Hangul: scripts searched as whitespace-free substrings.
    static func isSpacelessScalar(_ sc: Unicode.Scalar) -> Bool {
        switch sc.value {
        case 0x1100...0x11FF, 0x3005...0x3007, 0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFF66...0xFF9F, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }
}

// MARK: - Matching

private nonisolated enum PreparedQuery {
    case spaced(words: [[UInt16]], phrase: [UInt16])
    case spaceless(pattern: [UInt16])
}

private nonisolated enum TranscriptMatcher {
    struct SegmentMatch {
        let segment: Int
        let score: Double
        /// True when the match runs from this segment into the next one.
        let cross: Bool
        /// Folded-unit range of a cross match (valid when `cross`), used for spaceless highlights.
        let crossStart: Int
        let crossEnd: Int
    }

    static let shortSegmentLength = 60
    static let maxSnippetLength = 160
    static let leadContext = 40
    static let snapSlack = 24

    // MARK: Query

    static func prepare(_ query: String) -> PreparedQuery? {
        var buf = FoldBuffer()
        var cache: [Character: [UInt16]] = [:]
        TranscriptFolding.fold(query, into: &buf, cache: &cache)
        guard !buf.units.isEmpty else { return nil }
        if query.unicodeScalars.contains(where: TranscriptFolding.isSpacelessScalar) {
            let pattern = buf.units.filter { $0 != 0x20 }
            return pattern.isEmpty ? nil : .spaceless(pattern: pattern)
        }
        let words = buf.units.split(separator: 0x20, omittingEmptySubsequences: true).map { Array($0) }
        guard !words.isEmpty else { return nil }
        return .spaced(words: words, phrase: buf.units)
    }

    // MARK: Scanning primitives

    static func wordEnd(_ units: [UInt16], _ p: Int, _ limit: Int) -> Int {
        var q = p
        while q < limit, units[q] != 0x20 { q += 1 }
        return q
    }

    static func hasPrefix(_ units: [UInt16], at p: Int, limit: Int, pattern: [UInt16]) -> Bool {
        let m = pattern.count
        guard p + m <= limit else { return false }
        for k in 0..<m where units[p + k] != pattern[k] { return false }
        return true
    }

    /// First position in [from, startLimit) where `pattern` starts on a word boundary and matches
    /// (the match must fit inside [from, to)).
    static func findPhrase(_ pattern: [UInt16], _ units: [UInt16], from: Int, to: Int, startLimit: Int) -> Int? {
        let m = pattern.count
        guard m > 0, to - from >= m else { return nil }
        let last = min(startLimit, to - m + 1)
        let first = pattern[0]
        var p = from
        while p < last {
            if units[p] == first, p == from || units[p - 1] == 0x20,
               hasPrefix(units, at: p, limit: to, pattern: pattern) {
                return p
            }
            p += 1
        }
        return nil
    }

    /// First word in [from, to) at or after `after` that begins with `word`.
    static func findWordPrefix(_ word: [UInt16], _ units: [UInt16], from: Int, to: Int, after: Int) -> Int? {
        let m = word.count
        guard m > 0 else { return nil }
        let first = word[0]
        var p = max(from, after)
        while p + m <= to {
            if units[p] == first, p == from || units[p - 1] == 0x20,
               hasPrefix(units, at: p, limit: to, pattern: word) {
                return p
            }
            p += 1
        }
        return nil
    }

    /// Matches `q` starting at `i`, skipping separators in the text. Returns the exclusive end.
    static func compactMatch(_ q: [UInt16], _ units: [UInt16], at i: Int, limit: Int) -> Int? {
        var j = i
        var k = 0
        while k < q.count {
            while j < limit, units[j] == 0x20 { j += 1 }
            guard j < limit, units[j] == q[k] else { return nil }
            j += 1
            k += 1
        }
        return j
    }

    static func findCompact(_ q: [UInt16], _ units: [UInt16], from: Int, to: Int, startLimit: Int) -> (start: Int, end: Int)? {
        guard let first = q.first else { return nil }
        var p = from
        let last = min(startLimit, to)
        while p < last {
            if units[p] == first, let end = compactMatch(q, units, at: p, limit: to) {
                return (p, end)
            }
            p += 1
        }
        return nil
    }

    static func completeness(_ units: [UInt16], wordStart: Int, matched: Int, limit: Int) -> Double {
        let full = wordEnd(units, wordStart, limit) - wordStart
        return full > 0 ? min(1, Double(matched) / Double(full)) : 1
    }

    // MARK: Scoring

    static func matches(_ q: PreparedQuery, in index: TranscriptSearchIndex) -> [SegmentMatch] {
        var out: [SegmentMatch] = []
        for i in 0..<index.segmentCount {
            let m: SegmentMatch?
            switch q {
            case .spaced(let words, let phrase): m = scoreSpaced(i, words: words, phrase: phrase, index: index)
            case .spaceless(let pattern): m = scoreSpaceless(i, pattern: pattern, index: index)
            }
            if let m { out.append(m) }
        }
        return out
    }

    // Tier bases are 30 apart; completeness (0...10) + shortness (0...5) can't cross a tier.
    static func scoreSpaced(_ i: Int, words: [[UInt16]], phrase: [UInt16], index: TranscriptSearchIndex) -> SegmentMatch? {
        let s = index.segStart[i]
        let e = index.segEnd[i]
        guard e > s else { return nil }
        let units = index.units
        let shortness = max(0, 1 - Double(e - s) / 400)
        let lastWord = words[words.count - 1]

        if let p = findPhrase(phrase, units, from: s, to: e, startLimit: e) {
            let c = completeness(units, wordStart: p + phrase.count - lastWord.count, matched: lastWord.count, limit: e)
            return SegmentMatch(segment: i, score: 100 + 10 * c + 5 * shortness, cross: false, crossStart: -1, crossEnd: -1)
        }
        if words.count > 1, i + 1 < index.segmentCount {
            let e2 = index.segEnd[i + 1]
            if e2 > index.segStart[i + 1],
               let p = findPhrase(phrase, units, from: s, to: e2, startLimit: e) {
                let c = completeness(units, wordStart: p + phrase.count - lastWord.count, matched: lastWord.count, limit: e2)
                return SegmentMatch(segment: i, score: 95 + 10 * c + 5 * shortness,
                                    cross: true, crossStart: p, crossEnd: p + phrase.count)
            }
        }
        var firsts: [Int] = []
        firsts.reserveCapacity(words.count)
        var comp = 0.0
        for w in words {
            guard let p = findWordPrefix(w, units, from: s, to: e, after: s) else { return nil }
            firsts.append(p)
            comp += Double(w.count) / Double(max(1, wordEnd(units, p, e) - p))
        }
        comp /= Double(words.count)
        let tier = words.count > 1 && isOrderedNearby(words, units, from: s, to: e, budget: phrase.count + 40) ? 60.0 : 30.0
        return SegmentMatch(segment: i, score: tier + 10 * min(1, comp) + 5 * shortness, cross: false, crossStart: -1, crossEnd: -1)
    }

    /// True when the words occur in order (each starting after the previous word ends) within `budget` units.
    static func isOrderedNearby(_ words: [[UInt16]], _ units: [UInt16], from s: Int, to e: Int, budget: Int) -> Bool {
        var candidate = findWordPrefix(words[0], units, from: s, to: e, after: s)
        while let start = candidate {
            var pos = wordEnd(units, start, e)
            var end = pos
            for w in words.dropFirst() {
                // A later start for the first word only pushes the chain further right, so a miss is final.
                guard let q = findWordPrefix(w, units, from: s, to: e, after: pos) else { return false }
                end = wordEnd(units, q, e)
                pos = end
            }
            if end - start <= budget { return true }
            candidate = findWordPrefix(words[0], units, from: s, to: e, after: start + 1)
        }
        return false
    }

    static func scoreSpaceless(_ i: Int, pattern: [UInt16], index: TranscriptSearchIndex) -> SegmentMatch? {
        let s = index.segStart[i]
        let e = index.segEnd[i]
        guard e > s else { return nil }
        let units = index.units
        let shortness = max(0, 1 - Double(e - s) / 400)
        if findCompact(pattern, units, from: s, to: e, startLimit: e) != nil {
            return SegmentMatch(segment: i, score: 100 + 5 * shortness, cross: false, crossStart: -1, crossEnd: -1)
        }
        if i + 1 < index.segmentCount {
            let e2 = index.segEnd[i + 1]
            if e2 > index.segStart[i + 1],
               let hit = findCompact(pattern, units, from: s, to: e2, startLimit: e) {
                return SegmentMatch(segment: i, score: 90 + 5 * shortness,
                                    cross: true, crossStart: hit.start, crossEnd: hit.end)
            }
        }
        return nil
    }

    // MARK: Hits, highlights, snippets

    static func hit(for m: SegmentMatch, query q: PreparedQuery, in index: TranscriptSearchIndex) -> TranscriptSearchHit {
        let i = m.segment
        var text = index.texts[i]
        var highlights = segmentHighlights(i, query: q, index: index)

        if m.cross, i + 1 < index.segmentCount {
            let next = index.texts[i + 1]
            let glue = joiner(text, next)
            let offset = text.utf16.count + glue.utf16.count
            if case .spaceless = q {
                let e1 = index.segEnd[i]
                let s2 = index.segStart[i + 1]
                if m.crossStart < e1 {
                    highlights.append(originalRange(index, m.crossStart, e1 - 1))
                }
                if m.crossEnd > s2 {
                    highlights.append(shifted(originalRange(index, s2, m.crossEnd - 1), by: offset))
                }
            }
            highlights += segmentHighlights(i + 1, query: q, index: index).map { shifted($0, by: offset) }
            text = text + glue + next
        } else if i > 0, text.utf16.count < shortSegmentLength {
            let prev = index.texts[i - 1]
            // Context only when it fits: a long previous segment would push the match out of the snippet.
            if !prev.isEmpty, prev.utf16.count + text.utf16.count < maxSnippetLength {
                let j = joiner(prev, text)
                let shift = prev.utf16.count + j.utf16.count
                highlights = highlights.map { shifted($0, by: shift) }
                text = prev + j + text
            }
        }

        let (snippet, ranges) = trim(text, highlights: merge(highlights))
        return TranscriptSearchHit(segmentIndex: i, time: index.times[i], score: m.score,
                                   snippet: snippet, highlights: ranges)
    }

    /// Highlights for one segment, in that segment's original UTF-16 coordinates.
    static func segmentHighlights(_ j: Int, query q: PreparedQuery, index: TranscriptSearchIndex) -> [NSRange] {
        let s = index.segStart[j]
        let e = index.segEnd[j]
        guard e > s else { return [] }
        let units = index.units
        var out: [NSRange] = []
        switch q {
        case .spaced(let words, _):
            for w in words {
                var p = s
                while let f = findWordPrefix(w, units, from: s, to: e, after: p) {
                    out.append(originalRange(index, f, f + w.count - 1))
                    p = f + 1
                }
            }
        case .spaceless(let pattern):
            var p = s
            while p < e, let m = findCompact(pattern, units, from: p, to: e, startLimit: e) {
                out.append(originalRange(index, m.start, m.end - 1))
                p = m.end
            }
        }
        return out
    }

    /// Original UTF-16 range covering folded units first...last (inclusive).
    static func originalRange(_ index: TranscriptSearchIndex, _ first: Int, _ last: Int) -> NSRange {
        let a = Int(index.origStart[first])
        let b = Int(index.origEnd[last])
        return NSRange(location: a, length: max(0, b - a))
    }

    static func shifted(_ r: NSRange, by delta: Int) -> NSRange {
        NSRange(location: r.location + delta, length: r.length)
    }

    /// Sorts and joins overlapping or touching ranges.
    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var out: [NSRange] = []
        for r in sorted {
            if let last = out.last, r.location <= NSMaxRange(last) {
                out[out.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(r)) - last.location)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Separator to put between two adjoining segments: none next to a spaceless script.
    static func joiner(_ a: String, _ b: String) -> String {
        if let l = a.unicodeScalars.last, TranscriptFolding.isSpacelessScalar(l) { return "" }
        if let f = b.unicodeScalars.first, TranscriptFolding.isSpacelessScalar(f) { return "" }
        return " "
    }

    static func isWhitespaceUnit(_ u: unichar) -> Bool {
        guard let sc = Unicode.Scalar(u) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(sc)
    }

    static func isSpacelessUnit(_ u: unichar) -> Bool {
        // A lone surrogate may be a plane-2 Han character: don't try to snap to a word there.
        guard let sc = Unicode.Scalar(u) else { return true }
        return TranscriptFolding.isSpacelessScalar(sc)
    }

    static func isMidWord(_ ns: NSString, at idx: Int) -> Bool {
        guard idx > 0, idx < ns.length else { return false }
        let a = ns.character(at: idx - 1)
        let b = ns.character(at: idx)
        return !isWhitespaceUnit(a) && !isWhitespaceUnit(b) && !isSpacelessUnit(a) && !isSpacelessUnit(b)
    }

    /// Trims long text to about `maxSnippetLength` around the first highlight, cutting at word
    /// boundaries (anywhere for CJK) and marking cut ends with "…". Highlights are clipped to the
    /// window and moved into the final string's coordinates.
    static func trim(_ text: String, highlights: [NSRange]) -> (String, [NSRange]) {
        let ns = text as NSString
        let len = ns.length
        guard len > maxSnippetLength else {
            return (text, highlights.filter { NSMaxRange($0) <= len })
        }
        let anchor = highlights.first ?? NSRange(location: 0, length: 0)
        let anchorEnd = min(len, NSMaxRange(anchor))
        var start = max(0, min(anchor.location, len - 1) - leadContext)
        var end = min(len, start + maxSnippetLength)
        if end == len { start = max(0, len - maxSnippetLength) }

        if start > 0 {
            start = ns.rangeOfComposedCharacterSequence(at: start).location
            if start > 0, isMidWord(ns, at: start) {
                var k = start
                let limit = min(anchor.location, start + snapSlack)
                while k < limit, !isWhitespaceUnit(ns.character(at: k)) { k += 1 }
                if k < limit { start = k }
            }
            while start < anchor.location, start < len, isWhitespaceUnit(ns.character(at: start)) { start += 1 }
        }
        if end < len {
            end = ns.rangeOfComposedCharacterSequence(at: end).location
            if end > start, isMidWord(ns, at: end) {
                var k = end
                let limit = max(anchorEnd, end - snapSlack)
                while k > limit, !isWhitespaceUnit(ns.character(at: k - 1)) { k -= 1 }
                if k > limit { end = k }
            }
            while end > max(start, anchorEnd), isWhitespaceUnit(ns.character(at: end - 1)) { end -= 1 }
        }
        if end <= start {
            start = max(0, min(anchor.location, len - 1))
            end = min(len, start + maxSnippetLength)
        }

        let window = NSRange(location: start, length: end - start)
        let lead = start > 0 ? "…" : ""
        let tail = end < len ? "…" : ""
        let shift = lead.utf16.count - start
        var out: [NSRange] = []
        for h in highlights {
            let inter = NSIntersectionRange(h, window)
            if inter.length > 0 { out.append(NSRange(location: inter.location + shift, length: inter.length)) }
        }
        return (lead + ns.substring(with: window) + tail, out)
    }
}
