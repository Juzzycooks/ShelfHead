import Foundation

/// Batch 441: the Library Doctor's checks. Pure and nonisolated: it works on `DoctorBook`
/// snapshots (a plain value copy of the few fields it needs, built from a `LibraryItem` on the main
/// actor by `DoctorBook(item:)`), does no I/O and never deletes or changes anything. It only describes
/// problems and, where one has an obvious remedy, a `DoctorFix` the view model can offer; every fix is
/// previewed and confirmed before it is sent to the server.
///
/// Note on the data: the library list endpoint returns *minified* items, which carry `numChapters`
/// but no chapters, and `seriesName` ("Name #3") but no structured `series[]`. `DoctorBook` copes with
/// both shapes; the series parse is the display-string one, so a series whose name itself contains
/// ", " and no "#n" tail is read as one series.

// MARK: - Model

nonisolated enum DoctorFindingKind: String, CaseIterable, Sendable, Identifiable {
    case duplicate, missingCover, seriesMissingSequence, seriesDuplicateSequence, seriesGap, badChapters
    var id: String { rawValue }
}

nonisolated enum DoctorSeverity: Int, Comparable, Sendable {
    case info = 0, warning = 1
    static func < (a: DoctorSeverity, b: DoctorSeverity) -> Bool { a.rawValue < b.rawValue }
}

/// What a finding is about, as data the view turns into words.
nonisolated enum DoctorDetail: Equatable, Sendable {
    /// `reason` is which key matched.
    case duplicate(reason: DuplicateReason, key: String)
    case missingCover
    case seriesMissingSequence(series: String)
    case seriesDuplicateSequence(series: String, sequence: Double)
    /// Whole numbers absent between the lowest and highest numbered book.
    case seriesGap(series: String, missing: [Int])
    case badChapters(issues: [ChapterHealthIssue])
}

nonisolated enum DuplicateReason: String, Sendable { case asin, isbn, titleAndAuthor }

/// A remedy the app can apply, once the user confirms. Duplicates and gaps have none.
nonisolated enum DoctorFix: Equatable, Sendable {
    case setCover(itemId: String)
    case setSequence(itemId: String, series: String, proposed: Double)
    /// Replace the server chapters. The chapters come from a local accepted override when one
    /// exists (the view model checks); without one the user is pointed at chapter suggestions.
    case chapters(itemId: String)
}

nonisolated struct DoctorFinding: Identifiable, Equatable, Sendable {
    let id: String
    let kind: DoctorFindingKind
    let severity: DoctorSeverity
    /// The affected books, in display order.
    let itemIds: [String]
    /// A book title, or the series name, for the row heading.
    let subject: String
    let detail: DoctorDetail
    let fix: DoctorFix?
}

/// What the doctor reads from one book.
nonisolated struct DoctorBook: Equatable, Sendable {
    nonisolated struct SeriesEntry: Equatable, Sendable {
        var name: String
        var sequence: Double?
    }

    var id: String
    var title: String?
    var authorName: String?
    var asin: String?
    var isbn: String?
    var publishedYear: Int?
    var hasCover: Bool
    var isPodcast: Bool
    var isEbookOnly: Bool
    var series: [SeriesEntry]
    /// Already worked out with `ChapterHealth`; empty = healthy or not applicable.
    var chapterIssues: [ChapterHealthIssue]

    nonisolated init(id: String, title: String? = nil, authorName: String? = nil, asin: String? = nil,
                     isbn: String? = nil, publishedYear: Int? = nil, hasCover: Bool = true,
                     isPodcast: Bool = false, isEbookOnly: Bool = false, series: [SeriesEntry] = [],
                     chapterIssues: [ChapterHealthIssue] = []) {
        self.id = id
        self.title = title
        self.authorName = authorName
        self.asin = asin
        self.isbn = isbn
        self.publishedYear = publishedYear
        self.hasCover = hasCover
        self.isPodcast = isPodcast
        self.isEbookOnly = isEbookOnly
        self.series = series
        self.chapterIssues = chapterIssues
    }
}

// MARK: - Snapshot from LibraryItem

