import Foundation

/// Batch 442: pure decisions for the release radar. No I/O, no clock: callers pass `today` and a
/// calendar, so day maths is deterministic in tests.
nonisolated enum ReleaseRadarPlanner {

    // MARK: Inputs

    /// What the planner needs to know about one library book.
    struct LibraryBook: Equatable, Sendable {
        var asin: String?
        var author: String
        var language: String?
        /// The user has started or finished it.
        var isStarted: Bool
        /// (series name, sequence in that series)
        var series: [(name: String, sequence: Double?)]

        static func == (l: LibraryBook, r: LibraryBook) -> Bool {
            l.asin == r.asin && l.author == r.author && l.language == r.language && l.isStarted == r.isStarted
                && l.series.count == r.series.count
                && zip(l.series, r.series).allSatisfy { $0.name == $1.name && $0.sequence == $1.sequence }
        }
    }

    /// A series worth asking Audible about.
    struct SeriesTarget: Equatable, Sendable {
        var key: String          // normalised name
        var name: String
        var author: String
        var language: String?
        var maxOwnedSequence: Double
        var ownedASINs: Set<String>
        /// Some owned book's ASIN, used to find the series ASIN precisely.
        var sampleASIN: String?
    }

    // MARK: Outputs

    enum Status: Equatable, Sendable {
        case upcoming(daysUntil: Int)
        case outNotInLibrary
    }

    struct RadarEntry: Codable, Equatable, Identifiable, Sendable {
        var seriesName: String
        var sequence: Double
        var title: String
        var author: String
        var releaseDate: Date
        var asin: String
        var coverURL: URL?
        var id: String { asin }

        func status(today: Date, calendar: Calendar) -> Status {
            ReleaseRadarPlanner.status(releaseDate: releaseDate, today: today, calendar: calendar)
        }
    }

    // MARK: Helpers

    /// Case/diacritic/punctuation-insensitive series key; drops a leading "the" and a trailing "series".
    static func normalisedSeriesKey(_ name: String) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        s = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var words = s.split(separator: " ").map(String.init)
        if words.first == "the" { words.removeFirst() }
        if words.last == "series", words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Whole calendar days from `today` to `releaseDate` (negative once released).
    static func daysUntil(_ releaseDate: Date, today: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: today)
        let b = calendar.startOfDay(for: releaseDate)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    static func status(releaseDate: Date, today: Date, calendar: Calendar) -> Status {
        let d = daysUntil(releaseDate, today: today, calendar: calendar)
        return d > 0 ? .upcoming(daysUntil: d) : .outNotInLibrary
    }

    /// `yyyy-MM-dd` -> start of that day in `calendar`.
    static func parseReleaseDate(_ s: String?, calendar: Calendar) -> Date? {
        guard let s else { return nil }
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps).map { calendar.startOfDay(for: $0) }
    }

    // MARK: Which series to check

    /// Series where the user has started or finished at least one book, in a stable order, windowed
    /// to `cap` entries starting at `rotation` (wrapping) so a big library is covered over several days.
    static func seriesToCheck(books: [LibraryBook], cap: Int, rotation: Int = 0) -> (targets: [SeriesTarget], nextRotation: Int) {
        var byKey: [String: SeriesTarget] = [:]
        var started: Set<String> = []
        for book in books {
            for ref in book.series {
                let key = normalisedSeriesKey(ref.name)
                guard !key.isEmpty else { continue }
                var t = byKey[key] ?? SeriesTarget(key: key, name: ref.name, author: book.author, language: book.language,
                                                   maxOwnedSequence: 0, ownedASINs: [], sampleASIN: nil)
                if let seq = ref.sequence { t.maxOwnedSequence = max(t.maxOwnedSequence, seq) }
                if let asin = book.asin, !asin.isEmpty {
                    t.ownedASINs.insert(asin)
                    if t.sampleASIN == nil { t.sampleASIN = asin }
                }
                if t.language == nil { t.language = book.language }
                byKey[key] = t
                if book.isStarted { started.insert(key) }
            }
        }
        let all = started.sorted().compactMap { byKey[$0] }
        guard !all.isEmpty, cap > 0 else { return ([], 0) }
        // Review 3 Low (Release Radar rotation): when everything fits, still honour the offset so a stopped run's
        // unchecked series come first. The next offset stays put (the full order is one window).
        if all.count <= cap {
            let offset = ((rotation % all.count) + all.count) % all.count
            return (Array(all[offset...] + all[..<offset]), 0)
        }
        let start = ((rotation % all.count) + all.count) % all.count
        let window = (0..<cap).map { all[(start + $0) % all.count] }
        return (window, (start + cap) % all.count)
    }

    // MARK: Plan

    /// Later books per target. `catalog` maps a target `key` to the products fetched for it.
    static func plan(targets: [SeriesTarget], catalog: [String: [CatalogProduct]], today: Date, calendar: Calendar) -> [RadarEntry] {
        var entries: [RadarEntry] = []
        for target in targets {
            guard let products = catalog[target.key] else { continue }
            // Candidates for this series with their sequence.
            var bySequence: [Double: [(CatalogProduct, Date)]] = [:]
            for p in products {
                guard !target.ownedASINs.contains(p.asin),
                      let ref = p.series.first(where: { normalisedSeriesKey($0.title ?? "") == target.key }),
                      let seq = ref.sequence, seq > target.maxOwnedSequence,
                      let date = parseReleaseDate(p.releaseDate, calendar: calendar),
                      (p.title ?? "").isEmpty == false
                else { continue }
                if let want = target.language, want.count > 3, let have = p.language,
                   want.lowercased() != have.lowercased() { continue }
                bySequence[seq, default: []].append((p, date))
            }
            for (seq, candidates) in bySequence {
                // Prefer unabridged, then the earliest release.
                let best = candidates.min { a, b in
                    let au = (a.0.formatType ?? "unabridged").lowercased() == "unabridged"
                    let bu = (b.0.formatType ?? "unabridged").lowercased() == "unabridged"
                    if au != bu { return au }
                    if a.1 != b.1 { return a.1 < b.1 }
                    return a.0.asin < b.0.asin
                }!
                let p = best.0
                entries.append(RadarEntry(
                    seriesName: target.name, sequence: seq, title: p.title ?? "",
                    author: p.authors.first ?? target.author, releaseDate: best.1, asin: p.asin,
                    coverURL: p.coverURL.flatMap(URL.init(string:))))
            }
        }
        return sorted(entries, today: today, calendar: calendar)
    }

    /// Upcoming soonest first, then released newest first; ties by series then sequence.
    static func sorted(_ entries: [RadarEntry], today: Date, calendar: Calendar) -> [RadarEntry] {
        func isUpcoming(_ e: RadarEntry) -> Bool { daysUntil(e.releaseDate, today: today, calendar: calendar) > 0 }
        return entries.sorted { a, b in
            let au = isUpcoming(a), bu = isUpcoming(b)
            if au != bu { return au }
            if a.releaseDate != b.releaseDate { return au ? a.releaseDate < b.releaseDate : a.releaseDate > b.releaseDate }
            if a.seriesName != b.seriesName { return a.seriesName < b.seriesName }
            return a.sequence < b.sequence
        }
    }
}

extension ReleaseRadarPlanner.LibraryBook {
    /// Maps a library item (series refs, asin, author, user progress).
    init(item: LibraryItem) {
        let meta = item.media?.metadata
        var refs: [(name: String, sequence: Double?)] = (meta?.series ?? []).compactMap { r in
            guard let n = r.name, !n.isEmpty else { return nil }
            return (n, r.sequence)
        }
        if refs.isEmpty, let n = meta?.seriesName, !n.isEmpty {
            // "Name #5" display string: keep the bare name, take the number from the metadata helper.
            let bare = n.components(separatedBy: " #").first ?? n
            refs = [(bare, meta?.seriesSequence)]
        }
        self.init(asin: meta?.asin, author: meta?.authorName ?? "", language: meta?.language,
                  isStarted: item.isFinished || (item.mediaProgress?.progress ?? 0) > 0,
                  series: refs)
    }
}
