import Foundation

/// Batch 427: pure planning for auto-chapters (Section E). No I/O, no UI; unit-tested in
/// `AutoChapterPlanningTests`. Suggestions come from long pauses in the audio, chapter announcements in
/// the transcript, track starts and any usable server chapters. Accepted chapters are saved on this device
/// only (`ChapterOverride`).

// `Chapter` has a custom `init(from:)` and `let` members, so there is no memberwise initialiser.
extension Chapter {
    nonisolated init(id: Int, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }
}

extension Chapter: Equatable {
    nonisolated static func == (lhs: Chapter, rhs: Chapter) -> Bool {
        lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end && lhs.title == rhs.title
    }
}

// MARK: - Health

/// Why a book is offered suggestions. An empty issue list means healthy.
nonisolated enum ChapterHealthIssue: Equatable, Sendable { case none, single, overlong, dropped }

nonisolated enum ChapterHealth {
    nonisolated static let overlongThreshold: Double = 3 * 3600
    nonisolated static let minimumBookDuration: Double = 1200

    /// `.none` (no chapters at all), `.single`, `.overlong` (any chapter over 3 h) and `.dropped`
    /// (some chapters couldn't be read), in that order. Books under 20 minutes never have issues.
    nonisolated static func issues(chapters: [Chapter], droppedCount: Int, bookDuration: Double) -> [ChapterHealthIssue] {
        guard bookDuration >= minimumBookDuration else { return [] }
        var result: [ChapterHealthIssue] = []
        if chapters.isEmpty { result.append(.none) }
        if chapters.count == 1 { result.append(.single) }
        if chapters.contains(where: { $0.end - $0.start > overlongThreshold }) { result.append(.overlong) }
        if droppedCount > 0 { result.append(.dropped) }
        return result
    }
}

// MARK: - Silence

/// A quiet stretch in book time.
nonisolated struct SilenceGap: Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

nonisolated enum SilenceGapFinder {
    /// Runs of quiet windows lasting at least `minGap` seconds, in book time. `levels` are dBFS RMS
    /// levels of consecutive `windowSeconds` windows starting at book time `offset`.
    nonisolated static func gaps(levels: [Float], windowSeconds: Double, offset: Double, minGap: Double = 1.5) -> [SilenceGap] {
        guard !levels.isEmpty, windowSeconds > 0 else { return [] }
        let limit = threshold(levels: levels)
        var result: [SilenceGap] = []
        var runStart: Int?
        func close(at endIndex: Int) {
            guard let s = runStart else { return }
            runStart = nil
            let length = Double(endIndex - s) * windowSeconds
            if length >= minGap - 1e-9 {
                result.append(SilenceGap(start: offset + Double(s) * windowSeconds,
                                         end: offset + Double(endIndex) * windowSeconds))
            }
        }
        for (i, level) in levels.enumerated() {
            let quiet = level.isNaN ? false : level < limit
            if quiet {
                if runStart == nil { runStart = i }
            } else {
                close(at: i)
            }
        }
        close(at: levels.count)
        return result
    }

    /// The 10th percentile of the finite levels plus 10 dB, clamped to [-60, -30] dBFS; -50 when there
    /// is nothing finite to measure.
    nonisolated static func threshold(levels: [Float]) -> Float {
        let finite = levels.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return -50 }
        let index = Int((Double(finite.count - 1) * 0.1).rounded(.down))
        return min(max(finite[index] + 10, -60), -30)
    }

    /// Sorts and joins gaps that touch or overlap (up to 0.05 s apart).
    nonisolated static func merged(_ gaps: [SilenceGap]) -> [SilenceGap] {
        var result: [SilenceGap] = []
        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, gap.start <= last.end + 0.05 {
                result[result.count - 1].end = max(last.end, gap.end)
            } else {
                result.append(gap)
            }
        }
        return result
    }
}

// MARK: - Spoken announcements

/// A spoken chapter announcement found in the transcript.
nonisolated struct ChapterCue: Equatable, Sendable {
    var time: Double
    var title: String
}

