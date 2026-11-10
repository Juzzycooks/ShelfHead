import Foundation
import Compression

// Pure EPUB parsing for the in-app reader (Batch 430): a minimal ZIP reader, the OPF/nav/NCX
// package model, path resolution and the reader's CSS. Foundation + Compression only, so every
// piece is unit-testable without WebKit.

// MARK: - ZIP

nonisolated enum ZipError: Error, Equatable {
    case notAZip
    case unsupportedCompression(UInt16)
    case corrupt
    case missing(String)
    case tooLarge
}

/// Reads entries out of an in-memory ZIP via the central directory (not the local headers: their
/// sizes may live in a trailing data descriptor). Supports method 0 (stored) and 8 (deflate);
/// no ZIP64. Entries that would expand past 64 MB are refused with `.tooLarge`. CRCs are not
/// verified.
nonisolated struct ZipReader: Sendable {
    private struct Entry: Sendable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    static let maxEntrySize = 64 * 1024 * 1024

    private let bytes: Data
    private let entries: [Entry]
    private let index: [String: Int]

    init(data: Data) throws {
        let bytes = Data(data) // re-base so indices start at 0
        let count = bytes.count
        guard count >= 22 else { throw ZipError.notAZip }

        // End of central directory: scan backwards (it may be followed by a comment up to 64 KB).
        var eocd = -1
        var i = count - 22
        let lowest = max(0, count - 22 - 65_535)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let total = Self.u16(bytes, eocd + 10)
        let cdSize = Self.u32(bytes, eocd + 12)
        let cdOffset = Self.u32(bytes, eocd + 16)
        guard let total, let cdSize, let cdOffset else { throw ZipError.corrupt }
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.corrupt } // ZIP64
        guard cdOffset + cdSize <= count else { throw ZipError.corrupt }

        var parsed: [Entry] = []
        var lookup: [String: Int] = [:]
        var p = cdOffset
        let end = cdOffset + cdSize
        while p + 46 <= end {
            guard Self.u32(bytes, p) == 0x0201_4B50 else { throw ZipError.corrupt }
            guard let flags = Self.u16(bytes, p + 8),
                  let method = Self.u16(bytes, p + 10),
                  let csize = Self.u32(bytes, p + 20),
                  let usize = Self.u32(bytes, p + 24),
                  let nameLen = Self.u16(bytes, p + 28),
                  let extraLen = Self.u16(bytes, p + 30),
                  let commentLen = Self.u16(bytes, p + 32),
                  let offset = Self.u32(bytes, p + 42)
            else { throw ZipError.corrupt }
            let nameStart = p + 46
            let nameEnd = nameStart + Int(nameLen)
            guard nameEnd <= end else { throw ZipError.corrupt }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw ZipError.corrupt }
            let entry = Entry(name: name, method: method, flags: flags,
                              compressedSize: csize, uncompressedSize: usize,
                              localHeaderOffset: offset)
            if lookup[name] == nil { lookup[name] = parsed.count }
            parsed.append(entry)
            p = nameEnd + Int(extraLen) + Int(commentLen)
        }
        self.bytes = bytes
        self.entries = parsed
        self.index = lookup
    }

    var entryNames: [String] { entries.map(\.name) }

    func contains(_ path: String) -> Bool { index[path] != nil }

    /// Uncompressed size of an entry from the central directory, or nil when it doesn't exist.
    func uncompressedSize(for path: String) -> Int? {
        index[path].map { entries[$0].uncompressedSize }
    }

    func data(for path: String) throws -> Data {
        guard let i = index[path] else { throw ZipError.missing(path) }
        let entry = entries[i]
        if entry.uncompressedSize > Self.maxEntrySize { throw ZipError.tooLarge }
        if entry.flags & 0x1 != 0 { throw ZipError.corrupt } // encrypted
        let header = entry.localHeaderOffset
        guard Self.u32(bytes, header) == 0x0403_4B50,
              let nameLen = Self.u16(bytes, header + 26),
              let extraLen = Self.u16(bytes, header + 28)
        else { throw ZipError.corrupt }
        let start = header + 30 + Int(nameLen) + Int(extraLen)
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count else { throw ZipError.corrupt }
        let raw = bytes[start..<end]

        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corrupt }
            return Data(raw)
        case 8:
            let size = entry.uncompressedSize
            if size == 0 { return Data() }
            var out = Data(count: size)
            let written: Int = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, size, s, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == size else { throw ZipError.corrupt }
            return out
        default:
            throw ZipError.unsupportedCompression(entry.method)
        }
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= d.count else { return nil }
        return UInt16(d[o]) | UInt16(d[o + 1]) << 8
    }

    private static func u32(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
    }
}

