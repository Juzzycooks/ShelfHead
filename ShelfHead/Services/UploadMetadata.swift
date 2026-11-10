import AVFoundation
import Foundation
import PDFKit

/// Batch 444: title, author and series suggested for an upload. Every field is only a
/// suggestion: the Upload screen shows them in editable fields.
nonisolated struct UploadMetadata: Sendable, Equatable {
    var title: String?
    var author: String?
    var series: String?
    /// Position in the series ("2", "1.5"). Shown as a hint only: `/api/upload` has no field for it.
    var sequence: String?

    /// Fields of `self` that are set, otherwise those of `fallback`.
    func filling(from fallback: UploadMetadata) -> UploadMetadata {
        UploadMetadata(title: title.nonEmpty ?? fallback.title.nonEmpty,
                       author: author.nonEmpty ?? fallback.author.nonEmpty,
                       series: series.nonEmpty ?? fallback.series.nonEmpty,
                       sequence: sequence.nonEmpty ?? fallback.sequence.nonEmpty)
    }
}

private extension Optional where Wrapped == String {
    nonisolated var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Batch 444: pure filename parsing, the fallback when a file carries no usable tags.
///
/// - `Author - Title.m4b` -> author + title (first " - ", en or em dash with spaces around it)
/// - `Title (Series 2).m4b`, `Title [Series #2]`, `Title (Series, Book 2)` -> series + sequence
/// - a leading track number (`01 - Title`) is dropped, not taken for an author
/// - underscores become spaces, runs of whitespace collapse
nonisolated enum UploadFilenameParser {

    static func parse(_ filename: String, stripExtension: Bool = true) -> UploadMetadata {
        var name = stripExtension ? (filename as NSString).deletingPathExtension : filename
        name = name.replacingOccurrences(of: "_", with: " ")
        name = collapse(name)
        guard !name.isEmpty else { return UploadMetadata() }

        var series: String?
        var sequence: String?
        if let match = trailingSeries(in: name) {
            series = match.series
            sequence = match.sequence
            name = collapse(String(name[..<match.range.lowerBound]))
        }

        var author: String?
        var title = name
        if let split = splitAuthor(name) {
            author = split.author
            title = split.title
        }
        return UploadMetadata(title: title.isEmpty ? nil : title, author: author, series: series, sequence: sequence)
    }

    /// Suggestions for a set of files that make up one book: the longest prefix their cleaned names
    /// share (after trimming "Part", "Chapter", "Disc", digits and dashes off its end) parsed like a
    /// single name, so "Frank Herbert - Dune - Part 01/02" gives author "Frank Herbert", title
    /// "Dune". With no meaningful shared prefix (< 4 characters) the first file's name is used.
    static func parseCommon(of filenames: [String]) -> UploadMetadata {
        guard let first = filenames.first else { return UploadMetadata() }
        guard filenames.count > 1 else { return parse(first) }
        let names = filenames.map { collapse(($0 as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")) }
        var prefix = names[0]
        for name in names.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0.lowercased() == $1.lowercased() }.map { $0.0 })
        }
        let trimmed = trimTrailingMarkers(prefix)
        return trimmed.count >= 4 ? parse(trimmed, stripExtension: false) : parse(first)
    }

    // MARK: Pieces

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func trimTrailingMarkers(_ s: String) -> String {
        var out = s
        let junk = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-\u{2013}\u{2014}_.,(["))
        while let last = out.unicodeScalars.last, junk.contains(last) || CharacterSet.decimalDigits.contains(last) {
            out.unicodeScalars.removeLast()
        }
        for word in [" part", " chapter", " disc", " disk", " cd", " track"] where out.lowercased().hasSuffix(word) {
            out = String(out.dropLast(word.count))
            return trimTrailingMarkers(out)
        }
        return out
    }

    private static let seriesWords: Set<String> = ["book", "vol", "vol.", "volume", "part", "disc", "disk", "cd", "no", "no.", "number", "#"]

    private static func trailingSeries(in name: String) -> (series: String, sequence: String, range: Range<String.Index>)? {
        // "(Name 2)", "[Name #2]", "(Name, Book 2)", "(Name Vol. 1.5)"
        let pattern = #"\s*[\(\[]\s*([^\(\)\[\]]+?)[,\s]+(?:#|no\.?\s*|book\s*|vol\.?\s*|volume\s*)?(\d+(?:\.\d+)?)\s*[\)\]]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              m.numberOfRanges == 3,
              let whole = Range(m.range, in: name),
              let nameRange = Range(m.range(at: 1), in: name),
              let numRange = Range(m.range(at: 2), in: name) else { return nil }
        let series = collapse(String(name[nameRange]))
        // "(Book 2)" alone is a position, not a series name; "(2019)" never matches (needs a name).
        guard !series.isEmpty, !seriesWords.contains(series.lowercased()) else { return nil }
        // Everything before the bracket must still be a title.
        guard !collapse(String(name[..<whole.lowerBound])).isEmpty else { return nil }
        return (series, String(name[numRange]), whole)
    }

    private static func splitAuthor(_ name: String) -> (author: String?, title: String)? {
        for separator in [" - ", " \u{2013} ", " \u{2014} "] {
            guard let range = name.range(of: separator) else { continue }
            let left = collapse(String(name[..<range.lowerBound]))
            let right = collapse(String(name[range.upperBound...]))
            guard !right.isEmpty else { continue }
            // "01 - Title" / "Track 3 - Title": a track number, not an author.
            if left.isEmpty || left.allSatisfy({ $0.isNumber || $0 == "." }) { return (nil, right) }
            if left.lowercased().hasPrefix("track ") || left.lowercased().hasPrefix("chapter ") { return (nil, right) }
            return (left, right)
        }
        return nil
    }
}

/// Batch 444: reads suggestions out of the file itself, falling back to its name. Audio comes from
/// the container's common metadata (`AVURLAsset`, album over track title for a book split across
/// files), EPUB from the OPF package document, PDF from `PDFDocument.documentAttributes`.
nonisolated enum UploadMetadataReader {

    /// Suggestions for a set of files that belong to one upload. The first file with usable tags
    /// wins; the filename fills whatever the tags lack.
    static func read(files: [URL]) async -> UploadMetadata {
        var tagged = UploadMetadata()
        for url in files {
            let found = await readTags(from: url)
            tagged = tagged.filling(from: found)
            if tagged.title != nil, tagged.author != nil { break }
        }
        return tagged.filling(from: UploadFilenameParser.parseCommon(of: files.map(\.lastPathComponent)))
    }

    static func readTags(from url: URL) async -> UploadMetadata {
        switch url.pathExtension.lowercased() {
        case "epub": return readEPUB(url)
        case "pdf": return readPDF(url)
        case "mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "caf", "mp4":
            return await readAudio(url)
        default: return UploadMetadata()
        }
    }

    private static func readAudio(_ url: URL) async -> UploadMetadata {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return UploadMetadata() }
        func value(_ identifier: AVMetadataIdentifier) async -> String? {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            }
            return nil
        }
        // For a book split into tracks the album is the book; the track title is a chapter.
        let album = await value(.commonIdentifierAlbumName)
        let title = await value(.commonIdentifierTitle)
        var author = await value(.commonIdentifierArtist)
        if author == nil { author = await value(.commonIdentifierCreator) }
        return UploadMetadata(title: album ?? title, author: author)
    }

    private static func readPDF(_ url: URL) -> UploadMetadata {
        guard let doc = PDFDocument(url: url), let attrs = doc.documentAttributes else { return UploadMetadata() }
        return UploadMetadata(title: attrs[PDFDocumentAttribute.titleAttribute] as? String,
                              author: attrs[PDFDocumentAttribute.authorAttribute] as? String)
    }

    private static func readEPUB(_ url: URL) -> UploadMetadata {
        // EPUBs are small; anything past 200 MB is skipped rather than read into memory.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 200_000_000,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let zip = try? ZipReader(data: data),
              let container = try? zip.data(for: "META-INF/container.xml"),
              let opfPath = OPFMetadataParser.rootfilePath(inContainer: container),
              let opf = try? zip.data(for: opfPath) else { return UploadMetadata() }
        return OPFMetadataParser.parse(opf)
    }
}

/// Batch 444: the few OPF elements an upload needs: `dc:title`, first `dc:creator`, Calibre's
/// `calibre:series` / `calibre:series_index` metas and EPUB 3 `belongs-to-collection` with its
/// `group-position`. Pure and namespace-agnostic (matches on the local name after any prefix).
nonisolated enum OPFMetadataParser {

    static func rootfilePath(inContainer data: Data) -> String? {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.path
    }

    static func parse(_ data: Data) -> UploadMetadata {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.result
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var path: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if path == nil, elementName.hasSuffix("rootfile"), let full = attributeDict["full-path"], !full.isEmpty {
                path = full
            }
        }
    }

