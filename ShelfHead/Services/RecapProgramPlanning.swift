import Foundation

/// Batch 433: pure planning for the narrator "Previously On…" montage. Picks candidate moments from the
/// transcript (per chunk of notes), fits them into the model's context, maps the model's script back to
/// moments, falls back deterministically, and builds the `RecapProgram`. No I/O, no FoundationModels;
/// unit-tested in `RecapProgramPlanningTests`.

/// One sentence of the heard book that could be played in the narrator's voice.
nonisolated struct RecapMomentCandidate: Equatable, Sendable {
    /// 1…n in book order. Stable even when `RecapProgramPlanner.fit` drops some from the prompt.
    var id: Int
    var chunkIndex: Int
    var start: Double
    var end: Double
    var text: String
    /// 0 = best match inside its chunk. Used to drop the weakest first when the prompt must shrink.
    var rank: Int = 0
    /// End of the chunk the sentence belongs to; a clip never extends past it.
    var chunkEnd: Double = .infinity
}

nonisolated enum RecapProgramPlanner {
    nonisolated static let promptBudgetTokens = 2_800
    nonisolated static let maxBeats = 6
    nonisolated static let minBeats = 2
    nonisolated private static let epsilon = 0.001

    // MARK: Candidates

    /// For each note (in order): the sentences inside `note.start..<note.end`, scored (BM25) against that
    /// chunk's summary and entity names, speakable length only (6–40 words, or 12–80 characters when
    /// `spaceless`), chapter headings skipped. The top `perChunk` per chunk, in time order within the chunk;
    /// ids 1…n over the whole list. When fewer than `perChunk` sentences match, the rest are topped up with
    /// unmatched speakable sentences (ranked after the matches).
    nonisolated static func candidates(notes: [ChunkNotes], segments: [TranscriptSegment], spaceless: Bool,
                                       perChunk: Int = 3) -> [RecapMomentCandidate] {
        guard perChunk > 0, !segments.isEmpty else { return [] }
        var out: [RecapMomentCandidate] = []
        for note in notes.sorted(by: { $0.start < $1.start }) {
            let eligible = eligibleSegments(in: note, segments: segments, spaceless: spaceless)
            guard !eligible.isEmpty else { continue }
            let query = ([note.summary] + note.entities.map(\.name)).joined(separator: " ")
            let matched = BM25.rank(query: query, documents: eligible.map { $0.text }, k: eligible.count)
            var order = matched
            let seen = Set(matched)
            order.append(contentsOf: eligible.indices.filter { !seen.contains($0) })
            var picks: [(rank: Int, seg: TranscriptSegment)] = []
            for (rank, index) in order.prefix(perChunk).enumerated() {
                picks.append((rank, eligible[index]))
            }
            picks.sort { $0.seg.start < $1.seg.start }
            for pick in picks {
                out.append(RecapMomentCandidate(id: out.count + 1, chunkIndex: note.chunkIndex,
                                                start: pick.seg.start, end: pick.seg.end,
                                                text: pick.seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                rank: pick.rank, chunkEnd: note.end))
            }
        }
        return out
    }

    nonisolated private static func eligibleSegments(in note: ChunkNotes, segments: [TranscriptSegment],
                                                     spaceless: Bool) -> [TranscriptSegment] {
        // Segments are sorted by start: binary search for the first that could be inside.
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start < note.start - epsilon { lo = mid + 1 } else { hi = mid }
        }
        var result: [TranscriptSegment] = []
        var i = lo
        while i < segments.count, segments[i].start < note.end - epsilon {
            let seg = segments[i]
            if seg.end <= note.end + epsilon, isSpeakable(seg.text, spaceless: spaceless) { result.append(seg) }
            i += 1
        }
        return result
    }

    nonisolated static func isSpeakable(_ text: String, spaceless: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHeading(trimmed, spaceless: spaceless) else { return false }
        if spaceless {
            let count = trimmed.filter { !$0.isWhitespace }.count
            return (12...80).contains(count)
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        return (6...40).contains(words)
    }

    /// "Chapter 3.", "Part Two: The Road", "Prologue", "第三章", "第十二回 夜话".
    nonisolated static func isHeading(_ text: String, spaceless: Bool) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("第") {
            let head = t.prefix(8)
            if head.contains(where: { "章节節回卷部篇".contains($0) }) { return true }
        }
        let folded = t.lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = words.first else { return true }
        let markers: Set<String> = ["chapter", "part", "book", "section", "prologue", "epilogue", "interlude",
                                    "preface", "foreword", "afterword", "introduction", "volume"]
        return markers.contains(first) && words.count <= 6
    }

    // MARK: Clip range

    /// Starts at the candidate's sentence and extends forward over whole following sentences until at least
    /// `minLength` seconds, never past `maxLength` (a single sentence longer than that stays as is) and never
    /// past the candidate's chunk end, nor into a sentence starting at or after `stopBefore` (the next chosen
    /// moment, so two clips never play the same sentence twice).
    nonisolated static func clipRange(for candidate: RecapMomentCandidate, segments: [TranscriptSegment],
                                      minLength: Double = 6, maxLength: Double = 20,
                                      stopBefore: Double = .infinity) -> ClipRange {
        let fallback = ClipRange(start: candidate.start, end: candidate.end)
        guard !segments.isEmpty else { return fallback }
        var index: Int?
        for (i, seg) in segments.enumerated() where abs(seg.start - candidate.start) < 0.01 {
            index = i
            break
        }
        guard var i = index else { return fallback }
        var end = segments[i].end
        while end - candidate.start < minLength, i + 1 < segments.count {
            let next = segments[i + 1]
            guard next.end <= candidate.chunkEnd + epsilon, next.end - candidate.start <= maxLength,
                  next.start < stopBefore - epsilon else { break }
            i += 1
            end = next.end
        }
        return ClipRange(start: candidate.start, end: end)
    }

    // MARK: Prompt

    /// Notes and candidates that fit `budgetTokens`: weakest candidates (highest `rank`, older first) are
    /// dropped first, down to two; then the oldest summaries.
    nonisolated static func fit(title: String, author: String, notes: [ChunkNotes],
                                candidates: [RecapMomentCandidate], spaceless: Bool = false,
                                budgetTokens: Int = promptBudgetTokens)
        -> (notes: [ChunkNotes], candidates: [RecapMomentCandidate]) {
        var notes = notes
        var candidates = candidates
        func cost() -> Int {
            TokenEstimate.tokens(render(title: title, author: author, notes: notes, candidates: candidates),
                                 spaceless: spaceless)
        }
        while cost() > budgetTokens {
            if candidates.count > minBeats {
                var worst = 0
                for i in candidates.indices where candidates[i].rank > candidates[worst].rank { worst = i }
                candidates.remove(at: worst)
            } else if notes.count > 1 {
                notes.removeFirst()
            } else {
                break
            }
        }
        return (notes, candidates)
    }

    /// "Book:", "Author:", blank, one "Part n (t1–t2): summary" per note, blank, "Moments:", then one
    /// "[id] (m:ss) sentence" per candidate. Shrinks to `budgetTokens` through `fit` first.
    nonisolated static func scriptPrompt(title: String, author: String, notes: [ChunkNotes],
                                         candidates: [RecapMomentCandidate], spaceless: Bool = false,
                                         budgetTokens: Int = promptBudgetTokens) -> String {
        let fitted = fit(title: title, author: author, notes: notes, candidates: candidates,
                         spaceless: spaceless, budgetTokens: budgetTokens)
        return render(title: title, author: author, notes: fitted.notes, candidates: fitted.candidates)
    }

    nonisolated private static func render(title: String, author: String, notes: [ChunkNotes],
                                           candidates: [RecapMomentCandidate]) -> String {
        var text = RecapPlanner.recapPrompt(title: title, author: author, notes: notes)
        text += "\n\nMoments:"
        for c in candidates {
            text += "\n[\(c.id)] (\(RecapPlanner.timestamp(c.start))) \(c.text)"
        }
        return text
    }

    // MARK: Beats

    /// The model's lines mapped to candidates: unknown and duplicate moment numbers dropped, at most
    /// `maxBeats` (model order decides which survive), then sorted into book order.
    nonisolated static func beats(fromModel lines: [(line: String, moment: Int)],
                                  candidates: [RecapMomentCandidate],
                                  maxBeats: Int = maxBeats) -> [(line: String, candidate: RecapMomentCandidate)] {
        var byId: [Int: RecapMomentCandidate] = [:]
        for c in candidates { byId[c.id] = c }
        var seen = Set<Int>()
        var out: [(line: String, candidate: RecapMomentCandidate)] = []
        for entry in lines {
            guard out.count < maxBeats, let c = byId[entry.moment], seen.insert(entry.moment).inserted else { continue }
            out.append((entry.line.trimmingCharacters(in: .whitespacesAndNewlines), c))
        }
        return out.sorted { $0.candidate.start < $1.candidate.start }
    }

    /// No model needed: the best candidate of each of the most recent chunks (up to `maxBeats`), in book
    /// order, each introduced by the first sentence of that chunk's summary.
    nonisolated static func fallbackBeats(notes: [ChunkNotes], candidates: [RecapMomentCandidate],
                                          maxBeats: Int = maxBeats) -> [(line: String, candidate: RecapMomentCandidate)] {
        var out: [(line: String, candidate: RecapMomentCandidate)] = []
        for note in notes.sorted(by: { $0.start < $1.start }).suffix(maxBeats) {
            let best = candidates.filter { $0.chunkIndex == note.chunkIndex }
                .min { $0.rank != $1.rank ? $0.rank < $1.rank : $0.start < $1.start }
            if let best { out.append((firstSentence(note.summary), best)) }
        }
        return out
    }

    nonisolated static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        let enders: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
        for (i, ch) in chars.enumerated() where enders.contains(ch) {
            let cjk = ch == "\u{3002}" || ch == "\u{FF01}" || ch == "\u{FF1F}"
            if cjk || i + 1 == chars.count || chars[i + 1].isWhitespace {
                return String(chars[...i])
            }
        }
        return trimmed
    }

    // MARK: Program

    nonisolated static func program(itemId: String, summary: String,
                                    beats: [(line: String, candidate: RecapMomentCandidate)],
                                    segments: [TranscriptSegment], spokenLinks: Bool, spaceless: Bool = false,
                                    madeThrough: Double, inputHash: String) -> RecapProgram {
        var items: [RecapProgramItem] = []
        let starts = beats.map(\.candidate.start)
        var kept: [ClipRange] = []
        for beat in beats {
            let start = beat.candidate.start
            let nextChosen = starts.filter { $0 > start + epsilon }.min() ?? .infinity
            let range = clipRange(for: beat.candidate, segments: segments, stopBefore: nextChosen)
            // The same moment chosen twice, or one already inside an earlier clip: play it once.
            if kept.contains(where: { range.start < $0.end - epsilon && $0.start < range.end - epsilon }) { continue }
            kept.append(range)
            var text = ClipText.text(for: range, segments: segments, spaceless: spaceless)
            if text.isEmpty { text = beat.candidate.text }
            if spokenLinks, !beat.line.isEmpty { items.append(.speech(beat.line)) }
            items.append(.clip(start: range.start, end: range.end, text: text))
        }
        if beats.isEmpty { items = [.speech(summary)] }
        return RecapProgram(version: RecapProgram.currentVersion, itemId: itemId, summary: summary, items: items,
                            madeThrough: madeThrough, inputHash: inputHash, spokenLinks: spokenLinks)
    }

    nonisolated static func inputHash(notes: [ChunkNotes], spokenLinks: Bool) -> String {
        let parts = notes.map { "\($0.chunkIndex):\($0.sourceHash)" }
        return NotesCache.hash(parts.joined(separator: "|")
                               + "|links=\(spokenLinks)|v\(RecapProgram.currentVersion)")
    }
}