// MARK: - Paths

nonisolated enum EPUBPath {
    /// Resolves `href` (percent-encoded, may contain `../` and `#frag`) against the directory of
    /// `base` (a zip path). The fragment is kept as written; the path part is percent-decoded.
    /// A leading "/" means the zip root.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        var pathPart = href
        var fragment = ""
        if let hash = href.firstIndex(of: "#") {
            pathPart = String(href[..<hash])
            fragment = String(href[hash...])
        }
        if let q = pathPart.firstIndex(of: "?") { pathPart = String(pathPart[..<q]) }
        if pathPart.isEmpty { return base + fragment }
        pathPart = pathPart.removingPercentEncoding ?? pathPart

        var parts: [Substring] = []
        if !pathPart.hasPrefix("/") {
            parts = base.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        }
        for seg in pathPart.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(seg)
        }
        return parts.joined(separator: "/") + fragment
    }

    static func mimeType(forPath path: String) -> String {
        var name = path
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "xhtml": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "xml": return "application/xml"
        case "ncx": return "application/x-dtbncx+xml"
        case "opf": return "application/oebps-package+xml"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Package

nonisolated struct EPUBManifestItem: Sendable, Equatable {
    let id: String
    /// Full zip path.
    let href: String
    let mediaType: String
    let properties: [String]
}

nonisolated struct EPUBTOCEntry: Sendable, Equatable {
    let title: String
    /// Full zip path, fragment kept.
    let href: String
    let level: Int
}

nonisolated struct EPUBPackage: Sendable {
    let title: String?
    let language: String?
    /// e.g. "OEBPS/content.opf"
    let opfPath: String
    /// By manifest id.
    let manifest: [String: EPUBManifestItem]
    /// Reading order; `linear="no"` items dropped, only XHTML/HTML media types.
    let spine: [EPUBManifestItem]
    /// EPUB 3 nav document if present, else EPUB 2 toc.ncx, else empty.
    let toc: [EPUBTOCEntry]
    /// Uncompressed byte sizes of the spine items, for a whole-book progress fraction.
    let spineWeights: [Int]

    init(zip: ZipReader) throws {
        let containerData = try zip.data(for: "META-INF/container.xml")
        let container = EPUBXML.parse(containerData, delegate: ContainerParser())
        guard let opfPath = container?.rootfilePath, !opfPath.isEmpty else { throw ZipError.corrupt }
        let opfData = try zip.data(for: opfPath)
        guard let opf = EPUBXML.parse(opfData, delegate: OPFParser()) else { throw ZipError.corrupt }

        var manifest: [String: EPUBManifestItem] = [:]
        var order: [EPUBManifestItem] = []
        for raw in opf.items {
            let item = EPUBManifestItem(id: raw.id,
                                        href: EPUBPath.resolve(raw.href, relativeTo: opfPath),
                                        mediaType: raw.mediaType,
                                        properties: raw.properties)
            if manifest[item.id] == nil { manifest[item.id] = item }
            order.append(item)
        }
        var spine: [EPUBManifestItem] = []
        for ref in opf.spineRefs where ref.linear {
            guard let item = manifest[ref.idref] else { continue }
            let type = item.mediaType.lowercased()
            guard type == "application/xhtml+xml" || type == "text/html" else { continue }
            spine.append(item)
        }

        var toc: [EPUBTOCEntry] = []
        if let nav = order.first(where: { $0.properties.contains("nav") }),
           let data = try? zip.data(for: nav.href),
           let parsed = EPUBXML.parse(data, delegate: NavParser(basePath: nav.href)) {
            toc = parsed.entries
        }
        if toc.isEmpty {
            let ncx = opf.spineTOCID.flatMap { manifest[$0] }
                ?? order.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
            if let ncx, let data = try? zip.data(for: ncx.href),
               let parsed = EPUBXML.parse(data, delegate: NCXParser(basePath: ncx.href)) {
                toc = parsed.entries
            }
        }

        self.title = opf.title
        self.language = opf.language
        self.opfPath = opfPath
        self.manifest = manifest
        self.spine = spine
        self.toc = toc
        self.spineWeights = spine.map { zip.uncompressedSize(for: $0.href) ?? 0 }
    }

    /// Index in `spine` of the document at `path` (a fragment is ignored), or nil.
    func spineIndex(forPath path: String) -> Int? {
        var clean = path
        if let hash = clean.firstIndex(of: "#") { clean = String(clean[..<hash]) }
        return spine.firstIndex { $0.href == clean }
    }
}

// MARK: - Position

/// Whole-book position: spine item + fraction scrolled through it.
nonisolated struct EPUBPosition: Codable, Sendable, Equatable {
    var spineIndex: Int
    var fraction: Double

    init(spineIndex: Int, fraction: Double) {
        self.spineIndex = spineIndex
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
    }

    /// (sum of weights before this item + fraction * its weight) / total; 0 when there are no
    /// weights. Equal weights are assumed if every weight is zero.
    func overallProgress(weights: [Int]) -> Double {
        guard !weights.isEmpty else { return 0 }
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        let idx = min(max(0, spineIndex), weights.count - 1)
        let total = weights.reduce(0) { $0 + max(0, $1) }
        if total <= 0 {
            return min(1, max(0, (Double(idx) + f) / Double(weights.count)))
        }
        let before = weights[..<idx].reduce(0) { $0 + max(0, $1) }
        let value = (Double(before) + f * Double(max(0, weights[idx]))) / Double(total)
        return min(1, max(0, value))
    }
}

// MARK: - Style

/// The reader's look, applied as CSS injected after the book's own styles.
nonisolated struct EPUBReaderStyle: Sendable, Equatable {
    var backgroundHex: String
    var textHex: String
    var accentHex: String
    var fontScale: Double
    var serif: Bool

    /// A complete CSS string. Colours are forced with `!important` on the body and descendant text;
    /// `.shelfhead-readalong` is the sentence highlight used by the read-along (Batch 431).
    var css: String {
        let bg = Self.sanitized(backgroundHex, fallback: "#FFFFFF")
        let fg = Self.sanitized(textHex, fallback: "#000000")
        let accent = Self.sanitized(accentHex, fallback: "#B8860B")
        let scale = min(2.5, max(0.8, fontScale.isFinite ? fontScale : 1))
        let percent = Int((scale * 100).rounded())
        let family = serif
            ? "\"New York\", ui-serif, Georgia, serif"
            : "-apple-system, system-ui, sans-serif"
        return """
        html { background: \(bg) !important; -webkit-text-size-adjust: none; text-size-adjust: none; font-size: \(percent)%; }
        body { background: \(bg) !important; color: \(fg) !important; font-family: \(family) !important; \
        line-height: 1.6 !important; max-width: 40em; margin: 0 auto !important; padding: 20px !important; \
        box-sizing: border-box; }
        body *:not(img):not(svg):not(.shelfhead-readalong) { color: \(fg) !important; }
        body p, body li, body div, body span, body blockquote { font-family: \(family) !important; }
        a, a * { color: \(accent) !important; }
        img, svg, video { max-width: 100% !important; height: auto !important; }
        .shelfhead-readalong { background: \(Self.rgba(accent, alpha: 0.3)) !important; border-radius: 3px; }
        ::highlight(shelfhead-readalong) { background-color: \(Self.rgba(accent, alpha: 0.3)); }
        """
    }

    /// Only "#RRGGBB" / "#RGB" reach the stylesheet; anything else would be a CSS injection vector.
    private static func sanitized(_ hex: String, fallback: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#"), trimmed.count == 7 || trimmed.count == 4,
              trimmed.dropFirst().allSatisfy({ $0.isHexDigit }) else { return fallback }
        return trimmed
    }

    private static func rgba(_ hex: String, alpha: Double) -> String {
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(digits, radix: 16) else { return "rgba(0, 0, 0, \(alpha))" }
        return "rgba(\((value >> 16) & 0xFF), \((value >> 8) & 0xFF), \(value & 0xFF), \(alpha))"
    }
}

// MARK: - XML parsing (namespace-agnostic: element/attribute local names only)

private nonisolated enum EPUBXML {
    static func parse<D: XMLParserDelegate & NSObject>(_ data: Data, delegate: D) -> D? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() ? delegate : nil
    }

    static func local(_ name: String) -> String {
        let last = name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
        return last.lowercased()
    }

    /// Attribute dictionary keyed by lowercased local name.
    static func attrs(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw { out[local(k)] = v }
        return out
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private nonisolated final class ContainerParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard EPUBXML.local(elementName) == "rootfile", rootfilePath == nil else { return }
        rootfilePath = EPUBXML.attrs(attributeDict)["full-path"]
    }
}

