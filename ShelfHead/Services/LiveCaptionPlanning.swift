import Foundation

/// Batch 425: pure planning for live captions and translation (Section C). No I/O, no UI;
/// unit-tested in `LiveCaptionPlanningTests`. Transcript lookups come from `TranscriptLookup`.

/// Which transcript lines the captions view shows around the playhead.
nonisolated struct LiveCaptionWindow: Equatable, Sendable {
    /// The line being spoken, or (in a pause between lines) the last line that finished. Nil before
    /// the first line. Kept through a gap so the text doesn't blank on every pause.
    let anchor: Int?
    /// True when `anchor` is actually being spoken now (time inside its span, using the gapTolerance).
    let anchorIsLive: Bool
    /// Indices to draw, in order: up to `before` lines ahead of the anchor and `after` lines after it.
    /// Before the first line: the first `after + 1` lines (upcoming).
    let lines: [Int]
    /// True when `time` is past `coveredUntil` of an unfinished transcript (no text yet for here).
    let beyondTranscript: Bool
}

enum LiveCaptionPlanner {
    /// How long past a segment's end its last word stays highlighted.
    nonisolated private static let highlightTail = 0.3
    /// The same tolerance `TranscriptLookup` uses for "is this line being spoken".
    nonisolated private static let liveTolerance = 1.5

    nonisolated static func window(segments: [TranscriptSegment], time: Double, isComplete: Bool,
                                   before: Int = 2, after: Int = 2) -> LiveCaptionWindow {
        let before = max(0, before)
        let after = max(0, after)
        let covered = segments.last?.end ?? 0
        let beyond = !isComplete && time.isFinite && time > covered
        guard !segments.isEmpty else {
            return LiveCaptionWindow(anchor: nil, anchorIsLive: false, lines: [], beyondTranscript: beyond)
        }
        if let live = TranscriptLookup.segmentIndex(in: segments, at: time, gapTolerance: liveTolerance) {
            return LiveCaptionWindow(anchor: live, anchorIsLive: true,
                                     lines: range(around: live, count: segments.count, before: before, after: after),
                                     beyondTranscript: beyond)
        }
        // Not inside any line: hold the last line that started, if there is one.
        if let last = TranscriptLookup.segmentIndex(in: segments, at: time, gapTolerance: .infinity) {
            return LiveCaptionWindow(anchor: last, anchorIsLive: false,
                                     lines: range(around: last, count: segments.count, before: before, after: after),
                                     beyondTranscript: beyond)
        }
        // Before the first line (or a non-finite time): show the upcoming lines.
        let upcoming = Array(0..<min(segments.count, after + 1))
        return LiveCaptionWindow(anchor: nil, anchorIsLive: false, lines: upcoming, beyondTranscript: beyond)
    }

    nonisolated private static func range(around anchor: Int, count: Int, before: Int, after: Int) -> [Int] {
        Array(max(0, anchor - before)...min(count - 1, anchor + after))
    }

    /// UTF-16 range of the word being spoken in `segment` at `time`, or nil (no word timing, before
    /// the first word, or after the segment's end plus 0.3 s).
    nonisolated static func highlightRange(in segment: TranscriptSegment, at time: Double) -> NSRange? {
        guard !segment.wordStarts.isEmpty, time.isFinite, time <= segment.end + highlightTail,
              let index = TranscriptLookup.wordIndex(in: segment, at: time) else { return nil }
        return TranscriptLookup.wordRange(in: segment, wordIndex: index)
    }

    /// The playhead between periodic ticks: `lastTime` plus elapsed wall time × rate while playing,
    /// clamped to at most `maxExtrapolation` (1.0 s) past `lastTime`; `lastTime` itself when paused.
    nonisolated static func interpolatedTime(lastTime: Double, lastTickDate: Date, now: Date,
                                             isPlaying: Bool, rate: Float,
                                             maxExtrapolation: Double = 1.0) -> Double {
        guard isPlaying, rate > 0 else { return lastTime }
        let elapsed = max(0, now.timeIntervalSince(lastTickDate))
        let delta = min(elapsed * Double(rate), max(0, maxExtrapolation))
        return lastTime + delta
    }

    /// Segments to translate next: from the anchor (or the segment at/after `time`) forward through
    /// `lookAhead` seconds of book time, skipping indices in `done` or `inFlight`, at most `maxCount`.
    /// Ascending order. Empty when everything in range is done.
    nonisolated static func translationBatch(segments: [TranscriptSegment], time: Double,
                                             done: Set<Int>, inFlight: Set<Int>,
                                             lookAhead: Double = 90, maxCount: Int = 12) -> [Int] {
        guard !segments.isEmpty, maxCount > 0, time.isFinite else { return [] }
        // Last line that has started, else the first line (time is before it).
        let first = TranscriptLookup.segmentIndex(in: segments, at: time, gapTolerance: .infinity) ?? 0
        let horizon = time + lookAhead
        var batch: [Int] = []
        var index = first
        while index < segments.count, segments[index].start <= horizon, batch.count < maxCount {
            if !done.contains(index), !inFlight.contains(index) { batch.append(index) }
            index += 1
        }
        return batch
    }
}

enum CaptionTranslationLanguage {
    /// Whether translating `source` (a transcript locale id like "en-US", "zh-CN") into `target`
    /// (a language id like "fr", "zh-Hans", "en") makes sense: false when the language codes match
    /// and the scripts don't differ (en-US→en, en-GB→en-US); true for zh-Hans↔zh-Hant (script differs);
    /// false for an empty target.
    nonisolated static func isTranslation(source: String, target: String) -> Bool {
        guard !target.isEmpty, !source.isEmpty,
              let a = parts(of: source), let b = parts(of: target) else { return !target.isEmpty }
        return a.language != b.language || a.script != b.script
    }

    /// Default target to suggest: the first of `preferredLanguages` (Locale.preferredLanguages
    /// form, e.g. ["zh-Hans-AU", "en-AU"]) that `isTranslation(source:target:)` accepts, reduced to
    /// language[-script] ("zh-Hans", "en"); nil if none.
    nonisolated static func suggestedTarget(source: String, preferredLanguages: [String]) -> String? {
        for preferred in preferredLanguages {
            guard let p = parts(of: preferred), isTranslation(source: source, target: preferred) else { continue }
            // Keep the script only where it distinguishes languages we offer (Chinese) or was explicit.
            if p.language == "zh" || p.explicitScript { return "\(p.language)-\(p.script)" }
            return p.language
        }
        return nil
    }

    /// Language code and script of an identifier. The script is explicit when given, a small table
    /// for Chinese (region TW/HK/MO means Traditional), else inferred from the maximal identifier.
    nonisolated private static func parts(of identifier: String)
        -> (language: String, script: String, explicitScript: Bool)? {
        let lang = Locale.Language(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
        guard let code = lang.languageCode?.identifier, !code.isEmpty else { return nil }
        // `Locale.Language.script` is inferred ("fr-FR" reports Latn), so "explicit" means the
        // identifier itself spells a four-letter script subtag ("zh-Hans-AU", "sr-Latn").
        let subtags = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        let spelled = subtags.dropFirst().contains { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        if spelled, let script = lang.script?.identifier { return (code, script, true) }
        if code == "zh" {
            let traditional: Set<String> = ["TW", "HK", "MO"]
            let region = lang.region?.identifier ?? ""
            return (code, traditional.contains(region) ? "Hant" : "Hans", false)
        }
        let maximal = Locale.Language(identifier: lang.maximalIdentifier)
        return (code, maximal.script?.identifier ?? "", false)
    }
}