extension DoctorBook {
    /// Builds the snapshot on the main actor (LibraryItem is main-actor isolated).
    init(item: LibraryItem) {
        let meta = item.media?.metadata
        var refs: [SeriesEntry] = (meta?.series ?? []).compactMap { ref in
            guard let name = ref.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return SeriesEntry(name: name, sequence: ref.sequence)
        }
        if refs.isEmpty, let display = meta?.seriesName {
            refs = LibraryDoctor.parseSeriesDisplay(display)
        }
        let duration = item.media?.duration ?? 0
        let chapters: [Chapter]
        if let real = item.media?.chapters {
            chapters = real
        } else if let n = item.media?.numChapters, n >= 0, n <= 5000, duration > 0 {
            // Minified list items: stand in `n` equal chapters so `ChapterHealth` sees the count and the
            // average length (an over-long average is the best list-level hint of an overlong chapter).
            let each = duration / Double(max(n, 1))
            chapters = (0..<n).map {
                Chapter(id: $0, start: Double($0) * each, end: Double($0 + 1) * each, title: "")
            }
        } else {
            chapters = []
        }
        let known = item.media?.chapters != nil || item.media?.numChapters != nil
        let issues = (known && !item.isPodcast && !item.isEbookOnly)
            ? ChapterHealth.issues(chapters: chapters, droppedCount: item.media?.droppedChapterCount ?? 0,
                                   bookDuration: duration)
            : []
        self.init(
            id: item.id,
            title: meta?.title,
            authorName: meta?.authorName,
            asin: meta?.asin,
            isbn: meta?.isbn,
            publishedYear: meta?.publishedYear.flatMap { Int($0.prefix(4)) },
            hasCover: !((item.media?.coverPath ?? "").isEmpty),
            isPodcast: item.isPodcast,
            isEbookOnly: item.isEbookOnly,
            series: refs,
            chapterIssues: issues)
    }
}

// MARK: - Doctor

nonisolated enum SeriesSequenceFormat {
    /// "3" for 3.0, "1.5" for 1.5; the form ABS stores (it needs a string).
    nonisolated static func string(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        return String(value)
    }
}