private nonisolated final class OPFParser: NSObject, XMLParserDelegate {
    struct RawItem { let id: String; let href: String; let mediaType: String; let properties: [String] }
    struct SpineRef { let idref: String; let linear: Bool }
    var title: String?
    var language: String?
    var items: [RawItem] = []
    var spineRefs: [SpineRef] = []
    var spineTOCID: String?
    private var inMetadata = false
    private var current: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = EPUBXML.local(elementName)
        let a = EPUBXML.attrs(attributeDict)
        switch name {
        case "metadata": inMetadata = true
        case "title" where inMetadata && title == nil, "language" where inMetadata && language == nil:
            current = name
            text = ""
        case "item":
            guard let id = a["id"], let href = a["href"] else { return }
            let props = (a["properties"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
            items.append(RawItem(id: id, href: href, mediaType: a["media-type"] ?? "", properties: props))
        case "spine":
            spineTOCID = a["toc"]
        case "itemref":
            guard let idref = a["idref"] else { return }
            spineRefs.append(SpineRef(idref: idref, linear: (a["linear"] ?? "yes").lowercased() != "no"))
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = EPUBXML.local(elementName)
        if name == "metadata" { inMetadata = false }
        if name == current {
            let value = EPUBXML.collapse(text)
            if !value.isEmpty {
                if name == "title" { title = value } else { language = value }
            }
            current = nil
        }
    }
}

private nonisolated final class NavParser: NSObject, XMLParserDelegate {
    let basePath: String
    var entries: [EPUBTOCEntry] = []
    private var navDepth = 0
    private var inToc = false
    private var seenToc = false
    private var olDepth = 0
    private var inAnchor = false
    private var anchorHref: String?
    private var anchorLevel = 0
    private var text = ""

    init(basePath: String) { self.basePath = basePath }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = EPUBXML.local(elementName)
        let a = EPUBXML.attrs(attributeDict)
        switch name {
        case "nav":
            navDepth += 1
            if navDepth == 1 {
                let type = a["type"]?.lowercased() ?? ""
                let isToc = type.split(whereSeparator: { $0.isWhitespace }).contains("toc")
                if isToc || (type.isEmpty && !seenToc) {
                    inToc = true
                    seenToc = true
                    olDepth = 0
                }
            }
        case "ol" where inToc:
            olDepth += 1
        case "a" where inToc && olDepth > 0:
            if let href = a["href"], !href.isEmpty {
                inAnchor = true
                anchorHref = EPUBPath.resolve(href, relativeTo: basePath)
                anchorLevel = olDepth - 1
                text = ""
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = EPUBXML.local(elementName)
        switch name {
        case "a" where inAnchor:
            let title = EPUBXML.collapse(text)
            if let href = anchorHref, !title.isEmpty {
                entries.append(EPUBTOCEntry(title: title, href: href, level: anchorLevel))
            }
            inAnchor = false
            anchorHref = nil
        case "ol" where inToc:
            olDepth -= 1
        case "nav":
            if navDepth == 1 { inToc = false }
            navDepth -= 1
        default: break
        }
    }
}

private nonisolated final class NCXParser: NSObject, XMLParserDelegate {
    let basePath: String
    var entries: [EPUBTOCEntry] = []
    private var inNavMap = false
    private var titles: [String] = []
    private var inLabel = false
    private var inText = false
    private var text = ""

    init(basePath: String) { self.basePath = basePath }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = EPUBXML.local(elementName)
        let a = EPUBXML.attrs(attributeDict)
        switch name {
        case "navmap": inNavMap = true
        case "navpoint" where inNavMap: titles.append("")
        case "navlabel" where inNavMap && !titles.isEmpty: inLabel = true
        case "text" where inLabel:
            inText = true
            text = ""
        case "content" where inNavMap && !titles.isEmpty:
            if let src = a["src"], !src.isEmpty {
                let title = titles[titles.count - 1]
                if !title.isEmpty {
                    entries.append(EPUBTOCEntry(title: title,
                                                href: EPUBPath.resolve(src, relativeTo: basePath),
                                                level: titles.count - 1))
                }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = EPUBXML.local(elementName)
        switch name {
        case "text" where inText:
            inText = false
            if !titles.isEmpty, titles[titles.count - 1].isEmpty {
                titles[titles.count - 1] = EPUBXML.collapse(text)
            }
        case "navlabel": inLabel = false
        case "navpoint" where inNavMap: if !titles.isEmpty { titles.removeLast() }
        case "navmap": inNavMap = false
        default: break
        }
    }
}
