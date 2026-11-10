import XCTest
import Compression
@testable import ShelfHead

/// Pins the pure EPUB parsing behind the in-app reader (Batch 430): ZIP reading, OPF / nav / NCX
/// parsing, path resolution, progress maths and the reader CSS. Fixture archives are built in the
/// test by a tiny ZIP writer.
final class EPUBPackageTests: XCTestCase {

    // MARK: - Fixture ZIP writer

    struct TestEntry {
        var name: String
        var data: Data
        var method: UInt16 = 8
        /// Bit 3: sizes and CRC are zero in the local header and live in a data descriptor.
        var dataDescriptor = false
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    private func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let cap = data.count + 1024
        var out = Data(count: cap)
        let n: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }

    private func makeZip(_ entries: [TestEntry], comment: String = "") -> Data {
        var out = [UInt8]()
        var central = [UInt8]()
        for e in entries {
            let payload = e.method == 8 ? deflate(e.data) : e.data
            let name = Array(e.name.utf8)
            let offset = UInt32(out.count)
            let flags: UInt16 = e.dataDescriptor ? 0x8 : 0
            // Local header
            out += le32(0x0403_4B50) + le16(20) + le16(flags) + le16(e.method) + le16(0) + le16(0)
            out += le32(0) // CRC not verified by the reader
            out += le32(e.dataDescriptor ? 0 : UInt32(payload.count))
            out += le32(e.dataDescriptor ? 0 : UInt32(e.data.count))
            out += le16(UInt16(name.count)) + le16(0) + name
            out += Array(payload)
            if e.dataDescriptor {
                out += le32(0x0807_4B50) + le32(0) + le32(UInt32(payload.count)) + le32(UInt32(e.data.count))
            }
            // Central directory record (always carries the real sizes)
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(flags) + le16(e.method) + le16(0) + le16(0)
            central += le32(0) + le32(UInt32(payload.count)) + le32(UInt32(e.data.count))
            central += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(offset) + name
        }
        let cdOffset = UInt32(out.count)
        out += central
        let c = Array(comment.utf8)
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        out += le32(UInt32(central.count)) + le32(cdOffset) + le16(UInt16(c.count)) + c
        return Data(out)
    }

