import Foundation

/// Batch 426: pure planning for quote clips (Section D). No I/O, no UI; unit-tested in
/// `QuoteClipPlanningTests`. Sentence lookups come from `TranscriptLookup` / `TranscriptSegment`.

/// A passage of the book to cut, in book seconds.
nonisolated struct ClipRange: Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

nonisolated enum ClipRangeSnapper {
    nonisolated static let defaultLength: Double = 30
    nonisolated static let minLength: Double = 3
    nonisolated static let maxLength: Double = 120
    /// How far a boundary that falls in a silence may travel to reach a sentence edge.
    nonisolated private static let gapSnapTolerance: Double = 2
    nonisolated private static let epsilon: Double = 0.001

    /// Default range: the last `defaultLength` seconds ending at the playhead, clamped to the book,
    /// then snapped to sentence boundaries when segments exist. A playhead within `minLength` of 0
    /// gives `[0, min(defaultLength, bookDuration)]`.
    nonisolated static func defaultRange(playhead: Double, bookDuration: Double,
                                         segments: [TranscriptSegment]) -> ClipRange {
        let book = max(0, bookDuration.isFinite ? bookDuration : 0)
        let head = min(max(playhead.isFinite ? playhead : 0, 0), book)
        let raw: ClipRange
        if head < minLength {
            raw = ClipRange(start: 0, end: min(defaultLength, book))
        } else {
            raw = ClipRange(start: max(0, head - defaultLength), end: head)
        }
        return snapped(raw, bookDuration: book, segments: segments)
    }

    /// Snap the start to the start of its sentence (or the next sentence's start when in a gap within
    /// 2 s) and the end to the end of its sentence (or the previous sentence's end when in a gap within
    /// 2 s). An end whose snap would make the range shorter than `minLength` or longer than `maxLength`
    /// keeps its unsnapped value. Clamped to the book. Empty segments: just clamp.
    nonisolated static func snapped(_ range: ClipRange, bookDuration: Double,
                                    segments: [TranscriptSegment]) -> ClipRange {
        let base = clamped(range, bookDuration: bookDuration)
        guard !segments.isEmpty else { return base }
        var start = base.start
        var end = base.end
        if let s = snapStart(start, segments), isValidLength(end - s) { start = s }
        if let e = snapEnd(end, segments), isValidLength(e - start) { end = e }
        return clamped(ClipRange(start: start, end: end), bookDuration: bookDuration)
    }

    /// Move one end by whole sentences (`delta` = ±1, ±2, …; positive is later in time), staying within
    /// min/max length and the book. When the full step doesn't fit, the largest smaller step that does
    /// is used; if none fits the range is returned unchanged. `end: true` moves the end. With no
    /// segments, moves by `delta` seconds instead.
    nonisolated static func nudgedBySentence(_ range: ClipRange, end: Bool, delta: Int, bookDuration: Double,
                                             segments: [TranscriptSegment]) -> ClipRange {
        guard delta != 0 else { return range }
        guard !segments.isEmpty else {
            return nudged(range, end: end, by: Double(delta), bookDuration: bookDuration)
        }
        let boundaries: [Double]
        let moving = end ? range.end : range.start
        if delta > 0 {
            let all = segments.map { end ? $0.end : $0.start }
            boundaries = all.filter { $0 > moving + epsilon }
        } else {
            let all = segments.map { end ? $0.end : $0.start }
            boundaries = all.filter { $0 < moving - epsilon }.reversed()
        }
        let book = max(0, bookDuration)
        var steps = min(abs(delta), boundaries.count)
        while steps >= 1 {
            let candidate = boundaries[steps - 1]
            var out = range
            if end { out.end = candidate } else { out.start = candidate }
            if out.start >= 0, out.end <= book, isValidLength(out.duration) { return out }
            steps -= 1
        }
        return range
    }

    /// Move one end by seconds, clamped to min/max length and the book. No snapping.
    nonisolated static func nudged(_ range: ClipRange, end: Bool, by seconds: Double,
                                   bookDuration: Double) -> ClipRange {
        guard seconds.isFinite else { return range }
        let book = max(0, bookDuration)
        var out = range
        if end {
            let lower = range.start + minLength
            let upper = min(range.start + maxLength, book)
            guard lower <= upper else { return range }
            out.end = min(max(range.end + seconds, lower), upper)
        } else {
            let lower = max(0, range.end - maxLength)
            let upper = range.end - minLength
            guard lower <= upper else { return range }
            out.start = min(max(range.start + seconds, lower), upper)
        }
        return out
    }

    // MARK: Helpers

    nonisolated private static func isValidLength(_ length: Double) -> Bool {
        length >= minLength && length <= maxLength
    }

    nonisolated private static func clamped(_ range: ClipRange, bookDuration: Double) -> ClipRange {
        let book = max(0, bookDuration.isFinite ? bookDuration : 0)
        let start = min(max(range.start.isFinite ? range.start : 0, 0), book)
        let end = min(max(range.end.isFinite ? range.end : 0, start), book)
        return ClipRange(start: start, end: end)
    }

    /// Sentence start for a range start at `time`, or nil when it shouldn't move.
    nonisolated private static func snapStart(_ time: Double, _ segments: [TranscriptSegment]) -> Double? {
        let last = TranscriptLookup.segmentIndex(in: segments, at: time, gapTolerance: .infinity)
        if let last, segments[last].end > time { return segments[last].start }
        let next = (last ?? -1) + 1
        if next < segments.count, segments[next].start - time <= gapSnapTolerance { return segments[next].start }
        return nil
    }

    /// Sentence end for a range end at `time`, or nil when it shouldn't move. A time exactly at the
    /// start of a sentence belongs to the sentence before it, not the one it begins.
    nonisolated private static func snapEnd(_ time: Double, _ segments: [TranscriptSegment]) -> Double? {
        guard let last = TranscriptLookup.segmentIndex(in: segments, at: time, gapTolerance: .infinity) else {
            return nil
        }
        let prev = segments[last].start < time ? last : last - 1
        guard prev >= 0, segments[prev].end >= time - gapSnapTolerance else { return nil }
        return segments[prev].end
    }
}

