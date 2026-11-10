import Foundation

/// Batch 463: one stamp in the Listening Passport. Pure value, derived from the finished-book
/// catalog; nothing is persisted.
nonisolated struct PassportStamp: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case genre, narrator, decade, milestone
    }

    let kind: Kind
    /// Normalised identity (lowercased, whitespace-collapsed; the decade start year; the milestone threshold).
    let key: String
    /// Display text for genre/narrator/decade ("Fantasy", "Jim Dale", "1990s"); the threshold digits for a milestone.
    let name: String
    /// The earliest `finishedAt` among the books that earned the stamp (for a milestone, the finish that crossed it).
    let earnedAt: Date
    let earnedByBookID: String
    let earnedByTitle: String
    /// Books that count towards this stamp (always 1 for a milestone's own book).
    let count: Int
    /// The most recent finish among those books (used to break "top" ties).
    let latestAt: Date

    var id: String { "\(kind.rawValue):\(key)" }
    /// Milestone threshold, nil for other kinds.
    var threshold: Int? { kind == .milestone ? Int(key) : nil }
}

nonisolated struct PassportSummary: Equatable, Sendable {
    var topGenre: String?
    var favouriteNarrator: String?
}

/// Batch 463: the stamp rules. Genre, narrator and decade stamps are earned by the first book
/// finished with that attribute; milestone stamps by the finish that reaches 1/5/10/25/50/100.
nonisolated enum PassportStamps {
    static let milestoneThresholds = [1, 5, 10, 25, 50, 100]

    /// Lowercased, trimmed, inner whitespace collapsed. Empty result means "no value".
    static func normalised(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    static func cleaned(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "1990s" for 1999; 1899 is "1890s". Nil years are skipped by callers.
    static func decadeStart(of year: Int) -> Int { Int((Double(year) / 10).rounded(.down)) * 10 }

    /// All earned stamps. Each kind is sorted newest-earned first (ties by name).
    static func stamps(from books: [FinishedBook]) -> [PassportStamp] {
        let ordered = books.sorted { $0.finishedAt < $1.finishedAt }
        var out: [PassportStamp] = []
        out += attributeStamps(.genre, ordered) { $0.genres }
        out += attributeStamps(.narrator, ordered) { book in
            book.narrators.isEmpty ? FinishedBook.splitNarrators(book.narratorName) : book.narrators
        }
        out += attributeStamps(.decade, ordered) { book in
            book.publishedYear.map { y in ["\(decadeStart(of: y))"] } ?? []
        }
        for n in milestoneThresholds where ordered.count >= n {
            let b = ordered[n - 1]
            out.append(PassportStamp(kind: .milestone, key: String(n), name: String(n), earnedAt: b.finishedAt,
                                     earnedByBookID: b.id, earnedByTitle: b.title, count: 1, latestAt: b.finishedAt))
        }
        return out.sorted { a, b in
            if a.kind != b.kind { return PassportStamp.Kind.order(a.kind) < PassportStamp.Kind.order(b.kind) }
            if a.earnedAt != b.earnedAt { return a.earnedAt > b.earnedAt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func stamps(_ kind: PassportStamp.Kind, in all: [PassportStamp]) -> [PassportStamp] {
        all.filter { $0.kind == kind }
    }

    /// Most books wins; ties go to the one finished most recently, then alphabetically.
    static func summary(_ books: [FinishedBook]) -> PassportSummary {
        let all = stamps(from: books)
        return PassportSummary(topGenre: top(.genre, all)?.name, favouriteNarrator: top(.narrator, all)?.name)
    }

    private static func top(_ kind: PassportStamp.Kind, _ all: [PassportStamp]) -> PassportStamp? {
        stamps(kind, in: all).min { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.latestAt != b.latestAt { return a.latestAt > b.latestAt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// `books` must be sorted oldest first so the first book seen for a key is the earner.
    private static func attributeStamps(_ kind: PassportStamp.Kind, _ books: [FinishedBook],
                                        values: (FinishedBook) -> [String]) -> [PassportStamp] {
        var byKey: [String: PassportStamp] = [:]
        for book in books {
            var seen = Set<String>()
            for raw in values(book) {
                let key = normalised(raw)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if let existing = byKey[key] {
                    byKey[key] = PassportStamp(kind: kind, key: key, name: existing.name, earnedAt: existing.earnedAt,
                                               earnedByBookID: existing.earnedByBookID,
                                               earnedByTitle: existing.earnedByTitle,
                                               count: existing.count + 1, latestAt: max(existing.latestAt, book.finishedAt))
                } else {
                    let name = kind == .decade ? "\(key)s" : cleaned(raw)
                    byKey[key] = PassportStamp(kind: kind, key: key, name: name, earnedAt: book.finishedAt,
                                               earnedByBookID: book.id, earnedByTitle: book.title,
                                               count: 1, latestAt: book.finishedAt)
                }
            }
        }
        return Array(byKey.values)
    }
}

fileprivate extension PassportStamp.Kind {
    static func order(_ k: PassportStamp.Kind) -> Int {
        switch k {
        case .milestone: return 0
        case .genre: return 1
        case .narrator: return 2
        case .decade: return 3
        }
    }
}
