import Foundation

/// Batch 437: measures how fast a narrator reads, in words per minute of *speech time*,
/// from a book's on-device transcript, and turns a listener's target wpm into a playback
/// rate. Pure and `nonisolated`; no I/O.
///
/// The count is an approximation: words are whitespace-separated runs (or the segment's
/// `wordStarts` count when the transcriber gave word timing), and text with no spaces
/// (Chinese, Japanese) counts characters / 1.5 as a rough word equivalent.
nonisolated enum NarratorPace {
    /// Seconds of speech needed before the measure is trusted.
    static let minimumSpeechSeconds: Double = 300
    static let rateRange: ClosedRange<Double> = 0.5...3.0
    static let targetRange: ClosedRange<Int> = 120...300
    static let targetStep = 5
    static let defaultTarget = 170
    /// Characters per "word" for scripts written without spaces.
    static let charactersPerWord = 1.5

    /// Words per minute over the sum of segment durations (gaps excluded), or nil when
    /// fewer than `minimumSpeechSeconds` of speech are covered.
    static func wordsPerMinute(segments: [TranscriptSegment]) -> Double? {
        var speech = 0.0
        var words = 0.0
        for segment in segments {
            let duration = segment.duration
            guard duration > 0 else { continue }
            speech += duration
            words += wordCount(of: segment)
        }
        guard speech >= minimumSpeechSeconds, words > 0 else { return nil }
        return words / (speech / 60)
    }

    /// Approximate word count of one segment.
    static func wordCount(of segment: TranscriptSegment) -> Double {
        if !segment.wordStarts.isEmpty { return Double(segment.wordStarts.count) }
        return wordCount(of: segment.text)
    }

    static func wordCount(of text: String) -> Double {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        var total = 0.0
        for token in tokens {
            if token.unicodeScalars.contains(where: isCJK) {
                total += Double(token.unicodeScalars.filter(isCJK).count) / charactersPerWord
                // Latin/digit runs mixed into CJK text are rare; count them as one word.
                if token.unicodeScalars.contains(where: { !isCJK($0) && CharacterSet.alphanumerics.contains($0) }) {
                    total += 1
                }
            } else {
                total += 1
            }
        }
        return total
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// Playback rate that makes a narrator reading at `paceWPM` sound like `targetWPM`:
    /// clamped to 0.5...3.0 and rounded to the nearest 0.05.
    static func rate(targetWPM: Double, paceWPM: Double) -> Double {
        guard paceWPM > 0, targetWPM > 0 else { return 1.0 }
        let clamped = min(max(targetWPM / paceWPM, rateRange.lowerBound), rateRange.upperBound)
        return (clamped * 20).rounded() / 20
    }
}

extension SettingsKeys {
    static let speedMode = "settings_speedMode"
    static let targetWPM = "settings_targetWPM"
}

extension SettingsStore {
    /// Speed sheet mode: "multiplier" (default) or "wpm".
    static var speedModeIsWPM: Bool {
        get { UserDefaults.standard.string(forKey: SettingsKeys.speedMode) == "wpm" }
        set { UserDefaults.standard.set(newValue ? "wpm" : "multiplier", forKey: SettingsKeys.speedMode) }
    }

    /// Target words per minute for WPM mode (120...300, step 5, default 170).
    static var targetWPM: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: SettingsKeys.targetWPM) as? Int
            return min(max(stored ?? NarratorPace.defaultTarget, NarratorPace.targetRange.lowerBound),
                       NarratorPace.targetRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.targetWPM) }
    }
}
