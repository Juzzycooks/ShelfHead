import Foundation

// Batch 431: read-along. Pure pieces that match an on-device transcript (`Transcript`)
// to an EPUB's text, so the reader can highlight the sentence being spoken and play
// from a spot in the text. No I/O; unit-tested in `ReadAlongTests`.

/// Splits one XHTML spine item into leaf-block texts (the same blocks the reader's
/// JavaScript finds in the DOM; see `ReadAlongScript`).
enum EPUBTextExtractor {
    /// Element names that make a block. A block counts only when it contains no other.
    nonisolated static let blockTags: [String] = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre",
        "dt", "dd", "figcaption", "td", "th", "caption",
    ]

    /// Each leaf block's text (DOM `textContent`), in document order. A parse error
    /// returns the blocks completed before it.
    nonisolated static func blocks(fromXHTML data: Data) -> [String] {
        guard let prepared = prepare(data) else { return [] }
        let delegate = BlockCollector()
        let parser = XMLParser(data: prepared)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.blocks
    }

    // MARK: Preparation

    /// Decodes to UTF-8, drops the BOM and XML declaration (so a stale `encoding=` can't
    /// disagree with the bytes we hand the parser) and defines the common HTML entities.
    private nonisolated static func prepare(_ data: Data) -> Data? {
        var text: String
        if let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let s = String(data: data, encoding: .utf16) {
            text = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            text = s
        } else {
            return nil
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var bytes = Array(text.utf8)
        // Strip a leading `<?xml ... ?>` declaration.
        var start = 0
        while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x0A || bytes[start] == 0x0D || bytes[start] == 0x09 {
            start += 1
        }
        let decl = Array("<?xml".utf8)
        if bytes.count - start >= decl.count, Array(bytes[start..<start + decl.count]) == decl {
            var i = start + decl.count
            while i + 1 < bytes.count, !(bytes[i] == 0x3F && bytes[i + 1] == 0x3E) { i += 1 }
            if i + 1 < bytes.count { bytes.removeSubrange(0..<(i + 2)) }
        }
        return Data(replacingEntities(in: bytes))
    }

    private nonisolated static func replacingEntities(in bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0x26) else { return bytes }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 64)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x26 {
                // `&name;` with a short alphanumeric name.
                var j = i + 1
                while j < bytes.count, j - i <= 10,
                      (bytes[j] >= 0x30 && bytes[j] <= 0x39) || (bytes[j] >= 0x41 && bytes[j] <= 0x5A) || (bytes[j] >= 0x61 && bytes[j] <= 0x7A) {
                    j += 1
                }
                if j < bytes.count, bytes[j] == 0x3B, j > i + 1,
                   let name = String(bytes: bytes[(i + 1)..<j], encoding: .utf8),
                   let code = htmlEntities[name] {
                    out.append(contentsOf: Array("&#\(code);".utf8))
                    i = j + 1
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    /// HTML named entities XML doesn't define. (`lt gt amp quot apos` are left alone.)
    private nonisolated static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165, "sect": 167,
        "copy": 169, "laquo": 171, "shy": 173, "reg": 174, "deg": 176, "plusmn": 177, "middot": 183,
        "raquo": 187, "frac12": 189, "times": 215, "divide": 247,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220,
        "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "bull": 8226, "hellip": 8230, "prime": 8242,
        "euro": 8364, "trade": 8482, "larr": 8592, "rarr": 8594,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198,
        "Ccedil": 199, "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205,
        "Icirc": 206, "Iuml": 207, "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213,
        "Ouml": 214, "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221,
        "szlig": 223, "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229,
        "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236,
        "iacute": 237, "icirc": 238, "iuml": 239, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244,
        "otilde": 245, "ouml": 246, "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252,
        "yacute": 253, "yuml": 255, "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353,
    ]

    private nonisolated final class BlockCollector: NSObject, XMLParserDelegate {
        var blocks: [String] = []
        private var inBody = false
        private let tags = Set(EPUBTextExtractor.blockTags)
        /// Open block elements, outermost first. `hasChild` marks a non-leaf.
        private var open: [(text: String, hasChild: Bool)] = []

        private func local(_ name: String) -> String {
            (name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let name = local(elementName)
            if name == "body" { inBody = true; return }
            guard inBody, tags.contains(name) else { return }
            for i in open.indices { open[i].hasChild = true }
            open.append((text: "", hasChild: false))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = local(elementName)
            if name == "body" { inBody = false; return }
            guard inBody, tags.contains(name), let last = open.popLast() else { return }
            if !last.hasChild { blocks.append(last.text) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inBody, !open.isEmpty else { return }
            open[open.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard inBody, !open.isEmpty else { return }
            open[open.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

/// Word tokens with a comparison key and where they sit in the source string.
enum ReadAlongTokenizer {
    /// Each word's folded key and its UTF-16 range in `text`.
    nonisolated static func tokens(in text: String) -> [(key: String, range: Range<Int>)] {
        var result: [(key: String, range: Range<Int>)] = []
        let scalars = Array(text.unicodeScalars)
        // UTF-16 offset of each scalar (plus the end).
        var offsets = [Int](repeating: 0, count: scalars.count + 1)
        for (i, s) in scalars.enumerated() { offsets[i + 1] = offsets[i] + (s.value > 0xFFFF ? 2 : 1) }

        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if isCJK(s) {
                var j = i + 1
                while j < scalars.count, isMark(scalars[j]) { j += 1 }
                result.append((key: foldedKey(scalars[i..<j]), range: offsets[i]..<offsets[j]))
                i = j
            } else if isWordScalar(s) {
                var j = i + 1
                while j < scalars.count {
                    let c = scalars[j]
                    if isCJK(c) { break }
                    if isWordScalar(c) || isMark(c) {
                        j += 1
                    } else if isApostrophe(c), j + 1 < scalars.count, isWordScalar(scalars[j + 1]), !isCJK(scalars[j + 1]) {
                        j += 2
                    } else {
                        break
                    }
                }
                result.append((key: foldedKey(scalars[i..<j]), range: offsets[i]..<offsets[j]))
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    private nonisolated static func foldedKey(_ run: ArraySlice<Unicode.Scalar>) -> String {
        var raw = String.UnicodeScalarView()
        var ascii = true
        for s in run where !isApostrophe(s) {
            raw.append(s)
            if s.value >= 0x80 { ascii = false }
        }
        let str = String(raw)
        return ascii ? str.lowercased()
            : str.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private nonisolated static func isApostrophe(_ s: Unicode.Scalar) -> Bool { s.value == 0x27 || s.value == 0x2019 }

    private nonisolated static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private nonisolated static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        guard v >= 0x1100 else { return false }
        return (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0x20000 && v <= 0x2FFFF) || (v >= 0x3040 && v <= 0x30FF) || (v >= 0x31F0 && v <= 0x31FF)
            || (v >= 0xFF66 && v <= 0xFF9F) || (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0x1100 && v <= 0x11FF)
            || (v >= 0x3130 && v <= 0x318F)
    }
}

/// Monotonic word alignment between a transcript and a book.
enum TextAligner {
    /// Largest gap (a count times b count) the LCS table is built for.
    nonisolated static let maxDPCells = 4_000_000

    /// For each index of `a`, the index in `b` it matched, or nil. Strictly increasing.
    nonisolated static func align(_ a: [String], _ b: [String]) -> [Int?] {
        var out = [Int?](repeating: nil, count: a.count)
        guard !a.isEmpty, !b.isEmpty else { return out }

        // Intern keys so the hot loops compare Ints.
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(min(a.count, b.count) + 1024)
        func intern(_ s: String) -> Int32 {
            if let v = ids[s] { return v }
            let v = Int32(ids.count)
            ids[s] = v
            return v
        }
        let ai = a.map(intern)
        let bi = b.map(intern)

        struct Info { var ca: Int32 = 0; var cb: Int32 = 0; var ia = 0; var ib = 0 }
        var stack: [(aLo: Int, aHi: Int, bLo: Int, bHi: Int)] = [(0, a.count, 0, b.count)]

        while let range = stack.popLast() {
            var aLo = range.aLo, aHi = range.aHi, bLo = range.bLo, bHi = range.bHi
            while aLo < aHi, bLo < bHi, ai[aLo] == bi[bLo] {
                out[aLo] = bLo
                aLo += 1
                bLo += 1
            }
            while aLo < aHi, bLo < bHi, ai[aHi - 1] == bi[bHi - 1] {
                aHi -= 1
                bHi -= 1
                out[aHi] = bHi
            }
            guard aLo < aHi, bLo < bHi else { continue }

            var info: [Int32: Info] = [:]
            info.reserveCapacity(min(aHi - aLo, bHi - bLo) + 16)
            for i in aLo..<aHi {
                info[ai[i], default: Info()].ca += 1
                info[ai[i]]!.ia = i
            }
            for j in bLo..<bHi {
                // Only keys that appear in `a` can be anchors.
                if info[bi[j]] != nil {
                    info[bi[j]]!.cb += 1
                    info[bi[j]]!.ib = j
                }
            }
            var anchors: [(ia: Int, ib: Int)] = []
            for i in aLo..<aHi {
                if let e = info[ai[i]], e.ca == 1, e.cb == 1 { anchors.append((e.ia, e.ib)) }
            }

            if anchors.isEmpty {
                let n = aHi - aLo, m = bHi - bLo
                if n * m <= maxDPCells {
                    lcs(ai, bi, aLo, aHi, bLo, bHi, &out)
                }
                continue
            }

            // Longest increasing subsequence of anchors by `ib` (anchors are already increasing in `ia`).
            var tails: [Int] = []          // indices into anchors
            var prev = [Int](repeating: -1, count: anchors.count)
            for k in anchors.indices {
                let v = anchors[k].ib
                var lo = 0, hi = tails.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if anchors[tails[mid]].ib < v { lo = mid + 1 } else { hi = mid }
                }
                if lo > 0 { prev[k] = tails[lo - 1] }
                if lo == tails.count { tails.append(k) } else { tails[lo] = k }
            }
            var chain: [Int] = []
            var k = tails.last ?? -1
            while k >= 0 {
                chain.append(k)
                k = prev[k]
            }
            chain.reverse()

            var pa = aLo, pb = bLo
            for c in chain {
                let (ia, ib) = anchors[c]
                out[ia] = ib
                if ia > pa, ib > pb { stack.append((pa, ia, pb, ib)) }
                pa = ia + 1
                pb = ib + 1
            }
            if pa < aHi, pb < bHi { stack.append((pa, aHi, pb, bHi)) }
        }
        return out
    }

    /// Plain LCS over `a[aLo..<aHi]` and `b[bLo..<bHi]`, writing matches into `out`.
    private nonisolated static func lcs(_ a: [Int32], _ b: [Int32], _ aLo: Int, _ aHi: Int,
                                        _ bLo: Int, _ bHi: Int, _ out: inout [Int?]) {
        let n = aHi - aLo, m = bHi - bLo
        let width = m + 1
        // Directions: 0 = match (diagonal), 1 = skip an `a`, 2 = skip a `b`.
        var dir = [UInt8](repeating: 0, count: (n + 1) * width)
        var prevRow = [Int32](repeating: 0, count: width)
        var curRow = [Int32](repeating: 0, count: width)
        for i in 1...n {
            curRow[0] = 0
            dir[i * width] = 1
            let av = a[aLo + i - 1]
            for j in 1...m {
                if av == b[bLo + j - 1] {
                    curRow[j] = prevRow[j - 1] + 1
                    dir[i * width + j] = 0
                } else if prevRow[j] >= curRow[j - 1] {
                    curRow[j] = prevRow[j]
                    dir[i * width + j] = 1
                } else {
                    curRow[j] = curRow[j - 1]
                    dir[i * width + j] = 2
                }
            }
            swap(&prevRow, &curRow)
        }
        var i = n, j = m
        while i > 0, j > 0 {
            switch dir[i * width + j] {
            case 0:
                out[aLo + i - 1] = bLo + j - 1
                i -= 1
                j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
    }
}

/// Where one transcript segment sits in the ebook.
struct ReadAlongLocation: Codable, Equatable, Hashable, Sendable {
    var spineIndex: Int
    var startBlock: Int
    /// UTF-16 offset into the start block's text.
    var startOffset: Int
    var endBlock: Int
    /// UTF-16 offset into the end block's text (exclusive).
    var endOffset: Int
}

/// The cached result of matching a transcript to an ebook.
struct ReadAlongMap: Codable, Equatable, Sendable {
    /// 2: highlight ends take in closing punctuation.
    nonisolated static let currentVersion = 2

    var version: Int
    /// `ReadAlongMapBuilder.fingerprint`; a mismatch means rebuild.
    var key: String
    /// One entry per transcript segment, same order.
    var locations: [ReadAlongLocation?]
    /// UTF-16 length of each leaf block, per spine item.
    var blockLengths: [[Int]]
    /// Share of transcript words that found a match in the book, 0...1.
    var matchedFraction: Double

    /// The segment's location, or the nearest earlier located segment's.
    nonisolated func location(forSegment index: Int) -> ReadAlongLocation? {
        guard !locations.isEmpty, index >= 0 else { return nil }
        var i = min(index, locations.count - 1)
        while i >= 0 {
            if let l = locations[i] { return l }
            i -= 1
        }
        return nil
    }

    /// The segment to play for a spot in the text (see the contract's rule).
    nonisolated func segmentIndex(spineIndex: Int, block: Int, offset: Int) -> Int? {
        let located = locations.indices.filter { locations[$0] != nil }
        guard !located.isEmpty else { return nil }
        func startsAfter(_ l: ReadAlongLocation) -> Bool {
            (l.spineIndex, l.startBlock, l.startOffset) > (spineIndex, block, offset)
        }
        // First located segment whose start is after the spot.
        var lo = 0, hi = located.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if startsAfter(locations[located[mid]]!) { hi = mid } else { lo = mid + 1 }
        }
        if lo > 0 {
            let candidate = located[lo - 1]
            let l = locations[candidate]!
            if (spineIndex, block, offset) < (l.spineIndex, l.endBlock, l.endOffset) { return candidate }
        }
        if lo < located.count { return located[lo] }
        return located.last
    }
}

enum ReadAlongMapBuilder {
    /// Cache key for a transcript and an ebook file.
    nonisolated static func fingerprint(transcript: Transcript, ebookByteCount: Int) -> String {
        "v\(ReadAlongMap.currentVersion)-s\(transcript.segments.count)-c\(Int(transcript.coveredUntil.rounded()))"
            + "-u\(Int(transcript.updatedAt.timeIntervalSince1970))-e\(ebookByteCount)"
    }

    /// Aligns `segments` against the book's blocks (`spineBlocks[spine][block]`).
    nonisolated static func build(segments: [TranscriptSegment], spineBlocks: [[String]], key: String) -> ReadAlongMap {
        let blockLengths = spineBlocks.map { $0.map { $0.utf16.count } }

        // Transcript tokens, remembering their segment.
        var aKeys: [String] = []
        var segmentOf: [Int] = []
        var segmentTokenCounts = [Int](repeating: 0, count: segments.count)
        for (si, seg) in segments.enumerated() {
            let toks = ReadAlongTokenizer.tokens(in: seg.text)
            segmentTokenCounts[si] = toks.count
            for t in toks {
                aKeys.append(t.key)
                segmentOf.append(si)
            }
        }
        // Book tokens in spine order.
        var bKeys: [String] = []
        var bSpine: [Int32] = []
        var bBlock: [Int32] = []
        var bRange: [Range<Int>] = []
        for (spine, blocks) in spineBlocks.enumerated() {
            for (bi, text) in blocks.enumerated() {
                for t in ReadAlongTokenizer.tokens(in: text) {
                    bKeys.append(t.key)
                    bSpine.append(Int32(spine))
                    bBlock.append(Int32(bi))
                    bRange.append(t.range)
                }
            }
        }

        let match = TextAligner.align(aKeys, bKeys)

        var perSegment = [[Int]](repeating: [], count: segments.count)
        var matched = 0
        for (ai, m) in match.enumerated() {
            if let m {
                perSegment[segmentOf[ai]].append(m)
                matched += 1
            }
        }

        var locations = [ReadAlongLocation?](repeating: nil, count: segments.count)
        for si in segments.indices {
            let hits = perSegment[si]
            guard !hits.isEmpty else { continue }
            let maxGap = 3 * segmentTokenCounts[si] + 10
            // Largest cluster of hits that sit close together in the book.
            var bestStart = 0, bestLen = 0
            var runStart = 0
            for k in 1...hits.count {
                if k == hits.count || hits[k] - hits[k - 1] > maxGap {
                    if k - runStart > bestLen {
                        bestStart = runStart
                        bestLen = k - runStart
                    }
                    runStart = k
                }
            }
            let spine = bSpine[hits[bestStart]]
            let cluster = hits[bestStart..<(bestStart + bestLen)].filter { bSpine[$0] == spine }
            guard let first = cluster.first, let last = cluster.last else { continue }
            if Double(cluster.count) < max(1, 0.25 * Double(segmentTokenCounts[si])) { continue }
            let endBlock = Int(bBlock[last])
            locations[si] = ReadAlongLocation(
                spineIndex: Int(spine),
                startBlock: Int(bBlock[first]), startOffset: bRange[first].lowerBound,
                endBlock: endBlock,
                endOffset: extendingOverClosingPunctuation(bRange[last].upperBound,
                                                           in: spineBlocks[Int(spine)][endBlock]))
        }

        return ReadAlongMap(
            version: ReadAlongMap.currentVersion, key: key, locations: locations, blockLengths: blockLengths,
            matchedFraction: aKeys.isEmpty ? 0 : Double(matched) / Double(aKeys.count))
    }

    /// Moves a UTF-16 end offset past the sentence's closing punctuation and quotes
    /// (". ” ? ! …"), so the highlight takes in the full stop the way a reader sees it.
    nonisolated static func extendingOverClosingPunctuation(_ offset: Int, in text: String) -> Int {
        let closing: Set<UInt16> = Set(".,;:!?\"')]}\u{201D}\u{2019}\u{2026}\u{3002}\u{FF0C}\u{FF01}\u{FF1F}\u{300D}\u{300F}".utf16)
        let units = Array(text.utf16)
        var end = min(max(0, offset), units.count)
        while end < units.count, closing.contains(units[end]) { end += 1 }
        return end
    }
}

/// JavaScript function bodies for `EPUBReaderModel.evaluate(_:arguments:)`.
///
/// They find blocks with the same rule as `EPUBTextExtractor` (leaf elements among
/// `blockTags`) and count offsets in UTF-16 code units, which is what JS strings use.
enum ReadAlongScript {
    /// Must equal `EPUBTextExtractor.blockTags` joined by commas (pinned by a test).
    private nonisolated static let sel = "p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,dt,dd,figcaption,td,th,caption"

    /// Args: `startBlock, startOffset, endBlock, endOffset, startLength, endLength, scroll, smooth`.
    nonisolated static let highlight = #"""
    const SEL = '\#(sel)';
    const NAME = 'shelfhead-readalong';
    const useHighlights = (typeof Highlight !== 'undefined') && !!(window.CSS && CSS.highlights);
    document.querySelectorAll('.' + NAME).forEach(function (e) { e.classList.remove(NAME); });
    if (useHighlights) { CSS.highlights.delete(NAME); }
    const blocks = Array.from(document.body.querySelectorAll(SEL)).filter(function (e) { return !e.querySelector(SEL); });
    const sb = blocks[startBlock];
    const eb = blocks[endBlock];
    if (!sb) { return false; }
    function textNodes(block) {
        const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION);
        const nodes = [];
        let total = 0;
        let n;
        while ((n = walker.nextNode())) { nodes.push(n); total += n.data.length; }
        return { nodes: nodes, total: total };
    }
    function point(info, offset, isEnd) {
        if (info.nodes.length === 0) { return null; }
        let acc = 0;
        for (let i = 0; i < info.nodes.length; i++) {
            const len = info.nodes[i].data.length;
            if (isEnd ? offset <= acc + len : offset < acc + len) {
                return { node: info.nodes[i], offset: offset - acc };
            }
            acc += len;
        }
        const last = info.nodes[info.nodes.length - 1];
        return { node: last, offset: last.data.length };
    }
    let rect = null;
    let done = false;
    if (eb) {
        const si = textNodes(sb);
        const ei = (eb === sb) ? si : textNodes(eb);
        if (si.total === startLength && ei.total === endLength
            && startOffset >= 0 && startOffset <= si.total && endOffset >= 0 && endOffset <= ei.total) {
            const sp = point(si, startOffset, false);
            const ep = point(ei, endOffset, true);
            if (sp && ep) {
                const range = document.createRange();
                range.setStart(sp.node, sp.offset);
                range.setEnd(ep.node, ep.offset);
                if (useHighlights) {
                    CSS.highlights.set(NAME, new Highlight(range));
                } else {
                    blocks.slice(startBlock, endBlock + 1).forEach(function (e) { e.classList.add(NAME); });
                }
                rect = range.getBoundingClientRect();
                done = true;
            }
        }
    }
    if (!done) {
        sb.classList.add(NAME);
        rect = sb.getBoundingClientRect();
    }
    if (scroll && rect && (rect.width > 0 || rect.height > 0)) {
        const vh = window.innerHeight || document.documentElement.clientHeight;
        if (rect.top < 0 || rect.bottom > vh) {
            window.scrollTo({ top: window.scrollY + rect.top - vh / 3, behavior: smooth ? 'smooth' : 'instant' });
        }
    }
    return true;
    """#

    /// No args. Removes the highlight and any fallback classes.
    nonisolated static let clear = #"""
    const NAME = 'shelfhead-readalong';
    document.querySelectorAll('.' + NAME).forEach(function (e) { e.classList.remove(NAME); });
    if (typeof Highlight !== 'undefined' && window.CSS && CSS.highlights) { CSS.highlights.delete(NAME); }
    return null;
    """#

    /// No args. `[block, offset]` of the selection start, else of the first visible block, else null.
    nonisolated static let locate = #"""
    const SEL = '\#(sel)';
    const blocks = Array.from(document.body.querySelectorAll(SEL)).filter(function (e) { return !e.querySelector(SEL); });
    const sel = window.getSelection ? window.getSelection() : null;
    if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
        const r = sel.getRangeAt(0);
        const node = r.startContainer;
        for (let i = 0; i < blocks.length; i++) {
            if (blocks[i].contains(node)) {
                const pre = document.createRange();
                pre.selectNodeContents(blocks[i]);
                pre.setEnd(r.startContainer, r.startOffset);
                return [i, pre.toString().length];
            }
        }
    }
    for (let i = 0; i < blocks.length; i++) {
        if (blocks[i].getBoundingClientRect().bottom > 4) { return [i, 0]; }
    }
    return null;
    """#
}
