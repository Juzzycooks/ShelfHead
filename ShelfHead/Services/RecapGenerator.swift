import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Facts distilled from a `LibraryItem` + its progress, used to build a "Where you
/// left off" recap card on `BookDetailView`. Kept separate from `LibraryItem` so the
/// template/model generators stay pure and testable without a live server.
struct RecapFacts: Equatable {
    var title: String
    var author: String
    var seriesLine: String?
    var chapterTitle: String?
    var chapterNumber: Int?
    var chapterCount: Int?
    var progress: Double // 0...1
    var remainingSeconds: Double
    var lastListened: Date?
    var descriptionExcerpt: String?
}

/// Generates the recap card's text: an instant deterministic template, optionally
/// upgraded on-device by FoundationModels (iOS 26+) when Apple Intelligence is
/// available. The template is the source of truth everywhere else (older OS, model
/// unavailable, model times out).
enum RecapGenerator {

    /// Pure, deterministic 1-2 sentence recap. No model, no I/O — safe to unit test.
    nonisolated static func templateRecap(_ f: RecapFacts, now: Date = Date()) -> String {
        let percent = Int((f.progress * 100).rounded())
        var sentence: String
        if let series = f.seriesLine {
            sentence = String(localized: "You're \(percent)% through \(f.title) by \(f.author) (\(series))", comment: "Recap sentence start. %lld is percent complete, then book title, author, series line")
        } else {
            sentence = String(localized: "You're \(percent)% through \(f.title) by \(f.author)", comment: "Recap sentence start. %lld is percent complete, then book title, author")
        }
        if f.chapterNumber != nil || f.chapterTitle != nil {
            var chapterPart = ""
            var wroteNumber = false
            if let n = f.chapterNumber {
                if let count = f.chapterCount {
                    chapterPart = String(localized: "chapter \(n) of \(count)", comment: "Recap chapter position. First %lld is the chapter number, second is the chapter count")
                } else {
                    chapterPart = String(localized: "chapter \(n)", comment: "Recap chapter position. %lld is the chapter number")
                }
                wroteNumber = true
            }
            if let title = f.chapterTitle, !title.isEmpty {
                if wroteNumber {
                    chapterPart = String(localized: "\(chapterPart), \"\(title)\"", comment: "Recap chapter position with title. First %@ is e.g. 'chapter 3 of 20', second is the chapter title")
                } else {
                    chapterPart = String(localized: "chapter \"\(title)\"", comment: "Recap chapter position with only a title. %@ is the chapter title")
                }
            }
            sentence = String(localized: "\(sentence) \u{2014} \(chapterPart)", comment: "Recap: book position followed by chapter position. First %@ is the sentence so far, second the chapter position")
        }
        sentence = String(localized: "\(sentence).", comment: "Recap: closes a sentence. %@ is the sentence without its final period")

        var second = String(localized: "About \(remainingLabel(seconds: f.remainingSeconds)) left", comment: "Recap: time remaining. %@ is e.g. '2 h 5 m' or 'under a minute'")
        if let last = f.lastListened {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            let relative = formatter.localizedString(for: last, relativeTo: now)
            second = String(localized: "\(second); last listened \(relative)", comment: "Recap: time remaining plus when last listened. First %@ is the time-remaining clause, second is a relative date such as 'yesterday'")
        }
        second = String(localized: "\(second).", comment: "Recap: closes a sentence. %@ is the sentence without its final period")

        return sentence + " " + second
    }

    /// Pure formatting for remaining listening time. "H h M m" / "M m" (<1h) /
    /// "under a minute" (<1m).
    nonisolated static func remainingLabel(seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let minutes = total / 60
        if minutes < 1 { return String(localized: "under a minute", comment: "Remaining time label, less than one minute") }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours < 1 { return String(localized: "\(mins) m", comment: "Remaining time. %lld is minutes") }
        return String(localized: "\(hours) h \(mins) m", comment: "Remaining time. First %lld is hours, second is minutes")
    }

    /// Attempts an on-device model recap; nil on unavailability, error, timeout, or an
    /// implausible response (empty / too long). Never throws.
    static func modelRecap(_ f: RecapFacts) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let prompt = modelPrompt(for: f)
        let instructions = """
        You write a short, friendly "where you left off" note for an audiobook \
        listener returning to a book. Use ONLY the facts given below — never invent \
        plot details, characters, or events. Do not ask questions. Write exactly two \
        plain-text sentences, spoiler-free, no markdown.
        """

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let response = try? await session.respond(to: prompt)
                return response?.content
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()

            guard let text = first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 400 else { return nil }
            return text
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    private static func modelPrompt(for f: RecapFacts) -> String {
        let percent = Int((f.progress * 100).rounded())
        var lines = [
            "Title: \(f.title)",
            "Author: \(f.author)"
        ]
        if let series = f.seriesLine {
            lines.append("Series: \(series)")
        }
        if f.chapterNumber != nil || f.chapterTitle != nil || f.chapterCount != nil {
            var chapter = "Chapter:"
            if let n = f.chapterNumber { chapter += " \(n)" }
            if let count = f.chapterCount { chapter += " of \(count)" }
            if let title = f.chapterTitle { chapter += " \"\(title)\"" }
            lines.append(chapter)
        }
        lines.append("Percent complete: \(percent)%")
        lines.append("Time left: \(remainingLabel(seconds: f.remainingSeconds))")
        if let last = f.lastListened {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            lines.append("Last listened: \(formatter.localizedString(for: last, relativeTo: Date()))")
        }
        if let excerpt = f.descriptionExcerpt, !excerpt.isEmpty {
            lines.append("Description excerpt: \(String(excerpt.prefix(400)))")
        }
        return lines.joined(separator: "\n")
    }
    #endif

    /// Derives recap facts from a detailed `LibraryItem`, or nil when there's nothing
    /// to recap (no progress yet, or already finished). `description` is passed in
    /// (already HTML-stripped by the caller) rather than re-stripped here.
    static func facts(for item: LibraryItem, description: String?, now: Date = Date()) -> RecapFacts? {
        guard let progressRecord = item.mediaProgress,
              let progress = progressRecord.progress,
              progress > 0,
              !(progressRecord.isFinished ?? false) else { return nil }

        let currentTime = progressRecord.currentTime ?? 0
        let duration = progressRecord.duration ?? item.duration
        let remaining = max(duration - currentTime, 0)

        var chapterTitle: String?
        var chapterNumber: Int?
        let chapters = item.chapters
        if let index = chapters.firstIndex(where: { currentTime >= $0.start && currentTime < $0.end }) {
            chapterTitle = chapters[index].title
            chapterNumber = index + 1
        }

        var lastListened: Date?
        if let ms = progressRecord.lastUpdate {
            lastListened = Date(timeIntervalSince1970: Double(ms) / 1000)
        }

        var seriesLine: String?
        if let series = item.seriesName {
            if let seq = item.seriesSequence {
                let n = seq.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(seq)) : String(seq)
                seriesLine = String(localized: "Book \(n) of \(series)", comment: "Series position. First %@ is the book number, second is the series name")
            } else {
                seriesLine = series
            }
        }

        return RecapFacts(
            title: item.title,
            author: item.authorName,
            seriesLine: seriesLine,
            chapterTitle: chapterTitle,
            chapterNumber: chapterNumber,
            chapterCount: chapters.isEmpty ? nil : chapters.count,
            progress: progress,
            remainingSeconds: remaining,
            lastListened: lastListened,
            descriptionExcerpt: description
        )
    }
}