    private func text(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Fixture EPUBs

    private let containerXML = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    private func epub3(opf: String? = nil, nav: String? = nil, extra: [TestEntry] = []) -> Data {
        let defaultOPF = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>The Test Book</dc:title><dc:language>en-AU</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        let defaultNav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="landmarks"><ol><li><a href="ch1.xhtml">Start</a></li></ol></nav>
        <nav epub:type="toc"><ol>
          <li><a href="ch1.xhtml">Chapter  One</a>
            <ol><li><a href="ch1.xhtml#s1">Section 1.1</a></li>
                <li><a href="ch1.xhtml#s2"><span>Section</span> 1.2</a></li></ol></li>
          <li><a href="ch2.xhtml">Chapter Two</a></li>
        </ol></nav></body></html>
        """
        var entries = [
            TestEntry(name: "mimetype", data: text("application/epub+zip"), method: 0),
            TestEntry(name: "META-INF/container.xml", data: text(containerXML)),
            TestEntry(name: "OEBPS/content.opf", data: text(opf ?? defaultOPF)),
            TestEntry(name: "OEBPS/nav.xhtml", data: text(nav ?? defaultNav)),
            TestEntry(name: "OEBPS/ch1.xhtml", data: text("<html><head></head><body>" + String(repeating: "a", count: 300) + "</body></html>")),
            TestEntry(name: "OEBPS/ch2.xhtml", data: text("<html><body>" + String(repeating: "b", count: 100) + "</body></html>")),
            TestEntry(name: "OEBPS/style.css", data: text("p{}"), method: 0),
        ]
        entries += extra
        return makeZip(entries)
    }

    private func package(from zipData: Data) throws -> EPUBPackage {
        try EPUBPackage(zip: try ZipReader(data: zipData))
    }

    // MARK: - ZipReader

    func testZipStoredAndDeflatedEntries() throws {
        let big = String(repeating: "hello world ", count: 500)
        let zip = try ZipReader(data: makeZip([
            TestEntry(name: "a.txt", data: text("stored"), method: 0),
            TestEntry(name: "dir/b.txt", data: text(big), method: 8),
        ]))
        XCTAssertEqual(try zip.data(for: "a.txt"), text("stored"))
        XCTAssertEqual(try zip.data(for: "dir/b.txt"), text(big))
    }

    func testZipEntryNamesInCentralDirectoryOrder() throws {
        let zip = try ZipReader(data: makeZip([
            TestEntry(name: "z.txt", data: text("1"), method: 0),
            TestEntry(name: "a.txt", data: text("2"), method: 0),
            TestEntry(name: "m/n.txt", data: text("3"), method: 0),
        ]))
        XCTAssertEqual(zip.entryNames, ["z.txt", "a.txt", "m/n.txt"])
    }

    func testZipContains() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "a.txt", data: text("x"), method: 0)]))
        XCTAssertTrue(zip.contains("a.txt"))
        XCTAssertFalse(zip.contains("A.txt"))
        XCTAssertFalse(zip.contains("b.txt"))
    }

    func testZipDataDescriptorWithZeroSizesInLocalHeader() throws {
        let body = String(repeating: "descriptor ", count: 200)
        let zip = try ZipReader(data: makeZip([
            TestEntry(name: "d.txt", data: text(body), method: 8, dataDescriptor: true),
            TestEntry(name: "s.txt", data: text("stored"), method: 0, dataDescriptor: true),
            TestEntry(name: "after.txt", data: text("after"), method: 0),
        ]))
        XCTAssertEqual(try zip.data(for: "d.txt"), text(body))
        XCTAssertEqual(try zip.data(for: "s.txt"), text("stored"))
        XCTAssertEqual(try zip.data(for: "after.txt"), text("after"))
    }

    func testZipMissingEntryThrowsMissing() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "a.txt", data: text("x"), method: 0)]))
        XCTAssertThrowsError(try zip.data(for: "nope.txt")) {
            XCTAssertEqual($0 as? ZipError, .missing("nope.txt"))
        }
    }

    func testZipNotAZipThrows() {
        XCTAssertThrowsError(try ZipReader(data: Data("definitely not a zip file at all, just text".utf8))) {
            XCTAssertEqual($0 as? ZipError, .notAZip)
        }
    }

    func testZipTooShortThrowsNotAZip() {
        XCTAssertThrowsError(try ZipReader(data: Data())) { XCTAssertEqual($0 as? ZipError, .notAZip) }
        XCTAssertThrowsError(try ZipReader(data: Data([0x50, 0x4B, 0x05, 0x06]))) {
            XCTAssertEqual($0 as? ZipError, .notAZip)
        }
    }

    func testZipUnsupportedCompressionMethod() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "a.txt", data: text("hello"), method: 0)]).patchingMethod(to: 12))
        XCTAssertThrowsError(try zip.data(for: "a.txt")) {
            XCTAssertEqual($0 as? ZipError, .unsupportedCompression(12))
        }
    }

    func testZipEmptyArchive() throws {
        let zip = try ZipReader(data: makeZip([]))
        XCTAssertEqual(zip.entryNames, [])
    }

    func testZipEmptyEntries() throws {
        let zip = try ZipReader(data: makeZip([
            TestEntry(name: "empty-stored.txt", data: Data(), method: 0),
            TestEntry(name: "empty-deflated.txt", data: Data(), method: 8),
        ]))
        XCTAssertEqual(try zip.data(for: "empty-stored.txt"), Data())
        XCTAssertEqual(try zip.data(for: "empty-deflated.txt"), Data())
    }

    func testZipArchiveCommentIsSkipped() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "a.txt", data: text("x"), method: 0)],
                                              comment: String(repeating: "c", count: 300)))
        XCTAssertEqual(try zip.data(for: "a.txt"), text("x"))
    }

    func testZipTruncatedCentralDirectoryIsCorrupt() throws {
        var data = makeZip([TestEntry(name: "a.txt", data: text("x"), method: 0)])
        // Point the central directory offset past the end of the file.
        let eocd = data.count - 22
        data.replaceSubrange((eocd + 16)..<(eocd + 20), with: [0xF0, 0xFF, 0x00, 0x00])
        XCTAssertThrowsError(try ZipReader(data: data)) { XCTAssertEqual($0 as? ZipError, .corrupt) }
    }

    func testZipDataWithNonZeroStartIndex() throws {
        let padded = Data([1, 2, 3]) + makeZip([TestEntry(name: "a.txt", data: text("slice"), method: 0)])
        let slice = padded.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)
        let zip = try ZipReader(data: slice)
        XCTAssertEqual(try zip.data(for: "a.txt"), text("slice"))
    }

    func testZipTooLargeEntryRejected() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "big.bin", data: text("x"), method: 0)])
            .patchingUncompressedSize(to: 70 * 1024 * 1024))
        XCTAssertThrowsError(try zip.data(for: "big.bin")) { XCTAssertEqual($0 as? ZipError, .tooLarge) }
    }

    // MARK: - EPUBPackage: EPUB 3

    func testEPUB3TitleLanguageAndOPFPath() throws {
        let pkg = try package(from: epub3())
        XCTAssertEqual(pkg.title, "The Test Book")
        XCTAssertEqual(pkg.language, "en-AU")
        XCTAssertEqual(pkg.opfPath, "OEBPS/content.opf")
    }

    func testEPUB3ManifestHrefsAreFullZipPaths() throws {
        let pkg = try package(from: epub3())
        XCTAssertEqual(pkg.manifest["c1"]?.href, "OEBPS/ch1.xhtml")
        XCTAssertEqual(pkg.manifest["css"]?.mediaType, "text/css")
        XCTAssertEqual(pkg.manifest["nav"]?.properties, ["nav"])
    }

    func testEPUB3SpineOrder() throws {
        let pkg = try package(from: epub3())
        XCTAssertEqual(pkg.spine.map(\.id), ["c1", "c2"])
    }

    func testEPUB3NavTOCNestedLevels() throws {
        let pkg = try package(from: epub3())
        XCTAssertEqual(pkg.toc, [
            EPUBTOCEntry(title: "Chapter One", href: "OEBPS/ch1.xhtml", level: 0),
            EPUBTOCEntry(title: "Section 1.1", href: "OEBPS/ch1.xhtml#s1", level: 1),
            EPUBTOCEntry(title: "Section 1.2", href: "OEBPS/ch1.xhtml#s2", level: 1),
            EPUBTOCEntry(title: "Chapter Two", href: "OEBPS/ch2.xhtml", level: 0),
        ])
    }

    func testEPUB3NavIgnoresLandmarksNav() throws {
        let pkg = try package(from: epub3())
        XCTAssertFalse(pkg.toc.contains { $0.title == "Start" })
    }

    func testSpineWeightsAreUncompressedSizes() throws {
        let pkg = try package(from: epub3())
        XCTAssertEqual(pkg.spineWeights.count, 2)
        XCTAssertGreaterThan(pkg.spineWeights[0], pkg.spineWeights[1])
        XCTAssertEqual(pkg.spineWeights[0], "<html><head></head><body>".utf8.count + 300 + "</body></html>".utf8.count)
    }

    func testSpineIndexForPathIgnoresFragment() throws {
        let pkg = try package(from: epub3())
        XCTAssertEqual(pkg.spineIndex(forPath: "OEBPS/ch2.xhtml"), 1)
        XCTAssertEqual(pkg.spineIndex(forPath: "OEBPS/ch1.xhtml#s2"), 0)
        XCTAssertNil(pkg.spineIndex(forPath: "OEBPS/nope.xhtml"))
        XCTAssertNil(pkg.spineIndex(forPath: "OEBPS/style.css"))
    }

    func testLinearNoItemsDroppedFromSpine() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf"><metadata/>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="notes" linear="no"/><itemref idref="c2" linear="yes"/></spine>
        </package>
        """
        let pkg = try package(from: epub3(opf: opf))
        XCTAssertEqual(pkg.spine.map(\.id), ["c1", "c2"])
        XCTAssertEqual(pkg.spineWeights.count, 2)
    }

    func testNonHTMLSpineItemsDropped() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf"><metadata/>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="img" href="cover.png" media-type="image/png"/>
            <item id="h" href="ch2.xhtml" media-type="text/html"/>
          </manifest>
          <spine><itemref idref="img"/><itemref idref="c1"/><itemref idref="h"/><itemref idref="ghost"/></spine>
        </package>
        """
        let pkg = try package(from: epub3(opf: opf))
        XCTAssertEqual(pkg.spine.map(\.id), ["c1", "h"])
    }

    func testNamespacePrefixesOnOPFElements() throws {
        let opf = """
        <?xml version="1.0"?>
        <opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="2.0">
          <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Prefixed Title</dc:title><dc:language>fr</dc:language>
          </opf:metadata>
          <opf:manifest>
            <opf:item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </opf:manifest>
          <opf:spine><opf:itemref idref="c1"/></opf:spine>
        </opf:package>
        """
        let pkg = try package(from: epub3(opf: opf))
        XCTAssertEqual(pkg.title, "Prefixed Title")
        XCTAssertEqual(pkg.language, "fr")
        XCTAssertEqual(pkg.spine.map(\.id), ["c1"])
    }

    func testOPFTitleIsFirstDCTitleOnly() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Main</dc:title><dc:title>Second</dc:title></metadata>
          <manifest/><spine/></package>
        """
        XCTAssertEqual(try package(from: epub3(opf: opf)).title, "Main")
    }

