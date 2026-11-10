import Foundation

/// Batch 443: one book on a reading-site "want to read" shelf (Hardcover, Goodreads or StoryGraph).
nonisolated struct WantToReadEntry: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case hardcover, goodreads, storygraph }
    var title: String
    var author: String
    var isbn: String?
    var source: Source
    /// Hardcover's page for the book, when known.
    var url: String?

    var id: String { "\(source.rawValue)|\(ReadingSiteMatcher.normalizedTitle(title))|\(ReadingSiteMatcher.authorTokens(author).sorted().joined(separator: " "))" }
}

/// Batch 443: one finished book to write into a Goodreads-format export.
nonisolated struct FinishedBookRow: Equatable, Sendable {
    var title: String
    var author: String
    var isbn: String?
    /// 1...5, or nil / 0 when unrated.
    var rating: Int?
    var dateRead: Date?
}

/// Batch 443: pure CSV helpers for reading-site files. No I/O.
///
/// - Reader: RFC 4180 (quoted fields, doubled quotes, embedded commas and newlines, CRLF or LF,
///   optional UTF-8 BOM).
/// - Goodreads export: `Title`, `Author`, `ISBN` / `ISBN13` (written as `="0123456789"`),
///   `Exclusive Shelf` (`to-read`).
/// - StoryGraph export: `Title`, `Authors`, `ISBN/UID`, `Read Status` (`to-read`).
/// - Export: the Goodreads import layout, which StoryGraph also accepts.
nonisolated enum ReadingListCSV {

    // MARK: Reader

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var sawAny = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        if chars.first == "\u{FEFF}" { i = 1 }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                    sawAny = true
                case ",":
                    row.append(field)
                    field = ""
                    sawAny = true
                case "\r":
                    break
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                    sawAny = false
                default:
                    field.unicodeScalars.append(c)
                    sawAny = true
                }
            }
            i += 1
        }
        if sawAny || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Quotes a field only when it needs it.
    static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: Import

    /// Goodreads wraps ISBNs as `="9780441013593"` so spreadsheets keep leading zeros.
    static func cleanISBN(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("=") { s.removeFirst() }
        s = s.replacingOccurrences(of: "\"", with: "")
        let kept = s.uppercased().filter { $0.isNumber || $0 == "X" }
        return (kept.count == 10 || kept.count == 13) ? kept : nil
    }

    /// Detects the export flavour from its header and returns the want-to-read rows.
    /// Returns an empty array for an unrecognised file.
    static func wantToRead(fromCSV text: String) -> [WantToReadEntry] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func col(_ name: String) -> Int? { names.firstIndex(of: name) }
        func cell(_ row: [String], _ index: Int?) -> String {
            guard let index, index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let shelf = col("exclusive shelf"), let title = col("title") {
            let author = col("author")
            let isbn13 = col("isbn13"), isbn10 = col("isbn")
            return rows.dropFirst().compactMap { row in
                guard cell(row, shelf).lowercased() == "to-read" else { return nil }
                let t = cell(row, title)
                guard !t.isEmpty else { return nil }
                let isbn = cleanISBN(cell(row, isbn13)) ?? cleanISBN(cell(row, isbn10))
                return WantToReadEntry(title: t, author: cell(row, author), isbn: isbn, source: .goodreads, url: nil)
            }
        }
        if let status = col("read status"), let title = col("title") {
            let author = col("authors")
            let isbnCol = col("isbn/uid")
            return rows.dropFirst().compactMap { row in
                guard cell(row, status).lowercased() == "to-read" else { return nil }
                let t = cell(row, title)
                guard !t.isEmpty else { return nil }
                // The first author only: StoryGraph joins several with ", ".
                return WantToReadEntry(title: t, author: cell(row, author), isbn: cleanISBN(cell(row, isbnCol)), source: .storygraph, url: nil)
            }
        }
        return []
    }

    /// Keeps the first entry for each id (a re-import never duplicates).
    static func merged(_ existing: [WantToReadEntry], with incoming: [WantToReadEntry]) -> [WantToReadEntry] {
        var seen = Set(existing.map(\.id))
        var out = existing
        for entry in incoming where seen.insert(entry.id).inserted { out.append(entry) }
        return out
    }

    // MARK: Export

    static let exportHeader = ["Title", "Author", "ISBN", "My Rating", "Date Read", "Exclusive Shelf"]

    /// Goodreads-import layout. Dates are `yyyy/MM/dd` (Goodreads' own), in the given calendar's zone.
    static func exportFinished(items: [FinishedBookRow], calendar: Calendar = .current) -> String {
        var lines = [exportHeader.joined(separator: ",")]
        for item in items {
            var date = ""
            if let d = item.dateRead {
                let c = calendar.dateComponents([.year, .month, .day], from: d)
                if let y = c.year, let m = c.month, let day = c.day {
                    date = String(format: "%04d/%02d/%02d", y, m, day)
                }
            }
            let rating = String(max(0, min(5, item.rating ?? 0)))
            let fields = [item.title, item.author, item.isbn ?? "", rating, date, "read"]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Matching against the library

    /// For each wanted entry, the id of the library book that is already on the server, if any.
    static func owned(_ entries: [WantToReadEntry], in library: [ReadingSiteMatcher.Candidate]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            if let id = ReadingSiteMatcher.match(title: entry.title, author: entry.author, isbn: entry.isbn, asin: nil, in: library) {
                result[entry.id] = id
            }
        }
        return result
    }
}