nonisolated enum ChapterCueDetector {
    nonisolated private static let minCueSpacing: Double = 60
    nonisolated private static let pauseBefore: Double = 1.0

    /// Announcements at the start of a segment that is short or follows a pause. See the contract in
    /// `sectionE-contract.md` for the accepted forms. A lone roman "I" is only accepted as the last
    /// word ("Chapter I"), so "Part I think so" isn't read as an announcement.
    nonisolated static func cues(in segments: [TranscriptSegment]) -> [ChapterCue] {
        var result: [ChapterCue] = []
        var previousEnd: Double?
        for segment in segments {
            defer { previousEnd = segment.end }
            let text = trimLeading(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty else { continue }
            let found: (title: String, chinese: Bool)?
            if let zh = chineseAnnouncement(text) {
                found = (zh, true)
            } else if let en = englishAnnouncement(text) {
                found = (en, false)
            } else {
                found = nil
            }
            guard let hit = found else { continue }
            let short: Bool
            if hit.chinese {
                short = text.filter { !$0.isWhitespace }.count <= 20
            } else {
                short = text.split(whereSeparator: { $0.isWhitespace }).count <= 8
            }
            let paused = previousEnd.map { segment.start - $0 >= pauseBefore } ?? true
            guard short || paused else { continue }
            if let last = result.last, segment.start - last.time < minCueSpacing { continue }
            result.append(ChapterCue(time: segment.start, title: hit.title))
        }
        return result
    }

    // MARK: English

    nonisolated private struct Token { var separator: String; var word: String }

    nonisolated private static func trimLeading(_ s: String) -> String {
        String(s.drop(while: { !($0.isLetter || $0.isNumber) }))
    }

    nonisolated private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    nonisolated private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var sep = ""
        var word = ""
        for c in s {
            if isWordChar(c) {
                word.append(c)
            } else {
                if !word.isEmpty {
                    tokens.append(Token(separator: sep, word: word))
                    word = ""
                    sep = ""
                }
                sep.append(c)
            }
            if tokens.count >= 6 { break }
        }
        if !word.isEmpty { tokens.append(Token(separator: sep, word: word)) }
        return tokens
    }

    nonisolated private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }

    nonisolated private static func capitalised(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst().lowercased()
    }

    nonisolated private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    nonisolated private static let tens: Set<String> = [
        "twenty", "thirty", "forty", "fourty", "fifty", "sixty", "seventy", "eighty", "ninety"
    ]
    nonisolated private static let singleDigits: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"
    ]
    nonisolated private static let standalone: Set<String> = [
        "prologue", "epilogue", "introduction", "foreword", "preface", "afterword", "interlude",
        "acknowledgments", "acknowledgements"
    ]

    nonisolated private static func romanValue(_ s: String) -> Int? {
        let map: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        let chars = Array(s.uppercased())
        guard !chars.isEmpty, chars.allSatisfy({ map[$0] != nil }) else { return nil }
        var total = 0
        for (i, c) in chars.enumerated() {
            let v = map[c]!
            if i + 1 < chars.count, let next = map[chars[i + 1]], next > v { total -= v } else { total += v }
        }
        guard (1...40).contains(total) else { return nil }
        // Reject non-canonical spellings such as "IIII" or "VX".
        var rest = total
        var canonical = ""
        for (value, glyph) in [(40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while rest >= value { canonical += glyph; rest -= value }
        }
        return canonical == s.uppercased() ? total : nil
    }

    /// The spoken number starting at `tokens[index]`: its display text and how many tokens it used.
    nonisolated private static func number(in tokens: [Token], at index: Int) -> (text: String, used: Int)? {
        guard index < tokens.count else { return nil }
        let raw = tokens[index].word
        let word = fold(raw)
        if !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isNumber }) { return (raw, 1) }
        if units[word] != nil { return (capitalised(raw), 1) }
        if tens.contains(word) {
            if index + 1 < tokens.count {
                let next = tokens[index + 1]
                let sep = next.separator
                let simple = sep.allSatisfy { $0.isWhitespace || $0 == "-" } && !sep.isEmpty
                if simple, singleDigits.contains(fold(next.word)) {
                    let joiner = sep.contains("-") ? "-" : " "
                    return (capitalised(raw) + joiner + capitalised(next.word), 2)
                }
            }
            return (capitalised(raw), 1)
        }
        if raw == raw.uppercased(), romanValue(raw) != nil {
            if raw == "I", index != tokens.count - 1 { return nil }
            return (raw, 1)
        }
        return nil
    }

    nonisolated private static func englishAnnouncement(_ text: String) -> String? {
        let tokens = tokenize(text)
        guard let first = tokens.first else { return nil }
        let head = fold(first.word)
        switch head {
        case "chapter", "part", "book":
            guard let n = number(in: tokens, at: 1) else { return nil }
            return capitalised(first.word) + " " + n.text
        case "authors":
            if tokens.count > 1, fold(tokens[1].word) == "note" { return "Author's Note" }
            return nil
        default:
            return standalone.contains(head) ? capitalised(first.word) : nil
        }
    }

    // MARK: Chinese

    nonisolated private static let zhNumerals: Set<Character> = Set("一二三四五六七八九十百零〇两0123456789")
    nonisolated private static let zhUnits: Set<Character> = Set("章回节節部卷")
    nonisolated private static let zhFixed = ["序章", "序言", "楔子", "尾声", "后记", "前言", "引子"]

    nonisolated private static func chineseAnnouncement(_ text: String) -> String? {
        if text.hasPrefix("第") {
            var title = "第"
            var sawNumeral = false
            for c in text.dropFirst() {
                if zhNumerals.contains(c) {
                    sawNumeral = true
                    title.append(c)
                } else if zhUnits.contains(c), sawNumeral {
                    title.append(c)
                    return title
                } else {
                    return nil
                }
            }
            return nil
        }
        return zhFixed.first { text.hasPrefix($0) }
    }
}