    func testOPFWithoutTitleOrLanguage() throws {
        let opf = "<package xmlns=\"http://www.idpf.org/2007/opf\"><metadata/><manifest/><spine/></package>"
        let pkg = try package(from: epub3(opf: opf))
        XCTAssertNil(pkg.title)
        XCTAssertNil(pkg.language)
        XCTAssertTrue(pkg.spine.isEmpty)
        XCTAssertTrue(pkg.spineWeights.isEmpty)
    }

    // MARK: - EPUBPackage: subfolders, ../ and percent-encoding

    func testOPFInSubfolderWithParentRefsAndPercentEncoding() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf"><metadata/>
          <manifest>
            <item id="c1" href="ch%201.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="../Text/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        let pkg = try package(from: epub3(opf: opf, extra: [
            TestEntry(name: "OEBPS/ch 1.xhtml", data: text("<p>spaced</p>")),
            TestEntry(name: "Text/ch2.xhtml", data: text("<p>two</p>")),
        ]))
        XCTAssertEqual(pkg.spine.map(\.href), ["OEBPS/ch 1.xhtml", "Text/ch2.xhtml"])
        XCTAssertEqual(pkg.spineIndex(forPath: "Text/ch2.xhtml#x"), 1)
        XCTAssertEqual(pkg.spineWeights[0], "<p>spaced</p>".utf8.count)
    }

    func testRootfileInDeeperFolder() throws {
        let container = """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
        <rootfile full-path="book/OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf"><metadata/>
        <manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c"/></spine></package>
        """
        let data = makeZip([
            TestEntry(name: "META-INF/container.xml", data: text(container)),
            TestEntry(name: "book/OPS/package.opf", data: text(opf)),
            TestEntry(name: "book/OPS/text/c.xhtml", data: text("<p>x</p>")),
        ])
        let pkg = try package(from: data)
        XCTAssertEqual(pkg.opfPath, "book/OPS/package.opf")
        XCTAssertEqual(pkg.spine.first?.href, "book/OPS/text/c.xhtml")
    }

    // MARK: - EPUBPackage: EPUB 2 NCX

    private func epub2Zip(ncx: String, spineToc: Bool = true) -> Data {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Old Book</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine\(spineToc ? " toc=\"ncx\"" : "")><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        return makeZip([
            TestEntry(name: "META-INF/container.xml", data: text(containerXML)),
            TestEntry(name: "OEBPS/content.opf", data: text(opf)),
            TestEntry(name: "OEBPS/toc.ncx", data: text(ncx)),
            TestEntry(name: "OEBPS/ch1.xhtml", data: text("<p>1</p>")),
            TestEntry(name: "OEBPS/ch2.xhtml", data: text("<p>2</p>")),
        ])
    }

    private let sampleNCX = """
    <?xml version="1.0"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="x"/></head>
      <docTitle><text>Old Book</text></docTitle>
      <navMap>
        <navPoint id="n1" playOrder="1"><navLabel><text>Part One</text></navLabel><content src="ch1.xhtml"/>
          <navPoint id="n2" playOrder="2"><navLabel><text>Sub A</text></navLabel><content src="ch1.xhtml#a"/></navPoint>
        </navPoint>
        <navPoint id="n3" playOrder="3"><navLabel><text>Part Two</text></navLabel><content src="ch2.xhtml"/></navPoint>
      </navMap>
      <pageList><pageTarget id="p1"><navLabel><text>Page 1</text></navLabel><content src="ch1.xhtml#p1"/></pageTarget></pageList>
    </ncx>
    """

    func testEPUB2NCXOnly() throws {
        let pkg = try package(from: epub2Zip(ncx: sampleNCX))
        XCTAssertEqual(pkg.title, "Old Book")
        XCTAssertEqual(pkg.toc, [
            EPUBTOCEntry(title: "Part One", href: "OEBPS/ch1.xhtml", level: 0),
            EPUBTOCEntry(title: "Sub A", href: "OEBPS/ch1.xhtml#a", level: 1),
            EPUBTOCEntry(title: "Part Two", href: "OEBPS/ch2.xhtml", level: 0),
        ])
    }

    func testEPUB2NCXFoundByMediaTypeWithoutSpineTocAttribute() throws {
        let pkg = try package(from: epub2Zip(ncx: sampleNCX, spineToc: false))
        XCTAssertEqual(pkg.toc.count, 3)
    }

    func testEPUB2NCXWithNamespacePrefix() throws {
        let ncx = """
        <n:ncx xmlns:n="http://www.daisy.org/z3986/2005/ncx/"><n:navMap>
        <n:navPoint id="a"><n:navLabel><n:text>Only</n:text></n:navLabel><n:content src="ch1.xhtml"/></n:navPoint>
        </n:navMap></n:ncx>
        """
        let pkg = try package(from: epub2Zip(ncx: ncx))
        XCTAssertEqual(pkg.toc, [EPUBTOCEntry(title: "Only", href: "OEBPS/ch1.xhtml", level: 0)])
    }

    func testNoNavOrNCXGivesEmptyTOC() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf"><metadata/>
        <manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine></package>
        """
        let pkg = try package(from: epub3(opf: opf))
        XCTAssertTrue(pkg.toc.isEmpty)
        XCTAssertEqual(pkg.spine.count, 1)
    }

    func testNavWinsOverNCXWhenBothPresent() throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata/>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        </manifest><spine toc="ncx"><itemref idref="c1"/></spine></package>
        """
        let pkg = try package(from: epub3(opf: opf, extra: [
            TestEntry(name: "OEBPS/toc.ncx", data: text(sampleNCX)),
        ]))
        XCTAssertEqual(pkg.toc.first?.title, "Chapter One")
    }

    // MARK: - EPUBPackage: errors

    func testMissingContainerXMLThrowsMissing() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "mimetype", data: text("application/epub+zip"), method: 0)]))
        XCTAssertThrowsError(try EPUBPackage(zip: zip)) {
            XCTAssertEqual($0 as? ZipError, .missing("META-INF/container.xml"))
        }
    }

    func testMissingOPFThrowsMissing() throws {
        let zip = try ZipReader(data: makeZip([TestEntry(name: "META-INF/container.xml", data: text(containerXML))]))
        XCTAssertThrowsError(try EPUBPackage(zip: zip)) {
            XCTAssertEqual($0 as? ZipError, .missing("OEBPS/content.opf"))
        }
    }

    func testContainerWithoutRootfileIsCorrupt() throws {
        let zip = try ZipReader(data: makeZip([
            TestEntry(name: "META-INF/container.xml", data: text("<container><rootfiles/></container>")),
        ]))
        XCTAssertThrowsError(try EPUBPackage(zip: zip)) { XCTAssertEqual($0 as? ZipError, .corrupt) }
    }

    func testMalformedOPFIsCorrupt() throws {
        XCTAssertThrowsError(try package(from: epub3(opf: "<package><metadata></package"))) {
            XCTAssertEqual($0 as? ZipError, .corrupt)
        }
    }

    // MARK: - EPUBPath.resolve

    func testResolveSiblingFile() {
        XCTAssertEqual(EPUBPath.resolve("ch2.xhtml", relativeTo: "OEBPS/ch1.xhtml"), "OEBPS/ch2.xhtml")
    }

    func testResolveParentDirectory() {
        XCTAssertEqual(EPUBPath.resolve("../Images/a.png", relativeTo: "OEBPS/Text/ch1.xhtml"), "OEBPS/Images/a.png")
    }

    func testResolveKeepsFragment() {
        XCTAssertEqual(EPUBPath.resolve("ch2.xhtml#sec-1", relativeTo: "OEBPS/ch1.xhtml"), "OEBPS/ch2.xhtml#sec-1")
    }

    func testResolveFragmentOnly() {
        XCTAssertEqual(EPUBPath.resolve("#top", relativeTo: "OEBPS/ch1.xhtml"), "OEBPS/ch1.xhtml#top")
    }

    func testResolvePercentDecodes() {
        XCTAssertEqual(EPUBPath.resolve("ch%201.xhtml", relativeTo: "OEBPS/content.opf"), "OEBPS/ch 1.xhtml")
    }

    func testResolveDotSegments() {
        XCTAssertEqual(EPUBPath.resolve("./a/./b.xhtml", relativeTo: "OEBPS/content.opf"), "OEBPS/a/b.xhtml")
    }

    func testResolveBaseAtRoot() {
        XCTAssertEqual(EPUBPath.resolve("ch1.xhtml", relativeTo: "content.opf"), "ch1.xhtml")
    }

    func testResolveAboveRootClamps() {
        XCTAssertEqual(EPUBPath.resolve("../../x.xhtml", relativeTo: "OEBPS/content.opf"), "x.xhtml")
    }

    func testResolveAbsolutePathMeansZipRoot() {
        XCTAssertEqual(EPUBPath.resolve("/OEBPS/ch1.xhtml", relativeTo: "Other/Deep/base.xhtml"), "OEBPS/ch1.xhtml")
    }

    func testResolveMultipleParentSegments() {
        XCTAssertEqual(EPUBPath.resolve("../../css/s.css", relativeTo: "A/B/C/page.xhtml"), "A/css/s.css")
    }

    // MARK: - EPUBPath.mimeType

    func testMimeTypes() {
        let expected: [String: String] = [
            "a.xhtml": "application/xhtml+xml", "a.html": "text/html", "a.htm": "text/html",
            "a.css": "text/css", "a.js": "application/javascript", "a.svg": "image/svg+xml",
            "a.png": "image/png", "a.jpg": "image/jpeg", "a.jpeg": "image/jpeg", "a.gif": "image/gif",
            "a.webp": "image/webp", "a.ttf": "font/ttf", "a.otf": "font/otf", "a.woff": "font/woff",
            "a.woff2": "font/woff2", "a.xml": "application/xml", "a.ncx": "application/x-dtbncx+xml",
            "a.opf": "application/oebps-package+xml",
        ]
        for (path, mime) in expected {
            XCTAssertEqual(EPUBPath.mimeType(forPath: path), mime, path)
        }
    }

    func testMimeTypeIsCaseInsensitiveAndIgnoresFragment() {
        XCTAssertEqual(EPUBPath.mimeType(forPath: "OEBPS/Images/COVER.JPG"), "image/jpeg")
        XCTAssertEqual(EPUBPath.mimeType(forPath: "OEBPS/ch1.xhtml#frag"), "application/xhtml+xml")
    }

    func testMimeTypeDefault() {
        XCTAssertEqual(EPUBPath.mimeType(forPath: "a.bin"), "application/octet-stream")
        XCTAssertEqual(EPUBPath.mimeType(forPath: "noextension"), "application/octet-stream")
    }

    // MARK: - EPUBPosition

    func testOverallProgressWeighted() {
        let weights = [100, 300, 600]
        XCTAssertEqual(EPUBPosition(spineIndex: 0, fraction: 0).overallProgress(weights: weights), 0, accuracy: 1e-9)
        XCTAssertEqual(EPUBPosition(spineIndex: 0, fraction: 0.5).overallProgress(weights: weights), 0.05, accuracy: 1e-9)
        XCTAssertEqual(EPUBPosition(spineIndex: 1, fraction: 0).overallProgress(weights: weights), 0.1, accuracy: 1e-9)
        XCTAssertEqual(EPUBPosition(spineIndex: 1, fraction: 0.5).overallProgress(weights: weights), 0.25, accuracy: 1e-9)
        XCTAssertEqual(EPUBPosition(spineIndex: 2, fraction: 1).overallProgress(weights: weights), 1, accuracy: 1e-9)
    }

    func testOverallProgressEmptyWeightsIsZero() {
        XCTAssertEqual(EPUBPosition(spineIndex: 0, fraction: 0.5).overallProgress(weights: []), 0)
    }

    func testFractionClampedOnInit() {
        XCTAssertEqual(EPUBPosition(spineIndex: 0, fraction: 1.7).fraction, 1)
        XCTAssertEqual(EPUBPosition(spineIndex: 0, fraction: -0.3).fraction, 0)
        XCTAssertEqual(EPUBPosition(spineIndex: 0, fraction: .nan).fraction, 0)
    }

    func testFractionClampedWhenMutated() {
        var p = EPUBPosition(spineIndex: 0, fraction: 0)
        p.fraction = 5
        XCTAssertEqual(p.overallProgress(weights: [10, 10]), 0.5, accuracy: 1e-9)
        p.fraction = -5
        XCTAssertEqual(p.overallProgress(weights: [10, 10]), 0, accuracy: 1e-9)
    }

    func testOverallProgressSpineIndexOutOfRangeClamps() {
        XCTAssertEqual(EPUBPosition(spineIndex: 9, fraction: 1).overallProgress(weights: [10, 10]), 1, accuracy: 1e-9)
        XCTAssertEqual(EPUBPosition(spineIndex: -2, fraction: 0).overallProgress(weights: [10, 10]), 0, accuracy: 1e-9)
    }

    func testOverallProgressAllZeroWeightsUsesEqualShares() {
        XCTAssertEqual(EPUBPosition(spineIndex: 1, fraction: 0.5).overallProgress(weights: [0, 0]), 0.75, accuracy: 1e-9)
    }

    func testPositionCodableRoundTrip() throws {
        let original = EPUBPosition(spineIndex: 4, fraction: 0.25)
        let decoded = try JSONDecoder().decode(EPUBPosition.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - EPUBReaderStyle

    private func style(scale: Double = 1.0, serif: Bool = true) -> EPUBReaderStyle {
        EPUBReaderStyle(backgroundHex: "#112233", textHex: "#EEDDCC", accentHex: "#FF8800",
                        fontScale: scale, serif: serif)
    }

    func testCSSContainsColours() {
        let css = style().css
        XCTAssertTrue(css.contains("#112233"))
        XCTAssertTrue(css.contains("#EEDDCC"))
        XCTAssertTrue(css.contains("#FF8800"))
        XCTAssertTrue(css.contains("!important"))
    }

    func testCSSFontSizePercent() {
        XCTAssertTrue(style(scale: 1.0).css.contains("font-size: 100%"))
        XCTAssertTrue(style(scale: 1.15).css.contains("font-size: 115%"))
        XCTAssertTrue(style(scale: 1.1).css.contains("font-size: 110%"))
    }

    func testCSSFontScaleClamped() {
        XCTAssertTrue(style(scale: 0.1).css.contains("font-size: 80%"))
        XCTAssertTrue(style(scale: 9).css.contains("font-size: 250%"))
    }

    func testCSSContainsReadAlongClass() {
        let css = style().css
        XCTAssertTrue(css.contains(".shelfhead-readalong"))
        XCTAssertTrue(css.contains("rgba(255, 136, 0, 0.3)"))
        XCTAssertTrue(css.contains("border-radius: 3px"))
    }

    func testCSSFontFamilyFollowsSerifFlag() {
        XCTAssertTrue(style(serif: true).css.contains("\"New York\""))
        XCTAssertFalse(style(serif: true).css.contains("-apple-system"))
        XCTAssertTrue(style(serif: false).css.contains("-apple-system"))
        XCTAssertFalse(style(serif: false).css.contains("\"New York\""))
    }

    func testCSSLayoutRules() {
        let css = style().css
        XCTAssertTrue(css.contains("max-width: 40em"))
        XCTAssertTrue(css.contains("padding: 20px"))
        XCTAssertTrue(css.contains("line-height: 1.6"))
        XCTAssertTrue(css.contains("-webkit-text-size-adjust: none"))
        XCTAssertTrue(css.contains("max-width: 100%"))
    }

    func testCSSRejectsNonHexColoursInsteadOfInjecting() {
        let bad = EPUBReaderStyle(backgroundHex: "red; } body { display:none", textHex: "#000000",
                                  accentHex: "#abc", fontScale: 1, serif: true)
        XCTAssertFalse(bad.css.contains("display:none"))
        XCTAssertTrue(bad.css.contains("#abc"))
        XCTAssertTrue(bad.css.contains("rgba(170, 187, 204, 0.3)"))
    }

    // MARK: - EbookFileMetadata.normalizedExtension

    private func metadata(ext: String?) throws -> EbookFileMetadata {
        let json = ext.map { "{\"filename\":\"b\",\"ext\":\"\($0)\"}" } ?? "{\"filename\":\"b\"}"
        return try JSONDecoder().decode(EbookFileMetadata.self, from: Data(json.utf8))
    }

    func testNormalizedExtension() throws {
        XCTAssertEqual(try metadata(ext: ".EPUB").normalizedExtension, "epub")
        XCTAssertEqual(try metadata(ext: ".epub").normalizedExtension, "epub")
        XCTAssertEqual(try metadata(ext: "pdf").normalizedExtension, "pdf")
        XCTAssertEqual(try metadata(ext: "..Cbz").normalizedExtension, "cbz")
        XCTAssertEqual(try metadata(ext: nil).normalizedExtension, "")
        XCTAssertEqual(try metadata(ext: "").normalizedExtension, "")
        XCTAssertEqual(try metadata(ext: ".").normalizedExtension, "")
    }
}

// MARK: - Fixture patching

private extension Data {
    /// Rewrites the compression method in the central directory and the first local header.
    func patchingMethod(to method: UInt16) -> Data {
        var d = self
        let bytes = [UInt8(method & 0xFF), UInt8(method >> 8)]
        d.replaceSubrange(8..<10, with: bytes) // local header (first entry)
        if let cd = d.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])) {
            d.replaceSubrange((cd.lowerBound + 10)..<(cd.lowerBound + 12), with: bytes)
        }
        return d
    }

    /// Rewrites the uncompressed size in the first central-directory record.
    func patchingUncompressedSize(to size: UInt32) -> Data {
        var d = self
        if let cd = d.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])) {
            let b = [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
            d.replaceSubrange((cd.lowerBound + 24)..<(cd.lowerBound + 28), with: b)
        }
        return d
    }
}