    private final class OPFDelegate: NSObject, XMLParserDelegate {
        var title: String?
        var author: String?
        var series: String?
        var sequence: String?
        private var capture: String?   // "title" | "creator" | "collection"
        private var text = ""
        private var collectionId: String?
        private var positions: [String: String] = [:]   // refines id -> group-position
        private var pendingPositionRefines: String?

        var result: UploadMetadata {
            var seq = sequence
            if seq == nil, let id = collectionId { seq = positions[id] }
            return UploadMetadata(title: title, author: author, series: series, sequence: seq)
        }

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            let name = local(elementName)
            text = ""
            switch name {
            case "title" where title == nil: capture = "title"
            case "creator" where author == nil: capture = "creator"
            case "meta":
                if let key = a["name"]?.lowercased() {
                    let content = a["content"]
                    if key == "calibre:series", series == nil { series = content }
                    if key == "calibre:series_index", sequence == nil { sequence = content }
                }
                switch a["property"] {
                case "belongs-to-collection":
                    if series == nil { capture = "collection"; collectionId = a["id"] }
                case "collection-type": break
                case "group-position":
                    if let refines = a["refines"] { pendingPositionRefines = String(refines.drop(while: { $0 == "#" })); capture = "position" }
                default: break
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { text += string } }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let current = capture else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (current, local(elementName)) {
            case ("title", "title"): if !value.isEmpty { title = value }
            case ("creator", "creator"): if !value.isEmpty { author = value }
            case ("collection", "meta"): if !value.isEmpty { series = value }
            case ("position", "meta"):
                if let id = pendingPositionRefines, !value.isEmpty { positions[id] = value }
                pendingPositionRefines = nil
            default: return
            }
            capture = nil
        }
    }
}