// MARK: - Proposals

nonisolated enum ChapterSuggestionSource: String, Codable, Sendable { case server, cue, track, silence, start }

nonisolated struct ChapterSuggestion: Equatable, Sendable, Identifiable {
    var id: Int
    var start: Double
    var title: String
    var source: ChapterSuggestionSource
    var isIncluded: Bool = true
}

nonisolated enum ChapterProposalBuilder {
    nonisolated static let minSpacing: Double = 5 * 60
    nonisolated static let silenceOnlyMinGap: Double = 2.5
    nonisolated static let targetLength: Double = 45 * 60

    nonisolated private static let leadIn: Double = 0.5
    nonisolated private static let cueSnapWindow: Double = 10
    nonisolated private static let strongDuplicateWindow: Double = 20
    nonisolated private static let startMergeWindow: Double = 60

    nonisolated private struct Candidate {
        var time: Double
        var title: String?
        var source: ChapterSuggestionSource
        var gapLength: Double = 0
    }

    nonisolated static func suggestions(bookDuration: Double, serverChapters: [Chapter], cues: [ChapterCue],
                                        trackStarts: [Double], trackTitles: [String], gaps: [SilenceGap]) -> [ChapterSuggestion] {
        guard bookDuration.isFinite, bookDuration > 1 else { return [] }
        let limit = bookDuration - 1

        // Server chapters: ignored when there's at most one; overlong ones aren't usable.
        var servers: [Candidate] = []
        if serverChapters.count > 1 {
            for ch in serverChapters where ch.start.isFinite && ch.start >= 0 && ch.start < limit
                && ch.end - ch.start <= ChapterHealth.overlongThreshold {
                let title = ch.title.trimmingCharacters(in: .whitespacesAndNewlines)
                servers.append(Candidate(time: ch.start, title: title.isEmpty ? nil : title, source: .server))
            }
        }

        // Cues, nudged to the end of a pause just before them; server chapters win a near duplicate.
        var cueCandidates: [Candidate] = []
        for cue in cues where cue.time.isFinite && cue.time >= 0 {
            var time = cue.time
            if let gap = gaps.filter({ cue.time >= $0.start && cue.time <= $0.end + cueSnapWindow })
                .min(by: { abs($0.end - cue.time) < abs($1.end - cue.time) }) {
                time = max(gap.end - leadIn, gap.start, 0)
            }
            guard time < limit else { continue }
            if servers.contains(where: { abs($0.time - time) <= strongDuplicateWindow }) { continue }
            let title = cue.title.trimmingCharacters(in: .whitespacesAndNewlines)
            cueCandidates.append(Candidate(time: time, title: title.isEmpty ? nil : title, source: .cue))
        }
        var strong = (servers + cueCandidates).sorted { $0.time < $1.time }

        // The opening chapter takes the first announcement or server title within a minute of 0.
        var openingTitle: String?
        var mergedAnnouncement = false
        if let i = strong.firstIndex(where: { $0.time <= startMergeWindow }) {
            openingTitle = strong[i].title
            mergedAnnouncement = true
            strong.remove(at: i)
        }

        // Track starts, kept unless too close to something stronger (or an earlier track).
        var anchors: [Double] = [0] + strong.map(\.time)
        var tracks: [Candidate] = []
        for (i, start) in trackStarts.enumerated().sorted(by: { $0.element < $1.element })
        where start.isFinite && start > 0 && start < limit {
            guard !anchors.contains(where: { abs($0 - start) < minSpacing }) else { continue }
            var title: String?
            if i < trackTitles.count {
                let t = trackTitles[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !isGenericTrackTitle(t) { title = t }
            }
            tracks.append(Candidate(time: start, title: title, source: .track))
            anchors.append(start)
        }

        // Silence-only filling when there's nothing (or one thing) announced.
        var silences: [Candidate] = []
        if strong.count + (mergedAnnouncement ? 1 : 0) < 2 {
            let pool = gaps.filter { $0.duration >= silenceOnlyMinGap }.map {
                Candidate(time: max($0.end - leadIn, $0.start), title: nil, source: .silence, gapLength: $0.duration)
            }.filter { $0.time > 0 && $0.time <= limit && $0.time <= bookDuration - minSpacing }
            silences = walk(pool: pool, anchors: anchors.filter { $0 > 0 }.sorted(), bookDuration: bookDuration)
        }

        let ordered = (strong + tracks + silences).sorted { $0.time < $1.time }
        var generated = 0
        var result: [ChapterSuggestion] = [
            ChapterSuggestion(id: 0, start: 0, title: openingTitle ?? String(localized: "Opening", comment: "Title of the first suggested chapter when the book has no title for it"), source: .start)
        ]
        for candidate in ordered {
            let title: String
            if let given = candidate.title {
                title = given
            } else {
                generated += 1
                title = generatedTitle(generated)
            }
            result.append(ChapterSuggestion(id: result.count, start: candidate.time, title: title, source: candidate.source))
        }
        return result
    }

    nonisolated private static func generatedTitle(_ n: Int) -> String {
        String(localized: "Chapter \(n)", comment: "Generated chapter title. %lld is the chapter's number")
    }

    /// File names and bare numbers aren't titles.
    nonisolated private static func isGenericTrackTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        let extensions = [".mp3", ".m4a", ".m4b", ".aac", ".flac", ".ogg", ".opus", ".wav", ".wma", ".mp4"]
        if extensions.contains(where: { t.hasSuffix($0) }) { return true }
        let stripped = t.drop(while: { $0.isLetter })
        let prefix = t.prefix(t.count - stripped.count)
        let generic: Set<String> = ["", "track", "disc", "disk", "cd", "file", "part", "audio", "chapter"]
        // "Chapter 3" is a real title; the others are not.
        if prefix == "chapter" { return false }
        guard generic.contains(String(prefix)) else { return false }
        return stripped.allSatisfy { $0.isNumber || $0.isWhitespace || "_-#.".contains($0) }
            && stripped.contains(where: { $0.isNumber })
    }

    /// Greedy walk choosing silence candidates about `targetLength` apart.
    nonisolated private static func walk(pool: [Candidate], anchors: [Double], bookDuration: Double) -> [Candidate] {
        let usable = pool.filter { c in
            c.time >= minSpacing && !anchors.contains(where: { abs($0 - c.time) < minSpacing })
        }.sorted { $0.time < $1.time }
        var chosen: [Candidate] = []
        var last = 0.0
        func longest(in range: ClosedRange<Double>) -> Candidate? {
            // Longest gap; the earliest wins a tie.
            usable.filter { c in
                range.contains(c.time) && abs(c.time - last) >= minSpacing
                    && !chosen.contains(where: { abs(c.time - $0.time) < minSpacing })
            }
                .reduce(nil as Candidate?) { best, c in
                    guard let b = best else { return c }
                    return c.gapLength > b.gapLength ? c : b
                }
        }
        while last + minSpacing < bookDuration {
            let nextAnchor = anchors.first { $0 > last }
            let pick = longest(in: (last + 0.6 * targetLength)...(last + 1.4 * targetLength))
                ?? longest(in: (last + minSpacing)...(last + 2 * targetLength))
            if let a = nextAnchor, pick == nil || pick!.time > a {
                last = a
                continue
            }
            if let p = pick {
                chosen.append(p)
                last = p.time
            } else {
                last += targetLength
            }
        }
        return chosen
    }

    /// Chapters from the reviewed suggestions: included, sorted, deduplicated (starts within 1 s), each
    /// ending where the next starts and the last at the end of the book; the first always starts at 0.
    nonisolated static func chapters(from suggestions: [ChapterSuggestion], bookDuration: Double) -> [Chapter] {
        guard bookDuration.isFinite, bookDuration > 0 else { return [] }
        let included = suggestions.filter { $0.isIncluded && $0.start < bookDuration }
            .sorted { $0.start < $1.start }
        var kept: [(start: Double, title: String)] = []
        for s in included {
            let start = min(max(s.start, 0), bookDuration)
            if let last = kept.last, start - last.start <= 1 { continue }
            kept.append((start, s.title))
        }
        guard !kept.isEmpty else { return [] }
        kept[0].start = 0
        return kept.enumerated().map { i, k in
            let end = i + 1 < kept.count ? kept[i + 1].start : bookDuration
            let title = k.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Chapter(id: i, start: k.start, end: end, title: title.isEmpty ? generatedTitle(i + 1) : title)
        }
    }

    /// Moves a suggestion's start by `seconds`, staying 1 s clear of its neighbours and inside the book.
    /// The first suggestion can't move.
    nonisolated static func nudged(_ suggestions: [ChapterSuggestion], id: Int, by seconds: Double, bookDuration: Double) -> [ChapterSuggestion] {
        guard let index = suggestions.firstIndex(where: { $0.id == id }), index > 0,
              seconds.isFinite, bookDuration.isFinite else { return suggestions }
        let lower = suggestions[index - 1].start + 1
        var upper = bookDuration - 1
        if index + 1 < suggestions.count { upper = min(upper, suggestions[index + 1].start - 1) }
        guard lower <= upper else { return suggestions }
        var result = suggestions
        result[index].start = min(max(suggestions[index].start + seconds, lower), upper)
        return result
    }
}

