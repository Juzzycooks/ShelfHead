import Foundation

/// Batch 445: "Ask" in Library search. A listener types what they feel like ("something cosy under 8 hours by
/// a narrator I've starred", "a short unplayed mystery") and the app answers from the books it already has.
///
/// This file is the pure part: the query value type, a rule-based parser that works with no AI, and the
/// filter + ranker. Everything runs on device over the library snapshot; no network, no I/O. The optional
/// Apple Intelligence reading of the sentence lives in `MoodQueryModel.swift` and always merges with, and
/// falls back to, `MoodRuleParser`.

/// What a typed sentence was understood to mean.
nonisolated struct MoodQuery: Equatable, Sendable {
    /// Library genre names (spelled as the library spells them). A book must have at least one.
    var genres: [String] = []
    /// Mood or flavour words ("cosy", "dark", "funny"), matched against genres, title and description.
    var toneWords: [String] = []
    var minHours: Double?
    var maxHours: Double?
    /// Only books by a narrator the listener has starred.
    var starredNarrator = false
    /// Only books by an author the listener has starred.
    var starredAuthor = false
    var unplayedOnly = false
    /// A language name as the library spells it ("English"); matched case-insensitively.
    var language: String?

    /// True when nothing at all was understood, so there is nothing to search for.
    var isEmpty: Bool {
        genres.isEmpty && toneWords.isEmpty && minHours == nil && maxHours == nil
            && !starredNarrator && !starredAuthor && !unplayedOnly && language == nil
    }

    /// Merges `other` (the model's reading) into `self` (the rule parser's). Whatever the rules found
    /// explicitly wins for numbers and language; flags are OR-ed; word lists are unioned in order.
    func merged(withModel other: MoodQuery, knownGenres: [String]) -> MoodQuery {
        var out = self
        let known = Dictionary(knownGenres.map { (MoodRuleParser.stem($0), $0) }, uniquingKeysWith: { a, _ in a })
        for g in other.genres {
            guard let canonical = known[MoodRuleParser.stem(g)] else { continue }
            if !out.genres.contains(canonical) { out.genres.append(canonical) }
        }
        for w in other.toneWords {
            let lw = w.lowercased()
            if !out.toneWords.contains(lw), !out.genres.contains(where: { MoodRuleParser.stem($0) == MoodRuleParser.stem(lw) }) {
                out.toneWords.append(lw)
            }
        }
        if out.minHours == nil { out.minHours = other.minHours }
        if out.maxHours == nil { out.maxHours = other.maxHours }
        out.starredNarrator = out.starredNarrator || other.starredNarrator
        out.starredAuthor = out.starredAuthor || other.starredAuthor
        out.unplayedOnly = out.unplayedOnly || other.unplayedOnly
        if out.language == nil { out.language = other.language }
        return out
    }
}

// MARK: - Rule parser