/// One piece of a cut, in one track file's own time.
nonisolated struct ClipTrackPiece: Equatable, Sendable {
    let trackIndex: Int
    let start: Double
    let duration: Double
}

nonisolated enum ClipTrackPlanner {
    /// The pieces covering `[range.start, range.end)`, in book order. `tracks` may be in any order.
    /// Pieces shorter than 0.01 s are dropped; empty when the range is outside every track.
    nonisolated static func pieces(for range: ClipRange,
                                   tracks: [(index: Int, startOffset: Double, duration: Double)]) -> [ClipTrackPiece] {
        guard range.end > range.start else { return [] }
        var out: [ClipTrackPiece] = []
        for track in tracks.sorted(by: { $0.startOffset < $1.startOffset }) {
            let lo = max(range.start, track.startOffset)
            let hi = min(range.end, track.startOffset + track.duration)
            guard hi - lo >= 0.01 else { continue }
            out.append(ClipTrackPiece(trackIndex: track.index, start: lo - track.startOffset, duration: hi - lo))
        }
        return out
    }
}

nonisolated enum ClipText {
    /// Text of the segments that overlap `range` by at least half of their own length (so a sliver at
    /// an edge isn't included), joined with " " or "" when `spaceless`. Trimmed; empty when none.
    nonisolated static func text(for range: ClipRange, segments: [TranscriptSegment], spaceless: Bool) -> String {
        guard !segments.isEmpty, range.end >= range.start else { return "" }
        let indices = TranscriptLookup.segmentIndices(in: segments, from: range.start, to: range.end)
        var parts: [String] = []
        for index in indices {
            let seg = segments[index]
            let overlap = min(range.end, seg.end) - max(range.start, seg.start)
            guard overlap > 0, overlap >= seg.duration / 2 else { continue }
            let piece = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { parts.append(piece) }
        }
        return parts.joined(separator: spaceless ? "" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for languages written without spaces between words, decided from the transcript's locale
    /// identifier ("zh-CN", "ja_JP"), not the UI language.
    nonisolated static func isSpaceless(localeIdentifier: String) -> Bool {
        let language = localeIdentifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return language == "zh" || language == "ja"
    }

    /// Bookmark note: `text` trimmed, cut to at most `limit` characters at a word boundary (a character
    /// boundary when `spaceless`), with "…" appended when cut (so the result can be `limit + 1` long).
    nonisolated static func bookmarkNote(_ text: String, limit: Int = 200, spaceless: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        let chars = Array(trimmed)
        guard chars.count > limit else { return trimmed }
        var head = Array(chars.prefix(limit))
        if !spaceless, !chars[limit].isWhitespace, let space = head.lastIndex(where: { $0.isWhitespace }) {
            head = Array(head[..<space])
        }
        let cut = String(head).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "…"
    }

    /// File name for the exported m4a: "<Title> – <12m05s or 1h02m05s of start>.m4a". No colons: some
    /// share targets turn them into slashes. The title loses `/ : \ ? * " < > |`, runs of spaces
    /// collapse, it is trimmed to 60 characters, and is "Clip" when nothing is left.
    nonisolated static func fileName(title: String, start: Double) -> String {
        let illegal = Set<Character>(["/", ":", "\\", "?", "*", "\"", "<", ">", "|"])
        var clean = String(title.filter { !illegal.contains($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        clean = String(clean.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "Clip" }
        return "\(clean) – \(timeString(start)).m4a"
    }

    nonisolated private static func timeString(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh%02dm%02ds", h, m, s) }
        return String(format: "%dm%02ds", m, s)
    }
}