// MARK: - Saved override

/// What's saved for one book.
nonisolated struct ChapterOverride: Codable, Equatable, Sendable {
    nonisolated static let currentVersion = 1
    var version: Int
    var itemId: String
    var chapters: [Chapter]
    /// Fingerprint of the server chapters when this was saved (see `ChapterOverrideResolver.serverSignature`).
    var serverSignature: String
    var savedAt: Date
}

nonisolated enum ChapterOverrideResolver {
    /// "count|round(sum of durations)|round(last end)" of the server chapters.
    nonisolated static func serverSignature(_ chapters: [Chapter]) -> String {
        func whole(_ x: Double) -> Int { x.isFinite && abs(x) < 1e12 ? Int(x.rounded()) : 0 }
        let total = chapters.reduce(0.0) { $0 + ($1.end - $1.start) }
        return "\(chapters.count)|\(whole(total))|\(whole(chapters.last?.end ?? 0))"
    }

    /// The override's chapters when it's usable and the server's chapters haven't changed since; else the server's.
    nonisolated static func resolve(server: [Chapter], override: ChapterOverride?) -> [Chapter] {
        isApplied(server: server, override: override) ? (override?.chapters ?? server) : server
    }

    nonisolated static func isApplied(server: [Chapter], override: ChapterOverride?) -> Bool {
        guard let o = override, o.version == ChapterOverride.currentVersion, !o.chapters.isEmpty else { return false }
        return o.serverSignature == serverSignature(server)
    }
}
