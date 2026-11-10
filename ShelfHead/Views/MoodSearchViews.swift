import SwiftUI

/// Batch 445: the one-line "why" under a book in Ask results, e.g. "Mystery · 6h 10m · unplayed".
enum MoodReasonText {
    static func line(_ reasons: [MoodReason]) -> String {
        reasons.map { text($0) }.joined(separator: " \u{00B7} ")
    }

    static func text(_ reason: MoodReason) -> String {
        switch reason {
        case .genre(let g): return g
        case .duration(let seconds): return seconds.formattedDuration
        case .unplayed: return String(localized: "unplayed", comment: "Ask results: why a book matched, it hasn't been started")
        case .inProgress: return String(localized: "in progress", comment: "Ask results: why a book matched, it has been started")
        case .starredNarrator: return String(localized: "starred narrator", comment: "Ask results: why a book matched")
        case .starredAuthor: return String(localized: "starred author", comment: "Ask results: why a book matched")
        case .language(let l): return l
        }
    }

    /// A short "what I understood" line for the top of the results.
    static func understood(_ q: MoodQuery) -> String {
        var parts: [String] = q.genres
        parts.append(contentsOf: q.toneWords)
        if let lo = q.minHours, let hi = q.maxHours {
            parts.append(String(localized: "\(lo.formatted()) to \(hi.formatted()) hours", comment: "Ask search: understood length range"))
        } else if let hi = q.maxHours {
            parts.append(String(localized: "under \(hi.formatted()) hours", comment: "Ask search: understood maximum length"))
        } else if let lo = q.minHours {
            parts.append(String(localized: "over \(lo.formatted()) hours", comment: "Ask search: understood minimum length"))
        }
        if q.unplayedOnly { parts.append(text(.unplayed)) }
        if q.starredNarrator { parts.append(text(.starredNarrator)) }
        if q.starredAuthor { parts.append(text(.starredAuthor)) }
        if let l = q.language { parts.append(l) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A book row in Ask results: cover, title, author and the reasons it matched.
struct MoodResultRow: View {
    let match: MoodMatch

    private var why: String { MoodReasonText.line(match.reasons) }

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(itemId: match.item.id, width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Typo.rowTitle(Text(verbatim: match.item.title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)
                Typo.rowSubtitle(Text(verbatim: match.item.authorName))
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(1)
                if !why.isEmpty {
                    Typo.fine(Text(verbatim: why))
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([match.item.title, match.item.authorName, why].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
