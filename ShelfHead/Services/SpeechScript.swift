import AVFoundation
import Foundation

/// Batch 435: turns written recap text into something meant to be heard, and builds the utterance
/// both "Read It to Me" (`SpeechReader`) and the rendered montage (`RecapAudioRenderer`) speak.
///
/// - Written for the ear: brackets, markdown and list markers are dropped (a synthesizer reads them
///   out or stumbles over them).
/// - Pacing: SSML (`AVSpeechUtterance(ssmlRepresentation:)`, iOS 16) with a slightly slower rate and
///   a short pause between sentences. Apple's docs: utterance `rate`/`pitchMultiplier` don't apply to
///   an SSML utterance, so the rate lives in `<prosody>`. Invalid SSML returns nil, and the plain
///   utterance (rate and `postUtteranceDelay` set directly) is the fallback.
/// - Your own settings: `prefersAssistiveTechnologySettings` lets the system's assistive-technology
///   speech settings win while one is on (docs: "such as VoiceOver"); otherwise the utterance's
///   own values apply. Apps can't read the Spoken Content voice or rate directly.
nonisolated enum SpeechScript {
    /// Relative speaking rate for the recap voice, as an SSML percentage. Measured in the simulator
    /// (Batch 435): 92% rendered no slower than plain speech, 80% about 10% slower, "slow" about 30%.
    static let ratePercent = 80
    /// Pause between sentences, in milliseconds.
    static let sentencePauseMs = 350

    // MARK: Text

    /// `text` cleaned for listening: markdown emphasis/headings, list markers and bracketed or
    /// parenthetical asides removed, whitespace collapsed. Never returns an empty string for
    /// non-empty input that only had an aside: the original (trimmed) text comes back then.
    static func forListening(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // List markers and headings at the start of a line: "- ", "* ", "• ", "1. ", "2) ", "## ".
            line = line.replacingOccurrences(of: #"^(?:[-*•‣]+|\d{1,3}[.)]|#{1,6})\s+"#, with: "",
                                             options: .regularExpression)
            if !line.isEmpty { lines.append(line) }
        }
        var joined = lines.joined(separator: " ")
        // Asides in brackets: (…), […], {…}, and the full-width （…） 【…】.
        joined = joined.replacingOccurrences(of: #"\s*[\(\[\{（【][^\)\]\}）】]*[\)\]\}）】]"#, with: "",
                                             options: .regularExpression)
        // Markdown emphasis and code marks.
        joined = joined.replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
        joined = joined.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // A space left before punctuation by a removed aside ("Holden , who").
        joined = joined.replacingOccurrences(of: #"\s+([,.;:!?，。；：！？])"#, with: "$1",
                                             options: .regularExpression)
        let cleaned = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    /// Sentences of `text`, each keeping its closing punctuation (and a closing quote right after
    /// it). `. ! ? …` end a sentence only before whitespace or the end, so "3.5" stays whole; the
    /// CJK `。！？` always end one.
    static func sentences(_ text: String) -> [String] {
        let western: Set<Character> = [".", "!", "?", "…"]
        let cjk: Set<Character> = ["。", "！", "？"]
        let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", ")"]
        let chars = Array(text)
        var result: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if western.contains(c) || cjk.contains(c) {
                // Absorb a run of terminators and closing quotes ("?!", ".”").
                while i + 1 < chars.count, western.contains(chars[i + 1]) || cjk.contains(chars[i + 1])
                        || closers.contains(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let atEnd = i + 1 >= chars.count
                if cjk.contains(c) || atEnd || chars[i + 1].isWhitespace {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = ""
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    // MARK: SSML

    /// `<speak><prosody rate="80%">One.<break time="350ms"/>Two.</prosody></speak>`, XML-escaped.
    static func ssml(for text: String, ratePercent: Int = ratePercent,
                     pauseMs: Int = sentencePauseMs) -> String {
        let parts = sentences(text).map(escapeXML)
        let body = parts.joined(separator: "<break time=\"\(pauseMs)ms\"/>")
        return "<speak><prosody rate=\"\(ratePercent)%\">\(body)</prosody></speak>"
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: Utterance

    /// The utterance to speak `text` with: cleaned, paced SSML in `voice` (nil = system default),
    /// or the plain fallback when the SSML is refused.
    static func utterance(for text: String, voice: AVSpeechSynthesisVoice?) -> AVSpeechUtterance {
        let spoken = forListening(text)
        let utterance: AVSpeechUtterance
        if let ssml = AVSpeechUtterance(ssmlRepresentation: ssml(for: spoken)) {
            utterance = ssml
        } else {
            utterance = AVSpeechUtterance(string: spoken)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            utterance.postUtteranceDelay = Double(sentencePauseMs) / 1000
        }
        if let voice { utterance.voice = voice }
        utterance.prefersAssistiveTechnologySettings = true
        return utterance
    }
}