nonisolated enum LibraryDoctor {

    /// All findings for a library snapshot, grouped by kind in `DoctorFindingKind.allCases` order.
    @MainActor
    static func diagnose(items: [LibraryItem]) -> [DoctorFinding] {
        diagnose(books: items.map { DoctorBook(item: $0) })
    }

    nonisolated static func diagnose(books all: [DoctorBook]) -> [DoctorFinding] {
        let books = all.filter { !$0.isPodcast }
        var findings: [DoctorFinding] = []
        findings += duplicateFindings(books)
        findings += missingCoverFindings(books)
        findings += seriesFindings(books)
        findings += chapterFindings(books)
        let order = Dictionary(uniqueKeysWithValues: DoctorFindingKind.allCases.enumerated().map { ($1, $0) })
        return findings.enumerated().sorted { a, b in
            let ka = order[a.element.kind] ?? 0, kb = order[b.element.kind] ?? 0
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Normalisation

    /// Lowercase, no diacritics, no "(Unabridged)" style suffix, punctuation as spaces, no leading
    /// "the/a/an", single spaces.
    nonisolated static func normalizedTitle(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        for pattern in [#"\s*[\(\[]\s*(un)?abridged[^\)\]]*[\)\]]"#, #"\s*[-:–—]\s*(un)?abridged\s*$"#,
                        #"\s+(un)?abridged\s*$"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = squash(s)
        for article in ["the ", "a ", "an "] where s.hasPrefix(article) {
            s = String(s.dropFirst(article.count))
            break
        }
        return s
    }

    /// The first author, normalised: "Terry Pratchett, Neil Gaiman" and "Terry Pratchett & Neil Gaiman"
    /// both give "terry pratchett".
    nonisolated static func normalizedPrimaryAuthor(_ raw: String) -> String {
        var first = raw
        for separator in [",", ";", "&", " and ", " with "] {
            if let r = first.range(of: separator, options: .caseInsensitive) { first = String(first[..<r.lowerBound]) }
        }
        let folded = first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return squash(folded.lowercased())
    }

    private nonisolated static func squash(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    nonisolated static func normalizedISBN(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        return cleaned.count == 10 || cleaned.count == 13 ? cleaned : nil
    }

    // MARK: Duplicates

    private nonisolated static func duplicateFindings(_ books: [DoctorBook]) -> [DoctorFinding] {
        var out: [DoctorFinding] = []
        var reported = Set<[String]>()

        func group(_ reason: DuplicateReason, key: (DoctorBook) -> String?) {
            var buckets: [String: [DoctorBook]] = [:]
            var order: [String] = []
            for book in books {
                // An ebook and an audiobook of the same title are different editions, not duplicates.
                guard let k = key(book) else { continue }
                let bucketKey = "\(book.isEbookOnly ? "e" : "a")|\(k)"
                if buckets[bucketKey] == nil { order.append(bucketKey) }
                buckets[bucketKey, default: []].append(book)
            }
            for bucketKey in order {
                guard let members = buckets[bucketKey], members.count > 1 else { continue }
                let ids = members.map(\.id).sorted()
                guard reported.insert(ids).inserted else { continue }
                let shown = String(bucketKey.dropFirst(2))
                let subject = members.compactMap(\.title).first ?? shown
                out.append(DoctorFinding(
                    id: "dup|\(reason.rawValue)|\(bucketKey)", kind: .duplicate, severity: .warning,
                    itemIds: members.map(\.id), subject: subject,
                    detail: .duplicate(reason: reason, key: shown), fix: nil))
            }
        }
        group(.asin) { b in
            let v = (b.asin ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            return v.isEmpty ? nil : v
        }
        group(.isbn) { b in b.isbn.flatMap(normalizedISBN) }
        group(.titleAndAuthor) { b in
            guard let t = b.title else { return nil }
            let title = normalizedTitle(t)
            guard !title.isEmpty else { return nil }
            return title + "|" + normalizedPrimaryAuthor(b.authorName ?? "")
        }
        return out
    }

    // MARK: Covers

    private nonisolated static func missingCoverFindings(_ books: [DoctorBook]) -> [DoctorFinding] {
        books.filter { !$0.hasCover }.map { b in
            DoctorFinding(id: "cover|\(b.id)", kind: .missingCover, severity: .warning, itemIds: [b.id],
                          subject: b.title ?? b.id, detail: .missingCover, fix: .setCover(itemId: b.id))
        }
    }

    // MARK: Series

    /// "Name #3", "A #1, B #3.5", or just "Name". Only a "#number" tail ends one series entry, so names
    /// that contain commas survive.
    nonisolated static func parseSeriesDisplay(_ display: String) -> [DoctorBook.SeriesEntry] {
        var out: [DoctorBook.SeriesEntry] = []
        var rest = Substring(display)
        let tail = #"#\s*\d+(\.\d+)?(,\s+|\s*$)"#
        while let r = rest.range(of: tail, options: .regularExpression) {
            let chunk = rest[..<r.upperBound]
            if let hash = chunk.lastIndex(of: "#") {
                let name = chunk[..<hash].trimmingCharacters(in: .whitespaces)
                let digits = chunk[chunk.index(after: hash)...].filter { $0.isNumber || $0 == "." }
                if !name.isEmpty { out.append(.init(name: name, sequence: Double(digits))) }
            }
            rest = rest[r.upperBound...]
        }
        let leftover = rest.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        if !leftover.isEmpty { out.append(.init(name: leftover, sequence: nil)) }
        return out
    }

    private nonisolated static func seriesFindings(_ books: [DoctorBook]) -> [DoctorFinding] {
        struct Member { let book: DoctorBook; let sequence: Double? }
        var members: [String: [Member]] = [:]
        var names: [String: String] = [:]
        var keyOrder: [String] = []
        for book in books where !book.isEbookOnly || !book.series.isEmpty {
            for entry in book.series {
                let key = entry.name.lowercased()
                if names[key] == nil { names[key] = entry.name; keyOrder.append(key) }
                members[key, default: []].append(Member(book: book, sequence: entry.sequence))
            }
        }
        var out: [DoctorFinding] = []
        for key in keyOrder {
            guard let list = members[key], let name = names[key] else { continue }
            // A one-book series with no number is normal; the check only means something with company.
            if list.count >= 2 {
                for m in list where m.sequence == nil {
                    let proposed = proposedSequence(for: m.book.id, among: list.map {
                        SequenceCandidate(id: $0.book.id, sequence: $0.sequence, publishedYear: $0.book.publishedYear)
                    })
                    out.append(DoctorFinding(
                        id: "seqmissing|\(key)|\(m.book.id)", kind: .seriesMissingSequence, severity: .warning,
                        itemIds: [m.book.id], subject: m.book.title ?? name,
                        detail: .seriesMissingSequence(series: name),
                        fix: .setSequence(itemId: m.book.id, series: name, proposed: proposed)))
                }
            }
            var bySequence: [Double: [Member]] = [:]
            for m in list { if let s = m.sequence, s.isFinite { bySequence[s, default: []].append(m) } }
            for sequence in bySequence.keys.sorted() {
                guard let group = bySequence[sequence], group.count > 1 else { continue }
                out.append(DoctorFinding(
                    id: "seqdup|\(key)|\(SeriesSequenceFormat.string(sequence))", kind: .seriesDuplicateSequence,
                    severity: .warning, itemIds: group.map(\.book.id), subject: name,
                    detail: .seriesDuplicateSequence(series: name, sequence: sequence), fix: nil))
            }
            let missing = wholeNumberGaps(list.compactMap(\.sequence))
            if !missing.isEmpty {
                out.append(DoctorFinding(
                    id: "seqgap|\(key)", kind: .seriesGap, severity: .info, itemIds: list.map(\.book.id),
                    subject: name, detail: .seriesGap(series: name, missing: missing), fix: nil))
            }
        }
        return out
    }

    /// Whole numbers missing between the lowest and highest whole-numbered entries ([1,2,4] -> [3]).
    /// Fractional entries (1.5) are ignored. At most 20 numbers are returned.
    nonisolated static func wholeNumberGaps(_ sequences: [Double]) -> [Int] {
        let wholes = Set(sequences.filter { $0.isFinite && $0 == $0.rounded() && $0 >= 0 && $0 < 100_000 }.map { Int($0) })
        guard let lo = wholes.min(), let hi = wholes.max(), hi - lo >= 2 else { return [] }
        return Array((lo...hi).filter { !wholes.contains($0) }.prefix(20))
    }

    nonisolated struct SequenceCandidate: Equatable, Sendable {
        var id: String
        var sequence: Double?
        var publishedYear: Int?
    }

    /// The next free number for an unnumbered book: one past the highest number held by books published
    /// no later than it (or the highest overall when its year is unknown), then upward past any number
    /// already taken. Only a proposal; the user edits it before anything is sent.
    nonisolated static func proposedSequence(for id: String, among books: [SequenceCandidate]) -> Double {
        let taken = Set(books.compactMap(\.sequence).filter(\.isFinite))
        let target = books.first { $0.id == id }
        let comparable = books.filter { $0.id != id && $0.sequence != nil }
        let basis: [Double]
        if let year = target?.publishedYear {
            basis = comparable.filter { ($0.publishedYear ?? Int.max) <= year }.compactMap(\.sequence)
        } else {
            basis = comparable.compactMap(\.sequence)
        }
        // Review Low (LibraryDoctor loop, 30 October 2026): a huge or non-finite series number made
        // `candidate += 1` a no-op, so the loop never ended. Ignore absurd values and bound the loop.
        let sane = basis.filter { $0.isFinite && abs($0) < 100_000 }
        var candidate = (sane.max() ?? 0).rounded(.down) + 1
        var steps = 0
        while taken.contains(candidate), steps <= taken.count { candidate += 1; steps += 1 }
        return candidate
    }

    // MARK: Chapters

    private nonisolated static func chapterFindings(_ books: [DoctorBook]) -> [DoctorFinding] {
        books.filter { !$0.isEbookOnly && !$0.chapterIssues.isEmpty }.map { b in
            let severity: DoctorSeverity = b.chapterIssues.contains(where: { $0 == .overlong || $0 == .dropped }) ? .warning : .info
            return DoctorFinding(id: "chapters|\(b.id)", kind: .badChapters, severity: severity, itemIds: [b.id],
                                 subject: b.title ?? b.id, detail: .badChapters(issues: b.chapterIssues),
                                 fix: .chapters(itemId: b.id))
        }
    }
}