/// Reads a typed sentence without any AI. Pure.
nonisolated enum MoodRuleParser {
    /// "short" means under this many hours.
    static let shortHours = 6.0
    /// "long" means over this many hours.
    static let longHours = 15.0

    private static let languages = ["english", "spanish", "french", "german", "italian", "portuguese", "dutch",
                                    "swedish", "norwegian", "danish", "polish", "russian", "japanese", "chinese"]

    /// Words that carry no mood once the structure is read out.
    private static let filler: Set<String> = [
        "something", "anything", "book", "books", "audiobook", "audiobooks", "story", "stories", "listen",
        "listening", "want", "wanna", "looking", "look", "find", "show", "give", "like", "some", "ve", "ll", "im",
        "need", "feel", "feeling", "please", "good", "great", "new", "starred", "star", "favourite", "favorite",
        "favourites", "favorites", "narrator", "narrators", "author", "authors", "hours", "hour", "hrs", "hr",
        "unplayed", "unread", "short", "long", "quick", "english", "spanish", "french", "german", "italian"
    ]

    /// Cheap singular form so "mysteries" meets "Mystery" and "thrillers" meets "Thriller".
    static func stem(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { word -> String in
            var w = String(word)
            if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
            else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w = String(w.dropLast()) }
            return w
        }.joined(separator: " ")
    }

    static func parse(_ text: String, knownGenres: [String]) -> MoodQuery {
        var q = MoodQuery()
        var rest = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "

        // Hours. Ranges first, then the bounds.
        let num = #"(\d+(?:\.\d+)?|\d+\s*(?:and a half))"#
        let unit = #"\s*(?:hours?|hrs?|h)\b"#
        if let m = firstMatch(#"between\s+"# + num + #"\s*(?:and|to|-)\s*"# + num + unit, in: rest) {
            let a = number(m.groups[0]), b = number(m.groups[1])
            q.minHours = min(a, b); q.maxHours = max(a, b)
            rest.replaceSubrange(m.range, with: " ")
        }
        if q.maxHours == nil, let m = firstMatch(#"\b(?:under|below|less than|shorter than|fewer than|within|up to|max(?:imum)?(?: of)?|no more than)\s+"# + num + unit, in: rest) {
            q.maxHours = number(m.groups[0])
            rest.replaceSubrange(m.range, with: " ")
        }
        if q.minHours == nil, let m = firstMatch(#"\b(?:over|above|more than|longer than|at least|minimum(?: of)?)\s+"# + num + unit, in: rest) {
            q.minHours = number(m.groups[0])
            rest.replaceSubrange(m.range, with: " ")
        }
        if q.maxHours == nil, let m = firstMatch(num + unit + #"\s*(?:or|and)\s*(?:less|under|shorter)"#, in: rest) {
            q.maxHours = number(m.groups[0])
            rest.replaceSubrange(m.range, with: " ")
        }
        if q.minHours == nil, let m = firstMatch(num + unit + #"\s*(?:or|and)\s*(?:more|over|longer)"#, in: rest) {
            q.minHours = number(m.groups[0])
            rest.replaceSubrange(m.range, with: " ")
        }
        if q.maxHours == nil, let m = firstMatch(#"\b(short|quick)\b"#, in: rest) {
            q.maxHours = shortHours
            rest.replaceSubrange(m.range, with: " ")
        }
        if q.minHours == nil, let m = firstMatch(#"\b(long|lengthy|epic)\b"#, in: rest) {
            q.minHours = longHours
            rest.replaceSubrange(m.range, with: " ")
        }

        // Progress.
        let unplayed = #"\b(?:unplayed|unread|unlistened|not started|never (?:played|listened(?: to)?|started)|(?:haven't|have not|hasn't) (?:played|listened(?: to)?|started|read)|new to me|not yet (?:played|listened|started))\b"#
        if let m = firstMatch(unplayed, in: rest) {
            q.unplayedOnly = true
            rest.replaceSubrange(m.range, with: " ")
        }

        // Starred people.
        let star = #"(?:starred|stared|favou?rite|favou?rited|liked)"#
        let narratorPatterns = [
            #"\b(?:by )?(?:a |an |the |my )?narrators? (?:that |who )?i(?:'ve| have)? "# + star + #"\b"#,
            #"\b(?:by )?(?:a |an |my |the |one of my )?"# + star + #" narrators?\b"#,
            #"\b(?:narrated by )?(?:a )?narrators? i (?:like|love)\b"#
        ]
        for p in narratorPatterns {
            if let m = firstMatch(p, in: rest) { q.starredNarrator = true; rest.replaceSubrange(m.range, with: " "); break }
        }
        let authorPatterns = [
            #"\b(?:by )?(?:a |an |the |my )?authors? (?:that |who )?i(?:'ve| have)? "# + star + #"\b"#,
            #"\b(?:by )?(?:a |an |my |the |one of my )?"# + star + #" authors?\b"#,
            #"\b(?:by )?(?:an )?authors? i (?:like|love)\b"#
        ]
        for p in authorPatterns {
            if let m = firstMatch(p, in: rest) { q.starredAuthor = true; rest.replaceSubrange(m.range, with: " "); break }
        }

        // Language: "in english".
        for lang in languages {
            if let m = firstMatch(#"\bin "# + lang + #"\b"#, in: rest) {
                q.language = lang.capitalized
                rest.replaceSubrange(m.range, with: " ")
                break
            }
        }

        // Genres from the library's own list. Longest first so "science fiction" beats "fiction".
        var words = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        var stems = words.map { stem($0) }
        let candidates = knownGenres.map { ($0, stem($0).split(separator: " ").map(String.init)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        for (genre, gStem) in candidates {
            var i = 0
            while i + gStem.count <= stems.count {
                if Array(stems[i..<(i + gStem.count)]) == gStem {
                    if !q.genres.contains(genre) { q.genres.append(genre) }
                    words.removeSubrange(i..<(i + gStem.count))
                    stems.removeSubrange(i..<(i + gStem.count))
                } else {
                    i += 1
                }
            }
        }

        // The rest are tone words.
        for t in BM25.tokens(words.joined(separator: " ")) where !filler.contains(t) {
            if !q.toneWords.contains(t) { q.toneWords.append(t) }
        }
        return q
    }

    // MARK: Regex helpers

    private struct Match { var range: Range<String.Index>; var groups: [String] }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: ns), let r = Range(m.range, in: text) else { return nil }
        var groups: [String] = []
        if m.numberOfRanges > 1 {
            for i in 1..<m.numberOfRanges {
                if let gr = Range(m.range(at: i), in: text) { groups.append(String(text[gr])) }
            }
        }
        return Match(range: r, groups: groups)
    }

    private static func number(_ raw: String) -> Double {
        let lower = raw.lowercased()
        if lower.contains("and a half") {
            let digits = lower.prefix { $0.isNumber || $0 == "." }
            return (Double(digits) ?? 0) + 0.5
        }
        return Double(lower.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

// MARK: - Filter and ranking

/// One reason a book is in the results, rendered by the view ("Mystery · 6h 10m · unplayed").
nonisolated enum MoodReason: Equatable, Sendable {
    case genre(String)
    case duration(Double)
    case unplayed
    case inProgress
    case starredNarrator
    case starredAuthor
    case language(String)
}

nonisolated struct MoodMatch: Identifiable, Sendable {
    var item: LibraryItem
    var reasons: [MoodReason]
    var id: String { item.id }
}

nonisolated enum MoodFilter {
    /// Splits "A, B & C" style credit strings into single names.
    static func names(_ credit: String?) -> [String] {
        guard let credit else { return [] }
        return credit.replacingOccurrences(of: " & ", with: ",").replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The distinct genre names across `items`, most common first. The parser matches typed words against these.
    static func genreList(_ items: [LibraryItem]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items where !item.isPodcast {
            for g in item.media?.metadata?.genres ?? [] {
                let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { counts[t, default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Hard filters first, then BM25 over genres, title, series and description.
    ///
    /// - Genres are a hard filter (any one of them). Without genres, tone words are required to match
    ///   (BM25 score > 0); with genres they only reorder. A query with nothing in it returns nothing.
    /// - With only hard filters, starred and newest books come first.
    /// - Tags are not part of the decoded `LibraryItem` model, so they are not searched.
    static func rank(
        query: MoodQuery,
        items: [LibraryItem],
        progress: (LibraryItem) -> MediaProgress?,
        isStarredNarrator: (String) -> Bool,
        isStarredAuthor: (String) -> Bool,
        limit: Int = 100
    ) -> [MoodMatch] {
        guard !query.isEmpty else { return [] }
        let genreStems = Set(query.genres.map { MoodRuleParser.stem($0) })

        var kept: [(item: LibraryItem, reasons: [MoodReason], starred: Bool)] = []
        for item in items where !item.isPodcast {
            var reasons: [MoodReason] = []
            let hours = item.duration / 3600
            if query.minHours != nil || query.maxHours != nil {
                guard item.duration > 0 else { continue }
                if let lo = query.minHours, hours < lo { continue }
                if let hi = query.maxHours, hours > hi { continue }
            }
            if !genreStems.isEmpty {
                let matched = (item.media?.metadata?.genres ?? []).first { genreStems.contains(MoodRuleParser.stem($0)) }
                guard let matched else { continue }
                reasons.append(.genre(matched))
            }
            let mp = progress(item) ?? item.mediaProgress
            let started = (mp?.currentTime ?? 0) > 0 || (mp?.progress ?? 0) > 0
            if query.unplayedOnly {
                if mp?.isFinished == true || started { continue }
            }
            var starred = false
            if query.starredNarrator {
                guard MoodFilter.names(item.narratorName).contains(where: isStarredNarrator) else { continue }
                starred = true
            }
            if query.starredAuthor {
                guard MoodFilter.names(item.media?.metadata?.authorName).contains(where: isStarredAuthor) else { continue }
                starred = true
            }
            if let lang = query.language {
                guard let l = item.media?.metadata?.language, l.lowercased().contains(lang.lowercased()) else { continue }
                reasons.append(.language(l))
            }
            if item.duration > 0 { reasons.append(.duration(item.duration)) }
            if query.unplayedOnly { reasons.append(.unplayed) }
            else if started, mp?.isFinished != true { reasons.append(.inProgress) }
            if query.starredNarrator { reasons.append(.starredNarrator) }
            if query.starredAuthor { reasons.append(.starredAuthor) }
            kept.append((item, reasons, starred))
        }
        guard !kept.isEmpty else { return [] }

        let words = query.genres + query.toneWords
        var order = Array(kept.indices)
        if !words.isEmpty {
            let docs = kept.map { entry -> String in
                let md = entry.item.media?.metadata
                let genres = (md?.genres ?? []).joined(separator: " ")
                return [genres, genres, md?.title ?? "", md?.subtitle ?? "", md?.seriesName ?? "", md?.description ?? ""]
                    .joined(separator: " ")
            }
            let hits = BM25.rank(query: words.joined(separator: " "), documents: docs, k: docs.count)
            if query.genres.isEmpty {
                order = hits
            } else {
                let hitSet = Set(hits)
                order = hits + kept.indices.filter { !hitSet.contains($0) }.sorted { newer(kept[$0].item, kept[$1].item) }
            }
        } else {
            order.sort { newer(kept[$0].item, kept[$1].item) }
        }
        return order.prefix(limit).map { MoodMatch(item: kept[$0].item, reasons: kept[$0].reasons) }
    }

    private static func newer(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        (a.addedAt ?? 0) != (b.addedAt ?? 0) ? (a.addedAt ?? 0) > (b.addedAt ?? 0) : a.id < b.id
    }
}
